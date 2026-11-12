import Foundation
import AppKit
import Shared
import Processing

/// Bounded, nonblocking secondary microphone subscription. Capture persistence
/// never awaits recognition, database writes or a model. Overflow ends recognition
/// coverage instead of silently joining nonadjacent PCM.
public final class VoiceMarkerInput: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<CapturedAudio>.Continuation?
    private var generation: UUID?
    private var failure: VoiceMarkerState?
    private var playbackRevision: UInt64?
    private let playback: RetracePlaybackGate
    init(playback: RetracePlaybackGate) { self.playback = playback }

    public func offer(_ audio: CapturedAudio) {
        guard audio.source == .microphone else { return }
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return }
        let current = playback.admission
        guard !current.suppressed, playbackRevision == current.revision,
              let captured = audio.voiceMarkerPlaybackAdmission, !captured.suppressed,
              captured.revision == current.revision else {
            failure = .playbackSuppressed; self.continuation = nil; continuation.finish(); return
        }
        guard let identity = audio.sampleIdentity, identity.isValid,
              audio.audioData.count <= 32_000, audio.audioData.count == identity.sampleCount * 2 else {
            failure = .droppedInput; self.continuation = nil; continuation.finish(); return
        }
        if case .dropped = continuation.yield(audio) {
            failure = .droppedInput; self.continuation = nil; continuation.finish()
        }
    }
    func install(id: UUID) -> AsyncStream<CapturedAudio> {
        lock.lock(); defer { lock.unlock() }
        continuation?.finish()
        let pair = AsyncStream<CapturedAudio>.makeStream(bufferingPolicy: .bufferingOldest(256))
        continuation = pair.continuation; generation = id; failure = nil
        playbackRevision = playback.admission.revision
        return pair.stream
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        generation = nil; continuation?.finish(); continuation = nil
    }
    func state(for id: UUID) -> VoiceMarkerState? {
        lock.lock(); defer { lock.unlock() }
        guard generation == id else { return .stopped }
        if playbackRevision != playback.admission.revision { return .playbackSuppressed }
        return failure
    }
}

