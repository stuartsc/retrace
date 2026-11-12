import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database

final class NativeSourceMutationHooksTests: XCTestCase {
    func testTypedTargetsPreserveUnrelatedRowsAndReplaceRevokesDisplacedIdentity() throws {
        let db = try open(); defer { sqlite3_close_v2(db) }
        try execute(db, "CREATE TABLE frame(id INTEGER PRIMARY KEY, value TEXT UNIQUE)")
        try execute(db, "INSERT INTO frame VALUES(1,'first'),(2,'second')")
        let events = TypedEvents(), retained = NativeSourceDependencies(targets: [.frame(1)])
        let hooks = NativeSourceMutationHooks(db: db, onMutation: { events.record($0) })
        try hooks.install(); defer { hooks.detach() }
        try execute(db, "INSERT INTO frame VALUES(3,'third')")
        XCTAssertFalse(try XCTUnwrap(events.last).affects(retained))
        try execute(db, "UPDATE frame SET value='changed' WHERE id=1")
        XCTAssertTrue(try XCTUnwrap(events.last).affects(retained))
        try execute(db, "INSERT OR REPLACE INTO frame VALUES(4,'second')")
        XCTAssertTrue(try XCTUnwrap(events.last).affects(.init(targets: [.frame(2)])), "REPLACE displaced another ID; its implicit DELETE must revoke it")
        XCTAssertTrue(try XCTUnwrap(events.last).dependencies.all)
        try execute(db, "UPDATE frame SET id=5 WHERE id=1")
        XCTAssertEqual(try XCTUnwrap(events.last).dependencies.targets, [.frame(1), .frame(5)])
    }

    func testHigherPassInsertTargetsSameBatchAndSegmentExtensionIsIndexOnly() throws {
        let db = try open(); defer { sqlite3_close_v2(db) }
        try execute(db, "CREATE TABLE audio_captures(id INTEGER PRIMARY KEY,audio_path TEXT,batch_audio_path TEXT,transcription_pass INTEGER)")
        try execute(db, "CREATE TABLE segment(id INTEGER PRIMARY KEY,endDate INTEGER,windowName TEXT)")
        try execute(db, "INSERT INTO audio_captures VALUES(1,'shared','shared',1)")
        try execute(db, "INSERT INTO segment VALUES(7,10,'Original')")
        let events = TypedEvents(), retained = NativeSourceDependencies(targets: [.audioRow(1), .audioBatch("shared"), .segment(7)])
        let hooks = NativeSourceMutationHooks(db: db, onMutation: { events.record($0) })
        try hooks.install(); defer { hooks.detach() }
        try execute(db, "INSERT INTO audio_captures VALUES(2,'unrelated','unrelated',1)")
        XCTAssertFalse(try XCTUnwrap(events.last).affects(retained))
        try execute(db, "INSERT INTO audio_captures VALUES(3,'shared','shared',2)")
        XCTAssertTrue(try XCTUnwrap(events.last).affects(retained))
        try execute(db, "UPDATE segment SET endDate=20 WHERE id=7")
        XCTAssertEqual(events.last, .indexOnly)
        try execute(db, "UPDATE segment SET windowName='Changed' WHERE id=7")
        XCTAssertTrue(try XCTUnwrap(events.last).affects(retained))
    }

    func testOverflowAndUnknownLayoutUseStrongInvalidation() throws {
        let db = try open(); defer { sqlite3_close_v2(db) }
        try execute(db, "CREATE TABLE frame(id INTEGER PRIMARY KEY)")
        try execute(db, "CREATE TABLE audio_captures(id INTEGER PRIMARY KEY,text TEXT)")
        let events = TypedEvents()
        let hooks = NativeSourceMutationHooks(db: db, onMutation: { events.record($0) })
        try hooks.install(); defer { hooks.detach() }
        try execute(db, "BEGIN")
        for id in 1...257 { try execute(db, "INSERT INTO frame VALUES(\(id))") }
        try execute(db, "COMMIT")
        XCTAssertTrue(try XCTUnwrap(events.last).dependencies.all)
        XCTAssertLessThanOrEqual(events.maximumTargetCount, 256)
        try execute(db, "INSERT INTO audio_captures VALUES(1,'unknown layout')")
        XCTAssertTrue(try XCTUnwrap(events.last).dependencies.all)
    }

