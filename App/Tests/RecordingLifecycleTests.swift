import Foundation
import XCTest
@testable import App

final class RecordingLifecycleTests: XCTestCase {
    func testOwnerCancellationWithoutStopJoinsLateDeviceAndRollback() async throws {
        let lifecycle = RecordingLifecycle()
        let device = RecordingTestDevice()
        let rollbackEntered = expectation(description: "Cancelled owner begins rollback")
        let ownerFinished = expectation(description: "Owner waits for its rollback")
        ownerFinished.isInverted = true
        let (finishRollback, mayFinishRollback) = AsyncStream<Void>.makeStream()
        defer { mayFinishRollback.finish() }
        let owner = Task {
            defer { ownerFinished.fulfill() }
            try await lifecycle.start(operation: { try await device.acquire() }, rollback: {
                rollbackEntered.fulfill()
                await Task.detached { for await _ in finishRollback { break } }.value
                await device.release()
            })
        }
        await device.waitUntilAcquiring()
        owner.cancel()
        await device.completeAcquisition()
        await fulfillment(of: [rollbackEntered], timeout: 1)
        await fulfillment(of: [ownerFinished], timeout: 0.05)
        mayFinishRollback.yield(()); mayFinishRollback.finish()
        do { try await owner.value; XCTFail("Cancelled startup owner must not report success") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(type(of: error))") }
        let events = await device.events
        XCTAssertEqual(events, ["acquiring", "acquired", "released"])
        try await lifecycle.stop(onRequest: {}, operation: { await device.release() })
    }

    func testCancelledDuplicateCallerDoesNotCancelOriginalStartupOwner() async throws {
        let lifecycle = RecordingLifecycle()
        let device = RecordingTestDevice()
        let owner = Task {
            try await lifecycle.start(operation: { try await device.acquire() }, rollback: { await device.release() })
        }
        await device.waitUntilAcquiring()
        let entered = expectation(description: "Duplicate caller begins joining")
        let joined = Task {
            entered.fulfill()
            try await lifecycle.start(operation: { XCTFail("Duplicate must not acquire devices") }, rollback: {})
        }
        await fulfillment(of: [entered], timeout: 1)
        await Task.yield()
        joined.cancel()
        await device.completeAcquisition()
        try await owner.value
        do { try await joined.value; XCTFail("Cancelled joiner should report cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(type(of: error))") }
        let events = await device.events
        XCTAssertEqual(events, ["acquiring", "acquired"], "Joiner cancellation must not roll back its owner")
        try await lifecycle.stop(onRequest: {}, operation: { await device.release() })
    }

    func testTerminalFenceCancelsOwnedStartupWithoutWaitingForLateDeviceAPI() async throws {
        let lifecycle = RecordingLifecycle()
        let device = RecordingTestDevice()
        let owner = Task {
            try await lifecycle.start(operation: { try await device.acquire() }, rollback: { await device.release() })
        }
        await device.waitUntilAcquiring()
        await lifecycle.beginShutdown()
        await lifecycle.beginShutdown()
        let rejected = expectation(description: "Terminal fence rejects new start before late API finishes")
        let wake = Task {
            do {
                try await lifecycle.start(operation: { XCTFail("Shutdown must reject device acquisition") }, rollback: {})
                XCTFail("Shutdown must reject a new start")
            } catch RecordingLifecycleError.shuttingDown {
                rejected.fulfill()
            } catch { XCTFail("Unexpected error: \(type(of: error))") }
        }
        await fulfillment(of: [rejected], timeout: 0.3)
        await device.completeAcquisition()
        do { try await owner.value; XCTFail("Fence must cancel the owned startup") }
        catch is CancellationError {} catch { XCTFail("Unexpected owner error: \(type(of: error))") }
        await wake.value
        let events = await device.events
        XCTAssertEqual(events, ["acquiring", "acquired", "released"])
    }

    func testTerminalFenceRejectsPendingRestartAfterStopAndAnyLaterStart() async throws {
        let lifecycle = RecordingLifecycle()
        let device = RecordingTestDevice()
        await device.completeAcquisition()
        try await lifecycle.start(operation: { try await device.acquire() }, rollback: { await device.release() })
        let (stopping, didStartStop) = AsyncStream<Void>.makeStream()
        let (finishStop, mayFinishStop) = AsyncStream<Void>.makeStream()
        defer { mayFinishStop.finish() }
        let stop = Task {
            try await lifecycle.stop(onRequest: {}, operation: {
                didStartStop.yield(()); didStartStop.finish()
                for await _ in finishStop { break }
                await device.release()
            })
        }
        for await _ in stopping { break }
        let restartEntered = expectation(description: "Restart is waiting on ordinary stop")
        let restart = Task {
            restartEntered.fulfill()
            try await lifecycle.start(operation: { try await device.acquire() }, rollback: { await device.release() })
        }
        await fulfillment(of: [restartEntered], timeout: 1)
        await Task.yield()
        await lifecycle.beginShutdown()
        mayFinishStop.yield(()); mayFinishStop.finish()
        try await stop.value
        do { try await restart.value; XCTFail("Pending restart must recheck terminal fence after awaiting stop") }
        catch RecordingLifecycleError.shuttingDown {} catch { XCTFail("Unexpected restart error: \(type(of: error))") }
        do {
            try await lifecycle.start(operation: { XCTFail("Late wake must not acquire devices") }, rollback: {})
            XCTFail("Terminal fence must remain closed")
        } catch RecordingLifecycleError.shuttingDown {} catch { XCTFail("Unexpected late error: \(type(of: error))") }
        let events = await device.events
        XCTAssertEqual(events, ["acquiring", "acquired", "released"])
    }

    func testFailedStopCannotClearTerminalFence() async throws {
        let lifecycle = RecordingLifecycle()
        let device = RecordingTestDevice()
        await device.completeAcquisition()
        try await lifecycle.start(operation: { try await device.acquire() }, rollback: { await device.release() })
        await lifecycle.beginShutdown()
        do {
            try await lifecycle.stop(onRequest: {}, operation: {
                await device.release()
                throw CocoaError(.fileWriteUnknown)
            })
            XCTFail("Injected teardown failure must propagate")
        } catch is CocoaError {}
        do {
            try await lifecycle.start(operation: { XCTFail("Failed shutdown must keep the fence") }, rollback: {})
            XCTFail("Terminal fence must survive failed stop")
        } catch RecordingLifecycleError.shuttingDown {} catch { XCTFail("Unexpected error: \(type(of: error))") }
    }

    func testRestartWaitsForCancelledStreamToFinalizeItsRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingFinalization-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("finalized.txt")
        let frames = AsyncStream<Void>.makeStream()
        let (finalizing, didFinalize) = AsyncStream<Void>.makeStream()
        let (permission, mayFinalize) = AsyncStream<Void>.makeStream()
        let pipeline = Task.detached {
            for await _ in frames.stream {}
            didFinalize.yield(()); didFinalize.finish()
            // The already-owned final write deliberately finishes after cancellation.
            await Task.detached { for await _ in permission { break } }.value
            try? Data("finalized".utf8).write(to: receipt, options: .atomic)
        }
        let lifecycle = RecordingLifecycle()
        try await lifecycle.start(operation: {}, rollback: {})
        let stopping = Task {
            try await lifecycle.stop(onRequest: {}, operation: { await RecordingLifecycle.cancelAndJoin([pipeline]) })
        }
        for await _ in finalizing { break }
        let replacementStarted = expectation(description: "Replacement remains blocked until final media write")
        replacementStarted.isInverted = true
        let replacement = Task {
            try await lifecycle.start(operation: {
                replacementStarted.fulfill()
                XCTAssertEqual(try? String(contentsOf: receipt, encoding: .utf8), "finalized")
            }, rollback: {})
        }
        await fulfillment(of: [replacementStarted], timeout: 0.2)
        mayFinalize.yield(()); mayFinalize.finish()
        await pipeline.value
        try await stopping.value; try await replacement.value
    }

