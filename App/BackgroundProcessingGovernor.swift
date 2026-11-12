import Foundation
import CoreGraphics
import Darwin
import Shared

public struct BackgroundProcessingEnvironment: Sendable {
    public let idleSeconds: TimeInterval
    public let lowPowerMode: Bool
    public let pressureAllowsProcessing: Bool
    public let systemAllowsProcessing: Bool
    public let resourceUsage: ResourceUsageSnapshot?
    public init(idleSeconds: TimeInterval, lowPowerMode: Bool = false,
                pressureAllowsProcessing: Bool = true, systemAllowsProcessing: Bool = true,
                resourceUsage: ResourceUsageSnapshot? = nil) {
        self.idleSeconds = idleSeconds
        self.lowPowerMode = lowPowerMode
        self.pressureAllowsProcessing = pressureAllowsProcessing
        self.systemAllowsProcessing = systemAllowsProcessing
        self.resourceUsage = resourceUsage
    }
}

public struct BackgroundProcessingSnapshot: Sendable {
    public let waitingCount: Int
    public let isRunning: Bool
    public let processNow: Bool
    public let isWaitingForQuietMoment: Bool
    public let isClosed: Bool
    public let originalSpoolUnderPressure: Bool
    public let activeKind: BackgroundProcessingKind?
    public let waitReason: BackgroundProcessingWaitReason?
    public let resourceUsage: ResourceUsageSnapshot
}

public enum BackgroundProcessingAdmissionError: Error { case queueFull, closeIncomplete }

/// Owned native scheduling boundary; tests can supply a consumable grant without
/// waiting for macOS to decide when to run an activity.
protocol BackgroundActivityScheduling: Sendable {
    var allowsProcessing: Bool { get }
    func start()
    func finish(deferred: Bool)
    func invalidate()
}

