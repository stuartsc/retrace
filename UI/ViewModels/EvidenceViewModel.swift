import Foundation
import Combine
import CoreGraphics
import App
import Shared

/// Evidence access has no activity-feed or project dependencies.
struct EvidenceClient: Sendable {
    var reference: @Sendable (SearchResult) async throws -> ScreenEvidenceRef
    var frameReference: @Sendable (FrameID, FrameSource) async throws -> ScreenEvidenceRef
    var resolve: @Sendable (EvidenceRef) async -> EvidenceResolution
    var currentRevision: @Sendable (ScreenEvidenceRef) async throws -> Int64?
    var track: @Sendable (ProgressiveRecallAction, String, Int) async -> Void
    var retainedScreen: @Sendable (ScreenEvidenceRef) async -> ScreenEvidenceSnapshot? = { _ in nil }
    var sourceGeneration: @Sendable (FrameSource) async throws -> String = { _ in
        throw EvidenceUnavailableReason.unsupported
    }
    var expand: @Sendable (ScreenEvidenceExpansionRequest) async throws -> ScreenEvidenceExpansionPage = { _ in
        throw EvidenceUnavailableReason.unsupported
    }
    var presentationStamp: @Sendable (Set<FrameSource>) async throws -> EvidencePresentationStamp = { _ in
        throw EvidenceUnavailableReason.unsupported
    }

    static func live(service: ProgressiveRecallService) -> Self {
        live(service: { service })
    }

    static func live(service: @escaping @Sendable () async throws -> ProgressiveRecallService) -> Self {
        Self(reference: { try await service().reference(searchResult: $0) },
             frameReference: { try await service().reference(frameID: $0, source: $1) },
             resolve: { reference in
                 do {
                     let live = try await service()
                     return await live.resolve(reference, for: .localUser)
                 }
                 catch { return .unavailable((error as? EvidenceUnavailableReason) ?? .integrityFailure) }
             },
             currentRevision: { try await service().currentRevision($0) },
             track: { action, outcome, count in
                 guard let service = try? await service() else { return }
                 await service.track(action, outcome: outcome, count: count)
             },
             retainedScreen: { reference in
                 guard let service = try? await service() else { return nil }
                 return await service.retainedScreen(reference, for: .localUser)
             },
             sourceGeneration: { try await service().sourceGeneration(source: $0) },
             expand: { request in
                 try await service().expandScreenEvidence(request, for: .localUser)
             },
             presentationStamp: { try await service().presentationStamp(sources: $0) })
    }
}

@MainActor
final class EvidenceViewModel: ObservableObject {
    @Published private(set) var evidenceReference: EvidenceRef?
    @Published private(set) var resolution: EvidenceResolution?
    @Published private(set) var resolvingEvidence = false
    @Published private(set) var retainedSnapshot: ScreenEvidenceSnapshot?
    @Published private(set) var newerRevision: Int64?
    @Published private(set) var isPresentingEvidence = false
    @Published private(set) var selectedFrame: FrameReference?

    /// Availability is independent of pixels: retained context, transcripts and
    /// jobs can be selected when no screen was captured at their occurrence.
    var hasAdmittedEvidence: Bool {
        guard isPresentingEvidence, evidenceReference != nil else { return false }
        switch resolution {
        case .screen, .activity, .job, .audio: return true
        default: return retainedSnapshot != nil && selectedFrame != nil
        }
    }
    var selectedTimestamp: Date? {
        if let frame = selectedFrame { return frame.timestamp }
        switch resolution {
        case .activity(let stored): return stored.event.observedAt
        case .job(let stored): return stored.observation.observedAt
        case .audio(let stored): return stored.startTime
        default: return nil
        }
    }
    var availableReference: EvidenceRef? { hasAdmittedEvidence ? evidenceReference : nil }

    private let client: EvidenceClient
    private var generation: UInt64 = 0
    private var request: Request?
    private var task: Task<Void, Never>?
    private var standaloneRefresh: (id: UUID, generation: UInt64, task: Task<Void, Never>)?
    private var selectedSourceProof: SourceProof?

    private struct SourceProof: Sendable {
        let source: FrameSource
        let generation: String
    }

    private enum Request: Equatable {
        case search(SearchIdentity)
        case frame(FrameReference, String?)
        case evidence(EvidenceRef)
    }

