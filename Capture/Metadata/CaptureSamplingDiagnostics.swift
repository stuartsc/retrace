import Foundation
import Shared

/// Fixed sampling outcomes only. These describe admission attempts, never
/// retained-frame counts or inferred time spent working.
enum CaptureSamplingOutcome: String, CaseIterable, Sendable {
    case accepted, cancelled, invalidDisplay
    case contextUnavailable, applicationUnavailable, windowUnavailable
    case windowIdentityUnavailable, displayMismatch, focusedApplicationChanged
    case inventoryUnavailable, inventoryChangedDuringMetadata, inventoryChanged
    case notificationChangedBeforePixels, notificationChangedDuringPixels
    case pixelsUnavailable, contextChanged, invalidClock, samplingTooSlow
}

struct CaptureSamplingSummary: Sendable {
    let latest: CaptureSamplingOutcome
    let counts: [CaptureSamplingOutcome: Int]
    let countsClamped: Bool
    var message: String {
        let values = CaptureSamplingOutcome.allCases.compactMap { reason -> String? in
            guard let count = counts[reason] else { return nil }
            return "\(reason.rawValue):\(count)"
        }.joined(separator: ",")
        return "[CaptureSampling] latest=\(latest.rawValue) attempts=\(values) countsClamped=\(countsClamped)"
    }
}

/// Bounded content-free diagnostics, with file logging off the capture executor.
/// This adds no polling task, captured content, app identity or durable authority.
final class CaptureSamplingDiagnostics: @unchecked Sendable {
    private static let delivery = CaptureSamplingDiagnosticDelivery { Log.info($0.message, category: .capture) }
    private let lock = NSLock()
    private var counts: [CaptureSamplingOutcome: Int] = [:]
    private var clamped = false
    private var lastEmission: TimeInterval?
    private let minimumInterval: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let emit: @Sendable (CaptureSamplingSummary) -> Void

    init(minimumInterval: TimeInterval = 30,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         emit: @escaping @Sendable (CaptureSamplingSummary) -> Void = { summary in
             delivery.enqueue(summary)
         }) {
        self.minimumInterval = minimumInterval.isFinite ? max(1, minimumInterval) : 30
        self.now = now
        self.emit = emit
    }

    func record(_ outcome: CaptureSamplingOutcome) {
        let summary: CaptureSamplingSummary? = lock.withLock {
            let previous = counts[outcome, default: 0]
            counts[outcome] = min(1_000_000, previous + 1)
            if previous >= 1_000_000 { clamped = true }
            let time = now()
            guard time.isFinite, time >= 0 else { return nil }
            if let lastEmission, time >= lastEmission, time - lastEmission < minimumInterval { return nil }
            let result = CaptureSamplingSummary(latest: outcome, counts: counts, countsClamped: clamped)
            counts.removeAll(keepingCapacity: true)
            clamped = false
            lastEmission = time
            return result
        }
        if let summary { emit(summary) }
    }
}

/// One in-flight write and one fixed-size pending summary even if the logging
/// backend is blocked. Pending intervals merge counts rather than queue work.
final class CaptureSamplingDiagnosticDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "io.retrace.capture.sampling-diagnostics", qos: .utility)
    private let write: @Sendable (CaptureSamplingSummary) -> Void
    private var pending: CaptureSamplingSummary?
    private var draining = false

    init(write: @escaping @Sendable (CaptureSamplingSummary) -> Void) { self.write = write }

    func enqueue(_ summary: CaptureSamplingSummary) {
        let start = lock.withLock {
            if let old = pending {
                var counts = old.counts
                var clamped = old.countsClamped || summary.countsClamped
                for (reason, count) in summary.counts {
                    let total = counts[reason, default: 0] + count
                    counts[reason] = min(1_000_000, total)
                    clamped = clamped || total > 1_000_000
                }
                pending = .init(latest: summary.latest, counts: counts, countsClamped: clamped)
            } else { pending = summary }
            guard !draining else { return false }
            draining = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while let next = lock.withLock({ () -> CaptureSamplingSummary? in
            guard let next = pending else { draining = false; return nil }
            pending = nil
            return next
        }) { write(next) }
    }
}
