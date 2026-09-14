import Foundation
import XCTest
import Database
import SQLCipher
@testable import Retrace

@MainActor
final class TimelineSessionMetricsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testRepeatedCoordinatorConfigurationRetainsAccumulatedSessionCounters() async throws {
        let fixture = try await makeFixture()
        let owner = fixture.database
        var metrics = try XCTUnwrap(TimelineSessionMetrics.configured(retaining: nil, owner: owner,
            writer: { try await fixture.write($0, $1) }))
        metrics.beginSession(at: start)
        metrics.accumulateScrubDistance(125)
        metrics = try XCTUnwrap(TimelineSessionMetrics.configured(retaining: metrics, owner: owner,
            writer: { _, _ in XCTFail("Shortcut reload must retain the existing writer") }))
        let result = await metrics.flush(at: start.addingTimeInterval(10))
        XCTAssertTrue(result)
        try await assertValues(fixture, .duration, [10_000])
        try await assertValues(fixture, .scrubDistance, [125])
        try await fixture.close()
    }

    func testReconfigurationWhileHideWritesKeepsQuitJoinedToTheOriginalDrain() async throws {
        let fixture = try await makeFixture()
        let owner = fixture.database
        let gate = TimelineMetricWriteGate()
        let original = try XCTUnwrap(TimelineSessionMetrics.configured(retaining: nil, owner: owner,
            writer: { metric, value in
                try await fixture.write(metric, value)
                if metric == .duration { await gate.pauseFirstAcknowledgement() }
            }))
        original.beginSession(at: start)
        original.accumulateScrubDistance(125)
        original.endSession(at: start.addingTimeInterval(10))
        let hide = Task { await original.flushPending() }
        await gate.waitUntilPaused()
        let reconfigured = try XCTUnwrap(TimelineSessionMetrics.configured(retaining: original, owner: owner,
            writer: { _, _ in XCTFail("Reconfiguration must not detach the pending writer") }))
        var quitReturned = false
        let requested = expectation(description: "Quit requested after shortcut reconfiguration")
        let quit = Task {
            requested.fulfill()
            let result = await reconfigured.flush(at: start.addingTimeInterval(12))
            quitReturned = true
            return result
        }
        await fulfillment(of: [requested], timeout: 1)
        XCTAssertFalse(quitReturned, "Reconfiguration must preserve the join before database closure")
        await gate.open()
        let hidden = await hide.value, flushed = await quit.value
        XCTAssertTrue(hidden); XCTAssertTrue(flushed)
        try await assertValues(fixture, .duration, [10_000])
        try await assertValues(fixture, .scrubDistance, [125])
        try await fixture.close()
    }

    func testDifferentCoordinatorCannotReplaceTheBoundSessionOwner() async throws {
        let originalFixture = try await makeFixture(), replacementFixture = try await makeFixture()
        let original = try XCTUnwrap(TimelineSessionMetrics.configured(retaining: nil,
            owner: originalFixture.database, writer: { try await originalFixture.write($0, $1) }))
        original.beginSession(at: start)
        original.accumulateScrubDistance(125)
        let replacement = TimelineSessionMetrics.configured(retaining: original,
            owner: replacementFixture.database, writer: { try await replacementFixture.write($0, $1) })
        XCTAssertNil(replacement, "Coordinator replacement requires a separate controller lifetime")
        let current = replacement ?? original
        let flushed = await current.flush(at: start.addingTimeInterval(10))
        XCTAssertTrue(flushed)
        try await assertValues(originalFixture, .duration, [10_000])
        try await assertValues(originalFixture, .scrubDistance, [125])
        try await assertValues(replacementFixture, .duration, [])
        try await assertValues(replacementFixture, .scrubDistance, [])
        try await originalFixture.close()
        try await replacementFixture.close()
    }

    func testSuccessfulQuitFlushThenRetryDoesNotDuplicateCommittedCounters() async throws {
        let fixture = try await makeFixture()
        let metrics = TimelineSessionMetrics { try await fixture.write($0, $1) }
        metrics.beginSession(at: start)
        metrics.accumulateScrubDistance(125)
        let first = await metrics.flush(at: start.addingTimeInterval(10))
        let retry = await metrics.flush(at: start.addingTimeInterval(10))
        XCTAssertTrue(first); XCTAssertTrue(retry)
        try await assertValues(fixture, .duration, [10_000])
        try await assertValues(fixture, .scrubDistance, [125])
        try await fixture.close()
    }

    func testHideAfterSuccessfulFlushWritesOnlyTheRemainingSessionIncrement() async throws {
        let fixture = try await makeFixture()
        let metrics = TimelineSessionMetrics { try await fixture.write($0, $1) }
        metrics.beginSession(at: start)
        metrics.accumulateScrubDistance(125)
        let first = await metrics.flush(at: start.addingTimeInterval(10))
        metrics.accumulateScrubDistance(25)
        metrics.endSession(at: start.addingTimeInterval(12))
        let hidden = await metrics.flushPending()
        XCTAssertTrue(first); XCTAssertTrue(hidden)
        try await assertValues(fixture, .duration, [10_000, 2_000])
        try await assertValues(fixture, .scrubDistance, [125, 25])
        try await fixture.close()
    }

    func testSecondMetricSQLiteFailureRetriesOnlyTheUnacknowledgedWrite() async throws {
        let fixture = try await makeFixture()
        try await fixture.execute("CREATE TEMP TRIGGER fail_scrub BEFORE INSERT ON daily_metrics WHEN NEW.metricType = 'scrub_distance' BEGIN SELECT RAISE(ABORT, 'fixture'); END")
        let metrics = TimelineSessionMetrics { try await fixture.write($0, $1) }
        metrics.beginSession(at: start)
        metrics.accumulateScrubDistance(125)
        let failed = await metrics.flush(at: start.addingTimeInterval(10))
        XCTAssertFalse(failed)
        try await assertValues(fixture, .duration, [10_000])
        try await assertValues(fixture, .scrubDistance, [])
        try await fixture.execute("DROP TRIGGER fail_scrub")
        let retry = await metrics.flush(at: start.addingTimeInterval(10))
        XCTAssertTrue(retry)
        try await assertValues(fixture, .duration, [10_000])
        try await assertValues(fixture, .scrubDistance, [125])
        try await fixture.close()
    }

    func testConcurrentHideJoinsTheFlushAndPreservesNewIncrements() async throws {
        let fixture = try await makeFixture()
        let gate = TimelineMetricWriteGate()
        let metrics = TimelineSessionMetrics { metric, value in
            try await fixture.write(metric, value)
            if metric == .duration { await gate.pauseFirstAcknowledgement() }
        }
        metrics.beginSession(at: start)
        metrics.accumulateScrubDistance(125)
        let quit = Task { await metrics.flush(at: start.addingTimeInterval(10)) }
        await gate.waitUntilPaused()
        metrics.accumulateScrubDistance(25)
        metrics.endSession(at: start.addingTimeInterval(12))
        let hide = Task { await metrics.flushPending() }
        await gate.open()
        let quitResult = await quit.value, hideResult = await hide.value
        XCTAssertTrue(quitResult); XCTAssertTrue(hideResult)
        try await assertTotal(fixture, .duration, 12_000)
        try await assertTotal(fixture, .scrubDistance, 150)
        try await fixture.close()
    }

    func testReopenWhileOldHideIsWritingDoesNotLoseTheNewSession() async throws {
        let fixture = try await makeFixture()
        let gate = TimelineMetricWriteGate()
        let metrics = TimelineSessionMetrics { metric, value in
            try await fixture.write(metric, value)
            if metric == .duration { await gate.pauseFirstAcknowledgement() }
        }
        metrics.beginSession(at: start)
        metrics.accumulateScrubDistance(125)
        metrics.endSession(at: start.addingTimeInterval(10))
        let oldHide = Task { await metrics.flushPending() }
        await gate.waitUntilPaused()
        metrics.beginSession(at: start.addingTimeInterval(20))
        metrics.accumulateScrubDistance(60)
        let newQuit = Task { await metrics.flush(at: start.addingTimeInterval(26)) }
        await gate.open()
        let hidden = await oldHide.value, quit = await newQuit.value
        XCTAssertTrue(hidden); XCTAssertTrue(quit)
        try await assertTotal(fixture, .duration, 16_000)
        try await assertTotal(fixture, .scrubDistance, 185)
        // A retry must still know which new-session counters were committed.
        let retry = await metrics.flush(at: start.addingTimeInterval(26))
        XCTAssertTrue(retry)
        try await assertTotal(fixture, .duration, 16_000)
        try await assertTotal(fixture, .scrubDistance, 185)
        try await fixture.close()
    }

    func testTimedOutCommittedWriteIsJoinedAndNeverReplayedOnRetry() async throws {
        let fixture = try await makeFixture()
        let gate = TimelineMetricWriteGate()
        let metrics = TimelineSessionMetrics { metric, value in
            try await fixture.write(metric, value)
            if metric == .duration { await gate.pauseFirstAcknowledgement() }
        }
        metrics.beginSession(at: start)
        metrics.accumulateScrubDistance(125)
        var returned = false
        let flush = Task {
            let result = await metrics.flush(at: start.addingTimeInterval(10), timeoutMs: 5)
            returned = true
            return result
        }
        await gate.waitUntilPaused()
        try await Task.sleep(for: .milliseconds(25), clock: .continuous)
        XCTAssertFalse(returned, "Quit must not close the database while a timed-out writer is still unwinding")
        await gate.open()
        let timedOut = await flush.value
        XCTAssertFalse(timedOut)
        let retried = await metrics.flush(at: start.addingTimeInterval(10))
        XCTAssertTrue(retried)
        try await assertValues(fixture, .duration, [10_000])
        try await assertValues(fixture, .scrubDistance, [125])
        try await fixture.close()
    }

    func testQuitWithHiddenTimelineJoinsItsPendingMetricWriter() async throws {
        let fixture = try await makeFixture()
        let gate = TimelineMetricWriteGate()
        let metrics = TimelineSessionMetrics { metric, value in
            try await fixture.write(metric, value)
            if metric == .duration { await gate.pauseFirstAcknowledgement() }
        }
        metrics.beginSession(at: start)
        metrics.accumulateScrubDistance(125)
        metrics.endSession(at: start.addingTimeInterval(10))
        let hide = Task { await metrics.flushPending() }
        await gate.waitUntilPaused()
        var quitFinished = false
        let quitStarted = expectation(description: "Quit joins the hidden session write")
        let quit = Task {
            quitStarted.fulfill()
            let value = await metrics.flush(at: start.addingTimeInterval(12))
            quitFinished = true
            return value
        }
        await fulfillment(of: [quitStarted], timeout: 1)
        XCTAssertFalse(quitFinished)
        await gate.open()
        let hideResult = await hide.value, quitResult = await quit.value
        XCTAssertTrue(hideResult); XCTAssertTrue(quitResult)
        try await assertValues(fixture, .duration, [10_000])
        try await assertValues(fixture, .scrubDistance, [125])
        try await fixture.close()
    }

    func testShortSessionThresholdAndFractionalScrubRemainWellDefined() async throws {
        let fixture = try await makeFixture()
        let metrics = TimelineSessionMetrics { try await fixture.write($0, $1) }
        let empty = await metrics.flush(at: start)
        XCTAssertTrue(empty)
        metrics.beginSession(at: start)
        metrics.accumulateScrubDistance(0.5)
        metrics.endSession(at: start.addingTimeInterval(3))
        let hidden = await metrics.flushPending()
        XCTAssertTrue(hidden)
        try await assertValues(fixture, .duration, [])
        try await assertValues(fixture, .scrubDistance, [])
        try await fixture.close()
    }

    private func assertValues(_ fixture: TimelineMetricSQLiteFixture, _ metric: TimelineSessionMetrics.Metric,
                              _ expected: [Int64], file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await fixture.values(metric)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertTotal(_ fixture: TimelineMetricSQLiteFixture, _ metric: TimelineSessionMetrics.Metric,
                             _ expected: Int64, file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await fixture.values(metric)
        XCTAssertEqual(actual.reduce(0, +), expected, file: file, line: line)
    }

    private func makeFixture() async throws -> TimelineMetricSQLiteFixture {
        let database = DatabaseManager(databasePath: "file:timeline_metrics_\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        return TimelineMetricSQLiteFixture(database: database)
    }
}

private actor TimelineMetricSQLiteFixture {
    let database: DatabaseManager
    init(database: DatabaseManager) { self.database = database }
    func write(_ metric: TimelineSessionMetrics.Metric, _ value: Int64) async throws {
        try await database.recordMetricEvent(metricType: metric == .duration ? .timelineSessionDuration : .scrubDistance,
                                            metadata: String(value))
    }
    func values(_ metric: TimelineSessionMetrics.Metric) async throws -> [Int64] {
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        let sql = metric == .duration
            ? "SELECT CAST(metadata AS INTEGER) FROM daily_metrics WHERE metricType='timeline_session_duration' ORDER BY rowid"
            : "SELECT CAST(metadata AS INTEGER) FROM daily_metrics WHERE metricType='scrub_distance' ORDER BY rowid"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        defer { sqlite3_finalize(statement) }
        var values: [Int64] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            values.append(sqlite3_column_int64(statement, 0)); status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw FixtureError.sqlite }
        return values
    }
    func execute(_ sql: String) async throws {
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
    }
    func close() async throws { try await database.close() }
    private enum FixtureError: Error { case sqlite }
}

private actor TimelineMetricWriteGate {
    private var paused = false
    private var opened = false
    private var arrival: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    func pauseFirstAcknowledgement() async {
        guard !paused else { return }
        paused = true
        for waiter in arrival { waiter.resume() }
        arrival = []
        if !opened { await withCheckedContinuation { release = $0 } }
    }
    func waitUntilPaused() async {
        if !paused { await withCheckedContinuation { arrival.append($0) } }
    }
    func open() { opened = true; release?.resume(); release = nil }
}
