import Foundation
import SQLCipher
import Shared
import Database
import Capture
import XCTest
@testable import App

final class CaptureHealthTests: XCTestCase {
    func testEndedSourceGapDoesNotClaimRecoveryOrClearOtherComponents() async throws {
        let database = DatabaseManager(databasePath: "file:capture-source-ended-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let health = CaptureHealthMonitor { metadata in
            try await database.recordMetricEvent(metricType: .captureCoverage, metadata: metadata)
        }
        let time = Date(timeIntervalSince1970: 20)
        await health.noteCoverage(displayID: 42, reason: "displayUnavailable", observedAt: time)
        await health.noteCoverage(displayID: nil, reason: "configurationChanged", observedAt: time)
        await health.noteEnded(displayID: 42, observedAt: time)
        let switching = await health.snapshot()
        XCTAssertTrue(switching.hasGap, "The new source still needs an admitted frame")
        await health.noteCoverage(displayID: nil, reason: nil, observedAt: time.addingTimeInterval(1))
        let available = await health.snapshot()
        XCTAssertFalse(available.hasGap)
        let records = try await database.captureHealthMetricRecords()
        XCTAssertEqual(records.map { $0["outcome"] }, ["gap", "gap", "ended", "recovered"])
        XCTAssertEqual(records[2]["reason"], "source_ended")
        try await database.close()
    }

    func testNewSessionEndsOldDisplayGapsButPreservesStoragePressure() async throws {
        let database = DatabaseManager(databasePath: "file:capture-session-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let health = CaptureHealthMonitor { metadata in
            try await database.recordMetricEvent(metricType: .captureCoverage, metadata: metadata)
        }
        await health.noteCoverage(displayID: 42, reason: "displayUnavailable", observedAt: Date(timeIntervalSince1970: 10))
        await health.notePressure(.freeSpaceHeadroom(availableBytes: 100, incomingBytes: 20, minimumFreeBytes: 200))
        await health.beginCaptureSession()
        let waitingForSpace = await health.snapshot()
        XCTAssertTrue(waitingForSpace.hasGap, "Starting a session cannot resolve disk pressure")
        await health.noteAdmittedFrame()
        let admitted = await health.snapshot()
        XCTAssertFalse(admitted.hasGap, "The ended session's display must not remain an active gap")
        await health.beginCaptureSession()
        let records = try await database.captureHealthMetricRecords()
        XCTAssertEqual(records.map { $0["outcome"] }, ["gap", "gap", "ended", "recovered"])
        XCTAssertEqual(records[2]["reason"], "session_ended")
        XCTAssertEqual(records[2]["component"], "capture")
        try await database.close()
    }

    func testDeliveryOverflowSurvivesOrdinaryFrameAdmission() async throws {
        let database = DatabaseManager(databasePath: "file:capture-overflow-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let health = CaptureHealthMonitor { metadata in
            try await database.recordMetricEvent(metricType: .captureCoverage, metadata: metadata)
        }
        await health.noteDeliveryOverflow()
        await health.noteAdmittedFrame()
        let incomplete = await health.snapshot()
        XCTAssertTrue(incomplete.hasGap, "An admitted frame cannot prove missed coverage transitions")
        await health.beginCaptureSession()
        let restarted = await health.snapshot()
        XCTAssertFalse(restarted.hasGap)
        let records = try await database.captureHealthMetricRecords()
        XCTAssertEqual(records.map { $0["reason"] }, ["coverage_overflow", "restarted"])
        try await database.close()
    }

    func testPressurePersistsOnlyTransitionsAndAdmissionRecoversWithoutClearingSourceGap() async throws {
        let database = DatabaseManager(databasePath: "file:capture-health-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let health = CaptureHealthMonitor { metadata in
            try await database.recordMetricEvent(metricType: .captureCoverage, metadata: metadata)
        }
        let pressure = OriginalSpoolPressure.capacityLimit(retainedBytes: 5_000, incomingBytes: 200, limitBytes: 5_100)
        await health.notePressure(pressure)
        await health.notePressure(pressure)
        var snapshot = await health.snapshot()
        XCTAssertTrue(snapshot.hasGap)
        XCTAssertNotNil(snapshot.summary)
        XCTAssertEqual(snapshot.pendingOriginalBytes, 5_000)
        await health.noteCoverage(displayID: 42, reason: "captureFailed", observedAt: Date(timeIntervalSince1970: 20))
        await health.noteAdmittedFrame()
        snapshot = await health.snapshot()
        XCTAssertTrue(snapshot.hasGap, "Storage recovery cannot clear a separate native capture gap")
        await health.noteCoverage(displayID: 42, reason: nil, observedAt: Date(timeIntervalSince1970: 21))
        snapshot = await health.snapshot()
        XCTAssertFalse(snapshot.hasGap)
        XCTAssertNil(snapshot.summary)
        let records = try await database.captureHealthMetricRecords()
        XCTAssertEqual(records.count, 4)
        XCTAssertTrue(records.allSatisfy { Set($0.keys) == ["component", "outcome", "reason"] })
        XCTAssertEqual(records.map { $0["outcome"] }, ["gap", "gap", "recovered", "recovered"])
        try await database.close()
    }

