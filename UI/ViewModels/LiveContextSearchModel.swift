import App
import Combine
import Foundation
import Shared

/// Explicit range searches only; opening Live never schedules inference or a search.
@MainActor
final class LiveContextSearchModel: ObservableObject {
    @Published private(set) var query = ""
    @Published private(set) var items: [LiveContextSearchItem] = []
    @Published private(set) var coverage: [LiveContextSourceCoverage] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var revision = UUID()
    @Published var selectedIDs: Set<String> = []
    private(set) var interval: DateInterval?
    private(set) var cursor: LiveContextSearchCursor?
    private let service: @Sendable () async throws -> LiveContextSearchService
    private let rangePresentations: @Sendable () async throws -> ContextRangePresentationService
    private var task: Task<Void, Never>?
    private var observationOwner: ContextRangePresentationService?
    private var observationID: UUID?
    private var sourceDependencies = NativeSourceDependencies.unknown
    private var sourceReadGeneration: UInt64 = 0
    var isSearching: Bool { !query.isEmpty }
    var canLoadMore: Bool { cursor != nil && items.count < 500 }
    var selectedReferences: [LiveContextReference] { items.filter { selectedIDs.contains($0.id) }.map(\.reference) }
    var isPartial: Bool { cursor != nil || coverage.contains { $0.hasMore || $0.notice != nil } }

    init(service: @escaping @Sendable () async throws -> LiveContextSearchService,
         rangePresentations: @escaping @Sendable () async throws -> ContextRangePresentationService) {
        self.service = service; self.rangePresentations = rangePresentations
    }
    deinit {
        task?.cancel()
        if let observationID { observationOwner?.removeInvalidationObserver(observationID) }
    }

    func submit(interval: DateInterval, query: String) {
        reset()
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.interval = interval
        if !self.query.isEmpty { loadMore() }
    }

    func loadMore() {
        guard !isLoading, let interval, !query.isEmpty, items.isEmpty || canLoadMore else { return }
        let old = task, token = revision, query = query, cursor = cursor, sourceReadGeneration = sourceReadGeneration
        isLoading = true; message = nil
        task = Task { [weak self, service, rangePresentations] in
            await old?.value
            do {
                try Task.checkCancellation()
                let presentations = try await rangePresentations()
                try Task.checkCancellation()
                guard let self, self.revision == token else { return }
                try self.observe(presentations)
                let page = try await service().search(interval: interval, query: query, before: cursor)
                try Task.checkCancellation()
                guard self.revision == token else { return }
                guard self.sourceReadGeneration == sourceReadGeneration else { self.isLoading = false; return }
                var byID = Dictionary(uniqueKeysWithValues: self.items.map { ($0.id, $0) })
                for item in page.items { byID[item.id] = item }
                self.items = Array(byID.values).sorted { $0.timestamp > $1.timestamp }
                self.sourceDependencies = cursor == nil ? page.sourceDependencies : self.sourceDependencies.merging(page.sourceDependencies)
                if self.items.count > 500 { self.items = Array(self.items.prefix(500)) }
                self.cursor = page.nextCursor
                var bySource = Dictionary(self.coverage.map { ($0.source, $0) }, uniquingKeysWith: { _, latest in latest })
                for status in page.coverage { bySource[status.source] = status }
                self.coverage = bySource.values.sorted { $0.source < $1.source }
                if self.items.count >= 500 { self.message = "Showing up to 500 results. Narrow the interval or search to continue." }
                self.isLoading = false
            } catch {
                guard let self, self.revision == token else { return }
                self.isLoading = false
                if !Task.isCancelled { self.message = "Search could not complete. Submit the search again to retry." }
            }
        }
    }

    func reset() {
        clearResults()
        query = ""; interval = nil
        if let observationID { observationOwner?.removeInvalidationObserver(observationID) }
        observationOwner = nil; observationID = nil
    }

    private func clearResults() {
        task?.cancel(); revision = UUID(); cursor = nil
        items = []; coverage = []; selectedIDs = []; isLoading = false; message = nil
        sourceDependencies = .unknown
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

    private func sourceInvalidated(_ mutation: NativeSourceMutation) {
        sourceReadGeneration &+= 1
        guard !query.isEmpty, interval != nil else { return }
        guard mutation.affects(sourceDependencies) else {
            // Keep the reviewed snapshot, selection and cursor. A concurrent
            // page read still loses its conservative source admission.
            if isLoading { task?.cancel() }
            return
        }
        // Clear content and selection before joining any prior read or refreshing.
        clearResults()
        loadMore()
    }

    func finishPendingRead() async { await task?.value }
}
