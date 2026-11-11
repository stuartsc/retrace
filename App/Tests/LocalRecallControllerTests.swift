import Database
import Foundation
import Search
import Shared
import SQLCipher
import XCTest
@testable import App

final class LocalRecallControllerTests: XCTestCase {
    private var database: DatabaseManager!
    private var root: URL!
    private var controller: LocalRecallController!
    private var preparationGates: [LocalRecallPrepareGate] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalRecallOwner-\(UUID())")
        database = DatabaseManager()
        try await database.initialize()
        let owner = try await database.beginScreenEvidenceWriterSession(policy: .init(config: CaptureConfig()))
        try await database.activateScreenEvidencePolicy(owner)
        controller = LocalRecallController(database: database, cacheRoot: root)
    }

    override func tearDown() async throws {
        for gate in preparationGates { await gate.release() }
        preparationGates.removeAll()
        try await controller?.shutdown()
        try await database?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testDisabledSearchNeverCreatesAModelCacheOrChangesTheIndex() async throws {
        let before = try await database.localRecallCounts()
        let result = try await controller.search(.init(text: "authored pricing discussion"))
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let after = try await database.localRecallCounts()
        XCTAssertEqual(before.indexes, after.indexes)
        XCTAssertEqual(before.metrics, after.metrics)
    }

    func testInternalRollbackReopenLeavesLocalRecallDisabledWithoutStartingWork() async throws {
        let before = try await database.localRecallCounts()
        try await controller.shutdown()
        do { try await controller.configure(modelPackageURL: nil); XCTFail("Public shutdown remains terminal") }
        catch { XCTAssertEqual(error as? LocalRecallControllerError, .shuttingDown) }

        try await controller.reopenAfterJoinedClose()
        let state = await controller.snapshot()
        XCTAssertNil(state.modelPackageURL)
        XCTAssertNil(state.engine)
        XCTAssertNil(state.failure)
        XCTAssertNil(state.lastSearchWasPartial)
        let result = try await controller.search(.init(text: "authored pricing discussion"))
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let after = try await database.localRecallCounts()
        XCTAssertEqual(before.indexes, after.indexes)
        XCTAssertEqual(before.metrics, after.metrics)
        try await controller.configure(modelPackageURL: nil)
        try await controller.shutdown()
        do { try await controller.configure(modelPackageURL: nil); XCTFail("The next public shutdown is terminal too") }
        catch { XCTAssertEqual(error as? LocalRecallControllerError, .shuttingDown) }
    }

    func testCancelledInternalRollbackReopenKeepsLocalRecallClosed() async throws {
        try await controller.shutdown()
        let controller = controller!
        let reopening = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await controller.reopenAfterJoinedClose()
        }
        do { try await reopening.value; XCTFail("Cancelled initialization must not reopen local recall") }
        catch is CancellationError { }
        do { try await controller.configure(modelPackageURL: nil); XCTFail("Cancelled reopen cleared the shutdown fence") }
        catch { XCTAssertEqual(error as? LocalRecallControllerError, .shuttingDown) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    #if DEBUG
    func testInternalReopenDoesNotReviveConfigurationQueuedBeforeShutdown() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = root.appendingPathComponent("Invalid.mlpackage")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let preparationEntered = expectation(description: "Owned native preparation entered")
        let preparation = LocalRecallPrepareGate(entered: preparationEntered)
        let waiterEntered = expectation(description: "Second configuration queued behind preparation")
        let waiter = LocalRecallPrepareGate(entered: waiterEntered)
        preparationGates.append(contentsOf: [preparation, waiter])
        controller = LocalRecallController(database: database, cacheRoot: root, makeRuntime: { configuration, record in
            DeferredLocalEmbeddingRuntime(native: LocalEmbeddingRuntime(configuration: configuration, recordMetric: record),
                                          gate: preparation)
        })
        await controller.setConfigurationWaitCheckpointForTesting { await waiter.wait() }
        let controller = controller!
        let opening = Task { try await controller.configure(modelPackageURL: model) }
        await fulfillment(of: [preparationEntered], timeout: 5)
        let queued = Task { try await controller.configure(modelPackageURL: nil) }
        addTeardownBlock {
            await preparation.release(); await waiter.release()
            _ = await opening.result; _ = await queued.result
        }
        await fulfillment(of: [waiterEntered], timeout: 5)
        let stopping = Task { try await controller.shutdown() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await controller.isClosingForTesting()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let closed = await controller.isClosingForTesting()
        XCTAssertTrue(closed)
        await preparation.release()
        _ = await opening.result
        try await stopping.value
        try await controller.reopenAfterJoinedClose()
        await waiter.release()
        do { try await queued.value; XCTFail("An earlier configuration cannot cross an internal reopen") }
        catch { XCTAssertEqual(error as? LocalRecallControllerError, .shuttingDown) }
        await controller.setConfigurationWaitCheckpointForTesting(nil)
        try await controller.configure(modelPackageURL: nil)
        let state = await controller.snapshot()
        XCTAssertNil(state.modelPackageURL)
        XCTAssertNil(state.engine)
    }
    #endif

    func testInvalidExplicitModelFailsClosedAndMetricsFinishBeforeShutdownReturns() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = root.appendingPathComponent("Invalid.mlpackage")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        do {
            try await controller.configure(modelPackageURL: model)
            XCTFail("A user-selected folder must still pass pinned artifact verification")
        } catch { }
        let state = await controller.snapshot()
        XCTAssertNil(state.modelPackageURL)
        XCTAssertNotNil(state.failure)
        let unavailable = try await controller.search(.init(text: "INV-8042"))
        XCTAssertNil(unavailable)
        try await controller.shutdown()
        let rows = try await database.localRecallMetricRows()
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { !$0.contains(model.path) && !$0.contains("INV-8042") })
        let baseline = rows.count
        do { try await controller.configure(modelPackageURL: model); XCTFail("Shutdown is terminal") }
        catch { }
        let final = try await database.localRecallMetricRows()
        XCTAssertEqual(final.count, baseline, "Successful shutdown must join all metric producers")

        try await controller.reopenAfterJoinedClose()
        let reopened = await controller.snapshot()
        XCTAssertNil(reopened.modelPackageURL)
        XCTAssertNil(reopened.engine)
        XCTAssertNil(reopened.failure)
        let afterReopen = try await database.localRecallMetricRows()
        XCTAssertEqual(afterReopen.count, baseline, "An internal retry must not start a model or metric worker")
        try await controller.configure(modelPackageURL: nil)
    }

    func testShutdownJoinsALateActualCoreMLPreparationAndRemovesPrivateModelCopy() async throws {
        guard let path = ProcessInfo.processInfo.environment["RETRACE_MINILM_MODEL_PACKAGE"] else {
            throw XCTSkip("Explicit pinned native model package required")
        }
        let entered = expectation(description: "Actual Core ML prepared; acknowledgement held")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "First enable must create its private cache parent")
        let gate = LocalRecallPrepareGate(entered: entered)
        preparationGates.append(gate)
        addTeardownBlock { await gate.release() }
        controller = LocalRecallController(database: database, cacheRoot: root, makeRuntime: { configuration, record in
            HeldLocalEmbeddingRuntime(native: LocalEmbeddingRuntime(configuration: configuration, recordMetric: record), gate: gate)
        })
        let opening = Task { try await controller.configure(modelPackageURL: URL(fileURLWithPath: path)) }
        await fulfillment(of: [entered], timeout: 60)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let premature = expectation(description: "Shutdown cannot outlive a native owner")
        premature.isInverted = true
        let stopping = Task { try await controller.shutdown(); premature.fulfill() }
        await fulfillment(of: [premature], timeout: 0.05)
        let reopenedEarly = expectation(description: "Internal retry must join the native owner too")
        reopenedEarly.isInverted = true
        let reopening = Task { try await controller.reopenAfterJoinedClose(); reopenedEarly.fulfill() }
        await fulfillment(of: [reopenedEarly], timeout: 0.05)
        await gate.release()
        _ = await opening.result
        try await stopping.value
        try await reopening.value
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(files.isEmpty, "Joined native close must remove the private model copies")
        let rows = try await database.localRecallMetricRows()
        XCTAssertTrue(rows.contains { $0.contains("cleanup") && $0.contains("completed") })
        let state = await controller.snapshot()
        XCTAssertNil(state.modelPackageURL)
        XCTAssertNil(state.engine)
        try await controller.configure(modelPackageURL: nil)
    }
}

