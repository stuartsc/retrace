import CryptoKit
import Foundation
import SQLCipher
import Shared

extension DatabaseManager {
    /// Scans at most 500 raw frames and 100 raw videos per page, advancing over
    /// denied/deferred records. Videos follow the final frame page so confirmed
    /// earlier frame batches can become orphan candidates before that scan starts.
    /// TEMP watches revoke selected-row ABA without adding recording migrations.
    public func previewRetentionCommand(cutoff: Date, policy: RetentionCommandPolicy,
                                        access: ScreenEvidenceAccessPolicy,
                                        after: RetentionCommandCursor? = nil) throws -> RetentionCommandSelection {
        let db = try requireRecallConnection()
        guard cutoff.timeIntervalSince1970.isFinite, cutoff <= Date(),
              abs(cutoff.timeIntervalSince1970) < 9_000_000_000,
              policy.excludedApps.count <= 128, policy.excludedTagIDs.count <= 128,
              policy.excludedApps.allSatisfy({ $0.utf8.count <= 256 }), policy.excludedTagIDs.allSatisfy({ $0 > 0 }) else { throw RetentionCommandError.invalidArguments }
        try RetentionCommandSQL.install(db)
        return try PipelineSQL.transaction(db) {
            let budget = RetentionCommandSQL.startBudget(db)
            defer { RetentionCommandSQL.stopBudget(db, budget) }
            let store = try RetentionCommandSQL.store(db)
            if let after {
                guard after.nativeStoreID == store, after.cutoff == cutoff,
                      (after.frameTimestamp == nil) == (after.frameID == nil),
                      after.frameID.map({ $0 > 0 }) ?? true, after.videoID.map({ $0 > 0 }) ?? true else {
                    throw RetentionCommandError.stalePreview
                }
            }
            try PipelineSQL.execute(db, "DELETE FROM temp.retention_command_watch WHERE selectionID IN (SELECT id FROM temp.retention_command_selection WHERE expires<=?)", [.real(Date().timeIntervalSince1970)])
            try PipelineSQL.execute(db, "DELETE FROM temp.retention_command_selection WHERE expires<=?", [.real(Date().timeIntervalSince1970)])
            try PipelineSQL.execute(db, "DELETE FROM temp.retention_command_video_cleanup WHERE expires<=?", [.real(Date().timeIntervalSince1970)])
            guard (try PipelineSQL.integers(db, "SELECT (SELECT COUNT(*) FROM temp.retention_command_selection)+(SELECT COUNT(DISTINCT selectionID) FROM temp.retention_command_video_cleanup)").first ?? 8) < 8 else { throw RetentionCommandError.busy }
            let candidates = try RetentionCommandSQL.framePage(db, cutoff: cutoff, after: after)
            let scannedFrames = Array(candidates.prefix(500))
            let protection = RetentionCommandSQL.protection(policy)
            let eligible: Set<Int64> = scannedFrames.isEmpty ? [] : Set(try PipelineSQL.integers(db, """
                SELECT f.id FROM frame f LEFT JOIN segment s ON s.id=f.segmentId
                WHERE f.id IN (\(RetentionCommandSQL.marks(scannedFrames.count))) AND \(protection.sql)
                  AND NOT EXISTS(SELECT 1 FROM video v WHERE v.id=f.videoId AND v.processingState<>0)
                """, scannedFrames.map { .integer($0.id) } + protection.values))
            var frames: [Int64] = []
            for candidate in scannedFrames where eligible.contains(candidate.id) {
                if let frame = try FrameQueries.getByID(db: db, id: .init(value: candidate.id)), access.permitsLocalPresentation(frame.metadata) {
                    frames.append(candidate.id)
                }
            }
            let hasMoreFrames = candidates.count > 500
            let segments = try RetentionCommandSQL.deletableSegments(db, frames: frames, cutoff: cutoff)
            let videoPage = hasMoreFrames ? [] : try RetentionCommandSQL.videoPage(db, after: after)
            let scannedVideos = Array(videoPage.prefix(100))
            let videos = try RetentionCommandSQL.videos(db, candidates: scannedVideos, frames: frames, cutoff: cutoff)
            let hasMoreVideos = hasMoreFrames || videoPage.count > 100
            let id = UUID(), expires = Date().addingTimeInterval(120)
            let fingerprint = try RetentionCommandSQL.fingerprint(db, frames: frames, segments: segments, videos: videos)
            try PipelineSQL.execute(db, "INSERT INTO temp.retention_command_selection(id,expires,revision,fingerprint,cutoff) VALUES(?,?,0,?,?)", [.text(id.uuidString), .real(expires.timeIntervalSince1970), .text(fingerprint), .integer(Schema.dateToTimestamp(cutoff))])
            for frame in frames { try RetentionCommandSQL.watch(db, id, "frame", frame) }
            let contexts = try RetentionCommandSQL.segmentIDs(db, frames: frames)
            for segment in contexts { try RetentionCommandSQL.watch(db, id, "segment", segment) }
            for video in videos { try RetentionCommandSQL.watch(db, id, "video", video.id.value) }
            try budget.check()
            let cursor: RetentionCommandCursor? = hasMoreFrames || hasMoreVideos ? .init(nativeStoreID: store, cutoff: cutoff,
                frameTimestamp: scannedFrames.last?.timestamp ?? after?.frameTimestamp,
                frameID: scannedFrames.last?.id ?? after?.frameID, framesComplete: !hasMoreFrames,
                videoID: scannedVideos.last ?? after?.videoID, videosComplete: !hasMoreVideos) : nil
            return .init(id: id, nativeStoreID: store, cutoff: cutoff, expiresAt: expires, fingerprint: fingerprint,
                         frameIDs: frames, segmentIDs: segments, videos: videos,
                         hasMoreFrames: hasMoreFrames, hasMoreVideos: hasMoreVideos,
                         externalVersion: try RetentionCommandSQL.externalVersion(db), nextCursor: cursor,
                         scannedFrames: scannedFrames.count, skippedFrames: scannedFrames.count - frames.count,
                         scannedVideos: scannedVideos.count, skippedVideos: scannedVideos.count - videos.count)
        }
    }

