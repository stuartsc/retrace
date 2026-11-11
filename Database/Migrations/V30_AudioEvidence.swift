import Foundation
import SQLCipher

/// Exact native transcript observations, preserving declared milliseconds and
/// legacy rows. V28 source provenance does not attest consent or app policy.
struct V30_AudioEvidence: Migration {
    let version = 30
    func migrate(db: OpaquePointer) async throws {
        try MigrationRunner.executeStatements(db: db, statements: [
            """
            CREATE TABLE audio_evidence_state (
              singleton INTEGER PRIMARY KEY CHECK(singleton=1),
              mutationRevision INTEGER NOT NULL CHECK(typeof(mutationRevision)='integer' AND mutationRevision>0),
              historicalBoundary INTEGER NOT NULL CHECK(historicalBoundary>=0),
              throughRowID INTEGER NOT NULL CHECK(throughRowID>=0 AND throughRowID<=historicalBoundary),
              bootstrapComplete INTEGER NOT NULL CHECK(bootstrapComplete IN (0,1)))
            """,
            """
            INSERT INTO audio_evidence_state SELECT 1,1,COALESCE(MAX(id),0),0,
              CASE WHEN COALESCE(MAX(id),0)=0 THEN 1 ELSE 0 END FROM audio_captures
            """,
            """
            CREATE TABLE audio_evidence_alias (
              nativeRowID INTEGER PRIMARY KEY CHECK(nativeRowID>0), observationID TEXT NOT NULL UNIQUE,
              storeID TEXT NOT NULL, revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0),
              state TEXT NOT NULL CHECK(state IN ('available','unavailable','deleted')),
              reason TEXT, batchAudioPath TEXT, recordingID TEXT)
            """,
            """
            CREATE INDEX audio_evidence_alias_lineage ON audio_evidence_alias(batchAudioPath)
            """,
            """
            CREATE INDEX audio_evidence_alias_recording ON audio_evidence_alias(recordingID)
            """,
            """
            CREATE TABLE audio_evidence_snapshot (
              nativeRowID INTEGER PRIMARY KEY REFERENCES audio_evidence_alias(nativeRowID),
              observationID TEXT NOT NULL, storeID TEXT NOT NULL, revision INTEGER NOT NULL,
              recordingID TEXT NOT NULL, recordingSource TEXT NOT NULL, recordingStart INTEGER NOT NULL,
              recordingEnd INTEGER NOT NULL, startedAt INTEGER NOT NULL, endedAt INTEGER NOT NULL,
              text TEXT NOT NULL CHECK(length(CAST(text AS BLOB)) BETWEEN 1 AND 65536),
              transcriptStatus TEXT NOT NULL, transcriptionPass INTEGER NOT NULL,
              detectedLanguage TEXT, audioVariant TEXT NOT NULL, confidence REAL)
            """,
            """
            CREATE TABLE audio_evidence_materialization (
              nativeRowID INTEGER PRIMARY KEY CHECK(nativeRowID>0))
            """,
            """
            CREATE INDEX audio_evidence_preferred_pass ON audio_captures(batch_audio_path,transcription_pass DESC,id)
              WHERE source!='word'
            """,
            """
            CREATE INDEX audio_evidence_original_candidates ON audio_captures(batch_audio_path,source,id)
              WHERE transcription_pass=1 AND source!='word'
            """,
            """
            CREATE VIEW audio_evidence_projection AS
            SELECT c.id AS nativeRowID,a.observationID,a.storeID,a.revision,
              o.recordingID,o.source AS recordingSource,o.startedAt AS recordingStart,o.endedAt AS recordingEnd,
              c.start_time AS startedAt,c.end_time AS endedAt,c.text,c.transcript_status AS transcriptStatus,
              c.transcription_pass AS transcriptionPass,c.detected_language AS detectedLanguage,
              c.audio_variant AS audioVariant,c.confidence,
              CASE
                WHEN a.state='deleted' OR o.state='invalidated' OR EXISTS(
                  SELECT 1 FROM audio_original_source_tombstone t WHERE t.batchAudioPath=c.batch_audio_path)
                  THEN 'evidenceDeleted'
                WHEN c.source='word' OR c.batch_audio_path IS NULL OR o.recordingID IS NULL
                  OR o.state!='active' OR o.storeID IS NOT a.storeID OR NOT EXISTS(
                    SELECT 1 FROM evidence_store e WHERE e.source='native' AND e.storeID=a.storeID)
                  OR typeof(o.startedAt)!='integer' OR typeof(o.endedAt)!='integer' OR o.endedAt<=o.startedAt
                  OR o.startedAt NOT BETWEEN -9000000000000000 AND 9000000000000000
                  OR o.endedAt NOT BETWEEN -9000000000000000 AND 9000000000000000
                  OR o.source NOT IN ('system','microphone','zoom','google_meet','microsoft_teams','slack','discord')
                  THEN 'lineageUnavailable'
                WHEN (a.recordingID IS NOT NULL AND a.recordingID IS NOT o.recordingID)
                  OR c.batch_audio_path IS NOT a.batchAudioPath OR c.source IS NOT o.source
                  THEN 'lineageConflicting'
                WHEN o.rawRetired=0 AND NOT EXISTS(
                  SELECT 1 FROM audio_captures r WHERE r.id=o.rawRowID AND r.audio_path=o.batchAudioPath
                    AND r.batch_audio_path IS NULL AND r.source=o.source AND r.start_time=o.startedAt
                    AND r.end_time=o.endedAt AND r.audio_size=o.audioSize AND r.transcription_pass=1)
                  THEN 'lineageUnavailable'
                WHEN EXISTS(SELECT 1 FROM audio_captures p INDEXED BY audio_evidence_original_candidates
                  WHERE p.batch_audio_path=c.batch_audio_path AND p.transcription_pass=1 AND p.source!='word' LIMIT 1 OFFSET 512)
                  THEN 'budgetExceeded'
                WHEN EXISTS(SELECT 1 FROM audio_captures p INDEXED BY audio_evidence_original_candidates
                  WHERE p.batch_audio_path=c.batch_audio_path AND p.transcription_pass=1 AND p.source!='word' AND p.source!=o.source)
                  THEN 'lineageConflicting'
                WHEN typeof(c.start_time)!='integer' OR typeof(c.end_time)!='integer' OR c.end_time<=c.start_time
                  OR c.start_time NOT BETWEEN -9000000000000000 AND 9000000000000000
                  OR c.end_time NOT BETWEEN -9000000000000000 AND 9000000000000000
                  OR c.start_time<o.startedAt OR c.end_time>o.endedAt THEN 'invalidTiming'
                WHEN typeof(c.text)!='text' OR length(CAST(c.text AS BLOB))>65536 THEN 'oversizedText'
                WHEN length(CAST(c.text AS BLOB))=0 OR instr(c.text,char(0))>0 OR c.transcript_status NOT IN ('transcribed','refinement_failed','refinement_skipped')
                  OR c.transcription_pass NOT BETWEEN 1 AND 3 OR typeof(c.transcription_pass)!='integer'
                  OR typeof(c.audio_variant)!='text' OR instr(c.audio_variant,char(0))>0
                  OR length(CAST(c.audio_variant AS BLOB)) NOT BETWEEN 1 AND 128
                  OR (c.detected_language IS NOT NULL AND (typeof(c.detected_language)!='text' OR instr(c.detected_language,char(0))>0 OR length(CAST(c.detected_language AS BLOB))>128))
                  OR (c.confidence IS NOT NULL AND (typeof(c.confidence) NOT IN ('real','integer') OR c.confidence<0 OR c.confidence>1))
                  THEN 'unavailableQuality'
                WHEN c.transcription_pass IS NOT (SELECT p.transcription_pass FROM audio_captures p INDEXED BY audio_evidence_preferred_pass
                  WHERE p.batch_audio_path=c.batch_audio_path AND p.source!='word' ORDER BY p.transcription_pass DESC LIMIT 1)
                  THEN 'revisionUnavailable'
                ELSE NULL END AS reason
            FROM audio_captures c JOIN audio_evidence_alias a ON a.nativeRowID=c.id
            LEFT JOIN audio_original_source o ON o.batchAudioPath=c.batch_audio_path
            """,
            """
            CREATE TRIGGER audio_evidence_alias_immutable BEFORE UPDATE ON audio_evidence_alias
            WHEN OLD.nativeRowID IS NOT NEW.nativeRowID OR OLD.observationID IS NOT NEW.observationID
              OR OLD.storeID IS NOT NEW.storeID OR OLD.batchAudioPath IS NOT NEW.batchAudioPath
              OR (OLD.recordingID IS NOT NULL AND OLD.recordingID IS NOT NEW.recordingID)
              OR NEW.revision<OLD.revision OR (OLD.state='deleted' AND NEW.state!='deleted')
            BEGIN SELECT RAISE(ABORT,'Audio evidence identity is immutable'); END
            """,
            """
            CREATE TRIGGER audio_evidence_alias_retain BEFORE DELETE ON audio_evidence_alias
            BEGIN SELECT RAISE(ABORT,'Audio evidence identities must remain retained'); END
            """,
            """
            CREATE TRIGGER audio_evidence_snapshot_immutable BEFORE UPDATE ON audio_evidence_snapshot
            BEGIN SELECT RAISE(ABORT,'Audio transcript snapshots are immutable'); END
            """,
            """
            CREATE TRIGGER audio_evidence_row_identity BEFORE UPDATE OF id ON audio_captures
            WHEN OLD.id IS NOT NEW.id BEGIN SELECT RAISE(ABORT,'Audio row identity is immutable'); END
            """,
            """
            CREATE TRIGGER audio_evidence_materialize AFTER INSERT ON audio_evidence_materialization
            BEGIN
              SELECT CASE WHEN EXISTS(SELECT 1 FROM audio_evidence_alias WHERE nativeRowID=NEW.nativeRowID AND state='deleted')
                THEN RAISE(ABORT,'Deleted audio row identity cannot be reused') END;
              INSERT INTO audio_evidence_alias(nativeRowID,observationID,storeID,revision,state,reason,batchAudioPath)
              SELECT c.id,lower(hex(randomblob(4)))||'-'||lower(hex(randomblob(2)))||'-'||lower(hex(randomblob(2)))||'-'||lower(hex(randomblob(2)))||'-'||lower(hex(randomblob(6))),
                e.storeID,1,'unavailable','lineageUnavailable',CASE WHEN length(CAST(c.batch_audio_path AS BLOB)) BETWEEN 1 AND 4096 THEN c.batch_audio_path ELSE NULL END
              FROM audio_captures c JOIN evidence_store e ON e.source='native' WHERE c.id=NEW.nativeRowID
              ON CONFLICT(nativeRowID) DO UPDATE SET revision=revision+1,state='unavailable',reason='lineageUnavailable';
              UPDATE audio_evidence_alias SET recordingID=COALESCE(recordingID,(SELECT recordingID FROM audio_evidence_projection
                WHERE nativeRowID=NEW.nativeRowID AND reason IS NULL)) WHERE nativeRowID=NEW.nativeRowID;
              UPDATE audio_evidence_alias SET
                state=CASE WHEN (SELECT reason FROM audio_evidence_projection WHERE nativeRowID=NEW.nativeRowID) IS NULL THEN 'available' ELSE 'unavailable' END,
                reason=(SELECT reason FROM audio_evidence_projection WHERE nativeRowID=NEW.nativeRowID)
              WHERE nativeRowID=NEW.nativeRowID;
              DELETE FROM audio_evidence_snapshot WHERE nativeRowID=NEW.nativeRowID;
              INSERT INTO audio_evidence_snapshot SELECT nativeRowID,observationID,storeID,revision,recordingID,recordingSource,
                recordingStart,recordingEnd,startedAt,endedAt,text,transcriptStatus,transcriptionPass,detectedLanguage,audioVariant,confidence
              FROM audio_evidence_projection WHERE nativeRowID=NEW.nativeRowID AND reason IS NULL;
              UPDATE audio_evidence_state SET mutationRevision=mutationRevision+1 WHERE singleton=1;
              INSERT INTO daily_metrics(metricType,timestamp,metadata) VALUES('audio_evidence',CAST(strftime('%s','now') AS INTEGER)*1000,
                CASE WHEN EXISTS(SELECT 1 FROM audio_evidence_snapshot WHERE nativeRowID=NEW.nativeRowID)
                  THEN '{"outcome":"snapshot"}' ELSE '{"outcome":"unavailable"}' END);
              DELETE FROM audio_evidence_materialization WHERE nativeRowID=NEW.nativeRowID;
            END
            """,
            """
            CREATE TRIGGER audio_evidence_insert AFTER INSERT ON audio_captures
            BEGIN INSERT INTO audio_evidence_materialization(nativeRowID) VALUES(NEW.id); END
            """,
            """
            CREATE TRIGGER audio_evidence_update AFTER UPDATE ON audio_captures
            BEGIN
              INSERT INTO audio_evidence_materialization(nativeRowID) SELECT NEW.id
                WHERE NOT EXISTS(SELECT 1 FROM audio_evidence_alias WHERE nativeRowID=NEW.id AND state='deleted');
              UPDATE audio_evidence_state SET mutationRevision=mutationRevision+1 WHERE singleton=1;
            END
            """,
            """
            CREATE TRIGGER audio_evidence_delete AFTER DELETE ON audio_captures
            BEGIN
              DELETE FROM audio_evidence_snapshot WHERE nativeRowID=OLD.id;
              UPDATE audio_evidence_alias SET state='deleted',reason='evidenceDeleted',revision=revision+1 WHERE nativeRowID=OLD.id;
              UPDATE audio_evidence_state SET mutationRevision=mutationRevision+1 WHERE singleton=1;
              INSERT INTO daily_metrics(metricType,timestamp,metadata) VALUES('audio_evidence',CAST(strftime('%s','now') AS INTEGER)*1000,'{"outcome":"deleted"}');
            END
            """,
            """
            CREATE TRIGGER audio_evidence_lineage_tombstone AFTER INSERT ON audio_original_source_tombstone
            BEGIN
              DELETE FROM audio_evidence_snapshot WHERE nativeRowID IN (
                SELECT nativeRowID FROM audio_evidence_alias WHERE batchAudioPath=NEW.batchAudioPath);
              UPDATE audio_evidence_alias SET state='deleted',reason='evidenceDeleted',revision=revision+1 WHERE batchAudioPath=NEW.batchAudioPath;
              UPDATE audio_evidence_state SET mutationRevision=mutationRevision+1 WHERE singleton=1;
            END
            """,
            """
            CREATE TRIGGER audio_evidence_origin_change AFTER UPDATE ON audio_original_source
            BEGIN
              DELETE FROM audio_evidence_snapshot WHERE NEW.state='invalidated' AND nativeRowID IN (
                SELECT nativeRowID FROM audio_evidence_alias WHERE recordingID=NEW.recordingID OR batchAudioPath=NEW.batchAudioPath);
              UPDATE audio_evidence_alias SET state='deleted',reason='evidenceDeleted',revision=revision+1
                WHERE NEW.state='invalidated' AND (recordingID=NEW.recordingID OR batchAudioPath=NEW.batchAudioPath);
              UPDATE audio_evidence_state SET mutationRevision=mutationRevision+1 WHERE singleton=1;
            END
            """,
            """
            CREATE TRIGGER audio_evidence_origin_insert AFTER INSERT ON audio_original_source
            BEGIN UPDATE audio_evidence_state SET mutationRevision=mutationRevision+1 WHERE singleton=1; END
            """,
            """
            CREATE TRIGGER audio_evidence_store_update AFTER UPDATE ON evidence_store
            BEGIN UPDATE audio_evidence_state SET mutationRevision=mutationRevision+1 WHERE singleton=1; END
            """,
            """
            CREATE TRIGGER audio_evidence_store_delete AFTER DELETE ON evidence_store
            BEGIN UPDATE audio_evidence_state SET mutationRevision=mutationRevision+1 WHERE singleton=1; END
            """
        ])
    }
}
