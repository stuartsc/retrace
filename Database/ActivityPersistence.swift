import Foundation
import SQLCipher
import Shared

extension DatabaseManager: ActivityStoreProtocol {
    public func activityStoreID() async throws -> UUID {
        try RecallSQL.nativeStore(requireRecallConnection())
    }

    public func appendActivity(_ event: ActivityEvent) async throws -> PersistedActivityEvent {
        let db = try requireRecallConnection()
        let payload = try RecallSQL.encode(event)
        guard event.sequence > 0, event.monotonicTime.isFinite, event.monotonicTime >= 0,
              event.observedAt.timeIntervalSince1970.isFinite, !event.method.isEmpty,
              event.method.utf8.count <= 128, payload.utf8.count <= 65_536 else {
            throw RecallSQL.failure("Invalid or oversized activity event")
        }
        let administrative: Set<ActivityEventKind> = [.pause, .resume, .sleep, .wake, .shutdown, .gap, .excluded, .permissionLost, .observerFailure, .clockChange]
        guard !administrative.contains(event.kind) || event.context == nil else {
            throw RecallSQL.failure("Administrative activity must omit captured context")
        }
        return try PipelineSQL.transaction(db) {
            if let existing = try RecallSQL.activity(db, event.id) {
                guard existing.event == event else { throw RecallSQL.failure("Activity UUID reused with different content") }
                return existing
            }
            guard try PipelineSQL.integers(db, "SELECT 1 FROM activity_deleted WHERE eventID=?", [.text(event.id.uuidString)]).isEmpty else {
                throw RecallSQL.failure("Deleted activity cannot be recreated")
            }
            let previous = try PipelineSQL.query(db, "SELECT lastSequence,lastMonotonic,closed FROM activity_session WHERE sessionID=?", [.text(event.sessionID.uuidString)]) {
                (sqlite3_column_int64($0, 0), sqlite3_column_double($0, 1), sqlite3_column_int($0, 2) != 0)
            }.first
            if let previous {
                guard !previous.2, event.sequence > previous.0,
                      (event.sequence == previous.0 + 1 || event.kind == .gap), event.monotonicTime >= previous.1 else {
                    throw RecallSQL.failure("Activity session sequence or monotonic time conflicts")
                }
            } else if event.sequence != 1 && event.kind != .gap {
                throw RecallSQL.failure("Activity session must start at sequence one or explicit gap")
            }
            if event.kind == .enrichment {
                guard let relatedID = event.relatedEventID, let related = try RecallSQL.activity(db, relatedID),
                      related.event.sessionID == event.sessionID,
                      related.event.monotonicTime <= event.monotonicTime,
                      let original = related.event.context, let enriched = event.context,
                      original.appBundleID == enriched.appBundleID,
                      original.processID == enriched.processID, original.processGeneration == enriched.processGeneration,
                      original.windowID == enriched.windowID else { throw RecallSQL.failure("Enrichment target identity conflicts") }
            }
            let persistedTimestamp = Date().timeIntervalSince1970
            let persistedAt = Date(timeIntervalSince1970: persistedTimestamp)
            let sequence = try RecallSQL.feed(db, kind: "activity", id: event.id, payload: payload)
            let searchable = event.context.map { [$0.appName, $0.windowTitle, $0.documentID, $0.paneID, $0.safeURL].compactMap { $0 }.joined(separator: "\n") } ?? ""
            try PipelineSQL.execute(db, "INSERT INTO activity_event(eventID,sessionID,sessionSequence,commitSequence,observedAt,monotonicTime,persistedAt,appBundleID,metadataSearch,payload) VALUES(?,?,?,?,?,?,?,?,?,?)", [
                .text(event.id.uuidString), .text(event.sessionID.uuidString), .integer(event.sequence), .integer(sequence),
                .real(event.observedAt.timeIntervalSince1970), .real(event.monotonicTime), .real(persistedTimestamp),
                .text(event.context?.appBundleID ?? ""), .text(RecallSQL.searchKey(searchable)), .text(payload)
            ])
            try PipelineSQL.execute(db, "INSERT INTO activity_session(sessionID,lastSequence,lastMonotonic,closed) VALUES(?,?,?,?) ON CONFLICT(sessionID) DO UPDATE SET lastSequence=excluded.lastSequence,lastMonotonic=excluded.lastMonotonic,closed=excluded.closed", [
                .text(event.sessionID.uuidString), .integer(event.sequence), .real(event.monotonicTime), .integer(event.kind == .shutdown ? 1 : 0)
            ])
            try ActivityLinkSQL.invalidateLateLinks(db, event: event)
            if event.kind == .gap { try PipelineSQL.execute(db, "UPDATE activity_state SET gapCount=gapCount+1 WHERE id=1") }
            try DailyMetricsQueries.recordEvent(db: db, metricType: .activityPersisted,
                metadata: "{\"kind\":\"\(event.kind.rawValue)\",\"coverage\":\"\(event.coverage.rawValue)\"}")
            return PersistedActivityEvent(storeID: try RecallSQL.nativeStore(db), commitSequence: sequence, persistedAt: persistedAt, event: event)
        }
    }

