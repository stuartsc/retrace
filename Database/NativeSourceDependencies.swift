import Foundation
import SQLCipher
import Shared

extension DatabaseManager {
    /// Bounded identity-only dependency lookup outside mutation callbacks. Callers
    /// must bracket it with their existing source/policy read fence.
    public func nativeSourceDependencies(frameIDs: Set<Int64>, audioRowIDs: Set<Int64>) throws -> NativeSourceDependencies {
        guard frameIDs.count <= 500, audioRowIDs.count <= 500, let db = getConnection(),
              let mutex = sqlite3_db_mutex(db) else { return .unknown }
        // Never block behind a capture writer just to improve presentation precision.
        guard sqlite3_mutex_try(mutex) == SQLITE_OK else { throw DatabaseError.queryExecutionFailed("Source dependencies are busy") }
        defer { sqlite3_mutex_leave(mutex) }
        var targets = Set<NativeSourceTarget>()
        for id in frameIDs {
            try Task.checkCancellation()
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT segmentId FROM frame WHERE id=?", -1, &statement, nil) == SQLITE_OK else { return .unknown }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { return .unknown }
            targets.insert(.frame(id)); targets.insert(.segment(sqlite3_column_int64(statement, 0)))
        }
        for id in audioRowIDs {
            try Task.checkCancellation()
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT batch_audio_path,audio_path FROM audio_captures WHERE id=?", -1, &statement, nil) == SQLITE_OK else { return .unknown }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)
            guard sqlite3_step(statement) == SQLITE_ROW else { return .unknown }
            targets.insert(.audioRow(id))
            for column in [Int32(0), Int32(1)] where sqlite3_column_type(statement, column) != SQLITE_NULL {
                guard sqlite3_column_type(statement, column) == SQLITE_TEXT, sqlite3_column_bytes(statement, column) <= 1024,
                      let value = sqlite3_column_text(statement, column) else { return .unknown }
                let bytes = UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, column)))
                guard !bytes.contains(0), let path = String(bytes: bytes, encoding: .utf8) else { return .unknown }
                targets.insert(.audioBatch(path))
            }
        }
        return .init(targets: targets)
    }
}
