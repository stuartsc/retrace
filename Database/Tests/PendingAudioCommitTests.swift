import XCTest
import Shared
import SQLCipher
@testable import Database

final class PendingAudioCommitTests: XCTestCase {
    private var database: DatabaseManager!
    private var queries: AudioTranscriptionQueries!
    private var connection: OpaquePointer!
    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:pending_audio_\(UUID().uuidString)?mode=memory&cache=shared")
        try await database.initialize()
        connection = await database.getConnection()
        queries = AudioTranscriptionQueries(db: connection)
    }
    override func tearDown() async throws { try await database.close() }

    func testCommitReplacesRawRowExactlyOnceAndKeepsCanonicalMedia() async throws {
        let pending = try await makePending()
        let committed = try await queries.completePendingRawBatch(pending, with: [record(pending)])
        XCTAssertTrue(committed)
        let replay = try await queries.completePendingRawBatch(pending, with: [record(pending)])
        XCTAssertFalse(replay)
        let remaining = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(remaining, 0)
        let rows = try await queries.getTranscriptions(from: pending.startTime, to: pending.endTime)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.audioPath, pending.audioPath)
    }

    func testDeletionDuringInferenceCannotResurrectAudio() async throws {
        let pending = try await makePending()
        try await queries.deleteTranscription(id: pending.id)
        let committed = try await queries.completePendingRawBatch(pending, with: [record(pending)])
        XCTAssertFalse(committed)
        let rows = try await queries.getTranscriptions(from: pending.startTime, to: pending.endTime)
        XCTAssertTrue(rows.isEmpty)
    }

    func testFailedInsertRollsBackSentencesAndKeepsRawPending() async throws {
        let pending = try await makePending()
        XCTAssertEqual(sqlite3_exec(connection, "CREATE TEMP TRIGGER fail_pending_test BEFORE INSERT ON audio_captures WHEN NEW.text = 'reject' BEGIN SELECT RAISE(ABORT, 'held insert'); END;", nil, nil, nil), SQLITE_OK)
        do {
            _ = try await queries.completePendingRawBatch(pending, with: [record(pending), record(pending, text: "reject")])
            XCTFail("injected second insert failure must propagate")
        } catch {}
        let remaining = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(remaining, 1)
        let rows = try await queries.getTranscriptions(from: pending.startTime, to: pending.endTime)
        XCTAssertTrue(rows.allSatisfy { $0.text.isEmpty })
    }

    func testConflictingSourceOrPathCannotReplacePendingRow() async throws {
        let pending = try await makePending()
        let conflicting = UntranscribedBatch(id: pending.id, startTime: pending.startTime,
            endTime: pending.endTime, source: .system, audioPath: "audio/batch_other.m4a", audioSize: pending.audioSize)
        let committed = try await queries.completePendingRawBatch(conflicting, with: [record(conflicting)])
        XCTAssertFalse(committed)
        let count = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(count, 1)
    }

    func testCancelledPermitCannotPublishOrConsumeRawRow() async throws {
        let pending = try await makePending()
        let cancellation = BackgroundProcessingCancellation()
        cancellation.cancel()
        do {
            _ = try await queries.completePendingRawBatch(pending, with: [record(pending)], cancellation: cancellation)
            XCTFail("Revoked native permission must be checked on the database actor")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected cancellation failure: \(error)") }
        let remaining = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(remaining, 1)
    }

    func testRetainedFirstPassRejectsStaleRawAndChangedRepairCompletions() async throws {
        let raw = try await makePending()
        let queued = try await queries.updatePendingRawBatchOutcome(raw, text: "Keep invoice number four seven.",
            transcriptStatus: "needs_repair", detectedLanguage: "nn", audioVariant: "raw",
            qualityFlags: AudioPreparationMetadata.firstPassRepairPending)
        XCTAssertTrue(queued)
        let selected = try await queries.getOldestUntranscribedBatch()
        let repair = try XCTUnwrap(selected)
        XCTAssertTrue(repair.needsFirstPassRepair)
        let staleRaw = try await queries.completePendingRawBatch(raw, with: [record(raw)])
        XCTAssertFalse(staleRaw, "An older raw snapshot cannot consume a newly retained first pass")
        guard !staleRaw else { return }

        try await queries.updateBatchOutcome(id: raw.id, text: "Corrected invoice number four eight.",
            transcriptStatus: "needs_repair", detectedLanguage: "en", audioVariant: "raw",
            qualityFlags: AudioPreparationMetadata.firstPassRepairPending)
        let staleRepair = try await queries.completePendingRawBatch(repair, with: [record(repair)])
        XCTAssertFalse(staleRepair, "Repair must still match the candidate it ranked")
        let rows = try await queries.getUntranscribedBatches(limit: 1)
        XCTAssertEqual(rows.first?.retainedFirstPass?.text, "Corrected invoice number four eight.")
        XCTAssertEqual(rows.first?.retainedFirstPass?.language, "en")
    }

    func testPreparationMetricsFollowCommittedOutcomesWithoutRecordingContent() async throws {
        _ = try await queries.insertRawBatch(startTime: Date(timeIntervalSince1970: 1_000),
            endTime: Date(timeIntervalSince1970: 1_010), source: .microphone,
            audioPath: "audio/batch_private.m4a", audioSize: 100, deferForLowEnergy: true)
        let rawRows = try await queries.getUntranscribedBatches(limit: 1)
        let raw = try XCTUnwrap(rawRows.first)
        _ = try await queries.updatePendingRawBatchOutcome(raw, text: "Private provisional text.",
            transcriptStatus: "needs_repair", detectedLanguage: "nn", audioVariant: "raw",
            qualityFlags: AudioPreparationMetadata.firstPassRepairPending)
        let selected = try await queries.getOldestUntranscribedBatch()
        let repair = try XCTUnwrap(selected)
        let token = BackgroundProcessingCancellation()
        await queries.setPendingTransactionWillCommitForTesting { token.cancel() }
        do {
            _ = try await queries.completePendingRawBatch(repair, with: [record(repair)], cancellation: token)
            XCTFail("Cancelled outcome must not be counted as completed")
        } catch is CancellationError {}
        await queries.setPendingTransactionWillCommitForTesting(nil)
        XCTAssertEqual(try preparationMetrics(), [
            "{\"outcome\":\"saved_low_energy\",\"source\":\"microphone\"}",
            "{\"outcome\":\"repair_queued\",\"source\":\"microphone\"}"
        ])
        _ = try await queries.completePendingRawBatch(repair, with: [record(repair)])
        XCTAssertEqual(try preparationMetrics().last,
            "{\"outcome\":\"repair_completed\",\"source\":\"microphone\"}")
        XCTAssertEqual(try preparationMetrics().count, 3)
    }

    private func preparationMetrics() throws -> [String] {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection,
            "SELECT metadata FROM daily_metrics WHERE metricType = 'audio_preparation' ORDER BY id", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        return result
    }

    func testPendingIdentityRetainsSQLiteMillisecondsWithoutDateRoundTrip() async throws {
        let pending = try await makePending()
        // NSDate's internal reference epoch can lose a fraction when reconstructing this date.
        XCTAssertEqual(sqlite3_exec(connection, "UPDATE audio_captures SET start_time = 10000002, end_time = 10001004;", nil, nil, nil), SQLITE_OK)
        let fetched = try await queries.getUntranscribedBatches(limit: 1)
        let exact = try XCTUnwrap(fetched.first)
        XCTAssertEqual(exact.id, pending.id)
        XCTAssertEqual(exact.startTimeMilliseconds, 10_000_002)
        XCTAssertEqual(exact.endTimeMilliseconds, 10_001_004)
        let completed = try await queries.completePendingRawBatch(exact, with: [record(exact)])
        XCTAssertTrue(completed)
    }

    func testCancellationRollbackCannotEraseAnotherActorsSuccessfulWrite() async throws {
        let pending = try await makePending()
        let token = BackgroundProcessingCancellation()
        let held = expectation(description: "Pending transaction reaches precommit")
        let writerStarted = expectation(description: "Other actor attempts write")
        let otherCompletedWhileHeld = expectation(description: "Other write must wait for transaction mutex")
        otherCompletedWhileHeld.isInverted = true
        let release = DispatchSemaphore(value: 0)
        let completed = PendingAudioCompletionFlag()
        let released = PendingAudioCompletionFlag()
        await queries.setPendingTransactionWillCommitForTesting {
            held.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        let queries = try XCTUnwrap(self.queries)
        let rows = [record(pending)]
        let first = Task {
            try await queries.completePendingRawBatch(pending, with: rows, cancellation: token)
        }
        await fulfillment(of: [held], timeout: 3)
        let mutex = try XCTUnwrap(sqlite3_db_mutex(connection))
        let probe = sqlite3_mutex_try(mutex)
        if probe == SQLITE_OK { sqlite3_mutex_leave(mutex) }
        XCTAssertEqual(probe, SQLITE_BUSY, "Other connection owners must be excluded for the complete transaction")
        let other = AudioTranscriptionQueries(db: connection)
        let second = Task {
            writerStarted.fulfill()
            let id = try await other.insertRawBatch(startTime: Date(timeIntervalSince1970: 2_000),
                endTime: Date(timeIntervalSince1970: 2_001), source: .microphone,
                audioPath: "audio/batch_concurrent.m4a", audioSize: 200)
            completed.set()
            if !released.value { otherCompletedWhileHeld.fulfill() }
            return id
        }
        await fulfillment(of: [writerStarted], timeout: 1)
        await fulfillment(of: [otherCompletedWhileHeld], timeout: 0.15)
        XCTAssertFalse(completed.value)
        token.cancel()
        released.set()
        release.signal()
        do {
            _ = try await first.value
            XCTFail("Revoked transaction must roll back")
        } catch is CancellationError {}
        let otherID = try await second.value
        await queries.setPendingTransactionWillCommitForTesting(nil)
        let remaining = try await queries.getUntranscribedBatches(limit: 10)
        XCTAssertEqual(Set(remaining.map(\.id)), Set([pending.id, otherID]),
            "An already successful write from another actor must survive cancellation rollback")
    }

    private func makePending() async throws -> UntranscribedBatch {
        _ = try await queries.insertRawBatch(startTime: Date(timeIntervalSince1970: 1_000),
            endTime: Date(timeIntervalSince1970: 1_010), source: .microphone,
            audioPath: "audio/batch_1000.m4a", audioSize: 100)
        let rows = try await queries.getUntranscribedBatches(limit: 1)
        return try XCTUnwrap(rows.first)
    }
    private func record(_ batch: UntranscribedBatch, text: String = "The invoice total is twelve dollars.") -> AudioTranscriptionQueries.TranscriptionBatchRecord {
        (sessionID: nil, text: text, startTime: batch.startTime, endTime: batch.endTime,
         source: batch.source, confidence: 0.9, words: [], audioPath: batch.audioPath,
         transcriptionPass: 1, batchAudioPath: batch.audioPath, transcriptStatus: "transcribed",
         detectedLanguage: "en", audioVariant: "raw", qualityFlags: nil)
    }
}

private final class PendingAudioCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
    func set() { lock.lock(); storage = true; lock.unlock() }
}
