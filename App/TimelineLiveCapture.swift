import CoreGraphics
import CaptureLegacyBridge

/// Keeps the existing live-preview baseline available for comparison on SDKs
/// where its public CoreGraphics declarations are obsolete. Runtime absence is
/// an unavailable preview; this boundary does not change recording permissions.
public enum TimelineLiveCapture {
    public static func image(displayID: CGDirectDisplayID, bounds: CGRect,
                             belowWindowID: CGWindowID?) async -> CGImage? {
        guard !Task.isCancelled, displayID != 0 else { return nil }
        let capture = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard !Task.isCancelled else { return nil }
            if let belowWindowID,
               let image = RetraceLegacyCreateImageBelowWindow(bounds, belowWindowID, .boundsIgnoreFraming) {
                return image
            }
            guard !Task.isCancelled else { return nil }
            return RetraceLegacyCreateDisplayImage(displayID)
        }
        // Native calls cannot be interrupted. Join them even when cancelled and
        // discard their pixels rather than letting an old preview publish late.
        return await withTaskCancellationHandler {
            let image = await capture.value
            return Task.isCancelled ? nil : image
        } onCancel: {
            capture.cancel()
        }
    }
}
