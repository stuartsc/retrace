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
public let CURRENT_PIPELINE_VERSION: Int = 6

/// Database queries for audio transcription storage and retrieval
/// Owner: DATABASE agent
public actor AudioTranscriptionQueries {

    private let db: OpaquePointer

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

    // MARK: - Insert Transcription

    /// Insert a transcribed audio segment with word-level timestamps
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

        // Insert individual words if provided
        for word in words {
            try insertWord(
                transcriptionID: transcriptionID,
                word: word.word,
                startTime: startTime.addingTimeInterval(word.start),
                endTime: startTime.addingTimeInterval(word.end),
                confidence: word.confidence
            )
        }

        return transcriptionID
    }

    /// Insert a single word (for word-level transcriptions)
    private func insertWord(
        transcriptionID: Int64,
        word: String,
        startTime: Date,
        endTime: Date,
        confidence: Double?
    ) throws {
        let sql = """
            INSERT INTO audio_captures (
                session_id, text, start_time, end_time, source, confidence,
                transcription_pass, batch_audio_path, transcript_status, detected_language,
                audio_variant, quality_flags, pipeline_version
            )
            SELECT
                session_id, ?, ?, ?, 'word', ?,
                transcription_pass, batch_audio_path, transcript_status, detected_language,
                audio_variant, quality_flags, pipeline_version
            FROM audio_captures
            WHERE id = ?;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, word, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Schema.dateToTimestamp(startTime))
        sqlite3_bind_int64(stmt, 3, Schema.dateToTimestamp(endTime))
        if let confidence = confidence {
            sqlite3_bind_double(stmt, 4, confidence)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_int64(stmt, 5, transcriptionID)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_changes(db) == 1 else {
            throw DatabaseError.queryExecutionFailed("Parent transcription not found for word row")
        }
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

    /// Atomically insert pass-2 rows and remove the prior pass-1 rows for a batch.
    /// Existing pass-1 rows stay intact if any insert or delete step fails.
    @discardableResult
    public func replacePass1RecordsForBatch(
        batchAudioPath: String,
        with transcriptions: [TranscriptionBatchRecord]
    ) throws -> [Int64] {
        try replaceRecordsForBatch(
            batchAudioPath: batchAudioPath,
            replacingPass: 1,
            with: transcriptions
        )
    }

    /// Atomically insert pass-3 rows and remove the prior pass-2 rows for a batch.
    /// Existing pass-2 rows stay intact if any insert or delete step fails.
    @discardableResult
    public func replacePass2RecordsForBatch(
        batchAudioPath: String,
        with transcriptions: [TranscriptionBatchRecord]
    ) throws -> [Int64] {
        try replaceRecordsForBatch(
            batchAudioPath: batchAudioPath,
            replacingPass: 2,
            with: transcriptions
        )
    }

    private func replaceRecordsForBatch(
        batchAudioPath: String,
        replacingPass: Int,
        with transcriptions: [TranscriptionBatchRecord]
    ) throws -> [Int64] {
        guard !transcriptions.isEmpty else { return [] }

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

            _ = try deleteRecordsForBatch(batchAudioPath: batchAudioPath, transcriptionPass: replacingPass)
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

    /// Insert a raw audio batch record (before transcription)
    /// Saves the audio file path so raw audio is never lost even if transcription fails
    @discardableResult
    public func insertRawBatch(
        startTime: Date,
        endTime: Date,
        source: AudioSource,
        audioPath: String,
        audioSize: Int64
    ) throws -> Int64 {
        let sql = """
            INSERT INTO audio_captures (
                session_id, text, start_time, end_time, source, confidence, audio_path,
                audio_size, transcription_pass, pipeline_version, transcript_status, audio_variant
            ) VALUES (NULL, '', ?, ?, ?, NULL, ?, ?, 1, ?, 'pending', 'raw');
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

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }

        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Query Transcriptions

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
                   audio_path, transcript_status, detected_language, audio_variant, quality_flags
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
                transcriptStatus: transcriptStatus,
                detectedLanguage: detectedLanguage,
                audioVariant: audioVariant,
                qualityFlags: qualityFlags
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
            SELECT id, session_id, text, start_time, end_time, source, confidence, created_at
            FROM audio_captures
            WHERE rowid IN (SELECT rowid FROM audio_captures_fts WHERE audio_captures_fts MATCH ?)
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

            results.append(AudioTranscription(
                id: id,
                sessionID: sessionID,
                text: text,
                startTime: startTime,
                endTime: endTime,
                source: AudioSource(rawValue: sourceRaw) ?? .microphone,
                confidence: confidence,
                createdAt: createdAt
            ))
        }

        return results
    }

    /// Get transcriptions for a specific session
    public func getTranscriptions(forSession sessionID: String) throws -> [AudioTranscription] {
        let sql = """
            SELECT id, session_id, text, start_time, end_time, source, confidence, created_at
            FROM audio_captures
            WHERE session_id = ?
            ORDER BY start_time ASC;
            """

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

            results.append(AudioTranscription(
                id: id,
                sessionID: sessionID,
                text: text,
                startTime: startTime,
                endTime: endTime,
                source: AudioSource(rawValue: sourceRaw) ?? .microphone,
                confidence: confidence,
                createdAt: createdAt
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

    /// Get raw batch records that haven't been transcribed yet
    /// These have text="" and a batch audio file path
    public func getUntranscribedBatches(limit: Int = 50) throws -> [UntranscribedBatch] {
        let sql = """
            SELECT id, start_time, end_time, source, audio_path, audio_size
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
                audioSize: audioSize
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
            AND COALESCE(transcript_status, '') NOT IN ('refinement_failed', 'refinement_skipped')
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
            AND COALESCE(transcript_status, '') NOT IN ('refinement_failed', 'refinement_skipped')
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
        let precedingSql = """
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
            ORDER BY start_time ASC;
            """

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
        let followingSql = """
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
            ORDER BY start_time ASC;
            """

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
    public let transcriptStatus: String
    public let detectedLanguage: String?
    public let audioVariant: String
    public let qualityFlags: String?

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
        transcriptStatus: String = "transcribed",
        detectedLanguage: String? = nil,
        audioVariant: String = "raw",
        qualityFlags: String? = nil
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
        self.transcriptStatus = transcriptStatus
        self.detectedLanguage = detectedLanguage
        self.audioVariant = audioVariant
        self.qualityFlags = qualityFlags
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

    public init(
        id: Int64,
        startTime: Date,
        endTime: Date,
        source: AudioSource,
        audioPath: String,
        audioSize: Int64
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.source = source
        self.audioPath = audioPath
        self.audioSize = audioSize
    }
}
