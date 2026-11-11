import Foundation
import SQLCipher

/// Source-only receipts. These do not establish consent, app attribution, exact
/// transcript revisions, or general audio evidence admission.
struct V28_AudioOriginalSources: Migration {
    let version = 28

    func migrate(db: OpaquePointer) async throws {
        try MigrationRunner.executeStatements(db: db, statements: [
            """
            CREATE TABLE audio_original_source (
              recordingID TEXT PRIMARY KEY, storeID TEXT NOT NULL,
              batchAudioPath TEXT NOT NULL UNIQUE CHECK(length(CAST(batchAudioPath AS BLOB)) BETWEEN 1 AND 4096),
              rawRowID INTEGER NOT NULL UNIQUE CHECK(rawRowID>0), source TEXT NOT NULL,
              startedAt INTEGER NOT NULL, endedAt INTEGER NOT NULL CHECK(endedAt>startedAt),
              audioSize INTEGER NOT NULL CHECK(audioSize>0),
              generation INTEGER NOT NULL DEFAULT 1 CHECK(typeof(generation)='integer' AND generation>0),
              state TEXT NOT NULL DEFAULT 'active' CHECK(state IN ('active','invalidated')),
              rawRetired INTEGER NOT NULL DEFAULT 0 CHECK(rawRetired IN (0,1)))
            """,
            """
            CREATE TABLE audio_original_source_tombstone (
              batchAudioPath TEXT PRIMARY KEY CHECK(length(CAST(batchAudioPath AS BLOB)) BETWEEN 1 AND 4096))
            """,
            """
            CREATE INDEX audio_original_source_legacy_raw ON audio_captures(audio_path,id)
              WHERE batch_audio_path IS NULL
            """,
            """
            CREATE TRIGGER audio_original_source_immutable BEFORE UPDATE ON audio_original_source
            WHEN OLD.recordingID IS NOT NEW.recordingID OR OLD.storeID IS NOT NEW.storeID
              OR OLD.batchAudioPath IS NOT NEW.batchAudioPath OR OLD.rawRowID IS NOT NEW.rawRowID
              OR OLD.source IS NOT NEW.source OR OLD.startedAt IS NOT NEW.startedAt
              OR OLD.endedAt IS NOT NEW.endedAt OR OLD.audioSize IS NOT NEW.audioSize
              OR NEW.generation<OLD.generation OR NEW.rawRetired<OLD.rawRetired
              OR (OLD.state='invalidated' AND NEW.state!='invalidated')
            BEGIN SELECT RAISE(ABORT,'Original audio source identity is immutable'); END
            """,
            """
            CREATE TRIGGER audio_original_source_retain BEFORE DELETE ON audio_original_source
            BEGIN SELECT RAISE(ABORT,'Original audio source aliases must remain retained'); END
            """,
            """
            CREATE TRIGGER audio_original_source_tombstone_retain BEFORE DELETE ON audio_original_source_tombstone
            BEGIN SELECT RAISE(ABORT,'Original audio deletion aliases must remain retained'); END
            """,
            """
            CREATE TRIGGER audio_original_source_tombstone_immutable BEFORE UPDATE ON audio_original_source_tombstone
            BEGIN SELECT RAISE(ABORT,'Original audio deletion aliases are immutable'); END
            """,
            """
            CREATE TRIGGER audio_original_source_raw_guard BEFORE INSERT ON audio_captures
            WHEN NEW.audio_size IS NOT NULL AND NEW.batch_audio_path IS NULL
            BEGIN
              SELECT CASE WHEN NEW.audio_size<=0 OR NEW.end_time<=NEW.start_time
                OR NEW.audio_path IS NULL OR length(CAST(NEW.audio_path AS BLOB)) NOT BETWEEN 1 AND 4096
                OR NEW.transcription_pass!=1
                OR NOT EXISTS(SELECT 1 FROM evidence_store WHERE source='native')
                THEN RAISE(ABORT,'Invalid original audio source row') END;
              SELECT CASE WHEN EXISTS(SELECT 1 FROM audio_original_source WHERE batchAudioPath=NEW.audio_path)
                OR EXISTS(SELECT 1 FROM audio_original_source_tombstone WHERE batchAudioPath=NEW.audio_path)
                OR EXISTS(SELECT 1 FROM audio_captures WHERE audio_path=NEW.audio_path AND batch_audio_path IS NULL)
                OR EXISTS(SELECT 1 FROM audio_captures WHERE batch_audio_path=NEW.audio_path)
                THEN RAISE(ABORT,'Original audio path cannot be reused') END;
            END
            """,
            """
            CREATE TRIGGER audio_original_source_raw_insert AFTER INSERT ON audio_captures
            WHEN NEW.audio_size>0 AND NEW.batch_audio_path IS NULL
            BEGIN
              INSERT INTO audio_original_source(recordingID,storeID,batchAudioPath,rawRowID,source,startedAt,endedAt,audioSize)
              SELECT lower(hex(randomblob(4)))||'-'||lower(hex(randomblob(2)))||'-'||lower(hex(randomblob(2)))||'-'||lower(hex(randomblob(2)))||'-'||lower(hex(randomblob(6))),
                storeID,NEW.audio_path,NEW.id,NEW.source,NEW.start_time,NEW.end_time,NEW.audio_size
              FROM evidence_store WHERE source='native';
              INSERT INTO daily_metrics(metricType,timestamp,metadata) VALUES('audio_original_source',CAST(strftime('%s','now') AS INTEGER)*1000,'{"outcome":"receipt"}');
            END
            """,
            """
            CREATE TRIGGER audio_original_source_insert_guard BEFORE INSERT ON audio_captures
            WHEN NEW.batch_audio_path IS NOT NULL AND EXISTS(
              SELECT 1 FROM audio_original_source_tombstone WHERE batchAudioPath=NEW.batch_audio_path)
            BEGIN SELECT RAISE(ABORT,'Deleted original audio cannot be republished'); END
            """,
            """
            CREATE TRIGGER audio_original_source_insert_generation AFTER INSERT ON audio_captures
            WHEN NEW.batch_audio_path IS NOT NULL
            BEGIN UPDATE audio_original_source SET generation=generation+1 WHERE batchAudioPath=NEW.batch_audio_path; END
            """,
            """
            CREATE TRIGGER audio_original_source_update_generation AFTER UPDATE ON audio_captures
            BEGIN
              UPDATE audio_original_source SET generation=generation+1
              WHERE batchAudioPath IN (OLD.batch_audio_path,NEW.batch_audio_path) OR rawRowID=OLD.id;
            END
            """,
            """
            CREATE TRIGGER audio_original_source_raw_change AFTER UPDATE ON audio_captures
            WHEN OLD.audio_size>0 AND OLD.batch_audio_path IS NULL AND (
              OLD.id IS NOT NEW.id OR OLD.source IS NOT NEW.source OR OLD.start_time IS NOT NEW.start_time
              OR OLD.end_time IS NOT NEW.end_time OR OLD.audio_path IS NOT NEW.audio_path
              OR OLD.audio_size IS NOT NEW.audio_size OR OLD.batch_audio_path IS NOT NEW.batch_audio_path)
            BEGIN
              INSERT OR IGNORE INTO audio_original_source_tombstone(batchAudioPath) VALUES(OLD.audio_path);
              INSERT OR IGNORE INTO audio_original_source_tombstone(batchAudioPath)
                SELECT NEW.audio_path WHERE NEW.audio_path IS NOT NULL AND length(CAST(NEW.audio_path AS BLOB)) BETWEEN 1 AND 4096;
              UPDATE audio_original_source SET state='invalidated' WHERE rawRowID=OLD.id;
            END
            """,
            """
            CREATE TRIGGER audio_original_source_transcript_delete BEFORE DELETE ON audio_captures
            WHEN OLD.source!='word' AND OLD.batch_audio_path IS NOT NULL AND length(CAST(OLD.batch_audio_path AS BLOB)) BETWEEN 1 AND 4096
            BEGIN
              INSERT OR IGNORE INTO audio_original_source_tombstone(batchAudioPath) VALUES(OLD.batch_audio_path);
              UPDATE audio_original_source SET state='invalidated',generation=generation+1 WHERE batchAudioPath=OLD.batch_audio_path;
            END
            """,
            """
            CREATE TRIGGER audio_original_source_raw_delete BEFORE DELETE ON audio_captures
            WHEN OLD.audio_size>0 AND OLD.batch_audio_path IS NULL AND NOT EXISTS(
              SELECT 1 FROM audio_original_source WHERE rawRowID=OLD.id AND rawRetired=1 AND state='active')
            BEGIN
              INSERT OR IGNORE INTO audio_original_source_tombstone(batchAudioPath) VALUES(OLD.audio_path);
              UPDATE audio_original_source SET state='invalidated',generation=generation+1 WHERE rawRowID=OLD.id;
            END
            """
        ])
    }
}
