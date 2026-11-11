import AppKit
import SwiftUI
import App
import Database
import Shared

/// Shared native layout: the same inspector becomes a drawer at narrow widths.
struct UnifiedWorkspaceColumns<Content: View, Inspector: View>: View {
    let width: CGFloat
    @Binding var showsDrawer: Bool
    @ViewBuilder var content: () -> Content
    @ViewBuilder var inspector: () -> Inspector
    var onDrawerClose: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
            if !UnifiedWorkspacePolicy.usesDrawer(width: width), showsDrawer {
                Divider()
                inspector().frame(width: 350)
            }
        }
        .overlay(alignment: .trailing) {
            if UnifiedWorkspacePolicy.usesDrawer(width: width), showsDrawer {
                VStack(spacing: 0) {
                    HStack {
                        Text("Context & Intel").font(.headline)
                        Spacer()
                        Button("Close") { showsDrawer = false; onDrawerClose() }
                            .accessibilityIdentifier("workspace.drawer.close")
                    }.padding(12)
                    Divider()
                    inspector()
                }
                .frame(width: min(350, max(260, width - 80)))
                .background(.regularMaterial)
                .shadow(radius: 12)
            }
        }
    }
}

/// Lazily created by the dashboard host and retained across Settings/voice routing.
@MainActor
final class UnifiedWorkspaceSession {
    let timeline: SimpleTimelineViewModel
    let model: UnifiedWorkspaceModel
    let playback: TranscriptAudioPlayback
    let audio: WorkspaceAudioContext
    let context: LocalContextPresentationModel
    init(coordinator: AppCoordinator) {
        timeline = SimpleTimelineViewModel(coordinator: coordinator, workspace: true)
        model = UnifiedWorkspaceModel(evidence: timeline.evidence,
            latest: {
                let service = try await coordinator.progressiveRecall()
                return try await DashboardScreenshotIdentityPolicy.readRows(
                    sourceGeneration: { try await service.sourceGeneration(source: $0) }
                ) { try await coordinator.getMostRecentFramesWithVideoInfo(limit: UnifiedWorkspacePolicy.maximumRows) }
            }, search: { try await coordinator.search(query: $0, limit: 100).results },
            momentSearch: { try await coordinator.searchMoments(query: $0, limit: 100) },
            historySearch: { try await coordinator.searchHistory(query: $0, limit: 100) },
            revalidateHistorySearch: { try await coordinator.revalidateHistorySearch($0) }, track: { action in
                let metadata = "{\"action\":\"\(action)\",\"surface\":\"unified_workspace\"}"
                try? await coordinator.recordMetricEvent(metricType: .dashboardScreenshotAction, metadata: metadata)
            }, seek: { at in
                let service = try await coordinator.progressiveRecall()
                return try await DashboardScreenshotIdentityPolicy.readRows(
                    sourceGeneration: { try await service.sourceGeneration(source: $0) }
                ) {
                    async let before = coordinator.getFramesWithVideoInfoBefore(timestamp: at, limit: 1)
                    async let after = coordinator.getFramesWithVideoInfoAfter(timestamp: at, limit: 1)
                    let (older, newer) = try await (before, after)
                    return older + newer
                }
            }, bookmarkStore: WorkspaceBookmarkStore())
        playback = TranscriptAudioPlayback(resolve: { request in
            try await TranscriptAudioFileResolver.resolve(request: request, coordinator: coordinator)
        }, onEvent: { event in
            Task { try? await coordinator.recordMetricEvent(metricType: .audioTranscriptPlayback, metadata: event.metadata) }
        })
        audio = WorkspaceAudioContext(playback: playback, query: { at in
            guard let queries = await coordinator.getAudioTranscriptionQueries() else { return [] }
            return try await queries.getTranscriptions(from: at.addingTimeInterval(-120),
                to: at.addingTimeInterval(120), limit: 50)
        })
        context = LocalContextPresentationModel(load: { try await coordinator.localContext($0) })
        connectInvalidation()
    }

#if DEBUG
    /// Supplied owners keep the actual view on an authored store. This does not
    /// initialize a coordinator or replace the production evidence paths.
    init(visualFixtureTimeline: SimpleTimelineViewModel, model: UnifiedWorkspaceModel,
         playback: TranscriptAudioPlayback, audio: WorkspaceAudioContext) {
        timeline = visualFixtureTimeline; self.model = model
        self.playback = playback; self.audio = audio
        context = LocalContextPresentationModel(load: { _ in throw LocalContextError.unavailableEvidence })
        connectInvalidation()
    }
#endif

