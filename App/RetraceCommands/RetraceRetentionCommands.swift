import Foundation
import Shared

/// Keeps the writer-issued selection stable across preview and confirmation.
/// A discovery continuation changes the reviewed page; it never applies it.
actor RetraceRetentionCommands {
    typealias Owner = @Sendable () async throws -> RetentionCommandService
    private struct Input: Decodable { let cutoff: Date; let continuationID: UUID? }
    private struct Key: Hashable { let client: String; let cutoff: Date; let continuation: UUID? }
    private struct RequestKey: Hashable { let client: String; let requestID: UUID }
    private struct Binding { let key: Key; let preview: RetentionCommandPreview }
    private let owner: Owner
    private var previews: [Key: RetentionCommandPreview] = [:]
    private var pending: [Key: Task<RetentionCommandPreview, Error>] = [:]
    private var bindings: [RequestKey: Binding] = [:]

    init(owner: @escaping Owner) { self.owner = owner }

    func preview(_ context: RetraceCommandContext) async throws -> RetracePreviewMaterial {
        let input: Input = try context.decode(keys: ["cutoff", "continuationID"])
        try await context.authorize()
        let key = Key(client: context.clientID, cutoff: input.cutoff, continuation: input.continuationID)
        let request = RequestKey(client: context.clientID, requestID: context.requestID)
        previews = previews.filter { $0.value.expiresAt > Date() }
        bindings = bindings.filter { $0.value.preview.expiresAt > Date() }
        do {
            let service = try await owner()
            let value: RetentionCommandPreview
            if let retained = bindings[request] {
                guard retained.key == key else { throw RetraceCommandError.invalidArguments }
                try await service.validatePreview(preview: retained.preview, clientID: context.clientID)
                value = retained.preview
            } else if let existing = previews[key] {
                do { try await service.validatePreview(preview: existing, clientID: context.clientID) }
                catch {
                    if previews[key]?.id == existing.id { previews[key] = nil }
                    throw error
                }
                value = existing
            } else if let task = pending[key] {
                value = try await task.value
            } else {
                guard previews.count + pending.count < 8 else { throw RetraceCommandError.unavailable }
                let task = Task {
                    try await service.preview(clientID: context.clientID, cutoff: input.cutoff,
                                              continuationID: input.continuationID)
                }
                pending[key] = task
                defer { pending[key] = nil }
                value = try await task.value
                previews[key] = value
            }
            try await context.authorize()
            // A job may start after another request consumes this selection and
            // refreshes the discovery cache. Its authority is this exact preview,
            // never whichever page happens to occupy the same cache key later.
            if let retained = bindings[request] {
                guard retained.key == key, retained.preview == value else { throw RetraceCommandError.revisionConflict }
            } else {
                guard bindings.count < 128 else { throw RetraceCommandError.unavailable }
                bindings[request] = Binding(key: key, preview: value)
            }
            return .init(summary: "Delete \(value.frames) native screenshots and \(value.sessions) sessions before the selected cutoff. Audio remains retained. Existing video files are deferred; this page reclaims no file bytes.",
                revision: value.id.uuidString + ":" + value.fingerprint,
                affectedCount: value.frames + value.sessions + value.videoCandidates,
                details: try .encode(value))
        } catch { throw mapped(error) }
    }

    func apply(_ context: RetraceCommandContext) async throws -> RetraceJSON {
        let input: Input = try context.decode(keys: ["cutoff", "continuationID"])
        let key = Key(client: context.clientID, cutoff: input.cutoff, continuation: input.continuationID)
        let request = RequestKey(client: context.clientID, requestID: context.requestID)
        guard let binding = bindings.removeValue(forKey: request), binding.key == key,
              binding.preview.expiresAt > Date() else {
            throw RetraceCommandError.revisionConflict
        }
        let preview = binding.preview
        if previews[key]?.id == preview.id { previews[key] = nil }
        try await context.authorize()
        do {
            let service = try await owner()
            let outcome = try await service.execute(preview: preview, clientID: context.clientID,
                commandFence: context.mutationFence, progress: { await context.reportRetentionProgress($0) })
            // No post-commit cancellation check: retain the actual committed counts.
            return try .encode(outcome)
        } catch { throw mapped(error) }
    }

    private func mapped(_ error: Error) -> Error {
        switch error as? RetentionCommandError {
        case .invalidArguments: return RetraceCommandError.invalidArguments
        case .stalePreview: return RetraceCommandError.revisionConflict
        case .notPermitted: return RetraceCommandError.notPermitted
        case .unavailable, .busy, .closed: return RetraceCommandError.unavailable
        case nil:
            if error is CancellationError, !Task.isCancelled { return RetraceCommandError.revisionConflict }
            return error
        }
    }

    nonisolated static func handlers(owner: @escaping Owner) -> [RetraceCommandHandler] {
        let commands = RetraceRetentionCommands(owner: owner)
        return [.init(operation: .retention, runsAsJob: true,
            preview: { try await commands.preview($0) }, execute: { try await commands.apply($0) })]
    }
}
