import CryptoKit
import Foundation
import Shared

public enum RetraceCommandError: Error, Sendable {
    case invalidArguments, unavailable, revisionConflict, notPermitted
}

public struct RetraceCommandContext: Sendable {
    public let clientID: String
    public let requestID: UUID
    public let arguments: RetraceJSON
    /// A command handler may use this grant only for the operation currently being dispatched.
    public let capability: RetraceCapability
    /// Immutable admission snapshot; every source read also rechecks the live grant.
    public let capabilities: Set<RetraceCapability>
    public let mutationFence: NativeMutationFence
    let jobProgress: @Sendable (ExactOCRRepairPhase) async -> Void
    let retentionProgress: @Sendable (RetentionCommandPhase) async -> Void
    let authorization: @Sendable () async throws -> Void
    let sourceAuthorization: @Sendable (RetraceCapability) async throws -> Void
    public func reportProgress(_ phase: ExactOCRRepairPhase) async { await jobProgress(phase) }
    public func reportRetentionProgress(_ phase: RetentionCommandPhase) async { await retentionProgress(phase) }
    public func authorize() async throws { try await authorization() }
    public func authorize(_ capability: RetraceCapability) async throws { try await sourceAuthorization(capability) }
}

public struct RetracePreviewMaterial: Sendable {
    public let summary: String
    public let revision: String
    public let affectedCount: Int
    public let details: RetraceJSON?
    public init(summary: String, revision: String, affectedCount: Int, details: RetraceJSON? = nil) {
        self.summary = summary; self.revision = revision; self.affectedCount = affectedCount
        self.details = details
    }
}

public struct RetraceCommandHandler: Sendable {
    public let operation: RetraceOperation
    public let runsAsJob: Bool
    public let preview: (@Sendable (RetraceCommandContext) async throws -> RetracePreviewMaterial)?
    public let execute: @Sendable (RetraceCommandContext) async throws -> RetraceJSON
    public init(operation: RetraceOperation, runsAsJob: Bool = false,
                preview: (@Sendable (RetraceCommandContext) async throws -> RetracePreviewMaterial)? = nil,
                execute: @escaping @Sendable (RetraceCommandContext) async throws -> RetraceJSON) {
        self.operation = operation; self.runsAsJob = runsAsJob; self.preview = preview; self.execute = execute
    }
}