    private func connectInvalidation() {
        model.onSelectionInvalidated = { [weak audio, weak timeline, weak context] in
            context?.clear(); audio?.clear(); timeline?.invalidateWorkspaceTape()
        }
        model.onSourceInvalidated = { [weak timeline, weak context] in context?.clear(); timeline?.invalidateWorkspaceTape() }
        model.onContextInvalidated = { [weak timeline, weak context] in context?.clearPresentation(); timeline?.invalidateWorkspaceTape() }
    }

}

struct UnifiedWorkspaceView: View {
    let coordinator: AppCoordinator
    let openSettings: () -> Void
    let openVoice: () -> Void
    private let backgroundEffects: Bool
    private let notifications: NotificationCenter
    private let settingsStore: UserDefaults
    private let recordAction: (String) -> Void
    @ObservedObject var dashboard: DashboardViewModel
    @ObservedObject private var timeline: SimpleTimelineViewModel
    @ObservedObject private var model: UnifiedWorkspaceModel
    @StateObject private var intel: FuseIntelViewModel
    @ObservedObject private var playback: TranscriptAudioPlayback
    @ObservedObject private var audio: WorkspaceAudioContext
    @ObservedObject private var localContext: LocalContextPresentationModel
    @AppStorage private var localTopicsEnabled: Bool
    @State private var query = ""
    @State private var showsInspector = false
    @State private var windowVisible = true
    @State private var captureSummary: String?
    @State private var hasCaptureGap = false
    @State private var transcriptionSummary = "Transcription freshness unavailable"
    @State private var semanticSummary = "Meaning search off"
    @StateObject private var meetingStatus = MeetingStatusModel()
    @State private var meaningSearchEnabled = false
    @State private var intelPresentation = FuseIntelPresentationSnapshot.empty
    @State private var selectedInspector = "Text"
    @State private var timeScale: WorkspaceTimeScale = .hour
    @State private var timeCentre = Date()
    @State private var timeOffset: Double = 0
    @State private var searchMarkerIndices: [Int] = []
    @State private var timeSeekTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    @AppStorage private var scrollOrientation: String

