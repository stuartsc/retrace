import Foundation
import SQLCipher

/// Additive local semantic tables. V22's blocked work and V23's unpublished
/// artifacts remain unchanged. The tail index contains identity/state only.
struct V25_SemanticRecall: Migration {
    let version = 25

    func migrate(db: OpaquePointer) async throws {
        try MigrationRunner.executeStatements(db: db, statements: [
            """
            CREATE TABLE semantic_recall_index (
              indexID TEXT PRIMARY KEY, feedID TEXT NOT NULL, storeID TEXT NOT NULL,
              transformSHA256 TEXT NOT NULL UNIQUE CHECK(length(transformSHA256)=64),
              transformPayload TEXT NOT NULL CHECK(length(CAST(transformPayload AS BLOB))<=4096),
              policySHA256 TEXT NOT NULL, writerID TEXT NOT NULL, leaseID TEXT NOT NULL, expiresAt REAL NOT NULL,
              boundarySequence INTEGER NOT NULL CHECK(boundarySequence>=0),
              freshSequence INTEGER NOT NULL CHECK(freshSequence>=boundarySequence),
              maximumFrameID INTEGER NOT NULL CHECK(maximumFrameID>=0),
              lastFrameID INTEGER NOT NULL CHECK(lastFrameID>=0 AND lastFrameID<=maximumFrameID),
              backfillComplete INTEGER NOT NULL CHECK(backfillComplete IN (0,1)),
              generation INTEGER NOT NULL DEFAULT 0 CHECK(generation>=0),
              completedCount INTEGER NOT NULL DEFAULT 0 CHECK(completedCount>=0),
              emptyCount INTEGER NOT NULL DEFAULT 0 CHECK(emptyCount>=0),
              pendingCount INTEGER NOT NULL DEFAULT 0 CHECK(pendingCount>=0),
              skippedCount INTEGER NOT NULL DEFAULT 0 CHECK(skippedCount>=0),
              windowCount INTEGER NOT NULL DEFAULT 0 CHECK(windowCount>=0))
            """,
            """
            CREATE TABLE semantic_recall_document (
              indexID TEXT NOT NULL REFERENCES semantic_recall_index(indexID),
              observationID TEXT NOT NULL, storeID TEXT NOT NULL, frameID INTEGER NOT NULL CHECK(frameID>0),
              extractionRevision INTEGER NOT NULL CHECK(extractionRevision>=0),
              sourceSequence INTEGER NOT NULL CHECK(sourceSequence>=0),
              referencePayload TEXT NOT NULL CHECK(length(CAST(referencePayload AS BLOB))<=65536),
              policySHA256 TEXT NOT NULL CHECK(length(policySHA256)=64),
              lane TEXT NOT NULL CHECK(lane IN ('fresh','backfill')),
              status TEXT NOT NULL CHECK(status IN ('pending','complete','empty','skipped')),
              pageCount INTEGER NOT NULL DEFAULT 0 CHECK(pageCount>=0),
              nextCursor TEXT CHECK(nextCursor IS NULL OR length(CAST(nextCursor AS BLOB))<=65536),
              PRIMARY KEY(indexID,observationID))
            """,
            "CREATE INDEX semantic_recall_pending ON semantic_recall_document(indexID,status,lane,sourceSequence DESC,frameID)",
            "CREATE INDEX semantic_recall_source ON semantic_recall_document(storeID,observationID)",
            "CREATE INDEX semantic_recall_frame ON semantic_recall_document(frameID)",
            """
            CREATE TABLE semantic_recall_page (
              indexID TEXT NOT NULL, observationID TEXT NOT NULL, pageOrdinal INTEGER NOT NULL CHECK(pageOrdinal>=0),
              expansionPayload TEXT NOT NULL CHECK(length(CAST(expansionPayload AS BLOB))<=65536),
              inputSHA256 TEXT NOT NULL CHECK(length(inputSHA256)=64),
              windowCount INTEGER NOT NULL CHECK(windowCount BETWEEN 0 AND 32),
              PRIMARY KEY(indexID,observationID,pageOrdinal),
              FOREIGN KEY(indexID,observationID) REFERENCES semantic_recall_document(indexID,observationID) ON DELETE CASCADE)
            """,
            """
            CREATE TABLE semantic_recall_window (
              rowID INTEGER PRIMARY KEY AUTOINCREMENT, indexID TEXT NOT NULL, observationID TEXT NOT NULL,
              pageOrdinal INTEGER NOT NULL CHECK(pageOrdinal>=0), windowOrdinal INTEGER NOT NULL CHECK(windowOrdinal BETWEEN 0 AND 31),
              tokenStart INTEGER NOT NULL CHECK(tokenStart>=0), tokenEnd INTEGER NOT NULL CHECK(tokenEnd>tokenStart AND tokenEnd-tokenStart<=224),
              inputLocation INTEGER NOT NULL CHECK(inputLocation>=0), inputLength INTEGER NOT NULL CHECK(inputLength>0),
              spansPayload TEXT NOT NULL CHECK(length(CAST(spansPayload AS BLOB))<=65536),
              vector BLOB NOT NULL CHECK(typeof(vector)='blob' AND length(vector)=1536),
              vectorSHA256 TEXT NOT NULL CHECK(length(vectorSHA256)=64),
              UNIQUE(indexID,observationID,pageOrdinal,windowOrdinal),
              FOREIGN KEY(indexID,observationID,pageOrdinal) REFERENCES semantic_recall_page(indexID,observationID,pageOrdinal) ON DELETE CASCADE)
            """,
            "CREATE INDEX semantic_recall_window_page ON semantic_recall_window(indexID,rowID)",
            """
            CREATE TABLE semantic_recall_attempt (
              attemptID TEXT PRIMARY KEY, indexID TEXT NOT NULL, observationID TEXT NOT NULL,
              claimPayload TEXT NOT NULL CHECK(length(CAST(claimPayload AS BLOB))<=65536),
              status TEXT NOT NULL CHECK(status IN ('claimed','published','cancelled')),
              deadline REAL NOT NULL, deadlineUptime REAL NOT NULL,
              resultSHA256 TEXT, resultPayload TEXT CHECK(resultPayload IS NULL OR length(CAST(resultPayload AS BLOB))<=65536),
              FOREIGN KEY(indexID,observationID) REFERENCES semantic_recall_document(indexID,observationID) ON DELETE CASCADE)
            """,
            "CREATE INDEX semantic_recall_attempt_owner ON semantic_recall_attempt(indexID,status)",
            "CREATE INDEX semantic_recall_source_tail ON screen_evidence_source_state(storeID,latestSequence)",
            """
            CREATE TRIGGER semantic_recall_index_capacity BEFORE INSERT ON semantic_recall_index
            WHEN (SELECT COUNT(*) FROM semantic_recall_index)>=4
            BEGIN SELECT RAISE(ABORT,'Semantic index capacity reached'); END
            """,
            """
            CREATE TRIGGER semantic_recall_attempt_capacity BEFORE INSERT ON semantic_recall_attempt
            WHEN (SELECT COUNT(*) FROM semantic_recall_attempt)>=64
            BEGIN SELECT RAISE(ABORT,'Semantic attempt capacity reached'); END
            """,
            """
            CREATE TRIGGER semantic_recall_document_insert AFTER INSERT ON semantic_recall_document BEGIN
              UPDATE semantic_recall_index SET completedCount=completedCount+(NEW.status='complete'),
                emptyCount=emptyCount+(NEW.status='empty'),pendingCount=pendingCount+(NEW.status='pending'),
                skippedCount=skippedCount+(NEW.status='skipped') WHERE indexID=NEW.indexID;
            END
            """,
            """
            CREATE TRIGGER semantic_recall_document_update AFTER UPDATE OF status ON semantic_recall_document BEGIN
              UPDATE semantic_recall_index SET completedCount=completedCount+(NEW.status='complete')-(OLD.status='complete'),
                emptyCount=emptyCount+(NEW.status='empty')-(OLD.status='empty'),
                pendingCount=pendingCount+(NEW.status='pending')-(OLD.status='pending'),
                skippedCount=skippedCount+(NEW.status='skipped')-(OLD.status='skipped') WHERE indexID=NEW.indexID;
            END
            """,
            """
            CREATE TRIGGER semantic_recall_document_delete AFTER DELETE ON semantic_recall_document BEGIN
              UPDATE semantic_recall_index SET completedCount=completedCount-(OLD.status='complete'),
                emptyCount=emptyCount-(OLD.status='empty'),pendingCount=pendingCount-(OLD.status='pending'),
                skippedCount=skippedCount-(OLD.status='skipped') WHERE indexID=OLD.indexID;
            END
            """,
            """
            CREATE TRIGGER semantic_recall_window_insert AFTER INSERT ON semantic_recall_window BEGIN
              UPDATE semantic_recall_index SET windowCount=windowCount+1 WHERE indexID=NEW.indexID;
            END
            """,
            """
            CREATE TRIGGER semantic_recall_window_delete AFTER DELETE ON semantic_recall_window BEGIN
              UPDATE semantic_recall_index SET windowCount=windowCount-1 WHERE indexID=OLD.indexID;
            END
            """,
            """
            CREATE TRIGGER semantic_recall_source_insert AFTER INSERT ON screen_evidence_source_state BEGIN
              DELETE FROM semantic_recall_document WHERE storeID=NEW.storeID AND observationID=NEW.observationID;
              UPDATE semantic_recall_index SET generation=generation+1 WHERE storeID=NEW.storeID;
            END
            """,
            """
            CREATE TRIGGER semantic_recall_source_update AFTER UPDATE ON screen_evidence_source_state BEGIN
              DELETE FROM semantic_recall_document WHERE storeID=NEW.storeID AND observationID=NEW.observationID;
              UPDATE semantic_recall_index SET generation=generation+1 WHERE storeID=NEW.storeID;
            END
            """,
            """
            CREATE TRIGGER semantic_recall_source_delete AFTER DELETE ON screen_evidence_source_state BEGIN
              DELETE FROM semantic_recall_document WHERE storeID=OLD.storeID AND observationID=OLD.observationID;
              UPDATE semantic_recall_index SET generation=generation+1 WHERE storeID=OLD.storeID;
            END
            """,
            """
            CREATE TRIGGER semantic_recall_policy AFTER UPDATE OF policySHA256 ON screen_evidence_admission_state
            WHEN OLD.policySHA256 IS NOT NEW.policySHA256 BEGIN
              DELETE FROM semantic_recall_document;
              UPDATE semantic_recall_index SET policySHA256=COALESCE(NEW.policySHA256,''),
                boundarySequence=(SELECT latestSequence FROM screen_evidence_feed_state WHERE id=1),
                freshSequence=(SELECT latestSequence FROM screen_evidence_feed_state WHERE id=1),
                maximumFrameID=COALESCE((SELECT MAX(frameID) FROM screen_observation WHERE source='native' AND storeID=NEW.storeID),0),
                lastFrameID=0,backfillComplete=0,generation=generation+1;
            END
            """,
            """
            CREATE TRIGGER semantic_recall_authority AFTER UPDATE OF writerID,policyEpoch,phase,metadataEpoch ON screen_evidence_admission_state
            WHEN OLD.writerID IS NOT NEW.writerID OR OLD.policyEpoch IS NOT NEW.policyEpoch
              OR OLD.phase IS NOT NEW.phase OR OLD.metadataEpoch IS NOT NEW.metadataEpoch BEGIN
              UPDATE semantic_recall_index SET generation=generation+1;
            END
            """,
            """
            CREATE TRIGGER semantic_recall_visibility_tag_insert AFTER INSERT ON tag BEGIN
              UPDATE semantic_recall_index SET generation=generation+1;
            END
            """,
            """
            CREATE TRIGGER semantic_recall_visibility_tag_delete AFTER DELETE ON tag BEGIN
              UPDATE semantic_recall_index SET generation=generation+1;
            END
            """,
            """
            CREATE TRIGGER semantic_recall_visibility_tag_update AFTER UPDATE OF id,name ON tag
            WHEN OLD.id IS NOT NEW.id OR OLD.name IS NOT NEW.name BEGIN
              UPDATE semantic_recall_index SET generation=generation+1;
            END
            """,
            """
            CREATE TRIGGER semantic_recall_visibility_segment_tag_insert AFTER INSERT ON segment_tag BEGIN
              UPDATE semantic_recall_index SET generation=generation+1;
            END
            """,
            """
            CREATE TRIGGER semantic_recall_visibility_segment_tag_delete AFTER DELETE ON segment_tag BEGIN
              UPDATE semantic_recall_index SET generation=generation+1;
            END
            """,
            """
            CREATE TRIGGER semantic_recall_visibility_segment_tag_update AFTER UPDATE OF segmentId,tagId ON segment_tag
            WHEN OLD.segmentId IS NOT NEW.segmentId OR OLD.tagId IS NOT NEW.tagId BEGIN
              UPDATE semantic_recall_index SET generation=generation+1;
            END
            """,
            """
            CREATE TRIGGER semantic_recall_frame_context AFTER UPDATE OF segmentId ON frame
            WHEN OLD.segmentId IS NOT NEW.segmentId BEGIN
              \(resetContext("frameID=NEW.id"))
            END
            """,
            """
            CREATE TRIGGER semantic_recall_segment_context AFTER UPDATE OF id,bundleID,windowName,browserUrl ON segment
            WHEN OLD.id IS NOT NEW.id OR OLD.bundleID IS NOT NEW.bundleID OR OLD.windowName IS NOT NEW.windowName
              OR OLD.browserUrl IS NOT NEW.browserUrl BEGIN
              \(resetContext("EXISTS (SELECT 1 FROM frame WHERE frame.id=semantic_recall_document.frameID AND frame.segmentId IN (OLD.id,NEW.id))"))
            END
            """
        ])
    }

    /// Only internal, fixed SQL predicates are interpolated. No captured text.
    private func resetContext(_ predicate: String) -> String {
        """
        DELETE FROM semantic_recall_page WHERE (indexID,observationID) IN (
          SELECT indexID,observationID FROM semantic_recall_document WHERE \(predicate));
        DELETE FROM semantic_recall_attempt WHERE (indexID,observationID) IN (
          SELECT indexID,observationID FROM semantic_recall_document WHERE \(predicate));
        UPDATE semantic_recall_document SET status='pending',pageCount=0,nextCursor=NULL WHERE \(predicate);
        UPDATE semantic_recall_index SET generation=generation+1;
        """
    }
}