/// All callers enter the same App-owned operation handlers. No tool supplies a native path,
/// shell command, arbitrary query, an arbitrary handler name, or a substituted client identity.
public actor RetraceCommandDispatcher {
    private let ledger: RetraceCommandLedger
    private var grants: [RetraceClientGrant]
    private let handlers: [RetraceOperation: RetraceCommandHandler]
    private var terminal = false
    private var activeScopes: Set<UUID> = []
    private var mutationFences: [UUID: NativeMutationFence] = [:]
    private var work: [UUID: Task<RetraceCommandResponse, Never>] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
#if DEBUG
    private var jobReadCheckpoint: (@Sendable () async -> Void)?
    func holdNextJobReadForTesting(_ checkpoint: @escaping @Sendable () async -> Void) {
        jobReadCheckpoint = checkpoint
    }
#endif

    public init(directory: URL, grants: [RetraceClientGrant], handlers: [RetraceCommandHandler]) throws {
        try Self.validate(grants)
        guard Set(handlers.map(\.operation)).count == handlers.count,
              handlers.allSatisfy({ (!$0.operation.requiresPreview || $0.preview != nil) && (!$0.runsAsJob || $0.operation.mutates) }),
              !handlers.contains(where: { [.manifest, .jobRead, .jobCancel].contains($0.operation) }) else { throw RetraceCommandError.invalidArguments }
        self.ledger = try RetraceCommandLedger(directory: directory)
        self.grants = grants; self.handlers = Dictionary(uniqueKeysWithValues: handlers.map { ($0.operation, $0) })
    }

    /// Local owner only; never an MCP operation. Revocation cancels admitted operations and is
    /// rechecked before returning any result. Cancellation cannot reverse an already committed effect.
    public func replaceGrants(_ newGrants: [RetraceClientGrant]) throws {
        try Self.validate(newGrants)
        for fence in mutationFences.values { fence.invalidate() }
        grants = newGrants
        for task in work.values { task.cancel() }
        for task in jobs.values { task.cancel() }
    }

    public func execute(_ request: RetraceCommandRequest, bearerToken: String) async -> RetraceCommandResponse {
        guard !terminal else { return response(request, .unavailable, "app_closed") }
        guard let grant = authenticate(bearerToken), permits(grant, request.operation) else { return response(request, .denied, "not_permitted") }
        guard let bytes = try? RetraceWire.encoder().encode(request), bytes.count <= 65_536,
              bounded(request.arguments) else { return response(request, .failed, "invalid_arguments") }
        let taskID = UUID()
        guard work.count < 8 else { return response(request, .unavailable, "busy") }
        let task = Task { await perform(request, grant: grant) }
        work[taskID] = task
        defer { work[taskID] = nil }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !terminal, grants.contains(grant), permits(grant, request.operation) else { return response(request, .denied, "grant_revoked") }
        return result
    }

    public func close() async {
        terminal = true
        for fence in mutationFences.values { fence.invalidate() }
        let admitted = Array(work.values)
        for task in admitted { task.cancel() }
        for task in admitted { _ = await task.value }
        work.removeAll()
        let runningJobs = Array(jobs.values)
        for task in runningJobs { task.cancel() }
        for task in runningJobs { await task.value }
        jobs.removeAll()
        ledger.close()
    }

    public nonisolated static func tokenDigest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func perform(_ request: RetraceCommandRequest, grant: RetraceClientGrant) async -> RetraceCommandResponse {
        if request.operation == .manifest {
            let jobEntries: [RetraceCapabilityManifest.Entry] = handlers.values.contains(where: \.runsAsJob) && (grant.capabilities.contains(.processing) || grant.capabilities.contains(.maintenance)) ? [.init(operation: .jobRead, capability: grant.capabilities.contains(.processing) ? .processing : .maintenance, requiresPreview: false), .init(operation: .jobCancel, capability: grant.capabilities.contains(.processing) ? .processing : .maintenance, requiresPreview: false)] : []
            let entries = ([RetraceCapabilityManifest.Entry(operation: .manifest, requiresPreview: false)] + jobEntries + handlers.values
                .filter { permits(grant, $0.operation) }.map { .init(operation: $0.operation, requiresPreview: $0.preview != nil) })
                .sorted { $0.operation.rawValue < $1.operation.rawValue }
            return response(request, .succeeded, data: try? .encode(RetraceCapabilityManifest(operations: entries)))
        }
        let handler: RetraceCommandHandler
        if request.operation == .jobRead || request.operation == .jobCancel {
            guard handlers.values.contains(where: \.runsAsJob) else { return response(request, .unavailable, "operation_unavailable") }
            handler = .init(operation: request.operation) { [weak self] context in
                guard let self else { throw RetraceCommandError.unavailable }
                return try await self.jobOperation(context, cancel: request.operation == .jobCancel)
            }
        } else if let registered = handlers[request.operation] { handler = registered }
        else { return response(request, .unavailable, "operation_unavailable") }
        let scope = UUID()
        activeScopes.insert(scope)
        let mutationFence = NativeMutationFence(expiresAt: grant.expiresAt); mutationFences[scope] = mutationFence
        defer { mutationFence.invalidate(); mutationFences[scope] = nil; activeScopes.remove(scope) }
        let context = RetraceCommandContext(clientID: grant.clientID, requestID: request.requestID, arguments: request.arguments, capability: request.operation.capability, capabilities: grant.capabilities, mutationFence: mutationFence, jobProgress: { _ in }, retentionProgress: { _ in }, authorization: { [weak self] in
            guard let self else { throw RetraceCommandError.notPermitted }
            try await self.checkScope(scope, grant: grant, operation: request.operation)
        }, sourceAuthorization: { [weak self] capability in
            guard let self else { throw RetraceCommandError.notPermitted }
            try await self.checkScope(scope, grant: grant, operation: request.operation, additional: capability)
        })
        var reserved = false
        do {
            try Task.checkCancellation()
            let digest = Self.digest(try RetraceWire.encoder().encode(request))
            let payloadDigest = Self.digest(try RetraceWire.encoder().encode(Payload(operation: request.operation, arguments: request.arguments)))
            if request.operation.mutates {
                if let previous = try ledger.lookup(client: grant.clientID, request: request.requestID, digest: digest) {
                    if let previous {
                        if request.operation == .jobCancel, let data = previous.data {
                            let job = try data.decode(RetraceCommandJob.self)
                            try check(grant, job.operation)
                        }
                        // Receipts describe historical outcomes. They are never a current evidence snapshot.
                        return .init(requestID: request.requestID, status: previous.status, code: previous.code,
                                     observedAt: previous.observedAt, replayed: true, data: previous.data, preview: previous.preview)
                    }
                    return response(request, .indeterminate, "reserved_outcome_unknown")
                }
            }
            if request.mode == .preview {
                guard request.operation.mutates, let makePreview = handler.preview, request.confirmation == nil else { throw RetraceCommandError.invalidArguments }
                let material = try await makePreview(context)
                try check(grant, request.operation)
                guard material.summary.utf8.count <= 4096, !material.revision.isEmpty,
                      material.revision.utf8.count <= 1024, material.affectedCount >= 0 else { throw RetraceCommandError.invalidArguments }
                if let details = material.details {
                    guard bounded(details), try RetraceWire.encoder().encode(details).count <= 65_536 else { throw RetraceCommandError.invalidArguments }
                }
                let preview = RetraceDestructivePreview(id: UUID(), digest: payloadDigest, summary: material.summary,
                    revision: material.revision, affectedCount: material.affectedCount, expiresAt: Date().addingTimeInterval(120), details: material.details)
                try ledger.reserve(client: grant.clientID, request: request.requestID, digest: digest, proof: nil, payloadDigest: payloadDigest, revision: nil, now: Date())
                reserved = true
                try ledger.addPreview(preview, client: grant.clientID)
                let result = response(request, .preview, preview: preview)
                try ledger.complete(client: grant.clientID, request: request.requestID, response: result)
                return result
            }
            var revision: String?
            if let makePreview = handler.preview {
                guard request.confirmation != nil else { return response(request, .conflict, "preview_required") }
                revision = try await makePreview(context).revision
            } else if request.confirmation != nil { throw RetraceCommandError.invalidArguments }
            try check(grant, request.operation)
            if request.operation.mutates {
                try ledger.reserve(client: grant.clientID, request: request.requestID, digest: digest,
                    proof: request.confirmation, payloadDigest: payloadDigest, revision: revision, now: Date())
                reserved = true
            }
            let data: RetraceJSON
            if handler.runsAsJob { data = try startJob(handler, request: request, grant: grant) }
            else { data = try await handler.execute(context) }
            guard bounded(data), try RetraceWire.encoder().encode(data).count <= 1_000_000 else { throw RetraceCommandError.invalidArguments }
            let result = response(request, .succeeded, data: data)
            // Commit the historical receipt even if the caller disconnected after the effect.
            if reserved { try ledger.complete(client: grant.clientID, request: request.requestID, response: result) }
            try check(grant, request.operation)
            return result
        } catch {
            let status: RetraceCommandResponse.Status
            let code: String
            switch error {
            case RetraceCommandLedger.Failure.conflict: status = .conflict; code = "request_conflict"
            case RetraceCommandLedger.Failure.invalidPreview: status = .conflict; code = "invalid_preview"
            case RetraceCommandError.revisionConflict, NativeAnnotationError.staleSelection, ContextStoreError.revisionConflict, CompanionError.staleEvidence, CompanionError.staleMarker, CompanionError.nativeStoreMismatch: status = .conflict; code = "revision_conflict"
            case RetraceCommandError.notPermitted, NativeAnnotationError.notPermitted, EvidenceUnavailableReason.notPermitted: status = .denied; code = "not_permitted"
            case RetraceCommandError.unavailable, NativeAnnotationError.unavailable, NativeAnnotationError.closed: status = .unavailable; code = "operation_unavailable"
            case RetraceCommandError.invalidArguments, NativeAnnotationError.invalidArguments, NativeAnnotationError.tooLarge, ContextStoreError.invalidInput, is DecodingError: status = .failed; code = "invalid_arguments"
            case is CancellationError: status = reserved ? .indeterminate : .cancelled; code = reserved ? "reserved_outcome_unknown" : "cancelled"
            default: status = reserved ? .indeterminate : .failed; code = reserved ? "reserved_outcome_unknown" : "operation_failed"
            }
            let result = response(request, status, code)
            // A reservation with an unknown effect stays unresolved forever rather than risking replay.
            if reserved, status != .indeterminate { try? ledger.complete(client: grant.clientID, request: request.requestID, response: result) }
            return result
        }
    }

    private func startJob(_ handler: RetraceCommandHandler, request: RetraceCommandRequest, grant: RetraceClientGrant) throws -> RetraceJSON {
        try check(grant, request.operation)
        guard jobs.count < 2 else { throw RetraceCommandError.unavailable }
        let job = RetraceCommandJob(id: UUID(), operation: request.operation, state: .running, requestedAt: Date())
        try ledger.putJob(job, client: grant.clientID, creating: true)
        let task = Task { [self] in await runJob(job, handler: handler, request: request, grant: grant) }
        jobs[job.id] = task
        return try .encode(job)
    }
    private func runJob(_ job: RetraceCommandJob, handler: RetraceCommandHandler, request: RetraceCommandRequest, grant: RetraceClientGrant) async {
        let scope = UUID(); activeScopes.insert(scope)
        let mutationFence = NativeMutationFence(expiresAt: grant.expiresAt); mutationFences[scope] = mutationFence
        defer { mutationFence.invalidate(); mutationFences[scope] = nil; activeScopes.remove(scope); jobs[job.id] = nil }
        let context = RetraceCommandContext(clientID: grant.clientID, requestID: request.requestID, arguments: request.arguments,
            capability: request.operation.capability, capabilities: grant.capabilities, mutationFence: mutationFence, jobProgress: { [weak self] phase in
                await self?.updateJobProgress(job, client: grant.clientID, phase: phase)
            }, retentionProgress: { [weak self] phase in
                await self?.updateRetentionJobProgress(job, client: grant.clientID, phase: phase)
            }, authorization: { [weak self] in
                guard let self else { throw RetraceCommandError.notPermitted }
                try await self.checkScope(scope, grant: grant, operation: request.operation)
            }, sourceAuthorization: { [weak self] capability in
                guard let self else { throw RetraceCommandError.notPermitted }
                try await self.checkScope(scope, grant: grant, operation: request.operation, additional: capability)
            })
        let state: RetraceCommandJob.State
        var outcome: ExactOCRRepairOutcome?
        var retentionOutcome: RetentionCommandOutcome?
        do {
            try check(grant, request.operation)
            let result = try await handler.execute(context)
            outcome = try? result.decode(ExactOCRRepairOutcome.self)
            if job.operation == .retention { retentionOutcome = try result.decode(RetentionCommandOutcome.self) }
            // A joined handler returning success records an already completed effect.
            // Later revocation still denies job.read, but cannot undo that outcome.
            state = .succeeded
        } catch is CancellationError { state = .cancelled }
        catch { state = .failed }
        try? ledger.putJob(.init(id: job.id, operation: job.operation, state: state, requestedAt: job.requestedAt,
            repairOutcome: outcome, retentionPhase: retentionOutcome == nil ? nil : .completed,
            retentionOutcome: retentionOutcome), client: grant.clientID)
    }
    private func updateJobProgress(_ job: RetraceCommandJob, client: String, phase: ExactOCRRepairPhase) {
        guard jobs[job.id] != nil, !terminal else { return }
        try? ledger.putJob(.init(id: job.id, operation: job.operation, state: .running,
            requestedAt: job.requestedAt, repairPhase: phase), client: client)
    }
    private func updateRetentionJobProgress(_ job: RetraceCommandJob, client: String, phase: RetentionCommandPhase) {
        guard jobs[job.id] != nil, !terminal, job.operation == .retention else { return }
        try? ledger.putJob(.init(id: job.id, operation: job.operation, state: .running,
            requestedAt: job.requestedAt, retentionPhase: phase), client: client)
    }
    private struct JobIdentifier: Decodable { let id: UUID }
    private func jobOperation(_ context: RetraceCommandContext, cancel: Bool) async throws -> RetraceJSON {
        let input: JobIdentifier = try context.decode(keys: ["id"])
        guard var record = try ledger.job(input.id, client: context.clientID) else { throw RetraceCommandError.unavailable }
#if DEBUG
        if let checkpoint = jobReadCheckpoint {
            jobReadCheckpoint = nil
            await checkpoint()
        }
#endif
        try await context.authorize(record.operation.capability)
        // Authorization yields this actor. The job may have committed its terminal
        // outcome and released its owner while that check was suspended.
        guard let current = try ledger.job(input.id, client: context.clientID) else { throw RetraceCommandError.unavailable }
        record = current
        if let task = jobs[input.id] {
            if cancel { task.cancel(); await task.value; record = try ledger.job(input.id, client: context.clientID) ?? record }
        } else if record.state == .running {
            // A job with no live owner is interrupted, never resumed automatically after restart.
            record = .init(id: record.id, operation: record.operation, state: .interrupted, requestedAt: record.requestedAt)
            try ledger.putJob(record, client: context.clientID)
        }
        try await context.authorize(record.operation.capability)
        return try .encode(record)
    }

    private struct Payload: Encodable { let operation: RetraceOperation; let arguments: RetraceJSON }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func authenticate(_ token: String) -> RetraceClientGrant? {
        guard token.utf8.count >= 32, token.utf8.count <= 512 else { return nil }
        let digest = Array(Self.tokenDigest(token).utf8)
        return grants.first { grant in
            let candidate = Array(grant.tokenSHA256.utf8)
            guard candidate.count == digest.count else { return false }
            return zip(candidate, digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0 && (grant.expiresAt.map { $0 > Date() } ?? true)
        }
    }
    private func permits(_ grant: RetraceClientGrant, _ operation: RetraceOperation) -> Bool {
        (grant.expiresAt.map { $0 > Date() } ?? true) && (operation == .manifest || grant.capabilities.contains(operation.capability) || ((operation == .jobRead || operation == .jobCancel) && grant.capabilities.contains(.maintenance)))
    }
    private func checkScope(_ scope: UUID, grant: RetraceClientGrant, operation: RetraceOperation, additional: RetraceCapability? = nil) throws {
        guard activeScopes.contains(scope) else { throw RetraceCommandError.notPermitted }
        try check(grant, operation)
        if let additional, !grant.capabilities.contains(additional) { throw RetraceCommandError.notPermitted }
    }
    private func check(_ grant: RetraceClientGrant, _ operation: RetraceOperation) throws {
        try Task.checkCancellation()
        guard !terminal, grants.contains(grant), permits(grant, operation) else { throw RetraceCommandError.notPermitted }
    }
    private static func validate(_ grants: [RetraceClientGrant]) throws {
        guard grants.count <= 64, Set(grants.map(\.clientID)).count == grants.count,
              Set(grants.map(\.tokenSHA256)).count == grants.count,
              grants.allSatisfy({ !$0.clientID.isEmpty && $0.clientID.utf8.count <= 128 && !$0.clientID.contains("\0") &&
                  $0.tokenSHA256.count == 64 && $0.tokenSHA256.allSatisfy { "0123456789abcdef".contains($0) } &&
                  ($0.expiresAt.map { $0.timeIntervalSince1970.isFinite } ?? true) }) else { throw RetraceCommandError.invalidArguments }
    }
    private func bounded(_ value: RetraceJSON, depth: Int = 0) -> Bool {
        guard depth <= 32 else { return false }
        switch value {
        case .null, .bool, .integer: return true
        case .number(let number): return number.isFinite
        case .string(let string): return string.utf8.count <= 1_000_000 && !string.contains("\0")
        case .array(let values): return values.count <= 1000 && values.allSatisfy { bounded($0, depth: depth + 1) }
        case .object(let values): return values.count <= 100 && values.allSatisfy { $0.key.utf8.count <= 128 && bounded($0.value, depth: depth + 1) }
        }
    }
    private func response(_ request: RetraceCommandRequest, _ status: RetraceCommandResponse.Status, _ code: String? = nil,
                          data: RetraceJSON? = nil, preview: RetraceDestructivePreview? = nil) -> RetraceCommandResponse {
        .init(requestID: request.requestID, status: status, code: code, data: data, preview: preview)
    }
}
