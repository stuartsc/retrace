import Foundation
import SQLCipher
import Shared

extension AudioTranscriptionQueries {
    public func audioMediaStoreID() throws -> UUID {
        try withOriginalSourceTransaction { try AudioChunkMediaSQL.storeID(db) }
    }

    /// Raw work, immutable source lineage and all media references become visible
    /// together. A journal replay cannot resurrect retired/deleted work.
    @discardableResult
    public func registerRawAudioWindow(_ window: StoredAudioWindow, sessionID: String? = nil,
                                       probableSilenceHint: Bool? = nil) throws -> Int64 {
        try AudioChunkMediaValidation.validate(window)
        guard window.manifest.source != .unknown,
              sessionID.map({ $0.utf8.count <= 4096 && !$0.contains("\0") }) ?? true else {
            throw AudioOriginalSourceError.invalidInput
        }
        return try withOriginalSourceTransaction(honorsCancellation: true) {
            let store = try AudioChunkMediaSQL.storeID(db)
            guard window.manifest.storeID == store else { throw AudioOriginalSourceError.conflicting }
            let previous = try AudioEvidenceSQL.rows(db, """
                SELECT relativePath FROM audio_media_window WHERE relativePath=? OR windowID=? LIMIT 2
                """, [.text(window.relativePath), .text(window.manifest.id.uuidString)]) {
                    try AudioEvidenceSQL.string($0, 0)
                }
            if !previous.isEmpty {
                guard previous == [window.relativePath] else { throw AudioOriginalSourceError.conflicting }
                let retained = try AudioChunkMediaSQL.window(db, path: window.relativePath)
                guard retained.window == window else { throw AudioOriginalSourceError.conflicting }
                _ = try loadOriginalSourceReceipt(path: window.relativePath)
                return retained.rawRowID
            }
            let deleted = try AudioEvidenceSQL.rows(db,
                "SELECT 1 FROM audio_original_source_tombstone WHERE batchAudioPath=?", [.text(window.relativePath)]) { _ in true }
            guard deleted.isEmpty else { throw AudioOriginalSourceError.unavailable }

            for range in window.manifest.ranges {
                let chunk = range.chunk
                let encoded = try AudioChunkMediaSQL.encodedChunk(chunk)
                let existing = try AudioEvidenceSQL.rows(db, """
                    SELECT descriptorJSON FROM audio_media_chunk WHERE chunkID=? OR relativePath=? LIMIT 2
                    """, [.text(chunk.id.uuidString), .text(chunk.relativePath)]) { try AudioEvidenceSQL.string($0, 0) }
                if existing.isEmpty {
                    try AudioChunkMediaSQL.validateNewChunk(db, chunk: chunk)
                    try AudioEvidenceSQL.execute(db, """
                        INSERT INTO audio_media_chunk(chunkID,storeID,streamID,startFrame,frameCount,relativePath,descriptorJSON)
                        VALUES(?,?,?,?,?,?,?)
                        """, [.text(chunk.id.uuidString), .text(store.uuidString), .text(chunk.streamID.uuidString),
                               .integer(chunk.startFrame), .integer(chunk.frameCount), .text(chunk.relativePath), .text(encoded)])
                } else {
                    guard existing == [encoded] else { throw AudioOriginalSourceError.conflicting }
                }
            }

            let raw = try insertRawAudioRecord(startTime: window.manifest.startTime, endTime: window.manifest.endTime,
                source: window.manifest.source, audioPath: window.relativePath, audioSize: window.manifestBytes,
                probableSilenceHint: probableSilenceHint == true)
            if let sessionID {
                try AudioEvidenceSQL.execute(db, "UPDATE audio_captures SET session_id=? WHERE id=?", [.text(sessionID), .integer(raw)])
            }
            let source = try AudioEvidenceSQL.rows(db,
                "SELECT recordingID FROM audio_original_source WHERE rawRowID=? AND batchAudioPath=? AND state='active'",
                [.integer(raw), .text(window.relativePath)]) { try AudioEvidenceSQL.string($0, 0) }
            guard source.count == 1, let recordingID = source.first else { throw AudioOriginalSourceError.unavailable }
            let manifest = window.manifest
            try AudioEvidenceSQL.execute(db, """
                INSERT INTO audio_media_window(windowID,kind,storeID,streamID,source,origin,startFrame,frameCount,
                  ownedStartFrame,relativePath,manifestSHA256,manifestBytes,rawRowID,recordingID)
                VALUES(?,'chunkWindowV1',?,?,?,CAST(? AS REAL),?,?,?,?,?,?,?,?)
                """, [.text(manifest.id.uuidString), .text(store.uuidString), .text(manifest.streamID.uuidString),
                       .text(manifest.source.rawValue), .text(String(manifest.origin.timeIntervalSinceReferenceDate)),
                       .integer(manifest.startFrame), .integer(manifest.frameCount), .integer(manifest.ownedStartFrame),
                       .text(window.relativePath), .text(window.manifestSHA256), .integer(window.manifestBytes),
                       .integer(raw), .text(recordingID)])
            for (ordinal, range) in manifest.ranges.enumerated() {
                try AudioEvidenceSQL.execute(db, """
                    INSERT INTO audio_media_window_range(windowID,ordinal,chunkID,offsetFrames,frameCount) VALUES(?,?,?,?,?)
                    """, [.text(manifest.id.uuidString), .integer(Int64(ordinal)), .text(range.chunk.id.uuidString),
                           .integer(range.offsetFrames), .integer(range.frameCount)])
            }
            guard try AudioChunkMediaSQL.window(db, path: window.relativePath).window == window else {
                throw AudioOriginalSourceError.conflicting
            }
            _ = try loadOriginalSourceReceipt(path: window.relativePath)
            return raw
        }
    }

