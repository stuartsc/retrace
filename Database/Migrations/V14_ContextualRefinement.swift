import Foundation
import SQLCipher
import Shared

/// V14 Migration: Add composite index for contextual refinement neighbor lookups
struct V14_ContextualRefinement: Migration {
    let version = 14

    func migrate(db: OpaquePointer) async throws {
        Log.info("Adding composite index for contextual refinement...", category: .database)

        try MigrationRunner.executeStatements(db: db, statements: [
            """
            CREATE INDEX IF NOT EXISTS idx_audio_captures_batch_pass_time
            ON audio_captures(batch_audio_path, transcription_pass, start_time);
            """
        ])

        Log.info("V14 migration completed: contextual refinement index ready", category: .database)
    }
}
