import XCTest
@testable import Processing

final class FrameProcessingWakeSignalTests: XCTestCase {
    func testNotificationBeforeRegistrationIsNotLost() async {
        let signal = FrameProcessingWakeSignal()
        let generation = await signal.snapshot()
        await signal.notify()
        let finished = expectation(description: "changed generation returns immediately")
        let task = Task {
            await signal.wait(after: generation, timeout: .seconds(10))
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)
        task.cancel()
        await task.value
    }

    func testNotificationWakesAllRegisteredWorkers() async {
        let signal = FrameProcessingWakeSignal()
        let generation = await signal.snapshot()
        let finished = expectation(description: "all idle workers wake")
        finished.expectedFulfillmentCount = 3
        let tasks = (0..<3).map { _ in Task {
            await signal.wait(after: generation, timeout: .seconds(10))
            finished.fulfill()
        } }
        for _ in 0..<1_000 {
            if await signal.pendingWaiterCount == 3 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let count = await signal.pendingWaiterCount
        XCTAssertEqual(count, 3)
        await signal.notify()
        await fulfillment(of: [finished], timeout: 1)
        for task in tasks { task.cancel(); await task.value }
        let remaining = await signal.pendingWaiterCount
        XCTAssertEqual(remaining, 0)
    }

    func testCancellationUnregistersWaiterWithoutNotification() async {
        let signal = FrameProcessingWakeSignal()
        let generation = await signal.snapshot()
        let finished = expectation(description: "cancel wakes idle worker")
        let task = Task {
            await signal.wait(after: generation, timeout: .seconds(10))
            finished.fulfill()
        }
        for _ in 0..<1_000 {
            if await signal.pendingWaiterCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        await fulfillment(of: [finished], timeout: 1)
        await task.value
        let remaining = await signal.pendingWaiterCount
        XCTAssertEqual(remaining, 0)
    }

    func testTimeoutPermitsDurableQueuePolling() async {
        let signal = FrameProcessingWakeSignal()
        let generation = await signal.snapshot()
        let finished = expectation(description: "external enqueue fallback")
        let task = Task {
            await signal.wait(after: generation, timeout: .milliseconds(10))
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)
        task.cancel()
        await task.value
        let remaining = await signal.pendingWaiterCount
        XCTAssertEqual(remaining, 0)
    }
}
