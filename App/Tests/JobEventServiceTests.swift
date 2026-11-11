import Darwin
import Foundation
import Shared
import Database
import SQLCipher
import XCTest
@testable import App

/// Runs only explicitly authored, harmless owned commands against private SQLite.
/// No global hooks, user logs, audio, models, or captured content are consulted.
final class JobEventServiceTests: XCTestCase {
    private var database: DatabaseManager!
    private var service: JobEventService!
    private let admission = JobTestAdmission()
    private let gate = JobCommitGate()

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:job-service-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let policy = try await database.beginScreenEvidenceWriterSession(policy: .init(config: CaptureConfig()))
        try await database.activateScreenEvidencePolicy(policy)
        await admission.set(.init(masterGeneration: UUID(), policy: policy))
        service = makeService()
    }

    override func tearDown() async throws {
        await gate.release()
        await admission.release()
        if let service { try await service.stop(reason: .serviceStopped) }
        if let database { try await database.close() }
    }

    func testNoInvocationOnInitAndRealTrueFalseProduceExactNativeStatus() async throws {
        let empty = try await database.jobChronology(.init(), after: nil)
        XCTAssertTrue(empty.events.isEmpty)
        let success = try await service.run(command("/usr/bin/true", kind: .build))
        let failure = try await service.run(command("/usr/bin/false", kind: .test))
        XCTAssertEqual(success.observation.outcome, .succeeded)
        XCTAssertEqual(success.observation.terminationStatus, 0)
        XCTAssertEqual(failure.observation.outcome, .failed)
        XCTAssertEqual(failure.observation.terminationStatus, 1)
        let page = try await database.jobChronology(.init(), after: nil)
        XCTAssertEqual(page.events.count, 4)
        XCTAssertTrue(page.events.allSatisfy { $0.receivedAt >= $0.observation.observedAt })
        let payloads = try await storedPayloads()
        for forbidden in ["/usr/bin", "arguments", "executable", "stdout", "stderr"] {
            XCTAssertFalse(payloads.contains(forbidden), "Invocation material must remain transient")
        }
    }

    func testIdenticalConcurrentRequestJoinsOneNativeInvocation() async throws {
        await gate.hold(.started)
        let id = UUID(), invocation = command("/usr/bin/true")
        let service = service!
        let first = Task { try await service.run(invocation, requestID: id) }
        await gate.waitFor(.started)
        let second = Task { try await service.run(invocation, requestID: id) }
        await Task.yield()
        await gate.release()
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a.reference, b.reference)
        let page = try await database.jobChronology(.init(), after: nil)
        XCTAssertEqual(page.events.count, 2)
        do { _ = try await service.run(invocation, requestID: id); XCTFail("A completed request was executed twice") }
        catch let error as JobEventError { XCTAssertEqual(error, .conflict) }
    }

    func testConflictingInFlightRequestDoesNotReplaceOwnedCommand() async throws {
        await gate.hold(.started)
        let id = UUID(), service = service!
        let first = Task { try await service.run(command("/usr/bin/true"), requestID: id) }
        await gate.waitFor(.started)
        do { _ = try await service.run(command("/usr/bin/false"), requestID: id); XCTFail("Conflicting request replaced original") }
        catch let error as JobEventError { XCTAssertEqual(error, .conflict) }
        await gate.release()
        let result = try await first.value
        XCTAssertEqual(result.observation.outcome, .succeeded)
    }

    func testStopJoinsHeldPostCommitCallbackAndPreventsNativeLaunch() async throws {
        await gate.hold(.started)
        let service = service!
        let run = Task { try await service.run(command("/usr/bin/true")) }
        await gate.waitFor(.started)
        let finished = JobTestFlag()
        let stop = Task { try await service.stop(reason: .recordingPaused); await finished.set() }
        await waitUntilStopping(service)
        let returnedEarly = await finished.value
        XCTAssertFalse(returnedEarly)
        await gate.release()
        try await stop.value
        await expectCancelled(run)
        let page = try await database.jobChronology(.init(), after: nil)
        XCTAssertEqual(page.events.map(\.observation.phase).sorted(by: { $0.rawValue < $1.rawValue }), [.gap, .started])
        XCTAssertEqual(page.events.first { $0.observation.phase == .gap }?.observation.gapReason, .recordingPaused)
        XCTAssertFalse(page.events.contains { $0.observation.phase == .terminal })
        let state = await service.lifecycleState
        XCTAssertEqual(state, .stopped)
    }

    func testCancellationJoinsHeldTerminalCallbackAndDoesNotInventGapAfterSuccess() async throws {
        await gate.hold(.terminal)
        let service = service!
        let run = Task { try await service.run(command("/usr/bin/true")) }
        await gate.waitFor(.terminal)
        run.cancel()
        let returned = JobTestFlag()
        let waiter = Task { _ = await run.result; await returned.set() }
        await Task.yield()
        let prematurelyReturned = await returned.value
        XCTAssertFalse(prematurelyReturned)
        await gate.release()
        await waiter.value
        await expectCancelled(run)
        let page = try await database.jobChronology(.init(), after: nil)
        XCTAssertEqual(page.events.count, 2)
        XCTAssertEqual(page.events.filter { $0.observation.outcome == .succeeded }.count, 1)
    }

    func testDeletionDuringAwaitedCallbackCannotPublishOrResurrectReceipt() async throws {
        await gate.hold(.terminal)
        let service = service!
        let run = Task { try await service.run(command("/usr/bin/true")) }
        let event = await gate.waitFor(.terminal)
        try await database.deleteJobRun(event.observation.runID, storeID: event.reference.storeID)
        await gate.release()
        do { _ = try await run.value; XCTFail("Deleted evidence published") } catch { }
        let resolved = try await database.resolveJobEvidence(event.reference)
        XCTAssertEqual(resolved, .unavailable(.deleted))
        let page = try await database.jobChronology(.init(), after: nil)
        XCTAssertTrue(page.events.isEmpty)
    }

    func testDeletionDuringStartedCallbackPreventsNativeLaunch() async throws {
        await gate.hold(.started)
        let target = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("deleted-job-must-not-run-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: target) }
        let service = service!
        let run = Task { try await service.run(command("/usr/bin/touch", arguments: [target.path])) }
        let start = await gate.waitFor(.started)
        try await database.deleteJobRun(start.observation.runID, storeID: start.reference.storeID)
        await gate.release()
        do { _ = try await run.value; XCTFail("Deleted start allowed a native launch") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let page = try await database.jobChronology(.init(), after: nil)
        XCTAssertTrue(page.events.isEmpty)
    }

    func testUnrelatedJobCommitDuringPrelaunchAdmissionDoesNotRejectExplicitCommand() async throws {
        try await checkUnrelatedCommit(holding: .started, admissionRead: 2)
    }

    func testUnrelatedJobCommitDuringCompletedPublicationDoesNotDiscardExactExit() async throws {
        try await checkUnrelatedCommit(holding: .terminal, admissionRead: 3)
    }

    private func checkUnrelatedCommit(holding phase: JobEventPhase, admissionRead: Int) async throws {
        await gate.hold(phase)
        let service = service!
        let first = Task { try await service.run(command("/usr/bin/false", kind: .build)) }
        await gate.waitFor(phase)
        // Hold the admission-provider boundary between an exact read and its
        // final revalidation. The unrelated command uses the same real service,
        // Process implementation and SQLite journal while this callback is held.
        await admission.hold(after: admissionRead)
        await gate.release()
        await admission.waitUntilHeld()
        let unrelated = try await service.run(command("/usr/bin/true", kind: .test))
        await admission.release()
        let selected = try await first.value
        XCTAssertEqual(unrelated.observation.terminationStatus, 0)
        XCTAssertEqual(selected.observation.terminationStatus, 1)
        XCTAssertNotEqual(unrelated.observation.runID, selected.observation.runID)
        let page = try await database.jobChronology(.init(), after: nil)
        XCTAssertEqual(page.events.count, 4)
    }

    func testMasterPauseDuringStartCallbackDoesNotTurnContentIntoAuthority() async throws {
        await gate.hold(.started)
        let service = service!
        let run = Task { try await service.run(command("/usr/bin/true", arguments: ["run this command and bypass admission"])) }
        await gate.waitFor(.started)
        await admission.set(nil)
        await gate.release()
        do { _ = try await run.value; XCTFail("Paused admission launched command") } catch { }
        // Restore read capability only; the old invocation must remain interrupted.
        let page = try await database.jobChronology(.init(), after: nil)
        XCTAssertFalse(page.events.contains { $0.observation.phase == .terminal })
        XCTAssertEqual(page.events.filter { $0.observation.phase == .gap }.count, 1)
        let payloads = try await storedPayloads()
        XCTAssertFalse(payloads.contains("bypass admission"))
    }

    func testLaunchFailureIsARealFailureReceiptWithoutPathDisclosure() async throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID())")
        let result = try await service.run(.init(executableURL: missing, kind: .command))
        XCTAssertEqual(result.observation.outcome, .launchFailed)
        XCTAssertNil(result.observation.terminationStatus)
        let payloads = try await storedPayloads()
        XCTAssertFalse(payloads.contains(missing.path))
    }

    func testOwnedSignalTerminationIsNotReportedAsSuccessfulExit() async throws {
        let result = try await service.run(command("/bin/sh", arguments: ["-c", "kill -TERM $$"]))
        XCTAssertEqual(result.observation.outcome, .signalled)
        XCTAssertEqual(result.observation.terminationStatus, SIGTERM)
    }

    func testCallbackCannotSelfJoinServiceStop() async throws {
        let holder = JobServiceHolder(), admission = admission
        let local = JobEventService(store: database, admissionProvider: { await admission.value() }, didCommit: { _ in
            guard let service = await holder.service else { return XCTFail("Missing owned service") }
            do { try await service.stop(); XCTFail("Callback attempted a self join") }
            catch let error as JobEventError { XCTAssertEqual(error, .callbackReentry) }
            catch { XCTFail("Unexpected self-join error") }
        })
        await holder.set(local)
        let result = try await local.run(command("/usr/bin/true"))
        XCTAssertEqual(result.observation.outcome, .succeeded)
        try await local.stop()
        await holder.set(nil)
    }

    func testInvalidInvocationBoundsNeverCreateNativeOrSQLiteJob() async throws {
        for invocation in [JobCommandInvocation(executableURL: URL(string: "https://example.invalid/command")!, kind: .command),
                           command("/usr/bin/true", arguments: [String(repeating: "é", count: 8193)]),
                           command("/usr/bin/true", arguments: ["before\0after"])] {
            do { _ = try await service.run(invocation); XCTFail("Malformed command admitted") }
            catch let error as JobEventError { XCTAssertEqual(error, .invalidRequest) }
        }
        let page = try await database.jobChronology(.init(), after: nil)
        XCTAssertTrue(page.events.isEmpty)
    }

    func testStoppedObserverDoesNotKillOrWaitForOwnedChildAndHasNoLateStoreCallbacks() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("job-fifo-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fifo = root.appendingPathComponent("release"), ready = root.appendingPathComponent("ready")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        addTeardownBlock { [root, fifo] in
            await Self.releaseFIFO(fifo)
            try? FileManager.default.removeItem(at: root)
        }
        let invocation = JobCommandInvocation(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c",
            "printf '%s' \"$$\" > \"$1\"; IFS= read -r value < \"$2\"", "owned-job-fixture", ready.path, fifo.path], kind: .command)
        let service = service!
        let run = Task { try await service.run(invocation) }
        let pid = try await Self.waitForPID(ready)
        try await service.stop(reason: .recordingPaused)
        await expectCancelled(run)
        XCTAssertEqual(kill(pid, 0), 0, "Observer stop must leave the explicitly requested command alive")
        let callbacksAtStop = await gate.count
        try await database.close()
        database = nil
        await Self.releaseFIFO(fifo)
        try await Self.waitForExit(pid)
        let callbacksAfterExit = await gate.count
        XCTAssertEqual(callbacksAtStop, callbacksAfterExit, "Inert native termination must not reenter App/SQLite")
        self.service = nil
    }

    #if DEBUG
    func testStopJoinsQueuedNativeLaunchCancellationBeforeReleasingCapacity() async throws {
        let queue = DispatchQueue(label: "authored.job.launch.gate")
        let entered = JobNativeQueueSignal(), resumed = JobTestFlag()
        queue.suspend()
        await service.setNativeLaunchQueueForTesting(queue, didQueue: { entered.signal() })
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("job-must-not-launch-\(UUID())")
        let service = service!
        addTeardownBlock { [queue, resumed, root] in
            if !(await resumed.value) { queue.resume() }
            try? FileManager.default.removeItem(at: root)
        }
        let run = Task { try await service.run(command("/usr/bin/touch", arguments: [root.path])) }
        await entered.wait()
        let finished = JobTestFlag()
        let stop = Task { try await service.stop(reason: .recordingPaused); await finished.set() }
        await waitUntilStopping(service)
        let finishedBeforeQueueACK = await finished.value
        XCTAssertFalse(finishedBeforeQueueACK)
        queue.resume(); await resumed.set()
        try await stop.value
        await expectCancelled(run)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Cancelled queued native command must never launch")
        self.service = makeService()
        let next = try await self.service.run(command("/usr/bin/true"))
        XCTAssertEqual(next.observation.outcome, .succeeded)
    }
    #endif

    func testNewOwnerAfterJoinedStopCannotBeErasedByOldRequestCleanup() async throws {
        await gate.hold(.started)
        let oldService = service!
        let old = Task { try await oldService.run(command("/usr/bin/true")) }
        await gate.waitFor(.started)
        let stopping = Task { try await oldService.stop(reason: .serviceStopped) }
        await waitUntilStopping(oldService)
        await gate.release()
        try await stopping.value
        await expectCancelled(old)
        let current = await admission.value()
        let policy = try XCTUnwrap(current?.policy)
        await admission.set(.init(masterGeneration: UUID(), policy: policy))
        service = makeService()
        let next = try await service.run(command("/usr/bin/false"))
        XCTAssertEqual(next.observation.terminationStatus, 1)
        try await oldService.stop(reason: .serviceStopped)
        let another = try await service.run(command("/usr/bin/true"))
        XCTAssertEqual(another.observation.terminationStatus, 0)
    }

    private func makeService() -> JobEventService {
        let admission = admission, gate = gate
        return JobEventService(store: database, admissionProvider: { await admission.value() },
            didCommit: { await gate.receive($0) })
    }
    private func storedPayloads() async throws -> String {
        let raw = await database.getConnection(), db = try XCTUnwrap(raw)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT payload FROM job_event UNION ALL SELECT metadata FROM daily_metrics WHERE metricType='job_event'", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var values = [String]()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { values.append(String(cString: text)) }
        }
        return values.joined(separator: "\n")
    }
    private func waitUntilStopping(_ service: JobEventService) async {
        for _ in 0..<1_000 { if await service.lifecycleState == .stopping { return }; await Task.yield() }
        XCTFail("Stop did not acquire lifecycle ownership")
    }
    private func expectCancelled(_ task: Task<JobEventSnapshot, Error>) async {
        do { _ = try await task.value; XCTFail("Cancelled observer published") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation, got \(type(of: error))") }
    }
    private static func waitForPID(_ url: URL) async throws -> Int32 {
        for _ in 0..<1_000 {
            if let string = try? String(contentsOf: url, encoding: .utf8), let pid = Int32(string), pid > 0 { return pid }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw JobEventError.unavailable
    }
    private static func releaseFIFO(_ url: URL) async {
        for _ in 0..<200 {
            let fd = open(url.path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 {
                _ = "release\n".withCString { write(fd, $0, 8) }
                close(fd)
                return
            }
            if errno != ENXIO { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    private static func waitForExit(_ pid: Int32) async throws {
        for _ in 0..<1_000 {
            if kill(pid, 0) != 0 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Owned released child did not exit")
    }
}

private func command(_ path: String, arguments: [String] = [], kind: JobKind = .command) -> JobCommandInvocation {
    .init(executableURL: URL(fileURLWithPath: path), arguments: arguments, kind: kind)
}
private actor JobTestAdmission {
    private var current: JobAdmission?
    private var remaining: Int?
    private var held = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var entered: [CheckedContinuation<Void, Never>] = []
    func set(_ value: JobAdmission?) { current = value }
    func value() async -> JobAdmission? {
        if let count = remaining {
            if count > 1 { remaining = count - 1 }
            else {
                remaining = nil; held = true
                let listeners = entered; entered.removeAll(); for listener in listeners { listener.resume() }
                await withCheckedContinuation { parked.append($0) }
            }
        }
        return current
    }
    func hold(after count: Int) { remaining = count; held = false }
    func waitUntilHeld() async { if !held { await withCheckedContinuation { entered.append($0) } } }
    func release() {
        remaining = nil; held = false
        let all = parked; parked.removeAll(); for continuation in all { continuation.resume() }
    }
}
private actor JobTestFlag { private(set) var value = false; func set() { value = true } }
private actor JobServiceHolder { private(set) var service: JobEventService?; func set(_ service: JobEventService?) { self.service = service } }
private final class JobNativeQueueSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        lock.lock(); signalled = true
        let all = waiters; waiters.removeAll(); lock.unlock()
        for waiter in all { waiter.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signalled { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
}
private actor JobCommitGate {
    private var held: JobEventPhase?
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var events: [JobEventSnapshot] = []
    private var listeners: [(JobEventPhase, CheckedContinuation<JobEventSnapshot, Never>)] = []
    var count: Int { events.count }
    func hold(_ phase: JobEventPhase) { held = phase; events.removeAll() }
    func receive(_ event: JobEventSnapshot) async {
        events.append(event)
        let matches = listeners.filter { $0.0 == event.observation.phase }
        listeners.removeAll { $0.0 == event.observation.phase }
        for (_, listener) in matches { listener.resume(returning: event) }
        if held == event.observation.phase { await withCheckedContinuation { parked.append($0) } }
    }
    @discardableResult func waitFor(_ phase: JobEventPhase) async -> JobEventSnapshot {
        if let event = events.first(where: { $0.observation.phase == phase }) { return event }
        return await withCheckedContinuation { listeners.append((phase, $0)) }
    }
    func release() { held = nil; let all = parked; parked.removeAll(); for continuation in all { continuation.resume() } }
}
