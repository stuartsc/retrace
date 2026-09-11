import Foundation
import SQLCipher
import Shared

extension DatabaseManager {
    /// Deletes one bounded batch while keeping video rows/paths as durable cleanup
    /// candidates until their files have been removed. No connection escapes this actor.
    public func performRetentionBatch(
        olderThan cutoff: Date,
        excludingApps: Set<String> = [],
        excludingTagIDs: Set<Int64> = [],
        excludeHidden: Bool = false,
        frameLimit: Int = 500,
        videoLimit: Int = 100
    ) async throws -> (deletedFrames: Int, deletedAppSegments: Int, videos: [VideoSegment]) {
        guard let db = getConnection() else { throw DatabaseError.connectionFailed(underlying: "Database not initialized") }
        guard (1...500).contains(frameLimit), (1...100).contains(videoLimit) else {
            throw PipelineSQL.failure("Invalid retention batch limit")
        }
        let protection = RetentionSQL.protection(excludingApps, excludingTagIDs, excludeHidden)
        return try PipelineSQL.transaction(db) {
            let ids = try PipelineSQL.integers(db, """
                SELECT f.id FROM frame f LEFT JOIN segment s ON s.id=f.segmentId
                WHERE f.createdAt < ? AND \(protection.sql)
                  AND NOT EXISTS(SELECT 1 FROM video v WHERE v.id=f.videoId AND v.processingState<>0)
                ORDER BY f.createdAt,f.id LIMIT ?
                """, [.integer(Schema.dateToTimestamp(cutoff))] + protection.values + [.integer(Int64(frameLimit))])
            for id in ids {
                try PipelineSQL.deleteFrameText(db, frameID: id)
                try PipelineSQL.execute(db, "DELETE FROM node WHERE frameId=?", [.integer(id)])
                try PipelineSQL.execute(db, "DELETE FROM processing_queue WHERE frameId=?", [.integer(id)])
                try PipelineSQL.execute(db, "UPDATE segment_comment SET frameId=NULL WHERE frameId=?", [.integer(id)])
                try PipelineSQL.execute(db, "DELETE FROM frame WHERE id=?", [.integer(id)])
            }

            // Keep sessions anchoring other evidence. Screen retention must not
            // cascade away audio or user notes without their own file lifecycle.
            let segmentIDs = try PipelineSQL.integers(db, """
                SELECT s.id FROM segment s WHERE s.endDate < ? AND \(protection.sql)
                  AND NOT EXISTS(SELECT 1 FROM frame f WHERE f.segmentId=s.id)
                  AND NOT EXISTS(SELECT 1 FROM doc_segment d WHERE d.segmentId=s.id)
                  AND NOT EXISTS(SELECT 1 FROM audio a WHERE a.segmentId=s.id)
                  AND NOT EXISTS(SELECT 1 FROM transcript_word t WHERE t.segmentId=s.id)
                  AND NOT EXISTS(SELECT 1 FROM event e WHERE e.segmentID=s.id)
                  AND NOT EXISTS(SELECT 1 FROM segment_comment_link c WHERE c.segmentId=s.id)
                ORDER BY s.endDate,s.id LIMIT ?
                """, [.integer(Schema.dateToTimestamp(cutoff))] + protection.values + [.integer(Int64(frameLimit))])
            for id in segmentIDs {
                try PipelineSQL.execute(db, "DELETE FROM segment_tag WHERE segmentId=?", [.integer(id)])
                try PipelineSQL.execute(db, "DELETE FROM segment WHERE id=?", [.integer(id)])
            }

            let videos = try PipelineSQL.query(db, """
                SELECT v.id,v.path,v.width,v.height,COALESCE(v.fileSize,0),COALESCE(v.frameCount,0)
                FROM video v WHERE v.processingState=0
                  AND NOT EXISTS(SELECT 1 FROM frame f WHERE f.videoId=v.id)
                  AND NOT EXISTS(
                    SELECT 1 FROM video other
                    WHERE other.path IN (v.path, v.path || '.mp4',
                      CASE WHEN substr(v.path,-4)='.mp4' THEN substr(v.path,1,length(v.path)-4) ELSE v.path END)
                      AND EXISTS(SELECT 1 FROM frame f WHERE f.videoId=other.id)
                  )
                ORDER BY v.id LIMIT ?
                """, [.integer(Int64(videoLimit))]) { statement in
                    VideoSegment(id: VideoSegmentID(value: sqlite3_column_int64(statement, 0)),
                        startTime: cutoff, endTime: cutoff, frameCount: Int(sqlite3_column_int(statement, 5)),
                        fileSizeBytes: sqlite3_column_int64(statement, 4),
                        relativePath: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
                        width: Int(sqlite3_column_int(statement, 2)), height: Int(sqlite3_column_int(statement, 3)))
                }
            return (ids.count, segmentIDs.count, videos)
        }
    }

