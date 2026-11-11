import Combine
import Foundation
import Shared
import App
import Database

enum UnifiedWorkspacePolicy {
    static let defaultsKey = "unifiedHistoryWorkspaceEnabled"
    static let minimumWidth: CGFloat = 760
    static let minimumHeight: CGFloat = 620
    static let maximumRows = 100
    static let maximumHistory = 50
    static func usesDrawer(width: CGFloat) -> Bool { width < 1_080 }
}

/// The audio inspector owns one query and clears its rows synchronously when
/// screen admission is revoked. Duplicate view/action reads join the same task.
@MainActor
final class WorkspaceAudioContext: ObservableObject {
    @Published private(set) var transcriptions: [AudioTranscription] = []
    private let playback: TranscriptAudioPlayback
    private let query: @Sendable (Date) async throws -> [AudioTranscription]
    private var generation: UInt64 = 0
    private var loadedAdmission: WorkspaceSelectionAdmission?
    private var pendingAdmission: WorkspaceSelectionAdmission?
    private var loadTask: Task<Bool, Never>?

    init(playback: TranscriptAudioPlayback, query: @escaping @Sendable (Date) async throws -> [AudioTranscription]) {
        self.playback = playback; self.query = query
    }

    func clear() {
        generation &+= 1; loadTask?.cancel(); loadTask = nil
        loadedAdmission = nil; pendingAdmission = nil; transcriptions = []
        playback.stop(reason: .selectionChanged)
    }

    func load(for admission: WorkspaceSelectionAdmission, model: UnifiedWorkspaceModel) async -> Bool {
        // Legacy nearby-row playback remains screen-context-only. An exact
        // standalone transcript requires its own verified media binding.
        guard model.admits(admission), case .screen = admission.reference,
              let at = model.evidence.selectedFrame?.timestamp else { return false }
        if loadedAdmission == admission { return true }
        if pendingAdmission == admission, let task = loadTask { return await task.value && model.admits(admission) }
        clear()
        let token = generation
        pendingAdmission = admission
        let task = Task { [weak self, query] in
            guard let self else { return false }
            defer {
                if generation == token { loadTask = nil; pendingAdmission = nil }
            }
            do {
                let rows = try await query(at)
                guard !Task.isCancelled, generation == token, model.admits(admission) else { return false }
                transcriptions = rows; loadedAdmission = admission
                return true
            } catch { return false }
        }
        loadTask = task
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }
}

enum WorkspaceTimeScale: String, CaseIterable {
    case minute = "Minute", hour = "Hour", day = "Day"
    var interval: TimeInterval {
        switch self { case .minute: return 60; case .hour: return 3_600; case .day: return 86_400 }
    }
    var tapeZoom: CGFloat {
        switch self { case .minute: return 0.85; case .hour: return 0.4; case .day: return 0 }
    }
}

struct WorkspaceBookmark: Codable, Identifiable, Sendable {
    let id: UUID
    let reference: EvidenceRef
    let capturedAt: Date
}

/// Acquired with a specific tape batch, never filled from the latest history.
enum WorkspaceTapeSelection: Sendable {
    case frame(DashboardScreenshotRow)
    case evidence(EvidenceRef)
}

struct WorkspaceSelectionAdmission: Equatable, Sendable {
    fileprivate let selection: UInt64
    fileprivate let presentation: UInt64
    let reference: EvidenceRef
}

actor WorkspaceBookmarkStore {
    private let defaults: UserDefaults
    private let key = "unifiedWorkspaceBookmarksV1"
    init(suiteName: String = "io.retrace.app") { defaults = UserDefaults(suiteName: suiteName) ?? .standard }
    func load() -> [WorkspaceBookmark] {
        guard let data = defaults.data(forKey: key), data.count <= 256 * 1_024,
              let values = try? JSONDecoder().decode([WorkspaceBookmark].self, from: data) else { return [] }
        return Array(values.prefix(50))
    }
    func save(_ values: [WorkspaceBookmark]) {
        guard let data = try? JSONEncoder().encode(Array(values.prefix(50))) else { return }
        defaults.set(data, forKey: key)
    }
}

