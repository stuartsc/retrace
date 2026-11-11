import CoreGraphics
import Foundation
import Shared

/// Admission binds the native include filter to the earlier privacy inventory.
/// New windows and reused identifiers never expand the snapshot's permission.
struct CapturePermittedWindow: Sendable, Hashable {
    let windowID: UInt32
    let processID: Int32
    let bundleID: String

    func admits(windowID: UInt32, processID: Int32, bundleID: String?, title: String?,
                config: CaptureConfig) -> Bool {
        self.windowID > 0 && self.processID > 0 && !self.bundleID.isEmpty &&
            self.windowID == windowID && self.processID == processID && self.bundleID == bundleID &&
            (title?.utf8.count ?? 0) <= 4096 &&
            !CGWindowListCapture.candidateMustMaskWindow(bundleID: bundleID, title: title, config: config)
    }
}

/// Masks full excluded window bounds, including fractional native pixel edges.
/// Full bounds deliberately avoid assuming foreground windows are opaque. A
/// failed mask never returns the unfiltered image.
enum CapturePrivacyMask {
    static func apply(to image: CGImage, displayBounds: CGRect, excludedBounds: [CGRect]) -> CGImage? {
        guard displayBounds.width.isFinite, displayBounds.height.isFinite,
              displayBounds.origin.x.isFinite, displayBounds.origin.y.isFinite,
              displayBounds.width > 0, displayBounds.height > 0,
              image.width > 0, image.height > 0,
              image.width <= 16_384, image.height <= 16_384,
              image.width * image.height <= 33_554_432,
              excludedBounds.count <= 4096,
              excludedBounds.allSatisfy({ $0.origin.x.isFinite && $0.origin.y.isFinite &&
                  $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }) else { return nil }
        guard !excludedBounds.isEmpty else { return image }
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setShouldAntialias(false)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        let scaleX = CGFloat(image.width) / displayBounds.width
        let scaleY = CGFloat(image.height) / displayBounds.height
        for bounds in excludedBounds {
            let clipped = bounds.intersection(displayBounds)
            guard !clipped.isEmpty, !clipped.isNull else { continue }
            let left = floor((clipped.minX - displayBounds.minX) * scaleX)
            let top = floor((clipped.minY - displayBounds.minY) * scaleY)
            let right = ceil((clipped.maxX - displayBounds.minX) * scaleX)
            let bottom = ceil((clipped.maxY - displayBounds.minY) * scaleY)
            context.fill(CGRect(x: left, y: CGFloat(image.height) - bottom,
                                width: right - left, height: bottom - top))
        }
        return context.makeImage()
    }
}
