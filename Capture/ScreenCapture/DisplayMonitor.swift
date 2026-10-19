import Foundation
import CoreGraphics
import ScreenCaptureKit
import AppKit
import ApplicationServices
import Shared

/// Replace only native lookups in tests. Production selection shares exactly
/// the same visible-window and display-area rules as capture attribution.
struct CaptureDisplayEnvironment: Sendable {
    let frontmostWindowBounds: @Sendable () async -> CGRect?
    let displayForBounds: @Sendable (CGRect) -> UInt32?
    let mainDisplayID: @Sendable () -> UInt32
    let accessibilityPermission: @Sendable () -> Bool

    static let live = Self(frontmostWindowBounds: {
        guard let pid = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication?.processIdentifier }),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return CapturedWindowGeometry.firstWindow(processID: pid, in: windows)?.bounds
    }, displayForBounds: { CapturedWindowGeometry.displayID(for: $0) },
        mainDisplayID: { CGMainDisplayID() },
        accessibilityPermission: { PermissionMonitor.shared.hasAccessibilityPermission() })
}

/// Monitors and provides information about available displays
actor DisplayMonitor {

    // MARK: - Properties

    private var cachedDisplays: [DisplayInfo] = []
    private var lastRefresh: Date?
    private let cacheValidityDuration: TimeInterval = 5.0 // Refresh every 5 seconds
    private let environment: CaptureDisplayEnvironment

    init(environment: CaptureDisplayEnvironment = .live) { self.environment = environment }

    // MARK: - Public Methods

    /// Get all available displays
    /// Results are cached for performance
    func getAvailableDisplays() async throws -> [DisplayInfo] {
        // Return cached results if still valid
        if let lastRefresh = lastRefresh,
           Date().timeIntervalSince(lastRefresh) < cacheValidityDuration {
            return cachedDisplays
        }

        // Refresh display list
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )

        let mainDisplayID = CGMainDisplayID()
        let displays = content.displays.map { display in
            DisplayInfo(
                id: display.displayID,
                width: display.width,
                height: display.height,
                scaleFactor: getScaleFactor(for: display.displayID),
                isMain: display.displayID == mainDisplayID,
                name: getDisplayName(for: display.displayID)
            )
        }

        cachedDisplays = displays
        lastRefresh = Date()

        return displays
    }

    /// Get the display containing the focused window (active display)
    /// This may differ from the main display in multi-monitor setups
    func getFocusedDisplay() async throws -> DisplayInfo? {
        let displays = try await getAvailableDisplays()

        // Get the display containing the frontmost window
        let activeDisplayID = await getActiveDisplayID()

        // Try to find the active display
        if let activeDisplay = displays.first(where: { $0.id == activeDisplayID }) {
            return activeDisplay
        }

        // Fallback to main display
        return displays.first { $0.isMain }
    }

    /// Get the display ID of the currently active display (contains focused window)
    /// Uses the frontmost window's position to determine which display is active
    /// This is more accurate than mouse position for keyboard-driven workflows
    func getActiveDisplayID() async -> UInt32 {
        let (displayID, _) = await getActiveDisplayIDWithPermissionStatus()
        return displayID
    }

    /// Get the checked WindowServer display and the independently observed AX permission.
    /// Returns: (displayID, hasAXPermission)
    func getActiveDisplayIDWithPermissionStatus() async -> (UInt32, Bool) {
        let hasAXPermission = environment.accessibilityPermission()
        if let bounds = await environment.frontmostWindowBounds(),
           let displayID = environment.displayForBounds(bounds) {
            return (displayID, hasAXPermission)
        }
        // Missing geometry is not proof of a permitted capture. The pixel
        // sequencer still requires matching complete context on this display.
        return (environment.mainDisplayID(), hasAXPermission)
    }

    /// Get display by ID
    func getDisplay(by id: UInt32) async throws -> DisplayInfo? {
        let displays = try await getAvailableDisplays()
        return displays.first { $0.id == id }
    }

    /// Force refresh of display cache
    func refreshDisplays() async throws -> [DisplayInfo] {
        lastRefresh = nil
        return try await getAvailableDisplays()
    }

    // MARK: - Private Helpers

    /// Get the scale factor (Retina multiplier) for a display
    private func getScaleFactor(for displayID: UInt32) -> Double {
        // Get the CGDisplay mode to determine scale factor
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            return 1.0
        }

        let pixelWidth = mode.pixelWidth
        let width = mode.width

        // Scale factor is the ratio of pixel width to logical width
        return Double(pixelWidth) / Double(width)
    }

    /// Get a human-readable name for the display
    private func getDisplayName(for displayID: UInt32) -> String? {
        // Try to get the display name from IOKit
        // For simplicity, we'll return a basic description
        // A full implementation would query IOKit for the actual display name

        if displayID == CGMainDisplayID() {
            return "Main Display"
        }

        return "Display \(displayID)"
    }
}