    public func searchActivity(_ query: ActivityQuery) async throws -> ActivityPage {
        let db = try requireRecallConnection()
        guard query.afterSequence >= 0, query.text.utf8.count <= 4096,
              (query.appBundleIDs?.count ?? 0) <= 100,
              query.from?.timeIntervalSince1970.isFinite ?? true,
              query.to?.timeIntervalSince1970.isFinite ?? true else { throw RecallSQL.failure("Invalid activity query") }
        if query.appBundleIDs?.isEmpty == true { return ActivityPage(events: [], nextSequence: nil) }
        var conditions = ["commitSequence>?"]
        var values: [PipelineSQL.Value] = [.integer(query.afterSequence)]
        if let from = query.from { conditions.append("observedAt>=?"); values.append(.real(from.timeIntervalSince1970)) }
        if let to = query.to { conditions.append("observedAt<=?"); values.append(.real(to.timeIntervalSince1970)) }
        if let apps = query.appBundleIDs {
            conditions.append("appBundleID IN (\(Array(repeating: "?", count: apps.count).joined(separator: ",")))")
            values += apps.map(PipelineSQL.Value.text)
        }
        if !query.text.isEmpty { conditions.append("instr(metadataSearch,?)>0"); values.append(.text(RecallSQL.searchKey(query.text))) }
        values.append(.integer(Int64(query.limit + 1)))
        let storeID = try RecallSQL.nativeStore(db)
        let rows = try PipelineSQL.query(db, "SELECT commitSequence,persistedAt,payload FROM activity_event WHERE \(conditions.joined(separator: " AND ")) ORDER BY commitSequence LIMIT ?", values) {
            try RecallSQL.activityRow($0, storeID: storeID)
        }
        let events = Array(rows.prefix(query.limit))
        return ActivityPage(events: events, nextSequence: rows.count > query.limit ? events.last?.commitSequence : nil)
    }

    public func activityEvent(id: UUID) async throws -> PersistedActivityEvent? {
        try RecallSQL.activity(requireRecallConnection(), id)
    }

    public func activityHealth() async throws -> ActivityStoreHealth {
        let db = try requireRecallConnection()
        let latest = try PipelineSQL.query(db, "SELECT observedAt,persistedAt,commitSequence FROM activity_event ORDER BY commitSequence DESC LIMIT 1") {
            (Date(timeIntervalSince1970: sqlite3_column_double($0, 0)), Date(timeIntervalSince1970: sqlite3_column_double($0, 1)), sqlite3_column_int64($0, 2))
        }.first
        let state = try PipelineSQL.query(db, "SELECT gapCount,correctionRevision FROM activity_state WHERE id=1") {
            (Int(sqlite3_column_int64($0, 0)), sqlite3_column_int64($0, 1))
        }.first
        return ActivityStoreHealth(lastObservedAt: latest?.0, lastPersistedAt: latest?.1,
                                   latestSequence: latest?.2 ?? 0, gapCount: state?.0 ?? 0, correctionRevision: state?.1 ?? 0)
    }

