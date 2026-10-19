import CoreGraphics
import Foundation

/// Shared WindowServer selection for capture routing and pixel attribution.
/// AX enrichment may add document metadata; it does not choose another screen.
enum CapturedWindowGeometry {
    struct Window {
        let index: Int
        let windowID: UInt32
        let bounds: CGRect
    }

    static func firstWindow(processID: Int32, in windows: [[String: Any]]) -> Window? {
        guard processID > 0, windows.count <= 4096 else { return nil }
        for (index, window) in windows.enumerated() {
            guard (window[kCGWindowOwnerPID as String] as? Int32) == processID,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowIsOnscreen as String] as? Bool) == true,
                  let alpha = window[kCGWindowAlpha as String] as? Double,
                  alpha.isFinite, alpha > 0, alpha <= 1,
                  let id = window[kCGWindowNumber as String] as? UInt32, id > 0,
                  let dictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  valid(bounds), bounds.width > 1, bounds.height > 1 else { continue }
            return .init(index: index, windowID: id, bounds: bounds)
        }
        return nil
    }

    static func displayID(for bounds: CGRect) -> UInt32? {
        guard valid(bounds) else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetDisplaysWithRect(bounds, 16, &displays, &count) == .success else { return nil }
        return displayID(for: bounds, displays: displays.prefix(Int(count)).map { ($0, CGDisplayBounds($0)) })
    }

    static func displayID(for bounds: CGRect, displays: [(id: UInt32, bounds: CGRect)]) -> UInt32? {
        guard valid(bounds) else { return nil }
        var best: (id: UInt32, area: CGFloat)?
        for display in displays where display.id > 0 && valid(display.bounds) {
            let intersection = display.bounds.intersection(bounds)
            guard valid(intersection) else { continue }
            let area = intersection.width * intersection.height
            guard area.isFinite, area > 0 else { continue }
            if let best, area < best.area || (area == best.area && display.id >= best.id) { continue }
            best = (display.id, area)
        }
        return best?.id
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite &&
            rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
            rect.width > 0 && rect.height > 0 && rect.maxX.isFinite && rect.maxY.isFinite
    }
}
