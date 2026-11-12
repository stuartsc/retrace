import Foundation
import Processing
import Shared

/// Capture offers packets synchronously; recognition can never delay the durable writer.
public final class LiveTranscriptionInput: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<CapturedAudio>.Continuation?
    private var dropped = false
    private var packetSerial: UInt64 = 0
    private var packetTime: ContinuousClock.Instant?
    var packetActivity: (serial: UInt64, time: ContinuousClock.Instant?) {
        lock.lock(); defer { lock.unlock() }; return (packetSerial, packetTime)
    }
    public func offer(_ audio: CapturedAudio) {
        guard audio.source == .microphone else { return }
        lock.lock(); defer { lock.unlock() }
        guard let identity = audio.sampleIdentity, identity.isValid,
              audio.audioData.count <= 32_000, audio.audioData.count == identity.sampleCount * 2 else {
            dropped = true; let old = continuation; self.continuation = nil; old?.finish(); return
        }
        packetSerial &+= 1; packetTime = .now
        guard let continuation else { return }
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

/// Explicit preview candidate; separately gated exact native reuse can prepare saved text for idle CPU correction.
public actor LiveTranscriptionController {
    public nonisolated let input = LiveTranscriptionInput()
    private let makeRecognizer: @Sendable () throws -> any VoiceRecognitionProtocol
    private let underPressure: @Sendable () async -> Bool
    private let changed: @Sendable () -> Void
    private let sourceIdleTimeout: Duration
    private var value = LiveTranscriptionSnapshot()
    private var recording = false
    private var terminal = false
    private var revision = UUID()
    private var active: (id: UUID, task: Task<Void, Never>, recognizer: any VoiceRecognitionProtocol, started: ContinuousClock.Instant)?
    private var awaitingPacketAfter: UInt64?
    private var nativeFirstPassEnabled = false
    private var coverage = NativeFirstPassCoverage()
    private var retiring: [UUID: Task<Void, Never>] = [:]
    private var timer: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var retryAfter = ContinuousClock.now

    public init(underPressure: @escaping @Sendable () async -> Bool = { false },
                sourceIdleTimeout: Duration = .seconds(5),
                changed: @escaping @Sendable () -> Void = {
                    NotificationCenter.default.post(name: .retraceLiveDraftChanged, object: nil)
                }, makeRecognizer: @escaping @Sendable () throws -> any VoiceRecognitionProtocol = {
                    if #available(macOS 26.0, *) { return NativeStreamingSpeechService() }
                    throw VoiceRecognitionError.unavailable
                }) {
        self.underPressure = underPressure; self.changed = changed; self.makeRecognizer = makeRecognizer
        self.sourceIdleTimeout = max(.milliseconds(20), sourceIdleTimeout)
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
    /// Separate promotion gate, off until native accuracy/asset acceptance.
    public func setNativeFirstPassEnabled(_ enabled: Bool) {
        nativeFirstPassEnabled = enabled
        coverage.reset()
        value.nativeFirstPassEnabled = enabled
        changed()
    }

    /// Invoked by the durable first-pass worker, never the capture/write callback.
    /// Missing, late, partial or stopped coverage returns nil for CPU fallback.
    public func firstPass(for batch: NativeFirstPassBatch) async throws -> NativeFirstPassText? {
        try Task.checkCancellation()
        guard nativeFirstPassEnabled, value.enabled, recording, !terminal,
              value.state == .listening, let active else { return nil }
        if let result = coverage.result(for: batch) { return result }
        do { try await active.recognizer.requestFinalization(source: batch.range.source,
            throughSample: batch.range.source.startSample + batch.frameCount) }
        catch { try Task.checkCancellation(); return nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard self.active?.id == active.id, nativeFirstPassEnabled, !terminal, !input.didDrop else { return nil }
            if let result = coverage.result(for: batch) { return result }
            try await Task.sleep(for: .milliseconds(20))
        }
        return nil
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
        coverage.reset()
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
            awaitingPacketAfter = nil
            active = (id, task, recognizer, .now)
        } catch { value.state = .unavailable; retryAfter = .now.advanced(by: .seconds(30)); changed() }
    }
    func checkConditions() async {
        guard !terminal, value.enabled, recording else { return }
        let activity = input.packetActivity
        if let active, ContinuousClock.now - max(active.started, activity.time ?? active.started) > sourceIdleTimeout {
            revision = UUID(); let next = revision
            awaitingPacketAfter = activity.serial
            await retire()
            guard next == revision, !terminal else { return }
            value.spans = []; value.state = .waitingForMicrophone; changed()
            return
        }
        if let previous = awaitingPacketAfter, previous == activity.serial { return }
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
        if nativeFirstPassEnabled { try coverage.receive(event) }
        switch event {
        case .ready: value.state = .listening
        case .discontinuity: throw VoiceRecognitionError.discontinuity
        case .finalized: return // Saved publication also requires exact persisted source/media proof.
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
        active = nil; input.stop(); value.spans = []; coverage.reset()
        value.state = (error as? VoiceRecognitionError) == .missingAssets ? .missingAssets : .interrupted
        retryAfter = .now.advanced(by: .seconds(30)); changed()
    }
}
