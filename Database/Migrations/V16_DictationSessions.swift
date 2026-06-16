import Foundation
import SQLCipher
import Shared

/// V16 Migration: Persist push-to-dictate sessions for dashboard history.
struct V16_DictationSessions: Migration {
    let version = 16

    func migrate(db: OpaquePointer) async throws {
        Log.info("Creating dictation_sessions table...", category: .database)

        try MigrationRunner.executeStatements(db: db, statements: [
            """
            CREATE TABLE IF NOT EXISTS dictation_sessions (
                id TEXT PRIMARY KEY,
                started_at INTEGER NOT NULL,
                ended_at INTEGER,
                inserted_at INTEGER,
                text TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL,
                target_bundle_id TEXT,
                target_app_name TEXT,
                target_window_title TEXT,
                insertion_method TEXT NOT NULL,
                error_message TEXT,
                created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),
                updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000)
            );
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_dictation_sessions_started_at
            ON dictation_sessions(started_at DESC);
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_dictation_sessions_status
            ON dictation_sessions(status, started_at DESC);
            """
        ])

        Log.info("V16 migration completed: dictation session history ready", category: .database)
    }
}
