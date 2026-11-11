import Shared

enum CaptureBackendSettingsPolicy {
    static func replacing(_ current: CaptureConfig, backend: CaptureBackend,
                          displayPolicy: CaptureDisplayPolicy, visibleTextEnabled: Bool? = nil,
                          groupReceiptsEnabled: Bool? = nil) -> CaptureConfig {
        CaptureConfig(captureIntervalSeconds: current.captureIntervalSeconds,
            adaptiveCaptureEnabled: current.adaptiveCaptureEnabled,
            deduplicationThreshold: current.deduplicationThreshold, maxResolution: current.maxResolution,
            excludedAppBundleIDs: current.excludedAppBundleIDs, excludePrivateWindows: current.excludePrivateWindows,
            customPrivateWindowPatterns: current.customPrivateWindowPatterns, showCursor: current.showCursor,
            redactWindowTitlePatterns: current.redactWindowTitlePatterns,
            redactBrowserURLPatterns: current.redactBrowserURLPatterns,
            idleThresholdSeconds: current.idleThresholdSeconds, captureOnWindowChange: current.captureOnWindowChange,
            backend: backend, displayPolicy: displayPolicy,
            captureVisibleTextEnabled: visibleTextEnabled ?? current.captureVisibleTextEnabled,
            captureGroupReceiptsEnabled: backend == .screenCaptureKitCandidate &&
                (groupReceiptsEnabled ?? current.captureGroupReceiptsEnabled))
    }
}