    init(coordinator: AppCoordinator, dashboard: DashboardViewModel, session: UnifiedWorkspaceSession,
         openSettings: @escaping () -> Void, openVoice: @escaping () -> Void) {
        self.coordinator = coordinator; self.dashboard = dashboard
        self.openSettings = openSettings; self.openVoice = openVoice
        timeline = session.timeline; model = session.model; playback = session.playback; audio = session.audio; localContext = session.context
        backgroundEffects = true; notifications = .default
        settingsStore = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        _localTopicsEnabled = AppStorage(wrappedValue: false, LocalContextSettings.foundationModelsKey, store: settingsStore)
        _scrollOrientation = AppStorage(wrappedValue: "horizontal", "timelineScrollOrientation", store: settingsStore)
        _intel = StateObject(wrappedValue: FuseIntelViewModel())
        recordAction = { action in
            DashboardViewModel.recordDashboardScreenshotAction(coordinator: coordinator, action: action,
                frameID: nil, source: nil, queryLength: nil)
        }
    }

#if DEBUG
    /// Opt-in native fixtures retain the real view/selection/tape and supply
    /// private state. Production polling, external routes and global observers
    /// are absent. Normal initialization above retains its existing behavior.
    init(coordinator: AppCoordinator, dashboard: DashboardViewModel, session: UnifiedWorkspaceSession,
         fixtureDefaults: UserDefaults, fixtureNotifications: NotificationCenter,
         fixtureIntel: FuseIntelViewModel, fixtureMetric: @escaping (String) -> Void) {
        self.coordinator = coordinator; self.dashboard = dashboard
        openSettings = {}; openVoice = {}
        timeline = session.timeline; model = session.model; playback = session.playback; audio = session.audio; localContext = session.context
        backgroundEffects = false; notifications = fixtureNotifications; settingsStore = fixtureDefaults
        recordAction = fixtureMetric
        _localTopicsEnabled = AppStorage(wrappedValue: false, LocalContextSettings.foundationModelsKey, store: fixtureDefaults)
        _scrollOrientation = AppStorage(wrappedValue: "horizontal", "timelineScrollOrientation", store: fixtureDefaults)
        _intel = StateObject(wrappedValue: fixtureIntel)
        _captureSummary = State(initialValue: "Authored fixture · capture disabled")
        _transcriptionSummary = State(initialValue: "No audio in this fixture")
    }
#endif

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            freshness
            if let message = captureSummary {
                Label(message, systemImage: hasCaptureGap ? "exclamationmark.triangle" : "info.circle")
                    .font(.caption).foregroundStyle(hasCaptureGap ? Color.orange : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 8)
            }
            Divider()
            GeometryReader { geometry in
                UnifiedWorkspaceColumns(width: geometry.size.width, showsDrawer: $showsInspector,
                    content: { mainContent(width: geometry.size.width) }, inspector: { inspector },
                    onDrawerClose: { metric("workspace_inspector_closed") })
                    .onAppear { showsInspector = !UnifiedWorkspacePolicy.usesDrawer(width: geometry.size.width) }
                    .onChange(of: UnifiedWorkspacePolicy.usesDrawer(width: geometry.size.width)) { narrow in showsInspector = !narrow }
            }
        }
        .background(Color.retraceBackground)
        .task(id: windowVisible) {
            guard windowVisible else { return }
            model.reopen(); dashboard.isWindowVisible = backgroundEffects
            timeline.handleTimelineOpened()
            timeline.workspaceFrameSelection = { frame in Task { await select(frame) } }
            metric("workspace_opened")
            if !backgroundEffects {
                await model.refresh()
                guard !Task.isCancelled else { return }
                await timeline.anchorWorkspaceEvidence()
                await updateIntelPresentation()
                refreshLocalContext()
                return
            }
            while !Task.isCancelled, windowVisible {
                let began = CFAbsoluteTimeGetCurrent()
                await model.refresh()
                guard !Task.isCancelled else { return }
                await timeline.anchorWorkspaceEvidence()
                let health = await coordinator.getCaptureHealth()
                guard !Task.isCancelled else { return }
                captureSummary = health.summary; hasCaptureGap = health.hasGap
                await refreshTranscriptionFreshness()
                let localSearch = await coordinator.localRecallSnapshot()
                guard !Task.isCancelled, windowVisible else { return }
                semanticSummary = localSearch.summary
                meaningSearchEnabled = localSearch.modelPackageURL != nil
                let meeting = await coordinator.meetingHealth()
                guard !Task.isCancelled, windowVisible else { return }
                meetingStatus.update(meeting)
                await intel.refresh()
                await updateIntelPresentation()
                refreshLocalContext()
                Log.recordLatency("workspace.refresh", valueMs: (CFAbsoluteTimeGetCurrent() - began) * 1_000, category: .ui)
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        .task(id: model.selectionAdmission) { _ = await loadAudio() }
        .task(id: model.searchResults.map(\.sourceQualifiedID)) { await updateMarkers() }
        .task(id: LocalContextPresentationKey(reference: model.presentedReference,
            modelEnabled: localTopicsEnabled, visible: windowVisible)) {
            refreshLocalContext()
        }
        .onChange(of: timeline.appBlockSnapshotRevision) { _ in Task { await updateMarkers() } }
        .onChange(of: model.presentedReference) { _ in
            if let at = model.selectedTimestamp { timeCentre = at; timeOffset = 0 }
        }
        .onDisappear { close() }
        .onReceive(notifications.publisher(for: .dashboardDidClose)) { _ in windowVisible = false; close() }
        .onReceive(notifications.publisher(for: .dashboardDidOpen)) { _ in windowVisible = true }
        .onReceive(notifications.publisher(for: .dataSourceDidChange)) { _ in
            model.sourceDidChange(); searchMarkerIndices = []
            Task { await model.refresh() }
        }
        .background(Button("") { searchFocused = true }.keyboardShortcut("k", modifiers: .command).hidden())
        .background(Button("") { Task { await model.goBack(); await anchor() } }.keyboardShortcut("[", modifiers: .command).hidden())
        .background(Button("") { Task { await model.goForward(); await anchor() } }.keyboardShortcut("]", modifiers: .command).hidden())
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Button { Task { await model.goBack(); await anchor() } } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack).accessibilityLabel("Previous selection")
                Button { Task { await model.goForward(); await anchor() } } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward).accessibilityLabel("Next selection")
            }
            Picker("View", selection: Binding(get: { model.mode }, set: { mode in
                Task {
                    if mode == .now { await model.returnToNow() } else { await model.showHistory() }
                    await anchor()
                }
            })) {
                ForEach(UnifiedWorkspaceModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(width: 145)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(meaningSearchEnabled ? "Find a recorded moment" : "Search recorded text", text: $query).focused($searchFocused)
                    .textFieldStyle(.plain).onSubmit { Task { await model.submitSearch(query) } }
                    .accessibilityIdentifier("workspace.search")
                if model.isSearching {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancelSearch() }
                        .accessibilityIdentifier("workspace.search.cancel")
                } else if !query.isEmpty {
                    Button { query = ""; Task { await model.submitSearch("") } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                        .accessibilityIdentifier("workspace.search.clear")
                }
            }.padding(8).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            Menu {
                if model.bookmarks.isEmpty { Text("No saved moments") }
                ForEach(model.bookmarks) { bookmark in
                    Menu(bookmark.capturedAt.formatted(date: .abbreviated, time: .standard)) {
                        Button("Open saved moment") { Task { await model.openBookmark(bookmark); await anchor() } }
                        Button("Remove bookmark") { Task { await model.removeBookmark(bookmark.id) } }
                    }
                }
            } label: { Image(systemName: "book") }.menuStyle(.borderlessButton).frame(width: 24)
            Menu {
                Button("Settings", action: openSettings)
                Button("Voice & dictation", action: openVoice)
                Button("Open fullscreen timeline") {
                    guard backgroundEffects else { metric("fixture_external_route_suppressed"); return }
                    metric("workspace_fullscreen_opened")
                    if let reference = model.evidence.evidenceReference {
                        Task { await TimelineWindowController.shared.openEvidence(reference, coordinator: coordinator) }
                    }
                    else { TimelineWindowController.shared.show() }
                }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24)
            Button { showsInspector.toggle(); metric("workspace_inspector_toggled") } label: { Image(systemName: "sidebar.right") }
                .accessibilityLabel("Context and Intel")
                .accessibilityIdentifier("workspace.inspector.toggle")
        }.padding(.horizontal, 18).padding(.top, 34).padding(.bottom, 14)
    }

    private var freshness: some View {
        HStack(spacing: 16) {
            Label(dashboard.isRecording ? "Recording" : "Recording paused", systemImage: dashboard.isRecording ? "record.circle" : "pause.circle")
            Text("OCR: \(dashboard.ocrIsPaused ? "paused · " : "")\(dashboard.ocrQueueDepth) queued")
            Text(transcriptionSummary).lineLimit(1)
            Spacer(minLength: 0)
            Text(semanticSummary).lineLimit(1)
                .help("Recording, OCR, transcripts and the optional local meaning index have separate readiness.")
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 10)
    }

    private func mainContent(width: CGFloat) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text(model.mode == .now ? "Latest recorded moment" : "Selected moment").font(.headline)
                if let at = model.selectedTimestamp { Text(at.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let display = model.evidence.selectedFrame?.metadata.displayID, display != 0 {
                    Text("Display \(display)").font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await model.toggleBookmark() } } label: {
                    Image(systemName: model.isBookmarked ? "bookmark.fill" : "bookmark")
                }.disabled(model.presentedReference == nil).accessibilityLabel(model.isBookmarked ? "Remove bookmark" : "Bookmark this moment")
                    .accessibilityIdentifier("workspace.bookmark")
                if model.mode == .history {
                    Button("Return to now") { Task { await model.returnToNow(); await anchor() } }
                        .accessibilityIdentifier("workspace.returnNow")
                }
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.secondary).font(.callout) }
            if !query.isEmpty {
                WorkspaceSearchProgress(model: model, evidence: model.evidence)
                searchResults.frame(maxHeight: 180)
            }
            CaptureGroupStrip(coordinator: coordinator, model: model) { reference in
                await model.selectEvidence(.screen(reference))
                await anchor()
                metric("workspace_display_selected")
            }
            WorkspaceEvidenceCanvas(model: model.evidence)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button { timeline.navigateToFrame(timeline.currentIndex - 1) } label: { Image(systemName: "backward.frame") }
                    .accessibilityLabel("Previous recorded frame")
                Button { timeline.navigateToFrame(timeline.currentIndex + 1) } label: { Image(systemName: "forward.frame") }
                    .accessibilityLabel("Next recorded frame")
                Text("Recorded changes").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Time range", selection: $timeScale) {
                    ForEach(WorkspaceTimeScale.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 220)
                    .onChange(of: timeScale) { scale in timeline.zoomLevel = scale.tapeZoom; metric("workspace_time_scale_changed") }
            }
            VStack(spacing: 2) {
                Slider(value: $timeOffset, in: -0.5...0.5, onEditingChanged: { editing in
                    guard !editing else { return }
                    let target = min(Date(), timeCentre.addingTimeInterval(timeOffset * timeScale.interval))
                    timeSeekTask?.cancel()
                    timeSeekTask = Task { await model.selectTimestamp(target); await anchor() }
                }).accessibilityLabel("Navigate to a time in the selected \(timeScale.rawValue.lowercased())")
                HStack {
                    Text(timeCentre.addingTimeInterval(-timeScale.interval / 2).formatted(date: .abbreviated, time: .shortened))
                    Spacer()
                    Text(timeCentre.addingTimeInterval(timeScale.interval / 2).formatted(date: .abbreviated, time: .shortened))
                }.font(.caption2).foregroundStyle(.secondary)
            }
            GeometryReader { tape in
                TimelineTapeView(viewModel: timeline, width: tape.size.width, coordinator: coordinator,
                    showsControls: false, searchMarkerIndices: searchMarkerIndices, settingsStore: settingsStore)
                    .frame(maxHeight: .infinity)
                    .background(WorkspaceTapeScrollCapture(horizontal: scrollOrientation != "vertical") { delta, precise in
                        guard windowVisible else { return }
                        Task { await timeline.handleScroll(delta: delta, isTrackpad: precise) }
                    })
                    .focusable()
                    .onKeyPress(.leftArrow) { timeline.navigateToFrame(timeline.currentIndex - 1); return .handled }
                    .onKeyPress(.rightArrow) { timeline.navigateToFrame(timeline.currentIndex + 1); return .handled }
                    .accessibilityLabel("Recorded timeline. Use left and right arrows to select a frame.")
            }.frame(height: 90).clipped()
            if !searchMarkerIndices.isEmpty { Label("Search matches", systemImage: "circle.fill").font(.caption2).foregroundStyle(.orange) }
        }.padding(18)
    }

    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if model.searchResults.isEmpty, model.historySearchResults.isEmpty, !model.isSearching {
                    Text(model.hasSearched ? "No matching moments in the searched history." : "Press Return to search your recorded history.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.searchNeedsRefresh {
                    Text("History changed. Search again for current results and coverage.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("workspace.search.needsRefresh")
                }
                if let coverage = model.momentCoverage {
                    WorkspaceSearchCoverage(coverage: coverage)
                }
                if let coverage = model.historySearchCoverage {
                    WorkspaceHistorySearchCoverage(coverage: coverage)
                }
                if !model.historySearchResults.isEmpty {
                    ForEach(model.historySearchResults) { hit in
                        Button {
                            Task { await model.selectHistoryHit(hit); await anchor() }
                        } label: {
                            WorkspaceHistoryResultLabel(hit: hit)
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("workspace.historyResult.\(hit.id)")
                    }
                } else {
                    legacySearchRows
                }
            }
        }
    }

    private var legacySearchRows: some View {
        ForEach(model.searchResults, id: \.sourceQualifiedID) { result in
                    Button {
                        Task { await model.select(result); await anchor() }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.metadata.appName ?? result.source.displayName).font(.caption.bold())
                            Text(result.snippet).font(.callout).lineLimit(2)
                            if let explanation = result.matchExplanation {
                                WorkspaceMatchExplanation(explanation: explanation)
                            }
                            Text(result.timestamp.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("workspace.result.\(result.sourceQualifiedID)")
        }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $selectedInspector) {
                Text("Text").tag("Text"); Text("Audio").tag("Audio"); Text("Intel").tag("Intel")
            }.pickerStyle(.segmented).padding(12)
                .accessibilityIdentifier("workspace.inspector.tabs")
                .onChange(of: selectedInspector) { _ in metric("workspace_inspector_selected") }
            if selectedInspector == "Text" {
                ExactEvidenceView(model: model.evidence, showsImage: false, showsClose: false,
                    onOpenEvidence: { reference in await model.selectEvidence(reference); await anchor() })
            } else if selectedInspector == "Audio", case .audio = model.presentedReference {
                VStack(alignment: .leading, spacing: 12) {
                    ExactEvidenceView(model: model.evidence, showsImage: false, showsClose: false)
                    Text("Playback is not available for this exact transcript yet.")
                        .font(.caption).foregroundStyle(.secondary).padding(12)
                }
            } else if selectedInspector == "Audio" {
                TranscriptContentView(transcriptions: audio.transcriptions,
                    timestamp: model.selectedTimestamp ?? Date(), playback: playback,
                    onReveal: { request in
                        guard backgroundEffects else { metric("fixture_external_route_suppressed"); return }
                        Task {
                            let root = await coordinator.getAudioStorageDirectory()
                            if let url = try? await TranscriptAudioFileResolver.resolveURL(request: request, storageRoot: root) {
                                NSWorkspace.shared.activateFileViewerSelecting([url]); metric("workspace_audio_revealed")
                            }
                        }
                    }, onClose: { selectedInspector = "Text"; playback.stop(reason: .closed) },
                    onSelect: { transcription in
                        await model.selectTranscript(at: transcription.startTime, anchor: { await anchor() },
                            loadAudio: { admission in
                                guard await audio.load(for: admission, model: model) else { return false }
                                return audio.transcriptions.contains { $0.id == transcription.id }
                            }, play: { admission in
                                await playback.playFromStart(TranscriptAudioRequest(transcription: transcription),
                                    isAdmitted: { model.admits(admission) })
                            })
                    })
            } else { intelPanel }
        }
    }

    private var intelPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Intel").font(.headline)
                LocalContextCards(model: localContext, onOpen: { reference in
                    await model.selectEvidence(reference); await anchor()
                })
                Divider()
                Text(meetingStatus.summary).font(.caption).foregroundStyle(.secondary)
                    .help("Possible means app presence only. Supported needs current call controls and input activity from the same app.")
                Text(intel.errorMessage == nil && intel.isConnected ? "FuseIntel · read only" : "FuseIntel · unavailable or stale")
                    .font(.caption).foregroundStyle(.secondary)
                if let date = intel.freshnessDate {
                    Text("Source updated \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(intelPresentation.nowItems.prefix(5))) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.subheadline.bold())
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(item.sourceRefs.enumerated()), id: \.offset) { _, source in
                            Text(source.citation ?? source.source).font(.caption2).textSelection(.enabled)
                        }
                    }
                    Divider()
                }
                if intelPresentation.nowItems.isEmpty { Text("No current suggestions from the connected source.").foregroundStyle(.secondary).font(.callout) }
            }.padding(16)
        }
    }

    private func select(_ frame: WorkspaceTapeSelection) async {
        guard windowVisible else { return }
        playback.stop(reason: .selectionChanged)
        await model.selectTimelineFrame(frame)
        await anchor()
    }
    private func anchor() async {
        guard windowVisible, !Task.isCancelled else { return }
        playback.stop(reason: .selectionChanged)
        await timeline.anchorWorkspaceEvidence()
    }
    private func loadAudio() async -> Bool {
        guard windowVisible, let admission = model.selectionAdmission else { audio.clear(); return false }
        return await audio.load(for: admission, model: model)
    }
    private func refreshTranscriptionFreshness() async {
        guard let queries = await coordinator.getAudioTranscriptionQueries() else {
            transcriptionSummary = "Transcription unavailable"; return
        }
        do {
            let now = Date()
            let latest = try await queries.getTranscriptions(from: now.addingTimeInterval(-86_400), to: now, limit: 1)
            guard !Task.isCancelled, windowVisible else { return }
            transcriptionSummary = latest.first.map { "Transcript latest \($0.endTime.formatted(date: .omitted, time: .shortened))" }
                ?? "No transcript in the last day"
        } catch {
            guard !Task.isCancelled, windowVisible else { return }
            transcriptionSummary = "Transcription freshness unavailable"
        }
    }
    private func updateIntelPresentation() async {
        let command = intel.command, feed = intel.feed
        let context = model.evidence.selectedFrame?.metadata.windowName ?? ""
        let presentation = await Task.detached(priority: .utility) {
            FuseIntelPresentationSnapshotPolicy.make(command: command, feed: feed, contextText: context)
        }.value
        guard !Task.isCancelled, windowVisible else { return }
        intelPresentation = presentation
    }
    private func refreshLocalContext() {
        guard backgroundEffects, windowVisible, !Task.isCancelled,
              let reference = model.presentedReference else { localContext.clear(); return }
        let request: LocalContextRequest
        switch reference {
        case .screen(let screen) where screen.source == .native:
            request = .init(screenReferences: [screen], foundationModelsEnabled: localTopicsEnabled)
        case .activity(let activity) where activity.source == .native:
            request = .init(activityReferences: [activity], foundationModelsEnabled: localTopicsEnabled)
        default: localContext.clear(); return
        }
        localContext.requestRefresh(request)
    }

    private func close() {
        localContext.clear()
        meetingStatus.close()
        dashboard.isWindowVisible = false
        timeSeekTask?.cancel(); timeSeekTask = nil
        model.close(); playback.stop(reason: .closed)
        timeline.workspaceFrameSelection = nil
        timeline.stopPeriodicStatusRefresh(); timeline.stopPlayback(); timeline.handleTimelineClosed()
    }

    private func updateMarkers() async {
        let frames = timeline.frames.map(\.frame)
        let hits = model.searchResults
        let markers = await Task.detached(priority: .utility) {
            let identities = Set(hits.map { hit in
                ScreenshotEvidenceSelection(FrameReference(id: hit.id, timestamp: hit.timestamp, segmentID: hit.segmentID,
                    frameIndexInSegment: hit.frameIndex, metadata: hit.metadata, source: hit.source))
            })
            return frames.indices.filter { identities.contains(frames[$0].screenshotIdentity) }
        }.value
        guard !Task.isCancelled, windowVisible,
              frames == timeline.frames.map(\.frame), hits.map(\.sourceQualifiedID) == model.searchResults.map(\.sourceQualifiedID) else { return }
        searchMarkerIndices = markers
    }
    private func metric(_ action: String) {
        recordAction(action)
    }
}