    /// Row identity deliberately omits revisions; request identity must not.
    /// Retain every original result field so a changed proof never joins a
    /// different validation already in flight.
    private struct SearchIdentity: Equatable {
        let frame: FrameReference
        let reference: ScreenEvidenceRef?
        let token: SearchSelectionToken?
        let snippet: String
        let text: String
        let score: Double
        let videoPath: String?
        let videoFrameRate: Double?
        let nodeID: Int64?
        let nodeOrder: Int?
        let bounds: [Double]?

        init(_ result: SearchResult) {
            frame = FrameReference(id: result.id, timestamp: result.timestamp, segmentID: result.segmentID,
                videoID: result.videoID, frameIndexInSegment: result.frameIndex, metadata: result.metadata, source: result.source)
            reference = result.evidenceRef; token = result.selectionToken
            snippet = result.snippet; text = result.matchedText; score = result.relevanceScore
            videoPath = result.videoPath; videoFrameRate = result.videoFrameRate
            nodeID = result.highlightNode?.nodeID; nodeOrder = result.highlightNode?.nodeOrder
            bounds = result.highlightNode.map { [$0.x, $0.y, $0.width, $0.height] }
        }
    }

    init(client: EvidenceClient) { self.client = client }

    /// Snippet admission does not select evidence or decode media. Both the
    /// original result proof and retained extraction must still be readable.
    func admitsSearchResult(_ result: SearchResult) async -> Bool {
        do {
            try Task.checkCancellation()
            let reference = try await client.reference(result)
            guard let snapshot = await client.retainedScreen(reference) else { return false }
            let expected = FrameReference(id: result.id, timestamp: result.timestamp, segmentID: result.segmentID,
                videoID: result.videoID, frameIndexInSegment: result.frameIndex, metadata: result.metadata, source: result.source)
            try Self.validate(snapshot, reference: reference, expectedFrame: expected)
            // Recheck after the retained-text read, including current privacy
            // and the original legacy selection token if one was supplied.
            guard try await client.reference(result) == reference else { return false }
            return !Task.isCancelled
        } catch { return false }
    }

    func sourceGeneration(for source: FrameSource) async throws -> String {
        try await client.sourceGeneration(source)
    }

    func presentationStamp(sources: Set<FrameSource>) async throws -> EvidencePresentationStamp {
        try await client.presentationStamp(sources)
    }

    func retainedFrame(_ reference: ScreenEvidenceRef) async -> FrameReference? {
        guard !Task.isCancelled, let snapshot = await client.retainedScreen(reference), !Task.isCancelled,
              (try? Self.validate(snapshot, reference: reference, expectedFrame: nil)) != nil else { return nil }
        return snapshot.frame
    }

    /// Use the admitted immutable metadata, not unchecked nearby-row metadata.
    func admittedContextFrame(_ frame: FrameReference, sourceGeneration: String) async -> FrameReference? {
        let proof = SourceProof(source: frame.source, generation: sourceGeneration)
        do {
            try await Self.validateSource(proof, client: client)
            let reference = try await client.frameReference(frame.id, frame.source)
            guard let snapshot = await client.retainedScreen(reference) else { return nil }
            try Self.validate(snapshot, reference: reference, expectedFrame: frame)
            try await Self.validateSource(proof, client: client)
            return snapshot.frame
        } catch { return nil }
    }

    func openSearchResult(_ result: SearchResult) async {
        let identity = SearchIdentity(result)
        let client = client
        await select(.search(identity), expectedFrame: identity.frame, requiresFrameProof: false) {
            .screen(try await client.reference(result))
        }
    }

    func openFrame(_ frame: FrameReference, expectedSourceGeneration: String? = nil) async {
        let client = client
        let proof = expectedSourceGeneration.map { SourceProof(source: frame.source, generation: $0) }
        await select(.frame(frame, expectedSourceGeneration), expectedFrame: frame, requiresFrameProof: true,
                     sourceProof: proof) {
            .screen(try await client.frameReference(frame.id, frame.source))
        }
    }

    func openEvidence(_ reference: EvidenceRef) async {
        await select(.evidence(reference), expectedFrame: nil, requiresFrameProof: false) { reference }
    }

