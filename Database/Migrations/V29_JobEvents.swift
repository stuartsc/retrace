import Foundation
import Shared
import SQLCipher

/// Additive categorical job receipts. No retained screen/audio scan or rewrite.
struct V29_JobEvents: Migration {
    let version = 29
    func migrate(db: OpaquePointer) async throws {
        try MigrationRunner.executeStatements(db: db, statements: [
            """
            CREATE TABLE job_state(id INTEGER PRIMARY KEY CHECK(id=1),
              revision INTEGER NOT NULL CHECK(revision>=0 AND revision<9223372036854775807));
            INSERT INTO job_state VALUES(1,0);
            """,
            """
            CREATE TABLE job_run(
              runID TEXT PRIMARY KEY, storeID TEXT NOT NULL, producerID TEXT NOT NULL,
              ownerID TEXT NOT NULL, admissionPayload TEXT NOT NULL CHECK(length(admissionPayload)<=8192),
              policySHA256 TEXT NOT NULL CHECK(length(policySHA256)=64),
              kind TEXT NOT NULL CHECK(kind IN ('build','test','command')),
              startEventID TEXT NOT NULL UNIQUE, terminalEventID TEXT UNIQUE);
            CREATE INDEX job_run_open ON job_run(terminalEventID,ownerID);
            """,
            """
            CREATE TABLE job_event(
              sequence INTEGER PRIMARY KEY AUTOINCREMENT, eventID TEXT NOT NULL UNIQUE,
              runID TEXT NOT NULL REFERENCES job_run(runID) ON DELETE CASCADE,
              observerID TEXT NOT NULL, phase TEXT NOT NULL CHECK(phase IN ('started','terminal','gap')),
              kind TEXT NOT NULL CHECK(kind IN ('build','test','command')),
              outcome TEXT NOT NULL CHECK(outcome IN ('','succeeded','failed','signalled','launchFailed','interrupted')),
              observedAt REAL NOT NULL, observedUptime REAL NOT NULL CHECK(observedUptime>=0), receivedAt REAL NOT NULL,
              policySHA256 TEXT NOT NULL CHECK(length(policySHA256)=64),
              payload TEXT NOT NULL CHECK(length(payload)<=8192), payloadSHA256 TEXT NOT NULL CHECK(length(payloadSHA256)=64),
              UNIQUE(runID,phase));
            CREATE INDEX job_event_chronology ON job_event(policySHA256,observedAt DESC,sequence DESC);
            CREATE INDEX job_event_kind ON job_event(policySHA256,kind,observedAt DESC,sequence DESC);
            CREATE INDEX job_event_outcome ON job_event(policySHA256,outcome,observedAt DESC,sequence DESC);
            """,
            """
            CREATE TABLE job_deleted(
              runID TEXT PRIMARY KEY, storeID TEXT NOT NULL, producerID TEXT NOT NULL,
              startEventID TEXT NOT NULL UNIQUE, terminalEventID TEXT UNIQUE, deletedAt REAL NOT NULL);
            CREATE TRIGGER job_run_deleted BEFORE DELETE ON job_run BEGIN
              INSERT OR IGNORE INTO job_deleted(runID,storeID,producerID,startEventID,terminalEventID,deletedAt)
              VALUES(OLD.runID,OLD.storeID,OLD.producerID,OLD.startEventID,OLD.terminalEventID,
                     (julianday('now')-2440587.5)*86400.0);
            END;
            CREATE TRIGGER job_event_immutable BEFORE UPDATE ON job_event BEGIN
              SELECT RAISE(ABORT,'Immutable job evidence');
            END;
            CREATE TRIGGER job_event_insert_revision AFTER INSERT ON job_event BEGIN
              UPDATE job_state SET revision=revision+1 WHERE id=1;
            END;
            CREATE TRIGGER job_event_delete_revision AFTER DELETE ON job_event BEGIN
              UPDATE job_state SET revision=revision+1 WHERE id=1;
            END;
            CREATE TRIGGER job_deleted_revision AFTER INSERT ON job_deleted BEGIN
              UPDATE job_state SET revision=revision+1 WHERE id=1;
            END;
            """
        ])
    }
}
