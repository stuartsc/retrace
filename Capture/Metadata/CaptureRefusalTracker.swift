import CoreGraphics
import Foundation

/// Content-free state of a continuing capture refusal. Reason and bundle
/// identifier only; never a window title, URL or captured content.
struct CaptureRefusalStatus: Sendable, Equatable {
    /// `ProcessInfo.systemUptime` at the first refused tick of this streak.
    let since: TimeInterval
    let reason: CaptureSamplingOutcome
    let bundleID: String?
}

enum CaptureRefusalEvent: Sendable, Equatable {
    case sustained(duration: TimeInterval, reason: CaptureSamplingOutcome, bundleID: String?)
    case restored(totalDuration: TimeInterval)

    var message: String {
        switch self {
        case let .sustained(duration, reason, bundleID):
            return "[CGWindowListCapture] No screen captured for \(Int(duration))s while the display is awake and unlocked: reason=\(reason.rawValue) frontmostBundleID=\(bundleID ?? "unknown")"
        case let .restored(total):
            return "[CGWindowListCapture] Screen capture restored after \(Int(total))s of refusal"
        }
    }
}

/// Pure decision logic for making a sustained, fail-closed refusal visible.
/// It never changes what is captured. Time is injected as monotonic seconds.
struct CaptureRefusalTracker: Sendable {
    static let warnAfter: TimeInterval = 60
    static let repeatInterval: TimeInterval = 600

    private(set) var status: CaptureRefusalStatus?
    private var lastWarning: TimeInterval?

    /// A refused tick. When the display is asleep or the session locked the
    /// refusal is expected: the streak is dropped silently and restarts later.
    mutating func recordRefusal(reason: CaptureSamplingOutcome, bundleID: String?,
                                displayActive: Bool, now: TimeInterval) -> CaptureRefusalEvent? {
        guard displayActive, now.isFinite else {
            status = nil
            lastWarning = nil
            return nil
        }
        let since = status?.since ?? now
        status = CaptureRefusalStatus(since: since, reason: reason, bundleID: bundleID)
        let duration = now - since
        guard duration >= Self.warnAfter else { return nil }
        if let lastWarning, now - lastWarning < Self.repeatInterval { return nil }
        lastWarning = now
        return .sustained(duration: duration, reason: reason, bundleID: bundleID)
    }

    /// An accepted sample. Reports the total only if a warning was issued.
    mutating func recordAccepted(now: TimeInterval) -> CaptureRefusalEvent? {
        defer { status = nil; lastWarning = nil }
        guard let status, lastWarning != nil, now >= status.since else { return nil }
        return .restored(totalDuration: now - status.since)
    }
}

/// Holds the latest sampling outcome of one capture attempt.
final class CaptureLastOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: CaptureSamplingOutcome?
    func set(_ value: CaptureSamplingOutcome) { lock.withLock { outcome = value } }
    var value: CaptureSamplingOutcome? { lock.withLock { outcome } }
}

enum CaptureDisplayActivity {
    /// True when the captured display is awake and the login session is not locked.
    static func isDisplayAwakeAndUnlocked(displayID: UInt32) -> Bool {
        guard CGDisplayIsAsleep(CGDirectDisplayID(displayID)) == 0 else { return false }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) != true
    }
}
