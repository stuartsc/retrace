import Foundation
import Darwin
import Shared

protocol CompanionLeaseTransport: CompanionTransport {
    func grantExecution(id: String, attempt: String) async throws -> Bool
    func revokeExecution(id: String, attempt: String) async throws -> Bool
}

/// Durable remote-first audio routing. A lease is issued before any remote job
/// publication; local takeover waits for revocation/join or the bounded grant expiry.
/// Legacy context requests retain their existing remote transport.
public actor CompanionFallbackTransport: CompanionTransport {
    private struct Assignment: Codable {
        let attempt: String
        var submitted = false
        var local = false
        var legacyRemote: Bool?
        var leaseAcknowledged: Bool?
        var knownUnpublished: Bool?
        var publicationAttempted: Bool?
        var provenanceCatalogueID: UUID?
        var provenanceNativeStoreID: UUID?
    }
    typealias Execute = @Sendable (URL, String, @escaping @Sendable () async throws -> Void,
        @escaping @Sendable () throws -> Void) async throws -> Data
    private let remote: any CompanionLeaseTransport
    private let root: URL
    private let execute: Execute
    private let now: @Sendable () -> ContinuousClock.Instant
    private let spool: CompanionSpool
    private var assignments: [String: Assignment] = [:]
    private var leaseDeadlines: [String: ContinuousClock.Instant] = [:]
    private var unavailableSince: ContinuousClock.Instant?
    private var closed = false
    private var ownerLock: Int32?
    private var localWork: (id: String, task: Task<Void, Never>)?
    private var localResults: [String: Data] = [:]
    private var queuedDates: [String: Date] = [:]
    private var unassignedObjects = Set<String>()
    private var phase: CompanionProcessingStatus.Phase = .remotePending
    private var catalogueID: UUID?
    public init(remote: CompanionHTTPTransport, root: URL, nativeStoreID: UUID, local: CompanionLocalExecutor) {
        self.remote = remote; self.root = root
        execute = { root, id, onAdmitted, admission in
            try await local.execute(root: root, jobID: id, onAdmitted: onAdmitted, admission: admission)
        }
        now = { .now }
        spool = CompanionSpool(root: root, nativeStoreID: nativeStoreID)
    }
    init(remote: any CompanionLeaseTransport, root: URL, nativeStoreID: UUID,
         execute: @escaping Execute, now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.remote = remote; self.root = root; self.execute = execute; self.now = now
        spool = CompanionSpool(root: root, nativeStoreID: nativeStoreID)
    }
    private func initialize() throws {
        guard !closed else { throw CompanionError.closed }; try Task.checkCancellation()
        if ownerLock == nil { ownerLock = try spool.acquire() }
        try spool.initialize()
        for folder in ["assignments", "request-archive", "audio-jobs", "audio-results", "execution-results", "routing-receipts"] {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            try spool.directory(directory)
        }
    }
    private func path(_ folder: String, _ id: String) -> URL { root.appendingPathComponent(folder).appendingPathComponent(id + ".json") }
    private func assignment(_ id: String) throws -> Assignment {
        if let value = assignments[id] { return value }
        let file = path("assignments", id)
        let value: Assignment
        if FileManager.default.fileExists(atPath: file.path) {
            value = try JSONDecoder().decode(Assignment.self, from: spool.read(file, limit: 4096))
            try CompanionBounds.digest(value.attempt)
            // After a restart do not rely on a persisted wall clock to infer lease expiry.
            if value.submitted { leaseDeadlines[id] = now().advanced(by: .seconds(130)) }
        } else {
            guard assignments.count < 256 else { throw CompanionError.capacityExceeded }
            value = Assignment(attempt: CompanionWire.digest(Data(UUID().uuidString.utf8)))
        }
        assignments[id] = value; return value
    }
    private func save(_ value: Assignment, id: String) throws {
        // Assignment is the sole mutable owner record; media, requests and results remain immutable.
        let file = path("assignments", id)
        let data = try JSONEncoder().encode(value)
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".assignment-" + UUID().uuidString)
        defer { Darwin.unlink(temporary.path) }
        try spool.publish(data, to: temporary)
        guard Darwin.rename(temporary.path, file.path) == 0 else { throw CompanionError.unsafeStorage }
        let directory = Darwin.open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw CompanionError.unsafeStorage }
        defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else { throw CompanionError.unsafeStorage }
        assignments[id] = value
    }
    private func failed() { if unavailableSince == nil { unavailableSince = now() }; phase = .waitingForRemote }
    public func bindCatalogue(_ id: UUID) async throws { try initialize(); catalogueID = id }
    public func registerUnpublishedJob(id: String, data: Data) async throws {
        try initialize(); try CompanionBounds.digest(id)
        guard CompanionWire.digest(data) == id else { throw CompanionError.invalidPayload }
        let request = try CompanionWire.decode(CompanionJobRequest.self, data: data, limit: 768 * 1024)
        try request.validate()
        guard request.kind == .speaker else { return }
        guard request.sourceStoreID == spool.nativeStoreID, let catalogueID else { throw CompanionError.nativeStoreMismatch }
        // Existing ownership, including unknown historical delivery, is never
        // upgraded to "not sent" by replaying a publication callback.
        guard !spool.exists(path("assignments", id)), assignments[id] == nil else { return }
        var owner = try assignment(id)
        owner.knownUnpublished = true; owner.publicationAttempted = false
        owner.provenanceCatalogueID = catalogueID; owner.provenanceNativeStoreID = spool.nativeStoreID
        try save(owner, id: id)
    }
    public func publishObject(sha256: String, data: Data) async throws {
        try initialize(); try CompanionBounds.digest(sha256)
        guard data.count <= 16 * 1024 * 1024, CompanionWire.digest(data) == sha256 else { throw CompanionError.invalidPayload }
        let target = try spool.path("objects", sha256, suffix: ".m4a")
        if !spool.exists(target) {
            let objects = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("objects"), includingPropertiesForKeys: [.fileSizeKey])
            guard objects.count < 4096 else { throw CompanionError.capacityExceeded }
            let bytes = try objects.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            let free = try FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber
            guard bytes + data.count <= 1024 * 1024 * 1024, (free?.uint64Value ?? 0) >= 20 * 1024 * 1024 * 1024 else { throw CompanionError.capacityExceeded }
        }
        try spool.publishObject(.init(sha256: sha256, data: data))
        unassignedObjects.insert(sha256)
    }
    public func publishJob(id: String, data: Data) async throws {
        try initialize(); try CompanionBounds.digest(id)
        guard CompanionWire.digest(data) == id else { throw CompanionError.invalidPayload }
        let request = try CompanionWire.decode(CompanionJobRequest.self, data: data, limit: 768 * 1024)
        try request.validate()
        guard request.kind == .speaker else { try await remote.publishJob(id: id, data: data); return }
        if !FileManager.default.fileExists(atPath: path("request-archive", id).path) {
            guard try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("request-archive").path).count < 256 else { throw CompanionError.capacityExceeded }
        }
        try spool.publish(data, to: path("request-archive", id))
        unassignedObjects.subtract(request.speaker!.media.map(\.sha256))
        queuedDates[id] = request.observedAt
        var owner = try assignment(id)
        if owner.local { return }
        do {
            // Persist uncertainty BEFORE the request crosses the network boundary.
            owner.submitted = true; try save(owner, id: id)
            leaseDeadlines[id] = now().advanced(by: .seconds(130))
            let supportsLease = try await remote.grantExecution(id: id, attempt: owner.attempt)
            owner.legacyRemote = !supportsLease
            owner.leaseAcknowledged = supportsLease
            try save(owner, id: id)
            for media in request.speaker!.media {
                let bytes = try spool.read(spool.path("objects", media.sha256, suffix: ".m4a"), limit: 16 * 1024 * 1024)
                try await remote.publishObject(sha256: media.sha256, data: bytes)
            }
            // Record uncertainty before the job payload can reach any peer.
            owner.publicationAttempted = true; try save(owner, id: id)
            try await remote.publishJob(id: id, data: data)
            unavailableSince = nil; phase = .remotePending
        } catch is CancellationError { throw CancellationError() }
        catch { failed() } // The routing outbox now durably owns the pending job.
    }
    public func result(id: String) async throws -> Data? {
        try initialize()
        guard FileManager.default.fileExists(atPath: path("request-archive", id).path) else { return try await remote.result(id: id) }
        let owner = try assignment(id)
        if !owner.local {
            do {
                let remoteResult = try await remote.result(id: id)
                // Admission may have completed while this network read was suspended.
                if assignments[id]?.local == true { return localResults[id] }
                if let work = localWork, work.id == id { work.task.cancel(); await work.task.value; localWork = nil }
                if let value = remoteResult { unavailableSince = nil; return value }
                if owner.legacyRemote == true { return nil }
                // Renew before the 120-second native execution lease ends.
                leaseDeadlines[id] = now().advanced(by: .seconds(130))
                _ = try await remote.grantExecution(id: id, attempt: owner.attempt)
                let data = try spool.read(path("request-archive", id), limit: 768 * 1024)
                try await publishJob(id: id, data: data)
                return nil
            } catch is CancellationError { throw CancellationError() }
            catch { failed() }
            let neverPublished = owner.knownUnpublished == true && owner.publicationAttempted == false
                && catalogueID != nil && owner.provenanceCatalogueID == catalogueID
                && owner.provenanceNativeStoreID == spool.nativeStoreID
            guard owner.legacyRemote != true || neverPublished else { return nil }
            guard let since = unavailableSince, since.duration(to: now()) >= .seconds(300) else { return nil }
            let joined = (try? await remote.revokeExecution(id: id, attempt: owner.attempt)) == true
            guard neverPublished || joined || (owner.leaseAcknowledged == true && leaseDeadlines[id].map({ now() >= $0 }) == true) else { return nil }

        }
        let output = path("execution-results", id)
        if FileManager.default.fileExists(atPath: output.path) { return try spool.read(output, limit: 2 * 1024 * 1024) }
        if let value = localResults[id] { return value }
        guard localWork == nil else { return nil }
        phase = .waitingForQuiet
        let executorOwner = self
        let evidenceAdmission = CompanionTransportAdmission.current
        let task = Task { [execute, root] in
            do {
                let bytes = try await execute(root, id,
                    { try await executorOwner.claimLocal(id) },
                    { if let evidenceAdmission { try evidenceAdmission({}) } })
                await executorOwner.finishedLocal(id, bytes: bytes)
            } catch { await executorOwner.finishedLocal(id, bytes: nil) }
        }
        localWork = (id, task)
        return nil
    }
    private func claimLocal(_ id: String) throws {
        guard !closed, let since = unavailableSince, since.duration(to: now()) >= .seconds(300) else { throw CancellationError() }
        var owner = try assignment(id)
        owner.local = true; try save(owner, id: id)
        phase = .improvingTextAndSpeakers
    }
    private func finishedLocal(_ id: String, bytes: Data?) {
        if !closed, let bytes { localResults[id] = bytes }
        if localWork?.id == id { localWork = nil }
        if bytes == nil { phase = .waitingForQuiet }
    }
    public func acknowledge(id: String, resultSHA256: String) async throws {
        try initialize(); try CompanionBounds.digest(resultSHA256)
        // A result can be atomically visible before its executor returns. Join
        // its reader before publishing acknowledgement or collecting any input.
        if let work = localWork, work.id == id {
            work.task.cancel(); await work.task.value
            if localWork?.id == id { localWork = nil }
        }
        let receipt = path("routing-receipts", id)
        if spool.exists(receipt) {
            guard try spool.read(receipt, limit: 64) == Data(resultSHA256.utf8) else { throw CompanionError.conflictingPublication }
            try collectAcknowledged(id); return
        }
        if FileManager.default.fileExists(atPath: path("assignments", id).path) { _ = try assignment(id) }
        if assignments[id]?.local != true { try await remote.acknowledge(id: id, resultSHA256: resultSHA256) }
        else {
            guard CompanionWire.digest(try spool.read(path("execution-results", id), limit: 2 * 1024 * 1024)) == resultSHA256 else { throw CompanionError.conflictingPublication }
        }
        try spool.publish(Data(resultSHA256.utf8), to: receipt)
        try collectAcknowledged(id)
    }
    private func collectAcknowledged(_ id: String) throws {
        // These are transfer copies only. The native delivery catalogue already retained the imported result.
        for folder in ["request-archive", "assignments", "execution-results"] {
            let file = path(folder, id)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        assignments[id] = nil; localResults[id] = nil; queuedDates[id] = nil; leaseDeadlines[id] = nil
        let requests = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("request-archive"), includingPropertiesForKeys: nil)
        guard requests.count <= 256 else { throw CompanionError.capacityExceeded }
        var retained = unassignedObjects
        for file in requests {
            let request = try CompanionWire.decode(CompanionJobRequest.self, data: spool.read(file, limit: 768 * 1024), limit: 768 * 1024)
            retained.formUnion(request.speaker?.media.map(\.sha256) ?? [])
        }
        // A concurrent local worker can hold an AAC reader; collect only while it is joined.
        if localWork == nil {
            for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("objects"), includingPropertiesForKeys: [.fileSizeKey]) {
                let hash = file.deletingPathExtension().lastPathComponent
                if !retained.contains(hash) {
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    try spool.removeObject(.init(sha256: hash, byteCount: size))
                }
            }
            if requests.isEmpty {
                for folder in ["audio-jobs", "audio-results"] {
                    let directory = root.appendingPathComponent(folder)
                    for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: item) }
                }
            }
        }
    }
    public func processingStatus() async -> CompanionProcessingStatus? {
        guard !closed, !queuedDates.isEmpty else { return nil }
        return .init(phase: phase, worker: phase == .waitingForQuiet || phase == .improvingTextAndSpeakers ? .thisMac : .otherMac,
                     oldestQueuedAt: queuedDates.values.min())
    }
    public func close() async {
        closed = true; let work = localWork; work?.task.cancel(); await work?.task.value
        localWork = nil; await remote.close()
        if let lock = ownerLock { Darwin.close(lock); ownerLock = nil }
    }
}