    /// Nil means an existing-format path. A new-format path without its exact
    /// registration is unavailable and must never fall back to filename timing.
    public func storedAudioWindow(forPath path: String) throws -> StoredAudioWindow? {
        guard AudioChunkMediaSQL.isManifestIdentity(path) else { return nil }
        return try withOriginalSourceTransaction(honorsCancellation: true) {
            _ = try loadOriginalSourceReceipt(path: path)
            return try AudioChunkMediaSQL.window(db, path: path).window
        }
    }

    /// Proves only that this exact publication journal has been superseded by a
    /// committed deletion. It never authorizes unlinking a chunk or manifest.
    public func isAudioWindowCanonicallyDeleted(_ window: StoredAudioWindow) throws -> Bool {
        try AudioChunkMediaValidation.validate(window)
        return try withOriginalSourceTransaction(honorsCancellation: true) {
            guard window.manifest.storeID == (try AudioChunkMediaSQL.storeID(db)) else {
                throw AudioOriginalSourceError.conflicting
            }
            let deleted = try AudioEvidenceSQL.rows(db, """
                SELECT 1 FROM audio_media_window w JOIN audio_original_source o ON o.recordingID=w.recordingID
                WHERE w.relativePath=? AND w.windowID=? AND w.state='deleted' AND o.state='invalidated'
                  AND EXISTS(SELECT 1 FROM audio_original_source_tombstone t WHERE t.batchAudioPath=w.relativePath)
                """, [.text(window.relativePath), .text(window.manifest.id.uuidString)]) { _ in true }
            guard deleted.count == 1 else { return false }
            guard try AudioChunkMediaSQL.window(db, path: window.relativePath, includingDeleted: true).window == window else {
                throw AudioOriginalSourceError.conflicting
            }
            return true
        }
    }

