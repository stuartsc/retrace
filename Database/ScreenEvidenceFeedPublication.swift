import Foundation
import SQLCipher
import Shared

extension DatabaseManager {
    public func screenEvidenceFeedStatus() async throws -> ScreenEvidenceFeedStatus {
        try ScreenEvidenceFeedSQL.status(requireRecallConnection())
    }
}

/// Shared canonical status decoder for publication and consumer bookkeeping.
enum ScreenEvidenceFeedSQL {
    static func status(_ db: OpaquePointer) throws -> ScreenEvidenceFeedStatus {
        let rows = try PipelineSQL.query(db, """
            SELECT s.feedID,s.storeID,s.latestSequence,s.retainedThrough
            FROM screen_evidence_feed_state s JOIN evidence_store e ON e.storeID=s.storeID
            WHERE s.id=1 AND e.source='native' AND e.identity='native'
            """) { statement -> ScreenEvidenceFeedStatus in
            guard let feedID = UUID(uuidString: RecallSQL.string(statement, 0)),
                  let storeID = UUID(uuidString: RecallSQL.string(statement, 1)) else {
                throw ScreenEvidenceFeedError.integrityFailure
            }
            let latest = sqlite3_column_int64(statement, 2)
            let floor = sqlite3_column_int64(statement, 3)
            guard latest >= 0, floor >= 0, floor <= latest else { throw ScreenEvidenceFeedError.integrityFailure }
            return ScreenEvidenceFeedStatus(feedID: feedID, storeID: storeID, latestSequence: latest, retainedThrough: floor)
        }
        guard rows.count == 1, let result = rows.first else { throw ScreenEvidenceFeedError.integrityFailure }
        return result
    }

