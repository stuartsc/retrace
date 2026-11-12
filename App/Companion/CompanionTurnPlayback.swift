import AVFoundation
import Foundation
import Shared

public struct CompanionTurnPlaybackState: Sendable {
    public let isPlaying: Bool
    public let reference: CompanionTurnReference?
    public let errorCode: String?
}

/// One App-owned exact-turn player, independent of whether companion delivery is enabled.
/// Every start resolves retained evidence before and after decoding original registered AAC.
public actor CompanionTurnPlayback {
    private struct Selection: Sendable { let turn: CompanionTurnPresentation; let pcm: Data }
    private let controller: CompanionController
    private let media: MarkerAudioMediaService
    private let gate: RetracePlaybackGate
    private let mutedForTesting: Bool
    private nonisolated let admission = CompanionTurnPlaybackAdmission()
    private nonisolated let events = CompanionTurnPlaybackEvents()
    private var observer: UUID?
    private var eventTask: Task<Void, Never>?
    private var preparing: (UUID, Task<Selection, Error>)?
    private var retiring: [UUID: Task<Selection, Error>] = [:]
    private var player: AVAudioPlayer?
    private var delegate: CompanionTurnPlayerDelegate?
    private var active: (token: UUID, reference: CompanionTurnReference)?
    private var lease: UUID?
    private var latestRequest = UUID()
    private var terminal = false
    private var closing: Task<Void, Never>?
    private var errorCode: String?

    public init(controller: CompanionController, media: MarkerAudioMediaService, gate: RetracePlaybackGate = .shared) {
        self.controller = controller; self.media = media; self.gate = gate; mutedForTesting = false
    }
    init(controller: CompanionController, media: MarkerAudioMediaService, gate: RetracePlaybackGate, mutedForTesting: Bool) {
        self.controller = controller; self.media = media; self.gate = gate; self.mutedForTesting = mutedForTesting
    }
    public func snapshot() -> CompanionTurnPlaybackState {
        .init(isPlaying: player?.isPlaying == true, reference: active?.reference, errorCode: errorCode)
    }
    public nonisolated func invalidate(_ change: CompanionSpeakerChange = .all) {
        if admission.invalidate(change) { events.send(.invalidated) }
    }
    public func play(_ reference: CompanionTurnReference, commandFence: NativeMutationFence? = nil) async throws {
        guard !terminal else { throw CompanionError.closed }
        try commandFence?.withAdmission {}
        try reference.validate(); try Task.checkCancellation()
        let request = UUID(); latestRequest = request
        await stopOwned()
        guard !terminal, latestRequest == request else { throw CancellationError() }
        try ensureObserver()
        let token = admission.begin(reference); errorCode = nil
        let controller = self.controller, media = self.media, admission = self.admission
        let task = Task {
            let initial = try await controller.resolveTurn(reference)
            try admission.bind(initial, token: token)
            let pcm = try await media.resolvePCM(.init(nativeStoreID: reference.nativeStoreID, identity: initial.sourceIdentity))
            let current = try await controller.resolveTurn(reference)
            guard CompanionController.sameWire(initial.sourceIdentity, current.sourceIdentity),
                  initial.firstPassReferences == current.firstPassReferences else { throw CompanionError.staleEvidence }
            try Task.checkCancellation(); try admission.check(token)
            return Selection(turn: current, pcm: pcm)
        }
        preparing = (token, task)
        do {
            let selection = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: {
                admission.cancel(token); task.cancel()
            })
            guard preparing?.0 == token, !terminal else { throw CancellationError() }
            try Task.checkCancellation(); try admission.check(token)
            try commandFence?.withAdmission {}
            let output = try AVAudioPlayer(data: Self.wave(selection.pcm))
            if mutedForTesting { output.volume = 0 }
            let events = self.events
            let delegate = CompanionTurnPlayerDelegate { events.send(.finished(token, $0)) }
            output.delegate = delegate
            guard output.prepareToPlay() else { throw MarkerAudioMediaError.unavailable }
            player = output; self.delegate = delegate; active = (token, reference)
            try admission.start(token) {
                let start = {
                    self.lease = self.gate.acquire()
                    guard output.play() else { throw MarkerAudioMediaError.unavailable }
                }
                if let commandFence { try commandFence.withAdmission(start) } else { try start() }
            }
            preparing = nil
        } catch {
            if preparing?.0 == token || active?.token == token {
                preparing = nil; stopPlayer()
                errorCode = error is CancellationError ? nil : "audio_unavailable"
            }
            throw error
        }
    }
    /// Called after a synchronous invalidation, outside SQL. Never waits for a source
    /// read: that read may be suspended on the mutation owner which is awaiting this drain.
    public func drainOutput() {
        guard !admission.hasCurrent else { return }
        preparing?.1.cancel(); stopPlayer()
    }
    public func stop() async { latestRequest = UUID(); await stopOwned() }
    public func stop(ifCurrent reference: CompanionTurnReference) async {
        guard active?.reference == reference else { return }
        latestRequest = UUID(); await stopOwned()
    }
    public func stop(commandFence: NativeMutationFence) async throws {
        try commandFence.withAdmission {
            latestRequest = UUID(); _ = admission.invalidate(.all)
            preparing?.1.cancel(); stopPlayer()
        }
        await stopOwned()
    }
    private func stopOwned() async {
        _ = admission.invalidate(.all)
        let prior = preparing; preparing = nil
        prior?.1.cancel(); if let prior { retiring[prior.0] = prior.1 }
        stopPlayer()
        let pending = retiring
        for task in pending.values { _ = await task.result }
        for id in pending.keys { retiring[id] = nil }
    }
    public func close() async {
        if let closing { await closing.value; return }
        terminal = true; latestRequest = UUID(); invalidate()
        let task = Task {
            await self.stopOwned()
            if let observer = self.observer { self.controller.removeSpeakerChangeObserver(observer); self.observer = nil }
            self.events.finish()
            if let eventTask = self.eventTask { await eventTask.value; self.eventTask = nil }
        }
        closing = task; await task.value
    }
    private func ensureObserver() throws {
        if observer != nil { return }
        observer = try controller.addSpeakerChangeObserver(invalidate: { [weak self] in self?.invalidate($0) },
            drain: { [weak self] in await self?.drainOutput() })
        let stream = events.stream
        eventTask = Task { [weak self] in
            for await event in stream { await self?.receive(event) }
        }
    }
    private func receive(_ event: CompanionTurnPlaybackEvents.Event) {
        switch event {
        case .invalidated: drainOutput()
        case .finished(let token, let success):
            guard active?.token == token else { return }
            _ = admission.invalidate(.all); stopPlayer(); errorCode = success ? nil : "audio_unavailable"
        }
    }
    private func stopPlayer() {
        player?.stop(); player?.delegate = nil; player = nil; delegate = nil; active = nil
        if let lease { gate.release(lease); self.lease = nil }
    }
    private static func wave(_ pcm: Data) -> Data {
        var result = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var encoded = value.littleEndian
            withUnsafeBytes(of: &encoded) { result.append(contentsOf: $0) }
        }
        append(UInt32(36 + pcm.count)); result.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(16000))
        append(UInt32(32000)); append(UInt16(2)); append(UInt16(16))
        result.append(Data("data".utf8)); append(UInt32(pcm.count)); result.append(pcm); return result
    }
}

final class CompanionTurnPlaybackAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID?
    private var reference: CompanionTurnReference?
    private var speakerID: String?
    private var dependencies = NativeSourceDependencies.unknown
    var hasCurrent: Bool { lock.withLock { token != nil } }
    func begin(_ reference: CompanionTurnReference) -> UUID {
        lock.withLock {
            let token = UUID(); self.token = token; self.reference = reference
            speakerID = nil; dependencies = .unknown; return token
        }
    }
    func bind(_ turn: CompanionTurnPresentation, token: UUID) throws {
        try lock.withLock {
            guard self.token == token else { throw CancellationError() }
            speakerID = turn.turn.speakerID; dependencies = turn.sourceDependencies
        }
    }
    func check(_ token: UUID) throws {
        try lock.withLock { guard self.token == token else { throw CancellationError() } }
    }
    func cancel(_ expected: UUID) {
        lock.withLock {
            guard token == expected else { return }
            token = nil; reference = nil; speakerID = nil; dependencies = .unknown
        }
    }
    func start(_ token: UUID, output: () throws -> Void) throws {
        try lock.withLock { guard self.token == token else { throw CancellationError() }; try output() }
    }
    @discardableResult func invalidate(_ change: CompanionSpeakerChange) -> Bool {
        lock.withLock {
            guard token != nil else { return false }
            let affected: Bool
            switch change {
            case .all: affected = true
            case .source(let mutation): affected = mutation.affects(dependencies)
            case .correction(let job, let speaker): affected = reference?.jobID == job && (speakerID == nil || speakerID == speaker)
            }
            guard affected else { return false }
            token = nil; reference = nil; speakerID = nil; dependencies = .unknown; return true
        }
    }
}
private final class CompanionTurnPlaybackEvents: Sendable {
    enum Event: Sendable { case invalidated, finished(UUID, Bool) }
    let stream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    init() { (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32)) }
    func send(_ event: Event) { continuation.yield(event) }
    func finish() { continuation.finish() }
}
private final class CompanionTurnPlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let completed: @Sendable (Bool) -> Void
    init(completed: @escaping @Sendable (Bool) -> Void) { self.completed = completed }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { completed(flag) }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { completed(false) }
}