    func testExplicitPauseStillRunsWhenItJoinsAnUnexpectedStop() async throws {
        let lifecycle = RecordingLifecycle()
        let device = RecordingTestDevice()
        await device.completeAcquisition()
        try await lifecycle.start(operation: { try await device.acquire() }, rollback: { await device.release() })
        let (entered, didEnter) = AsyncStream<Void>.makeStream()
        let (finish, mayFinish) = AsyncStream<Void>.makeStream()
        let unexpectedStop = Task {
            try await lifecycle.stop(onRequest: {}, operation: {
                didEnter.yield(()); didEnter.finish()
                for await _ in finish { break }
                await device.release()
            })
        }
        for await _ in entered { break }
        let contentPaused = expectation(description: "Explicit pause fences content even while teardown is shared")
        let explicitStop = Task {
            try await lifecycle.stop(onRequest: {
                await device.pauseContent(); contentPaused.fulfill()
            }, operation: { XCTFail("Joined teardown must not acquire a second teardown owner") })
        }
        await fulfillment(of: [contentPaused], timeout: 1)
        mayFinish.yield(()); mayFinish.finish()
        try await unexpectedStop.value; try await explicitStop.value
        let events = await device.events
        XCTAssertEqual(events, ["acquiring", "acquired", "content-paused", "released"])
    }

