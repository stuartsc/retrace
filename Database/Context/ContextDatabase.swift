import CryptoKit
import Foundation
import SQLCipher
import Shared

/// An actor-owned, separately versioned database. The native recording UUID is an identity fence,
/// not a connection or a disclosure capability. All transactions are synchronous and bounded.
public actor ContextDatabase: ContextStoreProtocol, AudioSessionSettingsStoreProtocol {
    private static let applicationID = 1_381_253_976 // RTCX
    private static let schemaVersion = 5
    private static let maximumPayloadBytes = 65_536
    private let databasePath: String
    public nonisolated let nativeStoreID: UUID
    private var connection: OpaquePointer?
    private var identity: UUID?
    private var terminallyClosed = false

    public init(databasePath: String, nativeStoreID: UUID) {
        self.databasePath = databasePath
        self.nativeStoreID = nativeStoreID
    }

    deinit { if let connection { sqlite3_close_v2(connection) } }

    public func initialize() throws {
        guard !terminallyClosed else { throw ContextStoreError.closed }
        if connection != nil { return }
        guard !databasePath.isEmpty, !databasePath.contains("\0") else { throw ContextStoreError.invalidInput }
        try Task.checkCancellation()
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(databasePath, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw DatabaseError.connectionFailed(underlying: "Unable to open context database")
        }
        connection = opened
        do {
            guard sqlite3_busy_timeout(opened, 1_000) == SQLITE_OK else { throw databaseError("busy_timeout") }
            try execute("PRAGMA foreign_keys=ON")
            let storedIdentity: UUID = try transaction {
                let applicationID = try scalar("PRAGMA application_id")
                let version = try scalar("PRAGMA user_version")
                if applicationID == 0 && version == 0 {
                    // In particular, never adopt the V23 recording database or an unrelated SQLite file.
                    guard try scalar("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0 else {
                        throw ContextStoreError.incompatibleDatabase
                    }
                    try execute(Self.schema)
                    try execute(Self.spokenSchema)
                    try execute(Self.contextProvenanceSchema)
                    try execute(Self.companionCandidateSchema)
                    try execute(Self.audioSessionSettingsSchema)
                    let id = UUID()
                    try run("INSERT INTO context_metadata(singleton, context_store_id, native_store_id) VALUES(1,?,?)",
                            [.text(id.uuidString), .text(nativeStoreID.uuidString)])
                    try execute("PRAGMA application_id=\(Self.applicationID)")
                    try execute("PRAGMA user_version=\(Self.schemaVersion)")
                    return id
                }
                guard applicationID == Self.applicationID, (1...Self.schemaVersion).contains(version) else {
                    throw ContextStoreError.incompatibleDatabase
                }
                let statement = try prepare("SELECT context_store_id,native_store_id FROM context_metadata WHERE singleton=1")
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW,
                      let id = UUID(uuidString: try textColumn(statement, 0)),
                      let nativeID = UUID(uuidString: try textColumn(statement, 1)) else {
                    throw ContextStoreError.incompatibleDatabase
                }
                guard nativeID == nativeStoreID else { throw ContextStoreError.nativeStoreMismatch }
                if version == 1 {
                    try execute(Self.spokenSchema)
                }
                if version < 3 { try execute(Self.contextProvenanceSchema) }
                if version < 4 { try execute(Self.companionCandidateSchema) }
                if version < 5 { try execute(Self.audioSessionSettingsSchema) }
                if version < Self.schemaVersion { try execute("PRAGMA user_version=\(Self.schemaVersion)") }
                return id
            }
            // Only change journaling after identity/schema checks have accepted this file.
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            identity = storedIdentity
        } catch {
            sqlite3_close_v2(opened)
            connection = nil
            identity = nil
            throw error
        }
    }

    public func close() throws {
        if terminallyClosed { return }
        if let connection {
            guard sqlite3_close(connection) == SQLITE_OK else { throw databaseError("close context database") }
        }
        connection = nil
        identity = nil
        terminallyClosed = true
    }

    public func contextStoreID() throws -> UUID {
        try requireInitialized()
        guard let identity else { throw ContextStoreError.notInitialized }
        return identity
    }

    public func createManualMarker(_ command: ManualTimelineMarkerCommand) throws -> TimelineMarker {
        try requireInitialized()
        try validate(command)
        let payload = try encode(command)
        let digest = Data(SHA256.hash(data: payload))
        return try transaction {
            let statement = try prepare("SELECT payload_digest,outcome FROM marker_commands WHERE client_id=? AND request_id=?",
                                        [.text(command.clientID), .text(command.requestID.uuidString)])
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                guard try blobColumn(statement, 0) == digest else { throw ContextStoreError.requestConflict }
                return try decode(TimelineMarker.self, data: blobColumn(statement, 1))
            }
            guard result == SQLITE_DONE else { throw databaseError("read marker command") }
            let marker = TimelineMarker(id: UUID(), revision: UUID(), nativeStoreID: nativeStoreID,
                anchoredAt: command.anchoredAt, title: command.title, note: command.note,
                screenReference: command.screenReference, createdAt: Date())
            let outcome = try encode(marker)
            try run("INSERT INTO timeline_markers(id,anchored_at,deleted_at,payload) VALUES(?,?,NULL,?)",
                    [.text(marker.id.uuidString), .real(marker.anchoredAt.timeIntervalSince1970), .blob(outcome)])
            try run("INSERT INTO marker_commands(client_id,request_id,payload_digest,outcome) VALUES(?,?,?,?)",
                    [.text(command.clientID), .text(command.requestID.uuidString), .blob(digest), .blob(outcome)])
            return marker
        }
    }

    public func updateMarker(_ command: TimelineMarkerEditCommand) throws -> TimelineMarker {
        try requireInitialized()
        try validateText(command.clientID, maximumBytes: 128)
        try validateText(command.title, maximumBytes: 1_024)
        if let note = command.note { try validateText(note, maximumBytes: 16_384, allowEmpty: true) }
        // The operation prefix prevents a request UUID shared with a creation
        // command from being treated as the same request across operation types.
        var payload = Data("marker.update\0".utf8)
        payload.append(try encode(command))
        let digest = Data(SHA256.hash(data: payload))
        return try transaction {
            let statement = try prepare("SELECT payload_digest,outcome FROM marker_commands WHERE client_id=? AND request_id=?",
                [.text(command.clientID), .text(command.requestID.uuidString)])
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                guard try blobColumn(statement, 0) == digest else { throw ContextStoreError.requestConflict }
                return try decode(TimelineMarker.self, data: blobColumn(statement, 1))
            }
            guard status == SQLITE_DONE else { throw databaseError("read marker edit receipt") }
            guard let current = try marker(id: command.id, includeDeleted: false) else { throw ContextStoreError.markerNotFound }
            guard current.revision == command.expectedRevision else { throw ContextStoreError.revisionConflict }
            let saved = TimelineMarker(id: current.id, revision: UUID(), nativeStoreID: current.nativeStoreID,
                anchoredAt: current.anchoredAt, title: command.title, note: command.note,
                screenReference: current.screenReference, createdAt: current.createdAt,
                spokenObservation: current.spokenObservation, userEditedAt: Date())
            let outcome = try encode(saved)
            try run("UPDATE timeline_markers SET payload=? WHERE id=?", [.blob(outcome), .text(saved.id.uuidString)])
            try run("INSERT INTO marker_commands(client_id,request_id,payload_digest,outcome) VALUES(?,?,?,?)",
                [.text(command.clientID), .text(command.requestID.uuidString), .blob(digest), .blob(outcome)])
            return saved
        }
    }

    public func marker(id: UUID, includeDeleted: Bool) throws -> TimelineMarker? {
        try requireInitialized()
        let suffix = includeDeleted ? "" : " AND deleted_at IS NULL AND (spoken_state IS NULL OR spoken_state!='withdrawn')"
        return try readOne(TimelineMarker.self, sql: "SELECT payload FROM timeline_markers WHERE id=?" + suffix,
                           bindings: [.text(id.uuidString)])
    }

    public func listMarkers(_ query: TimelineMarkerQuery) throws -> TimelineMarkerPage {
        try requireInitialized()
        guard (1...200).contains(query.limit) else { throw ContextStoreError.invalidInput }
        try validateDate(query.from); try validateDate(query.to); try validateDate(query.before?.anchoredAt)
        if let from = query.from, let to = query.to, from > to { throw ContextStoreError.invalidInput }
        var predicates = [String]()
        var bindings = [Binding]()
        if !query.includeDeleted { predicates.append("deleted_at IS NULL AND (spoken_state IS NULL OR spoken_state!='withdrawn')") }
        if let from = query.from { predicates.append("anchored_at>=?"); bindings.append(.real(from.timeIntervalSince1970)) }
        if let to = query.to { predicates.append("anchored_at<=?"); bindings.append(.real(to.timeIntervalSince1970)) }
        if let before = query.before {
            predicates.append("(anchored_at,id)<(?,?)")
            bindings += [.real(before.anchoredAt.timeIntervalSince1970), .text(before.id.uuidString)]
        }
        let whereClause = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        bindings.append(.integer(query.limit + 1))
        var markers = try readMany(TimelineMarker.self,
            sql: "SELECT payload FROM timeline_markers" + whereClause + " ORDER BY anchored_at DESC,id DESC LIMIT ?",
            bindings: bindings)
        let hasMore = markers.count > query.limit
        if hasMore { markers.removeLast() }
        let cursor = hasMore ? markers.last.map { TimelineMarkerCursor(anchoredAt: $0.anchoredAt, id: $0.id) } : nil
        return TimelineMarkerPage(markers: markers, nextCursor: cursor)
    }

    public func setMarkerDeleted(id: UUID, expectedRevision: UUID, deleted: Bool) throws -> TimelineMarker {
        try requireInitialized()
        return try transaction {
            guard let current = try marker(id: id, includeDeleted: true) else { throw ContextStoreError.markerNotFound }
            guard current.revision == expectedRevision else { throw ContextStoreError.revisionConflict }
            let changed = TimelineMarker(id: current.id, revision: UUID(), nativeStoreID: current.nativeStoreID,
                anchoredAt: current.anchoredAt, title: current.title, note: current.note,
                screenReference: current.screenReference, createdAt: current.createdAt,
                deletedAt: deleted ? Date() : nil, spokenObservation: current.spokenObservation, userEditedAt: current.userEditedAt)
            try run("UPDATE timeline_markers SET deleted_at=?,payload=? WHERE id=?",
                [changed.deletedAt.map { .real($0.timeIntervalSince1970) } ?? .null, .blob(try encode(changed)), .text(id.uuidString)])
            if deleted, let observation = current.spokenObservation {
                try run("UPDATE spoken_occurrences SET user_suppressed=1 WHERE occurrence_id=?", [.text(observation.occurrenceID.uuidString)])
            }
            return changed
        }
    }

    public func saveKeywordRule(_ rule: KeywordRule, expectedRevision: UUID?) throws -> KeywordRule {
        try requireInitialized()
        try validateText(rule.phrase, maximumBytes: 256)
        try validateText(rule.name, maximumBytes: 256)
        try validateText(rule.meaning, maximumBytes: 4_096, allowEmpty: true)
        guard rule.aliases.count <= 16, Set(rule.aliases).count == rule.aliases.count,
              !rule.aliases.contains(rule.phrase) else { throw ContextStoreError.invalidInput }
        for alias in rule.aliases { try validateText(alias, maximumBytes: 256) }
        return try transaction {
            let current = try readOne(KeywordRule.self, sql: "SELECT payload FROM keyword_rules WHERE id=?", bindings: [.text(rule.id.uuidString)])
            guard current?.revision == expectedRevision else { throw ContextStoreError.revisionConflict }
            let saved = KeywordRule(id: rule.id, revision: UUID(), phrase: rule.phrase, aliases: rule.aliases,
                                   name: rule.name, meaning: rule.meaning, enabled: rule.enabled, action: rule.action)
            try run("INSERT INTO keyword_rules(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
                    [.text(saved.id.uuidString), .blob(try encode(saved))])
            return saved
        }
    }

    public func listKeywordRules(afterID: UUID?, limit: Int) throws -> [KeywordRule] {
        try requireInitialized()
        guard (1...100).contains(limit) else { throw ContextStoreError.invalidInput }
        let predicate = afterID == nil ? "" : " WHERE id>?"
        let bindings: [Binding] = (afterID.map { [.text($0.uuidString)] } ?? []) + [.integer(limit)]
        return try readMany(KeywordRule.self, sql: "SELECT payload FROM keyword_rules" + predicate + " ORDER BY id LIMIT ?", bindings: bindings)
    }

    public func saveContextRange(markerID: UUID, range: MarkerContextRange, expectedRevision: UUID?, expectedMarkerRevision: UUID? = nil) throws -> MarkerContextRange {
        try requireInitialized()
        try validateDate(range.start); try validateDate(range.end)
        guard range.start <= range.end else { throw ContextStoreError.invalidInput }
        try validateText(range.explanation, maximumBytes: 4_096)
        if let note = range.userNote { try validateText(note, maximumBytes: 4_096, allowEmpty: true) }
        return try transaction {
            guard let active = try marker(id: markerID, includeDeleted: false) else { throw ContextStoreError.markerNotFound }
            if let expectedMarkerRevision, active.revision != expectedMarkerRevision { throw ContextStoreError.revisionConflict }
            let current = try readOne(MarkerContextRange.self,
                sql: "SELECT payload FROM marker_context_ranges WHERE marker_id=? AND id=?",
                bindings: [.text(markerID.uuidString), .text(range.id.uuidString)])
            guard current?.revision == expectedRevision else { throw ContextStoreError.revisionConflict }
            if let current, current.ownership != .proposed, range.ownership == .proposed {
                throw ContextStoreError.protectedContextRange
            }
            if let current, current.effectiveExplanationOrigin != .userAuthored,
               range.explanation != current.explanation { throw ContextStoreError.invalidInput }
            let alreadyActive = try scalar("SELECT EXISTS(SELECT 1 FROM marker_context_ranges WHERE marker_id=? AND id=? AND active=1)",
                [.text(markerID.uuidString), .text(range.id.uuidString)]) != 0
            if !alreadyActive {
                guard try scalar("SELECT count(*) FROM marker_context_ranges WHERE marker_id=? AND active=1", [.text(markerID.uuidString)]) < 64 else {
                    throw ContextStoreError.capacityExceeded
                }
            }
            if let current { try retainInitialRange(markerID: markerID, range: current) }
            let saved = MarkerContextRange(id: range.id, revision: UUID(), start: range.start, end: range.end,
                explanation: current?.effectiveExplanationOrigin == .userAuthored || current == nil ? range.explanation : current!.explanation,
                ownership: range.ownership,
                explanationOrigin: current?.effectiveExplanationOrigin ?? (range.ownership == .proposed ? .legacyUnverified : .userAuthored),
                provenance: current?.provenance, userNote: range.userNote ?? current?.userNote)
            try run("""
                INSERT INTO marker_context_ranges(marker_id,id,starts_at,payload,active) VALUES(?,?,?,?,1)
                ON CONFLICT(marker_id,id) DO UPDATE SET starts_at=excluded.starts_at,payload=excluded.payload,active=1
                """, [.text(markerID.uuidString), .text(saved.id.uuidString), .real(saved.start.timeIntervalSince1970), .blob(try encode(saved))])
            try appendContextRangeRevision(markerID: markerID, range: saved, state: .active)
            return saved
        }
    }

    public func listContextRanges(markerID: UUID, limit: Int) throws -> [MarkerContextRange] {
        try requireInitialized()
        guard (1...64).contains(limit) else { throw ContextStoreError.invalidInput }
        guard try marker(id: markerID, includeDeleted: false) != nil else { throw ContextStoreError.markerNotFound }
        return try readMany(MarkerContextRange.self,
            sql: "SELECT payload FROM marker_context_ranges WHERE marker_id=? AND active=1 ORDER BY starts_at,id LIMIT ?",
            bindings: [.text(markerID.uuidString), .integer(limit)])
    }

    private func validate(_ command: ManualTimelineMarkerCommand) throws {
        try validateText(command.clientID, maximumBytes: 128)
        try validateDate(command.anchoredAt)
        try validateText(command.title, maximumBytes: 1_024)
        if let note = command.note { try validateText(note, maximumBytes: 16_384, allowEmpty: true) }
        if let ref = command.screenReference {
            guard ref.source == .native, ref.storeID == nativeStoreID, ref.frameID.value > 0,
                  ref.extractionRevision > 0, ref.blockIDs.count <= 256,
                  ref.blockIDs.allSatisfy({ $0 >= 0 }), Set(ref.blockIDs).count == ref.blockIDs.count else {
                throw ContextStoreError.invalidInput
            }
        }
    }

    private func validateText(_ text: String, maximumBytes: Int, allowEmpty: Bool = false) throws {
        guard text.utf8.count <= maximumBytes, !text.contains("\0"),
              allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ContextStoreError.invalidInput }
    }

    private func validateDate(_ date: Date?) throws {
        if let date, !date.timeIntervalSince1970.isFinite { throw ContextStoreError.invalidInput }
    }

    func requireInitialized() throws {
        guard !terminallyClosed else { throw ContextStoreError.closed }
        guard connection != nil, identity != nil else { throw ContextStoreError.notInitialized }
        try Task.checkCancellation()
    }

    enum Binding { case text(String), blob(Data), real(Double), integer(Int), int64(Int64), null }

    func prepare(_ sql: String, _ bindings: [Binding] = []) throws -> OpaquePointer {
        guard let connection else { throw ContextStoreError.notInitialized }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError(sql)
        }
        do {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, value) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let status: Int32
                switch value {
                case .text(let text): status = sqlite3_bind_text(statement, index, text, -1, transient)
                case .blob(let data): status = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
                case .real(let value): status = sqlite3_bind_double(statement, index, value)
                case .integer(let value): status = sqlite3_bind_int64(statement, index, Int64(value))
                case .int64(let value): status = sqlite3_bind_int64(statement, index, value)
                case .null: status = sqlite3_bind_null(statement, index)
                }
                guard status == SQLITE_OK else { throw databaseError("bind context statement") }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }

    func run(_ sql: String, _ bindings: [Binding] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(sql) }
    }

    private func execute(_ sql: String) throws {
        guard let connection else { throw ContextStoreError.notInitialized }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError(sql) }
    }

    func scalar(_ sql: String, _ bindings: [Binding] = []) throws -> Int {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError(sql) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func readOne<T: Decodable>(_ type: T.Type, sql: String, bindings: [Binding]) throws -> T? {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { try Task.checkCancellation(); return nil }
        guard status == SQLITE_ROW else { throw databaseError(sql) }
        let result = try decode(type, data: blobColumn(statement, 0))
        try Task.checkCancellation()
        return result
    }

    private func readMany<T: Decodable>(_ type: T.Type, sql: String, bindings: [Binding]) throws -> [T] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var values = [T]()
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { try Task.checkCancellation(); return values }
            guard status == SQLITE_ROW else { throw databaseError(sql) }
            values.append(try decode(type, data: blobColumn(statement, 0)))
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try Task.checkCancellation()
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try Task.checkCancellation()
            try execute("COMMIT")
            return result
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumPayloadBytes else { throw ContextStoreError.invalidInput }
        return data
    }

    func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }

    func blobColumn(_ statement: OpaquePointer, _ column: Int32, limit: Int = 65_536) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard (1...limit).contains(count), let bytes = sqlite3_column_blob(statement, column) else {
            throw ContextStoreError.incompatibleDatabase
        }
        return Data(bytes: bytes, count: count)
    }

    func textColumn(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard sqlite3_column_bytes(statement, column) <= 128, let text = sqlite3_column_text(statement, column) else {
            throw ContextStoreError.incompatibleDatabase
        }
        return String(cString: text)
    }

    private func databaseError(_ operation: String) -> DatabaseError {
        DatabaseError.queryFailed(query: operation,
            underlying: connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Context database unavailable")
    }

    private static let schema = """
        CREATE TABLE context_metadata (
            singleton INTEGER PRIMARY KEY CHECK(singleton=1), context_store_id TEXT NOT NULL, native_store_id TEXT NOT NULL
        );
        CREATE TABLE timeline_markers (id TEXT PRIMARY KEY, anchored_at REAL NOT NULL, deleted_at REAL, payload BLOB NOT NULL);
        CREATE INDEX timeline_markers_time ON timeline_markers(anchored_at DESC,id DESC);
        CREATE INDEX timeline_markers_active_time ON timeline_markers(anchored_at DESC,id DESC) WHERE deleted_at IS NULL;
        CREATE TABLE marker_commands (
            client_id TEXT NOT NULL, request_id TEXT NOT NULL, payload_digest BLOB NOT NULL, outcome BLOB NOT NULL,
            PRIMARY KEY(client_id,request_id)
        ) WITHOUT ROWID;
        CREATE TABLE keyword_rules (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
        CREATE TABLE marker_context_ranges (
            marker_id TEXT NOT NULL REFERENCES timeline_markers(id), id TEXT NOT NULL, starts_at REAL NOT NULL, payload BLOB NOT NULL,
            PRIMARY KEY(marker_id,id)
        ) WITHOUT ROWID;
        CREATE INDEX marker_context_ranges_time ON marker_context_ranges(marker_id,starts_at,id);
        """

    /// Additive context-only migration. Existing manual payloads decode without spoken provenance.
    private static let spokenSchema = """
        ALTER TABLE timeline_markers ADD COLUMN spoken_state TEXT;
        CREATE TABLE spoken_occurrences (
            occurrence_id TEXT PRIMARY KEY, marker_id TEXT NOT NULL UNIQUE REFERENCES timeline_markers(id),
            latest_revision TEXT NOT NULL, confirmed_anchor BLOB, user_suppressed INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE spoken_observations (
            sequence INTEGER PRIMARY KEY, occurrence_id TEXT NOT NULL REFERENCES spoken_occurrences(occurrence_id),
            revision TEXT NOT NULL UNIQUE, payload BLOB NOT NULL
        );
        CREATE INDEX spoken_observations_history ON spoken_observations(occurrence_id,sequence);
        CREATE TRIGGER spoken_observations_immutable_update BEFORE UPDATE ON spoken_observations
            BEGIN SELECT RAISE(ABORT,'Spoken observations are immutable'); END;
        CREATE TRIGGER spoken_observations_immutable_delete BEFORE DELETE ON spoken_observations
            BEGIN SELECT RAISE(ABORT,'Spoken observations are immutable'); END;
        CREATE TABLE spoken_commands (
            client_id TEXT NOT NULL, request_id TEXT NOT NULL, payload_digest BLOB NOT NULL, outcome BLOB NOT NULL,
            PRIMARY KEY(client_id,request_id)
        ) WITHOUT ROWID;
        CREATE TABLE audio_media_manifests (
            id TEXT PRIMARY KEY, relative_path TEXT NOT NULL UNIQUE, payload_digest BLOB NOT NULL, payload BLOB NOT NULL
        );
        CREATE TABLE audio_media_ranges (
            manifest_id TEXT NOT NULL REFERENCES audio_media_manifests(id), ordinal INTEGER NOT NULL,
            recording_generation TEXT NOT NULL, continuity_id TEXT NOT NULL, start_sample INTEGER NOT NULL,
            end_sample INTEGER NOT NULL, approximate_origin REAL NOT NULL, batch_start_sample INTEGER NOT NULL,
            PRIMARY KEY(manifest_id,ordinal)
        ) WITHOUT ROWID;
        CREATE INDEX audio_media_ranges_source ON audio_media_ranges(recording_generation,continuity_id,start_sample,end_sample);
        """
}

