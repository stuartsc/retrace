import Foundation
import Shared

/// Application-code authority only. Never construct this from captured text,
/// search results, model output, or an external event. No command data is saved.
/// Kind is an integration-supplied category, not proof of a build artifact or
/// test suite: the only native completion claim is this command's exit fact.
public struct JobCommandInvocation: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let kind: JobKind
    public init(executableURL: URL, arguments: [String] = [], kind: JobKind) {
        self.executableURL = executableURL; self.arguments = arguments; self.kind = kind
    }
    fileprivate func validate() throws {
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/"),
              executableURL.query == nil, executableURL.fragment == nil,
              executableURL.path.utf8.count <= 4096, !executableURL.path.utf8.contains(0),
              arguments.count <= 64 else { throw JobEventError.invalidRequest }
        var bytes = 0
        for argument in arguments {
            guard argument.utf8.count <= 16_384, !argument.utf8.contains(0) else { throw JobEventError.invalidRequest }
            bytes += argument.utf8.count
            guard bytes <= 16_384 else { throw JobEventError.invalidRequest }
        }
    }
}

public enum JobServiceLifecycleState: Equatable, Sendable { case idle, observing, stopping, stopped }
private enum JobCallbackScope { @TaskLocal static var owner: UUID? }

/// One recording/master-generation owner. No execution on initialization and no
/// ambient process discovery. Stop is terminal; create a new instance after the
/// previous stop joins. Policy/master changes require that same lifecycle step.
public actor JobEventService {
    private struct Work {
        let id: UUID
        let invocation: JobCommandInvocation
        let task: Task<JobEventSnapshot, Error>
    }
    private struct Opening {
        let id: UUID
        let admission: JobAdmission
        let task: Task<JobWriterSession, Error>
    }
    private let store: any JobEventStoreProtocol
    private let admissionProvider: @Sendable () async throws -> JobAdmission?
    private let didCommit: @Sendable (JobEventSnapshot) async -> Void
    private let owner = UUID()
    private var writer: JobWriterSession?
    private var opening: Opening?
    private var work: [UUID: Work] = [:]
    private var stopping = false
    private var stopped = false
    private var stopReason = JobGapReason.serviceStopped
    private var stopTask: Task<Void, Error>?
    private var activeCalls = 0
    private var callWaiters: [CheckedContinuation<Void, Never>] = []
    private var nativeLaunchQueue = DispatchQueue.global(qos: .utility)
    #if DEBUG
    private var nativeDidQueueForTesting: (@Sendable () -> Void)?
    /// Owned native queue control, not a replacement Process or store. The
    /// synchronous signal only observes scheduling; tests suspend their own queue.
    func setNativeLaunchQueueForTesting(_ queue: DispatchQueue, didQueue: @escaping @Sendable () -> Void) {
        precondition(work.isEmpty && writer == nil && !stopping && !stopped)
        nativeLaunchQueue = queue; nativeDidQueueForTesting = didQueue
    }
    #endif

    /// didCommit is awaited and joined, with no per-event background Task. It
    /// must not synchronously await this service's run/stop. Reentrant calls fail
    /// with callbackReentry; an owning lifecycle controller may request stop from
    /// outside the callback. Callbacks contain only canonical categorical facts.
    public init(store: any JobEventStoreProtocol,
                admissionProvider: @escaping @Sendable () async throws -> JobAdmission?,
                didCommit: @escaping @Sendable (JobEventSnapshot) async -> Void = { _ in }) {
        self.store = store; self.admissionProvider = admissionProvider; self.didCommit = didCommit
    }

    public var lifecycleState: JobServiceLifecycleState {
        stopped ? .stopped : stopping ? .stopping : work.isEmpty ? .idle : .observing
    }

    /// Explicit invocation; equal concurrent request IDs join one native command.
    /// Reusing a completed ID is denied by the durable start, never re-executed.
    /// Cancelling any joined owner cancels observation for that shared request.
    public func run(_ invocation: JobCommandInvocation, requestID: UUID = UUID()) async throws -> JobEventSnapshot {
        guard JobCallbackScope.owner != owner else { throw JobEventError.callbackReentry }
        try checkLive()
        try Task.checkCancellation()
        activeCalls += 1
        defer { finishCall() }
        do { try invocation.validate() }
        catch { try? await store.recordJobDiagnostic(.rejected); throw JobEventError.invalidRequest }
        let current: Work
        if let existing = work[requestID] {
            guard existing.invocation == invocation else { throw JobEventError.conflict }
            current = existing
        } else {
            guard work.count < JobProducer.maximumOutstanding else {
                try await store.recordJobDiagnostic(.capacityExceeded)
                throw JobEventError.capacityExceeded
            }
            let id = UUID()
            let task = Task { [self] in try await perform(invocation, requestID: requestID) }
            current = Work(id: id, invocation: invocation, task: task)
            work[requestID] = current
        }
        defer { if work[requestID]?.id == current.id { work.removeValue(forKey: requestID) } }
        let result = try await withTaskCancellationHandler {
            try await current.task.value
        } onCancel: { current.task.cancel() }
        try Task.checkCancellation()
        try checkLive()
        guard let writer else { throw JobEventError.inactive }
        return try await publish(result, admission: writer.admission)
    }

    /// Cancels and joins all App/database callbacks. An already-launched command
    /// keeps running; only a bounded inert native lifetime remains until its exit.
    /// This method never waits for that exit and never sends the child a signal.
    public func stop(reason: JobGapReason = .serviceStopped) async throws {
        guard JobCallbackScope.owner != owner else { throw JobEventError.callbackReentry }
        if let stopTask { try await stopTask.value; return }
        guard !stopped else { return }
        stopping = true; stopReason = reason
        let tasks = work.values.map(\.task), pendingOpen = opening?.task, accepted = writer
        for task in tasks { task.cancel() }
        pendingOpen?.cancel()
        let task = Task { [self] in
            for task in tasks { _ = await task.result }
            // A COMMIT may precede delivery of its open ACK. Always join it and
            // retire any returned token, even if opening's caller was cancelled.
            let opened = await pendingOpen?.result
            var failure: Error?
            if let accepted {
                do { try await store.closeJobWriter(accepted, reason: reason) } catch { failure = error }
            }
            if let opened, case .success(let late) = opened, late != accepted {
                do { try await store.closeJobWriter(late, reason: reason) } catch { failure = error }
            }
            await joinCalls()
            do { try await store.recordJobDiagnostic(.stopped) } catch { failure = failure ?? error }
            writer = nil; opening = nil; work.removeAll(); stopped = true; stopping = false
            if failure != nil { throw JobEventError.unavailable }
        }
        stopTask = task
        try await task.value
    }

    private func perform(_ invocation: JobCommandInvocation, requestID: UUID) async throws -> JobEventSnapshot {
        var activeWriter: JobWriterSession?
        var start: JobObservation?
        var ended = false
        do {
            let admission = try await admitted()
            let session = try await getWriter(admission)
            activeWriter = session
            try await checkAdmission(admission)
            let proposed = JobObservation(runID: requestID, kind: invocation.kind, phase: .started)
            let receipt = try await store.appendJobStart(proposed, session: session)
            // A replay ACK is evidence, not permission to execute the command again.
            guard receipt.inserted else { throw JobEventError.conflict }
            start = proposed
            await notify(receipt.event)
            // Deletion or policy change while the callback was suspended must
            // invalidate this exact admitted start before a native launch.
            _ = try await publish(receipt.event, admission: admission)
            // This is the final App admission point before native launch. The
            // cancellation-safe native boundary also checks before Process.run.
            #if DEBUG
            let native = try await JobNativeObservation.observe(invocation, queue: nativeLaunchQueue, didQueue: nativeDidQueueForTesting)
            #else
            let native = try await JobNativeObservation.observe(invocation, queue: nativeLaunchQueue)
            #endif
            try await checkAdmission(admission)
            let terminal = JobObservation(runID: requestID, kind: invocation.kind, phase: .terminal,
                outcome: native.outcome, terminationStatus: native.status,
                observedAt: native.observedAt, observedUptime: native.observedUptime)
            let result = try await store.appendJobEnd(terminal, session: session)
            ended = true
            await notify(result)
            try await checkAdmission(admission)
            return result
        } catch {
            if start == nil, !stopping, !(error is CancellationError) {
                try? await store.recordJobDiagnostic(.rejected)
            }
            if let start, let session = activeWriter, !ended {
                let reason: JobGapReason
                if stopping { reason = stopReason }
                else if error is CancellationError { reason = .observationCancelled }
                else if error as? JobEventError == .inactive { reason = .admissionChanged }
                else if error as? JobEventError == .capacityExceeded { reason = .observerCapacityExceeded }
                else { reason = .persistenceUnavailable }
                let gap = JobObservation(runID: start.runID, kind: start.kind, phase: .gap,
                    outcome: .interrupted, gapReason: reason)
                do { await notify(try await store.appendJobEnd(gap, session: session)) }
                catch JobEventError.deleted { /* Deletion is authoritative; never resurrect. */ }
                catch { try? await store.recordJobDiagnostic(.persistenceFailed) }
            }
            if Task.isCancelled || stopping { throw CancellationError() }
            if let error = error as? JobEventError { throw error }
            throw JobEventError.unavailable
        }
    }

    private func getWriter(_ admission: JobAdmission) async throws -> JobWriterSession {
        try checkLive()
        if let writer {
            guard writer.admission == admission else { throw JobEventError.inactive }
            return writer
        }
        let current: Opening
        if let opening {
            guard opening.admission == admission else { throw JobEventError.inactive }
            current = opening
        } else {
            let store = store
            current = .init(id: UUID(), admission: admission, task: Task { try await store.openJobWriter(admission: admission) })
            opening = current
        }
        do {
            let session = try await current.task.value
            try checkLive()
            guard opening?.id == current.id || writer == session else { throw JobEventError.inactive }
            writer = session
            if opening?.id == current.id { opening = nil }
            return session
        } catch {
            // Stop captured the owning task and will join/retire its result.
            if !stopping, opening?.id == current.id { opening = nil }
            throw error
        }
    }

    private func admitted() async throws -> JobAdmission {
        try checkLive(); try Task.checkCancellation()
        let supplied = try await JobCallbackScope.$owner.withValue(owner) { try await admissionProvider() }
        guard let value = supplied else { throw JobEventError.inactive }
        try checkLive(); try Task.checkCancellation()
        return value
    }
    private func checkAdmission(_ expected: JobAdmission) async throws {
        guard try await admitted() == expected else { throw JobEventError.inactive }
    }
    private func publish(_ event: JobEventSnapshot, admission: JobAdmission) async throws -> JobEventSnapshot {
        try await checkAdmission(admission)
        guard case .available(let current, let stamp) = try await store.resolveJobEvidence(event.reference),
              current == event, stamp.policy == admission.policy, stamp.policyPhase == .active else { throw JobEventError.staleRead }
        try await checkAdmission(admission)
        // The global chronology revision belongs to list paging. An unrelated
        // job must not suppress this explicitly requested command or its exit.
        // Re-resolve the exact immutable event after the last awaited App fence.
        guard case .available(let exact, let latest) = try await store.resolveJobEvidence(event.reference),
              exact == event, latest.policy == admission.policy, latest.policyPhase == .active else { throw JobEventError.staleRead }
        try checkLive(); try Task.checkCancellation()
        return exact
    }
    private func notify(_ event: JobEventSnapshot) async {
        await JobCallbackScope.$owner.withValue(owner) { await didCommit(event) }
    }
    private func checkLive() throws { if stopping || stopped { throw JobEventError.stopped } }
    private func finishCall() {
        activeCalls -= 1
        if activeCalls == 0 { let all = callWaiters; callWaiters.removeAll(); for waiter in all { waiter.resume() } }
    }
    private func joinCalls() async {
        if activeCalls > 0 { await withCheckedContinuation { callWaiters.append($0) } }
    }
}

