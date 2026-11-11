import Foundation
import Shared
import Capture

/// A cheap snapshot for presentation. Recording and searchable coverage are
/// deliberately separate: this describes capture admission, not OCR readiness.
public struct CaptureHealthSnapshot: Sendable, Equatable {
    public let summary: String?
    public let hasGap: Bool
    public let pendingOriginalBytes: Int64
    public let originalLimitBytes: Int64
}

/// Coalesces content-free transitions before persisting daily metrics. No frame,
/// display, application, path, or captured text is written to metric metadata.
actor CaptureHealthMonitor {
    private struct Coverage {
        let observedAt: Date
        let reason: String?
    }
    private let record: @Sendable (String) async throws -> Void
    private var coverage: [UInt32: Coverage] = [:]
    private var storageReason: String?
    private var pipelineFailed = false
    private var deliveryOverflow = false
    private var pendingBytes: Int64 = 0
    private var limitBytes = OriginalSpoolStatus.defaultLimitBytes

    init(record: @escaping @Sendable (String) async throws -> Void) {
        self.record = record
    }

    func notePressure(_ pressure: OriginalSpoolPressure) async {
        let reason: String
        switch pressure {
        case let .capacityLimit(retainedBytes, _, limit):
            pendingBytes = retainedBytes
            limitBytes = limit
            reason = "original_spool_full"
        case .freeSpaceHeadroom:
            reason = "free_space_headroom"
        }
        guard storageReason != reason else { return }
        storageReason = reason
        await emit(component: "storage", outcome: "gap", reason: reason)
    }

    func noteAdmittedFrame() async {
        if storageReason != nil {
            storageReason = nil
            await emit(component: "storage", outcome: "recovered", reason: "admitted")
        }
        if pipelineFailed {
            pipelineFailed = false
            await emit(component: "capture", outcome: "recovered", reason: "admitted")
        }
    }

    func notePipelineFailure() async {
        guard !pipelineFailed else { return }
        pipelineFailed = true
        await emit(component: "capture", outcome: "gap", reason: "pipelineFailed")
    }

    func noteDeliveryOverflow() async {
        guard !deliveryOverflow else { return }
        deliveryOverflow = true
        await emit(component: "capture", outcome: "gap", reason: "coverage_overflow")
    }

    func beginCaptureSession() async {
        // The coordinator has finished and joined the old coverage inbox before
        // entering here. A new backend cannot recover gaps from that session.
        let endedGaps = coverage.values.contains { $0.reason != nil }
        coverage.removeAll(keepingCapacity: true)
        if endedGaps {
            await emit(component: "capture", outcome: "ended", reason: "session_ended")
        }
        if deliveryOverflow {
            deliveryOverflow = false
            await emit(component: "capture", outcome: "ended", reason: "restarted")
        }
    }

    func updateSpool(_ status: OriginalSpoolStatus) {
        pendingBytes = status.retainedBytes
        limitBytes = status.limitBytes
    }

    func noteEnded(displayID: UInt32?, observedAt: Date) async {
        let key = displayID ?? 0
        guard let previous = coverage[key], previous.observedAt <= observedAt else { return }
        coverage[key] = Coverage(observedAt: observedAt, reason: nil)
        if previous.reason != nil {
            await emit(component: "capture", outcome: "ended", reason: "source_ended")
        }
    }

    func noteCoverage(displayID: UInt32?, reason: String?, observedAt: Date) async {
        // CGDirectDisplayID zero is invalid and represents backend-wide state.
        let key = displayID ?? 0
        if let previous = coverage[key], previous.observedAt > observedAt { return }
        let previousReason = coverage[key]?.reason
        // Keep a bounded ordering fence for recently removed/recovered displays.
        // Active gaps are never evicted to make the status appear healthy.
        if coverage[key] == nil, coverage.count >= 64,
           let oldest = coverage.filter({ $0.value.reason == nil })
            .min(by: { $0.value.observedAt < $1.value.observedAt })?.key {
            coverage.removeValue(forKey: oldest)
        }
        if coverage[key] == nil, coverage.count >= 64 {
            await noteDeliveryOverflow()
            return
        }
        coverage[key] = Coverage(observedAt: observedAt, reason: reason)
        guard previousReason != reason else { return }
        let knownReasons: Set<String> = ["busy", "displayUnavailable", "unstableContext",
            "captureFailed", "consumerBackpressure", "configurationChanged", "pipelineFailed"]
        await emit(component: "capture", outcome: reason == nil ? "recovered" : "gap",
                   reason: reason.map { knownReasons.contains($0) ? $0 : "unavailable" } ?? "observed")
    }

    func snapshot() -> CaptureHealthSnapshot {
        let summary: String?
        if deliveryOverflow {
            summary = "Capture status updates were missed. Restart recording to check coverage."
        } else if storageReason == "free_space_headroom" {
            summary = "Screen history has a gap. Capture is waiting for 20 GiB of free disk space."
        } else if storageReason != nil {
            summary = "Screen history has a gap. Original images are waiting for text extraction and archive verification."
        } else if pipelineFailed || coverage.values.contains(where: { $0.reason != nil }) {
            summary = "Screen history has a gap. Some displays could not be captured."
        } else {
            summary = nil
        }
        return CaptureHealthSnapshot(summary: summary, hasGap: summary != nil,
                                     pendingOriginalBytes: pendingBytes, originalLimitBytes: limitBytes)
    }

    private func emit(component: String, outcome: String, reason: String) async {
        do {
            let data = try JSONEncoder().encode(["component": component, "outcome": outcome, "reason": reason])
            try await record(String(decoding: data, as: UTF8.self))
        } catch {
            Log.warning("Capture coverage metric could not be persisted", category: .app)
        }
    }
}

