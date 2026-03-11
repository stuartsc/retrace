import Foundation
import SQLCipher
import Shared

/// Database queries for audio transcription storage and retrieval
/// Owner: DATABASE agent
public actor AudioTranscriptionQueries {

    private let db: OpaquePointer

    public init(db: OpaquePointer) {
        self.db = db
    }

    // MARK: - Insert Transcription

    /// Insert a transcribed audio segment with word-level timestamps
    public func insertTranscription(
        sessionID: String?,
        text: String,
        startTime: Date,
        endTime: Date,
        source: AudioSource,
        confidence: Double?,
        words: [TranscriptionWord]
    ) throws -> Int64 {
        // Insert the full transcription segment
        let sql = """
            INSERT INTO audio_captures (
                session_id, text, start_time, end_time, source, confidence
            ) VALUES (?, ?, ?, ?, ?, ?);
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
                session_id, text, start_time, end_time, source, confidence
            ) VALUES (
                (SELECT session_id FROM audio_captures WHERE id = ?),
                ?, ?, ?, 'word', ?
            );
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, transcriptionID)
        sqlite3_bind_text(stmt, 2, word, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, Schema.dateToTimestamp(startTime))
        sqlite3_bind_int64(stmt, 4, Schema.dateToTimestamp(endTime))
        if let confidence = confidence {
            sqlite3_bind_double(stmt, 5, confidence)
        } else {
            sqlite3_bind_null(stmt, 5)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Batch insert multiple transcriptions in a single transaction
    public func insertTranscriptionsBatch(
        _ transcriptions: [(
            sessionID: String?,
            text: String,
            startTime: Date,
            endTime: Date,
            source: AudioSource,
            confidence: Double?,
            words: [TranscriptionWord]
        )]
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
                    words: transcription.words
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
                session_id, text, start_time, end_time, source, confidence, audio_path, audio_size
            ) VALUES (NULL, '', ?, ?, ?, NULL, ?, ?);
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
        limit: Int = 100
    ) throws -> [AudioTranscription] {
        var sql = """
            SELECT id, session_id, text, start_time, end_time, source, confidence, created_at
            FROM audio_captures
            WHERE start_time >= ? AND end_time <= ?
            """

        if let source = source {
            sql += " AND source = ?"
        }

        sql += " ORDER BY start_time DESC LIMIT ?;"

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
        sqlite3_bind_int(stmt, Int32(paramIndex), Int32(limit))

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
        let sql = "UPDATE audio_captures SET text = ? WHERE id = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, id)

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
            WHERE text = '' AND audio_path IS NOT NULL AND audio_path LIKE '%batch_%'
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
            WHERE text = '' AND audio_path IS NOT NULL AND audio_path LIKE '%batch_%';
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

    /// Get count of transcriptions within a time range (lightweight availability check)
    public func getTranscriptionCount(from startDate: Date, to endDate: Date) throws -> Int {
        let sql = """
            SELECT COUNT(*) FROM audio_captures
            WHERE start_time >= ? AND end_time <= ? AND text != '';
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

    public init(
        id: Int64,
        sessionID: String?,
        text: String,
        startTime: Date,
        endTime: Date,
        source: AudioSource,
        confidence: Double?,
        createdAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.source = source
        self.confidence = confidence
        self.createdAt = createdAt
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