private struct JobNativeTermination: Sendable {
    let outcome: JobOutcome
    let status: Int32?
    let observedAt: Date
    let observedUptime: TimeInterval
}

/// At most eight retained Process lifetimes, including detached still-running
/// commands. Repeated service restart cannot grow this native ownership without
/// bound. A detached callback has no reference to a service, store, or invocation.
private final class JobNativeLifetimePool: @unchecked Sendable {
    static let shared = JobNativeLifetimePool()
    private let lock = NSLock()
    private var retained: [UUID: JobNativeObservation] = [:]
    func insert(_ observation: JobNativeObservation) throws {
        lock.lock(); defer { lock.unlock() }
        guard retained.count < JobProducer.maximumOutstanding else { throw JobEventError.capacityExceeded }
        retained[observation.id] = observation
    }
    func remove(_ id: UUID) { lock.lock(); retained.removeValue(forKey: id); lock.unlock() }
}

/// Short locked state changes only; Process.run executes on a background queue.
/// Cancellation joins any in-flight launch but never waits for child termination.
private final class JobNativeObservation: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private let process = Process()
    private var continuation: CheckedContinuation<JobNativeTermination, Error>?
    private var cancelled = false
    private var launchScheduled = false
    private var launchInFlight = false
    private var finished = false
    private var terminal: JobNativeTermination?

    static func observe(_ invocation: JobCommandInvocation, queue: DispatchQueue,
                        didQueue: (@Sendable () -> Void)? = nil) async throws -> JobNativeTermination {
        let owner = JobNativeObservation()
        try JobNativeLifetimePool.shared.insert(owner)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if owner.install(continuation) {
                    queue.async { owner.launch(invocation) }
                    didQueue?()
                }
            }
        } onCancel: { owner.cancel() }
    }
    private func install(_ value: CheckedContinuation<JobNativeTermination, Error>) -> Bool {
        lock.lock()
        if cancelled || finished {
            finished = true; lock.unlock()
            JobNativeLifetimePool.shared.remove(id); value.resume(throwing: CancellationError()); return false
        }
        continuation = value; launchScheduled = true; lock.unlock(); return true
    }
    private func launch(_ invocation: JobCommandInvocation) {
        lock.lock()
        launchScheduled = false
        guard !cancelled, !finished else {
            let waiter = continuation; continuation = nil; finished = true; lock.unlock()
            JobNativeLifetimePool.shared.remove(id)
            waiter?.resume(throwing: CancellationError())
            return
        }
        launchInFlight = true
        lock.unlock()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [self] child in complete(child) }
        do {
            try process.run()
            lock.lock(); launchInFlight = false
            let result = terminal
            let shouldResume = cancelled || result != nil
            let waiter = shouldResume ? continuation : nil
            let wasCancelled = cancelled
            if shouldResume { continuation = nil; finished = true }
            lock.unlock()
            if wasCancelled { waiter?.resume(throwing: CancellationError()) }
            else if let result { waiter?.resume(returning: result) }
        } catch {
            process.terminationHandler = nil
            let failure = JobNativeTermination(outcome: .launchFailed, status: nil,
                observedAt: Date(), observedUptime: ProcessInfo.processInfo.systemUptime)
            lock.lock(); launchInFlight = false; finished = true
            let waiter = continuation, wasCancelled = cancelled
            continuation = nil; lock.unlock()
            JobNativeLifetimePool.shared.remove(id)
            if wasCancelled { waiter?.resume(throwing: CancellationError()) }
            else { waiter?.resume(returning: failure) }
        }
    }
    private func cancel() {
        lock.lock(); cancelled = true
        // A queued/in-flight launch owns its cancellation ACK. This keeps both
        // queued invocation memory and native pool permits bounded across stop.
        let launchOwned = launchInFlight || launchScheduled
        let waiter = launchOwned ? nil : continuation
        if !launchOwned { continuation = nil; finished = true }
        lock.unlock()
        // install/queued launch/real native termination releases the pool in its
        // own branch. Cancellation must not drop a still-running Process owner.
        waiter?.resume(throwing: CancellationError())
    }
    private func complete(_ child: Process) {
        let status = child.terminationStatus
        let outcome: JobOutcome = child.terminationReason == .uncaughtSignal ? .signalled : status == 0 ? .succeeded : .failed
        let result = JobNativeTermination(outcome: outcome, status: status,
            observedAt: Date(), observedUptime: ProcessInfo.processInfo.systemUptime)
        lock.lock(); terminal = result
        let waiter = launchInFlight ? nil : continuation, wasCancelled = cancelled
        if !launchInFlight { continuation = nil; finished = true }
        lock.unlock()
        // Clear the native cycle before releasing retained ownership. No Task,
        // App callback, database call, or evidence publication occurs here.
        child.terminationHandler = nil
        JobNativeLifetimePool.shared.remove(id)
        if wasCancelled { waiter?.resume(throwing: CancellationError()) }
        else { waiter?.resume(returning: result) }
    }
}
