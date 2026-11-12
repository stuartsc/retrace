import Foundation
import Darwin
import Shared
import Database

public protocol CompanionTransport: Sendable {
    func publishObject(sha256: String, data: Data) async throws
    func publishJob(id: String, data: Data) async throws
    func result(id: String) async throws -> Data?
    func acknowledge(id: String, resultSHA256: String) async throws
    func close() async
}
public struct CompanionMediaObject: Sendable {
    public let sha256: String
    public let data: Data
    public init(sha256: String, data: Data) { self.sha256 = sha256; self.data = data }
}
public struct CompanionDeliveryStatus: Sendable {
    public typealias State = CompanionDeliveryStage
    public let jobID: String
    public let kind: CompanionJobRequest.Kind
    public let observedAt: Date
    public let state: State
}

/// Only the source owner may classify a missing/replaced source as terminal. A revoked
/// session or unavailable permission remains a retryable admission failure.
enum CompanionSourceInvalidated: Error { case unavailable }
/// Only a never-committed proposal whose expected head is obsolete is terminal.
enum CompanionProposalSuperseded: Error { case marker(UUID) }
struct CompanionContextRefresh: Sendable {
    let jobID: String
    let markerID: UUID
}
struct CompanionContextCandidate: Sendable {
    let jobID: String
    let request: CompanionJobRequest
    let state: CompanionDeliveryStatus.State
}
enum CompanionTransmissionRevoked: Error { case changed }
enum CompanionAdmissionUnavailable: Error { case revoked }
enum CompanionTransportAdmission {
    @TaskLocal static var current: CompanionHTTPTransport.Admission?
}

