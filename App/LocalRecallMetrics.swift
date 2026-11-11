import Foundation
import Shared

/// One owning consumer, bounded content-free payloads, and explicit overflow.
/// Search/runtime callbacks only enqueue; successful close joins every callback
/// before App finishes this inbox and its SQLite delivery task.
final class LocalRecallMetricsInbox: @unchecked Sendable {
    private struct Measurement: Encodable {
        let scope: String
        let operation: String
        let outcome: String
        let windows: Int
        let inspected: Int
        let partial: Bool
        let elapsedMilliseconds: Double
    }
    private let lock = NSLock()
    private let capacity: Int
    private let wake: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var pending: [String] = []
    private var overflow = 0
    private var finished = false

    init(capacity: Int = 64) {
        self.capacity = min(max(capacity, 1), 256)
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = pair.stream; signal = pair.continuation
    }

    func send(_ metric: LocalEmbeddingMetric) {
        enqueue(.init(scope: "runtime", operation: metric.operation.rawValue, outcome: metric.outcome.rawValue,
            windows: metric.windowCount, inspected: 0, partial: false, elapsedMilliseconds: metric.elapsedMilliseconds))
    }

    func send(_ metric: SemanticRecallMetric) {
        enqueue(.init(scope: "index", operation: metric.operation.rawValue, outcome: metric.outcome.rawValue,
            windows: metric.windowCount, inspected: metric.inspectedCount, partial: metric.partial,
            elapsedMilliseconds: metric.elapsedMilliseconds))
    }

    private func enqueue(_ value: Measurement) {
        let payload: String
        if (0...1_000_000).contains(value.windows), (0...1_000_000).contains(value.inspected),
           value.elapsedMilliseconds.isFinite, (0...86_400_000).contains(value.elapsedMilliseconds),
           let encoded = try? JSONEncoder().encode(value), encoded.count <= 1_024 {
            payload = String(decoding: encoded, as: UTF8.self)
        } else { payload = "{\"outcome\":\"invalidMeasurement\"}" }
        let accepted = lock.withLock { () -> Bool in
            guard !finished else { return false }
            if pending.count < capacity { pending.append(payload) }
            else { overflow = min(Int.max - 1, overflow) + 1 }
            return true
        }
        if accepted { signal.yield(()) }
    }

    func finish() {
        let close = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        if close { signal.finish() }
    }

    func deliver(_ record: @escaping @Sendable (String) async throws -> Void) async {
        for await _ in wake { await persist(drain(), record: record) }
        await persist(drain(), record: record)
    }

    private func drain() -> [String] {
        lock.withLock {
            var result = pending
            if overflow > 0 { result.append("{\"outcome\":\"deliveryOverflow\",\"count\":\(overflow)}") }
            pending.removeAll(keepingCapacity: true); overflow = 0
            return result
        }
    }

    private func persist(_ rows: [String], record: @Sendable (String) async throws -> Void) async {
        for row in rows {
            do { try await record(row) }
            catch { Log.warning("Local recall metric could not be persisted", category: .search) }
        }
    }
}
