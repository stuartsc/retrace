import AppKit
import Foundation
import SQLite3
import XCTest
@testable import Retrace

@MainActor
final class ApplicationTerminationWorkflowTests: XCTestCase {
    func testPreparationFinishesBeforeMetricsAndCanReleaseOwnedStartupForJoin() async {
        let workflow = ApplicationTerminationWorkflow()
        let startup = TerminationTestGate(), preparation = TerminationTestGate()
        let startupEntered = expectation(description: "Startup is waiting on its owned operation")
        let preparationEntered = expectation(description: "Preparation cancels the owned operation")
        let replied = expectation(description: "Prepared shutdown replies after joined startup")
        var events: [String] = []
        workflow.startInitialization {
            startupEntered.fulfill()
            await startup.wait()
            XCTAssertTrue(Task.isCancelled)
            events.append("startup-joined")
        }
        await fulfillment(of: [startupEntered], timeout: 1)
        workflow.requestTermination(prepareShutdown: {
            events.append("prepare-start"); preparationEntered.fulfill()
            await preparation.wait()
            events.append("prepare-finished"); startup.open()
        }, flushMetrics: { events.append("metrics") }, shutdown: {
            events.append("shutdown")
        }, reply: { permitted in
            XCTAssertTrue(permitted); events.append("reply"); replied.fulfill()
        }, reportFailure: { _ in XCTFail("Unexpected shutdown failure") })
        await fulfillment(of: [preparationEntered], timeout: 1)
        XCTAssertEqual(events, ["prepare-start"])
        XCTAssertEqual(workflow.requestTermination(prepareShutdown: { XCTFail("Duplicate preparation") },
            flushMetrics: { XCTFail("Duplicate metrics") }, shutdown: { XCTFail("Duplicate shutdown") },
            reply: { _ in XCTFail("Duplicate reply") }, reportFailure: { _ in XCTFail("Unexpected error") }), .terminateLater)
        preparation.open()
        // Release even the broken pre-preparation implementation so RED does not leave a task behind.
        if !events.contains("prepare-start") { startup.open() }
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(events, ["prepare-start", "prepare-finished", "metrics", "startup-joined", "shutdown", "reply"])
    }

    func testQuitWaitsForMetricsThenShutdownAndRepeatedQuitKeepsWaiting() async {
        let workflow = ApplicationTerminationWorkflow()
        let metrics = TerminationTestGate(), shutdown = TerminationTestGate()
        let metricsEntered = expectation(description: "Metrics entered")
        let shutdownEntered = expectation(description: "Shutdown entered")
        let replied = expectation(description: "Termination reply")
        var events: [String] = [], replies: [Bool] = []
        let decision = workflow.requestTermination(flushMetrics: {
            events.append("metrics-start"); metricsEntered.fulfill()
            await metrics.wait(); events.append("metrics-finished")
        }, shutdown: {
            events.append("shutdown-start"); shutdownEntered.fulfill()
            await shutdown.wait(); events.append("shutdown-finished")
        }, reply: { value in
            events.append("reply"); replies.append(value); replied.fulfill()
        }, reportFailure: { _ in XCTFail("Unexpected shutdown failure") })
        XCTAssertEqual(decision, .terminateLater)
        await fulfillment(of: [metricsEntered], timeout: 1)
        XCTAssertEqual(workflow.requestTermination(flushMetrics: { XCTFail("Duplicate metrics owner") },
            shutdown: { XCTFail("Duplicate shutdown owner") }, reply: { _ in XCTFail("Duplicate reply owner") },
            reportFailure: { _ in XCTFail("Duplicate failure owner") }), .terminateLater)
        XCTAssertTrue(replies.isEmpty)
        let responsive = expectation(description: "Main actor remains available during drain")
        Task { @MainActor in responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 1)
        metrics.open()
        await fulfillment(of: [shutdownEntered], timeout: 1)
        XCTAssertEqual(events, ["metrics-start", "metrics-finished", "shutdown-start"])
        XCTAssertTrue(replies.isEmpty, "The application must remain alive until shutdown finishes")
        shutdown.open()
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(events, ["metrics-start", "metrics-finished", "shutdown-start", "shutdown-finished", "reply"])
        XCTAssertEqual(replies, [true])
    }

