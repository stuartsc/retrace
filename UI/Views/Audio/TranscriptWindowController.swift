import AppKit
import SwiftUI
import App
import Database
import Shared

/// Floating panel that can become key window above the timeline
private final class TranscriptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum TranscriptRefreshPolicy {
    static let minimumTimestampDelta: TimeInterval = 5.0
    static let stationaryRefreshInterval: TimeInterval = 15.0

    static func shouldStartRefresh(
        isVisible: Bool,
        isRefreshInFlight: Bool,
        currentTimestamp: Date?,
        lastRefreshedTimestamp: Date?,
        lastRefreshAttemptAt: Date? = nil,
        now: Date = Date()
    ) -> Bool {
        guard isVisible, !isRefreshInFlight, let currentTimestamp else {
            return false
        }
        guard let lastRefreshedTimestamp else {
            return true
        }
        return abs(currentTimestamp.timeIntervalSince(lastRefreshedTimestamp)) >= minimumTimestampDelta
            || lastRefreshAttemptAt.map { now.timeIntervalSince($0) >= stationaryRefreshInterval } == true
    }
}

/// Manages the audio transcript window as an on-demand floating panel
/// Follows the DashboardWindowController singleton pattern
@MainActor
public class TranscriptWindowController: NSObject {

    // MARK: - Singleton

    public static let shared = TranscriptWindowController()

    // MARK: - Properties

    private(set) var window: NSPanel?
    private var coordinator: AppCoordinator?
    private var hostingView: FirstMouseHostingView<TranscriptContentView>?
    private var playback: TranscriptAudioPlayback?
    private var revealTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private var openingTimestamp: Date?
    private var openGeneration = UUID()
    private var refreshGeneration = UUID()
    private let presentWindow: (NSPanel) -> Void

    /// Whether the transcript window is currently visible
    public private(set) var isVisible = false

    /// Provides the current timeline timestamp for auto-refresh
    public var currentTimestampProvider: (() -> Date?)? {
        didSet {
            cancelOpen()
            // Keep the old task owned until it returns; a replacement provider must
            // neither publish its result nor create overlapping refresh reads.
            refreshTask?.cancel()
            lastRefreshedTimestamp = nil
            lastRefreshAttemptAt = nil
        }
    }

    /// Timer for periodic refresh while the window is visible
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var loadRecordings: (@Sendable (Date) async throws -> TranscriptRecordingPage)?
    private var lastRefreshAttemptAt: Date?

    /// Last timestamp used for refresh (to avoid redundant queries)
    private var lastRefreshedTimestamp: Date?

    // MARK: - Initialization

    private override init() {
        presentWindow = { $0.makeKeyAndOrderFront(nil) }
        super.init()
    }

    /// Keeps lifecycle tests on real panels without putting a window on the shared desktop.
    init(playback: TranscriptAudioPlayback, presentWindow: @escaping (NSPanel) -> Void,
         loadRecordings: (@Sendable (Date) async throws -> TranscriptRecordingPage)? = nil) {
        self.playback = playback
        self.presentWindow = presentWindow
        self.loadRecordings = loadRecordings
        super.init()
    }

    // MARK: - Configuration

    /// Configure with the app coordinator (call once during app launch)
    public func configure(coordinator: AppCoordinator) {
        if self.coordinator === coordinator { return }
        // A different recording source invalidates rows and reads from the old owner.
        hide()
        stopRefreshTimer()
        playback?.stop(reason: .closed)
        revealTask?.cancel()
        self.coordinator = coordinator
        loadRecordings = { timestamp in
            guard let queries = await coordinator.getAudioTranscriptionQueries() else {
                throw TranscriptRecordingLoadError.unavailable
            }
            return try await TranscriptRecordingLoader.load(queries: queries, at: timestamp)
        }
        playback = TranscriptAudioPlayback(resolve: { request in
            let root = await coordinator.getAudioStorageDirectory()
            return try await TranscriptAudioFileResolver.resolve(request: request, storageRoot: root)
        }, onEvent: { event in
            Task {
                try? await coordinator.recordMetricEvent(metricType: .audioTranscriptPlayback, metadata: event.metadata)
            }
        })
    }