private actor LocalRecallPrepareGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(entered: XCTestExpectation) { self.entered = entered }
    func wait() async {
        entered.fulfill()
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor HeldLocalEmbeddingRuntime: LocalEmbeddingRuntimeProtocol {
    let native: LocalEmbeddingRuntime
    let gate: LocalRecallPrepareGate
    init(native: LocalEmbeddingRuntime, gate: LocalRecallPrepareGate) { self.native = native; self.gate = gate }
    func prepare() async throws -> LocalEmbeddingDescriptor {
        let descriptor = try await native.prepare()
        await gate.wait()
        return descriptor
    }
    func embed(_ text: String) async throws -> LocalEmbeddingBatch { try await native.embed(text) }
    func status() async -> LocalEmbeddingStatus { await native.status() }
    func close() async throws { try await native.close() }
}

/// Scheduling alone is held; the configured runtime and artifact validation stay native.
private actor DeferredLocalEmbeddingRuntime: LocalEmbeddingRuntimeProtocol {
    let native: LocalEmbeddingRuntime
    let gate: LocalRecallPrepareGate
    init(native: LocalEmbeddingRuntime, gate: LocalRecallPrepareGate) { self.native = native; self.gate = gate }
    func prepare() async throws -> LocalEmbeddingDescriptor {
        await gate.wait()
        return try await native.prepare()
    }
    func embed(_ text: String) async throws -> LocalEmbeddingBatch { try await native.embed(text) }
    func status() async -> LocalEmbeddingStatus { await native.status() }
    func close() async throws { try await native.close() }
}

private extension DatabaseManager {
    func localRecallCounts() throws -> (indexes: Int, metrics: Int) {
        let db = try XCTUnwrap(getConnection())
        func count(_ table: String) throws -> Int {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadCorruptFile) }
            return Int(sqlite3_column_int64(statement, 0))
        }
        return try (count("semantic_recall_index"), count("daily_metrics"))
    }
    func localRecallMetricRows() throws -> [String] {
        let db = try XCTUnwrap(getConnection())
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT metadata FROM daily_metrics WHERE metricType='semantic_recall' ORDER BY rowid",
                                -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        var result: [String] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { throw CocoaError(.fileReadCorruptFile) }
            result.append(String(cString: raw))
        }
    }
}
