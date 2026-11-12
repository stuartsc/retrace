import Foundation
import SQLCipher
import Shared

/// Current pipeline version — bump this whenever transcription logic changes
/// (sentence segmentation thresholds, overlap merge, whisper params, etc.)
/// Records with pipeline_version < CURRENT_PIPELINE_VERSION are auto-reset
/// to pass-1 at startup so they get re-processed with the current logic.
///
/// Version history:
/// - 1: Initial (pre-overlap-merge, pre-suppress_nst-fix)
/// - 2: Audio overlap merge in pass-2/pass-3 + suppress_nst=false + relaxed sentence segmentation
///      (REGRESSED: audio overlap prepend in refinement caused jumbled output)
/// - 3: Text-only initial_prompt in pass-2/pass-3, no audio prepend (fixes jumbling)
/// - 4: Recall-first transcription: no pre-transcription silence gate, metadata status/provenance
/// - 5: Recall-first whisper params: decoder no-speech gate disabled for quiet speech
/// - 6: Auto language maps to multilingual transcription, not detect-language-only mode
/// - 7: Sound-effect captions stay out of live transcripts; refinement skips noise/review rows
/// - 8: Short wrapped ambient captions like "(fire crackling)" are treated as repair artifacts
/// - 9: Punctuation-only decoder artifacts like "[" and "]" are treated as junk
public let CURRENT_PIPELINE_VERSION: Int = 9

/// Content-free failures for bounded context reads. Busy means the connection
/// mutex was unavailable before any query work began; callers may retry briefly.
public enum AudioContextReadError: Error, Sendable, Equatable {
    case connectionBusy
    case budgetExceeded
    case invalidContinuation
    case closed
}