    /// Persistent ordinary-table triggers also cover retained V21 writer code.
    /// Nothing here copies extraction/context payloads or authorizes a worker.
    static func installPublicationTriggers(_ db: OpaquePointer) throws {
        try MigrationRunner.executeStatements(db: db, statements: [
            """
            CREATE TRIGGER screen_evidence_feed_apply AFTER INSERT ON screen_evidence_feed BEGIN
              SELECT CASE WHEN NOT EXISTS(
                SELECT 1 FROM screen_evidence_feed_state s JOIN evidence_store e ON e.storeID=s.storeID
                WHERE s.id=1 AND s.storeID=NEW.storeID AND e.source='native' AND e.identity='native')
                THEN RAISE(ABORT,'Screen evidence feed identity is unavailable') END;
              SELECT CASE WHEN EXISTS(SELECT 1 FROM screen_evidence_source_state
                WHERE storeID=NEW.storeID AND observationID=NEW.observationID AND frameID<>NEW.frameID)
                THEN RAISE(ABORT,'Screen evidence observation identity conflicts') END;
              UPDATE screen_evidence_feed_state SET latestSequence=MAX(latestSequence,NEW.sequence) WHERE id=1;
              INSERT INTO screen_evidence_source_state(
                storeID,observationID,frameID,latestSequence,extractionRevision,deleted,redacted,mediaUnavailableReason)
              VALUES(NEW.storeID,NEW.observationID,NEW.frameID,NEW.sequence,
                MAX(NEW.extractionRevision,COALESCE((SELECT preferredRevision FROM screen_observation
                  WHERE storeID=NEW.storeID AND observationID=NEW.observationID),NEW.extractionRevision)),
                CASE WHEN NEW.kind='deleted' OR EXISTS(SELECT 1 FROM screen_deleted
                  WHERE storeID=NEW.storeID AND observationID=NEW.observationID) THEN 1 ELSE 0 END,
                COALESCE((SELECT redactionReason IS NOT NULL FROM frame WHERE id=NEW.frameID),0),
                (SELECT reason FROM frame_media_unavailable WHERE frameID=NEW.frameID))
              ON CONFLICT(storeID,observationID) DO UPDATE SET
                latestSequence=MAX(screen_evidence_source_state.latestSequence,excluded.latestSequence),
                extractionRevision=MAX(screen_evidence_source_state.extractionRevision,excluded.extractionRevision),
                deleted=MAX(screen_evidence_source_state.deleted,excluded.deleted),
                redacted=CASE WHEN screen_evidence_source_state.deleted=1 THEN screen_evidence_source_state.redacted ELSE excluded.redacted END,
                mediaUnavailableReason=CASE WHEN screen_evidence_source_state.deleted=1
                  THEN screen_evidence_source_state.mediaUnavailableReason ELSE excluded.mediaUnavailableReason END
              WHERE excluded.latestSequence>screen_evidence_source_state.latestSequence;
              UPDATE screen_evidence_work SET state=CASE WHEN EXISTS(
                SELECT 1 FROM screen_evidence_source_state WHERE storeID=NEW.storeID
                  AND observationID=NEW.observationID AND deleted=1) THEN 'deleted' ELSE 'invalidated' END
              WHERE storeID=NEW.storeID AND observationID=NEW.observationID AND state<>'deleted';
            END
            """,
            """
            CREATE TRIGGER screen_evidence_publish_extraction AFTER INSERT ON screen_extraction BEGIN
              \(publish("extraction_published", predicate: "o.observationID=NEW.observationID", revision: "NEW.revision"))
            END
            """,
            """
            CREATE TRIGGER screen_evidence_publish_deletion AFTER INSERT ON screen_deleted
            WHEN EXISTS(SELECT 1 FROM evidence_store WHERE storeID=NEW.storeID AND source='native' AND identity='native') BEGIN
              INSERT INTO screen_evidence_feed(kind,storeID,source,observationID,frameID,extractionRevision)
              VALUES('deleted',NEW.storeID,'native',NEW.observationID,NEW.frameID,
                MAX(COALESCE((SELECT preferredRevision FROM screen_observation
                  WHERE storeID=NEW.storeID AND observationID=NEW.observationID),0),
                  COALESCE((SELECT extractionRevision FROM screen_evidence_source_state
                  WHERE storeID=NEW.storeID AND observationID=NEW.observationID),0)));
            END
            """,
            """
            CREATE TRIGGER screen_evidence_media_insert AFTER INSERT ON frame_media_unavailable BEGIN
              \(publish("media_unavailable", predicate: "o.nativeFrameID=NEW.frameID"))
            END
            """,
            """
            CREATE TRIGGER screen_evidence_media_update AFTER UPDATE OF reason ON frame_media_unavailable
            WHEN OLD.reason IS NOT NEW.reason BEGIN
              \(publish("media_unavailable", predicate: "o.nativeFrameID=NEW.frameID"))
            END
            """,
            """
            CREATE TRIGGER screen_evidence_media_delete AFTER DELETE ON frame_media_unavailable BEGIN
              \(publish("media_restored", predicate: "o.nativeFrameID=OLD.frameID"))
            END
            """,
            """
            CREATE TRIGGER screen_evidence_frame_media_update
            AFTER UPDATE OF videoId,videoFrameIndex,encodingStatus,imageFileName ON frame
            WHEN OLD.videoId IS NOT NEW.videoId OR OLD.videoFrameIndex IS NOT NEW.videoFrameIndex
              OR OLD.encodingStatus IS NOT NEW.encodingStatus OR OLD.imageFileName IS NOT NEW.imageFileName BEGIN
              \(publish("media_link_changed", predicate: "o.nativeFrameID=NEW.id"))
            END
            """,
            """
            CREATE TRIGGER screen_evidence_video_media_update
            AFTER UPDATE OF path,width,height,processingState ON video
            WHEN OLD.path IS NOT NEW.path OR OLD.width IS NOT NEW.width OR OLD.height IS NOT NEW.height
              OR OLD.processingState IS NOT NEW.processingState BEGIN
              \(publish("media_link_changed", predicate: "o.nativeFrameID IN (SELECT id FROM frame WHERE videoId=NEW.id)"))
            END
            """,
            """
            CREATE TRIGGER screen_evidence_frame_redaction_update AFTER UPDATE OF redactionReason ON frame
            WHEN OLD.redactionReason IS NOT NEW.redactionReason BEGIN
              \(publish("redaction_changed", predicate: "o.nativeFrameID=NEW.id"))
            END
            """,
            """
            CREATE TRIGGER screen_evidence_native_observation_identity
            BEFORE UPDATE OF storeID,source,frameID,nativeFrameID,observationID ON screen_observation
            WHEN (OLD.source='native' OR NEW.source='native') AND
              (OLD.storeID IS NOT NEW.storeID OR OLD.source IS NOT NEW.source OR OLD.frameID IS NOT NEW.frameID
                OR OLD.nativeFrameID IS NOT NEW.nativeFrameID OR OLD.observationID IS NOT NEW.observationID)
            BEGIN SELECT RAISE(ABORT,'Retained native screen identity is immutable'); END
            """,
            """
            CREATE TRIGGER screen_evidence_native_store_identity BEFORE UPDATE OF storeID,source,identity ON evidence_store
            WHEN (OLD.source='native' OR NEW.source='native') AND
              (OLD.storeID IS NOT NEW.storeID OR OLD.source IS NOT NEW.source OR OLD.identity IS NOT NEW.identity)
            BEGIN SELECT RAISE(ABORT,'Native evidence store identity is immutable'); END
            """,
            """
            CREATE TRIGGER screen_evidence_native_capture_time BEFORE UPDATE OF createdAt ON frame
            WHEN OLD.createdAt IS NOT NEW.createdAt
              AND EXISTS(SELECT 1 FROM screen_observation WHERE nativeFrameID=OLD.id AND source='native')
            BEGIN SELECT RAISE(ABORT,'Retained native capture time is immutable'); END
            """,
            """
            CREATE TRIGGER screen_evidence_feed_identity BEFORE UPDATE OF feedID,storeID ON screen_evidence_feed_state
            WHEN OLD.feedID IS NOT NEW.feedID OR OLD.storeID IS NOT NEW.storeID
            BEGIN SELECT RAISE(ABORT,'Screen evidence feed identity is immutable'); END
            """
        ])
    }

    /// Arguments are internal SQL fragments only. The deleted predicate makes
    /// tombstones absorb later media cleanup regardless of cascade trigger order.
    private static func publish(_ kind: String, predicate: String, revision: String = "o.preferredRevision") -> String {
        """
        INSERT INTO screen_evidence_feed(kind,storeID,source,observationID,frameID,extractionRevision)
        SELECT '\(kind)',o.storeID,'native',o.observationID,o.frameID,\(revision)
        FROM screen_observation o WHERE o.source='native' AND (\(predicate))
          AND NOT EXISTS(SELECT 1 FROM screen_deleted d WHERE d.storeID=o.storeID AND d.observationID=o.observationID);
        """
    }
}