extension ContextDatabase {
    public func applySpokenObservation(_ command: SpokenObservationCommand) throws -> SpokenMarkerReceipt {
        try requireInitialized()
        try validateSpokenCommand(command)
        let digest = Data(SHA256.hash(data: try encode(command)))
        return try transaction {
            if let receipt = try spokenCommandReceipt(command, digest: digest) { return receipt }
            let occurrence = try loadSpokenOccurrence(command.occurrenceID)
            guard occurrence?.latestRevision == command.expectedRevision else { throw ContextStoreError.revisionConflict }
            let current = try spokenMarkerState(occurrenceID: command.occurrenceID)
            guard (occurrence == nil) == (current == nil) else { throw ContextStoreError.incompatibleDatabase }
            if let current {
                guard current.observation.ruleSnapshot == command.ruleSnapshot else { throw ContextStoreError.ruleUnavailable }
                let prior = current.observation.anchor
                guard prior.recordingGeneration == command.anchor.recordingGeneration,
                      prior.continuityID == command.anchor.continuityID,
                      prior.approximateOrigin == command.anchor.approximateOrigin else { throw ContextStoreError.invalidInput }
            } else {
                let storedRule = try readOne(KeywordRule.self, sql: "SELECT payload FROM keyword_rules WHERE id=?",
                                             bindings: [.text(command.ruleSnapshot.id.uuidString)])
                guard storedRule == command.ruleSnapshot, command.ruleSnapshot.enabled else { throw ContextStoreError.ruleUnavailable }
            }
            if let fixed = occurrence?.confirmedAnchor {
                guard fixed == command.anchor else { throw ContextStoreError.confirmedAnchorConflict }
                guard command.status != .provisional else { throw ContextStoreError.revisionConflict }
            }
            let lastSequence = try scalar("SELECT COALESCE(MAX(sequence),0) FROM spoken_observations")
            guard lastSequence < Int.max else { throw ContextStoreError.capacityExceeded }
            let observation = SpokenMarkerObservation(occurrenceID: command.occurrenceID, revision: UUID(),
                sequence: Int64(lastSequence + 1), status: command.status, anchor: command.anchor,
                ruleSnapshot: command.ruleSnapshot, matchedPhrase: command.matchedPhrase,
                explanation: command.explanation, recordedAt: Date())
            let suppressed = occurrence?.suppressed ?? false
            let projected: TimelineMarker
            if suppressed, let current { projected = current.marker }
            else {
                projected = TimelineMarker(id: current?.marker.id ?? UUID(), revision: UUID(), nativeStoreID: nativeStoreID,
                    anchoredAt: command.anchor.approximateStart,
                    title: current?.marker.userEditedAt == nil ? command.ruleSnapshot.name : current!.marker.title,
                    note: current?.marker.userEditedAt == nil ? command.explanation : current!.marker.note,
                    screenReference: nil, createdAt: current?.marker.createdAt ?? observation.recordedAt,
                    spokenObservation: observation, userEditedAt: current?.marker.userEditedAt)
                try run("""
                    INSERT INTO timeline_markers(id,anchored_at,deleted_at,payload,spoken_state) VALUES(?,?,NULL,?,?)
                    ON CONFLICT(id) DO UPDATE SET anchored_at=excluded.anchored_at,payload=excluded.payload,spoken_state=excluded.spoken_state
                    """, [.text(projected.id.uuidString), .real(projected.anchoredAt.timeIntervalSince1970),
                          .blob(try encode(projected)), .text(command.status.rawValue)])
            }
            let fixedAnchor = occurrence?.confirmedAnchor ?? (command.status == .confirmed ? command.anchor : nil)
            try run("""
                INSERT INTO spoken_occurrences(occurrence_id,marker_id,latest_revision,confirmed_anchor,user_suppressed) VALUES(?,?,?,?,?)
                ON CONFLICT(occurrence_id) DO UPDATE SET latest_revision=excluded.latest_revision,confirmed_anchor=excluded.confirmed_anchor
                """, [.text(command.occurrenceID.uuidString), .text(projected.id.uuidString), .text(observation.revision.uuidString),
                      try fixedAnchor.map { .blob(try encode($0)) } ?? .null, .integer(suppressed ? 1 : 0)])
            try run("INSERT INTO spoken_observations(sequence,occurrence_id,revision,payload) VALUES(?,?,?,?)",
                    [.int64(observation.sequence), .text(command.occurrenceID.uuidString), .text(observation.revision.uuidString), .blob(try encode(observation))])
            let receipt = SpokenMarkerReceipt(observation: observation, marker: projected, suppressed: suppressed)
            try run("INSERT INTO spoken_commands(client_id,request_id,payload_digest,outcome) VALUES(?,?,?,?)",
                    [.text(command.clientID), .text(command.requestID.uuidString), .blob(digest), .blob(try encode(receipt))])
            return receipt
        }
    }

