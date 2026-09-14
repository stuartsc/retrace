import SwiftUI
import AppKit
import ImageIO
import Shared
import App
import Database

// MARK: - Layout Size

/// Fixed layout size for dashboard stat cards
/// Content stays at a consistent size and centers in the window
private enum LayoutSize {
    case normal

    static func from(width: CGFloat) -> LayoutSize {
        return .normal
    }

    // MARK: - Card Dimensions

    var cardWidth: CGFloat { 280 }
    var graphHeight: CGFloat { 70 }

    // MARK: - Icon Sizes

    var iconCircleSize: CGFloat { 44 }
    var iconFont: Font { .retraceHeadline }

    // MARK: - Text Fonts

    var titleFont: Font { .retraceCaption2Medium }
    var valueFont: Font { .retraceMediumNumber }
    var subtitleFont: Font { .retraceCaption2Medium }

    // MARK: - Spacing & Padding

    var iconSpacing: CGFloat { 14 }
    var textSpacing: CGFloat { 2 }
    var cardPadding: CGFloat { 16 }
    var graphHorizontalPadding: CGFloat { 12 }
    var graphBottomPadding: CGFloat { 8 }
}

/// Maximum width for the dashboard content area before it centers
private let dashboardMaxWidth = DashboardVoiceLayoutPolicy.defaultContentWidth
/// Shared breakpoint for compact dashboard-style layouts.
let dashboardCompactLayoutThreshold: CGFloat = 850

private struct RecordingIndicatorAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct DashboardLiveDerivedPresentation: Equatable, Sendable {
    let activityBrief: RetraceActivityBrief
    let fuseIntel: FuseIntelPresentationSnapshot
}

/// Main dashboard view - analytics and statistics
/// Default landing screen
public struct DashboardView: View {

    // MARK: - Properties

    @ObservedObject var viewModel: DashboardViewModel
    @StateObject private var coordinatorWrapper: AppCoordinatorWrapper
    @StateObject private var fuseIntelViewModel: FuseIntelViewModel
    @ObservedObject var launchOnLoginReminderManager: LaunchOnLoginReminderManager
    @ObservedObject private var updaterManager = UpdaterManager.shared
    @State private var isPulsing = false
    @State private var usageViewMode: AppUsageViewMode = Self.loadSavedViewMode()
    @State private var selectedApp: AppUsageData? = nil
    @State private var selectedWindow: WindowUsageData? = nil
    @State private var showSessionsSheet = false
    @State private var showSystemMonitor = false
    @State private var currentTheme: MilestoneCelebrationManager.ColorTheme = MilestoneCelebrationManager.getCurrentTheme()
    @State private var selectedDashboardTab: DashboardContentTab = .defaultTab
    @State private var dictationConfig: DictationConfig = .default
    @State private var recentDictationSessions: [DictationSession] = []
    @State private var dictationDashboardError: String?
    @State private var isLoadingDictationSessions = false
    @State private var isLoadingMoreDictationSessions = false
    @State private var canLoadMoreDictationSessions = true
    @State private var expandedDictationSessionIDs: Set<UUID> = []
    @State private var liveAudioRawRows: [DashboardLiveAudioRow] = []
    @State private var liveAudioRows: [DashboardLiveAudioRow] = []
    @State private var liveAudioStatusRows: [DashboardLiveAudioRow] = []
    @State private var liveAudioTranscriptBlocks: [DashboardLiveTranscriptBlock] = []
    @State private var liveAudioError: String?
    @State private var isLoadingLiveAudio = false
    @State private var isLoadingMoreLiveAudio = false
    @State private var canLoadMoreLiveAudioRows = true
    @State private var liveAudioTranscriptOffset = 0
    @State private var lastAutoLoadedLiveAudioBoundaryRowID: Int64?
    @State private var lastAutoLoadedLiveAudioOffset: Int?
    @State private var expandedLiveAudioRowIDs: Set<Int64> = []
    @State private var liveFrames: [FrameWithVideoInfo] = []
    @State private var liveFrameError: String?
    @State private var isLoadingLiveFrames = false
    @State private var isLoadingMoreLiveFrames = false
    @State private var canLoadMoreLiveFrames = true
    @State private var lastAutoLoadedLiveFrameBoundaryID: Int64?
    @State private var selectedLiveFrameID: Int64?
    @State private var selectedLiveFrameRefresher = DashboardSelectedFrameRefresher()
    @State private var liveFrameThumbnails: [Int64: NSImage] = [:]
    @State private var liveFrameThumbnailLoadingIDs: Set<Int64> = []
    @State private var liveFrameThumbnailFailureCounts: [Int64: Int] = [:]
    @State private var liveFrameOCRNodes: [Int64: [OCRNodeWithText]] = [:]
    @State private var liveFrameOCRLoadingIDs: Set<Int64> = []
    @State private var liveFrameOCRLoadedStatuses: [Int64: Int] = [:]
    @State private var liveFrameAppNamesByBundleID: [String: String] = [:]
    @State private var screenshotSearchText = ""
    @State private var selectedLiveFramePreview: NSImage?
    @State private var selectedLiveFramePreviewID: Int64?
    @State private var isLoadingSelectedLiveFramePreview = false
    @State private var selectedLiveFramePreviewLoadingID: Int64?
    @State private var selectedLiveFramePreviewError: String?
    @State private var liveFramePreviewFailureCounts: [Int64: Int] = [:]
    @State private var recentActivityFrames: [FrameWithVideoInfo] = []
    @State private var latestLiveContextFrame: FrameWithVideoInfo?
    @State private var liveActivityBriefSnapshot = RetraceActivityBriefPolicy.make(moments: [], speech: [])
    @State private var liveFuseIntelPresentationSnapshot = FuseIntelPresentationSnapshot.empty
    @State private var liveDerivedPresentationGeneration = 0
    @State private var selectedFuseIntelSection: FuseIntelSection = .now
    @State private var expandedFuseIntelItemIDs: Set<String> = []
    @Binding var hasLoadedInitialData: Bool

    enum AppUsageViewMode: String, CaseIterable {
        case list = "list"
        case hardDrive = "squares"

        var icon: String {
            switch self {
            case .list: return "list.bullet"
            case .hardDrive: return "square.grid.2x2"
            }
        }
    }

    private static let viewModeDefaultsKey = "dashboardAppUsageViewMode"
    private static let pauseMenuWidth: CGFloat = 100
    private static let transcriptPageSize = 20

    private static func loadSavedViewMode() -> AppUsageViewMode {
        guard let raw = UserDefaults.standard.string(forKey: viewModeDefaultsKey),
              let mode = AppUsageViewMode(rawValue: raw) else {
            return .list
        }
        return mode
    }