    public func activityFeed(after sequence: Int64, limit: Int) async throws -> [ActivityFeedEntry] {
        guard sequence >= 0, (1...500).contains(limit) else { throw RecallSQL.failure("Invalid feed page") }
        return try PipelineSQL.query(requireRecallConnection(), "SELECT sequence,kind,entityID,payload FROM activity_feed WHERE sequence>? ORDER BY sequence LIMIT ?", [.integer(sequence), .integer(Int64(limit))]) {
            guard let id = UUID(uuidString: RecallSQL.string($0, 2)) else { throw RecallSQL.failure("Invalid feed identity") }
            return ActivityFeedEntry(id: sqlite3_column_int64($0, 0), kind: RecallSQL.string($0, 1), entityID: id, payload: Data(RecallSQL.string($0, 3).utf8))
        }
    }

    public func acknowledgeActivityFeed(consumer: String, through sequence: Int64) async throws {
        let db = try requireRecallConnection()
        guard !consumer.isEmpty, consumer.utf8.count <= 128, sequence >= 0,
              consumer.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw RecallSQL.failure("Invalid consumer checkpoint") }
        try PipelineSQL.transaction(db) {
            let maximum = try PipelineSQL.integers(db, "SELECT COALESCE(MAX(sequence),0) FROM activity_feed").first ?? 0
            guard sequence <= maximum else { throw RecallSQL.failure("Cannot acknowledge unpublished feed sequence") }
            try PipelineSQL.execute(db, "INSERT INTO activity_checkpoint(consumer,sequence) VALUES(?,?) ON CONFLICT(consumer) DO UPDATE SET sequence=MAX(sequence,excluded.sequence)", [.text(consumer), .integer(sequence)])
        }
    }

    public func activityFeedCheckpoint(consumer: String) async throws -> Int64 {
        guard !consumer.isEmpty, consumer.utf8.count <= 128 else { throw RecallSQL.failure("Invalid consumer") }
        return try PipelineSQL.integers(requireRecallConnection(), "SELECT sequence FROM activity_checkpoint WHERE consumer=?", [.text(consumer)]).first ?? 0
    }

    public func submitActivityCorrection(_ command: ActivityCorrection) async throws -> ActivityCorrectionReceipt {
        let db = try requireRecallConnection()
        let payload = try RecallSQL.encode(command)
        guard !command.targetEventIDs.isEmpty, command.targetEventIDs.count <= 500,
              Set(command.targetEventIDs).count == command.targetEventIDs.count, command.expectedRevision >= 0,
              payload.utf8.count <= 65_536, (command.label?.utf8.count ?? 0) <= 512,
              !command.author.isEmpty, command.author.utf8.count <= 128, command.createdAt.timeIntervalSince1970.isFinite else {
            throw RecallSQL.failure("Invalid correction command")
        }
        if [.rename, .assignProject].contains(command.action), command.label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw RecallSQL.failure("Correction label is required")
        }
        return try PipelineSQL.transaction(db) {
            if let existing = try RecallSQL.correction(db, id: command.id) {
                guard try RecallSQL.encode(existing.command) == payload else { throw RecallSQL.failure("Correction UUID reused") }
                return existing
            }
            let current = try RecallSQL.correctionRevision(db)
            let targets = try command.targetEventIDs.compactMap { try RecallSQL.activity(db, $0) }
            var valid = current == command.expectedRevision && targets.count == command.targetEventIDs.count
            if command.scope == .document {
                valid = valid && command.documentKey != nil && targets.allSatisfy { $0.event.context?.stableDocumentKey == command.documentKey }
            }
            if command.action == .revoke {
                if let revokedID = command.revokesCommandID, let target = try RecallSQL.correction(db, id: revokedID) {
                    valid = valid && [.draft, .pending, .applied].contains(target.status)
                        && Set(target.command.targetEventIDs) == Set(command.targetEventIDs)
                } else { valid = false }
            } else if command.revokesCommandID != nil { valid = false }
            let revision = valid ? current + 1 : current
            let status: ActivityCorrectionStatus = valid ? (command.confirmed ? .pending : .draft) : .conflict
            let receipt = ActivityCorrectionReceipt(command: command, revision: revision, status: status)
            try PipelineSQL.execute(db, "INSERT INTO activity_correction(commandID,revision,status,payload) VALUES(?,?,?,?)", [.text(command.id.uuidString), .integer(revision), .text(status.rawValue), .text(payload)])
            for id in command.targetEventIDs {
                try PipelineSQL.execute(db, "INSERT INTO activity_correction_target(commandID,eventID) VALUES(?,?)", [.text(command.id.uuidString), .text(id.uuidString)])
            }
            if valid { try PipelineSQL.execute(db, "UPDATE activity_state SET correctionRevision=? WHERE id=1", [.integer(revision)]) }
            _ = try RecallSQL.feed(db, kind: "correction", id: command.id, payload: RecallSQL.encode(receipt))
            try DailyMetricsQueries.recordEvent(db: db, metricType: .activityCorrection,
                metadata: "{\"action\":\"\(command.action.rawValue)\",\"status\":\"\(status.rawValue)\",\"confirmed\":\(command.confirmed)}")
            return receipt
        }
    }

    public func activityCorrections() async throws -> [ActivityCorrectionReceipt] {
        // Compatibility read must not silently hide active mappings. Incremental consumers
        // use the bounded, resumable activity feed rather than repeatedly loading this list.
        try PipelineSQL.query(requireRecallConnection(), "SELECT revision,status,payload FROM activity_correction ORDER BY revision,commandID") { try RecallSQL.correctionRow($0) }
    }

    public func acknowledgeActivityCorrection(id: UUID, expectedRevision: Int64, applied: Bool) async throws {
        let db = try requireRecallConnection()
        try PipelineSQL.transaction(db) {
            guard let receipt = try RecallSQL.correction(db, id: id), receipt.revision == expectedRevision,
                  receipt.command.confirmed else { throw RecallSQL.failure("Correction acknowledgement conflicts") }
            let outcome: ActivityCorrectionStatus = applied ? .applied : .conflict
            if receipt.status == outcome { return }
            guard receipt.status == .pending else { throw RecallSQL.failure("Correction is not awaiting acknowledgement") }
            let targetsExist = try receipt.command.targetEventIDs.allSatisfy { try RecallSQL.activity(db, $0) != nil }
            let status: ActivityCorrectionStatus = targetsExist ? outcome : .conflict
            try PipelineSQL.execute(db, "UPDATE activity_correction SET status=? WHERE commandID=?", [.text(status.rawValue), .text(id.uuidString)])
            if status == .applied, let original = receipt.command.revokesCommandID {
                try PipelineSQL.execute(db, "UPDATE activity_correction SET status='revoked' WHERE commandID=?", [.text(original.uuidString)])
            }
            let updated = ActivityCorrectionReceipt(command: receipt.command, revision: receipt.revision, status: status)
            _ = try RecallSQL.feed(db, kind: "correction_acknowledged", id: id, payload: RecallSQL.encode(updated))
            try DailyMetricsQueries.recordEvent(db: db, metricType: .activityCorrection, metadata: "{\"action\":\"acknowledged\",\"status\":\"\(status.rawValue)\"}")
        }
    }

    public func deleteActivity(eventIDs: [UUID]) async throws {
        guard eventIDs.count <= 500 else { throw RecallSQL.failure("Activity deletion exceeds bounded batch") }
        let db = try requireRecallConnection()
        try PipelineSQL.transaction(db) {
            var deletedCount = 0
            for id in Set(eventIDs) {
                if try PipelineSQL.integers(db, "SELECT 1 FROM activity_deleted WHERE eventID=?", [.text(id.uuidString)]).first != nil { continue }
                let correctionIDs = try PipelineSQL.query(db, "SELECT commandID FROM activity_correction_target WHERE eventID=?", [.text(id.uuidString)]) { RecallSQL.string($0, 0) }
                for rawID in correctionIDs {
                    guard let commandID = UUID(uuidString: rawID), let old = try RecallSQL.correction(db, id: commandID) else { continue }
                    let sanitized = ActivityCorrection(id: commandID, targetEventIDs: [], expectedRevision: old.command.expectedRevision,
                        action: old.command.action, confirmed: old.command.confirmed, author: "redacted", createdAt: old.command.createdAt)
                    try PipelineSQL.execute(db, "UPDATE activity_correction SET payload=?,status='revoked' WHERE commandID=?", [.text(try RecallSQL.encode(sanitized)), .text(rawID)])
                    try PipelineSQL.execute(db, "DELETE FROM activity_correction_target WHERE commandID=?", [.text(rawID)])
                    try PipelineSQL.execute(db, "UPDATE activity_feed SET kind='redacted',payload='{}' WHERE entityID=?", [.text(rawID)])
                }
                try PipelineSQL.execute(db, "DELETE FROM activity_event WHERE eventID=?", [.text(id.uuidString)])
                try PipelineSQL.execute(db, "UPDATE activity_feed SET kind='redacted',payload='{}' WHERE entityID=?", [.text(id.uuidString)])
                try PipelineSQL.execute(db, "INSERT INTO activity_deleted(eventID) VALUES(?)", [.text(id.uuidString)])
                _ = try RecallSQL.feed(db, kind: "activity_deleted", id: id, payload: "{}")
                deletedCount += 1
            }
            if deletedCount > 0 {
                try PipelineSQL.execute(db, "UPDATE activity_state SET correctionRevision=correctionRevision+1 WHERE id=1")
                try DailyMetricsQueries.recordEvent(db: db, metricType: .activityDeleted, metadata: "{\"count\":\(deletedCount)}")
            }
        }
    }

    func requireRecallConnection() throws -> OpaquePointer {
        guard let db = getConnection() else { throw DatabaseError.connectionFailed(underlying: "Database not initialized") }
        return db
    }
}

