import Foundation
import Shared

/// Capture callbacks enqueue synchronously; one App-owned task drains and joins
/// before the database closes. This buffer contains counts and categories only.
final class CaptureTextMetricsInbox: @unchecked Sendable {
    struct Snapshot: Sendable {
        let events: [CaptureTextOutcome]
        let overflowCount: Int
    }
    private let lock = NSLock()
    private let capacity: Int
    private let wakeStream: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation
    private var pending: [CaptureTextOutcome] = []
    private var overflow = 0
    private var finished = false

    init(capacity: Int = 64) {
        self.capacity = min(max(capacity, 1), 256)
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeStream = pair.stream; wakeContinuation = pair.continuation
    }

    @discardableResult
    func send(_ event: CaptureTextOutcome) -> Bool {
        let result = lock.withLock { () -> (Bool, Bool) in
            guard !finished else { return (false, false) }
            guard pending.count < capacity else {
                overflow = min(overflow, Int.max - 1) + 1
                return (false, true)
            }
            pending.append(event)
            return (true, true)
        }
        if result.1 { wakeContinuation.yield(()) }
        return result.0
    }

    func finish() {
        let close = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        if close { wakeContinuation.finish() }
    }

    var snapshots: Snapshots { Snapshots(inbox: self) }

    private func drain() -> Snapshot? {
        lock.withLock {
            guard !pending.isEmpty || overflow > 0 else { return nil }
            let snapshot = Snapshot(events: pending, overflowCount: overflow)
            pending.removeAll(keepingCapacity: true); overflow = 0
            return snapshot
        }
    }

    struct Snapshots: AsyncSequence, Sendable {
        typealias Element = Snapshot
        fileprivate let inbox: CaptureTextMetricsInbox
        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(inbox: inbox, wake: inbox.wakeStream.makeAsyncIterator())
        }
        struct AsyncIterator: AsyncIteratorProtocol {
            fileprivate let inbox: CaptureTextMetricsInbox
            fileprivate var wake: AsyncStream<Void>.Iterator
            mutating func next() async -> Snapshot? {
                while await wake.next() != nil {
                    if let result = inbox.drain() { return result }
                }
                return inbox.drain()
            }
        }
    }
}

enum CaptureTextMetrics {
    private struct Measurement: Encodable {
        let backend: String
        let availability: String
        let reasons: [String]
        let visitedNodes: Int
        let retainedRuns: Int
        let retainedUTF16Units: Int
        let preReadMilliseconds: Double?
        let postReadMilliseconds: Double?
    }

    static func persist(_ snapshot: CaptureTextMetricsInbox.Snapshot,
                        record: @Sendable (String) async throws -> Void) async {
        for event in snapshot.events {
            do {
                let durations = [event.preReadMilliseconds, event.postReadMilliseconds].compactMap { $0 }
                guard (0...256).contains(event.visitedNodes), (0...128).contains(event.retainedRuns),
                      (0...8_192).contains(event.retainedUTF16Units), event.reasons.count <= 16,
                      durations.allSatisfy({ $0.isFinite && (0...10_000).contains($0) }) else {
                    try await record("{\"outcome\":\"invalidMeasurement\"}")
                    continue
                }
                let value = Measurement(backend: event.backend.rawValue, availability: event.availability.rawValue,
                    reasons: Set(event.reasons.map(\.rawValue)).sorted(), visitedNodes: event.visitedNodes,
                    retainedRuns: event.retainedRuns, retainedUTF16Units: event.retainedUTF16Units,
                    preReadMilliseconds: event.preReadMilliseconds, postReadMilliseconds: event.postReadMilliseconds)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try await record(String(decoding: try encoder.encode(value), as: UTF8.self))
            } catch { Log.warning("Capture text metric could not be persisted", category: .app) }
        }
        if snapshot.overflowCount > 0 {
            do { try await record("{\"outcome\":\"deliveryOverflow\",\"count\":\(snapshot.overflowCount)}") }
            catch { Log.warning("Capture text overflow metric could not be persisted", category: .app) }
        }
    }
}
