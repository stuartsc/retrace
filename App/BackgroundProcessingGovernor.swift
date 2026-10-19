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
    private var scheduler: (any BackgroundActivityScheduling)?
    private var memoryPressure: BackgroundMemoryPressureBridge?
    private var closing: [CheckedContinuation<Void, Never>] = []

    public init(observeSystem: Bool = true, resourceUsage: (any ResourceUsageProviding)? = nil) {
        self.observeSystem = observeSystem
        self.resourceUsage = resourceUsage
    }

    init(scheduler: any BackgroundActivityScheduling) {
        observeSystem = false; resourceUsage = nil
        self.scheduler = scheduler
    }

    public func tryAcquire(_ kind: BackgroundProcessingKind) async throws -> BackgroundProcessingPermit? {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        await startObservationIfNeeded()
        if observeSystem { await refreshEnvironment() }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let explicitRequest = BackgroundProcessingContext.explicitRequest
        guard active == nil, !waiters.contains(where: { mayProcess(kind: $0.kind, explicitRequest: $0.explicitRequest) }),
              mayProcess(kind: kind, explicitRequest: explicitRequest) else { return nil }
        let permit = BackgroundProcessingPermit(threadCount: threadCount(for: kind))
        active = permit
        activeKind = kind
        activeExplicitRequest = explicitRequest
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
        let usedScheduledWindow = !activeExplicitRequest && activeKind?.isFresh != true
        active = nil
        activeKind = nil
        activeExplicitRequest = false
        if usedScheduledWindow { scheduler?.finish(deferred: permit.cancellation.isCancelled) }
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
        if !finishingFreshBurst && !mayProcess(kind: activeKind, explicitRequest: activeExplicitRequest) {
            active?.cancellation.cancel()
        }
        if active == nil && !mayProcess { scheduler?.finish(deferred: true) }
        admit()
    }

    public func setProcessNow(_ enabled: Bool) {
        guard !closed else { return }
        processNow = enabled
        if !enabled && !activeExplicitRequest && activeKind?.isFresh != true { active?.cancellation.cancel() }
        admit()
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
        guard resourcePolicy.reason == nil else { return false }
        if kind?.isFresh == true { return true }
        return environment.idleSeconds.isFinite && environment.idleSeconds >= 300 && environment.systemAllowsProcessing
    }

    private var waitReason: BackgroundProcessingWaitReason? {
        if closed { return .closed }
        if !environment.pressureAllowsProcessing { return .resourcePressure }
        if processNow || activeExplicitRequest { return nil }
        if let reason = resourcePolicy.reason { return reason }
        if activeKind?.isFresh == true || waiters.contains(where: { $0.kind.isFresh }) { return nil }
        if !environment.idleSeconds.isFinite || environment.idleSeconds < 300 { return .activeUse }
        return environment.systemAllowsProcessing ? nil : .systemDeferral
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    private func threadCount(for kind: BackgroundProcessingKind) -> Int {
        if kind == .freshTranscription { return environment.lowPowerMode ? 1 : 2 }
        return environment.lowPowerMode ? 2 : 4
    }

    private func admit() {
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
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
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
