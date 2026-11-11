import Foundation
import Shared
import Database
import SQLCipher
import XCTest
@testable import App

/// Actual private SQLite, the production policy owner, and authored owned
/// commands. No devices, user process discovery, command UI, or global hooks.
final class JobIntegrationTests: XCTestCase {
    private var database: DatabaseManager!
    private var owner: JobIntegration!
    private var bridge: ScreenEvidenceAdmissionCoordinator!
    private let callbacks = JobOwnerCallbackGate()
    private let metrics = JobOwnerMetricGate()
    private var joinedTasks: [@Sendable () async -> Void] = []
    private var releaseBoundaries: [@Sendable () async -> Void] = []
    private var containers: [ServiceContainer] = []
    private var ownedFiles: [URL] = []

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:job-owner-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let database = database!, callbacks = callbacks, metrics = metrics
        owner = JobIntegration(store: database, didCommit: { await callbacks.receive($0) }, metric: { action in
            await metrics.receive(action)
            try? await database.recordMetricEvent(metricType: .jobEvent,
                metadata: JobIntegration.metricMetadata(action))
        })
        bridge = ScreenEvidenceAdmissionCoordinator(store: database, jobs: owner)
    }

    override func tearDown() async throws {
        await callbacks.release(); await metrics.release()
        for release in releaseBoundaries { await release() }
        for join in joinedTasks { await join() }
        joinedTasks.removeAll()
        for file in ownedFiles { try? FileManager.default.removeItem(at: file) }
        ownedFiles.removeAll()
        if let owner { try await owner.shutdown() }
        if let bridge { try await bridge.endSession() }
        for container in containers { try await container.shutdown() }
        if let database { try await database.close() }
    }

    func testIndependentMissingConfigurationDefaultsOffAndInitCannotExecute() async throws {
        let old = try JSONDecoder().decode(JobObservationConfig.self, from: Data("{}".utf8))
        XCTAssertFalse(old.enabled)
        XCTAssertFalse(JobObservationConfig.default.enabled)
        _ = try await activate()
        try await owner.beginRecording(generation: UUID())
        await assertInactive { try await self.owner.run(self.command("/usr/bin/true")) }
        let empty = try await database.jobChronology(.init(), after: nil)
        XCTAssertTrue(empty.events.isEmpty)

        try await owner.setConfiguration(.init(enabled: true))
        let success = try await owner.run(command("/usr/bin/true", kind: .build))
        let failure = try await owner.run(command("/usr/bin/false", kind: .test))
        XCTAssertEqual(success.observation.terminationStatus, 0)
        XCTAssertEqual(success.observation.outcome, .succeeded)
        XCTAssertEqual(failure.observation.terminationStatus, 1)
        XCTAssertEqual(failure.observation.outcome, .failed)
        XCTAssertEqual(success.observerSessionID, failure.observerSessionID)
        let page = try await database.jobChronology(.init(), after: nil)
        XCTAssertEqual(page.events.count, 4)
    }

    func testPauseJoinsHeldStartAndRestartUsesFreshObserverWhileHistoryStaysReadable() async throws {
        _ = try await enableAndStart()
        let entered = await callbacks.hold(.started)
        let owner = owner!
        let run = tracked(Task { try await owner.run(self.command("/usr/bin/true")) })
        await fulfillment(of: [entered], timeout: 3)
        let startedValue = await callbacks.lastEvent
        let started = try XCTUnwrap(startedValue)
        let stopped = JobOwnerFlag()
        let pause = tracked(Task { try await owner.endRecording(); await stopped.set() })
        try await waitUntil { !(await owner.isReady) }
        let stopReturned = await stopped.value
        XCTAssertFalse(stopReturned)
        await assertInactive { try await owner.run(self.command("/usr/bin/true")) }
        await callbacks.release()
        try await pause.value
        await assertCancelled(run)
        let paused = try await database.jobChronology(.init(), after: nil)
        let gaps = paused.events.filter { $0.observation.phase == .gap }
        XCTAssertEqual(gaps.count, 1)
        // Immediate cancellation can finish before deferred stop sets its more
        // specific pause reason. Both receipts truthfully report interruption.
        XCTAssertTrue(gaps.allSatisfy { $0.observation.gapReason == .recordingPaused || $0.observation.gapReason == .observationCancelled })
        XCTAssertFalse(paused.events.contains { $0.observation.phase == .terminal })
        try await owner.beginRecording(generation: UUID())
        let next = try await owner.run(command("/usr/bin/false"))
        XCTAssertNotEqual(next.observerSessionID, started.observerSessionID)
        XCTAssertEqual(next.observation.terminationStatus, 1)
    }

    func testPolicyPrepareJoinsCallbackBeforeDurableMutationAndPreparedPolicyDeniesCommands() async throws {
        let original = try await enableAndStart()
        let entered = await callbacks.hold(.started)
        let owner = owner!, bridge = bridge!
        let run = tracked(Task { try await owner.run(self.command("/usr/bin/true")) })
        await fulfillment(of: [entered], timeout: 3)
        let completed = JobOwnerFlag()
        let preparing = tracked(Task {
            let token = try await bridge.prepareConfiguration(CaptureConfig(excludedAppBundleIDs: ["io.retrace.authored.excluded"]))
            await completed.set(); return token
        })
        try await waitUntil { !(await owner.isReady) }
        let controlReturned = await completed.value
        XCTAssertFalse(controlReturned)
        let whileHeld = try await database.jobChronology(.init(), after: nil)
        XCTAssertEqual(whileHeld.stamp.policy, original, "V23 must not advance before old callbacks have joined")
        await callbacks.release()
        let changed = try await preparing.value
        await assertCancelled(run)
        await assertInactive { try await owner.run(self.command("/usr/bin/true")) }
        try await bridge.activate(changed)
        let result = try await owner.run(command("/usr/bin/false"))
        XCTAssertEqual(result.policySHA256, changed.policySHA256)
        XCTAssertNotEqual(original.policyEpoch, changed.policyEpoch)
        // Cleanup for an old epoch must not retire the current job observer.
        try await bridge.revoke(original)
        let stillCurrent = try await owner.run(command("/usr/bin/true"))
        XCTAssertEqual(stillCurrent.observerSessionID, result.observerSessionID)
    }

    func testDisableJoinsHeldRealExitWithoutErasingItsDurableTerminalReceipt() async throws {
        _ = try await enableAndStart()
        let entered = await callbacks.hold(.terminal)
        let owner = owner!
        let run = tracked(Task { try await owner.run(self.command("/usr/bin/true")) })
        await fulfillment(of: [entered], timeout: 3)
        let committedValue = await callbacks.lastEvent
        let committed = try XCTUnwrap(committedValue)
        let disabled = JobOwnerFlag()
        let change = tracked(Task { try await owner.setConfiguration(.init(enabled: false)); await disabled.set() })
        try await waitUntil { !(await owner.isReady) }
        let disableReturned = await disabled.value
        XCTAssertFalse(disableReturned)
        await callbacks.release()
        try await change.value
        await assertCancelled(run)
        let configured = await owner.configuration
        XCTAssertFalse(configured.enabled)
        guard case .available(let retained, _) = try await database.resolveJobEvidence(committed.reference) else {
            return XCTFail("Stopping observation discarded a committed native exit")
        }
        XCTAssertEqual(retained.observation.outcome, .succeeded)
        XCTAssertEqual(retained.observation.terminationStatus, 0)
        await assertInactive { try await owner.run(self.command("/usr/bin/true")) }
    }

    func testPauseQueuedRestartThenPauseCoalescesWithoutAReplacementObserver() async throws {
        _ = try await enableAndStart()
        let entered = await callbacks.hold(.started)
        let owner = owner!
        let run = tracked(Task { try await owner.run(self.command("/usr/bin/true")) })
        await fulfillment(of: [entered], timeout: 3)
        let first = tracked(Task { try await owner.endRecording() })
        try await waitUntil { !(await owner.isRecording) }
        let restarting = tracked(Task { try await owner.beginRecording(generation: UUID()) })
        try await waitUntil { await owner.isRecording }
        let last = tracked(Task { try await owner.endRecording() })
        try await waitUntil { !(await owner.isRecording) }
        first.cancel() // Cleanup belongs to the shared owner, not this waiter.
        await callbacks.release()
        try await first.value; try await restarting.value; try await last.value
        await assertCancelled(run)
        let ready = await owner.isReady
        XCTAssertFalse(ready)
        let page = try await database.jobChronology(.init(), after: nil)
        XCTAssertEqual(page.events.count, 2)
        XCTAssertFalse(page.events.contains { $0.observation.phase == .terminal })
        await assertInactive { try await owner.run(self.command("/usr/bin/true")) }
    }

    func testShutdownJoinsHeldMetricDeliveryBeforeReturningAndNeverReopens() async throws {
        _ = try await enableAndStart()
        let entered = await metrics.hold(.disabled)
        let owner = owner!
        let change = tracked(Task { try await owner.setConfiguration(.init(enabled: false)) })
        await fulfillment(of: [entered], timeout: 3)
        let completed = JobOwnerFlag()
        let closing = tracked(Task { try await owner.shutdown(); await completed.set() })
        try await waitUntil { await owner.isClosed }
        let controlReturned = await completed.value
        XCTAssertFalse(controlReturned)
        await metrics.release()
        try await change.value; try await closing.value
        await assertInactive { try await owner.run(self.command("/usr/bin/true")) }
        do { try await owner.beginRecording(generation: UUID()); XCTFail("Closed owner restarted") }
        catch let error as JobEventError { XCTAssertEqual(error, .stopped) }
        try await owner.shutdown() // Idempotent after its callback join.
        let rows = try await metricRows()
        XCTAssertFalse(rows.isEmpty)
        for row in rows where row.contains("owner.") {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["action", "count"])
            XCTAssertFalse(row.contains("/usr/bin"))
        }
    }

    func testInternalRollbackReopenJoinsShutdownAndRequiresFreshAdmission() async throws {
        _ = try await enableAndStart()
        let first = try await owner.run(command("/usr/bin/true"))
        let history = try await database.jobChronology(.init(), after: nil)
        let entered = await metrics.hold(.shutdown)
        let owner = owner!
        let closing = tracked(Task { try await owner.shutdown() })
        await fulfillment(of: [entered], timeout: 3)
        // Retiring the native observer records its own stopped diagnostic before
        // the owner shutdown delivery is held. Only that held delivery remains.
        let metricsAtHeldShutdown = try await metricRows()
        XCTAssertTrue(metricsAtHeldShutdown.contains { $0.contains("\"operation\":\"stopped\"") })
        let premature = expectation(description: "Internal reopen must join held shutdown delivery")
        premature.isInverted = true
        let reopening = tracked(Task {
            try await owner.reopenAfterJoinedClose()
            premature.fulfill()
        })
        await fulfillment(of: [premature], timeout: 0.05)
        let stillClosed = await owner.isClosed
        XCTAssertTrue(stillClosed)
        do { try await owner.beginRecording(generation: UUID()); XCTFail("Held close must still fence admission") }
        catch let error as JobEventError { XCTAssertEqual(error, .stopped) }

        await metrics.release()
        try await closing.value
        try await reopening.value
        let closed = await owner.isClosed
        let recording = await owner.isRecording
        let ready = await owner.isReady
        let configuration = await owner.configuration
        XCTAssertFalse(closed)
        XCTAssertFalse(recording)
        XCTAssertFalse(ready)
        XCTAssertTrue(configuration.enabled)
        let afterReopen = try await database.jobChronology(.init(), after: nil)
        XCTAssertEqual(afterReopen.events.map(\.reference), history.events.map(\.reference))
        let metricsAfterReopen = try await metricRows()
        XCTAssertEqual(metricsAfterReopen.count, metricsAtHeldShutdown.count + 1,
                       "Reopening must not create a new metric producer or observer")
        await assertInactive { try await owner.run(self.command("/usr/bin/true")) }
        try await owner.beginRecording(generation: UUID())
        await assertInactive { try await owner.run(self.command("/usr/bin/true")) }
        try await bridge.endSession()
        _ = try await activate()
        let next = try await owner.run(command("/usr/bin/false"))
        XCTAssertEqual(next.observation.terminationStatus, 1)
        XCTAssertNotEqual(next.observerSessionID, first.observerSessionID)
    }

    func testInternalRollbackReopenRejectsFailedShutdownUntilAJoinedRetry() async throws {
        _ = try await enableAndStart()
        _ = try await owner.run(command("/usr/bin/true"))
        try await database.setJobStopMetricFailure(true)
        addTeardownBlock { try await self.database.setJobStopMetricFailure(false) }
        do { try await owner.shutdown(); XCTFail("Real SQLite stop diagnostic failure must escape") }
        catch let error as JobEventError { XCTAssertEqual(error, .unavailable) }
        do { try await owner.reopenAfterJoinedClose(); XCTFail("An unsuccessful close is not a joined rollback") }
        catch let error as JobEventError { XCTAssertEqual(error, .stopped) }
        let closed = await owner.isClosed
        XCTAssertTrue(closed)
        try await database.setJobStopMetricFailure(false)
        try await owner.shutdown()
        try await owner.reopenAfterJoinedClose()
        await assertInactive { try await owner.run(self.command("/usr/bin/true")) }
    }

    func testCancelledInternalRollbackReopenKeepsShutdownTerminal() async throws {
        try await owner.shutdown()
        let owner = owner!
        let reopening = tracked(Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await owner.reopenAfterJoinedClose()
        })
        do { try await reopening.value; XCTFail("Cancelled initialization must not reopen the owner") }
        catch is CancellationError { }
        let closed = await owner.isClosed
        XCTAssertTrue(closed)
    }

    func testCallbackCannotSelfJoinOwningRecordingPauseOrShutdown() async throws {
        let holder = JobOwnerHolder(), database = database!
        let local = JobIntegration(store: database, configuration: .init(enabled: true), didCommit: { _ in
            guard let current = await holder.value else { return XCTFail("Missing owner") }
            do { try await current.endRecording(); XCTFail("Callback joined its own pause") }
            catch let error as JobEventError { XCTAssertEqual(error, .callbackReentry) }
            catch { XCTFail("Unexpected pause reentry error") }
            do { try await current.shutdown(); XCTFail("Callback joined its own shutdown") }
            catch let error as JobEventError { XCTAssertEqual(error, .callbackReentry) }
            catch { XCTFail("Unexpected shutdown reentry error") }
            do { try await current.reopenAfterJoinedClose(); XCTFail("Callback reached owner-only reopen") }
            catch let error as JobEventError { XCTAssertEqual(error, .callbackReentry) }
            catch { XCTFail("Unexpected reopen reentry error") }
        })
        await holder.set(local)
        let localBridge = ScreenEvidenceAdmissionCoordinator(store: database, jobs: local)
        addTeardownBlock { try? await local.shutdown(); try? await localBridge.endSession() }
        let policy = try await localBridge.beginSession(config: CaptureConfig())
        try await localBridge.activate(policy)
        try await local.beginRecording(generation: UUID())
        let result = try await local.run(command("/usr/bin/true"))
        XCTAssertEqual(result.observation.terminationStatus, 0)
        try await local.shutdown(); try await localBridge.endSession()
    }

    #if DEBUG
    func testDisableEnableRoundTripBeforeReconciliationStillRetiresThePreviousObserver() async throws {
        _ = try await enableAndStart()
        let entered = await callbacks.hold(.started)
        let owner = owner!
        let run = tracked(Task { try await owner.run(self.command("/usr/bin/true")) })
        await fulfillment(of: [entered], timeout: 3)
        let oldValue = await callbacks.lastEvent
        let old = try XCTUnwrap(oldValue)
        let boundary = JobOwnerReconciliationGate()
        releaseBoundaries.append { await boundary.release() }
        let held = await boundary.prepare()
        await owner.setReconciliationCheckpointForTesting { await boundary.hold() }
        let disabling = tracked(Task { try await owner.setConfiguration(.init(enabled: false)) })
        await fulfillment(of: [held], timeout: 3)
        let enabling = tracked(Task { try await owner.setConfiguration(.init(enabled: true)) })
        try await waitUntil { await owner.configuration.enabled }
        await boundary.release()
        await callbacks.release()
        try await disabling.value; try await enabling.value
        await owner.setReconciliationCheckpointForTesting(nil)
        await assertCancelled(run)
        let replacement = try await owner.run(command("/usr/bin/false"))
        XCTAssertNotEqual(replacement.observerSessionID, old.observerSessionID)
        XCTAssertEqual(replacement.observation.terminationStatus, 1)
        let page = try await database.jobChronology(.init(), after: nil)
        XCTAssertFalse(page.events.contains { $0.observation.runID == old.observation.runID && $0.observation.phase == .terminal })
    }

    func testDisableCancelsQueuedNativeLaunchBeforeHeldReconciliationBegins() async throws {
        _ = try await enableAndStart()
        let owner = owner!
        let nativeQueue = JobOwnerNativeQueue()
        releaseBoundaries.append { nativeQueue.release() }
        let queued = expectation(description: "real Process launch is queued")
        await owner.setNativeLaunchQueueForTesting(nativeQueue.queue) { queued.fulfill() }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("job-owner-no-launch-\(UUID())")
        ownedFiles.append(target)
        let run = tracked(Task {
            try await owner.run(JobCommandInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
                arguments: [target.path], kind: .command))
        })
        await fulfillment(of: [queued], timeout: 3)
        let boundary = JobOwnerReconciliationGate()
        releaseBoundaries.append { await boundary.release() }
        let held = await boundary.prepare()
        await owner.setReconciliationCheckpointForTesting { await boundary.hold() }
        let disableReturned = JobOwnerFlag()
        let disabling = tracked(Task {
            try await owner.setConfiguration(.init(enabled: false)); await disableReturned.set()
        })
        await fulfillment(of: [held], timeout: 3)
        // Release the actual native queue while deferred service.stop is held.
        // The synchronous owner cancellation must already have reached its
        // existing native observation flag; no command may reach Process.run.
        nativeQueue.release()
        await assertCancelled(run)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let returned = await disableReturned.value
        XCTAssertFalse(returned)
        let page = try await database.jobChronology(.init(), after: nil)
        XCTAssertEqual(page.events.map(\.observation.phase), [.gap, .started])
        XCTAssertEqual(page.events.first?.observation.gapReason, .observationCancelled)
        await boundary.release()
        try await disabling.value
        await owner.setReconciliationCheckpointForTesting(nil)
        try await owner.setConfiguration(.init(enabled: true))
        let later = try await owner.run(command("/usr/bin/false"))
        XCTAssertEqual(later.observation.terminationStatus, 1)
        XCTAssertNotEqual(later.observerSessionID, page.events.first?.observerSessionID)
    }

    func testDisableWhileExactFinalStartResolveIsHeldCannotLaunchAfterItReturns() async throws {
        let resolve = JobOwnerFinalResolveStore(database: database)
        owner = JobIntegration(store: resolve)
        bridge = ScreenEvidenceAdmissionCoordinator(store: database, jobs: owner)
        _ = try await enableAndStart()
        let owner = owner!
        releaseBoundaries.append { await resolve.release() }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("job-owner-resolve-no-launch-\(UUID())")
        ownedFiles.append(target)
        let heldResolve = await resolve.holdSecondStartResolve()
        let run = tracked(Task {
            try await owner.run(JobCommandInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
                arguments: [target.path], kind: .command))
        })
        await fulfillment(of: [heldResolve], timeout: 3)
        let boundary = JobOwnerReconciliationGate()
        releaseBoundaries.append { await boundary.release() }
        let heldReconcile = await boundary.prepare()
        await owner.setReconciliationCheckpointForTesting { await boundary.hold() }
        let disabling = tracked(Task { try await owner.setConfiguration(.init(enabled: false)) })
        await fulfillment(of: [heldReconcile], timeout: 3)
        await resolve.release()
        await assertCancelled(run)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let page = try await database.jobChronology(.init(), after: nil)
        XCTAssertEqual(page.events.map(\.observation.phase), [.gap, .started])
        XCTAssertFalse(page.events.contains { $0.observation.phase == .terminal })
        await boundary.release()
        try await disabling.value
        await owner.setReconciliationCheckpointForTesting(nil)
    }

    func testOwnedRequestMapCoalescesIdentityAndPreservesConflictAndCapacity() async throws {
        _ = try await enableAndStart()
        let owner = owner!
        let nativeQueue = JobOwnerNativeQueue()
        releaseBoundaries.append { nativeQueue.release() }
        let queued = expectation(description: "bounded real native invocations queued")
        queued.expectedFulfillmentCount = JobProducer.maximumOutstanding
        queued.assertForOverFulfill = true
        await owner.setNativeLaunchQueueForTesting(nativeQueue.queue) { queued.fulfill() }
        let requests = (0..<JobProducer.maximumOutstanding).map { _ in UUID() }
        let runs = requests.map { requestID in
            tracked(Task { try await owner.run(self.command("/usr/bin/true"), requestID: requestID) })
        }
        await fulfillment(of: [queued], timeout: 3)
        do { _ = try await owner.run(command("/usr/bin/false"), requestID: requests[0]); XCTFail("Mismatched invocation joined") }
        catch let error as JobEventError { XCTAssertEqual(error, .conflict) }
        do { _ = try await owner.run(command("/usr/bin/true")); XCTFail("Owner request bound was exceeded") }
        catch let error as JobEventError { XCTAssertEqual(error, .capacityExceeded) }
        let duplicate = tracked(Task { try await owner.run(self.command("/usr/bin/true"), requestID: requests[0]) })
        try await waitUntil { await owner.requestWaiterCountForTesting(requests[0]) == 2 }
        nativeQueue.release()
        var events: [JobEventSnapshot] = []
        for run in runs { events.append(try await run.value) }
        let joined = try await duplicate.value
        XCTAssertEqual(joined, events[0])
        XCTAssertTrue(events.allSatisfy { $0.observation.terminationStatus == 0 })
        let page = try await database.jobChronology(.init(), after: nil)
        XCTAssertEqual(page.events.count, JobProducer.maximumOutstanding * 2)
    }

    func testActualContainerCloseWaitsForOwnedJobCallbackBeforeClosingSQLite() async throws {
        let container = ServiceContainer(inMemory: true)
        containers.append(container)
        await container.setInitializationBoundaryForTesting { }
        try await container.initialize()
        let callbacks = callbacks
        let jobs = await container.jobs
        await jobs.setCommitHandlerForTesting { await callbacks.receive($0) }
        try await jobs.setConfiguration(.init(enabled: true))
        try await jobs.beginRecording(generation: UUID())
        let entered = await callbacks.hold(.terminal)
        let run = tracked(Task { try await jobs.run(self.command("/usr/bin/true")) })
        await fulfillment(of: [entered], timeout: 3)
        let committedValue = await callbacks.lastEvent
        let committed = try XCTUnwrap(committedValue)
        let reachedClose = JobOwnerFlag()
        await container.setBeforeDatabaseCloseForTesting {
            let page = try await container.database.jobChronology(.init(), after: nil)
            XCTAssertTrue(page.events.contains { $0.reference == committed.reference })
            await reachedClose.set()
        }
        let closing = tracked(Task { try await container.shutdown() })
        try await waitUntil { await jobs.isClosed }
        let closeReachedEarly = await reachedClose.value
        XCTAssertFalse(closeReachedEarly)
        await callbacks.release()
        try await closing.value
        await assertCancelled(run)
        let closeReached = await reachedClose.value
        XCTAssertTrue(closeReached)
        let connection = await container.database.getConnection()
        XCTAssertNil(connection)
        await assertInactive { try await jobs.run(self.command("/usr/bin/true")) }
    }
    #endif

    private func enableAndStart() async throws -> ScreenEvidencePolicyTransition {
        try await owner.setConfiguration(.init(enabled: true))
        let token = try await activate()
        try await owner.beginRecording(generation: UUID())
        return token
    }
    private func activate() async throws -> ScreenEvidencePolicyTransition {
        let token = try await bridge.beginSession(config: CaptureConfig())
        try await bridge.activate(token)
        return token
    }
    private func command(_ path: String, kind: JobKind = .command) -> JobCommandInvocation {
        .init(executableURL: URL(fileURLWithPath: path), kind: kind)
    }
    private func tracked<Value: Sendable>(_ task: Task<Value, Error>) -> Task<Value, Error> {
        joinedTasks.append { task.cancel(); _ = await task.result }
        return task
    }
    private func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5), clock: .continuous)
        }
        XCTFail("Owned lifecycle boundary did not arrive")
        throw JobEventError.unavailable
    }
    private func assertInactive(_ operation: () async throws -> JobEventSnapshot) async {
        do { _ = try await operation(); XCTFail("Inactive owner executed a command") }
        catch let error as JobEventError { XCTAssertTrue([.inactive, .stopped].contains(error)) }
        catch { XCTFail("Unexpected inactive error: \(type(of: error))") }
    }
    private func assertCancelled(_ task: Task<JobEventSnapshot, Error>) async {
        do { _ = try await task.value; XCTFail("Retired job owner returned a result") }
        catch is CancellationError { }
        catch let error as JobEventError { XCTAssertTrue([.inactive, .stopped].contains(error)) }
        catch { XCTFail("Unexpected cancellation error: \(type(of: error))") }
    }
    private func metricRows() async throws -> [String] {
        let connection = await database.getConnection(), db = try XCTUnwrap(connection)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT metadata FROM daily_metrics WHERE metricType='job_event'", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) { values.append(String(cString: raw)) }
        }
        return values
    }
}