    func validateRegisteredAudioRecords(_ records: [TranscriptionBatchRecord], path: String) throws {
        guard AudioChunkMediaSQL.isManifestIdentity(path) else { return }
        let window = try AudioChunkMediaSQL.window(db, path: path).window
        let lower = Schema.dateToTimestamp(window.manifest.ownedStartTime)
        let upper = Schema.dateToTimestamp(window.manifest.endTime)
        guard records.allSatisfy({ row in
            row.audioPath == path && row.batchAudioPath == path && row.source == window.manifest.source &&
                Schema.dateToTimestamp(row.startTime) >= lower && Schema.dateToTimestamp(row.endTime) <= upper
        }) else { throw AudioOriginalSourceError.invalidInput }
    }

    /// Match all returned transcript evidence fields, not just a numeric row ID.
    /// Legacy rows retain their existing playback route and get no new proof.
    func exactAudioReference(id: Int64, text: String, startTime: Date, endTime: Date, source: String,
        confidence: Double?, audioPath: String?, batchAudioPath: String?, transcriptStatus: String,
        detectedLanguage: String?, audioVariant: String, transcriptionPass: Int) throws -> AudioEvidenceRef? {
        guard let path = batchAudioPath, AudioChunkMediaSQL.isManifestIdentity(path), audioPath == path else { return nil }
        let state = try AudioEvidenceSQL.state(db, readerID: UUID())
        let references = try AudioEvidenceSQL.rows(db, """
            SELECT a.observationID,a.revision,s.startedAt,s.endedAt FROM audio_evidence_alias a
              JOIN audio_evidence_snapshot s ON s.nativeRowID=a.nativeRowID
            WHERE a.nativeRowID=? AND a.state='available' AND a.batchAudioPath=?
            """, [.integer(id), .text(path)]) { p -> AudioEvidenceRef in
                AudioEvidenceRef(storeID: state.stamp.storeID, source: .native,
                    segmentID: try AudioEvidenceSQL.string(p, 0), transcriptRevision: sqlite3_column_int64(p, 1),
                    startTime: Double(sqlite3_column_int64(p, 2)) / 1000, endTime: Double(sqlite3_column_int64(p, 3)) / 1000)
            }
        guard let reference = references.first,
              case .available(let snapshot, _) = try AudioEvidenceSQL.resolve(db, reference: reference, stamp: state.stamp),
              snapshot.text == text, snapshot.startTime == startTime, snapshot.endTime == endTime,
              snapshot.recordingSource.rawValue == source, snapshot.confidence == confidence,
              snapshot.transcriptStatus == transcriptStatus, snapshot.detectedLanguage == detectedLanguage,
              snapshot.audioVariant == audioVariant, snapshot.transcriptionPass == transcriptionPass,
              let registered = try? AudioChunkMediaSQL.window(db, path: path),
              registered.recordingID == snapshot.recordingID else { return nil }
        return reference
    }
}

/// Synchronous, bounded helpers. Callers hold a transaction or an active SQLite
/// read statement; these helpers never await or acquire another transaction.
enum AudioChunkMediaSQL {
    struct RegisteredWindow {
        let window: StoredAudioWindow
        let rawRowID: Int64
        let recordingID: UUID
    }

    static func isManifestIdentity(_ path: String) -> Bool {
        path.hasPrefix("audio/chunk-media/") || path.hasSuffix(".retraceaudio")
    }

    static func storeID(_ db: OpaquePointer) throws -> UUID {
        let values = try AudioEvidenceSQL.rows(db, "SELECT storeID FROM evidence_store WHERE source='native' LIMIT 2") {
            try AudioEvidenceSQL.string($0, 0)
        }
        guard values.count == 1, let value = values.first, let id = UUID(uuidString: value) else {
            throw AudioOriginalSourceError.unavailable
        }
        return id
    }

    static func encodedChunk(_ chunk: AudioChunkDescriptor) throws -> String {
        try AudioChunkMediaValidation.validate(chunk)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(chunk)
        guard bytes.count <= 8192, let text = String(data: bytes, encoding: .utf8) else {
            throw AudioOriginalSourceError.invalidInput
        }
        return text
    }

