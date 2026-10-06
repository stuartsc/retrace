import XCTest
import Shared
import SQLCipher
@testable import Database

final class AutomaticAudioSelectionTests: XCTestCase {
    private var database: DatabaseManager!
    private var queries: AudioTranscriptionQueries!
    private var connection: OpaquePointer!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:automatic_audio_\(UUID().uuidString)?mode=memory&cache=shared")
        try await database.initialize()
        connection = await database.getConnection()
        queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
    }

    override func tearDown() async throws { try await database.close() }

    func testRecentLaneChoosesNewestPendingAndSkipsRepairAndCompletedOutcomes() async throws {
        _ = try await seed(at: now.addingTimeInterval(-3_600))
        let newest = try await seed(at: now.addingTimeInterval(-60), path: "audio/batch_Élodie_😀_' OR 1=1 --.m4a")
        _ = try await seed(at: now.addingTimeInterval(-30), status: "needs_repair")
        _ = try await seed(at: now.addingTimeInterval(-20), status: "transcribed")
        _ = try await seed(at: now.addingTimeInterval(-10), status: "probable_silence")
        _ = try await seed(at: now.addingTimeInterval(-5), status: "needs_review")
        let selected = try await queries.getRecentPendingBatch(now: now)
        XCTAssertEqual(selected?.id, newest)
        XCTAssertEqual(selected?.audioPath, "audio/batch_Élodie_😀_' OR 1=1 --.m4a")
        let rows = try await queries.getUntranscribedBatches(limit: 100)
        XCTAssertEqual(rows.count, 3, "Read selection must not rewrite any retained status")
    }

    func testRecentHorizonIncludesBothExactBoundariesAndExcludesOutsideAndFuture() async throws {
        let start = now.addingTimeInterval(-24 * 3_600)
        _ = try await seed(at: start.addingTimeInterval(-0.001))
        let firstInside = try await seed(at: start)
        let finalInside = try await seed(at: now)
        _ = try await seed(at: now.addingTimeInterval(0.001))
        let newest = try await queries.getRecentPendingBatch(now: now)
        XCTAssertEqual(newest?.id, finalInside)
        try await queries.deleteTranscription(id: finalInside)
        let boundary = try await queries.getRecentPendingBatch(now: now)
        XCTAssertEqual(boundary?.id, firstInside)
        try await queries.deleteTranscription(id: firstInside)
        let outside = try await queries.getRecentPendingBatch(now: now)
        XCTAssertNil(outside)
    }

    func testClockChangeRecomputesWindowWithoutChangingStoredTimestamps() async throws {
        let older = try await seed(at: now.addingTimeInterval(-48 * 3_600))
        let current = try await seed(at: now.addingTimeInterval(-60))
        let present = try await queries.getRecentPendingBatch(now: now)
        XCTAssertEqual(present?.id, current)
        let rewound = try await queries.getRecentPendingBatch(now: now.addingTimeInterval(-47 * 3_600))
        XCTAssertEqual(rewound?.id, older)
        let advanced = try await queries.getRecentPendingBatch(now: now.addingTimeInterval(48 * 3_600))
        XCTAssertNil(advanced)
        let rows = try await queries.getUntranscribedBatches(limit: 100)
        XCTAssertEqual(rows.map(\.startTimeMilliseconds), [
            Schema.dateToTimestamp(now.addingTimeInterval(-48 * 3_600)),
            Schema.dateToTimestamp(now.addingTimeInterval(-60))
        ])
    }

    func testTimestampTiesUseRowIDNewestForRecentAndOldestAcrossStatuses() async throws {
        let first = try await seed(at: now, status: "needs_repair")
        _ = try await seed(at: now)
        let newest = try await seed(at: now)
        let recent = try await queries.getRecentPendingBatch(now: now)
        let oldest = try await queries.getOldestUntranscribedBatch()
        XCTAssertEqual(recent?.id, newest)
        XCTAssertEqual(oldest?.id, first)
    }

    func testOldestSelectsEitherStatusWithExactTiesAndHandlesSingleLane() async throws {
        let newerRepair = try await seed(at: now.addingTimeInterval(-40), status: "needs_repair")
        let pending = try await seed(at: now.addingTimeInterval(-60))
        let old = try await queries.getOldestUntranscribedBatch()
        XCTAssertEqual(old?.id, pending)
        try await queries.deleteTranscription(id: pending)
        let repairOnly = try await queries.getOldestUntranscribedBatch()
        XCTAssertEqual(repairOnly?.id, newerRepair)
        try await queries.deleteTranscription(id: newerRepair)
        let empty = try await queries.getOldestUntranscribedBatch()
        XCTAssertNil(empty)
        let pendingOnly = try await seed(at: now)
        let last = try await queries.getOldestUntranscribedBatch()
        XCTAssertEqual(last?.id, pendingOnly)
    }

    func testRecentAndOldestRejectNonBatchAndMissingMediaPaths() async throws {
        let invalidPath = try await seed(at: now, path: "audio/sentence.m4a")
        let noPath = try await seed(at: now)
        try exec("UPDATE audio_captures SET audio_path = NULL WHERE id = \(noPath)")
        let recent = try await queries.getRecentPendingBatch(now: now)
        let oldest = try await queries.getOldestUntranscribedBatch()
        XCTAssertNil(recent)
        XCTAssertNil(oldest)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_captures WHERE id IN (\(invalidPath), \(noPath))"), 2)
    }

    func testSelectedRowPreservesExactIntegerIdentityThroughCompletion() async throws {
        let id = try await seed(at: now)
        try exec("UPDATE audio_captures SET start_time = 10000002, end_time = 10001004 WHERE id = \(id)")
        let selected = try await queries.getRecentPendingBatch(now: Date(timeIntervalSince1970: 10_100))
        let batch = try XCTUnwrap(selected)
        XCTAssertEqual(batch.startTimeMilliseconds, 10_000_002)
        XCTAssertEqual(batch.endTimeMilliseconds, 10_001_004)
        let committed = try await queries.completePendingRawBatch(batch, with: [(
            sessionID: nil, text: "Retained exact sentence.", startTime: batch.startTime, endTime: batch.endTime,
            source: batch.source, confidence: 0.9, words: [], audioPath: batch.audioPath,
            transcriptionPass: 1, batchAudioPath: batch.audioPath, transcriptStatus: "transcribed",
            detectedLanguage: "en", audioVariant: "raw", qualityFlags: nil
        )])
        XCTAssertTrue(committed)
        let replay = try await queries.completePendingRawBatch(batch, with: [(
            sessionID: nil, text: "Stale duplicate.", startTime: batch.startTime, endTime: batch.endTime,
            source: batch.source, confidence: 0.9, words: [], audioPath: batch.audioPath,
            transcriptionPass: 1, batchAudioPath: batch.audioPath, transcriptStatus: "transcribed",
            detectedLanguage: "en", audioVariant: "raw", qualityFlags: nil
        )])
        XCTAssertFalse(replay)
    }

    func testManualQueryRetainsItsOriginalOldestFirstOrder() async throws {
        let recent = try await seed(at: now)
        let pending = try await seed(at: now.addingTimeInterval(-48 * 3_600))
        let repair = try await seed(at: now.addingTimeInterval(-72 * 3_600), status: "needs_repair")
        let selected = try await queries.getUntranscribedBatches(limit: 3)
        XCTAssertEqual(selected.map(\.id), [repair, pending, recent])
    }

    func testInvalidClockIsRejectedInsteadOfTrappingOrSelectingAllHistory() async throws {
        for interval in [Double.nan, .infinity, -.infinity, Double(Int64.max)] {
            do {
                _ = try await queries.getRecentPendingBatch(now: Date(timeIntervalSince1970: interval))
                XCTFail("Invalid clock must be rejected")
            } catch is DatabaseError {}
        }
    }

    func testSchemaAndStepFailuresPropagateRatherThanPretendingQueueIsEmpty() async throws {
        _ = try await seed(at: now)
        sqlite3_progress_handler(connection, 1, { _ in 1 }, nil)
        do {
            _ = try await queries.getOldestUntranscribedBatch()
            XCTFail("Interrupted SQLite read must throw")
        } catch is DatabaseError {}
        sqlite3_progress_handler(connection, 0, nil, nil)
        try exec("DROP INDEX idx_audio_captures_transcript_status")
        do {
            _ = try await queries.getRecentPendingBatch(now: now)
            XCTFail("Missing required installed-schema index must throw")
        } catch is DatabaseError {}
    }

    func testCancelledReadDoesNotSelectWork() async throws {
        _ = try await seed(at: now)
        let queries = try XCTUnwrap(self.queries)
        let now = self.now
        let gate = AutomaticAudioReadGate()
        let task = Task {
            await gate.wait()
            return try await queries.getRecentPendingBatch(now: now)
        }
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancelled read must not return a candidate")
        } catch is CancellationError {}
        let count = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(count, 1)
    }

    func testLargeEligibleQueueUsesThreeIndexSeeksWithoutTemporarySort() async throws {
        let millis = Schema.dateToTimestamp(now)
        try exec("""
            WITH RECURSIVE sequence(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM sequence WHERE n < 20000)
            INSERT INTO audio_captures(text, start_time, end_time, source, audio_path, audio_size, transcript_status)
            SELECT '', \(millis)-n, \(millis)-n+10000, 'microphone', 'audio/batch_' || n || '.m4a', 60598,
                   CASE WHEN n % 2 = 0 THEN 'pending' ELSE 'needs_repair' END FROM sequence;
            """)
        let trace = AutomaticAudioSQLTrace()
        sqlite3_trace_v2(connection, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
            guard let context, let statement else { return 0 }
            let pointer = OpaquePointer(statement)
            guard let expanded = sqlite3_expanded_sql(pointer) else { return 0 }
            defer { sqlite3_free(expanded) }
            Unmanaged<AutomaticAudioSQLTrace>.fromOpaque(context).takeUnretainedValue().record(
                sql: String(cString: expanded), steps: sqlite3_stmt_status(pointer, SQLITE_STMTSTATUS_VM_STEP, 0))
            return 0
        }, Unmanaged.passUnretained(trace).toOpaque())
        defer { sqlite3_trace_v2(connection, 0, nil, nil) }
        let newest = try await queries.getRecentPendingBatch(now: now)
        let oldest = try await queries.getOldestUntranscribedBatch()
        sqlite3_trace_v2(connection, 0, nil, nil)
        XCTAssertEqual(newest?.startTimeMilliseconds, millis - 2)
        XCTAssertEqual(oldest?.startTimeMilliseconds, millis - 20_000)
        XCTAssertEqual(trace.entries.count, 3)
        XCTAssertLessThan(trace.entries.reduce(0) { $0 + $1.steps }, 250,
            "Eligible first candidates must not scan or sort a 20k-row backlog")
        for entry in trace.entries {
            let plans = try plan(entry.sql)
            print("AUTOMATIC_AUDIO_QUERY_VM_STEPS \(entry.steps) PLAN \(plans)")
            XCTAssertTrue(plans.contains { $0.contains("idx_audio_captures_transcript_status") })
            XCTAssertFalse(plans.contains { $0.contains("TEMP B-TREE") })
        }
    }

    private func seed(at date: Date, status: String = "pending", path: String? = nil) async throws -> Int64 {
        let id = try await queries.insertRawBatch(startTime: date, endTime: date.addingTimeInterval(10),
            source: .microphone, audioPath: path ?? "audio/batch_\(UUID().uuidString).m4a", audioSize: 60_598)
        if status != "pending" {
            try await queries.updateBatchOutcome(id: id, text: "", transcriptStatus: status,
                detectedLanguage: nil, audioVariant: "raw", qualityFlags: nil)
        }
        return id
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(connection)))
        }
    }

    private func scalar(_ sql: String) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw DatabaseError.queryExecutionFailed("missing scalar") }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func plan(_ sql: String) throws -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "EXPLAIN QUERY PLAN \(sql)", -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(stmt) }
        var result: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { result.append(String(cString: sqlite3_column_text(stmt, 3))) }
        return result
    }
}

private final class AutomaticAudioSQLTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(sql: String, steps: Int32)] = []
    var entries: [(sql: String, steps: Int32)] { lock.lock(); defer { lock.unlock() }; return storage }
    func record(sql: String, steps: Int32) {
        lock.lock(); defer { lock.unlock() }
        storage.append((sql, steps))
    }
}

private actor AutomaticAudioReadGate {
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { open = true; continuation?.resume(); continuation = nil }
}
