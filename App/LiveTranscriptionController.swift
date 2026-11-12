import Foundation
import Processing
import Shared

/// Capture offers packets synchronously; recognition can never delay the durable writer.
public final class LiveTranscriptionInput: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<CapturedAudio>.Continuation?
    private var dropped = false
    public func offer(_ audio: CapturedAudio) {
        guard audio.source == .microphone else { return }
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return }
        guard let identity = audio.sampleIdentity, identity.isValid,
              audio.audioData.count <= 32_000, audio.audioData.count == identity.sampleCount * 2 else {
            dropped = true; self.continuation = nil; continuation.finish(); return
        }
        if case .dropped = continuation.yield(audio) {
            dropped = true; self.continuation = nil; continuation.finish()
        }
    }
    func install() -> AsyncStream<CapturedAudio> {
        lock.lock(); defer { lock.unlock() }
        continuation?.finish(); dropped = false
        let pair = AsyncStream<CapturedAudio>.makeStream(bufferingPolicy: .bufferingOldest(32))
        continuation = pair.continuation
        return pair.stream
    }
    func stop() { lock.lock(); defer { lock.unlock() }; continuation?.finish(); continuation = nil }
    var didDrop: Bool { lock.lock(); defer { lock.unlock() }; return dropped }
}

/// Explicitly enabled candidate. Preview text cannot trigger markers or replace canonical Whisper text.
public actor LiveTranscriptionController {
    public nonisolated let input = LiveTranscriptionInput()
    private let makeRecognizer: @Sendable () throws -> any VoiceRecognitionProtocol
    private let underPressure: @Sendable () async -> Bool
    private let changed: @Sendable () -> Void
    private var value = LiveTranscriptionSnapshot()
    private var recording = false
    private var terminal = false
    private var revision = UUID()
    private var active: (id: UUID, task: Task<Void, Never>)?
    private var retiring: [UUID: Task<Void, Never>] = [:]
    private var timer: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var retryAfter = ContinuousClock.now

    public init(underPressure: @escaping @Sendable () async -> Bool = { false },
                changed: @escaping @Sendable () -> Void = {
                    NotificationCenter.default.post(name: .retraceLiveDraftChanged, object: nil)
                }, makeRecognizer: @escaping @Sendable () throws -> any VoiceRecognitionProtocol = {
                    if #available(macOS 26.0, *) { return NativeStreamingSpeechService() }
                    throw VoiceRecognitionError.unavailable
                }) {
        self.underPressure = underPressure; self.changed = changed; self.makeRecognizer = makeRecognizer
    }
    public func snapshot() -> LiveTranscriptionSnapshot {
        var current = value
        let now = Date()
        current.spans.removeAll {
            let end = $0.source.approximateOrigin.addingTimeInterval(Double($0.endSample) / 16_000)
            return now.timeIntervalSince(end) > 30
        }
        return current
    }
    public func setEnabled(_ enabled: Bool) async {
        guard !terminal else { return }
        value.enabled = enabled; revision = UUID(); retryAfter = .now
        ensureTimer()
        await reconcile(revision)
    }
    public func setRecording(_ recording: Bool) async {
        guard !terminal else { return }
        self.recording = recording; revision = UUID()
        ensureTimer()
        await reconcile(revision)
    }
    private func ensureTimer() {
        if recording && value.enabled && timer == nil {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                    await self?.checkConditions()
                }
            }
        }
    }
    public func close() async {
        if let closing { await closing.value; return }
        terminal = true; revision = UUID(); input.stop(); timer?.cancel()
        let tick = timer
        let drain = Task {
            await self.retire(); await tick?.value
            self.timer = nil; self.value.spans = []; self.value.state = .stopped; self.changed()
        }
        closing = drain; await drain.value
    }
    private func retire() async {
        input.stop()
        if let old = active { active = nil; retiring[old.id] = old.task; old.task.cancel() }
        let pending = retiring
        for task in pending.values { await task.value }
        for id in pending.keys { retiring[id] = nil }
    }
    private func reconcile(_ token: UUID) async {
        await retire()
        guard token == revision, !terminal else { return }
        value.spans = []; value.firstUpdateMilliseconds = nil
        guard value.enabled else { value.state = .disabled; changed(); return }
        guard recording else { value.state = .waitingForMicrophone; changed(); return }
        let pressured = await underPressure()
        guard token == revision, !terminal else { return }
        guard !pressured else { value.state = .resourcePressure; changed(); return }
        do {
            let recognizer = try makeRecognizer(), id = UUID(), stream = input.install()
            value.state = .preparing; changed()
            let task = Task { [weak self] in
                do {
                    try await recognizer.run(input: stream) { [weak self] event in
                        guard let self else { throw CancellationError() }
                        try await self.receive(event, id: id)
                    }
                    await self?.finished(id: id, error: nil)
                } catch { await self?.finished(id: id, error: error) }
            }
            active = (id, task)
        } catch { value.state = .unavailable; retryAfter = .now.advanced(by: .seconds(30)); changed() }
    }
    private func checkConditions() async {
        guard !terminal, value.enabled, recording else { return }
        let token = revision, pressure = await underPressure()
        guard token == revision, !terminal else { return }
        if pressure && active != nil {
            revision = UUID(); let next = revision
            await retire()
            guard next == revision, !terminal else { return }
            value.spans = []; value.state = .resourcePressure; changed()
        } else if !pressure, active == nil, ContinuousClock.now >= retryAfter { await reconcile(revision) }
    }
    private func receive(_ event: VoiceRecognitionEvent, id: UUID) throws {
        try Task.checkCancellation()
        guard !terminal, active?.id == id, !input.didDrop else { throw CancellationError() }
        switch event {
        case .ready: value.state = .listening
        case .discontinuity: throw VoiceRecognitionError.discontinuity
        case .finalized: return // Native finality is not canonical saved-transcript acceptance.
        case .update(let update):
            guard update.source.isValid, update.startSample >= 0, update.endSample > update.startSample,
                  update.text.utf8.count <= 8_192 else { throw VoiceRecognitionError.invalidInput }
            if let previous = value.spans.first {
                guard previous.source.recordingGeneration == update.source.recordingGeneration,
                      previous.source.continuityID == update.source.continuityID,
                      previous.source.approximateOrigin == update.source.approximateOrigin else {
                    throw VoiceRecognitionError.discontinuity
                }
            }
            // A revised native range replaces overlapping preview ranges. No text concatenation dedup heuristics.
            value.spans.removeAll { $0.startSample < update.endSample && update.startSample < $0.endSample }
            if !update.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value.spans.append(update) }
            value.spans.sort { $0.startSample < $1.startSample }
            value.spans = Array(value.spans.suffix(16))
            if value.firstUpdateMilliseconds == nil {
                let end = update.source.approximateOrigin.addingTimeInterval(Double(update.endSample) / 16_000)
                value.firstUpdateMilliseconds = max(0, Date().timeIntervalSince(end) * 1_000)
            }
        }
        changed()
    }
    private func finished(id: UUID, error: Error?) {
        guard active?.id == id else { return }
        active = nil; input.stop(); value.spans = []
        value.state = (error as? VoiceRecognitionError) == .missingAssets ? .missingAssets : .interrupted
        retryAfter = .now.advanced(by: .seconds(30)); changed()
    }
}
