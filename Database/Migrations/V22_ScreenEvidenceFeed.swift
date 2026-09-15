import Foundation
import SQLCipher

/// Constant-size migration: retained observations are visited only by bounded
/// consumer bootstrap. Existing frame/extraction payloads remain unchanged.
struct V22_ScreenEvidenceFeed: Migration {
    let version = 22

    func migrate(db: OpaquePointer) async throws {
        let storeID = try RecallSQL.nativeStore(db)
        try MigrationRunner.executeStatements(db: db, statements: [
            """
            CREATE TABLE screen_evidence_feed_state (
              id INTEGER PRIMARY KEY CHECK(id=1), feedID TEXT NOT NULL UNIQUE,
              storeID TEXT NOT NULL REFERENCES evidence_store(storeID),
              latestSequence INTEGER NOT NULL DEFAULT 0 CHECK(latestSequence>=0),
              retainedThrough INTEGER NOT NULL DEFAULT 0 CHECK(retainedThrough>=0 AND retainedThrough<=latestSequence))
            """,
            "INSERT INTO screen_evidence_feed_state(id,feedID,storeID) VALUES(1,'\(UUID().uuidString)','\(storeID.uuidString)')",
            """
            CREATE TABLE screen_evidence_feed (
              sequence INTEGER PRIMARY KEY AUTOINCREMENT,
              kind TEXT NOT NULL CHECK(kind IN ('extraction_published','deleted','media_unavailable','media_restored','media_link_changed','redaction_changed')),
              storeID TEXT NOT NULL, source TEXT NOT NULL CHECK(source='native'),
              observationID TEXT NOT NULL, frameID INTEGER NOT NULL CHECK(frameID>0),
              extractionRevision INTEGER NOT NULL CHECK(extractionRevision>=0))
            """,
            """
            CREATE TABLE screen_evidence_source_state (
              storeID TEXT NOT NULL, observationID TEXT NOT NULL, frameID INTEGER NOT NULL CHECK(frameID>0),
              latestSequence INTEGER NOT NULL CHECK(latestSequence>=0),
              extractionRevision INTEGER NOT NULL CHECK(extractionRevision>=0),
              deleted INTEGER NOT NULL CHECK(deleted IN (0,1)), redacted INTEGER NOT NULL CHECK(redacted IN (0,1)),
              mediaUnavailableReason TEXT CHECK(mediaUnavailableReason IN ('recordingMissing','integrityFailure','frameFinalising')),
              PRIMARY KEY(storeID,observationID))
            """,
            """
            CREATE TABLE screen_evidence_consumer (
              consumerID TEXT PRIMARY KEY, feedID TEXT NOT NULL, storeID TEXT NOT NULL, leaseID TEXT NOT NULL,
              phase TEXT NOT NULL CHECK(phase IN ('bootstrap','replay','expired')),
              bootstrapBoundary INTEGER NOT NULL CHECK(bootstrapBoundary>=0),
              maxFrameID INTEGER NOT NULL CHECK(maxFrameID>=0), lastFrameID INTEGER NOT NULL CHECK(lastFrameID>=0 AND lastFrameID<=maxFrameID),
              checkpoint INTEGER NOT NULL CHECK(checkpoint>=0), expiresAt REAL NOT NULL)
            """,
            "CREATE INDEX screen_evidence_consumer_expiry ON screen_evidence_consumer(expiresAt)",
            """
            CREATE TABLE screen_evidence_applied (
              consumerID TEXT NOT NULL REFERENCES screen_evidence_consumer(consumerID),
              eventSequence INTEGER NOT NULL CHECK(eventSequence>0), PRIMARY KEY(consumerID,eventSequence))
            """,
            """
            CREATE TABLE screen_evidence_work (
              consumerID TEXT NOT NULL REFERENCES screen_evidence_consumer(consumerID),
              storeID TEXT NOT NULL, observationID TEXT NOT NULL, frameID INTEGER NOT NULL CHECK(frameID>0),
              leaseID TEXT NOT NULL, channel TEXT NOT NULL CHECK(channel IN ('lexical','vector')),
              extractionRevision INTEGER NOT NULL CHECK(extractionRevision>=0),
              sourceSequence INTEGER NOT NULL CHECK(sourceSequence>=0),
              state TEXT NOT NULL CHECK(state IN ('blocked','invalidated','deleted')),
              PRIMARY KEY(consumerID,storeID,observationID,channel))
            """,
            "CREATE INDEX screen_evidence_work_observation ON screen_evidence_work(storeID,observationID)",
            """
            CREATE TRIGGER screen_evidence_consumer_capacity BEFORE INSERT ON screen_evidence_consumer
            WHEN NOT EXISTS(SELECT 1 FROM screen_evidence_consumer WHERE consumerID=NEW.consumerID)
              AND (SELECT COUNT(*) FROM screen_evidence_consumer)>=32
            BEGIN SELECT RAISE(ABORT,'Screen evidence consumer capacity reached'); END
            """
        ])
        try ScreenEvidenceFeedSQL.installPublicationTriggers(db)
    }
}