    func testStopFencesContentImmediatelyAndJoinsLateDeviceCompletionBeforeRestart() async throws {
        let lifecycle = RecordingLifecycle()
        let device = RecordingTestDevice()
        let first = Task {
            try await lifecycle.start(operation: { try await device.acquire() }, rollback: { await device.release() })
        }
        await device.waitUntilAcquiring()
        let stopping = Task { try await lifecycle.stop(onRequest: { await device.pauseContent() }, operation: {}) }
        await device.waitUntilPaused()
        let replacement = Task {
            try await lifecycle.start(operation: { try await device.acquire() }, rollback: { await device.release() })
        }
        await device.completeAcquisition()
        do { try await first.value; XCTFail("Cancelled startup must not report a running recorder") }
        catch is CancellationError {} catch { XCTFail("Unexpected startup error: \(type(of: error))") }
        try await stopping.value
        try await replacement.value
        let events = await device.events
        XCTAssertEqual(events, ["acquiring", "content-paused", "acquired", "released", "acquiring", "acquired"])
        let maximumOwners = await device.maximumOwners
        XCTAssertEqual(maximumOwners, 1, "A late completion must not share devices with its replacement")
        try await lifecycle.stop(onRequest: {}, operation: { await device.release() })
    }

    func testDuplicateStartJoinsOneDeviceAcquisition() async throws {
        let lifecycle = RecordingLifecycle()
        let device = RecordingTestDevice()
        let first = Task { try await lifecycle.start(operation: { try await device.acquire() }, rollback: { await device.release() }) }
        await device.waitUntilAcquiring()
        let joined = Task { try await lifecycle.start(operation: { try await device.acquire() }, rollback: { await device.release() }) }
        // The operation's real AsyncStream remains suspended while another caller joins.
        await Task.yield()
        await device.completeAcquisition()
        try await first.value; try await joined.value
        let events = await device.events
        XCTAssertEqual(events.filter { $0 == "acquiring" }.count, 1)
        try await lifecycle.stop(onRequest: {}, operation: { await device.release() })
    }

    func testFailedStartupRollsBackBeforeAReplacementCanAcquire() async throws {
        let lifecycle = RecordingLifecycle()
        let device = RecordingTestDevice()
        await device.completeAcquisition()
        do {
            try await lifecycle.start(operation: {
                try await device.acquire()
                throw CocoaError(.fileReadUnknown)
            }, rollback: { await device.release() })
            XCTFail("Acquisition failure must propagate")
        } catch is CocoaError {}
        try await lifecycle.start(operation: { try await device.acquire() }, rollback: { await device.release() })
        let events = await device.events
        XCTAssertEqual(events, ["acquiring", "acquired", "released", "acquiring", "acquired"])
        try await lifecycle.stop(onRequest: {}, operation: { await device.release() })
    }
}

/// Only the external device completion is controlled. Production task ownership,
/// cancellation, joining and rollback run against actual suspended AsyncStreams.
private actor RecordingTestDevice {
    private let acquisition = AsyncStream<Void>.makeStream()
    private let started = AsyncStream<Void>.makeStream()
    private let paused = AsyncStream<Void>.makeStream()
    private var completed = false
    private var owners = 0
    private(set) var maximumOwners = 0
    private(set) var events: [String] = []

    func acquire() async throws {
        events.append("acquiring"); started.continuation.yield(())
        if !completed {
            // Simulate a device API which completes after task cancellation.
            let stream = acquisition.stream
            await Task.detached { for await _ in stream { break } }.value
        }
        owners += 1; maximumOwners = max(maximumOwners, owners)
        events.append("acquired")
    }
    func release() { owners = max(0, owners - 1); events.append("released") }
    func completeAcquisition() { completed = true; acquisition.continuation.yield(()); acquisition.continuation.finish() }
    func waitUntilAcquiring() async { for await _ in started.stream { break } }
    func pauseContent() { events.append("content-paused"); paused.continuation.yield(()) }
    func waitUntilPaused() async { for await _ in paused.stream { break } }
}
