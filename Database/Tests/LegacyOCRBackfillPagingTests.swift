import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database

final class LegacyOCRBackfillPagingTests: XCTestCase {
    private var database: DatabaseManager!
    private var directory: URL!
    private var databasePath: String!
    private var segmentID: Int64 = 0

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-ocr-page-\(UUID())")
        databasePath = directory.appendingPathComponent("retrace.db").path
        database = DatabaseManager(databasePath: databasePath)
        try await database.initialize()
        segmentID = try await database.insertSegment(
            bundleID: "com.test.backfill", startDate: Date(), endDate: Date(),
            windowName: "Stored OCR", browserUrl: nil, type: 0
        )
    }

    override func tearDown() async throws {
        try await database.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testSparsePageAdvancesWithoutSearchingBeyondTheNodeBudget() async throws {
        let modern = try await frame(text: "Modern", legacy: false)
        try await addModernNodes(frameID: modern, count: 2_500)
        let legacy = try await frame(text: "Retained evidence", legacy: true)
        let firstNode = try await scalar("SELECT MIN(id) FROM node")

        let first = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5)
        XCTAssertTrue(first.isEmpty, "A sparse page must not search ahead for matching frames")
        let cursor = try await scalar("SELECT nodeCursor FROM ocr_backfill_state WHERE id=1")
        XCTAssertEqual(cursor, firstNode + 999)

        let second = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5)
        let third = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(third, [legacy])
    }

    func testNoMatchPageUsesBoundedSQLiteWorkAndPrimaryKeySeek() async throws {
        let modern = try await frame(text: "Modern", legacy: false)
        try await addModernNodes(frameID: modern, count: 60_000)
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        let trace = BackfillSQLTrace()
        sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
            guard let context, let statement else { return 0 }
            let pointer = OpaquePointer(statement)
            guard let expanded = sqlite3_expanded_sql(pointer) else { return 0 }
            defer { sqlite3_free(expanded) }
            Unmanaged<BackfillSQLTrace>.fromOpaque(context).takeUnretainedValue().record(
                sql: String(cString: expanded), steps: sqlite3_stmt_status(pointer, SQLITE_STMTSTATUS_VM_STEP, 0)
            )
            return 0
        }, Unmanaged.passUnretained(trace).toOpaque())
        defer { sqlite3_trace_v2(db, 0, nil, nil) }

        let queued = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5)
        sqlite3_trace_v2(db, 0, nil, nil)
        XCTAssertTrue(queued.isEmpty)
        print("LEGACY_BACKFILL_NO_MATCH_VM_STEPS \(trace.steps)")
        XCTAssertLessThan(trace.steps, 30_000, "The node budget must bound actual SQLite VM work")
        let nodeQueries = trace.statements.filter { $0.contains("FROM node") }
        XCTAssertEqual(nodeQueries.count, 2, "Only a one-row endpoint lookup and the bounded page are allowed")
        XCTAssertEqual(nodeQueries.filter { $0.contains("WHERE id>") }.count, 1)
        for sql in nodeQueries {
            let plan = try PipelineSQL.query(db, "EXPLAIN QUERY PLAN \(sql)") {
                String(cString: sqlite3_column_text($0, 3))
            }
            if sql.contains("WHERE id>") {
                XCTAssertTrue(plan.contains { $0.contains("SEARCH node USING INTEGER PRIMARY KEY") }, "\(plan)")
            } else {
                XCTAssertTrue(sql.hasSuffix("ORDER BY id DESC LIMIT 1"), "\(sql)")
            }
            XCTAssertFalse(plan.contains { $0.contains("TEMP B-TREE") }, "\(plan)")
        }
    }

    func testCursorSurvivesDatabaseCloseAndReopen() async throws {
        let modern = try await frame(text: "Modern", legacy: false)
        try await addModernNodes(frameID: modern, count: 1_100)
        let legacy = try await frame(text: "Retained evidence", legacy: true)
        let first = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5)
        XCTAssertTrue(first.isEmpty)
        let cursorBefore = try await scalar("SELECT nodeCursor FROM ocr_backfill_state WHERE id=1")
        try await database.close()
        database = DatabaseManager(databasePath: databasePath)
        try await database.initialize()
        let cursorAfter = try await scalar("SELECT nodeCursor FROM ocr_backfill_state WHERE id=1")
        XCTAssertEqual(cursorAfter, cursorBefore)
        let next = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5)
        XCTAssertEqual(next, [legacy])
    }

    func testBusyQueueDoesNotReadNodesOrAdvanceCursor() async throws {
        let legacy = try await frame(text: "Retained evidence", legacy: true)
        try await execute("""
            WITH RECURSIVE rows(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM rows WHERE x<250)
            INSERT INTO frame(createdAt,imageFileName,processingStatus) SELECT x,'',0 FROM rows;
            """)
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        sqlite3_set_authorizer(db, { _, action, table, _, _, _ in
            if action == SQLITE_READ, let table, String(cString: table) == "node" { return SQLITE_DENY }
            return SQLITE_OK
        }, nil)
        defer { sqlite3_set_authorizer(db, nil, nil) }
        let queued = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5)
        XCTAssertTrue(queued.isEmpty)
        let cursor = try await scalar("SELECT COALESCE((SELECT nodeCursor FROM ocr_backfill_state WHERE id=1),0)")
        let status = try await database.getFrameProcessingStatus(frameID: legacy)
        XCTAssertEqual(cursor, 0)
        XCTAssertEqual(status, 2)
    }

    func testStaleQueueDuplicatesDoNotConsumeCapacityOrRequireFullScan() async throws {
        let modern = try await frame(text: "Modern", legacy: false)
        let legacy = try await frame(text: "Retained evidence", legacy: true)
        try await execute("""
            WITH RECURSIVE rows(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM rows WHERE x<60_000)
            INSERT INTO processing_queue(frameId,enqueuedAt,priority,retryCount)
            SELECT \(modern),x,0,0 FROM rows;
            """)
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        let budget = BackfillSQLProgressBudget()
        sqlite3_progress_handler(db, 1_000, { context in
            guard let context else { return 1 }
            return Unmanaged<BackfillSQLProgressBudget>.fromOpaque(context).takeUnretainedValue().tick()
        }, Unmanaged.passUnretained(budget).toOpaque())
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        let queued = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5, maxQueueDepth: 25)
        sqlite3_progress_handler(db, 0, nil, nil)
        XCTAssertEqual(queued, [legacy])
        XCTAssertFalse(budget.exceeded, "Stale queue entries must not trigger a full scan")
    }

    func testBatchLimitDoesNotSkipUnqueuedCandidatesAndPreservesFTSAndNodes() async throws {
        var frames: [Int64] = []
        for index in 0..<5 { frames.append(try await frame(text: "Retained evidence \(index)", legacy: true)) }
        let nodeCount = try await scalar("SELECT COUNT(*) FROM node")
        let docCount = try await scalar("SELECT COUNT(*) FROM doc_segment")
        let first = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 2, priority: -5)
        let second = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 2, priority: -5)
        let third = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 2, priority: -5)
        XCTAssertEqual(first + second + third, frames)
        let nodesAfter = try await scalar("SELECT COUNT(*) FROM node")
        let docsAfter = try await scalar("SELECT COUNT(*) FROM doc_segment")
        let searchable = try await scalar("SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'Retained'")
        XCTAssertEqual(nodesAfter, nodeCount)
        XCTAssertEqual(docsAfter, docCount)
        XCTAssertEqual(searchable, 5)
    }

    func testFailedSecondEnqueueRollsBackWholePageAndCursor() async throws {
        let first = try await frame(text: "Retained first", legacy: true)
        let second = try await frame(text: "Retained second", legacy: true)
        try await execute("""
            CREATE TEMP TRIGGER reject_backfill BEFORE INSERT ON processing_queue
            WHEN NEW.frameId=\(second) BEGIN SELECT RAISE(ABORT,'injected second insert failure'); END;
            """)
        do {
            _ = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5)
            XCTFail("Expected the page transaction to fail")
        } catch { }
        let statuses = try await database.getFrameProcessingStatuses(frameIDs: [first, second])
        let queued = try await database.getProcessingQueueDepth()
        let cursor = try await scalar("SELECT COALESCE((SELECT nodeCursor FROM ocr_backfill_state WHERE id=1),0)")
        let searchable = try await scalar("SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'Retained'")
        XCTAssertEqual(statuses[first], 2)
        XCTAssertEqual(statuses[second], 2)
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(cursor, 0)
        XCTAssertEqual(searchable, 2)
        try await execute("DROP TRIGGER reject_backfill")
        let retried = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5)
        XCTAssertEqual(retried, [first, second])
    }

    func testRemainingCapacityBoundsEnqueueAndRetainsUninspectedNode() async throws {
        var frames: [Int64] = []
        for index in 0..<5 { frames.append(try await frame(text: "Retained \(index)", legacy: true)) }
        try await execute("INSERT INTO frame(createdAt,imageFileName,processingStatus) VALUES(1,'in flight',1)")
        let queued = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5, maxQueueDepth: 3)
        XCTAssertEqual(queued, Array(frames.prefix(2)))
        let cursor = try await scalar("SELECT nodeCursor FROM ocr_backfill_state WHERE id=1")
        let lastQueuedNode = try await scalar("SELECT MAX(id) FROM node WHERE frameId=\(frames[1])")
        XCTAssertEqual(cursor, lastQueuedNode)
        let blocked = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5, maxQueueDepth: 3)
        XCTAssertTrue(blocked.isEmpty)
        let unchangedCursor = try await scalar("SELECT nodeCursor FROM ocr_backfill_state WHERE id=1")
        XCTAssertEqual(unchangedCursor, cursor)
    }

    func testCursorWriteFailureRollsBackEnqueuedFrameAndPreservesSearch() async throws {
        let legacy = try await frame(text: "Retained evidence", legacy: true)
        try await execute("""
            CREATE TEMP TRIGGER reject_cursor BEFORE UPDATE ON ocr_backfill_state
            BEGIN SELECT RAISE(ABORT,'injected cursor failure'); END;
            """)
        do {
            _ = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5)
            XCTFail("Expected cursor publication failure")
        } catch { }
        let status = try await database.getFrameProcessingStatus(frameID: legacy)
        let cursor = try await scalar("SELECT nodeCursor FROM ocr_backfill_state WHERE id=1")
        let queued = try await database.getProcessingQueueDepth()
        let searchable = try await scalar("SELECT COUNT(*) FROM searchRanking WHERE searchRanking MATCH 'Retained'")
        XCTAssertEqual(status, 2)
        XCTAssertEqual(cursor, 0)
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(searchable, 1)
    }

    func testAlreadyCancelledMaintenanceDoesNotChangeCursorOrQueue() async throws {
        let legacy = try await frame(text: "Retained evidence", legacy: true)
        let database = try XCTUnwrap(database)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled maintenance must stop before taking a transaction")
        } catch is CancellationError { }
        let status = try await database.getFrameProcessingStatus(frameID: legacy)
        let cursor = try await scalar("SELECT nodeCursor FROM ocr_backfill_state WHERE id=1")
        XCTAssertEqual(status, 2)
        XCTAssertEqual(cursor, 0)
    }

    func testEndOfTableWrapsOnLaterTickAndFindsPreviouslyBusyFrame() async throws {
        let legacy = try await frame(text: "Retained evidence", legacy: true)
        try await database.updateFrameProcessingStatus(frameID: legacy, status: 1)
        let first = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5)
        XCTAssertTrue(first.isEmpty)
        try await database.updateFrameProcessingStatus(frameID: legacy, status: 2)
        let wrap = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5)
        XCTAssertTrue(wrap.isEmpty, "Wrap must not cause a second page scan in one call")
        let cursor = try await scalar("SELECT nodeCursor FROM ocr_backfill_state WHERE id=1")
        XCTAssertEqual(cursor, 0)
        let next = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5)
        XCTAssertEqual(next, [legacy])
    }

    func testGrowingNodeTailCannotPreventRevisitingPreviouslyBusyFrame() async throws {
        let legacy = try await frame(text: "Retained evidence", legacy: true)
        try await database.updateFrameProcessingStatus(frameID: legacy, status: 1)
        let initial = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5)
        XCTAssertTrue(initial.isEmpty)

        // New captures arrive faster than one maintenance page per minute.
        // They must not extend the sweep that already passed the busy old frame.
        let modern = try await frame(text: "Modern", legacy: false)
        try await addModernNodes(frameID: modern, count: 5_000)
        try await database.updateFrameProcessingStatus(frameID: legacy, status: 2)
        let wrap = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5)
        XCTAssertTrue(wrap.isEmpty)
        let cursor = try await scalar("SELECT nodeCursor FROM ocr_backfill_state WHERE id=1")
        XCTAssertEqual(cursor, 0, "An established sweep must finish despite newly appended nodes")
        let revisit = try await database.enqueueLegacyOCRNodeTextBackfill(limit: 25, priority: -5)
        XCTAssertEqual(revisit, [legacy])
    }

    private func frame(text: String, legacy: Bool) async throws -> Int64 {
        let frameID = try await database.insertFrame(FrameReference(
            id: FrameID(value: 0), timestamp: Date(), segmentID: AppSegmentID(value: segmentID),
            videoID: VideoSegmentID(value: 0), frameIndexInSegment: 0,
            metadata: FrameMetadata(appBundleID: "com.test.backfill")
        ))
        _ = try await database.indexFrameText(mainText: text, chromeText: nil, windowTitle: nil, segmentId: segmentID, frameId: frameID)
        try await database.insertNodes(
            frameID: FrameID(value: frameID),
            nodes: [(textOffset: 0, textLength: text.count, text: legacy ? nil : text,
                     bounds: CGRect(x: 1, y: 1, width: 20, height: 10), windowIndex: nil)],
            frameWidth: 100, frameHeight: 100
        )
        try await database.updateFrameProcessingStatus(frameID: frameID, status: 2)
        return frameID
    }

    private func addModernNodes(frameID: Int64, count: Int) async throws {
        try await execute("""
            WITH RECURSIVE rows(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM rows WHERE x<\(count))
            INSERT INTO node(frameId,nodeOrder,textOffset,textLength,leftX,topY,width,height,text)
            SELECT \(frameID),x,0,6,0,0,1,1,'Modern' FROM rows;
            """)
    }

    private func execute(_ sql: String) async throws {
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func scalar(_ sql: String) async throws -> Int64 {
        let connection = await database.getConnection()
        return try PipelineSQL.integers(XCTUnwrap(connection), sql).first ?? 0
    }
}

private final class BackfillSQLTrace {
    private let lock = NSLock()
    private var recorded: [(String, Int)] = []
    var statements: [String] { lock.lock(); defer { lock.unlock() }; return recorded.map(\.0) }
    var steps: Int { lock.lock(); defer { lock.unlock() }; return recorded.reduce(0) { $0 + $1.1 } }
    func record(sql: String, steps: Int32) { lock.lock(); defer { lock.unlock() }; recorded.append((sql, Int(steps))) }
}

private final class BackfillSQLProgressBudget {
    private var ticks = 0
    var exceeded: Bool { ticks > 30 }
    func tick() -> Int32 { ticks += 1; return exceeded ? 1 : 0 }
}