private actor JobOwnerCallbackGate {
    private var target: JobEventPhase?
    private var entry: XCTestExpectation?
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var lastEvent: JobEventSnapshot?
    func hold(_ phase: JobEventPhase) -> XCTestExpectation {
        target = phase; lastEvent = nil
        let value = XCTestExpectation(description: "canonical \(phase.rawValue) callback held")
        entry = value; return value
    }
    func receive(_ event: JobEventSnapshot) async {
        guard event.observation.phase == target else { return }
        target = nil; lastEvent = event
        await withCheckedContinuation { waiting = $0; entry?.fulfill() }
    }
    func release() { target = nil; let old = waiting; waiting = nil; old?.resume() }
}
private actor JobOwnerMetricGate {
    private var target: JobIntegrationAction?
    private var entry: XCTestExpectation?
    private var waiting: CheckedContinuation<Void, Never>?
    func hold(_ action: JobIntegrationAction) -> XCTestExpectation {
        target = action
        let value = XCTestExpectation(description: "owner metric held")
        entry = value; return value
    }
    func receive(_ action: JobIntegrationAction) async {
        guard action == target else { return }
        target = nil
        await withCheckedContinuation { waiting = $0; entry?.fulfill() }
    }
    func release() { target = nil; let old = waiting; waiting = nil; old?.resume() }
}
private actor JobOwnerFlag { private(set) var value = false; func set() { value = true } }
private actor JobOwnerHolder { private(set) var value: JobIntegration?; func set(_ owner: JobIntegration) { value = owner } }