    public func spokenMarkerState(occurrenceID: UUID) throws -> SpokenMarkerReceipt? {
        try requireInitialized()
        let statement = try prepare("""
            SELECT o.payload,m.payload,c.user_suppressed FROM spoken_occurrences c
            JOIN spoken_observations o ON o.revision=c.latest_revision
            JOIN timeline_markers m ON m.id=c.marker_id WHERE c.occurrence_id=?
            """, [.text(occurrenceID.uuidString)])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { try Task.checkCancellation(); return nil }
        guard status == SQLITE_ROW else { throw databaseError("read spoken marker state") }
        let result = SpokenMarkerReceipt(observation: try decode(SpokenMarkerObservation.self, data: blobColumn(statement, 0)),
            marker: try decode(TimelineMarker.self, data: blobColumn(statement, 1)), suppressed: sqlite3_column_int(statement, 2) != 0)
        try Task.checkCancellation()
        return result
    }

    public func spokenObservation(occurrenceID: UUID) throws -> SpokenMarkerObservation? {
        try requireInitialized()
        return try readOne(SpokenMarkerObservation.self, sql: """
            SELECT o.payload FROM spoken_occurrences c JOIN spoken_observations o ON o.revision=c.latest_revision WHERE c.occurrence_id=?
            """, bindings: [.text(occurrenceID.uuidString)])
    }

