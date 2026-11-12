import CryptoKit
import Darwin
import Foundation
import Shared
import SQLCipher

/// Private command receipts, never the recording database. A reserved command is never replayed
/// after a crash: cross-store effects cannot honestly be claimed atomic with this receipt.
final class RetraceCommandLedger {
    enum Failure: Error { case unsafePath, database, conflict, capacity, invalidPreview }
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700, info.st_uid == getuid() else { throw Failure.unsafePath }
        let path = directory.appendingPathComponent("commands.db").path
        var descriptor = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if descriptor < 0 && errno == EEXIST { descriptor = open(path, O_RDWR | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw Failure.unsafePath }
        defer { Darwin.close(descriptor) }
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_uid == getuid(), info.st_nlink == 1 else { throw Failure.unsafePath }
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw Failure.database }
        do {
            sqlite3_busy_timeout(database, 250)
            let appID = try scalar("PRAGMA application_id")
            let tables = try scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table'")
            guard appID == 0x5254434d || (appID == 0 && tables == 0) else { throw Failure.database }
            try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA application_id=1381253965")
            try exec("CREATE TABLE IF NOT EXISTS command_receipt(client TEXT NOT NULL, request TEXT NOT NULL, digest TEXT NOT NULL, response BLOB, PRIMARY KEY(client,request)); CREATE TABLE IF NOT EXISTS command_preview(id TEXT PRIMARY KEY, client TEXT NOT NULL, digest TEXT NOT NULL, revision TEXT NOT NULL, expires REAL NOT NULL, consumed INTEGER NOT NULL DEFAULT 0); CREATE TABLE IF NOT EXISTS command_job(id TEXT PRIMARY KEY, client TEXT NOT NULL, payload BLOB NOT NULL)")
        } catch { close(); throw error }
    }
    deinit { close() }
    func close() { if let database { sqlite3_close_v2(database); self.database = nil } }
    func lookup(client: String, request: UUID, digest: String) throws -> RetraceCommandResponse?? {
        let statement = try prepare("SELECT digest,response FROM command_receipt WHERE client=? AND request=?")
        defer { sqlite3_finalize(statement) }
        try bind(client, to: statement, at: 1); try bind(request.uuidString, to: statement, at: 2)
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw Failure.database }
        guard string(statement, 0) == digest else { throw Failure.conflict }
        if sqlite3_column_type(statement, 1) == SQLITE_NULL { return .some(nil) }
        guard let bytes = sqlite3_column_blob(statement, 1) else { throw Failure.database }
        return .some(try RetraceWire.decoder().decode(RetraceCommandResponse.self,
            from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))))
    }
    func reserve(client: String, request: UUID, digest: String, proof: RetracePreviewConfirmation?,
                 payloadDigest: String, revision: String?, now: Date) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            guard try scalar("SELECT COUNT(*) FROM command_receipt") < 100_000 else { throw Failure.capacity }
            if let proof {
                let statement = try prepare("UPDATE command_preview SET consumed=1 WHERE id=? AND client=? AND digest=? AND revision=? AND expires>? AND consumed=0")
                defer { sqlite3_finalize(statement) }
                try bind(proof.previewID.uuidString, to: statement, at: 1); try bind(client, to: statement, at: 2)
                try bind(payloadDigest, to: statement, at: 3); try bind(revision ?? "", to: statement, at: 4)
                sqlite3_bind_double(statement, 5, now.timeIntervalSince1970)
                guard proof.digest == payloadDigest, sqlite3_step(statement) == SQLITE_DONE,
                      sqlite3_changes(database) == 1 else { throw Failure.invalidPreview }
            }
            let statement = try prepare("INSERT INTO command_receipt(client,request,digest) VALUES(?,?,?)")
            defer { sqlite3_finalize(statement) }
            try bind(client, to: statement, at: 1); try bind(request.uuidString, to: statement, at: 2); try bind(digest, to: statement, at: 3)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.conflict }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    func complete(client: String, request: UUID, response: RetraceCommandResponse) throws {
        let data = try RetraceWire.encoder().encode(response)
        guard data.count <= 1_048_576 else { throw Failure.capacity }
        let statement = try prepare("UPDATE command_receipt SET response=? WHERE client=? AND request=? AND response IS NULL")
        defer { sqlite3_finalize(statement) }
        let result = data.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(data.count), transient) }
        guard result == SQLITE_OK else { throw Failure.database }
        try bind(client, to: statement, at: 2); try bind(request.uuidString, to: statement, at: 3)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else { throw Failure.database }
    }
    func addPreview(_ preview: RetraceDestructivePreview, client: String) throws {
        // Expired or consumed previews are bounded metadata; receipts are never pruned automatically.
        let cleanup = try prepare("DELETE FROM command_preview WHERE expires<? OR consumed=1")
        sqlite3_bind_double(cleanup, 1, Date().timeIntervalSince1970)
        guard sqlite3_step(cleanup) == SQLITE_DONE else { sqlite3_finalize(cleanup); throw Failure.database }
        sqlite3_finalize(cleanup)
        guard try scalar("SELECT COUNT(*) FROM command_preview") < 1024 else { throw Failure.capacity }
        let statement = try prepare("INSERT INTO command_preview(id,client,digest,revision,expires) VALUES(?,?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        try bind(preview.id.uuidString, to: statement, at: 1); try bind(client, to: statement, at: 2)
        try bind(preview.digest, to: statement, at: 3); try bind(preview.revision, to: statement, at: 4)
        sqlite3_bind_double(statement, 5, preview.expiresAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.database }
    }
    func putJob(_ job: RetraceCommandJob, client: String, creating: Bool = false) throws {
        if creating { guard try scalar("SELECT COUNT(*) FROM command_job") < 1000 else { throw Failure.capacity } }
        let data = try RetraceWire.encoder().encode(job)
        let statement = try prepare(creating ? "INSERT INTO command_job(payload,id,client) VALUES(?,?,?)" : "UPDATE command_job SET payload=? WHERE id=? AND client=?")
        defer { sqlite3_finalize(statement) }
        guard data.withUnsafeBytes({ sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(data.count), transient) }) == SQLITE_OK else { throw Failure.database }
        try bind(job.id.uuidString, to: statement, at: 2); try bind(client, to: statement, at: 3)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else { throw Failure.database }
    }
    func job(_ id: UUID, client: String) throws -> RetraceCommandJob? {
        let statement = try prepare("SELECT payload FROM command_job WHERE id=? AND client=?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: statement, at: 1); try bind(client, to: statement, at: 2)
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw Failure.database }
        return try RetraceWire.decoder().decode(RetraceCommandJob.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }
    private func scalar(_ sql: String) throws -> Int {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Failure.database }
        return Int(sqlite3_column_int64(statement, 0))
    }
    private func exec(_ sql: String) throws {
        guard let database, sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.database }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard let database, sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Failure.database }
        return statement
    }
    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        guard value.withCString({ sqlite3_bind_text(statement, index, $0, -1, transient) }) == SQLITE_OK else { throw Failure.database }
    }
    private func string(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }
}