private struct WorkspaceTapeScrollCapture: NSViewRepresentable {
    let horizontal: Bool
    let onScroll: (CGFloat, Bool) -> Void
    func makeNSView(context: Context) -> WorkspaceTapeScrollSurface { WorkspaceTapeScrollSurface() }
    func updateNSView(_ view: WorkspaceTapeScrollSurface, context: Context) {
        view.horizontal = horizontal; view.onScroll = onScroll
    }
    static func dismantleNSView(_ view: WorkspaceTapeScrollSurface, coordinator: ()) { view.stopMonitoring() }
}

@MainActor
private final class WorkspaceTapeScrollSurface: NSView {
    var horizontal = true
    var onScroll: ((CGFloat, Bool) -> Void)?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, let window = self.window, window.isVisible, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return false }
                let delta = self.horizontal ? -event.scrollingDeltaX : -event.scrollingDeltaY
                guard delta != 0 else { return false }
                self.onScroll?(delta, event.hasPreciseScrollingDeltas)
                return true
            }
            return consumed ? nil : event
        }
    }
    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

private struct WorkspaceSearchProgress: View {
    @ObservedObject var model: UnifiedWorkspaceModel
    @ObservedObject var evidence: EvidenceViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var checking: Bool { model.isCheckingSearchEvidence || evidence.resolvingEvidence }
    private var working: Bool { model.isSearching || checking }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .symbolEffect(.pulse, options: .repeating, isActive: working && !reduceMotion)
            Text(checking ? "Checking evidence" : (model.isSearching ? "Finding moments" : (model.hasSearched ? "Ready" : "Search your history")))
            Spacer()
        }.font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
    }
}