enum RecallSQL {
    static func failure(_ message: String) -> DatabaseError { .queryFailed(query: "progressive recall persistence", underlying: message) }
    static func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T { try JSONDecoder().decode(type, from: Data(value.utf8)) }
    static func searchKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func nativeStore(_ db: OpaquePointer) throws -> UUID {
        let value = try PipelineSQL.query(db, "SELECT storeID FROM evidence_store WHERE source='native' AND identity='native'") { string($0, 0) }.first
        guard let value, let uuid = UUID(uuidString: value) else { throw failure("Canonical store identity missing") }
        return uuid
    }
    @discardableResult static func feed(_ db: OpaquePointer, kind: String, id: UUID, payload: String) throws -> Int64 {
        try PipelineSQL.execute(db, "INSERT INTO activity_feed(kind,entityID,payload) VALUES(?,?,?)", [.text(kind), .text(id.uuidString), .text(payload)])
        return sqlite3_last_insert_rowid(db)
    }
    static func activity(_ db: OpaquePointer, _ id: UUID) throws -> PersistedActivityEvent? {
        let storeID = try nativeStore(db)
        return try PipelineSQL.query(db, "SELECT commitSequence,persistedAt,payload FROM activity_event WHERE eventID=?", [.text(id.uuidString)]) { try activityRow($0, storeID: storeID) }.first
    }
    static func activityRow(_ statement: OpaquePointer, storeID: UUID) throws -> PersistedActivityEvent {
        PersistedActivityEvent(storeID: storeID, commitSequence: sqlite3_column_int64(statement, 0),
            persistedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), event: try decode(ActivityEvent.self, string(statement, 2)))
    }
    static func correctionRevision(_ db: OpaquePointer) throws -> Int64 {
        try PipelineSQL.integers(db, "SELECT correctionRevision FROM activity_state WHERE id=1").first ?? 0
    }
    static func correction(_ db: OpaquePointer, id: UUID) throws -> ActivityCorrectionReceipt? {
        try PipelineSQL.query(db, "SELECT revision,status,payload FROM activity_correction WHERE commandID=?", [.text(id.uuidString)]) { try correctionRow($0) }.first
    }
    static func correctionRow(_ statement: OpaquePointer) throws -> ActivityCorrectionReceipt {
        guard let status = ActivityCorrectionStatus(rawValue: string(statement, 1)) else { throw failure("Invalid correction status") }
        return ActivityCorrectionReceipt(command: try decode(ActivityCorrection.self, string(statement, 2)), revision: sqlite3_column_int64(statement, 0), status: status)
    }
}
