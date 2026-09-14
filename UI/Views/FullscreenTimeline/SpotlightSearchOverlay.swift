import SwiftUI
import Shared
import App
import AppKit

private let searchLog = "[SpotlightSearch]"

/// Spotlight-style search overlay that appears center-screen
/// Triggered by Cmd+K or search icon click
public struct SpotlightSearchOverlay: View {

    // MARK: - Properties

    let coordinator: AppCoordinator
    let onResultSelected: (SearchResult, String) -> Void  // Result + search query for highlighting
    let onDismiss: () -> Void

    /// External SearchViewModel that persists across overlay open/close
    /// This allows search results to be preserved when clicking on a result
    @ObservedObject private var viewModel: SearchViewModel
    @State private var isVisible = false
    @State private var resultsHeight: CGFloat = 0  // Reserved results viewport height to avoid collapse during reloads
    @State private var isExpanded = false  // Whether to show filters and results (expanded view)
    @State private var refocusSearchField: UUID = UUID()  // Trigger to refocus search field
    @State private var keyboardSelectedResultIndex: Int?
    @State private var isResultKeyboardNavigationActive = false
    @State private var shouldFocusFirstResultAfterSubmit = false
    @State private var isRecentEntriesPopoverVisible = false
    @State private var isRecentEntriesDismissedByUser = false
    @State private var suppressRecentEntriesForCurrentPresentation = false
    @State private var highlightedRecentEntryIndex = 0
    @State private var hoveredRecentEntryKey: String?
    @State private var rankedRecentEntries: [SearchViewModel.RecentSearchEntry] = []
    @State private var recentEntryTagByID: [Int64: Tag] = [:]
    @State private var recentEntryAppNamesByBundleID: [String: String] = [:]
    @State private var recentEntriesRevealBlockedUntil: Date?
    @State private var recentEntriesRevealTask: Task<Void, Never>?
    @State private var recentEntriesMetadataWarmupTask: Task<Void, Never>?
    @State private var didScheduleRecentEntriesMetadataWarmup = false
    @State private var keyEventMonitor: Any?
    @State private var overlayOpenStartTime: CFAbsoluteTime?
    @State private var didRecordOpenLatency = false
    @State private var isDismissing = false
    @State private var overlaySessionID = "unknown"
    @State private var isSearchFieldFocused = false
    @State private var thumbnailLoader = SearchEvidenceThumbnailLoader()

    private let panelWidth: CGFloat = 1000
    private let collapsedWidth: CGFloat = 450
    private let maxResultsHeight: CGFloat = 550
    private let minResultsHeight: CGFloat = 220
    private let dismissAnimationDuration: TimeInterval = 0.15
    private let thumbnailSize = CGSize(width: 280, height: 175)
    private let recentEntryLimit = 15
    private let recentEntryVisibleCount = 5
    private let recentEntryRowHeight: CGFloat = 54
    private let recentEntryRowSpacing: CGFloat = 0
    private let recentEntryListVerticalPadding: CGFloat = 6
    private let recentEntryAppIconSize: CGFloat = 16
    private static let recentEntryMediumDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
    private static let recentEntryShortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
    private let gridColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    // MARK: - Initialization

