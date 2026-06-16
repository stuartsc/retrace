import Foundation
import SQLCipher
import Shared

/// V15 Migration: Add pipeline_version column to track which transcription logic
/// produced each record. When logic changes, bump CURRENT_PIPELINE_VERSION and
/// older records will be auto-reset to pass=1 on startup for reprocessing.
struct V15_PipelineVersion: Migration {
    let version = 15

    func migrate(db: OpaquePointer) async throws {
        Log.info("Adding pipeline_version column for version-aware reprocessing...", category: .database)

        try MigrationRunner.executeStatements(db: db, statements: [
            """
            ALTER TABLE audio_captures ADD COLUMN pipeline_version INTEGER NOT NULL DEFAULT 1;
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_audio_captures_pipeline_version
            ON audio_captures(pipeline_version, transcription_pass);
            """
        ])

        Log.info("V15 migration completed: pipeline_version tracking ready", category: .database)
    }
}
