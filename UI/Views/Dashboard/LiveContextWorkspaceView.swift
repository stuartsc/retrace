import App
import AppKit
import Database
import Shared
import SwiftUI

/// Local saved evidence only. Appearing starts bounded readers, never a model,
/// transcription request, remote client or playback.
struct LiveContextWorkspaceView: View {
    let isActive: Bool
    let isRecording: Bool
    private let validateScreenReference: @Sendable (ScreenEvidenceRef) async -> Bool
    private let openEvidence: @MainActor (EvidenceRef) -> Void
    private let openMarker: @MainActor (TimelineMarker) async throws -> Void
    private let openVoiceMarkerSettings: @MainActor () -> Void
    private let contextService: @Sendable () async throws -> LiveContextSearchService
    @StateObject private var model: LiveContextWorkspaceModel
    @StateObject private var evidence: EvidenceViewModel
    @StateObject private var playback: TranscriptAudioPlayback
    @StateObject private var markers: TimelineMarkersViewModel
    @StateObject private var voice: VoiceMarkerStatusModel
    @StateObject private var search: LiveContextSearchModel
    @StateObject private var companion: CompanionWorkspaceModel
    @State private var presenter = DashboardScreenshotEvidencePresenter()
    @State private var completedScreen: ScreenshotEvidenceSelection?
    @State private var compactPane = "Transcript"
    @State private var screenPane = "Screenshot"
    @State private var splitRatio: CGFloat = 0.6
    @State private var dragStartRatio: CGFloat?
    @State private var visibleTranscriptID: String?
    @State private var selectedRange: LiveContextRange = .history
    @State private var showingSearchDates = false
    @State private var customFrom = Date().addingTimeInterval(-1_800)
    @State private var customTo = Date()
    @State private var searchText = ""
    @State private var copyPreview: String?
    @State private var copyQuestion = ""
    @State private var copyRows: [AudioTranscription] = []
    @State private var copyScreen: ScreenEvidenceSnapshot?
    @State private var copyReferences: [LiveContextReference] = []
    @State private var copyInterval: DateInterval?
    @State private var copyPartial = false
    @State private var copyBudgetNotice: String?
    @State private var searchAudio: AudioTranscription?
    @State private var showingSpeakers = false
    @State private var selectedSpeaker: CompanionSpeakerPresentation?
    @State private var actionMessage: String?
    @State private var actionTask: Task<Void, Never>?
    @State private var actionID: UUID?
    @State private var showingMarkers = false

    init(coordinator: AppCoordinator, isActive: Bool, isRecording: Bool, initialInterval: DateInterval? = nil) {
        self.isActive = isActive
        self.isRecording = isRecording
        contextService = { try await coordinator.liveContextSearch() }
        _search = StateObject(wrappedValue: LiveContextSearchModel(service: { try await coordinator.liveContextSearch() },
            rangePresentations: { try await coordinator.contextRanges() }))
        _companion = StateObject(wrappedValue: CompanionWorkspaceModel(service: { try await coordinator.companion() },
            playbackService: { try await coordinator.companionTurnPlayback() }))
        validateScreenReference = { reference in
            guard let service = try? await coordinator.progressiveRecall(),
                  let retained = await service.retainedScreen(reference, for: .localUser) else { return false }
            return retained.ref == reference && !Task.isCancelled
        }
        openEvidence = { reference in
            Task { await TimelineWindowController.shared.openEvidence(reference, coordinator: coordinator) }
        }
        openMarker = { marker in
            try await MarkerContextWindowController.shared.open(markerID: marker.id, expectedRevision: marker.revision, coordinator: coordinator)
        }
        openVoiceMarkerSettings = { DashboardWindowController.shared.showVoiceMarkerSettings() }
        let workspace = LiveContextWorkspaceModel(coordinator: coordinator)
        if let initialInterval {
            workspace.configure(range: .custom, from: initialInterval.start, to: initialInterval.end, query: "")
            _selectedRange = State(initialValue: .custom)
            _customFrom = State(initialValue: initialInterval.start)
            _customTo = State(initialValue: initialInterval.end)
        }
        _model = StateObject(wrappedValue: workspace)
        _markers = StateObject(wrappedValue: TimelineMarkersViewModel(service: { try await coordinator.timelineMarkers() }))
        _voice = StateObject(wrappedValue: VoiceMarkerStatusModel(coordinator: coordinator))
        _evidence = StateObject(wrappedValue: EvidenceViewModel(client: .live(service: {
            try await coordinator.progressiveRecall()
        })))
        _playback = StateObject(wrappedValue: TranscriptAudioPlayback(resolve: { request in
            guard let queries = await coordinator.getAudioTranscriptionQueries(),
                  let current = try await queries.getContextEntry(id: request.id),
                  TranscriptAudioRequest(transcription: current) == request else {
                throw TranscriptAudioError.unavailable
            }
            try Task.checkCancellation()
            let root = await coordinator.getAudioStorageDirectory()
            return try await TranscriptAudioFileResolver.resolve(request: request, storageRoot: root)
        }, onEvent: { event in
            Task { try? await coordinator.recordMetricEvent(metricType: .audioTranscriptPlayback, metadata: event.metadata) }
        }))
    }

