import Foundation
import Shared

actor RetraceSpeakerCommands {
    private let owner: @Sendable () async throws -> CompanionController
    private struct Cursor { let client: String; let from: Date; let to: Date; let native: String; let expires: Date }
    private var cursors: [UUID: Cursor] = [:]
    init(owner: @escaping @Sendable () async throws -> CompanionController) { self.owner = owner }

    func read(_ context: RetraceCommandContext) async throws -> RetraceJSON {
        let input: Query = try context.decode(keys: ["from", "to", "cursor"])
        guard input.from < input.to else { throw RetraceCommandError.invalidArguments }
        try await context.authorize(.evidenceRead)
        cursors = cursors.filter { $0.value.expires > Date() }
        var native: String?
        if let id = input.cursor {
            guard let cursor = cursors[id], cursor.client == context.clientID,
                  cursor.from == input.from, cursor.to == input.to else { throw RetraceCommandError.revisionConflict }
            native = cursor.native
        }
        let service = try await owner()
        // A result can include a full original first pass. One job bounds every response
        // without silently truncating its turns or advancing past omitted jobs.
        let page = try await service.speakerPresentations(from: input.from, to: input.to, before: native, limit: 1)
        var values: [RetraceJSON] = []
        for item in page.items {
            guard let current = try await service.speakerPresentation(jobID: item.jobID),
                  current.enhancement == item.enhancement, current.corrections == item.corrections,
                  current.firstPassText == item.firstPassText,
                  current.firstPassSourceIdentity == item.firstPassSourceIdentity else { throw RetraceCommandError.revisionConflict }
            values.append(.object(["jobID": .string(item.jobID), "nativeStoreID": .string(item.nativeStoreID.uuidString),
                "firstPassText": .string(item.firstPassText), "firstPassSourceIdentity": try .encode(item.firstPassSourceIdentity),
                "enhancement": try .encode(item.enhancement), "corrections": try .encode(item.corrections)]))
        }
        try await context.authorize(.evidenceRead)
        var next: UUID?
        if let native = page.nextCursor {
            guard cursors.count < 128 else { throw RetraceCommandError.unavailable }
            let id = UUID(); next = id
            cursors[id] = .init(client: context.clientID, from: input.from, to: input.to, native: native, expires: Date().addingTimeInterval(120))
        }
        return .object(["entries": .array(values), "nextCursor": next.map { .string($0.uuidString) } ?? .null,
            "coverage": .string("Retained locally validated enrichment only; speaker coverage is incomplete. Anonymous speakers remain distinct. Suggested names are not confirmed identity. Manual corrections apply only to the exact source; the first-pass transcript is retained separately and can extend beyond the enhanced interval."),
            "transportStarted": .bool(false)])
    }
    func correct(_ context: RetraceCommandContext) async throws -> RetraceJSON {
        let input: Correction = try context.decode(keys: ["jobID", "speakerID", "displayName", "personID", "expectedRevision"])
        try await context.authorize(.annotationsWrite)
        let saved = try await owner().correctSpeaker(.init(clientID: context.clientID, requestID: context.requestID,
            jobID: input.jobID, speakerID: input.speakerID, displayName: input.displayName,
            personID: input.personID, expectedRevision: input.expectedRevision))
        // Durable command receipts retain identity/revision only, never a deleted label.
        return .object(["speakerID": .string(saved.speakerID), "nativeStoreID": .string(saved.nativeStoreID.uuidString),
            "revision": .string(saved.revision.uuidString), "historicalOutcome": .bool(true)])
    }
    private struct Query: Decodable { let from: Date; let to: Date; let cursor: UUID? }
    private struct Correction: Decodable {
        let jobID: String; let speakerID: String; let displayName: String?; let personID: String?; let expectedRevision: UUID?
    }
}