    static func validateNewChunk(_ db: OpaquePointer, chunk: AudioChunkDescriptor) throws {
        let identity: [AudioEvidenceSQL.Value] = [.text(chunk.storeID.uuidString), .text(chunk.streamID.uuidString)]
        let first = try AudioEvidenceSQL.rows(db, """
            SELECT descriptorJSON FROM audio_media_chunk WHERE storeID=? AND streamID=? ORDER BY startFrame LIMIT 1
            """, identity) { try AudioEvidenceSQL.string($0, 0) }.first
        if let first {
            let existing = try JSONDecoder().decode(AudioChunkDescriptor.self, from: Data(first.utf8))
            guard existing.source == chunk.source, existing.origin == chunk.origin else { throw AudioOriginalSourceError.conflicting }
        }
        let before = try AudioEvidenceSQL.rows(db, """
            SELECT startFrame,frameCount FROM audio_media_chunk WHERE storeID=? AND streamID=? AND startFrame<=?
            ORDER BY startFrame DESC LIMIT 1
            """, identity + [.integer(chunk.startFrame)]) { (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1)) }.first
        let after = try AudioEvidenceSQL.rows(db, """
            SELECT startFrame FROM audio_media_chunk WHERE storeID=? AND streamID=? AND startFrame>?
            ORDER BY startFrame LIMIT 1
            """, identity + [.integer(chunk.startFrame)]) { sqlite3_column_int64($0, 0) }.first
        guard before.map({ $0.0 <= chunk.startFrame - $0.1 }) ?? true,
              after.map({ chunk.startFrame + chunk.frameCount <= $0 }) ?? true else {
            throw AudioOriginalSourceError.conflicting
        }
    }

    static func window(_ db: OpaquePointer, path: String, includingDeleted: Bool = false) throws -> RegisteredWindow {
        guard isManifestIdentity(path), path.utf8.count <= 4096, !path.contains("\0") else {
            throw AudioOriginalSourceError.invalidInput
        }
        let rows = try AudioEvidenceSQL.rows(db, """
            SELECT w.windowID,w.storeID,w.streamID,w.source,w.origin,w.startFrame,w.frameCount,w.ownedStartFrame,
              w.manifestSHA256,w.manifestBytes,w.rawRowID,w.recordingID,o.startedAt,o.endedAt,o.audioSize
            FROM audio_media_window w JOIN audio_original_source o ON o.recordingID=w.recordingID
              JOIN evidence_store e ON e.source='native' AND e.storeID=w.storeID
            WHERE w.relativePath=? AND w.kind='chunkWindowV1'
              AND o.storeID=w.storeID AND o.batchAudioPath=w.relativePath AND o.rawRowID=w.rawRowID AND o.source=w.source
              AND (?=1 OR (w.state='active' AND o.state='active'
                AND NOT EXISTS(SELECT 1 FROM audio_original_source_tombstone t WHERE t.batchAudioPath=w.relativePath)))
            """, [.text(path), .integer(includingDeleted ? 1 : 0)]) { p -> RegisteredWindow in
                guard let id = UUID(uuidString: try AudioEvidenceSQL.string(p, 0)),
                      let store = UUID(uuidString: try AudioEvidenceSQL.string(p, 1)),
                      let stream = UUID(uuidString: try AudioEvidenceSQL.string(p, 2)),
                      let source = AudioSource(rawValue: try AudioEvidenceSQL.string(p, 3)), source != .unknown,
                      let recording = UUID(uuidString: try AudioEvidenceSQL.string(p, 11)) else {
                    throw AudioOriginalSourceError.unavailable
                }
                let ranges = try AudioEvidenceSQL.rows(db, """
                    SELECT r.ordinal,r.offsetFrames,r.frameCount,c.descriptorJSON,c.chunkID,c.storeID,c.relativePath,
                      c.streamID,c.startFrame,c.frameCount
                    FROM audio_media_window_range r JOIN audio_media_chunk c ON c.chunkID=r.chunkID
                    WHERE r.windowID=? ORDER BY r.ordinal LIMIT 3
                    """, [.text(id.uuidString)]) { q -> (Int64, AudioChunkRange) in
                        let bytes = Data(try AudioEvidenceSQL.string(q, 3).utf8)
                        guard bytes.count <= 8192 else { throw AudioOriginalSourceError.unavailable }
                        let chunk = try JSONDecoder().decode(AudioChunkDescriptor.self, from: bytes)
                        guard chunk.id == UUID(uuidString: try AudioEvidenceSQL.string(q, 4)),
                              chunk.storeID == UUID(uuidString: try AudioEvidenceSQL.string(q, 5)),
                              chunk.relativePath == (try AudioEvidenceSQL.string(q, 6)),
                              chunk.streamID == UUID(uuidString: try AudioEvidenceSQL.string(q, 7)),
                              chunk.startFrame == sqlite3_column_int64(q, 8), chunk.frameCount == sqlite3_column_int64(q, 9) else {
                            throw AudioOriginalSourceError.unavailable
                        }
                        return (sqlite3_column_int64(q, 0), .init(chunk: chunk,
                            offsetFrames: sqlite3_column_int64(q, 1), frameCount: sqlite3_column_int64(q, 2)))
                    }
                guard (1...2).contains(ranges.count), ranges.enumerated().allSatisfy({ $0.element.0 == Int64($0.offset) }) else {
                    throw AudioOriginalSourceError.unavailable
                }
                let manifest = AudioWindowManifest(storeID: store, id: id, streamID: stream, source: source,
                    origin: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(p, 4)),
                    startFrame: sqlite3_column_int64(p, 5), frameCount: sqlite3_column_int64(p, 6),
                    ownedStartFrame: sqlite3_column_int64(p, 7), ranges: ranges.map(\.1))
                let stored = StoredAudioWindow(manifest: manifest, relativePath: path,
                    manifestSHA256: try AudioEvidenceSQL.string(p, 8), manifestBytes: sqlite3_column_int64(p, 9))
                try AudioChunkMediaValidation.validate(stored)
                guard Schema.dateToTimestamp(manifest.startTime) == sqlite3_column_int64(p, 12),
                      Schema.dateToTimestamp(manifest.endTime) == sqlite3_column_int64(p, 13),
                      stored.manifestBytes == sqlite3_column_int64(p, 14) else {
                    throw AudioOriginalSourceError.conflicting
                }
                return RegisteredWindow(window: stored, rawRowID: sqlite3_column_int64(p, 10), recordingID: recording)
            }
        guard rows.count == 1, let value = rows.first else { throw AudioOriginalSourceError.unavailable }
        return value
    }

    static func media(_ db: OpaquePointer, snapshot: AudioEvidenceSnapshot) throws -> StoredAudioWindow? {
        let paths = try AudioEvidenceSQL.rows(db, """
            SELECT batchAudioPath,recordingID FROM audio_evidence_alias
            WHERE observationID=? AND storeID=? AND revision=? AND state='available'
            """, [.text(snapshot.reference.segmentID), .text(snapshot.reference.storeID.uuidString),
                   .integer(snapshot.reference.transcriptRevision)]) {
                (try AudioEvidenceSQL.optionalString($0, 0), try AudioEvidenceSQL.string($0, 1))
            }
        guard paths.count == 1, let entry = paths.first, let path = entry.0,
              UUID(uuidString: entry.1) == snapshot.recordingID else { throw AudioEvidenceError.dataChanged }
        guard isManifestIdentity(path) else { return nil }
        let registered = try window(db, path: path)
        guard registered.recordingID == snapshot.recordingID else { throw AudioEvidenceError.dataChanged }
        return registered.window
    }
}
