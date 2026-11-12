import Foundation
import SQLCipher
import XCTest
@testable import Database

final class SQLCipherConnectionOwnershipTests: XCTestCase {
    func testTransferredHandleClosesAfterLastPreparedStatementFinishes() throws {
        let (pointer, closed) = try openTrackedDatabase()
        var statement: OpaquePointer?
        do {
            let owner = SQLCipherConnection(takingOwnershipOf: pointer)
            statement = try owner.prepare(sql: "SELECT ownership_probe()")
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        }
        XCTAssertEqual(closed.count, 0, "close_v2 retains a pending statement's native owner")
        XCTAssertEqual(sqlite3_finalize(statement), SQLITE_OK)
        XCTAssertEqual(closed.count, 1, "The final statement releases the transferred native handle")
    }

    func testBorrowedHandleRemainsOwnedByItsOriginalCaller() throws {
        let (pointer, closed) = try openTrackedDatabase()
        do {
            let borrowed = SQLCipherConnection(db: pointer)
            let statement = try borrowed.prepare(sql: "SELECT ownership_probe()")
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            borrowed.finalize(statement)
        }
        XCTAssertEqual(closed.count, 0)
        XCTAssertEqual(sqlite3_close(pointer), SQLITE_OK)
        XCTAssertEqual(closed.count, 1)
    }

    private func openTrackedDatabase() throws -> (OpaquePointer, SourceConnectionCloseCounter) {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(":memory:", &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        let pointer = try XCTUnwrap(raw), counter = SourceConnectionCloseCounter()
        let retained = Unmanaged.passRetained(counter).toOpaque()
        let status = sqlite3_create_function_v2(pointer, "ownership_probe", 0, SQLITE_UTF8, retained,
            { context, _, _ in sqlite3_result_int(context, 1) }, nil, nil,
            { opaque in
                guard let opaque else { return }
                Unmanaged<SourceConnectionCloseCounter>.fromOpaque(opaque).takeRetainedValue().increment()
            })
        guard status == SQLITE_OK else { sqlite3_close(pointer); throw DatabaseConnectionError.notConnected }
        return (pointer, counter)
    }
}

private final class SourceConnectionCloseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
}