    public init(
        coordinator: AppCoordinator,
        viewModel: SearchViewModel,
        onResultSelected: @escaping (SearchResult, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.viewModel = viewModel
        self.onResultSelected = onResultSelected
        self.onDismiss = onDismiss
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Backdrop - also dismisses dropdowns if open
            // Only show backdrop when expanded
            if isExpanded {
                Color.black.opacity(isVisible ? 0.6 : 0)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if viewModel.isDropdownOpen {
                            viewModel.closeDropdownsSignal += 1
                        } else {
                            // Outside click should dismiss with animation but preserve search state.
                            dismissOverlayPreservingSearch()
                        }
                    }
            }

            // Search panel - use ZStack to allow dropdowns to escape clipping
            ZStack(alignment: .top) {
                // Main panel content (clipped)
                VStack(spacing: 0) {
                    searchBar

                    // Only show filter bar and results when expanded
                    if isExpanded {
                        Divider()
                            .background(Color.white.opacity(0.1))

                        // Filter bar placeholder + results
                        VStack(spacing: 0) {
                            // Reserve vertical space for the filter bar so results don't jump when it appears.
                            Color.clear
                                .frame(height: 48)
                                .allowsHitTesting(false)

                            if hasResults {
                                // Small gap before divider to maintain visual spacing below filter bar
                                Color.clear.frame(height: 4)

                                Divider()
                                    .background(Color.white.opacity(0.1))

                                resultsArea
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        // Dismiss dropdown when tapping on results area
                                        if viewModel.isDropdownOpen {
                                            viewModel.closeDropdownsSignal += 1
                                        }
                                    }
                            }
                        }
                    }
                }
                .frame(width: isExpanded ? panelWidth : collapsedWidth)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.4))
                        .background(.ultraThinMaterial)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(isExpanded ? 0 : 0.15), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 20, y: 10)
                .overlay(alignment: .top) {
                    recentEntriesPopover
                        .offset(y: isRecentEntriesPopoverVisible ? 58 : 50)
                        .opacity(isRecentEntriesPopoverVisible ? 1 : 0)
                        .allowsHitTesting(isRecentEntriesPopoverVisible)
                        .zIndex(20)
                }

                // Filter bar overlay (NOT clipped, so dropdowns can extend beyond panel)
                if isExpanded {
                    VStack(spacing: 0) {
                        // Offset to position below search bar + divider
                        Color.clear.frame(height: 57) // searchBar height (~56px) + divider (1px)
                        SearchFilterBar(viewModel: viewModel)
                    }
                    .frame(width: panelWidth)
                }
            }
            .scaleEffect(isVisible ? 1.0 : 0.95)
            .opacity(isVisible ? 1.0 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isExpanded)
            .animation(.easeOut(duration: 0.15), value: isRecentEntriesPopoverVisible)
        }
        .onAppear {
            overlaySessionID = String(UUID().uuidString.prefix(8))
            overlayOpenStartTime = CFAbsoluteTimeGetCurrent()
            didRecordOpenLatency = false
            viewModel.isRecentEntriesPopoverVisible = false
            logRecentEntriesState(context: "onAppear:beforeOpenAnimation")
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isVisible = true
                // If there are existing results, expand to show them
                if viewModel.results != nil && !viewModel.searchQuery.isEmpty {
                    isExpanded = true
                }
            }
            viewModel.isSearchOverlayExpanded = isExpanded
            installKeyEventMonitor()
            scheduleOpenLatencyMeasurement()
            if !viewModel.visibleResults.isEmpty {
                reserveExpandedResultsHeight()
            }
            isRecentEntriesDismissedByUser = false
            configureRecentEntriesRevealDelay()
            refreshRankedRecentEntries()
            refreshRecentEntryTagMap()
            refreshRecentEntryAppNameMap()
            scheduleRecentEntriesMetadataWarmupIfNeeded()
            refreshRecentEntriesPopoverVisibility()
            logRecentEntriesState(context: "onAppear:afterRefresh")
        }
        .onDisappear {
            recentEntriesRevealTask?.cancel()
            recentEntriesRevealTask = nil
            recentEntriesMetadataWarmupTask?.cancel()
            recentEntriesMetadataWarmupTask = nil
            removeKeyEventMonitor()
            clearResultKeyboardNavigation()
            viewModel.isSearchOverlayExpanded = false
            overlayOpenStartTime = nil
            didRecordOpenLatency = false
            isRecentEntriesPopoverVisible = false
            isRecentEntriesDismissedByUser = false
            suppressRecentEntriesForCurrentPresentation = false
            highlightedRecentEntryIndex = 0
            hoveredRecentEntryKey = nil
            isSearchFieldFocused = false
            rankedRecentEntries = []
            recentEntryTagByID = [:]
            recentEntryAppNamesByBundleID = [:]
            recentEntriesRevealBlockedUntil = nil
            didScheduleRecentEntriesMetadataWarmup = false
            viewModel.isRecentEntriesPopoverVisible = false
            logRecentEntriesState(context: "onDisappear")
        }
        .onChange(of: isExpanded) { expanded in
            viewModel.isSearchOverlayExpanded = expanded
        }
        .onExitCommand {
            handleSearchEscape()
        }
        .onChange(of: viewModel.searchQuery) { newValue in
            if newValue != viewModel.committedSearchQuery {
                clearResultKeyboardNavigation()
            }
            highlightedRecentEntryIndex = 0
            if newValue.isEmpty {
                resultsHeight = 0
            }
            refreshRankedRecentEntries()
            refreshRecentEntriesPopoverVisibility()
        }
        .onChange(of: viewModel.isSearching) { isSearching in
            if isSearching && !isExpanded {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded = true
                }
            }
            // Log results when search completes
            if !isSearching {
                if let results = viewModel.results {
                    Log.info("\(searchLog) Results received: \(results.results.count) results, totalCount=\(results.totalCount), searchTime=\(results.searchTimeMs)ms", category: .ui)
                }
                if shouldFocusFirstResultAfterSubmit {
                    focusFirstResultIfAvailable()
                }
            }
            refreshRecentEntriesPopoverVisibility()
        }
        .onChange(of: viewModel.visibleResults.count) { _ in
            Log.info(
                "\(searchLog) Results count changed: generation=\(viewModel.searchGeneration), isSearching=\(viewModel.isSearching), filteredCount=\(viewModel.visibleResults.count), totalCount=\(viewModel.results?.results.count ?? 0), query='\(viewModel.searchQuery)', committed='\(viewModel.committedSearchQuery)'",
                category: .ui
            )
            if !viewModel.visibleResults.isEmpty {
                reserveExpandedResultsHeight()
            }
            syncKeyboardSelectionWithCurrentResults()
        }
        .onChange(of: viewModel.searchGeneration) { generation in
            Log.info(
                "\(searchLog) searchGeneration changed to \(generation) (query='\(viewModel.searchQuery)', committed='\(viewModel.committedSearchQuery)', currentResults=\(viewModel.results?.results.count ?? 0))",
                category: .ui
            )
        }
        .onChange(of: isExpanded) { _ in
            refreshRecentEntriesPopoverVisibility()
        }
        .onChange(of: viewModel.openFilterSignal.id) { _ in
            // When Tab cycles back to search field (index 0), trigger refocus
            if viewModel.openFilterSignal.index == 0 {
                refocusSearchField = UUID()
            }
        }
        .onChange(of: viewModel.isDropdownOpen) { isOpen in
            // When a dropdown closes (Escape or Enter selection), refocus the search field
            if !isOpen {
                refocusSearchField = UUID()
            }
            if isOpen {
                isRecentEntriesPopoverVisible = false
            } else {
                refreshRecentEntriesPopoverVisibility()
            }
        }
        .onChange(of: viewModel.dismissOverlaySignal.id) { _ in
            dismissOverlay(clearSearchState: viewModel.dismissOverlaySignal.clearSearchState)
        }
        .onChange(of: viewModel.collapseOverlaySignal) { _ in
            collapseToCompactSearchBar(clearFilters: false)
        }
        .onChange(of: viewModel.dismissRecentEntriesPopoverSignal) { _ in
            dismissRecentEntriesPopoverByUser()
        }
        .onChange(of: viewModel.recentSearchEntries) { _ in
            refreshRankedRecentEntries()
            refreshRecentEntriesPopoverVisibility()
        }
        .onChange(of: viewModel.availableTags.map { "\($0.id.value)|\($0.name)" }) { _ in
            refreshRecentEntryTagMap()
        }
        .onChange(of: viewModel.availableApps.map { "\($0.bundleID)|\($0.name)" }) { _ in
            refreshRecentEntryAppNameMap()
        }
        .onChange(of: isRecentEntriesPopoverVisible) { isVisible in
            viewModel.isRecentEntriesPopoverVisible = isVisible
        }
        .onPreferenceChange(ResultsAreaHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            let clampedHeight = min(maxResultsHeight, max(minResultsHeight, height))
            // Guard with epsilon to prevent geometry-driven update loops.
            guard abs(resultsHeight - clampedHeight) > 1 else { return }
            resultsHeight = clampedHeight
        }
    }

    // MARK: - Search Bar

    private var isSpotlightSearchGlowActive: Bool {
        isSearchFieldFocused || !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.retraceTitle3)
                    .foregroundColor(.white.opacity(0.5))

                SpotlightSearchField(
                    text: $viewModel.searchQuery,
                    onSubmit: {
                        if isRecentEntriesPopoverVisible {
                            selectHighlightedRecentEntry()
                            return
                        }
                        if !viewModel.searchQuery.isEmpty {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                isExpanded = true
                            }
                            prepareResultKeyboardNavigationAfterSubmit()
                            viewModel.submitSearch()
                        }
                    },
                    onEscape: {
                        handleSearchEscape()
                    },
                    onTab: {
                        // Tab from search field opens search-order dropdown (first filter)
                        isRecentEntriesPopoverVisible = false
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isExpanded = true
                        }
                        // Signal to open search-order filter (index 1)
                        viewModel.openFilterSignal = (1, UUID())
                    },
                    onBackTab: {
                        // Shift+Tab from search field opens Advanced filter (last filter)
                        isRecentEntriesPopoverVisible = false
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isExpanded = true
                        }
                        viewModel.openFilterSignal = (7, UUID())
                    },
                    onFocus: {
                        Log.info("\(searchLog)[\(overlaySessionID)] search field focused", category: .ui)
                        isSearchFieldFocused = true
                        clearResultKeyboardNavigation()
                        // Close any open dropdowns when search field gains focus
                        if viewModel.isDropdownOpen {
                            viewModel.closeDropdownsSignal += 1
                        }
                        refreshRecentEntriesPopoverVisibility()
                    },
                    onBlur: {
                        isSearchFieldFocused = false
                    },
                    onArrowDown: {
                        guard isRecentEntriesPopoverVisible else { return false }
                        guard !rankedRecentEntries.isEmpty else { return false }
                        highlightedRecentEntryIndex = min(highlightedRecentEntryIndex + 1, rankedRecentEntries.count - 1)
                        return true
                    },
                    onArrowUp: {
                        guard isRecentEntriesPopoverVisible else { return false }
                        highlightedRecentEntryIndex = max(highlightedRecentEntryIndex - 1, 0)
                        return true
                    },
                    refocusTrigger: refocusSearchField
                )
                .frame(height: 30)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                refocusSearchField = UUID()
            }

            // Loading spinner (shown while searching)
            if viewModel.isSearching {
                SpinnerView(size: 20, lineWidth: 2, color: .white)
                    // Keep search row height stable while loading so filter bar offset does not shift.
                    .frame(width: 24, height: 24)
            }

            // Filter button (expands to show filters)
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded = true
                }
            }) {
                ZStack {
                    Circle()
                        .fill(isExpanded || viewModel.hasActiveFilters ? Color.white.opacity(0.2) : Color.white.opacity(0.1))
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(isExpanded || viewModel.hasActiveFilters ? .white : .white.opacity(0.6))
                }
                .frame(width: 24, height: 24)
                .overlay(alignment: .topTrailing) {
                    if viewModel.activeFilterCount > 0 {
                        Text("\(viewModel.activeFilterCount)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 14, height: 14)
                            .background(Color.red)
                            .clipShape(Circle())
                            .offset(x: 4, y: -4)
                    }
                }
            }
            .buttonStyle(.plain)

            // Close button
            Button(action: {
                dismissOverlay()
            }) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.1))
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 12,
                bottomLeadingRadius: isExpanded ? 0 : 12,
                bottomTrailingRadius: isExpanded ? 0 : 12,
                topTrailingRadius: 12
            )
                .stroke(
                    Color.white.opacity(isExpanded ? 0 : (isSpotlightSearchGlowActive ? 0.60 : 0.28)),
                    lineWidth: isExpanded ? 0 : (isSpotlightSearchGlowActive ? 1.8 : 1.0)
                )
        )
        .shadow(
            color: Color.white.opacity(isExpanded ? 0 : (isSpotlightSearchGlowActive ? 0.28 : 0.10)),
            radius: isSpotlightSearchGlowActive ? 14 : 7,
            x: 0,
            y: 0
        )
        .shadow(
            color: Color.black.opacity(isSpotlightSearchGlowActive ? 0.32 : 0.14),
            radius: isSpotlightSearchGlowActive ? 22 : 10,
            x: 0,
            y: 0
        )
        .animation(.easeOut(duration: 0.18), value: isSpotlightSearchGlowActive)
    }

    // MARK: - Recent Entries

    private func refreshRankedRecentEntries() {
        rankedRecentEntries = viewModel.rankedRecentSearchEntries(for: viewModel.searchQuery, limit: recentEntryLimit)
    }

    private func refreshRecentEntryTagMap() {
        recentEntryTagByID = Dictionary(
            viewModel.availableTags.map { ($0.id.value, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func refreshRecentEntryAppNameMap() {
        recentEntryAppNamesByBundleID = Dictionary(
            viewModel.availableApps.map { ($0.bundleID, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var rankedRecentEntriesCount: Int {
        rankedRecentEntries.count
    }

    private var shouldShowRecentEntriesPopover: Bool {
        guard isVisible else { return false }
        guard !isRecentEntriesDismissedByUser else { return false }
        let isQueryEmpty = viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if suppressRecentEntriesForCurrentPresentation && isQueryEmpty {
            return false
        }
        if let blockedUntil = recentEntriesRevealBlockedUntil, Date() < blockedUntil {
            return false
        }
        guard !viewModel.isDropdownOpen else { return false }
        guard !viewModel.isSearching else { return false }
        guard !isResultKeyboardNavigationActive else { return false }
        guard !isExpanded else { return false }
        guard viewModel.results == nil else { return false }
        return rankedRecentEntriesCount > 0
    }

    private func configureRecentEntriesRevealDelay() {
        recentEntriesRevealTask?.cancel()
        recentEntriesRevealTask = nil

        suppressRecentEntriesForCurrentPresentation = viewModel.consumeSuppressRecentEntriesForNextOverlayOpen()
        let revealDelay = viewModel.consumeNextRecentEntriesRevealDelay()
        Log.info(
            "\(searchLog)[\(overlaySessionID)] configureRecentEntriesRevealDelay suppressForPresentation=\(suppressRecentEntriesForCurrentPresentation) revealDelay=\(String(format: "%.3f", revealDelay))",
            category: .ui
        )
        guard revealDelay > 0 else {
            recentEntriesRevealBlockedUntil = nil
            return
        }

        recentEntriesRevealBlockedUntil = Date().addingTimeInterval(revealDelay)
        recentEntriesRevealTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(revealDelay), clock: .continuous)
            guard !Task.isCancelled else { return }
            recentEntriesRevealBlockedUntil = nil
            Log.info("\(searchLog)[\(overlaySessionID)] revealDelay elapsed; reevaluating popover visibility", category: .ui)
            refreshRecentEntriesPopoverVisibility()
        }
    }

    private func refreshRecentEntriesPopoverVisibility() {
        let shouldShow = shouldShowRecentEntriesPopover
        if shouldShow != isRecentEntriesPopoverVisible {
            Log.info(
                "\(searchLog)[\(overlaySessionID)] popover visibility \(isRecentEntriesPopoverVisible) -> \(shouldShow)",
                category: .ui
            )
            withAnimation(.easeOut(duration: 0.15)) {
                isRecentEntriesPopoverVisible = shouldShow
            }
        }

        if shouldShow {
            scheduleRecentEntriesMetadataWarmupIfNeeded()
        }

        if isRecentEntriesPopoverVisible {
            highlightedRecentEntryIndex = min(highlightedRecentEntryIndex, max(rankedRecentEntries.count - 1, 0))
        } else {
            highlightedRecentEntryIndex = 0
            hoveredRecentEntryKey = nil
        }
        logRecentEntriesState(context: "refreshRecentEntriesPopoverVisibility")
    }

    private func scheduleRecentEntriesMetadataWarmupIfNeeded() {
        guard !didScheduleRecentEntriesMetadataWarmup else { return }
        didScheduleRecentEntriesMetadataWarmup = true

        recentEntriesMetadataWarmupTask?.cancel()
        recentEntriesMetadataWarmupTask = Task(priority: .utility) {
            // Let overlay first frame settle before metadata warmup.
            try? await Task.sleep(for: .milliseconds(120), clock: .continuous)
            guard !Task.isCancelled else { return }

            async let apps: Void = viewModel.loadAvailableApps()
            async let tags: Void = viewModel.loadAvailableTags()
            _ = await (apps, tags)
        }
    }

    private func selectHighlightedRecentEntry() {
        let entries = rankedRecentEntries
        guard !entries.isEmpty else { return }
        let selectedIndex = min(highlightedRecentEntryIndex, entries.count - 1)
        selectRecentEntry(entries[selectedIndex])
    }

    private func selectRecentEntry(_ entry: SearchViewModel.RecentSearchEntry) {
        viewModel.submitRecentSearchEntry(entry)
        isRecentEntriesPopoverVisible = false
        highlightedRecentEntryIndex = 0
        hoveredRecentEntryKey = nil

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isExpanded = true
        }

        prepareResultKeyboardNavigationAfterSubmit()
    }

    private func removeRecentEntry(_ entry: SearchViewModel.RecentSearchEntry) {
        viewModel.removeRecentSearchEntry(entry)
        Log.info("\(searchLog)[\(overlaySessionID)] removed recent entry key=\(entry.key)", category: .ui)
    }

    private func dismissRecentEntriesPopoverByUser() {
        isRecentEntriesDismissedByUser = true
        Log.info("\(searchLog)[\(overlaySessionID)] user dismissed recent entries popover via header x", category: .ui)
        withAnimation(.easeOut(duration: 0.15)) {
            isRecentEntriesPopoverVisible = false
        }
        highlightedRecentEntryIndex = 0
        hoveredRecentEntryKey = nil
    }

    private func logRecentEntriesState(context: String) {
        let isQueryEmpty = viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let blockedUntilActive: Bool = {
            if let blockedUntil = recentEntriesRevealBlockedUntil {
                return Date() < blockedUntil
            }
            return false
        }()
        let hasResults = viewModel.results != nil
        let rankedCount = rankedRecentEntriesCount
        let shouldShow = shouldShowRecentEntriesPopover
        Log.info(
            "\(searchLog)[\(overlaySessionID)] \(context) visible=\(isVisible) expanded=\(isExpanded) queryEmpty=\(isQueryEmpty) hasResults=\(hasResults) rankedCount=\(rankedCount) dismissedByUser=\(isRecentEntriesDismissedByUser) suppressForPresentation=\(suppressRecentEntriesForCurrentPresentation) blockedUntilActive=\(blockedUntilActive) dropdownOpen=\(viewModel.isDropdownOpen) searching=\(viewModel.isSearching) resultNavActive=\(isResultKeyboardNavigationActive) popoverVisible=\(isRecentEntriesPopoverVisible) shouldShow=\(shouldShow)",
            category: .ui
        )
    }

    private var recentEntriesViewportHeight: CGFloat {
        let visibleCount = max(1, min(recentEntryVisibleCount, rankedRecentEntriesCount))
        let rowsHeight = CGFloat(visibleCount) * recentEntryRowHeight
        let spacingHeight = CGFloat(max(0, visibleCount - 1)) * recentEntryRowSpacing
        return rowsHeight + spacingHeight + (recentEntryListVerticalPadding * 2)
    }

    private var recentEntriesPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(RetraceMenuStyle.textColorMuted)
                Text("Recent Entries")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(RetraceMenuStyle.textColorMuted)
                Spacer(minLength: 8)
                Button(action: {
                    dismissRecentEntriesPopoverByUser()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(RetraceMenuStyle.textColorMuted)
                        .frame(width: 16, height: 16)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .help("Hide recent entries")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView(.vertical, showsIndicators: rankedRecentEntriesCount > recentEntryVisibleCount) {
                VStack(spacing: recentEntryRowSpacing) {
                    ForEach(Array(rankedRecentEntries.enumerated()), id: \.element.key) { index, entry in
                        let isRowHovered = hoveredRecentEntryKey == entry.key
                        HStack(alignment: .top, spacing: 8) {
                            Button {
                                selectRecentEntry(entry)
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text(entry.query)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(RetraceMenuStyle.textColor)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Spacer(minLength: 6)
                                        Text(recentEntryRelativeTimeText(for: entry))
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(RetraceMenuStyle.textColorMuted)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }

                                    recentEntryFilterSummaryRow(for: entry.filters)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Button {
                                removeRecentEntry(entry)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundColor(RetraceMenuStyle.textColorMuted)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 12, height: 12)
                            .padding(.top, 2)
                            .opacity(isRowHovered ? 1 : 0)
                            .allowsHitTesting(isRowHovered)
                            .accessibilityHidden(!isRowHovered)
                            .help("Remove recent search")
                        }
                        .frame(maxWidth: .infinity, minHeight: recentEntryRowHeight, maxHeight: recentEntryRowHeight, alignment: .leading)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: RetraceMenuStyle.itemCornerRadius)
                                .fill(index == highlightedRecentEntryIndex ? RetraceMenuStyle.itemHoverColor : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: RetraceMenuStyle.itemCornerRadius)
                                .stroke(
                                    index == highlightedRecentEntryIndex
                                        ? RetraceMenuStyle.filterStrokeMedium
                                        : Color.clear,
                                    lineWidth: 1
                                )
                        )
                        .contentShape(Rectangle())
                        .id(entry.key)
                        .onHover { hovering in
                            if hovering {
                                highlightedRecentEntryIndex = index
                                hoveredRecentEntryKey = entry.key
                            } else if hoveredRecentEntryKey == entry.key {
                                hoveredRecentEntryKey = nil
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, recentEntryListVerticalPadding)
            }
            .frame(height: recentEntriesViewportHeight)
            .padding(.bottom, 10)
        }
        .frame(width: collapsedWidth - 8, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.4))
                .background(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.5), radius: 20, y: 10)
    }

    private func recentEntryRelativeTimeText(for entry: SearchViewModel.RecentSearchEntry) -> String {
        let now = Date()
        let usedDate = Date(timeIntervalSince1970: entry.lastUsedAt)
        let elapsedSeconds = max(0, Int(now.timeIntervalSince(usedDate)))
        let calendar = Calendar.current

        if elapsedSeconds < 60 {
            return "just now"
        }
        if elapsedSeconds < 3600 {
            let minutes = elapsedSeconds / 60
            return "\(minutes) min ago"
        }
        if elapsedSeconds < 86_400 {
            let hours = elapsedSeconds / 3600
            let minutes = (elapsedSeconds % 3600) / 60
            if minutes == 0 {
                return "\(hours) hour\(hours == 1 ? "" : "s") ago"
            }
            return "\(hours) hour\(hours == 1 ? "" : "s") \(minutes) min ago"
        }
        if calendar.isDateInYesterday(usedDate) {
            return "yesterday"
        }
        if elapsedSeconds < 7 * 86_400 {
            let days = elapsedSeconds / 86_400
            return "\(days) day\(days == 1 ? "" : "s") ago"
        }

        return Self.recentEntryMediumDateFormatter.string(from: usedDate)
    }

    @ViewBuilder
    private func recentEntryFilterSummaryRow(for filters: SearchViewModel.RecentSearchFilters) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
            if !filters.appBundleIDs.isEmpty {
                recentEntryAppSummary(for: filters)
            }

            if !filters.tagIDs.isEmpty {
                if filters.tagFilterMode == .exclude {
                    recentEntryMetadataToken(icon: "minus.circle.fill", text: "Tags", tint: .orange.opacity(0.9))
                }
                ForEach(recentEntryTags(for: filters), id: \.id.value) { tag in
                    recentEntryTagBadge(tag)
                }
            }

            if let dateLabel = recentEntryDateLabel(for: filters) {
                recentEntryMetadataToken(icon: "calendar", text: dateLabel)
            }

            if filters.hiddenFilter != .hide {
                recentEntryMetadataToken(
                    icon: visibilityIcon(for: filters.hiddenFilter),
                    text: visibilityLabel(for: filters.hiddenFilter)
                )
            }

            if filters.commentFilter != .allFrames {
                recentEntryMetadataToken(
                    icon: commentIcon(for: filters.commentFilter),
                    text: commentLabel(for: filters.commentFilter)
                )
            }

            if !filters.windowNameTerms.isEmpty {
                let tint: Color = filters.windowNameFilterMode == .exclude ? .orange.opacity(0.9) : RetraceMenuStyle.textColorMuted
                let icon = filters.windowNameFilterMode == .exclude ? "minus.circle.fill" : "rectangle.and.text.magnifyingglass"
                ForEach(Array(filters.windowNameTerms.prefix(3)), id: \.self) { term in
                    recentEntryMetadataToken(icon: icon, text: "Title: \(term)", tint: tint)
                }
                if filters.windowNameTerms.count > 3 {
                    recentEntryMetadataToken(icon: "ellipsis.circle", text: "+\(filters.windowNameTerms.count - 3)", tint: tint)
                }
            }

            if !filters.browserUrlTerms.isEmpty {
                let tint: Color = filters.browserUrlFilterMode == .exclude ? .orange.opacity(0.9) : RetraceMenuStyle.textColorMuted
                let icon = filters.browserUrlFilterMode == .exclude ? "minus.circle.fill" : "link"
                ForEach(Array(filters.browserUrlTerms.prefix(3)), id: \.self) { term in
                    recentEntryMetadataToken(icon: icon, text: "URL: \(term)", tint: tint)
                }
                if filters.browserUrlTerms.count > 3 {
                    recentEntryMetadataToken(icon: "ellipsis.circle", text: "+\(filters.browserUrlTerms.count - 3)", tint: tint)
                }
            }

            if !filters.excludedQueryTerms.isEmpty {
                ForEach(Array(filters.excludedQueryTerms.prefix(4)), id: \.self) { excludedTerm in
                    recentEntryMetadataToken(
                        icon: "minus.circle.fill",
                        text: excludedTerm,
                        tint: .orange.opacity(0.9)
                    )
                }
                if filters.excludedQueryTerms.count > 4 {
                    recentEntryMetadataToken(
                        icon: "ellipsis.circle",
                        text: "+\(filters.excludedQueryTerms.count - 4)",
                        tint: .orange.opacity(0.9)
                    )
                }
            }

            if !hasRecentEntryFilterMetadata(filters) {
                recentEntryMetadataToken(icon: "slider.horizontal.3", text: "No filters")
            }
        }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recentEntryAppSummary(for filters: SearchViewModel.RecentSearchFilters) -> some View {
        let bundleIDs = filters.appBundleIDs

        return HStack(spacing: 4) {
            if filters.appFilterMode == .exclude {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.orange.opacity(0.95))
            }

            if bundleIDs.count == 1, let bundleID = bundleIDs.first {
                HStack(spacing: 5) {
                    AppIconView(bundleID: bundleID, size: recentEntryAppIconSize)
                        .frame(width: recentEntryAppIconSize, height: recentEntryAppIconSize)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5))
                    Text(recentEntryAppName(for: bundleID))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(RetraceMenuStyle.textColorMuted)
                        .lineLimit(1)
                }
            } else {
                HStack(spacing: -4) {
                    ForEach(Array(bundleIDs.prefix(8)), id: \.self) { bundleID in
                        AppIconView(bundleID: bundleID, size: recentEntryAppIconSize)
                            .frame(width: recentEntryAppIconSize, height: recentEntryAppIconSize)
                            .clipShape(RoundedRectangle(cornerRadius: 3.5))
                    }
                }
            }
        }
    }

    private func recentEntryAppName(for bundleID: String) -> String {
        if let appName = recentEntryAppNamesByBundleID[bundleID] {
            return appName
        }
        let fallback = bundleID
            .split(separator: ".")
            .last
            .map(String.init) ?? bundleID
        return fallback
    }

    private func recentEntryMetadataToken(icon: String, text: String, tint: Color = RetraceMenuStyle.textColorMuted) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint)
                .lineLimit(1)
        }
    }

    private func recentEntryTagBadge(_ tag: Tag) -> some View {
        let tint = TagColorStore.color(for: tag)
        return HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(tag.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint.opacity(0.95))
                .lineLimit(1)
        }
    }

    private func recentEntryTags(for filters: SearchViewModel.RecentSearchFilters) -> [Tag] {
        return filters.tagIDs.map { tagID in
            recentEntryTagByID[tagID] ?? Tag(id: TagID(value: tagID), name: "#\(tagID)")
        }
    }

    private func hasRecentEntryFilterMetadata(_ filters: SearchViewModel.RecentSearchFilters) -> Bool {
        let dateRanges = filters.effectiveDateRanges
        return !filters.appBundleIDs.isEmpty ||
        !filters.tagIDs.isEmpty ||
        filters.hiddenFilter != .hide ||
        filters.commentFilter != .allFrames ||
        !dateRanges.isEmpty ||
        !filters.windowNameTerms.isEmpty ||
        !filters.browserUrlTerms.isEmpty ||
        !filters.excludedQueryTerms.isEmpty
    }

    private func recentEntryDateLabel(for filters: SearchViewModel.RecentSearchFilters) -> String? {
        let dateRanges = filters.effectiveDateRanges
        if dateRanges.count > 1 {
            return "\(dateRanges.count) date ranges"
        }
        if let startDate = dateRanges.first?.start, let endDate = dateRanges.first?.end {
            return "\(Self.recentEntryShortDateFormatter.string(from: startDate)) - \(Self.recentEntryShortDateFormatter.string(from: endDate))"
        }
        if let startDate = dateRanges.first?.start {
            return "From \(Self.recentEntryShortDateFormatter.string(from: startDate))"
        }
        if let endDate = dateRanges.first?.end {
            return "Until \(Self.recentEntryShortDateFormatter.string(from: endDate))"
        }
        return nil
    }

    private func visibilityIcon(for filter: HiddenFilter) -> String {
        switch filter {
        case .hide:
            return "eye"
        case .onlyHidden:
            return "eye.slash"
        case .showAll:
            return "eye.circle"
        }
    }

    private func visibilityLabel(for filter: HiddenFilter) -> String {
        switch filter {
        case .hide:
            return "Visible"
        case .onlyHidden:
            return "Hidden"
        case .showAll:
            return "All"
        }
    }

    private func commentIcon(for filter: CommentFilter) -> String {
        switch filter {
        case .allFrames:
            return "text.bubble"
        case .commentsOnly:
            return "text.bubble.fill"
        case .noComments:
            return "text.bubble.slash"
        }
    }

    private func commentLabel(for filter: CommentFilter) -> String {
        switch filter {
        case .allFrames:
            return "All"
        case .commentsOnly:
            return "Comments"
        case .noComments:
            return "No Comments"
        }
    }

    // MARK: - Results Area

    private var hasResults: Bool {
        !viewModel.searchQuery.isEmpty && (viewModel.isSearching || viewModel.results != nil || resultsHeight > 0)
    }

    private var reservedResultsHeight: CGFloat {
        max(minResultsHeight, resultsHeight)
    }

    private func reserveExpandedResultsHeight() {
        guard resultsHeight < maxResultsHeight - 1 else { return }
        resultsHeight = maxResultsHeight
    }

    /// Records first-frame overlay open latency once per presentation.
    /// Uses next runloop turn so timing includes view construction/layout cost.
    private func scheduleOpenLatencyMeasurement() {
        DispatchQueue.main.async {
            guard !didRecordOpenLatency, let startTime = overlayOpenStartTime else { return }
            didRecordOpenLatency = true
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            Log.recordLatency(
                "search.overlay.open.first_frame_ms",
                valueMs: elapsedMs,
                category: .ui,
                summaryEvery: 5,
                warningThresholdMs: 120,
                criticalThresholdMs: 300
            )
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        if let message = viewModel.error {
            HStack {
                Text(message).font(.caption).foregroundColor(.orange)
                Button("Refresh search") { viewModel.rerunSearchImmediately(trigger: "evidence.refresh") }
            }.padding(12)
        }
        if viewModel.isSearching && viewModel.results == nil {
            searchingView
                .frame(height: reservedResultsHeight)
        } else if viewModel.results != nil {
            if viewModel.visibleResults.isEmpty {
                noResultsView
                    .frame(height: reservedResultsHeight)
            } else {
                resultsList(viewModel.visibleResults)
            }
        }
    }

    // MARK: - Results List

    private func resultsList(_ visibleResults: [SearchResult]) -> some View {
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(Array(visibleResults.enumerated()), id: \.element.sourceQualifiedID) { index, result in
                        GalleryResultCard(
                            result: result,
                            thumbnailKey: thumbnailKey(for: result),
                            thumbnailSize: thumbnailSize,
                            thumbnailLoader: thumbnailLoader,
                            coordinator: coordinator,
                            index: index,
                            isKeyboardSelected: isResultKeyboardNavigationActive && keyboardSelectedResultIndex == index,
                            onSelect: {
                                // Save scroll position before selecting result
                                viewModel.savedScrollPosition = CGFloat(index)
                                keyboardSelectedResultIndex = index
                                isResultKeyboardNavigationActive = true
                                selectResult(result)
                            },
                            viewModel: viewModel
                        )
                        .onAppear {
                            loadAppIcon(for: result)

                            // Infinite scroll: load more when near the end
                            if index >= visibleResults.count - 3 && viewModel.canLoadMore {
                                Task {
                                    await viewModel.loadMore()
                                }
                            }
                        }
                    }
                }
                .onAppear {
                    Log.info(
                        "\(searchLog) Results grid appear: generation=\(viewModel.searchGeneration), filteredCount=\(visibleResults.count), totalCount=\(viewModel.results?.results.count ?? 0), query='\(viewModel.searchQuery)', committed='\(viewModel.committedSearchQuery)'",
                        category: .ui
                    )
                }
                .onDisappear {
                    Log.info(
                        "\(searchLog) Results grid disappear: generation=\(viewModel.searchGeneration), query='\(viewModel.searchQuery)', committed='\(viewModel.committedSearchQuery)'",
                        category: .ui
                    )
                }
                .padding(16)

                // Loading more indicator
                if viewModel.isLoadingMore {
                    HStack {
                        Spacer()
                        SpinnerView(size: 16, lineWidth: 2, color: .white)
                        Text("Loading more...")
                            .font(.retraceCaption2)
                            .foregroundColor(.white.opacity(0.5))
                        Spacer()
                    }
                    .padding(.vertical, 16)
                }
            }
            .scrollContentBackground(.hidden)
            .frame(maxHeight: maxResultsHeight)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ResultsAreaHeightPreferenceKey.self,
                        value: geo.size.height
                    )
                }
            )
            .onAppear {
                // Restore scroll position when overlay appears
                if viewModel.savedScrollPosition > 0 {
                    let targetIndex = Int(viewModel.savedScrollPosition)
                    guard visibleResults.indices.contains(targetIndex) else { return }
                    let targetResultID = visibleResults[targetIndex].sourceQualifiedID
                    // Scroll to the saved position with a slight delay to ensure layout is complete
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(targetResultID, anchor: .center)
                        }
                    }
                }
            }
            .onChange(of: keyboardSelectedResultIndex) { selectedIndex in
                guard let selectedIndex else { return }
                guard visibleResults.indices.contains(selectedIndex) else { return }
                let selectedResultID = visibleResults[selectedIndex].sourceQualifiedID
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(selectedResultID, anchor: .center)
                }
            }
        }
    }

    // MARK: - Empty States

    private var searchingView: some View {
        VStack(spacing: 12) {
            SpinnerView(size: 28, lineWidth: 3, color: .white)

            Text("Searching...")
                .font(.retraceCallout)
                .foregroundColor(.white.opacity(0.5))

            // Show slow query alert when filtering by app with "All" mode
            if viewModel.selectedAppFilters != nil && !viewModel.selectedAppFilters!.isEmpty && viewModel.searchMode == .all {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.retraceCaption2)
                    Text("\"All\" queries with app filters are slower")
                        .font(.retraceCaption2)
                }
                .foregroundColor(.yellow.opacity(0.8))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.yellow.opacity(0.15))
                )
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.retraceDisplay2)
                .foregroundColor(.white.opacity(0.3))

            Text(viewModel.hasActiveFilters ? "No results match this query with current filters" : "No results found")
                .font(.retraceBodyMedium)
                .foregroundColor(.white.opacity(0.6))

            Text(viewModel.hasActiveFilters ? "Try broadening filters or changing your query" : "Try a different search term")
                .font(.retraceCaption)
                .foregroundColor(.white.opacity(0.4))

            if viewModel.hasActiveFilters {
                noResultsActionButton(title: "Clear Filters") {
                    viewModel.clearAllFilters()
                    viewModel.rerunSearchImmediately(trigger: "no-results.clear-filters")
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noResultsActionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Thumbnail Loading

    private func thumbnailKey(for result: SearchResult) -> String {
        // Use committedSearchQuery (set on Enter) instead of live searchQuery
        // This prevents thumbnails from reloading while user is typing
        "\(result.sourceQualifiedID)_\(result.evidenceRef?.extractionRevision ?? -1)_\(viewModel.searchGeneration)_\(viewModel.committedSearchQuery)"
    }

    // MARK: - App Icon Loading

    private func loadAppIcon(for result: SearchResult) {
        guard let bundleID = result.appBundleID else { return }
        guard viewModel.appIconCache[bundleID] == nil else { return }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 20, height: 20)
            viewModel.appIconCache[bundleID] = icon
        }
    }

    // MARK: - Actions

    private func selectResult(_ result: SearchResult) {
        let query = viewModel.searchQuery
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        df.timeZone = .current
        Log.info("\(searchLog) Result selected: query='\(query)', frameID=\(result.frameID.stringValue), timestamp=\(df.string(from: result.timestamp)) (epoch: \(result.timestamp.timeIntervalSince1970)), segmentID=\(result.segmentID.stringValue), app=\(result.appName ?? "unknown")", category: .ui)

        // Dismiss overlay WITHOUT clearing search state - user selected a result
        dismissOverlayPreservingSearch()

        // Small delay to allow dismiss animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onResultSelected(result, query)
        }
    }

    /// Dismisses the overlay without clearing search state (used when selecting a result)
    private func dismissOverlayPreservingSearch() {
        dismissOverlay(clearSearchState: false)
    }

    /// Dismisses the overlay and clears search state (used for explicit dismissal like Escape key)
    private func dismissOverlay() {
        dismissOverlay(clearSearchState: true)
    }

    private func collapseToCompactSearchBar(clearFilters: Bool) {
        guard isExpanded else { return }

        clearResultKeyboardNavigation()
        isRecentEntriesPopoverVisible = false
        highlightedRecentEntryIndex = 0
        hoveredRecentEntryKey = nil

        if clearFilters {
            viewModel.clearAllFilters()
            viewModel.resetSearchOrderToDefault()
        }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isExpanded = false
        }

        refocusSearchField = UUID()
        refreshRecentEntriesPopoverVisibility()
    }

    private func handleSearchEscape() {
        if isRecentEntriesPopoverVisible {
            withAnimation(.easeOut(duration: 0.15)) {
                isRecentEntriesPopoverVisible = false
            }
            highlightedRecentEntryIndex = 0
            hoveredRecentEntryKey = nil
            return
        }

        // If a dropdown is open, close it instead of collapsing/dismissing.
        if viewModel.isDropdownOpen {
            viewModel.closeDropdownsSignal += 1
            return
        }

        // Expanded overlay with no submitted search should collapse back to compact mode.
        if isExpanded && !viewModel.shouldDismissExpandedOverlayOnEscape {
            collapseToCompactSearchBar(clearFilters: true)
            return
        }

        dismissOverlay()
    }

    private func dismissOverlay(clearSearchState: Bool) {
        guard !isDismissing else { return }
        isDismissing = true

        // Cancel any in-flight search tasks to prevent blocking while the overlay fades out.
        viewModel.cancelSearch()
        clearResultKeyboardNavigation()
        isRecentEntriesPopoverVisible = false
        highlightedRecentEntryIndex = 0
        hoveredRecentEntryKey = nil
        rankedRecentEntries = []

        withAnimation(.easeOut(duration: dismissAnimationDuration)) {
            isVisible = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAnimationDuration) {
            // Clear only after fade-out completes so dismiss is visually smooth.
            if clearSearchState {
                viewModel.searchQuery = ""
                viewModel.clearAllFilters()
                viewModel.resetSearchOrderToDefault()
            }
            onDismiss()
            isDismissing = false
        }
    }

    // MARK: - Keyboard Navigation

    private var keyboardNavigableResults: [SearchResult] {
        viewModel.visibleResults
    }

    private func prepareResultKeyboardNavigationAfterSubmit() {
        shouldFocusFirstResultAfterSubmit = true
        isResultKeyboardNavigationActive = true
        keyboardSelectedResultIndex = nil
        isRecentEntriesPopoverVisible = false
        resignSearchFieldFocus()
    }

    private func focusFirstResultIfAvailable() {
        let results = keyboardNavigableResults
        shouldFocusFirstResultAfterSubmit = false

        guard !results.isEmpty else {
            clearResultKeyboardNavigation()
            return
        }

        isResultKeyboardNavigationActive = true
        keyboardSelectedResultIndex = 0
        resignSearchFieldFocus()
    }

    private func syncKeyboardSelectionWithCurrentResults() {
        let results = keyboardNavigableResults

        if shouldFocusFirstResultAfterSubmit {
            focusFirstResultIfAvailable()
            return
        }

        guard isResultKeyboardNavigationActive else { return }
        guard !results.isEmpty else {
            clearResultKeyboardNavigation()
            return
        }

        if let index = keyboardSelectedResultIndex {
            keyboardSelectedResultIndex = min(index, results.count - 1)
        } else {
            keyboardSelectedResultIndex = 0
        }
    }

    private func clearResultKeyboardNavigation() {
        shouldFocusFirstResultAfterSubmit = false
        isResultKeyboardNavigationActive = false
        keyboardSelectedResultIndex = nil
        refreshRecentEntriesPopoverVisibility()
    }

    private func resignSearchFieldFocus() {
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func installKeyEventMonitor() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isResultKeyboardNavigationActive,
                  !viewModel.isDropdownOpen,
                  !viewModel.isDatePopoverHandlingKeys else {
                return event
            }

            let results = keyboardNavigableResults
            guard !results.isEmpty else {
                return event
            }

            switch event.keyCode {
            case 123: // left
                moveSelection(in: results, offset: -1)
                return nil
            case 124: // right
                moveSelection(in: results, offset: 1)
                return nil
            case 125: // down
                moveSelection(in: results, offset: gridColumns.count)
                return nil
            case 126: // up
                moveSelection(in: results, offset: -gridColumns.count)
                return nil
            case 36, 76: // return / enter
                let selectedIndex = min(keyboardSelectedResultIndex ?? 0, results.count - 1)
                keyboardSelectedResultIndex = selectedIndex
                viewModel.savedScrollPosition = CGFloat(selectedIndex)
                selectResult(results[selectedIndex])
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyEventMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    private func moveSelection(in results: [SearchResult], offset: Int) {
        guard !results.isEmpty else { return }
        let currentIndex = keyboardSelectedResultIndex ?? 0
        let nextIndex = max(0, min(results.count - 1, currentIndex + offset))
        keyboardSelectedResultIndex = nextIndex
    }
}

// MARK: - Gallery Result Card

private struct GalleryResultCard: View {
    let result: SearchResult
    let thumbnailKey: String
    let thumbnailSize: CGSize
    let thumbnailLoader: SearchEvidenceThumbnailLoader
    let coordinator: AppCoordinator
    let index: Int
    let isKeyboardSelected: Bool
    let onSelect: () -> Void
    @ObservedObject var viewModel: SearchViewModel

    @State private var isHovered = false
    @StateObject private var thumbnailPreview = SearchEvidenceThumbnailPreview()

    private var appIcon: NSImage? {
        viewModel.appIconCache[result.appBundleID ?? ""]
    }

    /// Display title: window name (c2) if available, otherwise app name
    private var displayTitle: String {
        if let windowName = result.windowName, !windowName.isEmpty {
            return windowName
        }
        return result.appName ?? "Unknown"
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                // A verified full-image preview; exact evidence owns immutable OCR highlighting.
                thumbnailView

                // Title bar with app icon
                HStack(spacing: 8) {
                    // App icon
                    if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 30, height: 30)
                    } else {
                        Circle()
                            .fill(Color.segmentColor(for: result.appBundleID ?? ""))
                            .frame(width: 30, height: 30)
                    }

                    // Title and timestamp
                    VStack(alignment: .leading, spacing: 2) {
                        // Title with source badge
                        HStack(spacing: 6) {
                            Text(displayTitle)
                                .font(.retraceCaption2Medium)
                                .foregroundColor(.white)
                                .lineLimit(1)

                            // Source badge
                            Text(result.source == .native ? "Retrace" : "Rewind")
                                .font(.retraceTinyBold)
                                .foregroundColor(result.source == .native ? RetraceMenuStyle.actionBlue : .purple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(result.source == .native ? RetraceMenuStyle.actionBlue.opacity(0.2) : Color.purple.opacity(0.2))
                                .cornerRadius(3)
                        }

                        // Timestamp and relevance
                        HStack(spacing: 6) {
                            Text(formatTimestamp(result.timestamp))
                                .font(.retraceTiny)
                                .foregroundColor(.white.opacity(0.5))

                            Text("•")
                                .font(.retraceTiny)
                                .foregroundColor(.white.opacity(0.3))

                            Text(String(format: "relevance: %.0f%%", result.relevanceScore * 100))
                                .font(.retraceMonoSmall)
                                .foregroundColor(.yellow.opacity(0.7))
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.3))
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovered ? Color.white.opacity(0.3) : Color.white.opacity(0.1), lineWidth: isHovered ? 2 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.retraceAccent, lineWidth: 2)
                    .opacity(isKeyboardSelected ? 1 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(isHovered ? 0.4 : 0.2), radius: isHovered ? 8 : 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .animation(.easeOut(duration: 0.2).delay(Double(index) * 0.03), value: true)
        .task(id: thumbnailKey) {
            await thumbnailPreview.show(result, key: thumbnailKey, loader: thumbnailLoader, size: thumbnailSize,
                service: { try await coordinator.progressiveRecall() })
        }
        .onDisappear { thumbnailPreview.hide() }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            Color.black

            if let thumbnail = thumbnailPreview.image(for: thumbnailKey) {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                    .clipped()
            } else if thumbnailPreview.isUnavailable(for: thumbnailKey) {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text("Preview unavailable")
                        .font(.retraceCaption2)
                }
                .foregroundColor(.white.opacity(0.5))
            } else {
                SpinnerView(size: 16, lineWidth: 2, color: .white.opacity(0.4))
            }
        }
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy HH:mm"
        return formatter.string(from: date)
    }
}

