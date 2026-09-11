import SQLCipher

/// Constant-size migration: resume maintenance by node primary key, without
/// indexing or scanning historical OCR text during startup.
struct V20_OCRBackfillState: Migration {
    let version = 20

    func migrate(db: OpaquePointer) async throws {
        try MigrationRunner.executeStatements(db: db, statements: [
            "CREATE TABLE IF NOT EXISTS ocr_backfill_state (id INTEGER PRIMARY KEY CHECK(id=1), nodeCursor INTEGER NOT NULL DEFAULT 0, nodeUpperBound INTEGER);",
            "INSERT OR IGNORE INTO ocr_backfill_state(id,nodeCursor) VALUES(1,0);"
        ])
    }
}