/// App owner for rule activation, native task lifetime, durable acknowledgement and
/// controlled retries. No speaker inference or semantic action can trigger rules.
public actor VoiceMarkerController {
    public nonisolated let input: VoiceMarkerInput
    private let markers: TimelineMarkerService
    private let nativeStoreID: @Sendable () async throws -> UUID
    private let makeRecognizer: @Sendable () throws -> any VoiceRecognitionProtocol
    private let underPressure: @Sendable () async -> Bool
    private let playback: RetracePlaybackGate
    private var rules: [KeywordRule] = []
    private var recording = false
    private var terminal = false
    private var started = false
    private var revision = UUID()
    private var active: (id: UUID, task: Task<Void, Never>)?
    private var retiring: [UUID: Task<Void, Never>] = [:]
    private var closing: Task<Void, Never>?
    private var ruleTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var chime: Task<Void, Never>?
    private var assetPreparation: Task<Void, Error>?
    private var ruleSignal: AsyncStream<Void>.Continuation?
    private var state = VoiceMarkerStatus()
    private var matcher = VoicePhraseMatcher(rules: [])
    private var observationRevisions: [UUID: UUID] = [:]
    private var storeID: UUID?
    private var retryAfter = ContinuousClock.now

    public init(markers: TimelineMarkerService, nativeStoreID: @escaping @Sendable () async throws -> UUID,
                playback: RetracePlaybackGate = .shared,
                underPressure: @escaping @Sendable () async -> Bool = { false },
                makeRecognizer: @escaping @Sendable () throws -> any VoiceRecognitionProtocol = {
                    if #available(macOS 26.0, *) { return NativeStreamingSpeechService() }
                    throw VoiceRecognitionError.unavailable
                }) {
        self.markers = markers; self.nativeStoreID = nativeStoreID; self.playback = playback
        self.underPressure = underPressure; self.makeRecognizer = makeRecognizer
        input = VoiceMarkerInput(playback: playback)
    }

    public func start() async {
        guard !started, !terminal else { return }
        started = true
        let (changes, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        ruleSignal = signal
        let input = self.input
        await markers.setRulesChangedHandler { input.stop(); signal.yield(()) }
        ruleTask = Task { [weak self] in
            for await _ in changes { guard !Task.isCancelled else { break }; await self?.reloadRules() }
        }
        await reloadRules()
    }

    public func setRecording(_ enabled: Bool) async {
        guard !terminal else { return }
        recording = enabled; revision = UUID()
        let token = revision
        if enabled && timer == nil {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                    await self?.checkConditions()
                }
            }
        }
        // Once created, the cheap condition timer remains owned across pauses.
        // checkConditions is inert while paused or disabled; terminal close joins
        // it. A stale pause can therefore never remove a newer recording's timer.
        await reconcile(token)
    }

    public func status() -> VoiceMarkerStatus { state }
    public func markMediaMappingIncomplete() { state.mediaMappingIncomplete = true }

    public func prepareAssets() async throws {
        guard !terminal else { throw ContextStoreError.closed }
        if let task = assetPreparation { try await task.value; return }
        guard #available(macOS 26.0, *) else { throw VoiceRecognitionError.unavailable }
        let task = Task { try await NativeStreamingSpeechService.prepareAssets() }
        assetPreparation = task
        do {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            assetPreparation = nil
            guard !terminal else { throw ContextStoreError.closed }
            try Task.checkCancellation()
            await reloadRules()
        } catch { assetPreparation = nil; throw error }
    }

    public func close() async {
        if let closing { await closing.value; return }
        terminal = true; recording = false; revision = UUID(); input.stop()
        ruleSignal?.finish(); ruleSignal = nil
        ruleTask?.cancel(); timer?.cancel(); chime?.cancel(); assetPreparation?.cancel()
        let rules = ruleTask, tick = timer, sound = chime, assets = assetPreparation
        let drain = Task {
            await self.retireAndJoinRecognition()
            await rules?.value; await tick?.value; await sound?.value
            if let assets { _ = await assets.result }
            self.assetPreparation = nil
            self.ruleTask = nil; self.timer = nil; self.chime = nil; self.state.state = .stopped
        }
        closing = drain
        await drain.value
    }

    private func retireAndJoinRecognition() async {
        if let old = active {
            active = nil; retiring[old.id] = old.task; old.task.cancel()
        }
        let pending = retiring
        for task in pending.values { await task.value }
        for id in pending.keys { retiring[id] = nil }
    }

    private func reloadRules() async {
        guard !terminal else { return }
        revision = UUID()
        let token = revision
        input.stop()
        await retireAndJoinRecognition()
        guard revision == token, !terminal else { if !terminal { ruleSignal?.yield(()) }; return }
        do {
            var loaded: [KeywordRule] = []
            var after: UUID?
            repeat {
                let page = try await markers.listKeywordRules(afterID: after, limit: 100)
                loaded += page
                guard loaded.count <= 128 else { throw ContextStoreError.capacityExceeded }
                if page.count < 100 { break }
                after = page.last?.id
            } while true
            let id = try await nativeStoreID()
            guard revision == token, !terminal else { if !terminal { ruleSignal?.yield(()) }; return }
            rules = loaded.filter(\.enabled); storeID = id
            state.enabledRuleCount = rules.count
            matcher = VoicePhraseMatcher(rules: rules); observationRevisions = [:]
            retryAfter = .now
            await reconcile(token)
        } catch {
            guard revision == token, !terminal else { return }
            state.state = .writeFailed
        }
    }

    private func checkConditions() async {
        guard !terminal, recording, !rules.isEmpty else { return }
        let observed = revision
        let pressure = await underPressure()
        guard observed == revision, !terminal, recording else { return }
        if pressure || playback.isSuppressed {
            revision = UUID(); input.stop()
            let token = revision
            await retireAndJoinRecognition()
            guard token == revision, !terminal else { return }
            state.state = pressure ? .resourcePressure : .playbackSuppressed
        } else if active == nil, ContinuousClock.now >= retryAfter {
            await reconcile(revision)
        }
    }

    private func reconcile(_ expected: UUID) async {
        input.stop()
        await retireAndJoinRecognition()
        guard expected == revision, !terminal else { return }
        guard !rules.isEmpty else { state.state = .disabled; return }
        guard recording else { state.state = .waitingForMicrophone; return }
        guard !playback.isSuppressed else { state.state = .playbackSuppressed; return }
        guard !(await underPressure()) else { state.state = .resourcePressure; return }
        guard expected == revision, !terminal else { return }
        do {
            let recognizer = try makeRecognizer()
            let id = UUID()
            // A recognizer restart is a new coverage interval even if capture
            // itself remained continuous (playback, resource deferral or loss).
            matcher = VoicePhraseMatcher(rules: rules)
            observationRevisions = [:]
            let stream = input.install(id: id)
            state.state = .preparing
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
        } catch { state.state = .unavailable; retryAfter = .now.advanced(by: .seconds(30)) }
    }

    private func receive(_ event: VoiceRecognitionEvent, id: UUID) async throws {
        try Task.checkCancellation()
        guard !terminal, active?.id == id, input.state(for: id) == nil, !playback.isSuppressed else {
            throw CancellationError()
        }
        let changes: [VoicePhraseChange]
        switch event {
        case .ready: state.state = .listening; return
        case .discontinuity: throw VoiceRecognitionError.discontinuity
        case .update(let update): changes = try matcher.receive(update)
        case .finalized(let generation, let continuity, let through):
            changes = matcher.finalize(recordingGeneration: generation, continuityID: continuity, throughSample: through)
        }
        observationRevisions = observationRevisions.filter { matcher.retainedOccurrenceIDs.contains($0.key) }
        guard let storeID else { throw ContextStoreError.notInitialized }
        for change in changes {
            try Task.checkCancellation()
            guard active?.id == id, !playback.isSuppressed else { throw CancellationError() }
            let anchor = SpokenMarkerAnchor(nativeStoreID: storeID,
                recordingGeneration: change.source.recordingGeneration, continuityID: change.source.continuityID,
                startSample: change.startSample, endSample: change.endSample,
                approximateOrigin: change.source.approximateOrigin, timingPrecision: change.precision)
            let previous = observationRevisions[change.occurrenceID]
            let command = SpokenObservationCommand(occurrenceID: change.occurrenceID, expectedRevision: previous,
                status: change.status, anchor: anchor, ruleSnapshot: change.rule,
                matchedPhrase: change.matchedPhrase, explanation: change.explanation)
            let receipt: SpokenMarkerReceipt
            do { receipt = try await markers.applySpokenObservation(command) }
            catch { state.state = .writeFailed; retryAfter = .now.advanced(by: .seconds(30)); throw error }
            observationRevisions[change.occurrenceID] = receipt.observation.revision
            guard active?.id == id, !terminal, !receipt.suppressed,
                  receipt.observation.status != .withdrawn else { continue }
            // Notification follows successful commit AND current-state reread.
            if previous == nil {
                state.lastMarkerID = receipt.marker.id; state.lastAcknowledgedAt = Date()
                state.lastAcknowledgementMilliseconds = max(0, Date().timeIntervalSince(
                    anchor.approximateOrigin.addingTimeInterval(Double(anchor.endSample) / 16_000)) * 1_000)
                state.acknowledgedProvisional = receipt.observation.status == .provisional
                playAcknowledgementIfEnabled()
            } else if state.lastMarkerID == receipt.marker.id {
                state.acknowledgedProvisional = receipt.observation.status == .provisional
            }
        }
    }

    private func playAcknowledgementIfEnabled() {
        let preferences = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        guard preferences.bool(forKey: "voiceMarkersAcknowledgementSoundEnabled") else { return }
        chime?.cancel()
        let playback = self.playback
        let lease = playback.acquire()
        chime = Task {
            await MainActor.run { _ = NSSound(named: NSSound.Name("Pop"))?.play() }
            try? await Task.sleep(for: .seconds(1))
            playback.release(lease)
        }
    }

    private func finished(id: UUID, error: Error?) {
        guard active?.id == id, !terminal else { return }
        let inputFailure = input.state(for: id)
        active = nil; input.stop()
        if let inputFailure { state.state = inputFailure }
        else if let error = error as? VoiceRecognitionError {
            switch error {
            case .missingAssets: state.state = .missingAssets
            case .droppedInput, .discontinuity, .invalidInput: state.state = .droppedInput
            default: state.state = .unavailable
            }
        } else if state.state != .writeFailed { state.state = error == nil ? .waitingForMicrophone : .unavailable }
        retryAfter = .now.advanced(by: state.state == .missingAssets || state.state == .writeFailed ? .seconds(30) : .seconds(2))
    }
}
