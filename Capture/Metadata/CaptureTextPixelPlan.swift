import CoreGraphics
import Foundation
import Shared

/// Ephemeral composition proof from the plan that will actually read pixels.
/// Raw window titles and native window IDs never leave Capture in this value.
struct CaptureTextPixelProof: Sendable {
    enum CurrentFailure: String, Sendable {
        case inventoryUnavailable, displayGeometryChanged, windowCountChanged
        case windowOrderChanged, windowProcessChanged, windowBoundsChanged
        case windowLayerChanged, windowAlphaChanged, windowTitleChanged
    }
    enum WindowMatch: String, Sendable {
        case matched, invalidInput, absent, ambiguous, wrongWindow, wrongDisplay
    }
    struct Window: Sendable {
        let id: UInt32
        let processID: Int32
        let title: String
        let bounds: CGRect
        let layer: Int
        let alpha: Double
    }
    let displayID: UInt32
    let displayBounds: CGRect
    let frameWidth: Int
    let frameHeight: Int
    let includedWindowIDs: Set<UInt32>
    let privacyMaskBounds: [CGRect]
    let windows: [Window] // WindowServer order: front to back.

    static func copy(displayID: UInt32, includedWindowIDs: Set<UInt32>, privacyMaskBounds: [CGRect],
                     suppliedWindows: [[String: Any]]? = nil) -> Self? {
        let display = CGDisplayBounds(displayID)
        let width = CGDisplayPixelsWide(displayID), height = CGDisplayPixelsHigh(displayID)
        guard displayID > 0, CGDisplayIsActive(displayID) != 0, CGDisplayIsAsleep(displayID) == 0,
              valid(display), width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 33_554_432, includedWindowIDs.count <= 4096,
              privacyMaskBounds.count <= 4096, privacyMaskBounds.allSatisfy(valid),
              let inventory = suppliedWindows ?? CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              inventory.count <= 4096 else { return nil }
        var windows: [Window] = []
        var seen = Set<UInt32>()
        for item in inventory {
            guard let id = item[kCGWindowNumber as String] as? UInt32, id > 0,
                  seen.insert(id).inserted, let pid = item[kCGWindowOwnerPID as String] as? Int32,
                  let layer = item[kCGWindowLayer as String] as? Int,
                  let alpha = item[kCGWindowAlpha as String] as? Double, alpha.isFinite,
                  let dictionary = item[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary), valid(bounds),
                  let onScreen = item[kCGWindowIsOnscreen as String] as? Bool else { return nil }
            let title = item[kCGWindowName as String] as? String ?? ""
            guard title.utf8.count <= 4096 else { return nil }
            guard onScreen, alpha > 0, display.intersects(bounds) else { continue }
            windows.append(Window(id: id, processID: pid, title: title, bounds: bounds, layer: layer, alpha: alpha))
        }
        return Self(displayID: displayID, displayBounds: display, frameWidth: width, frameHeight: height,
                    includedWindowIDs: includedWindowIDs, privacyMaskBounds: privacyMaskBounds, windows: windows)
    }

    static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }

    func uniquelyMatches(context: ActivityContext, bounds: CGRect, title: String) -> Bool {
        windowMatch(context: context, bounds: bounds, title: title) == .matched
    }

    func windowMatch(context: ActivityContext, bounds: CGRect, title: String) -> WindowMatch {
        guard Self.valid(bounds), title.utf8.count <= 4096 else { return .invalidInput }
        let matches = windows.filter {
            $0.processID == context.processID && $0.layer == 0 && $0.alpha == 1 &&
                $0.title.utf16.elementsEqual(title.utf16) &&
                abs($0.bounds.minX - bounds.minX) <= 1 && abs($0.bounds.minY - bounds.minY) <= 1 &&
                abs($0.bounds.width - bounds.width) <= 1 && abs($0.bounds.height - bounds.height) <= 1
        }
        guard !matches.isEmpty else { return .absent }
        guard matches.count == 1 else { return .ambiguous }
        guard matches[0].id == context.windowID else { return .wrongWindow }
        guard context.displayID == displayID else { return .wrongDisplay }
        return .matched
    }

    func isCurrent() -> Bool { currentFailure() == nil }

    /// The same conservative full-composition proof, with fixed mismatch
    /// categories for diagnosis. No window identity, title or geometry escapes.
    func currentFailure() -> CurrentFailure? {
        guard let current = Self.copy(displayID: displayID, includedWindowIDs: includedWindowIDs,
                                      privacyMaskBounds: privacyMaskBounds) else { return .inventoryUnavailable }
        guard displayBounds == current.displayBounds, frameWidth == current.frameWidth,
              frameHeight == current.frameHeight else { return .displayGeometryChanged }
        guard windows.count == current.windows.count else { return .windowCountChanged }
        for (previous, next) in zip(windows, current.windows) {
            guard previous.id == next.id else { return .windowOrderChanged }
            guard previous.processID == next.processID else { return .windowProcessChanged }
            guard previous.bounds == next.bounds else { return .windowBoundsChanged }
            guard previous.layer == next.layer else { return .windowLayerChanged }
            guard previous.alpha == next.alpha else { return .windowAlphaChanged }
            guard previous.title.utf16.elementsEqual(next.title.utf16) else { return .windowTitleChanged }
        }
        return nil
    }

    func pixelBounds(for screenBounds: CGRect, context: ActivityContext) -> Result<CGRect, CaptureTextBoundsFailure> {
        guard Self.valid(screenBounds), displayBounds.contains(screenBounds),
              let index = windows.firstIndex(where: { $0.id == context.windowID }),
              windows[index].bounds.contains(screenBounds) else { return .failure(.invalidGeometry) }
        guard !privacyMaskBounds.contains(where: { $0.intersects(screenBounds) }) else { return .failure(.privacyMasked) }
        guard !windows.prefix(index).contains(where: { $0.bounds.intersects(screenBounds) }) else { return .failure(.occluded) }
        let x = CGFloat(frameWidth) / displayBounds.width, y = CGFloat(frameHeight) / displayBounds.height
        let result = CGRect(x: (screenBounds.minX - displayBounds.minX) * x,
                            y: (screenBounds.minY - displayBounds.minY) * y,
                            width: screenBounds.width * x, height: screenBounds.height * y)
        guard Self.valid(result), CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight).contains(result) else {
            return .failure(.invalidGeometry)
        }
        return .success(result)
    }
}

enum CaptureTextBoundsFailure: Error { case invalidGeometry, privacyMasked, occluded }

struct CapturePixelImageRead: @unchecked Sendable {
    let image: CGImage
    let pixelReceipt: CapturePixelReceipt
    let captureText: CaptureTextObservation?
}

/// The frame/receipt/text are one result from one prepared native operation.
/// A nil receipt is reserved for the unchanged legacy comparison path.
struct CaptureAttributedPixelRead: Sendable {
    let frame: CapturedFrame
    let pixelReceipt: CapturePixelReceipt?
    let captureText: CaptureTextObservation?
    init(frame: CapturedFrame, pixelReceipt: CapturePixelReceipt? = nil, captureText: CaptureTextObservation? = nil) {
        self.frame = frame; self.pixelReceipt = pixelReceipt; self.captureText = captureText
    }
}
