import Foundation
import Shared

/// Adapts the same local source owner used by Settings. The outer dispatcher
/// provides durable outcomes and client-bound confirmation receipts; this cache
/// retains the exact service preview across the dispatcher's second preview call.
actor RetraceSourceCommands {
    typealias Owner = @Sendable () async throws -> SourceConfigurationService
    private struct Input: Decodable {
        let source: FrameSource
        let enabled: Bool
        let expectedRevision: UUID
    }
    private struct Key: Hashable {
        let clientID: String
        let enabled: Bool
        let expectedRevision: UUID
    }
    private let owner: Owner
    private let clock: @Sendable () -> Date
    private var selections: [Key: SourceConfigurationPreview] = [:]
    private var pending: [Key: Task<SourceConfigurationPreview, Error>] = [:]

    init(owner: @escaping Owner, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.owner = owner; self.clock = clock
    }

    func read(_ context: RetraceCommandContext) async throws -> RetraceJSON {
        try context.requireKeys([])
        try await context.authorize()
        do {
            let service = try await owner(), snapshot = try await service.read()
            try await context.authorize()
            return try .encode(snapshot)
        } catch { throw mapped(error) }
    }

    func preview(_ context: RetraceCommandContext) async throws -> RetracePreviewMaterial {
        let input: Input = try context.decode(keys: ["source", "enabled", "expectedRevision"])
        guard input.source == .rewind else { throw RetraceCommandError.invalidArguments }
        try await context.authorize()
        let key = Key(clientID: context.clientID, enabled: input.enabled, expectedRevision: input.expectedRevision)
        selections = selections.filter { $0.value.expiresAt > clock() }
        do {
            let service = try await owner()
            let preview: SourceConfigurationPreview
            if let existing = selections[key] {
                try await service.validatePreview(clientID: context.clientID, previewID: existing.id)
                preview = existing
            } else if let creating = pending[key] {
                preview = try await creating.value
            } else {
                guard selections.count + pending.count < 128 else { throw RetraceCommandError.unavailable }
                let creating = Task {
                    try await service.preview(clientID: context.clientID,
                        expectedRevision: input.expectedRevision, enabled: input.enabled)
                }
                pending[key] = creating
                defer { pending[key] = nil }
                preview = try await creating.value
                selections[key] = preview
            }
            try await context.authorize()
            return .init(summary: preview.summary,
                revision: preview.id.uuidString + ":" + preview.expectedRevision.uuidString, affectedCount: 1)
        } catch { throw mapped(error) }
    }

    func apply(_ context: RetraceCommandContext) async throws -> RetraceJSON {
        let input: Input = try context.decode(keys: ["source", "enabled", "expectedRevision"])
        guard input.source == .rewind else { throw RetraceCommandError.invalidArguments }
        let key = Key(clientID: context.clientID, enabled: input.enabled, expectedRevision: input.expectedRevision)
        guard let preview = selections[key], preview.expiresAt > clock() else { throw RetraceCommandError.revisionConflict }
        try await context.authorize()
        do {
            let service = try await owner()
            let receipt = try await service.apply(clientID: context.clientID, requestID: context.requestID,
                previewID: preview.id, commandFence: context.mutationFence)
            selections.removeValue(forKey: key)
            return try .encode(receipt)
        } catch { throw mapped(error) }
    }

    private func mapped(_ error: Error) -> Error {
        switch error as? SourceConfigurationError {
        case .stalePreview: return RetraceCommandError.revisionConflict
        case .invalidRequest: return RetraceCommandError.invalidArguments
        case .busy, .closed, .selectionUnavailable, .connectionFailed, .persistenceFailed, .cleanupFailed:
            return RetraceCommandError.unavailable
        case nil: return error
        }
    }

    nonisolated static func handlers(owner: @escaping Owner,
                                    clock: @escaping @Sendable () -> Date = { Date() }) -> [RetraceCommandHandler] {
        let commands = RetraceSourceCommands(owner: owner, clock: clock)
        return [
            .init(operation: .sourcesRead) { try await commands.read($0) },
            .init(operation: .sourcesUpdate, preview: { try await commands.preview($0) }) { try await commands.apply($0) }
        ]
    }
}
