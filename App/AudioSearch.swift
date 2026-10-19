import Foundation
import CryptoKit
import Database
import Shared
import SQLCipher

/// A local, ephemeral selection proof. Audio never manufactures a screen frame.
public struct AudioSearchHit: Sendable, Identifiable {
    public let record: AudioTranscription
    public let id: String
    let owner: UUID

    init(record: AudioTranscription, owner: UUID) throws {
        self.record = record
        self.owner = owner
        let fields: [String?] = [String(record.id), record.sessionID, record.text,
            String(record.startTime.timeIntervalSince1970), String(record.endTime.timeIntervalSince1970),
            record.source.rawValue, record.confidence.map(String.init(describing:)),
            String(record.createdAt.timeIntervalSince1970), record.audioPath, record.batchAudioPath,
            record.transcriptStatus, record.detectedLanguage, record.audioVariant, record.qualityFlags,
            String(record.transcriptionPass)]
        let data = try JSONEncoder().encode(fields)
        id = owner.uuidString + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct AudioSearchPage: Sendable {
    public let hits: [AudioSearchHit]
    public let isTruncated: Bool
    public let notice: String?
    public init(hits: [AudioSearchHit] = [], isTruncated: Bool = false, notice: String? = nil) {
        self.hits = hits; self.isTruncated = isTruncated; self.notice = notice
    }
}

public enum AudioSearchError: Error { case changed, invalidQuery, unavailable }

/// Called synchronously on DataAdapter's owned read connection. Never starts a
/// model, prepares history, or borrows the application's SQLite writer.
enum AudioSearchReader {
    private static let columns = """
        a.id,a.session_id,a.text,a.start_time,a.end_time,a.source,a.confidence,a.created_at,
        a.audio_path,a.batch_audio_path,a.transcript_status,a.detected_language,a.audio_variant,
        a.quality_flags,a.transcription_pass
        """
    private static let visible = """
        a.source IN ('microphone','system') AND a.transcript_status='transcribed'
        AND (a.batch_audio_path IS NULL OR a.batch_audio_path='' OR a.transcription_pass=(
          SELECT MAX(latest.transcription_pass) FROM audio_captures latest
          WHERE latest.batch_audio_path=a.batch_audio_path AND latest.source!='word'))
        """

    static func search(connection: DatabaseConnection, owner: UUID,
                       query: SearchQuery, match: String) throws -> AudioSearchPage {
        let filters = query.filters
        guard (filters.appBundleIDs ?? []).isEmpty, (filters.excludedAppBundleIDs ?? []).isEmpty,
              (filters.selectedTagIds ?? []).isEmpty, (filters.excludedTagIds ?? []).isEmpty,
              filters.windowNameFilter == nil, filters.browserUrlFilter == nil,
              filters.commentFilter == .allFrames, filters.hiddenFilter != .onlyHidden else {
            return AudioSearchPage(notice: "Audio was not searched: these screen filters have no verified audio association.")
        }
        guard query.text.utf8.count <= 16_384, query.limit > 0 else { throw AudioSearchError.invalidQuery }
        let limit = min(query.limit, 100)
        var bounds: [Int64] = []
        var dateSQL: [String] = []
        for range in filters.effectiveDateRanges {
            var parts: [String] = []
            for (date, field, operation) in [(range.start, "a.start_time", ">="), (range.end, "a.end_time", "<=")] {
                if let date {
                    let milliseconds = date.timeIntervalSince1970 * 1_000
                    guard milliseconds.isFinite, milliseconds > Double(Int64.min), milliseconds < Double(Int64.max) else {
                        throw AudioSearchError.invalidQuery
                    }
                    parts.append("\(field) \(operation) ?")
                    bounds.append(Int64(milliseconds))
                }
            }
            if !parts.isEmpty { dateSQL.append("(" + parts.joined(separator: " AND ") + ")") }
        }
        let ordering = query.sortOrder == .oldestFirst ? "ASC" : "DESC"
        let sql = "SELECT \(columns) FROM audio_captures a WHERE \(visible) " +
            "AND a.id IN (SELECT rowid FROM audio_captures_fts WHERE audio_captures_fts MATCH ?) " +
            (dateSQL.isEmpty ? "" : "AND (" + dateSQL.joined(separator: " OR ") + ") ") +
            "ORDER BY a.start_time \(ordering),a.id \(ordering) LIMIT ?"
        let statement = try connection.prepare(sql: sql)
        defer { connection.finalize(statement) }
        sqlite3_bind_text(statement, 1, match, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        for (index, bound) in bounds.enumerated() { sqlite3_bind_int64(statement, Int32(index + 2), bound) }
        sqlite3_bind_int(statement, Int32(bounds.count + 2), Int32(limit + 1))
        let rows = try read(statement)
        return AudioSearchPage(hits: try rows.prefix(limit).map { try AudioSearchHit(record: $0, owner: owner) },
                               isTruncated: rows.count > limit)
    }

    static func resolve(_ hit: AudioSearchHit, connection: DatabaseConnection, owner: UUID) throws -> AudioTranscription {
        guard hit.owner == owner else { throw AudioSearchError.changed }
        let statement = try connection.prepare(sql: "SELECT \(columns) FROM audio_captures a WHERE a.id=? AND \(visible)")
        defer { connection.finalize(statement) }
        sqlite3_bind_int64(statement, 1, hit.record.id)
        guard let row = try read(statement).first,
              try AudioSearchHit(record: row, owner: owner).id == hit.id else { throw AudioSearchError.changed }
        return row
    }

    private static func read(_ statement: OpaquePointer?) throws -> [AudioTranscription] {
        var rows: [AudioTranscription] = []
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW, rows.count < 101 else { throw AudioSearchError.unavailable }
            func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
            func date(_ column: Int32) -> Date { Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, column)) / 1_000) }
            guard let body = text(2), body.utf8.count <= 262_144,
                  let source = text(5).flatMap(AudioSource.init(rawValue:)) else { throw AudioSearchError.unavailable }
            rows.append(AudioTranscription(id: sqlite3_column_int64(statement, 0), sessionID: text(1), text: body,
                startTime: date(3), endTime: date(4), source: source,
                confidence: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 6),
                createdAt: date(7), audioPath: text(8), batchAudioPath: text(9),
                transcriptStatus: text(10) ?? "transcribed", detectedLanguage: text(11), audioVariant: text(12) ?? "raw",
                qualityFlags: text(13), transcriptionPass: Int(sqlite3_column_int(statement, 14))))
        }
    }
}