/// One owner for automatic expensive work. Initialization starts no observers or tasks.
/// Durable queues remain in their source owners; this queue holds at most 64 suspended callers.
public actor BackgroundProcessingGovernor: BackgroundProcessingProtocol {
    private struct Waiter {
        let id: UUID
        let kind: BackgroundProcessingKind
        let explicitRequest: Bool
        let continuation: CheckedContinuation<BackgroundProcessingPermit, Error>
        let cancellation: BackgroundProcessingCancellation
    }
    private let observeSystem: Bool
    private let resourceUsage: (any ResourceUsageProviding)?
    private var resourcePolicy = ResourceProcessingPolicy()
    private var fallbackResources = ResourceUsageSeries()
    private var environment = BackgroundProcessingEnvironment(idleSeconds: 0)
    private var waiters: [Waiter] = []
    private var active: BackgroundProcessingPermit?
    private var activeKind: BackgroundProcessingKind?
    private var activeExplicitRequest = false
    private var processNow = false
    private var originalSpoolUnderPressure = false
    private var closed = false
    private var joinedClose = false
    private var closeCallers = 0
    private var consecutiveSpeech = 0
    private var consecutiveFreshOCR = 0
    private var consecutivePreferred = 0
    private var monitor: Task<Void, Never>?
    private let monitorQueue = DispatchQueue(label: "com.retrace.processing-monitor", qos: .background)
    private let monitorDelayInterval: DispatchTimeInterval
    private let monitorDelayCheckpoint: (@Sendable (BackgroundProcessingMonitorDelay.Checkpoint) -> Void)?
    private var scheduler: (any BackgroundActivityScheduling)?
    private var scheduledWindowStarted: TimeInterval?
    private var activeUsesScheduledWindow = false
    private var nextOverdueAdmission: TimeInterval = 0
    private var monotonicNow: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private static let scheduledWindowBudget: TimeInterval = 20
    private var memoryPressure: BackgroundMemoryPressureBridge?
    private var closing: [CheckedContinuation<Void, Never>] = []

    public init(observeSystem: Bool = true, resourceUsage: (any ResourceUsageProviding)? = nil) {
        self.observeSystem = observeSystem
        self.resourceUsage = resourceUsage
        monitorDelayInterval = .seconds(1)
        monitorDelayCheckpoint = nil
    }

    init(scheduler: any BackgroundActivityScheduling, monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        observeSystem = false; resourceUsage = nil
        monitorDelayInterval = .seconds(1)
        monitorDelayCheckpoint = nil
        self.scheduler = scheduler
        self.monotonicNow = monotonicNow
    }

    /// Internal fixture boundary: tests still run the actual native timer and
    /// observer lifecycle, with immutable checkpoints shared by all build modes.
    init(resourceUsage: any ResourceUsageProviding, monitorDelayInterval: DispatchTimeInterval,
         monitorDelayCheckpoint: (@Sendable (BackgroundProcessingMonitorDelay.Checkpoint) -> Void)? = nil) {
        observeSystem = true
        self.resourceUsage = resourceUsage
        self.monitorDelayInterval = monitorDelayInterval
        self.monitorDelayCheckpoint = monitorDelayCheckpoint
    }

    public func tryAcquire(_ kind: BackgroundProcessingKind) async throws -> BackgroundProcessingPermit? {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        await startObservationIfNeeded()
        if observeSystem { await refreshEnvironment() }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let explicitRequest = BackgroundProcessingContext.explicitRequest
        finishExpiredScheduledWindowIfIdle()
        guard active == nil, !waiters.contains(where: { mayProcess(kind: $0.kind, explicitRequest: $0.explicitRequest) }),
              mayProcess(kind: kind, explicitRequest: explicitRequest) else { return nil }
        let permit = BackgroundProcessingPermit(threadCount: threadCount(for: kind))
        active = permit
        activeKind = kind
        activeExplicitRequest = explicitRequest
        beginScheduledWindowIfNeeded(kind: kind, explicitRequest: explicitRequest)
        consecutiveSpeech = kind == .ambientSpeech || kind == .freshTranscription ? min(consecutiveSpeech + 1, 3) : 0
        consecutiveFreshOCR = kind == .freshOCR ? min(consecutiveFreshOCR + 1, 3) : 0
        consecutivePreferred = kind.isFresh || kind == .ambientSpeech ? min(consecutivePreferred + 1, 3) : 0
        return permit
    }

    public func acquire(_ kind: BackgroundProcessingKind) async throws -> BackgroundProcessingPermit {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard waiters.count < 64 else { throw BackgroundProcessingAdmissionError.queueFull }
        await startObservationIfNeeded()
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let id = UUID()
        let cancellation = BackgroundProcessingCancellation()
        let explicitRequest = BackgroundProcessingContext.explicitRequest
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !cancellation.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: id, kind: kind, explicitRequest: explicitRequest,
                                      continuation: continuation, cancellation: cancellation))
                if explicitRequest && !activeExplicitRequest { active?.cancellation.cancel() }
                if kind.isFresh, !activeExplicitRequest, activeKind?.isFresh != true,
                   mayProcess(kind: kind, explicitRequest: false) {
                    active?.cancellation.cancel()
                }
                admit()
            }
        } onCancel: {
            // Set the native flag immediately, even if actor delivery is delayed.
            cancellation.cancel()
            Task { await self.cancelWaiter(id) }
        }
    }

    public func release(_ permit: BackgroundProcessingPermit) async {
        guard active?.id == permit.id else { return }
        // Explicit/manual probes and fresh OCR never consume the native quiet-
        // time grant. Otherwise an empty manual lane could end every scheduler
        // window before the historical lane gets a chance to claim its work.
        let usedScheduledWindow = activeUsesScheduledWindow
        if activeKind == .overdueTranscription { nextOverdueAdmission = monotonicNow() + 30 }
        active = nil
        activeKind = nil
        activeExplicitRequest = false
        activeUsesScheduledWindow = false
        if usedScheduledWindow && permit.cancellation.isCancelled {
            finishScheduledWindow(deferred: true)
        } else {
            finishExpiredScheduledWindowIfIdle()
        }
        if closed {
            let continuations = closing
            closing.removeAll()
            continuations.forEach { $0.resume() }
        } else {
            if observeSystem { await refreshEnvironment() }
            admit()
        }
    }

    public func updateEnvironment(_ value: BackgroundProcessingEnvironment) {
        environment = value
        if let sample = value.resourceUsage { resourcePolicy.update(sample, idleSeconds: value.idleSeconds) }
        // An admitted, bounded fresh utterance may finish its own CPU burst. Killing
        // it for raising the app average would repeatedly redo the same audio.
        let finishingFreshBurst = activeKind?.isFresh == true && value.pressureAllowsProcessing &&
            resourcePolicy.reason == .cpuBudget
        let lostScheduledGrant = activeUsesScheduledWindow &&
            (!value.idleSeconds.isFinite || value.idleSeconds < 300 ||
             !value.systemAllowsProcessing || !(scheduler?.allowsProcessing ?? true))
        if lostScheduledGrant || (!finishingFreshBurst && !mayProcess(kind: activeKind, explicitRequest: activeExplicitRequest)) {
            active?.cancellation.cancel()
        }
        if active == nil && !mayProcess { finishScheduledWindow(deferred: true) }
        finishExpiredScheduledWindowIfIdle()
        admit()
    }

    public func setProcessNow(_ enabled: Bool) {
        guard !closed else { return }
        processNow = enabled
        if !enabled && !activeExplicitRequest && activeKind?.isFresh != true { active?.cancellation.cancel() }
        admit()
    }

    public func setProcessNowFromCommand(_ enabled: Bool) throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        setProcessNow(enabled)
    }

    public func snapshot() -> BackgroundProcessingSnapshot {
        .init(waitingCount: waiters.count, isRunning: active != nil, processNow: processNow,
              isWaitingForQuietMoment: !closed && !waiters.isEmpty &&
                !waiters.contains(where: { mayProcess(kind: $0.kind, explicitRequest: $0.explicitRequest) }), isClosed: closed,
              originalSpoolUnderPressure: originalSpoolUnderPressure, activeKind: activeKind,
              waitReason: waitReason, resourceUsage: environment.resourceUsage ?? .unavailable)
    }

    public func setOriginalSpoolPressure(_ underPressure: Bool) {
        originalSpoolUnderPressure = underPressure
        admit()
    }

    /// Terminal close joins the owned observer and all acquired native work. Source owners must
    /// cancel their worker tasks and release permits; a cancellation request is not completion.
    public func close() async {
        if joinedClose { return }
        closeCallers += 1
        cancelAutomaticWork()
        let task = monitor
        await task?.value
        monitor = nil
        await memoryPressure?.close()
        if active != nil {
            await withCheckedContinuation { closing.append($0) }
        }
        closeCallers -= 1
        if closeCallers == 0 { joinedClose = true }
    }

    /// Only the owning service lifecycle may use this after a fully joined startup rollback.
    /// Reopening discards system observations and starts no native observer or worker.
    public func reopenAfterJoinedClose() throws {
        guard closed else { return }
        guard joinedClose, closeCallers == 0, monitor == nil, active == nil, closing.isEmpty else {
            throw BackgroundProcessingAdmissionError.closeIncomplete
        }
        scheduler = nil
        scheduledWindowStarted = nil
        activeUsesScheduledWindow = false
        nextOverdueAdmission = 0
        memoryPressure = nil
        environment = .init(idleSeconds: 0)
        resourcePolicy = ResourceProcessingPolicy()
        fallbackResources = ResourceUsageSeries()
        consecutiveSpeech = 0
        consecutiveFreshOCR = 0
        consecutivePreferred = 0
        originalSpoolUnderPressure = false
        joinedClose = false
        closed = false
    }

    /// Terminal admission fence, called before source workers join. `close` subsequently joins
    /// the observer and native permits. This method alone does not establish shutdown completion.
    public func cancelAutomaticWork() {
        closed = true
        processNow = false
        active?.cancellation.cancel()
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume(throwing: CancellationError()) }
        monitor?.cancel()
        scheduler?.invalidate()
    }

    private var mayProcess: Bool {
        mayProcess(kind: nil, explicitRequest: false)
    }

    private func mayProcess(kind: BackgroundProcessingKind?, explicitRequest: Bool) -> Bool {
        guard !closed, environment.pressureAllowsProcessing else { return false }
        if processNow || explicitRequest { return true }
        // Recording itself can exceed the app-only soft target. First-pass text
        // must still progress; host load, unknown measurements and native pressure
        // continue to block it. Refinement and OCR retain the ordinary CPU policy.
        guard resourcePolicy.reason == nil ||
                (kind?.isFirstPass == true && resourcePolicy.reason == .cpuBudget) else { return false }
        if kind?.isFresh == true { return true }
        if kind == .overdueTranscription {
            if quietWindowAvailable { return true }
            // During active use an old or quiet first pass gets one bounded
            // single-thread job per thirty seconds, never an idle-only gate.
            return monotonicNow() >= nextOverdueAdmission
        }
        return environment.idleSeconds.isFinite && environment.idleSeconds >= 300 &&
            environment.systemAllowsProcessing && (scheduler?.allowsProcessing ?? true)
    }

    private var waitReason: BackgroundProcessingWaitReason? {
        if closed { return .closed }
        if !environment.pressureAllowsProcessing { return .resourcePressure }
        if processNow || activeExplicitRequest { return nil }
        if let reason = resourcePolicy.reason, reason != .cpuBudget { return reason }
        if !quietWindowAvailable && monotonicNow() < nextOverdueAdmission &&
            !waiters.contains(where: { $0.kind.isFresh }) &&
            waiters.contains(where: { $0.kind == .overdueTranscription }) { return .audioPacing }
        if let reason = resourcePolicy.reason {
            let progressingFirstPass = activeKind?.isFirstPass == true ||
                waiters.contains { $0.kind.isFirstPass }
            if reason != .cpuBudget || !progressingFirstPass { return reason }
        }
        if activeKind?.isFirstPass == true || activeKind?.isFresh == true || waiters.contains(where: { $0.kind.isFresh || $0.kind.isFirstPass }) { return nil }
        if !environment.idleSeconds.isFinite || environment.idleSeconds < 300 { return .activeUse }
        return environment.systemAllowsProcessing ? nil : .systemDeferral
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    private func threadCount(for kind: BackgroundProcessingKind) -> Int {
        if kind == .overdueTranscription { return 1 }
        if kind == .freshTranscription { return environment.lowPowerMode ? 1 : 2 }
        return environment.lowPowerMode ? 2 : 4
    }

    private var quietWindowAvailable: Bool {
        environment.idleSeconds.isFinite && environment.idleSeconds >= 300 &&
            environment.systemAllowsProcessing && (scheduler?.allowsProcessing ?? true)
    }

    private var scheduledWindowExpired: Bool {
        guard let started = scheduledWindowStarted else { return false }
        return monotonicNow() - started >= Self.scheduledWindowBudget
    }

    private func beginScheduledWindowIfNeeded(kind: BackgroundProcessingKind, explicitRequest: Bool) {
        activeUsesScheduledWindow = scheduler != nil && !kind.isFresh && !explicitRequest && !processNow && quietWindowAvailable
        if activeUsesScheduledWindow && scheduledWindowStarted == nil { scheduledWindowStarted = monotonicNow() }
    }

    private func finishScheduledWindow(deferred: Bool) {
        scheduledWindowStarted = nil
        scheduler?.finish(deferred: deferred)
    }

    private func finishExpiredScheduledWindowIfIdle() {
        // Do not repeatedly abort a bounded inference at the budget boundary.
        // Finish the current job, then refuse more admissions on this grant.
        if active == nil && scheduledWindowExpired { finishScheduledWindow(deferred: false) }
    }

    private func admit() {
        finishExpiredScheduledWindowIfIdle()
        guard active == nil, !closed, environment.pressureAllowsProcessing else { return }
        // Prioritize speech but force the oldest other work after at most three speech jobs.
        while !waiters.isEmpty {
            let index: Int
            if let explicit = waiters.firstIndex(where: { $0.explicitRequest }) {
                index = explicit
            } else if originalSpoolUnderPressure, mayProcess,
                      let extraction = waiters.firstIndex(where: { $0.kind == .historicalOCR }) {
                index = extraction
            } else if consecutivePreferred >= 3, let other = waiters.firstIndex(where: {
                !$0.kind.isFresh && $0.kind != .ambientSpeech &&
                    mayProcess(kind: $0.kind, explicitRequest: $0.explicitRequest)
            }) {
                // Alternating preferred kinds must not reset one another's
                // budget and starve historical OCR or other queued work.
                index = other
            } else if let fresh = waiters.firstIndex(where: {
                $0.kind == .freshTranscription && mayProcess(kind: $0.kind, explicitRequest: $0.explicitRequest)
            }), consecutiveSpeech < 3 || !waiters.contains(where: {
                $0.kind == .freshOCR && mayProcess(kind: $0.kind, explicitRequest: $0.explicitRequest)
            }) {
                index = fresh
            } else if let fresh = waiters.firstIndex(where: { $0.kind == .freshOCR && mayProcess(kind: .freshOCR, explicitRequest: false) }),
                      consecutiveFreshOCR < 3 || !waiters.contains(where: {
                          $0.kind != .freshOCR && mayProcess(kind: $0.kind, explicitRequest: $0.explicitRequest)
                      }) {
                index = fresh
            } else if let overdue = waiters.firstIndex(where: {
                $0.kind == .overdueTranscription && mayProcess(kind: $0.kind, explicitRequest: $0.explicitRequest)
            }) {
                index = overdue
            } else if !mayProcess {
                return
            } else if consecutiveSpeech >= 3, let other = waiters.firstIndex(where: { $0.kind != .ambientSpeech }) {
                index = other
            } else if consecutiveSpeech < 3, let speech = waiters.firstIndex(where: { $0.kind == .ambientSpeech }) {
                index = speech
            } else { index = 0 }
            let waiter = waiters.remove(at: index)
            guard !waiter.cancellation.isCancelled else {
                waiter.continuation.resume(throwing: CancellationError())
                continue
            }
            consecutiveSpeech = waiter.kind == .ambientSpeech || waiter.kind == .freshTranscription ? min(consecutiveSpeech + 1, 3) : 0
            consecutiveFreshOCR = waiter.kind == .freshOCR ? min(consecutiveFreshOCR + 1, 3) : 0
            consecutivePreferred = waiter.kind.isFresh || waiter.kind == .ambientSpeech
                ? min(consecutivePreferred + 1, 3) : 0
            let permit = BackgroundProcessingPermit(id: waiter.id, threadCount: threadCount(for: waiter.kind),
                                                    cancellation: waiter.cancellation)
            active = permit
            activeKind = waiter.kind
            activeExplicitRequest = waiter.explicitRequest
            beginScheduledWindowIfNeeded(kind: waiter.kind, explicitRequest: waiter.explicitRequest)
            waiter.continuation.resume(returning: permit)
            return
        }
    }

    private func startObservationIfNeeded() async {
        guard observeSystem, monitor == nil else { return }
        scheduler = BackgroundSchedulerBridge()
        scheduler?.start()
        memoryPressure = BackgroundMemoryPressureBridge()
        // Install the task before awaiting the shared sampler, so reentrant
        // callers cannot create duplicate native observers.
        let queue = monitorQueue
        let interval = monitorDelayInterval
        let checkpoint = monitorDelayCheckpoint
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                let delay = BackgroundProcessingMonitorDelay(interval: interval, queue: queue,
                                                            checkpoint: checkpoint)
                do { try await delay.wait() } catch { return }
                guard !Task.isCancelled else { return }
                await self?.refreshEnvironment()
            }
        }
        await refreshEnvironment()
    }

    private func refreshEnvironment() async {
        guard !closed else { return }
        let process = ProcessInfo.processInfo
        let sample: ResourceUsageSnapshot
        if let resourceUsage { sample = await resourceUsage.snapshot() }
        else { sample = fallbackResources.append(NativeResourceUsageProbe.read()) }
        guard !closed else { return }
        let pressure = process.thermalState != .serious && process.thermalState != .critical
            && (memoryPressure?.allowsProcessing ?? false)
        updateEnvironment(.init(
            idleSeconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!),
            lowPowerMode: process.isLowPowerModeEnabled,
            pressureAllowsProcessing: pressure,
            systemAllowsProcessing: scheduler?.allowsProcessing ?? false,
            resourceUsage: sample))
    }
}

