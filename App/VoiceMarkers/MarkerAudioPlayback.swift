import AVFoundation
import Foundation
import Shared

public struct MarkerAudioPlaybackState: Sendable {
    public let isPlaying: Bool
    public let markerID: UUID?
    public let revision: UUID?
    public let errorCode: String?
}

/// One App-owned player for UI and explicit foreground commands. It plays only
/// verified in-memory PCM; source files are never handed to a late URL opener.
public actor MarkerAudioPlayback {
    private let media: MarkerAudioMediaService
    private let markers: TimelineMarkerService
    private let gate: RetracePlaybackGate
    private let isMuted: Bool
    private let admission = MarkerPlaybackAdmission()
    private var observer: UUID?
    private var observerInitialization: Task<UUID, Error>?
    private var preparing: (UUID, Task<MarkerAudioSelection, Error>)?
    private var retiring: [UUID: Task<MarkerAudioSelection, Error>] = [:]
    private var closing: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var delegate: MarkerPlayerDelegate?
    private var lease: UUID?
    private var active: (id: UUID, revision: UUID, token: UUID)?
    private var terminal = false
    private var errorCode: String?
    private var latestRequest = UUID()

    public init(media: MarkerAudioMediaService, markers: TimelineMarkerService,
                gate: RetracePlaybackGate = .shared) {
        self.media = media; self.markers = markers; self.gate = gate
        isMuted = false
    }

    init(media: MarkerAudioMediaService, markers: TimelineMarkerService,
         gate: RetracePlaybackGate, mutedForTesting: Bool) {
        self.media = media; self.markers = markers; self.gate = gate
        isMuted = mutedForTesting
    }

    public func play(markerID: UUID, expectedRevision: UUID, commandFence: NativeMutationFence? = nil) async throws {
        guard !terminal else { throw ContextStoreError.closed }
        try commandFence?.withAdmission {}
        try Task.checkCancellation()
        let request = UUID(); latestRequest = request
        await stopOwned()
        guard !terminal, latestRequest == request else { throw CancellationError() }
        try await ensureObserver()
        guard !terminal, latestRequest == request else { throw CancellationError() }
        let token = admission.begin(markerID)
        errorCode = nil
        let task = Task { try await media.resolve(markerID: markerID, expectedRevision: expectedRevision) }
        preparing = (token, task)
        do {
            let selection = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: {
                self.admission.invalidate(markerID); task.cancel()
            })
            guard preparing?.0 == token, admission.isCurrent(token), !terminal else { throw CancellationError() }
            guard let current = try await markers.marker(id: markerID), current.revision == selection.markerRevision else {
                throw MarkerAudioMediaError.staleMarker
            }
            try Task.checkCancellation()
            guard admission.isCurrent(token), !terminal else { throw CancellationError() }
            try commandFence?.withAdmission {}
            let output = try AVAudioPlayer(data: Self.wave(selection.pcm))
            if isMuted { output.volume = 0 }
            let completion = MarkerPlayerDelegate { [weak self] succeeded in
                Task { await self?.finished(token: token, succeeded: succeeded) }
            }
            output.delegate = completion
            guard output.prepareToPlay(), admission.isCurrent(token) else { throw MarkerAudioMediaError.unavailable }
            try admission.start(token) {
                let start = {
                    self.lease = self.gate.acquire()
                    self.player = output; self.delegate = completion
                    self.active = (markerID, expectedRevision, token)
                    guard output.play() else { throw MarkerAudioMediaError.unavailable }
                }
                if let commandFence { try commandFence.withAdmission(start) } else { try start() }
            }
            preparing = nil
        } catch {
            if preparing?.0 == token || active?.token == token {
                stopPlayer(); preparing = nil
                errorCode = error is CancellationError ? nil : "audio_unavailable"
            }
            throw error
        }
    }

    public func snapshot() -> MarkerAudioPlaybackState {
        .init(isPlaying: player?.isPlaying == true, markerID: active?.id,
              revision: active?.revision, errorCode: errorCode)
    }

    public func stop() async {
        latestRequest = UUID()
        await stopOwned()
    }

    public func stop(commandFence: NativeMutationFence) async throws {
        try commandFence.withAdmission {
            latestRequest = UUID(); admission.invalidate(nil)
            preparing?.1.cancel(); stopPlayer()
        }
        await stopOwned()
    }

    private func stopOwned() async {
        admission.invalidate(nil)
        let prior = preparing; preparing = nil
        prior?.1.cancel()
        if let prior { retiring[prior.0] = prior.1 }
        stopPlayer()
        let pending = retiring
        for task in pending.values { _ = await task.result }
        for id in pending.keys { retiring[id] = nil }
    }

    public func close() async {
        if let closing { await closing.value; return }
        terminal = true
        latestRequest = UUID()
        let drain = Task {
            await self.stopOwned()
            if let initialization = self.observerInitialization {
                if let id = try? await initialization.value { await self.markers.removeChangeObserver(id) }
                self.observerInitialization = nil
            }
            if let observer = self.observer { await self.markers.removeChangeObserver(observer); self.observer = nil }
        }
        closing = drain
        await drain.value
    }

    private func ensureObserver() async throws {
        if observer != nil { return }
        let task: Task<UUID, Error>
        if let current = observerInitialization { task = current }
        else {
            let admission = self.admission, markers = self.markers
            task = Task { [weak self] in
                try await markers.addChangeObserver(invalidate: { admission.invalidate($0) }, drain: { [weak self] id in
                    await self?.markerChanged(id)
                })
            }
            observerInitialization = task
        }
        do {
            let id = try await task.value
            guard !terminal else { await markers.removeChangeObserver(id); throw ContextStoreError.closed }
            observer = id; observerInitialization = nil
        } catch { observerInitialization = nil; throw error }
    }

    private func markerChanged(_ id: UUID?) async {
        guard id == nil || id == active?.id || !admission.hasCurrent else { return }
        // Do not join a pending marker read here: this callback itself is joined
        // by a marker write. Cancellation fences its later presentation instead.
        preparing?.1.cancel()
        stopPlayer()
    }

    private func stopPlayer() {
        player?.stop(); player?.delegate = nil; player = nil; delegate = nil; active = nil
        if let lease { gate.release(lease); self.lease = nil }
    }

    private func finished(token: UUID, succeeded: Bool) {
        guard active?.token == token else { return }
        stopPlayer()
        errorCode = succeeded ? nil : "audio_unavailable"
    }

    private static func wave(_ pcm: Data) -> Data {
        var result = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var encoded = value.littleEndian
            withUnsafeBytes(of: &encoded) { result.append(contentsOf: $0) }
        }
        append(UInt32(36 + pcm.count)); result.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16_000)); append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
        result.append(Data("data".utf8)); append(UInt32(pcm.count)); result.append(pcm)
        return result
    }
}

private final class MarkerPlaybackAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var markerID: UUID?
    private var token: UUID?
    func begin(_ id: UUID) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let value = UUID(); markerID = id; token = value; return value
    }
    func invalidate(_ id: UUID?) {
        lock.lock(); defer { lock.unlock() }
        if id == nil || markerID == id { token = nil; markerID = nil }
    }
    func isCurrent(_ value: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return token == value }
    func start(_ value: UUID, effect: () throws -> Void) throws {
        try lock.withLock { guard token == value else { throw CancellationError() }; try effect() }
    }
    var hasCurrent: Bool { lock.lock(); defer { lock.unlock() }; return token != nil }
}

private final class MarkerPlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let completed: @Sendable (Bool) -> Void
    init(completed: @escaping @Sendable (Bool) -> Void) { self.completed = completed }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { completed(flag) }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { completed(false) }
}
