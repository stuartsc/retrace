import Foundation
import AppKit
import ApplicationServices
import Shared

protocol FrontmostMetadataProviding: Sendable {
    func getFrontmostAppInfo(includeBrowserURL: Bool) async -> FrameMetadata
}

/// Provides information about the currently active application
struct AppInfoProvider: FrontmostMetadataProviding {

    /// A bounded metadata snapshot of the originally notified process. No OCR or AppleScript.
    /// Called from the activity worker, never the main actor.
    func activityContext(for app: ActivityApplicationSnapshot, isStillFocused: Bool,
                         config: CaptureConfig) -> ActivityContext? {
        guard !config.excludedAppBundleIDs.contains(app.bundleID),
              !["com.apple.loginwindow", "com.apple.SecurityAgent"].contains(app.bundleID) else { return nil }
        let browser = BrowserURLExtractor.isBrowser(app.bundleID)
        guard isStillFocused else {
            // Cannot safely establish private/title/URL exclusions for an unsampled old window.
            guard !browser, config.redactWindowTitlePatterns.isEmpty, config.redactBrowserURLPatterns.isEmpty else { return nil }
            return ActivityContext(appBundleID: app.bundleID, appName: app.name, processID: app.pid,
                                   processGeneration: app.generation, uncertainty: ["Window was not sampled before focus changed"])
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let window = windows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? Int32) == app.pid &&
                  ($0[kCGWindowLayer as String] as? Int) == 0 &&
                  ($0[kCGWindowIsOnscreen as String] as? Bool) == true
              }) else { return nil }
        let title = window[kCGWindowName as String] as? String
        let lower = title?.lowercased() ?? ""
        let privatePatterns = ["incognito", "private browsing", "inprivate", "(private)"] + config.customPrivateWindowPatterns
        if config.excludePrivateWindows && browser && (title == nil || privatePatterns.contains(where: { lower.contains($0.lowercased()) })) { return nil }
        if config.redactWindowTitlePatterns.contains(where: { !$0.isEmpty && lower.contains($0.lowercased()) }) { return nil }
        // Until a URL has been validated, URL-redacted applications have unknown activity coverage.
        if browser && !config.redactBrowserURLPatterns.isEmpty { return nil }
        let windowID = window[kCGWindowNumber as String] as? UInt32
        let visibleWindowIDs = Set(windows.compactMap { item -> UInt32? in
            guard (item[kCGWindowOwnerPID as String] as? Int32) == app.pid,
                  (item[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return item[kCGWindowNumber as String] as? UInt32
        })
        let windowGeneration = windowID.flatMap {
            ObservedWindowGenerations.shared.generation(processID: app.pid, processGeneration: app.generation,
                windowID: $0, visibleWindowIDs: visibleWindowIDs)
        }
        let bounds = (window[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        var displayID: UInt32?
        if let bounds {
            var displays = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            if CGGetDisplaysWithRect(bounds, 16, &displays, &count) == .success {
                displayID = displays.prefix(Int(count)).max(by: {
                    CGDisplayBounds($0).intersection(bounds).area < CGDisplayBounds($1).intersection(bounds).area
                })
            }
        }
        let adapter: String
        switch app.bundleID.lowercased() {
        case "com.microsoft.word": adapter = "word-document-v1"
        case "com.microsoft.excel": adapter = "excel-document-v1"
        case "com.openai.chat": adapter = "chatgpt-conversation-v1"
        case let id where id.contains("codex"): adapter = "codex-session-v1"
        case let id where id.contains("claude"): adapter = "claude-conversation-v1"
        case let id where id.contains("cursor"): adapter = "cursor-window-v1"
        case "com.apple.finder": adapter = "finder-window-v1"
        default: adapter = browser ? "browser-window-v1" : "window-metadata-v1"
        }
        return ActivityContext(appBundleID: app.bundleID, appName: app.name, processID: app.pid,
                               processGeneration: app.generation, windowID: windowID, windowGeneration: windowGeneration, windowTitle: title,
                               displayID: displayID, adapter: adapter,
                               uncertainty: ["Document and pane identity unavailable; focus is not engagement"])
    }

    // MARK: - App Info Retrieval

    /// Read only the captured process's visible focused-window document attribute.
    /// Never walks hidden children or substitutes a newly frontmost application.
    func activityDocumentContext(_ context: ActivityContext, app: ActivityApplicationSnapshot) -> ActivityContext? {
        guard context.windowID != nil, context.windowGeneration != nil,
              AXIsProcessTrusted(), app.pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let element = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.1)
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
              CapturedURLPolicy.sanitizeLabel(titleValue as? String) == context.windowTitle,
              uniquelyMatchesCapturedWindow(window, context: context) else { return nil }
        var documentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &documentValue) == .success,
              let raw = documentValue as? String, let safe = CapturedURLPolicy.sanitize(raw),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let top = windows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? Int32) == app.pid && ($0[kCGWindowLayer as String] as? Int) == 0
              }), (top[kCGWindowNumber as String] as? UInt32) == context.windowID,
              CapturedURLPolicy.sanitizeLabel(top[kCGWindowName as String] as? String) == context.windowTitle else { return nil }
        var focusedAfter: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focusedAfter) == .success,
              let focusedAfter, CFEqual(window, focusedAfter),
              uniquelyMatchesCapturedWindow(window, context: context) else { return nil }
        return ActivityContext(appBundleID: context.appBundleID, appName: context.appName,
                               processID: context.processID, processGeneration: context.processGeneration,
                               windowID: context.windowID, windowGeneration: context.windowGeneration,
                               windowTitle: context.windowTitle, displayID: context.displayID,
                               documentID: CapturedURLPolicy.navigationIdentity(raw), safeURL: safe,
                               adapter: context.adapter,
                               uncertainty: ["Document identity is URL-derived; pane and background execution unavailable"])
    }

    /// Public AX has no portable WindowServer ID attribute. Require exactly one
    /// same-process visible window matching the focused AX window's geometry and
    /// title; ambiguous same-title/overlapping windows stay unenriched.
    private func uniquelyMatchesCapturedWindow(_ window: AXUIElement, context: ActivityContext) -> Bool {
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return false }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let matches = windows.compactMap { item -> UInt32? in
            guard (item[kCGWindowOwnerPID as String] as? Int32) == context.processID,
                  (item[kCGWindowLayer as String] as? Int) == 0,
                  CapturedURLPolicy.sanitizeLabel(item[kCGWindowName as String] as? String) == context.windowTitle,
                  let dictionary = item[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  abs(bounds.minX - position.x) <= 1, abs(bounds.minY - position.y) <= 1,
                  abs(bounds.width - size.width) <= 1, abs(bounds.height - size.height) <= 1 else { return nil }
            return item[kCGWindowNumber as String] as? UInt32
        }
        return matches.count == 1 && matches.first == context.windowID
    }

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

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