/// One native delay, joined through the source's serial delivery queue. This
/// narrowly avoids the governor monitor's Swift task-sleep wake path; it does
/// not establish the cause of the observed runtime assertion. DispatchTime
/// excludes system sleep, so wake may retain up to the remaining one-second delay.
final class BackgroundProcessingMonitorDelay: @unchecked Sendable {
    enum Checkpoint: Sendable { case armed, eventSelected, cancelHandlerEntered }
    private enum Outcome { case fired, cancelled }

    private let lock = NSLock()
    private let interval: DispatchTimeInterval
    private let queue: DispatchQueue
    private let checkpoint: (@Sendable (Checkpoint) -> Void)?
    private var source: DispatchSourceTimer?
    private var continuation: CheckedContinuation<Void, Never>?
    private var outcome: Outcome?
    private var cancellationRequested = false
    private var started = false
    private var finished = false

    /// The owner supplies one serial queue for all of its monitor delays.
    init(interval: DispatchTimeInterval = .seconds(1), queue: DispatchQueue,
         checkpoint: (@Sendable (Checkpoint) -> Void)? = nil) {
        self.interval = interval
        self.queue = queue
        self.checkpoint = checkpoint
    }

    /// Single use. Even pre-cancellation activates and drains the native source,
    /// so continuation completion always means its callbacks have returned.
    func wait() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                start(continuation)
            }
        } onCancel: {
            self.cancel()
        }
        // Cancellation may win after the timer selects its fired outcome.
        try Task.checkCancellation()
    }

    private func start(_ continuation: CheckedContinuation<Void, Never>) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.setEventHandler { self.timerFired() }
        source.setCancelHandler {
            self.checkpoint?(.cancelHandlerEntered)
            // A serial successor cannot run until this native cancel handler
            // has returned. Keep the owner alive until that successor joins it.
            self.queue.async { self.finalize() }
        }
        source.schedule(deadline: .now() + interval, repeating: .never)
        let shouldCancel = lock.withLock {
            precondition(!started, "A monitor delay may only be awaited once")
            started = true
            self.continuation = continuation
            self.source = source
            // Activation and publication are one locked transition. A racing
            // cancellation cannot leave an unactivated source behind.
            source.activate()
            return cancellationRequested
        }
        if shouldCancel { source.cancel() }
        checkpoint?(.armed)
    }

    private func timerFired() {
        let source = lock.withLock { () -> DispatchSourceTimer? in
            guard outcome == nil else { return nil }
            outcome = .fired
            return self.source
        }
        guard let source else { return }
        checkpoint?(.eventSelected)
        source.cancel()
    }

    private func cancel() {
        let source = lock.withLock { () -> DispatchSourceTimer? in
            cancellationRequested = true
            if outcome == nil { outcome = .cancelled }
            return self.source
        }
        source?.cancel()
    }

    private func finalize() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !finished else { return nil }
            finished = true
            let value = self.continuation
            self.continuation = nil
            source = nil
            return value
        }
        continuation?.resume()
    }
}