    public func discardRetentionCommand(_ id: UUID) throws {
        let db = try requireRecallConnection()
        try RetentionCommandSQL.install(db)
        try PipelineSQL.execute(db, "DELETE FROM temp.retention_command_watch WHERE selectionID=?", [.text(id.uuidString)])
        try PipelineSQL.execute(db, "DELETE FROM temp.retention_command_selection WHERE id=?", [.text(id.uuidString)])
        try PipelineSQL.execute(db, "DELETE FROM temp.retention_command_video_cleanup WHERE selectionID=?", [.text(id.uuidString)])
    }

    /// Removes only writer-issued IDs. New old frames, unselected sessions and all
    /// audio remain untouched. Fences remain held through COMMIT; no await occurs.
    public func executeRetentionCommand(_ expected: RetentionCommandSelection, policy: RetentionCommandPolicy,
                                        access: ScreenEvidenceAccessPolicy, fences: [NativeMutationFence]) throws -> (frames: Int, sessions: Int) {
        guard (1...3).contains(fences.count), Set(fences.map(ObjectIdentifier.init)).count == fences.count,
              expected.frameIDs.count <= 500, expected.segmentIDs.count <= 500, expected.videos.count <= 100 else { throw RetentionCommandError.invalidArguments }
        let db = try requireRecallConnection()
        try PipelineSQL.execute(db, "BEGIN IMMEDIATE")
        do {
            let budget = RetentionCommandSQL.startBudget(db)
            defer { RetentionCommandSQL.stopBudget(db, budget) }
            func admitted<T>(_ index: Int, _ body: () throws -> T) throws -> T {
                if index == fences.count { return try body() }
                return try fences[index].withAdmission { try admitted(index + 1, body) }
            }
            return try admitted(0) {
                let valid = try PipelineSQL.integers(db, "SELECT revision FROM temp.retention_command_selection WHERE id=? AND expires>? AND fingerprint=? AND cutoff=?", [.text(expected.id.uuidString), .real(Date().timeIntervalSince1970), .text(expected.fingerprint), .integer(Schema.dateToTimestamp(expected.cutoff))])
                guard valid == [0], expected.expiresAt > Date(), try RetentionCommandSQL.store(db) == expected.nativeStoreID,
                      try RetentionCommandSQL.externalVersion(db) == expected.externalVersion,
                      try RetentionCommandSQL.fingerprint(db, frames: expected.frameIDs, segments: expected.segmentIDs, videos: expected.videos) == expected.fingerprint,
                      try RetentionCommandSQL.deletableSegments(db, frames: expected.frameIDs, cutoff: expected.cutoff) == expected.segmentIDs else { throw RetentionCommandError.stalePreview }
                let protection = RetentionCommandSQL.protection(policy)
                for id in expected.frameIDs {
                    guard let frame = try FrameQueries.getByID(db: db, id: .init(value: id)), access.permitsLocalPresentation(frame.metadata),
                          try PipelineSQL.integers(db, """
                            SELECT f.id FROM frame f LEFT JOIN segment s ON s.id=f.segmentId
                            WHERE f.id=? AND f.createdAt<? AND \(protection.sql)
                              AND NOT EXISTS(SELECT 1 FROM video v WHERE v.id=f.videoId AND v.processingState<>0)
                            """, [.integer(id), .integer(Schema.dateToTimestamp(expected.cutoff))] + protection.values) == [id] else { throw RetentionCommandError.stalePreview }
                }
                // Consume the capability inside the same transaction. Rollback restores it.
                try PipelineSQL.execute(db, "DELETE FROM temp.retention_command_watch WHERE selectionID=?", [.text(expected.id.uuidString)])
                try PipelineSQL.execute(db, "DELETE FROM temp.retention_command_selection WHERE id=?", [.text(expected.id.uuidString)])
                for id in expected.frameIDs {
                    try Task.checkCancellation()
                    try PipelineSQL.deleteFrameText(db, frameID: id)
                    try PipelineSQL.execute(db, "DELETE FROM node WHERE frameId=?", [.integer(id)])
                    try PipelineSQL.execute(db, "DELETE FROM processing_queue WHERE frameId=?", [.integer(id)])
                    try PipelineSQL.execute(db, "UPDATE segment_comment SET frameId=NULL WHERE frameId=?", [.integer(id)])
                    try PipelineSQL.execute(db, "DELETE FROM frame WHERE id=?", [.integer(id)])
                    guard sqlite3_changes(db) == 1 else { throw RetentionCommandError.stalePreview }
                }
                for id in expected.segmentIDs {
                    try PipelineSQL.execute(db, "DELETE FROM segment_tag WHERE segmentId=?", [.integer(id)])
                    try PipelineSQL.execute(db, "DELETE FROM segment WHERE id=?", [.integer(id)])
                    guard sqlite3_changes(db) == 1 else { throw RetentionCommandError.stalePreview }
                }
                // Transfer the already-validated video selection into per-video
                // authority before releasing the writer. Own frame deletes have
                // finished; every subsequent video/reference mutation revokes it.
                for video in expected.videos {
                    let fingerprint = try RetentionCommandSQL.fingerprint(db, frames: [], segments: [], videos: [video])
                    try PipelineSQL.execute(db, """
                        INSERT INTO temp.retention_command_video_cleanup
                          (selectionID,videoID,expires,revision,fingerprint,selectionFingerprint,externalVersion)
                        VALUES(?,?,?,0,?,?,?)
                        """, [.text(expected.id.uuidString), .integer(video.id.value), .real(expected.expiresAt.timeIntervalSince1970),
                               .text(fingerprint), .text(expected.fingerprint), .integer(expected.externalVersion)])
                }
                try Task.checkCancellation()
                for fence in fences { try fence.checkDeadline() }
                try budget.check()
                try PipelineSQL.execute(db, "COMMIT")
                return (expected.frameIDs.count, expected.segmentIDs.count)
            }
        } catch { try? PipelineSQL.execute(db, "ROLLBACK"); throw error }
    }

