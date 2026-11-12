import Foundation
import Database
import Shared

/// Bounded ephemeral selection/cursor proofs shared by transcript, mixed search and Copy.
/// The durable native reference is returned separately; a selection token never grants access.
actor RetraceContextCommands {
    typealias Reader = @Sendable () async throws -> LiveContextSearchService
    private let reader: Reader
    private struct Selection { let client: String; let reference: LiveContextReference; let interval: DateInterval; let expires: Date; let weight: Int }
    private struct Cursor {
        let client: String; let interval: DateInterval; let query: String
        let pending: [LiveContextSearchItem]; let native: LiveContextSearchCursor?
        let coverage: [LiveContextSourceCoverage]; let expires: Date; let weight: Int
    }
    private var selections: [UUID: Selection] = [:]
    private var cursors: [UUID: Cursor] = [:]
    init(reader: @escaping Reader) { self.reader = reader }

    func search(_ context: RetraceCommandContext) async throws -> RetraceJSON {
        let input: Search = try context.decode(keys: ["text", "from", "to", "limit", "cursor"])
        guard input.from < input.to, (1...50).contains(input.limit ?? 20) else { throw RetraceCommandError.invalidArguments }
        let interval = DateInterval(start: input.from, end: input.to)
        let query = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        try await context.authorize(.evidenceRead)
        prune()
        let service = try await reader()
        var items: [LiveContextSearchItem], next: LiveContextSearchCursor?, coverage: [LiveContextSourceCoverage]
        if let token = input.cursor {
            guard let previous = cursors[token], previous.client == context.clientID,
                  previous.interval == interval, previous.query == query else { throw RetraceCommandError.revisionConflict }
            if !previous.pending.isEmpty { items = previous.pending; next = previous.native; coverage = previous.coverage }
            else {
                guard let native = previous.native else { throw RetraceCommandError.revisionConflict }
                let page = try await service.searchGranted(interval: interval, query: query, before: native, context: context)
                items = page.items; next = page.nextCursor; coverage = page.coverage
            }
        } else {
            let page = try await service.searchGranted(interval: interval, query: query, context: context)
            items = page.items; next = page.nextCursor; coverage = page.coverage
        }
        let selected = Array(items.prefix(input.limit ?? 20)), remainder = Array(items.dropFirst(selected.count))
        let consumed = input.cursor.flatMap { cursors[$0] }
        guard remainder.count <= 2048, cursors.count - (consumed == nil ? 0 : 1) < 32,
              cursors.values.reduce(remainder.count, { $0 + $1.pending.count }) - (consumed?.pending.count ?? 0) <= 4096 else { throw RetraceCommandError.unavailable }
        let cursorWeight = try remainder.reduce(0) { $0 + $1.title.utf8.count + $1.text.utf8.count + (try Self.weight($1.reference)) }
        var rows: [RetraceJSON] = [], pending: [(UUID, LiveContextReference)] = []
        for item in selected {
            try await service.validateGranted(item.reference, context: context)
            let id = UUID(); pending.append((id, item.reference))
            rows.append(.object(["selectionID": .string(id.uuidString), "kind": .string(item.kind),
                "timestamp": .number(item.timestamp.timeIntervalSince1970 * 1000),
                "title": .string(String(item.title.prefix(1024))), "text": .string(String(item.text.prefix(4096))),
                "excerptTruncated": .bool(item.title.count > 1024 || item.text.count > 4096),
                "reference": try Self.identity(item.reference)]))
        }
        for (_, reference) in pending { try await service.validateGranted(reference, context: context) }
        try await context.authorize()
        let selectionWeights = try pending.map { try Self.weight($0.1) }
        guard selections.count + pending.count <= 1000,
              retainedBytes - (consumed?.weight ?? 0) + cursorWeight + selectionWeights.reduce(0, +) <= 8 * 1024 * 1024 else { throw RetraceCommandError.unavailable }
        if let consumedID = input.cursor { cursors[consumedID] = nil }
        let expires = Date().addingTimeInterval(120)
        for (index, pair) in pending.enumerated() { selections[pair.0] = .init(client: context.clientID, reference: pair.1, interval: interval, expires: expires, weight: selectionWeights[index]) }
        var token: UUID?
        if !remainder.isEmpty || next != nil {
            let id = UUID(); token = id
            cursors[id] = .init(client: context.clientID, interval: interval, query: query, pending: remainder, native: next, coverage: coverage, expires: expires, weight: cursorWeight)
        }
        return .object(["entries": .array(rows), "coverage": try .encode(coverage),
            "nextCursor": token.map { .string($0.uuidString) } ?? .null,
            "selectionExpiresAt": .number(expires.timeIntervalSince1970 * 1000),
            "notice": .string("Each source pages independently within the selected interval. Results are current native evidence, not exhaustive context. Foreground application labels do not establish ownership of individual OCR regions.")])
    }

    func registerTranscripts(_ rows: [AudioTranscription], interval: DateInterval, context: RetraceCommandContext) async throws -> [(UUID, RetraceJSON)] {
        let service = try await reader()
        let references = try await service.transcriptReferencesGranted(rows, context: context)
        prune()
        guard selections.count + references.count <= 1000 else { throw RetraceCommandError.unavailable }
        let weights = try references.map(Self.weight)
        guard retainedBytes + weights.reduce(0, +) <= 8 * 1024 * 1024 else { throw RetraceCommandError.unavailable }
        let result = try references.map { (UUID(), $0, try Self.identity($0)) }
        try await context.authorize(.evidenceRead)
        for (index, value) in result.enumerated() { selections[value.0] = .init(client: context.clientID, reference: value.1, interval: interval, expires: Date().addingTimeInterval(120), weight: weights[index]) }
        return result.map { ($0.0, $0.2) }
    }

    func copy(_ context: RetraceCommandContext) async throws -> RetraceJSON {
        let input: Copy = try context.decode(keys: ["selectionIDs", "question"])
        guard (1...20).contains(input.selectionIDs.count), Set(input.selectionIDs).count == input.selectionIDs.count else { throw RetraceCommandError.invalidArguments }
        try await context.authorize()
        prune()
        let selected = try input.selectionIDs.map { id -> Selection in
            guard let value = selections[id], value.client == context.clientID else { throw RetraceCommandError.revisionConflict }
            return value
        }
        let interval = DateInterval(start: selected.map(\.interval.start).min()!, end: selected.map(\.interval.end).max()!)
        let material = try await reader().copyGranted(references: selected.map(\.reference), interval: interval,
            question: input.question ?? "", partial: true, context: context)
        try await context.authorize()
        return .object(["text": .string(material.text), "references": .array(try selected.map { try Self.identity($0.reference) }),
            "clipboardChanged": .bool(false), "coverage": .string("Preview of explicitly selected material; incomplete or developing context remains labelled. Copy this text explicitly in the receiving client.")])
    }
    private var retainedBytes: Int { selections.values.reduce(0) { $0 + $1.weight } + cursors.values.reduce(0) { $0 + $1.weight } }
    private static func weight(_ reference: LiveContextReference) throws -> Int {
        switch reference {
        case .transcript(let value): return try CompanionWire.encode(value).count
        case .screen(let value): return try CompanionWire.encode(value).count
        case .metadata(let value):
            let appBytes = value.appBundleID?.utf8.count ?? 0
            let titleBytes = value.windowTitle?.utf8.count ?? 0
            let urlBytes = value.browserURL?.utf8.count ?? 0
            return 256 + appBytes + titleBytes + urlBytes
        case .note(let value):
            let commentBytes = try CompanionWire.encode(value.comment).count
            let appBytes = value.appBundleID?.utf8.count ?? 0
            let titleBytes = value.windowTitle?.utf8.count ?? 0
            let urlBytes = value.browserURL?.utf8.count ?? 0
            return 512 + commentBytes + appBytes + titleBytes + urlBytes
        case .marker(let value): return try CompanionWire.encode(value).count
        case .range(let marker, let range):
            let markerBytes = try CompanionWire.encode(marker).count
            let rangeBytes = try CompanionWire.encode(range).count
            return markerBytes + rangeBytes
        case .speaker(let value):
            let enhancementBytes = try CompanionWire.encode(value.enhancement).count
            let correctionBytes = try CompanionWire.encode(value.corrections).count
            return enhancementBytes + correctionBytes + value.firstPassText.utf8.count
        case .speakerTurn(let value): return try CompanionWire.encode(value).count
        }
    }
    private func prune() {
        let now = Date(); selections = selections.filter { $0.value.expires > now }; cursors = cursors.filter { $0.value.expires > now }
    }
    private static func identity(_ reference: LiveContextReference) throws -> RetraceJSON {
        switch reference {
        case .transcript(let value): return .object(["kind": .string("transcript"), "reference": try .encode(value)])
        case .screen(let value): return .object(["kind": .string("screen"), "reference": try .encode(value)])
        case .metadata(let value): return .object(["kind": .string("appWindow"), "nativeStoreID": .string(value.nativeStoreID.uuidString), "frameID": .integer(value.frameID.value), "timestamp": .number(value.timestamp.timeIntervalSince1970 * 1000)])
        case .note(let value): return .object(["kind": .string("note"), "nativeStoreID": .string(value.nativeStoreID.uuidString), "id": .integer(value.comment.id.value), "snapshotSHA256": .string(CompanionWire.digest(try CompanionWire.encode(value.comment)))])
        case .marker(let value): return .object(["kind": .string("marker"), "nativeStoreID": .string(value.nativeStoreID.uuidString), "id": .string(value.id.uuidString), "revision": .string(value.revision.uuidString)])
        case .range(let marker, let range): return .object(["kind": .string("contextRange"), "nativeStoreID": .string(marker.nativeStoreID.uuidString), "markerID": .string(marker.id.uuidString), "markerRevision": .string(marker.revision.uuidString), "id": .string(range.id.uuidString), "revision": .string(range.revision.uuidString)])
        case .speaker(let value): return .object(["kind": .string("speaker"), "nativeStoreID": .string(value.nativeStoreID.uuidString), "jobID": .string(value.jobID), "sourceIdentity": try .encode(value.enhancement.sourceIdentity), "correctionRevisions": .array(value.corrections.map { .string($0.revision.uuidString) })])
        case .speakerTurn(let value): return .object(["kind": .string("speakerTurn"), "reference": try .encode(value)])
        }
    }
    private struct Search: Decodable { let text: String; let from: Date; let to: Date; let limit: Int?; let cursor: UUID? }
    private struct Copy: Decodable { let selectionIDs: [UUID]; let question: String? }
}
