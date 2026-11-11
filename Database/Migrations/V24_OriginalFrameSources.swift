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
            """
        ])
    }
}
