import Foundation
import SQLCipher

/// Protocol abstracting SQLite/SQLCipher database operations
/// Allows UnifiedDatabaseAdapter to work with both encrypted and unencrypted databases
public protocol DatabaseConnection: Sendable {
    /// Get the underlying database pointer
    func getConnection() -> OpaquePointer?

    /// Prepare a SQL statement
    func prepare(sql: String) throws -> OpaquePointer?

    /// Execute a SQL statement without results (returns number of changes)
    @discardableResult
    func execute(sql: String) throws -> Int

    /// Begin a transaction
    func beginTransaction() throws

    /// Commit the current transaction
    func commit() throws

    /// Rollback the current transaction
    func rollback() throws

    /// Finalize a statement
    func finalize(_ statement: OpaquePointer?)
}

// MARK: - Database Errors

public enum DatabaseConnectionError: Error, CustomStringConvertible {
    case openingFailed(error: String)
    case statementPreparationFailed(sql: String, error: String)
    case executionFailed(sql: String, error: String)
    case transactionFailed(error: String)
    case notConnected

    public var description: String {
        switch self {
        case .openingFailed(let error):
            return "Failed to open read-only database: \(error)"
        case .statementPreparationFailed(let sql, let error):
            return "Failed to prepare statement '\(sql)': \(error)"
        case .executionFailed(let sql, let error):
            return "Failed to execute '\(sql)': \(error)"
        case .transactionFailed(let error):
            return "Transaction failed: \(error)"
        case .notConnected:
            return "Database not connected"
        }
    }
}

// MARK: - SQLite Connection (Unencrypted)

/// Wrapper for standard SQLite connection (used by RetraceDataSource)
public final class SQLiteConnection: DatabaseConnection, @unchecked Sendable {
    private let db: OpaquePointer?
    private let ownsConnection: Bool

    public init(db: OpaquePointer?) {
        self.db = db
        self.ownsConnection = false
    }

    /// A separate reader observes committed state even while another actor owns a
    /// write transaction. The pointer initializer remains an explicitly borrowed seam.
    public init(readOnlyDatabasePath: String) throws {
        guard !readOnlyDatabasePath.isEmpty, !readOnlyDatabasePath.contains("\0") else {
            throw DatabaseConnectionError.openingFailed(error: "Invalid database path")
        }
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(readOnlyDatabasePath, &opened,
            SQLITE_OPEN_URI | SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Database unavailable"
            if let opened { sqlite3_close_v2(opened) }
            throw DatabaseConnectionError.openingFailed(error: message)
        }
        guard sqlite3_db_readonly(opened, "main") == 1,
              sqlite3_busy_timeout(opened, 1_000) == SQLITE_OK else {
            sqlite3_close_v2(opened)
            throw DatabaseConnectionError.openingFailed(error: "Read-only connection setup failed")
        }
        self.db = opened
        self.ownsConnection = true
    }

    deinit {
        if ownsConnection, let db { sqlite3_close_v2(db) }
    }

    public func getConnection() -> OpaquePointer? {
        return db
    }

    public func prepare(sql: String) throws -> OpaquePointer? {
        guard let db = db else {
            throw DatabaseConnectionError.notConnected
        }

        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)

        guard result == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseConnectionError.statementPreparationFailed(sql: sql, error: error)
        }

        return statement
    }

    @discardableResult
    public func execute(sql: String) throws -> Int {
        guard let db = db else {
            throw DatabaseConnectionError.notConnected
        }

        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseConnectionError.executionFailed(sql: sql, error: error)
        }

        return Int(sqlite3_changes(db))
    }

    public func beginTransaction() throws {
        try execute(sql: "BEGIN TRANSACTION")
    }

    public func commit() throws {
        try execute(sql: "COMMIT")
    }

    public func rollback() throws {
        try execute(sql: "ROLLBACK")
    }

    public func finalize(_ statement: OpaquePointer?) {
        if let statement = statement {
            sqlite3_finalize(statement)
        }
    }
}

// MARK: - SQLCipher Connection (Encrypted)

/// Wrapper for SQLCipher connection (used by RewindDataSource)
public final class SQLCipherConnection: DatabaseConnection, @unchecked Sendable {
    private let db: OpaquePointer?

    public init(db: OpaquePointer?) {
        self.db = db
    }

    public func getConnection() -> OpaquePointer? {
        return db
    }

    public func prepare(sql: String) throws -> OpaquePointer? {
        guard let db = db else {
            throw DatabaseConnectionError.notConnected
        }

        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)

        guard result == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseConnectionError.statementPreparationFailed(sql: sql, error: error)
        }

        return statement
    }

    @discardableResult
    public func execute(sql: String) throws -> Int {
        guard let db = db else {
            throw DatabaseConnectionError.notConnected
        }

        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseConnectionError.executionFailed(sql: sql, error: error)
        }

        return Int(sqlite3_changes(db))
    }

    public func beginTransaction() throws {
        try execute(sql: "BEGIN TRANSACTION")
    }

    public func commit() throws {
        try execute(sql: "COMMIT")
    }

    public func rollback() throws {
        try execute(sql: "ROLLBACK")
    }

    public func finalize(_ statement: OpaquePointer?) {
        if let statement = statement {
            sqlite3_finalize(statement)
        }
    }
}
