import Foundation
import SQLCipher
import Shared
import Database
import XCTest
@testable import App

final class CaptureTextMetricsTests: XCTestCase {
    func testBoundedProducerBurstDrainsIntoSQLiteBeforeClosingAndReportsOverflow() async throws {
        let database = DatabaseManager(databasePath: "file:capture-text-metrics-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let inbox = CaptureTextMetricsInbox(capacity: 2)
        let event = CaptureTextOutcome(backend: .screenCaptureKitCandidate, availability: .partial,
            reasons: [.unsupportedRange], visitedNodes: 15, retainedRuns: 2, retainedUTF16Units: 34,
            preReadMilliseconds: 12, postReadMilliseconds: 8)
        XCTAssertTrue(inbox.send(event))
        XCTAssertTrue(inbox.send(event))
        for _ in 0..<1_000 { XCTAssertFalse(inbox.send(event)) }
        inbox.finish()
        let delivery = Task {
            for await snapshot in inbox.snapshots {
                await CaptureTextMetrics.persist(snapshot) { metadata in
                    try await database.recordMetricEvent(metricType: .captureText, metadata: metadata)
                }
            }
        }
        await delivery.value
        XCTAssertFalse(inbox.send(event), "A stopped producer must not restart metric delivery")
        let rows = try await database.captureTextMetricRows()
        XCTAssertEqual(rows.count, 3)
        let objects = try rows.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(objects[0]["availability"] as? String, "partial")
        XCTAssertEqual(objects[0]["retainedUTF16Units"] as? Int, 34)
        XCTAssertEqual(objects[2]["outcome"] as? String, "deliveryOverflow")
        XCTAssertEqual(objects[2]["count"] as? Int, 1_000)
        let allowed = Set(["backend", "availability", "reasons", "visitedNodes", "retainedRuns", "retainedUTF16Units",
                           "preReadMilliseconds", "postReadMilliseconds", "outcome", "count"])
        XCTAssertTrue(objects.allSatisfy { Set($0.keys).isSubset(of: allowed) })
        try await database.close()
    }

    func testInvalidMeasurementDoesNotEmitNonfiniteOrUnboundedJSON() async throws {
        let database = DatabaseManager(databasePath: "file:capture-text-invalid-metrics-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let inbox = CaptureTextMetricsInbox()
        inbox.send(CaptureTextOutcome(backend: .legacy, availability: .available, reasons: [],
            visitedNodes: -1, retainedRuns: Int.max, retainedUTF16Units: Int.max,
            preReadMilliseconds: .nan, postReadMilliseconds: .infinity))
        inbox.finish()
        for await snapshot in inbox.snapshots {
            await CaptureTextMetrics.persist(snapshot) { metadata in
                try await database.recordMetricEvent(metricType: .captureText, metadata: metadata)
            }
        }
        let rows = try await database.captureTextMetricRows()
        XCTAssertEqual(rows, ["{\"outcome\":\"invalidMeasurement\"}"])
        try await database.close()
    }
}

private extension DatabaseManager {
    func captureTextMetricRows() throws -> [String] {
        let db = try XCTUnwrap(getConnection())
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT metadata FROM daily_metrics WHERE metricType='capture_text' ORDER BY rowid", -1,
                                &statement, nil) == SQLITE_OK else { throw CaptureMetricTestError.query }
        var result: [String] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { throw CaptureMetricTestError.query }
            result.append(String(cString: raw))
        }
    }
}

private enum CaptureMetricTestError: Error { case query }