    func testLateCoverageCallbacksCannotReopenRecoveredGap() async throws {
        let database = DatabaseManager(databasePath: "file:capture-health-order-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let health = CaptureHealthMonitor { metadata in
            try await database.recordMetricEvent(metricType: .captureCoverage, metadata: metadata)
        }
        await health.noteCoverage(displayID: 43, reason: "displayUnavailable", observedAt: Date(timeIntervalSince1970: 30))
        await health.noteCoverage(displayID: 43, reason: nil, observedAt: Date(timeIntervalSince1970: 32))
        await health.noteCoverage(displayID: 43, reason: "displayUnavailable", observedAt: Date(timeIntervalSince1970: 31))
        let state = await health.snapshot()
        XCTAssertFalse(state.hasGap)
        let records = try await database.captureHealthMetricRecords()
        XCTAssertEqual(records.count, 2, "Stale callbacks must not create false coverage transitions")
        try await database.close()
    }

    func testInboxCoalescesBurstWithoutHidingGapAndDrainsAfterFinish() async throws {
        let inbox = CaptureCoverageInbox(maximumDisplays: 2)
        for index in 0..<10_000 {
            XCTAssertTrue(inbox.send(CaptureCoverageEvent(backend: .screenCaptureKitCandidate, displayID: 42,
                observedAt: Date(timeIntervalSince1970: Double(index)),
                state: index == 9_999 ? .recovered : .gap(.busy))))
        }
        inbox.finish()
        var batches: [CaptureCoverageInbox.Snapshot] = []
        for await snapshot in inbox.snapshots { batches.append(snapshot) }
        XCTAssertEqual(batches.count, 1)
        let batch = try XCTUnwrap(batches.first)
        XCTAssertEqual(batch.events.map(\.state), [.gap(.busy), .recovered])
        XCTAssertEqual(batch.events.map(\.observedAt), [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 9_999)])
        XCTAssertEqual(batch.coalescedEventCount, 9_998)
        XCTAssertEqual(batch.overflowedEventCount, 0)
        XCTAssertFalse(inbox.send(CaptureCoverageEvent(backend: .legacy, displayID: nil, state: .gap(.captureFailed))))
    }

    func testInboxConcurrentDisplaysPreserveEachFinalStateAndExplicitOverflow() async throws {
        let inbox = CaptureCoverageInbox(maximumDisplays: 8)
        await withTaskGroup(of: Void.self) { group in
            for display in UInt32(1)...8 {
                group.addTask {
                    for index in 0..<100 {
                        _ = inbox.send(CaptureCoverageEvent(backend: .screenCaptureKitCandidate, displayID: display,
                            observedAt: Date(timeIntervalSince1970: Double(index)),
                            state: index == 99 ? .recovered : .gap(.captureFailed)))
                    }
                }
            }
        }
        XCTAssertFalse(inbox.send(CaptureCoverageEvent(backend: .screenCaptureKitCandidate, displayID: 9,
                                                      state: .gap(.displayUnavailable))))
        inbox.finish()
        var iterator = inbox.snapshots.makeAsyncIterator()
        let received = await iterator.next()
        let batch = try XCTUnwrap(received)
        XCTAssertEqual(batch.events.count, 16)
        XCTAssertEqual(batch.coalescedEventCount, 784)
        XCTAssertEqual(batch.overflowedEventCount, 1)
        for display in UInt32(1)...8 {
            XCTAssertEqual(batch.events.filter { $0.displayID == display }.map(\.state), [.gap(.captureFailed), .recovered])
        }
        let end = await iterator.next()
        XCTAssertNil(end)
    }

    func testInboxRejectsOlderLastStateAndConsumerFinishesBeforeDatabaseClose() async throws {
        let database = DatabaseManager(databasePath: "file:capture-health-inbox-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let health = CaptureHealthMonitor { metadata in
            try await database.recordMetricEvent(metricType: .captureCoverage, metadata: metadata)
        }
        let inbox = CaptureCoverageInbox()
        let consumer = Task {
            for await snapshot in inbox.snapshots {
                for event in snapshot.events {
                    let reason: String?
                    switch event.state {
                    case .gap(let value): reason = value.rawValue
                    case .recovered: reason = nil
                    case .ended:
                        await health.noteEnded(displayID: event.displayID, observedAt: event.observedAt)
                        continue
                    }
                    await health.noteCoverage(displayID: event.displayID, reason: reason, observedAt: event.observedAt)
                }
            }
        }
        _ = inbox.send(CaptureCoverageEvent(backend: .screenCaptureKitCandidate, displayID: 42,
            observedAt: Date(timeIntervalSince1970: 10), state: .gap(.busy)))
        _ = inbox.send(CaptureCoverageEvent(backend: .screenCaptureKitCandidate, displayID: 42,
            observedAt: Date(timeIntervalSince1970: 12), state: .recovered))
        _ = inbox.send(CaptureCoverageEvent(backend: .screenCaptureKitCandidate, displayID: 42,
            observedAt: Date(timeIntervalSince1970: 11), state: .gap(.busy)))
        inbox.finish()
        await consumer.value
        let snapshot = await health.snapshot()
        XCTAssertFalse(snapshot.hasGap)
        let records = try await database.captureHealthMetricRecords()
        XCTAssertEqual(records.map { $0["outcome"] }, ["gap", "recovered"])
        try await database.close()
        XCTAssertFalse(inbox.send(CaptureCoverageEvent(backend: .legacy, displayID: 42, state: .gap(.captureFailed))))
    }
}

private extension DatabaseManager {
    func captureHealthMetricRecords() throws -> [[String: String]] {
        let db = try XCTUnwrap(getConnection())
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(db,
            "SELECT metadata FROM daily_metrics WHERE metricType='capture_coverage' ORDER BY rowid", -1, &statement, nil), SQLITE_OK)
        var records: [[String: String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let text = String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0)))
            records.append(try JSONDecoder().decode([String: String].self, from: Data(text.utf8)))
        }
        return records
    }
}
