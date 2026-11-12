import DatabaseNativeSupport
import Foundation
import SQLCipher
import Shared

/// Connection-owned, process-local revocation. Callbacks only move in-memory
/// fences; they must not query SQL, enter actors or acquire another connection.
/// Failed/rolled-back writes intentionally keep conservative read revocations.
final class NativeSourceMutationHooks: @unchecked Sendable {
    typealias Handler = @Sendable (NativeSourceMutation) -> Void
    private let db: OpaquePointer
    private let handler: Handler
    private var installed = false
    private var transactionDirty = false
    private var statementChanged = false
    private var transactionMutation = NativeSourceMutation.indexOnly
    private var columns: [String: [String: Int32]] = [:]

    private static let indexTables: Set<String> = ["doc_segment", "searchranking_content"]
    private static let sourceTables: Set<String> = [
        "frame", "segment", "screen_observation", "screen_extraction", "screen_deleted",
        "evidence_store", "audio_captures", "segment_comment", "segment_comment_link",
        "segment_tag", "tag", "doc_segment", "searchranking_content", "frame_media_unavailable"
    ]

    init(db: OpaquePointer, onMutation: @escaping Handler) { self.db = db; handler = onMutation }
    convenience init(db: OpaquePointer, handler: @escaping @Sendable () -> Void) {
        self.init(db: db, onMutation: { _ in handler() })
    }
    deinit { if installed { detach() } }

