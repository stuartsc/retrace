import Foundation

/// Owns the timeline's current counters and asynchronous metric writes.
@MainActor
final class TimelineSessionMetrics {
    enum Metric: Sendable { case duration, scrubDistance }
    typealias Writer = @Sendable (Metric, Int64) async throws -> Void

    private let writer: Writer
    private var configurationOwner: AnyObject?
    private var startTime: Date?
    private var capturedDuration: Int64 = 0
    private var scrubDistance: Double = 0
    // Pending increments are bounded to two numbers, including closed sessions.
    // An acknowledgement subtracts only its own snapshot, preserving later input.
    private var pendingDuration: Int64 = 0
    private var pendingScrub: Int64 = 0
    private var inFlight: Task<Bool, Never>?

    init(writer: @escaping Writer) { self.writer = writer }

    /// Bind the write owner to the controller's coordinator for its full lifetime.
    static func configured(retaining current: TimelineSessionMetrics?, owner: AnyObject,
                           writer: @escaping Writer) -> TimelineSessionMetrics? {
        if let current {
            guard current.configurationOwner === owner else { return nil }
            return current
        }
        let metrics = TimelineSessionMetrics(writer: writer)
        metrics.configurationOwner = owner
        return metrics
    }

    func beginSession(at time: Date = Date()) {
        guard startTime == nil else { return }
        startTime = time
        capturedDuration = 0
        scrubDistance = 0
    }

    func accumulateScrubDistance(_ distance: Double) {
        guard startTime != nil, distance.isFinite, distance > 0 else { return }
        scrubDistance += distance
    }

    func endSession(at time: Date = Date()) {
        captureIncrements(at: time, endingSession: true)
        self.startTime = nil
        capturedDuration = 0
        scrubDistance = 0
    }

    func flush(at time: Date = Date(), timeoutMs: UInt64? = nil) async -> Bool {
        captureIncrements(at: time, endingSession: false)
        // A hidden timeline can still have an owned metric write to join.
        return await flushPending(timeoutMs: timeoutMs)
    }

    func flushPending(timeoutMs: UInt64? = nil) async -> Bool {
        let task: Task<Bool, Never>
        if let inFlight {
            task = inFlight
        } else {
            guard pendingDuration > 0 || pendingScrub > 0 else { return true }
            task = Task { await drainPending() }
            inFlight = task
        }
        guard let timeoutMs else { return await task.value }

        // This is a cooperative deadline. Even when it wins, join the owned write
        // and retain its acknowledgements before allowing the database to close.
        return await withTaskGroup(of: FlushResult.self) { group in
            group.addTask { .completed(await task.value) }
            group.addTask {
                do {
                    try await Task.sleep(for: .milliseconds(timeoutMs), clock: .continuous)
                } catch { }
                return .deadline
            }
            let first = await group.next() ?? .deadline
            group.cancelAll()
            switch first {
            case .completed(let succeeded): return succeeded
            case .deadline:
                task.cancel()
                return false
            }
        }
    }

    private func captureIncrements(at time: Date, endingSession: Bool) {
        guard let startTime else { return }
        let totalDuration = max(capturedDuration, Int64(max(0, time.timeIntervalSince(startTime)) * 1000))
        // Preserve hide's >3-second threshold, while retaining short increments
        // after an earlier force-flush of the same session.
        if !endingSession || totalDuration > 3000 || capturedDuration > 0 {
            pendingDuration += totalDuration - capturedDuration
            capturedDuration = totalDuration
        }
        let wholePixels = Int64(scrubDistance)
        pendingScrub += wholePixels
        scrubDistance -= Double(wholePixels)
    }

    private func drainPending() async -> Bool {
        defer { inFlight = nil }
        do {
            while pendingDuration > 0 || pendingScrub > 0 {
                try Task.checkCancellation()
                if pendingDuration > 0 {
                    let value = pendingDuration
                    try await writer(.duration, value)
                    pendingDuration -= value
                } else {
                    let value = pendingScrub
                    try await writer(.scrubDistance, value)
                    pendingScrub -= value
                }
            }
            return true
        } catch { return false }
    }

    private enum FlushResult: Sendable { case completed(Bool), deadline }
}
