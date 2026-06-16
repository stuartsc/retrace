import AppKit
import ApplicationServices
import Foundation
import Shared

public enum DictationTargetContextProvider {
    @MainActor
    public static func current() -> DictationTargetContext? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return DictationTargetContext(
            bundleID: frontApp.bundleIdentifier,
            appName: frontApp.localizedName,
            windowTitle: focusedWindowTitle(pid: frontApp.processIdentifier)
        )
    }

    @MainActor
    private static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let appRef = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let window = windowValue else {
            return nil
        }

        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success else {
            return nil
        }

        return titleValue as? String
    }
}