    func closeEvidence() {
        guard isPresentingEvidence || task != nil || standaloneRefresh != nil else { return }
        generation &+= 1
        standaloneRefresh?.task.cancel(); standaloneRefresh = nil
        task?.cancel(); task = nil; request = nil
        selectedSourceProof = nil
        resolution = nil; evidenceReference = nil; selectedFrame = nil
        retainedSnapshot = nil; newerRevision = nil
        resolvingEvidence = false; isPresentingEvidence = false
    }

    func cancel() { closeEvidence() }

    /// Invalidate already published pixels synchronously before a source-change
    /// revalidation can suspend. Keep the original citation as the only retry target.
    func invalidateForSourceChange() {
        generation &+= 1
        standaloneRefresh?.task.cancel(); standaloneRefresh = nil
        task?.cancel(); task = nil; request = nil
        selectedSourceProof = nil
        resolution = .unavailable(.sourceDisconnected)
        selectedFrame = nil; retainedSnapshot = nil; newerRevision = nil
        resolvingEvidence = false; isPresentingEvidence = true
    }

    func refreshCurrentRevision() async {
        if isPresentingEvidence, let reference = evidenceReference {
            switch reference {
            case .screen: break
            default:
                await refreshStandalone(reference)
                return
            }
        }
        guard isPresentingEvidence, selectedFrame != nil,
              case .screen(let ref) = evidenceReference else { return }
        let token = generation
        let proof = selectedSourceProof
        do {
            try await Self.validateSource(proof, client: client)
            guard isCurrent(token) else { return }
            let revision = try await client.currentRevision(ref)
            guard isCurrent(token) else { return }
            try await Self.validateSource(proof, client: client)
            guard isCurrent(token) else { return }
            if let revision {
                newerRevision = revision > ref.extractionRevision ? revision : nil
            } else {
                // A missing current revision also represents deletion or a new
                // privacy restriction. Re-resolve this citation, never a newer
                // extraction or the current row sharing its numeric ID.
                clearPresentedEvidence(reason: nil)
                resolvingEvidence = true
                defer { if isCurrent(token) { resolvingEvidence = false } }
                let reference = EvidenceRef.screen(ref)
                let result = await client.resolve(reference)
                guard isCurrent(token) else { return }
                try await Self.validateSource(proof, client: client)
                guard isCurrent(token) else { return }
                try Self.validate(result, reference: reference, expectedFrame: nil)
                resolution = result
                if case .screen(let snapshot, _) = result {
                    selectedFrame = snapshot.frame
                } else if case .unavailable = result {
                    let retained = await client.retainedScreen(ref)
                    guard isCurrent(token) else { return }
                    try await Self.validateSource(proof, client: client)
                    guard isCurrent(token) else { return }
                    if let retained {
                        try Self.validate(retained, reference: ref, expectedFrame: nil)
                        retainedSnapshot = retained; selectedFrame = retained.frame
                    }
                }
            }
        } catch {
            if isCurrent(token) {
                clearPresentedEvidence(reason: (error as? EvidenceUnavailableReason) ?? .integrityFailure)
                resolvingEvidence = false
            }
        }
    }

    /// Join the owning selection before a fresh canonical read. A refresh takes
    /// publication ownership immediately, so the joined selection cannot flash
    /// an older snapshot after a deletion or another current-state denial.
    private func refreshStandalone(_ reference: EvidenceRef) async {
        guard !Task.isCancelled else { return }
        if let existing = standaloneRefresh, existing.generation == generation {
            await existing.task.value
            return
        }
        let token = generation, id = UUID()
        let pendingSelection = task
        let client = client
        resolvingEvidence = true
        let owned = Task { [weak self] in
            defer {
                if self?.standaloneRefresh?.id == id {
                    self?.standaloneRefresh = nil
                    self?.resolvingEvidence = false
                }
            }
            if let pendingSelection { await pendingSelection.value }
            guard self?.isCurrent(token) == true, self?.standaloneRefresh?.id == id else { return }
            let current = await client.resolve(reference)
            guard self?.isCurrent(token) == true, self?.standaloneRefresh?.id == id else { return }
            do {
                try Self.validate(current, reference: reference, expectedFrame: nil)
                self?.resolution = current
            } catch {
                self?.clearPresentedEvidence(reason: .integrityFailure)
            }
        }
        standaloneRefresh = (id, token, owned)
        await withTaskCancellationHandler(operation: { await owned.value }, onCancel: { owned.cancel() })
    }

