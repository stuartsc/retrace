import CryptoKit
import Foundation
import SQLCipher
import Shared

extension DatabaseManager {
    /// Committed native reads use their own read-only connection. Borrowed
    /// in-memory writer handles are deliberately not accepted here.
    public func makeAudioEvidenceStore() throws -> any AudioEvidenceStoreProtocol {
        guard isReady(), !screenEvidenceAdmissionClosing else { throw AudioEvidenceError.readerClosed }
        let generation = audioEvidenceReaderGeneration
        let connection = try makeRecallReadConnection()
        return try NativeAudioEvidenceStore(connection: connection, validateOwner: { [weak self] in
            guard let self else { throw AudioEvidenceError.readerClosed }
            try await self.validateAudioEvidenceOwner(generation)
        }, metric: { [weak self] operation, count in
            guard let self else { throw AudioEvidenceError.readerClosed }
            try await self.recordAudioEvidenceReadAttempt(operation, count: count, generation: generation)
        })
    }

    private func validateAudioEvidenceOwner(_ generation: UUID) throws {
        guard isReady(), !screenEvidenceAdmissionClosing, generation == audioEvidenceReaderGeneration else {
            throw AudioEvidenceError.readerClosed
        }
    }

    private func recordAudioEvidenceReadAttempt(_ operation: String, count: Int, generation: UUID) throws {
        try validateAudioEvidenceOwner(generation)
        guard ["search", "read", "media", "revalidate", "coverage"].contains(operation), (0...50).contains(count),
              let db = getConnection() else { throw AudioEvidenceError.invalidRequest }
        try AudioEvidenceSQL.transaction(db, write: true) {
            try DailyMetricsQueries.recordEvent(db: db, metricType: .audioEvidence,
                metadata: "{\"operation\":\"\(operation)\",\"outcome\":\"attempt\",\"count\":\(count)}")
        }
    }

    /// The migration's fixed historical boundary never follows a fresh insert
    /// flood. A page inspects IDs before admission, advances over gaps, and does
    /// not mutate legacy transcript text, pass, source, or status.
    public func advanceAudioEvidenceBootstrap(limit: Int = 128) async throws -> AudioEvidenceBootstrapProgress {
        guard isReady(), !screenEvidenceAdmissionClosing, let db = getConnection() else {
            throw AudioEvidenceError.readerClosed
        }
        return try AudioEvidenceSQL.advanceBootstrap(db, limit: limit)
    }
}

