import Foundation
import SQLCipher

/// Adds an inactive admission boundary without scanning or rewriting retained
/// evidence. Ordinary-table triggers also fence supported older native writers.
struct V23_ScreenEvidenceAdmission: Migration {
    let version = 23

    func migrate(db: OpaquePointer) async throws {
        try MigrationRunner.executeStatements(db: db, statements: [
            """
            CREATE TABLE screen_evidence_admission_state (
              id INTEGER PRIMARY KEY CHECK(id=1),
              feedID TEXT NOT NULL REFERENCES screen_evidence_feed_state(feedID),
              storeID TEXT NOT NULL REFERENCES evidence_store(storeID),
              writerID TEXT, policyEpoch INTEGER NOT NULL DEFAULT 0 CHECK(typeof(policyEpoch)='integer' AND policyEpoch>=0),
              metadataEpoch INTEGER NOT NULL DEFAULT 0 CHECK(typeof(metadataEpoch)='integer' AND metadataEpoch>=0),
              phase TEXT NOT NULL DEFAULT 'inactive' CHECK(phase IN ('inactive','prepared','active','revoked')),
              policySHA256 TEXT CHECK(policySHA256 IS NULL OR length(policySHA256)=64),
              policyPayload TEXT CHECK(policyPayload IS NULL OR length(CAST(policyPayload AS BLOB))<=65536),
              CHECK(phase IN ('inactive','revoked') OR
                (writerID IS NOT NULL AND policyEpoch>0 AND policySHA256 IS NOT NULL AND policyPayload IS NOT NULL)))
            """,
            "INSERT INTO screen_evidence_admission_state(id,feedID,storeID) SELECT 1,feedID,storeID FROM screen_evidence_feed_state WHERE id=1",
            """
            CREATE TABLE screen_evidence_derivation (
              attemptID TEXT PRIMARY KEY, consumerID TEXT NOT NULL REFERENCES screen_evidence_consumer(consumerID),
              storeID TEXT NOT NULL, observationID TEXT NOT NULL, channel TEXT NOT NULL CHECK(channel IN ('lexical','vector')),
              writerID TEXT NOT NULL, policyEpoch INTEGER NOT NULL CHECK(policyEpoch>0),
              claimPayload TEXT NOT NULL CHECK(length(CAST(claimPayload AS BLOB))<=65536),
              status TEXT NOT NULL CHECK(status IN ('claimed','staged','cancelled','invalidated')),
              deadline REAL NOT NULL, deadlineUptime REAL NOT NULL,
              receiptPayload TEXT CHECK(receiptPayload IS NULL OR length(CAST(receiptPayload AS BLOB))<=65536),
              artifact BLOB, artifactBytes INTEGER NOT NULL DEFAULT 0 CHECK(artifactBytes BETWEEN 0 AND 262144),
              retainUntil REAL,
              CHECK(artifactBytes=COALESCE(length(artifact),0)),
              CHECK((status='staged' AND receiptPayload IS NOT NULL AND artifact IS NOT NULL AND artifactBytes>0 AND retainUntil IS NOT NULL)
                 OR (status<>'staged' AND receiptPayload IS NULL AND artifact IS NULL AND artifactBytes=0 AND retainUntil IS NULL)))
            """,
            "CREATE INDEX screen_evidence_derivation_observation ON screen_evidence_derivation(storeID,observationID)",
            "CREATE INDEX screen_evidence_derivation_work ON screen_evidence_derivation(consumerID,storeID,observationID,channel,status)",
            "CREATE INDEX screen_evidence_derivation_expiry ON screen_evidence_derivation(deadline,attemptID)",
            """
            CREATE TRIGGER screen_evidence_derivation_capacity BEFORE INSERT ON screen_evidence_derivation
            WHEN (SELECT COUNT(*) FROM screen_evidence_derivation)>=256
            BEGIN SELECT RAISE(ABORT,'Screen evidence derivation capacity reached'); END
            """,
            """
            CREATE TRIGGER screen_evidence_artifact_insert_capacity BEFORE INSERT ON screen_evidence_derivation
            WHEN NEW.artifactBytes+(SELECT COALESCE(SUM(artifactBytes),0) FROM screen_evidence_derivation)>16777216
            BEGIN SELECT RAISE(ABORT,'Screen evidence artifact capacity reached'); END
            """,
            """
            CREATE TRIGGER screen_evidence_artifact_update_capacity BEFORE UPDATE OF artifactBytes ON screen_evidence_derivation
            WHEN NEW.artifactBytes>OLD.artifactBytes
              AND NEW.artifactBytes-OLD.artifactBytes+(SELECT COALESCE(SUM(artifactBytes),0) FROM screen_evidence_derivation)>16777216
            BEGIN SELECT RAISE(ABORT,'Screen evidence artifact capacity reached'); END
            """,
            """
            CREATE TRIGGER screen_evidence_admission_identity BEFORE UPDATE ON screen_evidence_admission_state
            WHEN OLD.feedID IS NOT NEW.feedID OR OLD.storeID IS NOT NEW.storeID
              OR NEW.policyEpoch<OLD.policyEpoch OR NEW.metadataEpoch<OLD.metadataEpoch
            BEGIN SELECT RAISE(ABORT,'Screen evidence admission identity cannot regress'); END
            """,
            """
            CREATE TRIGGER screen_evidence_admission_no_delete BEFORE DELETE ON screen_evidence_admission_state
            BEGIN SELECT RAISE(ABORT,'Screen evidence admission identity is retained'); END
            """,
            """
            CREATE TRIGGER screen_evidence_admission_frame_context AFTER UPDATE OF segmentId ON frame
            WHEN OLD.segmentId IS NOT NEW.segmentId BEGIN
              UPDATE screen_evidence_admission_state SET metadataEpoch=metadataEpoch+1 WHERE id=1;
            END
            """,
            """
            CREATE TRIGGER screen_evidence_admission_segment_context AFTER UPDATE OF id,bundleID,windowName,browserUrl ON segment
            WHEN OLD.id IS NOT NEW.id OR OLD.bundleID IS NOT NEW.bundleID
              OR OLD.windowName IS NOT NEW.windowName OR OLD.browserUrl IS NOT NEW.browserUrl BEGIN
              UPDATE screen_evidence_admission_state SET metadataEpoch=metadataEpoch+1 WHERE id=1;
            END
            """,
            """
            CREATE TRIGGER screen_evidence_admission_segment_delete AFTER DELETE ON segment BEGIN
              UPDATE screen_evidence_admission_state SET metadataEpoch=metadataEpoch+1 WHERE id=1;
            END
            """,
            // REPLACE need not run SQLite's DELETE triggers. Supported segment
            // writers insert fresh identities or UPDATE existing context instead.
            """
            CREATE TRIGGER screen_evidence_admission_segment_no_replace BEFORE INSERT ON segment
            WHEN EXISTS(SELECT 1 FROM segment WHERE id=NEW.id)
            BEGIN SELECT RAISE(ABORT,'Existing segment identity cannot be replaced'); END
            """,
            """
            CREATE TRIGGER screen_evidence_native_capture_payload BEFORE UPDATE OF framePayload,legacy ON screen_observation
            WHEN OLD.source='native' AND (OLD.framePayload IS NOT NEW.framePayload OR OLD.legacy IS NOT NEW.legacy)
            BEGIN SELECT RAISE(ABORT,'Native capture payload is immutable'); END
            """,
            """
            CREATE TRIGGER screen_evidence_native_dimensions BEFORE UPDATE OF width,height ON screen_observation
            WHEN OLD.source='native' AND
              (NEW.width<0 OR NEW.height<0 OR (OLD.width>0 AND NEW.width<>OLD.width) OR (OLD.height>0 AND NEW.height<>OLD.height))
            BEGIN SELECT RAISE(ABORT,'Established native dimensions are immutable'); END
            """,
            """
            CREATE TRIGGER screen_evidence_native_preference BEFORE UPDATE OF preferredRevision ON screen_observation
            WHEN OLD.source='native' AND NEW.preferredRevision IS NOT OLD.preferredRevision AND
              (NEW.preferredRevision<OLD.preferredRevision OR NOT EXISTS(
                SELECT 1 FROM screen_extraction WHERE observationID=OLD.observationID AND revision=NEW.preferredRevision))
            BEGIN SELECT RAISE(ABORT,'Native extraction preference cannot regress or invent a revision'); END
            """,
            """
            CREATE TRIGGER screen_evidence_native_extraction_immutable BEFORE UPDATE ON screen_extraction
            WHEN (OLD.observationID IS NOT NEW.observationID OR OLD.revision IS NOT NEW.revision OR OLD.payload IS NOT NEW.payload)
              AND EXISTS(SELECT 1 FROM screen_observation WHERE source='native' AND observationID IN (OLD.observationID,NEW.observationID))
            BEGIN SELECT RAISE(ABORT,'Native extraction payload is immutable'); END
            """,
            """
            CREATE TRIGGER screen_evidence_native_extraction_no_replace BEFORE INSERT ON screen_extraction
            WHEN EXISTS(SELECT 1 FROM screen_extraction e JOIN screen_observation o ON o.observationID=e.observationID
              WHERE e.observationID=NEW.observationID AND e.revision=NEW.revision AND o.source='native')
            BEGIN SELECT RAISE(ABORT,'Native extraction revision cannot be replaced'); END
            """,
            """
            CREATE TRIGGER screen_evidence_native_extraction_delete BEFORE DELETE ON screen_extraction
            WHEN EXISTS(SELECT 1 FROM screen_observation o WHERE o.observationID=OLD.observationID AND o.source='native'
              AND NOT EXISTS(SELECT 1 FROM screen_deleted d WHERE d.storeID=o.storeID AND d.observationID=o.observationID))
            BEGIN SELECT RAISE(ABORT,'Native extraction deletion requires its evidence tombstone'); END
            """,
            """
            CREATE TRIGGER screen_evidence_native_observation_delete BEFORE DELETE ON screen_observation
            WHEN OLD.source='native' AND NOT EXISTS(SELECT 1 FROM screen_deleted
              WHERE storeID=OLD.storeID AND observationID=OLD.observationID)
            BEGIN SELECT RAISE(ABORT,'Native observation deletion requires its evidence tombstone'); END
            """,
            """
            CREATE TRIGGER screen_evidence_artifact_source_delete AFTER INSERT ON screen_deleted
            WHEN NEW.storeID=(SELECT storeID FROM screen_evidence_admission_state WHERE id=1) BEGIN
              UPDATE screen_evidence_derivation SET status='invalidated',artifact=NULL,artifactBytes=0,
                receiptPayload=NULL,retainUntil=NULL WHERE storeID=NEW.storeID AND observationID=NEW.observationID;
            END
            """
        ])
    }
}