/// App-owned durable outbox and imported-result repository. Construction is inert.
/// Revalidation owns current policy and exact reference resolution. Import callbacks must
/// be retry-safe by jobID because a crash can follow their commit before the local receipt.
public actor CompanionEnrichmentService {
    public typealias Revalidate = @Sendable (CompanionJobRequest) async throws -> Void
    public typealias Import = @Sendable (CompanionJobRequest, CompanionResult, Data, Data) async throws -> Void
    private let spool: CompanionSpool
    private let catalog: CompanionDeliveryDatabase
    private let transport: any CompanionTransport
    private let revalidate: Revalidate
    private let importResult: Import
    private let transmissionAdmission: @Sendable () -> CompanionHTTPTransport.Admission?
    private var ready = false
    private var lease: Int32?
    private var initialization: Task<Void, Error>?
    private var terminal = false
    private var synchronized: (UUID, Task<Int, Error>)?
    private var lastRefreshSequence: Int64 = 0
    private var lastDeliverySequence: Int64?
    private var closing: Task<Void, Error>?
    private struct Operation: Sendable {
        let cancel: @Sendable () -> Void
        let join: @Sendable () async -> Void
    }
    private var operations: [UUID: Operation] = [:]

    public init(root: URL, nativeStoreID: UUID, transport: any CompanionTransport,
                revalidate: @escaping Revalidate, importResult: @escaping Import,
                transmissionAdmission: @escaping @Sendable () -> CompanionHTTPTransport.Admission? = { nil }) {
        spool = CompanionSpool(root: root, nativeStoreID: nativeStoreID)
        catalog = .init(databasePath: root.appendingPathComponent("delivery.db").path, nativeStoreID: nativeStoreID)
        self.transport = transport; self.revalidate = revalidate; self.importResult = importResult
        self.transmissionAdmission = transmissionAdmission
    }
    @discardableResult public func publish(_ request: CompanionJobRequest, objects: [CompanionMediaObject] = []) async throws -> String {
        let data = try CompanionWire.encode(request)
        let receipt = try await publishGroup(semanticPayload: data, requests: [request], objects: objects)
        guard let id = receipt.jobIDs.first else { throw CompanionError.invalidPayload }; return id
    }
    func publicationGroup(semanticPayload: Data) async throws -> CompanionBatchPublicationReceipt? {
        try await perform { try await self.initialize(); return try await self.catalog.group(groupID: CompanionWire.digest(semanticPayload)) }
    }
    func latestBatchGroup(batchKey: String) async throws -> CompanionBatchPublicationReceipt? {
        try await perform { try await self.initialize(); return try await self.catalog.latestBatchGroup(batchKey: batchKey) }
    }
    /// The full fragment set and its group receipt are committed together. Staged objects
    /// are leased through publication so concurrent acknowledgement cleanup cannot remove them.
    @discardableResult func publishGroup(semanticPayload: Data, requests: [CompanionJobRequest],
                                         objects: [CompanionMediaObject] = [], batchKey: String? = nil, coverageJobIDs: [String] = []) async throws -> CompanionBatchPublicationReceipt {
        try await perform { try await self.publishOwned(semanticPayload: semanticPayload, requests: requests, objects: objects, batchKey: batchKey, coverageJobIDs: coverageJobIDs) }
    }
    private func publishOwned(semanticPayload: Data, requests: [CompanionJobRequest],
                              objects: [CompanionMediaObject], batchKey: String?, coverageJobIDs: [String]) async throws -> CompanionBatchPublicationReceipt {
        guard !semanticPayload.isEmpty, semanticPayload.count <= 768 * 1024, requests.count <= 32,
              objects.count <= 32, objects.reduce(0, { $0 + $1.data.count }) <= 64 * 1024 * 1024 else { throw CompanionError.capacityExceeded }
        for request in requests {
            try request.validate(); guard request.sourceStoreID == spool.nativeStoreID else { throw CompanionError.nativeStoreMismatch }
            try await revalidate(request); try Task.checkCancellation()
        }
        try await initialize()
        if let old = try await catalog.group(groupID: CompanionWire.digest(semanticPayload)) {
            try await validateCoverage(old.jobIDs + old.coverageJobIDs); return old
        }
        try await validateCoverage(coverageJobIDs)
        let expected = Dictionary(grouping: requests.flatMap { $0.speaker?.media ?? [] }, by: \.sha256)
        let reservations = try expected.map { hash, slices -> CompanionObjectReservation in
            guard let first = slices.first, slices.allSatisfy({ $0.byteCount == first.byteCount }) else { throw CompanionError.invalidPayload }
            return .init(sha256: hash, byteCount: first.byteCount)
        }
        guard Set(objects.map(\.sha256)).count == objects.count else { throw CompanionError.invalidPayload }
        for object in objects {
            guard let slices = expected[object.sha256], slices.allSatisfy({ $0.byteCount == object.data.count }),
                  CompanionWire.digest(object.data) == object.sha256 else { throw CompanionError.invalidPayload }
        }
        let reservation = UUID()
        try await catalog.reserveObjects(reservations, owner: reservation)
        do {
            for object in objects { try spool.publishObject(object) }
            for object in reservations {
                let bytes = try spool.read(spool.path("objects", object.sha256, suffix: ".m4a"), limit: 16 * 1024 * 1024)
                guard bytes.count == object.byteCount, CompanionWire.digest(bytes) == object.sha256 else { throw CompanionError.invalidPayload }
                try await catalog.markObjectReady(object)
            }
            for request in requests { try await revalidate(request); try Task.checkCancellation() }
            try await validateCoverage(coverageJobIDs)
            return try await catalog.publishGroup(semanticPayload: semanticPayload, requests: requests.map { try CompanionWire.encode($0) }, reservationID: reservation, batchKey: batchKey, coverageJobIDs: coverageJobIDs)
        } catch {
            // Cancellation must not strand a lease. The joined cleanup has no network work.
            let cleanup = Task { try await catalog.releaseObjectReservation(reservation) }; _ = await cleanup.result
            throw error
        }
    }
    private func validateCoverage(_ ids: [String]) async throws {
        guard ids.count <= 288 else { throw CompanionError.capacityExceeded }
        for id in Set(ids) {
            guard let record = try await catalog.record(jobID: id, includeResult: false), record.stage != .invalidated else { throw CompanionError.staleEvidence }
            try await revalidate(decodeRequest(record)); try Task.checkCancellation()
        }
    }
    @discardableResult public func synchronize(limit: Int = 8) async throws -> Int {
        guard !terminal else { throw CompanionError.closed }
        guard (1...32).contains(limit) else { throw CompanionError.invalidPayload }
        if let synchronized { return try await synchronized.1.value }
        let id = UUID(), task = Task { try await self.perform { try await self.synchronizeOwned(limit: limit) } }
        synchronized = (id, task)
        do {
            let count = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            if synchronized?.0 == id { synchronized = nil }; return count
        } catch { if synchronized?.0 == id { synchronized = nil }; throw error }
    }
    private func synchronizeOwned(limit: Int) async throws -> Int {
        try await initialize()
        var pending = try await catalog.activeRecords(beforeSequence: lastDeliverySequence, limit: limit)
        if pending.count < limit, lastDeliverySequence != nil {
            let wrap = try await catalog.activeRecords(limit: limit), seen = Set(pending.map(\.jobID))
            pending += wrap.filter { !seen.contains($0.jobID) }.prefix(limit - pending.count)
        }
        lastDeliverySequence = pending.last?.sequence
        var completed = 0, firstFailure: (any Error)?
        for record in pending {
            try Task.checkCancellation()
            do { if try await synchronizeOne(record) { completed += 1 } }
            catch is CancellationError { throw CancellationError() }
            catch CompanionProposalSuperseded.marker(let markerID) { try await catalog.supersede(jobID: record.jobID, markerID: markerID) }
            catch CompanionError.staleMarker { try await catalog.transition(jobID: record.jobID, stage: .invalidated) }
            catch is CompanionSourceInvalidated { try await catalog.transition(jobID: record.jobID, stage: .invalidated) }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        try await collectGarbage()
        if let firstFailure { throw firstFailure }; return completed
    }
    private func synchronizeOne(_ record: CompanionDeliveryRecord) async throws -> Bool {
        let id = record.jobID, request = try decodeRequest(record)
        try await revalidate(request); try Task.checkCancellation()
        if record.stage == .queued {
            var sent = Set<String>()
            for object in request.speaker?.media ?? [] where sent.insert(object.sha256).inserted {
                let data = try spool.read(spool.path("objects", object.sha256, suffix: ".m4a"), limit: 16 * 1024 * 1024)
                guard CompanionWire.digest(data) == object.sha256, data.count == object.byteCount else { throw CompanionError.invalidPayload }
                let permit = try await validatedTransmission(request)
                try await CompanionTransportAdmission.$current.withValue(permit) { try await transport.publishObject(sha256: object.sha256, data: data) }
                try Task.checkCancellation()
            }
            let permit = try await validatedTransmission(request)
            try await CompanionTransportAdmission.$current.withValue(permit) { try await transport.publishJob(id: id, data: record.requestPayload) }
            try Task.checkCancellation(); try await catalog.transition(jobID: id, stage: .published)
        }
        let resultData: Data
        if let retained = try await catalog.record(jobID: id)?.resultPayload { resultData = retained }
        else {
            let permit = try await validatedTransmission(request)
            let downloaded = try await CompanionTransportAdmission.$current.withValue(permit) { try await transport.result(id: id) }
            guard let downloaded else { return false }; resultData = downloaded
        }
        let result = try CompanionWire.decode(CompanionResult.self, data: resultData, limit: 2 * 1024 * 1024)
        try CompanionWire.validate(result, request: request, id: id); try Task.checkCancellation()
        try await catalog.storeResult(jobID: id, payload: resultData)
        if record.stage != .imported {
            try await revalidate(request); try Task.checkCancellation()
            try await importResult(request, result, record.requestPayload, resultData)
            try Task.checkCancellation(); try await catalog.transition(jobID: id, stage: .imported)
        }
        let permit = try await validatedTransmission(request)
        try await CompanionTransportAdmission.$current.withValue(permit) { try await transport.acknowledge(id: id, resultSHA256: CompanionWire.digest(resultData)) }
        try Task.checkCancellation(); try await catalog.transition(jobID: id, stage: .acknowledged); return true
    }
    private func validatedTransmission(_ request: CompanionJobRequest) async throws -> CompanionHTTPTransport.Admission? {
        let permit = transmissionAdmission(); try await revalidate(request); try Task.checkCancellation(); return permit
    }
    public func status() async throws -> [CompanionDeliveryStatus] {
        try await perform {
            try await self.initialize()
            return try await self.catalog.records(activeOnly: false).map { record in
                let request = try self.decodeRequest(record)
                return .init(jobID: record.jobID, kind: request.kind, observedAt: record.observedAt, state: record.stage)
            }
        }
    }
    func pendingCount() async throws -> Int { try await perform { try await self.initialize(); return try await self.catalog.activeCount() } }
    func speakerCoverage(intersecting source: LiveAudioSampleIdentity) async throws -> [(String, CompanionJobRequest)] {
        try await perform {
            try await self.initialize()
            return try await self.catalog.speakerCoverage(intersecting: source).map { ($0.jobID, try self.decodeRequest($0)) }
        }
    }
    func pendingContextRefreshes(limit: Int = 8) async throws -> [CompanionContextRefresh] {
        try await perform { try await self.pendingRefreshesOwned(limit: limit) }
    }
    private func pendingRefreshesOwned(limit: Int) async throws -> [CompanionContextRefresh] {
        try await initialize()
        var pending = try await catalog.pendingRefreshes(afterSequence: lastRefreshSequence, limit: limit)
        if pending.count < limit, lastRefreshSequence > 0 {
            let wrap = try await catalog.pendingRefreshes(afterSequence: 0, limit: limit)
            let seen = Set(pending.map(\.jobID))
            pending += wrap.filter { !seen.contains($0.jobID) }.prefix(limit - pending.count)
        }
        if let last = pending.last { lastRefreshSequence = last.sequence }
        return pending.map { .init(jobID: $0.jobID, markerID: $0.markerID) }
    }
    func completeContextRefresh(jobID: String) async throws {
        try await perform { try await self.initialize(); try await self.catalog.completeRefresh(jobID: jobID) }
    }
    func contextCandidates(currentHeadJobID: String? = nil) async throws -> [CompanionContextCandidate] {
        try await perform {
            try await self.initialize()
            var records = try await self.catalog.records(activeOnly: true, kind: .context)
            if let id = currentHeadJobID, !records.contains(where: { $0.jobID == id }),
               let record = try await self.catalog.record(jobID: id, includeResult: false), record.stage != .invalidated { records.append(record) }
            return try records.map { .init(jobID: $0.jobID, request: try self.decodeRequest($0), state: $0.stage) }
        }
    }
    func request(jobID: String) async throws -> CompanionJobRequest? {
        try await perform {
            try await self.initialize()
            guard let record = try await self.catalog.record(jobID: jobID, includeResult: false), record.stage != .invalidated else { return nil }
            return try self.decodeRequest(record)
        }
    }
    public func retainedResult(jobID: String) async throws -> CompanionResult? { try await perform { try await self.readRetained(jobID)?.1 } }
    func retainedRequest(jobID: String) async throws -> CompanionJobRequest? { try await perform { try await self.readRetained(jobID)?.0 } }
    private func readRetained(_ id: String) async throws -> (CompanionJobRequest, CompanionResult)? {
        try await initialize()
        guard let record = try await catalog.record(jobID: id), [.imported, .acknowledged].contains(record.stage), let data = record.resultPayload else { return nil }
        let request = try decodeRequest(record), result = try CompanionWire.decode(CompanionResult.self, data: data, limit: 2 * 1024 * 1024)
        try CompanionWire.validate(result, request: request, id: id)
        try await revalidate(request); try Task.checkCancellation(); return (request, result)
    }
    private nonisolated func decodeRequest(_ record: CompanionDeliveryRecord) throws -> CompanionJobRequest {
        guard CompanionWire.digest(record.requestPayload) == record.jobID else { throw CompanionError.conflictingPublication }
        let request = try CompanionWire.decode(CompanionJobRequest.self, data: record.requestPayload, limit: 768 * 1024)
        try request.validate(); guard request.sourceStoreID == spool.nativeStoreID else { throw CompanionError.nativeStoreMismatch }; return request
    }
    public func beginClose() {
        terminal = true; synchronized?.1.cancel(); initialization?.cancel(); for operation in operations.values { operation.cancel() }
    }
    public func close() async throws {
        beginClose(); if let closing { return try await closing.value }
        let active = Array(operations.values), sync = synchronized?.1, initial = initialization
        let task = Task {
            if let sync { _ = await sync.result }; if let initial { _ = await initial.result }
            for operation in active { await operation.join() }
            await transport.close(); try await catalog.close()
            if let lease = self.lease { Darwin.close(lease); self.lease = nil }
        }
        closing = task
        do { try await task.value } catch { closing = nil; throw error }
    }
    private func initialize() async throws {
        try Task.checkCancellation(); guard !terminal else { throw CompanionError.closed }
        if ready { return }; if let initialization { return try await initialization.value }
        let task = Task { try await self.initializeOwned() }; initialization = task
        do { try await task.value; ready = true; initialization = nil }
        catch { initialization = nil; throw error }
    }
    private func initializeOwned() async throws {
        if lease == nil { lease = try spool.acquire() }
        try spool.initialize(); try await catalog.initialize()
        try await catalog.recoverPublicationReservations()
        if !(try await catalog.migrationComplete()) { try await migrateLegacy(); try await catalog.completeLegacyMigration() }
    }
    private func migrateLegacy() async throws {
        let paths = try spool.entries("requests")
        guard paths.count <= 256 else { throw CompanionError.capacityExceeded }
        // Old staged objects were already confined to this private spool. Validate every
        // filename/hash before adopting it; unknown files are never guessed or deleted.
        let reservation = UUID()
        for path in try spool.entries("objects") {
            guard path.pathExtension == "m4a" else { throw CompanionError.unsafeStorage }
            let hash = path.deletingPathExtension().lastPathComponent; try CompanionBounds.digest(hash)
            let bytes = try spool.read(path, limit: 16 * 1024 * 1024)
            guard CompanionWire.digest(bytes) == hash else { throw CompanionError.conflictingPublication }
            let object = CompanionObjectReservation(sha256: hash, byteCount: bytes.count)
            try await catalog.reserveObjects([object], owner: reservation); try await catalog.markObjectReady(object)
        }
        for path in paths {
            try Task.checkCancellation(); guard path.pathExtension == "json" else { throw CompanionError.unsafeStorage }
            let id = path.deletingPathExtension().lastPathComponent, data = try spool.read(path, limit: 768 * 1024)
            guard CompanionWire.digest(data) == id else { throw CompanionError.conflictingPublication }
            let request = try CompanionWire.decode(CompanionJobRequest.self, data: data, limit: 768 * 1024)
            try request.validate()
            let resultPath = try spool.path("results", id)
            let result = spool.exists(resultPath) ? try spool.read(resultPath, limit: 2 * 1024 * 1024) : nil
            if let result { try CompanionWire.validate(CompanionWire.decode(CompanionResult.self, data: result, limit: 2 * 1024 * 1024), request: request, id: id) }
            var stage: CompanionDeliveryStage = result == nil ? .queued : .received
            for item in ["published", "imported", "acknowledged"] {
                let receipt = try spool.path("receipts", id, suffix: "." + item)
                if spool.exists(receipt) {
                    let expected: Data
                    if item == "published" { expected = Data(id.utf8) }
                    else { guard let result else { throw CompanionError.conflictingPublication }; expected = Data(CompanionWire.digest(result).utf8) }
                    guard try spool.read(receipt, limit: 64) == expected else { throw CompanionError.conflictingPublication }
                    if item != "published" || result == nil { stage = CompanionDeliveryStage(rawValue: item)! }
                }
            }
            if stage == .acknowledged {
                guard spool.exists(try spool.path("receipts", id, suffix: ".imported")) else { throw CompanionError.conflictingPublication }
            }
            var superseded: UUID?, refreshed = false
            for item in ["invalidated", "superseded", "refreshed"] {
                let receipt = try spool.path("receipts", id, suffix: "." + item)
                if spool.exists(receipt) {
                    guard try spool.read(receipt, limit: 64) == Data(id.utf8) else { throw CompanionError.conflictingPublication }
                    if item == "refreshed" { refreshed = true }
                    else { stage = .invalidated }
                    if item == "superseded" { guard let marker = request.context?.markerID else { throw CompanionError.invalidPayload }; superseded = marker }
                }
            }
            guard !refreshed || superseded != nil else { throw CompanionError.conflictingPublication }
            try await catalog.importLegacy(requestPayload: data, resultPayload: result, stage: stage, supersededMarkerID: superseded, refreshCompleted: refreshed)
        }
        try await catalog.releaseObjectReservation(reservation)
    }
    private func collectGarbage() async throws {
        for object in try await catalog.claimObjectGarbage(limit: 16) {
            try Task.checkCancellation(); try spool.removeObject(object)
            try await catalog.completeObjectDeletion(sha256: object.sha256)
        }
    }
    private func perform<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !terminal else { throw CompanionError.closed }; try Task.checkCancellation()
        let id = UUID(), task = Task { try await body() }
        operations[id] = Operation(cancel: { task.cancel() }, join: { _ = await task.result })
        defer { operations[id] = nil }
        return try await withTaskCancellationHandler(operation: { let value = try await task.value; try Task.checkCancellation(); return value }, onCancel: { task.cancel() })
    }
}