/// One presentation owner for live and historical evidence. Refresh can advance
/// Now, but only a user action can replace a pinned historical citation.
@MainActor
final class UnifiedWorkspaceModel: ObservableObject {
    enum Mode: String, CaseIterable { case now = "Now", history = "History" }
    @Published private(set) var mode: Mode = .now
    @Published private(set) var rows: [DashboardScreenshotRow] = []
    @Published private(set) var selection: ScreenshotEvidenceSelection?
    @Published private(set) var presentedReference: EvidenceRef?
    @Published private(set) var searchResults: [SearchResult] = []
    @Published private(set) var historySearchResults: [HistorySearchHit] = []
    @Published private(set) var historySearchCoverage: HistorySearchCoverage?
    @Published private(set) var momentCoverage: MomentSearchCoverage?
    @Published private(set) var hasSearched = false
    @Published private(set) var searchNeedsRefresh = false
    @Published private(set) var isSearching = false
    @Published private(set) var isCheckingSearchEvidence = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isVisible = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var historyPosition = 0
    @Published private(set) var historyCount = 1
    @Published private(set) var bookmarks: [WorkspaceBookmark] = []
    let evidence: EvidenceViewModel
    var onSelectionInvalidated: (() -> Void)?
    var onSourceInvalidated: (() -> Void)?
    var onContextInvalidated: (() -> Void)?
    private let latest: @Sendable () async throws -> [DashboardScreenshotRow]
    private let search: @Sendable (String) async throws -> [SearchResult]
    private let momentSearch: (@Sendable (String) async throws -> SearchResults)?
    private let historySearch: (@Sendable (String) async throws -> HistorySearchResults)?
    private let revalidateHistorySearch: (@Sendable (HistorySearchResults) async throws -> Void)?
    private var historySearchBatch: HistorySearchResults?
    private let track: @Sendable (String) async -> Void
    private let seek: @Sendable (Date) async throws -> [DashboardScreenshotRow]
    private let bookmarkStore: WorkspaceBookmarkStore?
    private var loadedBookmarks = false
    private var lifecycle: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var presentationGeneration: UInt64 = 0
    private var searchGeneration: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    private var evidenceObservation: AnyCancellable?
    private var nonScreenEvidenceObservation: AnyCancellable?
    private var history: [Destination] = [.now]

    private enum Destination {
        case now
        case row(DashboardScreenshotRow)
        case reference(EvidenceRef)
        case search(SearchResult)
        case unavailableTime(Date)
    }

    init(evidence: EvidenceViewModel,
         latest: @escaping @Sendable () async throws -> [DashboardScreenshotRow],
         search: @escaping @Sendable (String) async throws -> [SearchResult],
         momentSearch: (@Sendable (String) async throws -> SearchResults)? = nil,
         historySearch: (@Sendable (String) async throws -> HistorySearchResults)? = nil,
         revalidateHistorySearch: (@Sendable (HistorySearchResults) async throws -> Void)? = nil,
         track: @escaping @Sendable (String) async -> Void,
         seek: @escaping @Sendable (Date) async throws -> [DashboardScreenshotRow] = { _ in [] },
         bookmarkStore: WorkspaceBookmarkStore? = nil) {
        self.evidence = evidence; self.latest = latest; self.search = search; self.track = track
        self.momentSearch = momentSearch
        self.historySearch = historySearch; self.revalidateHistorySearch = revalidateHistorySearch
        self.seek = seek; self.bookmarkStore = bookmarkStore
        evidenceObservation = evidence.$selectedFrame.sink { [weak self] frame in
            guard frame == nil, let self, case .screen = self.presentedReference else { return }
            self.invalidatePresentation()
        }
        nonScreenEvidenceObservation = evidence.$resolution.sink { [weak self] resolution in
            guard let self, let reference = self.presentedReference else { return }
            if case .screen = reference { return }
            switch resolution {
            case .activity, .job, .audio: break
            default: self.invalidatePresentation()
            }
        }
    }

    var selectedTimestamp: Date? { presentedReference == nil ? nil : evidence.selectedTimestamp }
    var canGoBack: Bool { historyPosition > 0 }
    var canGoForward: Bool { historyPosition + 1 < historyCount }
    var selectionAdmission: WorkspaceSelectionAdmission? {
        guard isVisible, let reference = presentedReference, evidence.hasAdmittedEvidence else { return nil }
        return WorkspaceSelectionAdmission(selection: selectionGeneration,
            presentation: presentationGeneration, reference: reference)
    }
    func admits(_ admission: WorkspaceSelectionAdmission) -> Bool {
        !Task.isCancelled && selectionAdmission == admission
    }