    public func spokenObservations(occurrenceID: UUID, afterSequence: Int64, limit: Int) throws -> [SpokenMarkerObservation] {
        try requireInitialized()
        guard afterSequence >= 0, (1...200).contains(limit) else { throw ContextStoreError.invalidInput }
        return try readMany(SpokenMarkerObservation.self,
            sql: "SELECT payload FROM spoken_observations WHERE occurrence_id=? AND sequence>? ORDER BY sequence LIMIT ?",
            bindings: [.text(occurrenceID.uuidString), .int64(afterSequence), .integer(limit)])
    }

    public func registerAudioManifest(_ manifest: AudioMediaManifest) throws -> AudioMediaManifest {
        try requireInitialized()
        try validateManifest(manifest)
        let payload = try encode(manifest)
        let digest = Data(SHA256.hash(data: payload))
        return try transaction {
            if let current = try mediaManifestReceipt(manifest.id, digest: digest) { return current }
            guard try scalar("SELECT count(*) FROM audio_media_manifests WHERE relative_path=?", [.text(manifest.relativePath)]) == 0 else {
                throw ContextStoreError.mediaMappingConflict
            }
            for range in manifest.sourceRanges {
                // Several original files deliberately retain overlapping five-second tails.
                // Preserve all alternatives while refusing a conflicting origin for the same continuity.
                let conflicts = try scalar("""
                    SELECT EXISTS(SELECT 1 FROM audio_media_ranges
                    WHERE recording_generation=? AND continuity_id=? AND approximate_origin!=? LIMIT 1)
                    """, [.text(range.source.recordingGeneration.uuidString), .text(range.source.continuityID.uuidString),
                          .real(range.source.approximateOrigin.timeIntervalSince1970)])
                guard conflicts == 0 else { throw ContextStoreError.mediaMappingConflict }
            }
            try run("INSERT INTO audio_media_manifests(id,relative_path,payload_digest,payload) VALUES(?,?,?,?)",
                    [.text(manifest.id.uuidString), .text(manifest.relativePath), .blob(digest), .blob(payload)])
            for (ordinal, range) in manifest.sourceRanges.enumerated() {
                try run("""
                    INSERT INTO audio_media_ranges(manifest_id,ordinal,recording_generation,continuity_id,start_sample,end_sample,approximate_origin,batch_start_sample)
                    VALUES(?,?,?,?,?,?,?,?)
                    """, [.text(manifest.id.uuidString), .integer(ordinal), .text(range.source.recordingGeneration.uuidString),
                          .text(range.source.continuityID.uuidString), .int64(range.source.startSample),
                          .int64(range.source.startSample + range.source.sampleCount),
                          .real(range.source.approximateOrigin.timeIntervalSince1970), .int64(range.batchStartSample)])
            }
            try enrollCompanionManifest(manifest)
            return manifest
        }
    }

