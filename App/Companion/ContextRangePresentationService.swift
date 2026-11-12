import Foundation
import Shared

/// Local disclosure owner over raw context storage. No transport, model, spool lock or
/// reader is created here: the App injects its shared retained-evidence reader and epoch.
public actor ContextRangePresentationService {
    public typealias ValidateEvidence = @Sendable (CompanionJobRequest) async throws -> Void
    public typealias CurrentEpoch = @Sendable () async throws -> String
    public typealias SourceDependencies = @Sendable (CompanionJobRequest) async throws -> NativeSourceDependencies
    private let markers: TimelineMarkerService
    private let validateEvidence: ValidateEvidence
    private let currentEpoch: CurrentEpoch
    private let sourceDependencies: SourceDependencies
    private nonisolated let admission = ContextPresentationAdmission()
    private struct Operation { let cancel: @Sendable () -> Void; let join: @Sendable () async -> Void }
    private var operations: [UUID: Operation] = [:]
    public init(markers: TimelineMarkerService, validateEvidence: @escaping ValidateEvidence, currentEpoch: @escaping CurrentEpoch,
                sourceDependencies: @escaping SourceDependencies = { _ in .unknown }) {
        self.markers = markers; self.validateEvidence = validateEvidence; self.currentEpoch = currentEpoch
        self.sourceDependencies = sourceDependencies
    }
    public nonisolated func invalidate(_ mutation: NativeSourceMutation = .all) { admission.invalidate(mutation) }
    public nonisolated func subscribeInvalidation(_ callback: @escaping @Sendable () -> Void) throws -> UUID { try admission.subscribe { _ in callback() } }
    public nonisolated func subscribeSourceChanges(_ callback: @escaping @Sendable (NativeSourceMutation) -> Void) throws -> UUID { try admission.subscribe(callback) }
    public nonisolated func removeInvalidationObserver(_ id: UUID) { admission.remove(id) }
    public func list(markerID: UUID, limit: Int = 64, includeDerivedEvidence: Bool = true) async throws -> ContextRangePresentationPage {
        guard (1...64).contains(limit) else { throw CompanionError.invalidPayload }
        return try await perform { token in try await self.listOwned(markerID: markerID, limit: limit, includeDerivedEvidence: includeDerivedEvidence, token: token) }
    }
    public func resolve(_ reference: ContextRangePresentationReference, includeDerivedEvidence: Bool = true) async throws -> ContextRangePresentation {
        try await perform { token in
            let page = try await self.listOwned(markerID: reference.markerID, limit: 64, includeDerivedEvidence: includeDerivedEvidence, token: token)
            guard let item = page.items.first(where: { $0.reference == reference }) else { throw CompanionError.staleEvidence }
            return item
        }
    }
    public func close() async {
        admission.close()
        let owned = Array(operations.values)
        for operation in owned { operation.cancel() }
        for operation in owned { await operation.join() }
    }
    private func perform<T: Sendable>(_ body: @escaping @Sendable (UUID) async throws -> T) async throws -> T {
        let token = try admission.snapshot()
        guard operations.count < 32 else { throw CompanionError.capacityExceeded }
        let id = UUID(), task = Task { try await body(token) }
        operations[id] = .init(cancel: { task.cancel() }, join: { _ = await task.result })
        defer { operations[id] = nil }
        return try await withTaskCancellationHandler(operation: {
            let value = try await task.value
            try Task.checkCancellation(); try admission.check(token)
            return value
        }, onCancel: { task.cancel() })
    }
    private func listOwned(markerID: UUID, limit: Int, includeDerivedEvidence: Bool, token: UUID) async throws -> ContextRangePresentationPage {
        let epoch = try await currentEpoch()
        guard let marker = try await markers.marker(id: markerID) else { throw CompanionError.staleMarker }
        let ranges = try await markers.listContextRanges(markerID: markerID)
        var items: [ContextRangePresentation] = []
        var dependencies = NativeSourceDependencies.none
        for range in ranges.prefix(limit) {
            try Task.checkCancellation(); try admission.check(token)
            let reference = ContextRangePresentationReference(nativeStoreID: marker.nativeStoreID, markerID: marker.id,
                markerRevision: marker.revision, rangeID: range.id, rangeRevision: range.revision, provenance: includeDerivedEvidence ? range.provenance : nil)
            let availability: ContextRangePresentation.Availability
            switch range.effectiveExplanationOrigin {
            case .userAuthored: availability = .available
            case .legacyUnverified: availability = .legacyUnverified
            case .companionDerived:
                if includeDerivedEvidence {
                    do { dependencies = dependencies.merging(try await validate(range, marker: marker)); availability = .available }
                    catch is CancellationError { throw CancellationError() }
                    catch { availability = .sourceUnavailable }
                } else { availability = .evidenceGrantRequired }
            }
            let visibleRange: MarkerContextRange?
            if availability != .available { visibleRange = nil }
            else if includeDerivedEvidence { visibleRange = range }
            else {
                visibleRange = .init(id: range.id, revision: range.revision, start: range.start, end: range.end,
                    explanation: range.explanation, ownership: range.ownership,
                    explanationOrigin: .userAuthored, userNote: range.userNote)
            }
            items.append(.init(reference: reference, ownership: range.ownership, availability: availability,
                               range: visibleRange, userNote: range.userNote))
        }
        guard try await markers.marker(id: markerID) == marker,
              try await markers.listContextRanges(markerID: markerID) == ranges else { throw CompanionError.staleEvidence }
        guard try await currentEpoch() == epoch else { throw CompanionError.staleEvidence }
        try Task.checkCancellation(); try admission.check(token)
        return .init(markerID: markerID, markerRevision: marker.revision, items: items,
            incomplete: ranges.count > limit || items.contains { $0.availability != .available }, sourceDependencies: dependencies)
    }
    private func validate(_ range: MarkerContextRange, marker: TimelineMarker) async throws -> NativeSourceDependencies {
        guard let provenance = range.provenance, let retained = try await markers.contextProposal(jobID: provenance.jobID),
              retained.markerID == marker.id, retained.proposalRevision == provenance.proposalRevision,
              retained.resultSHA256 == provenance.resultSHA256, CompanionWire.digest(retained.requestPayload) == provenance.jobID,
              CompanionWire.digest(retained.resultPayload) == provenance.resultSHA256 else { throw CompanionError.staleEvidence }
        let request = try CompanionWire.decode(CompanionJobRequest.self, data: retained.requestPayload, limit: 768 * 1024)
        let result = try CompanionWire.decode(CompanionResult.self, data: retained.resultPayload, limit: 2 * 1024 * 1024)
        try request.validate(); try CompanionWire.validate(result, request: request, id: provenance.jobID)
        guard request.sourceStoreID == marker.nativeStoreID, let source = request.context,
              source.markerID == marker.id, source.markerRevision == retained.markerRevision,
              source.snapshotID == provenance.proposalRevision,
              let proposal = result.contextProposal?.ranges.first(where: { $0.id == range.id }),
              proposal.supportIDs == provenance.supportIDs, proposal.explanation == range.explanation else { throw CompanionError.staleEvidence }
        if range.ownership == .proposed {
            guard CompanionWire.sameWireDate(proposal.start, range.start), CompanionWire.sameWireDate(proposal.end, range.end) else { throw CompanionError.staleEvidence }
        }
        let ids = Set(provenance.supportIDs), supports = source.evidence.filter { ids.contains($0.id) }
        guard supports.count == ids.count, !supports.isEmpty else { throw CompanionError.staleEvidence }
        for support in supports where support.reference.kind == .media {
            guard let anchor = support.reference.media, marker.spokenObservation?.anchor == anchor,
                  marker.spokenObservation?.status != .withdrawn else { throw CompanionError.staleEvidence }
        }
        // Validate only the sources inherited by this range; unrelated unavailable candidates
        // in the original retrieval must not revoke a manually retained, still-readable support.
        let selected = CompanionJobRequest(sourceStoreID: request.sourceStoreID, observedAt: request.observedAt,
            context: .init(markerID: source.markerID, markerRevision: source.markerRevision, snapshotID: source.snapshotID,
                query: source.query, verbatimExplanation: source.verbatimExplanation, developing: source.developing,
                incomplete: source.incomplete, evidence: supports, expectedProposalHead: source.expectedProposalHead))
        try await validateEvidence(selected)
        return try await sourceDependencies(selected)
    }
}

private final class ContextPresentationAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID(), closed = false
    private var observers: [UUID: @Sendable (NativeSourceMutation) -> Void] = [:]
    func snapshot() throws -> UUID { try lock.withLock { guard !closed else { throw CompanionError.closed }; return generation } }
    func check(_ token: UUID) throws { try lock.withLock {
        guard !closed else { throw CompanionError.closed }
        guard token == generation else { throw CompanionError.staleEvidence }
    } }
    func subscribe(_ callback: @escaping @Sendable (NativeSourceMutation) -> Void) throws -> UUID { try lock.withLock {
        guard !closed else { throw CompanionError.closed }
        guard observers.count < 32 else { throw CompanionError.capacityExceeded }
        let id = UUID(); observers[id] = callback; return id
    } }
    func remove(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }
    func invalidate(_ mutation: NativeSourceMutation) {
        let callbacks = lock.withLock { generation = UUID(); return Array(observers.values) }
        callbacks.forEach { $0(mutation) }
    }
    func close() {
        let callbacks = lock.withLock { closed = true; generation = UUID(); let callbacks = Array(observers.values); observers.removeAll(); return callbacks }
        callbacks.forEach { $0(.all) }
    }
}
