import Foundation
import SQLCipher
import Shared

/// V18 Migration: Store raw OCR region text directly on nodes.
///
/// Older rows continue to work through textOffset/textLength fallback, but new
/// captures should not depend on offsets into Accessibility-enriched FTS text.
struct V18_NodeText: Migration {
    let version = 18

    func migrate(db: OpaquePointer) async throws {
        Log.info("Adding direct OCR node text storage...", category: .database)

        if try Self.columnExists(db: db, table: "node", column: "text") {
            Log.info("V18 migration skipped: node.text already exists", category: .database)
            return
        }

        try MigrationRunner.executeStatements(db: db, statements: [
            """
            ALTER TABLE node ADD COLUMN text TEXT;
            """
        ])

        Log.info("V18 migration completed: OCR node text column ready", category: .database)
    }

    private static func columnExists(db: OpaquePointer, table: String, column: String) throws -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let columnName = sqlite3_column_text(statement, 1).map({ String(cString: $0) }) else {
                continue
            }
            if columnName == column {
                return true
            }
        }

        return false
    }
}