    public func audioManifest(relativePath: String) async throws -> AudioMediaManifest? {
        try requireInitialized()
        guard !relativePath.isEmpty, relativePath.utf8.count <= 1024, !relativePath.contains("\0") else { throw ContextStoreError.invalidInput }
        return try readMany(AudioMediaManifest.self,
            sql: "SELECT payload FROM audio_media_manifests WHERE relative_path=? LIMIT 1", bindings: [.text(relativePath)]).first
    }

    public func audioManifests(intersecting anchor: SpokenMarkerAnchor, limit: Int) throws -> [AudioMediaManifest] {
        try requireInitialized()
        try validateAnchor(anchor)
        guard (1...100).contains(limit) else { throw ContextStoreError.invalidInput }
        return try readMany(AudioMediaManifest.self, sql: """
            SELECT m.payload FROM audio_media_ranges r JOIN audio_media_manifests m ON m.id=r.manifest_id
            WHERE r.recording_generation=? AND r.continuity_id=? AND r.start_sample<? AND r.end_sample>?
            AND r.approximate_origin=? GROUP BY m.id ORDER BY m.id LIMIT ?
            """, bindings: [.text(anchor.recordingGeneration.uuidString), .text(anchor.continuityID.uuidString),
                              .int64(anchor.endSample), .int64(anchor.startSample),
                              .real(anchor.approximateOrigin.timeIntervalSince1970), .integer(limit)])
    }

