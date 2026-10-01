import Foundation
import Shared
import SQLCipher
import XCTest
@testable import Database

final class ResourceUsagePersistenceTests: XCTestCase {
    func testTelemetryRollbackCannotUndoConcurrentAudioWrite() async throws {
        let database = DatabaseManager(databasePath: "file:resource_lock_\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        addTeardownBlock { try await database.close() }
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let entered = expectation(description: "telemetry transaction entered")
        let writerStarted = expectation(description: "other audio writer started")
        let release = DispatchSemaphore(value: 0)
        let writerCompleted = DispatchSemaphore(value: 0)
        let timestamp = Date(timeIntervalSince1970: 1_790_000_000)
        let transaction = Task {
            try await database.recordResourceUsageMinuteForTesting(.init(timestamp: timestamp,
                cpu: .init(cpuPercent: 5, sampledSeconds: 60, elapsedSeconds: 60),
                systemCPUPercent: nil, physicalFootprintBytes: nil)) {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 10)
                throw CancellationError()
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        let mutex = try XCTUnwrap(sqlite3_db_mutex(try XCTUnwrap(connection)))
        let lockResult = sqlite3_mutex_try(mutex)
        if lockResult == SQLITE_OK { sqlite3_mutex_leave(mutex) }
        XCTAssertEqual(lockResult, SQLITE_BUSY, "The whole transaction must own the connection mutex")
        let writer = Task {
            writerStarted.fulfill()
            let id = try await queries.insertRawBatch(startTime: timestamp,
                endTime: timestamp.addingTimeInterval(10), source: .system,
                audioPath: "batch_recording-during-telemetry.m4a", audioSize: 100)
            writerCompleted.signal()
            return id
        }
        await fulfillment(of: [writerStarted], timeout: 5)
        // A successful insert must never belong to the telemetry transaction
        // that is about to roll back. It may complete only after lock release.
        let completedEarly = await Task.detached {
            writerCompleted.wait(timeout: .now() + 0.2) == .success
        }.value
        release.signal()
        do { try await transaction.value; XCTFail("Expected telemetry rollback") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        _ = try await writer.value
        XCTAssertFalse(completedEarly)
        let rows = try await queries.getUntranscribedBatches(limit: 2)
        XCTAssertEqual(rows.map(\.audioPath), ["batch_recording-during-telemetry.m4a"])
        XCTAssertEqual(try PipelineSQL.integers(XCTUnwrap(connection),
            "SELECT COUNT(*) FROM daily_metrics WHERE metricType='resource_usage'").first, 0)
    }

    func testTelemetryExpiryAndRowBoundPreserveOtherMetrics() async throws {
        let database = DatabaseManager(databasePath: "file:resource_\(UUID().uuidString)?mode=memory&cache=private")
        try await database.initialize()
        addTeardownBlock { try await database.close() }
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        try PipelineSQL.execute(db, "INSERT INTO daily_metrics(metricType,timestamp,metadata) VALUES('searches',0,'{}'),('resource_usage',0,'{}')")
        let timestamp = Date(timeIntervalSince1970: 1_790_000_000)
        let value = ResourceUsageMinute(timestamp: timestamp, cpu: .init(cpuPercent: 150, peakCPUPercent: 250,
            sampledSeconds: 45, elapsedSeconds: 60), systemCPUPercent: nil, physicalFootprintBytes: 8192)
        try await database.recordResourceUsageMinute(value)
        XCTAssertEqual(try PipelineSQL.integers(db, "SELECT COUNT(*) FROM daily_metrics WHERE metricType='searches'").first, 1)
        XCTAssertEqual(try PipelineSQL.integers(db, "SELECT COUNT(*) FROM daily_metrics WHERE metricType='resource_usage'").first, 1)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT metadata FROM daily_metrics WHERE metricType='resource_usage'", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let encoded = String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0)))
        XCTAssertEqual(try JSONDecoder().decode(ResourceUsageMinute.self, from: Data(encoded.utf8)), value)
        XCTAssertLessThan(encoded.utf8.count, 4096)
        try PipelineSQL.execute(db, """
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<43300)
            INSERT INTO daily_metrics(metricType,timestamp,metadata)
            SELECT 'resource_usage',1790000000000+x,'{}' FROM n
            """)
        try await database.recordResourceUsageMinute(value)
        XCTAssertEqual(try PipelineSQL.integers(db, "SELECT COUNT(*) FROM daily_metrics WHERE metricType='resource_usage'").first, 43200)
        XCTAssertEqual(try PipelineSQL.integers(db, "SELECT COUNT(*) FROM daily_metrics WHERE metricType='searches'").first, 1)
    }

    func testInvalidAggregateCannotWriteOrEraseTelemetry() async throws {
        let database = DatabaseManager(databasePath: "file:invalid_resource_\(UUID().uuidString)?mode=memory&cache=private")
        try await database.initialize()
        addTeardownBlock { try await database.close() }
        for date in [Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: 1e30)] {
            do {
                try await database.recordResourceUsageMinute(.init(timestamp: date, cpu: .init(),
                    systemCPUPercent: nil, physicalFootprintBytes: nil))
                XCTFail("Invalid timestamp must not reach SQLite or an integer conversion")
            } catch { }
        }
        do {
            try await database.recordResourceUsageMinute(.init(timestamp: Date(),
                cpu: .init(cpuPercent: -5, sampledSeconds: 61, elapsedSeconds: 60),
                systemCPUPercent: 101, physicalFootprintBytes: nil))
            XCTFail("Invalid counter units must be rejected")
        } catch { }
        let connection = await database.getConnection()
        XCTAssertEqual(try PipelineSQL.integers(XCTUnwrap(connection), "SELECT COUNT(*) FROM daily_metrics WHERE metricType='resource_usage'").first, 0)
    }
}
