import Foundation
import Shared

public enum BackgroundProcessingWaitReason: String, Sendable {
    case audioPacing, measurementsUnavailable, cpuBudget, systemBusy, resourcePressure, activeUse, systemDeferral, closed

    public var summary: String {
        switch self {
        case .audioPacing: return "Preparing older audio gradually"
        case .measurementsUnavailable: return "Waiting for current CPU measurements"
        case .cpuBudget: return "Waiting for CPU usage to fall"
        case .systemBusy: return "Waiting for the Mac to be less busy"
        case .resourcePressure: return "Waiting for memory or temperature to recover"
        case .activeUse: return "Waiting for a quiet moment"
        case .systemDeferral: return "Waiting for macOS background time"
        case .closed: return "Processing stopped"
        }
    }
}

/// Initial responsiveness-first thresholds. They govern automatic admission,
/// not capture or explicit foreground operations, and are not a hard CPU cap.
struct ResourceProcessingPolicy {
    private var appThrottled = false
    private var systemThrottled = false
    private var recoveryStarted: Double?
    private var previousSample: Double?
    private(set) var reason: BackgroundProcessingWaitReason?

    mutating func update(_ sample: ResourceUsageSnapshot, idleSeconds: Double) {
        guard sample.isCurrent, let time = sample.sampleUptime, time.isFinite,
              let app = sample.oneMinute.cpuPercent, app.isFinite, app >= 0,
              let system = sample.systemFiveSecondCPUPercent, system.isFinite, system >= 0, system <= 100 else {
            reason = .measurementsUnavailable
            recoveryStarted = nil
            previousSample = nil
            return
        }
        if let previousSample, time < previousSample || time - previousSample > 3 {
            recoveryStarted = nil
        }
        previousSample = time
        let active = !idleSeconds.isFinite || idleSeconds < 300
        if !active { appThrottled = false }
        if active && app > 20 { appThrottled = true; recoveryStarted = nil }
        if system > 80 { systemThrottled = true; recoveryStarted = nil }
        if appThrottled || systemThrottled {
            // Capture and durable writes are never throttled and can themselves
            // use 15–20% of a core. Recover below the actual target for fifteen
            // continuous seconds; a lower release threshold can latch forever.
            if (!active || app < 20) && system < 70 {
                if recoveryStarted == nil { recoveryStarted = time }
                if time - (recoveryStarted ?? time) >= 15 {
                    appThrottled = false
                    systemThrottled = false
                    recoveryStarted = nil
                }
            } else { recoveryStarted = nil }
        }
        reason = systemThrottled ? .systemBusy : (appThrottled ? .cpuBudget : nil)
    }
}
