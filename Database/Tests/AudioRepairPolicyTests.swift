import XCTest
import Database
import Shared
import SQLCipher

final class AudioRepairPolicyTests: XCTestCase {
    private var database: DatabaseManager!

    override func setUp() async throws {
        let path = "file:audio_repair_policy_tests_\(UUID().uuidString)?mode=memory&cache=shared"
        database = DatabaseManager(databasePath: path)
        try await database.initialize()
    }

    override func tearDown() async throws {
        try await database.close()
        database = nil
    }

    func testTranscriptionMetadataIsPersistedAndLoaded() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 10_000)

        _ = try await queries.insertTranscription(
            sessionID: nil,
            text: "短い日本語",
            startTime: start,
            endTime: start.addingTimeInterval(1),
            source: .microphone,
            confidence: 0.7,
            words: [],
            transcriptStatus: "needs_review",
            detectedLanguage: "ja",
            audioVariant: "normalized",
            qualityFlags: "short_text"
        )

        let rows = try await queries.getTranscriptions(
            from: start.addingTimeInterval(-1),
            to: start.addingTimeInterval(2)
        )

        XCTAssertEqual(rows.first?.transcriptStatus, "needs_review")
        XCTAssertEqual(rows.first?.detectedLanguage, "ja")
        XCTAssertEqual(rows.first?.audioVariant, "normalized")
        XCTAssertEqual(rows.first?.qualityFlags, "short_text")
    }

    func testWordTimingDoesNotCreateHiddenTranscriptRows() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 15_000)

        _ = try await queries.insertTranscription(
            sessionID: nil,
            text: "keep the complete sentence",
            startTime: start,
            endTime: start.addingTimeInterval(2),
            source: .microphone,
            confidence: 0.9,
            words: [
                TranscriptionWord(word: "keep", start: 0, end: 0.4, confidence: 0.9),
                TranscriptionWord(word: "sentence", start: 1, end: 1.8, confidence: 0.9)
            ],
            batchAudioPath: "audio/2026/08/26/batch_15000000_microphone_test.m4a"
        )

        let sentenceCount = try await countAudioRows(where: "source != 'word'")
        let hiddenWordCount = try await countAudioRows(where: "source = 'word'")

        XCTAssertEqual(sentenceCount, 1)
        XCTAssertEqual(hiddenWordCount, 0)
    }

    func testHistoricalPlaceholdersCanBeMarkedPendingForRepair() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 20_000)
        let batchID = try await queries.insertRawBatch(
            startTime: start,
            endTime: start.addingTimeInterval(30),
            source: .microphone,
            audioPath: "audio/batch_20000000_microphone_test.m4a",
            audioSize: 1024
        )
        try await queries.updateBatchOutcome(
            id: batchID,
            text: "[silence]",
            transcriptStatus: "probable_silence",
            detectedLanguage: nil,
            audioVariant: "raw",
            qualityFlags: "legacy_placeholder"
        )

        let marked = try await queries.markHistoricalPlaceholdersPendingForRepair(
            from: start.addingTimeInterval(-1),
            to: start.addingTimeInterval(31),
            limit: 10
        )
        let pending = try await queries.getUntranscribedBatches(limit: 10)

        XCTAssertEqual(marked, 1)
        XCTAssertEqual(pending.map(\.id), [batchID])
    }

    func testFreshRawBatchStartsPending() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 30_000)

        let batchID = try await queries.insertRawBatch(
            startTime: start,
            endTime: start.addingTimeInterval(30),
            source: .microphone,
            audioPath: "audio/batch_30000000_microphone_test.m4a",
            audioSize: 2048
        )

        let status = try await transcriptStatus(for: batchID)

        XCTAssertEqual(status, "pending")
    }

    func testClassifiedEmptyBatchIsNotAutoSelectedUntilMarkedForRepair() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 35_000)
        let batchID = try await queries.insertRawBatch(
            startTime: start,
            endTime: start.addingTimeInterval(30),
            source: .microphone,
            audioPath: "audio/batch_35000000_microphone_test.m4a",
            audioSize: 2048
        )
        try await queries.updateBatchOutcome(
            id: batchID,
            text: "",
            transcriptStatus: "needs_review",
            detectedLanguage: "nn",
            audioVariant: "raw",
            qualityFlags: "empty_text,speech_energy"
        )

        let automaticPending = try await queries.getUntranscribedBatches(limit: 10)
        XCTAssertTrue(automaticPending.isEmpty)

        let marked = try await queries.markHistoricalPlaceholdersPendingForRepair(
            from: start.addingTimeInterval(-1),
            to: start.addingTimeInterval(31),
            limit: 10
        )
        let repairPending = try await queries.getUntranscribedBatches(limit: 10)

        XCTAssertEqual(marked, 1)
        XCTAssertEqual(repairPending.map(\.id), [batchID])
    }

    func testPass2RefinementPreservesPass1RowsButRemovesBatchFromPass1Candidates() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 40_000)
        let batchPath = "audio/batch_40000000_microphone_test.m4a"

        _ = try await queries.insertTranscription(
            sessionID: nil,
            text: "old pass one",
            startTime: start,
            endTime: start.addingTimeInterval(1),
            source: .microphone,
            confidence: 0.6,
            words: [TranscriptionWord(word: "old", start: 0, end: 0.5, confidence: 0.6)],
            transcriptionPass: 1,
            batchAudioPath: batchPath
        )

        let insertedIDs = try await queries.replacePass1RecordsForBatch(
            batchAudioPath: batchPath,
            with: [makeTranscription(
                text: "new pass two",
                start: start,
                pass: 2,
                batchPath: batchPath,
                word: "new"
            )]
        )

        XCTAssertEqual(insertedIDs.count, 1)
        let oldSentenceCount = try await countAudioRows(where: "text = 'old pass one'")
        let oldWordCount = try await countAudioRows(where: "source = 'word' AND text = 'old'")
        let newSentenceCount = try await countAudioRows(where: "transcription_pass = 2 AND text = 'new pass two'")
        let newWordCount = try await countAudioRows(where: "source = 'word' AND batch_audio_path = '\(batchPath)' AND transcription_pass = 2 AND text = 'new'")
        let candidates = try await queries.getDistinctBatchPathsForRefinement(limit: 10)

        XCTAssertEqual(oldSentenceCount, 1)
        XCTAssertEqual(oldWordCount, 0)
        XCTAssertEqual(newSentenceCount, 1)
        XCTAssertEqual(newWordCount, 0)
        XCTAssertFalse(candidates.contains(batchPath))
    }

    func testPass3RefinementPreservesPass2RowsButRemovesBatchFromPass2Candidates() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 50_000)
        let batchPath = "audio/batch_50000000_microphone_test.m4a"

        _ = try await queries.insertTranscription(
            sessionID: nil,
            text: "old pass two",
            startTime: start,
            endTime: start.addingTimeInterval(1),
            source: .microphone,
            confidence: 0.6,
            words: [TranscriptionWord(word: "stale", start: 0, end: 0.5, confidence: 0.6)],
            transcriptionPass: 2,
            batchAudioPath: batchPath
        )

        let insertedIDs = try await queries.replacePass2RecordsForBatch(
            batchAudioPath: batchPath,
            with: [makeTranscription(
                text: "new pass three",
                start: start,
                pass: 3,
                batchPath: batchPath,
                word: "fresh"
            )]
        )

        XCTAssertEqual(insertedIDs.count, 1)
        let oldSentenceCount = try await countAudioRows(where: "text = 'old pass two'")
        let oldWordCount = try await countAudioRows(where: "source = 'word' AND text = 'stale'")
        let newSentenceCount = try await countAudioRows(where: "transcription_pass = 3 AND text = 'new pass three'")
        let newWordCount = try await countAudioRows(where: "source = 'word' AND batch_audio_path = '\(batchPath)' AND transcription_pass = 3 AND text = 'fresh'")
        let candidates = try await queries.getDistinctBatchPathsForContextualRefinement(limit: 10)

        XCTAssertEqual(oldSentenceCount, 1)
        XCTAssertEqual(oldWordCount, 0)
        XCTAssertEqual(newSentenceCount, 1)
        XCTAssertEqual(newWordCount, 0)
        XCTAssertFalse(candidates.contains(batchPath))
    }

    func testFailedPass1CandidateIsRetiredFromRefinementQuery() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 60_000)
        let batchPath = "audio/batch_60000000_microphone_test.m4a"

        _ = try await queries.insertTranscription(
            sessionID: nil,
            text: "candidate",
            startTime: start,
            endTime: start.addingTimeInterval(1),
            source: .microphone,
            confidence: 0.6,
            words: [],
            transcriptionPass: 1,
            batchAudioPath: batchPath
        )

        let candidatesBeforeMark = try await queries.getDistinctBatchPathsForRefinement(limit: 10)
        XCTAssertEqual(candidatesBeforeMark, [batchPath])

        try await queries.markBatchRefinementAttempted(
            batchAudioPath: batchPath,
            transcriptionPass: 1,
            transcriptStatus: "refinement_failed",
            qualityFlag: "missing_file"
        )

        let candidatesAfterMark = try await queries.getDistinctBatchPathsForRefinement(limit: 10)
        XCTAssertEqual(candidatesAfterMark, [])
    }

    func testSkippedPass2CandidateIsRetiredFromContextualQuery() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 70_000)
        let batchPath = "audio/batch_70000000_microphone_test.m4a"

        _ = try await queries.insertTranscription(
            sessionID: nil,
            text: "candidate",
            startTime: start,
            endTime: start.addingTimeInterval(1),
            source: .microphone,
            confidence: 0.6,
            words: [],
            transcriptionPass: 2,
            batchAudioPath: batchPath
        )

        let candidatesBeforeMark = try await queries.getDistinctBatchPathsForContextualRefinement(limit: 10)
        XCTAssertEqual(candidatesBeforeMark, [batchPath])

        try await queries.markBatchRefinementAttempted(
            batchAudioPath: batchPath,
            transcriptionPass: 2,
            transcriptStatus: "refinement_skipped",
            qualityFlag: "no_context"
        )

        let candidatesAfterMark = try await queries.getDistinctBatchPathsForContextualRefinement(limit: 10)
        XCTAssertEqual(candidatesAfterMark, [])
    }

    func testRefinementCandidatesExcludeNoiseAndReviewRows() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 72_000)

        let rows: [(text: String, status: String, flags: String?, batchPath: String)] = [
            ("readable speech should refine", "transcribed", nil, "audio/batch_72000000_microphone_clean.m4a"),
            ("(footsteps)", "needs_review", "short_text,variant:raw", "audio/batch_72000001_microphone_review.m4a"),
            ("(footsteps) (bell rings)", "probable_junk", "junk_pattern,variant:raw", "audio/batch_72000002_microphone_junk.m4a"),
            ("Mills, ¿is it please, sir?", "language_uncertain", "language_uncertain,variant:raw", "audio/batch_72000003_microphone_uncertain.m4a"),
            ("[silence]", "probable_silence", "low_energy", "audio/batch_72000004_microphone_silence.m4a"),
            ("( Meaning No audio )", "transcribed", nil, "audio/batch_72000005_microphone_no_audio.m4a"),
            ("(fire crackling)", "transcribed", nil, "audio/batch_72000006_microphone_fire.m4a")
        ]

        for (index, row) in rows.enumerated() {
            _ = try await queries.insertTranscription(
                sessionID: nil,
                text: row.text,
                startTime: start.addingTimeInterval(Double(index)),
                endTime: start.addingTimeInterval(Double(index + 1)),
                source: .microphone,
                confidence: 0.6,
                words: [],
                transcriptionPass: 1,
                batchAudioPath: row.batchPath,
                transcriptStatus: row.status,
                detectedLanguage: "en",
                qualityFlags: row.flags
            )
        }

        let candidates = try await queries.getDistinctBatchPathsForRefinement(limit: 10)

        XCTAssertEqual(candidates, ["audio/batch_72000000_microphone_clean.m4a"])
    }

    func testContextualRefinementCandidatesExcludeNoiseAndReviewRows() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 73_000)

        let rows: [(text: String, status: String, flags: String?, batchPath: String)] = [
            ("readable pass two speech should refine", "transcribed", nil, "audio/batch_73000000_microphone_clean.m4a"),
            ("No.", "needs_review", "short_text,variant:raw", "audio/batch_73000001_microphone_review.m4a"),
            ("ʕ ʕ ʕ ʕ ʕ", "probable_junk", "vocalization_artifact,variant:raw", "audio/batch_73000002_microphone_junk.m4a"),
            ("garbled language guess", "language_uncertain", "language_uncertain,variant:raw", "audio/batch_73000003_microphone_uncertain.m4a")
        ]

        for (index, row) in rows.enumerated() {
            _ = try await queries.insertTranscription(
                sessionID: nil,
                text: row.text,
                startTime: start.addingTimeInterval(Double(index)),
                endTime: start.addingTimeInterval(Double(index + 1)),
                source: .microphone,
                confidence: 0.6,
                words: [],
                transcriptionPass: 2,
                batchAudioPath: row.batchPath,
                transcriptStatus: row.status,
                detectedLanguage: "en",
                qualityFlags: row.flags
            )
        }

        let candidates = try await queries.getDistinctBatchPathsForContextualRefinement(limit: 10)

        XCTAssertEqual(candidates, ["audio/batch_73000000_microphone_clean.m4a"])
    }

    func testResetStalePipelineRecordsDoesNotCreateWordRows() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 80_000)
        let batchPath = "audio/batch_80000000_microphone_test.m4a"

        _ = try await queries.insertTranscription(
            sessionID: nil,
            text: "stale refined text",
            startTime: start,
            endTime: start.addingTimeInterval(1),
            source: .microphone,
            confidence: 0.6,
            words: [TranscriptionWord(word: "stale", start: 0, end: 0.5, confidence: 0.6)],
            transcriptionPass: 2,
            batchAudioPath: batchPath,
            pipelineVersion: CURRENT_PIPELINE_VERSION - 1
        )

        let result = try await queries.resetStalePipelineRecords()

        let resetSentenceCount = try await countAudioRows(
            where: "source != 'word' AND text = 'stale refined text' AND transcription_pass = 1"
        )
        let preservedWordCount = try await countAudioRows(
            where: "source = 'word' AND text = 'stale' AND batch_audio_path = '\(batchPath)' AND transcription_pass = 1"
        )

        XCTAssertEqual(result.resetCount, 1)
        XCTAssertEqual(result.resetWords, 0)
        XCTAssertEqual(resetSentenceCount, 1)
        XCTAssertEqual(preservedWordCount, 0)
    }

    private func makeQueries() async throws -> AudioTranscriptionQueries {
        guard let db = await database.getConnection() else {
            XCTFail("database connection missing")
            throw DatabaseError.connectionFailed(underlying: "database connection missing")
        }
        return AudioTranscriptionQueries(db: db)
    }

    private func transcriptStatus(for id: Int64) async throws -> String? {
        guard let db = await database.getConnection() else {
            throw DatabaseError.connectionFailed(underlying: "database connection missing")
        }

        let sql = "SELECT transcript_status FROM audio_captures WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }

    private func makeTranscription(
        text: String,
        start: Date,
        pass: Int,
        batchPath: String,
        word: String
    ) -> (
        sessionID: String?,
        text: String,
        startTime: Date,
        endTime: Date,
        source: AudioSource,
        confidence: Double?,
        words: [TranscriptionWord],
        audioPath: String?,
        transcriptionPass: Int,
        batchAudioPath: String?,
        transcriptStatus: String,
        detectedLanguage: String?,
        audioVariant: String,
        qualityFlags: String?
    ) {
        (
            sessionID: nil,
            text: text,
            startTime: start,
            endTime: start.addingTimeInterval(1),
            source: .microphone,
            confidence: 0.8,
            words: [TranscriptionWord(word: word, start: 0, end: 0.5, confidence: 0.8)],
            audioPath: nil,
            transcriptionPass: pass,
            batchAudioPath: batchPath,
            transcriptStatus: "transcribed",
            detectedLanguage: "en",
            audioVariant: "raw",
            qualityFlags: nil
        )
    }

    private func countAudioRows(where predicate: String) async throws -> Int {
        guard let db = await database.getConnection() else {
            throw DatabaseError.connectionFailed(underlying: "database connection missing")
        }

        let sql = "SELECT COUNT(*) FROM audio_captures WHERE \(predicate);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int(stmt, 0))
    }
}
