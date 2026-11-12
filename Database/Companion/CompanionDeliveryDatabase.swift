import CryptoKit
import Darwin
import Dispatch
import Foundation
import SQLCipher
import Shared

/// Independently versioned sender catalog. Immutable wire bytes and receipts stay local;
/// active work is a bounded projection, never the lifetime retained-history count.
public actor CompanionDeliveryDatabase {
    private static let applicationID = 1_381_253_977
    private let path: String
    private let nativeStoreID: UUID
    private let readOnly: Bool
    private var db: OpaquePointer?
    private var catalogID: UUID?
    private var closed = false
    #if DEBUG
    private var readInstructionLimitForTesting: Int?
    func setReadInstructionLimitForTesting(_ limit: Int?) { readInstructionLimitForTesting = limit }
    #endif
    public init(databasePath: String, nativeStoreID: UUID, readOnly: Bool = false) {
        path = databasePath; self.nativeStoreID = nativeStoreID; self.readOnly = readOnly
    }
    deinit { if let db { sqlite3_close_v2(db) } }
    public func initialize() throws {
        guard !closed else { throw CompanionError.closed }
        if db != nil { return }
        try Task.checkCancellation()
        guard !path.isEmpty, !path.contains("\0") else { throw CompanionError.unsafeStorage }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var directory = stat(), info = stat()
        guard lstat(parent, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_uid == geteuid(), directory.st_mode & 0o077 == 0 else { throw CompanionError.unsafeStorage }
        if lstat(path, &info) != 0 {
            guard !readOnly, errno == ENOENT else { throw CompanionError.unavailable }
            let fd = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw CompanionError.unsafeStorage }; Darwin.close(fd)
            let directoryFD = Darwin.open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard directoryFD >= 0 else { throw CompanionError.unsafeStorage }
            let synced = fsync(directoryFD); Darwin.close(directoryFD)
            guard synced == 0 else { throw CompanionError.unsafeStorage }
            guard lstat(path, &info) == 0 else { throw CompanionError.unsafeStorage }
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw CompanionError.unsafeStorage }
        var opened: OpaquePointer?
        guard sqlite3_open_v2(path, &opened, (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened else { if let opened { sqlite3_close_v2(opened) }; throw CompanionError.unavailable }
        db = opened
        do {
            sqlite3_busy_timeout(opened, 1000)
            // First publication can commit between two PRAGMA reads. Bind all
            // identity/schema checks to one read snapshot so a new catalog
            // cannot appear to have a mixed application ID and version.
            if readOnly { try execute("BEGIN") }
            let application = try scalar("PRAGMA application_id"), version = try scalar("PRAGMA user_version")
            if application == 0 && version == 0 && !readOnly {
                guard try scalar("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0 else { throw CompanionError.unsafeStorage }
                try transaction {
                    try execute(Self.schema)
                    try run("INSERT INTO metadata(singleton,catalog_id,native_id) VALUES(1,?,?)", [.text(UUID().uuidString), .text(nativeStoreID.uuidString)])
                    try execute("PRAGMA application_id=\(Self.applicationID)"); try execute("PRAGMA user_version=1")
                }
            } else { if readOnly && application == 0 && version == 0 {
                guard try scalar("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0 else { throw CompanionError.unsafeStorage }
                throw CompanionDeliveryDatabaseError.unpublished
            }; guard application == Self.applicationID, version == 1 else { throw CompanionError.unsafeStorage } }
            do {
                let statement = try prepare("SELECT catalog_id,native_id FROM metadata WHERE singleton=1")
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW, let identity = UUID(uuidString: try text(statement, 0)),
                      UUID(uuidString: try text(statement, 1)) == nativeStoreID else { throw CompanionError.nativeStoreMismatch }
                catalogID = identity
            }
            if readOnly { try execute("COMMIT") }
            // A statement paused at SQLITE_ROW owns a read transaction. Finish it
            // before changing journal mode, including the first database creation.
            if !readOnly { try execute("PRAGMA journal_mode=WAL"); try execute("PRAGMA synchronous=FULL") }
        } catch {
            if readOnly { try? execute("ROLLBACK") }
            sqlite3_close_v2(opened); db = nil; catalogID = nil; throw error
        }
    }
    public func close() throws {
        if let db { guard sqlite3_close(db) == SQLITE_OK else { throw CompanionError.unavailable } }
        db = nil; catalogID = nil; closed = true
    }
    public func activeCount() throws -> Int { try check(); return Int(try scalar("SELECT count(*) FROM jobs WHERE active=1")) }
    public func migrationComplete() throws -> Bool { try check(); return try scalar("SELECT migrated FROM metadata WHERE singleton=1") != 0 }
    public func completeLegacyMigration() throws { try writable(); try run("UPDATE metadata SET migrated=1 WHERE singleton=1") }
    public func recoverPublicationReservations() throws { try writable(); try run("DELETE FROM object_leases") }

    public func group(groupID: String) throws -> CompanionBatchPublicationReceipt? {
        try check(); try CompanionBounds.digest(groupID)
        let s = try prepare("SELECT receipt,semantic_payload FROM publication_groups WHERE id=?", [.text(groupID)]); defer { sqlite3_finalize(s) }
        let status = sqlite3_step(s); if status == SQLITE_DONE { try Task.checkCancellation(); return nil }
        guard status == SQLITE_ROW else { throw CompanionError.unavailable }
        let value = try JSONDecoder().decode(CompanionBatchPublicationReceipt.self, from: blob(s, 0, 65536))
        guard Self.digest(try blob(s, 1, 768 * 1024)) == groupID, value.groupID == groupID,
              value.jobIDs.count <= 32, value.coverageJobIDs.count <= 256,
              Set(value.jobIDs).count == value.jobIDs.count,
              Set(value.coverageJobIDs).count == value.coverageJobIDs.count,
              value.alreadyCovered == value.jobIDs.isEmpty else { throw CompanionError.conflictingPublication }
        for id in value.jobIDs + value.coverageJobIDs { try CompanionBounds.digest(id) }
        try Task.checkCancellation(); return value
    }
    public func latestBatchGroup(batchKey: String) throws -> CompanionBatchPublicationReceipt? {
        try check(); try CompanionBounds.digest(batchKey)
        let s = try prepare("SELECT group_id FROM batch_plans WHERE batch_key=? ORDER BY sequence DESC LIMIT 1", [.text(batchKey)])
        defer { sqlite3_finalize(s) }; let status = sqlite3_step(s)
        if status == SQLITE_DONE { try Task.checkCancellation(); return nil }; guard status == SQLITE_ROW else { throw CompanionError.unavailable }
        return try group(groupID: text(s, 0))
    }
    public func publishGroup(semanticPayload: Data, requests: [Data], reservationID: UUID, batchKey: String? = nil, coverageJobIDs: [String] = []) throws -> CompanionBatchPublicationReceipt {
        try writable()
        guard !semanticPayload.isEmpty, semanticPayload.count <= 768 * 1024, requests.count <= 32 else { throw CompanionError.invalidPayload }
        if let batchKey { try CompanionBounds.digest(batchKey) }
        guard coverageJobIDs.count <= 256, Set(coverageJobIDs).count == coverageJobIDs.count else { throw CompanionError.invalidPayload }
        for id in coverageJobIDs { try CompanionBounds.digest(id) }
        let groupID = Self.digest(semanticPayload)
        let decoded = try requests.map { data -> (String, Data, CompanionJobRequest) in (Self.digest(data), data, try request(data)) }
        guard Set(decoded.map { $0.0 }).count == decoded.count else { throw CompanionError.invalidPayload }
        return try transaction {
            if let previous = try group(groupID: groupID) { try releaseReservation(reservationID); return previous }
            for id in coverageJobIDs {
                guard let dependency = try record(jobID: id, includeResult: false), dependency.stage != .invalidated,
                      try request(dependency.requestPayload).speaker != nil else { throw CompanionError.staleEvidence }
            }
            let new = try decoded.filter { try scalar("SELECT count(*) FROM jobs WHERE id=?", [.text($0.0)]) == 0 }
            guard try scalar("SELECT count(*) FROM jobs WHERE active=1") + Int64(new.count) <= 256 else { throw CompanionError.capacityExceeded }
            for (id, data, request) in decoded {
                if let previous = try record(jobID: id, includeResult: false) {
                    guard previous.requestPayload == data else { throw CompanionError.conflictingPublication }
                    guard previous.stage != .invalidated else { throw CompanionError.staleEvidence }; continue
                }
                for object in request.speaker?.media ?? [] {
                    guard try scalar("SELECT count(*) FROM objects WHERE id=? AND bytes=? AND state='ready'", [.text(object.sha256), .integer(Int64(object.byteCount))]) == 1 else { throw CompanionError.unavailable }
                }
                try insertJob(id: id, data: data, request: request)
            }
            let receipt = CompanionBatchPublicationReceipt(groupID: groupID, jobIDs: decoded.map { $0.0 }, alreadyCovered: decoded.isEmpty, coverageJobIDs: coverageJobIDs)
            try run("INSERT INTO publication_groups(id,semantic_payload,receipt) VALUES(?,?,?)", [.text(groupID), .blob(semanticPayload), .blob(try JSONEncoder().encode(receipt))])
            if let batchKey { try run("INSERT INTO batch_plans(batch_key,group_id) VALUES(?,?)", [.text(batchKey), .text(groupID)]) }
            try releaseReservation(reservationID)
            return receipt
        }
    }
    private func insertJob(id: String, data: Data, request: CompanionJobRequest) throws {
        let source = request.speaker?.sourceIdentity
        let start = source.map { $0.approximateOrigin.timeIntervalSince1970 + Double($0.startSample) / 16000 }
        let end = source.map { $0.approximateOrigin.timeIntervalSince1970 + Double($0.startSample + $0.sampleCount) / 16000 }
        try run("""
            INSERT INTO jobs(id,request,kind,observed,stage,active,source_start,source_end,recording_generation,continuity,origin,sample_start,sample_end,marker_id)
            VALUES(?,?,?,?,'queued',1,?,?,?,?,?,?,?,?)
            """, [.text(id), .blob(data), .text(request.kind.rawValue), .real(request.observedAt.timeIntervalSince1970),
                start.map(Binding.real) ?? .null, end.map(Binding.real) ?? .null,
                source.map { .text($0.recordingGeneration.uuidString) } ?? .null, source.map { .text($0.continuityID.uuidString) } ?? .null,
                try source.map { .blob(try Self.origin($0.approximateOrigin)) } ?? .null,
                source.map { .integer($0.startSample) } ?? .null, source.map { .integer($0.startSample + $0.sampleCount) } ?? .null,
                request.context.map { .text($0.markerID.uuidString) } ?? .null])
        for hash in Set(request.speaker?.media.map(\.sha256) ?? []) {
            try run("INSERT INTO job_objects(job_id,object_id) VALUES(?,?)", [.text(id), .text(hash)])
        }
    }
    /// One-time bounded legacy import. No current source disclosure or inference is admitted here.
    public func importLegacy(requestPayload: Data, resultPayload: Data?, stage: CompanionDeliveryStage,
                             supersededMarkerID: UUID? = nil, refreshCompleted: Bool = false) throws {
        try writable(); let decoded = try request(requestPayload), id = Self.digest(requestPayload)
        try transaction {
            if let previous = try record(jobID: id, includeResult: false) {
                guard previous.requestPayload == requestPayload else { throw CompanionError.conflictingPublication }
            } else { try insertJob(id: id, data: requestPayload, request: decoded) }
            if let resultPayload { try insertResult(jobID: id, payload: resultPayload) }
            if stage == .acknowledged { try advance(id, .imported) }
            try advance(id, stage)
            if let marker = supersededMarkerID {
                guard stage == .invalidated, decoded.context?.markerID == marker else { throw CompanionError.invalidPayload }
                try run("INSERT OR IGNORE INTO context_refresh(job_id,marker_id,completed) VALUES(?,?,?)",
                        [.text(id), .text(marker.uuidString), .integer(refreshCompleted ? 1 : 0)])
            }
            guard try scalar("SELECT count(*) FROM jobs WHERE active=1") <= 256 else { throw CompanionError.capacityExceeded }
        }
    }
    public func record(jobID: String, includeResult: Bool = true) throws -> CompanionDeliveryRecord? {
        try check(); try CompanionBounds.digest(jobID)
        return try rows("WHERE j.id=?", [.text(jobID)], limit: 1, includeResult: includeResult).first
    }
    public func records(activeOnly: Bool, kind: CompanionJobRequest.Kind? = nil, limit: Int = 256) throws -> [CompanionDeliveryRecord] {
        try check(); guard (1...256).contains(limit) else { throw CompanionError.invalidPayload }
        var conditions = [String](), bindings = [Binding]()
        if activeOnly { conditions.append("j.active=1") }
        if let kind { conditions.append("j.kind=?"); bindings.append(.text(kind.rawValue)) }
        return try rows(conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND "), bindings, limit: limit)
    }
    public func activeRecords(beforeSequence: Int64? = nil, limit: Int = 8) throws -> [CompanionDeliveryRecord] {
        try check(); guard (1...32).contains(limit), beforeSequence == nil || beforeSequence! > 0 else { throw CompanionError.invalidPayload }
        return try rows("WHERE j.active=1 AND j.sequence<?", [.integer(beforeSequence ?? Int64.max)], limit: limit,
                        order: "j.sequence DESC", index: "jobs_active_sequence")
    }
    public func speakerCoverage(intersecting source: LiveAudioSampleIdentity, limit: Int = 256) throws -> [CompanionDeliveryRecord] {
        try check(); guard source.isValid, (1...256).contains(limit) else { throw CompanionError.invalidPayload }
        // Every request is <=60 seconds. Earlier starts cannot intersect this source.
        let lower = max(0, source.startSample - 960_000 + 1)
        let records = try rows("WHERE j.kind='speaker' AND j.stage!='invalidated' AND j.recording_generation=? AND j.continuity=? AND j.origin=? AND j.sample_start>=? AND j.sample_start<? AND j.sample_end>?",
            [.text(source.recordingGeneration.uuidString), .text(source.continuityID.uuidString), .blob(try Self.origin(source.approximateOrigin)),
             .integer(lower), .integer(source.startSample + source.sampleCount), .integer(source.startSample)], limit: limit + 1,
             order: "j.sample_start DESC,j.id DESC", index: "jobs_source_samples")
        guard records.count <= limit else { throw CompanionError.capacityExceeded }; return records
    }
    public func speakerPage(from: Date, to: Date, before: CompanionDeliveryCursor? = nil, limit: Int = 32) throws -> CompanionDeliveryPage {
        try check(); try CompanionBounds.date(from); try CompanionBounds.date(to)
        guard from <= to, (1...64).contains(limit), let catalogID else { throw CompanionError.invalidPayload }
        if let before {
            guard before.catalogID == catalogID, before.nativeStoreID == nativeStoreID,
                  try Self.origin(before.from) == Self.origin(from), try Self.origin(before.to) == Self.origin(to),
                  before.maximumSequence >= 0, before.beforeSourceStart.isFinite, before.beforeSourceStart > 0 else { throw CompanionError.staleEvidence }
            try CompanionBounds.digest(before.beforeID)
        }
        let upper: Int64
        if let before { upper = before.maximumSequence } else { upper = try scalar("SELECT COALESCE(MAX(sequence),0) FROM receipts") }
        var predicate = "WHERE j.kind='speaker' AND j.stage IN ('imported','acknowledged') AND j.import_sequence<=? AND j.source_start>=? AND j.source_start<=? AND j.source_end>=?"
        var bindings: [Binding] = [.integer(upper), .real(from.timeIntervalSince1970 - 60), .real(to.timeIntervalSince1970), .real(from.timeIntervalSince1970)]
        if let before { predicate += " AND (j.source_start,j.id)<(?,?)"; bindings += [.real(before.beforeSourceStart), .text(before.beforeID)] }
        var records = try rows(predicate, bindings, limit: limit + 1, order: "j.source_start DESC,j.id DESC", index: "jobs_speaker_time")
        let more = records.count > limit
        if more { records.removeLast() }
        var next: CompanionDeliveryCursor?
        if more, let last = records.last {
            let s = try prepare("SELECT source_start FROM jobs WHERE id=?", [.text(last.jobID)]); defer { sqlite3_finalize(s) }
            guard sqlite3_step(s) == SQLITE_ROW else { throw CompanionError.unavailable }
            next = .init(catalogID: catalogID, nativeStoreID: nativeStoreID, from: from, to: to,
                maximumSequence: upper, beforeSourceStart: sqlite3_column_double(s, 0), beforeID: last.jobID)
        }
        try Task.checkCancellation(); return .init(records: records, nextCursor: next)
    }
    public func storeResult(jobID: String, payload: Data) throws {
        try writable(); try transaction { try insertResult(jobID: jobID, payload: payload) }
    }
    private func insertResult(jobID: String, payload: Data) throws {
        guard payload.count <= 2 * 1024 * 1024, let record = try record(jobID: jobID, includeResult: false) else { throw CompanionError.invalidPayload }
        let request = try request(record.requestPayload), decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let result = try decoder.decode(CompanionResult.self, from: payload)
        guard result.version == 1, result.jobID == jobID, result.sourceStoreID == nativeStoreID, result.kind == request.kind else { throw CompanionError.invalidPayload }
        if let old = try self.record(jobID: jobID)?.resultPayload { guard old == payload else { throw CompanionError.conflictingPublication } }
        else { try run("INSERT INTO results(job_id,payload,digest) VALUES(?,?,?)", [.text(jobID), .blob(payload), .text(Self.digest(payload))]) }
        try advance(jobID, .received)
    }
    public func transition(jobID: String, stage: CompanionDeliveryStage) throws { try writable(); try transaction { try advance(jobID, stage) } }
    private func advance(_ id: String, _ stage: CompanionDeliveryStage) throws {
        guard let old = try record(jobID: id, includeResult: false) else { throw CompanionError.invalidPayload }
        let order: [CompanionDeliveryStage] = [.queued, .published, .received, .imported, .acknowledged, .invalidated]
        guard let previous = order.firstIndex(of: old.stage), let next = order.firstIndex(of: stage) else { throw CompanionError.invalidPayload }
        if previous >= next { return }
        if [.received, .imported, .acknowledged].contains(stage) {
            guard try scalar("SELECT count(*) FROM results WHERE job_id=?", [.text(id)]) == 1 else { throw CompanionError.invalidPayload }
        }
        try run("INSERT INTO receipts(job_id,stage) VALUES(?,?)", [.text(id), .text(stage.rawValue)])
        let sequence = try scalar("SELECT last_insert_rowid()")
        try run("UPDATE jobs SET stage=?,active=?,import_sequence=CASE WHEN ?='imported' THEN ? ELSE import_sequence END WHERE id=?",
            [.text(stage.rawValue), .integer(stage == .acknowledged || stage == .invalidated ? 0 : 1), .text(stage.rawValue), .integer(sequence), .text(id)])
    }
    public func supersede(jobID: String, markerID: UUID) throws {
        try writable()
        try transaction {
            guard let old = try record(jobID: jobID, includeResult: false), ![.imported, .acknowledged].contains(old.stage),
                  try request(old.requestPayload).context?.markerID == markerID else { throw CompanionError.conflictingPublication }
            try advance(jobID, .invalidated)
            try run("INSERT OR IGNORE INTO context_refresh(job_id,marker_id) VALUES(?,?)", [.text(jobID), .text(markerID.uuidString)])
        }
    }
    public func pendingRefreshes(afterSequence: Int64, limit: Int = 8) throws -> [CompanionRefreshCandidate] {
        try check(); guard afterSequence >= 0, (1...32).contains(limit) else { throw CompanionError.invalidPayload }
        let s = try prepare("SELECT sequence,job_id,marker_id FROM context_refresh WHERE completed=0 AND sequence>? ORDER BY sequence LIMIT ?", [.integer(afterSequence), .integer(Int64(limit))]); defer { sqlite3_finalize(s) }
        var values: [CompanionRefreshCandidate] = []
        while true {
            try Task.checkCancellation(); let status = sqlite3_step(s)
            if status == SQLITE_DONE { break }; guard status == SQLITE_ROW else { throw CompanionError.unavailable }
            guard let marker = UUID(uuidString: try text(s, 2)) else { throw CompanionError.invalidPayload }
            values.append(.init(sequence: sqlite3_column_int64(s, 0), jobID: try text(s, 1), markerID: marker))
        }
        try Task.checkCancellation(); return values
    }
    public func completeRefresh(jobID: String) throws { try writable(); try run("UPDATE context_refresh SET completed=1 WHERE job_id=?", [.text(jobID)]) }

    public func reserveObjects(_ objects: [CompanionObjectReservation], owner: UUID) throws {
        try writable(); guard objects.count <= 32, Set(objects.map(\.sha256)).count == objects.count else { throw CompanionError.invalidPayload }
        for object in objects { try CompanionBounds.digest(object.sha256); guard (1...16 * 1024 * 1024).contains(object.byteCount) else { throw CompanionError.invalidPayload } }
        try transaction {
            for object in objects {
                let existing = try scalar("SELECT count(*) FROM objects WHERE id=?", [.text(object.sha256)])
                if existing == 0 { try run("INSERT INTO objects(id,bytes,state) VALUES(?,?,'reserved')", [.text(object.sha256), .integer(Int64(object.byteCount))]) }
                guard try scalar("SELECT count(*) FROM objects WHERE id=? AND bytes=? AND state!='deleting'", [.text(object.sha256), .integer(Int64(object.byteCount))]) == 1 else { throw CompanionError.unavailable }
                try run("INSERT OR IGNORE INTO object_leases(owner,object_id) VALUES(?,?)", [.text(owner.uuidString), .text(object.sha256)])
            }
            guard try scalar("SELECT count(*) FROM objects") <= 4096,
                  try scalar("SELECT COALESCE(sum(bytes),0) FROM objects") <= 1024 * 1024 * 1024 else { throw CompanionError.capacityExceeded }
        }
    }
    public func markObjectReady(_ object: CompanionObjectReservation) throws {
        try writable(); try run("UPDATE objects SET state='ready' WHERE id=? AND bytes=? AND state!='deleting'", [.text(object.sha256), .integer(Int64(object.byteCount))])
    }
    public func releaseObjectReservation(_ owner: UUID) throws { try writable(); try releaseReservation(owner) }
    private func releaseReservation(_ owner: UUID) throws { try run("DELETE FROM object_leases WHERE owner=?", [.text(owner.uuidString)]) }
    public func claimObjectGarbage(limit: Int = 16) throws -> [CompanionObjectReservation] {
        try writable(); guard (1...32).contains(limit) else { throw CompanionError.invalidPayload }
        return try transaction {
            let s = try prepare("""
                SELECT id,bytes FROM objects o WHERE NOT EXISTS(SELECT 1 FROM object_leases l WHERE l.object_id=o.id)
                AND o.id NOT IN (SELECT r.object_id FROM jobs j INDEXED BY jobs_active JOIN job_objects r ON r.job_id=j.id WHERE j.active=1)
                ORDER BY id LIMIT ?
                """, [.integer(Int64(limit))]); defer { sqlite3_finalize(s) }
            var objects: [CompanionObjectReservation] = []
            while true {
                try Task.checkCancellation(); let status = sqlite3_step(s)
                if status == SQLITE_DONE { break }; guard status == SQLITE_ROW else { throw CompanionError.unavailable }
                objects.append(.init(sha256: try text(s, 0), byteCount: Int(sqlite3_column_int64(s, 1))))
            }
            for object in objects { try run("UPDATE objects SET state='deleting' WHERE id=?", [.text(object.sha256)]) }
            return objects
        }
    }
    public func completeObjectDeletion(sha256: String) throws { try writable(); try run("DELETE FROM objects WHERE id=? AND state='deleting'", [.text(sha256)]) }

    private func rows(_ predicate: String, _ bindings: [Binding], limit: Int, includeResult: Bool = false,
                      order: String = "j.observed DESC,j.id DESC", index: String? = nil) throws -> [CompanionDeliveryRecord] {
        let budget = beginReadBudget(); defer { endReadBudget(); withExtendedLifetime(budget) {} }
        let indexed = index.map { " INDEXED BY " + $0 } ?? ""
        let result = includeResult ? "r.payload" : "NULL"
        let s = try prepare("SELECT j.sequence,j.id,j.request,j.stage,j.observed,\(result),r.digest FROM jobs j\(indexed) LEFT JOIN results r ON r.job_id=j.id \(predicate) ORDER BY \(order) LIMIT ?", bindings + [.integer(Int64(limit))], budget: budget)
        defer { sqlite3_finalize(s) }; var values: [CompanionDeliveryRecord] = [], bytes = 0
        while true {
            try Task.checkCancellation(); guard !budget.expired else { throw CompanionError.capacityExceeded }
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { try Task.checkCancellation(); return values }
            if status == SQLITE_INTERRUPT { try Task.checkCancellation(); if budget.expired || budget.exhausted { throw CompanionError.capacityExceeded } }
            guard status == SQLITE_ROW, let stage = CompanionDeliveryStage(rawValue: try text(s, 3)) else { throw CompanionError.unavailable }
            let request = try blob(s, 2, 768 * 1024), id = try text(s, 1)
            guard Self.digest(request) == id else { throw CompanionError.conflictingPublication }
            bytes += request.count; guard bytes <= 64 * 1024 * 1024 else { throw CompanionError.capacityExceeded }
            let payload = sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : try blob(s, 5, 2 * 1024 * 1024)
            if let payload { guard Self.digest(payload) == (try text(s, 6)) else { throw CompanionError.conflictingPublication } }
            values.append(.init(sequence: sqlite3_column_int64(s, 0), jobID: id, requestPayload: request, resultPayload: payload,
                                stage: stage, observedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 4))))
        }
    }
    private final class ReadBudget {
        let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        var remaining: Int?
        var exhausted = false
        init(instructions: Int? = nil) { remaining = instructions }
        var expired: Bool { DispatchTime.now().uptimeNanoseconds >= deadline }
        func interrupt() -> Bool {
            if let remaining { self.remaining = remaining - 1; exhausted = remaining <= 1 }
            return expired || exhausted || Task<Never, Never>.isCancelled
        }
    }
    private func beginReadBudget() -> ReadBudget {
        #if DEBUG
        let instructionLimit = readInstructionLimitForTesting
        #else
        let instructionLimit: Int? = nil
        #endif
        let budget = ReadBudget(instructions: instructionLimit)
        sqlite3_progress_handler(db, instructionLimit == nil ? 1000 : 1, { raw in
            guard let raw else { return 1 }
            return Unmanaged<ReadBudget>.fromOpaque(raw).takeUnretainedValue().interrupt() ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
        return budget
    }
    private func endReadBudget() { sqlite3_progress_handler(db, 0, nil, nil) }
    private func request(_ data: Data) throws -> CompanionJobRequest {
        guard data.count <= 768 * 1024 else { throw CompanionError.invalidPayload }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let value = try decoder.decode(CompanionJobRequest.self, from: data); try value.validate()
        guard value.sourceStoreID == nativeStoreID else { throw CompanionError.nativeStoreMismatch }; return value
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func origin(_ date: Date) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try encoder.encode(decoder.decode(Date.self, from: encoder.encode(date)))
    }
    private func check() throws { guard !closed, db != nil else { throw CompanionError.closed }; try Task.checkCancellation() }
    private func writable() throws { try check(); guard !readOnly else { throw CompanionError.unavailable } }
    private enum Binding { case text(String), blob(Data), integer(Int64), real(Double), null }
    private func prepare(_ sql: String, _ bindings: [Binding] = [], budget: ReadBudget? = nil) throws -> OpaquePointer {
        guard let db else { throw CompanionError.closed }; var s: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &s, nil)
        guard status == SQLITE_OK, let s else {
            if let s { sqlite3_finalize(s) }
            if status == SQLITE_INTERRUPT {
                try Task.checkCancellation()
                if let budget, budget.expired || budget.exhausted { throw CompanionError.capacityExceeded }
            }
            throw CompanionError.unavailable
        }
        do {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, value) in bindings.enumerated() {
                let index = Int32(offset + 1), code: Int32
                switch value {
                case .text(let text): code = sqlite3_bind_text(s, index, text, -1, transient)
                case .blob(let data): code = data.withUnsafeBytes { sqlite3_bind_blob(s, index, $0.baseAddress, Int32($0.count), transient) }
                case .integer(let value): code = sqlite3_bind_int64(s, index, value)
                case .real(let value): code = sqlite3_bind_double(s, index, value)
                case .null: code = sqlite3_bind_null(s, index)
                }
                guard code == SQLITE_OK else { throw CompanionError.unavailable }
            }; return s
        } catch { sqlite3_finalize(s); throw error }
    }
    private func execute(_ sql: String) throws { guard let db, sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CompanionError.unavailable } }
    private func run(_ sql: String, _ bindings: [Binding] = []) throws { let s = try prepare(sql, bindings); defer { sqlite3_finalize(s) }; guard sqlite3_step(s) == SQLITE_DONE else { throw CompanionError.unavailable } }
    private func scalar(_ sql: String, _ bindings: [Binding] = []) throws -> Int64 { let s = try prepare(sql, bindings); defer { sqlite3_finalize(s) }; guard sqlite3_step(s) == SQLITE_ROW else { throw CompanionError.unavailable }; return sqlite3_column_int64(s, 0) }
    private func text(_ s: OpaquePointer, _ column: Int32) throws -> String { guard sqlite3_column_bytes(s, column) <= 256, let raw = sqlite3_column_text(s, column) else { throw CompanionError.invalidPayload }; return String(cString: raw) }
    private func blob(_ s: OpaquePointer, _ column: Int32, _ limit: Int) throws -> Data { let count = Int(sqlite3_column_bytes(s, column)); guard count > 0, count <= limit, let raw = sqlite3_column_blob(s, column) else { throw CompanionError.invalidPayload }; return Data(bytes: raw, count: count) }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try Task.checkCancellation(); try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try Task.checkCancellation(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private static let schema = """
        CREATE TABLE metadata(singleton INTEGER PRIMARY KEY,catalog_id TEXT NOT NULL,native_id TEXT NOT NULL,migrated INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE jobs(sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,request BLOB NOT NULL,kind TEXT NOT NULL,observed REAL NOT NULL,
            stage TEXT NOT NULL,active INTEGER NOT NULL,import_sequence INTEGER,source_start REAL,source_end REAL,recording_generation TEXT,continuity TEXT,origin BLOB,sample_start INTEGER,sample_end INTEGER,marker_id TEXT);
        CREATE INDEX jobs_history ON jobs(observed DESC,id DESC);
        CREATE INDEX jobs_active ON jobs(active,observed DESC,id DESC);
        CREATE INDEX jobs_active_sequence ON jobs(active,sequence DESC);
        CREATE INDEX jobs_context ON jobs(kind,active,observed DESC,id DESC);
        CREATE INDEX jobs_speaker_time ON jobs(source_start DESC,id DESC) WHERE kind='speaker' AND stage IN ('imported','acknowledged');
        CREATE INDEX jobs_source_samples ON jobs(recording_generation,continuity,origin,sample_start DESC,id DESC) WHERE kind='speaker' AND stage!='invalidated';
        CREATE TABLE results(job_id TEXT PRIMARY KEY,payload BLOB NOT NULL,digest TEXT NOT NULL);
        CREATE TABLE receipts(sequence INTEGER PRIMARY KEY AUTOINCREMENT,job_id TEXT NOT NULL,stage TEXT NOT NULL,UNIQUE(job_id,stage));
        CREATE TABLE publication_groups(id TEXT PRIMARY KEY,semantic_payload BLOB NOT NULL,receipt BLOB NOT NULL);
        CREATE TABLE batch_plans(sequence INTEGER PRIMARY KEY AUTOINCREMENT,batch_key TEXT NOT NULL,group_id TEXT NOT NULL);
        CREATE INDEX batch_plan_latest ON batch_plans(batch_key,sequence DESC);
        CREATE TRIGGER batch_plans_immutable BEFORE UPDATE ON batch_plans BEGIN SELECT RAISE(ABORT,'immutable plan'); END;
        CREATE TRIGGER batch_plans_retained BEFORE DELETE ON batch_plans BEGIN SELECT RAISE(ABORT,'retained plan'); END;
        CREATE TABLE objects(id TEXT PRIMARY KEY,bytes INTEGER NOT NULL,state TEXT NOT NULL);
        CREATE TABLE object_leases(owner TEXT NOT NULL,object_id TEXT NOT NULL,PRIMARY KEY(owner,object_id));
        CREATE INDEX object_lease_id ON object_leases(object_id);
        CREATE TABLE job_objects(job_id TEXT NOT NULL,object_id TEXT NOT NULL,PRIMARY KEY(job_id,object_id));
        CREATE INDEX object_job_ids ON job_objects(object_id,job_id);
        CREATE TABLE context_refresh(sequence INTEGER PRIMARY KEY AUTOINCREMENT,job_id TEXT NOT NULL UNIQUE,marker_id TEXT NOT NULL,completed INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX context_refresh_due ON context_refresh(completed,sequence);
        CREATE TRIGGER requests_immutable BEFORE UPDATE OF id,request,kind,observed,source_start,source_end,recording_generation,continuity,origin,sample_start,sample_end,marker_id ON jobs BEGIN SELECT RAISE(ABORT,'immutable request'); END;
        CREATE TRIGGER jobs_retained BEFORE DELETE ON jobs BEGIN SELECT RAISE(ABORT,'retained request'); END;
        CREATE TRIGGER results_immutable BEFORE UPDATE ON results BEGIN SELECT RAISE(ABORT,'immutable result'); END;
        CREATE TRIGGER results_retained BEFORE DELETE ON results BEGIN SELECT RAISE(ABORT,'retained result'); END;
        CREATE TRIGGER receipts_immutable BEFORE UPDATE ON receipts BEGIN SELECT RAISE(ABORT,'immutable receipt'); END;
        CREATE TRIGGER receipts_retained BEFORE DELETE ON receipts BEGIN SELECT RAISE(ABORT,'retained receipt'); END;
        CREATE TRIGGER groups_immutable BEFORE UPDATE ON publication_groups BEGIN SELECT RAISE(ABORT,'immutable group'); END;
        CREATE TRIGGER groups_retained BEFORE DELETE ON publication_groups BEGIN SELECT RAISE(ABORT,'retained group'); END;
        """
}