/// This actor owns one actual read-only SQLite handle. It never returns paths or
/// claims verified media, capture-policy attribution, or model/search coverage.
actor NativeAudioEvidenceStore: AudioEvidenceStoreProtocol {
    private var connection: SQLiteConnection?
    private let readerID = UUID()
    private let validateOwner: (@Sendable () async throws -> Void)?
    private let metric: (@Sendable (String, Int) async throws -> Void)?
    private(set) var closed = false
    private var active = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(connection: SQLiteConnection,
         validateOwner: (@Sendable () async throws -> Void)? = nil,
         metric: (@Sendable (String, Int) async throws -> Void)? = nil) throws {
        guard let db = connection.getConnection(), sqlite3_db_readonly(db, "main") == 1,
              sqlite3_db_mutex(db) != nil else { throw AudioEvidenceError.unsupportedConnection }
        self.connection = connection; self.validateOwner = validateOwner; self.metric = metric
    }

    func searchAudioEvidence(_ request: AudioEvidenceSearchRequest) async throws -> AudioEvidenceSearchPage {
        try enter(); defer { leave() }
        try await validateOwner?()
        let query = try AudioEvidenceSQL.Query(request)
        let page: AudioEvidenceSearchPage
        do {
            page = try read { db in try AudioEvidenceSQL.search(db, query: query, readerID: readerID) }
        } catch AudioEvidenceSQL.Failure.budget {
            let base = try read { db in try AudioEvidenceSQL.state(db, readerID: readerID) }
            page = AudioEvidenceSearchPage(hits: [], stamp: base.stamp, nextCursor: nil,
                coverage: AudioEvidenceCoverage(bootstrap: base.bootstrap), unavailableReason: .budgetExceeded)
        }
        try await finish(operation: "search", count: page.hits.count, stamp: page.stamp,
                         references: page.hits.map { $0.snapshot.reference })
        return page
    }

    func readAudioEvidence(_ reference: AudioEvidenceRef) async throws -> AudioEvidenceReadResult {
        try enter(); defer { leave() }
        try await validateOwner?()
        let result = try read { db -> AudioEvidenceReadResult in
            let state = try AudioEvidenceSQL.state(db, readerID: readerID)
            return try AudioEvidenceSQL.resolve(db, reference: reference, stamp: state.stamp)
        }
        switch result {
        case .available(_, let stamp):
            try await finish(operation: "read", count: 1, stamp: stamp, references: [reference])
        case .unavailable:
            try await finish(operation: "read", count: 0, stamp: nil, references: [])
        }
        return result
    }

    func readAudioMedia(_ reference: AudioEvidenceRef) async throws -> AudioEvidenceMediaReadResult {
        try enter(); defer { leave() }
        try await validateOwner?()
        let result = try read { db -> AudioEvidenceMediaReadResult in
            let state = try AudioEvidenceSQL.state(db, readerID: readerID)
            switch try AudioEvidenceSQL.resolve(db, reference: reference, stamp: state.stamp) {
            case .unavailable(let reason): return .unavailable(reason)
            case .available(let snapshot, let stamp):
                do {
                    guard let window = try AudioChunkMediaSQL.media(db, snapshot: snapshot) else {
                        return .unavailable(.mediaUnregistered)
                    }
                    return .available(window, snapshot, stamp)
                } catch is CancellationError { throw CancellationError() }
                catch { return .unavailable(.integrityFailure) }
            }
        }
        switch result {
        case .available(let window, let snapshot, let stamp):
            try await finish(operation: "media", count: 1, stamp: stamp, references: [reference])
            try read { db in
                guard try AudioEvidenceSQL.state(db, readerID: readerID).stamp == stamp,
                      try AudioChunkMediaSQL.media(db, snapshot: snapshot) == window else {
                    throw AudioEvidenceError.dataChanged
                }
            }
        case .unavailable:
            try await finish(operation: "media", count: 0, stamp: nil, references: [])
        }
        return result
    }

    func revalidateAudioEvidence(_ stamp: AudioEvidenceReadStamp, references: [AudioEvidenceRef]) async throws {
        try enter(); defer { leave() }
        guard references.count <= 50 else { throw AudioEvidenceError.invalidRequest }
        try await finish(operation: "revalidate", count: references.count, stamp: stamp, references: references)
    }

    func audioEvidenceCoverage() async throws -> AudioEvidenceCoverage {
        try enter(); defer { leave() }
        try await validateOwner?()
        let state = try read { db in try AudioEvidenceSQL.state(db, readerID: readerID) }
        try await finish(operation: "coverage", count: 0, stamp: state.stamp, references: [])
        return AudioEvidenceCoverage(bootstrap: state.bootstrap)
    }

    func close() async {
        closed = true
        if active > 0 { await withCheckedContinuation { closeWaiters.append($0) } }
        connection = nil
    }

    private func enter() throws {
        guard !closed else { throw AudioEvidenceError.readerClosed }
        try Task.checkCancellation(); active += 1
    }
    private func leave() {
        active -= 1
        if active == 0 {
            let waiters = closeWaiters; closeWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }
    private func read<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard !closed, let db = connection?.getConnection() else { throw AudioEvidenceError.readerClosed }
        return try AudioEvidenceSQL.transaction(db, write: false) { try body(db) }
    }
    /// Metrics are awaited attempts, not invented delivery success. Any mutation
    /// or owner close while they suspend is rejected by the final canonical read.
    private func finish(operation: String, count: Int, stamp: AudioEvidenceReadStamp?,
                        references: [AudioEvidenceRef]) async throws {
        guard !closed else { throw AudioEvidenceError.readerClosed }
        try Task.checkCancellation()
        try await validateOwner?()
        guard !closed else { throw AudioEvidenceError.readerClosed }
        try await metric?(operation, count)
        try await validateOwner?()
        try Task.checkCancellation()
        try read { db in
            let current = try AudioEvidenceSQL.state(db, readerID: readerID)
            if let stamp {
                guard stamp == current.stamp else { throw AudioEvidenceError.dataChanged }
                for reference in references {
                    guard case .available = try AudioEvidenceSQL.resolve(db, reference: reference, stamp: stamp) else {
                        throw AudioEvidenceError.dataChanged
                    }
                }
            }
        }
    }
}

