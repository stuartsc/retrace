import Foundation
import SQLCipher

/// Additive aliases for newly admitted originals. No historical scan, archive
/// rewrite or automatic adoption of unqualified legacy journals occurs.
struct V24_OriginalFrameSources: Migration {
    let version = 24

    func migrate(db: OpaquePointer) async throws {
        try MigrationRunner.executeStatements(db: db, statements: [
            """
            CREATE TABLE original_frame_source (
              storeID TEXT NOT NULL REFERENCES evidence_store(storeID),
              originalVideoPathID INTEGER NOT NULL CHECK(originalVideoPathID>0),
              sourceIndex INTEGER NOT NULL CHECK(sourceIndex>=0),
              frameID INTEGER NOT NULL CHECK(frameID>0),
              deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0,1)),
              PRIMARY KEY(storeID,originalVideoPathID,sourceIndex),
              UNIQUE(storeID,frameID))
            """,
            "CREATE INDEX original_frame_source_frame ON original_frame_source(frameID,deleted)",
            """
            CREATE TRIGGER original_frame_source_deleted BEFORE DELETE ON frame BEGIN
              UPDATE original_frame_source SET deleted=1 WHERE frameID=OLD.id;
            END
            """,
            """
            CREATE TRIGGER original_frame_source_identity BEFORE UPDATE ON original_frame_source
            WHEN OLD.storeID IS NOT NEW.storeID OR OLD.originalVideoPathID IS NOT NEW.originalVideoPathID
              OR OLD.sourceIndex IS NOT NEW.sourceIndex OR OLD.frameID IS NOT NEW.frameID
              OR NEW.deleted<OLD.deleted
            BEGIN SELECT RAISE(ABORT,'Original frame identity cannot be rebound'); END
            """,
            """
            CREATE TRIGGER original_frame_source_retained BEFORE DELETE ON original_frame_source
            BEGIN SELECT RAISE(ABORT,'Original frame tombstones are retained'); END
            """,
            """
            CREATE TABLE original_frame_extraction_skip (
              frameID INTEGER PRIMARY KEY REFERENCES frame(id) ON DELETE CASCADE,
              storeID TEXT NOT NULL REFERENCES evidence_store(storeID),
              observationID TEXT NOT NULL REFERENCES screen_observation(observationID) ON DELETE CASCADE,
              captureTimestamp INTEGER NOT NULL,
              reason TEXT NOT NULL CHECK(reason='app_excluded'),
              recordedAt INTEGER NOT NULL)
            """,
            "CREATE INDEX original_frame_skip_store ON original_frame_extraction_skip(storeID)",
            "CREATE INDEX original_frame_skip_observation ON original_frame_extraction_skip(observationID)",
            """
            CREATE TRIGGER original_frame_skip_reset AFTER UPDATE OF processingStatus ON frame
            WHEN NEW.processingStatus IS NOT 2
            BEGIN DELETE FROM original_frame_extraction_skip WHERE frameID=NEW.id; END
            """
        ])
    }
}
