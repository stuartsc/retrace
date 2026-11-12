import Foundation
import Database
import Shared

/// The canonical metadata reader supplies the timestamp/ID keyset. Only exact, currently
/// permitted native evidence is exported; skipped rows still advance bounded pagination.
actor RetraceTimelineCommands {
    private let coordinator: AppCoordinator
    private struct Cursor {
        let client: String; let generation: String; let query: Query; let native: ContextReadCursor; let expires: Date
    }
    private var cursors: [UUID: Cursor] = [:]
    init(coordinator: AppCoordinator) { self.coordinator = coordinator }

    func read(_ context: RetraceCommandContext) async throws -> RetraceJSON {
        let query: Query = try context.decode(keys: ["from", "to", "query", "limit", "cursor"])
        guard query.from < query.to, (1...50).contains(query.limit ?? 20), (query.query?.utf8.count ?? 0) <= 512 else { throw RetraceCommandError.invalidArguments }
        try await context.authorize()
        let service = try await coordinator.progressiveRecall()
        let generation = try await service.sourceGeneration(source: .native)
        cursors = cursors.filter { $0.value.expires > Date() && $0.value.generation == generation }
        let before: ContextReadCursor?
        if let id = query.cursor {
            guard let prior = cursors[id], prior.client == context.clientID, prior.query.sameScope(as: query) else { throw RetraceCommandError.revisionConflict }
            before = prior.native
        } else { before = nil }
        let page = try await coordinator.contextMetadataPage(from: query.from, to: query.to,
            query: query.query ?? "", before: before, limit: query.limit ?? 20)
        var entries: [RetraceJSON] = []
        var references: [ScreenEvidenceRef] = []
        var omitted = 0
        for candidate in page.entries {
            try await context.authorize()
            do {
                let reference = try await service.reference(frameID: candidate.frameID, source: .native)
                guard reference.storeID == candidate.nativeStoreID else { throw RetraceCommandError.revisionConflict }
                let snapshot = try await service.grantedScreen(reference, context: context)
                guard abs(snapshot.frame.timestamp.timeIntervalSince(candidate.timestamp)) < 0.001 else { throw RetraceCommandError.revisionConflict }
                let text = snapshot.text.map { $0.fullText + ($0.chromeText.isEmpty ? "" : "\n" + $0.chromeText) }
                let fits = (text?.utf8.count ?? 0) <= 16_384
                entries.append(.object(["reference": try .encode(reference),
                    "timestamp": .number(snapshot.frame.timestamp.timeIntervalSince1970 * 1000),
                    "foregroundWindow": try .encode(snapshot.frame.metadata),
                    "ocr": fits ? text.map(RetraceJSON.string) ?? .null : .null,
                    "ocrCoverage": .string(text == nil ? "unavailable" : fits ? "retained" : "requires_exact_evidence_read"),
                    "regionOwnership": .string("Foreground window attribution does not prove OCR-region ownership.")]))
                references.append(reference)
            } catch is CancellationError { throw CancellationError() }
            catch RetraceCommandError.notPermitted { throw RetraceCommandError.notPermitted }
            catch { omitted += 1 }
        }
        for reference in references { _ = try await service.grantedScreen(reference, context: context) }
        guard try await service.sourceGeneration(source: .native) == generation else { throw RetraceCommandError.revisionConflict }
        try await context.authorize()
        var next: UUID?
        if let native = page.nextCursor {
            guard cursors.count < 128 else { throw RetraceCommandError.unavailable }
            let id = UUID()
            cursors[id] = .init(client: context.clientID, generation: generation, query: query, native: native, expires: Date().addingTimeInterval(120))
            next = id
        }
        return .object(["entries": .array(entries), "nextCursor": next.map { .string($0.uuidString) } ?? .null,
            "omittedCandidates": .integer(Int64(omitted)), "sourceIdentity": .string(generation),
            "coverage": .string("Bounded native screen observations only. Audio-only moments remain available through transcript and marker tools. Imported, hidden, excluded and unresolved candidates are omitted explicitly.")])
    }
    private struct Query: Decodable {
        let from: Date; let to: Date; let query: String?; let limit: Int?; let cursor: UUID?
        func sameScope(as other: Self) -> Bool { from == other.from && to == other.to && query == other.query }
    }
}