/// Database queries for audio transcription storage and retrieval
/// Owner: DATABASE agent
public actor AudioTranscriptionQueries {

    /// Includes the unconsumed lookahead row. No request drains old history to
    /// prove that a long recording cannot overlap the selected interval.
    public nonisolated static let contextCandidateLimit = 512

    private let db: OpaquePointer
    private let contextReaderID = UUID()
    #if DEBUG
    private var pendingTransactionWillCommitForTesting: (@Sendable () -> Void)?
    func setPendingTransactionWillCommitForTesting(_ hook: (@Sendable () -> Void)?) {
        pendingTransactionWillCommitForTesting = hook
    }
    #endif

    public init(db: OpaquePointer) {
        self.db = db
    }

    public typealias TranscriptionBatchRecord = (
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
    )

    /// Replace an exact, still-pending raw row once. No transaction suspension or schema change.
    public func completePendingRawBatch(
        _ batch: UntranscribedBatch,
        with transcriptions: [TranscriptionBatchRecord],
        cancellation: BackgroundProcessingCancellation? = nil
    ) throws -> Bool {
        guard !transcriptions.isEmpty else { return false }
        guard transcriptions.count <= 1_024, transcriptions.allSatisfy({
            $0.batchAudioPath == batch.audioPath && $0.audioPath == batch.audioPath &&
            $0.source == batch.source && $0.transcriptionPass == 1
        }) else {
            throw DatabaseError.queryExecutionFailed("Pending audio completion must retain its canonical media/source")
        }
        return try mutatePendingRawBatch(batch, cancellation: cancellation) {
            for item in transcriptions {
                _ = try insertTranscription(sessionID: item.sessionID, text: item.text,
                    startTime: item.startTime, endTime: item.endTime, source: item.source,
                    confidence: item.confidence, words: item.words, audioPath: item.audioPath,
                    transcriptionPass: item.transcriptionPass, batchAudioPath: item.batchAudioPath,
                    transcriptStatus: item.transcriptStatus, detectedLanguage: item.detectedLanguage,
                    audioVariant: item.audioVariant, qualityFlags: item.qualityFlags)
            }
            try deleteTranscription(id: batch.id)
            if batch.needsFirstPassRepair {
                recordPreparationMetric(outcome: "repair_completed", source: batch.source)
            }
        }
    }

    /// Classify only the same pending row; deleted/completed audio cannot be resurrected.
    public func updatePendingRawBatchOutcome(
        _ batch: UntranscribedBatch, text: String, transcriptStatus: String,
        detectedLanguage: String?, audioVariant: String, qualityFlags: String?,
        cancellation: BackgroundProcessingCancellation? = nil
    ) throws -> Bool {
        try mutatePendingRawBatch(batch, cancellation: cancellation) {
            try updateBatchOutcome(id: batch.id, text: text, transcriptStatus: transcriptStatus,
                detectedLanguage: detectedLanguage, audioVariant: audioVariant, qualityFlags: qualityFlags)
            if transcriptStatus == "needs_repair",
               qualityFlags?.split(separator: ",").contains(Substring(AudioPreparationMetadata.firstPassRepairPending)) == true {
                recordPreparationMetric(outcome: "repair_queued", source: batch.source)
            } else if batch.needsFirstPassRepair {
                recordPreparationMetric(outcome: transcriptStatus == "decode_failed"
                    ? "repair_decode_failed" : "repair_completed", source: batch.source)
            }
        }
    }

    private func recordPreparationMetric(outcome: String, source: AudioSource) {
        // Categorical accounting must not prevent durable recording or expose
        // captured text, timestamps, names or media paths.
        do {
            try DailyMetricsQueries.recordEvent(db: db, metricType: .audioPreparation,
                metadata: "{\"outcome\":\"\(outcome)\",\"source\":\"\(source.rawValue)\"}")
        } catch {
            Log.warning("[AudioTranscriptionQueries] Preparation metric could not be recorded", category: .database)
        }
    }

    private func mutatePendingRawBatch(_ batch: UntranscribedBatch,
        cancellation: BackgroundProcessingCancellation?, operation: () throws -> Void) throws -> Bool {
        func checkCancellation() throws {
            try Task.checkCancellation()
            if cancellation?.isCancelled == true { throw CancellationError() }
        }
        try checkCancellation()
        // FULLMUTEX serializes individual SQLite calls. Keep its recursive mutex for
        // the complete transaction so another actor sharing this pointer cannot write
        // into a transaction whose cancellation may roll back.
        guard let mutex = sqlite3_db_mutex(db) else {
            throw DatabaseError.queryExecutionFailed("Pending audio requires a serialized SQLite connection")
        }
        sqlite3_mutex_enter(mutex)
        defer { sqlite3_mutex_leave(mutex) }
        try checkCancellation()
        try executeStatement("BEGIN IMMEDIATE TRANSACTION;")
        var committed = false
        defer { if !committed { try? executeStatement("ROLLBACK;") } }
        guard try pendingRawBatchMatches(batch) else { return false }
        try operation()
        #if DEBUG
        pendingTransactionWillCommitForTesting?()
        #endif
        try checkCancellation()
        try executeStatement("COMMIT;")
        committed = true
        return true
    }

    private func pendingRawBatchMatches(_ batch: UntranscribedBatch) throws -> Bool {
        let sql = """
            SELECT 1 FROM audio_captures WHERE id = ? AND audio_path = ? AND source = ?
            AND start_time = ? AND end_time = ? AND audio_size = ?
            AND transcript_status IN ('pending', 'needs_repair')
            AND (transcript_status = 'needs_repair' AND
                 instr(',' || COALESCE(quality_flags, '') || ',', ',\(AudioPreparationMetadata.firstPassRepairPending),') > 0) = ?
            \(batch.retainedFirstPass == nil ? "" : "AND text = ? AND detected_language IS ?")
            LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, batch.id)
        sqlite3_bind_text(statement, 2, batch.audioPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, batch.source.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 4, batch.startTimeMilliseconds)
        sqlite3_bind_int64(statement, 5, batch.endTimeMilliseconds)
        sqlite3_bind_int64(statement, 6, batch.audioSize)
        sqlite3_bind_int(statement, 7, batch.needsFirstPassRepair ? 1 : 0)
        if let retained = batch.retainedFirstPass {
            sqlite3_bind_text(statement, 8, retained.text, -1, SQLITE_TRANSIENT)
            if let language = retained.language {
                sqlite3_bind_text(statement, 9, language, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 9)
            }
        }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }
        return result == SQLITE_ROW
    }

    // MARK: - Insert Transcription

    /// Insert a transcribed sentence. Word timing is used upstream for segmentation
    /// but is not duplicated into hidden FTS rows.
    public func insertTranscription(
        sessionID: String?,
        text: String,
        startTime: Date,
        endTime: Date,
        source: AudioSource,
        confidence: Double?,
        words: [TranscriptionWord],
        audioPath: String? = nil,
        transcriptionPass: Int = 1,
        batchAudioPath: String? = nil,
        transcriptStatus: String = "transcribed",
        detectedLanguage: String? = nil,
        audioVariant: String = "raw",
        qualityFlags: String? = nil,
        pipelineVersion: Int = CURRENT_PIPELINE_VERSION
    ) throws -> Int64 {
        // Insert the full transcription segment
        let sql = """
            INSERT INTO audio_captures (
                session_id, text, start_time, end_time, source, confidence, audio_path,
                transcription_pass, batch_audio_path, transcript_status, detected_language,
                audio_variant, quality_flags, pipeline_version
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        // Bind parameters
        if let sessionID = sessionID {
            sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_text(stmt, 2, text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, Schema.dateToTimestamp(startTime))
        sqlite3_bind_int64(stmt, 4, Schema.dateToTimestamp(endTime))
        sqlite3_bind_text(stmt, 5, source.rawValue, -1, SQLITE_TRANSIENT)
        if let confidence = confidence {
            sqlite3_bind_double(stmt, 6, confidence)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if let audioPath = audioPath {
            sqlite3_bind_text(stmt, 7, audioPath, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_bind_int(stmt, 8, Int32(transcriptionPass))
        if let batchAudioPath = batchAudioPath {
            sqlite3_bind_text(stmt, 9, batchAudioPath, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        sqlite3_bind_text(stmt, 10, transcriptStatus, -1, SQLITE_TRANSIENT)
        if let detectedLanguage {
            sqlite3_bind_text(stmt, 11, detectedLanguage, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 11)
        }
        sqlite3_bind_text(stmt, 12, audioVariant, -1, SQLITE_TRANSIENT)
        if let qualityFlags {
            sqlite3_bind_text(stmt, 13, qualityFlags, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 13)
        }
        sqlite3_bind_int(stmt, 14, Int32(pipelineVersion))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }

        let transcriptionID = sqlite3_last_insert_rowid(db)

        // Raw audio plus sentence boundaries are canonical and can regenerate word
        // timing. Production transcript/search queries exclude source='word', so
        // persisting those rows only multiplies database and FTS storage.
        _ = words

        return transcriptionID
    }

    /// Batch insert multiple transcriptions in a single transaction
    public func insertTranscriptionsBatch(
        _ transcriptions: [TranscriptionBatchRecord]
    ) throws -> [Int64] {
        guard !transcriptions.isEmpty else { return [] }

        // Begin transaction
        var beginStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "BEGIN TRANSACTION;", -1, &beginStmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(beginStmt) }
        guard sqlite3_step(beginStmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }

        var insertedIDs: [Int64] = []

        do {
            // Insert each transcription
            for transcription in transcriptions {
                let id = try insertTranscription(
                    sessionID: transcription.sessionID,
                    text: transcription.text,
                    startTime: transcription.startTime,
                    endTime: transcription.endTime,
                    source: transcription.source,
                    confidence: transcription.confidence,
                    words: transcription.words,
                    audioPath: transcription.audioPath,
                    transcriptionPass: transcription.transcriptionPass,
                    batchAudioPath: transcription.batchAudioPath,
                    transcriptStatus: transcription.transcriptStatus,
                    detectedLanguage: transcription.detectedLanguage,
                    audioVariant: transcription.audioVariant,
                    qualityFlags: transcription.qualityFlags
                )
                insertedIDs.append(id)
            }

            // Commit transaction
            var commitStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "COMMIT;", -1, &commitStmt, nil) == SQLITE_OK else {
                throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(commitStmt) }
            guard sqlite3_step(commitStmt) == SQLITE_DONE else {
                throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
            }

            return insertedIDs

        } catch {
            // Rollback on error
            var rollbackStmt: OpaquePointer?
            sqlite3_prepare_v2(db, "ROLLBACK;", -1, &rollbackStmt, nil)
            sqlite3_step(rollbackStmt)
            sqlite3_finalize(rollbackStmt)
            throw error
        }
    }

    /// Insert pass-2 rows for a batch while preserving pass-1 rows for audit/debugging.
    /// Product reads select the latest pass, so old passes are retained but not normally surfaced.
    @discardableResult
    public func replacePass1RecordsForBatch(
        batchAudioPath: String,
        with transcriptions: [TranscriptionBatchRecord]
    ) throws -> [Int64] {
        try insertVersionedRecordsForBatch(
            batchAudioPath: batchAudioPath,
            with: transcriptions
        )
    }

    /// Insert pass-3 rows for a batch while preserving pass-2 rows for audit/debugging.
    /// Product reads select the latest pass, so old passes are retained but not normally surfaced.
    @discardableResult
    public func replacePass2RecordsForBatch(
        batchAudioPath: String,
        with transcriptions: [TranscriptionBatchRecord]
    ) throws -> [Int64] {
        try insertVersionedRecordsForBatch(
            batchAudioPath: batchAudioPath,
            with: transcriptions
        )
    }

    private func insertVersionedRecordsForBatch(
        batchAudioPath: String,
        with transcriptions: [TranscriptionBatchRecord]
    ) throws -> [Int64] {
        guard !transcriptions.isEmpty else { return [] }
        guard transcriptions.allSatisfy({ $0.batchAudioPath == batchAudioPath }) else {
            throw DatabaseError.queryExecutionFailed("Replacement records must use the target batch audio path")
        }

        try executeStatement("BEGIN TRANSACTION;")
        var insertedIDs: [Int64] = []

        do {
            for transcription in transcriptions {
                let id = try insertTranscription(
                    sessionID: transcription.sessionID,
                    text: transcription.text,
                    startTime: transcription.startTime,
                    endTime: transcription.endTime,
                    source: transcription.source,
                    confidence: transcription.confidence,
                    words: transcription.words,
                    audioPath: transcription.audioPath,
                    transcriptionPass: transcription.transcriptionPass,
                    batchAudioPath: transcription.batchAudioPath,
                    transcriptStatus: transcription.transcriptStatus,
                    detectedLanguage: transcription.detectedLanguage,
                    audioVariant: transcription.audioVariant,
                    qualityFlags: transcription.qualityFlags
                )
                insertedIDs.append(id)
            }

            try executeStatement("COMMIT;")
            return insertedIDs
        } catch {
            try? executeStatement("ROLLBACK;")
            throw error
        }
    }

    private func executeStatement(_ sql: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func latestBatchPassPredicate(alias: String) -> String {
        """
            AND (
                \(alias).batch_audio_path IS NULL
                OR \(alias).batch_audio_path = ''
                OR \(alias).transcription_pass = (
                    SELECT MAX(latest.transcription_pass)
                    FROM audio_captures AS latest
                    WHERE latest.batch_audio_path = \(alias).batch_audio_path
                    AND latest.source != 'word'
                )
            )
        """
    }

    /// Insert a raw audio batch record (before transcription)
    /// Saves the audio file path so raw audio is never lost even if transcription fails.
    /// Low energy is a versioned scheduling hint, never a completed transcript outcome.
    @discardableResult
    public func insertRawBatch(
        startTime: Date,
        endTime: Date,
        source: AudioSource,
        audioPath: String,
        audioSize: Int64,
        deferForLowEnergy: Bool = false
    ) throws -> Int64 {
        guard let mutex = sqlite3_db_mutex(db) else {
            throw DatabaseError.queryExecutionFailed("Raw audio requires a serialized SQLite connection")
        }
        sqlite3_mutex_enter(mutex)
        defer { sqlite3_mutex_leave(mutex) }
        let sql = """
            INSERT INTO audio_captures (
                session_id, text, start_time, end_time, source, confidence, audio_path,
                audio_size, transcription_pass, pipeline_version, transcript_status, audio_variant, quality_flags
            ) VALUES (NULL, '', ?, ?, ?, NULL, ?, ?, 1, ?, 'pending', 'raw', ?);
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Schema.dateToTimestamp(startTime))
        sqlite3_bind_int64(stmt, 2, Schema.dateToTimestamp(endTime))
        sqlite3_bind_text(stmt, 3, source.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, audioPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 5, audioSize)
        sqlite3_bind_int(stmt, 6, Int32(CURRENT_PIPELINE_VERSION))
        if deferForLowEnergy {
            sqlite3_bind_text(stmt, 7, AudioPreparationMetadata.lowEnergyPending, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 7)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }

        let rawID = sqlite3_last_insert_rowid(db)
        recordPreparationMetric(outcome: deferForLowEnergy ? "saved_low_energy" : "saved_unclassified", source: source)
        return rawID
    }

    // MARK: - Query Transcriptions

    /// A bounded live read, not an immutable snapshot or durable evidence grant.
    /// The interval is half-open; entries retain their original full audio ranges.
    public func getContextPage(
        from startDate: Date, to endDate: Date, source: AudioSource? = nil,
        limit: Int = 100, before cursor: AudioContextCursor? = nil, query: String? = nil
    ) throws -> AudioContextPage {
        try withContextReadBudget {
            try readContextPage(from: startDate, to: endDate, source: source, limit: limit,
                before: cursor, query: query)
        }
    }

    private func readContextPage(
        from startDate: Date, to endDate: Date, source: AudioSource?,
        limit: Int, before cursor: AudioContextCursor?, query: String?
    ) throws -> AudioContextPage {
        try Task.checkCancellation()
        // Validate before converting Double dates to integer SQLite milliseconds.
        let seconds = [startDate.timeIntervalSince1970, endDate.timeIntervalSince1970]
        guard seconds.allSatisfy({ $0.isFinite && (-62_135_596_800...253_402_300_799).contains($0) }),
              startDate < endDate, (1...500).contains(limit) else {
            throw DatabaseError.queryExecutionFailed("Invalid context interval or page size")
        }
        let from = Schema.dateToTimestamp(startDate)
        let to = Schema.dateToTimestamp(endDate)
        let query = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard from < to, query.utf8.count <= 512, !query.contains("\0") else {
            throw DatabaseError.queryExecutionFailed("Invalid context interval or search phrase")
        }
        if let cursor {
            guard cursor.readerID == contextReaderID, cursor.from == from, cursor.to == to,
                  cursor.source == source, cursor.query == query else {
                throw AudioContextReadError.invalidContinuation
            }
        }
        // Bound chronological candidates before applying overlap/FTS/latest-pass
        // filters. Filtering first makes a final partial page scan the complete
        // historical tail through V23's start-time index. No lower start bound
        // is valid: a much earlier recording may still overlap this interval.
        var sql = "SELECT id,start_time,end_time,source FROM audio_captures WHERE start_time < ?"
        // V23's existing (start_time,end_time) index includes the rowid. Follow
        // its full order so even a large equal-start group needs no temp sort.
        if cursor != nil { sql += " AND start_time <= ? AND (start_time, end_time, id) < (?, ?, ?)" }
        sql += " ORDER BY start_time DESC, end_time DESC, id DESC LIMIT ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, to)
        var parameter: Int32 = 2
        if let cursor {
            sqlite3_bind_int64(statement, parameter, cursor.start)
            sqlite3_bind_int64(statement, parameter + 1, cursor.start)
            sqlite3_bind_int64(statement, parameter + 2, cursor.end)
            sqlite3_bind_int64(statement, parameter + 3, cursor.id)
            parameter += 4
        }
        sqlite3_bind_int(statement, parameter, Int32(Self.contextCandidateLimit))

        // Exact primary-key eligibility avoids reading captured text for the
        // rejected historical candidates. MATCH remains a bound literal phrase.
        var eligibilitySQL = "SELECT id FROM audio_captures WHERE id = ?"
            + Self.latestBatchPassPredicate(alias: "audio_captures")
        if !query.isEmpty {
            eligibilitySQL += " AND EXISTS (SELECT 1 FROM audio_captures_fts WHERE rowid = audio_captures.id AND audio_captures_fts MATCH ?)"
        }
        var eligibility: OpaquePointer?
        guard sqlite3_prepare_v2(db, eligibilitySQL, -1, &eligibility, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(eligibility) }
        if !query.isEmpty {
            let literal = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            sqlite3_bind_text(eligibility, 2, literal, -1, SQLITE_TRANSIENT)
        }
        var entries: [AudioTranscription] = []
        var lastInspected: (start: Int64, end: Int64, id: Int64)?
        var continuation: (start: Int64, end: Int64, id: Int64)?
        var scannedCandidates = 0
        var scanIncomplete = false
        while true {
            try Task.checkCancellation()
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else {
                throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
            }
            scannedCandidates += 1
            // Reserve the final raw candidate as an unconsumed lookahead. Its
            // existence proves only unchecked candidates, not matching results.
            if scannedCandidates == Self.contextCandidateLimit {
                continuation = lastInspected
                scanIncomplete = true
                break
            }
            let candidate = (start: sqlite3_column_int64(statement, 1), end: sqlite3_column_int64(statement, 2),
                id: sqlite3_column_int64(statement, 0))
            defer { lastInspected = candidate }
            guard sqlite3_column_type(statement, 2) != SQLITE_NULL,
                  sqlite3_column_int64(statement, 2) > from,
                  let rawSource = sqlite3_column_text(statement, 3) else { continue }
            let candidateSource = String(cString: rawSource)
            guard candidateSource != "word", source == nil || source?.rawValue == candidateSource else { continue }
            sqlite3_reset(eligibility)
            sqlite3_bind_int64(eligibility, 1, candidate.id)
            let eligible = sqlite3_step(eligibility)
            if eligible == SQLITE_DONE { continue }
            guard eligible == SQLITE_ROW else {
                throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
            }
            if entries.count == limit {
                // The matching sentinel must remain available on the next page.
                // Copy the prior inspected key before this iteration's defer.
                continuation = lastInspected
                break
            }
            if let row = try readContextEntry(id: candidate.id) { entries.append(row) }
        }
        let next = continuation.map {
            AudioContextCursor(readerID: contextReaderID, from: from, to: to, source: source,
                query: query, start: $0.start, end: $0.end, id: $0.id)
        }
        return AudioContextPage(entries: entries, nextCursor: next,
            scanIncomplete: scanIncomplete, scannedCandidates: scannedCandidates)
    }

    /// Re-read one current latest-pass row before an explicit action. Callers
    /// must compare it with the selected row and retain their source/lifetime fence.
    public func getContextEntry(id: Int64) throws -> AudioTranscription? {
        try withContextReadBudget { try readContextEntry(id: id) }
    }

    /// Exact original first-pass row for durable publication proofs. A later pass
    /// does not replace this identity. Callers compare the complete retained row.
    public func getRetainedFirstPassEntry(id: Int64) throws -> AudioTranscription? {
        try withContextReadBudget { try readContextEntry(id: id, latestOnly: false) }
    }

    /// Exact retained first-pass rows for one canonical AAC path. This is an internal publication
    /// boundary, not a search endpoint; callers must retain full-row source proofs.
    public func getContextBatchEntries(batchAudioPath: String) throws -> [AudioTranscription] {
        try withContextReadBudget {
            guard !batchAudioPath.isEmpty, batchAudioPath.utf8.count <= 1024, !batchAudioPath.contains("\0") else {
                throw DatabaseError.queryExecutionFailed("Invalid audio batch identity")
            }
            let sql = Self.contextColumns + " WHERE batch_audio_path = ? AND transcription_pass = 1 AND source != 'word' ORDER BY start_time,id LIMIT 1025"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, batchAudioPath, -1, SQLITE_TRANSIENT)
            var rows: [AudioTranscription] = []
            while true {
                try Task.checkCancellation()
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw DatabaseError.queryExecutionFailed("Audio batch snapshot unavailable") }
                rows.append(Self.contextEntry(statement))
                guard rows.count <= 1024 else { throw DatabaseError.queryExecutionFailed("Audio batch exceeds publication budget") }
            }
            return rows
        }
    }

    private func readContextEntry(id: Int64, latestOnly: Bool = true) throws -> AudioTranscription? {
        try Task.checkCancellation()
        let sql = Self.contextColumns + " WHERE id = ? AND source != 'word'"
            + (latestOnly ? Self.latestBatchPassPredicate(alias: "audio_captures") : " AND transcription_pass = 1")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { try Task.checkCancellation(); return nil }
        guard code == SQLITE_ROW else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }
        try Task.checkCancellation()
        return Self.contextEntry(statement)
    }

    /// This connection has no persistent progress handler. Hold its recursive
    /// mutex while installing/removing this request-local handler so another
    /// actor sharing the writer cannot use it. Noncritical UI reads fail busy
    /// rather than waiting behind a writer. VM deadlines are cooperative: native
    /// I/O is not a hard 250 ms wall-time guarantee.
    private func withContextReadBudget<T>(_ operation: () throws -> T) throws -> T {
        try Task.checkCancellation()
        guard let mutex = sqlite3_db_mutex(db), sqlite3_mutex_try(mutex) == SQLITE_OK else {
            throw AudioContextReadError.connectionBusy
        }
        defer { sqlite3_mutex_leave(mutex) }
        var deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        return try withUnsafeMutablePointer(to: &deadline) { pointer in
            sqlite3_progress_handler(db, 1_000, { context in
                guard let context else { return 1 }
                let deadline = context.assumingMemoryBound(to: ContinuousClock.Instant.self).pointee
                return Task.isCancelled || ContinuousClock.now >= deadline ? 1 : 0
            }, pointer)
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            do {
                let value = try operation()
                try Task.checkCancellation()
                return value
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if ContinuousClock.now >= pointer.pointee {
                    throw AudioContextReadError.budgetExceeded
                }
                throw error
            }
        }
    }

    private static let contextColumns = """
        SELECT id, session_id, text, start_time, end_time, source, confidence, created_at,
               audio_path, transcript_status, detected_language, audio_variant, quality_flags,
               transcription_pass, batch_audio_path FROM audio_captures
        """

    private static func contextEntry(_ statement: OpaquePointer?) -> AudioTranscription {
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        return AudioTranscription(id: sqlite3_column_int64(statement, 0), sessionID: text(1), text: text(2) ?? "",
            startTime: Schema.timestampToDate(sqlite3_column_int64(statement, 3)),
            endTime: Schema.timestampToDate(sqlite3_column_int64(statement, 4)),
            source: AudioSource(rawValue: text(5) ?? "") ?? .unknown,
            confidence: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 6),
            createdAt: Schema.timestampToDate(sqlite3_column_int64(statement, 7)),
            audioPath: text(8), batchAudioPath: text(14), transcriptStatus: text(9) ?? "transcribed",
            detectedLanguage: text(10), audioVariant: text(11) ?? "raw", qualityFlags: text(12),
            transcriptionPass: Int(sqlite3_column_int(statement, 13)))
    }

    /// Get transcriptions within a time range
    public func getTranscriptions(
        from startDate: Date,
        to endDate: Date,
        source: AudioSource? = nil,
        limit: Int = 100,
        offset: Int = 0,
        includeActivityRows: Bool = false
    ) throws -> [AudioTranscription] {
        var sql = """
            SELECT id, session_id, text, start_time, end_time, source, confidence, created_at,
                   audio_path, transcript_status, detected_language, audio_variant, quality_flags,
                   transcription_pass, batch_audio_path
            FROM audio_captures
            WHERE start_time >= ? AND end_time <= ?
            AND source != 'word'
            """

        if !includeActivityRows {
            sql += """
                AND text != ''
                AND text NOT IN ('[silence]', '[hallucination]', '[decode_error]')
                """
        }

        if source != nil {
            sql += " AND source = ?"
        }

        sql += Self.latestBatchPassPredicate(alias: "audio_captures")
        sql += " ORDER BY start_time DESC LIMIT ? OFFSET ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Schema.dateToTimestamp(startDate))
        sqlite3_bind_int64(stmt, 2, Schema.dateToTimestamp(endDate))

        var paramIndex = 3
        if let source = source {
            sqlite3_bind_text(stmt, Int32(paramIndex), source.rawValue, -1, SQLITE_TRANSIENT)
            paramIndex += 1
        }
        sqlite3_bind_int(stmt, Int32(paramIndex), Int32(max(limit, 0)))
        sqlite3_bind_int(stmt, Int32(paramIndex + 1), Int32(max(offset, 0)))

        var results: [AudioTranscription] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let sessionID = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let text = String(cString: sqlite3_column_text(stmt, 2))
            let startTime = Schema.timestampToDate(sqlite3_column_int64(stmt, 3))
            let endTime = Schema.timestampToDate(sqlite3_column_int64(stmt, 4))
            let sourceRaw = String(cString: sqlite3_column_text(stmt, 5))
            let confidence = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 6)
            let createdAt = Schema.timestampToDate(sqlite3_column_int64(stmt, 7))
            let audioPath = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            let transcriptStatus = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? "transcribed"
            let detectedLanguage = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
            let audioVariant = sqlite3_column_text(stmt, 11).map { String(cString: $0) } ?? "raw"
            let qualityFlags = sqlite3_column_text(stmt, 12).map { String(cString: $0) }
            let transcriptionPass = Int(sqlite3_column_int(stmt, 13))
            let batchAudioPath = sqlite3_column_text(stmt, 14).map { String(cString: $0) }

            results.append(AudioTranscription(
                id: id,
                sessionID: sessionID,
                text: text,
                startTime: startTime,
                endTime: endTime,
                source: AudioSource(rawValue: sourceRaw) ?? .microphone,
                confidence: confidence,
                createdAt: createdAt,
                audioPath: audioPath,
                batchAudioPath: batchAudioPath,
                transcriptStatus: transcriptStatus,
                detectedLanguage: detectedLanguage,
                audioVariant: audioVariant,
                qualityFlags: qualityFlags,
                transcriptionPass: transcriptionPass
            ))
        }

        return results
    }

    /// Search transcriptions by text (full-text search via FTS5)
    public func searchTranscriptions(
        query: String,
        from startDate: Date? = nil,
        to endDate: Date? = nil,
        limit: Int = 50
    ) throws -> [AudioTranscription] {
        var sql = """
            SELECT id, session_id, text, start_time, end_time, source, confidence, created_at,
                   audio_path, transcript_status, detected_language, audio_variant, quality_flags,
                   transcription_pass, batch_audio_path
            FROM audio_captures
            WHERE rowid IN (SELECT rowid FROM audio_captures_fts WHERE audio_captures_fts MATCH ?)
            AND source != 'word'
            """

        var paramIndex: Int32 = 2
        if startDate != nil {
            sql += " AND start_time >= ?"
            paramIndex += 1
        }
        if endDate != nil {
            sql += " AND end_time <= ?"
            paramIndex += 1
        }

        sql += Self.latestBatchPassPredicate(alias: "audio_captures")
        sql += " ORDER BY start_time DESC LIMIT ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, query, -1, SQLITE_TRANSIENT)

        var nextParam: Int32 = 2
        if let startDate = startDate {
            sqlite3_bind_int64(stmt, nextParam, Schema.dateToTimestamp(startDate))
            nextParam += 1
        }
        if let endDate = endDate {
            sqlite3_bind_int64(stmt, nextParam, Schema.dateToTimestamp(endDate))
            nextParam += 1
        }
        sqlite3_bind_int(stmt, nextParam, Int32(limit))

        var results: [AudioTranscription] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let sessionID = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let text = String(cString: sqlite3_column_text(stmt, 2))
            let startTime = Schema.timestampToDate(sqlite3_column_int64(stmt, 3))
            let endTime = Schema.timestampToDate(sqlite3_column_int64(stmt, 4))
            let sourceRaw = String(cString: sqlite3_column_text(stmt, 5))
            let confidence = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 6)
            let createdAt = Schema.timestampToDate(sqlite3_column_int64(stmt, 7))
            let audioPath = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            let transcriptStatus = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? "transcribed"
            let detectedLanguage = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
            let audioVariant = sqlite3_column_text(stmt, 11).map { String(cString: $0) } ?? "raw"
            let qualityFlags = sqlite3_column_text(stmt, 12).map { String(cString: $0) }
            let transcriptionPass = Int(sqlite3_column_int(stmt, 13))
            let batchAudioPath = sqlite3_column_text(stmt, 14).map { String(cString: $0) }

            results.append(AudioTranscription(
                id: id,
                sessionID: sessionID,
                text: text,
                startTime: startTime,
                endTime: endTime,
                source: AudioSource(rawValue: sourceRaw) ?? .microphone,
                confidence: confidence,
                createdAt: createdAt,
                audioPath: audioPath,
                batchAudioPath: batchAudioPath,
                transcriptStatus: transcriptStatus,
                detectedLanguage: detectedLanguage,
                audioVariant: audioVariant,
                qualityFlags: qualityFlags,
                transcriptionPass: transcriptionPass
            ))
        }

        return results
    }

    /// Get transcriptions for a specific session
    public func getTranscriptions(forSession sessionID: String) throws -> [AudioTranscription] {
        var sql = """
            SELECT id, session_id, text, start_time, end_time, source, confidence, created_at,
                   audio_path, transcript_status, detected_language, audio_variant, quality_flags,
                   transcription_pass, batch_audio_path
            FROM audio_captures
            WHERE session_id = ?
            """
        sql += Self.latestBatchPassPredicate(alias: "audio_captures")
        sql += " ORDER BY start_time ASC;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)

        var results: [AudioTranscription] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let sessionID = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let text = String(cString: sqlite3_column_text(stmt, 2))
            let startTime = Schema.timestampToDate(sqlite3_column_int64(stmt, 3))
            let endTime = Schema.timestampToDate(sqlite3_column_int64(stmt, 4))
            let sourceRaw = String(cString: sqlite3_column_text(stmt, 5))
            let confidence = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 6)
            let createdAt = Schema.timestampToDate(sqlite3_column_int64(stmt, 7))
            let audioPath = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            let transcriptStatus = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? "transcribed"
            let detectedLanguage = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
            let audioVariant = sqlite3_column_text(stmt, 11).map { String(cString: $0) } ?? "raw"
            let qualityFlags = sqlite3_column_text(stmt, 12).map { String(cString: $0) }
            let transcriptionPass = Int(sqlite3_column_int(stmt, 13))
            let batchAudioPath = sqlite3_column_text(stmt, 14).map { String(cString: $0) }

            results.append(AudioTranscription(
                id: id,
                sessionID: sessionID,
                text: text,
                startTime: startTime,
                endTime: endTime,
                source: AudioSource(rawValue: sourceRaw) ?? .microphone,
                confidence: confidence,
                createdAt: createdAt,
                audioPath: audioPath,
                batchAudioPath: batchAudioPath,
                transcriptStatus: transcriptStatus,
                detectedLanguage: detectedLanguage,
                audioVariant: audioVariant,
                qualityFlags: qualityFlags,
                transcriptionPass: transcriptionPass
            ))
        }

        return results
    }

    // MARK: - Delete Transcriptions

    /// Delete transcriptions older than a specific date
    public func deleteTranscriptions(olderThan date: Date) throws -> Int {
        let sql = "DELETE FROM audio_captures WHERE start_time < ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Schema.dateToTimestamp(date))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }

        return Int(sqlite3_changes(db))
    }

    /// Delete a single transcription record by ID
    @discardableResult
    public func deleteTranscription(id: Int64) throws -> Bool {
        let sql = "DELETE FROM audio_captures WHERE id = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, id)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }

        return sqlite3_changes(db) > 0
    }

    /// Update the text field of a transcription record (used to mark silence batches)
    public func updateTranscriptionText(id: Int64, text: String) throws {
        let sql = "UPDATE audio_captures SET text = ?, pipeline_version = ? WHERE id = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(CURRENT_PIPELINE_VERSION))
        sqlite3_bind_int64(stmt, 3, id)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Update the outcome metadata for a raw batch that did not produce sentence rows.
    public func updateBatchOutcome(
        id: Int64,
        text: String,
        transcriptStatus: String,
        detectedLanguage: String?,
        audioVariant: String,
        qualityFlags: String?
    ) throws {
        let sql = """
            UPDATE audio_captures
            SET text = ?,
                transcript_status = ?,
                detected_language = ?,
                audio_variant = ?,
                quality_flags = ?,
                pipeline_version = ?
            WHERE id = ?;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, transcriptStatus, -1, SQLITE_TRANSIENT)
        if let detectedLanguage {
            sqlite3_bind_text(stmt, 3, detectedLanguage, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_text(stmt, 4, audioVariant, -1, SQLITE_TRANSIENT)
        if let qualityFlags {
            sqlite3_bind_text(stmt, 5, qualityFlags, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_int(stmt, 6, Int32(CURRENT_PIPELINE_VERSION))
        sqlite3_bind_int64(stmt, 7, id)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Backfill Queries

    /// A bounded chronological lane for newly captured speech-like or unclassified
    /// audio. This narrow ordering window is not a first-pass eligibility expiry;
    /// getFirstPassPendingBatch also supplies older and quiet retained recordings.
    public func getFreshPendingBatch(now: Date = Date()) throws -> UntranscribedBatch? {
        let lower = now.addingTimeInterval(-120).timeIntervalSince1970 * 1_000
        let upper = now.timeIntervalSince1970 * 1_000
        guard lower.isFinite, upper.isFinite, lower >= Double(Int64.min), upper < Double(Int64.max) else {
            throw DatabaseError.queryExecutionFailed("Fresh audio selection requires a representable clock")
        }
        return try selectAutomaticBatch(status: "pending", newestFirst: false,
                                        timeRange: (Int64(lower), Int64(upper)), excludeLowEnergy: true)
    }

    /// Reads only the first limit + 1 indexed entries per status. It never counts
    /// the whole library, decodes media, or treats a failed read as an empty queue.
    public func getPendingAudioSummary(limit: Int = 1_000) throws -> AudioPreparationStatus {
        guard (1...1_000).contains(limit) else {
            throw DatabaseError.queryExecutionFailed("Audio summary limit must be between 1 and 1000")
        }
        func bounded(_ status: String) throws -> (Int, Bool, Date?) {
            try Task.checkCancellation()
            let sql = "SELECT start_time FROM audio_captures INDEXED BY idx_audio_captures_transcript_status WHERE transcript_status = ? ORDER BY start_time ASC LIMIT ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, status, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 2, Int32(limit + 1))
            var count = 0
            var oldest: Date?
            while true {
                try Task.checkCancellation()
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else {
                    throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
                }
                if count == 0 { oldest = Schema.timestampToDate(sqlite3_column_int64(statement, 0)) }
                count += 1
            }
            return (min(count, limit), count > limit, oldest)
        }
        let pending = try bounded("pending")
        let repair = try bounded("needs_repair")
        return .init(observedAt: Date(), pendingCountLowerBound: pending.0, hasMorePending: pending.1,
                     oldestPendingAt: pending.2, repairCountLowerBound: repair.0, hasMoreRepair: repair.1,
                     oldestRepairAt: repair.2)
    }

    /// First-pass eligibility never expires. Three recent speech-like turns are
    /// followed by an oldest pending turn in the owner, including quiet recordings.
    /// A hint only changes ordering; it never completes or removes a recording.
    public func getFirstPassPendingBatch(preferRecent: Bool = true, now: Date = Date()) throws -> UntranscribedBatch? {
        if preferRecent {
            if let fresh = try getFreshPendingBatch(now: now) { return fresh }
            let lower = now.addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970 * 1_000
            let upper = now.timeIntervalSince1970 * 1_000
            guard lower.isFinite, upper.isFinite, lower >= Double(Int64.min), upper < Double(Int64.max) else {
                throw DatabaseError.queryExecutionFailed("First-pass audio selection requires a representable clock")
            }
            if let recent = try selectAutomaticBatch(status: "pending", newestFirst: true,
                timeRange: (Int64(lower), Int64(upper)), excludeLowEnergy: true) {
                return recent
            }
        }
        return try selectAutomaticBatch(status: "pending", newestFirst: false)
    }

    /// Heavy repair owns a separate quiet-time admission; first-pass recordings
    /// must not get trapped behind a repair merely because both retain media.
    public func getOldestRepairBatch() throws -> UntranscribedBatch? {
        try selectAutomaticBatch(status: "needs_repair", newestFirst: false)
    }

    /// New first-pass recordings get a recent lane without changing manual backfill order.
    /// The rolling 24-hour window includes both endpoints; future-dated recordings remain
    /// available to the oldest-work lane rather than leading the recent lane after a clock change.
    public func getRecentPendingBatch(now: Date = Date()) throws -> UntranscribedBatch? {
        try Task.checkCancellation()
        let lowerMilliseconds = now.addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970 * 1_000
        let upperMilliseconds = now.timeIntervalSince1970 * 1_000
        guard lowerMilliseconds.isFinite, upperMilliseconds.isFinite,
              lowerMilliseconds >= Double(Int64.min), upperMilliseconds < Double(Int64.max) else {
            throw DatabaseError.queryExecutionFailed("Recent audio selection requires a representable clock")
        }
        return try selectAutomaticBatch(status: "pending", newestFirst: true,
            timeRange: (Int64(lowerMilliseconds), Int64(upperMilliseconds)))
    }

    /// Read one oldest candidate per status using the existing V17 status/time index.
    /// Comparing the two exact integer identities avoids sorting the complete pending queue.
    public func getOldestUntranscribedBatch() throws -> UntranscribedBatch? {
        let pending = try selectAutomaticBatch(status: "pending", newestFirst: false)
        let repair = try selectAutomaticBatch(status: "needs_repair", newestFirst: false)
        switch (pending, repair) {
        case let (pending?, repair?):
            if pending.startTimeMilliseconds != repair.startTimeMilliseconds {
                return pending.startTimeMilliseconds < repair.startTimeMilliseconds ? pending : repair
            }
            return pending.id < repair.id ? pending : repair
        case let (pending?, nil): return pending
        case let (nil, repair?): return repair
        case (nil, nil): return nil
        }
    }

    private func selectAutomaticBatch(status: String, newestFirst: Bool,
                                     timeRange: (lower: Int64, upper: Int64)? = nil,
                                     excludeLowEnergy: Bool = false) throws -> UntranscribedBatch? {
        try Task.checkCancellation()
        let order = newestFirst ? "DESC" : "ASC"
        let sql = """
            SELECT id, start_time, end_time, source, audio_path, audio_size,
                   transcript_status = 'needs_repair' AND
                   instr(',' || COALESCE(quality_flags, '') || ',', ',\(AudioPreparationMetadata.firstPassRepairPending),') > 0,
                   text, detected_language
            FROM audio_captures INDEXED BY idx_audio_captures_transcript_status
            WHERE transcript_status = ?
            \(timeRange == nil ? "" : "AND start_time BETWEEN ? AND ?")
            \(excludeLowEnergy ? "AND COALESCE(quality_flags, '') != ?" : "")
            AND audio_path IS NOT NULL
            AND audio_path LIKE '%batch_%'
            ORDER BY start_time \(order), id \(order)
            LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, status, -1, SQLITE_TRANSIENT)
        if let timeRange {
            sqlite3_bind_int64(statement, 2, timeRange.lower)
            sqlite3_bind_int64(statement, 3, timeRange.upper)
        }
        if excludeLowEnergy {
            sqlite3_bind_text(statement, timeRange == nil ? 2 : 4, AudioPreparationMetadata.lowEnergyPending, -1, SQLITE_TRANSIENT)
        }
        let result = sqlite3_step(statement)
        try Task.checkCancellation()
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }
        let start = sqlite3_column_int64(statement, 1)
        let end = sqlite3_column_int64(statement, 2)
        return UntranscribedBatch(
            id: sqlite3_column_int64(statement, 0),
            startTime: Schema.timestampToDate(start), endTime: Schema.timestampToDate(end),
            source: AudioSource(rawValue: String(cString: sqlite3_column_text(statement, 3))) ?? .microphone,
            audioPath: String(cString: sqlite3_column_text(statement, 4)),
            audioSize: sqlite3_column_int64(statement, 5),
            startTimeMilliseconds: start, endTimeMilliseconds: end,
            retainedFirstPass: Self.retainedFirstPass(from: statement))
    }

    private static func retainedFirstPass(from statement: OpaquePointer?) -> DetailedTranscriptionResult? {
        guard sqlite3_column_int(statement, 6) != 0 else { return nil }
        return DetailedTranscriptionResult(
            text: sqlite3_column_text(statement, 7).map { String(cString: $0) } ?? "",
            words: [], language: sqlite3_column_text(statement, 8).map { String(cString: $0) }, duration: nil)
    }

    /// Get raw batch records that haven't been transcribed yet
    /// These have text="" and a batch audio file path
    public func getUntranscribedBatches(limit: Int = 50) throws -> [UntranscribedBatch] {
        let sql = """
            SELECT id, start_time, end_time, source, audio_path, audio_size,
                   transcript_status = 'needs_repair' AND
                   instr(',' || COALESCE(quality_flags, '') || ',', ',\(AudioPreparationMetadata.firstPassRepairPending),') > 0,
                   text, detected_language
            FROM audio_captures
            WHERE audio_path IS NOT NULL
            AND audio_path LIKE '%batch_%'
            AND transcript_status IN ('pending', 'needs_repair')
            ORDER BY start_time ASC
            LIMIT ?;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var results: [UntranscribedBatch] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let startTime = Schema.timestampToDate(sqlite3_column_int64(stmt, 1))
            let endTime = Schema.timestampToDate(sqlite3_column_int64(stmt, 2))
            let sourceRaw = String(cString: sqlite3_column_text(stmt, 3))
            let audioPath = String(cString: sqlite3_column_text(stmt, 4))
            let audioSize = sqlite3_column_int64(stmt, 5)

            results.append(UntranscribedBatch(
                id: id,
                startTime: startTime,
                endTime: endTime,
                source: AudioSource(rawValue: sourceRaw) ?? .microphone,
                audioPath: audioPath,
                audioSize: audioSize,
                startTimeMilliseconds: sqlite3_column_int64(stmt, 1),
                endTimeMilliseconds: sqlite3_column_int64(stmt, 2),
                retainedFirstPass: Self.retainedFirstPass(from: stmt)
            ))
        }

        return results
    }

    /// Get count of untranscribed batch records
    public func getUntranscribedBatchCount() throws -> Int {
        let sql = """
            SELECT COUNT(*) FROM audio_captures
            WHERE audio_path IS NOT NULL
            AND audio_path LIKE '%batch_%'
            AND transcript_status IN ('pending', 'needs_repair');
            """

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

    /// Mark historical placeholder batch rows as pending so backfill can retry them.
    @discardableResult
    public func markHistoricalPlaceholdersPendingForRepair(
        from startDate: Date,
        to endDate: Date,
        limit: Int
    ) throws -> Int {
        let sql = """
            UPDATE audio_captures
            SET text = '',
                transcript_status = 'pending',
                quality_flags = COALESCE(quality_flags, 'historical_repair'),
                pipeline_version = ?
            WHERE id IN (
                SELECT id FROM audio_captures
                WHERE start_time >= ?
                AND end_time <= ?
                AND audio_path IS NOT NULL
                AND audio_path LIKE '%batch_%'
                AND source != 'word'
                AND (
                    text IN ('[silence]', '[hallucination]')
                    OR transcript_status IN ('probable_silence', 'probable_junk', 'needs_review', 'language_uncertain')
                )
                ORDER BY start_time ASC
                LIMIT ?
            );
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(CURRENT_PIPELINE_VERSION))
        sqlite3_bind_int64(stmt, 2, Schema.dateToTimestamp(startDate))
        sqlite3_bind_int64(stmt, 3, Schema.dateToTimestamp(endDate))
        sqlite3_bind_int(stmt, 4, Int32(max(limit, 0)))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }

        return Int(sqlite3_changes(db))
    }

    // MARK: - Refinement Queries

    /// Get distinct batch audio paths that have pass-1 sentence records eligible for refinement
    public func getDistinctBatchPathsForRefinement(limit: Int = 10) throws -> [String] {
        let sql = """
            SELECT DISTINCT batch_audio_path FROM audio_captures
            WHERE transcription_pass = 1
            AND batch_audio_path IS NOT NULL
            AND source NOT IN ('word')
            AND text NOT IN ('', '[silence]', '[hallucination]', '[decode_error]')
            AND COALESCE(transcript_status, 'transcribed') = 'transcribed'
            AND NOT EXISTS (
                SELECT 1 FROM audio_captures AS newer
                WHERE newer.batch_audio_path = audio_captures.batch_audio_path
                AND newer.source NOT IN ('word')
                AND newer.transcription_pass > 1
            )
            AND NOT (
                substr(ltrim(text), 1, 1) IN ('(', '[', '*')
                AND substr(rtrim(text), -1) IN (')', ']', '*')
                AND (
                    lower(text) LIKE '%footstep%'
                    OR lower(text) LIKE '%bell%'
                    OR lower(text) LIKE '%door%'
                    OR lower(text) LIKE '%keyboard%'
                    OR lower(text) LIKE '%click%'
                    OR lower(text) LIKE '%chime%'
                    OR lower(text) LIKE '%crackl%'
                    OR lower(text) LIKE '%fire%'
                    OR lower(text) LIKE '%notification%'
                    OR lower(text) LIKE '%ring%'
                    OR lower(text) LIKE '%no audio%'
                    OR lower(text) LIKE '%no sound%'
                )
            )
            ORDER BY start_time ASC
            LIMIT ?;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            paths.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return paths
    }

    /// Delete all pass-1 sentence and word records associated with a batch audio path
    @discardableResult
    public func deletePass1RecordsForBatch(batchAudioPath: String) throws -> Int {
        try deleteRecordsForBatch(batchAudioPath: batchAudioPath, transcriptionPass: 1)
    }

    /// Mark a failed/skipped refinement candidate so it is not selected repeatedly.
    @discardableResult
    public func markBatchRefinementAttempted(
        batchAudioPath: String,
        transcriptionPass: Int,
        transcriptStatus: String,
        qualityFlag: String
    ) throws -> Int {
        let sql = """
            UPDATE audio_captures
            SET transcript_status = ?,
                quality_flags = CASE
                    WHEN quality_flags IS NULL OR quality_flags = '' THEN ?
                    WHEN instr(',' || quality_flags || ',', ',' || ? || ',') > 0 THEN quality_flags
                    ELSE quality_flags || ',' || ?
                END,
                pipeline_version = ?
            WHERE batch_audio_path = ?
            AND transcription_pass = ?;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, transcriptStatus, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, qualityFlag, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, qualityFlag, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, qualityFlag, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 5, Int32(CURRENT_PIPELINE_VERSION))
        sqlite3_bind_text(stmt, 6, batchAudioPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 7, Int32(transcriptionPass))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }

        return Int(sqlite3_changes(db))
    }

    private func deleteRecordsForBatch(batchAudioPath: String, transcriptionPass: Int) throws -> Int {
        let legacyDeleted = try deleteLegacyWordRowsForBatch(
            batchAudioPath: batchAudioPath,
            transcriptionPass: transcriptionPass
        )

        let sql = """
            DELETE FROM audio_captures
            WHERE batch_audio_path = ?
            AND transcription_pass = ?;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, batchAudioPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(transcriptionPass))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }

        return legacyDeleted + Int(sqlite3_changes(db))
    }

    private func deleteLegacyWordRowsForBatch(batchAudioPath: String, transcriptionPass: Int) throws -> Int {
        let sql = """
            DELETE FROM audio_captures
            WHERE id IN (
                SELECT word.id
                FROM audio_captures AS word
                JOIN audio_captures AS parent
                    ON parent.batch_audio_path = ?
                    AND parent.transcription_pass = ?
                    AND parent.source != 'word'
                    AND word.start_time >= parent.start_time
                    AND word.end_time <= parent.end_time
                WHERE word.source = 'word'
                AND (word.batch_audio_path IS NULL OR word.batch_audio_path = '')
            );
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, batchAudioPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(transcriptionPass))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }

        return Int(sqlite3_changes(db))
    }

    /// Reset any records produced by an older pipeline version so the refinement pipeline re-processes them.
    /// Resets pass-2 / pass-3 records and their word rows back to pass-1 when
    /// their pipeline_version < CURRENT_PIPELINE_VERSION. Word rows are preserved
    /// until a replacement pass succeeds so timestamp-level text remains recoverable.
    @discardableResult
    public func resetStalePipelineRecords() throws -> (resetCount: Int, resetWords: Int) {
        try executeStatement("BEGIN TRANSACTION;")

        do {
            // Keep stale word rows recoverable, but demote them with their parent batch
            // so successful pass-2 replacement can delete the full pass-1 batch atomically.
            let resetWordsSql = """
                UPDATE audio_captures
                SET transcription_pass = 1
                WHERE source = 'word'
                AND transcription_pass > 1
                AND pipeline_version < ?;
                """

            var wordStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, resetWordsSql, -1, &wordStmt, nil) == SQLITE_OK else {
                throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(wordStmt) }
            sqlite3_bind_int(wordStmt, 1, Int32(CURRENT_PIPELINE_VERSION))

            guard sqlite3_step(wordStmt) == SQLITE_DONE else {
                throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
            }
            let resetWords = Int(sqlite3_changes(db))

            // Reset stale pass-2 / pass-3 sentence records back to pass-1 so they get re-refined.
            let resetSql = """
                UPDATE audio_captures
                SET transcription_pass = 1
                WHERE source != 'word'
                AND transcription_pass > 1
                AND pipeline_version < ?;
                """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, resetSql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(CURRENT_PIPELINE_VERSION))

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
            }
            let resetCount = Int(sqlite3_changes(db))

            try executeStatement("COMMIT;")
            return (resetCount, resetWords)
        } catch {
            try? executeStatement("ROLLBACK;")
            throw error
        }
    }

    /// Count records that would be reset by resetStalePipelineRecords (diagnostic)
    public func countStalePipelineRecords() throws -> Int {
        let sql = """
            SELECT COUNT(*) FROM audio_captures
            WHERE source != 'word'
            AND transcription_pass > 1
            AND pipeline_version < ?;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(CURRENT_PIPELINE_VERSION))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Get the batch_audio_path of the batch immediately preceding the given batch (by start_time)
    /// Used to prepend 5s of overlap audio for refinement passes so words aren't cut at batch edges.
    public func getPrecedingBatchPath(forBatchPath: String) throws -> String? {
        // Get the start_time of the target batch
        let timeSql = """
            SELECT MIN(start_time) FROM audio_captures
            WHERE batch_audio_path = ? AND source NOT IN ('word');
            """

        var timeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, timeSql, -1, &timeStmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(timeStmt) }

        sqlite3_bind_text(timeStmt, 1, forBatchPath, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(timeStmt) == SQLITE_ROW,
              sqlite3_column_type(timeStmt, 0) != SQLITE_NULL else {
            return nil
        }
        let targetTime = sqlite3_column_int64(timeStmt, 0)

        // Find the batch with the latest start_time that is still before the target
        let sql = """
            SELECT batch_audio_path FROM audio_captures
            WHERE batch_audio_path IS NOT NULL AND batch_audio_path != ?
            AND source NOT IN ('word')
            AND start_time < ?
            ORDER BY start_time DESC
            LIMIT 1;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, forBatchPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, targetTime)

        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL else {
            return nil
        }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    // MARK: - Contextual Refinement Queries

    /// Get distinct batch audio paths that have pass-2 records eligible for contextual refinement (pass 3)
    public func getDistinctBatchPathsForContextualRefinement(limit: Int = 10) throws -> [String] {
        let sql = """
            SELECT DISTINCT batch_audio_path FROM audio_captures
            WHERE transcription_pass = 2
            AND batch_audio_path IS NOT NULL
            AND source NOT IN ('word')
            AND text NOT IN ('', '[silence]', '[hallucination]', '[decode_error]')
            AND COALESCE(transcript_status, 'transcribed') = 'transcribed'
            AND NOT EXISTS (
                SELECT 1 FROM audio_captures AS newer
                WHERE newer.batch_audio_path = audio_captures.batch_audio_path
                AND newer.source NOT IN ('word')
                AND newer.transcription_pass > 2
            )
            AND NOT (
                substr(ltrim(text), 1, 1) IN ('(', '[', '*')
                AND substr(rtrim(text), -1) IN (')', ']', '*')
                AND (
                    lower(text) LIKE '%footstep%'
                    OR lower(text) LIKE '%bell%'
                    OR lower(text) LIKE '%door%'
                    OR lower(text) LIKE '%keyboard%'
                    OR lower(text) LIKE '%click%'
                    OR lower(text) LIKE '%chime%'
                    OR lower(text) LIKE '%crackl%'
                    OR lower(text) LIKE '%fire%'
                    OR lower(text) LIKE '%notification%'
                    OR lower(text) LIKE '%ring%'
                    OR lower(text) LIKE '%no audio%'
                    OR lower(text) LIKE '%no sound%'
                )
            )
            ORDER BY start_time ASC
            LIMIT ?;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            paths.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return paths
    }

    /// Delete all pass-2 records associated with a batch audio path
    @discardableResult
    public func deletePass2RecordsForBatch(batchAudioPath: String) throws -> Int {
        try deleteRecordsForBatch(batchAudioPath: batchAudioPath, transcriptionPass: 2)
    }

    /// Get concatenated text from the batches immediately before and after the given batch
    /// Used to build contextual prompts for pass-3 refinement
    public func getNeighborBatchText(forBatchPath: String) throws -> (preceding: String?, following: String?) {
        // First get the start_time of the target batch
        let timeSql = """
            SELECT MIN(start_time) FROM audio_captures
            WHERE batch_audio_path = ? AND source NOT IN ('word')
            AND text NOT IN ('', '[silence]', '[hallucination]', '[decode_error]');
            """

        var timeStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, timeSql, -1, &timeStmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(timeStmt) }

        sqlite3_bind_text(timeStmt, 1, forBatchPath, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(timeStmt) == SQLITE_ROW,
              sqlite3_column_type(timeStmt, 0) != SQLITE_NULL else {
            return (nil, nil)
        }
        let targetTime = sqlite3_column_int64(timeStmt, 0)

        // Get preceding batch text (batch with max start_time < targetTime)
        var precedingSql = """
            SELECT GROUP_CONCAT(text, ' ') FROM audio_captures
            WHERE batch_audio_path = (
                SELECT batch_audio_path FROM audio_captures
                WHERE batch_audio_path IS NOT NULL AND batch_audio_path != ?
                AND source NOT IN ('word')
                AND text NOT IN ('', '[silence]', '[hallucination]', '[decode_error]')
                AND start_time < ?
                ORDER BY start_time DESC
                LIMIT 1
            )
            AND source NOT IN ('word')
            AND text NOT IN ('', '[silence]', '[hallucination]', '[decode_error]')
            """
        precedingSql += Self.latestBatchPassPredicate(alias: "audio_captures")
        precedingSql += " ORDER BY start_time ASC;"

        var precStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, precedingSql, -1, &precStmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(precStmt) }

        sqlite3_bind_text(precStmt, 1, forBatchPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(precStmt, 2, targetTime)

        let preceding: String?
        if sqlite3_step(precStmt) == SQLITE_ROW, sqlite3_column_type(precStmt, 0) != SQLITE_NULL {
            preceding = String(cString: sqlite3_column_text(precStmt, 0))
        } else {
            preceding = nil
        }

        // Get following batch text (batch with min start_time > targetTime + 30s)
        var followingSql = """
            SELECT GROUP_CONCAT(text, ' ') FROM audio_captures
            WHERE batch_audio_path = (
                SELECT batch_audio_path FROM audio_captures
                WHERE batch_audio_path IS NOT NULL AND batch_audio_path != ?
                AND source NOT IN ('word')
                AND text NOT IN ('', '[silence]', '[hallucination]', '[decode_error]')
                AND start_time > ? + 30000
                ORDER BY start_time ASC
                LIMIT 1
            )
            AND source NOT IN ('word')
            AND text NOT IN ('', '[silence]', '[hallucination]', '[decode_error]')
            """
        followingSql += Self.latestBatchPassPredicate(alias: "audio_captures")
        followingSql += " ORDER BY start_time ASC;"

        var folStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, followingSql, -1, &folStmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(folStmt) }

        sqlite3_bind_text(folStmt, 1, forBatchPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(folStmt, 2, targetTime)

        let following: String?
        if sqlite3_step(folStmt) == SQLITE_ROW, sqlite3_column_type(folStmt, 0) != SQLITE_NULL {
            following = String(cString: sqlite3_column_text(folStmt, 0))
        } else {
            following = nil
        }

        return (preceding, following)
    }

    /// Get count of transcriptions within a time range (lightweight availability check)
    public func getTranscriptionCount(from startDate: Date, to endDate: Date) throws -> Int {
        let sql = """
            SELECT COUNT(*) FROM audio_captures
            WHERE start_time >= ? AND end_time <= ?
            AND source != 'word';
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Schema.dateToTimestamp(startDate))
        sqlite3_bind_int64(stmt, 2, Schema.dateToTimestamp(endDate))

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Get total count of transcriptions
    public func getTranscriptionCount() throws -> Int {
        let sql = "SELECT COUNT(*) FROM audio_captures;"

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

// MARK: - Audio Transcription Model

/// Ephemeral last-inspected candidate key. It is tied to one reader and exact
/// query scope, including candidates that did not match the selected interval.
/// Order is descending start, end, then row ID, matching the existing V23 index.
/// It is deliberately neither Codable nor an audio evidence reference.
public struct AudioContextCursor: Sendable, Equatable {
    fileprivate let readerID: UUID
    fileprivate let from: Int64
    fileprivate let to: Int64
    fileprivate let source: AudioSource?
    fileprivate let query: String
    fileprivate let start: Int64
    fileprivate let end: Int64
    fileprivate let id: Int64
}

public struct AudioContextPage: Sendable {
    public let entries: [AudioTranscription]
    public let nextCursor: AudioContextCursor?
    /// The candidate limit left unchecked history. A continuation does not
    /// prove another matching row; an empty accepted page can still continue.
    public let scanIncomplete: Bool
    /// Includes an unconsumed raw/matching lookahead, bounded at 512 per request.
    public let scannedCandidates: Int
    public var hasMoreMatches: Bool { nextCursor != nil && !scanIncomplete }

    public init(entries: [AudioTranscription], nextCursor: AudioContextCursor?,
                scanIncomplete: Bool = false, scannedCandidates: Int? = nil) {
        self.entries = entries
        self.nextCursor = nextCursor
        self.scanIncomplete = scanIncomplete
        self.scannedCandidates = scannedCandidates ?? entries.count
    }
}

public struct AudioTranscription: Sendable {
    public let id: Int64
    public let sessionID: String?
    public let text: String
    public let startTime: Date
    public let endTime: Date
    public let source: AudioSource
    public let confidence: Double?
    public let createdAt: Date
    public let audioPath: String?
    public let batchAudioPath: String?
    public let transcriptStatus: String
    public let detectedLanguage: String?
    public let audioVariant: String
    public let qualityFlags: String?
    public let transcriptionPass: Int

    public init(
        id: Int64,
        sessionID: String?,
        text: String,
        startTime: Date,
        endTime: Date,
        source: AudioSource,
        confidence: Double?,
        createdAt: Date,
        audioPath: String? = nil,
        batchAudioPath: String? = nil,
        transcriptStatus: String = "transcribed",
        detectedLanguage: String? = nil,
        audioVariant: String = "raw",
        qualityFlags: String? = nil,
        transcriptionPass: Int = 1
    ) {
        self.id = id
        self.sessionID = sessionID
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.source = source
        self.confidence = confidence
        self.createdAt = createdAt
        self.audioPath = audioPath
        self.batchAudioPath = batchAudioPath
        self.transcriptStatus = transcriptStatus
        self.detectedLanguage = detectedLanguage
        self.audioVariant = audioVariant
        self.qualityFlags = qualityFlags
        self.transcriptionPass = transcriptionPass
    }
}

// MARK: - Untranscribed Batch Model

public struct UntranscribedBatch: Sendable {
    public let id: Int64
    public let startTime: Date
    public let endTime: Date
    public let source: AudioSource
    public let audioPath: String
    public let audioSize: Int64
    public let startTimeMilliseconds: Int64
    public let endTimeMilliseconds: Int64
    /// The original raw candidate survives process restart and is ranked alongside
    /// later enhancement results. Empty text is still a completed raw attempt.
    public let retainedFirstPass: DetailedTranscriptionResult?
    public var needsFirstPassRepair: Bool { retainedFirstPass != nil }

    public init(
        id: Int64,
        startTime: Date,
        endTime: Date,
        source: AudioSource,
        audioPath: String,
        audioSize: Int64,
        startTimeMilliseconds: Int64? = nil,
        endTimeMilliseconds: Int64? = nil,
        retainedFirstPass: DetailedTranscriptionResult? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.source = source
        self.audioPath = audioPath
        self.audioSize = audioSize
        self.startTimeMilliseconds = startTimeMilliseconds ?? Schema.dateToTimestamp(startTime)
        self.endTimeMilliseconds = endTimeMilliseconds ?? Schema.dateToTimestamp(endTime)
        self.retainedFirstPass = retainedFirstPass
    }
}
