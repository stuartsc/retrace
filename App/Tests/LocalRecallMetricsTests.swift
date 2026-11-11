import Database
import Foundation
import Shared
import SQLCipher
import XCTest
@testable import App

final class LocalRecallMetricsTests: XCTestCase {
    func testBoundedBurstAndShutdownDrainPersistRealSQLiteRowsWithoutContent() async throws {
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        addTeardownBlock { try await database.close() }
        let inbox = LocalRecallMetricsInbox(capacity: 2)
        let metric = SemanticRecallMetric(operation: .query, outcome: .completed,
            windowCount: 12, inspectedCount: 3, partial: true, elapsedMilliseconds: 42)
        for _ in 0..<1_002 { inbox.send(metric) }
        inbox.finish()
        inbox.send(metric)
        await inbox.deliver { metadata in
            try await database.recordMetricEvent(metricType: .semanticRecall, metadata: metadata)
        }
        let rows = try await database.recallMetricsTestRows()
        XCTAssertEqual(rows.count, 3)
        let objects = try rows.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(objects[0]["operation"] as? String, "query")
        XCTAssertEqual(objects[0]["windows"] as? Int, 12)
        XCTAssertEqual(objects[2]["outcome"] as? String, "deliveryOverflow")
        XCTAssertEqual(objects[2]["count"] as? Int, 1_000)
        let allowed = Set(["scope", "operation", "outcome", "windows", "inspected", "partial", "elapsedMilliseconds", "count"])
        XCTAssertTrue(objects.allSatisfy { Set($0.keys).isSubset(of: allowed) })
        XCTAssertTrue(rows.allSatisfy { $0.utf8.count <= 1_024 })
    }

    func testInvalidNativeMeasurementsCannotWriteUnboundedOrNonfinitePayloads() async throws {
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        addTeardownBlock { try await database.close() }
        let inbox = LocalRecallMetricsInbox()
        inbox.send(LocalEmbeddingMetric(operation: .embedding, outcome: .failed,
            windowCount: Int.max, elapsedMilliseconds: .nan))
        inbox.send(SemanticRecallMetric(operation: .work, outcome: .failed,
            inspectedCount: -1, elapsedMilliseconds: .infinity))
        inbox.finish()
        await inbox.deliver { metadata in
            try await database.recordMetricEvent(metricType: .semanticRecall, metadata: metadata)
        }
        let rows = try await database.recallMetricsTestRows()
        XCTAssertEqual(rows, Array(repeating: "{\"outcome\":\"invalidMeasurement\"}", count: 2))
    }
}

private extension DatabaseManager {
    func recallMetricsTestRows() throws -> [String] {
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
