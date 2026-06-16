import Foundation
import SQLCipher
import Shared

public actor DictationSessionQueries {
    private let db: OpaquePointer

    public init(db: OpaquePointer) {
        self.db = db
    }

    public func save(_ session: DictationSession) async throws {
        try upsertSession(session)
    }

    public func upsertSession(_ session: DictationSession) throws {
        let sql = """
            INSERT INTO dictation_sessions (
                id, started_at, ended_at, inserted_at, text, status,
                target_bundle_id, target_app_name, target_window_title,
                insertion_method, error_message, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                started_at = excluded.started_at,
                ended_at = excluded.ended_at,
                inserted_at = excluded.inserted_at,
                text = excluded.text,
                status = excluded.status,
                target_bundle_id = excluded.target_bundle_id,
                target_app_name = excluded.target_app_name,
                target_window_title = excluded.target_window_title,
                insertion_method = excluded.insertion_method,
                error_message = excluded.error_message,
                updated_at = excluded.updated_at;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }

        bindText(statement, index: 1, value: session.id.uuidString)
        sqlite3_bind_int64(statement, 2, Schema.dateToTimestamp(session.startedAt))
        bindDate(statement, index: 3, value: session.endedAt)
        bindDate(statement, index: 4, value: session.insertedAt)
        bindText(statement, index: 5, value: session.text)
        bindText(statement, index: 6, value: session.status.rawValue)
        bindText(statement, index: 7, value: session.targetContext?.bundleID)
        bindText(statement, index: 8, value: session.targetContext?.appName)
        bindText(statement, index: 9, value: session.targetContext?.windowTitle)
        bindText(statement, index: 10, value: session.insertionMethod.rawValue)
        bindText(statement, index: 11, value: session.errorMessage)
        sqlite3_bind_int64(statement, 12, Schema.currentTimestamp())

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func getRecentSessions(limit: Int, offset: Int = 0) throws -> [DictationSession] {
        let sql = """
            SELECT id, started_at, ended_at, inserted_at, text, status,
                   target_bundle_id, target_app_name, target_window_title,
                   insertion_method, error_message
            FROM dictation_sessions
            ORDER BY started_at DESC
            LIMIT ? OFFSET ?;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed(String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int(statement, 1, Int32(max(limit, 0)))
        sqlite3_bind_int(statement, 2, Int32(max(offset, 0)))

        var sessions: [DictationSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                  let id = UUID(uuidString: idText) else {
                continue
            }

            let startedAt = Schema.timestampToDate(sqlite3_column_int64(statement, 1))
            let endedAt = optionalDate(statement, index: 2)
            let insertedAt = optionalDate(statement, index: 3)
            let text = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
            let statusRaw = sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? ""
            let bundleID = optionalText(statement, index: 6)
            let appName = optionalText(statement, index: 7)
            let windowTitle = optionalText(statement, index: 8)
            let methodRaw = sqlite3_column_text(statement, 9).map { String(cString: $0) } ?? ""
            let errorMessage = optionalText(statement, index: 10)

            let context: DictationTargetContext?
            if bundleID != nil || appName != nil || windowTitle != nil {
                context = DictationTargetContext(bundleID: bundleID, appName: appName, windowTitle: windowTitle)
            } else {
                context = nil
            }

            sessions.append(DictationSession(
                id: id,
                startedAt: startedAt,
                endedAt: endedAt,
                insertedAt: insertedAt,
                text: text,
                status: DictationInsertionStatus(rawValue: statusRaw) ?? .failed,
                targetContext: context,
                insertionMethod: DictationInsertionMethod(rawValue: methodRaw) ?? .clipboardPaste,
                errorMessage: errorMessage
            ))
        }

        return sessions
    }

    private func bindText(_ statement: OpaquePointer?, index: Int32, value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindDate(_ statement: OpaquePointer?, index: Int32, value: Date?) {
        if let value {
            sqlite3_bind_int64(statement, index, Schema.dateToTimestamp(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func optionalText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func optionalDate(_ statement: OpaquePointer?, index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Schema.timestampToDate(sqlite3_column_int64(statement, index))
    }
}
