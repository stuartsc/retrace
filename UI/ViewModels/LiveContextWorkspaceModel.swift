import App
import Combine
import Database
import Foundation
import Shared

enum LiveContextRange: String, CaseIterable, Identifiable {
    case history = "All history"
    case recent = "Last 30 minutes"
    case today = "Today"
    case custom = "Custom"
    var id: String { rawValue }

    func interval(now: Date, from: Date, to: Date) -> DateInterval? {
        let start: Date
        let end: Date
        switch self {
        case .history: start = Date(timeIntervalSince1970: -62_135_596_800); end = now
        case .recent: start = now.addingTimeInterval(-1_800); end = now
        case .today: start = Calendar.current.startOfDay(for: now); end = now
        case .custom: start = from; end = min(to, now)
        }
        guard start < end else { return nil }
        return DateInterval(start: start, end: end)
    }
}

struct LiveContextScreenPage: Sendable {
    let rows: [DashboardScreenshotRow]
    let hasMore: Bool
}

private enum LiveContextCoreRead: Sendable {
    case audio(AudioContextPage)
    case screens(LiveContextScreenPage)
    case audioUnavailable(LiveContextAudioReadFailure)
    case screensUnavailable
}

private enum LiveContextAudioReadFailure: String, Sendable {
    case connectionBusy = "connection_busy"
    case budgetExceeded = "budget_exceeded"
    case invalidContinuation = "invalid_continuation"
    case closed
    case unavailable

    init(_ error: Error) {
        switch error {
        case AudioContextReadError.connectionBusy: self = .connectionBusy
        case AudioContextReadError.budgetExceeded: self = .budgetExceeded
        case AudioContextReadError.invalidContinuation: self = .invalidContinuation
        case AudioContextReadError.closed: self = .closed
        default: self = .unavailable
        }
    }

    var message: String {
        switch self {
        case .connectionBusy: "Saved audio is temporarily busy. Retry in a moment."
        case .budgetExceeded: "This audio read exceeded its time limit. Retry or choose a narrower interval."
        case .invalidContinuation: "This audio page is no longer available. Return to live or choose another interval."
        case .closed: "The audio reader is unavailable. Retry when the library is ready."
        case .unavailable: "Saved audio could not be read. Retry or choose another interval."
        }
    }
}

enum LiveContextPresentation {
    static func sameRecording(_ lhs: AudioTranscription, _ rhs: AudioTranscription) -> Bool {
        lhs.id == rhs.id && lhs.sessionID == rhs.sessionID && lhs.text == rhs.text &&
        lhs.startTime == rhs.startTime && lhs.endTime == rhs.endTime && lhs.source == rhs.source &&
        lhs.confidence == rhs.confidence && lhs.createdAt == rhs.createdAt && lhs.audioPath == rhs.audioPath &&
        lhs.batchAudioPath == rhs.batchAudioPath && lhs.transcriptStatus == rhs.transcriptStatus &&
        lhs.detectedLanguage == rhs.detectedLanguage && lhs.audioVariant == rhs.audioVariant &&
        lhs.qualityFlags == rhs.qualityFlags && lhs.transcriptionPass == rhs.transcriptionPass
    }