    // MARK: - Show/Hide

    /// Load the same bounded recording page used by refresh before an explicit open.
    func open(at timestamp: Date) async {
        guard !Task.isCancelled, let loadRecordings else { return }
        if let openTask, openingTimestamp == timestamp {
            // A duplicate caller joins; only the original caller owns cancellation.
            await openTask.value
            return
        }
        cancelOpen()
        refreshTask?.cancel()
        let generation = openGeneration
        let task = Task { [weak self] in
            defer {
                if self?.openGeneration == generation {
                    self?.openTask = nil
                    self?.openingTimestamp = nil
                }
            }
            let start = CFAbsoluteTimeGetCurrent()
            do {
                let page = try await loadRecordings(timestamp)
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
                Log.recordLatency("transcript.open.query_ms", valueMs: elapsedMs, category: .ui,
                    summaryEvery: 10, warningThresholdMs: 100, criticalThresholdMs: 500)
                guard !Task.isCancelled, self?.openGeneration == generation,
                      self?.currentTimestampProvider?() == timestamp else { return }
                self?.show(transcriptions: page.transcriptions, timestamp: timestamp, isTruncated: page.isTruncated)
            } catch {
                if !Task.isCancelled { Log.warning("[TranscriptWindowController] Open failed: \(error)", category: .ui) }
            }
        }
        openingTimestamp = timestamp
        openTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in self?.cancelOpen(ifGeneration: generation) }
        }
    }

    private func cancelOpen(ifGeneration generation: UUID? = nil) {
        if let generation, generation != openGeneration { return }
        openTask?.cancel()
        openTask = nil
        openingTimestamp = nil
        openGeneration = UUID()
    }

    /// Show the transcript window with transcription data
    public func show(transcriptions: [AudioTranscription], timestamp: Date,
                     isTruncated: Bool = false, bringToFront: Bool = true) {
        Log.info("[TranscriptWindowController] show requested timestamp=\(Log.timestamp(from: timestamp)) count=\(transcriptions.count) existingWindow=\(window != nil) visible=\(isVisible)", category: .ui)
        let wasVisible = isVisible
        guard let playback else { return }
        playback.retainSelection(in: transcriptions.map(TranscriptAudioRequest.init))

        let contentView = TranscriptContentView(
            transcriptions: transcriptions,
            timestamp: timestamp,
            isTruncated: isTruncated,
            playback: playback,
            onReveal: { [weak self] request in self?.reveal(request) },
            onClose: { [weak self] in
                self?.hide()
            }
        )

        lastRefreshedTimestamp = timestamp
        lastRefreshAttemptAt = Date()

        if let hostingView = hostingView, let window = window {
            // Update existing window content
            hostingView.rootView = contentView
            if bringToFront { presentWindow(window) }
            Log.info("[TranscriptWindowController] updated existing transcript panel count=\(transcriptions.count)", category: .ui)
        } else {
            // Create new panel with custom hosting view for scroll support
            let hosting = FirstMouseHostingView(rootView: contentView)
            self.hostingView = hosting

            let panel = TranscriptPanel(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.contentView = hosting
            panel.title = "Audio Recordings"
            panel.minSize = NSSize(width: 350, height: 300)
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.level = .screenSaver + 1
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .participatesInCycle]
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.backgroundColor = NSColor.windowBackgroundColor
            panel.delegate = self

            // Position to the right side of screen
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let x = screenFrame.maxX - 520
                let y = screenFrame.midY - 300
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }

            self.window = panel
            if bringToFront { presentWindow(panel) }
            Log.info("[TranscriptWindowController] created transcript panel count=\(transcriptions.count)", category: .ui)
        }

        isVisible = true
        if !wasVisible {
            startRefreshTimer()
        }
    }

    /// Hide the transcript window
    public func hide() {
        cancelOpen()
        playback?.stop(reason: .closed)
        revealTask?.cancel()
        revealTask = nil
        guard let window = window, isVisible else { return }
        Log.info("[TranscriptWindowController] hide requested", category: .ui)
        window.orderOut(nil)
        isVisible = false
        stopRefreshTimer()
    }

    /// Toggle transcript window visibility
    public func toggle(transcriptions: [AudioTranscription], timestamp: Date) {
        if isVisible {
            hide()
        } else {
            show(transcriptions: transcriptions, timestamp: timestamp)
        }
    }

    /// Bring transcript window to front if visible
    public func bringToFront() {
        guard let window = window else { return }
        presentWindow(window)
    }

    // MARK: - Auto-Refresh

    private func reveal(_ request: TranscriptAudioRequest) {
        guard let coordinator else { return }
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            do {
                let root = await coordinator.getAudioStorageDirectory()
                let url = try await TranscriptAudioFileResolver.resolveURL(request: request, storageRoot: root)
                try Task.checkCancellation()
                guard self?.isVisible == true, self?.coordinator === coordinator else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                if !Task.isCancelled { Log.warning("[TranscriptWindowController] Audio reveal unavailable", category: .ui) }
            }
        }
    }

    private func startRefreshTimer() {
        stopRefreshTimer()
        Log.debug("[TranscriptWindowController] refresh timer started", category: .ui)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshIfNeeded()
            }
        }
    }

    private func stopRefreshTimer() {
        if refreshTimer != nil {
            Log.debug("[TranscriptWindowController] refresh timer stopped", category: .ui)
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration = UUID()
    }

    @discardableResult
    func refreshIfNeeded(now: Date = Date()) -> Task<Void, Never>? {
        guard isVisible, openTask == nil,
              let provider = currentTimestampProvider,
              let currentTimestamp = provider(),
              let loadRecordings else { return nil }

        guard TranscriptRefreshPolicy.shouldStartRefresh(
            isVisible: isVisible,
            isRefreshInFlight: refreshTask != nil,
            currentTimestamp: currentTimestamp,
            lastRefreshedTimestamp: lastRefreshedTimestamp,
            lastRefreshAttemptAt: lastRefreshAttemptAt,
            now: now
        ) else {
            return nil
        }

        let generation = refreshGeneration
        // Back off after unsuccessful reads too, rather than retrying each timer tick.
        lastRefreshedTimestamp = currentTimestamp
        lastRefreshAttemptAt = now
        refreshTask = Task { [weak self, currentTimestamp] in
            defer {
                if self?.refreshGeneration == generation { self?.refreshTask = nil }
            }

            let start = CFAbsoluteTimeGetCurrent()
            do {
                Log.debug("[TranscriptWindowController] refresh query started timestamp=\(Log.timestamp(from: currentTimestamp))", category: .ui)
                let page = try await loadRecordings(currentTimestamp)
                let transcriptions = page.transcriptions
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
                Task.detached(priority: .utility) {
                    Log.recordLatency(
                        "transcript.refresh.query_ms", valueMs: elapsedMs, category: .ui,
                        summaryEvery: 10, warningThresholdMs: 100, criticalThresholdMs: 500
                    )
                }
                Log.info("[TranscriptWindowController] refresh query completed count=\(transcriptions.count) elapsed=\(String(format: "%.1f", elapsedMs))ms", category: .ui)
                await MainActor.run {
                    guard !Task.isCancelled, self?.isVisible == true,
                          self?.refreshGeneration == generation,
                          self?.currentTimestampProvider?() == currentTimestamp else { return }
                    self?.show(transcriptions: transcriptions, timestamp: currentTimestamp,
                        isTruncated: page.isTruncated, bringToFront: false)
                }
            } catch {
                if !Task.isCancelled {
                    Log.warning("[TranscriptWindowController] Refresh failed: \(error)", category: .ui)
                }
            }
        }
        return refreshTask
    }
}

// MARK: - NSWindowDelegate

extension TranscriptWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        cancelOpen()
        Log.info("[TranscriptWindowController] windowWillClose", category: .ui)
        playback?.stop(reason: .closed)
        revealTask?.cancel()
        revealTask = nil
        isVisible = false
        stopRefreshTimer()
    }
}
