import Database
import Foundation
import Shared
import XCTest
@testable import Capture

/// The canonical SQLite writer commits normally; only delivery of its first
/// acknowledgement is held so the monitor's latency boundary is observable.
final class ActivityMonitorLatencyTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var monitor: ActivityMonitor?
    private var store: ActivityAcknowledgementGate?
    private let samples = ActivityLatencySamples()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ActivityLatency-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = DatabaseManager(databasePath: directory.appendingPathComponent("fixture.db").path)
        try await database.initialize()
    }

    override func tearDown() async throws {
        _ = await store?.release()
        await monitor?.stop()
        try await database?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testDurableLatencyIncludesHeldAcknowledgementAfterRealSQLiteCommit() async throws {
        let gate = ActivityAcknowledgementGate(database: database)
        store = gate
        let monitor = makeMonitor(store: gate)
        self.monitor = monitor
        await monitor.start(observations: ActivityObservationBuffer())
        try await waitUntil { await gate.committed != nil }

        let pending = await gate.committed
        let receipt = try XCTUnwrap(pending)
        let stored = try await database.activityEvent(id: receipt.id)
        XCTAssertEqual(stored?.commitSequence, receipt.commitSequence,
                       "The held acknowledgement must follow the canonical SQLite commit")
        XCTAssertTrue(samples.snapshot.isEmpty, "No success latency may be emitted before acknowledgement")

        let releasedAt = await gate.release()
        try await waitUntil { self.samples.snapshot.count == 1 }
        let latency = try XCTUnwrap(samples.snapshot.first)
        let acknowledgedElapsed = (releasedAt - receipt.event.monotonicTime) * 1000
        XCTAssertTrue(latency.isFinite)
        XCTAssertGreaterThan(acknowledgedElapsed, 0)
        XCTAssertGreaterThanOrEqual(latency, acknowledgedElapsed,
                                   "Notification latency must include the held acknowledgement, not stop at precommit persistedAt")
        XCTAssertLessThanOrEqual(latency, (ProcessInfo.processInfo.systemUptime - receipt.event.monotonicTime) * 1000)
    }

    func testFailedCanonicalAppendDoesNotEmitDurableLatency() async throws {
        try await database.close()
        let monitor = makeMonitor(store: database)
        self.monitor = monitor
        await monitor.start(observations: ActivityObservationBuffer())
        try await waitUntil { await monitor.health().degraded }
        XCTAssertTrue(samples.snapshot.isEmpty, "A real closed-database failure has no durable acknowledgement")
        await monitor.stop()
        XCTAssertTrue(samples.snapshot.isEmpty, "The failed terminal append must not emit success latency either")
    }

    func testEarlyGateReleaseDoesNotParkALaterCanonicalAppend() async throws {
        let gate = ActivityAcknowledgementGate(database: database)
        store = gate
        _ = await gate.release()
        let monitor = makeMonitor(store: gate)
        self.monitor = monitor
        await monitor.start(observations: ActivityObservationBuffer())
        try await waitUntil { self.samples.snapshot.count == 1 }
        let events = try await database.searchActivity(ActivityQuery()).events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.event.kind, .startup)
    }

    private func makeMonitor(store: any ActivityStoreProtocol) -> ActivityMonitor {
        let samples = samples
        return ActivityMonitor(store: store, configuration: { CaptureConfig() },
            source: ActivityContextSource(frontmost: { nil }, window: { _, _, _ in nil },
                                          document: { _, _ in nil }, permission: { true }),
            recordDurableLatency: { samples.append($0) })
    }

    private func waitUntil(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while try await !predicate() {
            guard ContinuousClock.now < deadline else { throw ActivityLatencyFailure.timeout }
            try await Task.sleep(for: .milliseconds(5), clock: .continuous)
        }
    }
}

private enum ActivityLatencyFailure: Error { case timeout }

private final class ActivityLatencySamples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    var snapshot: [Double] { lock.withLock { values } }
    func append(_ value: Double) { lock.withLock { values.append(value) } }
}

private actor ActivityAcknowledgementGate: ActivityStoreProtocol {
    private let database: DatabaseManager
    private var holdFirstAcknowledgement = true
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var committed: PersistedActivityEvent?

    init(database: DatabaseManager) { self.database = database }

    func appendActivity(_ event: ActivityEvent) async throws -> PersistedActivityEvent {
        let receipt = try await database.appendActivity(event)
        if holdFirstAcknowledgement {
            holdFirstAcknowledgement = false
            committed = receipt
            await withCheckedContinuation { waiter = $0 }
        }
        return receipt
    }

    func release() -> TimeInterval {
        let releasedAt = ProcessInfo.processInfo.systemUptime
        holdFirstAcknowledgement = false
        waiter?.resume(); waiter = nil
        return releasedAt
    }

    func activityStoreID() async throws -> UUID { try await database.activityStoreID() }
    func searchActivity(_ query: ActivityQuery) async throws -> ActivityPage { try await database.searchActivity(query) }
    func activityEvent(id: UUID) async throws -> PersistedActivityEvent? { try await database.activityEvent(id: id) }
    func activityHealth() async throws -> ActivityStoreHealth { try await database.activityHealth() }
    func activityFeed(after sequence: Int64, limit: Int) async throws -> [ActivityFeedEntry] {
        try await database.activityFeed(after: sequence, limit: limit)
    }
    func acknowledgeActivityFeed(consumer: String, through sequence: Int64) async throws {
        try await database.acknowledgeActivityFeed(consumer: consumer, through: sequence)
    }
    func activityFeedCheckpoint(consumer: String) async throws -> Int64 {
        try await database.activityFeedCheckpoint(consumer: consumer)
    }
    func submitActivityCorrection(_ command: ActivityCorrection) async throws -> ActivityCorrectionReceipt {
        try await database.submitActivityCorrection(command)
    }
    func activityCorrections() async throws -> [ActivityCorrectionReceipt] { try await database.activityCorrections() }
    func acknowledgeActivityCorrection(id: UUID, expectedRevision: Int64, applied: Bool) async throws {
        try await database.acknowledgeActivityCorrection(id: id, expectedRevision: expectedRevision, applied: applied)
    }
    func deleteActivity(eventIDs: [UUID]) async throws { try await database.deleteActivity(eventIDs: eventIDs) }
}