    /// Removes only an exact previewed row whose files were already missing.
    /// This API does not unlink files. Authority survives the App output-drain
    /// await and is consumed atomically with this one row's deletion.
    public func completeRetentionCommandMissingVideo(selection: RetentionCommandSelection, candidate: VideoSegment,
                                                     fences: [NativeMutationFence],
                                                     filesAreMissing: @Sendable () throws -> Bool) throws -> Bool {
        guard (1...3).contains(fences.count), Set(fences.map(ObjectIdentifier.init)).count == fences.count,
              selection.videos.count <= 100, selection.videos.contains(where: { $0.id == candidate.id && $0.relativePath == candidate.relativePath }) else {
            throw RetentionCommandError.invalidArguments
        }
        let db = try requireRecallConnection()
        try PipelineSQL.execute(db, "BEGIN IMMEDIATE")
        do {
            let budget = RetentionCommandSQL.startBudget(db)
            defer { RetentionCommandSQL.stopBudget(db, budget) }
            func admitted<T>(_ index: Int, _ body: () throws -> T) throws -> T {
                if index == fences.count { return try body() }
                return try fences[index].withAdmission { try admitted(index + 1, body) }
            }
            return try admitted(0) {
                let fingerprint = try RetentionCommandSQL.fingerprint(db, frames: [], segments: [], videos: [candidate])
                let valid = try PipelineSQL.integers(db, """
                    SELECT revision FROM temp.retention_command_video_cleanup
                    WHERE selectionID=? AND videoID=? AND expires>? AND fingerprint=? AND selectionFingerprint=? AND externalVersion=?
                    """, [.text(selection.id.uuidString), .integer(candidate.id.value), .real(Date().timeIntervalSince1970),
                           .text(fingerprint), .text(selection.fingerprint), .integer(try RetentionCommandSQL.externalVersion(db))])
                guard valid == [0], selection.expiresAt > Date(), try RetentionCommandSQL.store(db) == selection.nativeStoreID else {
                    throw RetentionCommandError.stalePreview
                }
                let eligible = try PipelineSQL.integers(db, """
                    SELECT id FROM video WHERE id=? AND path=? AND processingState=0
                      AND NOT EXISTS(SELECT 1 FROM frame WHERE videoId=video.id)
                      AND NOT EXISTS(
                        SELECT 1 FROM video other
                        WHERE other.path IN (video.path,video.path||'.mp4',
                          CASE WHEN substr(video.path,-4)='.mp4' THEN substr(video.path,1,length(video.path)-4) ELSE video.path END)
                          AND EXISTS(SELECT 1 FROM frame f WHERE f.videoId=other.id))
                    """, [.integer(candidate.id.value), .text(candidate.relativePath)])
                guard eligible == [candidate.id.value], try filesAreMissing() else { throw RetentionCommandError.stalePreview }
                try Task.checkCancellation()
                try PipelineSQL.execute(db, "DELETE FROM temp.retention_command_video_cleanup WHERE selectionID=? AND videoID=?",
                    [.text(selection.id.uuidString), .integer(candidate.id.value)])
                try PipelineSQL.execute(db, "DELETE FROM video WHERE id=?", [.integer(candidate.id.value)])
                guard sqlite3_changes(db) == 1 else { throw RetentionCommandError.stalePreview }
                for fence in fences { try fence.checkDeadline() }
                try budget.check()
                try PipelineSQL.execute(db, "COMMIT")
                return true
            }
        } catch { try? PipelineSQL.execute(db, "ROLLBACK"); throw error }
    }
}