    /// Native authored fixtures inject the same production view and owners
    /// without initializing devices or opening the installed recording store.
    init(model: LiveContextWorkspaceModel, evidence: EvidenceViewModel, playback: TranscriptAudioPlayback,
         isActive: Bool, isRecording: Bool,
         validateScreen: @escaping @Sendable (ScreenEvidenceRef) async -> Bool,
         openEvidence: @escaping @MainActor (EvidenceRef) -> Void,
         markers: TimelineMarkersViewModel? = nil, voice: VoiceMarkerStatusModel? = nil,
         companion: CompanionWorkspaceModel? = nil,
         search: LiveContextSearchModel? = nil,
         openVoiceMarkerSettings: @escaping @MainActor () -> Void = { DashboardWindowController.shared.showVoiceMarkerSettings() }) {
        self.isActive = isActive
        self.isRecording = isRecording
        self.validateScreenReference = validateScreen
        self.openEvidence = openEvidence
        self.openMarker = { _ in throw ContextStoreError.notInitialized }
        self.openVoiceMarkerSettings = openVoiceMarkerSettings
        contextService = { throw ContextStoreError.notInitialized }
        _search = StateObject(wrappedValue: search ?? LiveContextSearchModel(service: { throw ContextStoreError.notInitialized },
            rangePresentations: { throw ContextStoreError.notInitialized }))
        _companion = StateObject(wrappedValue: companion ?? CompanionWorkspaceModel(service: { throw ContextStoreError.notInitialized }))
        _model = StateObject(wrappedValue: model)
        _evidence = StateObject(wrappedValue: evidence)
        _playback = StateObject(wrappedValue: playback)
        _markers = StateObject(wrappedValue: markers ?? TimelineMarkersViewModel(service: { throw ContextStoreError.notInitialized }))
        _voice = StateObject(wrappedValue: voice ?? VoiceMarkerStatusModel(readStatus: { VoiceMarkerStatus() }))
    }