/// A single owning consumer drains this inbox before the database closes.
/// Producers do no asynchronous work, and the wake stream retains one token.
/// First-gap and final-state receipts survive coalescing; overload is explicit.
final class CaptureCoverageInbox: @unchecked Sendable {
    struct Snapshot: Sendable {
        let events: [CaptureCoverageEvent]
        let coalescedEventCount: Int
        let overflowedEventCount: Int
    }

    private struct Receipt {
        let ordinal: UInt64
        let event: CaptureCoverageEvent
    }
    private struct Pending {
        var firstGap: Receipt?
        var latest: Receipt
        var count: Int
    }

    private let lock = NSLock()
    private let maximumDisplays: Int
    private let wakeStream: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation
    private var pending: [UInt32: Pending] = [:]
    private var overflowedEventCount = 0
    private var ordinal: UInt64 = 0
    private var finished = false

    init(maximumDisplays: Int = 128) {
        self.maximumDisplays = min(max(maximumDisplays, 1), 1024)
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeStream = pair.stream; wakeContinuation = pair.continuation
    }

    @discardableResult
    func send(_ event: CaptureCoverageEvent) -> Bool {
        let result: (accepted: Bool, wake: Bool) = lock.withLock {
            guard !finished else { return (false, false) }
            let key = event.displayID ?? 0
            guard pending[key] != nil || pending.count < maximumDisplays else {
                overflowedEventCount = min(overflowedEventCount, Int.max - 1) + 1
                return (false, true)
            }
            ordinal &+= 1
            let receipt = Receipt(ordinal: ordinal, event: event)
            let isGap: Bool
            if case .gap = event.state { isGap = true } else { isGap = false }
            if var existing = pending[key] {
                existing.count = min(existing.count, Int.max - 1) + 1
                if event.observedAt >= existing.latest.event.observedAt { existing.latest = receipt }
                if isGap && (existing.firstGap == nil || event.observedAt < existing.firstGap!.event.observedAt) {
                    existing.firstGap = receipt
                }
                pending[key] = existing
            } else {
                pending[key] = Pending(firstGap: isGap ? receipt : nil, latest: receipt, count: 1)
            }
            return (true, true)
        }
        if result.wake { wakeContinuation.yield(()) }
        return result.accepted
    }

    func finish() {
        let shouldFinish = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        if shouldFinish { wakeContinuation.finish() }
    }

    var snapshots: Snapshots { Snapshots(inbox: self) }

    private func drain() -> Snapshot? {
        lock.withLock {
            guard !pending.isEmpty || overflowedEventCount > 0 else { return nil }
            var receipts: [Receipt] = []
            var coalesced = 0
            for value in pending.values {
                if let first = value.firstGap, first.ordinal != value.latest.ordinal {
                    receipts.append(first)
                    coalesced += max(0, value.count - 2)
                } else {
                    coalesced += max(0, value.count - 1)
                }
                receipts.append(value.latest)
            }
            receipts.sort {
                if $0.event.observedAt != $1.event.observedAt { return $0.event.observedAt < $1.event.observedAt }
                return $0.ordinal < $1.ordinal
            }
            let result = Snapshot(events: receipts.map(\.event), coalescedEventCount: coalesced,
                                  overflowedEventCount: overflowedEventCount)
            pending.removeAll(keepingCapacity: true)
            overflowedEventCount = 0
            return result
        }
    }

    struct Snapshots: AsyncSequence, Sendable {
        typealias Element = Snapshot
        fileprivate let inbox: CaptureCoverageInbox

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(inbox: inbox, wake: inbox.wakeStream.makeAsyncIterator())
        }

        struct AsyncIterator: AsyncIteratorProtocol {
            fileprivate let inbox: CaptureCoverageInbox
            fileprivate var wake: AsyncStream<Void>.Iterator

            mutating func next() async -> Snapshot? {
                while await wake.next() != nil {
                    if let snapshot = inbox.drain() { return snapshot }
                }
                // A send accepted just before finish is retained even if its
                // later wake yield encounters an already-finished signal.
                return inbox.drain()
            }
        }
    }
}
