import Foundation
import AppKit
import ApplicationServices
import Shared

/// Provides information about the currently active application
struct AppInfoProvider: Sendable {

    // MARK: - App Info Retrieval

    /// Get information about the frontmost application
    /// - Returns: FrameMetadata with app info, or minimal metadata if unavailable
    /// - Parameter includeBrowserURL: Whether browser URL extraction should run (can be expensive)
    func getFrontmostAppInfo(includeBrowserURL: Bool = true) async -> FrameMetadata {
        // Read NSWorkspace state on main actor, then do expensive work off-main.
        guard let frontApp = await MainActor.run(body: {
            NSWorkspace.shared.frontmostApplication
        }) else {
            return FrameMetadata(displayID: CGMainDisplayID())
        }

        // Use bundleIdentifier if available, otherwise check if it's the current app (dev build)
        var bundleID = frontApp.bundleIdentifier
        var appName = frontApp.localizedName

        // Dev build fix: if bundleID is nil but this is Retrace (same PID), use known bundle ID
        if bundleID == nil && frontApp.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            bundleID = Bundle.main.bundleIdentifier ?? "io.retrace.app"
            appName = appName ?? "Retrace"
        }

        let isCurrentProcess = frontApp.processIdentifier == ProcessInfo.processInfo.processIdentifier

        // Get window title via Accessibility API
        let windowName = getWindowTitle(
            for: frontApp.processIdentifier,
            bundleID: bundleID,
            appName: appName
        )

        // Get URL metadata from the active app window if available.
        // Limit extraction to known browsers/web apps plus Finder path context.
        var browserURL: String? = nil
        if includeBrowserURL,
           !isCurrentProcess,
           let bundleID,
           (BrowserURLExtractor.isBrowser(bundleID) || bundleID == "com.apple.finder") {
            let urlExtractionStart = CFAbsoluteTimeGetCurrent()
            browserURL = await BrowserURLExtractor.getURL(
                bundleID: bundleID,
                pid: frontApp.processIdentifier,
                windowCacheKey: windowName ?? appName
            )
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - urlExtractionStart) * 1000
            if elapsedMs >= 250 {
                Log.warning(
                    "[AppInfoProvider] Slow browser URL extraction bundle=\(bundleID), pid=\(frontApp.processIdentifier), elapsed=\(String(format: "%.1f", elapsedMs))ms, foundURL=\(browserURL != nil)",
                    category: .capture
                )
            } else if elapsedMs >= 120 {
                Log.debug(
                    "[AppInfoProvider] Browser URL extraction bundle=\(bundleID), pid=\(frontApp.processIdentifier), elapsed=\(String(format: "%.1f", elapsedMs))ms, foundURL=\(browserURL != nil)",
                    category: .capture
                )
            }
        }

        return FrameMetadata(
            appBundleID: bundleID,
            appName: appName,
            windowName: windowName,
            browserURL: browserURL,
            displayID: CGMainDisplayID()
        )
    }

    // MARK: - Private Helpers

    /// Get the title of the focused window.
    /// Uses AX first, then falls back to CGWindow metadata for apps/PWAs that
    /// omit AXTitle on their focused window.
    /// - Parameters:
    ///   - pid: Process ID of the application
    ///   - bundleID: App bundle ID (used for PWA-specific fallback behavior)
    ///   - appName: App display name
    /// - Returns: Window title if available
    private func getWindowTitle(for pid: pid_t, bundleID: String?, appName: String?) -> String? {
        // Avoid AX reads against our own process; use lightweight fallbacks instead.
        if pid == ProcessInfo.processInfo.processIdentifier {
            if let title = getWindowTitleFromWindowList(for: pid) {
                return title
            }
            return normalizedWindowTitle(appName)
        }

        // 1) AX focused-window title
        if let title = normalizedWindowTitle(PermissionMonitor.shared.safeGetWindowTitle(for: pid)) {
            return title
        }

        // 2) CGWindow fallback (works for many PWA-style windows)
        if let title = getWindowTitleFromWindowList(for: pid) {
            return title
        }

        // 3) Last-resort fallback for app-shim PWAs
        if let bundleID = bundleID,
           bundleID.hasPrefix("com.google.Chrome.app."),
           let appName = normalizedWindowTitle(appName) {
            return appName
        }

        return nil
    }

    private func normalizedWindowTitle(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        return title
    }

    /// Fallback title extraction via CoreGraphics window list.
    /// Uses front-to-back ordering returned by CGWindowListCopyWindowInfo.
    private func getWindowTitleFromWindowList(for pid: pid_t) -> String? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid else {
                continue
            }

            // Layer 0: normal app windows
            let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 {
                continue
            }

            let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false
            if !isOnScreen {
                continue
            }

            if let title = normalizedWindowTitle(windowInfo[kCGWindowName as String] as? String) {
                return title
            }
        }

        return nil
    }

    /// Check if accessibility permissions are granted
    /// Uses the central PermissionMonitor for consistent checking
    static func hasAccessibilityPermission() -> Bool {
        return PermissionMonitor.shared.hasAccessibilityPermission()
    }

    /// Request accessibility permission (shows system dialog)
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