private extension DatabaseManager {
    func setJobStopMetricFailure(_ enabled: Bool) throws {
        let db = try XCTUnwrap(getConnection())
        let sql = enabled ? """
            CREATE TEMP TRIGGER authored_job_stop_failure BEFORE INSERT ON daily_metrics
            WHEN NEW.metricType='job_event' AND NEW.metadata LIKE '%"operation":"stopped"%'
            BEGIN SELECT RAISE(ABORT, 'authored stop diagnostic failure'); END;
            """ : "DROP TRIGGER IF EXISTS authored_job_stop_failure"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw JobEventError.unavailable }
    }
}

private actor JobOwnerReconciliationGate {
    private var entered: XCTestExpectation?
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false
    func prepare() -> XCTestExpectation {
        let value = XCTestExpectation(description: "owned reconciliation entered")
        entered = value; return value
    }
    func hold() async {
        guard !released else { return }
        await withCheckedContinuation { waiting = $0; entered?.fulfill() }
    }
    func release() { released = true; let old = waiting; waiting = nil; old?.resume() }
}

#if DEBUG
/// Owns only a test queue; no global queue is suspended. Idempotent teardown
/// releases it before joining any request so a failed assertion cannot hang.
private final class JobOwnerNativeQueue: @unchecked Sendable {
    let queue = DispatchQueue(label: "retrace.owned-job-launch-test", qos: .utility)
    private let lock = NSLock()
    private var released = false
    init() { queue.suspend() }
    func release() {
        let shouldResume = lock.withLock {
            guard !released else { return false }; released = true; return true
        }
        if shouldResume { queue.resume() }
    }
}

