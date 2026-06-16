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

    static func shouldStartRefresh(
        isVisible: Bool,
        isRefreshInFlight: Bool,
        currentTimestamp: Date?,
        lastRefreshedTimestamp: Date?
    ) -> Bool {
        guard isVisible, !isRefreshInFlight, let currentTimestamp else {
            return false
        }
        guard let lastRefreshedTimestamp else {
            return true
        }
        return abs(currentTimestamp.timeIntervalSince(lastRefreshedTimestamp)) >= minimumTimestampDelta
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

    /// Whether the transcript window is currently visible
    public private(set) var isVisible = false

    /// Provides the current timeline timestamp for auto-refresh
    public var currentTimestampProvider: (() -> Date?)?

    /// Timer for periodic refresh while the window is visible
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    /// Last timestamp used for refresh (to avoid redundant queries)
    private var lastRefreshedTimestamp: Date?

    // MARK: - Initialization

    private override init() {
        super.init()
    }

    // MARK: - Configuration

    /// Configure with the app coordinator (call once during app launch)
    public func configure(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Show/Hide

    /// Show the transcript window with transcription data
    public func show(transcriptions: [AudioTranscription], timestamp: Date) {
        Log.info("[TranscriptWindowController] show requested timestamp=\(Log.timestamp(from: timestamp)) count=\(transcriptions.count) existingWindow=\(window != nil) visible=\(isVisible)", category: .ui)
        let wasVisible = isVisible

        let storageRoot = coordinator != nil
            ? URL(fileURLWithPath: NSString(string: "~/Library/Application Support/Retrace").expandingTildeInPath)
            : nil

        let contentView = TranscriptContentView(
            transcriptions: transcriptions,
            timestamp: timestamp,
            storageRoot: storageRoot,
            onClose: { [weak self] in
                self?.hide()
            }
        )

        lastRefreshedTimestamp = timestamp

        if let hostingView = hostingView, let window = window {
            // Update existing window content
            hostingView.rootView = contentView
            window.makeKeyAndOrderFront(nil)
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
            panel.title = "Audio Transcript"
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
            panel.makeKeyAndOrderFront(nil)
            Log.info("[TranscriptWindowController] created transcript panel count=\(transcriptions.count)", category: .ui)
        }

        isVisible = true
        if !wasVisible {
            startRefreshTimer()
        }
    }

    /// Hide the transcript window
    public func hide() {
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
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Auto-Refresh

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
    }

    private func refreshIfNeeded() {
        guard isVisible,
              let provider = currentTimestampProvider,
              let currentTimestamp = provider(),
              let coordinator = coordinator else { return }

        guard TranscriptRefreshPolicy.shouldStartRefresh(
            isVisible: isVisible,
            isRefreshInFlight: refreshTask != nil,
            currentTimestamp: currentTimestamp,
            lastRefreshedTimestamp: lastRefreshedTimestamp
        ) else {
            return
        }

        refreshTask = Task { [weak self, coordinator, currentTimestamp] in
            let windowSeconds: TimeInterval = 30 * 60
            let fromDate = currentTimestamp.addingTimeInterval(-windowSeconds)
            let toDate = currentTimestamp.addingTimeInterval(windowSeconds)

            defer {
                Task { @MainActor [weak self] in
                    self?.refreshTask = nil
                }
            }

            guard let queries = await coordinator.getAudioTranscriptionQueries() else { return }
            let start = CFAbsoluteTimeGetCurrent()
            do {
                Log.debug("[TranscriptWindowController] refresh query started timestamp=\(Log.timestamp(from: currentTimestamp))", category: .ui)
                let transcriptions = try await queries.getTranscriptions(from: fromDate, to: toDate)
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
                Log.recordLatency(
                    "transcript.refresh.query_ms",
                    valueMs: elapsedMs,
                    category: .ui,
                    summaryEvery: 10,
                    warningThresholdMs: 100,
                    criticalThresholdMs: 500
                )
                Log.info("[TranscriptWindowController] refresh query completed count=\(transcriptions.count) elapsed=\(String(format: "%.1f", elapsedMs))ms", category: .ui)
                await MainActor.run {
                    guard self?.isVisible == true else { return }
                    self?.show(transcriptions: transcriptions, timestamp: currentTimestamp)
                }
            } catch {
                Log.warning("[TranscriptWindowController] Refresh failed: \(error)", category: .ui)
            }
        }
    }
}

// MARK: - NSWindowDelegate

extension TranscriptWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        Log.info("[TranscriptWindowController] windowWillClose", category: .ui)
        isVisible = false
        stopRefreshTimer()
    }
}
