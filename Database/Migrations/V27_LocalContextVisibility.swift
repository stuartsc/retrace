import Foundation
import SQLCipher

/// Visibility lookups stay bounded by a selected event/document, not all prior
/// corrections. No derived context or captured content is added by this migration.
struct V27_LocalContextVisibility: Migration {
    let version = 27
    func migrate(db: OpaquePointer) async throws {
        try MigrationRunner.executeStatements(db: db, statements: [
            """
            CREATE INDEX activity_correction_hide_document
            ON activity_correction(json_extract(payload,'$.documentKey'),commandID)
            WHERE status='applied' AND json_extract(payload,'$.confirmed')=1
              AND json_extract(payload,'$.action')='hide' AND json_extract(payload,'$.scope')='document'
            """,
            """
            CREATE INDEX activity_correction_revoke_target
            ON activity_correction(CAST(json_extract(payload,'$.revokesCommandID') AS TEXT))
            WHERE status IN ('pending','applied') AND json_extract(payload,'$.confirmed')=1
              AND json_extract(payload,'$.action')='revoke'
            """
        ])
    }
}
