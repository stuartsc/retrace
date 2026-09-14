import DatabaseTestSupport
import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database

final class SearchRevisionCompatibilityTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appendingPathComponent("native.sqlite").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecallCompatibility-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testDefensiveReadOnlyConnectionCanQueryMigratedSchemaAndFTS() async throws {
        let writer = try openWriter()
        defer { sqlite3_close_v2(writer) }
        try await MigrationRunner(db: writer).runMigrations()
        try execute(writer, "INSERT INTO searchRanking(rowid,text,title) VALUES(1,'contract 42000','authored fixture')")

        let reader = try defensiveReader()
        defer { sqlite3_close_v2(reader) }
        XCTAssertEqual(try scalar(reader, "SELECT MAX(version) FROM schema_migrations"), 21)
        XCTAssertEqual(try scalar(reader, "SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH '42000'"), 1)
        XCTAssertEqual(try scalar(reader, "SELECT COUNT(*) FROM sqlite_schema WHERE type='trigger' AND tbl_name='searchRanking_content'"), 0)
    }

    func testTwoManagedWritersFenceInsertSameLengthUpdateDeleteAndRollback() async throws {
        let first = try openWriter()
        defer { sqlite3_close_v2(first) }
        try await MigrationRunner(db: first).runMigrations()
        let second = try openWriter()
        defer { sqlite3_close_v2(second) }
        try await MigrationRunner(db: second).runMigrations()
        let reader = try defensiveReader()
        defer { sqlite3_close_v2(reader) }

        for (index, writer) in [first, second].enumerated() {
            let id = index + 1
            var committed = try revision(reader)
            try execute(writer, "BEGIN IMMEDIATE")
            try execute(writer, "INSERT INTO searchRanking(rowid,text,title) VALUES(\(id),'contract 42000','authored fixture')")
            XCTAssertGreaterThan(try revision(writer), committed)
            XCTAssertEqual(try revision(reader), committed)
            try execute(writer, "COMMIT")
            XCTAssertGreaterThan(try revision(reader), committed)
            committed = try revision(reader)

            try execute(writer, "BEGIN IMMEDIATE")
            try execute(writer, "UPDATE searchRanking SET text='contract 47000' WHERE rowid=\(id)")
            XCTAssertGreaterThan(try revision(writer), committed)
            XCTAssertEqual(try revision(reader), committed)
            try execute(writer, "ROLLBACK")
            XCTAssertEqual(try revision(writer), committed)
            XCTAssertEqual(try revision(reader), committed)
            XCTAssertEqual(try scalar(reader, "SELECT COUNT(*) FROM searchRanking WHERE rowid=\(id) AND searchRanking MATCH '42000'"), 1)

            try execute(writer, "UPDATE searchRanking SET text='contract 47000' WHERE rowid=\(id)")
            XCTAssertGreaterThan(try revision(reader), committed)
            committed = try revision(reader)
            XCTAssertEqual(try scalar(reader, "SELECT COUNT(*) FROM searchRanking WHERE rowid=\(id) AND searchRanking MATCH '47000'"), 1)
            try execute(writer, "BEGIN IMMEDIATE")
            try execute(writer, "DELETE FROM searchRanking WHERE rowid=\(id)")
            XCTAssertGreaterThan(try revision(writer), committed)
            try execute(writer, "ROLLBACK")
            XCTAssertEqual(try revision(reader), committed)
            try execute(writer, "DELETE FROM searchRanking WHERE rowid=\(id)")
            XCTAssertGreaterThan(try revision(reader), committed)
            XCTAssertEqual(try scalar(reader, "SELECT COUNT(*) FROM searchRanking WHERE rowid=\(id)"), 0)
        }
    }

    func testReopenedManagedWriterRestoresConnectionLocalFence() async throws {
        let first = try openWriter()
        do { try await MigrationRunner(db: first).runMigrations() }
        catch { sqlite3_close_v2(first); throw error }
        sqlite3_close_v2(first)
        let reopened = try openWriter()
        defer { sqlite3_close_v2(reopened) }
        try await MigrationRunner(db: reopened).runMigrations()
        try await MigrationRunner(db: reopened).runMigrations()
        let before = try revision(reopened)
        try execute(reopened, "INSERT INTO searchRanking(rowid,text) VALUES(1,'restored connection')")
        XCTAssertGreaterThan(try revision(reopened), before)
    }

    func testFTSWriterRejectsV21WithoutRequiredRevisionTable() async throws {
        let writer = try openWriter()
        defer { sqlite3_close_v2(writer) }
        try await MigrationRunner(db: writer).runMigrations()
        try execute(writer, "DROP TABLE recall_search_revision")
        let manager = FTSManager(databasePath: path)
        do {
            try await manager.initialize()
            XCTFail("A V21 writer must not open without its revision fence")
        } catch {
            XCTAssertTrue(error is DatabaseError)
        }
        try await manager.close()
    }

    func testFTSWriterCanInitializeLegacyEmptyStore() async throws {
        let manager = FTSManager(databasePath: path)
        try await manager.initialize()
        try await manager.close()
    }

    private func openWriter() throws -> OpaquePointer {
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw DatabaseError.connectionFailed(underlying: "Temporary writer unavailable")
        }
        do { try execute(pointer, "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON") }
        catch { sqlite3_close_v2(pointer); throw error }
        return pointer
    }

    private func defensiveReader() throws -> OpaquePointer {
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw DatabaseError.connectionFailed(underlying: "Temporary reader unavailable")
        }
        var enabled: Int32 = 0
        XCTAssertEqual(retrace_test_enable_defensive(pointer, &enabled), SQLITE_OK)
        XCTAssertEqual(enabled, 1)
        XCTAssertEqual(sqlite3_db_readonly(pointer, "main"), 1)
        return pointer
    }

    private func revision(_ db: OpaquePointer) throws -> Int64 {
        try scalar(db, "SELECT revision FROM recall_search_revision WHERE id=1")
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: "authored compatibility fixture", underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func scalar(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(query: "compatibility scalar", underlying: String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_column_int64(statement, 0)
    }
}
