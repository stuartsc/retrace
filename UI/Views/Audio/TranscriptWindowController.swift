import AppKit
import SwiftUI
import App
import Database
import Shared

/// Manages the audio transcript window as an on-demand window
/// Follows the DashboardWindowController singleton pattern
@MainActor
public class TranscriptWindowController: NSObject {

    // MARK: - Singleton

    public static let shared = TranscriptWindowController()

    // MARK: - Properties

    private(set) var window: NSWindow?
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

        let contentView = TranscriptContentView(
            transcriptions: transcriptions,
            timestamp: timestamp,
            onClose: { [weak self] in
                self?.hide()
            }
        )

        if let hostingController = hostingController, let window = window {
            // Update existing window content
            hostingController.rootView = contentView
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Create new window
            let hosting = NSHostingController(rootView: contentView)
            self.hostingController = hosting

            let window = NSWindow(contentViewController: hosting)
            window.title = "Audio Transcript"
            window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 500, height: 600))
            window.minSize = NSSize(width: 350, height: 300)
            window.center()
            window.level = .screenSaver + 1
            window.collectionBehavior = [.managed, .participatesInCycle]
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor.windowBackgroundColor
            window.delegate = self

            self.window = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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
            if let window = window, window.isKeyWindow && NSApp.isActive {
                hide()
            } else {
                bringToFront()
            }
        } else {
            show(transcriptions: transcriptions, timestamp: timestamp)
        }
    }

    /// Bring transcript window to front if visible
    public func bringToFront() {
        guard let window = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - NSWindowDelegate

extension TranscriptWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        isVisible = false
    }
}
