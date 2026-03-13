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

/// Manages the audio transcript window as an on-demand floating panel
/// Follows the DashboardWindowController singleton pattern
@MainActor
public class TranscriptWindowController: NSObject {

    // MARK: - Singleton

    public static let shared = TranscriptWindowController()

    // MARK: - Properties

    private(set) var window: NSPanel?
    private var coordinator: AppCoordinator?
    private var hostingController: NSHostingController<TranscriptContentView>?

    /// Whether the transcript window is currently visible
    public private(set) var isVisible = false

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
        Log.info("[TranscriptWindowController] show requested with \(transcriptions.count) transcriptions", category: .ui)

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

        if let hostingController = hostingController, let window = window {
            // Update existing window content
            hostingController.rootView = contentView
            window.makeKeyAndOrderFront(nil)
        } else {
            // Create new panel
            let hosting = NSHostingController(rootView: contentView)
            self.hostingController = hosting

            let panel = TranscriptPanel(
                contentViewController: hosting
            )
            panel.title = "Audio Transcript"
            panel.styleMask = [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView]
            panel.setContentSize(NSSize(width: 500, height: 600))
            panel.minSize = NSSize(width: 350, height: 300)
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.level = .screenSaver + 1
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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
        }

        isVisible = true
    }

    /// Hide the transcript window
    public func hide() {
        guard let window = window, isVisible else { return }
        window.orderOut(nil)
        isVisible = false
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
}

// MARK: - NSWindowDelegate

extension TranscriptWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        isVisible = false
    }
}