private enum RetentionCommandSQL {
    final class Budget {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        func check() throws {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw RetentionCommandError.unavailable }
        }
    }
    static func startBudget(_ db: OpaquePointer) -> Budget {
        let budget = Budget()
        sqlite3_progress_handler(db, 1_000, { pointer in
            guard let pointer else { return 1 }
            let budget = Unmanaged<Budget>.fromOpaque(pointer).takeUnretainedValue()
            return Task.isCancelled || ContinuousClock.now >= budget.deadline ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
        return budget
    }
    static func stopBudget(_ db: OpaquePointer, _ budget: Budget) {
        sqlite3_progress_handler(db, 0, nil, nil)
        withExtendedLifetime(budget) {}
    }
    static func install(_ db: OpaquePointer) throws {
        try PipelineSQL.execute(db, "CREATE TEMP TABLE IF NOT EXISTS retention_command_selection(id TEXT PRIMARY KEY,expires REAL NOT NULL,revision INTEGER NOT NULL,fingerprint TEXT NOT NULL,cutoff INTEGER NOT NULL)")
        try PipelineSQL.execute(db, "CREATE TEMP TABLE IF NOT EXISTS retention_command_watch(selectionID TEXT NOT NULL,kind TEXT NOT NULL,target INTEGER NOT NULL,PRIMARY KEY(selectionID,kind,target)) WITHOUT ROWID")
        try PipelineSQL.execute(db, "CREATE INDEX IF NOT EXISTS temp.retention_command_target ON retention_command_watch(kind,target,selectionID)")
        try PipelineSQL.execute(db, "CREATE TEMP TABLE IF NOT EXISTS retention_command_video_cleanup(selectionID TEXT NOT NULL,videoID INTEGER NOT NULL,expires REAL NOT NULL,revision INTEGER NOT NULL,fingerprint TEXT NOT NULL,selectionFingerprint TEXT NOT NULL,externalVersion INTEGER NOT NULL,PRIMARY KEY(selectionID,videoID)) WITHOUT ROWID")
        try PipelineSQL.execute(db, "CREATE INDEX IF NOT EXISTS temp.retention_command_cleanup_video ON retention_command_video_cleanup(videoID,selectionID)")
        for (table, kind) in [("frame", "frame"), ("segment", "segment"), ("video", "video")] {
            for action in ["INSERT", "UPDATE", "DELETE"] {
                let versions = action == "INSERT" ? ["NEW"] : action == "DELETE" ? ["OLD"] : ["OLD", "NEW"]
                var conditions = versions.map { "(kind='\(kind)' AND target=\($0).id)" }
                if table == "frame" {
                    conditions += versions.flatMap { ["(kind='segment' AND target=\($0).segmentId)", "(kind='video' AND target=\($0).videoId)"] }
                }
                try PipelineSQL.execute(db, """
                    CREATE TEMP TRIGGER IF NOT EXISTS retention_command_\(table)_\(action) AFTER \(action) ON main.\(table) BEGIN
                      UPDATE retention_command_selection SET revision=revision+1 WHERE id IN
                        (SELECT selectionID FROM retention_command_watch WHERE \(conditions.joined(separator: " OR ")));
                    END
                    """)
                if table == "video" || table == "frame" {
                    let target = table == "video" ? "id" : "videoId"
                    try PipelineSQL.execute(db, """
                        CREATE TEMP TRIGGER IF NOT EXISTS retention_command_cleanup_\(table)_\(action) AFTER \(action) ON main.\(table) BEGIN
                          UPDATE retention_command_video_cleanup SET revision=revision+1
                          WHERE \(versions.map { "videoID=\($0).\(target)" }.joined(separator: " OR "));
                        END
                        """)
                }
            }
        }
        // Notes/tags and other retained evidence protect only the watched
        // sessions. Unrelated OCR/transcription continues without expiring a preview.
        for table in ["tag", "segment_tag", "segment_comment", "segment_comment_link", "audio", "transcript_word", "event", "doc_segment"] {
            for action in ["INSERT", "UPDATE", "DELETE"] {
                let versions = action == "INSERT" ? ["NEW"] : action == "DELETE" ? ["OLD"] : ["OLD", "NEW"]
                let tests = versions.map { version -> String in
                    switch table {
                    case "tag": return "target IN (SELECT segmentId FROM segment_tag WHERE tagId=\(version).id)"
                    case "segment_comment": return "target IN (SELECT segmentId FROM segment_comment_link WHERE commentId=\(version).id)"
                    default: return "target=\(version).segmentId"
                    }
                }
                try PipelineSQL.execute(db, """
                    CREATE TEMP TRIGGER IF NOT EXISTS retention_command_\(table)_\(action) AFTER \(action) ON main.\(table) BEGIN
                      UPDATE retention_command_selection SET revision=revision+1 WHERE id IN
                        (SELECT selectionID FROM retention_command_watch WHERE kind='segment' AND (\(tests.joined(separator: " OR "))));
                    END
                    """)
            }
        }
    }
    static func watch(_ db: OpaquePointer, _ id: UUID, _ kind: String, _ target: Int64) throws {
        try PipelineSQL.execute(db, "INSERT OR IGNORE INTO temp.retention_command_watch VALUES(?,?,?)", [.text(id.uuidString), .text(kind), .integer(target)])
    }
    static func store(_ db: OpaquePointer) throws -> UUID {
        guard let id = try PipelineSQL.query(db, "SELECT storeID FROM evidence_store WHERE source='native' AND identity='native' LIMIT 1", map: { UUID(uuidString: RecallSQL.string($0, 0)) }).first ?? nil else { throw RetentionCommandError.unavailable }
        return id
    }
    static func externalVersion(_ db: OpaquePointer) throws -> Int64 {
        guard let version = try PipelineSQL.integers(db, "PRAGMA main.data_version").first else { throw RetentionCommandError.unavailable }; return version
    }
    static func marks(_ count: Int) -> String { Array(repeating: "?", count: count).joined(separator: ",") }
    struct FramePosition { let id: Int64; let timestamp: Int64 }
    static func framePage(_ db: OpaquePointer, cutoff: Date, after: RetentionCommandCursor?) throws -> [FramePosition] {
        guard after?.framesComplete != true else { return [] }
        let continuation: String
        var values: [PipelineSQL.Value] = [.integer(Schema.dateToTimestamp(cutoff))]
        if let timestamp = after?.frameTimestamp, let id = after?.frameID {
            continuation = "AND (createdAt,id)>(?,?)"; values += [.integer(timestamp), .integer(id)]
        } else { continuation = "" }
        return try PipelineSQL.query(db, "SELECT id,createdAt FROM frame WHERE createdAt<? \(continuation) ORDER BY createdAt,id LIMIT 501", values) {
            FramePosition(id: sqlite3_column_int64($0, 0), timestamp: sqlite3_column_int64($0, 1))
        }
    }
    static func videoPage(_ db: OpaquePointer, after: RetentionCommandCursor?) throws -> [Int64] {
        guard after?.videosComplete != true else { return [] }
        if let id = after?.videoID { return try PipelineSQL.integers(db, "SELECT id FROM video WHERE id>? ORDER BY id LIMIT 101", [.integer(id)]) }
        return try PipelineSQL.integers(db, "SELECT id FROM video ORDER BY id LIMIT 101")
    }
    static func protection(_ policy: RetentionCommandPolicy) -> (sql: String, values: [PipelineSQL.Value]) {
        var clauses = ["1=1"], values: [PipelineSQL.Value] = []
        if !policy.excludedApps.isEmpty {
            clauses.append("COALESCE(s.bundleID,'') NOT IN (\(marks(policy.excludedApps.count)))")
            values += policy.excludedApps.sorted().map { .text($0) }
        }
        if !policy.excludedTagIDs.isEmpty {
            clauses.append("NOT EXISTS(SELECT 1 FROM segment_tag st WHERE st.segmentId=s.id AND st.tagId IN (\(marks(policy.excludedTagIDs.count))))")
            values += policy.excludedTagIDs.sorted().map { .integer($0) }
        }
        if policy.excludeHidden { clauses.append("NOT EXISTS(SELECT 1 FROM segment_tag st JOIN tag t ON t.id=st.tagId WHERE st.segmentId=s.id AND LOWER(t.name)='hidden')") }
        return (clauses.joined(separator: " AND "), values)
    }
    static func segmentIDs(_ db: OpaquePointer, frames: [Int64]) throws -> [Int64] {
        guard !frames.isEmpty else { return [] }
        return try PipelineSQL.integers(db, "SELECT DISTINCT segmentId FROM frame WHERE id IN (\(marks(frames.count))) ORDER BY segmentId", frames.map { .integer($0) })
    }
    static func deletableSegments(_ db: OpaquePointer, frames: [Int64], cutoff: Date) throws -> [Int64] {
        guard !frames.isEmpty else { return [] }
        return try PipelineSQL.integers(db, """
            SELECT s.id FROM segment s WHERE s.id IN (SELECT segmentId FROM frame WHERE id IN (\(marks(frames.count))))
              AND s.endDate<? AND NOT EXISTS(SELECT 1 FROM frame f WHERE f.segmentId=s.id AND f.id NOT IN (\(marks(frames.count))))
              AND NOT EXISTS(SELECT 1 FROM doc_segment d WHERE d.segmentId=s.id AND (d.frameId IS NULL OR d.frameId NOT IN (\(marks(frames.count)))))
              AND NOT EXISTS(SELECT 1 FROM audio a WHERE a.segmentId=s.id)
              AND NOT EXISTS(SELECT 1 FROM transcript_word t WHERE t.segmentId=s.id)
              AND NOT EXISTS(SELECT 1 FROM event e WHERE e.segmentID=s.id)
              AND NOT EXISTS(SELECT 1 FROM segment_comment_link c WHERE c.segmentId=s.id)
            ORDER BY s.id
            """, frames.map { .integer($0) } + [.integer(Schema.dateToTimestamp(cutoff))] + frames.map { .integer($0) } + frames.map { .integer($0) })
    }
    static func videos(_ db: OpaquePointer, candidates: [Int64], frames: [Int64], cutoff: Date) throws -> [VideoSegment] {
        guard !candidates.isEmpty else { return [] }
        let condition = frames.isEmpty ? "1=1" : "f.id NOT IN (\(marks(frames.count)))"
        return try PipelineSQL.query(db, """
            SELECT v.id,v.path,v.width,v.height,COALESCE(v.fileSize,0),COALESCE(v.frameCount,0)
            FROM video v WHERE v.id IN (\(marks(candidates.count))) AND v.processingState=0
              AND NOT EXISTS(SELECT 1 FROM frame f WHERE f.videoId=v.id AND \(condition))
            ORDER BY v.id
            """, candidates.map { .integer($0) } + frames.map { .integer($0) }) { row in
                let path = RecallSQL.string(row, 1)
                guard path.utf8.count <= 4096 else { throw RetentionCommandError.unavailable }
                return .init(id: .init(value: sqlite3_column_int64(row, 0)), startTime: cutoff, endTime: cutoff,
                             frameCount: Int(sqlite3_column_int64(row, 5)), fileSizeBytes: sqlite3_column_int64(row, 4),
                             relativePath: path, width: Int(sqlite3_column_int64(row, 2)), height: Int(sqlite3_column_int64(row, 3)))
            }
    }
    static func fingerprint(_ db: OpaquePointer, frames: [Int64], segments: [Int64], videos: [VideoSegment]) throws -> String {
        var rows: [[String]] = []
        let contexts = try segmentIDs(db, frames: frames)
        for (table, ids) in [("frame", frames), ("segment", contexts), ("video", videos.map { $0.id.value })] {
            for id in ids {
                let values = try PipelineSQL.query(db, "SELECT * FROM \(table) WHERE id=?", [.integer(id)]) { row -> [String] in
                    var values = [table]
                    for index in 0..<sqlite3_column_count(row) {
                        guard sqlite3_column_bytes(row, index) <= 16_384 else { throw RetentionCommandError.unavailable }
                        values.append("\(sqlite3_column_type(row, index)):\(RecallSQL.string(row, index))")
                    }
                    return values
                }
                guard values.count == 1 else { throw RetentionCommandError.stalePreview }
                rows.append(values[0])
            }
        }
        rows.append(["deletableSegments"] + segments.map(String.init))
        let bytes = try JSONEncoder().encode(rows)
        guard bytes.count <= 2_097_152 else { throw RetentionCommandError.unavailable }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