    func refresh() async {
        guard isVisible, !Task.isCancelled else { return }
        if let refreshTask { await refreshTask.value; return }
        let epoch = lifecycle
        isRefreshing = true
        onContextInvalidated?()
        let task = Task { [weak self, latest] in
            guard let self else { return }
            defer {
                if lifecycle == epoch { refreshTask = nil; isRefreshing = false }
            }
            await revalidateSearchResults()
            guard admits(epoch) else { return }
            do {
                if !loadedBookmarks {
                    let saved = await bookmarkStore?.load() ?? []
                    guard admits(epoch) else { return }
                    bookmarks = saved; loadedBookmarks = true
                }
                let current = try await latest()
                guard admits(epoch) else { return }
                var seen = Set<ScreenshotEvidenceSelection>()
                rows = Array(current.filter { seen.insert($0.id).inserted }.prefix(UnifiedWorkspacePolicy.maximumRows))
                errorMessage = nil
                if mode == .now, let newest = rows.first {
                    await show(newest, pin: false)
                } else {
                    if evidence.isPresentingEvidence {
                        let token = selectionGeneration
                        await evidence.refreshCurrentRevision()
                        guard acceptsSelection(token) else { return }
                        publishPresentedReference()
                    }
                    else if mode == .history { await restore(history[historyPosition]) }
                }
            } catch {
                guard admits(epoch) else { return }
                errorMessage = "Recorded history is temporarily unavailable."
                let token = selectionGeneration
                await evidence.refreshCurrentRevision()
                guard acceptsSelection(token) else { return }
                publishPresentedReference()
            }
        }
        refreshTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: {
            task.cancel()
        })
    }

    func select(_ row: DashboardScreenshotRow) async { await show(row, pin: true) }

    func select(_ result: SearchResult) async {
        guard isVisible, !Task.isCancelled else { return }
        let token = beginSelection(mode: .history)
        selection = ScreenshotEvidenceSelection(FrameReference(id: result.id, timestamp: result.timestamp,
            segmentID: result.segmentID, videoID: result.videoID, frameIndexInSegment: result.frameIndex,
            metadata: result.metadata, source: result.source), sourceGeneration: result.selectionToken?.sourceGeneration)
        await evidence.openSearchResult(result)
        guard acceptsSelection(token) else { return }
        presentedReference = evidence.availableReference
        append(evidence.evidenceReference.map(Destination.reference) ?? .search(result))
        await track("workspace_search_result_selected")
    }

    func selectTimelineFrame(_ acquired: WorkspaceTapeSelection) async {
        switch acquired {
        case .frame(let row): await show(row, pin: true)
        case .evidence(let reference): await selectEvidence(reference)
        }
    }

    /// This is a new user time navigation request, not resolution of a citation.
    /// The admitted nearest recorded row keeps its actual capture time visible.
    func selectTimestamp(_ timestamp: Date) async {
        guard isVisible, !Task.isCancelled else { return }
        let token = beginSelection(mode: .history)
        await selectTimestamp(timestamp, token: token)
    }

    /// One owned operation spans screen admission, tape anchoring, audio lookup
    /// and playback. Every selection/close/source change cancels this owner.
    func selectTranscript(at timestamp: Date,
        anchor: @escaping @MainActor () async -> Void,
        loadAudio: @escaping @MainActor (WorkspaceSelectionAdmission) async -> Bool,
        play: @escaping @MainActor (WorkspaceSelectionAdmission) async -> Void) async {
        guard isVisible, !Task.isCancelled else { return }
        let token = beginSelection(mode: .history)
        let task = Task { [weak self] in
            guard let self else { return }
            await selectTimestamp(timestamp, token: token)
            guard acceptsSelection(token), let admission = selectionAdmission else { return }
            await anchor()
            guard admits(admission) else { return }
            guard await loadAudio(admission), admits(admission) else { return }
            await play(admission)
            guard admits(admission) else { return }
            await track("workspace_transcript_selected")
        }
        transcriptTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        if selectionGeneration == token { transcriptTask = nil }
    }

    private func selectTimestamp(_ timestamp: Date, token: UInt64) async {
        guard acceptsSelection(token) else { return }
        evidence.closeEvidence()
        do {
            let candidates = try await seek(timestamp)
            guard acceptsSelection(token) else { return }
            guard let row = candidates.min(by: {
                abs($0.frame.timestamp.timeIntervalSince(timestamp)) < abs($1.frame.timestamp.timeIntervalSince(timestamp))
            }) else {
                selection = nil
                errorMessage = "No recorded screen is available near this time."
                append(.unavailableTime(timestamp)); return
            }
            await show(row, pin: true, ownedToken: token)
            guard acceptsSelection(token) else { return }
            await track("workspace_time_selected")
        } catch {
            guard acceptsSelection(token) else { return }
            selection = nil
            errorMessage = "The selected time could not be read."
            append(.unavailableTime(timestamp))
        }
    }

    var isBookmarked: Bool {
        guard let reference = presentedReference else { return false }
        return bookmarks.contains { $0.reference == reference }
    }

    func toggleBookmark() async {
        guard let reference = presentedReference, let timestamp = selectedTimestamp else { return }
        if let existing = bookmarks.first(where: { $0.reference == reference }) { await removeBookmark(existing.id); return }
        bookmarks.insert(WorkspaceBookmark(id: UUID(), reference: reference, capturedAt: timestamp), at: 0)
        bookmarks = Array(bookmarks.prefix(50))
        await bookmarkStore?.save(bookmarks)
        await track("workspace_bookmark_added")
    }

    func removeBookmark(_ id: UUID) async {
        bookmarks.removeAll { $0.id == id }
        await bookmarkStore?.save(bookmarks)
        await track("workspace_bookmark_removed")
    }

    func openBookmark(_ bookmark: WorkspaceBookmark) async {
        guard isVisible, !Task.isCancelled else { return }
        let token = selectionGeneration &+ 1
        await restore(.reference(bookmark.reference))
        guard acceptsSelection(token) else { return }
        append(.reference(bookmark.reference))
        await track("workspace_bookmark_opened")
    }

    func selectEvidence(_ reference: EvidenceRef) async {
        guard isVisible, !Task.isCancelled else { return }
        let token = selectionGeneration &+ 1
        await restore(.reference(reference))
        guard acceptsSelection(token) else { return }
        append(.reference(reference))
        await track("workspace_extraction_selected")
    }

    func showHistory() async {
        guard isVisible else { return }
        selectionGeneration &+= 1; transcriptTask?.cancel(); transcriptTask = nil
        mode = .history
        if let reference = evidence.evidenceReference { append(.reference(reference)) }
        else if let row = rows.first { await show(row, pin: true) }
        await track("workspace_history_opened")
    }

    func returnToNow() async {
        guard isVisible else { return }
        _ = beginSelection(mode: .now)
        evidence.closeEvidence()
        append(.now)
        await refresh()
        if mode == .now, isVisible, !Task.isCancelled, let newest = rows.first,
           selection != newest.id || !evidence.isPresentingEvidence {
            await show(newest, pin: false)
        }
        await track("workspace_returned_to_now")
    }

    func goBack() async {
        guard canGoBack, isVisible else { return }
        historyPosition -= 1
        await restore(history[historyPosition])
        await track("workspace_back")
    }

    func goForward() async {
        guard canGoForward, isVisible else { return }
        historyPosition += 1
        await restore(history[historyPosition])
        await track("workspace_forward")
    }

    func submitSearch(_ query: String) async {
        guard isVisible, !Task.isCancelled else { return }
        searchGeneration &+= 1
        let token = searchGeneration, epoch = lifecycle
        searchTask?.cancel()
        searchResults = []; isCheckingSearchEvidence = false; errorMessage = nil
        clearHistorySearch()
        momentCoverage = nil; hasSearched = false; searchNeedsRefresh = false
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isSearching = false; await track("workspace_search_cleared"); return
        }
        isSearching = true
        let task = Task { [weak self, search, momentSearch, historySearch, revalidateHistorySearch, track] in
            guard let self else { return }
            defer {
                if searchGeneration == token { isSearching = false; isCheckingSearchEvidence = false; searchTask = nil }
            }
            await track("workspace_search_submitted")
            do {
                if let historySearch {
                    let response = try await historySearch(query)
                    guard admits(epoch), searchGeneration == token else { return }
                    guard let revalidateHistorySearch else { throw EvidenceUnavailableReason.unsupported }
                    isCheckingSearchEvidence = true
                    try await revalidateHistorySearch(response)
                    guard admits(epoch), searchGeneration == token else { return }
                    publishHistorySearch(response)
                    hasSearched = true
                    await track(response.isEmpty ? "workspace_search_no_results" : "workspace_search_completed")
                    return
                }
                let results: [SearchResult]
                let coverage: MomentSearchCoverage?
                if let momentSearch {
                    let response = try await momentSearch(query)
                    results = response.results; coverage = response.momentCoverage
                } else {
                    results = try await search(query); coverage = nil
                }
                guard admits(epoch), searchGeneration == token else { return }
                isCheckingSearchEvidence = true
                let admitted = await admittedSearchResults(results, token: token, epoch: epoch)
                guard admits(epoch), searchGeneration == token else { return }
                searchResults = admitted
                momentCoverage = admitted.count == results.count ? coverage : nil
                searchNeedsRefresh = admitted.count != results.count
                hasSearched = true
                await track(admitted.isEmpty ? "workspace_search_no_results" : "workspace_search_completed")
            } catch {
                guard admits(epoch), searchGeneration == token else { return }
                errorMessage = "Search could not read the selected history sources."
                await track("workspace_search_failed")
            }
        }
        searchTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    func cancelSearch() {
        clearHistorySearch()
        momentCoverage = nil; hasSearched = false; searchNeedsRefresh = false
        searchGeneration &+= 1; searchTask?.cancel(); searchTask = nil; isSearching = false; isCheckingSearchEvidence = false
        Task { await track("workspace_search_cancelled") }
    }

    func sourceDidChange() {
        clearHistorySearch()
        momentCoverage = nil; hasSearched = false; searchNeedsRefresh = false
        lifecycle &+= 1; selectionGeneration &+= 1; searchGeneration &+= 1
        refreshTask?.cancel(); refreshTask = nil; searchTask?.cancel(); searchTask = nil
        rows = []; searchResults = []; isRefreshing = false; isSearching = false; isCheckingSearchEvidence = false
        invalidatePresentation(); onSourceInvalidated?()
        evidence.invalidateForSourceChange()
    }

    func close() {
        clearHistorySearch()
        momentCoverage = nil; hasSearched = false; searchNeedsRefresh = false
        isVisible = false; lifecycle &+= 1; selectionGeneration &+= 1; searchGeneration &+= 1
        refreshTask?.cancel(); refreshTask = nil; searchTask?.cancel(); searchTask = nil
        isRefreshing = false; isSearching = false; isCheckingSearchEvidence = false; rows = []; searchResults = []
        invalidatePresentation(); onSourceInvalidated?()
        evidence.closeEvidence()
    }

    func reopen() { isVisible = true }

    func selectHistoryHit(_ hit: HistorySearchHit) async {
        switch hit {
        case .screen(let screen): await select(screen.result)
        case .audio(let audio): await selectEvidence(.audio(audio.snapshot.reference))
        }
    }

    private func clearHistorySearch() {
        if historySearchBatch != nil { searchResults = []; momentCoverage = nil }
        historySearchBatch = nil; historySearchResults = []; historySearchCoverage = nil
    }

    private func publishHistorySearch(_ response: HistorySearchResults) {
        historySearchBatch = response
        historySearchResults = response.results
        historySearchCoverage = response.coverage
        searchResults = response.results.compactMap { hit in
            if case .screen(let screen) = hit { return screen.result }
            return nil
        }
        momentCoverage = response.coverage.screen
    }

    private func revalidateSearchResults() async {
        if let batch = historySearchBatch {
            let token = searchGeneration, epoch = lifecycle
            clearHistorySearch(); searchResults = []; momentCoverage = nil
            isCheckingSearchEvidence = true
            defer { if searchGeneration == token { isCheckingSearchEvidence = false } }
            do {
                guard let revalidateHistorySearch else { throw EvidenceUnavailableReason.unsupported }
                try await revalidateHistorySearch(batch)
                guard admits(epoch), searchGeneration == token else { return }
                publishHistorySearch(batch)
            } catch {
                guard admits(epoch), searchGeneration == token else { return }
                searchNeedsRefresh = true
            }
            return
        }
        guard !searchResults.isEmpty else { return }
        let candidates = searchResults, token = searchGeneration, epoch = lifecycle
        // Remove old snippets before any suspension. Revalidation cannot leave
        // known cached content visible while current permissions are checked.
        searchResults = []; isCheckingSearchEvidence = true
        defer { if searchGeneration == token { isCheckingSearchEvidence = false } }
        let admitted = await admittedSearchResults(candidates, token: token, epoch: epoch)
        guard admits(epoch), searchGeneration == token else { return }
        searchResults = admitted
        if admitted.count != candidates.count {
            momentCoverage = nil
            searchNeedsRefresh = true
        }
        // The remaining coverage describes this query's original scan. A
        // successful unchanged admission is not a new exhaustive search.
    }

    private func admittedSearchResults(_ candidates: [SearchResult], token: UInt64, epoch: UInt64) async -> [SearchResult] {
        let began = CFAbsoluteTimeGetCurrent()
        defer { Log.recordLatency("workspace.search.admission", valueMs: (CFAbsoluteTimeGetCurrent() - began) * 1_000, category: .ui) }
        var seen = Set<String>()
        let bounded = candidates.prefix(100).filter { seen.insert($0.sourceQualifiedID).inserted }
        guard !bounded.isEmpty, admits(epoch), searchGeneration == token else { return [] }
        let sources = Set(bounded.map(\.source))
        do {
            // Per-row checks cannot detect A changing while B is suspended.
            // Fence the complete publication batch with the canonical source,
            // content and privacy stamp, including all admission awaits.
            let before = try await evidence.presentationStamp(sources: sources)
            var admitted: [SearchResult] = []
            for result in bounded {
                guard admits(epoch), searchGeneration == token else { return [] }
                let permitted = await evidence.admitsSearchResult(result)
                guard admits(epoch), searchGeneration == token else { return [] }
                if permitted { admitted.append(result) }
            }
            let after = try await evidence.presentationStamp(sources: sources)
            guard before == after, admits(epoch), searchGeneration == token else { return [] }
            return admitted
        } catch {
            guard admits(epoch), searchGeneration == token else { return [] }
            return []
        }
    }

    private func show(_ row: DashboardScreenshotRow, pin: Bool, ownedToken: UInt64? = nil) async {
        guard isVisible, !Task.isCancelled else { return }
        if !pin, selection == row.id, evidence.isPresentingEvidence, evidence.evidenceReference != nil {
            let token = selectionGeneration
            await evidence.refreshCurrentRevision()
            guard acceptsSelection(token) else { return }
            publishPresentedReference()
            return
        }
        let token = ownedToken ?? beginSelection(mode: pin ? .history : .now)
        guard acceptsSelection(token) else { return }
        selection = row.id
        await evidence.openFrame(row.frame, expectedSourceGeneration: row.sourceGeneration)
        guard acceptsSelection(token) else { return }
        presentedReference = evidence.availableReference
        errorMessage = nil
        if pin {
            append(evidence.evidenceReference.map(Destination.reference) ?? .row(row))
            await track("workspace_moment_selected")
        }
    }

    private func restore(_ destination: Destination) async {
        switch destination {
        case .now:
            _ = beginSelection(mode: .now); evidence.closeEvidence()
            if let row = rows.first { await show(row, pin: false) }
        case .row(let row):
            let token = beginSelection(mode: .history); selection = row.id
            await evidence.openFrame(row.frame, expectedSourceGeneration: row.sourceGeneration)
            guard acceptsSelection(token) else { return }
            presentedReference = evidence.availableReference
        case .reference(let reference):
            let token = beginSelection(mode: .history)
            selection = nil
            await evidence.openEvidence(reference)
            guard acceptsSelection(token) else { return }
            presentedReference = evidence.availableReference
            if let frame = evidence.selectedFrame {
                selection = ScreenshotEvidenceSelection(frame)
            }
        case .search(let result):
            let token = beginSelection(mode: .history)
            selection = nil
            await evidence.openSearchResult(result)
            guard acceptsSelection(token) else { return }
            presentedReference = evidence.availableReference
        case .unavailableTime:
            _ = beginSelection(mode: .history)
            selection = nil; evidence.closeEvidence()
            errorMessage = "No recorded screen is available for the requested time."
        }
    }

    private func append(_ destination: Destination) {
        if case .reference(let ref) = destination,
           case .reference(let existing) = history[historyPosition], ref == existing { return }
        if case .now = destination, case .now = history[historyPosition] { return }
        history = Array(history.prefix(historyPosition + 1))
        history.append(destination)
        if history.count > UnifiedWorkspacePolicy.maximumHistory { history.removeFirst(history.count - UnifiedWorkspacePolicy.maximumHistory) }
        historyPosition = history.count - 1; historyCount = history.count
    }

    private func beginSelection(mode: Mode) -> UInt64 {
        selectionGeneration &+= 1; invalidatePresentation(); self.mode = mode; return selectionGeneration
    }
    private func invalidatePresentation() {
        presentationGeneration &+= 1; presentedReference = nil
        transcriptTask?.cancel(); transcriptTask = nil
        onSelectionInvalidated?()
    }
    private func publishPresentedReference() {
        presentedReference = evidence.availableReference
    }
    private func acceptsSelection(_ token: UInt64) -> Bool {
        isVisible && !Task.isCancelled && token == selectionGeneration
    }
    private func admits(_ epoch: UInt64) -> Bool { isVisible && !Task.isCancelled && lifecycle == epoch }
}