    public func audioManifests(intersecting range: NativeAudioSampleRange, limit: Int) async throws -> [AudioMediaManifest] {
        try requireInitialized()
        guard range.nativeStoreID == nativeStoreID, range.source == .microphone,
              range.identity.isValid, (1...100).contains(limit) else { throw ContextStoreError.invalidInput }
        let source = range.identity
        // Generation/continuity/sample coordinates are exact. The App compares canonical
        // wire origins after decoding; a persisted Date can differ from wire by one ULP.
        return try readMany(AudioMediaManifest.self, sql: """
            SELECT m.payload FROM audio_media_ranges r JOIN audio_media_manifests m ON m.id=r.manifest_id
            WHERE r.recording_generation=? AND r.continuity_id=? AND r.start_sample<? AND r.end_sample>?
            GROUP BY m.id ORDER BY m.id LIMIT ?
            """, bindings: [.text(source.recordingGeneration.uuidString), .text(source.continuityID.uuidString),
                              .int64(source.startSample + source.sampleCount), .int64(source.startSample), .integer(limit)])
    }

    private struct SpokenOccurrence {
        let latestRevision: UUID
        let confirmedAnchor: SpokenMarkerAnchor?
        let suppressed: Bool
    }

    private func loadSpokenOccurrence(_ id: UUID) throws -> SpokenOccurrence? {
        let statement = try prepare("SELECT latest_revision,confirmed_anchor,user_suppressed FROM spoken_occurrences WHERE occurrence_id=?", [.text(id.uuidString)])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let revision = UUID(uuidString: try textColumn(statement, 0)) else {
            throw ContextStoreError.incompatibleDatabase
        }
        let anchor = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : try decode(SpokenMarkerAnchor.self, data: blobColumn(statement, 1))
        return SpokenOccurrence(latestRevision: revision, confirmedAnchor: anchor, suppressed: sqlite3_column_int(statement, 2) != 0)
    }

    private func spokenCommandReceipt(_ command: SpokenObservationCommand, digest: Data) throws -> SpokenMarkerReceipt? {
        let statement = try prepare("SELECT payload_digest,outcome FROM spoken_commands WHERE client_id=? AND request_id=?",
                                    [.text(command.clientID), .text(command.requestID.uuidString)])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw databaseError("read spoken command receipt") }
        guard try blobColumn(statement, 0) == digest else { throw ContextStoreError.requestConflict }
        return try decode(SpokenMarkerReceipt.self, data: blobColumn(statement, 1))
    }

    private func mediaManifestReceipt(_ id: UUID, digest: Data) throws -> AudioMediaManifest? {
        let statement = try prepare("SELECT payload_digest,payload FROM audio_media_manifests WHERE id=?", [.text(id.uuidString)])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw databaseError("read media manifest") }
        guard try blobColumn(statement, 0) == digest else { throw ContextStoreError.requestConflict }
        return try decode(AudioMediaManifest.self, data: blobColumn(statement, 1))
    }

    private func validateSpokenCommand(_ command: SpokenObservationCommand) throws {
        try validateText(command.clientID, maximumBytes: 128)
        try validateText(command.matchedPhrase, maximumBytes: 256)
        try validateText(command.explanation, maximumBytes: 4_096, allowEmpty: true)
        try validateAnchor(command.anchor)
        try validateText(command.ruleSnapshot.phrase, maximumBytes: 256)
        try validateText(command.ruleSnapshot.name, maximumBytes: 256)
        try validateText(command.ruleSnapshot.meaning, maximumBytes: 4_096, allowEmpty: true)
        guard command.ruleSnapshot.aliases.count <= 16 else { throw ContextStoreError.invalidInput }
        for alias in command.ruleSnapshot.aliases { try validateText(alias, maximumBytes: 256) }
        let normalise: (String) -> String = {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let phrase = normalise(command.matchedPhrase)
        guard command.ruleSnapshot.enabled,
              ([command.ruleSnapshot.phrase] + command.ruleSnapshot.aliases).contains(where: { normalise($0) == phrase }) else {
            throw ContextStoreError.ruleUnavailable
        }
    }

    private func validateAnchor(_ anchor: SpokenMarkerAnchor) throws {
        guard anchor.nativeStoreID == nativeStoreID, anchor.source == .microphone, anchor.sampleRate == 16_000,
              anchor.startSample >= 0, anchor.endSample > anchor.startSample,
              anchor.endSample - anchor.startSample <= 16_000 * 60,
              anchor.approximateOrigin.timeIntervalSince1970.isFinite,
              anchor.approximateStart.timeIntervalSince1970.isFinite else { throw ContextStoreError.invalidInput }
    }

    private func validateManifest(_ manifest: AudioMediaManifest) throws {
        guard manifest.nativeStoreID == nativeStoreID, manifest.source == .microphone, manifest.sampleRate == 16_000,
              manifest.frameCount > 0, manifest.frameCount <= 16_000 * 3_600,
              (1...256).contains(manifest.sourceRanges.count), manifest.sha256.utf8.count == 64,
              manifest.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ContextStoreError.invalidInput
        }
        try validateText(manifest.relativePath, maximumBytes: 2_048)
        let components = manifest.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first == "audio", components.count >= 2,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !manifest.relativePath.contains("\\"),
              manifest.relativePath.hasSuffix(".m4a") || manifest.relativePath.hasSuffix(".aac") else {
            throw ContextStoreError.invalidInput
        }
        var previousBatchEnd: Int64 = 0
        var seen = [String: [LiveAudioSampleIdentity]]()
        for range in manifest.sourceRanges {
            let source = range.source
            guard source.isValid, range.batchStartSample >= previousBatchEnd,
                  range.batchStartSample <= manifest.frameCount,
                  source.sampleCount <= manifest.frameCount - range.batchStartSample else { throw ContextStoreError.invalidInput }
            previousBatchEnd = range.batchStartSample + source.sampleCount
            let key = source.recordingGeneration.uuidString + source.continuityID.uuidString
            for other in seen[key, default: []] {
                guard other.approximateOrigin == source.approximateOrigin,
                      source.startSample >= other.startSample + other.sampleCount ||
                        other.startSample >= source.startSample + source.sampleCount else { throw ContextStoreError.mediaMappingConflict }
            }
            seen[key, default: []].append(source)
        }
    }
}