    func testMetricTransactionCommitsBeforeCanonicalWriterCloses() async throws {
        let database = try TerminationTestDatabase()
        defer { database.remove() }
        let workflow = ApplicationTerminationWorkflow()
        let replied = expectation(description: "Reply follows SQLite commit and close")
        workflow.requestTermination(flushMetrics: {
            do { try database.recordMetric() } catch { XCTFail("Metric transaction failed: \(error)") }
        }, shutdown: {
            XCTAssertEqual(try database.metricCount(), 1)
            try database.close()
        }, reply: { permitted in
            XCTAssertTrue(permitted)
            XCTAssertTrue(database.isClosed, "A true reply must not precede closing the writer")
            replied.fulfill()
        }, reportFailure: { _ in XCTFail("Unexpected shutdown failure") })
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(try database.readPersistedMetricCount(), 1)
    }

    func testShutdownFailureCancelsQuitAndRetryOwnsANewDrain() async {
        let workflow = ApplicationTerminationWorkflow()
        let failed = expectation(description: "Failed shutdown cancels quit")
        var events: [String] = []
        workflow.requestTermination(flushMetrics: { events.append("metrics") }, shutdown: {
            events.append("shutdown-failed"); throw TerminationTestFailure.expected
        }, reply: { value in
            XCTAssertFalse(value); events.append("reply-false"); failed.fulfill()
        }, reportFailure: { error in
            XCTAssertTrue(error is TerminationTestFailure); events.append("failure-reported")
        })
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(events, ["metrics", "shutdown-failed", "failure-reported", "reply-false"])
        XCTAssertFalse(workflow.didCompleteShutdown)
        XCTAssertFalse(workflow.isDraining)
        workflow.startInitialization { XCTFail("A partially stopped launch must remain fenced after shutdown failure") }
        await Task.yield()
        let retried = expectation(description: "Retry completes remaining shutdown")
        XCTAssertEqual(workflow.requestTermination(flushMetrics: { events.append("retry-metrics") },
            shutdown: { events.append("retry-shutdown") }, reply: { value in
                XCTAssertTrue(value); retried.fulfill()
            }, reportFailure: { _ in XCTFail("Unexpected retry failure") }), .terminateLater)
        await fulfillment(of: [retried], timeout: 1)
        XCTAssertEqual(Array(events.suffix(2)), ["retry-metrics", "retry-shutdown"])
    }

    func testQuitBeforeInitializationDoesNotStartServicesOrRevealWindows() async {
        let workflow = ApplicationTerminationWorkflow()
        let replied = expectation(description: "Pre-initialization quit completes")
        workflow.requestTermination(flushMetrics: {}, shutdown: {}, reply: { value in
            XCTAssertTrue(value); replied.fulfill()
        }, reportFailure: { _ in XCTFail("Unexpected shutdown failure") })
        workflow.startInitialization { XCTFail("Quit must fence a queued initializer") }
        await fulfillment(of: [replied], timeout: 1)
        workflow.startInitialization { XCTFail("Completed shutdown must not initialize services") }
        await Task.yield()
    }

    func testOrdinaryLaunchRunsInitializationAndAutostartOnce() async {
        let workflow = ApplicationTerminationWorkflow()
        let started = expectation(description: "Initialization started")
        let completed = expectation(description: "Ordinary launch may autostart and reveal")
        let gate = TerminationTestGate()
        var events: [String] = []
        workflow.startInitialization {
            events.append("initialize"); started.fulfill()
            await gate.wait()
            guard !Task.isCancelled else { XCTFail("Ordinary startup was cancelled"); return }
            events += ["autostart", "reveal"]; completed.fulfill()
        }
        await fulfillment(of: [started], timeout: 1)
        workflow.startInitialization { XCTFail("Duplicate launch must share the original initialization") }
        gate.open()
        await fulfillment(of: [completed], timeout: 1)
        workflow.startInitialization { XCTFail("Completed initialization must not autostart twice") }
        await Task.yield()
        XCTAssertEqual(events, ["initialize", "autostart", "reveal"])
    }

