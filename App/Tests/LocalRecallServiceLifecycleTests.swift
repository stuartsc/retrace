import Database
import Foundation
import Search
import Shared
import SQLCipher
import XCTest
@testable import App

final class LocalRecallServiceLifecycleTests: XCTestCase {
    func testFailedCanonicalCancellationRetainsWriterUntilServiceShutdownRetryDrainsEverything() async throws {
        guard let path = ProcessInfo.processInfo.environment["RETRACE_MINILM_MODEL_PACKAGE"] else {
            throw XCTSkip("Explicit pinned native Core ML model required")
        }
        let services = ServiceContainer(inMemory: true)
        let db = await services.database
        let root = await services.storage.getStorageDirectory()
        let entered = expectation(description: "Native embedding finished; real V25 claim held")
        let gate = RecallServiceEmbeddingGate(entered: entered)
        let veto = RecallCancellationCommitVeto()
        addTeardownBlock {
            await gate.release()
            await db.removeRecallCancellationVeto()
            try await services.shutdown()
            try? FileManager.default.removeItem(at: root)
            _ = veto // Keep the hook context alive until the hooks are removed.
        }
        await services.setInitializationBoundaryForTesting { }
        try await services.initialize()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let segment = try await db.insertSegment(bundleID: "com.authored.recall-lifecycle", startDate: at,
            endDate: at, windowName: "Authored proposal", browserUrl: nil, type: 0)
        let frame = try await db.insertFrame(.init(id: .init(value: 0), timestamp: at,
            segmentID: .init(value: segment), frameIndexInSegment: 0,
            metadata: .init(appBundleID: "com.authored.recall-lifecycle", windowName: "Authored proposal")))
        _ = try await db.indexFrameText(mainText: "Cedar proposal amount 47000. Approval NOT GRANTED.",
            chromeText: nil, windowTitle: "Authored proposal", segmentId: segment, frameId: frame)
        try await services.localRecall.setRuntimeFactoryForTesting { configuration, record in
            RecallServiceHeldRuntime(native: LocalEmbeddingRuntime(configuration: configuration, recordMetric: record), gate: gate)
        }
        try await services.localRecall.configure(modelPackageURL: URL(fileURLWithPath: path))
        await fulfillment(of: [entered], timeout: 60)
        let initial = try await db.recallServiceState()
        XCTAssertEqual(initial.claimed, 1)
        XCTAssertEqual(initial.phase, "active")
        try await db.installRecallCancellationVeto(veto)

        let requested = expectation(description: "Service terminal shutdown requested")
        await services.setInitializationBoundaryForTesting(shutdownRequest: { requested.fulfill() }) { }
        let stopping = Task { try await services.shutdown() }
        addTeardownBlock {
            await gate.release()
            await db.removeRecallCancellationVeto()
            _ = await stopping.result
        }
        await fulfillment(of: [requested], timeout: 5)
        // The task may be between the service and controller actors. Wait for
        // the controller's actual terminal admission fence, never a fixed sleep.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await services.localRecall.isClosingForTesting()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let closed = await services.localRecall.isClosingForTesting()
        XCTAssertTrue(closed)
        let search = try await services.localRecall.search(.init(text: "authored pricing"))
        XCTAssertNil(search)
        do { try await services.localRecall.configure(modelPackageURL: nil); XCTFail("Shutdown must fence configuration") }
        catch { XCTAssertEqual(error as? LocalRecallControllerError, .shuttingDown) }
        await gate.release()
        do { try await stopping.value; XCTFail("Real failed cancellation commits must escape shutdown") }
        catch { }

        let retained = try await db.recallServiceState()
        let ready = await db.isReady()
        XCTAssertTrue(ready)
        XCTAssertEqual(retained.claimed, 1)
        XCTAssertEqual(retained.writer, initial.writer)
        XCTAssertEqual(retained.phase, "active", "Failed cleanup must retain the capability needed to cancel its exact claim")
        XCTAssertGreaterThanOrEqual(veto.failures, 2, "Exercise request cleanup and joined service teardown retry")
        do {
            try await services.localRecall.reopenAfterJoinedClose()
            XCTFail("A failed native cleanup cannot be treated as a joined rollback")
        } catch { XCTAssertEqual(error as? LocalRecallControllerError, .shuttingDown) }
        await db.removeRecallCancellationVeto()
        // Remove the one-shot observation before retry; only the real lifecycle
        // remains, with its terminal admission state unchanged.
        await services.setInitializationBoundaryForTesting { }
        let inspected = expectation(description: "Joined cleanup inspected before database close")
        await services.setBeforeDatabaseCloseForTesting {
            let final = try await db.recallServiceState()
            XCTAssertEqual(final.claimed, 0)
            XCTAssertEqual(final.cancelled, 1)
            let rows = try await db.recallServiceMetricRows()
            XCTAssertTrue(rows.contains { $0.contains("cleanup") && $0.contains("completed") })
            XCTAssertTrue(rows.contains { $0.contains("shutdown") && $0.contains("completed") })
            inspected.fulfill()
        }
        try await services.shutdown()
        await fulfillment(of: [inspected], timeout: 5)
        let finalReady = await db.isReady()
        XCTAssertFalse(finalReady)
    }
}

private actor RecallServiceEmbeddingGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(entered: XCTestExpectation) { self.entered = entered }
    func wait() async {
        entered.fulfill()
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor RecallServiceHeldRuntime: LocalEmbeddingRuntimeProtocol {
    let native: LocalEmbeddingRuntime
    let gate: RecallServiceEmbeddingGate
    init(native: LocalEmbeddingRuntime, gate: RecallServiceEmbeddingGate) { self.native = native; self.gate = gate }
    func prepare() async throws -> LocalEmbeddingDescriptor { try await native.prepare() }
    func embed(_ text: String) async throws -> LocalEmbeddingBatch {
        let result = try await native.embed(text)
        await gate.wait()
        try Task.checkCancellation()
        return result
    }
    func status() async -> LocalEmbeddingStatus { await native.status() }
    func close() async throws { try await native.close() }
}

private final class RecallCancellationCommitVeto: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    private var count = 0
    var failures: Int { lock.withLock { count } }
    func attemptChanged() { lock.withLock { changed = true } }
    func commit() -> Int32 {
        lock.withLock {
            defer { changed = false }
            guard changed else { return 0 }
            count += 1
            return 1
        }
    }
    func rollback() { lock.withLock { changed = false } }
}

private extension DatabaseManager {
    func installRecallCancellationVeto(_ value: RecallCancellationCommitVeto) throws {
        let db = try XCTUnwrap(getConnection())
        let context = Unmanaged.passUnretained(value).toOpaque()
        sqlite3_update_hook(db, { context, operation, _, table, _ in
            guard let context, operation == SQLITE_UPDATE, let table,
                  String(cString: table) == "semantic_recall_attempt" else { return }
            Unmanaged<RecallCancellationCommitVeto>.fromOpaque(context).takeUnretainedValue().attemptChanged()
        }, context)
        sqlite3_commit_hook(db, { context in
            guard let context else { return 0 }
            return Unmanaged<RecallCancellationCommitVeto>.fromOpaque(context).takeUnretainedValue().commit()
        }, context)
        sqlite3_rollback_hook(db, { context in
            guard let context else { return }
            Unmanaged<RecallCancellationCommitVeto>.fromOpaque(context).takeUnretainedValue().rollback()
        }, context)
    }
    func removeRecallCancellationVeto() {
        guard let db = getConnection() else { return }
        sqlite3_update_hook(db, nil, nil); sqlite3_commit_hook(db, nil, nil); sqlite3_rollback_hook(db, nil, nil)
    }
    func recallServiceMetricRows() throws -> [String] {
        try recallServiceStrings("SELECT metadata FROM daily_metrics WHERE metricType='semantic_recall'")
    }
    func recallServiceState() throws -> (claimed: Int, cancelled: Int, writer: String?, phase: String?) {
        let counts = try recallServiceStrings("SELECT COUNT(*) FROM semantic_recall_attempt WHERE status='claimed' UNION ALL SELECT COUNT(*) FROM semantic_recall_attempt WHERE status='cancelled'")
        let writer = try recallServiceStrings("SELECT writerID FROM screen_evidence_admission_state WHERE id=1").first
        let phase = try recallServiceStrings("SELECT phase FROM screen_evidence_admission_state WHERE id=1").first
        return (Int(counts[0]) ?? -1, Int(counts[1]) ?? -1, writer, phase)
    }
    func recallServiceStrings(_ sql: String) throws -> [String] {
        let db = try XCTUnwrap(getConnection())
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        var values: [String] = []
        while true {
            let state = sqlite3_step(statement)
            if state == SQLITE_DONE { return values }
            guard state == SQLITE_ROW else { throw CocoaError(.fileReadCorruptFile) }
            if let value = sqlite3_column_text(statement, 0) { values.append(String(cString: value)) }
        }
    }
}
