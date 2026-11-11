import Foundation
import Database
import Storage
import Shared
import SQLCipher
import XCTest
@testable import App

final class LocalContextOwnershipTests: XCTestCase {
    func testContainerOwnsContextAndJoinsFinalMetricBeforeClosingItsPrivateWriter() async throws {
        let services = ServiceContainer(inMemory: true)
        let db = await services.database
        let root = await services.storage.getStorageDirectory()
        await services.setInitializationBoundaryForTesting { }
        try await services.initialize()
        let connection = await db.getConnection()
        let adapter = DataAdapter(retraceConnection: SQLiteConnection(db: try XCTUnwrap(connection)),
            retraceConfig: .init(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: db)
        try await adapter.initialize()
        let capture = await services.capture
        let evidence = ProgressiveRecallService(database: db, adapter: adapter,
            configuration: { await capture.getConfig() }, imageReader: { _ in throw EvidenceUnavailableReason.unsupported })
        addTeardownBlock {
            await adapter.shutdown()
            try await services.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        let owner = try await services.localContextService(evidence: evidence)
        let joined = try await services.localContextService(evidence: evidence)
        XCTAssertTrue(owner === joined)
        _ = try await owner.refresh(.init())
        let inspected = expectation(description: "Stopped owner and durable metric before database close")
        await services.setBeforeDatabaseCloseForTesting {
            do { _ = try await owner.current(); XCTFail("Context owner still admitted reads") }
            catch { XCTAssertEqual(error as? LocalContextError, .stopped) }
            let metadata = try await db.contextMetricMetadataForOwnershipTest()
            XCTAssertTrue(metadata.contains { $0.contains("stopped") })
            XCTAssertTrue(metadata.allSatisfy { !$0.contains("screenReferences") && !$0.contains(root.path) })
            inspected.fulfill()
        }
        try await services.shutdown()
        await fulfillment(of: [inspected], timeout: 5)
        do { _ = try await services.localContextService(evidence: evidence); XCTFail("Shutdown recreated context owner") }
        catch { XCTAssertEqual(error as? LocalContextError, .stopped) }
    }
}

private extension DatabaseManager {
    func contextMetricMetadataForOwnershipTest() throws -> [String] {
        let db = try XCTUnwrap(getConnection())
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT metadata FROM daily_metrics WHERE metricType='local_context' ORDER BY id", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { rows.append(String(cString: text)) }
        }
        return rows
    }
}