    private var canPresentEvidence: Bool { isActive && model.presentationReady }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 12) {
                controls
                statusStrip
                if let marker = voice.acknowledgedMarker {
                    HStack(spacing: 8) {
                        Image(systemName: "bookmark.fill").foregroundStyle(Color.retraceAccent)
                        Text("Voice marker saved: \(marker.title)")
                        Text(marker.spokenObservation?.status == .provisional ? "Provisional phrase" : "Confirmed phrase")
                            .foregroundStyle(.secondary)
                        if let date = voice.status?.lastAcknowledgedAt {
                            Text(date.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button("Undo") { markers.delete(marker) }.controlSize(.small).disabled(markers.isSaving)
                    }.font(.caption)
                }
                if let actionMessage {
                    Text(actionMessage).font(.caption).foregroundStyle(Color.retraceWarning)
                }
                if let message = markers.message {
                    HStack {
                        Label(message, systemImage: "bookmark").font(.caption).foregroundStyle(.secondary)
                        if markers.undoMarker != nil { Button("Undo") { markers.undo() }.controlSize(.small).disabled(markers.isSaving) }
                        Spacer(minLength: 0)
                    }
                }
                GeometryReader { geometry in
                    let split = DashboardLiveLayoutPolicy.contentMode(forWidth: geometry.size.width) == .split
                    let columns = DashboardLiveLayoutPolicy.columnWidths(forWidth: geometry.size.width, transcriptRatio: splitRatio)
                    let transcriptVisible = split || compactPane == "Transcript"
                    let screenVisible = split || compactPane == "Screen"
                    let layout = split ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(ZStackLayout(alignment: .topLeading))
                    VStack(spacing: 10) {
                        if !split {
                            Picker("Live pane", selection: $compactPane) {
                                Text("Transcript").tag("Transcript")
                                Text("Screen").tag("Screen")
                            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Live pane")
                        }
                        // Preserve the transcript's structural identity while its
                        // layout and visibility change. Replacing this parent
                        // recreates its native scroll view at the first row.
                        layout {
                            leadingPane(isVisible: transcriptVisible)
                                .frame(width: split ? columns.transcript : geometry.size.width)
                                .opacity(transcriptVisible ? 1 : 0)
                                .allowsHitTesting(transcriptVisible)
                                .disabled(!transcriptVisible)
                                .accessibilityElement(children: transcriptVisible ? .contain : .ignore)
                                .accessibilityHidden(!transcriptVisible)
                            divider(availableWidth: geometry.size.width)
                                .frame(width: split ? DashboardLiveLayoutPolicy.columnSpacing : 0)
                                .opacity(split ? 1 : 0)
                                .allowsHitTesting(split)
                                .disabled(!split)
                                .accessibilityHidden(!split)
                            ZStack {
                                // Text expansion owns appearance-scoped work;
                                // hiding Screen must continue to cancel it.
                                if screenVisible { screenContextPane }
                            }
                            .frame(width: split ? columns.context : geometry.size.width)
                            .frame(maxHeight: .infinity)
                            .allowsHitTesting(screenVisible)
                            .disabled(!screenVisible)
                            .accessibilityElement(children: screenVisible ? .contain : .ignore)
                            .accessibilityHidden(!screenVisible)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.07), lineWidth: 1))
            // Retain the native scroll view and its viewport while an inactive destination
            // or a resumed source check temporarily makes this evidence unavailable.
            .opacity(canPresentEvidence ? 1 : 0)
            .animation(nil, value: canPresentEvidence)
            .allowsHitTesting(canPresentEvidence)
            .disabled(!canPresentEvidence)
            // Native List children can remain exported by AppKit while a
            // transparent SwiftUI container is hidden. Withhold its children
            // as well until the retained records pass canonical validation.
            .accessibilityElement(children: canPresentEvidence ? .contain : .ignore)
            .accessibilityHidden(!canPresentEvidence)

            if isActive && !model.presentationReady {
                VStack(spacing: 10) {
                    if model.isLoading { ProgressView().controlSize(.small) }
                    Text("Checking retained context…").font(.callout)
                    if let message = model.audioError {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Retry") { Task { await model.refresh() } }
                        .disabled(model.isLoading)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(isActive):\(model.requestRevision)") {
            model.setActive(isActive)
            guard isActive else { return }
            while isActive && !Task.isCancelled {
                await model.refresh()
                await model.refreshDrafts()
                guard isActive, !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .retraceAudioTextCommitted)) { _ in model.audioTextCommitted() }
        .onReceive(NotificationCenter.default.publisher(for: .retraceLiveDraftChanged)) { _ in model.draftChanged() }
        .task(id: evidenceRequest) { await showSelectedScreen() }
        .task(id: "\(isActive):\(model.requestRevision)") {
            guard isActive else { return }
            while !Task.isCancelled {
                await companion.refreshStatus()
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
            }
        }
        .task(id: isActive) {
            guard isActive else { return }
            while !Task.isCancelled {
                await companion.refreshPlayback()
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            }
        }
        .task(id: isActive) {
            guard isActive else { return }
            while !Task.isCancelled {
                await voice.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .task(id: playback.state.request) {
            guard let request = playback.state.request else { return }
            while isActive && !Task.isCancelled {
                guard let row = (model.transcripts + [searchAudio].compactMap { $0 }).first(where: { $0.id == request.id }),
                      await model.validateForAction([row]) else {
                    if !Task.isCancelled { playback.stop(reason: .selectionChanged) }
                    return
                }
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
            }
        }
        .onChange(of: isActive) { active in
            model.setActive(active)
            if !active { stopPresentation() }
        }
        .onChange(of: model.presentationReady) { ready in
            if ready { companion.adopt(model.speakers, interval: model.interval) }
            else { stopPresentation(resetSearch: false) }
        }
        .onChange(of: search.revision) { _ in
            dismissCopyPreview()
            searchAudio = nil
            selectedSpeaker = nil; showingSpeakers = false
            playback.stop(reason: .selectionChanged)
            companion.stopPlayback()
        }
        .onChange(of: model.transcriptRevision) { _ in companion.adopt(model.speakers, interval: model.interval) }
        .onChange(of: companion.savedRevision) { _ in
            if let current = companion.selectedPresentation { model.replaceSpeaker(current) }
        }
        .onChange(of: model.sourceInvalidationRevision) { _ in
            dismissCopyPreview(); playback.stop(reason: .selectionChanged); companion.hide()
            selectedSpeaker = nil; showingSpeakers = false
            presenter.close(model: evidence); completedScreen = nil
            if canPresentEvidence { companion.adopt(model.speakers, interval: model.interval) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dataSourceDidChange)) { _ in
            stopPresentation()
            model.sourceChanged()
        }
        .onDisappear {
            model.setActive(false)
            stopPresentation()
        }
        .sheet(isPresented: Binding(get: { copyPreview != nil }, set: { if !$0 { dismissCopyPreview() } })) {
            copyPreviewSheet
        }
        .sheet(isPresented: $showingSpeakers) {
            CompanionSpeakerView(model: companion, selected: selectedSpeaker) { showingSpeakers = false; selectedSpeaker = nil }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search recorded context", text: $searchText)
                        .textFieldStyle(.plain).onSubmit { applyScope() }
                    if !searchText.isEmpty {
                        Button { searchText = ""; applyScope() } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).help("Clear search")
                    }
                }
                .padding(.horizontal, 9).frame(height: 29)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .help("Press Return to search saved transcripts, OCR, apps, windows, notes, markers and available speaker labels.")
                Button { showingSearchDates.toggle() } label: { Image(systemName: "calendar") }
                    .help("Filter search by date").accessibilityLabel("Filter search by date")
                Button(action: prepareCopyPreview) { Label("Copy context", systemImage: "doc.on.doc") }
                    .disabled(!hasCopyEvidence || model.interval == nil || actionTask != nil)
                Button { markers.markNow() } label: { Label("Mark now", systemImage: "bookmark.fill") }
                    .disabled(markers.isSaving).help("Save a marker at the current time")
                Button { showingMarkers.toggle() } label: { Image(systemName: "list.bullet") }
                    .help("Marked moments").accessibilityLabel("Marked moments")
                    .popover(isPresented: $showingMarkers) { TimelineMarkersPanel(model: markers, openMarker: openMarker) }
            }
            if showingSearchDates {
                HStack {
                    Text("Search dates").font(.caption).foregroundStyle(.secondary)
                    Picker("Search dates", selection: $selectedRange) {
                        ForEach(LiveContextRange.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 158)
                    if selectedRange == .custom {
                        DatePicker("From", selection: $customFrom, displayedComponents: [.date, .hourAndMinute])
                        DatePicker("To", selection: $customTo, displayedComponents: [.date, .hourAndMinute])
                    }
                    Button("Search", action: applyScope).disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.controlSize(.small)
            }
        }
    }

    private var hasCopyEvidence: Bool {
        if search.isSearching { return !search.selectedIDs.isEmpty }
        if !model.transcripts.isEmpty || !model.speakers.isEmpty || model.selectedTurn != nil { return true }
        if model.selectedScreen != nil, completedScreen == model.selectedScreenID,
           case .screen = evidence.resolution { return true }
        return false
    }

    private var statusStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                recordingStatus
                transcriptStatus
                speakerStatus
                Spacer(minLength: 0)
                Label(companion.title, systemImage: "network")
                voiceSettingsAction
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) { recordingStatus; Spacer(minLength: 0); transcriptStatus }
                voiceSettingsAction
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .help("Saved first-pass transcripts stay local and remain readable when companion enrichment is unavailable.")
    }

    private var voiceSettingsAction: some View {
        Button(action: openVoiceMarkerSettings) {
            Label("Voice markers · \(voice.title)", systemImage: "waveform")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voice markers settings")
        .help("Open voice marker rules in Settings → Audio. " + voice.detail)
    }

    private var speakerStatus: some View {
        Button {
            selectedSpeaker = nil; showingSpeakers = true
        } label: {
            Label(companion.presentations.isEmpty ? "Speakers unassigned" : "Speaker labels (\(companion.presentations.count))",
                systemImage: "person.crop.circle")
        }.buttonStyle(.plain).help("Review available labels and correct a name for a specific recording")
    }

    private var recordingStatus: some View {
        Label(isRecording ? "Recording" : "Recording paused", systemImage: isRecording ? "record.circle" : "pause.circle")
            .foregroundStyle(isRecording ? Color.retraceDanger : Color.secondary)
    }

    private var transcriptStatus: some View {
        HStack(spacing: 4) {
            Image(systemName: "text.bubble")
            if let date = model.latestTranscriptAt {
                Text("Latest loaded text")
                Text(date.formatted(date: .abbreviated, time: .shortened))
            } else { Text("No saved text loaded") }
            if model.isLoading { ProgressView().controlSize(.mini) }
        }
    }

    private func divider(availableWidth: CGFloat) -> some View {
        Rectangle().fill(Color.clear)
            .overlay(Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 3, height: 34))
            .frame(width: DashboardLiveLayoutPolicy.columnSpacing)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if dragStartRatio == nil { dragStartRatio = splitRatio }
                let usable = max(availableWidth - DashboardLiveLayoutPolicy.columnSpacing, 1)
                splitRatio = DashboardLiveLayoutPolicy.boundedRatio((dragStartRatio ?? 0.6) + value.translation.width / usable)
            }.onEnded { _ in dragStartRatio = nil })
            .accessibilityLabel("Resize transcript and screen panes")
            .accessibilityAdjustableAction { direction in
                splitRatio = DashboardLiveLayoutPolicy.boundedRatio(splitRatio + (direction == .increment ? 0.05 : -0.05))
            }
    }

    @ViewBuilder private func leadingPane(isVisible: Bool) -> some View {
        if search.isSearching { searchPane } else { transcriptPane(isVisible: isVisible) }
    }

    private var searchPane: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Interval results", systemImage: "magnifyingglass").font(.headline)
                if search.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Return to live") { searchText = ""; search.reset(); searchAudio = nil; selectedRange = .history; model.returnToLive() }
                    .controlSize(.small)
            }
            Text("Select evidence to include in Copy context. Results load in bounded pages from each source.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = search.message { Text(message).font(.caption).foregroundStyle(Color.retraceWarning) }
            DisclosureGroup("Search coverage") {
                ForEach(Array(search.coverage.enumerated()), id: \.offset) { _, status in
                    Text("\(status.source): \(status.hasMore ? "more pages available" : "page complete")\(status.notice.map { " · " + $0 } ?? "")")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.font(.caption)
            List {
                if let searchAudio { transcriptRow(searchAudio).listRowSeparator(.hidden) }
                ForEach(search.items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            Toggle("Include \(item.title)", isOn: Binding(get: { search.selectedIDs.contains(item.id) }, set: {
                                if $0 { search.selectedIDs.insert(item.id) } else { search.selectedIDs.remove(item.id) }
                            })).labelsHidden().toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.callout.weight(.medium))
                                Text("\(item.kind) · \(item.timestamp.formatted(date: .abbreviated, time: .standard))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if searchResultCanOpen(item) {
                                Button("Open") { openSearchResult(item) }.controlSize(.small).disabled(actionTask != nil)
                            }
                        }
                        Text(item.text).font(.callout).lineLimit(7).textSelection(.enabled)
                    }.padding(.vertical, 6).listRowBackground(Color.clear)
                }
                if search.canLoadMore { Button("Load more results") { search.loadMore() }.disabled(search.isLoading) }
                if search.items.isEmpty && !search.isLoading {
                    Text("No matches in the completed sources. Check Search coverage for unavailable or incomplete sources.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    }

    private func searchResultCanOpen(_ item: LiveContextSearchItem) -> Bool {
        switch item.reference { case .transcript, .screen, .metadata, .marker, .range, .speaker: true; default: false }
    }

    private func openSearchResult(_ item: LiveContextSearchItem) {
        let token = search.revision
        performAction {
            do {
                let service = try await contextService()
                try await service.validate(item.reference)
                guard !Task.isCancelled, token == search.revision else { return }
                switch item.reference {
                case .transcript(let reference):
                    let row = try await service.resolveTranscript(reference)
                    guard !Task.isCancelled, token == search.revision else { return }
                    playback.stop(reason: .selectionChanged)
                    searchAudio = row; model.selectAudio(row)
                case .screen(let reference): openEvidence(.screen(reference))
                case .metadata(let record):
                    let reference = try await service.screenReference(for: record)
                    guard !Task.isCancelled, token == search.revision else { return }
                    openEvidence(.screen(reference))
                case .marker(let marker), .range(let marker, _): try await openMarker(marker)
                case .speaker(let presentation):
                    try await companion.select(jobID: presentation.jobID)
                    guard !Task.isCancelled, token == search.revision else { return }
                    selectedSpeaker = presentation; showingSpeakers = true
                default: break
                }
            } catch { if !Task.isCancelled { actionMessage = "This result changed or its exact evidence is unavailable. Run the search again." } }
        }
    }

    private func transcriptPane(isVisible: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Transcript", systemImage: "waveform").font(.headline)
                Text("\(model.transcripts.count) loaded").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !model.followingLive {
                    Button {
                        playback.stop(reason: .selectionChanged)
                        companion.stopPlayback()
                        presenter.close(model: evidence)
                        selectedRange = .history
                        searchText = ""
                        model.returnToLive()
                    } label: {
                        Label(model.hasNewerContent ? "New content · Return to live" : "Return to live", systemImage: "arrow.up")
                    }.controlSize(.small)
                } else {
                    Text("Following live").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = model.audioError {
                HStack { Text(message); Button("Retry") { Task { await model.refresh() } } }
                    .font(.caption).foregroundStyle(Color.retraceWarning)
            }
            if let preparation = model.preparationStatus {
                Text("Text waiting: \(preparation.pendingCountLowerBound)\(preparation.hasMorePending ? "+" : "") recordings · further review: \(preparation.repairCountLowerBound)\(preparation.hasMoreRepair ? "+" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                if let oldest = preparation.oldestPendingAt {
                    Text("Oldest waiting: \(oldest.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Queue checked \(preparation.observedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Toggle("Fast microphone drafts (trial)", isOn: Binding(get: { model.drafts.enabled }, set: { enabled in
                Task { await model.setDraftsEnabled(enabled) }
            })).toggleStyle(.switch).controlSize(.small)
                .help("On-device microphone preview using installed speech assets. System audio and saved searchable text continue through the recording pipeline.")
            if model.drafts.enabled && model.followingLive {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.drafts.notice).font(.caption).foregroundStyle(.secondary)
                    if !model.drafts.text.isEmpty {
                        Text(model.drafts.text).font(.callout).lineLimit(4)
                            .accessibilityLabel("Provisional microphone preview: \(model.drafts.text)")
                    }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.retraceAccent.opacity(0.08)).cornerRadius(8)
            }
            if let notice = model.audioScanNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if let message = model.speakerError { Text(message).font(.caption).foregroundStyle(Color.retraceWarning) }
            if let message = companion.playbackMessage { Text(message).font(.caption).foregroundStyle(Color.retraceWarning) }
            ScrollViewReader { proxy in
                transcriptList(isVisible: isVisible)
                    .onChange(of: model.followingLive) { following in
                        if following && isVisible && canPresentEvidence { proxy.scrollTo("transcript-top", anchor: .top) }
                    }
                    .onChange(of: isVisible) { visible in
                        if visible && canPresentEvidence && model.followingLive { proxy.scrollTo("transcript-top", anchor: .top) }
                    }
                    .onChange(of: model.presentationReady) { ready in
                        if isVisible && isActive && ready && model.followingLive { proxy.scrollTo("transcript-top", anchor: .top) }
                    }
                    .onChange(of: model.transcriptRevision) { _ in
                        if isVisible && canPresentEvidence && model.followingLive { proxy.scrollTo("transcript-top", anchor: .top) }
                    }
                    .overlay {
                        if model.transcriptItems.isEmpty && !model.isLoading {
                            VStack(spacing: 9) {
                                Image(systemName: "waveform").font(.title2).foregroundStyle(.secondary)
                                Text(model.audioScanIncomplete ? "Checking earlier recordings…" : "No saved audio yet")
                                    .font(.callout)
                                Text("Saved recordings appear here before their transcript is ready.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                        }
                    }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    }

    private func transcriptList(isVisible: Bool) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text("Newest first · scroll down for older recordings")
                    .font(.caption).foregroundStyle(.secondary).id("transcript-top")
                ForEach(model.transcriptItems) { item in
                    Group {
                        switch item {
                        case .recording(let row): transcriptRow(row)
                        case .turn(let turn): speakerTurnRow(turn)
                        case .original(let original): originalTranscriptRow(original)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(LiveContextTranscriptRowIdentity(rowID: item.id))
                    .id(item.id)
                    .onAppear {
                        guard isVisible && canPresentEvidence else { return }
                        Task { await model.loadOlderIfNeeded(near: item.id) }
                    }
                }
                if model.canLoadOlder {
                    HStack(spacing: 8) {
                        if model.isLoading { ProgressView().controlSize(.small) }
                        Text("Scroll for older recordings").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(8)
                    .task(id: "\(model.olderPageRevision):\(isVisible && canPresentEvidence):\(model.audioError == nil):\(model.speakerError == nil)") {
                        guard isVisible && canPresentEvidence else { return }
                        // Continue empty candidate pages only while this footer
                        // is visible. Yield between bounded reads, never scan all
                        // history merely because Live was opened.
                        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                        await model.loadOlderIfNeeded()
                    }
                }
                if model.speakerCoverageIncomplete {
                    Text("Speaker labels cover available saved enrichment; unmatched recordings remain unassigned.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Color.clear.frame(height: 1).id("transcript-bottom")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(LiveTranscriptScrollTargets())
        }
        .modifier(LiveTranscriptScrollPosition(position: $visibleTranscriptID))
        .focusable(isVisible && canPresentEvidence)
        .background(LiveContextScrollInteractionObserver(
            isActive: { isVisible && canPresentEvidence },
            shouldInitiallyFollow: { isVisible && canPresentEvidence && model.followingLive && !model.transcriptItems.isEmpty },
            onScroll: { model.pauseFollowing() }))
    }

    private func transcriptRow(_ row: AudioTranscription) -> some View {
        let request = TranscriptAudioRequest(transcription: row)
        let selected = model.selectedAudioID == row.id
        let selectedAudio = playback.state.request == request
        let playing = selectedAudio && playback.state.phase == .playing
        let loading = selectedAudio && playback.state.phase == .loading
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    playback.stop(reason: .selectionChanged)
                    companion.stopPlayback()
                    presenter.close(model: evidence)
                    model.selectAudio(row)
                } label: {
                    Text(row.startTime.formatted(date: .abbreviated, time: .standard))
                        .font(.caption.weight(.medium))
                }.buttonStyle(.plain).foregroundStyle(selected ? Color.retraceAccent : Color.secondary)
                    .help("Show recorded screens during this audio entry")
                Spacer(minLength: 0)
                Text(row.source.displayName).font(.caption).foregroundStyle(.secondary)
                if request.hasAudioPath {
                    Button {
                        model.pauseFollowing()
                        companion.stopPlayback()
                        if selectedAudio && [.playing, .loading].contains(playback.state.phase) {
                            playback.toggle(request)
                        } else {
                            performAction {
                                guard await model.validateForAction([row]) else {
                                    if !Task.isCancelled { actionMessage = "This recording changed or is no longer available. Refresh the interval." }
                                    return
                                }
                                guard canPresentEvidence, !Task.isCancelled else { return }
                                playback.toggle(request)
                            }
                        }
                    } label: {
                        if loading { ProgressView().controlSize(.mini) }
                        else { Image(systemName: playing ? "pause.fill" : "play.fill") }
                    }
                    .buttonStyle(.borderless).frame(width: 24, height: 22)
                    .help(playing ? "Pause this recording" : "Play this exact saved recording")
                    .accessibilityLabel(playing ? "Pause recording" : "Play recording from \(row.startTime.formatted())")
                }
            }
            if !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(row.text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.badge.clock")
                    // Pending-only history needs the same native text responder
                    // as transcribed history for focused Page Up/Home navigation.
                    Text("Audio is saved. Transcript text is not ready.")
                        .textSelection(.enabled)
                }.font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 7) {
                Text(LiveContextPresentation.status(row))
                Text("· Speaker unassigned")
                Spacer(minLength: 0)
                Button {
                    playback.stop(reason: .selectionChanged)
                    companion.stopPlayback()
                    presenter.close(model: evidence)
                    model.selectAudio(row)
                    compactPane = "Screen"
                } label: { Label("Screens", systemImage: "rectangle.on.rectangle") }.buttonStyle(.plain)
            }.font(.caption2).foregroundStyle(.secondary)
            if selectedAudio, let message = playback.state.message {
                Text(message).font(.caption).foregroundStyle(Color.retraceWarning)
            }
        }
        .padding(12)
        .background(selected ? Color.retraceAccent.opacity(0.08) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.retraceAccent.opacity(0.5) : Color.clear, lineWidth: 1))
    }

    private func speakerTurnRow(_ item: LiveTranscriptTurn) -> some View {
        let selected = model.selectedTurn?.reference == item.reference
        let playing = companion.playingTurn == item.reference
        let loading = companion.loadingTurn == item.reference
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { selectTurn(item, showScreen: false) } label: {
                    Text(item.interval.start.formatted(date: .abbreviated, time: .standard)).font(.caption.weight(.medium))
                }.buttonStyle(.plain).foregroundStyle(selected ? Color.retraceAccent : Color.secondary)
                Text(item.displayLabel).font(.callout.weight(.semibold))
                    .help("This speaker identity belongs only to the selected recording's saved inference.")
                Spacer(minLength: 0)
                Button {
                    if playing || loading { companion.stopPlayback() }
                    else {
                        model.pauseFollowing(); playback.stop(reason: .selectionChanged)
                        performAction {
                            do {
                                try await model.selectTurn(item.reference)
                                guard !Task.isCancelled else { return }
                                companion.playTurn(item.reference)
                            } catch { if !Task.isCancelled { actionMessage = "This saved turn changed or is unavailable. Refresh the interval." } }
                        }
                    }
                } label: {
                    if loading { ProgressView().controlSize(.mini) }
                    else { Image(systemName: playing ? "stop.fill" : "play.fill") }
                }.buttonStyle(.borderless).frame(width: 24, height: 22)
                    .accessibilityLabel(playing ? "Stop turn playback" : "Play saved turn by \(item.displayLabel)")
                    .help("Play the verified source samples for this saved turn. Speech boundaries are model estimates.")
            }
            Text(item.turn.text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 7) {
                Text(item.statusText)
                Text("· Saved enhancement")
                Spacer(minLength: 0)
                Button("Name") { editSpeaker(item.presentation) }.buttonStyle(.plain)
                Button { selectTurn(item, showScreen: true) } label: { Label("Screens", systemImage: "rectangle.on.rectangle") }
                    .buttonStyle(.plain)
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(selected ? Color.retraceAccent.opacity(0.08) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.retraceAccent.opacity(0.5) : Color.clear, lineWidth: 1))
    }

    private func originalTranscriptRow(_ original: LiveTranscriptOriginal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup {
                Text("Full original recording. Its text is not aligned to individual enhanced turns and may include an overlapping tail.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(original.presentation.firstPassText).textSelection(.enabled).font(.callout)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Original first pass · \(original.startedAt.formatted(date: .omitted, time: .standard))").font(.caption.weight(.medium))
                    Text(original.hasDisplayedTurns ? "Preserved separately from the speaker turns" : "No enhanced turn is shown for this original")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(10).background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func selectTurn(_ item: LiveTranscriptTurn, showScreen: Bool) {
        guard canPresentEvidence else { return }
        playback.stop(reason: .selectionChanged); companion.stopPlayback(); presenter.close(model: evidence)
        performAction {
            do {
                try await model.selectTurn(item.reference)
                guard !Task.isCancelled else { return }
                if showScreen { compactPane = "Screen" }
            } catch { if !Task.isCancelled { actionMessage = "This saved turn changed or is unavailable. Refresh the interval." } }
        }
    }

    private func editSpeaker(_ presentation: CompanionSpeakerPresentation) {
        guard canPresentEvidence else { return }
        model.pauseFollowing()
        performAction {
            do {
                try await companion.select(jobID: presentation.jobID)
                guard canPresentEvidence, !Task.isCancelled else { return }
                selectedSpeaker = presentation; showingSpeakers = true
            } catch { if !Task.isCancelled { actionMessage = "This recording's speaker evidence is no longer available." } }
        }
    }

    private var screenContextPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Screen context", systemImage: "macwindow").font(.headline)
                Spacer()
                Picker("Screen details", selection: $screenPane) {
                    Text("Screenshot").tag("Screenshot")
                    Text("Text").tag("Text")
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Screen details").frame(width: 160)
            }
            if let interval = model.selectedInterval {
                Text("During \(interval.start.formatted(date: .abbreviated, time: .standard)) – \(interval.end.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
                if model.selectedTurn != nil {
                    Text("Screen association uses the recording's approximate wall clock. Turn audio retains exact source-sample offsets.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("\(model.screens.count) recorded screens in this interval\(model.screensHaveMore ? " · more omitted" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.screenError {
                Text(error).font(.caption).foregroundStyle(Color.retraceWarning)
            }
            if !model.screens.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 6) {
                        ForEach(model.screens) { row in
                            Button {
                                guard model.selectedScreenID != row.id else { return }
                                presenter.close(model: evidence)
                                model.selectScreen(row)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.frame.timestamp, style: .time).font(.caption2)
                                    Text(row.frame.metadata.appName ?? row.frame.metadata.appBundleID ?? "Recorded screen")
                                        .font(.caption.weight(.medium)).lineLimit(1)
                                }
                                .frame(width: 112, alignment: .leading).padding(8)
                                .background(model.selectedScreenID == row.id ? Color.retraceAccent.opacity(0.13) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            if model.screens.isEmpty && !model.isLoading {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.dashed").font(.title2)
                    Text("No recorded screen in this interval")
                    Text("No nearby screen has been substituted.").font(.caption)
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if screenPane == "Text" {
                if model.selectedScreen != nil && completedScreen == model.selectedScreenID {
                    ExactEvidenceView(model: evidence, showsImage: false, showsClose: false)
                } else {
                    Text("Select a retained screen to inspect its text.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScreenshotEvidencePreview(model: evidence, selection: model.selectedScreenID,
                    selectionAvailable: model.selectedScreen != nil, completedSelection: completedScreen,
                    retrySelection: { Task { await showSelectedScreen() } }, openTimeline: openEvidence)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    }

    private var evidenceRequest: DashboardScreenshotEvidenceRequest {
        DashboardScreenshotEvidenceRequest(selection: canPresentEvidence ? model.selectedScreenID : nil,
            available: model.selectedScreen != nil, epoch: model.screenReadRevision)
    }

    private func showSelectedScreen() async {
        let request = evidenceRequest
        guard canPresentEvidence, let row = model.selectedScreen else {
            presenter.close(model: evidence); completedScreen = nil; return
        }
        await presenter.show(row, model: evidence)
        guard !Task.isCancelled, request == evidenceRequest else { return }
        completedScreen = row.id
    }

    private func applyScope() {
        guard canPresentEvidence else { return }
        stopPresentation()
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let interval = selectedRange.interval(now: Date(), from: customFrom, to: customTo) {
            model.pauseFollowing()
            search.submit(interval: interval, query: searchText)
        } else {
            actionMessage = "Choose a search start time before the end time."
        }
    }

    private func stopPresentation(resetSearch: Bool = true) {
        actionTask?.cancel()
        playback.stop(reason: .closed)
        presenter.close(model: evidence)
        completedScreen = nil
        copyPreview = nil
        copyRows = []
        copyScreen = nil
        copyReferences = []; copyInterval = nil
        copyBudgetNotice = nil
        if resetSearch { search.reset() }
        searchAudio = nil
        companion.hide(); showingSpeakers = false; selectedSpeaker = nil
        actionMessage = nil
        showingMarkers = false
        markers.hide()
    }

    private func prepareCopyPreview() {
        guard canPresentEvidence, let loadedInterval = model.interval else { return }
        model.pauseFollowing()
        let loadedStart = model.transcriptItems.map(\.startedAt).min() ?? model.screens.last?.frame.timestamp ?? loadedInterval.end.addingTimeInterval(-1_800)
        let loadedSelection = DateInterval(start: loadedStart, end: max(loadedStart.addingTimeInterval(0.001), loadedInterval.end))
        let interval = search.interval ?? model.selectedInterval ?? loadedSelection
        let snapshot: ScreenEvidenceSnapshot?
        if completedScreen == model.selectedScreenID, model.selectedScreen != nil,
           case .screen(let retained, _) = evidence.resolution { snapshot = retained }
        else { snapshot = nil }
        let rows = model.selectedAudio.map { [$0] } ?? Array(model.transcripts.prefix(LiveContextWorkspaceModel.maximumActionRecordings))
        let omittedRows = model.selectedAudio == nil ? model.transcripts.count - rows.count : 0
        let selection = model.selectedScreenID
        let revision = model.requestRevision
        let searchRevision = search.revision
        let selectedIDs = search.selectedIDs
        let selectedReferences = search.selectedReferences
        let selectedTurn = model.selectedTurn?.reference
        let speakers = model.speakers
        let partial = search.isSearching ? search.isPartial : model.selectedAudio == nil && selectedTurn == nil &&
            (omittedRows > 0 || model.nextCursor != nil || model.audioScanIncomplete || model.speakerCursor != nil || model.speakerCoverageIncomplete || model.turnsTruncated)
        let coverageNotices: [String]
        if search.isSearching {
            coverageNotices = search.coverage.compactMap { status in status.notice.map { "\(status.source): \($0)" } }
        } else {
            coverageNotices = model.selectedAudio == nil && selectedTurn == nil ?
                [model.audioScanNotice, omittedRows > 0 ? "\(omittedRows) older loaded recordings omitted from this bounded copy. Select a recording to include it." : nil].compactMap { $0 } : []
        }
        performAction {
            do {
                let service = try await contextService()
                var references = selectedReferences
                if !search.isSearching {
                    if let selectedTurn { references = [.speakerTurn(selectedTurn)] }
                    else {
                        let transcriptReferences = try await service.transcriptReferences(rows)
                        references = model.selectedAudio == nil ? speakers.map(LiveContextReference.speaker) + transcriptReferences : transcriptReferences
                    }
                    if let snapshot { references.insert(.screen(snapshot.ref), at: 0) }
                }
                let budget = LiveContextCopyBudget(references: references)
                let isPartial = partial || budget.omittedCount > 0
                let material = try await service.copy(references: budget.references, interval: interval, partial: isPartial)
                guard revision == model.requestRevision, selection == model.selectedScreenID,
                      searchRevision == search.revision, selectedIDs == search.selectedIDs, !Task.isCancelled else { return }
                copyRows = rows; copyScreen = snapshot; copyReferences = budget.references
                let notices = [budget.notice].compactMap { $0 } + coverageNotices
                copyBudgetNotice = notices.isEmpty ? nil : notices.joined(separator: "\n")
                copyInterval = interval; copyPartial = isPartial; copyQuestion = ""; copyPreview = material.text
            } catch {
                if !Task.isCancelled { actionMessage = "The selected context changed or became unavailable. Refresh it before copying." }
            }
        }
    }

    private func validateScreen(_ snapshot: ScreenEvidenceSnapshot?) async -> Bool {
        guard let snapshot else { return !Task.isCancelled }
        return await validateScreenReference(snapshot.ref) && !Task.isCancelled
    }

    private func performAction(_ operation: @escaping @MainActor () async -> Void) {
        guard canPresentEvidence else { return }
        let prior = actionTask
        prior?.cancel()
        let id = UUID()
        let revision = model.requestRevision
        actionID = id
        actionMessage = nil
        actionTask = Task { @MainActor in
            defer { if actionID == id { actionTask = nil; actionID = nil } }
            await prior?.value
            guard !Task.isCancelled, canPresentEvidence, revision == model.requestRevision else { return }
            await operation()
        }
    }

    private func dismissCopyPreview() {
        actionTask?.cancel()
        copyPreview = nil
        copyRows = []
        copyScreen = nil
        copyReferences = []; copyInterval = nil
        copyBudgetNotice = nil
    }

    private var copyPreviewSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Copy recorded context").font(.title2.weight(.semibold))
            Text("Review the exact text before copying it to the clipboard.")
                .font(.callout).foregroundStyle(.secondary)
            if let copyBudgetNotice {
                Text(copyBudgetNotice).font(.callout).foregroundStyle(Color.retraceWarning)
            }
            TextField("Question to include (optional)", text: $copyQuestion, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
                .disabled(actionTask != nil)
            ScrollView {
                Text(copyPreview ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Spacer()
                Button("Cancel") { dismissCopyPreview() }.keyboardShortcut(.cancelAction)
                Button("Copy") {
                    guard let preview = copyPreview, let interval = copyInterval else { return }
                    let references = copyReferences
                    let question = copyQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
                    let notice = copyBudgetNotice
                    let revision = model.requestRevision
                    performAction {
                        do {
                            let service = try await contextService()
                            let material = try await service.copy(references: references, interval: interval, partial: copyPartial)
                            guard material.text == preview, revision == model.requestRevision,
                                  copyPreview == preview, !Task.isCancelled else { throw CompanionError.staleEvidence }
                            let final = question.isEmpty ? material : try await service.copy(references: references,
                                interval: interval, question: question, partial: copyPartial)
                            guard revision == model.requestRevision, copyPreview == preview, !Task.isCancelled else { throw CompanionError.staleEvidence }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(LiveContextCopyBudget.text(final.text, notice: notice), forType: .string)
                            dismissCopyPreview()
                        } catch {
                            if !Task.isCancelled {
                                self.copyPreview = nil
                                actionMessage = "Context changed while the preview was open. Review a fresh preview before copying."
                            }
                        }
                    }
                }.keyboardShortcut(.defaultAction).disabled(actionTask != nil)
            }
        }.padding(22).frame(width: 680, height: 520)
    }
}
