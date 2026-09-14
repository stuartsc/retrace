import Foundation
import SQLCipher

/// Additive and constant-size: existing libraries are materialized one requested frame at a time.
struct V21_ProgressiveRecall: Migration {
    let version = 21

    func migrate(db: OpaquePointer) async throws {
        try MigrationRunner.executeStatements(db: db, statements: [
            "CREATE TABLE recall_search_revision (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL DEFAULT 0)",
            "INSERT INTO recall_search_revision(id) VALUES(1)",
            "CREATE TABLE evidence_store (storeID TEXT PRIMARY KEY, source TEXT NOT NULL, identity TEXT NOT NULL, UNIQUE(source,identity))",
            "INSERT INTO evidence_store(storeID,source,identity) VALUES('\(UUID().uuidString)','native','native')",
            "CREATE TABLE activity_state (id INTEGER PRIMARY KEY CHECK(id=1), correctionRevision INTEGER NOT NULL DEFAULT 0, gapCount INTEGER NOT NULL DEFAULT 0)",
            "INSERT INTO activity_state(id) VALUES(1)",
            "CREATE TABLE activity_session (sessionID TEXT PRIMARY KEY, lastSequence INTEGER NOT NULL, lastMonotonic REAL NOT NULL, closed INTEGER NOT NULL DEFAULT 0)",
            "CREATE TABLE activity_feed (sequence INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, entityID TEXT NOT NULL, payload TEXT NOT NULL)",
            "CREATE INDEX activity_feed_entity ON activity_feed(entityID)",
            """
            CREATE TABLE activity_event (
              eventID TEXT PRIMARY KEY, sessionID TEXT NOT NULL, sessionSequence INTEGER NOT NULL,
              commitSequence INTEGER NOT NULL UNIQUE REFERENCES activity_feed(sequence),
              observedAt REAL NOT NULL, monotonicTime REAL NOT NULL, persistedAt REAL NOT NULL, appBundleID TEXT NOT NULL,
              metadataSearch TEXT NOT NULL, payload TEXT NOT NULL, UNIQUE(sessionID,sessionSequence))
            """,
            "CREATE INDEX activity_event_app_page ON activity_event(appBundleID,commitSequence)",
            "CREATE INDEX activity_event_time ON activity_event(observedAt,commitSequence)",
            "CREATE INDEX activity_event_session_clock ON activity_event(sessionID,monotonicTime,sessionSequence)",
            "CREATE TABLE activity_checkpoint (consumer TEXT PRIMARY KEY, sequence INTEGER NOT NULL CHECK(sequence>=0))",
            "CREATE TABLE activity_deleted (eventID TEXT PRIMARY KEY)",
            "CREATE TABLE activity_correction (commandID TEXT PRIMARY KEY, revision INTEGER NOT NULL, status TEXT NOT NULL, payload TEXT NOT NULL)",
            "CREATE INDEX activity_correction_revision ON activity_correction(revision,commandID)",
            "CREATE TABLE activity_correction_target (commandID TEXT NOT NULL REFERENCES activity_correction(commandID) ON DELETE CASCADE, eventID TEXT NOT NULL, PRIMARY KEY(commandID,eventID))",
            "CREATE INDEX activity_correction_target_event ON activity_correction_target(eventID,commandID)",
            """
            CREATE TABLE screen_observation (
              observationID TEXT PRIMARY KEY, storeID TEXT NOT NULL REFERENCES evidence_store(storeID), source TEXT NOT NULL,
              frameID INTEGER NOT NULL, nativeFrameID INTEGER REFERENCES frame(id) ON DELETE CASCADE,
              framePayload TEXT NOT NULL, width INTEGER NOT NULL DEFAULT 0, height INTEGER NOT NULL DEFAULT 0,
              legacy INTEGER NOT NULL, preferredRevision INTEGER NOT NULL DEFAULT 0, UNIQUE(storeID,frameID))
            """,
            "CREATE INDEX screen_observation_native_frame ON screen_observation(nativeFrameID)",
            "CREATE TABLE screen_extraction (observationID TEXT NOT NULL REFERENCES screen_observation(observationID) ON DELETE CASCADE, revision INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(observationID,revision))",
            "CREATE TABLE screen_deleted (storeID TEXT NOT NULL, observationID TEXT NOT NULL, frameID INTEGER NOT NULL, PRIMARY KEY(storeID,observationID))",
            "CREATE INDEX screen_deleted_frame ON screen_deleted(storeID,frameID)",
            "CREATE TABLE frame_media_unavailable (frameID INTEGER PRIMARY KEY REFERENCES frame(id) ON DELETE CASCADE, reason TEXT NOT NULL, observedAt REAL NOT NULL)",
            """
            CREATE TABLE activity_screen_link (
              linkID TEXT PRIMARY KEY, commitSequence INTEGER NOT NULL UNIQUE REFERENCES activity_feed(sequence),
              eventID TEXT NOT NULL REFERENCES activity_event(eventID) ON DELETE CASCADE,
              sessionID TEXT NOT NULL, activitySequence INTEGER NOT NULL, captureMonotonicTime REAL NOT NULL,
              observationID TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL,
              FOREIGN KEY(observationID,revision) REFERENCES screen_extraction(observationID,revision) ON DELETE CASCADE,
              UNIQUE(eventID,observationID,revision))
            """,
            "CREATE INDEX activity_screen_link_event_page ON activity_screen_link(eventID,commitSequence)",
            "CREATE INDEX activity_screen_link_extraction ON activity_screen_link(observationID,revision)",
            "CREATE INDEX activity_screen_link_session_clock ON activity_screen_link(sessionID,captureMonotonicTime,activitySequence)",
            """
            CREATE TRIGGER activity_screen_link_delete BEFORE DELETE ON activity_screen_link BEGIN
              UPDATE activity_feed SET kind='redacted',payload='{}' WHERE entityID=OLD.linkID;
              INSERT INTO activity_feed(kind,entityID,payload) VALUES('activity_screen_link_deleted',OLD.linkID,'{}');
            END
            """,
            """
            CREATE TRIGGER screen_evidence_frame_delete BEFORE DELETE ON frame BEGIN
              INSERT OR IGNORE INTO screen_deleted(storeID,observationID,frameID)
                SELECT storeID,observationID,frameID FROM screen_observation WHERE nativeFrameID=OLD.id;
              DELETE FROM screen_extraction WHERE observationID IN
                (SELECT observationID FROM screen_observation WHERE nativeFrameID=OLD.id);
              DELETE FROM screen_observation WHERE nativeFrameID=OLD.id;
              DELETE FROM frame_media_unavailable WHERE frameID=OLD.id;
            END
            """
        ])
        try installSearchRevisionTriggers(db: db)
    }