    private func clearPresentedEvidence(reason: EvidenceUnavailableReason?) {
        // Keep evidenceReference unchanged so Retry preserves the citation.
        resolution = reason.map(EvidenceResolution.unavailable)
        retainedSnapshot = nil; selectedFrame = nil; newerRevision = nil
    }

    func expandText(_ request: ScreenEvidenceExpansionRequest) async throws -> ScreenEvidenceExpansionPage {
        try Task.checkCancellation()
        try request.validate()
        guard isPresentingEvidence, case .screen(let reference) = evidenceReference,
              reference == request.reference, let frame = selectedFrame else {
            throw EvidenceUnavailableReason.integrityFailure
        }
        let snapshot: ScreenEvidenceSnapshot?
        if case .screen(let resolved, _) = resolution { snapshot = resolved }
        else { snapshot = retainedSnapshot }
        guard let snapshot else { throw EvidenceUnavailableReason.extractionUnavailable }
        let token = generation
        let proof = selectedSourceProof
        try await Self.validateSource(proof, client: client)
        guard isCurrent(token) else { throw CancellationError() }
        let page = try await client.expand(request)
        guard isCurrent(token) else { throw CancellationError() }
        try await Self.validateSource(proof, client: client)
        guard isCurrent(token) else { throw CancellationError() }
        guard page.reference == reference,
              abs(page.captureTimestamp.timeIntervalSince(frame.timestamp)) < 0.001,
              page.width == snapshot.width, page.height == snapshot.height,
              page.fragments.count <= request.blockLimit,
              page.textUTF8Bytes <= request.maximumUTF8Bytes,
              page.fragments.allSatisfy({ $0.id.reference == reference }) else {
            throw EvidenceUnavailableReason.integrityFailure
        }
        return page
    }

    private func select(_ selection: Request, expectedFrame: FrameReference?, requiresFrameProof: Bool,
                        sourceProof: SourceProof? = nil,
                        reference: @escaping @Sendable () async throws -> EvidenceRef) async {
        guard !Task.isCancelled else { return }
        if request == selection, let task {
            await task.value
            if let refresh = standaloneRefresh, refresh.generation == generation {
                await refresh.task.value
            }
            return
        }
        generation &+= 1
        let token = generation
        standaloneRefresh?.task.cancel(); standaloneRefresh = nil
        task?.cancel()
        request = selection
        selectedSourceProof = sourceProof
        resolution = nil; evidenceReference = nil; selectedFrame = nil
        retainedSnapshot = nil; newerRevision = nil
        resolvingEvidence = true; isPresentingEvidence = true
        let client = client
        let owned = Task { [weak self] in
            let began = CFAbsoluteTimeGetCurrent()
            defer {
                if self?.generation == token {
                    if self?.standaloneRefresh?.generation != token { self?.resolvingEvidence = false }
                    self?.task = nil; self?.request = nil
                }
                Log.recordLatency("progressive_recall.evidence", valueMs: (CFAbsoluteTimeGetCurrent() - began) * 1_000, category: .ui)
            }
            await client.track(.evidenceRequested, "success", 1)
            guard self?.isCurrent(token) == true else { return }
            do {
                try await Self.validateSource(sourceProof, client: client)
                guard self?.isCurrent(token) == true else { return }
                let ref = try await reference()
                guard self?.isCurrent(token) == true else { return }
                try await Self.validateSource(sourceProof, client: client)
                guard self?.isCurrent(token) == true else { return }
                if let expectedFrame {
                    guard case .screen(let screen) = ref, screen.source == expectedFrame.source,
                          screen.frameID == expectedFrame.id else { throw EvidenceUnavailableReason.integrityFailure }
                }
                // A numeric frame lookup is not yet a capture-time proof. Do not
                // expose a retryable citation until a returned snapshot agrees.
                if !requiresFrameProof { self?.evidenceReference = ref }
                let result = await client.resolve(ref)
                guard self?.isCurrent(token) == true else { return }
                try await Self.validateSource(sourceProof, client: client)
                guard self?.isCurrent(token) == true else { return }
                // A same-generation standalone refresh has joined this task
                // and now owns the only publication after its fresh read.
                guard self?.standaloneRefresh?.generation != token else { return }
                try Self.validate(result, reference: ref, expectedFrame: expectedFrame)
                if case .screen(let snapshot, _) = result {
                    self?.evidenceReference = ref
                    self?.selectedFrame = snapshot.frame
                }
                self?.resolution = result
                if case .unavailable = result, case .screen(let screen) = ref {
                    let retained = await client.retainedScreen(screen)
                    guard self?.isCurrent(token) == true else { return }
                    try await Self.validateSource(sourceProof, client: client)
                    guard self?.isCurrent(token) == true else { return }
                    if let retained {
                        try Self.validate(retained, reference: screen, expectedFrame: expectedFrame)
                        self?.retainedSnapshot = retained
                        self?.selectedFrame = retained.frame
                        self?.evidenceReference = ref
                    }
                }
                if case .screen(let snapshot, _) = result {
                    let revision = try? await client.currentRevision(snapshot.ref)
                    guard self?.isCurrent(token) == true else { return }
                    try await Self.validateSource(sourceProof, client: client)
                    guard self?.isCurrent(token) == true else { return }
                    if let revision, revision > snapshot.ref.extractionRevision { self?.newerRevision = revision }
                }
                guard self?.isCurrent(token) == true else { return }
                if case .unavailable = result { await client.track(.evidenceUnavailable, "unavailable", 1) }
                else { await client.track(.evidenceResolved, "success", 1) }
            } catch {
                guard self?.isCurrent(token) == true,
                      self?.standaloneRefresh?.generation != token else { return }
                self?.resolution = .unavailable((error as? EvidenceUnavailableReason) ?? .integrityFailure)
                self?.evidenceReference = nil; self?.retainedSnapshot = nil; self?.selectedFrame = nil
                self?.selectedSourceProof = nil
                await client.track(.evidenceUnavailable, "unavailable", 1)
            }
        }
        task = owned
        await withTaskCancellationHandler {
            await owned.value
        } onCancel: {
            owned.cancel()
            Task { @MainActor [weak self] in self?.cancel(ifCurrent: token) }
        }
        // The main-actor cleanup task may run after the joined task completes.
        if Task.isCancelled { cancel(ifCurrent: token) }
    }