    func testDroppingHookDetachesCallbacksWhileConnectionAndStatementRemainAlive() throws {
        let db = try open()
        defer { sqlite3_close_v2(db) }
        try execute(db, "CREATE TABLE frame(id INTEGER PRIMARY KEY, value TEXT)")
        let events = Events()
        var hooks: NativeSourceMutationHooks? = NativeSourceMutationHooks(db: db, handler: { events.record() })
        try hooks?.install()
        try execute(db, "INSERT INTO frame VALUES(1,'original')")
        XCTAssertGreaterThanOrEqual(events.count, 2)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "UPDATE frame SET value='changed' WHERE id=1", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let baseline = events.count
        hooks = nil
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        try execute(db, "DELETE FROM frame")
        XCTAssertEqual(events.count, baseline, "A surviving native handle cannot call a released Swift hook")
    }

    func testPreparedDeleteReplaceAndUnrelatedWrites() throws {
        let db = try open()
        defer { sqlite3_close_v2(db) }
        try execute(db, "CREATE TABLE frame(id INTEGER PRIMARY KEY, value TEXT UNIQUE)")
        try execute(db, "CREATE TABLE daily_metrics(value INTEGER)")
        try execute(db, "INSERT INTO frame VALUES(1,'first'),(2,'second')")
        // Compiled before installation: the authorizer must expire its OP_Clear.
        var deletion: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "DELETE FROM frame", -1, &deletion, nil), SQLITE_OK)
        defer { sqlite3_finalize(deletion) }
        let events = Events()
        let hooks = NativeSourceMutationHooks(db: db, handler: { events.record() })
        try hooks.install()
        defer { hooks.detach() }
        XCTAssertEqual(sqlite3_step(deletion), SQLITE_DONE)
        XCTAssertGreaterThanOrEqual(events.count, 2, "Revoke during deletion and again after its completion")
        var baseline = events.count
        try execute(db, "INSERT INTO daily_metrics VALUES(1)")
        try execute(db, "SELECT count(*) FROM frame")
        XCTAssertEqual(events.count, baseline, "Metrics/reads cannot revoke their own source admission")

        try execute(db, "INSERT INTO frame VALUES(1,'first'),(2,'second')")
        baseline = events.count
        // SQLite omits update-hook DELETE for REPLACE, but the replacement INSERT
        // still invalidates the complete source, including the displaced row.
        try execute(db, "INSERT OR REPLACE INTO frame VALUES(3,'second')")
        XCTAssertGreaterThanOrEqual(events.count, baseline + 2)
        hooks.detach()
        baseline = events.count
        try execute(db, "DELETE FROM frame")
        XCTAssertEqual(events.count, baseline)
    }

    func testExplicitCommitAndRollbackRevokeAfterLastMutationStatement() throws {
        let db = try open()
        defer { sqlite3_close_v2(db) }
        try execute(db, "CREATE TABLE audio_captures(id INTEGER PRIMARY KEY, text TEXT)")
        let events = Events()
        let hooks = NativeSourceMutationHooks(db: db, handler: { events.record() })
        try hooks.install()
        defer { hooks.detach() }

        try execute(db, "BEGIN IMMEDIATE")
        try execute(db, "INSERT INTO audio_captures VALUES(1,'original')")
        let beforeCommit = events.count
        XCTAssertGreaterThanOrEqual(beforeCommit, 2)
        try execute(db, "COMMIT")
        XCTAssertGreaterThan(events.count, beforeCommit, "A permit obtained during the transaction must not survive COMMIT")
        let committed = events.count
        try execute(db, "SELECT text FROM audio_captures")
        XCTAssertEqual(events.count, committed)

        try execute(db, "BEGIN IMMEDIATE")
        try execute(db, "UPDATE audio_captures SET text='uncommitted'")
        let beforeRollback = events.count
        try execute(db, "ROLLBACK")
        XCTAssertGreaterThan(events.count, beforeRollback)
        let rolledBack = events.count
        try execute(db, "SELECT text FROM audio_captures")
        XCTAssertEqual(events.count, rolledBack)
    }

    func testFailedCommitRetainsDirtyFenceThroughRetry() throws {
        let db = try open()
        defer { sqlite3_close_v2(db) }
        try execute(db, "PRAGMA foreign_keys=ON")
        try execute(db, "CREATE TABLE parent(id INTEGER PRIMARY KEY)")
        try execute(db, "CREATE TABLE frame(id INTEGER PRIMARY KEY, parentID INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED)")
        let events = Events()
        let hooks = NativeSourceMutationHooks(db: db, handler: { events.record() })
        try hooks.install()
        defer { hooks.detach() }
        try execute(db, "BEGIN")
        try execute(db, "INSERT INTO frame VALUES(1,9)")
        XCTAssertEqual(sqlite3_exec(db, "COMMIT", nil, nil, nil), SQLITE_CONSTRAINT)
        XCTAssertEqual(sqlite3_get_autocommit(db), 0)
        try execute(db, "INSERT INTO parent VALUES(9)")
        let beforeRetry = events.count
        try execute(db, "COMMIT")
        XCTAssertGreaterThan(events.count, beforeRetry)
        let finished = events.count
        try execute(db, "SELECT count(*) FROM frame")
        XCTAssertEqual(events.count, finished)
    }

    func testFTSContentAndHiddenTagChangesRevokeWithNoSchemaWrites() throws {
        let db = try open()
        defer { sqlite3_close_v2(db) }
        try execute(db, "CREATE VIRTUAL TABLE searchRanking USING fts5(text)")
        try execute(db, "CREATE TABLE segment_tag(segmentId INTEGER,tagId INTEGER,PRIMARY KEY(segmentId,tagId))")
        let events = Events()
        let hooks = NativeSourceMutationHooks(db: db, handler: { events.record() })
        try hooks.install()
        defer { hooks.detach() }
        try execute(db, "INSERT INTO searchRanking(text) VALUES('first pass')")
        XCTAssertGreaterThanOrEqual(events.count, 2)
        let beforeHide = events.count
        try execute(db, "INSERT INTO segment_tag VALUES(1,1)")
        XCTAssertGreaterThanOrEqual(events.count, beforeHide + 2)
        let beforeShow = events.count
        try execute(db, "DELETE FROM segment_tag")
        XCTAssertGreaterThanOrEqual(events.count, beforeShow + 2)
        let complete = events.count
        try execute(db, "SELECT rowid FROM searchRanking WHERE searchRanking MATCH 'first'")
        XCTAssertEqual(events.count, complete, "Internal FTS statements cannot leave a false dirty transaction")
    }

    func testDatabaseOwnerInstallsAndRestoresHandlerAcrossClose() async throws {
        let database = DatabaseManager(databasePath: ":memory:")
        let events = Events()
        try await database.setSourceMutationHandler { events.record() }
        try await database.initialize()
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await database.insertSegment(bundleID: "com.fixture", startDate: time, endDate: time,
            windowName: "Authored", browserUrl: nil, type: 0)
        XCTAssertGreaterThanOrEqual(events.count, 2)
        try await database.close()
        let closed = events.count
        try await database.initialize()
        _ = try await database.insertSegment(bundleID: "com.fixture", startDate: time, endDate: time,
            windowName: "Reopened", browserUrl: nil, type: 0)
        XCTAssertGreaterThan(events.count, closed)
        try await database.setSourceMutationHandler(nil)
        let detached = events.count
        _ = try await database.insertSegment(bundleID: "com.fixture", startDate: time, endDate: time,
            windowName: "Detached", browserUrl: nil, type: 0)
        XCTAssertEqual(events.count, detached)
        try await database.close()
    }

    private func open() throws -> OpaquePointer {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let connection else {
            throw DatabaseError.connectionFailed(underlying: "Private mutation fixture unavailable")
        }
        return connection
    }
    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryExecutionFailed("Private mutation fixture command failed")
        }
    }
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func record() { lock.lock(); value += 1; lock.unlock() }
    }
    private final class TypedEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var value: NativeSourceMutation?
        private var maximum = 0
        var last: NativeSourceMutation? { lock.withLock { value } }
        var maximumTargetCount: Int { lock.withLock { maximum } }
        func record(_ mutation: NativeSourceMutation) {
            lock.withLock { value = mutation; maximum = max(maximum, mutation.dependencies.targets.count) }
        }
    }
}