    private func installSearchRevisionTriggers(db: OpaquePointer) throws {
        // FTS shadow-table hooks are TEMP triggers installed on each supported
        // writer by RecallSearchRevisionHooks. Persisting them makes otherwise
        // read-only defensive SQLite connections reject the database schema.
        let tables: [(String, [String])] = [
            ("doc_segment", ["docid", "segmentId", "frameId"]),
            ("frame", ["id", "createdAt", "imageFileName", "segmentId", "videoId", "videoFrameIndex", "encodingStatus", "redactionReason"]),
            ("segment", ["id", "bundleID", "windowName", "browserUrl"]),
            ("tag", ["id", "name"]),
            ("segment_tag", ["segmentId", "tagId"]),
            ("segment_comment_link", ["commentId", "segmentId"])
        ]
        var statements: [String] = []
        for (table, columns) in tables {
            for operation in ["INSERT", "DELETE"] {
                statements.append("CREATE TRIGGER recall_search_\(table)_\(operation) AFTER \(operation) ON \(table) BEGIN UPDATE recall_search_revision SET revision=revision+1 WHERE id=1; END")
            }
            let changed = columns.map { "OLD.\($0) IS NOT NEW.\($0)" }.joined(separator: " OR ")
            statements.append("CREATE TRIGGER recall_search_\(table)_UPDATE AFTER UPDATE OF \(columns.joined(separator: ",")) ON \(table) WHEN \(changed) BEGIN UPDATE recall_search_revision SET revision=revision+1 WHERE id=1; END")
        }
        // Materializing a retained thumbnail appends an immutable extraction and
        // can establish its dimensions, but does not change the indexed corpus.
        // Capture and every native text writer already mutate frame/FTS in the
        // same transaction. Imported registry copies never change native search.
        // Keep identity/deletion fences for native evidence without treating a
        // new observation or preferred extraction as an independent index write.
        let identities: [(String, [String])] = [
            ("screen_observation", ["storeID", "observationID", "frameID", "nativeFrameID", "source"]),
            ("evidence_store", ["storeID", "source", "identity"])
        ]
        for (table, columns) in identities {
            let changed = columns.map { "OLD.\($0) IS NOT NEW.\($0)" }.joined(separator: " OR ")
            statements.append("CREATE TRIGGER recall_search_\(table)_DELETE AFTER DELETE ON \(table) WHEN OLD.source='native' BEGIN UPDATE recall_search_revision SET revision=revision+1 WHERE id=1; END")
            statements.append("CREATE TRIGGER recall_search_\(table)_UPDATE AFTER UPDATE OF \(columns.joined(separator: ",")) ON \(table) WHEN (OLD.source='native' OR NEW.source='native') AND (\(changed)) BEGIN UPDATE recall_search_revision SET revision=revision+1 WHERE id=1; END")
        }
        statements.append("CREATE TRIGGER recall_search_evidence_store_INSERT AFTER INSERT ON evidence_store WHEN NEW.source='native' BEGIN UPDATE recall_search_revision SET revision=revision+1 WHERE id=1; END")
        try MigrationRunner.executeStatements(db: db, statements: statements)
    }
}