    private func saveViewMode(_ mode: AppUsageViewMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: Self.viewModeDefaultsKey)
    }

    // MARK: - Initialization

    public init(
        viewModel: DashboardViewModel,
        coordinator: AppCoordinator,
        launchOnLoginReminderManager: LaunchOnLoginReminderManager,
        hasLoadedInitialData: Binding<Bool> = .constant(false)
    ) {
        self.viewModel = viewModel
        _coordinatorWrapper = StateObject(wrappedValue: AppCoordinatorWrapper(coordinator: coordinator))
        _fuseIntelViewModel = StateObject(wrappedValue: FuseIntelViewModel())
        self.launchOnLoginReminderManager = launchOnLoginReminderManager
        self._hasLoadedInitialData = hasLoadedInitialData
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Accessibility permission warning banner
            if viewModel.showAccessibilityWarning {
                PermissionBanner(
                    message: "Retrace needs Accessibility permission to detect display changes and exclude private/incognito windows and excluded apps.",
                    actionTitle: "Open Settings",
                    action: {
                        SystemSettingsOpener.openAccessibilitySettings()
                    },
                    onDismiss: {
                        viewModel.dismissAccessibilityWarning()
                    }
                )
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
            }

            // Screen recording permission warning banner
            if viewModel.showScreenRecordingWarning {
                PermissionBanner(
                    message: "Retrace needs Screen Recording permission to capture your screen.",
                    actionTitle: "Open Settings",
                    action: {
                        SystemSettingsOpener.openScreenRecordingSettings()
                    },
                    onDismiss: {
                        viewModel.dismissScreenRecordingWarning()
                    }
                )
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.top, viewModel.showAccessibilityWarning ? 12 : 20)
            }

            // Launch on login reminder banner
            if launchOnLoginReminderManager.shouldShowReminder {
                PermissionBanner(
                    message: "Retrace works best when it launches automatically on login so you never miss a moment.",
                    actionTitle: "Launch on Login",
                    action: {
                        launchOnLoginReminderManager.enableLaunchAtLogin()
                    },
                    onDismiss: {
                        launchOnLoginReminderManager.dismissReminder()
                    }
                )
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.top, (viewModel.showAccessibilityWarning || viewModel.showScreenRecordingWarning) ? 12 : 20)
            }

            // Header
            header
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 32)

            // Voice-first content layout with compact stats strip.
            GeometryReader { geometry in
                let layoutSize = LayoutSize.from(width: geometry.size.width)

                VStack(spacing: 14) {
                    dashboardContentSection(layoutSize: layoutSize)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    dashboardStatsStrip(layoutSize: layoutSize)
                }
                .frame(maxWidth: dashboardMaxWidth)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .background(
            ZStack {
                // Theme-aware base background color
                themeBaseBackground

                // Theme-aware ambient glow background
                themeAmbientBackground
            }
            .ignoresSafeArea()
        )
        .background(
            Button("") {
                Task { await viewModel.loadStatistics() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
        )
        .task {
            viewModel.isWindowVisible = true
            if !hasLoadedInitialData {
                hasLoadedInitialData = true
                Log.debug("[Dashboard] Initial load - first appearance", category: .ui)
                await viewModel.loadStatistics()
                DashboardViewModel.recordDashboardDefaultOpened(
                    coordinator: coordinatorWrapper.coordinator,
                    tab: selectedDashboardTab.rawValue
                )
            } else {
                Log.debug("[Dashboard] Tab switch - skipping reload", category: .ui)
            }
        }
        .task(id: "\(selectedDashboardTab.rawValue):\(viewModel.isWindowVisible)") {
            guard viewModel.isWindowVisible else { return }
            switch selectedDashboardTab {
            case .dictation:
                switch DashboardTabEntryLoadPolicy.action(hasLoadedItems: !recentDictationSessions.isEmpty) {
                case .initialLoad:
                    await loadDictationDashboardData(reset: true)
                case .refresh:
                    await refreshDictationDashboardData()
                }
            case .live:
                async let contextRefresh: Void = refreshLatestLiveContextFrame()
                async let intelRefresh: Void = fuseIntelViewModel.refresh()
                switch DashboardTabEntryLoadPolicy.action(hasLoadedItems: !liveAudioRows.isEmpty) {
                case .initialLoad:
                    await loadLiveAudioDashboardData(reset: true)
                case .refresh:
                    await refreshLiveAudioDashboardData()
                }
                _ = await (contextRefresh, intelRefresh)
                await refreshLiveDerivedPresentation()
                while !Task.isCancelled && DashboardRefreshLoopPolicy.shouldContinue(
                    loopTab: .live,
                    selectedTab: selectedDashboardTab,
                    isWindowVisible: viewModel.isWindowVisible
                ) {
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    guard DashboardRefreshLoopPolicy.shouldContinue(
                        loopTab: .live,
                        selectedTab: selectedDashboardTab,
                        isWindowVisible: viewModel.isWindowVisible
                    ) else { return }
                    async let audioRefresh: Void = refreshLiveAudioDashboardData()
                    async let frameRefresh: Void = refreshLatestLiveContextFrame()
                    async let fuseIntelRefresh: Void = fuseIntelViewModel.refresh()
                    _ = await (audioRefresh, frameRefresh, fuseIntelRefresh)
                    await refreshLiveDerivedPresentation()
                }
            case .screenshots:
                switch DashboardTabEntryLoadPolicy.action(hasLoadedItems: !liveFrames.isEmpty) {
                case .initialLoad:
                    await loadLiveFramesDashboardData(reset: true)
                case .refresh:
                    await refreshLiveFramesDashboardData()
                }
                while !Task.isCancelled && DashboardRefreshLoopPolicy.shouldContinue(
                    loopTab: .screenshots,
                    selectedTab: selectedDashboardTab,
                    isWindowVisible: viewModel.isWindowVisible
                ) {
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    guard DashboardRefreshLoopPolicy.shouldContinue(
                        loopTab: .screenshots,
                        selectedTab: selectedDashboardTab,
                        isWindowVisible: viewModel.isWindowVisible
                    ) else { return }
                    await refreshLiveFramesDashboardData()
                }
            case .appUsage:
                return
            }

            while !Task.isCancelled && DashboardRefreshLoopPolicy.shouldContinue(
                loopTab: .dictation,
                selectedTab: selectedDashboardTab,
                isWindowVisible: viewModel.isWindowVisible
            ) {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                guard DashboardRefreshLoopPolicy.shouldContinue(
                    loopTab: .dictation,
                    selectedTab: selectedDashboardTab,
                    isWindowVisible: viewModel.isWindowVisible
                ) else { return }
                await refreshDictationDashboardData()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardDidBecomeKey)) { _ in
            Log.debug("[Dashboard] Window became key - refreshing", category: .ui)
            Task {
                await viewModel.loadStatistics()
                if selectedDashboardTab == .dictation {
                    await refreshDictationDashboardData()
                } else if selectedDashboardTab == .live {
                    async let audioRefresh: Void = refreshLiveAudioDashboardData()
                    async let frameRefresh: Void = refreshLatestLiveContextFrame()
                    async let intelRefresh: Void = fuseIntelViewModel.refresh()
                    _ = await (audioRefresh, frameRefresh, intelRefresh)
                    await refreshLiveDerivedPresentation()
                } else if selectedDashboardTab == .screenshots {
                    await refreshLiveFramesDashboardData()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardDidOpen)) { _ in
            viewModel.isWindowVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardDidClose)) { _ in
            viewModel.isWindowVisible = false
            selectedLiveFrameRefresher.cancel()
        }
        .onChange(of: selectedDashboardTab) { _ in
            selectedLiveFrameRefresher.cancel()
        }
        .onChange(of: viewModel.isWindowVisible) { isVisible in
            if !isVisible { selectedLiveFrameRefresher.cancel() }
        }
        .onDisappear {
            selectedLiveFrameRefresher.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .colorThemeDidChange)) { notification in
            if let newTheme = notification.object as? MilestoneCelebrationManager.ColorTheme {
                currentTheme = newTheme
            }
        }
        .overlayPreferenceValue(RecordingIndicatorAnchorPreferenceKey.self) { anchor in
            GeometryReader { proxy in
                if showPauseOptionsPopover, let anchor {
                    let anchorRect = proxy[anchor]
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.12)) {
                                    showPauseOptionsPopover = false
                                }
                            }

                        pauseRecordingMenu
                            .frame(width: Self.pauseMenuWidth)
                            .offset(
                                x: pauseMenuOriginX(
                                    anchorRect: anchorRect,
                                    containerWidth: proxy.size.width,
                                    menuWidth: Self.pauseMenuWidth
                                ),
                                y: anchorRect.maxY + 6
                            )
                            .transition(
                                .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                            )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .zIndex(showPauseOptionsPopover ? 20 : 0)
        }
        .overlay {
            // Sessions detail overlay (replaces .sheet for faster presentation)
            if showSessionsSheet, let app = selectedApp {
                ZStack {
                    // Dimmed background
                    Color.black.opacity(0.6)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) {
                                showSessionsSheet = false
                            }
                        }

                    // Sessions detail dialog
                    Group {
                        if let window = selectedWindow {
                            // Window-filtered sessions
                            AppSessionsDetailView(
                                app: app,
                                onOpenInTimeline: { date in
                                    showSessionsSheet = false
                                    openTimelineAt(date: date)
                                },
                                loadSessions: { offset, limit in
                                    await viewModel.getSessionsForAppWindow(
                                        bundleID: app.appBundleID,
                                        windowNameOrDomain: window.displayName,
                                        offset: offset,
                                        limit: limit
                                    )
                                },
                                subtitle: window.displayName,
                                onDismiss: {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        showSessionsSheet = false
                                    }
                                }
                            )
                        } else {
                            // All sessions for app
                            AppSessionsDetailView(
                                app: app,
                                onOpenInTimeline: { date in
                                    showSessionsSheet = false
                                    openTimelineAt(date: date)
                                },
                                loadSessions: { offset, limit in
                                    await viewModel.getSessionsForApp(
                                        bundleID: app.appBundleID,
                                        offset: offset,
                                        limit: limit
                                    )
                                },
                                onDismiss: {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        showSessionsSheet = false
                                    }
                                }
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 10)
                    .transition(.scale.combined(with: .opacity))
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showSessionsSheet)
            }
        }
    }

    // MARK: - App Session Actions

    private func handleAppTapped(_ app: AppUsageData) {
        selectedApp = app
        selectedWindow = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showSessionsSheet = true
        }
    }

    private func handleWindowTapped(_ app: AppUsageData, _ window: WindowUsageData) {
        let clickStartTime = CFAbsoluteTimeGetCurrent()

        // Calculate week date range (same as dashboard uses)
        let calendar = Calendar.current
        let now = Date()
        let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
        let weekEnd = now

        // Launch filtered timeline instantly instead of showing sessions dialog
        TimelineWindowController.shared.showWithFilter(
            bundleID: app.appBundleID,
            windowName: window.windowName,
            browserUrl: window.browserUrl,
            startDate: weekStart,
            endDate: weekEnd,
            clickStartTime: clickStartTime
        )
    }

    private func openTimelineAt(date: Date) {
        // Show the timeline and navigate to the specific date
        TimelineWindowController.shared.showAndNavigate(to: date)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                // Retrace logo + Dashboard text
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        LogoTriangle()
                            .fill(Color.white)
                            .frame(width: 14, height: 18)
                            .rotationEffect(.degrees(180))
                        LogoTriangle()
                            .fill(Color.white)
                            .frame(width: 14, height: 18)
                    }

                    Text("Dashboard")
                        .font(.retraceTitle3)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                // Recording status indicator
                recordingIndicator

                // Action buttons
                openTimelineButton
                refreshTranscriptsButton
                monitorButton
                if updaterManager.shouldShowWhatsNew {
                    changelogButton
                }
                settingsButton
            }
        }
    }

    private func actionButton(icon: String, label: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.retraceCalloutMedium)
                if let label = label {
                    Text(label)
                        .font(.retraceCaptionMedium)
                }
            }
            .foregroundColor(.retraceSecondary)
            .padding(.horizontal, label != nil ? 14 : 10)
            .padding(.vertical, label != nil ? 8 : 10)
            .background(Color.white.opacity(0.05))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    // MARK: - Action Button States

    @State private var isHoveringTimeline = false
    @State private var isHoveringSettings = false
    @State private var settingsRotation: Double = 0

    // MARK: - Timeline Button

    private var openTimelineButton: some View {
        Button(action: {
            TimelineWindowController.shared.show()
        }) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.retraceCalloutMedium)
                .foregroundColor(.retraceSecondary)
                .padding(10)
                .background(Color.white.opacity(0.05))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .scaleEffect(isHoveringTimeline ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isHoveringTimeline)
        .compactTopTooltip("Open Timeline", isVisible: $isHoveringTimeline)
        .onHover { hovering in
            isHoveringTimeline = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    // MARK: - Monitor Button

    private var monitorButton: some View {
        MonitorButton(isProcessing: viewModel.ocrQueueDepth > 0)
    }

    // MARK: - Refresh Transcripts Button

    @State private var refreshRotation: Double = 0
    @State private var refreshSpinTask: Task<Void, Never>?

    private var refreshTranscriptsButton: some View {
        Button(action: {
            Task { await coordinatorWrapper.refineNow() }
        }) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.retraceCalloutMedium)
                    .rotationEffect(.degrees(refreshRotation))
                if let message = coordinatorWrapper.lastRefinementMessage {
                    Text(message)
                        .font(.retraceCaption2Medium)
                        .transition(.opacity)
                }
            }
            .foregroundColor(.retraceSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .disabled(coordinatorWrapper.isRefining)
        .help("Refresh transcripts — runs pass-2 and pass-3 refinement on any pending audio")
        .onChange(of: coordinatorWrapper.isRefining) { isRefining in
            refreshSpinTask?.cancel()
            if isRefining {
                // Drive the spin from a loop we can cancel cleanly
                refreshSpinTask = Task { @MainActor in
                    while !Task.isCancelled {
                        withAnimation(.linear(duration: 1.0)) {
                            refreshRotation += 360
                        }
                        try? await Task.sleep(for: .seconds(1), clock: .continuous)
                    }
                }
            } else {
                // Snap back to 0 with a short settle animation
                refreshSpinTask = nil
                withAnimation(.easeOut(duration: 0.2)) {
                    refreshRotation = 0
                }
            }
        }
    }

    // MARK: - Changelog Button

    private var changelogButton: some View {
        actionButton(icon: "sparkles", label: "What's New") {
            NotificationCenter.default.post(
                name: .openDashboard,
                object: nil,
                userInfo: ["target": "changelog"]
            )
        }
    }

    // MARK: - Settings Button

    private var settingsButton: some View {
        Button(action: {
            // Quick spin on click
            withAnimation(.easeInOut(duration: 0.3)) {
                settingsRotation += 90
            }
            NotificationCenter.default.post(name: .openSettings, object: nil)
        }) {
            Image(systemName: "gearshape")
                .font(.retraceCalloutMedium)
                .foregroundColor(.retraceSecondary)
                .rotationEffect(.degrees(settingsRotation + (isHoveringSettings ? 30 : 0)))
                .animation(.easeInOut(duration: 0.2), value: isHoveringSettings)
                .padding(10)
                .background(Color.white.opacity(0.05))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .scaleEffect(isHoveringSettings ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isHoveringSettings)
        .compactTopTooltip("Open Settings", isVisible: $isHoveringSettings)
        .onHover { hovering in
            isHoveringSettings = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    // MARK: - Recording Indicator

    @State private var isHoveringRecordingIndicator = false
    @State private var showPauseOptionsPopover = false

    private var recordingIndicator: some View {
        Button(action: {
            if viewModel.isRecording {
                withAnimation(.easeOut(duration: 0.12)) {
                    showPauseOptionsPopover.toggle()
                }
            } else {
                Task {
                    await viewModel.toggleRecording(to: true)
                }
            }
        }) {
            HStack(spacing: 6) {
                if viewModel.isRecording && isHoveringRecordingIndicator {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.retraceSecondary)
                        .frame(width: 6)
                        .transition(.opacity)
                } else if viewModel.recordingPauseRemainingSeconds != nil {
                    Image(systemName: "timer")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.retraceSecondary)
                        .frame(width: 8)
                        .transition(.opacity)
                } else if viewModel.isRecordingPaused {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.retraceSecondary)
                        .frame(width: 8)
                        .transition(.opacity)
                } else {
                    Circle()
                        .fill(viewModel.isRecording ? Color.retraceDanger : Color.retraceSecondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                        .transition(.opacity)
                }

                Text(recordingIndicatorLabel)
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceSecondary)
                    .contentTransition(.interpolate)
                    .frame(width: 74, alignment: .center)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.05))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isHoveringRecordingIndicator)
        .animation(.easeInOut(duration: 0.15), value: viewModel.isRecording)
        .anchorPreference(key: RecordingIndicatorAnchorPreferenceKey.self, value: .bounds) { $0 }
        // .instantTooltip("Toggle Recording  ⌘⇧R", isVisible: $isHoveringRecordingIndicator)
        .onHover { hovering in
            isHoveringRecordingIndicator = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var recordingIndicatorLabel: String {
        if viewModel.isRecording {
            return isHoveringRecordingIndicator ? "Pause" : "Recording"
        } else if let seconds = viewModel.recordingPauseRemainingSeconds {
            return isHoveringRecordingIndicator ? "Start Rec." : formatPauseCountdown(seconds)
        } else if viewModel.isRecordingPaused {
            return isHoveringRecordingIndicator ? "Start Rec." : "Paused"
        } else {
            return isHoveringRecordingIndicator ? "Start Rec." : "Off"
        }
    }

    private func formatPauseCountdown(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let remainingSeconds = clamped % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private var pauseRecordingMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            PauseMenuOptionRow(title: "5 min") {
                handlePauseSelection(duration: 5 * 60)
            }
            PauseMenuOptionRow(title: "30 min") {
                handlePauseSelection(duration: 30 * 60)
            }
            PauseMenuOptionRow(title: "60 min") {
                handlePauseSelection(duration: 60 * 60)
            }

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 1)

            PauseMenuOptionRow(title: "Turn Off") {
                handlePauseSelection(duration: nil)
            }
        }
        .padding(4)
        .retraceMenuContainer(addPadding: false)
    }

    private func handlePauseSelection(duration: TimeInterval?) {
        withAnimation(.easeOut(duration: 0.12)) {
            showPauseOptionsPopover = false
        }
        Task {
            await viewModel.pauseRecording(for: duration)
        }
    }

    private func pauseMenuOriginX(anchorRect: CGRect, containerWidth: CGFloat, menuWidth: CGFloat) -> CGFloat {
        let horizontalPadding: CGFloat = 16
        let desiredX = anchorRect.minX
        return min(
            max(horizontalPadding, desiredX),
            max(horizontalPadding, containerWidth - menuWidth - horizontalPadding)
        )
    }

    private struct PauseMenuOptionRow: View {
        let title: String
        let action: () -> Void

        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 0) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(isHovering ? .white : .white.opacity(0.78))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovering ? Color.white.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.1)) {
                    isHovering = hovering
                }
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
        }
    }

    // MARK: - Stats Cards Row

    private struct StatCardData: Identifiable {
        let id: String
        let icon: String
        let title: String
        let value: String
        let subtitle: String
        let graphData: [DailyDataPoint]?
        let graphColor: Color
        let valueFormatter: ((Int64) -> String)?

        init(icon: String, title: String, value: String, subtitle: String, graphData: [DailyDataPoint]? = nil, graphColor: Color = .retraceAccent, valueFormatter: ((Int64) -> String)? = nil) {
            self.id = title
            self.icon = icon
            self.title = title
            self.value = value
            self.subtitle = subtitle
            self.graphData = graphData
            self.graphColor = graphColor
            self.valueFormatter = valueFormatter
        }
    }

    private var statsCards: [StatCardData] {
        [
            StatCardData(
                icon: "calendar",
                title: "Total Days Recorded",
                value: "\(viewModel.daysRecorded) days",
                subtitle: formatOldestDateSubtitle(viewModel.oldestRecordedDate)
            ),
            StatCardData(
                icon: "clock.fill",
                title: "Screen Time",
                value: formatScreenTimeFromDaily(viewModel.dailyScreenTimeData),
                subtitle: "Last 7 days",
                graphData: viewModel.dailyScreenTimeData.isEmpty ? nil : viewModel.dailyScreenTimeData,
                graphColor: .blue,
                valueFormatter: { milliseconds in
                    let hours = Double(milliseconds) / 1000.0 / 3600.0
                    return String(format: "%.1fh", hours)
                }
            ),
            StatCardData(
                icon: "externaldrive.fill",
                title: "Total Storage Used",
                value: formatStorageSize(viewModel.totalStorageBytes),
                subtitle: formatStoragePerMonth(),
                graphData: viewModel.dailyStorageData.isEmpty ? nil : viewModel.dailyStorageData,
                graphColor: .cyan
            ),
            StatCardData(
                icon: "timelapse",
                title: "Timeline Opens",
                value: "\(viewModel.timelineOpensThisWeek)",
                subtitle: "Last 7 days",
                graphData: viewModel.dailyTimelineOpensData.isEmpty ? nil : viewModel.dailyTimelineOpensData,
                graphColor: .purple
            ),
            StatCardData(
                icon: "magnifyingglass",
                title: "Searches",
                value: "\(viewModel.searchesThisWeek)",
                subtitle: "Last 7 days",
                graphData: viewModel.dailySearchesData.isEmpty ? nil : viewModel.dailySearchesData,
                graphColor: .orange
            ),
            StatCardData(
                icon: "doc.on.doc",
                title: "Text Copies",
                value: "\(viewModel.textCopiesThisWeek)",
                subtitle: "Last 7 days",
                graphData: viewModel.dailyTextCopiesData.isEmpty ? nil : viewModel.dailyTextCopiesData,
                graphColor: .green
            ),
        ]
    }

    private func dashboardStatsStrip(layoutSize _: LayoutSize) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DashboardStatsStripLayoutPolicy.spacing) {
                ForEach(statsCards) { card in
                    compactStatTile(card)
                        .frame(
                            width: DashboardStatsStripLayoutPolicy.tileWidth,
                            height: DashboardStatsStripLayoutPolicy.tileHeight
                        )
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: DashboardStatsStripLayoutPolicy.tileHeight,
            maxHeight: DashboardStatsStripLayoutPolicy.tileHeight
        )
    }

    private func compactStatTile(_ card: StatCardData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.retraceSecondary.opacity(0.10))
                        .frame(width: 32, height: 32)

                    Image(systemName: card.icon)
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSecondary)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title)
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retraceSecondary)
                        .lineLimit(1)

                    Text(card.value)
                        .font(.retraceCalloutMedium)
                        .foregroundColor(.retracePrimary)
                        .lineLimit(1)

                    Text(card.subtitle)
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary.opacity(0.72))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            if let data = card.graphData, !data.isEmpty {
                MiniLineGraphView(
                    dataPoints: data,
                    lineColor: card.graphColor,
                    showGradientFill: true,
                    showYAxis: false,
                    valueFormatter: card.valueFormatter
                )
                .frame(height: DashboardStatsStripLayoutPolicy.graphHeight)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.018))
                    .frame(height: DashboardStatsStripLayoutPolicy.graphHeight)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.03))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(themeBorderColor.opacity(0.8), lineWidth: 1)
        )
    }

    private func statCard(
        icon: String,
        title: String,
        value: String,
        subtitle: String,
        graphData: [DailyDataPoint]?,
        graphColor: Color,
        theme: MilestoneCelebrationManager.ColorTheme,
        valueFormatter: ((Int64) -> String)?,
        layoutSize: LayoutSize = .normal
    ) -> some View {
        // Use a consistent muted color for all icons
        let iconColor = Color.retraceSecondary

        return VStack(spacing: 0) {
            HStack(spacing: layoutSize.iconSpacing) {
                // Icon
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.10))
                        .frame(width: layoutSize.iconCircleSize, height: layoutSize.iconCircleSize)

                    Image(systemName: icon)
                        .font(layoutSize.iconFont)
                        .foregroundColor(iconColor)
                }

                VStack(alignment: .leading, spacing: layoutSize.textSpacing) {
                    Text(title)
                        .font(layoutSize.titleFont)
                        .foregroundColor(.retraceSecondary)

                    Text(value)
                        .font(layoutSize.valueFont)
                        .foregroundColor(.retracePrimary)

                    Text(subtitle)
                        .font(layoutSize.subtitleFont)
                        .foregroundColor(.retraceSecondary.opacity(0.7))
                }

                Spacer()
            }
            .padding(layoutSize.cardPadding)

            // Mini line graph (if data is available)
            if let data = graphData, !data.isEmpty {
                MiniLineGraphView(
                    dataPoints: data,
                    lineColor: graphColor,
                    showGradientFill: true,
                    valueFormatter: valueFormatter
                )
                .frame(height: layoutSize.graphHeight)
                .padding(.horizontal, layoutSize.graphHorizontalPadding)
                .padding(.bottom, layoutSize.graphBottomPadding)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.02))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.controlBorderColor.opacity(0.6), lineWidth: 1)
        )
    }

    private func formatStorageSize(_ bytes: Int64) -> String {
        // Use decimal (SI) units to match Finder
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        } else {
            let mb = Double(bytes) / 1_000_000
            return String(format: "%.0f MB", mb)
        }
    }

    private func formatStoragePerMonth() -> String {
        let dailyData = viewModel.dailyStorageData
        guard !dailyData.isEmpty else { return "est. 0 GB/month" }

        // Sum all daily values and extrapolate to 30 days
        let totalBytes = dailyData.reduce(0) { $0 + $1.value }
        let daysWithData = dailyData.count
        let bytesPerDay = Double(totalBytes) / Double(daysWithData)
        let bytesPerMonth = bytesPerDay * 30.0
        let gbPerMonth = bytesPerMonth / 1_000_000_000
        return String(format: "est. %.1f GB/month", gbPerMonth)
    }

    private func formatOldestDateSubtitle(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return "since \(formatter.string(from: date))"
    }

    // MARK: - Dashboard Content Section

    private func dashboardContentSection(layoutSize: LayoutSize) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            dashboardContentTabs

            Group {
                switch selectedDashboardTab {
                case .dictation:
                    dictationDashboardCard(layoutSize: layoutSize)
                case .appUsage:
                    appUsageDashboardCard(layoutSize: layoutSize)
                case .live:
                    liveDashboardCard(layoutSize: layoutSize)
                case .screenshots:
                    screenshotsDashboardCard(layoutSize: layoutSize)
                }
            }
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var dashboardContentTabs: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(DashboardContentTab.allCases) { tab in
                    Button {
                        selectDashboardTab(tab)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: tab.icon)
                                .font(.retraceCaption2Medium)

                            Text(tab.title)
                                .font(.retraceCaptionMedium)
                        }
                        .foregroundColor(selectedDashboardTab == tab ? .retracePrimary : .retraceSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(selectedDashboardTab == tab ? Color.white.opacity(0.10) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )

            Text(selectedDashboardTab.subtitle)
                .font(.retraceCaption2Medium)
                .foregroundColor(.retraceSecondary.opacity(0.8))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    private func selectDashboardTab(_ tab: DashboardContentTab) {
        guard selectedDashboardTab != tab else { return }

        withAnimation(.easeInOut(duration: 0.16)) {
            selectedDashboardTab = tab
        }

        DashboardViewModel.recordDashboardTabSelected(
            coordinator: coordinatorWrapper.coordinator,
            tab: tab.rawValue
        )

        if tab == .dictation {
            Task {
                await refreshDictationDashboardData()
            }
        } else if tab == .live {
            Task {
                await refreshLiveAudioDashboardData()
            }
        } else if tab == .screenshots {
            Task {
                await refreshLiveFramesDashboardData()
            }
        }
    }

    // MARK: - App Usage Section

    private func appUsageDashboardCard(layoutSize: LayoutSize) -> some View {
        let appUsageLayout: AppUsageLayoutSize = .normal

        return Group {
            if viewModel.isLoading && viewModel.weeklyAppUsage.isEmpty {
                loadingStateView
            } else if viewModel.weeklyAppUsage.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 0) {
                    // Header row with view mode toggle
                    HStack {
                        Text("App Usage")
                            .font(.retraceHeadline)
                            .foregroundColor(.retracePrimary)

                        Spacer()

                        Text("\(formatTotalTime(viewModel.weeklyAppUsage.reduce(0) { $0 + $1.duration }))  ·  Last 7 days")
                            .font(.retraceCaptionMedium)
                            .foregroundColor(.retraceSecondary)

                        // View mode toggle
                        viewModeToggle
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)

                    Divider()
                        .background(Color.white.opacity(0.06))

                    // Content based on view mode
                    switch usageViewMode {
                    case .list:
                        AppUsageListView(
                            apps: viewModel.weeklyAppUsage,
                            totalTime: viewModel.totalWeeklyTime,
                            layoutSize: appUsageLayout,
                            loadWindowUsage: { bundleID in
                                await viewModel.getWindowUsageForApp(bundleID: bundleID)
                            },
                            loadTabsForDomain: { bundleID, domain in
                                await viewModel.getBrowserTabsForDomain(bundleID: bundleID, domain: domain)
                            },
                            onWindowTapped: { app, window in
                                handleWindowTapped(app, window)
                            }
                        )
                    case .hardDrive:
                        AppUsageHardDriveView(
                            apps: viewModel.weeklyAppUsage,
                            totalTime: viewModel.totalWeeklyTime,
                            onAppTapped: { app in
                                handleAppTapped(app)
                            }
                        )
                    }
                }
                .background(Color.white.opacity(0.03))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(themeBorderColor.opacity(1.2), lineWidth: 1.2)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Dictation Dashboard

    private func dictationDashboardCard(layoutSize _: LayoutSize) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.retraceAccent.opacity(0.14))
                        .frame(width: 42, height: 42)

                    Image(systemName: "mic.fill")
                        .font(.retraceHeadline)
                        .foregroundColor(.retraceAccent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Voice Dictation")
                        .font(.retraceHeadline)
                        .foregroundColor(.retracePrimary)

                    Text(dictationConfig.isEnabled ? DashboardContentTab.dictation.subtitle : "Disabled")
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSecondary)
                }

                Spacer()

                Text(dictationConfig.shortcut.displayString)
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retracePrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
            }

            recentInsertionsPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(18)
        .background(Color.white.opacity(0.03))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeBorderColor.opacity(1.2), lineWidth: 1.2)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Live Dashboard

    private func liveDashboardCard(layoutSize _: LayoutSize) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.retraceDanger.opacity(viewModel.isRecording ? 0.14 : 0.08))
                        .frame(width: 42, height: 42)

                    Image(systemName: "waveform.and.magnifyingglass")
                        .font(.retraceHeadline)
                        .foregroundColor(viewModel.isRecording ? .retraceDanger : .retraceSecondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Live Memory")
                        .font(.retraceHeadline)
                        .foregroundColor(.retracePrimary)

                    Text(DashboardContentTab.live.subtitle)
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSecondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.isRecording ? Color.retraceDanger : Color.retraceSecondary)
                        .frame(width: 7, height: 7)

                    Text(viewModel.isRecording ? "Recording" : "Paused")
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retraceSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
            }

            GeometryReader { geometry in
                let mode = DashboardLiveLayoutPolicy.contentMode(forWidth: geometry.size.width)
                let columns = DashboardLiveLayoutPolicy.columnWidths(forWidth: geometry.size.width)

                Group {
                    switch mode {
                    case .threeColumn:
                        HStack(alignment: .top, spacing: DashboardLiveLayoutPolicy.columnSpacing) {
                            liveAudioPanel
                                .frame(width: columns.transcript)
                                .frame(maxHeight: .infinity)

                            liveIntelligencePanel
                                .frame(width: columns.intelligence)
                                .frame(maxHeight: .infinity)

                            liveConversationContextPanel
                                .frame(width: columns.context)
                                .frame(maxHeight: .infinity)
                        }
                    case .stacked:
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 14) {
                                liveAudioPanel
                                liveIntelligencePanel
                                liveConversationContextPanel
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.03))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeBorderColor.opacity(1.2), lineWidth: 1.2)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func screenshotsDashboardCard(layoutSize _: LayoutSize) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.retraceAccent.opacity(0.12))
                        .frame(width: 42, height: 42)

                    Image(systemName: DashboardContentTab.screenshots.icon)
                        .font(.retraceHeadline)
                        .foregroundColor(.retraceAccent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Visual Memory")
                        .font(.retraceHeadline)
                        .foregroundColor(.retracePrimary)

                    Button("Activity & Evidence") {
                        ActivityTimelineController.shared.show(coordinator: coordinatorWrapper.coordinator)
                    }.buttonStyle(.link)

                    Text("Find what you saw, recover the text, then jump back into that moment.")
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSecondary)
                }

                Spacer()

                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSecondary)

                    TextField("Filter loaded moments", text: $screenshotSearchText)
                        .textFieldStyle(.plain)
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retracePrimary)
                        .onSubmit {
                            recordScreenshotAction("filter", frame: selectedLiveFrame)
                        }

                    if !screenshotSearchText.isEmpty {
                        Button {
                            screenshotSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.retraceCaptionMedium)
                                .foregroundColor(.retraceSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear filter")
                    }
                }
                .padding(.horizontal, 10)
                .frame(width: 248, height: 32)
                .background(Color.white.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                }

                screenshotNavigationControls

                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.isRecording ? Color.retraceDanger : Color.retraceSecondary)
                        .frame(width: 7, height: 7)

                    Text(viewModel.isRecording ? "Recording" : "Paused")
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retraceSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
            }

            GeometryReader { geometry in
                if DashboardScreenshotWorkspacePolicy.contentMode(forWidth: geometry.size.width) == .threeColumn {
                    let columns = DashboardScreenshotWorkspacePolicy.columnWidths(forWidth: geometry.size.width)

                    HStack(alignment: .top, spacing: DashboardLiveLayoutPolicy.columnSpacing) {
                        liveScreenshotsPanel
                            .frame(width: columns.momentRail)
                            .frame(maxHeight: .infinity)

                        selectedScreenshotPreviewPanel
                            .frame(width: columns.preview)
                            .frame(maxHeight: .infinity)

                        screenshotContextPanel
                            .frame(width: columns.inspector)
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 14) {
                            selectedScreenshotPreviewPanel
                                .frame(minHeight: 360)
                            liveScreenshotsPanel
                                .frame(minHeight: 320)
                            screenshotContextPanel
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.03))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeBorderColor.opacity(1.2), lineWidth: 1.2)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: screenshotSearchText) { _ in
            ensureFilteredLiveFrameSelection()
        }
    }

    private var recentInsertionsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Insertions")
                .font(.retraceCalloutMedium)
                .foregroundColor(.retracePrimary)

            Text("Only speech captured during the dictation hold appears here.")
                .font(.retraceCaption2)
                .foregroundColor(.retraceSecondary)

            if let dictationDashboardError {
                Text(dictationDashboardError)
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceWarning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if isLoadingDictationSessions && recentDictationSessions.isEmpty {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else if recentDictationSessions.isEmpty {
                Text("No dictation sessions yet. Hold \(dictationConfig.shortcut.displayString), speak, then release to paste.")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(recentDictationSessions) { session in
                            dictationSessionRow(session)
                                .onAppear {
                                    loadMoreDictationSessionsIfNeeded(current: session)
                                }

                            if session.id != recentDictationSessions.last?.id {
                                Divider()
                                    .background(Color.white.opacity(0.06))
                            }
                        }

                        if canLoadMoreDictationSessions {
                            loadOlderFooter(isLoading: isLoadingMoreDictationSessions)
                                .onAppear {
                                    Task { await loadMoreDictationSessions() }
                                }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.025))
        .cornerRadius(14)
    }

    private var liveAudioPanel: some View {
        let transcriptBlocks = liveAudioTranscriptBlocks
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.isRecording ? Color.retraceDanger : Color.retraceSecondary)
                    .frame(width: 7, height: 7)

                Text("Live Transcript")
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retracePrimary)

                Spacer()

                if !transcriptBlocks.isEmpty {
                    Button {
                        copyTranscriptText(
                            DashboardLiveTranscriptBlockPolicy.copyText(from: transcriptBlocks),
                            surface: "live_audio_loaded"
                        )
                    } label: {
                        Label("Copy loaded", systemImage: "doc.on.doc")
                            .font(.retraceCaption2Medium)
                            .foregroundColor(.retraceSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help("Copy all currently loaded transcript text")
                }

                if isLoadingLiveAudio {
                    ProgressView()
                        .scaleEffect(0.55)
                }
            }

            Text("Continuous speech blocks update as refinement improves them. Select text or copy a full passage.")
                .font(.retraceCaption2)
                .foregroundColor(.retraceSecondary)

            if let liveAudioError {
                Text(liveAudioError)
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceWarning)
            } else {
                liveAudioTranscriptHistory
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.025))
        .cornerRadius(14)
    }

    private var liveAudioTranscriptHistory: some View {
        let transcriptBlocks = liveAudioTranscriptBlocks
        return List {
            if transcriptBlocks.isEmpty {
                Text(liveAudioStatusRows.isEmpty
                    ? "No continuous transcript yet."
                    : "No readable transcript in the newest page. Older readable transcripts may still be below."
                )
                .font(.retraceCaptionMedium)
                .foregroundColor(.retraceSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                ForEach(transcriptBlocks) { block in
                    liveAudioTranscriptBlock(block)
                        .padding(.bottom, 10)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .onAppear {
                            loadMoreLiveAudioRowsIfNeeded(current: block)
                        }
                }
            }

            if DashboardLiveAudioHistoryPolicy.shouldShowHistory(
                readableRowCount: liveAudioRows.count,
                canLoadMoreOlderRows: canLoadMoreLiveAudioRows,
                isLoadingOlderRows: isLoadingMoreLiveAudio
            ) && canLoadMoreLiveAudioRows {
                Button {
                    Task { await loadMoreLiveAudioRows() }
                } label: {
                    loadOlderFooter(
                        isLoading: isLoadingMoreLiveAudio,
                        idleText: liveAudioRows.isEmpty ? "Load older readable transcripts" : "Scroll or click for older entries"
                    )
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .task(id: liveAudioTranscriptOffset) {
                    await autoContinueLiveAudioHistoryIfNeeded(
                        offset: liveAudioTranscriptOffset
                    )
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var liveScreenshotsPanel: some View {
        let displayedFrames = filteredLiveFrames
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceAccent)

                Text("Moments")
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retracePrimary)

                Spacer()

                Text(screenshotSearchText.isEmpty ? "\(liveFrames.count) loaded" : "\(displayedFrames.count) matches")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary)

                if isLoadingLiveFrames {
                    ProgressView()
                        .scaleEffect(0.55)
                }
            }

            Text("Newest first. Keep scrolling to travel further back.")
                .font(.retraceCaption2)
                .foregroundColor(.retraceSecondary)

            if let liveFrameError {
                Text(liveFrameError)
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceWarning)
            } else if isLoadingLiveFrames && liveFrames.isEmpty {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else if liveFrames.isEmpty {
                Text("No screen frames yet.")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else if displayedFrames.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.retraceHeadline)
                        .foregroundColor(.retraceSecondary.opacity(0.7))
                    Text("No loaded moments match this filter")
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSecondary)
                    Button("Clear filter") {
                        screenshotSearchText = ""
                    }
                    .buttonStyle(.plain)
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceAccent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                paginatedLiveScreenshotMomentList(displayedFrames)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.028))
        .cornerRadius(14)
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func paginatedLiveScreenshotMomentList(_ displayedFrames: [FrameWithVideoInfo]) -> some View {
        if #available(macOS 15.0, *) {
            liveScreenshotMomentList(displayedFrames)
                .onScrollGeometryChange(for: DashboardScreenshotScrollGeometry.self) { geometry in
                    DashboardScreenshotScrollGeometry(
                        offsetY: geometry.contentOffset.y,
                        contentHeight: geometry.contentSize.height,
                        containerHeight: geometry.containerSize.height
                    )
                } action: { previous, current in
                    handleLiveScreenshotScroll(previous: previous, current: current)
                }
        } else {
            liveScreenshotMomentList(displayedFrames)
        }
    }

    private func liveScreenshotMomentList(_ displayedFrames: [FrameWithVideoInfo]) -> some View {
        List {
            ForEach(displayedFrames, id: \.frame.id.value) { frame in
                liveScreenshotRow(frame)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .padding(.bottom, 6)
                    .onAppear {
                        loadLiveFrameThumbnailIfNeeded(frame)
                    }
            }

            if canLoadMoreLiveFrames && screenshotSearchText.isEmpty {
                Button {
                    Task { await loadMoreLiveFrames() }
                } label: {
                    loadOlderFooter(isLoading: isLoadingMoreLiveFrames)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
    }

    private var selectedScreenshotPreviewPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selectedFrame = selectedLiveFrame {
                let frame = selectedFrame.frame
                let frameID = frame.id.value

                HStack(spacing: 8) {
                    Image(systemName: "viewfinder")
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceAccent)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(liveFrameDisplayAppName(selectedFrame))
                            .font(.retraceCalloutMedium)
                            .foregroundColor(.retracePrimary)
                            .lineLimit(1)

                        Text(formatDashboardTimestamp(frame.timestamp))
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary)
                    }

                    Spacer(minLength: 8)

                    Text(screenshotOCRStatusLabel(selectedFrame))
                        .font(.retraceCaption2Medium)
                        .foregroundColor(screenshotOCRStatusColor(selectedFrame))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(screenshotOCRStatusColor(selectedFrame).opacity(0.10))
                        .clipShape(Capsule())

                    Button {
                        openTimelineAt(date: frame.timestamp)
                        recordScreenshotAction("open_timeline", frame: selectedFrame)
                    } label: {
                        Label("Open moment", systemImage: "arrow.up.right.square")
                            .font(.retraceCaption2Medium)
                            .foregroundColor(.retracePrimary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Color.retraceAccent.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Open this moment in the timeline")
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Color.black.opacity(0.24))

                    if selectedLiveFramePreviewID == frameID,
                       let image = selectedLiveFramePreview {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(8)
                            .transition(.opacity)
                    } else if let thumbnail = liveFrameThumbnails[frameID] {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(8)
                            .overlay {
                                if isLoadingSelectedLiveFramePreview {
                                    ProgressView()
                                        .scaleEffect(0.65)
                                        .padding(8)
                                        .background(Color.black.opacity(0.45))
                                        .clipShape(Circle())
                                }
                            }
                    } else if isLoadingSelectedLiveFramePreview {
                        VStack(spacing: 9) {
                            ProgressView()
                                .scaleEffect(0.75)
                            Text("Recovering this moment...")
                                .font(.retraceCaption2Medium)
                                .foregroundColor(.retraceSecondary)
                        }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundColor(.retraceWarning)

                            Text(selectedLiveFramePreviewError ?? "This frame is not ready to display yet.")
                                .font(.retraceCaptionMedium)
                                .foregroundColor(.retraceSecondary)
                                .multilineTextAlignment(.center)

                            Button("Try again") {
                                retrySelectedLiveFrameImage()
                            }
                            .buttonStyle(.plain)
                            .font(.retraceCaption2Medium)
                            .foregroundColor(.retraceAccent)
                        }
                        .padding(24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                }

                if let windowName = frame.metadata.windowName, !windowName.isEmpty {
                    Text(windowName)
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retracePrimary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                if let browserURL = frame.metadata.browserURL, !browserURL.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.retraceCaption2)
                        Text(browserURL)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button("Open") {
                            openScreenshotURL(browserURL, frame: selectedFrame)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.retraceAccent)
                    }
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.retraceSecondary)
                    Text("Select a moment to inspect it")
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [Color.retraceAccent.opacity(0.055), Color.white.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(14)
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.retraceAccent.opacity(0.12), lineWidth: 1)
        }
    }

    private var liveIntelligencePanel: some View {
        let items = liveFuseIntelPresentationSnapshot.items(for: selectedFuseIntelSection)
        let operatingBrief = FuseIntelOperatingBriefPolicy.make(from: items)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceWarning)

                Text("Operating Brief")
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retracePrimary)

                Text("RETRACE × FUSEINTEL")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundColor(.retraceWarning)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.retraceWarning.opacity(0.11))
                    .clipShape(Capsule())

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(fuseIntelConnectionColor)
                        .frame(width: 6, height: 6)
                    Text(fuseIntelConnectionLabel)
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retraceSecondary)
                }

                Button {
                    Task {
                        await fuseIntelViewModel.refresh(force: true)
                        await refreshLiveDerivedPresentation()
                        recordFuseIntelAction("refresh")
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retraceSecondary)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(fuseIntelViewModel.isLoading)
                .help("Refresh FuseIntel")

                Button {
                    openFuseIntelDashboard()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retraceSecondary)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("Open the full FuseIntel dashboard")
            }

            Text("Current work connected to source-backed priorities, risks, relationships, and next moves.")
                .font(.retraceCaption2)
                .foregroundColor(.retraceSecondary)

            HStack(spacing: 8) {
                Label("Local context live", systemImage: "bolt.fill")
                    .foregroundColor(.retraceSuccess)

                if let freshness = fuseIntelViewModel.freshnessDate {
                    Text("Business evidence updated \(freshness, style: .relative)")
                        .foregroundColor(.retraceSecondary)
                }
            }
            .font(.retraceCaption2)

            HStack(spacing: 4) {
                ForEach(FuseIntelSection.allCases) { section in
                    Button {
                        selectedFuseIntelSection = section
                        recordFuseIntelAction("section_\(section.rawValue)")
                    } label: {
                        HStack(spacing: 5) {
                            Text(section.title)
                            if section == selectedFuseIntelSection, !items.isEmpty {
                                Text("\(items.count)")
                                    .foregroundColor(.retraceSecondary)
                            }
                        }
                        .font(.retraceCaption2Medium)
                        .foregroundColor(section == selectedFuseIntelSection ? .retracePrimary : .retraceSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(section == selectedFuseIntelSection ? Color.white.opacity(0.085) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.black.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if fuseIntelViewModel.isLoading && fuseIntelViewModel.snapshot == nil {
                VStack(spacing: 9) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Connecting to the local intel loop...")
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if fuseIntelViewModel.snapshot == nil {
                fuseIntelUnavailableState
            } else if items.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "checkmark.circle")
                        .font(.retraceHeadline)
                        .foregroundColor(.retraceSuccess)
                    Text("Nothing needs your attention here")
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retracePrimary)
                    Text("FuseIntel is connected; this view will update as new evidence arrives.")
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else if selectedFuseIntelSection == .now {
                operatingBriefContent(operatingBrief)
            } else {
                ScrollView(showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(items) { item in
                            fuseIntelItemCard(item)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [Color.retraceWarning.opacity(0.04), Color.white.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(14)
    }

    private func operatingBriefContent(_ brief: FuseIntelOperatingBrief) -> some View {
        ScrollView(showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let recommendation = brief.recommendation {
                    fuseIntelRecommendationCard(recommendation)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("No evidenced next move yet", systemImage: "checkmark.seal")
                            .font(.retraceCaptionMedium)
                            .foregroundColor(.retracePrimary)
                        Text("Unsupported suggestions are withheld. Broader signals remain available in the other views.")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if !brief.connectedContext.isEmpty {
                    fuseIntelListHeading(
                        title: "Connected to current work",
                        detail: "Older evidence matching the live screen and transcript"
                    )
                    ForEach(brief.connectedContext) { item in
                        fuseIntelCompactRow(item)
                    }
                }

                if !brief.broaderPriorities.isEmpty {
                    fuseIntelListHeading(
                        title: "Across the business",
                        detail: "High-value work that should not disappear behind the current task"
                    )
                    ForEach(brief.broaderPriorities) { item in
                        fuseIntelCompactRow(item)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func fuseIntelRecommendationCard(_ item: FuseIntelDisplayItem) -> some View {
        let accent = fuseIntelAccentColor(item)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Text("BEST NEXT MOVE")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundColor(accent)

                if item.relevance == .contextMatch {
                    Text("CONNECTED TO NOW")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.45)
                        .foregroundColor(.retraceSuccess)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.retraceSuccess.opacity(0.11))
                        .clipShape(Capsule())
                }

                Spacer(minLength: 0)

                if let timestamp = item.timestamp {
                    Text(timestamp, style: .relative)
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary)
                }
            }

            Text(item.title)
                .font(.retraceCalloutMedium)
                .foregroundColor(.retracePrimary)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 3) {
                Text("WHY NOW")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.65)
                    .foregroundColor(.retraceSecondary)
                Text(item.detail)
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retracePrimary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let suggestedAction = item.suggestedAction,
               !suggestedAction.isEmpty,
               suggestedAction != item.detail {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.retraceCaption2Medium)
                        .foregroundColor(accent)
                    Text(suggestedAction)
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retracePrimary)
                        .textSelection(.enabled)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }

            fuseIntelEvidenceFooter(item, accent: accent)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [accent.opacity(0.14), Color.white.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(accent.opacity(0.28), lineWidth: 1)
        }
    }

    private func fuseIntelListHeading(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.retraceCaptionMedium)
                .foregroundColor(.retracePrimary)
            Text(detail)
                .font(.retraceCaption2)
                .foregroundColor(.retraceSecondary)
        }
        .padding(.top, 2)
    }

    private func fuseIntelCompactRow(_ item: FuseIntelDisplayItem) -> some View {
        let accent = fuseIntelAccentColor(item)
        let isExpanded = expandedFuseIntelItemIDs.contains(item.id)

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: fuseIntelIconName(item.kind))
                .font(.retraceCaptionMedium)
                .foregroundColor(accent)
                .frame(width: 26, height: 26)
                .background(accent.opacity(0.11))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.eyebrow.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.45)
                        .foregroundColor(accent)
                    Spacer(minLength: 0)
                    if item.relevance == .contextMatch {
                        Image(systemName: "link")
                            .font(.retraceCaption2Medium)
                            .foregroundColor(.retraceSuccess)
                    }
                }

                Text(item.title)
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retracePrimary)
                    .lineLimit(isExpanded ? nil : 2)
                    .textSelection(.enabled)

                Text(item.detail)
                    .font(.retraceCaption2)
                    .foregroundColor(.retraceSecondary)
                    .lineLimit(isExpanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: isExpanded)

                if isExpanded {
                    fuseIntelEvidenceFooter(item, accent: accent)
                }
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.065))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isExpanded {
                expandedFuseIntelItemIDs.remove(item.id)
            } else {
                expandedFuseIntelItemIDs.insert(item.id)
            }
        }
    }

    private func fuseIntelEvidenceFooter(_ item: FuseIntelDisplayItem, accent: Color) -> some View {
        HStack(spacing: 6) {
            if let impactLabel = item.impactLabel, !impactLabel.isEmpty {
                Text(impactLabel)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(accent.opacity(0.10))
                    .clipShape(Capsule())
            }

            ForEach(Array(item.sourceRefs.prefix(3).enumerated()), id: \.offset) { _, sourceRef in
                Text(sourceRef.source.replacingOccurrences(of: "_", with: " ").uppercased())
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundColor(.retraceSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.05))
                    .clipShape(Capsule())
            }

            Spacer(minLength: 0)

            if let confidence = item.confidence, confidence > 0 {
                Text("\(Int((confidence * 100).rounded()))% evidence")
                    .font(.retraceCaption2)
                    .foregroundColor(.retraceSecondary)
            }
        }
    }

    private var fuseIntelUnavailableState: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.retraceWarning.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: "bolt.horizontal.circle")
                    .font(.retraceHeadline)
                    .foregroundColor(.retraceWarning)
            }

            Text(fuseIntelConnectionLabel == "Delayed" ? "FuseIntel is catching up" : "FuseIntel is offline")
                .font(.retraceCaptionMedium)
                .foregroundColor(.retracePrimary)

            Text(fuseIntelConnectionLabel == "Delayed"
                ? "The local intel loop is taking longer than usual. Retrace keeps recording while it finishes; retry remains available."
                : "Retrace keeps recording locally. Start the FuseIntel BFF on 127.0.0.1:9010 to restore the wider work feed.")
                .font(.retraceCaption2)
                .foregroundColor(.retraceSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Retry") {
                    Task {
                        await fuseIntelViewModel.refresh(force: true)
                        await refreshLiveDerivedPresentation()
                        recordFuseIntelAction("retry")
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.retraceAccent)

                Button("Open dashboard") {
                    openFuseIntelDashboard()
                }
                .buttonStyle(.plain)
                .foregroundColor(.retraceSecondary)
            }
            .font(.retraceCaption2Medium)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func fuseIntelItemCard(_ item: FuseIntelDisplayItem) -> some View {
        let accent = fuseIntelAccentColor(item)
        let isExpanded = expandedFuseIntelItemIDs.contains(item.id)

        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(accent.opacity(0.18))
                    .frame(width: 38, height: 38)

                Image(systemName: fuseIntelIconName(item.kind))
                    .font(.retraceCalloutMedium)
                    .foregroundColor(accent)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.eyebrow.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundColor(accent)

                    if item.relevance == .contextMatch {
                        Text("CONTEXT MATCH")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .tracking(0.4)
                            .foregroundColor(.retraceSuccess)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.retraceSuccess.opacity(0.10))
                            .clipShape(Capsule())
                    }

                    Spacer(minLength: 0)

                    if let timestamp = item.timestamp {
                        Text(timestamp, style: .relative)
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.75))
                    }
                }

                Text(item.title)
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retracePrimary)
                    .lineLimit(isExpanded ? nil : 2)

                Text(item.detail)
                    .font(.retraceCaption2)
                    .foregroundColor(.retraceSecondary)
                    .lineLimit(isExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: isExpanded)

                HStack(spacing: 6) {
                    ForEach(Array(item.sourceRefs.prefix(3).enumerated()), id: \.offset) { _, sourceRef in
                        Text(sourceRef.source.replacingOccurrences(of: "_", with: " ").uppercased())
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundColor(.retraceSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.045))
                            .clipShape(Capsule())
                    }

                    if let confidence = item.confidence, confidence > 0 {
                        Text("\(Int((confidence * 100).rounded()))% evidence")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.8))
                    } else if let evidenceState = item.evidenceState {
                        Text(evidenceState.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.8))
                    }

                    Spacer(minLength: 0)

                    if let sourceURL = item.sourceRefs.compactMap(\.url).first,
                       let url = URL(string: sourceURL),
                       ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                        Button {
                            NSWorkspace.shared.open(url)
                            recordFuseIntelAction("open_source")
                        } label: {
                            Image(systemName: "arrow.up.right")
                                .font(.retraceCaption2Medium)
                                .foregroundColor(.retraceAccent)
                        }
                        .buttonStyle(.plain)
                        .help("Open source")
                    }
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    accent.opacity(0.07),
                    Color.white.opacity(0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(accent.opacity(0.16), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isExpanded {
                expandedFuseIntelItemIDs.remove(item.id)
            } else {
                expandedFuseIntelItemIDs.insert(item.id)
            }
        }
    }

    private var liveConversationContextPanel: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path")
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSuccess)

                    Text("Activity Pulse")
                        .font(.retraceCalloutMedium)
                        .foregroundColor(.retracePrimary)

                    Spacer()

                    Text("LOCAL · LIVE")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .foregroundColor(.retraceSuccess)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.retraceSuccess.opacity(0.10))
                        .clipShape(Capsule())
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("WORKING ON NOW")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundColor(.retraceSuccess)

                    Text(liveActivityBrief.headline)
                        .font(.retraceCalloutMedium)
                        .foregroundColor(.retracePrimary)
                        .lineLimit(3)
                        .textSelection(.enabled)

                    Text(liveUserActivitySummary)
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [Color.retraceSuccess.opacity(0.11), Color.white.opacity(0.025)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.retraceSuccess.opacity(0.18), lineWidth: 1)
                }

                if !liveActivityBrief.appTrail.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("RECENT WORK TRAIL")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .tracking(0.65)
                            .foregroundColor(.retraceSecondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                ForEach(Array(liveActivityBrief.appTrail.prefix(4)), id: \.self) { appName in
                                    Text(appName)
                                        .font(.retraceCaption2Medium)
                                        .foregroundColor(appName == liveActivityBrief.currentApp ? .retracePrimary : .retraceSecondary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 4)
                                        .background(
                                            appName == liveActivityBrief.currentApp
                                                ? Color.retraceAccent.opacity(0.14)
                                                : Color.white.opacity(0.045)
                                        )
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 6) {
                    activityPulseMetric(
                        value: activityDurationLabel(liveActivityBrief.duration),
                        label: "window"
                    )
                    activityPulseMetric(
                        value: "\(liveActivityBrief.capturedMomentCount)",
                        label: "moments"
                    )
                    activityPulseMetric(
                        value: "\(liveActivityBrief.appSwitchCount)",
                        label: "switches"
                    )
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Image(systemName: liveFuseIntelContextMatchCount > 0 ? "link.badge.plus" : "link")
                            .font(.retraceCaptionMedium)
                            .foregroundColor(liveFuseIntelContextMatchCount > 0 ? .retraceSuccess : .retraceSecondary)
                        Text("Connected evidence")
                            .font(.retraceCaptionMedium)
                            .foregroundColor(.retracePrimary)
                    }
                    Text(liveFuseIntelRelationshipSummary)
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 10) {
                    liveContextMetadataRow(
                        iconName: "clock",
                        label: "Latest",
                        value: formatDashboardTimestamp(liveContextReferenceDate)
                    )

                    if let frame = latestLiveContextFrame?.frame {
                        liveContextMetadataRow(
                            iconName: "app.dashed",
                            label: "App",
                            value: liveFrameDisplayAppName(frame)
                        )

                        if let windowName = frame.metadata.windowName, !windowName.isEmpty {
                            liveContextMetadataRow(iconName: "macwindow", label: "Window", value: windowName)
                        }

                        if let browserURL = frame.metadata.browserURL, !browserURL.isEmpty {
                            liveContextMetadataRow(iconName: "link", label: "URL", value: browserURL)
                        }

                        liveContextMetadataRow(
                            iconName: "photo",
                            label: "Frame",
                            value: "#\(frame.id.value)"
                        )
                    } else {
                        liveContextMetadataRow(
                            iconName: "app.dashed",
                            label: "Screen",
                            value: viewModel.isRecording ? "Waiting for a readable frame" : "Capture paused"
                        )
                    }

                    if let latestAudio = liveAudioRows.first {
                        liveContextMetadataRow(
                            iconName: "waveform",
                            label: "Audio",
                            value: latestAudio.source.rawValue.capitalized
                        )
                        liveContextMetadataRow(
                            iconName: "checkmark.seal",
                            label: "Transcript",
                            value: liveTranscriptConfidenceLabel(latestAudio)
                        )
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.035))
                .cornerRadius(12)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.025))
        .cornerRadius(14)
    }

    private func activityPulseMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.retraceCaptionMedium)
                .foregroundColor(.retracePrimary)
            Text(label.uppercased())
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .tracking(0.45)
                .foregroundColor(.retraceSecondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func activityDurationLabel(_ duration: TimeInterval) -> String {
        guard duration >= 60 else { return "Now" }
        if duration < 3_600 { return "\(max(Int(duration / 60), 1))m" }
        let hours = Int(duration / 3_600)
        let minutes = Int(duration.truncatingRemainder(dividingBy: 3_600) / 60)
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    private var screenshotContextPanel: some View {
        let selectedFrame = selectedLiveFrame

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.viewfinder")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceAccent)

                Text("Inspector")
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retracePrimary)

                Spacer()

                if let selectedFrame {
                    Text(selectedFrame.frame.source.displayName)
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retraceSecondary)
                }
            }

            Text("Everything Retrace captured about this moment, without truncation.")
                .font(.retraceCaption2)
                .foregroundColor(.retraceSecondary)

            if let selectedFrame {
                liveFrameMetadataCard(selectedFrame)

                let frameID = selectedFrame.frame.id.value
                if liveFrameOCRLoadingIDs.contains(frameID) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.55)
                        Text("Loading captured text...")
                            .font(.retraceCaption2Medium)
                            .foregroundColor(.retraceSecondary)
                    }
                    .padding(.vertical, 6)
                } else if let nodes = liveFrameOCRNodes[frameID], !nodes.isEmpty {
                    liveFrameOCRTextPanel(nodes)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            selectedFrame.processingStatus == 2 ? "No readable text found" : "Text indexing is still catching up",
                            systemImage: selectedFrame.processingStatus == 2 ? "text.badge.xmark" : "clock.arrow.circlepath"
                        )
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSecondary)

                        Text(selectedFrame.processingStatus == 2
                            ? "The image is preserved and searchable by app, window, URL, and time."
                            : "This panel updates automatically when OCR completes; no repair action is required."
                        )
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            } else {
                Text("Select a screenshot to inspect its context.")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.025))
        .cornerRadius(14)
    }

    private func liveFrameOCRTextPanel(_ nodes: [OCRNodeWithText]) -> some View {
        let lines = DashboardOCRContextPolicy.readableLines(from: nodes)
        let fullText = lines.map(\.text).joined(separator: "\n")

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Captured Text")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceSecondary)

                Spacer(minLength: 0)

                Text("\(lines.count) lines · \(nodes.count) regions")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary.opacity(0.8))

                Button {
                    copyTranscriptText(fullText, surface: "screenshot_ocr")
                    recordScreenshotAction("copy_ocr", frame: selectedLiveFrame)
                } label: {
                    Label("Copy all", systemImage: "doc.on.doc")
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retraceAccent)
                }
                .buttonStyle(.plain)
            }

            if lines.isEmpty {
                Text("OCR regions were captured, but no readable text was available.")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView(showsIndicators: false) {
                    Text(fullText)
                        .font(.retraceCaption2)
                        .foregroundColor(.retracePrimary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.white.opacity(0.035))
                        .cornerRadius(9)
                }
            }
        }
    }

    private func liveScreenshotRow(_ item: FrameWithVideoInfo) -> some View {
        let frame = item.frame
        let frameID = frame.id.value
        let isSelected = selectedLiveFrameID == frameID

        return HStack(alignment: .center, spacing: 9) {
            ZStack {
                if let image = liveFrameThumbnails[frameID] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(0.035))
                        .overlay {
                            if liveFrameThumbnailLoadingIDs.contains(frameID) {
                                ProgressView()
                                    .scaleEffect(0.5)
                            } else {
                                Image(systemName: frame.isEncodedToVideo ? "photo" : "clock.badge.exclamationmark")
                                    .font(.retraceCaptionMedium)
                                    .foregroundColor(.retraceSecondary.opacity(0.7))
                            }
                        }
                }
            }
            .frame(width: 82, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(frame.timestamp, style: .time)
                        .font(.retraceCaption2Medium)
                        .foregroundColor(isSelected ? .retraceAccent : .retraceSecondary)

                    Spacer(minLength: 0)

                    if frame.source == .rewind {
                        Text("Imported")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.75))
                    }
                }

                Text(liveFrameDisplayAppName(item))
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retracePrimary)
                    .lineLimit(1)

                if let windowName = frame.metadata.windowName, !windowName.isEmpty {
                    Text(windowName)
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary.opacity(0.8))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(isSelected ? Color.retraceAccent.opacity(0.11) : Color.white.opacity(0.035))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.retraceAccent.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectLiveFrame(item)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Screenshot from \(liveFrameDisplayAppName(item))")
        .accessibilityAddTraits(.isButton)
    }

    private func liveFrameMetadataCard(_ item: FrameWithVideoInfo) -> some View {
        let frame = item.frame

        return VStack(alignment: .leading, spacing: 8) {
            metadataLine(label: "Time", value: formatDashboardTimestamp(frame.timestamp))
            metadataLine(label: "App", value: liveFrameDisplayAppName(item))

            if let windowName = frame.metadata.windowName, !windowName.isEmpty {
                metadataLine(label: "Window", value: windowName)
            }

            if let browserURL = frame.metadata.browserURL, !browserURL.isEmpty {
                metadataLine(label: "URL", value: browserURL)
            }

            metadataLine(label: "Frame", value: "#\(frame.id.value)")
            metadataLine(label: "Video", value: frame.isEncodedToVideo ? "\(frame.videoID.value) · \(frame.frameIndexInSegment)" : "Pending encode")
        }
        .padding(10)
        .background(Color.white.opacity(0.035))
        .cornerRadius(10)
    }

    private func liveContextInsightCard(iconName: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceAccent)
                    .frame(width: 18)

                Text(title)
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceSecondary)
            }

            Text(body)
                .font(.retraceCaptionMedium)
                .foregroundColor(.retracePrimary)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.white.opacity(0.035))
                .cornerRadius(10)
        }
        .padding(10)
        .background(Color.white.opacity(0.025))
        .cornerRadius(12)
    }

    private func liveContextMetadataRow(iconName: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.retraceCaptionMedium)
                .foregroundColor(.retraceSecondary.opacity(0.75))
                .frame(width: 18)

            Text(label)
                .font(.retraceCaption2Medium)
                .foregroundColor(.retraceSecondary)

            Spacer(minLength: 8)

            Text(value)
                .font(.retraceCaption2Medium)
                .foregroundColor(.retracePrimary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private var liveUserActivitySummary: String {
        liveActivityBrief.summary
    }

    private var liveContextReferenceDate: Date {
        [
            latestLiveContextFrame?.frame.timestamp,
            liveAudioRows.first?.startedAt,
            liveAudioStatusRows.first?.startedAt
        ]
        .compactMap { $0 }
        .max() ?? Date()
    }

    private var liveActivityBrief: RetraceActivityBrief {
        liveActivityBriefSnapshot
    }

    private var liveFuseIntelContextItems: [FuseIntelDisplayItem] {
        liveFuseIntelPresentationSnapshot.contextItems
    }

    private var liveFuseIntelContextMatchCount: Int {
        liveFuseIntelPresentationSnapshot.contextMatchCount
    }

    private var liveFuseIntelRelationshipSummary: String {
        let contextItems = liveFuseIntelContextItems
        guard !contextItems.isEmpty else {
            return fuseIntelViewModel.isConnected
                ? "No evidence-backed relationship to the current screen or speech yet. Workspace-wide intel remains available in the centre feed."
                : "FuseIntel is offline. Retrace is still preserving local screen and audio context."
        }

        let terms = Array(Set(contextItems.flatMap(\.matchedTerms))).sorted().prefix(4)
        let termText = terms.isEmpty ? "the current context" : terms.joined(separator: ", ")
        return "\(liveFuseIntelContextMatchCount) source-backed item\(liveFuseIntelContextMatchCount == 1 ? "" : "s") match \(termText)."
    }

    private var fuseIntelConnectionLabel: String {
        if fuseIntelViewModel.isLoading && fuseIntelViewModel.snapshot == nil { return "Connecting" }
        if fuseIntelViewModel.snapshot == nil,
           fuseIntelViewModel.errorMessage?.localizedCaseInsensitiveContains("timed out") == true {
            return "Delayed"
        }
        guard let snapshot = fuseIntelViewModel.snapshot else { return "Offline" }
        if fuseIntelViewModel.errorMessage != nil { return "Stale" }
        if snapshot.commandEnvelope.degraded || snapshot.feedEnvelope.degraded || !fuseIntelViewModel.warnings.isEmpty {
            return "Degraded"
        }
        if let freshness = fuseIntelViewModel.freshnessDate,
           Date().timeIntervalSince(freshness) > 3_600 {
            return "Stale"
        }
        return "Connected"
    }

    private var fuseIntelConnectionColor: Color {
        switch fuseIntelConnectionLabel {
        case "Connected": return .retraceSuccess
        case "Connecting": return .retraceAccent
        case "Stale", "Degraded", "Delayed": return .retraceWarning
        default: return .retraceSecondary
        }
    }

    private func fuseIntelIconName(_ kind: FuseIntelDisplayKind) -> String {
        switch kind {
        case .move: return "arrow.forward.circle.fill"
        case .commercial: return "chart.line.uptrend.xyaxis"
        case .foresight: return "binoculars.fill"
        case .radar: return "scope"
        case .signal: return "waveform.path.ecg"
        case .upcoming: return "calendar"
        case .waiting: return "hourglass"
        case .delegated: return "person.crop.circle.badge.checkmark"
        case .judgement: return "questionmark.diamond.fill"
        case .thread: return "bubble.left.and.bubble.right.fill"
        }
    }

    private func fuseIntelAccentColor(_ item: FuseIntelDisplayItem) -> Color {
        if item.relevance == .contextMatch { return .retraceSuccess }
        if ["critical", "high"].contains(item.priority.lowercased()) { return .retraceDanger }
        switch item.kind {
        case .move: return .retraceAccent
        case .commercial: return .retraceSuccess
        case .foresight: return .retraceWarning
        case .radar: return .retraceWarning
        case .signal: return .teal
        case .upcoming: return .retraceSuccess
        case .waiting: return .orange
        case .delegated: return .blue
        case .judgement: return .orange
        case .thread: return .cyan
        }
    }

    private func liveTranscriptConfidenceLabel(_ row: DashboardLiveAudioRow) -> String {
        DashboardTranscriptConfidencePolicy.displayLabel(
            transcriptionPass: row.transcriptionPass,
            confidence: row.confidence
        )
    }

    private func openFuseIntelDashboard() {
        NSWorkspace.shared.open(fuseIntelViewModel.baseURL)
        recordFuseIntelAction("open_dashboard")
    }

    private func recordFuseIntelAction(_ action: String) {
        DashboardViewModel.recordDashboardFuseIntelAction(
            coordinator: coordinatorWrapper.coordinator,
            action: action,
            section: selectedFuseIntelSection.rawValue,
            connectionState: fuseIntelConnectionLabel.lowercased()
        )
    }

    private func metadataLine(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.retraceCaption2Medium)
                .foregroundColor(.retraceSecondary.opacity(0.7))

            Text(value)
                .font(.retraceCaption2)
                .foregroundColor(.retracePrimary)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func loadOlderFooter(isLoading: Bool, idleText: String = "Scroll for older entries") -> some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.55)
            }

            Text(isLoading ? "Loading older entries..." : idleText)
                .font(.retraceCaption2Medium)
                .foregroundColor(.retraceSecondary.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func liveAudioRow(_ row: DashboardLiveAudioRow) -> some View {
        if row.isPendingSummary || row.isLowConfidenceSummary || row.isStatusSummary {
            liveAudioPendingSummaryRow(row)
        } else {
            liveAudioTranscriptRow(row)
        }
    }

    private var liveAudioStatusPanel: some View {
        let latestStatusDate = liveAudioStatusRows.map(\.startedAt).max()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceWarning)

                Text("Recent capture status")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retracePrimary)

                Spacer(minLength: 0)

                if let latestStatusDate {
                    HStack(spacing: 4) {
                        Text("Updated")
                        Text(latestStatusDate, style: .time)
                    }
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.055))
                    .clipShape(Capsule())
                }
            }

            Text("First-pass transcripts stay in the feed. Repair and catch-up state is tracked here.")
                .font(.retraceCaption2)
                .foregroundColor(.retraceSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(liveAudioStatusRows.prefix(3))) { row in
                    liveAudioStatusSummaryRow(row)
                }

                if liveAudioStatusRows.count > 3 {
                    Text("+\(liveAudioStatusRows.count - 3) more status groups")
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retraceSecondary.opacity(0.8))
                }
            }
        }
        .padding(10)
        .background(
            LinearGradient(
                colors: [
                    Color.retraceWarning.opacity(0.08),
                    Color.white.opacity(0.028)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.retraceWarning.opacity(0.18), lineWidth: 1)
        )
    }

    private func liveAudioStatusSummaryRow(_ row: DashboardLiveAudioRow) -> some View {
        let accent = row.isPendingSummary
            ? Color.retraceAccent
            : (row.isLowConfidenceSummary ? Color.retraceWarning : Color.retraceSecondary)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: summaryIconName(for: row))
                .font(.retraceCaption2Medium)
                .foregroundColor(accent)
                .frame(width: 16, height: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(summaryTitle(for: row))
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retracePrimary)

                    Text(row.startedAt, style: .time)
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary.opacity(0.8))
                }

                Text(statusSummaryDescription(for: row))
                    .font(.retraceCaption2)
                    .foregroundColor(.retraceSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Text(row.pendingBatchCount == 1 ? "1" : "\(row.pendingBatchCount)")
                .font(.retraceCaption2Medium)
                .foregroundColor(accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(accent.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(8)
        .background(Color.white.opacity(0.028))
        .cornerRadius(9)
    }

    private func liveAudioPendingSummaryRow(_ row: DashboardLiveAudioRow) -> some View {
        let isLowConfidence = row.isLowConfidenceSummary
        let isPending = row.isPendingSummary
        let accent = isLowConfidence ? Color.retraceSecondary : (isPending ? Color.retraceWarning : Color.retraceAccent)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(accent.opacity(0.14))
                        .frame(width: 28, height: 28)

                    Image(systemName: summaryIconName(for: row))
                        .font(.retraceCaptionMedium)
                        .foregroundColor(accent)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(summaryTitle(for: row))
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retracePrimary)

                    Text("Latest capture \(row.startedAt, style: .time)")
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary)
                }

                Spacer(minLength: 0)

                Text(row.pendingBatchCount == 1 ? "1 batch" : "\(row.pendingBatchCount) batches")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.12))
                    .clipShape(Capsule())
            }

            Text(row.displayText)
                .font(.retraceCaptionMedium)
                .foregroundColor(.retracePrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(isLowConfidence
                ? "Stored for repair, hidden from the readable stream unless a cleaner pass finds speech."
                : (isPending
                    ? "Showing the newest readable transcripts below instead of repeating placeholder rows."
                    : "Repeated identical status rows are collapsed so speech and repair state stay readable.")
            )
                .font(.retraceCaption2)
                .foregroundColor(.retraceSecondary)
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [
                    accent.opacity(0.09),
                    Color.white.opacity(0.035)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(accent.opacity(0.24), lineWidth: 1)
        )
    }

    private func summaryTitle(for row: DashboardLiveAudioRow) -> String {
        if row.ambientLabel != nil {
            return "Ambient audio"
        }
        if row.isLowConfidenceSummary {
            return "Repair queue"
        }
        if row.isPendingSummary {
            return "Transcribing"
        }
        return "Capture notice"
    }

    private func statusSummaryDescription(for row: DashboardLiveAudioRow) -> String {
        if row.ambientLabel != nil {
            return row.displayText
        }
        if row.isLowConfidenceSummary {
            return "Uncertain audio is preserved for repair; useful first-pass text remains in the feed."
        }
        if row.isPendingSummary {
            return "Captured audio is decoding now."
        }
        return DashboardLiveAudioRow.statusText(status: row.transcriptStatus, qualityFlags: row.qualityFlags)
    }

    private func summaryIconName(for row: DashboardLiveAudioRow) -> String {
        if row.ambientLabel != nil {
            return "waveform"
        }
        if row.isLowConfidenceSummary {
            return "waveform.badge.exclamationmark"
        }
        if row.isPendingSummary {
            return "waveform.path.badge.clock"
        }
        return "rectangle.stack.badge.minus"
    }

    private func liveAudioTranscriptBlock(_ block: DashboardLiveTranscriptBlock) -> some View {
        let accent = block.isUpdating ? Color.retraceWarning : Color.retraceAccent

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(block.startedAt, style: .time)
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary)

                if block.spansMultipleDisplayMinutes {
                    Text("–")
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retraceSecondary.opacity(0.7))
                    Text(block.endedAt, style: .time)
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retraceSecondary)
                }

                Text(block.sourceLabel)
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceAccent)

                if let badgeText = block.refinementBadgeText {
                    Text(badgeText)
                        .font(.retraceCaption2Medium)
                        .foregroundColor(block.isUpdating ? .retraceWarning : .retraceSuccess)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (block.isUpdating ? Color.retraceWarning : Color.retraceSuccess)
                                .opacity(0.12)
                        )
                        .clipShape(Capsule())
                }

                Spacer(minLength: 0)

                copyTranscriptButton(text: block.text, surface: "live_audio_block")
            }

            Text(block.text)
                .font(.retraceCaptionMedium)
                .foregroundColor(.retracePrimary)
                .lineSpacing(2)
                .lineLimit(nil)
                .textSelection(.enabled)
        }
        .padding(12)
        .padding(.leading, 2)
        .background {
            RoundedRectangle(cornerRadius: 11)
                .fill(accent.opacity(block.isUpdating ? 0.065 : 0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(accent.opacity(block.isUpdating ? 0.2 : 0.1), lineWidth: 1)
                }
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent.opacity(block.isUpdating ? 0.65 : 0.5))
                .frame(width: 2)
                .padding(.vertical, 10)
        }
    }

    private func liveAudioTranscriptRow(_ row: DashboardLiveAudioRow) -> some View {
        let isExpanded = expandedLiveAudioRowIDs.contains(row.id)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(row.startedAt, style: .time)
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary)

                Text(row.source.rawValue.capitalized)
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceAccent)

                if row.isRepairedTranscript {
                    Text(row.repairedBadgeText)
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retraceSuccess)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.retraceSuccess.opacity(0.12))
                        .clipShape(Capsule())
                } else if row.isRepairingTranscript {
                    Text("First pass")
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retraceWarning)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.retraceWarning.opacity(0.12))
                        .clipShape(Capsule())
                } else if !row.hasTranscriptText {
                    Text(row.statusBadgeText)
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retraceSecondary)
                }

                Spacer(minLength: 0)

                if row.hasTranscriptText {
                    copyTranscriptButton(text: row.text, surface: "live_audio")
                }
            }

            Text(row.displayText)
                .font(.retraceCaptionMedium)
                .foregroundColor(row.hasTranscriptText ? .retracePrimary : .retraceSecondary)
                .lineLimit(DashboardTranscriptDisplayPolicy.lineLimit(isExpanded: isExpanded))
                .textSelection(.enabled)
        }
        .padding(10)
        .background(row.isRepairingTranscript ? Color.retraceWarning.opacity(0.045) : Color.white.opacity(0.035))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isExpanded
                        ? Color.retraceAccent.opacity(0.45)
                        : (row.isRepairingTranscript ? Color.retraceWarning.opacity(0.18) : Color.clear),
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            toggleLiveAudioExpansion(row)
        }
    }

    private func dictationSessionRow(_ session: DictationSession) -> some View {
        let isExpanded = expandedDictationSessionIDs.contains(session.id)
        let transcriptText = dictationSessionPreview(session)

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: dictationStatusIcon(session.status))
                .font(.retraceCaptionMedium)
                .foregroundColor(dictationStatusColor(session.status))
                .frame(width: 18, height: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.startedAt, style: .time)
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retraceSecondary)

                    Text(dictationStatusLabel(session.status))
                        .font(.retraceCaption2Medium)
                        .foregroundColor(dictationStatusColor(session.status))

                    if let endedAt = session.endedAt {
                        Text(formatDictationDuration(endedAt.timeIntervalSince(session.startedAt)))
                            .font(.retraceCaption2Medium)
                            .foregroundColor(.retraceSecondary.opacity(0.8))
                    }

                    Spacer(minLength: 0)

                    copyTranscriptButton(text: transcriptText, surface: "dictation")
                }

                Text(transcriptText)
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retracePrimary)
                    .lineLimit(DashboardTranscriptDisplayPolicy.lineLimit(isExpanded: isExpanded))
                    .textSelection(.enabled)

                if let appName = session.targetContext?.appName, !appName.isEmpty {
                    Text(appName)
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary.opacity(0.8))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .background(isExpanded ? Color.white.opacity(0.028) : Color.clear)
        .cornerRadius(10)
        .contentShape(Rectangle())
        .onTapGesture {
            toggleDictationSessionExpansion(session)
        }
    }

    private func copyTranscriptButton(text: String, surface: String) -> some View {
        Button {
            copyTranscriptText(text, surface: surface)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.retraceCaption2Medium)
                .foregroundColor(.retraceSecondary)
                .padding(5)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Copy full text")
    }

    private func copyTranscriptText(_ text: String, surface _: String) {
        let cleanedText = DashboardTranscriptDisplayPolicy.copyText(text)
        guard !cleanedText.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cleanedText, forType: .string)
        DashboardViewModel.recordTextCopy(
            coordinator: coordinatorWrapper.coordinator,
            text: cleanedText
        )
    }

    private func toggleDictationSessionExpansion(_ session: DictationSession) {
        if expandedDictationSessionIDs.contains(session.id) {
            expandedDictationSessionIDs.remove(session.id)
        } else {
            expandedDictationSessionIDs.insert(session.id)
            DashboardViewModel.recordDashboardTranscriptExpanded(
                coordinator: coordinatorWrapper.coordinator,
                surface: "dictation"
            )
        }
    }

    private func toggleLiveAudioExpansion(_ row: DashboardLiveAudioRow) {
        if expandedLiveAudioRowIDs.contains(row.id) {
            expandedLiveAudioRowIDs.remove(row.id)
        } else {
            expandedLiveAudioRowIDs.insert(row.id)
            DashboardViewModel.recordDashboardTranscriptExpanded(
                coordinator: coordinatorWrapper.coordinator,
                surface: "live_audio"
            )
        }
    }

    private var selectedLiveFrame: FrameWithVideoInfo? {
        guard let selectedLiveFrameID else {
            return liveFrames.first
        }
        return liveFrames.first { $0.frame.id.value == selectedLiveFrameID } ?? liveFrames.first
    }

    private func liveFrameDisplayAppName(_ item: FrameWithVideoInfo) -> String {
        liveFrameDisplayAppName(item.frame)
    }

    private func liveFrameDisplayAppName(_ frame: FrameReference) -> String {
        if let bundleID = frame.metadata.appBundleID,
           let resolvedName = liveFrameAppNamesByBundleID[bundleID] {
            return resolvedName
        }
        return frame.metadata.appName ?? frame.metadata.appBundleID ?? "Unknown app"
    }

    private var filteredLiveFrames: [FrameWithVideoInfo] {
        guard !screenshotSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return liveFrames
        }

        return liveFrames.filter { item in
            let frameID = item.frame.id.value
            return DashboardScreenshotFilterPolicy.matches(
                query: screenshotSearchText,
                appName: liveFrameDisplayAppName(item),
                windowName: item.frame.metadata.windowName,
                browserURL: item.frame.metadata.browserURL,
                ocrText: liveFrameOCRNodes[frameID].map(DashboardOCRContextPolicy.fullText(from:))
            )
        }
    }

    private var screenshotNavigationControls: some View {
        let orderedIDs = filteredLiveFrames.map(\.frame.id.value)
        let newerID = DashboardScreenshotNavigationPolicy.adjacentID(
            from: selectedLiveFrameID,
            direction: .newer,
            orderedIDs: orderedIDs
        )
        let olderID = DashboardScreenshotNavigationPolicy.adjacentID(
            from: selectedLiveFrameID,
            direction: .older,
            orderedIDs: orderedIDs
        )

        return HStack(spacing: 1) {
            screenshotNavigationButton(
                icon: "chevron.up",
                help: "Newer moment",
                isEnabled: newerID != nil
            ) {
                navigateScreenshots(.newer)
            }

            screenshotNavigationButton(
                icon: "chevron.down",
                help: "Older moment",
                isEnabled: olderID != nil
            ) {
                navigateScreenshots(.older)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func screenshotNavigationButton(
        icon: String,
        help: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.retraceCaption2Medium)
                .foregroundColor(isEnabled ? .retracePrimary : .retraceSecondary.opacity(0.35))
                .frame(width: 27, height: 27)
                .background(Color.white.opacity(isEnabled ? 0.035 : 0))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
    }

    private func selectLiveFrame(_ item: FrameWithVideoInfo) {
        if selectedLiveFrameID != item.frame.id.value || selectedLiveFrame?.frame.source != item.frame.source {
            selectedLiveFrameRefresher.cancel()
        }
        selectedLiveFrameID = item.frame.id.value
        Log.debug("[Dashboard] Selected live screenshot frame \(item.frame.id.value)", category: .ui)
        DashboardViewModel.recordDashboardLiveFrameSelected(
            coordinator: coordinatorWrapper.coordinator,
            frameID: item.frame.id.value,
            source: item.frame.source.rawValue
        )
        loadLiveFrameThumbnailIfNeeded(item)
        loadLiveFrameContextIfNeeded(item)
        loadSelectedLiveFramePreview(item)
        Task { await refreshSelectedLiveFrameState() }
    }

    private func navigateScreenshots(_ direction: DashboardScreenshotNavigationDirection) {
        let orderedIDs = filteredLiveFrames.map(\.frame.id.value)
        guard let targetID = DashboardScreenshotNavigationPolicy.adjacentID(
            from: selectedLiveFrameID,
            direction: direction,
            orderedIDs: orderedIDs
        ), let item = liveFrames.first(where: { $0.frame.id.value == targetID }) else {
            return
        }

        selectLiveFrame(item)
        recordScreenshotAction(direction == .older ? "navigate_older" : "navigate_newer", frame: item)
    }

    private func ensureFilteredLiveFrameSelection() {
        guard let first = filteredLiveFrames.first else { return }
        guard filteredLiveFrames.contains(where: { $0.frame.id.value == selectedLiveFrameID }) else {
            selectLiveFrame(first)
            return
        }
    }

    private func retrySelectedLiveFrameImage() {
        guard let selectedLiveFrame else { return }
        let frameID = selectedLiveFrame.frame.id.value
        liveFrameThumbnailFailureCounts[frameID] = 0
        liveFramePreviewFailureCounts[frameID] = 0
        selectedLiveFramePreviewError = nil
        loadLiveFrameThumbnailIfNeeded(selectedLiveFrame)
        loadSelectedLiveFramePreview(selectedLiveFrame, force: true)
        recordScreenshotAction("retry_image", frame: selectedLiveFrame)
    }

    private func openScreenshotURL(_ value: String, frame: FrameWithVideoInfo) {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return
        }
        NSWorkspace.shared.open(url)
        recordScreenshotAction("open_url", frame: frame)
    }

    private func recordScreenshotAction(_ action: String, frame: FrameWithVideoInfo?) {
        DashboardViewModel.recordDashboardScreenshotAction(
            coordinator: coordinatorWrapper.coordinator,
            action: action,
            frameID: frame?.frame.id.value,
            source: frame?.frame.source.rawValue,
            queryLength: action == "filter" ? screenshotSearchText.count : nil
        )
    }

    private func screenshotOCRStatusLabel(_ item: FrameWithVideoInfo) -> String {
        switch item.processingStatus {
        case 2:
            return "Text ready"
        case 3:
            return "Text unavailable"
        default:
            return "Indexing text"
        }
    }

    private func screenshotOCRStatusColor(_ item: FrameWithVideoInfo) -> Color {
        switch item.processingStatus {
        case 2:
            return .retraceSuccess
        case 3:
            return .retraceWarning
        default:
            return .retraceAccent
        }
    }

    private func loadMoreDictationSessionsIfNeeded(current session: DictationSession) {
        guard session.id == recentDictationSessions.last?.id else { return }
        Task { await loadMoreDictationSessions() }
    }

    private func loadMoreLiveAudioRowsIfNeeded(current row: DashboardLiveAudioRow) {
        guard DashboardLiveAudioHistoryPolicy.shouldAutoLoadOlderRows(
            currentRowID: row.id,
            lastRowID: liveAudioRows.last?.id,
            lastRequestedBoundaryRowID: lastAutoLoadedLiveAudioBoundaryRowID,
            canLoadMoreOlderRows: canLoadMoreLiveAudioRows,
            isLoadingOlderRows: isLoadingMoreLiveAudio
        ) else { return }
        lastAutoLoadedLiveAudioBoundaryRowID = row.id
        Task { await loadMoreLiveAudioRows() }
    }

    private func loadMoreLiveAudioRowsIfNeeded(current block: DashboardLiveTranscriptBlock) {
        guard DashboardLiveAudioHistoryPolicy.shouldAutoLoadOlderRows(
            currentRowID: block.oldestRowID,
            lastRowID: liveAudioRows.last?.id,
            lastRequestedBoundaryRowID: lastAutoLoadedLiveAudioBoundaryRowID,
            canLoadMoreOlderRows: canLoadMoreLiveAudioRows,
            isLoadingOlderRows: isLoadingMoreLiveAudio
        ) else { return }
        lastAutoLoadedLiveAudioBoundaryRowID = block.oldestRowID
        Task { await loadMoreLiveAudioRows() }
    }

    private func handleLiveScreenshotScroll(
        previous: DashboardScreenshotScrollGeometry,
        current: DashboardScreenshotScrollGeometry
    ) {
        let boundaryID = liveFrames.last?.frame.id.value
        guard DashboardScreenshotPaginationPolicy.shouldLoadOlder(
            previousOffsetY: previous.offsetY,
            currentOffsetY: current.offsetY,
            contentHeight: current.contentHeight,
            containerHeight: current.containerHeight,
            boundaryID: boundaryID,
            lastRequestedBoundaryID: lastAutoLoadedLiveFrameBoundaryID,
            canLoadMore: canLoadMoreLiveFrames,
            isLoading: isLoadingMoreLiveFrames
        ) else { return }

        lastAutoLoadedLiveFrameBoundaryID = boundaryID
        Task { await loadMoreLiveFrames() }
    }

    private func loadMoreDictationSessions() async {
        await loadDictationDashboardData(reset: false)
    }

    private func loadMoreLiveAudioRows() async {
        await loadLiveAudioDashboardData(reset: false)
    }

    private func autoContinueLiveAudioHistoryIfNeeded(offset: Int) async {
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        guard DashboardLiveAudioHistoryPolicy.shouldAutoContinueFromVisibleFooter(
            currentOffset: offset,
            lastRequestedOffset: lastAutoLoadedLiveAudioOffset,
            canLoadMoreOlderRows: canLoadMoreLiveAudioRows,
            isLoadingOlderRows: isLoadingMoreLiveAudio
        ) else { return }

        lastAutoLoadedLiveAudioOffset = offset
        await loadMoreLiveAudioRows()
    }

    private func loadMoreLiveFrames() async {
        await loadLiveFramesDashboardData(reset: false)
    }

    private func loadDictationDashboardData(reset: Bool = true) async {
        guard reset || canLoadMoreDictationSessions else { return }
        guard !isLoadingDictationSessions && !isLoadingMoreDictationSessions else { return }

        if reset {
            isLoadingDictationSessions = true
            canLoadMoreDictationSessions = true
        } else {
            isLoadingMoreDictationSessions = true
        }
        defer {
            isLoadingDictationSessions = false
            isLoadingMoreDictationSessions = false
        }

        do {
            dictationConfig = await coordinatorWrapper.coordinator.getDictationConfig()
            let offset = reset ? 0 : recentDictationSessions.count
            let sessions = try await coordinatorWrapper.coordinator.getRecentDictationSessions(
                limit: Self.transcriptPageSize,
                offset: offset
            )

            if reset {
                recentDictationSessions = sessions
            } else {
                appendDictationSessions(sessions)
                if !sessions.isEmpty {
                    DashboardViewModel.recordDashboardTranscriptLoadOlder(
                        coordinator: coordinatorWrapper.coordinator,
                        surface: "dictation"
                    )
                }
            }

            canLoadMoreDictationSessions = sessions.count == Self.transcriptPageSize
            dictationDashboardError = nil
        } catch {
            dictationDashboardError = "Unable to load dictation history"
            DashboardViewModel.recordDashboardLoadFailed(
                coordinator: coordinatorWrapper.coordinator,
                surface: "dictation_sessions",
                error: error
            )
            Log.error("[Dashboard] Failed to load dictation history", category: .ui, error: error)
        }
    }

    private func refreshDictationDashboardData() async {
        guard !isLoadingDictationSessions && !isLoadingMoreDictationSessions else { return }
        if recentDictationSessions.isEmpty {
            await loadDictationDashboardData(reset: true)
            return
        }

        do {
            dictationConfig = await coordinatorWrapper.coordinator.getDictationConfig()
            let sessions = try await coordinatorWrapper.coordinator.getRecentDictationSessions(
                limit: Self.transcriptPageSize,
                offset: 0
            )
            mergeLatestDictationSessions(sessions)
            if recentDictationSessions.count <= Self.transcriptPageSize {
                canLoadMoreDictationSessions = sessions.count == Self.transcriptPageSize
            }
            dictationDashboardError = nil
        } catch {
            dictationDashboardError = "Unable to load dictation history"
            DashboardViewModel.recordDashboardLoadFailed(
                coordinator: coordinatorWrapper.coordinator,
                surface: "dictation_sessions",
                error: error
            )
            Log.error("[Dashboard] Failed to refresh dictation history", category: .ui, error: error)
        }
    }

    private func loadLiveAudioDashboardData(reset: Bool = true) async {
        guard reset || canLoadMoreLiveAudioRows else { return }
        guard !isLoadingLiveAudio && !isLoadingMoreLiveAudio else { return }

        if reset {
            isLoadingLiveAudio = liveAudioRows.isEmpty
            canLoadMoreLiveAudioRows = true
            lastAutoLoadedLiveAudioBoundaryRowID = nil
            lastAutoLoadedLiveAudioOffset = nil
        } else {
            isLoadingMoreLiveAudio = true
        }
        defer {
            isLoadingLiveAudio = false
            isLoadingMoreLiveAudio = false
        }

        do {
            guard let queries = await coordinatorWrapper.coordinator.getAudioTranscriptionQueries() else {
                liveAudioRawRows = []
                liveAudioRows = []
                liveAudioStatusRows = []
                liveAudioTranscriptBlocks = []
                liveAudioTranscriptOffset = 0
                lastAutoLoadedLiveAudioBoundaryRowID = nil
                lastAutoLoadedLiveAudioOffset = nil
                liveAudioError = "Transcript store is not available"
                return
            }

            let canLoadMore: Bool
            if reset {
                let activityRows = try await fetchLiveAudioRows(
                    queries: queries,
                    limit: Self.transcriptPageSize,
                    offset: 0,
                    includeActivityRows: true
                )
                let transcriptRows = try await fetchLiveAudioRows(
                    queries: queries,
                    limit: Self.transcriptPageSize,
                    offset: 0,
                    includeActivityRows: false
                )
                var mergedRows = normalizedLiveAudioRows(activityRows + transcriptRows)
                var fetchedTranscriptRows = transcriptRows.count
                var lastFetchedTranscriptRows = transcriptRows.count
                var fetchedPageCount = 1
                var preparedSnapshot = await prepareLiveAudioSnapshot(for: mergedRows)
                var transcriptOffset = DashboardLiveAudioPaginationPolicy.nextTranscriptOffset(
                    currentOffset: 0,
                    fetchedTranscriptRows: lastFetchedTranscriptRows,
                    reset: true
                )

                while DashboardLiveAudioHistoryPolicy.shouldPrefetchMoreReadableRows(
                    readableRowCount: preparedSnapshot.transcriptRows.count,
                    targetReadableRowCount: DashboardLiveMemoryPolicy.initialReadableTranscriptTarget,
                    fetchedTranscriptRows: lastFetchedTranscriptRows,
                    fetchedPageCount: fetchedPageCount,
                    pageSize: Self.transcriptPageSize,
                    canLoadMoreOlderRows: lastFetchedTranscriptRows == Self.transcriptPageSize
                ) {
                    let olderTranscriptRows = try await fetchLiveAudioRows(
                        queries: queries,
                        limit: Self.transcriptPageSize,
                        offset: transcriptOffset,
                        includeActivityRows: false
                    )
                    guard !olderTranscriptRows.isEmpty else {
                        lastFetchedTranscriptRows = 0
                        break
                    }

                    mergedRows = DashboardLiveAudioPresentationPolicy.mergedRowsReplacingOlderPasses(
                        existing: mergedRows,
                        latest: olderTranscriptRows
                    )
                    lastFetchedTranscriptRows = olderTranscriptRows.count
                    fetchedPageCount += 1
                    fetchedTranscriptRows += olderTranscriptRows.count
                    transcriptOffset = DashboardLiveAudioPaginationPolicy.nextTranscriptOffset(
                        currentOffset: transcriptOffset,
                        fetchedTranscriptRows: olderTranscriptRows.count,
                        reset: false
                    )
                    preparedSnapshot = await prepareLiveAudioSnapshot(for: mergedRows)
                }

                guard !Task.isCancelled else { return }
                liveAudioRawRows = mergedRows
                applyLiveAudioSnapshot(preparedSnapshot)
                liveAudioTranscriptOffset = fetchedTranscriptRows
                canLoadMore = lastFetchedTranscriptRows == Self.transcriptPageSize
            } else {
                let targetReadableRows = liveAudioRows.count + DashboardLiveMemoryPolicy.olderReadableTranscriptTarget
                var transcriptOffset = liveAudioTranscriptOffset
                var fetchedTranscriptRows = 0
                var lastFetchedTranscriptRows = Self.transcriptPageSize
                var fetchedPageCount = 0
                var mergedRows = liveAudioRawRows
                var preparedSnapshot = await prepareLiveAudioSnapshot(for: mergedRows)

                repeat {
                    let rows = try await fetchLiveAudioRows(
                        queries: queries,
                        limit: Self.transcriptPageSize,
                        offset: transcriptOffset,
                        includeActivityRows: false
                    )
                    guard !rows.isEmpty else {
                        lastFetchedTranscriptRows = 0
                        break
                    }

                    mergedRows = DashboardLiveAudioPresentationPolicy.mergedRowsReplacingOlderPasses(
                        existing: mergedRows,
                        latest: rows
                    )
                    lastFetchedTranscriptRows = rows.count
                    fetchedPageCount += 1
                    fetchedTranscriptRows += rows.count
                    transcriptOffset = DashboardLiveAudioPaginationPolicy.nextTranscriptOffset(
                        currentOffset: transcriptOffset,
                        fetchedTranscriptRows: rows.count,
                        reset: false
                    )
                    preparedSnapshot = await prepareLiveAudioSnapshot(for: mergedRows)
                } while DashboardLiveAudioHistoryPolicy.shouldPrefetchMoreReadableRows(
                    readableRowCount: preparedSnapshot.transcriptRows.count,
                    targetReadableRowCount: targetReadableRows,
                    fetchedTranscriptRows: lastFetchedTranscriptRows,
                    fetchedPageCount: fetchedPageCount,
                    pageSize: Self.transcriptPageSize,
                    canLoadMoreOlderRows: lastFetchedTranscriptRows == Self.transcriptPageSize
                )

                guard !Task.isCancelled else { return }
                liveAudioRawRows = mergedRows
                applyLiveAudioSnapshot(preparedSnapshot)
                canLoadMore = lastFetchedTranscriptRows == Self.transcriptPageSize
                liveAudioTranscriptOffset = transcriptOffset
                if fetchedTranscriptRows > 0 {
                    DashboardViewModel.recordDashboardTranscriptLoadOlder(
                        coordinator: coordinatorWrapper.coordinator,
                        surface: "live_audio"
                    )
                }
            }

            canLoadMoreLiveAudioRows = canLoadMore
            liveAudioError = nil
        } catch {
            liveAudioError = "Unable to load live transcript"
            DashboardViewModel.recordDashboardLoadFailed(
                coordinator: coordinatorWrapper.coordinator,
                surface: "live_audio",
                error: error
            )
            Log.error("[Dashboard] Failed to load live audio transcript", category: .ui, error: error)
        }
    }

    private func refreshLiveAudioDashboardData() async {
        guard !isLoadingLiveAudio && !isLoadingMoreLiveAudio else { return }
        if liveAudioRawRows.isEmpty {
            await loadLiveAudioDashboardData(reset: true)
            return
        }

        do {
            guard let queries = await coordinatorWrapper.coordinator.getAudioTranscriptionQueries() else {
                liveAudioError = "Transcript store is not available"
                return
            }

            let activityRows = try await fetchLiveAudioRows(
                queries: queries,
                limit: Self.transcriptPageSize,
                offset: 0,
                includeActivityRows: true
            )
            let transcriptRows = try await fetchLiveAudioRows(
                queries: queries,
                limit: Self.transcriptPageSize,
                offset: 0,
                includeActivityRows: false
            )
            let mergedRows = DashboardLiveAudioPresentationPolicy.mergedRowsReplacingOlderPasses(
                existing: liveAudioRawRows,
                latest: activityRows + transcriptRows
            )
            let preparedSnapshot = await prepareLiveAudioSnapshot(for: mergedRows)
            guard !Task.isCancelled else { return }
            liveAudioRawRows = mergedRows
            applyLiveAudioSnapshot(preparedSnapshot)
            liveAudioTranscriptOffset = max(liveAudioTranscriptOffset, transcriptRows.count)
            if liveAudioRows.count <= Self.transcriptPageSize {
                canLoadMoreLiveAudioRows = transcriptRows.count == Self.transcriptPageSize
            }
            liveAudioError = nil
        } catch {
            liveAudioError = "Unable to load live transcript"
            DashboardViewModel.recordDashboardLoadFailed(
                coordinator: coordinatorWrapper.coordinator,
                surface: "live_audio",
                error: error
            )
            Log.error("[Dashboard] Failed to refresh live audio transcript", category: .ui, error: error)
        }
    }

    private func refreshLiveDerivedPresentation() async {
        liveDerivedPresentationGeneration &+= 1
        let generation = liveDerivedPresentationGeneration
        let moments = recentActivityFrames.map { item in
            let appName = liveFrameDisplayAppName(item)
            return RetraceActivityMoment(
                timestamp: item.frame.timestamp,
                appName: appName,
                windowTitle: item.frame.metadata.windowName,
                browserURL: item.frame.metadata.browserURL,
                isSelfCapture: isRetraceActivityFrame(item, resolvedAppName: appName)
            )
        }
        let speech = liveAudioTranscriptBlocks
            .prefix(RetraceActivityBriefPolicy.maximumSpeechSegments)
            .map { block in
                RetraceSpeechMoment(
                    startedAt: block.startedAt,
                    endedAt: block.endedAt,
                    text: block.text
                )
            }
        let command = fuseIntelViewModel.command
        let feed = fuseIntelViewModel.feed
        let start = CFAbsoluteTimeGetCurrent()

        let derived = await Task.detached(priority: .utility) {
            let activityBrief = RetraceActivityBriefPolicy.make(moments: moments, speech: speech)
            return DashboardLiveDerivedPresentation(
                activityBrief: activityBrief,
                fuseIntel: FuseIntelPresentationSnapshotPolicy.make(
                    command: command,
                    feed: feed,
                    contextText: activityBrief.contextText
                )
            )
        }.value

        guard !Task.isCancelled, generation == liveDerivedPresentationGeneration else { return }
        if liveActivityBriefSnapshot != derived.activityBrief {
            liveActivityBriefSnapshot = derived.activityBrief
        }
        if liveFuseIntelPresentationSnapshot != derived.fuseIntel {
            liveFuseIntelPresentationSnapshot = derived.fuseIntel
        }
        Log.recordLatency(
            "dashboard.live.derived_presentation_background_ms",
            valueMs: (CFAbsoluteTimeGetCurrent() - start) * 1_000,
            category: .ui,
            summaryEvery: 10,
            warningThresholdMs: 25,
            criticalThresholdMs: 75
        )
    }

    private func refreshLatestLiveContextFrame() async {
        do {
            let fetchLimit = recentActivityFrames.isEmpty
                ? DashboardLiveLayoutPolicy.activityInitialFrameFetchLimit
                : DashboardLiveLayoutPolicy.activityRefreshFrameFetchLimit
            let frames = try await coordinatorWrapper.coordinator.getMostRecentFramesWithVideoInfo(
                limit: fetchLimit
            )
            await resolveLiveFrameAppNames(frames)
            guard !Task.isCancelled else { return }

            var seenFrameIDs = Set<FrameID>()
            let usefulFrames = (frames.filter { !isRetraceActivityFrame($0) } + recentActivityFrames)
                .sorted { $0.frame.timestamp > $1.frame.timestamp }
                .filter { seenFrameIDs.insert($0.frame.id).inserted }
            recentActivityFrames = Array(usefulFrames.prefix(RetraceActivityBriefPolicy.maximumMoments))
            latestLiveContextFrame = frames.first
        } catch {
            Log.warning("[Dashboard] Unable to refresh latest live screen context: \(error)", category: .ui)
        }
    }

    private func isRetraceActivityFrame(
        _ item: FrameWithVideoInfo,
        resolvedAppName: String? = nil
    ) -> Bool {
        if item.frame.metadata.appBundleID?.caseInsensitiveCompare("io.retrace.app") == .orderedSame {
            return true
        }
        let appName = resolvedAppName ?? liveFrameDisplayAppName(item)
        return appName.caseInsensitiveCompare("Retrace") == .orderedSame
    }

    private func loadLiveFramesDashboardData(reset: Bool = true) async {
        guard reset || canLoadMoreLiveFrames else { return }
        guard !isLoadingLiveFrames && !isLoadingMoreLiveFrames else { return }

        if reset {
            isLoadingLiveFrames = liveFrames.isEmpty
            canLoadMoreLiveFrames = true
            lastAutoLoadedLiveFrameBoundaryID = nil
        } else {
            isLoadingMoreLiveFrames = true
        }
        defer {
            isLoadingLiveFrames = false
            isLoadingMoreLiveFrames = false
        }

        do {
            let frames: [FrameWithVideoInfo]
            if reset {
                frames = try await coordinatorWrapper.coordinator.getMostRecentFramesWithVideoInfo(
                    limit: DashboardLiveLayoutPolicy.screenshotPageSize
                )
            } else if let oldestTimestamp = liveFrames.last?.frame.timestamp {
                frames = try await coordinatorWrapper.coordinator.getFramesWithVideoInfoBefore(
                    timestamp: oldestTimestamp,
                    limit: DashboardLiveLayoutPolicy.screenshotPageSize
                )
            } else {
                frames = []
            }

            await resolveLiveFrameAppNames(frames)

            if reset {
                liveFrames = frames
            } else {
                appendLiveFrames(frames)
                if !frames.isEmpty {
                    DashboardViewModel.recordDashboardTranscriptLoadOlder(
                        coordinator: coordinatorWrapper.coordinator,
                        surface: "live_screenshots"
                    )
                }
            }

            canLoadMoreLiveFrames = frames.count == DashboardLiveLayoutPolicy.screenshotPageSize
            liveFrameError = nil
            ensureSelectedLiveFrame()
            trimLiveFrameCaches()
            retryTransientLiveFrameImages()
        } catch {
            liveFrameError = "Unable to load screenshots"
            DashboardViewModel.recordDashboardLoadFailed(
                coordinator: coordinatorWrapper.coordinator,
                surface: "live_screenshots",
                error: error
            )
            Log.error("[Dashboard] Failed to load live screenshots", category: .ui, error: error)
        }
    }

    private func refreshLiveFramesDashboardData() async {
        guard !isLoadingLiveFrames && !isLoadingMoreLiveFrames else { return }
        if liveFrames.isEmpty {
            await loadLiveFramesDashboardData(reset: true)
            return
        }

        do {
            let frames = try await coordinatorWrapper.coordinator.getMostRecentFramesWithVideoInfo(
                limit: DashboardLiveLayoutPolicy.screenshotPageSize
            )
            await resolveLiveFrameAppNames(frames)
            guard !Task.isCancelled else { return }
            mergeLatestLiveFrames(frames)
            if liveFrames.count <= DashboardLiveLayoutPolicy.screenshotPageSize {
                canLoadMoreLiveFrames = frames.count == DashboardLiveLayoutPolicy.screenshotPageSize
            }
            liveFrameError = nil
            await refreshSelectedLiveFrameState()
            guard !Task.isCancelled,
                  DashboardRefreshLoopPolicy.shouldContinue(loopTab: .screenshots, selectedTab: selectedDashboardTab, isWindowVisible: viewModel.isWindowVisible) else { return }
            ensureSelectedLiveFrame()
            refreshSelectedLiveFrameOCRIfCompleted()
            trimLiveFrameCaches()
            retryTransientLiveFrameImages()
        } catch {
            liveFrameError = "Unable to refresh screenshots"
            DashboardViewModel.recordDashboardLoadFailed(
                coordinator: coordinatorWrapper.coordinator,
                surface: "live_screenshots",
                error: error
            )
            Log.error("[Dashboard] Failed to refresh live screenshots", category: .ui, error: error)
        }
    }

    private func appendDictationSessions(_ sessions: [DictationSession]) {
        let existingIDs = Set(recentDictationSessions.map(\.id))
        recentDictationSessions.append(contentsOf: sessions.filter { !existingIDs.contains($0.id) })
    }

    private func mergeLatestDictationSessions(_ sessions: [DictationSession]) {
        let latestIDs = Set(sessions.map(\.id))
        recentDictationSessions = sessions + recentDictationSessions.filter { !latestIDs.contains($0.id) }
    }

    private func fetchLiveAudioRows(
        queries: AudioTranscriptionQueries,
        limit: Int,
        offset: Int,
        includeActivityRows: Bool
    ) async throws -> [DashboardLiveAudioRow] {
        let transcriptions = try await queries.getTranscriptions(
            from: Date(timeIntervalSince1970: 0),
            to: Date(),
            source: nil,
            limit: limit,
            offset: offset,
            includeActivityRows: includeActivityRows
        )
        return liveAudioRows(from: transcriptions)
    }

    private func liveAudioRows(from transcriptions: [AudioTranscription]) -> [DashboardLiveAudioRow] {
        transcriptions.map {
            DashboardLiveAudioRow(
                id: $0.id,
                text: DashboardTranscriptDisplayPolicy.copyText($0.text),
                startedAt: $0.startTime,
                endedAt: $0.endTime,
                source: $0.source,
                confidence: $0.confidence,
                transcriptStatus: $0.transcriptStatus,
                detectedLanguage: $0.detectedLanguage,
                audioVariant: $0.audioVariant,
                qualityFlags: $0.qualityFlags,
                transcriptionPass: $0.transcriptionPass,
                batchAudioPath: $0.batchAudioPath
            )
        }
    }

    private func normalizedLiveAudioRows(_ rows: [DashboardLiveAudioRow]) -> [DashboardLiveAudioRow] {
        DashboardLiveAudioPresentationPolicy.normalizedRows(rows)
    }

    private func prepareLiveAudioSnapshot(
        for rawRows: [DashboardLiveAudioRow]
    ) async -> DashboardLiveAudioPreparedSnapshot {
        let start = CFAbsoluteTimeGetCurrent()
        let statusRowLimit = DashboardLiveMemoryPolicy.recentStatusRowLimit
        let snapshot = await Task.detached(priority: .userInitiated) {
            DashboardLiveAudioPreparedSnapshot(
                rawRows: rawRows,
                statusRowLimit: statusRowLimit
            )
        }.value

        Log.recordLatency(
            "dashboard.live.transcript_prepare_background_ms",
            valueMs: (CFAbsoluteTimeGetCurrent() - start) * 1_000,
            category: .ui,
            summaryEvery: 10,
            warningThresholdMs: 50,
            criticalThresholdMs: 150
        )
        return snapshot
    }

    private func applyLiveAudioSnapshot(_ snapshot: DashboardLiveAudioPreparedSnapshot) {
        if liveAudioRows != snapshot.transcriptRows {
            liveAudioRows = snapshot.transcriptRows
        }
        if liveAudioStatusRows != snapshot.statusRows {
            liveAudioStatusRows = snapshot.statusRows
        }
        if liveAudioTranscriptBlocks != snapshot.transcriptBlocks {
            liveAudioTranscriptBlocks = snapshot.transcriptBlocks
        }
    }

    private func appendLiveFrames(_ frames: [FrameWithVideoInfo]) {
        let existingIDs = Set(liveFrames.map(\.frame.id.value))
        liveFrames.append(contentsOf: frames.filter { !existingIDs.contains($0.frame.id.value) })
    }

    private func resolveLiveFrameAppNames(_ frames: [FrameWithVideoInfo]) async {
        let unresolvedBundleIDs = Set(frames.compactMap(\.frame.metadata.appBundleID))
            .filter { liveFrameAppNamesByBundleID[$0] == nil }
        guard !unresolvedBundleIDs.isEmpty else { return }

        let bundleIDs = Array(unresolvedBundleIDs)
        let resolved = await Task.detached(priority: .utility) {
            AppNameResolver.shared.resolveAll(bundleIDs: bundleIDs)
        }.value
        guard !Task.isCancelled else { return }

        for app in resolved {
            liveFrameAppNamesByBundleID[app.bundleID] = app.name
        }
    }

    private func mergeLatestLiveFrames(_ frames: [FrameWithVideoInfo]) {
        let retentionLimit = max(
            DashboardLiveMemoryPolicy.passiveScreenshotRetentionLimit,
            liveFrames.count
        )
        liveFrames = DashboardLiveMemoryPolicy.mergedLatest(
            frames,
            into: liveFrames,
            id: { $0.frame.id.value },
            maxCount: retentionLimit
        )
    }

    private func trimLiveFrameCaches() {
        trimLiveFrameThumbnailCache()
        trimLiveFrameOCRCache()
    }

    private func trimLiveFrameThumbnailCache() {
        let retainedIDs = DashboardLiveMemoryPolicy.retainedCacheIDs(
            preferredIDs: liveFrames.map(\.frame.id.value),
            selectedID: selectedLiveFrameID,
            maxCount: DashboardLiveMemoryPolicy.thumbnailCacheLimit
        )
        liveFrameThumbnails = liveFrameThumbnails.filter { retainedIDs.contains($0.key) }
        liveFrameThumbnailFailureCounts = liveFrameThumbnailFailureCounts.filter { retainedIDs.contains($0.key) }
        liveFramePreviewFailureCounts = liveFramePreviewFailureCounts.filter { retainedIDs.contains($0.key) }
    }

    private func trimLiveFrameOCRCache() {
        let retainedIDs = DashboardLiveMemoryPolicy.retainedCacheIDs(
            preferredIDs: liveFrames.map(\.frame.id.value),
            selectedID: selectedLiveFrameID,
            maxCount: DashboardLiveMemoryPolicy.ocrCacheLimit
        )
        liveFrameOCRNodes = liveFrameOCRNodes.filter { retainedIDs.contains($0.key) }
        liveFrameOCRLoadedStatuses = liveFrameOCRLoadedStatuses.filter { retainedIDs.contains($0.key) }
    }

    private func isRetainedLiveFrame(_ frameID: Int64) -> Bool {
        liveFrames.contains { $0.frame.id.value == frameID }
    }

    private func ensureSelectedLiveFrame() {
        if let selectedLiveFrameID,
           liveFrames.contains(where: { $0.frame.id.value == selectedLiveFrameID }) {
            if let selected = liveFrames.first(where: { $0.frame.id.value == selectedLiveFrameID }) {
                loadLiveFrameThumbnailIfNeeded(selected)
                loadLiveFrameContextIfNeeded(selected)
                loadSelectedLiveFramePreview(selected)
            }
            return
        }

        selectedLiveFrameRefresher.cancel()
        selectedLiveFrameID = liveFrames.first?.frame.id.value
        if let first = liveFrames.first {
            loadLiveFrameThumbnailIfNeeded(first)
            loadLiveFrameContextIfNeeded(first)
            loadSelectedLiveFramePreview(first)
        }
    }

    private func loadLiveFrameThumbnailIfNeeded(_ item: FrameWithVideoInfo) {
        let frame = item.frame
        let frameID = frame.id.value
        guard liveFrameThumbnails[frameID] == nil else { return }
        guard !liveFrameThumbnailLoadingIDs.contains(frameID) else { return }
        let failureCount = liveFrameThumbnailFailureCounts[frameID, default: 0]
        guard DashboardScreenshotRetryPolicy.shouldRetry(attemptCount: failureCount) else { return }

        liveFrameThumbnailLoadingIDs.insert(frameID)

        let coordinator = coordinatorWrapper.coordinator

        Task.detached(priority: .utility) {
            do {
                let cgImage = try await coordinator.getLiveFrameCGImage(frameWithInfo: item)
                let thumbnailData = Self.dashboardThumbnailPNGData(from: cgImage)

                guard let thumbnailData,
                      let image = NSImage(data: thumbnailData) else {
                    throw NSError(
                        domain: "DashboardLiveScreenshot",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Unable to create screenshot thumbnail"]
                    )
                }

                await MainActor.run {
                    if isRetainedLiveFrame(frameID) {
                        liveFrameThumbnails[frameID] = image
                        liveFrameThumbnailFailureCounts.removeValue(forKey: frameID)
                        trimLiveFrameThumbnailCache()
                    }
                    _ = liveFrameThumbnailLoadingIDs.remove(frameID)
                }
            } catch {
                await MainActor.run {
                    liveFrameThumbnailFailureCounts[frameID, default: 0] += 1
                    _ = liveFrameThumbnailLoadingIDs.remove(frameID)
                }
                Log.warning("[Dashboard] Failed to load live screenshot thumbnail \(frameID): \(error)", category: .ui)
            }
        }
    }

    private func loadSelectedLiveFramePreview(_ item: FrameWithVideoInfo, force: Bool = false) {
        let frameID = item.frame.id.value
        if !force,
           selectedLiveFramePreviewID == frameID,
           selectedLiveFramePreview != nil {
            return
        }
        guard selectedLiveFramePreviewLoadingID != frameID else { return }
        if !force {
            let failureCount = liveFramePreviewFailureCounts[frameID, default: 0]
            guard DashboardScreenshotRetryPolicy.shouldRetry(attemptCount: failureCount) else { return }
        }

        selectedLiveFramePreview = nil
        selectedLiveFramePreviewID = nil
        selectedLiveFramePreviewError = nil
        isLoadingSelectedLiveFramePreview = true
        selectedLiveFramePreviewLoadingID = frameID

        let coordinator = coordinatorWrapper.coordinator
        Task.detached(priority: .userInitiated) {
            do {
                let cgImage = try await coordinator.getLiveFrameCGImage(frameWithInfo: item)
                guard let imageData = Self.dashboardPreviewJPEGData(from: cgImage),
                      let image = NSImage(data: imageData) else {
                    throw NSError(
                        domain: "DashboardScreenshotPreview",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Unable to prepare the screenshot preview"]
                    )
                }

                await MainActor.run {
                    guard selectedLiveFrameID == frameID else { return }
                    selectedLiveFramePreview = image
                    selectedLiveFramePreviewID = frameID
                    selectedLiveFramePreviewError = nil
                    liveFramePreviewFailureCounts.removeValue(forKey: frameID)
                    isLoadingSelectedLiveFramePreview = false
                    selectedLiveFramePreviewLoadingID = nil
                }
            } catch {
                await MainActor.run {
                    guard selectedLiveFrameID == frameID else { return }
                    selectedLiveFramePreviewError = "The active capture is still being finalized. Retrace will retry automatically."
                    liveFramePreviewFailureCounts[frameID, default: 0] += 1
                    isLoadingSelectedLiveFramePreview = false
                    selectedLiveFramePreviewLoadingID = nil
                }
                Log.warning("[Dashboard] Failed to load selected screenshot preview \(frameID): \(error)", category: .ui)
            }
        }
    }

    nonisolated private static func dashboardPreviewJPEGData(from image: CGImage) -> Data? {
        let preview = downscaledCGImage(image, maxPixelDimension: 1_600) ?? image
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary
        CGImageDestinationAddImage(destination, preview, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func retryTransientLiveFrameImages() {
        for frame in liveFrames.prefix(8) {
            let frameID = frame.frame.id.value
            guard liveFrameThumbnails[frameID] == nil else { continue }
            loadLiveFrameThumbnailIfNeeded(frame)
        }

        if selectedLiveFramePreview == nil,
           selectedLiveFramePreviewError != nil,
           let selectedLiveFrame,
           DashboardScreenshotRetryPolicy.shouldRetry(
               attemptCount: liveFramePreviewFailureCounts[selectedLiveFrame.frame.id.value, default: 0]
           ) {
            loadSelectedLiveFramePreview(selectedLiveFrame, force: true)
        }
    }

    nonisolated private static func dashboardThumbnailPNGData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: DashboardLiveMemoryPolicy.thumbnailMaxPixelDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return pngData(from: thumbnail)
    }

    nonisolated private static func dashboardThumbnailPNGData(from image: CGImage) -> Data? {
        let thumbnail = downscaledCGImage(
            image,
            maxPixelDimension: DashboardLiveMemoryPolicy.thumbnailMaxPixelDimension
        ) ?? image
        return pngData(from: thumbnail)
    }

    nonisolated private static func downscaledCGImage(_ image: CGImage, maxPixelDimension: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        let largestDimension = max(width, height)
        guard largestDimension > maxPixelDimension else {
            return image
        }

        let scale = CGFloat(maxPixelDimension) / CGFloat(largestDimension)
        let targetWidth = max(1, Int((CGFloat(width) * scale).rounded()))
        let targetHeight = max(1, Int((CGFloat(height) * scale).rounded()))
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    nonisolated private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    private func loadLiveFrameContextIfNeeded(_ item: FrameWithVideoInfo) {
        let frame = item.frame
        let frameID = frame.id.value
        guard liveFrameOCRNodes[frameID] == nil else { return }
        guard !liveFrameOCRLoadingIDs.contains(frameID) else { return }

        liveFrameOCRLoadingIDs.insert(frameID)

        Task {
            do {
                let nodes = try await coordinatorWrapper.coordinator.getAllOCRNodes(
                    frameID: frame.id,
                    source: frame.source
                )
                await MainActor.run {
                    if let retained = liveFrames.first(where: { $0.frame.id == frame.id && $0.frame.source == frame.source }),
                       retained.processingStatus == item.processingStatus {
                        liveFrameOCRNodes[frameID] = nodes
                        liveFrameOCRLoadedStatuses[frameID] = item.processingStatus
                        trimLiveFrameOCRCache()
                    }
                    _ = liveFrameOCRLoadingIDs.remove(frameID)
                }
            } catch {
                await MainActor.run {
                    // A transient read failure is not a completed empty OCR result.
                    _ = liveFrameOCRLoadingIDs.remove(frameID)
                }
                Log.warning("[Dashboard] Failed to load live frame OCR \(frameID): \(error)", category: .ui)
            }
        }
    }

    private func refreshSelectedLiveFrameOCRIfCompleted() {
        guard let selectedLiveFrame else { return }
        let frameID = selectedLiveFrame.frame.id.value
        guard liveFrameOCRLoadedStatuses[frameID] != selectedLiveFrame.processingStatus else { return }

        liveFrameOCRNodes.removeValue(forKey: frameID)
        liveFrameOCRLoadedStatuses.removeValue(forKey: frameID)
        loadLiveFrameContextIfNeeded(selectedLiveFrame)
    }

    @MainActor
    private func refreshSelectedLiveFrameState() async {
        guard !Task.isCancelled,
              DashboardRefreshLoopPolicy.shouldContinue(loopTab: .screenshots, selectedTab: selectedDashboardTab, isWindowVisible: viewModel.isWindowVisible),
              let selected = selectedLiveFrame,
              selected.frame.source == .native else { return }
        let frameID = selected.frame.id.value
        let coordinator = coordinatorWrapper.coordinator
        let loadedStatus = liveFrameOCRNodes[frameID] == nil ? nil : liveFrameOCRLoadedStatuses[frameID]
        do {
            guard let snapshot = try await selectedLiveFrameRefresher.refresh(
                selected,
                loadedStatus: loadedStatus,
                loadFrame: { try await coordinator.getFrameWithVideoInfoByID(id: $0) },
                loadNodes: { try await coordinator.getAllOCRNodes(frameID: $0.frame.id, source: $0.frame.source) }
            ), !Task.isCancelled,
               DashboardRefreshLoopPolicy.shouldContinue(loopTab: .screenshots, selectedTab: selectedDashboardTab, isWindowVisible: viewModel.isWindowVisible) else { return }
            if DashboardSelectedFrameRefresher.apply(snapshot, selectedID: selectedLiveFrameID, frames: &liveFrames, nodes: &liveFrameOCRNodes, loadedStatuses: &liveFrameOCRLoadedStatuses) {
                loadLiveFrameContextIfNeeded(snapshot.frame)
                trimLiveFrameOCRCache()
            }
        } catch is CancellationError {
            return
        } catch {
            Log.warning("[Dashboard] Unable to refresh selected screenshot status: \(error)", category: .ui)
        }
    }

    private func dictationSessionPreview(_ session: DictationSession) -> String {
        let trimmedText = session.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            return trimmedText
        }
        if let errorMessage = session.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        return "No inserted text"
    }

    private func dictationStatusLabel(_ status: DictationInsertionStatus) -> String {
        switch status {
        case .capturing:
            return "Capturing"
        case .transcribing:
            return "Transcribing"
        case .inserted:
            return "Inserted"
        case .empty:
            return "Empty"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        case .blockedSecureInput:
            return "Secure input"
        case .blockedFocusChanged:
            return "Focus changed"
        }
    }

    private func dictationStatusIcon(_ status: DictationInsertionStatus) -> String {
        switch status {
        case .inserted:
            return "checkmark.circle.fill"
        case .failed, .blockedSecureInput, .blockedFocusChanged:
            return "exclamationmark.triangle.fill"
        case .empty:
            return "circle.dashed"
        case .cancelled:
            return "xmark.circle.fill"
        case .capturing:
            return "mic.circle.fill"
        case .transcribing:
            return "waveform.circle.fill"
        }
    }

    private func dictationStatusColor(_ status: DictationInsertionStatus) -> Color {
        switch status {
        case .inserted:
            return .retraceSuccess
        case .failed, .blockedSecureInput, .blockedFocusChanged:
            return .retraceWarning
        case .empty, .cancelled:
            return .retraceSecondary
        case .capturing, .transcribing:
            return .retraceAccent
        }
    }

    private var themeBorderColor: Color {
        currentTheme.controlBorderColor
    }

    /// Theme-aware base background color
    /// Gold theme uses a warmer, darker tone that complements gold better than blue
    private var themeBaseBackground: Color {
        switch currentTheme {
        case .gold:
            // Warm dark brown/slate that complements gold
            // HSL roughly: 30°, 20%, 5% - a very dark warm gray with slight brown undertone
            return Color(red: 15/255, green: 12/255, blue: 8/255)
        default:
            // Default deep blue for all other themes
            return Color.retraceBackground
        }
    }

    /// Theme-aware ambient background with subtle glow effects
    private var themeAmbientBackground: some View {
        let theme = currentTheme

        // Use custom colors for better contrast against backgrounds
        let ambientGlowColor: Color = {
            switch theme {
            case .blue:
                // Deeper blue orb: #0e2a68
                return Color(red: 14/255, green: 42/255, blue: 104/255)
            case .gold:
                // Warm amber instead of pure gold
                return Color(red: 255/255, green: 160/255, blue: 60/255)
            case .purple:
                return theme.glowColor
            }
        }()

        // Adjust opacity per theme for best visual balance
        // Blue gets moderate opacity - enough presence without being theatrical
        let glowOpacity: Double = {
            switch theme {
            case .blue: return 0.3
            case .gold: return 0.05
            case .purple: return 0.08
            }
        }()
        let edgeGlowOpacity: Double = {
            switch theme {
            case .blue: return 0.6
            case .gold: return 0.04
            case .purple: return 0.06
            }
        }()
        let cornerGlowOpacity: Double = {
            switch theme {
            case .blue: return 0.5
            case .gold: return 0.03
            case .purple: return 0.05
            }
        }()

        return GeometryReader { geometry in
            ZStack {
                // Primary accent orb (top-left) - uses theme color
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.retraceAccent.opacity(0.10), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 300
                        )
                    )
                    .frame(width: 600, height: 600)
                    .offset(x: -200, y: -100)
                    .blur(radius: 60)

                // Secondary orb (top-left) - theme glow color
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [ambientGlowColor.opacity(glowOpacity), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 250
                        )
                    )
                    .frame(width: 500, height: 500)
                    .offset(x: -150, y: -50)
                    .blur(radius: 50)

                // Top edge glow - all themes get this now
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [ambientGlowColor.opacity(edgeGlowOpacity), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .position(x: geometry.size.width / 2, y: 0)
                    .blur(radius: 30)

                // Bottom-right corner glow - all themes get this now
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [ambientGlowColor.opacity(cornerGlowOpacity), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 400
                        )
                    )
                    .frame(width: 800, height: 800)
                    .position(x: geometry.size.width, y: geometry.size.height)
                    .blur(radius: 80)
            }
        }
    }

    private var viewModeToggle: some View {
        HStack(spacing: 4) {
            ForEach(AppUsageViewMode.allCases, id: \.self) { mode in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        usageViewMode = mode
                    }
                    saveViewMode(mode)
                }) {
                    Image(systemName: mode.icon)
                        .font(.retraceCaption2Medium)
                        .foregroundColor(usageViewMode == mode ? .retracePrimary : .retraceSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(usageViewMode == mode ? Color.white.opacity(0.1) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var loadingStateView: some View {
        VStack(spacing: 16) {
            SpinnerView(size: 32, lineWidth: 3)

            Text("Loading activity...")
                .font(.retraceHeadline)
                .foregroundColor(.retraceSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.02))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeBorderColor, lineWidth: 1)
        )
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient.retraceAccentGradient.opacity(0.2))
                    .frame(width: 80, height: 80)

                Image(systemName: "clock.badge.questionmark")
                    .font(.retraceDisplay3)
                    .foregroundStyle(LinearGradient.retraceAccentGradient)
            }

            VStack(spacing: 8) {
                Text("No activity recorded yet")
                    .font(.retraceHeadline)
                    .foregroundColor(.retracePrimary)

                Text("Start using your Mac and Retrace will track your app usage automatically.")
                    .font(.retraceCallout)
                    .foregroundColor(.retraceSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .background(Color.white.opacity(0.02))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeBorderColor, lineWidth: 1)
        )
    }

    // MARK: - Formatting Helpers

    private func formatTotalTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private func formatDictationDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", max(seconds, 0))
        }
        return formatTotalTime(seconds)
    }

    private func formatDashboardTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm:ss a"
        return formatter.string(from: date)
    }

    private func formatScreenTimeFromDaily(_ data: [DailyDataPoint]) -> String {
        // Data is in milliseconds, sum and convert to hours/minutes
        let totalMs = data.reduce(0) { $0 + $1.value }
        let totalMinutes = Int(totalMs / 1000 / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

}

// MARK: - Preview

// MARK: - Scroll Affordance

/// A subtle inner shadow at the bottom of a container that suggests scrollable content continues
/// This is the Apple-favorite pattern for indicating scrollability
private struct ScrollAffordance: View {
    var height: CGFloat = 24
    var color: Color = .black

    var body: some View {
        VStack {
            Spacer()
            LinearGradient(
                colors: [
                    color.opacity(0),
                    color.opacity(0.4),
                    color.opacity(0.6)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Logo Triangle Shape

/// Triangle shape pointing right (like a play button) for the Retrace logo
private struct LogoTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Points: left-top, left-bottom, right-center
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Monitor Button (isolated to prevent parent re-renders)

/// Extracted to its own view so animation state changes don't cause DashboardView to re-render
private struct MonitorButton: View {
    let isProcessing: Bool

    @State private var heartbeatScale: CGFloat = 1.0
    @State private var isHovering = false

    var body: some View {
        Button(action: {
            NotificationCenter.default.post(name: .openSystemMonitor, object: nil)
        }) {
            ZStack {
                Image(systemName: "waveform.path.ecg")
                    .font(.retraceCalloutMedium)
                    .foregroundColor(isProcessing ? .green : .retraceSecondary)
                    .scaleEffect(isProcessing ? heartbeatScale : 1.0)
            }
            .padding(10)
            .background(Color.white.opacity(0.05))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .scaleEffect(isHovering ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .compactTopTooltip("Open System Monitor", isVisible: $isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .task(id: isProcessing) {
            // Heartbeat animation - quick expand then contract like a health monitor
            while !Task.isCancelled {
                if isProcessing {
                    // Beat 1: quick expand
                    withAnimation(.easeOut(duration: 0.1)) {
                        heartbeatScale = 1.25
                    }
                    try? await Task.sleep(for: .nanoseconds(Int64(100_000_000)), clock: .continuous)

                    // Contract back
                    withAnimation(.easeIn(duration: 0.15)) {
                        heartbeatScale = 1.05
                    }
                    try? await Task.sleep(for: .nanoseconds(Int64(150_000_000)), clock: .continuous)

                    // Beat 2: smaller secondary beat
                    withAnimation(.easeOut(duration: 0.08)) {
                        heartbeatScale = 1.15
                    }
                    try? await Task.sleep(for: .nanoseconds(Int64(80_000_000)), clock: .continuous)

                    // Contract and rest
                    withAnimation(.easeIn(duration: 0.2)) {
                        heartbeatScale = 1.05
                    }
                    try? await Task.sleep(for: .nanoseconds(Int64(600_000_000)), clock: .continuous)
                } else {
                    heartbeatScale = 1.0
                    try? await Task.sleep(for: .nanoseconds(Int64(500_000_000)), clock: .continuous)
                }
            }
        }
    }
}

// MARK: - Compact Tooltip

private struct CompactTopTooltip: ViewModifier {
    let text: String
    @Binding var isVisible: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isVisible {
                    Text(text)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.82))
                        )
                        .offset(y: -26)
                        .transition(.opacity.combined(with: .offset(y: 3)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isVisible)
    }
}

private extension View {
    func compactTopTooltip(_ text: String, isVisible: Binding<Bool>) -> some View {
        modifier(CompactTopTooltip(text: text, isVisible: isVisible))
    }
}

#if DEBUG
struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()
        let launchOnLoginManager = LaunchOnLoginReminderManager(coordinator: coordinator)

        DashboardView(
            viewModel: DashboardViewModel(coordinator: coordinator),
            coordinator: coordinator,
            launchOnLoginReminderManager: launchOnLoginManager
        )
        .frame(width: 1200, height: 900)
        .preferredColorScheme(.dark)
    }
}
#endif