/// All callbacks under the recursive connection mutex are synchronous; the
/// autocommit guard refuses to join/rollback another actor's transaction.
enum AudioEvidenceSQL {
    enum Failure: Error { case budget }
    enum Value { case integer(Int64), text(String) }
    struct State { let stamp: AudioEvidenceReadStamp; let bootstrap: AudioEvidenceBootstrapProgress }
    private final class Budget {
        var remaining: Int
        init(write: Bool) { remaining = write ? 10_000 : 1_000 }
        func interrupted() -> Bool { remaining -= 1; return remaining < 0 || Task.isCancelled }
    }
    static func transaction<T>(_ db: OpaquePointer, write: Bool, _ body: () throws -> T) throws -> T {
        guard let mutex = sqlite3_db_mutex(db) else { throw AudioEvidenceError.unsupportedConnection }
        guard sqlite3_mutex_try(mutex) == SQLITE_OK else { throw AudioEvidenceError.connectionBusy }
        defer { sqlite3_mutex_leave(mutex) }
        guard sqlite3_get_autocommit(db) != 0 else { throw AudioEvidenceError.connectionBusy }
        try Task.checkCancellation()
        let budget = Budget(write: write)
        sqlite3_progress_handler(db, 1_000, { raw in
            guard let raw else { return 1 }
            return Unmanaged<Budget>.fromOpaque(raw).takeUnretainedValue().interrupted() ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        try execute(db, write ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let value = try body(); try Task.checkCancellation(); try execute(db, "COMMIT"); return value
        } catch {
            sqlite3_progress_handler(db, 0, nil, nil)
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }
    static func rows<T>(_ db: OpaquePointer, _ sql: String, _ values: [Value] = [],
                        _ row: (OpaquePointer) throws -> T) throws -> [T] {
        var pointer: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &pointer, nil)
        guard prepared == SQLITE_OK, let pointer else {
            sqlite3_finalize(pointer)
            if prepared == SQLITE_INTERRUPT { try Task.checkCancellation(); throw Failure.budget }
            throw AudioEvidenceError.integrityFailure
        }
        defer { sqlite3_finalize(pointer) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let result: Int32
            switch value {
            case .integer(let number): result = sqlite3_bind_int64(pointer, Int32(index + 1), number)
            case .text(let text): result = sqlite3_bind_text(pointer, Int32(index + 1), text, -1, transient)
            }
            guard result == SQLITE_OK else { throw AudioEvidenceError.integrityFailure }
        }
        var output: [T] = []
        while true {
            let status = sqlite3_step(pointer)
            if status == SQLITE_DONE { return output }
            if status == SQLITE_INTERRUPT {
                try Task.checkCancellation(); throw Failure.budget
            }
            guard status == SQLITE_ROW else { throw AudioEvidenceError.integrityFailure }
            output.append(try row(pointer))
        }
    }
    static func execute(_ db: OpaquePointer, _ sql: String, _ values: [Value] = []) throws {
        _ = try rows(db, sql, values) { _ in true }
    }
    static func string(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, column) else { throw AudioEvidenceError.integrityFailure }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= 65_536, let value = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8),
              !value.contains("\0") else { throw AudioEvidenceError.integrityFailure }
        return value
    }
    static func optionalString(_ statement: OpaquePointer, _ column: Int32) throws -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : try string(statement, column)
    }
    static func state(_ db: OpaquePointer, readerID: UUID) throws -> State {
        let values = try rows(db, """
            SELECT e.storeID,s.mutationRevision,s.historicalBoundary,s.throughRowID,s.bootstrapComplete
            FROM evidence_store e CROSS JOIN audio_evidence_state s WHERE e.source='native' AND s.singleton=1 LIMIT 2
            """) { p -> State in
                guard let store = UUID(uuidString: try string(p, 0)), sqlite3_column_type(p, 1) == SQLITE_INTEGER,
                      sqlite3_column_int64(p, 1) > 0 else { throw AudioEvidenceError.integrityFailure }
                let boundary = sqlite3_column_int64(p, 2), through = sqlite3_column_int64(p, 3)
                guard boundary >= 0, through >= 0, through <= boundary else { throw AudioEvidenceError.integrityFailure }
                return State(stamp: .init(storeID: store, readerID: readerID, mutationRevision: sqlite3_column_int64(p, 1)),
                    bootstrap: .init(historicalBoundary: boundary, throughRowID: through,
                                     complete: sqlite3_column_int(p, 4) == 1))
            }
        guard values.count == 1, let value = values.first else { throw AudioEvidenceError.integrityFailure }
        return value
    }
    static func advanceBootstrap(_ db: OpaquePointer, limit: Int) throws -> AudioEvidenceBootstrapProgress {
        guard (1...128).contains(limit) else { throw AudioEvidenceError.invalidRequest }
        return try transaction(db, write: true) {
            let original = try state(db, readerID: UUID()).bootstrap
            guard !original.complete else { return original }
            let ids = try rows(db, "SELECT id FROM audio_captures WHERE id>? AND id<=? ORDER BY id LIMIT ?",
                [.integer(original.throughRowID), .integer(original.historicalBoundary), .integer(Int64(limit))]) {
                    sqlite3_column_int64($0, 0)
                }
            for id in ids {
                try execute(db, """
                    INSERT INTO audio_evidence_materialization(nativeRowID) SELECT ?
                    WHERE NOT EXISTS(SELECT 1 FROM audio_evidence_alias WHERE nativeRowID=?)
                    """, [.integer(id), .integer(id)])
            }
            let through = ids.last ?? original.historicalBoundary
            let remaining = try rows(db, "SELECT 1 FROM audio_captures WHERE id>? AND id<=? LIMIT 1",
                [.integer(through), .integer(original.historicalBoundary)]) { _ in true }
            let complete = remaining.isEmpty
            let finalThrough = complete ? original.historicalBoundary : through
            try execute(db, "UPDATE audio_evidence_state SET throughRowID=?,bootstrapComplete=?,mutationRevision=mutationRevision+1 WHERE singleton=1",
                [.integer(finalThrough), .integer(complete ? 1 : 0)])
            try DailyMetricsQueries.recordEvent(db: db, metricType: .audioEvidence,
                metadata: "{\"outcome\":\"bootstrap\",\"count\":\(ids.count)}")
            return .init(historicalBoundary: original.historicalBoundary, throughRowID: finalThrough,
                         complete: complete, inspectedRows: ids.count)
        }
    }

    struct Query {
        let request: AudioEvidenceSearchRequest
        let unavailable: AudioEvidenceUnavailableReason?
        let fingerprint: String
        let match: String?
        let from: Int64?
        let through: Int64?
        init(_ request: AudioEvidenceSearchRequest) throws {
            guard (1...50).contains(request.limit), (1...512).contains(request.maximumInspectedRows),
                  request.terms.count <= 16, request.terms.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }),
                  request.recordingSources.count <= 7, !request.recordingSources.contains(.unknown) else {
                throw AudioEvidenceError.invalidRequest
            }
            self.request = request
            let f = request.filters
            if request.requiresCapturePolicyAttestation { unavailable = .unattestedCapturePolicy }
            else if f.appBundleIDs?.isEmpty == false || f.excludedAppBundleIDs?.isEmpty == false { unavailable = .unsupportedApplicationScope }
            else if f.windowNameFilter?.isEmpty == false { unavailable = .unsupportedWindowScope }
            else if f.browserUrlFilter?.isEmpty == false { unavailable = .unsupportedURLScope }
            else if f.selectedTagIds?.isEmpty == false || f.excludedTagIds?.isEmpty == false { unavailable = .unsupportedTagScope }
            else if f.commentFilter != .allFrames { unavailable = .unsupportedCommentScope }
            else if f.hiddenFilter == .onlyHidden { unavailable = .unsupportedHiddenScope }
            else if f.effectiveDateRanges.count > 1 { unavailable = .unsupportedDateScope }
            else { unavailable = nil }
            let range = f.effectiveDateRanges.first
            func milliseconds(_ value: Date?, up: Bool) throws -> Int64? {
                guard let value else { return nil }
                let seconds = value.timeIntervalSince1970
                guard seconds.isFinite, abs(seconds) < 9_000_000_000_000 else { throw AudioEvidenceError.invalidRequest }
                return Int64((seconds * 1000).rounded(up ? .up : .down))
            }
            from = try milliseconds(range?.start, up: true)
            through = try milliseconds(range?.end, up: false)
            if let from, let through, from > through { throw AudioEvidenceError.invalidRequest }
            match = request.terms.isEmpty ? nil : request.terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
            struct Fingerprint: Encodable {
                let terms: [String]; let sources: [String]; let from: Int64?; let through: Int64?
                let hidden: String; let limit: Int; let inspected: Int
            }
            let value = Fingerprint(terms: request.terms, sources: request.recordingSources.map(\.rawValue).sorted(),
                from: from, through: through, hidden: f.hiddenFilter.rawValue,
                limit: request.limit, inspected: request.maximumInspectedRows)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            fingerprint = SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func search(_ db: OpaquePointer, query: Query, readerID: UUID) throws -> AudioEvidenceSearchPage {
        let base = try state(db, readerID: readerID)
        if let reason = query.unavailable {
            return .init(hits: [], stamp: base.stamp, nextCursor: nil,
                         coverage: .init(bootstrap: base.bootstrap), unavailableReason: reason)
        }
        if let cursor = query.request.cursor {
            guard cursor.querySHA256 == query.fingerprint, cursor.beforeRowID > 0 else { throw AudioEvidenceError.invalidRequest }
            guard cursor.stamp == base.stamp else { throw AudioEvidenceError.dataChanged }
        }
        let upper = query.request.cursor?.beforeRowID ?? Int64.max
        let ids = try rows(db, "SELECT id FROM audio_captures WHERE id<? ORDER BY id DESC LIMIT ?",
            [.integer(upper), .integer(Int64(query.request.maximumInspectedRows + 1))]) { sqlite3_column_int64($0, 0) }
        var hits: [AudioEvidenceSearchHit] = []
        var inspected = 0, available = 0, unproven = 0, quality = 0, unmaterialized = 0, outputBytes = 0
        var lastConsumed = upper
        for id in ids.prefix(query.request.maximumInspectedRows) {
            try Task.checkCancellation(); inspected += 1
            let candidate = try loadCandidate(db, rowID: id, stamp: base.stamp)
            if candidate.unmaterialized { unmaterialized += 1 }
            if let reason = candidate.reason {
                switch reason {
                case .lineageUnavailable, .lineageConflicting: unproven += 1
                case .unavailableQuality, .oversizedText, .invalidTiming, .budgetExceeded: quality += 1
                default: break
                }
            }
            guard let value = candidate.snapshot else { lastConsumed = id; continue }
            let begin = Int64((value.reference.startTime * 1000).rounded())
            let end = Int64((value.reference.endTime * 1000).rounded())
            guard query.from.map({ begin >= $0 }) ?? true,
                  query.through.map({ end <= $0 }) ?? true,
                  query.request.recordingSources.isEmpty || query.request.recordingSources.contains(value.recordingSource) else {
                lastConsumed = id; continue
            }
            available += 1
            if let match = query.match {
                let matches = try rows(db, "SELECT 1 FROM audio_captures_fts WHERE rowid=? AND audio_captures_fts MATCH ? LIMIT 1",
                    [.integer(id), .text(match)]) { _ in true }
                if matches.isEmpty { lastConsumed = id; continue }
            }
            let cost = value.text.utf8.count
            if outputBytes + cost > 262_144 { break }
            outputBytes += cost
            let string = value.text as NSString
            var excerptEnd = min(string.length, 512)
            if excerptEnd < string.length {
                let boundary = string.rangeOfComposedCharacterSequence(at: excerptEnd)
                if boundary.location < excerptEnd { excerptEnd = boundary.location }
            }
            let excerpt = string.substring(to: excerptEnd)
            hits.append(.init(snapshot: value, excerpt: .init(reference: value.reference,
                utf16Range: .init(location: 0, length: excerpt.utf16.count), text: excerpt)))
            lastConsumed = id
            if hits.count == query.request.limit { break }
        }
        let more = ids.contains { $0 < lastConsumed }
        let cursor = more ? AudioEvidenceSearchCursor(stamp: base.stamp, querySHA256: query.fingerprint, beforeRowID: lastConsumed) : nil
        return .init(hits: hits, stamp: base.stamp, nextCursor: cursor,
            coverage: .init(bootstrap: base.bootstrap, inspectedRows: inspected, availableRows: available,
                unprovenLineageRows: unproven, unavailableQualityRows: quality, unmaterializedRows: unmaterialized,
                scanComplete: !more))
    }

    static func resolve(_ db: OpaquePointer, reference: AudioEvidenceRef,
                        stamp: AudioEvidenceReadStamp) throws -> AudioEvidenceReadResult {
        guard reference.source == .native else { return .unavailable(.notNative) }
        guard reference.storeID == stamp.storeID else { return .unavailable(.sourceMismatch) }
        guard UUID(uuidString: reference.segmentID) != nil, reference.transcriptRevision > 0,
              reference.startTime.isFinite, reference.endTime.isFinite,
              abs(reference.startTime) < 9_000_000_000_000, abs(reference.endTime) < 9_000_000_000_000,
              reference.endTime > reference.startTime else { return .unavailable(.invalidTiming) }
        let aliases = try rows(db, "SELECT nativeRowID,revision,state FROM audio_evidence_alias WHERE observationID=?",
            [.text(reference.segmentID)]) { (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1), try string($0, 2)) }
        guard let alias = aliases.first else { return .unavailable(.evidenceMissing) }
        if alias.2 == "deleted" { return .unavailable(.evidenceDeleted) }
        guard alias.1 == reference.transcriptRevision else { return .unavailable(.revisionUnavailable) }
        let candidate = try loadCandidate(db, rowID: alias.0, stamp: stamp)
        guard let snapshot = candidate.snapshot else { return .unavailable(candidate.reason ?? .evidenceMissing) }
        guard snapshot.reference == reference else { return .unavailable(.revisionUnavailable) }
        return .available(snapshot, stamp)
    }

    private struct Candidate {
        let snapshot: AudioEvidenceSnapshot?
        let reason: AudioEvidenceUnavailableReason?
        var unmaterialized = false
    }
    private static func loadCandidate(_ db: OpaquePointer, rowID: Int64,
                                      stamp: AudioEvidenceReadStamp) throws -> Candidate {
        let alias = try rows(db, "SELECT state,storeID FROM audio_evidence_alias WHERE nativeRowID=?", [.integer(rowID)]) {
            (try string($0, 0), try string($0, 1))
        }.first
        guard let alias else { return .init(snapshot: nil, reason: .evidenceMissing, unmaterialized: true) }
        if alias.0 == "deleted" { return .init(snapshot: nil, reason: .evidenceDeleted) }
        guard UUID(uuidString: alias.1) == stamp.storeID else { return .init(snapshot: nil, reason: .sourceMismatch) }
        let reasons = try rows(db, "SELECT reason FROM audio_evidence_projection WHERE nativeRowID=?", [.integer(rowID)]) {
            try optionalString($0, 0)
        }
        guard !reasons.isEmpty else { return .init(snapshot: nil, reason: .evidenceMissing) }
        if let raw = reasons[0] { return .init(snapshot: nil, reason: AudioEvidenceUnavailableReason(rawValue: raw) ?? .integrityFailure) }
        // Exact current row and origin revalidation, in the same read transaction
        // as the mutation stamp. A numeric native row ID alone is never returned.
        let values = try rows(db, """
            SELECT s.observationID,s.storeID,s.revision,s.recordingID,s.recordingSource,s.recordingStart,s.recordingEnd,
              s.startedAt,s.endedAt,s.text,s.transcriptStatus,s.transcriptionPass,s.detectedLanguage,s.audioVariant,s.confidence
            FROM audio_evidence_snapshot s JOIN audio_evidence_projection v ON v.nativeRowID=s.nativeRowID
            WHERE s.nativeRowID=? AND v.reason IS NULL AND s.observationID=v.observationID AND s.storeID=v.storeID
              AND s.revision=v.revision AND s.recordingID=v.recordingID AND s.recordingSource=v.recordingSource
              AND s.recordingStart=v.recordingStart AND s.recordingEnd=v.recordingEnd
              AND s.startedAt=v.startedAt AND s.endedAt=v.endedAt AND s.text IS v.text
              AND s.transcriptStatus IS v.transcriptStatus AND s.transcriptionPass=v.transcriptionPass
              AND s.detectedLanguage IS v.detectedLanguage AND s.audioVariant IS v.audioVariant AND s.confidence IS v.confidence
            """, [.integer(rowID)]) { p -> AudioEvidenceSnapshot in
                let observation = try string(p, 0)
                guard UUID(uuidString: observation) != nil, let store = UUID(uuidString: try string(p, 1)),
                      store == stamp.storeID, let recording = UUID(uuidString: try string(p, 3)),
                      let source = AudioSource(rawValue: try string(p, 4)), source != .unknown,
                      sqlite3_column_int64(p, 2) > 0 else { throw AudioEvidenceError.integrityFailure }
                let start = sqlite3_column_int64(p, 7), end = sqlite3_column_int64(p, 8)
                guard end > start else { throw AudioEvidenceError.integrityFailure }
                let reference = AudioEvidenceRef(storeID: store, source: .native, segmentID: observation,
                    transcriptRevision: sqlite3_column_int64(p, 2), startTime: Double(start) / 1000, endTime: Double(end) / 1000)
                let confidence: Double? = sqlite3_column_type(p, 14) == SQLITE_NULL ? nil : sqlite3_column_double(p, 14)
                return AudioEvidenceSnapshot(reference: reference, recordingID: recording, recordingSource: source,
                    recordingStartedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(p, 5)) / 1000),
                    recordingEndedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(p, 6)) / 1000),
                    text: try string(p, 9), transcriptStatus: try string(p, 10), transcriptionPass: Int(sqlite3_column_int(p, 11)),
                    detectedLanguage: try optionalString(p, 12), audioVariant: try string(p, 13), confidence: confidence)
            }
        guard let snapshot = values.first else { return .init(snapshot: nil, reason: .revisionUnavailable, unmaterialized: true) }
        return .init(snapshot: snapshot, reason: nil)
    }
}
