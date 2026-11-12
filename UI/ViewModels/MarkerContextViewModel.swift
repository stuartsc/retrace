import App
import Combine
import Foundation
import Shared

@MainActor
final class MarkerContextViewModel: ObservableObject {
    @Published private(set) var marker: TimelineMarker?
    @Published private(set) var presentations: [ContextRangePresentation] = []
    @Published private(set) var isSaving = false
    @Published private(set) var message: String?
    @Published private(set) var saveRevision: UInt64 = 0
    var ranges: [MarkerContextRange] { presentations.filter { $0.availability == .available }.compactMap(\.range) }
    private let service: @Sendable () async throws -> TimelineMarkerService
    private let presentationService: @Sendable () async throws -> ContextRangePresentationService
    private var generation: UInt64 = 0
    private var sourceReadGeneration: UInt64 = 0
    private var sourceDependencies = NativeSourceDependencies.unknown
    private var visibilityGeneration: UInt64 = 0
    private var visible = true
    private var selectedMarkerID: UUID?
    private var writeTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var observationOwner: ContextRangePresentationService?
    private var observationID: UUID?

    init(service: @escaping @Sendable () async throws -> TimelineMarkerService,
         presentations: @escaping @Sendable () async throws -> ContextRangePresentationService) {
        self.service = service; presentationService = presentations
    }
    deinit {
        refreshTask?.cancel()
        if let observationID { observationOwner?.removeInvalidationObserver(observationID) }
    }

    func load(id: UUID, expectedRevision: UUID? = nil) async throws {
        visible = true
        selectedMarkerID = id
        invalidatePayloads()
        marker = nil
        let generation = generation
        let sourceReadGeneration = sourceReadGeneration
        let owner = try await service()
        let reader = try await presentationService()
        try Task.checkCancellation()
        guard self.generation == generation, self.sourceReadGeneration == sourceReadGeneration, visible else { throw CancellationError() }
        try observe(reader)
        guard let current = try await owner.marker(id: id), current.deletedAt == nil,
              expectedRevision == nil || current.revision == expectedRevision else { throw ContextStoreError.revisionConflict }
        let page = try await reader.list(markerID: id)
        guard page.markerID == id, page.markerRevision == current.revision,
              let retained = try await owner.marker(id: id), retained == current else { throw ContextStoreError.revisionConflict }
        try Task.checkCancellation()
        guard self.generation == generation, self.sourceReadGeneration == sourceReadGeneration, visible else { throw CancellationError() }
        sourceDependencies = page.sourceDependencies
        marker = current; presentations = page.items
        message = page.incomplete ? "Some context sources are unavailable or the range list is incomplete." : nil
    }

    func resolveForAction(_ reference: ContextRangePresentationReference) async throws -> MarkerContextRange {
        let generation = generation
        guard visible, marker?.id == reference.markerID else { throw ContextStoreError.revisionConflict }
        let item = try await presentationService().resolve(reference)
        try Task.checkCancellation()
        guard self.generation == generation, visible, item.reference == reference,
              item.availability == .available, let range = item.range else { throw ContextStoreError.revisionConflict }
        return range
    }

    func save(start: Date, end: Date, explanation: String, editing: ContextRangePresentationReference?, pinned: Bool) {
        let text = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker, visible, writeTask == nil, start < end else { return }
        let visibility = visibilityGeneration
        isSaving = true; message = nil
        writeTask = Task { [weak self, service] in
            defer { self?.writeTask = nil; self?.isSaving = false }
            do {
                guard let self else { return }
                let original: MarkerContextRange?
                if let editing { original = try await self.resolveForAction(editing) } else { original = nil }
                let origin = original?.effectiveExplanationOrigin ?? .userAuthored
                guard origin != .userAuthored || !text.isEmpty else { throw ContextStoreError.invalidInput }
                let sourceGeneration = self.generation
                let range = MarkerContextRange(id: original?.id ?? UUID(), start: start, end: end,
                    explanation: origin == .userAuthored ? text : original?.explanation ?? "",
                    ownership: pinned ? .pinned : .manual, explanationOrigin: origin,
                    provenance: original?.provenance, userNote: origin == .userAuthored ? original?.userNote : text)
                let owner = try await service()
                guard self.visible, self.visibilityGeneration == visibility,
                      self.generation == sourceGeneration else { throw CancellationError() }
                _ = try await owner.saveContextRange(markerID: marker.id, range: range,
                    expectedRevision: editing?.rangeRevision, expectedMarkerRevision: marker.revision)
                guard self.visible, self.visibilityGeneration == visibility else { return }
                self.saveRevision &+= 1
                // A durable write receipt is not a source disclosure grant.
                // Publish its explanation only through the validated reader.
                do {
                    try await self.load(id: marker.id)
                    if self.visible, self.visibilityGeneration == visibility {
                        self.message = pinned ? "Context range pinned." : "Manual context range saved."
                    }
                } catch {
                    if self.visible, self.visibilityGeneration == visibility {
                        self.message = "Range saved, but its latest state could not be refreshed. Reopen the marker before editing again."
                    }
                }
            } catch {
                if let self, self.visible, self.visibilityGeneration == visibility {
                    self.message = "The marker, source or range changed. Refresh before saving your edit."
                }
            }
        }
    }

    private func observe(_ reader: ContextRangePresentationService) throws {
        guard observationOwner !== reader else { return }
        if let observationID { observationOwner?.removeInvalidationObserver(observationID) }
        observationOwner = nil; observationID = nil
        let id = try reader.subscribeSourceChanges { [weak self] mutation in
            Task { @MainActor [weak self] in self?.sourceInvalidated(mutation) }
        }
        observationOwner = reader; observationID = id
    }

    private func invalidatePayloads() {
        generation &+= 1
        presentations = presentations.map { item in
            ContextRangePresentation(reference: item.reference, ownership: item.ownership,
                availability: item.availability == .legacyUnverified ? .legacyUnverified : .sourceUnavailable,
                range: nil, userNote: item.userNote)
        }
    }

    private func sourceInvalidated(_ mutation: NativeSourceMutation) {
        sourceReadGeneration &+= 1
        guard visible else { return }
        guard mutation.affects(sourceDependencies) else { return }
        let id = selectedMarkerID
        invalidatePayloads()
        marker = nil
        let old = refreshTask
        old?.cancel()
        guard let id else { return }
        let visibility = visibilityGeneration
        refreshTask = Task { [weak self] in
            await old?.value
            guard let self, self.visible, self.visibilityGeneration == visibility, !Task.isCancelled else { return }
            do { try await self.load(id: id) }
            catch { if !Task.isCancelled { self.message = "Context sources changed. Unavailable explanations have been removed." } }
        }
    }

    func hide() {
        visible = false; visibilityGeneration &+= 1; invalidatePayloads(); refreshTask?.cancel()
        marker = nil
        selectedMarkerID = nil
        if let observationID { observationOwner?.removeInvalidationObserver(observationID) }
        observationOwner = nil; observationID = nil
    }
    func finishPendingWrite() async { await writeTask?.value }
    func finishPendingRefresh() async { await refreshTask?.value }
}