private struct WorkspaceEvidenceCanvas: View {
    @ObservedObject var model: EvidenceViewModel
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.3))
            if case .screen(let snapshot, let image) = model.resolution {
                ExactEvidenceImage(snapshot: snapshot, image: image).padding(8)
            } else if model.hasAdmittedEvidence, model.selectedFrame == nil {
                ExactEvidenceView(model: model, showsImage: false, showsClose: false)
            } else if model.resolvingEvidence { ProgressView("Opening recorded moment…") }
            else {
                Text(model.isPresentingEvidence ? "The exact image is unavailable. Recorded text and context may still be available in the inspector." : "No recorded moment selected.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24)
            }
        }
    }
}

/// Typed result rows retain their own source and exact supporting excerpt.
private struct WorkspaceHistoryResultLabel: View {
    let hit: HistorySearchHit
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch hit {
            case .screen(let screen):
                Label(screen.result.metadata.appName ?? screen.result.source.displayName, systemImage: "display")
                    .font(.caption.bold())
                Text(screen.excerpt.text).font(.callout).lineLimit(2)
                if let explanation = screen.result.matchExplanation {
                    WorkspaceMatchExplanation(explanation: explanation)
                }
            case .audio(let audio):
                Label("Transcript · \(audio.snapshot.recordingSource.displayName)", systemImage: "waveform")
                    .font(.caption.bold())
                Text(audio.excerpt.text).font(.callout).lineLimit(2)
                Text("Matching transcript text").font(.caption2).foregroundStyle(.secondary)
            }
            Text(hit.timestamp.formatted(date: .abbreviated, time: .standard))
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

private struct WorkspaceHistorySearchCoverage: View {
    let coverage: HistorySearchCoverage
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !coverage.screenCandidateScanComplete {
                Text("Screen search checked a limited set of matching moments.")
            }
            if coverage.unavailableScreenHits > 0 {
                Text("Some matching screens are unavailable and were omitted.")
            }
            Text(audioSummary)
            if let audio = coverage.audio {
                if !audio.bootstrap.complete {
                    Text("Older transcripts have not all been prepared for search.")
                }
                if !audio.scanComplete {
                    Text("Transcript search checked a limited part of the available history.")
                }
                if audio.unprovenLineageRows > 0 || audio.unavailableQualityRows > 0 {
                    Text("Some recordings could not provide usable transcript evidence.")
                }
            }
            if coverage.screenHitsOmittedByLimit + coverage.audioHitsOmittedByLimit > 0 {
                Text("More matching moments are available; narrow the search to see them.")
            }
        }.font(.caption2).foregroundStyle(.secondary)
            .accessibilityIdentifier("workspace.search.transcriptCoverage")
    }
    private var audioSummary: String {
        switch coverage.audioState {
        case .searched: return "Transcripts searched by text."
        case .notConfigured: return "Transcript search is unavailable for this history source."
        case .unsupportedQuerySyntax: return "Transcript search supports plain words here; these search operators apply to screens."
        case .queryExceedsAudioLimits: return "This query exceeds the transcript search limit; shorten it to include transcripts."
        case .unavailable(let reason):
            switch reason {
            case .unsupportedApplicationScope, .unsupportedWindowScope, .unsupportedURLScope,
                 .unsupportedTagScope, .unsupportedCommentScope, .unsupportedHiddenScope, .unsupportedDateScope:
                return "Transcripts cannot be matched to these filters and are omitted from this search."
            default: return "Transcript evidence is unavailable for this search."
            }
        }
    }
}
