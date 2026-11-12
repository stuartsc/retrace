import Foundation
import Shared

/// Client-bound selections hold the exact source/annotation snapshot. Mutations
/// return content-free receipts through the dispatcher's durable request ledger.
actor RetraceAnnotationCommands {
    typealias Owner = @Sendable () async throws -> NativeAnnotationService
    private struct Selection {
        let clientID: String, revision: UUID, expires: Date, snapshot: NativeAnnotationSnapshot
        let bytes: Int
    }
    private let owner: Owner
    private let clock: @Sendable () -> Date
    private var selections: [UUID: Selection] = [:]
    init(owner: @escaping Owner, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.owner = owner; self.clock = clock
    }

    func read(_ context: RetraceCommandContext, comments: Bool) async throws -> RetraceJSON {
        let input: Read = try context.decode(keys: ["references"])
        guard (1...16).contains(input.references.count) else { throw RetraceCommandError.invalidArguments }
        try await context.authorize(.annotationsRead)
        let service = try await owner(), snapshot = try await service.read(references: input.references)
        try await context.authorize(.annotationsRead)
        try await service.validate(snapshot)
        prune()
        let bytes = try RetraceWire.encoder().encode(snapshot).count
        guard selections.count < 128, selections.values.reduce(0, { $0 + $1.bytes }) + bytes <= 8_388_608 else { throw RetraceCommandError.unavailable }
        let id = UUID(), revision = UUID()
        selections[id] = Selection(clientID: context.clientID, revision: revision, expires: clock().addingTimeInterval(120), snapshot: snapshot, bytes: bytes)
        let entries = try snapshot.segments.map { segment -> RetraceJSON in
            let payload = comments ? try RetraceJSON.encode(segment.comments) : try RetraceJSON.encode(segment.tags)
            return .object(["reference": try .encode(segment.reference), "segmentID": .integer(segment.id.value),
                     comments ? "comments" : "tags": payload])
        }
        return .object(["selectionID": .string(id.uuidString), "expectedRevision": .string(revision.uuidString),
            "nativeStoreID": .string(snapshot.nativeStoreID.uuidString), "segments": .array(entries),
            "coverage": .string("Exact selected native segments; attachment files are not shared.")])
    }

    func preview(_ context: RetraceCommandContext, comments: Bool) async throws -> RetracePreviewMaterial {
        let parsed = try parse(context, comments: comments, removing: true)
        try await context.authorize(.annotationsWrite)
        let service = try await owner()
        let count = try await service.preview(snapshot: parsed.selection.snapshot, mutation: parsed.mutation)
        try await context.authorize(.annotationsWrite)
        guard parsed.selection.expires > clock() else { throw RetraceCommandError.revisionConflict }
        // No user-authored text is retained in a durable preview receipt.
        return .init(summary: "\(parsed.input.action) annotation \(parsed.input.id ?? 0) on \(count) selected native segment(s). Attachment files are retained.",
            revision: parsed.selection.snapshot.fingerprint + ":" + parsed.selection.revision.uuidString,
            affectedCount: count)
    }

    func write(_ context: RetraceCommandContext, comments: Bool, removing: Bool) async throws -> RetraceJSON {
        let parsed = try parse(context, comments: comments, removing: removing)
        try await context.authorize(.annotationsWrite)
        let service = try await owner()
        let receipt = try await service.apply(snapshot: parsed.selection.snapshot, mutation: parsed.mutation,
            commandFence: context.mutationFence,
            selectionFence: NativeMutationFence(expiresAt: parsed.selection.expires, clock: clock))
        return try .encode(receipt)
    }

    private func parse(_ context: RetraceCommandContext, comments: Bool, removing: Bool) throws -> (input: Write, selection: Selection, mutation: NativeAnnotationMutation, count: Int) {
        let input: Write = try context.decode(keys: ["selectionID", "expectedRevision", "action", "id", "text"])
        prune()
        guard let selection = selections[input.selectionID], selection.clientID == context.clientID,
              selection.revision == input.expectedRevision else { throw RetraceCommandError.revisionConflict }
        let snapshot = selection.snapshot
        let mutation: NativeAnnotationMutation, count: Int
        switch (comments, removing, input.action) {
        case (false, false, "add"):
            guard input.id == nil, let name = input.text else { throw RetraceCommandError.invalidArguments }
            mutation = .addTag(name: name); count = snapshot.segments.count
        case (false, true, "unlink"), (false, true, "delete"):
            guard input.text == nil, let id = input.id, id > 0 else { throw RetraceCommandError.invalidArguments }
            count = snapshot.segments.filter { $0.tags.contains(where: { $0.id.value == id && !$0.isHidden }) }.count
            guard count > 0 else { throw RetraceCommandError.revisionConflict }
            mutation = input.action == "unlink" ? .removeTag(id: .init(value: id)) : .deleteTag(id: .init(value: id))
        case (true, false, "create"):
            guard input.id == nil, let body = input.text else { throw RetraceCommandError.invalidArguments }
            mutation = .createComment(body: body, author: "MCP \(context.clientID)", attachments: [], anchor: snapshot.segments.first?.reference.frameID)
            count = snapshot.segments.count
        case (true, false, "update"):
            guard let id = input.id, id > 0, let body = input.text else { throw RetraceCommandError.invalidArguments }
            count = snapshot.segments.filter { $0.comments.contains(where: { $0.id.value == id }) }.count
            guard count > 0 else { throw RetraceCommandError.revisionConflict }
            mutation = .updateComment(id: .init(value: id), body: body)
        case (true, false, "link"):
            guard input.text == nil, let id = input.id, id > 0,
                  snapshot.segments.contains(where: { $0.comments.contains(where: { $0.id.value == id }) }) else { throw RetraceCommandError.invalidArguments }
            mutation = .linkComment(id: .init(value: id)); count = snapshot.segments.count
        case (true, true, "unlink"), (true, true, "delete"):
            guard input.text == nil, let id = input.id, id > 0 else { throw RetraceCommandError.invalidArguments }
            count = snapshot.segments.filter { $0.comments.contains(where: { $0.id.value == id }) }.count
            guard count > 0 else { throw RetraceCommandError.revisionConflict }
            mutation = input.action == "unlink" ? .unlinkComment(id: .init(value: id)) : .deleteComment(id: .init(value: id))
        default: throw RetraceCommandError.invalidArguments
        }
        return (input, selection, mutation, count)
    }
    private func prune() { let now = clock(); selections = selections.filter { $0.value.expires > now } }
    private struct Read: Decodable { let references: [ScreenEvidenceRef] }
    private struct Write: Decodable { let selectionID: UUID; let expectedRevision: UUID; let action: String; let id: Int64?; let text: String? }

    nonisolated static func handlers(owner: @escaping Owner, clock: @escaping @Sendable () -> Date = { Date() }) -> [RetraceCommandHandler] {
        let commands = RetraceAnnotationCommands(owner: owner, clock: clock)
        return [
            .init(operation: .tagsRead) { try await commands.read($0, comments: false) },
            .init(operation: .commentsRead) { try await commands.read($0, comments: true) },
            .init(operation: .tagsWrite) { try await commands.write($0, comments: false, removing: false) },
            .init(operation: .commentsWrite) { try await commands.write($0, comments: true, removing: false) },
            .init(operation: .tagsRemove, preview: { try await commands.preview($0, comments: false) }) { try await commands.write($0, comments: false, removing: true) },
            .init(operation: .commentsRemove, preview: { try await commands.preview($0, comments: true) }) { try await commands.write($0, comments: true, removing: true) }
        ]
    }
}