    func install() throws {
        guard let mutex = sqlite3_db_mutex(db) else {
            throw DatabaseError.connectionFailed(underlying: "Native mutation observer needs a serialized writer")
        }
        sqlite3_mutex_enter(mutex)
        defer { sqlite3_mutex_leave(mutex) }
        guard !installed else { return }
        // Read layout once while installing, never from a mutation callback.
        for table in Self.sourceTables {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA main.table_info('\(table)')", -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.connectionFailed(underlying: "Native source layout unavailable")
            }
            var names: [String: Int32] = [:]
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 1) {
                    names[String(cString: name).lowercased()] = sqlite3_column_int(statement, 0)
                }
                step = sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            guard step == SQLITE_DONE else {
                throw DatabaseError.connectionFailed(underlying: "Native source layout unavailable")
            }
            columns[table] = names
        }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard sqlite3_set_authorizer(db, { context, action, table, _, schema, _ in
            guard let context, NativeSourceMutationHooks.isSource(table: table, schema: schema) else { return SQLITE_OK }
            if action == SQLITE_DROP_TABLE {
                Unmanaged<NativeSourceMutationHooks>.fromOpaque(context).takeUnretainedValue().changed(.all)
            }
            // Expire prepared DELETE truncate optimizations as well as new ones.
            return action == SQLITE_DELETE ? SQLITE_IGNORE : SQLITE_OK
        }, pointer) == SQLITE_OK else {
            throw DatabaseError.connectionFailed(underlying: "Native mutation authorizer could not be installed")
        }
        guard retrace_native_preupdate_install(db, { context, _, operation, schema, table, oldID, newID in
            guard let context, let table, NativeSourceMutationHooks.isSource(table: table, schema: schema) else { return }
            let owner = Unmanaged<NativeSourceMutationHooks>.fromOpaque(context).takeUnretainedValue()
            owner.changed(owner.mutation(table: String(cString: table).lowercased(), operation: operation, oldID: oldID, newID: newID))
        }, pointer) == SQLITE_OK else {
            sqlite3_set_authorizer(db, nil, nil)
            throw DatabaseError.connectionFailed(underlying: "Native preupdate observation unavailable")
        }
        // FTS shadow writes may use a virtual-table path without preupdate hooks.
        // They affect current search membership, not retained immutable snapshots.
        sqlite3_update_hook(db, { context, _, schema, table, _ in
            guard let context, let table, NativeSourceMutationHooks.isSource(table: table, schema: schema),
                  NativeSourceMutationHooks.indexTables.contains(String(cString: table).lowercased()) else { return }
            Unmanaged<NativeSourceMutationHooks>.fromOpaque(context).takeUnretainedValue().changed(.indexOnly)
        }, pointer)
        let result = sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_PROFILE), { _, context, _, _ in
            guard let context else { return 0 }
            Unmanaged<NativeSourceMutationHooks>.fromOpaque(context).takeUnretainedValue().statementFinished()
            return 0
        }, pointer)
        guard result == SQLITE_OK else {
            retrace_native_preupdate_remove(db); sqlite3_update_hook(db, nil, nil); sqlite3_set_authorizer(db, nil, nil)
            throw DatabaseError.connectionFailed(underlying: "Native mutation completion observer could not be installed")
        }
        installed = true
    }

    func detach() {
        guard installed, let mutex = sqlite3_db_mutex(db) else { return }
        sqlite3_mutex_enter(mutex)
        defer { sqlite3_mutex_leave(mutex) }
        guard installed else { return }
        retrace_native_preupdate_remove(db)
        sqlite3_update_hook(db, nil, nil); sqlite3_trace_v2(db, 0, nil, nil); sqlite3_set_authorizer(db, nil, nil)
        installed = false; transactionDirty = false; statementChanged = false; transactionMutation = .indexOnly
    }

    private static func isSource(table: UnsafePointer<CChar>?, schema: UnsafePointer<CChar>?) -> Bool {
        guard let table, let schema, String(cString: schema) == "main" else { return false }
        return sourceTables.contains(String(cString: table).lowercased())
    }

    private func mutation(table: String, operation: Int32, oldID: Int64, newID: Int64) -> NativeSourceMutation {
        if Self.indexTables.contains(table) { return .indexOnly }
        // Privacy, identity and deletion use a strong fallback. Preupdate includes
        // displaced REPLACE deletes, which SQLite's update_hook omits.
        if operation == SQLITE_DELETE || ["tag", "segment_tag", "screen_deleted", "evidence_store"].contains(table) { return .all }
        guard operation == SQLITE_INSERT || operation == SQLITE_UPDATE,
              let layout = columns[table], layout.count == Int(retrace_native_preupdate_count(db)), !layout.isEmpty else { return .all }
        // Capture extends the active segment on every new frame. endDate is not
        // part of frame metadata, note anchor identity or retained screen text.
        if table == "segment", operation == SQLITE_UPDATE, oldID == newID,
           layout["enddate"] != nil, unchanged(table, except: ["enddate"]) { return .indexOnly }
        var targets = Set<NativeSourceTarget>()
        let sides = operation == SQLITE_UPDATE ? [false, true] : [true]
        for new in sides {
            let rowID = new ? newID : oldID
            switch table {
            case "frame":
                guard layout["id"] != nil, rowID > 0 else { return .all }
                targets.insert(.frame(rowID))
            case "segment":
                guard layout["id"] != nil, rowID > 0 else { return .all }
                targets.insert(.segment(rowID))
            case "audio_captures":
                guard layout["id"] != nil, rowID > 0,
                      let batch = value(table, "batch_audio_path", new: new), let audio = value(table, "audio_path", new: new) else { return .all }
                targets.insert(.audioRow(rowID))
                for field in [batch, audio] where sqlite3_value_type(field) != SQLITE_NULL {
                    guard let path = boundedText(field) else { return .all }
                    targets.insert(.audioBatch(path))
                }
            case "screen_observation", "screen_extraction":
                guard let field = value(table, "observationid", new: new), let text = boundedText(field), let id = UUID(uuidString: text) else { return .all }
                targets.insert(.observation(id))
                if table == "screen_observation" {
                    guard let frame = value(table, "frameid", new: new), sqlite3_value_type(frame) == SQLITE_INTEGER,
                          sqlite3_value_int64(frame) > 0 else { return .all }
                    targets.insert(.frame(sqlite3_value_int64(frame)))
                }
            case "segment_comment":
                guard layout["id"] != nil, rowID > 0 else { return .all }
                targets.insert(.comment(rowID))
            case "segment_comment_link":
                guard let field = value(table, "commentid", new: new), sqlite3_value_type(field) == SQLITE_INTEGER,
                      sqlite3_value_int64(field) > 0 else { return .all }
                targets.insert(.comment(sqlite3_value_int64(field)))
            case "frame_media_unavailable":
                guard let field = value(table, "frameid", new: new), sqlite3_value_type(field) == SQLITE_INTEGER,
                      sqlite3_value_int64(field) > 0 else { return .all }
                targets.insert(.frame(sqlite3_value_int64(field)))
            default: return .all
            }
        }
        return .init(.init(targets: targets))
    }

    private func value(_ table: String, _ column: String, new: Bool) -> OpaquePointer? {
        guard let index = columns[table]?[column], index >= 0, index < retrace_native_preupdate_count(db) else { return nil }
        var value: OpaquePointer?
        let result = new ? retrace_native_preupdate_new(db, index, &value) : retrace_native_preupdate_old(db, index, &value)
        return result == SQLITE_OK ? value : nil
    }
    private func boundedText(_ value: OpaquePointer) -> String? {
        guard sqlite3_value_type(value) == SQLITE_TEXT, sqlite3_value_bytes(value) <= 1024,
              let text = sqlite3_value_text(value) else { return nil }
        let bytes = UnsafeBufferPointer(start: text, count: Int(sqlite3_value_bytes(value)))
        guard !bytes.contains(0) else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }
    private func unchanged(_ table: String, except ignored: Set<String>) -> Bool {
        guard let layout = columns[table] else { return false }
        for column in layout.keys where !ignored.contains(column) {
            guard let old = value(table, column, new: false), let new = value(table, column, new: true),
                  sqlite3_value_type(old) == sqlite3_value_type(new) else { return false }
            switch sqlite3_value_type(old) {
            case SQLITE_NULL: break
            case SQLITE_INTEGER: if sqlite3_value_int64(old) != sqlite3_value_int64(new) { return false }
            case SQLITE_FLOAT: if sqlite3_value_double(old) != sqlite3_value_double(new) { return false }
            case SQLITE_TEXT:
                guard let a = boundedText(old), let b = boundedText(new), a == b else { return false }
            default: return false
            }
        }
        return true
    }
    private func changed(_ mutation: NativeSourceMutation) {
        transactionDirty = true
        let previous = transactionMutation
        transactionMutation = transactionMutation.merging(mutation)
        let notify = !statementChanged || transactionMutation != previous
        statementChanged = true
        if notify { handler(transactionMutation) }
    }
    private func statementFinished() {
        guard transactionDirty else { return }
        handler(transactionMutation)
        statementChanged = false
        if sqlite3_get_autocommit(db) != 0, sqlite3_txn_state(db, "main") != SQLITE_TXN_WRITE {
            transactionDirty = false; transactionMutation = .indexOnly
        }
    }
}
