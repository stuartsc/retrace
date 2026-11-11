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

/// Database queries for audio transcription storage and retrieval
/// Owner: DATABASE agent
public actor AudioTranscriptionQueries {

    let db: OpaquePointer

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

    // MARK: - Original recording source (source identity only)

    /// Returns the source attested by the original raw insertion, never by a
    /// refinement row or a reset pass number. Legacy adoption is raw-row-only.
    public func originalSourceReceipt(forBatchPath path: String) throws -> AudioOriginalSourceReceipt {
        try withOriginalSourceTransaction { try loadOriginalSourceReceipt(path: path) }
    }

    /// Revalidate a queued first-pass candidate after admission, before decoding or inference.
    /// Original lineage intentionally survives retirement, but pending work must not.
    public func pendingFirstPassSource(rawBatchID: Int64, path: String) throws -> AudioOriginalSourceReceipt {
        try withOriginalSourceTransaction(honorsCancellation: true) {
            let receipt = try loadOriginalSourceReceipt(path: path)
            let rows = try originalSourceRows("""
                SELECT 1 FROM audio_captures c JOIN audio_original_source o ON o.rawRowID=c.id
                WHERE c.id=? AND c.audio_path=? AND c.batch_audio_path IS NULL
                  AND c.transcript_status IN ('pending','needs_repair')
                  AND o.recordingID=? AND o.rawRetired=0 AND o.state='active'
                  AND NOT EXISTS(SELECT 1 FROM audio_captures t WHERE t.batch_audio_path=c.audio_path)
                """, values: [.integer(rawBatchID), .text(path), .text(receipt.recordingID)]) {
                    sqlite3_column_int($0, 0)
                }
            guard rows.count == 1 else { throw AudioOriginalSourceError.changed }
            return receipt
        }
    }

    /// Internal processing transition. Explicit deletion must continue to use
    /// deleteTranscription/deleteTranscriptions so the lineage is invalidated.
    public func retireRawBatchAfterTranscription(id: Int64) throws {
        try withOriginalSourceTransaction {
            let row = try originalSourceRows("SELECT audio_path FROM audio_captures WHERE id=? AND batch_audio_path IS NULL AND audio_size>0",
                values: [.integer(id)]) { Self.originalSourceString($0, 0) }.first
            guard let path = row else { throw AudioOriginalSourceError.unavailable }
            let receipt = try loadOriginalSourceReceipt(path: path)
            let matching = try originalSourceRows("""
                SELECT 1 FROM audio_captures WHERE batch_audio_path=? AND transcription_pass=1
                  AND source=? AND text!='' LIMIT 1
                """, values: [.text(path), .text(receipt.source.rawValue)]) { sqlite3_column_int($0, 0) }.first
            guard matching != nil else { throw AudioOriginalSourceError.unavailable }
            try originalSourceExecute("UPDATE audio_original_source SET rawRetired=1,generation=generation+1 WHERE recordingID=? AND rawRowID=? AND rawRetired=0 AND state='active'",
                values: [.text(receipt.recordingID), .integer(id)])
            guard sqlite3_changes(db) == 1 else { throw AudioOriginalSourceError.changed }
            try originalSourceExecute("DELETE FROM audio_captures WHERE id=? AND audio_size>0 AND batch_audio_path IS NULL", values: [.integer(id)])
            guard sqlite3_changes(db) == 1 else { throw AudioOriginalSourceError.changed }
            try DailyMetricsQueries.recordEvent(db: db, metricType: .audioOriginalSource, metadata: "{\"outcome\":\"retired\"}")
        }
    }

    /// First-pass publication and placeholder retirement share one source-guarded transaction.
    @discardableResult
    public func commitFirstPass(rawBatchID: Int64, records: [TranscriptionBatchRecord],
                               originalSource receipt: AudioOriginalSourceReceipt) throws -> [Int64] {
        guard !records.isEmpty, records.count <= 512,
              records.allSatisfy({ $0.transcriptionPass == 1 && $0.source == receipt.source &&
                  $0.batchAudioPath == receipt.batchAudioPath && !$0.text.isEmpty &&
                  $0.text.utf8.count <= 65_536 && $0.endTime > $0.startTime &&
                  $0.startTime.timeIntervalSince1970.isFinite && $0.endTime.timeIntervalSince1970.isFinite &&
                  abs($0.startTime.timeIntervalSince1970) < 9_000_000_000_000 &&
                  abs($0.endTime.timeIntervalSince1970) < 9_000_000_000_000 }) else {
            throw AudioOriginalSourceError.invalidInput
        }
        return try withOriginalSourceTransaction(honorsCancellation: true) {
            guard try loadOriginalSourceReceipt(path: receipt.batchAudioPath) == receipt else {
                throw AudioOriginalSourceError.changed
            }
            let raw = try originalSourceRows("SELECT id FROM audio_captures WHERE id=? AND audio_path=? AND batch_audio_path IS NULL AND transcript_status IN ('pending','needs_repair')",
                values: [.integer(rawBatchID), .text(receipt.batchAudioPath)]) { sqlite3_column_int64($0, 0) }
            let existing = try originalSourceRows("SELECT 1 FROM audio_captures WHERE batch_audio_path=? LIMIT 1",
                values: [.text(receipt.batchAudioPath)]) { sqlite3_column_int($0, 0) }
            guard raw.count == 1, existing.isEmpty else { throw AudioOriginalSourceError.changed }
            try validateRegisteredAudioRecords(records, path: receipt.batchAudioPath)
            var ids: [Int64] = []
            for row in records {
                ids.append(try insertTranscription(sessionID: row.sessionID, text: row.text,
                    startTime: row.startTime, endTime: row.endTime, source: row.source,
                    confidence: row.confidence, words: row.words, audioPath: row.audioPath,
                    transcriptionPass: 1, batchAudioPath: row.batchAudioPath,
                    transcriptStatus: row.transcriptStatus, detectedLanguage: row.detectedLanguage,
                    audioVariant: row.audioVariant, qualityFlags: row.qualityFlags))
            }
            try originalSourceExecute("UPDATE audio_original_source SET rawRetired=1,generation=generation+1 WHERE recordingID=? AND rawRowID=? AND rawRetired=0 AND state='active'",
                values: [.text(receipt.recordingID), .integer(rawBatchID)])
            guard sqlite3_changes(db) == 1 else { throw AudioOriginalSourceError.changed }
            try originalSourceExecute("DELETE FROM audio_captures WHERE id=?", values: [.integer(rawBatchID)])
            guard sqlite3_changes(db) == 1 else { throw AudioOriginalSourceError.changed }
            return ids
        }
    }

    @discardableResult
    public func replacePass1RecordsForBatch(batchAudioPath: String,
        with transcriptions: [TranscriptionBatchRecord], originalSource: AudioOriginalSourceReceipt) throws -> [Int64] {
        try insertSourceGuardedRecords(path: batchAudioPath, records: transcriptions, pass: 2, receipt: originalSource)
    }

    @discardableResult
    public func replacePass2RecordsForBatch(batchAudioPath: String,
        with transcriptions: [TranscriptionBatchRecord], originalSource: AudioOriginalSourceReceipt) throws -> [Int64] {
        try insertSourceGuardedRecords(path: batchAudioPath, records: transcriptions, pass: 3, receipt: originalSource)
    }

    private func insertSourceGuardedRecords(path: String, records: [TranscriptionBatchRecord], pass: Int,
        receipt: AudioOriginalSourceReceipt) throws -> [Int64] {
        try Task.checkCancellation()
        guard !records.isEmpty, records.count <= 256, path == receipt.batchAudioPath,
              records.allSatisfy({ row in
                  row.batchAudioPath == path && row.source == receipt.source && row.transcriptionPass == pass
                    && !row.text.isEmpty && row.text.utf8.count <= 65_536
                    && row.startTime.timeIntervalSince1970.isFinite && row.endTime.timeIntervalSince1970.isFinite
                    && abs(row.startTime.timeIntervalSince1970) < 9_000_000_000_000
                    && abs(row.endTime.timeIntervalSince1970) < 9_000_000_000_000 && row.endTime > row.startTime
              }), records.reduce(0, { $0 + $1.text.utf8.count }) <= 1_048_576 else {
            throw AudioOriginalSourceError.invalidInput
        }
        return try withOriginalSourceTransaction(honorsCancellation: true) {
            let current: AudioOriginalSourceReceipt
            do { current = try loadOriginalSourceReceipt(path: path) }
            catch { throw AudioOriginalSourceError.changed }
            guard current == receipt else { throw AudioOriginalSourceError.changed }
            let latest = try originalSourceRows("SELECT MAX(transcription_pass) FROM audio_captures WHERE batch_audio_path=? AND source!='word'",
                values: [.text(path)]) { sqlite3_column_int($0, 0) }.first
            guard latest == Int32(pass - 1) else { throw AudioOriginalSourceError.changed }
            try validateRegisteredAudioRecords(records, path: path)
            var ids: [Int64] = []
            for row in records {
                ids.append(try insertTranscription(sessionID: row.sessionID, text: row.text,
                    startTime: row.startTime, endTime: row.endTime, source: row.source,
                    confidence: row.confidence, words: row.words, audioPath: row.audioPath,
                    transcriptionPass: row.transcriptionPass, batchAudioPath: row.batchAudioPath,
                    transcriptStatus: row.transcriptStatus, detectedLanguage: row.detectedLanguage,
                    audioVariant: row.audioVariant, qualityFlags: row.qualityFlags))
            }
            try DailyMetricsQueries.recordEvent(db: db, metricType: .audioOriginalSource, metadata: "{\"outcome\":\"published\",\"pass\":\(pass)}")
            return ids
        }
    }

    /// Called synchronously through the existing actor at the actual failed
    /// refinement boundary. Metrics never grant source authority or launch tasks.
    public func recordOriginalSourceFailure(_ failure: AudioOriginalSourceError, pass: Int) throws {
        guard pass == 2 || pass == 3 else { throw AudioOriginalSourceError.invalidInput }
        try withOriginalSourceTransaction {
            let metadata = "{\"outcome\":\"\(failure.rawValue)\",\"pass\":\(pass)}"
            try DailyMetricsQueries.recordEvent(db: db, metricType: .audioOriginalSource, metadata: metadata)
        }
    }

    /// SQLite's connection mutex is recursive in serialized/FULLMUTEX mode.
    /// No await or external callback is allowed while it is held. The explicit
    /// autocommit check refuses to join or roll back another actor's transaction.
    /// This brackets only the new source operations, not every legacy query.
    func withOriginalSourceTransaction<T>(honorsCancellation: Bool = false,
        _ body: () throws -> T) throws -> T {
        guard let mutex = sqlite3_db_mutex(db) else { throw AudioOriginalSourceError.connectionUnsupported }
        guard sqlite3_mutex_try(mutex) == SQLITE_OK else { throw AudioOriginalSourceError.connectionBusy }
        defer { sqlite3_mutex_leave(mutex) }
        guard sqlite3_get_autocommit(db) != 0 else { throw AudioOriginalSourceError.connectionBusy }
        if honorsCancellation { try BackgroundProcessingContext.checkCancellation() }
        try executeStatement("BEGIN IMMEDIATE TRANSACTION")
        do {
            let result = try body()
            if honorsCancellation { try BackgroundProcessingContext.checkCancellation() }
            try executeStatement("COMMIT")
            return result
        } catch {
            try? executeStatement("ROLLBACK")
            throw error
        }
    }

    func loadOriginalSourceReceipt(path: String) throws -> AudioOriginalSourceReceipt {
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.contains("\0") else { throw AudioOriginalSourceError.invalidInput }
        let deleted = try originalSourceRows("SELECT 1 FROM audio_original_source_tombstone WHERE batchAudioPath=?",
            values: [.text(path)]) { sqlite3_column_int($0, 0) }.first
        guard deleted == nil else { throw AudioOriginalSourceError.unavailable }
        let storeIDs = try originalSourceRows("SELECT storeID FROM evidence_store WHERE source='native' LIMIT 2") {
            Self.originalSourceString($0, 0)
        }
        guard storeIDs.count == 1, UUID(uuidString: storeIDs[0]) != nil else { throw AudioOriginalSourceError.unavailable }
        let storeID = storeIDs[0]
        let exists = try originalSourceRows("SELECT 1 FROM audio_original_source WHERE batchAudioPath=?", values: [.text(path)]) {
            sqlite3_column_int($0, 0)
        }.first
        if exists == nil {
            // Only insertRawBatch supplies audio_size; sentence/refinement rows
            // cannot become original proof through pass demotion/version restamp.
            // The partial path index bounds this lookup; two rows are ambiguity.
            let raw = try originalSourceRows("""
                SELECT id,source,start_time,end_time,audio_size,transcription_pass
                FROM audio_captures INDEXED BY audio_original_source_legacy_raw
                WHERE audio_path=? AND batch_audio_path IS NULL ORDER BY id LIMIT 2
                """, values: [.text(path)]) {
                    (sqlite3_column_int64($0, 0), Self.originalSourceString($0, 1), sqlite3_column_int64($0, 2),
                     sqlite3_column_int64($0, 3), sqlite3_column_int64($0, 4), sqlite3_column_int($0, 5))
                }
            guard raw.count == 1 else { throw raw.isEmpty ? AudioOriginalSourceError.unavailable : .conflicting }
            let item = raw[0]
            guard let source = AudioSource(rawValue: item.1), source != .unknown,
                  item.3 > item.2, item.4 > 0, item.5 == 1 else { throw AudioOriginalSourceError.unavailable }
            try originalSourceExecute("""
                INSERT INTO audio_original_source(recordingID,storeID,batchAudioPath,rawRowID,source,startedAt,endedAt,audioSize)
                VALUES(?,?,?,?,?,?,?,?)
                """, values: [.text(UUID().uuidString), .text(storeID), .text(path), .integer(item.0),
                              .text(source.rawValue), .integer(item.2), .integer(item.3), .integer(item.4)])
            try DailyMetricsQueries.recordEvent(db: db, metricType: .audioOriginalSource, metadata: "{\"outcome\":\"legacyAdopted\"}")
        }
        let rows = try originalSourceRows("""
            SELECT recordingID,storeID,source,generation,state,rawRowID,startedAt,endedAt,audioSize,rawRetired
            FROM audio_original_source WHERE batchAudioPath=?
            """, values: [.text(path)]) {
                (Self.originalSourceString($0, 0), Self.originalSourceString($0, 1), Self.originalSourceString($0, 2),
                 sqlite3_column_int64($0, 3), Self.originalSourceString($0, 4), sqlite3_column_int64($0, 5),
                 sqlite3_column_int64($0, 6), sqlite3_column_int64($0, 7), sqlite3_column_int64($0, 8), sqlite3_column_int($0, 9))
            }
        guard let row = rows.first, row.1 == storeID, row.4 == "active", row.3 > 0,
              UUID(uuidString: row.0) != nil, let source = AudioSource(rawValue: row.2), source != .unknown else {
            throw AudioOriginalSourceError.unavailable
        }
        if row.9 == 0 {
            let raw = try originalSourceRows("""
                SELECT 1 FROM audio_captures WHERE id=? AND audio_path=? AND batch_audio_path IS NULL
                  AND source=? AND start_time=? AND end_time=? AND audio_size=? AND transcription_pass=1
                """, values: [.integer(row.5), .text(path), .text(source.rawValue), .integer(row.6), .integer(row.7), .integer(row.8)]) {
                    sqlite3_column_int($0, 0)
                }.first
            guard raw != nil else { throw AudioOriginalSourceError.unavailable }
        }
        let candidates = try originalSourceRows("""
            SELECT source FROM audio_captures WHERE batch_audio_path=? AND transcription_pass=1
              AND source!='word' ORDER BY start_time LIMIT 513
            """, values: [.text(path)]) { Self.originalSourceString($0, 0) }
        guard candidates.count <= 512 else { throw AudioOriginalSourceError.capacityExceeded }
        guard candidates.allSatisfy({ $0 == source.rawValue }) else { throw AudioOriginalSourceError.conflicting }
        if AudioChunkMediaSQL.isManifestIdentity(path) {
            _ = try AudioChunkMediaSQL.window(db, path: path)
        }
        return AudioOriginalSourceReceipt(source: source, recordingID: row.0, storeID: storeID,
            batchAudioPath: path, generation: row.3)
    }

    private enum OriginalSourceValue { case text(String), integer(Int64) }

    private func originalSourceRows<T>(_ sql: String, values: [OriginalSourceValue] = [],
        row: (OpaquePointer) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.queryPreparationFailed("Original audio source statement unavailable")
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(statement, Int32(index + 1), text, -1, SQLITE_TRANSIENT)
            case .integer(let integer): result = sqlite3_bind_int64(statement, Int32(index + 1), integer)
            }
            guard result == SQLITE_OK else { throw DatabaseError.queryExecutionFailed("Original audio source bind failed") }
        }
        var rows: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw DatabaseError.queryExecutionFailed("Original audio source operation failed") }
            rows.append(try row(statement))
        }
    }

    private func originalSourceExecute(_ sql: String, values: [OriginalSourceValue] = []) throws {
        let _: [Int] = try originalSourceRows(sql, values: values) { _ in 0 }
    }

    private static func originalSourceString(_ row: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
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
    /// Saves the audio file path so raw audio is never lost even if transcription fails
    @discardableResult
    public func insertRawBatch(
        startTime: Date,
        endTime: Date,
        source: AudioSource,
        audioPath: String,
        audioSize: Int64,
        probableSilenceHint: Bool = false
    ) throws -> Int64 {
        guard !AudioChunkMediaSQL.isManifestIdentity(audioPath) else { throw AudioOriginalSourceError.invalidInput }
        return try insertRawAudioRecord(startTime: startTime, endTime: endTime, source: source,
            audioPath: audioPath, audioSize: audioSize, probableSilenceHint: probableSilenceHint)
    }

    func insertRawAudioRecord(startTime: Date, endTime: Date, source: AudioSource,
        audioPath: String, audioSize: Int64, probableSilenceHint: Bool) throws -> Int64 {
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

        if probableSilenceHint {
            sqlite3_bind_text(stmt, 7, "capture_probable_silence", -1, SQLITE_TRANSIENT)
        } else { sqlite3_bind_null(stmt, 7) }

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
                transcriptionPass: transcriptionPass,
                evidenceReference: try exactAudioReference(id: id, text: text, startTime: startTime,
                    endTime: endTime, source: sourceRaw, confidence: confidence,
                    audioPath: audioPath, batchAudioPath: batchAudioPath, transcriptStatus: transcriptStatus,
                    detectedLanguage: detectedLanguage, audioVariant: audioVariant, transcriptionPass: transcriptionPass)
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
                transcriptionPass: transcriptionPass,
                evidenceReference: try exactAudioReference(id: id, text: text, startTime: startTime,
                    endTime: endTime, source: sourceRaw, confidence: confidence,
                    audioPath: audioPath, batchAudioPath: batchAudioPath, transcriptStatus: transcriptStatus,
                    detectedLanguage: detectedLanguage, audioVariant: audioVariant, transcriptionPass: transcriptionPass)
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
                transcriptionPass: transcriptionPass,
                evidenceReference: try exactAudioReference(id: id, text: text, startTime: startTime,
                    endTime: endTime, source: sourceRaw, confidence: confidence,
                    audioPath: audioPath, batchAudioPath: batchAudioPath, transcriptStatus: transcriptStatus,
                    detectedLanguage: detectedLanguage, audioVariant: audioVariant, transcriptionPass: transcriptionPass)
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
        qualityFlags: String?,
        originalSource receipt: AudioOriginalSourceReceipt? = nil
    ) throws {
        if let receipt {
            try withOriginalSourceTransaction(honorsCancellation: true) {
                guard try loadOriginalSourceReceipt(path: receipt.batchAudioPath) == receipt else {
                    throw AudioOriginalSourceError.changed
                }
                let rows = try originalSourceRows("SELECT 1 FROM audio_captures WHERE id=? AND audio_path=? AND batch_audio_path IS NULL AND transcript_status IN ('pending','needs_repair')",
                    values: [.integer(id), .text(receipt.batchAudioPath)]) { sqlite3_column_int($0, 0) }
                guard rows.count == 1 else { throw AudioOriginalSourceError.changed }
                try updateBatchOutcome(id: id, text: text, transcriptStatus: transcriptStatus,
                    detectedLanguage: detectedLanguage, audioVariant: audioVariant, qualityFlags: qualityFlags)
            }
            return
        }
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

    static let pendingRawSQL = """
            SELECT id, start_time, end_time, source, audio_path, audio_size, quality_flags
            FROM audio_captures INDEXED BY audio_pending_raw_id
            WHERE audio_path IS NOT NULL
            AND (audio_path LIKE '%batch_%' OR EXISTS(
                SELECT 1 FROM audio_media_window w WHERE w.relativePath=audio_captures.audio_path
                  AND w.kind='chunkWindowV1' AND w.state='active'))
            AND transcript_status IN ('pending', 'needs_repair')
            AND batch_audio_path IS NULL AND audio_size>0 AND id>?
            ORDER BY id ASC
            LIMIT ?;
            """

    /// Get raw batch records that haven't been transcribed yet
    /// These have text="" and a batch audio file path
    public func getUntranscribedBatches(limit: Int = 50, afterID: Int64 = 0) throws -> [UntranscribedBatch] {
        let sql = Self.pendingRawSQL

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, afterID)
        sqlite3_bind_int(stmt, 2, Int32(min(max(limit, 1), 128)))

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
                probableSilenceHint: Self.originalSourceString(stmt!, 6) == "capture_probable_silence"
            ))
        }

        return results
    }

    /// Get count of untranscribed batch records
    public func getUntranscribedBatchCount() throws -> Int {
        let sql = """
            SELECT COUNT(*) FROM audio_captures
            WHERE audio_path IS NOT NULL
            AND (audio_path LIKE '%batch_%' OR EXISTS(
                SELECT 1 FROM audio_media_window w WHERE w.relativePath=audio_captures.audio_path
                  AND w.kind='chunkWindowV1' AND w.state='active'))
            AND transcript_status IN ('pending', 'needs_repair')
            AND batch_audio_path IS NULL AND audio_size>0;
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
                AND (audio_path LIKE '%batch_%' OR EXISTS(
                SELECT 1 FROM audio_media_window w WHERE w.relativePath=audio_captures.audio_path
                  AND w.kind='chunkWindowV1' AND w.state='active'))
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

    /// An indexed row seek bounds actual inspection before eligibility checks.
    /// Ineligible rows still return an ID so callers advance through sparse gaps.
    /// Managers deduplicate paths within a bounded cycle; this grants no source proof.
    public func originalSourceRefinementPage(transcriptionPass: Int,
        afterRowID: Int64, limit: Int = 10) throws -> [AudioRefinementInspection] {
        guard transcriptionPass == 1 || transcriptionPass == 2,
              afterRowID >= 0, (0...256).contains(limit) else {
            throw AudioOriginalSourceError.invalidInput
        }
        guard limit > 0 else { return [] }
        try Task.checkCancellation()
        return try originalSourceRows(Self.originalSourceRefinementSQL,
            values: [.integer(Int64(transcriptionPass)), .integer(afterRowID), .integer(Int64(limit))]) {
                AudioRefinementInspection(rowID: sqlite3_column_int64($0, 0),
                    batchAudioPath: sqlite3_column_type($0, 1) == SQLITE_NULL ? nil : Self.originalSourceString($0, 1))
            }
    }

    static let originalSourceRefinementSQL = """
        SELECT candidate.id, CASE WHEN
          candidate.batch_audio_path IS NOT NULL
          AND length(CAST(candidate.batch_audio_path AS BLOB)) BETWEEN 1 AND 4096
          AND length(CAST(candidate.text AS BLOB)) BETWEEN 1 AND 65536
          AND candidate.source!='word'
          AND candidate.text NOT IN ('[silence]', '[hallucination]', '[decode_error]')
          AND COALESCE(candidate.transcript_status, 'transcribed')='transcribed'
          AND NOT EXISTS (
            SELECT 1 FROM audio_captures AS newer
            WHERE newer.batch_audio_path=candidate.batch_audio_path
              AND newer.source!='word' AND newer.transcription_pass>candidate.transcription_pass)
          AND NOT (
            substr(ltrim(candidate.text),1,1) IN ('(', '[', '*')
            AND substr(rtrim(candidate.text),-1) IN (')', ']', '*')
            AND (lower(candidate.text) LIKE '%footstep%' OR lower(candidate.text) LIKE '%bell%'
              OR lower(candidate.text) LIKE '%door%' OR lower(candidate.text) LIKE '%keyboard%'
              OR lower(candidate.text) LIKE '%click%' OR lower(candidate.text) LIKE '%chime%'
              OR lower(candidate.text) LIKE '%crackl%' OR lower(candidate.text) LIKE '%fire%'
              OR lower(candidate.text) LIKE '%notification%' OR lower(candidate.text) LIKE '%ring%'
              OR lower(candidate.text) LIKE '%no audio%' OR lower(candidate.text) LIKE '%no sound%'))
          THEN candidate.batch_audio_path ELSE NULL END
        FROM audio_captures AS candidate INDEXED BY idx_audio_captures_pass
        WHERE candidate.transcription_pass=? AND candidate.id>?
        ORDER BY candidate.id LIMIT ?
        """

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
    /// Present only when this returned row was matched to its exact V30 snapshot.
    public let evidenceReference: AudioEvidenceRef?

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
        transcriptionPass: Int = 1,
        evidenceReference: AudioEvidenceRef? = nil
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
        self.evidenceReference = evidenceReference
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
    public let probableSilenceHint: Bool

    public init(
        id: Int64,
        startTime: Date,
        endTime: Date,
        source: AudioSource,
        audioPath: String,
        audioSize: Int64,
        probableSilenceHint: Bool = false
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.source = source
        self.audioPath = audioPath
        self.audioSize = audioSize
        self.probableSilenceHint = probableSilenceHint
    }
}

/// Ephemeral checked source receipt. No caller can construct or decode one.
/// It proves original declared recording source only, never capture consent.
public struct AudioOriginalSourceReceipt: Sendable, Equatable {
    public let source: AudioSource
    fileprivate let recordingID: String
    fileprivate let storeID: String
    fileprivate let batchAudioPath: String
    fileprivate let generation: Int64
}

public enum AudioOriginalSourceError: String, Error, Sendable {
    case unavailable, conflicting, changed, invalidInput, capacityExceeded, cancelled
    case connectionBusy, connectionUnsupported
}

/// Every inspected row advances progress, including ineligible/duplicate rows.
/// An optional candidate path is not a source or privacy receipt.
public struct AudioRefinementInspection: Sendable {
    public let rowID: Int64
    public let batchAudioPath: String?
}
