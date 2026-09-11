import CoreGraphics
import XCTest
import Shared
@testable import Capture

/// Exercise the production forwarding task with real AsyncStream termination and
/// CoreGraphics pixels. Gates suspend metadata work at the stop/restart boundary.
final class CaptureStreamLifecycleTests: XCTestCase {
    func testOldWorkerCannotPublishIntoOrFinishReplacementOutput() async throws {
        let manager = CaptureManager()
        let gate = CaptureMetadataGate()
        let entered = expectation(description: "old metadata started")
        let old = await manager.startFrameProcessing { frame in
            entered.fulfill()
            await gate.wait()
            return frame
        }
        old.input.yield(try renderedFrame(white: false))
        await fulfillment(of: [entered], timeout: 2)

        // Simulate an ended raw stream whose metadata await outlives replacement.
        old.input.finish()
        let replacement = await manager.startFrameProcessing { $0 }
        await gate.release()
        await old.task.value

        replacement.input.yield(try renderedFrame(white: true))
        replacement.input.finish()
        var replacementPixels: [Data] = []
        for await frame in replacement.output {
            replacementPixels.append(frame.imageData)
        }
        await replacement.task.value

        XCTAssertEqual(replacementPixels, [try renderedFrame(white: true).imageData],
                       "An old worker must neither inject old pixels nor close the new consumer stream")
        await manager.stopFrameProcessing()
    }

    func testStopJoinsMetadataWorkAndDiscardsFramesAcrossCancellation() async throws {
        let manager = CaptureManager()
        let gate = CaptureMetadataGate()
        let entered = expectation(description: "metadata started")
        let stopReturned = expectation(description: "stop must await worker")
        stopReturned.isInverted = true
        let session = await manager.startFrameProcessing { frame in
            entered.fulfill()
            await gate.wait()
            return frame
        }
        session.input.yield(try renderedFrame(white: false))
        await fulfillment(of: [entered], timeout: 2)
        let stop = Task {
            await manager.stopFrameProcessing()
            stopReturned.fulfill()
        }
        await fulfillment(of: [stopReturned], timeout: 0.1)
        await gate.release()
        await stop.value
        await session.task.value

        var received = 0
        for await _ in session.output { received += 1 }
        XCTAssertEqual(received, 0, "In-flight metadata cannot publish after capture cancellation")
        XCTAssertTrue(session.task.isCancelled, "The owner must cancel its worker before joining it")
        if case .terminated = session.input.yield(try renderedFrame(white: true)) {
            // Stopped input cannot retain more screenshots.
        } else {
            XCTFail("Stopped input remained open")
        }
    }

    func testNaturalInputCompletionDrainsAcceptedFramesBeforeOutputFinishes() async throws {
        let config = CaptureConfig(adaptiveCaptureEnabled: false)
        let manager = CaptureManager(config: config)
        let session = await manager.startFrameProcessing { $0 }
        let expected = try [renderedFrame(white: false), renderedFrame(white: true)]
        expected.forEach { session.input.yield($0) }
        session.input.finish()

        var received: [Data] = []
        for await frame in session.output { received.append(frame.imageData) }
        await session.task.value
        XCTAssertEqual(received, expected.map(\.imageData))
        await manager.stopFrameProcessing()
    }

    func testLifecycleOperationWaitsForSuspendedFailureThenAllowsRetry() async throws {
        let manager = CaptureManager()
        let gate = CaptureMetadataGate()
        let entered = expectation(description: "first lifecycle operation suspended")
        let prematureRetry = expectation(description: "retry must not overtake first operation")
        prematureRetry.isInverted = true
        let first = Task {
            try await manager.runLifecycleOperation {
                entered.fulfill()
                await gate.wait()
                throw CaptureError.permissionDenied
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let retry = Task {
            try await manager.runLifecycleOperation {
                prematureRetry.fulfill()
            }
        }
        await fulfillment(of: [prematureRetry], timeout: 0.1)
        await gate.release()
        do {
            try await first.value
            XCTFail("The first caller must receive its source error")
        } catch CaptureError.permissionDenied {
            // The error is propagated to its own caller, not to queued work.
        }
        try await retry.value
    }

    func testDisplaySourceOperationCannotOvertakeSuspendedLifecycleWork() async throws {
        let manager = CaptureManager()
        let session = await manager.startFrameProcessing { $0 }
        let gate = CaptureMetadataGate()
        let entered = expectation(description: "source stop suspended")
        let overtookStop = expectation(description: "display source must wait for lifecycle stop")
        overtookStop.isInverted = true
        let stopping = Task {
            try await manager.runLifecycleOperation {
                entered.fulfill()
                await gate.wait()
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let switching = Task {
            try await manager.runDisplaySwitchOperation(sessionID: session.id) {
                overtookStop.fulfill()
            }
        }
        await fulfillment(of: [overtookStop], timeout: 0.1)
        await gate.release()
        try await stopping.value
        try await switching.value
        await manager.stopFrameProcessing()
    }

    func testQueuedDisplayOperationRechecksSessionAfterAdmission() async throws {
        let manager = CaptureManager()
        let old = await manager.startFrameProcessing { $0 }
        let gate = CaptureMetadataGate()
        let entered = expectation(description: "source lifecycle suspended")
        let calls = CaptureOperationCounter()
        let staleDisplay = expectation(description: "old display must not touch replacement source")
        staleDisplay.isInverted = true
        let lifecycle = Task {
            try await manager.runLifecycleOperation {
                entered.fulfill()
                await gate.wait()
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let switching = Task {
            try await manager.runDisplaySwitchOperation(sessionID: old.id) {
                await calls.increment()
                staleDisplay.fulfill()
            }
        }
        await fulfillment(of: [staleDisplay], timeout: 0.1)
        let replacement = await manager.startFrameProcessing { $0 }
        await gate.release()
        try await lifecycle.value
        try await switching.value
        await old.task.value
        let staleCalls = await calls.value
        XCTAssertEqual(staleCalls, 0, "Admission must reject the old generation after queued work finishes")
        replacement.input.yield(try renderedFrame(white: true))
        replacement.input.finish()
        var frameCount = 0
        for await _ in replacement.output { frameCount += 1 }
        XCTAssertEqual(frameCount, 1)
        await manager.stopFrameProcessing()
    }

    private func renderedFrame(white: Bool) throws -> CapturedFrame {
        let width = 32
        let height = 32
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.setFillColor(CGColor(gray: white ? 1 : 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(context.data)
        return CapturedFrame(imageData: Data(bytes: pixels, count: width * height * 4),
                             width: width, height: height, bytesPerRow: width * 4)
    }
}

private actor CaptureMetadataGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor CaptureOperationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
