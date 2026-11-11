import Foundation
import Shared

/// Bounded local evidence comparison. App presence means possible, never active.
/// One owned poll/read/handler chain is cancelled and joined on stop or restart.
public actor MeetingDetector: MeetingDetectorProtocol {
    struct Environment: Sendable {
        let sample: @Sendable (Set<String>, Bool, MeetingApplicationIdentity?) async -> MeetingSample
        let reset: @Sendable () async -> Void
        let sleep: @Sendable () async throws -> Void
        let date: @Sendable () -> Date
        let uptime: @Sendable () -> TimeInterval

        static func live(captureConfig: (@Sendable () async -> MeetingCapturePolicySnapshot?)?) -> Self {
            let native = MeetingNativeObservationSource(captureConfig: captureConfig)
            return Self(sample: { await native.sample(bundleIDs: $0, comparisonEnabled: $1, previous: $2) },
                reset: { await native.reset() },
                sleep: { try await Task.sleep(for: .seconds(2), clock: .continuous) },
                date: { Date() }, uptime: { ProcessInfo.processInfo.systemUptime })
        }
    }

    private let environment: Environment
    private nonisolated let cache: MeetingStateCache
    private var reducer = MeetingAssessmentReducer(sessionID: UUID())
    private var currentMeetingState: MeetingState = .notInMeeting
    private var bundleIDs = Set<String>()
    private var comparisonEnabled = false
    private var monitoring = false
    private var generation = UUID()
    private var pollTask: Task<Void, Never>?
    private var lifecycleTail: Task<Void, Never>?
    private var lifecycleID = UUID()
    private var speech: MeetingObservation?
    private var legacyCallback: (@Sendable (MeetingState) -> Void)?
    private var ownedCallback: (@Sendable (MeetingState) async -> Void)?
    private var outcomeCallback: (@Sendable (MeetingDetectionOutcome) async -> Void)?

    public init(captureConfig: (@Sendable () async -> MeetingCapturePolicySnapshot?)? = nil) {
        environment = .live(captureConfig: captureConfig)
        cache = MeetingStateCache(uptime: { ProcessInfo.processInfo.systemUptime })
    }

    init(environment: Environment) {
        self.environment = environment
        cache = MeetingStateCache(uptime: environment.uptime)
    }

    public nonisolated func isMeetingActive() -> Bool { cache.isActive }
    public nonisolated func getActiveMeetingApp() -> String? { cache.activeApplication }

    public func startMonitoring(bundleIDs: Set<String>) async {
        await serialize { detector in await detector.startOwned(bundleIDs: bundleIDs) }
    }

    public func stopMonitoring() async {
        await serialize { detector in await detector.stopOwned() }
    }

    /// Independent comparison flag; does not grant audio consent or AX access.
    public func setComparisonEnabled(_ enabled: Bool) async {
        await serialize { detector in await detector.changeComparisonOwned(enabled) }
    }

    /// Compatibility callback. New consumers use the awaited callback below.
    public func onStateChange(_ callback: @escaping @Sendable (MeetingState) -> Void) { legacyCallback = callback }

    /// The owner must not synchronously stop this detector from its own callback;
    /// enqueue that lifecycle request after delivery, as with capture streams.
    public func onStateChangeAsync(_ callback: @escaping @Sendable (MeetingState) async -> Void) { ownedCallback = callback }

    /// Delivery is part of the owned poll chain and joined on stop/reconfigure.
    /// As with onStateChangeAsync, the handler must not await its own lifecycle stop.
    public func setOutcomeHandler(_ callback: (@Sendable (MeetingDetectionOutcome) async -> Void)?) { outcomeCallback = callback }

    func comparisonIsEnabled() -> Bool { comparisonEnabled }

    /// Called only for speech already produced under the existing recording
    /// settings. It starts no audio source and does not assign global speech to
    /// an application. Arrival must not refresh the original occurrence time.
    public func observeSpeech(_ observation: MeetingObservation) {
        guard monitoring, MeetingObservationAdmission.validSpeech(observation, now: environment.uptime(), date: environment.date()),
              observation.id != speech?.id,
              observation.audioOccurrence!.endedAt >= (speech?.audioOccurrence?.endedAt ?? .distantPast) else { return }
        speech = observation
    }

    public func getCurrentState() -> MeetingState {
        if let assessment = currentMeetingState.assessment, !assessment.isFresh(at: environment.uptime()) {
            let expired = reducer.expired(at: environment.date(), uptime: environment.uptime())
            currentMeetingState = MeetingState(assessment: expired)
            cache.set(currentMeetingState)
        }
        return currentMeetingState
    }

    private func serialize(_ operation: @escaping @Sendable (MeetingDetector) async -> Void) async {
        let predecessor = lifecycleTail
        let id = UUID()
        let task = Task { [self] in
            await predecessor?.value
            await operation(self)
        }
        lifecycleID = id; lifecycleTail = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if lifecycleID == id { lifecycleTail = nil }
    }

    private func startOwned(bundleIDs: Set<String>) async {
        guard !Task.isCancelled else { return }
        if monitoring, self.bundleIDs == bundleIDs { return }
        await stopOwned()
        guard !Task.isCancelled else { return }
        generation = UUID(); let token = generation
        self.bundleIDs = bundleIDs
        reducer = MeetingAssessmentReducer(sessionID: token)
        speech = nil; monitoring = true
        await publish(reducer.expired(at: environment.date(), uptime: environment.uptime(), reason: .noCorroboration))
        guard !Task.isCancelled else { await stopOwned(); return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.poll(token: token)
        }
    }

    private func stopOwned() async {
        guard monitoring || pollTask != nil else { return }
        monitoring = false; generation = UUID()
        let task = pollTask; pollTask = nil
        task?.cancel()
        await task?.value
        await environment.reset()
        speech = nil
        await publish(reducer.expired(at: environment.date(), uptime: environment.uptime(), reason: .stopped))
    }

    private func changeComparisonOwned(_ enabled: Bool) async {
        guard !Task.isCancelled, comparisonEnabled != enabled else { return }
        let wasMonitoring = monitoring, savedBundleIDs = bundleIDs
        await stopOwned()
        comparisonEnabled = enabled
        if wasMonitoring, !Task.isCancelled { await startOwned(bundleIDs: savedBundleIDs) }
    }

    private func poll(token: UUID) async {
        while monitoring, generation == token, !Task.isCancelled {
            let started = environment.uptime()
            let sample = await environment.sample(bundleIDs, comparisonEnabled, reducer.terminationTarget)
            guard monitoring, generation == token, !Task.isCancelled else { return }
            let assessment = reducer.consume(sample, comparisonEnabled: comparisonEnabled, speech: speech)
            let elapsed = (environment.uptime() - started) * 1_000
            let boundedElapsed = elapsed.isFinite && elapsed >= 0 ? elapsed : 0
            await publish(assessment, candidateCount: sample.candidateCount, controlsVisited: sample.controlsVisited,
                          elapsedMilliseconds: boundedElapsed)
            guard monitoring, generation == token, !Task.isCancelled else { return }
            Log.recordLatency("capture.meeting_evidence", valueMs: boundedElapsed, category: .capture)
            do { try await environment.sleep() } catch { return }
        }
    }

    private func publish(_ assessment: MeetingAssessment, candidateCount: Int = 0, controlsVisited: Int = 0,
                         elapsedMilliseconds: Double = 0) async {
        let previous = currentMeetingState
        let state = MeetingState(assessment: assessment)
        currentMeetingState = state; cache.set(state)
        // Await every freshness update so the audio privacy gate never relies
        // on an unowned task from an earlier monitoring generation.
        await ownedCallback?(state)
        await outcomeCallback?(MeetingDetectionOutcome(phase: assessment.phase, comparisonEnabled: comparisonEnabled,
            uncertainties: assessment.uncertainties, candidateCount: min(16, max(0, candidateCount)),
            controlsVisited: min(128, max(0, controlsVisited)), elapsedMilliseconds: elapsedMilliseconds))
        if previous.assessment?.phase != assessment.phase || previous.detectedApp != state.detectedApp ||
            previous.assessment?.uncertainties != assessment.uncertainties { legacyCallback?(state) }
    }
}

private final class MeetingStateCache: @unchecked Sendable {
    private let lock = NSLock()
    private let uptime: @Sendable () -> TimeInterval
    private var stored: MeetingState = .notInMeeting
    init(uptime: @escaping @Sendable () -> TimeInterval) { self.uptime = uptime }
    var value: MeetingState { lock.withLock { stored } }
    var isActive: Bool {
        let state = value
        return state.isInMeeting && (state.assessment?.isFresh(at: uptime()) ?? false)
    }
    var activeApplication: String? {
        let state = value
        return state.isInMeeting && (state.assessment?.isFresh(at: uptime()) ?? false) ? state.detectedApp : nil
    }
    func set(_ state: MeetingState) { lock.withLock { stored = state } }
}
