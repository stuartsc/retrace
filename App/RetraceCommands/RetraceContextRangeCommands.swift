import Foundation
import Shared

/// Marker access authorizes manual annotations. Inherited evidence requires a separate
/// current grant; denied ranges carry identity/status without source text, times or provenance.
enum RetraceContextRangeCommands {
    static func read(_ context: RetraceCommandContext, owner: ContextRangePresentationService) async throws -> RetraceJSON {
        let input: Identifier = try context.decode(keys: ["id"])
        try await context.authorize(.markersRead)
        let includeEvidence = context.capabilities.contains(.evidenceRead)
        if includeEvidence { try await context.authorize(.evidenceRead) }
        let initial = try await owner.list(markerID: input.id, includeDerivedEvidence: includeEvidence)
        try await context.authorize(.markersRead)
        if includeEvidence { try await context.authorize(.evidenceRead) }
        let current = try await owner.list(markerID: input.id, includeDerivedEvidence: includeEvidence)
        guard current.markerRevision == initial.markerRevision, current.items == initial.items,
              current.incomplete == initial.incomplete else { throw RetraceCommandError.revisionConflict }
        try await context.authorize(.markersRead)
        if includeEvidence { try await context.authorize(.evidenceRead) }
        return try .encode(current)
    }
    private struct Identifier: Decodable { let id: UUID }
}
