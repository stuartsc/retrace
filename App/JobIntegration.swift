import Foundation
import Shared

/// Categories only. Repeated equivalent lifecycle requests are coalesced; these
/// metrics do not count native jobs (their canonical receipts do that atomically).
public enum JobIntegrationAction: String, CaseIterable, Hashable, Sendable {
    case enabled, disabled, recordingStarted, recordingPaused, policyChanged, policyActivated, shutdown, failed
}

private enum JobIntegrationCallbackScope { @TaskLocal static var owner: UUID? }

/// App-owned observation, separate from execution authority and capture settings.
/// No command runs on initialization, recording start, or a policy transition.
/// Only run's explicit application-code invocation can reach Process.run.
public actor JobIntegration {
    public nonisolated static let defaultsKey = "jobObservationEnabled"

    private struct Slot {
        let id: UUID
        let revision: UUID
        let admission: JobAdmission
        let service: JobEventService
    }
    private struct Request {
        let id: UUID
        let slotID: UUID
        let invocation: JobCommandInvocation
        let task: Task<JobEventSnapshot, Error>
    }
    private struct Reconciliation {
        let id: UUID
        let task: Task<Void, Error>
    }
    private let store: any JobEventStoreProtocol
    private let metric: @Sendable (JobIntegrationAction) async -> Void
    private var didCommit: @Sendable (JobEventSnapshot) async -> Void
    private let callbackOwner = UUID()
    private var selectedConfiguration: JobObservationConfig
    private var masterGeneration: UUID?
    /// Every disabling/replacement boundary rotates even if desired values
    /// return A→B→A before the owning reconciliation task resumes.
    private var revision = UUID()
    private var activePolicy: ScreenEvidencePolicyTransition?
    private var slot: Slot?
    private var requests: [UUID: Request] = [:]
    private var reconciliation: Reconciliation?
    private var stopReason: JobGapReason = .serviceStopped
    private var closed = false
    private var shutdownTask: Task<Void, Error>?
    // One closed category set and one owning worker; never a Task per metric.
    private var pendingMetrics: Set<JobIntegrationAction> = []
    #if DEBUG
    private var requestWaitersForTesting: [UUID: Int] = [:]
    private var reconciliationCheckpointForTesting: (@Sendable () async -> Void)?
    #endif

    public init(store: any JobEventStoreProtocol,
                configuration: JobObservationConfig = .default,
                didCommit: @escaping @Sendable (JobEventSnapshot) async -> Void = { _ in },
                metric: @escaping @Sendable (JobIntegrationAction) async -> Void = { _ in }) {
        self.store = store; selectedConfiguration = configuration
        self.didCommit = didCommit; self.metric = metric
    }

    public var configuration: JobObservationConfig { selectedConfiguration }
    public var isRecording: Bool { masterGeneration != nil && !closed }
    public var isClosed: Bool { closed }
    public var isReady: Bool {
        guard reconciliation == nil, let slot, let current = desiredAdmission else { return false }
        return slot.revision == revision && slot.admission == current
    }

    /// Settings are independent of screen backend/audio consent. A disable takes
    /// effect before any await, then joins the previous service and its callbacks.
    public func setConfiguration(_ configuration: JobObservationConfig) async throws {
        try checkExternalCall(); try checkOpen()
        guard selectedConfiguration != configuration else { try await joinReconciliation(); return }
        selectedConfiguration = configuration
        advanceRevision()
        stopReason = .admissionChanged
        pendingMetrics.insert(configuration.enabled ? .enabled : .disabled)
        try await reconcile()
    }

    /// Only App's owning recording lifecycle supplies this generation. Duplicate
    /// starts keep their generation; a pause/restart always supplies a fresh one.
    func beginRecording(generation: UUID) async throws {
        try checkExternalCall(); try checkOpen()
        guard masterGeneration != generation else { try await joinReconciliation(); return }
        masterGeneration = generation
        advanceRevision()
        stopReason = .producerRestarted
        if selectedConfiguration.enabled { pendingMetrics.insert(.recordingStarted) }
        try await reconcile()
    }

    func endRecording(reason: JobGapReason = .recordingPaused) async throws {
        try checkExternalCall()
        let wasRecording = masterGeneration != nil
        masterGeneration = nil
        if wasRecording { advanceRevision() }
        stopReason = reason
        if wasRecording, selectedConfiguration.enabled { pendingMetrics.insert(.recordingPaused) }
        try await reconcile()
    }

    /// Called by the real App V23 bridge BEFORE begin/prepare/revoke/end can
    /// mutate SQLite. Stale token cleanup cannot pause a newer active policy.
    func policyWillChange(matching expected: ScreenEvidencePolicyTransition? = nil) async throws {
        try checkExternalCall()
        if let expected, activePolicy != expected { return }
        let hadPolicy = activePolicy != nil
        activePolicy = nil
        if hadPolicy { advanceRevision() }
        stopReason = .admissionChanged
        if hadPolicy, selectedConfiguration.enabled { pendingMetrics.insert(.policyChanged) }
        try await reconcile()
    }

    /// The bridge supplies only a successfully activated canonical token. It is
    /// not sufficient authority by itself: the store requires its live capability.
    func policyDidActivate(_ policy: ScreenEvidencePolicyTransition) async throws {
        try checkExternalCall(); try checkOpen()
        if activePolicy != policy { advanceRevision() }
        activePolicy = policy
        if selectedConfiguration.enabled { pendingMetrics.insert(.policyActivated) }
        try await reconcile()
    }

    /// No model/search/excerpt/tool route is registered. The invocation is
    /// application code authority and never persisted in these job receipts.
    public func run(_ invocation: JobCommandInvocation, requestID: UUID = UUID()) async throws -> JobEventSnapshot {
        try checkExternalCall(); try checkOpen(); try Task.checkCancellation()
        guard reconciliation == nil, let current = slot, current.revision == revision,
              current.admission == desiredAdmission else {
            throw JobEventError.inactive
        }
        let request: Request
        if let existing = requests[requestID] {
            guard existing.slotID == current.id, existing.invocation == invocation else { throw JobEventError.conflict }
            request = existing
        } else {
            guard requests.count < JobProducer.maximumOutstanding else {
                pendingMetrics.insert(.failed)
                try await reconcile()
                throw JobEventError.capacityExceeded
            }
            let task = Task {
                try Task.checkCancellation()
                return try await current.service.run(invocation, requestID: requestID)
            }
            request = Request(id: UUID(), slotID: current.id, invocation: invocation, task: task)
            requests[requestID] = request
        }
        #if DEBUG
        requestWaitersForTesting[request.id, default: 0] += 1
        #endif
        defer {
            if requests[requestID]?.id == request.id { requests.removeValue(forKey: requestID) }
            #if DEBUG
            let remaining = (requestWaitersForTesting[request.id] ?? 1) - 1
            if remaining == 0 { requestWaitersForTesting.removeValue(forKey: request.id) }
            else { requestWaitersForTesting[request.id] = remaining }
            #endif
        }
        let result = try await withTaskCancellationHandler {
            try await request.task.value
        } onCancel: { request.task.cancel() }
        guard !closed, slot?.id == current.id, current.revision == revision,
              desiredAdmission == current.admission else { throw CancellationError() }
        try Task.checkCancellation()
        return result
    }

    /// Terminal. Joins the old service, held post-commit callbacks and bounded
    /// metrics before the canonical database can close. It never kills a command.
    public func shutdown() async throws {
        try checkExternalCall()
        if let shutdownTask { try await shutdownTask.value; return }
        if !closed {
            closed = true; masterGeneration = nil; activePolicy = nil
            advanceRevision()
            stopReason = .serviceStopped
            pendingMetrics.insert(.shutdown)
        }
        let task = Task { try await self.reconcile() }
        shutdownTask = task
        do { try await task.value }
        catch { shutdownTask = nil; throw error }
    }

    /// Only ServiceContainer's serialized, nonterminal initialization retry uses
    /// this after rollback. Reopening grants neither recording nor policy admission.
    func reopenAfterJoinedClose() async throws {
        try checkExternalCall()
        try Task.checkCancellation()
        guard closed else { return }
        guard let shutdownTask else { throw JobEventError.stopped }
        try await shutdownTask.value
        try Task.checkCancellation()
        guard closed, reconciliation == nil, slot == nil, requests.isEmpty,
              pendingMetrics.isEmpty, masterGeneration == nil, activePolicy == nil else {
            throw JobEventError.stopped
        }
        self.shutdownTask = nil
        advanceRevision()
        closed = false
    }

    public nonisolated static func metricMetadata(_ action: JobIntegrationAction) -> String {
        "{\"action\":\"owner.\(action.rawValue)\",\"count\":1}"
    }

    #if DEBUG
    func setNativeLaunchQueueForTesting(_ queue: DispatchQueue, didQueue: @escaping @Sendable () -> Void) async {
        precondition(requests.isEmpty && reconciliation == nil)
        guard let current = slot else { preconditionFailure("Test requires an active owner slot") }
        await current.service.setNativeLaunchQueueForTesting(queue, didQueue: didQueue)
    }
    func requestWaiterCountForTesting(_ requestID: UUID) -> Int {
        guard let id = requests[requestID]?.id else { return 0 }
        return requestWaitersForTesting[id] ?? 0
    }

    func setReconciliationCheckpointForTesting(_ checkpoint: (@Sendable () async -> Void)?) {
        precondition(reconciliation == nil)
        reconciliationCheckpointForTesting = checkpoint
    }

    /// Replaces only delivery of canonical facts; native Process/store remain real.
    func setCommitHandlerForTesting(_ handler: @escaping @Sendable (JobEventSnapshot) async -> Void) {
        precondition(slot == nil && reconciliation == nil && masterGeneration == nil && !closed)
        didCommit = handler
    }
    #endif

    /// Cancellation handlers run synchronously. This reaches service.run's
    /// owned work/native cancellation flag even when its last canonical read
    /// or native queue is held and deferred reconciliation has not begun.
    /// Already-launched children continue; stop joins observation callbacks.
    private func advanceRevision() {
        revision = UUID()
        for request in requests.values { request.task.cancel() }
    }

    private var desiredAdmission: JobAdmission? {
        guard !closed, selectedConfiguration.enabled, let masterGeneration, let activePolicy else { return nil }
        return JobAdmission(masterGeneration: masterGeneration, policy: activePolicy)
    }

    private func checkOpen() throws { if closed { throw JobEventError.stopped } }
    private func checkExternalCall() throws {
        if JobIntegrationCallbackScope.owner == callbackOwner { throw JobEventError.callbackReentry }
    }
    private func joinReconciliation() async throws { if let current = reconciliation { try await current.task.value } }
    private func reconcile() async throws {
        if let current = reconciliation { try await current.task.value; return }
        let id = UUID()
        let task = Task { [self] in try await reconcileOwned(id: id) }
        reconciliation = Reconciliation(id: id, task: task)
        // Cancelling a waiter cannot abandon this owned cleanup or metric drain.
        try await task.value
    }

    private func reconcileOwned(id: UUID) async throws {
        defer { if reconciliation?.id == id { reconciliation = nil } }
        #if DEBUG
        await reconciliationCheckpointForTesting?()
        #endif
        var retirementFailure = false
        while true {
            if let previous = slot, previous.revision != revision || previous.admission != desiredAdmission {
                // Synchronous cancellation already closed queued native work.
                // Stop and join every owned request before replacing the slot.
                let retiring = requests.filter { $0.value.slotID == previous.id }
                do { try await previous.service.stop(reason: stopReason) }
                catch { retirementFailure = true; pendingMetrics.insert(.failed) }
                for (requestID, request) in retiring {
                    _ = await request.task.result
                    if requests[requestID]?.id == request.id { requests.removeValue(forKey: requestID) }
                }
                if slot?.id == previous.id { slot = nil }
                continue
            }
            if !retirementFailure, slot == nil, let admission = desiredAdmission {
                let slotID = UUID()
                let service = JobEventService(store: store, admissionProvider: { [weak self] in
                    await self?.admission(for: slotID, expected: admission)
                }, didCommit: { [weak self] event in
                    await self?.deliver(event)
                })
                slot = Slot(id: slotID, revision: revision, admission: admission, service: service)
            }
            if let action = pendingMetrics.sorted(by: { $0.rawValue < $1.rawValue }).first {
                pendingMetrics.remove(action)
                await JobIntegrationCallbackScope.$owner.withValue(callbackOwner) { await metric(action) }
                // Configuration/master/policy may change while metric delivery
                // is held. Reconcile again before returning to any joined caller.
                continue
            }
            if retirementFailure { throw JobEventError.unavailable }
            return
        }
    }

    private func admission(for id: UUID, expected: JobAdmission) -> JobAdmission? {
        guard !closed, slot?.id == id, slot?.revision == revision, desiredAdmission == expected else { return nil }
        return expected
    }
    private func deliver(_ event: JobEventSnapshot) async {
        await JobIntegrationCallbackScope.$owner.withValue(callbackOwner) { await didCommit(event) }
    }
}
