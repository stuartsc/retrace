import Foundation
import SQLCipher

/// Additive references to independently encoded chunks. Existing audio paths and
/// media bytes are not rewritten. Deletion fences access but never unlinks files.
struct V32_AudioChunkMedia: Migration {
    let version = 32

    func migrate(db: OpaquePointer) async throws {
        try MigrationRunner.executeStatements(db: db, statements: [
            """
            CREATE TABLE audio_media_chunk (
              chunkID TEXT PRIMARY KEY, storeID TEXT NOT NULL, streamID TEXT NOT NULL,
              startFrame INTEGER NOT NULL CHECK(startFrame>=0), frameCount INTEGER NOT NULL CHECK(frameCount BETWEEN 1 AND 160000),
              relativePath TEXT NOT NULL UNIQUE,
              descriptorJSON TEXT NOT NULL CHECK(length(CAST(descriptorJSON AS BLOB)) BETWEEN 1 AND 8192),
              UNIQUE(storeID,streamID,startFrame))
            """,
            """
            CREATE TABLE audio_media_window (
              windowID TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK(kind='chunkWindowV1'),
              storeID TEXT NOT NULL, streamID TEXT NOT NULL, source TEXT NOT NULL, origin REAL NOT NULL,
              startFrame INTEGER NOT NULL CHECK(startFrame>=0), frameCount INTEGER NOT NULL CHECK(frameCount BETWEEN 1 AND 240000),
              ownedStartFrame INTEGER NOT NULL CHECK(ownedStartFrame BETWEEN 0 AND 80000),
              relativePath TEXT NOT NULL UNIQUE, manifestSHA256 TEXT NOT NULL CHECK(length(manifestSHA256)=64),
              manifestBytes INTEGER NOT NULL CHECK(manifestBytes BETWEEN 1 AND 65536),
              rawRowID INTEGER NOT NULL UNIQUE CHECK(rawRowID>0), recordingID TEXT NOT NULL UNIQUE,
              state TEXT NOT NULL DEFAULT 'active' CHECK(state IN ('active','deleted')))
            """,
            """
            CREATE TABLE audio_media_window_range (
              windowID TEXT NOT NULL REFERENCES audio_media_window(windowID),
              ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 0 AND 1),
              chunkID TEXT NOT NULL REFERENCES audio_media_chunk(chunkID),
              offsetFrames INTEGER NOT NULL CHECK(offsetFrames>=0),
              frameCount INTEGER NOT NULL CHECK(frameCount BETWEEN 1 AND 160000),
              PRIMARY KEY(windowID,ordinal), UNIQUE(windowID,chunkID))
            """,
            "CREATE INDEX audio_media_range_chunk ON audio_media_window_range(chunkID,windowID)",
            """
            CREATE TRIGGER audio_media_chunk_immutable BEFORE UPDATE ON audio_media_chunk
            BEGIN SELECT RAISE(ABORT,'Audio chunk receipts are immutable'); END
            """,
            """
            CREATE TRIGGER audio_media_chunk_retain BEFORE DELETE ON audio_media_chunk
            BEGIN SELECT RAISE(ABORT,'Audio chunk receipts must remain retained'); END
            """,
            """
            CREATE TRIGGER audio_media_window_immutable BEFORE UPDATE ON audio_media_window
            WHEN OLD.windowID IS NOT NEW.windowID OR OLD.kind IS NOT NEW.kind OR OLD.storeID IS NOT NEW.storeID
              OR OLD.streamID IS NOT NEW.streamID OR OLD.source IS NOT NEW.source OR OLD.origin IS NOT NEW.origin
              OR OLD.startFrame IS NOT NEW.startFrame OR OLD.frameCount IS NOT NEW.frameCount
              OR OLD.ownedStartFrame IS NOT NEW.ownedStartFrame OR OLD.relativePath IS NOT NEW.relativePath
              OR OLD.manifestSHA256 IS NOT NEW.manifestSHA256 OR OLD.manifestBytes IS NOT NEW.manifestBytes
              OR OLD.rawRowID IS NOT NEW.rawRowID OR OLD.recordingID IS NOT NEW.recordingID
              OR (OLD.state='deleted' AND NEW.state!='deleted')
            BEGIN SELECT RAISE(ABORT,'Audio window identity is immutable'); END
            """,
            """
            CREATE TRIGGER audio_media_window_retain BEFORE DELETE ON audio_media_window
            BEGIN SELECT RAISE(ABORT,'Audio window identities must remain retained'); END
            """,
            """
            CREATE TRIGGER audio_media_range_immutable BEFORE UPDATE ON audio_media_window_range
            BEGIN SELECT RAISE(ABORT,'Audio window ranges are immutable'); END
            """,
            """
            CREATE TRIGGER audio_media_range_retain BEFORE DELETE ON audio_media_window_range
            BEGIN SELECT RAISE(ABORT,'Audio window ranges must remain retained'); END
            """,
            """
            CREATE TRIGGER audio_media_lineage_tombstone AFTER INSERT ON audio_original_source_tombstone
            BEGIN UPDATE audio_media_window SET state='deleted' WHERE relativePath=NEW.batchAudioPath AND state='active'; END
            """,
            """
            CREATE TRIGGER audio_media_origin_invalidated AFTER UPDATE OF state ON audio_original_source
            WHEN NEW.state='invalidated'
            BEGIN UPDATE audio_media_window SET state='deleted' WHERE recordingID=NEW.recordingID AND state='active'; END
            """,
            """
            CREATE TRIGGER audio_media_window_invalidated AFTER UPDATE OF state ON audio_media_window
            WHEN NEW.state='deleted' AND OLD.state='active'
            BEGIN
              INSERT OR IGNORE INTO audio_original_source_tombstone(batchAudioPath) VALUES(NEW.relativePath);
              UPDATE audio_original_source SET state='invalidated',generation=generation+1
                WHERE recordingID=NEW.recordingID AND state='active';
              UPDATE audio_evidence_state SET mutationRevision=mutationRevision+1 WHERE singleton=1;
            END
            """
        ])
    }
}