    func testQuitCancelsQueuedInitializationBeforeItCanBegin() async {
        let workflow = ApplicationTerminationWorkflow()
        let replied = expectation(description: "Queued startup is cancelled before service shutdown")
        workflow.startInitialization { XCTFail("A queued initializer must not begin after confirmed Quit") }
        workflow.requestTermination(flushMetrics: {}, shutdown: {}, reply: { value in
            XCTAssertTrue(value); replied.fulfill()
        }, reportFailure: { _ in XCTFail("Unexpected shutdown failure") })
        await fulfillment(of: [replied], timeout: 1)
    }

    func testQuitCancelsAndJoinsLateInitializationBeforeClosingServices() async {
        let workflow = ApplicationTerminationWorkflow()
        let started = expectation(description: "Startup entered an async operation")
        let flushed = expectation(description: "Metrics flushed while startup unwinds")
        let replied = expectation(description: "Reply follows cancelled startup and shutdown")
        let gate = TerminationTestGate()
        var events: [String] = []
        workflow.startInitialization {
            events.append("initializing"); started.fulfill()
            // Models an already-owned async operation whose completion ignores cancellation.
            await gate.wait()
            guard !Task.isCancelled else { events.append("cancelled-startup-joined"); return }
            events += ["autostart", "reveal"]
        }
        await fulfillment(of: [started], timeout: 1)
        workflow.requestTermination(flushMetrics: { events.append("metrics"); flushed.fulfill() },
            shutdown: { events.append("shutdown") }, reply: { value in
                XCTAssertTrue(value); events.append("reply"); replied.fulfill()
            }, reportFailure: { _ in XCTFail("Unexpected shutdown failure") })
        await fulfillment(of: [flushed], timeout: 1)
        XCTAssertEqual(events, ["initializing", "metrics"])
        gate.open()
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(events, ["initializing", "metrics", "cancelled-startup-joined", "shutdown", "reply"])
    }

    func testCompletedShutdownDoesNotFlushOrCloseServicesAgain() async {
        let workflow = ApplicationTerminationWorkflow()
        let replied = expectation(description: "Initial shutdown completes")
        workflow.requestTermination(flushMetrics: {}, shutdown: {}, reply: { _ in replied.fulfill() },
            reportFailure: { _ in XCTFail("Unexpected shutdown failure") })
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertTrue(workflow.didCompleteShutdown)
        XCTAssertEqual(workflow.requestTermination(flushMetrics: { XCTFail("Repeated metrics flush") },
            shutdown: { XCTFail("Repeated service close") }, reply: { _ in XCTFail("Repeated async reply") },
            reportFailure: { _ in XCTFail("Unexpected shutdown failure") }), .terminateNow)
        await Task.yield()
    }
}

@MainActor
private final class TerminationTestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters; waiters = []
        for continuation in pending { continuation.resume() }
    }
}

private enum TerminationTestFailure: Error { case expected, sqlite }

@MainActor
private final class TerminationTestDatabase {
    private let directory: URL
    private let path: String
    private var connection: OpaquePointer?
    var isClosed: Bool { connection == nil }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Termination-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        path = directory.appendingPathComponent("fixture.db").path
        guard sqlite3_open(path, &connection) == SQLITE_OK,
              sqlite3_exec(connection, "CREATE TABLE metric(value INTEGER)", nil, nil, nil) == SQLITE_OK else {
            throw TerminationTestFailure.sqlite
        }
    }
    func recordMetric() throws {
        guard let connection,
              sqlite3_exec(connection, "BEGIN; INSERT INTO metric VALUES(1); COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw TerminationTestFailure.sqlite
        }
    }
    func metricCount() throws -> Int64 { try count(connection) }
    private func count(_ db: OpaquePointer?) throws -> Int64 {
        guard let db else { throw TerminationTestFailure.sqlite }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM metric", -1, &statement, nil) == SQLITE_OK else {
            throw TerminationTestFailure.sqlite
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw TerminationTestFailure.sqlite }
        return sqlite3_column_int64(statement, 0)
    }
    func close() throws {
        guard let connection else { return }
        guard sqlite3_close(connection) == SQLITE_OK else { throw TerminationTestFailure.sqlite }
        self.connection = nil
    }
    func readPersistedMetricCount() throws -> Int64 {
        var reader: OpaquePointer?
        guard sqlite3_open_v2(path, &reader, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw TerminationTestFailure.sqlite
        }
        defer { sqlite3_close(reader) }
        return try count(reader)
    }
    func remove() { try? close(); try? FileManager.default.removeItem(at: directory) }
}
