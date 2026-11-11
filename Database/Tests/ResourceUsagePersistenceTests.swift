import Foundation
import Shared
import SQLCipher
import XCTest
@testable import Database

final class ResourceUsagePersistenceTests: XCTestCase {
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
