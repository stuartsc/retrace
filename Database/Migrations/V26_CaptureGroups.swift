import Foundation
import SQLCipher

/// Additive capture receipts. Old frames receive no inferred display group.
struct V26_CaptureGroups: Migration {
    let version = 26
    func migrate(db: OpaquePointer) async throws {
        try MigrationRunner.executeStatements(db: db, statements: [
            "CREATE TABLE capture_group_state(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL CHECK(revision>=0 AND revision<9223372036854775807))",
            "INSERT INTO capture_group_state(id,revision) VALUES(1,0)",
            """
            CREATE TABLE capture_display_attachment (
              attachmentID TEXT PRIMARY KEY NOT NULL, sessionID TEXT NOT NULL,
              descriptorSHA256 TEXT NOT NULL, descriptor TEXT NOT NULL CHECK(length(descriptor)<=4096))
            """,
            """
            CREATE TABLE capture_group (
              groupID TEXT PRIMARY KEY NOT NULL, storeID TEXT NOT NULL REFERENCES evidence_store(storeID),
              sessionID TEXT NOT NULL, writerID TEXT NOT NULL, policyEpoch INTEGER NOT NULL CHECK(policyEpoch>0),
              configurationGeneration INTEGER NOT NULL CHECK(configurationGeneration>=0),
              enumerationStart REAL NOT NULL, enumerationEnd REAL NOT NULL,
              descriptor TEXT NOT NULL CHECK(length(descriptor)<=65536),
              samplingEnd TEXT, samplingEndUptime REAL)
            """,
            "CREATE INDEX capture_group_session ON capture_group(sessionID,enumerationEnd)",
            """
            CREATE TABLE capture_group_member (
              attemptID TEXT PRIMARY KEY NOT NULL, groupID TEXT NOT NULL REFERENCES capture_group(groupID),
              ordinal INTEGER NOT NULL CHECK(ordinal>=0 AND ordinal<64),
              attachmentID TEXT NOT NULL REFERENCES capture_display_attachment(attachmentID),
              displayID INTEGER NOT NULL CHECK(displayID>0),
              phase TEXT NOT NULL DEFAULT 'pending' CHECK(phase IN ('pending','retainedCandidate','suppressedSimilar','unavailable','dropped','cancelled')),
              outcome TEXT CHECK(outcome IS NULL OR length(outcome)<=16384),
              latestUptime REAL NOT NULL, frameID INTEGER UNIQUE,
              deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0,1)),
              UNIQUE(groupID,ordinal), UNIQUE(groupID,displayID),
              CHECK(frameID IS NULL OR phase='retainedCandidate'))
            """,
            "CREATE INDEX capture_group_members ON capture_group_member(groupID,ordinal)",
            """
            CREATE TABLE capture_group_event (
              eventID TEXT PRIMARY KEY NOT NULL, eventSHA256 TEXT NOT NULL,
              groupID TEXT NOT NULL REFERENCES capture_group(groupID))
            """,
            """
            CREATE TRIGGER capture_group_frame_deleted BEFORE DELETE ON frame BEGIN
              UPDATE capture_group_member SET deleted=1 WHERE frameID=OLD.id;
            END
            """,
            """
            CREATE TRIGGER capture_group_event_revision AFTER INSERT ON capture_group_event BEGIN
              UPDATE capture_group_state SET revision=revision+1 WHERE id=1;
            END
            """,
            """
            CREATE TRIGGER capture_group_member_revision AFTER UPDATE ON capture_group_member
            WHEN OLD.phase IS NOT NEW.phase OR OLD.outcome IS NOT NEW.outcome
              OR OLD.frameID IS NOT NEW.frameID OR OLD.deleted IS NOT NEW.deleted BEGIN
              UPDATE capture_group_state SET revision=revision+1 WHERE id=1;
            END
            """,
            """
            CREATE TRIGGER capture_group_member_identity BEFORE UPDATE ON capture_group_member
            WHEN OLD.attemptID IS NOT NEW.attemptID OR OLD.groupID IS NOT NEW.groupID
              OR OLD.ordinal IS NOT NEW.ordinal OR OLD.attachmentID IS NOT NEW.attachmentID
              OR OLD.displayID IS NOT NEW.displayID OR NEW.deleted<OLD.deleted
              OR (OLD.frameID IS NOT NULL AND OLD.frameID IS NOT NEW.frameID)
            BEGIN SELECT RAISE(ABORT,'Capture attempt identity cannot be rebound'); END
            """
        ])
    }
}