private struct ResultsAreaHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Spotlight Search Field

/// NSViewRepresentable text field for the spotlight search overlay
/// Uses manual makeFirstResponder for reliable focus in borderless windows
struct SpotlightSearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onEscape: () -> Void
    var onTab: (() -> Void)? = nil
    var onBackTab: (() -> Void)? = nil
    var onFocus: (() -> Void)? = nil
    var onBlur: (() -> Void)? = nil
    var onArrowDown: (() -> Bool)? = nil
    var onArrowUp: (() -> Bool)? = nil
    var placeholder: String = "Search anything you have seen..."
    var refocusTrigger: UUID = UUID()  // Change this to trigger refocus

    func makeNSView(context: Context) -> FocusableTextField {
        let textField = FocusableTextField()
        textField.placeholderString = placeholder
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.35),
                .font: NSFont.systemFont(ofSize: 17, weight: .medium)
            ]
        )
        textField.font = .systemFont(ofSize: 17, weight: .medium)
        textField.textColor = .white
        textField.backgroundColor = .clear
        textField.isBordered = false
        textField.focusRingType = .none
        textField.alignment = .left
        textField.delegate = context.coordinator
        textField.drawsBackground = false
        textField.cell?.isScrollable = true
        textField.cell?.wraps = false
        textField.cell?.usesSingleLineMode = true
        textField.isEditable = true
        textField.isSelectable = true

        textField.onCancelCallback = onEscape
        textField.onClickCallback = {
            self.onFocus?()
        }

        // Focus the text field with retry logic for external monitors
        Log.info("\(searchLog)[FieldFocus] makeNSView scheduling initial focus", category: .ui)
        focusTextField(textField, attempt: 1)

        return textField
    }

    func updateNSView(_ textField: FocusableTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
        // Update the click callback in case onFocus changed
        textField.onClickCallback = {
            self.onFocus?()
        }
        // Check if refocus was triggered
        if context.coordinator.lastRefocusTrigger != refocusTrigger {
            context.coordinator.lastRefocusTrigger = refocusTrigger
            focusTextField(textField, attempt: 1)
        }
    }

    private func focusTextField(_ textField: FocusableTextField, attempt: Int) {
        let maxAttempts = 5
        let delay: TimeInterval = attempt == 1 ? 0.0 : Double(attempt) * 0.05

        let schedule = {
            guard let window = textField.window else {
                if attempt < maxAttempts {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.focusTextField(textField, attempt: attempt + 1)
                    }
                }
                return
            }
            self.performFocus(textField, in: window, attempt: attempt)
        }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: schedule)
        } else {
            DispatchQueue.main.async(execute: schedule)
        }
    }

    private func performFocus(_ textField: FocusableTextField, in window: NSWindow, attempt: Int) {
        let maxAttempts = 5

        // Activate the app first — required for makeKey to work on external monitors
        // where NSApp.isActive may be false when the overlay opens
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        let isKeyAfterMakeKey = window.isKeyWindow
        let success = window.makeFirstResponder(textField)
        Log.info(
            "\(searchLog)[FieldFocus] performFocus attempt=\(attempt) isKeyAfterMakeKey=\(isKeyAfterMakeKey) makeFirstResponderSuccess=\(success)",
            category: .ui
        )

        // Ensure field editor exists for caret to appear
        if window.fieldEditor(false, for: textField) == nil {
            _ = window.fieldEditor(true, for: textField)
        }

        // Move caret to end of text instead of selecting all
        if let fieldEditor = window.fieldEditor(false, for: textField) as? NSTextView {
            let endPosition = fieldEditor.string.count
            fieldEditor.setSelectedRange(NSRange(location: endPosition, length: 0))
        }

        // If the window isn't key yet (activation is async on external monitors),
        // retry so keystrokes actually reach the text field
        if !isKeyAfterMakeKey && attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.focusTextField(textField, attempt: attempt + 1)
            }
        } else if !success && attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.focusTextField(textField, attempt: attempt + 1)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onEscape: onEscape,
            onTab: onTab,
            onBackTab: onBackTab,
            onFocus: onFocus,
            onBlur: onBlur,
            onArrowDown: onArrowDown,
            onArrowUp: onArrowUp
        )
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        let onSubmit: () -> Void
        let onEscape: () -> Void
        let onTab: (() -> Void)?
        let onBackTab: (() -> Void)?
        let onFocus: (() -> Void)?
        let onBlur: (() -> Void)?
        let onArrowDown: (() -> Bool)?
        let onArrowUp: (() -> Bool)?
        var lastRefocusTrigger: UUID = UUID()

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onEscape: @escaping () -> Void,
            onTab: (() -> Void)?,
            onBackTab: (() -> Void)?,
            onFocus: (() -> Void)?,
            onBlur: (() -> Void)?,
            onArrowDown: (() -> Bool)?,
            onArrowUp: (() -> Bool)?
        ) {
            self._text = text
            self.onSubmit = onSubmit
            self.onEscape = onEscape
            self.onTab = onTab
            self.onBackTab = onBackTab
            self.onFocus = onFocus
            self.onBlur = onBlur
            self.onArrowDown = onArrowDown
            self.onArrowUp = onArrowUp
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            onFocus?()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            onBlur?()
        }

        func controlTextDidChange(_ notification: Notification) {
            if let textField = notification.object as? NSTextField {
                text = textField.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onEscape()
                return true
            } else if commandSelector == #selector(NSResponder.insertTab(_:)) {
                onTab?()
                return true
            } else if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                onBackTab?()
                return true
            } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
                return onArrowDown?() ?? false
            } else if commandSelector == #selector(NSResponder.moveUp(_:)) {
                return onArrowUp?() ?? false
            }
            return false
        }
    }
}

// MARK: - Preview

#if DEBUG
struct SpotlightSearchOverlay_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()
        SpotlightSearchOverlay(
            coordinator: coordinator,
            viewModel: SearchViewModel(coordinator: coordinator),
            onResultSelected: { _, _ in },
            onDismiss: {}
        )
        .frame(width: 800, height: 600)
        .background(Color.gray.opacity(0.3))
        .preferredColorScheme(.dark)
    }
}
#endif