// Context-only V3: immutable proposal receipts and revision history, with a separate active projection.
extension ContextDatabase {
    private static let contextProvenanceSchema = """
        ALTER TABLE marker_context_ranges ADD COLUMN active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0,1));
        CREATE INDEX context_ranges_active ON marker_context_ranges(marker_id,active,starts_at,id);
        CREATE TABLE context_range_revisions (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT, marker_id TEXT NOT NULL, range_id TEXT NOT NULL,
            state TEXT NOT NULL, payload BLOB NOT NULL, recorded_at REAL NOT NULL
        );
        CREATE INDEX context_range_history ON context_range_revisions(marker_id,sequence);
        CREATE INDEX context_range_identity ON context_range_revisions(marker_id,range_id);
        CREATE TABLE context_proposals (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT, job_id TEXT NOT NULL UNIQUE,
            marker_id TEXT NOT NULL, proposal_revision TEXT NOT NULL UNIQUE, marker_revision TEXT NOT NULL,
            payload_digest BLOB NOT NULL, result_sha TEXT NOT NULL, request_payload BLOB NOT NULL,
            result_payload BLOB NOT NULL, receipt BLOB
        );
        CREATE TABLE context_proposal_heads (marker_id TEXT PRIMARY KEY, payload BLOB NOT NULL);
        CREATE TRIGGER context_range_history_no_update BEFORE UPDATE ON context_range_revisions BEGIN SELECT RAISE(ABORT,'immutable context history'); END;
        CREATE TRIGGER context_range_history_no_delete BEFORE DELETE ON context_range_revisions BEGIN SELECT RAISE(ABORT,'immutable context history'); END;
        CREATE TRIGGER context_proposals_no_update BEFORE UPDATE ON context_proposals WHEN OLD.receipt IS NOT NULL BEGIN SELECT RAISE(ABORT,'immutable context proposal'); END;
        CREATE TRIGGER context_proposals_no_delete BEFORE DELETE ON context_proposals BEGIN SELECT RAISE(ABORT,'immutable context proposal'); END;
        """

    public func contextProposalHead(markerID: UUID) async throws -> ContextProposalHead? {
        try requireInitialized()
        return try proposalHead(markerID)
    }
    private func proposalHead(_ markerID: UUID) throws -> ContextProposalHead? {
        try readOne(ContextProposalHead.self, sql: "SELECT payload FROM context_proposal_heads WHERE marker_id=?",
                    bindings: [.text(markerID.uuidString)])
    }

