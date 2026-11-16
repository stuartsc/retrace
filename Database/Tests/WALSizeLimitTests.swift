import Foundation
import SQLCipher
import XCTest
@testable import Database

/// The WAL must shrink back after a checkpoint instead of keeping its peak size.
final class WALSizeLimitTests: XCTestCase {
    func testFileDatabaseAppliesJournalSizeLimit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wal-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = DatabaseManager(databasePath: dir.appendingPathComponent("retrace.db").path)
        try await database.initialize()
        let opened = await database.getConnection()
        let connection = try XCTUnwrap(opened)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, "PRAGMA journal_size_limit;", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(statement, 0), 67_108_864)
        try await database.close()
    }
}
