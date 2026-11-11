import CaptureLegacyBridge
import CoreGraphics

/// Isolates the deprecated public runtime APIs used only by the comparison
/// baseline. Runtime availability remains separate from a successful build.
enum LegacyCaptureAPI {
    static var isAvailable: Bool { RetraceLegacyCaptureIsAvailable() }

    static func displayImage(_ displayID: UInt32) -> CGImage? {
        RetraceLegacyCreateDisplayImage(displayID)
    }

    static func windowImage(bounds: CGRect, windows: CFArray, options: CGWindowImageOption) -> CGImage? {
        RetraceLegacyCreateWindowImage(bounds, windows, options)
    }

    static func belowWindowImage(bounds: CGRect, windowID: CGWindowID, options: CGWindowImageOption) -> CGImage? {
        RetraceLegacyCreateImageBelowWindow(bounds, windowID, options)
    }
}
