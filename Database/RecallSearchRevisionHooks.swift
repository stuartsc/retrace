import SQLCipher
import Shared

/// FTS5 shadow-table triggers must stay connection-local: defensive SQLite readers
/// reject schemas containing persisted triggers on shadow tables. Both supported
/// native writer entry points install these hooks before accepting work.
enum RecallSearchRevisionHooks {
    static func install(db: OpaquePointer) throws {
        guard try tableExists("recall_search_revision", db: db) else {
            // The legacy standalone FTS initializer can open a pre-V21 or empty
            // store. A current store missing its fence must fail initialization.
            if try tableExists("schema_migrations", db: db),
               try scalar("SELECT COALESCE(MAX(version),0) FROM main.schema_migrations", db: db) >= 21 {
                throw DatabaseError.connectionFailed(underlying: "Native search revision table is missing")
            }
            return
        }

        var statements = [String]()
        for operation in ["INSERT", "DELETE"] {
            statements.append("""
                CREATE TEMP TRIGGER IF NOT EXISTS recall_search_fts_content_\(operation)
                AFTER \(operation) ON main.searchRanking_content BEGIN
                  UPDATE recall_search_revision SET revision=revision+1 WHERE id=1;
                END
                """)
        }
        statements.append("""
            CREATE TEMP TRIGGER IF NOT EXISTS recall_search_fts_content_UPDATE
            AFTER UPDATE OF id,c0,c1,c2 ON main.searchRanking_content
            WHEN OLD.id IS NOT NEW.id OR OLD.c0 IS NOT NEW.c0
              OR OLD.c1 IS NOT NEW.c1 OR OLD.c2 IS NOT NEW.c2 BEGIN
              UPDATE recall_search_revision SET revision=revision+1 WHERE id=1;
            END
            """)
        try MigrationRunner.executeStatements(db: db, statements: statements)
    }

    private static func tableExists(_ name: String, db: OpaquePointer) throws -> Bool {
        // Names are private constants, never user input.
        try scalar("SELECT COUNT(*) FROM main.sqlite_schema WHERE type='table' AND name='\(name)'", db: db) == 1
    }

    private static func scalar(_ sql: String, db: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.connectionFailed(underlying: "Native search revision setup could not read its schema")
        }
        return sqlite3_column_int64(statement, 0)
    }
}
