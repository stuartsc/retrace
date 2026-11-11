import Foundation
import SQLCipher

/// Bounded first-pass recovery seeks raw pending IDs without sorting the backlog.
struct V31_AudioPendingWorkIndex: Migration {
    let version = 31
    func migrate(db: OpaquePointer) async throws {
        try MigrationRunner.executeStatements(db: db, statements: [
            """
            CREATE INDEX audio_pending_raw_id ON audio_captures(id)
            WHERE batch_audio_path IS NULL AND audio_size>0
              AND transcript_status IN ('pending', 'needs_repair')
            """
        ])
    }
}
