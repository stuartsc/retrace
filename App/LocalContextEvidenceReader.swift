import CryptoKit
import Foundation
import Shared
import Database

/// The owner must compare the complete supplied snapshot with its current
/// already-fetched state, including content and expiry, not just a caller's ID.
/// Captured text cannot install this closure or change its authority.
public typealias LocalContextExternalRevalidator = @Sendable (LocalContextExternalSnapshot) async throws -> Bool

struct LocalContextAdmission: Sendable {
    let request: LocalContextRequest
    let items: [LocalContextItem]
    let stamp: EvidencePresentationStamp
    let sourceGeneration: String
    let identity: LocalContextReadIdentity
    let storeID: UUID
    let screenTextTruncated: Bool
    let externalProviders: [String]
}

/// All reads stay off the main actor. No images, media paths, audio, open-ended
/// queries or inference from process presence participate in this reader.
actor LocalContextEvidenceReader {
    private let database: DatabaseManager
    private let evidence: ProgressiveRecallService
    private let externalRevalidator: LocalContextExternalRevalidator?

    init(database: DatabaseManager, evidence: ProgressiveRecallService, externalRevalidator: LocalContextExternalRevalidator?) {
        self.database = database; self.evidence = evidence; self.externalRevalidator = externalRevalidator
    }

    static func validate(_ request: LocalContextRequest) throws {
        guard request.screenReferences.count <= 8, request.activityReferences.count <= 16,
              Set(request.screenReferences).count == request.screenReferences.count,
              Set(request.activityReferences).count == request.activityReferences.count,
              request.screenReferences.allSatisfy({ $0.source == .native && $0.blockIDs.count <= 64 }),
              request.activityReferences.allSatisfy({ $0.source == .native }) else { throw LocalContextError.invalidRequest }
        if let external = request.externalSnapshot {
            guard validIdentifier(external.providerID), validIdentifier(external.revision), external.items.count <= 16,
                  Set(external.items.map(\.id)).count == external.items.count,
                  external.generatedAt.timeIntervalSince1970.isFinite, external.expiresAt.timeIntervalSince1970.isFinite,
                  external.expiresAt > external.generatedAt else { throw LocalContextError.invalidRequest }
            for item in external.items {
                guard validIdentifier(item.id), (1...240).contains(item.title.utf8.count), item.detail.utf8.count <= 2_048,
                      (1...8).contains(item.citations.count) else { throw LocalContextError.invalidRequest }
                for citation in item.citations {
                    guard validIdentifier(citation.source), (citation.sourceID?.utf8.count ?? 0) <= 256,
                          (citation.citation?.utf8.count ?? 0) <= 512, (citation.url?.utf8.count ?? 0) <= 1_024,
                          citation.capturedAt?.timeIntervalSince1970.isFinite != false else { throw LocalContextError.invalidRequest }
                    if let url = citation.url {
                        guard let parsed = URLComponents(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                              parsed.host != nil, parsed.user == nil, parsed.password == nil else { throw LocalContextError.invalidRequest }
                    }
                }
            }
        }
    }

    func read(_ request: LocalContextRequest, now: Date, requiringExternal: Bool = false) async throws -> LocalContextAdmission {
        try Self.validate(request)
        try Task.checkCancellation()
        let identity = try await database.localContextReadIdentity()
        let policy = identity.policy
        let before = try await evidence.presentationStamp(sources: [.native])
        guard before.hasPolicySHA256(policy.policySHA256) else { throw LocalContextError.changedEvidence }
        let generation = try await evidence.sourceGeneration(source: .native)
        let storeID = identity.storeID
        var items: [LocalContextItem] = []
        var truncated = false
        var seenActivityContexts = Set<String>()
        for ref in request.activityReferences {
            guard ref.storeID == storeID, !(try await database.isActivityHiddenForLocalContext(eventID: ref.eventID)) else {
                throw LocalContextError.unavailableEvidence
            }
            guard case .activity(let saved) = await evidence.resolve(.activity(ref), for: .localUser),
                  saved.storeID == ref.storeID, saved.id == ref.eventID else { throw LocalContextError.unavailableEvidence }
            // A focus sample is an observation, not a claim that the user is
            // working on a project, attending a call, or running a job.
            guard [.focus, .reconciliation, .heartbeat, .enrichment].contains(saved.event.kind),
                  [.observed, .uncertain].contains(saved.event.coverage), let context = saved.event.context else { continue }
            let title = "Observed app: " + LocalContextText.prefix(context.appName, bytes: 128)
            let excerpt = context.windowTitle.map { LocalContextText.prefix($0, bytes: 384) }
            let signature = context.appBundleID + "\u{0}" + (excerpt ?? "")
            guard seenActivityContexts.insert(signature).inserted else { continue }
            let support = LocalContextSupport.activity(ref)
            items.append(.init(id: try LocalContextText.identity(support), kind: .activityObservation,
                title: title, excerpt: excerpt, observedAt: saved.event.observedAt, supports: [support]))
        }
        for ref in request.screenReferences {
            guard ref.storeID == storeID, !(try await database.isScreenHiddenForLocalContext(frameID: ref.frameID)),
                  try await evidence.currentRevision(ref) == ref.extractionRevision,
                  let snapshot = await evidence.retainedScreen(ref, for: .localUser) else { throw LocalContextError.unavailableEvidence }
            let page = try snapshot.expansionPage(for: .init(reference: ref, blockLimit: 2, maximumUTF8Bytes: 768))
            truncated = truncated || page.nextCursor != nil
            for fragment in page.fragments where !fragment.text.isEmpty {
                let excerpt = LocalContextText.prefix(fragment.text, bytes: 384)
                truncated = truncated || excerpt.utf8.count < fragment.text.utf8.count
                let span = LocalContextScreenSpan(fragmentID: fragment.id,
                    utf16Range: .init(location: fragment.utf16Range.location, length: excerpt.utf16.count))
                let support = LocalContextSupport.screen(span)
                items.append(.init(id: try LocalContextText.identity(support), kind: .screenExcerpt,
                    title: "Screen text", excerpt: excerpt, observedAt: page.captureTimestamp, supports: [support]))
            }
        }
        // Keep a bounded deterministic selection; omitted reference text is
        // reported as partial rather than represented as complete coverage.
        items.sort { ($0.observedAt ?? .distantPast, $0.id) > ($1.observedAt ?? .distantPast, $1.id) }
        if items.count > 5 { truncated = true; items = Array(items.prefix(5)) }
        var external: LocalContextExternalSnapshot?
        if let proposed = request.externalSnapshot, let externalRevalidator,
           proposed.generatedAt <= now, proposed.expiresAt > now,
           try await externalRevalidator(proposed) {
            external = proposed
            let terms = LocalContextText.words(items.map { $0.title + " " + ($0.excerpt ?? "") }.joined(separator: " "))
            var ranked = proposed.items.map { item in
                (item: item, score: terms.intersection(LocalContextText.words(item.title + " " + item.detail)).count)
            }
            ranked.sort { $0.score == $1.score ? $0.item.id < $1.item.id : $0.score > $1.score }
            // Only one relevant provider signal; all its original citations stay
            // separate from local evidence. No provider content enters the model.
            if let selected = ranked.first, selected.score > 0 {
                let ref = LocalContextExternalReference(providerID: proposed.providerID, snapshotRevision: proposed.revision,
                    itemID: selected.item.id, citations: selected.item.citations)
                let support = LocalContextSupport.external(ref)
                if items.count > 4 { truncated = true }
                items = Array(items.prefix(4))
                items.append(.init(id: try LocalContextText.identity(support), kind: .externalSignal,
                    title: selected.item.title, excerpt: LocalContextText.prefix(selected.item.detail, bytes: 384),
                    observedAt: proposed.generatedAt, supports: [support]))
            }
        } else if requiringExternal { throw LocalContextError.changedEvidence }
        try Task.checkCancellation()
        guard try await evidence.sourceGeneration(source: .native) == generation,
              try await evidence.presentationStamp(sources: [.native]) == before else { throw LocalContextError.changedEvidence }
        // One final canonical transaction fences screen deletion/hiding, activity
        // changes and policy revocation together, after every other awaited read.
        guard try await database.localContextReadIdentity() == identity else { throw LocalContextError.changedEvidence }
        try Task.checkCancellation()
        return .init(request: .init(screenReferences: request.screenReferences, activityReferences: request.activityReferences,
                     externalSnapshot: external, foundationModelsEnabled: request.foundationModelsEnabled), items: items, stamp: before,
                     sourceGeneration: generation, identity: identity, storeID: storeID, screenTextTruncated: truncated,
                     externalProviders: items.contains(where: { $0.kind == .externalSignal }) ? external.map { [$0.providerID] } ?? [] : [])
    }

    func revalidate(_ admitted: LocalContextAdmission, now: Date) async throws {
        let current = try await read(admitted.request, now: now, requiringExternal: admitted.request.externalSnapshot != nil)
        guard current.identity.policy == admitted.identity.policy, current.storeID == admitted.storeID, current.sourceGeneration == admitted.sourceGeneration,
              current.stamp.hasSamePolicy(as: admitted.stamp), current.items == admitted.items,
              current.externalProviders == admitted.externalProviders else { throw LocalContextError.changedEvidence }
        try Task.checkCancellation()
    }

    private static func validIdentifier(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

enum LocalContextText {
    static func prefix(_ text: String, bytes: Int) -> String {
        var output = "", used = 0
        for scalar in text.unicodeScalars {
            let piece = String(scalar), count = piece.utf8.count
            guard used + count <= bytes else { break }
            output += piece; used += count
        }
        return output
    }
    static func identity<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    static func words(_ text: String) -> Set<String> {
        let stop: Set<String> = ["this", "that", "with", "from", "observed", "screen", "text", "context", "authored", "there", "their"]
        return Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 4 && !stop.contains($0) })
    }
}
