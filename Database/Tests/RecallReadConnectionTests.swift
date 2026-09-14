import Foundation
import SQLCipher
import XCTest
@testable import Database

final class RecallReadConnectionTests: XCTestCase {
    private var directory: URL!
    private var writer: SQLiteConnection!
    private var pointer: OpaquePointer!
    private var path: String { directory.appendingPathComponent("reader.sqlite").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("recall-reader-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(sqlite3_open_v2(path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        writer = SQLiteConnection(db: pointer)
        try writer.execute(sql: "PRAGMA journal_mode=WAL")
        try writer.execute(sql: "CREATE TABLE revision(value INTEGER NOT NULL)")
        try writer.execute(sql: "INSERT INTO revision VALUES(1)")
    }

    override func tearDownWithError() throws {
        writer = nil
        XCTAssertEqual(sqlite3_close(pointer), SQLITE_OK)
        try FileManager.default.removeItem(at: directory)
    }

    func testReaderSeesOnlyCommittedWriterStateAndCannotWrite() throws {
        let reader: any DatabaseConnection = try SQLiteConnection(readOnlyDatabasePath: path)
        XCTAssertNotEqual(reader.getConnection(), pointer)
        try writer.beginTransaction()
        try writer.execute(sql: "UPDATE revision SET value=2")
        XCTAssertEqual(try value(reader), 1)
        try writer.commit()
        XCTAssertEqual(try value(reader), 2)
        XCTAssertThrowsError(try reader.execute(sql: "UPDATE revision SET value=3"))
        XCTAssertEqual(try value(writer), 2)
    }

    func testOwnedReaderClosesAfterDeinitWhileBorrowedConnectionStaysOpen() throws {
        weak var weakReader: SQLiteConnection?
        var pending: OpaquePointer?
        do {
            let reader = try SQLiteConnection(readOnlyDatabasePath: path)
            weakReader = reader
            pending = try reader.prepare(sql: "SELECT value FROM revision")
            XCTAssertEqual(sqlite3_step(pending), SQLITE_ROW)
        }
        XCTAssertNil(weakReader)
        // close_v2 permits outstanding statements to finish before freeing the handle.
        XCTAssertEqual(sqlite3_column_int64(pending, 0), 1)
        XCTAssertEqual(sqlite3_finalize(pending), SQLITE_OK)
        do { let borrowed = SQLiteConnection(db: pointer); XCTAssertEqual(try value(borrowed), 1) }
        XCTAssertEqual(try value(writer), 1)
    }

    func testMissingReadOnlyPathIsNotCreatedAndBusyWaitIsBounded() throws {
        let missing = directory.appendingPathComponent("missing.sqlite").path
        XCTAssertThrowsError(try SQLiteConnection(readOnlyDatabasePath: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
        let reader = try SQLiteConnection(readOnlyDatabasePath: path)
        let statement = try reader.prepare(sql: "PRAGMA busy_timeout")
        defer { reader.finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertTrue((1...2000).contains(sqlite3_column_int(statement, 0)))
    }

    private func value(_ connection: any DatabaseConnection) throws -> Int64 {
        let statement = try connection.prepare(sql: "SELECT value FROM revision")
        defer { connection.finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return sqlite3_column_int64(statement, 0)
    }
}