    static func latestTranscriptDate(_ rows: [AudioTranscription]) -> Date? {
        rows.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.endTime).max()
    }

    static func status(_ row: AudioTranscription) -> String {
        switch row.transcriptStatus {
        case "pending": return "Text pending"
        case "needs_repair", "needs_review": return "Text needs review"
        case "transcribed" where !row.text.isEmpty: return row.transcriptionPass > 1 ? "Refined transcript" : "Saved transcript"
        default: return row.text.isEmpty ? "Audio saved · no readable text" : "Saved transcript"
        }
    }

    static func copyPreview(rows: [AudioTranscription], interval: DateInterval, hasMore: Bool,
                            selectedScreen: ScreenEvidenceSnapshot?) -> String {
        var lines = ["Retrace — recorded context",
            "Interval: \(interval.start.formatted(date: .abbreviated, time: .standard)) – \(interval.end.formatted(date: .abbreviated, time: .standard))",
            "\(rows.count) loaded audio entries. Speaker: unassigned.",
            hasMore ? "More recordings are available; this is a partial selection." : "Only loaded recordings in the selected interval are included."]
        for row in rows.reversed() {
            lines.append("\n[\(row.startTime.formatted(date: .abbreviated, time: .standard)) – \(row.endTime.formatted(date: .omitted, time: .standard))] \(row.source.displayName) · row \(row.id) · \(status(row))")
            lines.append(row.text.isEmpty ? "[No saved transcript text]" : row.text)
        }
        if let screen = selectedScreen {
            lines.append("\nSelected screen: \(screen.frame.timestamp.formatted(date: .abbreviated, time: .standard)) · \(screen.ref.source.displayName) · frame \(screen.frame.id.value) · extraction \(screen.ref.extractionRevision)")
            if let app = screen.frame.metadata.appName { lines.append("App: \(app)") }
            if let title = screen.frame.metadata.windowName { lines.append("Window: \(title)") }
            if let url = screen.frame.metadata.browserURL { lines.append("Recorded URL: \(url)") }
            if let link = EvidenceRef.screen(screen.ref).deepLink { lines.append("Exact evidence: \(link.absoluteString)") }
            if let text = screen.text?.fullText, !text.isEmpty {
                lines.append("Recorded screen OCR:\n\(String(text.prefix(16_000)))")
                if text.count > 16_000 { lines.append("[Screen OCR excerpt truncated at 16,000 characters]") }
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// One visible workspace owns bounded reads. Closing or changing scope fences
/// publication immediately; cancelled reads remain owned until they finish.
@MainActor
final class LiveContextWorkspaceModel: ObservableObject {
    nonisolated static let audioPageSize = 100
    nonisolated static let maximumActionRecordings = 500
    nonisolated static let maximumScreens = 96

    @Published private(set) var drafts = LiveTranscriptionSnapshot()
    private let readDrafts: @Sendable () async -> LiveTranscriptionSnapshot
    private let setDraftTrial: @Sendable (Bool) async -> Void
    private var eventRefreshTask: Task<Void, Never>?
    private var eventRefreshID = UUID()
    private var eventRefreshPending = false
    private var draftRefreshTask: Task<Void, Never>?
    private var draftRefreshID = UUID()
    private var draftRefreshPending = false

    @Published private(set) var transcripts: [AudioTranscription] = []
    @Published private(set) var speakers: [CompanionSpeakerPresentation] = []
    @Published private(set) var transcriptItems: [LiveTranscriptItem] = []
    @Published private(set) var turnsTruncated = false
    @Published private(set) var audioScanIncomplete = false
    @Published private(set) var speakerCoverageIncomplete = false
    @Published private(set) var speakerError: String?
    @Published private(set) var speakerCursor: String?
    @Published private(set) var selectedTurn: CompanionTurnPresentation?
    @Published private(set) var screens: [DashboardScreenshotRow] = []
    @Published private(set) var nextCursor: AudioContextCursor?
    @Published private(set) var screensHaveMore = false
    @Published private(set) var audioError: String?
    @Published private(set) var screenError: String?
    @Published private(set) var isLoading = false
    /// Retained history stays mounted while hidden, but is not evidence until
    /// the resumed owner has checked its exact sources again.
    @Published private(set) var presentationReady = false
    @Published private(set) var followingLive = true
    @Published private(set) var hasNewerContent = false
    @Published private(set) var latestTranscriptAt: Date?
    @Published private(set) var preparationStatus: AudioPreparationStatus?
    @Published private(set) var selectedAudioID: Int64?
    private var selectedExternalAudio: AudioTranscription?
    @Published private(set) var selectedScreenID: ScreenshotEvidenceSelection?
    @Published private(set) var requestRevision: UInt64 = 0
    @Published private(set) var sourceInvalidationRevision: UInt64 = 0
    @Published private(set) var transcriptRevision: UInt64 = 0
    @Published private(set) var olderPageRevision: UInt64 = 0
    @Published private(set) var screenReadRevision: UInt64 = 0
    @Published private(set) var range: LiveContextRange = .history
    @Published private(set) var interval: DateInterval?
    @Published private(set) var query = ""
    private var customFrom = Date().addingTimeInterval(-1_800)
    private var customTo = Date()
    private var active = false
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var taskID: UUID?
    private var taskGeneration: UInt64?
    private var taskLoadsOlder = false
    private var olderRefreshCompletions: UInt64 = 0
    private let readPreparationStatus: @Sendable () async -> AudioPreparationStatus?
    private let loadAudio: @Sendable (DateInterval, AudioContextCursor?, String?) async throws -> AudioContextPage
    private let loadScreens: @Sendable (DateInterval) async throws -> LiveContextScreenPage
    private let readEntry: @Sendable (Int64) async throws -> AudioTranscription?
    private let loadSpeakers: @Sendable (DateInterval, String?) async throws -> CompanionSpeakerPage
    private let resolveTurn: @Sendable (CompanionTurnReference) async throws -> CompanionTurnPresentation
    private let readSpeaker: @Sendable (String) async throws -> CompanionSpeakerPresentation?
    private let sourceChanges: (@Sendable () async throws -> ContextRangePresentationService)?
    private let speakerChanges: (@Sendable () async throws -> CompanionController)?
    private var observationOwner: ContextRangePresentationService?
    private var observationID: UUID?
    private var speakerObservationOwner: CompanionController?
    private var speakerObservationID: UUID?
    private var sourceEpoch: UInt64 = 0
    private var hasPublishedTranscript = false
    private var needsResumeValidation = false
    private var recordingReferences: [V23TranscriptReference] = []
    private var lastAudioReadFailure: LiveContextAudioReadFailure?
    private let recordOlderPage: @Sendable (Int, Bool) async -> Void
    private let referenceRecordings: @Sendable ([AudioTranscription]) async throws -> [V23TranscriptReference]

    var selectedAudio: AudioTranscription? { selectedExternalAudio ?? transcripts.first { $0.id == selectedAudioID } }
    var selectedScreen: DashboardScreenshotRow? { screens.first { $0.id == selectedScreenID } }
    var audioScanNotice: String? {
        audioScanIncomplete ? "Earlier history is still being checked as you scroll." : nil
    }
    var canLoadOlder: Bool {
        nextCursor != nil || speakerCursor != nil
    }
    var selectedInterval: DateInterval? {
        if let selectedTurn { return .init(start: selectedTurn.approximateStart, end: selectedTurn.approximateEnd) }
        return selectedAudio.map { .init(start: $0.startTime, end: max($0.endTime, $0.startTime.addingTimeInterval(0.001))) }
    }

    init(loadAudio: @escaping @Sendable (DateInterval, AudioContextCursor?, String?) async throws -> AudioContextPage,
         loadScreens: @escaping @Sendable (DateInterval) async throws -> LiveContextScreenPage,
         readEntry: @escaping @Sendable (Int64) async throws -> AudioTranscription? = { _ in nil },
         loadSpeakers: @escaping @Sendable (DateInterval, String?) async throws -> CompanionSpeakerPage = { _, _ in .init(items: [], nextCursor: nil, incomplete: false) },
         resolveTurn: @escaping @Sendable (CompanionTurnReference) async throws -> CompanionTurnPresentation = { _ in throw CompanionError.unavailable },
         readSpeaker: @escaping @Sendable (String) async throws -> CompanionSpeakerPresentation? = { _ in nil },
         sourceChanges: (@Sendable () async throws -> ContextRangePresentationService)? = nil,
         speakerChanges: (@Sendable () async throws -> CompanionController)? = nil,
         referenceRecordings: @escaping @Sendable ([AudioTranscription]) async throws -> [V23TranscriptReference] = { _ in [] },
         recordOlderPage: @escaping @Sendable (Int, Bool) async -> Void = { _, _ in },
         readDrafts: @escaping @Sendable () async -> LiveTranscriptionSnapshot = { .init() },
         setDraftTrial: @escaping @Sendable (Bool) async -> Void = { _ in },
         readPreparationStatus: @escaping @Sendable () async -> AudioPreparationStatus? = { nil }) {
        self.loadAudio = loadAudio
        self.loadScreens = loadScreens
        self.readEntry = readEntry
        self.loadSpeakers = loadSpeakers; self.resolveTurn = resolveTurn; self.readSpeaker = readSpeaker; self.sourceChanges = sourceChanges
        self.speakerChanges = speakerChanges
        self.referenceRecordings = referenceRecordings
        self.recordOlderPage = recordOlderPage
        self.readDrafts = readDrafts; self.setDraftTrial = setDraftTrial
        self.readPreparationStatus = readPreparationStatus
    }

    deinit {
        eventRefreshTask?.cancel(); draftRefreshTask?.cancel()
        task?.cancel()
        if let observationID { observationOwner?.removeInvalidationObserver(observationID) }
        if let speakerObservationID { speakerObservationOwner?.removeSpeakerChangeObserver(speakerObservationID) }
    }

    convenience init(coordinator: AppCoordinator) {
        self.init(loadAudio: { interval, cursor, query in
            let reader = try await coordinator.getLiveAudioContextReader()
            return try await reader.getContextPage(from: interval.start, to: interval.end,
                limit: Self.audioPageSize, before: cursor, query: query)
        }, loadScreens: { interval in
            let service = try await coordinator.progressiveRecall()
            let rows = try await DashboardScreenshotIdentityPolicy.readRows(
                sourceGeneration: { try await service.sourceGeneration(source: $0) }
            ) {
                try await coordinator.getMostRecentFramesWithVideoInfo(limit: Self.maximumScreens + 1,
                    filters: FilterCriteria(startDate: interval.start, endDate: interval.end))
            }
            return LiveContextScreenPage(rows: Array(rows.prefix(Self.maximumScreens)), hasMore: rows.count > Self.maximumScreens)
        }, readEntry: { id in
            let reader = try await coordinator.getLiveAudioContextReader()
            return try await reader.getContextEntry(id: id)
        }, loadSpeakers: { interval, cursor in
            try await coordinator.companion().speakerPresentations(from: interval.start, to: interval.end, before: cursor, limit: 16)
        }, resolveTurn: { try await coordinator.companion().resolveTurn($0) },
           readSpeaker: { try await coordinator.companion().speakerPresentation(jobID: $0) },
           speakerChanges: { try await coordinator.companion() }, referenceRecordings: { rows in
               try await coordinator.liveContextSearch().transcriptReferences(rows).compactMap {
                   if case .transcript(let reference) = $0 { return reference }; return nil
               }
           }, recordOlderPage: { count, failed in
               try? await coordinator.recordMetricEvent(metricType: .dashboardTranscriptLoadOlder,
                   metadata: "{\"surface\":\"live_scroll\",\"added\":\(count),\"failed\":\(failed)}")
           }, readDrafts: { await coordinator.liveTranscriptionSnapshot() },
              setDraftTrial: { await coordinator.setLiveTranscriptionEnabled($0) },
              readPreparationStatus: { await coordinator.audioPreparationStatus() })
    }

    func setDraftsEnabled(_ enabled: Bool) async {
        await setDraftTrial(enabled)
        await refreshDrafts()
    }

    func refreshDrafts() async {
        guard active, !Task.isCancelled else { return }
        let token = generation
        let snapshot = await readDrafts()
        let preparation = await readPreparationStatus()
        guard active, generation == token, !Task.isCancelled else { return }
        drafts = snapshot
        preparationStatus = preparation
    }

    /// A burst of commits is one joined read; a commit arriving during that read
    /// requests one more pass so the latest publication cannot be missed.
    func audioTextCommitted() {
        guard active else { return }
        eventRefreshPending = true
        guard eventRefreshTask == nil else { return }
        let id = UUID(); eventRefreshID = id
        eventRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.eventRefreshID == id { self.eventRefreshTask = nil } }
            while self.active && self.eventRefreshPending && !Task.isCancelled {
                self.eventRefreshPending = false
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                await self.refresh(forceAfterJoin: true)
            }
        }
    }

    func draftChanged() {
        guard active else { return }
        draftRefreshPending = true
        guard draftRefreshTask == nil else { return }
        let id = UUID(); draftRefreshID = id
        draftRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.draftRefreshID == id { self.draftRefreshTask = nil } }
            while self.active && self.draftRefreshPending && !Task.isCancelled {
                self.draftRefreshPending = false
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                await self.refreshDrafts()
            }
        }
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        presentationReady = false
        if !value {
            eventRefreshTask?.cancel(); draftRefreshTask?.cancel()
            eventRefreshTask = nil; draftRefreshTask = nil
            eventRefreshID = UUID(); draftRefreshID = UUID()
            eventRefreshPending = false; draftRefreshPending = false
            drafts = .init()
            needsResumeValidation = hasPublishedTranscript || !transcripts.isEmpty || !speakers.isEmpty ||
                selectedExternalAudio != nil || selectedTurn != nil
            if let observationID { observationOwner?.removeInvalidationObserver(observationID) }
            observationID = nil; observationOwner = nil
            if let speakerObservationID { speakerObservationOwner?.removeSpeakerChangeObserver(speakerObservationID) }
            speakerObservationID = nil; speakerObservationOwner = nil
        }
        // Keep the bounded reading snapshot and its cursor scope. The cancelled
        // owner stays retained until refresh joins it, including a rapid reopen.
        invalidate(clear: false)
        if !value { isLoading = false }
    }

    func configure(range: LiveContextRange, from: Date, to: Date, query: String) {
        self.range = range
        customFrom = from
        customTo = to
        self.query = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        followingLive = range != .custom
        invalidate(clear: true)
    }

    func pauseFollowing() {
        guard followingLive else { return }
        followingLive = false
        invalidate(clear: false)
    }

    func selectAudio(_ row: AudioTranscription) {
        guard active, presentationReady else { return }
        followingLive = false
        selectedTurn = nil
        selectedExternalAudio = transcripts.contains { $0.id == row.id } ? nil : row
        selectedAudioID = row.id
        selectedScreenID = nil
        screens = []
        invalidate(clear: false)
    }

    func selectTurn(_ reference: CompanionTurnReference) async throws {
        guard active, presentationReady else { throw CancellationError() }
        let token = generation, epoch = sourceEpoch
        let current = try await resolveTurn(reference)
        try Task.checkCancellation()
        guard active, presentationReady, generation == token, sourceEpoch == epoch else { throw CancellationError() }
        followingLive = false
        selectedTurn = current; selectedAudioID = nil; selectedExternalAudio = nil
        selectedScreenID = nil; screens = []
        invalidate(clear: false)
    }

    func selectScreen(_ row: DashboardScreenshotRow) {
        guard active, presentationReady else { return }
        let wasFollowing = followingLive
        followingLive = false
        selectedScreenID = row.id
        if wasFollowing { invalidate(clear: false) }
    }

    func returnToLive() {
        followingLive = true
        range = .history
        query = ""
        selectedAudioID = nil
        selectedTurn = nil
        selectedExternalAudio = nil
        selectedScreenID = nil
        hasNewerContent = false
        invalidate(clear: false)
    }

    func sourceChanged() { invalidate(clear: true) }

    /// Historical rows are a presentation snapshot, not lasting permission to
    /// play or copy. Read each exact retained row again at the action boundary.
    func validateForAction(_ rows: [AudioTranscription]) async -> Bool {
        guard active, presentationReady, !rows.isEmpty, rows.count <= Self.maximumActionRecordings else { return false }
        let token = generation, epoch = sourceEpoch
        do {
            for row in rows {
                try Task.checkCancellation()
                guard let current = try await readEntry(row.id), LiveContextPresentation.sameRecording(current, row),
                      active, presentationReady, generation == token, sourceEpoch == epoch, !Task.isCancelled else { return false }
            }
            return active && presentationReady && generation == token && sourceEpoch == epoch && !Task.isCancelled
        } catch { return false }
    }

    private func invalidate(clear: Bool) {
        generation &+= 1
        requestRevision &+= 1
        screenReadRevision &+= 1
        task?.cancel()
        isLoading = active
        if clear {
            presentationReady = false
            needsResumeValidation = false
            selectedExternalAudio = nil
            transcripts = []; screens = []; nextCursor = nil
            speakers = []; speakerCursor = nil; transcriptItems = []; selectedTurn = nil
            hasPublishedTranscript = false
            recordingReferences = []
            audioScanIncomplete = false
            speakerError = nil; turnsTruncated = false; speakerCoverageIncomplete = false
            selectedAudioID = nil; selectedScreenID = nil
            audioError = nil; screenError = nil; latestTranscriptAt = nil
            interval = nil; hasNewerContent = false; screensHaveMore = false
        }
    }

    func refresh(now: Date = Date(), loadOlder: Bool = false, forceAfterJoin: Bool = false) async {
        guard active, !Task.isCancelled else { return }
        let generation = generation
        let olderCompletionsAtEntry = olderRefreshCompletions
        while let task {
            let joinedGeneration = taskGeneration
            let joinedLoadsOlder = taskLoadsOlder
            await task.value
            guard active, self.generation == generation, !Task.isCancelled else { return }
            // A head read cannot fulfil an explicit continuation request. Keep
            // one joined owner; multiple older callers still share one page.
            if !forceAfterJoin, joinedGeneration == generation, !task.isCancelled,
               !loadOlder || joinedLoadsOlder || olderRefreshCompletions != olderCompletionsAtEntry { return }
        }
        guard !loadOlder || canLoadOlder else { return }
        let id = UUID(), epoch = sourceEpoch
        isLoading = true
        let owned = Task { [weak self] in
            defer {
                if self?.taskID == id {
                    if loadOlder && !Task.isCancelled {
                        self?.olderRefreshCompletions &+= 1
                        self?.olderPageRevision &+= 1
                    }
                    self?.task = nil; self?.taskID = nil; self?.taskGeneration = nil; self?.taskLoadsOlder = false
                    self?.isLoading = false
                }
            }
            guard let self else { return }
            guard await self.observeSources(generation: generation, epoch: epoch),
                  self.canPublish(generation: generation, epoch: epoch) else { return }
            if self.needsResumeValidation {
                guard await self.revalidateRetainedPresentation(generation: generation, epoch: epoch),
                      self.canPublish(generation: generation, epoch: epoch) else { return }
                self.needsResumeValidation = false
            }
            let retainedWindow = (loadOlder || !self.followingLive) ? self.interval : nil
            guard let window = retainedWindow ?? self.range.interval(now: now, from: self.customFrom, to: self.customTo) else {
                self.audioError = "Choose a start time before the end time."
                // A rejected, cleared scope has no evidence to revalidate. Keep
                // its date controls reachable so the user can repair the range.
                if self.transcripts.isEmpty && self.transcriptItems.isEmpty && self.speakers.isEmpty &&
                    self.screens.isEmpty && self.selectedExternalAudio == nil && self.selectedTurn == nil {
                    self.presentationReady = true
                }
                return
            }
            self.interval = window
            // A fresh head reports arrivals without changing a pinned interval,
            // its visible row identities or its pagination cursor.
            let audioWindow: DateInterval
            if !loadOlder, !self.followingLive, self.range != .custom {
                audioWindow = self.range.interval(now: now, from: self.customFrom, to: self.customTo) ?? window
            } else { audioWindow = window }
            let screenWindow = self.selectedInterval ?? window
            let cursor = loadOlder ? self.nextCursor : nil
            let speakerBefore = loadOlder ? self.speakerCursor : nil
            let readAudio = !loadOlder || (self.nextCursor != nil && self.audioError == nil)
            let readSpeakers = !loadOlder || (self.speakerCursor != nil && self.speakerError == nil)
            let countBefore = self.transcripts.count
            let replaceVisible = self.followingLive || !self.hasPublishedTranscript
            let query = self.query.isEmpty ? nil : self.query
            var proofRows: [AudioTranscription] = []
            // Screens are re-read after suspension. Retained audio has already
            // passed exact validation, so either core lane may reveal its result
            // without exposing an old unvalidated screen while the other waits.
            if !self.presentationReady { self.screens = [] }
            let loadAudio = self.loadAudio, loadScreens = self.loadScreens
            await withTaskGroup(of: LiveContextCoreRead.self) { group in
                if readAudio {
                    group.addTask {
                        do { return .audio(try await Self.readAudioPage(loadAudio, interval: audioWindow, cursor: cursor, query: query)) }
                        catch { return .audioUnavailable(LiveContextAudioReadFailure(error)) }
                    }
                }
                if !loadOlder {
                    group.addTask {
                        do { return .screens(try await loadScreens(screenWindow)) }
                        catch { return .screensUnavailable }
                    }
                }
                for await result in group {
                    guard self.canPublish(generation: generation, epoch: epoch) else {
                        group.cancelAll()
                        return
                    }
                    switch result {
                    case .audio(let page):
                        if !loadOlder { self.latestTranscriptAt = LiveContextPresentation.latestTranscriptDate(page.entries) }
                        if loadOlder {
                            self.followingLive = false
                            let existing = Set(self.transcripts.map(\.id))
                            let additions = page.entries.filter { !existing.contains($0.id) }
                            self.transcripts += additions
                            proofRows = additions
                            self.nextCursor = page.nextCursor
                            self.audioScanIncomplete = page.scanIncomplete
                        } else if replaceVisible {
                            self.transcripts = page.entries
                            let retainedIDs = Set(self.transcripts.map(\.id))
                            self.recordingReferences.removeAll { !retainedIDs.contains($0.rowID) }
                            proofRows = self.transcripts
                            self.nextCursor = page.nextCursor
                            self.audioScanIncomplete = page.scanIncomplete
                            self.hasNewerContent = false
                        } else {
                            self.hasNewerContent = page.entries.first?.id != self.transcripts.first?.id
                        }
                        self.recordAudioReadOutcome(nil)
                        self.projectTranscript()
                    case .audioUnavailable(let failure):
                        self.recordAudioReadOutcome(failure)
                    case .screens(let page):
                        self.screens = Array(page.rows.prefix(Self.maximumScreens))
                        self.screensHaveMore = page.hasMore || page.rows.count > Self.maximumScreens
                        if self.followingLive || self.selectedScreenID == nil { self.selectedScreenID = self.screens.first?.id }
                        self.screenReadRevision &+= 1
                        self.screenError = nil
                    case .screensUnavailable:
                        self.screens = []
                        self.screenReadRevision &+= 1
                        self.screenError = "Recorded screens could not be read."
                    }
                    self.presentationReady = true
                }
            }
            guard self.canPublish(generation: generation, epoch: epoch) else { return }
            // Optional enrichment starts only after both structured core children
            // have joined; cancellation never abandons a reader or starts a rival.
            if readSpeakers { do {
                let page = try await self.loadSpeakers(audioWindow, speakerBefore)
                guard self.canPublish(generation: generation, epoch: epoch) else { return }
                if loadOlder {
                    let existing = Set(self.speakers.map(\.jobID))
                    self.speakers += page.items.filter { !existing.contains($0.jobID) }
                    self.speakerCursor = page.nextCursor
                } else if replaceVisible {
                    self.speakers = page.items
                    self.speakerCursor = page.nextCursor
                } else if page.items.map(\.jobID) != Array(self.speakers.prefix(page.items.count)).map(\.jobID) {
                    self.hasNewerContent = true
                }
                self.speakerCoverageIncomplete = page.incomplete
                self.speakerError = nil
                self.projectTranscript()
            } catch {
                guard self.canPublish(generation: generation, epoch: epoch) else { return }
                self.speakerError = "Saved speaker turns could not be refreshed. Original recordings remain available."
            } }
            // Only eligible first-pass text can ever collapse into an exact
            // original disclosure. Pending recordings need no deduplication proof.
            proofRows = proofRows.filter { $0.transcriptStatus == "transcribed" && $0.transcriptionPass == 1 }
            if !proofRows.isEmpty {
                let proofs = (try? await self.referenceRecordings(proofRows)) ?? []
                guard self.canPublish(generation: generation, epoch: epoch) else { return }
                let refreshedIDs = Set(proofRows.map(\.id))
                self.recordingReferences.removeAll { refreshedIDs.contains($0.rowID) }
                self.recordingReferences += proofs.filter { refreshedIDs.contains($0.rowID) }
                self.projectTranscript()
            }
            if loadOlder, self.canPublish(generation: generation, epoch: epoch) {
                await self.recordOlderPage(max(0, self.transcripts.count - countBefore), self.audioError != nil || self.speakerError != nil)
            }
        }
        task = owned; taskID = id; taskGeneration = generation; taskLoadsOlder = loadOlder
        await withTaskCancellationHandler { await owned.value } onCancel: { owned.cancel() }
    }

    /// Called only by visible trailing rows/the lazy footer. Duplicate visible
    /// rows share one continuation; hiding or changing scope cancels its owner.
    func loadOlderIfNeeded(near itemID: String? = nil) async {
        guard active, presentationReady,
              (nextCursor != nil && audioError == nil) || (speakerCursor != nil && speakerError == nil) else { return }
        if let itemID, !transcriptItems.suffix(10).contains(where: { $0.id == itemID }) { return }
        pauseFollowing()
        await refresh(loadOlder: true)
    }

    /// Retry only the typed pre-query mutex admission failure. Other failures
    /// retain their category, and owner cancellation interrupts the short waits.
    private nonisolated static func readAudioPage(
        _ read: @Sendable (DateInterval, AudioContextCursor?, String?) async throws -> AudioContextPage,
        interval: DateInterval, cursor: AudioContextCursor?, query: String?
    ) async throws -> AudioContextPage {
        var retries = 0
        while true {
            try Task.checkCancellation()
            do {
                let page = try await read(interval, cursor, query)
                try Task.checkCancellation()
                return page
            } catch AudioContextReadError.connectionBusy where retries < 2 {
                retries += 1
                try await Task.sleep(for: .milliseconds(retries == 1 ? 50 : 150))
            }
        }
    }

    private func recordAudioReadOutcome(_ failure: LiveContextAudioReadFailure?) {
        audioError = failure?.message
        guard failure != lastAudioReadFailure else { return }
        lastAudioReadFailure = failure
        // Fixed categories only: no error strings, SQL, source identities,
        // recorded content or recording times enter diagnostics.
        if let failure { Log.warning("live_audio_read category=\(failure.rawValue)", category: .ui) }
        else { Log.info("live_audio_read category=recovered", category: .ui) }
    }

    private func canPublish(generation: UInt64, epoch: UInt64) -> Bool {
        active && self.generation == generation && sourceEpoch == epoch && !Task.isCancelled
    }

    /// Registration belongs to the same owner as reads, so hiding during an
    /// awaited provider acquisition cannot install a late observer.
    private func observeSources(generation: UInt64, epoch: UInt64) async -> Bool {
        if speakerObservationOwner == nil, let speakerChanges {
            do {
                let owner = try await speakerChanges()
                guard canPublish(generation: generation, epoch: epoch) else { return false }
                speakerObservationID = try owner.addSpeakerChangeObserver(invalidate: { [weak self] change in
                    Task { @MainActor [weak self] in self?.speakerChanged(change) }
                })
                speakerObservationOwner = owner
            } catch {
                guard canPublish(generation: generation, epoch: epoch) else { return false }
                withholdForMissingSourceObserver()
                return false
            }
        }
        if observationOwner == nil, let sourceChanges {
            do {
                let owner = try await sourceChanges()
                guard canPublish(generation: generation, epoch: epoch) else { return false }
                observationID = try owner.subscribeSourceChanges { [weak self] change in
                    Task { @MainActor [weak self] in self?.nativeSourceChanged(change) }
                }
                observationOwner = owner
            } catch {
                guard canPublish(generation: generation, epoch: epoch) else { return false }
                withholdForMissingSourceObserver()
                return false
            }
        }
        return canPublish(generation: generation, epoch: epoch)
    }

    private func withholdForMissingSourceObserver() {
        // A configured observer is part of the native admission fence, including
        // the companion observer that forwards source changes in production.
        // Preserve the reading snapshot behind the gate for a verified retry.
        presentationReady = false
        needsResumeValidation = hasPublishedTranscript || !transcripts.isEmpty || !speakers.isEmpty ||
            selectedExternalAudio != nil || selectedTurn != nil
        audioError = "Source updates could not be connected. Retry to verify and reopen this history."
    }

    private func revalidateRetainedPresentation(generation: UInt64, epoch: UInt64) async -> Bool {
        do {
            var validRows: [AudioTranscription] = []
            for row in transcripts {
                let current = try await readEntry(row.id)
                guard canPublish(generation: generation, epoch: epoch) else { return false }
                if let current, LiveContextPresentation.sameRecording(current, row) { validRows.append(row) }
            }
            var external = selectedExternalAudio
            if let retained = external {
                let current = try await readEntry(retained.id)
                guard canPublish(generation: generation, epoch: epoch) else { return false }
                if current.map({ LiveContextPresentation.sameRecording($0, retained) }) != true { external = nil }
            }
            var validSpeakers: [CompanionSpeakerPresentation] = []
            var currentSpeakers: [String: CompanionSpeakerPresentation] = [:]
            var checkedJobs = Set<String>()
            for speaker in speakers {
                // One canonical App lookup validates the complete bounded job,
                // including every turn's correction revision, not just turn zero.
                let current = try await readSpeaker(speaker.jobID)
                guard canPublish(generation: generation, epoch: epoch) else { return false }
                checkedJobs.insert(speaker.jobID)
                if let current {
                    currentSpeakers[speaker.jobID] = current
                    if Self.sameSpeaker(current, speaker) { validSpeakers.append(speaker) }
                }
            }
            var turn = selectedTurn
            if let retained = turn {
                let jobID = retained.reference.jobID
                if !checkedJobs.contains(jobID) {
                    let current = try await readSpeaker(jobID)
                    guard canPublish(generation: generation, epoch: epoch) else { return false }
                    currentSpeakers[jobID] = current
                }
                guard canPublish(generation: generation, epoch: epoch) else { return false }
                let current = currentSpeakers[jobID]
                let index = retained.reference.turnIndex
                if current?.turnReferences.contains(retained.reference) != true ||
                    current?.enhancement.turns.indices.contains(index) != true ||
                    current?.enhancement.turns[index] != retained.turn ||
                    current?.firstPassText != retained.firstPassText ||
                    current?.firstPassSourceIdentity != retained.firstPassSourceIdentity ||
                    current?.firstPassReferences != retained.firstPassReferences {
                    turn = nil
                }
            }
            let removed = validRows.count != transcripts.count || validSpeakers.count != speakers.count ||
                (selectedExternalAudio != nil && external == nil) || (selectedTurn != nil && turn == nil)
            if validRows.count != transcripts.count { latestTranscriptAt = LiveContextPresentation.latestTranscriptDate(validRows) }
            transcripts = validRows; speakers = validSpeakers
            selectedExternalAudio = external; selectedTurn = turn
            if let selectedAudioID, !validRows.contains(where: { $0.id == selectedAudioID }), external?.id != selectedAudioID {
                self.selectedAudioID = nil
            }
            let retainedIDs = Set(validRows.map(\.id))
            recordingReferences.removeAll { !retainedIDs.contains($0.rowID) }
            if removed {
                sourceInvalidationRevision &+= 1
                selectedScreenID = nil; screens = []
                speakerCoverageIncomplete = true
                speakerError = "Some saved context changed while Live was hidden. Return to live to reload it."
                projectTranscript()
            }
            return true
        } catch {
            guard canPublish(generation: generation, epoch: epoch) else { return false }
            audioError = "Saved context could not be verified. Retry before reopening this history."
            return false
        }
    }

    private static func sameSpeaker(_ lhs: CompanionSpeakerPresentation, _ rhs: CompanionSpeakerPresentation) -> Bool {
        lhs.jobID == rhs.jobID && lhs.nativeStoreID == rhs.nativeStoreID &&
        lhs.firstPassText == rhs.firstPassText && lhs.firstPassSourceIdentity == rhs.firstPassSourceIdentity &&
        lhs.enhancement == rhs.enhancement && lhs.corrections == rhs.corrections &&
        lhs.firstPassReferences == rhs.firstPassReferences && lhs.turnReferences == rhs.turnReferences &&
        lhs.sourceDependencies == rhs.sourceDependencies
    }

    private func projectTranscript() {
        guard let interval else { transcriptItems = []; return }
        let projection = LiveTranscriptProjection.make(recordings: transcripts, speakers: speakers, interval: interval,
            recordingReferences: recordingReferences,
            maximumTurns: max(500, speakers.reduce(0) { $0 + $1.enhancement.turns.count }))
        transcriptItems = projection.items; turnsTruncated = projection.truncated
        hasPublishedTranscript = true
        transcriptRevision &+= 1
    }

    /// An explicit name correction may update its retained rows while history stays pinned.
    func replaceSpeaker(_ presentation: CompanionSpeakerPresentation) {
        guard active, let index = speakers.firstIndex(where: { $0.jobID == presentation.jobID }) else { return }
        speakers[index] = presentation
        if selectedTurn?.reference.jobID == presentation.jobID { selectedTurn = nil; selectedScreenID = nil; screens = []; invalidate(clear: false) }
        projectTranscript()
    }

    private static func dependencies(for row: AudioTranscription) -> NativeSourceDependencies {
        .init(targets: Set([NativeSourceTarget.audioRow(row.id)] +
            [row.audioPath, row.batchAudioPath].compactMap { $0.map(NativeSourceTarget.audioBatch) }))
    }

    private func nativeSourceChanged(_ change: NativeSourceMutation) {
        sourceEpoch &+= 1
        task?.cancel() // Every mutation fences reads already in progress.
        guard active else { return }
        if change.dependencies.all { clearRevokedSources(); return }
        let oldAudioCount = transcripts.count, oldSpeakerCount = speakers.count, oldScreenCount = screens.count
        transcripts.removeAll { change.affects(Self.dependencies(for: $0)) }
        speakers.removeAll { change.affects($0.sourceDependencies) }
        var selectionChanged = false
        if let external = selectedExternalAudio, change.affects(Self.dependencies(for: external)) {
            selectedExternalAudio = nil; selectionChanged = true
        }
        if let selectedAudioID, selectedExternalAudio?.id != selectedAudioID,
           !transcripts.contains(where: { $0.id == selectedAudioID }) {
            self.selectedAudioID = nil; selectionChanged = true
        }
        if let selectedTurn, change.affects(selectedTurn.sourceDependencies) {
            self.selectedTurn = nil; selectionChanged = true
        }
        screens.removeAll { change.affects(.init(targets: [.frame($0.frame.id.value), .segment($0.frame.segmentID.value)])) }
        if selectionChanged { screens = []; selectedScreenID = nil }
        if let selectedScreenID, !screens.contains(where: { $0.id == selectedScreenID }) { self.selectedScreenID = nil }
        let audioChanged = transcripts.count != oldAudioCount || speakers.count != oldSpeakerCount || selectionChanged
        let screensChanged = screens.count != oldScreenCount
        guard audioChanged || screensChanged else { return }
        sourceInvalidationRevision &+= 1
        if audioChanged {
            if transcripts.count != oldAudioCount { latestTranscriptAt = LiveContextPresentation.latestTranscriptDate(transcripts) }
            let retainedIDs = Set(transcripts.map(\.id))
            recordingReferences.removeAll { !retainedIDs.contains($0.rowID) }
            projectTranscript()
        }
        // Scoped screen/OCR writes cannot discard unrelated audio, pagination,
        // the pinned interval or the user's reading position.
        invalidate(clear: false)
    }

    private func speakerChanged(_ change: CompanionSpeakerChange) {
        switch change {
        case .source(let mutation): nativeSourceChanged(mutation)
        case .all: nativeSourceChanged(.all)
        case .correction(let jobID, let speakerID):
            sourceEpoch &+= 1; task?.cancel()
            guard active else { return }
            let affected = speakers.contains { $0.jobID == jobID && $0.enhancement.turns.contains { $0.speakerID == speakerID } }
            let selectedAffected = selectedTurn?.reference.jobID == jobID
            guard affected || selectedAffected else { return }
            speakers.removeAll { $0.jobID == jobID }
            if selectedAffected { selectedTurn = nil; selectedScreenID = nil; screens = [] }
            sourceInvalidationRevision &+= 1
            projectTranscript()
            invalidate(clear: false)
        }
    }

    private func clearRevokedSources() {
        let retainedInterval = interval
        sourceInvalidationRevision &+= 1; invalidate(clear: true)
        interval = retainedInterval
    }
}