    public func applyContextProposal(_ command: ContextProposalCommand) async throws -> ContextProposalReceipt {
        try requireInitialized()
        guard command.requestPayload.count <= 768 * 1024, command.resultPayload.count <= 2 * 1024 * 1024,
              Self.sha(command.requestPayload) == command.jobID else { throw ContextStoreError.invalidInput }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let request = try decoder.decode(CompanionJobRequest.self, from: command.requestPayload)
        let result = try decoder.decode(CompanionResult.self, from: command.resultPayload)
        try request.validate()
        guard request.sourceStoreID == nativeStoreID, request.kind == .context,
              let source = request.context, let proposal = result.contextProposal,
              result.version == 1, result.jobID == command.jobID, result.sourceStoreID == nativeStoreID,
              result.kind == .context, result.speakerEnrichment == nil,
              source.markerID == proposal.markerID, source.markerRevision == command.expectedMarkerRevision,
              source.markerRevision == proposal.markerRevision, source.snapshotID == command.proposalRevision,
              source.snapshotID == proposal.snapshotID, source.expectedProposalHead == command.expectedProposalHead,
              source.verbatimExplanation == proposal.verbatimExplanation, source.developing == proposal.developing,
              source.incomplete == proposal.incomplete, proposal.ranges.count <= 16,
              Set(proposal.ranges.map(\.id)).count == proposal.ranges.count else { throw ContextStoreError.invalidInput }
        try validateText(proposal.method, maximumBytes: 256)
        let evidence = Dictionary(uniqueKeysWithValues: source.evidence.map { ($0.id, $0) })
        var used = Set<String>()
        for range in proposal.ranges {
            guard range.supportIDs.count == 1, let id = range.supportIDs.first, let support = evidence[id],
                  used.insert(id).inserted, range.start == support.start, range.end == support.end,
                      range.explanation == CompanionProposedRange.supportedExplanation(support),
                  range.score.isFinite, (0...1).contains(range.score) else { throw ContextStoreError.invalidInput }
            try validateText(range.explanation, maximumBytes: 4096)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = Data(SHA256.hash(data: try encoder.encode(command)))
        let resultSHA = Self.sha(command.resultPayload)
        return try transaction {
            let existing = try prepare("SELECT payload_digest,receipt FROM context_proposals WHERE job_id=?", [.text(command.jobID)])
            defer { sqlite3_finalize(existing) }
            let status = sqlite3_step(existing)
            if status == SQLITE_ROW {
                guard try blobColumn(existing, 0) == digest else { throw ContextStoreError.requestConflict }
                return try decode(ContextProposalReceipt.self, data: blobColumn(existing, 1))
            }
            guard status == SQLITE_DONE else { throw databaseError("read context proposal") }
            guard let marker = try marker(id: source.markerID, includeDeleted: false) else { throw ContextStoreError.markerNotFound }
            guard marker.revision == command.expectedMarkerRevision,
                  try proposalHead(marker.id)?.revision == command.expectedProposalHead else { throw ContextStoreError.revisionConflict }
            // A reused proposal revision from a different request is a conflict, not a new head.
            guard try scalar("SELECT count(*) FROM context_proposals WHERE proposal_revision=?", [.text(command.proposalRevision.uuidString)]) == 0 else {
                throw ContextStoreError.requestConflict
            }
            let current = try listContextRanges(markerID: marker.id, limit: 64)
            let protected = Set(current.filter { $0.ownership != .proposed || !($0.userNote ?? "").isEmpty }.map(\.id))
            let proposedIDs = Set(proposal.ranges.map(\.id))
            for range in current where !protected.contains(range.id) && !proposedIDs.contains(range.id) {
                try retainInitialRange(markerID: marker.id, range: range)
                let retired = MarkerContextRange(id: range.id, revision: UUID(), start: range.start, end: range.end,
                    explanation: range.explanation, ownership: range.ownership, explanationOrigin: range.effectiveExplanationOrigin,
                    provenance: range.provenance, userNote: range.userNote)
                try run("UPDATE marker_context_ranges SET payload=?,active=0 WHERE marker_id=? AND id=?",
                    [.blob(try encode(retired)), .text(marker.id.uuidString), .text(range.id.uuidString)])
                try appendContextRangeRevision(markerID: marker.id, range: retired, state: .superseded)
            }
            for range in proposal.ranges where !protected.contains(range.id) {
                if let old = current.first(where: { $0.id == range.id }) { try retainInitialRange(markerID: marker.id, range: old) }
                let saved = MarkerContextRange(id: range.id, revision: UUID(), start: range.start, end: range.end,
                    explanation: range.explanation, ownership: .proposed, explanationOrigin: .companionDerived,
                    provenance: .init(jobID: command.jobID, resultSHA256: resultSHA, proposalRevision: command.proposalRevision, supportIDs: range.supportIDs))
                try run("""
                    INSERT INTO marker_context_ranges(marker_id,id,starts_at,payload,active) VALUES(?,?,?,?,1)
                    ON CONFLICT(marker_id,id) DO UPDATE SET starts_at=excluded.starts_at,payload=excluded.payload,active=1
                    """, [.text(marker.id.uuidString), .text(saved.id.uuidString), .real(saved.start.timeIntervalSince1970), .blob(try encode(saved))])
                try appendContextRangeRevision(markerID: marker.id, range: saved, state: .active)
            }
            guard try scalar("SELECT count(*) FROM marker_context_ranges WHERE marker_id=? AND active=1", [.text(marker.id.uuidString)]) <= 64 else {
                throw ContextStoreError.capacityExceeded
            }
            try run("""
                INSERT INTO context_proposals(job_id,marker_id,proposal_revision,marker_revision,payload_digest,result_sha,request_payload,result_payload)
                VALUES(?,?,?,?,?,?,?,?)
                """, [.text(command.jobID), .text(marker.id.uuidString), .text(command.proposalRevision.uuidString),
                       .text(marker.revision.uuidString), .blob(digest), .text(resultSHA), .blob(command.requestPayload), .blob(command.resultPayload)])
            guard let connection else { throw ContextStoreError.notInitialized }
            let head = ContextProposalHead(revision: command.proposalRevision, jobID: command.jobID, sequence: sqlite3_last_insert_rowid(connection))
            let receipt = ContextProposalReceipt(markerID: marker.id, head: head)
            try run("UPDATE context_proposals SET receipt=? WHERE job_id=?", [.blob(try encode(receipt)), .text(command.jobID)])
            try run("INSERT INTO context_proposal_heads(marker_id,payload) VALUES(?,?) ON CONFLICT(marker_id) DO UPDATE SET payload=excluded.payload",
                    [.text(marker.id.uuidString), .blob(try encode(head))])
            return receipt
        }
    }

    public func contextProposal(jobID: String) async throws -> RetainedContextProposal? {
        try requireInitialized(); try CompanionBounds.digest(jobID)
        let statement = try prepare("SELECT marker_id,marker_revision,proposal_revision,result_sha,request_payload,result_payload FROM context_proposals WHERE job_id=?", [.text(jobID)])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { try Task.checkCancellation(); return nil }
        guard status == SQLITE_ROW,
              let marker = UUID(uuidString: try textColumn(statement, 0)), let revision = UUID(uuidString: try textColumn(statement, 1)),
              let proposal = UUID(uuidString: try textColumn(statement, 2)) else { throw ContextStoreError.incompatibleDatabase }
        let sha = try textColumn(statement, 3)
        let request = try blobColumn(statement, 4, limit: 768 * 1024), result = try blobColumn(statement, 5, limit: 2 * 1024 * 1024)
        guard Self.sha(request) == jobID, Self.sha(result) == sha else { throw ContextStoreError.incompatibleDatabase }
        try Task.checkCancellation()
        return .init(markerID: marker, markerRevision: revision, proposalRevision: proposal, jobID: jobID,
                     resultSHA256: sha, requestPayload: request, resultPayload: result)
    }

    public func contextRangeHistory(markerID: UUID, afterSequence: Int64, limit: Int) async throws -> [ContextRangeRevision] {
        try requireInitialized()
        guard afterSequence >= 0, (1...100).contains(limit) else { throw ContextStoreError.invalidInput }
        let statement = try prepare("SELECT sequence,state,payload,recorded_at FROM context_range_revisions WHERE marker_id=? AND sequence>? ORDER BY sequence LIMIT ?",
            [.text(markerID.uuidString), .int64(afterSequence), .integer(limit)])
        defer { sqlite3_finalize(statement) }
        var result: [ContextRangeRevision] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { try Task.checkCancellation(); return result }
            guard status == SQLITE_ROW, let state = ContextRangeRevision.State(rawValue: try textColumn(statement, 1)) else { throw ContextStoreError.incompatibleDatabase }
            result.append(.init(sequence: sqlite3_column_int64(statement, 0), markerID: markerID,
                range: try decode(MarkerContextRange.self, data: blobColumn(statement, 2)), state: state,
                recordedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
        }
    }
    private func retainInitialRange(markerID: UUID, range: MarkerContextRange) throws {
        guard try scalar("SELECT EXISTS(SELECT 1 FROM context_range_revisions WHERE marker_id=? AND range_id=?)",
                         [.text(markerID.uuidString), .text(range.id.uuidString)]) == 0 else { return }
        try appendContextRangeRevision(markerID: markerID, range: range, state: .active)
    }
    private func appendContextRangeRevision(markerID: UUID, range: MarkerContextRange, state: ContextRangeRevision.State) throws {
        try run("INSERT INTO context_range_revisions(marker_id,range_id,state,payload,recorded_at) VALUES(?,?,?,?,?)",
                [.text(markerID.uuidString), .text(range.id.uuidString), .text(state.rawValue), .blob(try encode(range)), .real(Date().timeIntervalSince1970)])
    }
    private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
