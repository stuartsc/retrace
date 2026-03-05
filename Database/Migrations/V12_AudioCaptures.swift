import Foundation
import SQLCipher
import Shared

/// V12 Migration: Create audio_captures table and FTS5 index for audio transcriptions
struct V12_AudioCaptures: Migration {
    let version = 12

    func migrate(db: OpaquePointer) async throws {
        Log.info("Creating audio_captures table and FTS5 index...", category: .database)

        try MigrationRunner.executeStatements(db: db, statements: [
            // Main audio captures table
            """
            CREATE TABLE IF NOT EXISTS audio_captures (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT,
                text TEXT NOT NULL,
                start_time INTEGER NOT NULL,
                end_time INTEGER NOT NULL,
                source TEXT NOT NULL,
                confidence REAL,
                audio_path TEXT,
                audio_size INTEGER,
                created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000)
            );
            """,

            // Index for time-range queries
            """
            CREATE INDEX IF NOT EXISTS idx_audio_captures_time
            ON audio_captures(start_time, end_time);
            """,

            // Index for source filtering
            """
            CREATE INDEX IF NOT EXISTS idx_audio_captures_source
            ON audio_captures(source);
            """,

            // FTS5 virtual table for full-text search
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS audio_captures_fts
            USING fts5(text, content='audio_captures', content_rowid='id', tokenize='unicode61');
            """,

            // Auto-sync triggers: keep FTS index in sync with audio_captures table
            """
            CREATE TRIGGER IF NOT EXISTS audio_captures_ai AFTER INSERT ON audio_captures BEGIN
                INSERT INTO audio_captures_fts(rowid, text) VALUES (new.id, new.text);
            END;
            """,

            """
            CREATE TRIGGER IF NOT EXISTS audio_captures_ad AFTER DELETE ON audio_captures BEGIN
                INSERT INTO audio_captures_fts(audio_captures_fts, rowid, text) VALUES('delete', old.id, old.text);
            END;
            """,

            """
            CREATE TRIGGER IF NOT EXISTS audio_captures_au AFTER UPDATE ON audio_captures BEGIN
                INSERT INTO audio_captures_fts(audio_captures_fts, rowid, text) VALUES('delete', old.id, old.text);
                INSERT INTO audio_captures_fts(rowid, text) VALUES (new.id, new.text);
            END;
            """
        ])

        Log.info("V12 migration completed: audio_captures table and FTS5 index ready", category: .database)
    }
}
