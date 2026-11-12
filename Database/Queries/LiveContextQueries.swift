import Foundation
import Shared
import SQLCipher

public struct ContextMetadataRecord: Equatable, Sendable {
    public let nativeStoreID: UUID
    public let frameID: FrameID
    public let timestamp: Date
    public let appBundleID: String?
    public let windowTitle: String?
    public let browserURL: String?
}

public struct ContextNoteRecord: Equatable, Sendable {
    public let nativeStoreID: UUID
    public let comment: SegmentComment
    public let referenceTimestamp: Date
    public let segmentID: SegmentID
    public let appBundleID: String?
    public let windowTitle: String?
    public let browserURL: String?
}

public struct ContextReadCursor: Equatable, Sendable {
    let storeID: UUID
    let from: Date
    let to: Date
    let query: String
    let timestamp: Int64
    let rowID: Int64
    let kind: String
}

public struct ContextMetadataPage: Sendable {
    public let entries: [ContextMetadataRecord]
    public let nextCursor: ContextReadCursor?
}
public struct ContextNotePage: Sendable {
    public let entries: [ContextNoteRecord]
    public let nextCursor: ContextReadCursor?
}

/// Native V23 reads only. Same-timestamp rows use their exact IDs as the second
/// key. No schema writes, raw SQL inputs, nearby-frame assignment or media reads.
enum LiveContextQueries {
    static func metadata(db: OpaquePointer, storeID: UUID, from: Date, to: Date, query: String,
                         before: ContextReadCursor?, limit: Int, frameID: FrameID? = nil) throws -> ContextMetadataPage {
        let query = try validate(storeID: storeID, from: from, to: to, query: query, before: before, kind: "metadata", limit: limit)
        return try bounded(db) {
            let sql = """
                SELECT f.id,f.createdAt,s.bundleID,s.windowName,s.browserUrl
                FROM frame f JOIN segment s ON s.id=f.segmentId
                WHERE f.createdAt>=? AND f.createdAt<? AND f.redactionReason IS NULL
                AND NOT EXISTS(SELECT 1 FROM segment_tag st JOIN tag t ON t.id=st.tagId WHERE st.segmentId=s.id AND t.name='hidden')
                AND (lower(coalesce(s.bundleID,'')) LIKE ? ESCAPE '\\' OR lower(coalesce(s.windowName,'')) LIKE ? ESCAPE '\\')
                \(frameID == nil ? "" : "AND f.id=?")
                \(before == nil ? "" : "AND (f.createdAt,f.id)<(?,?)")
                ORDER BY f.createdAt DESC,f.id DESC LIMIT ?
                """
            let statement = try prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(from)); sqlite3_bind_int64(statement, 2, Schema.dateToTimestamp(to))
            bind(pattern(query), statement, 3); bind(pattern(query), statement, 4)
            var binding: Int32 = 5
            if let frameID { sqlite3_bind_int64(statement, binding, frameID.value); binding += 1 }
            if let before {
                sqlite3_bind_int64(statement, binding, before.timestamp); sqlite3_bind_int64(statement, binding + 1, before.rowID); binding += 2
            }
            sqlite3_bind_int(statement, binding, Int32(limit + 1))
            var entries: [ContextMetadataRecord] = []
            var lastTimestamp: Int64 = 0
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                entries.append(ContextMetadataRecord(nativeStoreID: storeID, frameID: .init(value: sqlite3_column_int64(statement, 0)),
                    timestamp: Schema.timestampToDate(sqlite3_column_int64(statement, 1)), appBundleID: string(statement, 2),
                    windowTitle: string(statement, 3), browserURL: string(statement, 4)))
                if entries.count <= limit { lastTimestamp = sqlite3_column_int64(statement, 1) }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw DatabaseError.queryExecutionFailed("Bounded context metadata read interrupted") }
            let more = entries.count > limit
            if more { entries.removeLast() }
            let cursor = more ? entries.last.map { ContextReadCursor(storeID: storeID, from: from, to: to, query: query,
                timestamp: lastTimestamp, rowID: $0.frameID.value, kind: "metadata") } : nil
            return ContextMetadataPage(entries: entries, nextCursor: cursor)
        }
    }

    static func notes(db: OpaquePointer, storeID: UUID, from: Date, to: Date, query: String,
                      before: ContextReadCursor?, limit: Int, commentID: SegmentCommentID? = nil,
                      segmentID: SegmentID? = nil) throws -> ContextNotePage {
        let query = try validate(storeID: storeID, from: from, to: to, query: query, before: before, kind: "notes", limit: limit)
        return try bounded(db) {
            // A note linked to several segments is returned once, using its first
            // eligible segment. Its text stays a note, never an invented screen.
            let sql = """
                WITH eligible AS (
                  SELECT c.id,s.id AS segmentID
                  FROM frame f INDEXED BY index_frame_on_createdat
                  CROSS JOIN segment_comment c INDEXED BY index_segment_comment_on_frameid ON c.frameId=f.id
                  JOIN segment s ON s.id=f.segmentId
                  JOIN segment_comment_link l ON l.commentId=c.id AND l.segmentId=s.id
                  WHERE f.createdAt>=?1 AND f.createdAt<?2 AND f.redactionReason IS NULL
                  AND NOT EXISTS(SELECT 1 FROM segment_tag st JOIN tag t ON t.id=st.tagId WHERE st.segmentId=s.id AND t.name='hidden')
                  UNION ALL
                  SELECT c.id,s.id AS segmentID
                  FROM segment s INDEXED BY index_segment_on_starttime
                  CROSS JOIN segment_comment_link l INDEXED BY index_segment_comment_link_on_segmentid_commentid ON l.segmentId=s.id
                  JOIN segment_comment c ON c.id=l.commentId AND c.frameId IS NULL
                  WHERE s.startDate>=?1 AND s.startDate<?2
                  AND NOT EXISTS(SELECT 1 FROM segment_tag st JOIN tag t ON t.id=st.tagId WHERE st.segmentId=s.id AND t.name='hidden')
                ), candidates AS (
                  SELECT e.id,MIN(e.segmentID) AS segmentID FROM eligible e JOIN segment_comment c ON c.id=e.id
                  WHERE lower(c.body) LIKE ?3 ESCAPE '\\' \(commentID == nil ? "" : "AND c.id=?")
                  \(segmentID == nil ? "" : "AND e.segmentID=?") GROUP BY e.id
                )
                SELECT c.id,c.body,c.author,c.attachmentsJson,c.frameId,c.createdAt,c.updatedAt,
                       coalesce(f.createdAt,s.startDate),s.id,s.bundleID,s.windowName,s.browserUrl
                FROM candidates x JOIN segment_comment c ON c.id=x.id JOIN segment s ON s.id=x.segmentID
                LEFT JOIN frame f ON f.id=c.frameId
                \(before == nil ? "" : "WHERE (coalesce(f.createdAt,s.startDate),c.id)<(?,?)")
                ORDER BY coalesce(f.createdAt,s.startDate) DESC,c.id DESC LIMIT ?
                """
            let statement = try prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Schema.dateToTimestamp(from)); sqlite3_bind_int64(statement, 2, Schema.dateToTimestamp(to))
            bind(pattern(query), statement, 3)
            var binding: Int32 = 4
            if let commentID { sqlite3_bind_int64(statement, binding, commentID.value); binding += 1 }
            if let segmentID { sqlite3_bind_int64(statement, binding, segmentID.value); binding += 1 }
            if let before { sqlite3_bind_int64(statement, binding, before.timestamp); sqlite3_bind_int64(statement, binding + 1, before.rowID); binding += 2 }
            sqlite3_bind_int(statement, binding, Int32(limit + 1))
            var entries: [ContextNoteRecord] = []
            var lastTimestamp: Int64 = 0
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let attachmentData = Data((string(statement, 3) ?? "[]").utf8)
                let attachments = try JSONDecoder().decode([SegmentCommentAttachment].self, from: attachmentData)
                let comment = SegmentComment(id: .init(value: sqlite3_column_int64(statement, 0)), body: string(statement, 1) ?? "",
                    author: string(statement, 2) ?? "", attachments: attachments,
                    frameID: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : .init(value: sqlite3_column_int64(statement, 4)),
                    createdAt: Schema.timestampToDate(sqlite3_column_int64(statement, 5)), updatedAt: Schema.timestampToDate(sqlite3_column_int64(statement, 6)))
                entries.append(ContextNoteRecord(nativeStoreID: storeID, comment: comment,
                    referenceTimestamp: Schema.timestampToDate(sqlite3_column_int64(statement, 7)), segmentID: .init(value: sqlite3_column_int64(statement, 8)),
                    appBundleID: string(statement, 9), windowTitle: string(statement, 10), browserURL: string(statement, 11)))
                if entries.count <= limit { lastTimestamp = sqlite3_column_int64(statement, 7) }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw DatabaseError.queryExecutionFailed("Bounded context note read interrupted") }
            let more = entries.count > limit
            if more { entries.removeLast() }
            let cursor = more ? entries.last.map { ContextReadCursor(storeID: storeID, from: from, to: to, query: query,
                timestamp: lastTimestamp, rowID: $0.comment.id.value, kind: "notes") } : nil
            return ContextNotePage(entries: entries, nextCursor: cursor)
        }
    }

    private static func validate(storeID: UUID, from: Date, to: Date, query: String, before: ContextReadCursor?, kind: String, limit: Int) throws -> String {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lower = from.timeIntervalSince1970 * 1_000, upper = to.timeIntervalSince1970 * 1_000
        guard lower.isFinite, upper.isFinite, lower >= Double(Int64.min), upper < Double(Int64.max), from < to,
              !query.contains("\0"), query.utf8.count <= 512, (1...100).contains(limit) else { throw DatabaseError.queryExecutionFailed("Invalid bounded context query") }
        if let before {
            guard before.storeID == storeID, before.from == from, before.to == to, before.query == query, before.kind == kind else {
                throw DatabaseError.queryExecutionFailed("Context cursor scope changed")
            }
        }
        return query
    }
    private static func pattern(_ value: String) -> String {
        "%" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
    }
    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.queryExecutionFailed("Context query could not be prepared")
        }
        return statement
    }
    private static func bind(_ value: String, _ statement: OpaquePointer, _ index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
    private final class Budget {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
    }
    private static func bounded<T>(_ db: OpaquePointer, body: () throws -> T) throws -> T {
        guard let mutex = sqlite3_db_mutex(db), sqlite3_mutex_try(mutex) == SQLITE_OK else {
            throw DatabaseError.queryExecutionFailed("Context reader busy; retry shortly")
        }
        defer { sqlite3_mutex_leave(mutex) }
        let budget = Budget()
        let opaque = Unmanaged.passUnretained(budget).toOpaque()
        sqlite3_progress_handler(db, 1_000, { pointer in
            guard let pointer else { return 1 }
            let budget = Unmanaged<Budget>.fromOpaque(pointer).takeUnretainedValue()
            return Task.isCancelled || ContinuousClock.now >= budget.deadline ? 1 : 0
        }, opaque)
        defer { sqlite3_progress_handler(db, 0, nil, nil); withExtendedLifetime(budget) {} }
        try Task.checkCancellation()
        return try body()
    }
}