/// Suspends return of the second real canonical start resolution, after its
/// immutable result is read. Every mutation/read still uses private SQLite.
private actor JobOwnerFinalResolveStore: JobEventStoreProtocol {
    let database: DatabaseManager
    private var remaining = 0
    private var entered: XCTestExpectation?
    private var waiting: CheckedContinuation<Void, Never>?
    init(database: DatabaseManager) { self.database = database }
    func holdSecondStartResolve() -> XCTestExpectation {
        remaining = 2
        let value = XCTestExpectation(description: "last canonical start resolve held")
        entered = value; return value
    }
    func release() { remaining = 0; let old = waiting; waiting = nil; old?.resume() }
    func resolveJobEvidence(_ reference: JobEvidenceRef) async throws -> JobEvidenceResolution {
        let result = try await database.resolveJobEvidence(reference)
        if remaining > 0, case .available(let event, _) = result, event.observation.phase == .started {
            remaining -= 1
            if remaining == 0 { await withCheckedContinuation { waiting = $0; entered?.fulfill() } }
        }
        return result
    }
    func openJobWriter(admission: JobAdmission) async throws -> JobWriterSession { try await database.openJobWriter(admission: admission) }
    func appendJobStart(_ event: JobObservation, session: JobWriterSession) async throws -> JobBeginReceipt { try await database.appendJobStart(event, session: session) }
    func appendJobEnd(_ event: JobObservation, session: JobWriterSession) async throws -> JobEventSnapshot { try await database.appendJobEnd(event, session: session) }
    func closeJobWriter(_ session: JobWriterSession, reason: JobGapReason) async throws { try await database.closeJobWriter(session, reason: reason) }
    func jobChronology(_ query: JobChronologyQuery, after cursor: JobEventCursor?) async throws -> JobEventPage { try await database.jobChronology(query, after: cursor) }
    func validateJobRead(_ stamp: JobReadStamp) async throws -> Bool { try await database.validateJobRead(stamp) }
    func deleteJobRun(_ runID: UUID, storeID: UUID) async throws { try await database.deleteJobRun(runID, storeID: storeID) }
    func recordJobDiagnostic(_ diagnostic: JobDiagnostic) async throws { try await database.recordJobDiagnostic(diagnostic) }
}
#endif