    /// The bounded file unlink is supplied by App after path validation. Holding
    /// the database write transaction across that synchronous operation prevents
    /// a writer from attaching a new frame between the eligibility check and unlink.
    /// Both the primary path and its reader-supported .mp4 fallback stay protected
    /// when another video row references either physical filename.
    public func completeRetentionVideoDeletion(
        candidate: VideoSegment,
        deleteFile: @Sendable () throws -> Int64
    ) async throws -> Int64? {
        guard let db = getConnection() else { throw DatabaseError.connectionFailed(underlying: "Database not initialized") }
        return try PipelineSQL.transaction(db) { () -> Int64? in
            let eligible = try PipelineSQL.integers(db, """
                SELECT id FROM video WHERE id=? AND path=? AND processingState=0
                  AND NOT EXISTS(SELECT 1 FROM frame WHERE videoId=video.id)
                  AND NOT EXISTS(
                    SELECT 1 FROM video other
                    WHERE other.path IN (video.path, video.path || '.mp4',
                      CASE WHEN substr(video.path,-4)='.mp4' THEN substr(video.path,1,length(video.path)-4) ELSE video.path END)
                      AND EXISTS(SELECT 1 FROM frame f WHERE f.videoId=other.id)
                  )
                """, [.integer(candidate.id.value), .text(candidate.relativePath)])
            guard eligible.count == 1 else { return nil }
            let removedBytes = try deleteFile()
            try PipelineSQL.execute(db, """
                DELETE FROM video WHERE id=? AND path=? AND processingState=0
                  AND NOT EXISTS(SELECT 1 FROM frame WHERE videoId=video.id)
                """, [.integer(candidate.id.value), .text(candidate.relativePath)])
            guard sqlite3_changes(db) == 1 else { throw PipelineSQL.failure("Retention candidate changed during deletion") }
            return removedBytes
        }
    }
}

private enum RetentionSQL {
    static func protection(_ apps: Set<String>, _ tags: Set<Int64>, _ hidden: Bool) -> (sql: String, values: [PipelineSQL.Value]) {
        var conditions = ["1=1"]
        var values: [PipelineSQL.Value] = []
        if !apps.isEmpty {
            conditions.append("COALESCE(s.bundleID,'') NOT IN (\(apps.map { _ in "?" }.joined(separator: ",")))")
            values += apps.sorted().map { .text($0) }
        }
        if !tags.isEmpty {
            conditions.append("NOT EXISTS(SELECT 1 FROM segment_tag st WHERE st.segmentId=s.id AND st.tagId IN (\(tags.map { _ in "?" }.joined(separator: ","))))")
            values += tags.sorted().map { .integer($0) }
        }
        if hidden {
            conditions.append("NOT EXISTS(SELECT 1 FROM segment_tag st JOIN tag t ON t.id=st.tagId WHERE st.segmentId=s.id AND LOWER(t.name)='hidden')")
        }
        return (conditions.joined(separator: " AND "), values)
    }
}
