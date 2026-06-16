import Foundation
import SQLCipher
import Shared

/// V13 Migration: Add transcription pass tracking for two-pass whisper refinement
struct V13_TranscriptionPass: Migration {
    let version = 13

    func migrate(db: OpaquePointer) async throws {
        Log.info("Adding transcription_pass and batch_audio_path columns...", category: .database)

        try MigrationRunner.executeStatements(db: db, statements: [
            // Track which transcription pass produced this record (1=fast/greedy, 2=accurate/beam)
            """
            ALTER TABLE audio_captures ADD COLUMN transcription_pass INTEGER NOT NULL DEFAULT 1;
            """,

            // Store the originating batch M4A path on sentence records for refinement lookups
            """
            ALTER TABLE audio_captures ADD COLUMN batch_audio_path TEXT;
            """,

            // Index for efficient refinement queries
            """
            CREATE INDEX IF NOT EXISTS idx_audio_captures_pass
            ON audio_captures(transcription_pass);
            """
        ])

        Log.info("V13 migration completed: transcription pass tracking ready", category: .database)
    }
}