/// Serial DispatchSource delivery and an awaited cancellation handler join native callbacks.
private final class BackgroundMemoryPressureBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let source: DispatchSourceMemoryPressure
    private var normal = true
    private var stopping = false
    private var stopped = false
    private var closers: [CheckedContinuation<Void, Never>] = []

    init() {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
                                                         queue: DispatchQueue(label: "com.retrace.processing-memory", qos: .background))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let isNormal = self.source.data.contains(.normal)
            self.lock.withLock { self.normal = isNormal }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            let pending = self.lock.withLock {
                self.stopped = true
                let value = self.closers
                self.closers.removeAll()
                return value
            }
            pending.forEach { $0.resume() }
        }
        source.resume()
    }

    var allowsProcessing: Bool { lock.withLock { normal && !stopping } }

    func close() async {
        await withCheckedContinuation { continuation in
            var shouldCancel = false
            let alreadyStopped = lock.withLock {
                if stopped { return true }
                closers.append(continuation)
                if !stopping { stopping = true; shouldCancel = true }
                return false
            }
            if alreadyStopped { continuation.resume() }
            if shouldCancel { source.cancel() }
        }
    }
}

/// The scheduler callback is synchronous and stores only its completion. No callback launches
/// detached work. Invalidation synchronizes with callbacks and discharges pending completion.
private final class BackgroundSchedulerBridge: BackgroundActivityScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private let scheduler = NSBackgroundActivityScheduler(identifier: "com.retrace.automatic-processing")
    private var completion: NSBackgroundActivityScheduler.CompletionHandler?
    private var stopped = false

    func start() {
        scheduler.interval = 30
        scheduler.tolerance = 10
        scheduler.repeats = true
        scheduler.qualityOfService = .background
        scheduler.schedule { [weak self] completion in
            guard let self else { completion(.deferred); return }
            let rejected = self.lock.withLock {
                if self.stopped { return true }
                self.completion = completion
                return false
            }
            if rejected { completion(.deferred) }
        }
    }

    var allowsProcessing: Bool {
        lock.withLock { !stopped && completion != nil && !scheduler.shouldDefer }
    }

    func finish(deferred: Bool) {
        let callback = lock.withLock {
            let value = completion
            completion = nil
            return value
        }
        callback?(deferred ? .deferred : .finished)
    }

    func invalidate() {
        lock.withLock { stopped = true }
        scheduler.invalidate()
        finish(deferred: true)
    }
}