    private func cancel(ifCurrent token: UInt64) {
        guard generation == token else { return }
        closeEvidence()
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        token == generation && isPresentingEvidence && !Task.isCancelled
    }

    private nonisolated static func validateSource(_ proof: SourceProof?, client: EvidenceClient) async throws {
        try Task.checkCancellation()
        guard let proof else { return }
        guard try await client.sourceGeneration(proof.source) == proof.generation else {
            throw EvidenceUnavailableReason.sourceDisconnected
        }
        try Task.checkCancellation()
    }

    private static func validate(_ result: EvidenceResolution, reference: EvidenceRef,
                                 expectedFrame: FrameReference?) throws {
        switch (reference, result) {
        case (.screen(let reference), .screen(let snapshot, let image)):
            try validate(snapshot, reference: reference, expectedFrame: expectedFrame)
            guard image.width == snapshot.width, image.height == snapshot.height else {
                throw EvidenceUnavailableReason.integrityFailure
            }
        case (.activity(let reference), .activity(let event)):
            guard event.id == reference.eventID, event.storeID == reference.storeID else {
                throw EvidenceUnavailableReason.integrityFailure
            }
        case (.audio(let reference), .audio(let snapshot)):
            guard snapshot.reference == reference else { throw EvidenceUnavailableReason.integrityFailure }
        case (.job(let reference), .job(let snapshot)):
            guard snapshot.reference == reference else { throw EvidenceUnavailableReason.integrityFailure }
        case (_, .unavailable): break
        default: throw EvidenceUnavailableReason.integrityFailure
        }
    }

    private static func validate(_ snapshot: ScreenEvidenceSnapshot, reference: ScreenEvidenceRef,
                                 expectedFrame: FrameReference?) throws {
        guard snapshot.ref == reference, snapshot.frame.id == reference.frameID,
              snapshot.frame.source == reference.source, snapshot.width > 0, snapshot.height > 0 else {
            throw EvidenceUnavailableReason.integrityFailure
        }
        if let expectedFrame {
            guard snapshot.frame.id == expectedFrame.id, snapshot.frame.source == expectedFrame.source,
                  abs(snapshot.frame.timestamp.timeIntervalSince(expectedFrame.timestamp)) < 0.001 else {
                throw EvidenceUnavailableReason.integrityFailure
            }
        }
    }

    func track(_ action: ProgressiveRecallAction, outcome: String = "success", count: Int = 1) async {
        await client.track(action, outcome, count)
    }
}
