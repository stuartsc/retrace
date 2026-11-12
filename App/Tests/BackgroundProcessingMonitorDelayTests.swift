import Dispatch
import Foundation
import XCTest
@testable import App

final class BackgroundProcessingMonitorDelayTests: XCTestCase {
    func testCancellationBeforeContinuationRegistrationStillDrainsNativeSource() async {
        let queue = makeQueue()
        let checkpoints = MonitorDelayCheckpoints()
        let delay = BackgroundProcessingMonitorDelay(interval: .seconds(60), queue: queue,
                                                     checkpoint: checkpoints.record)
        let beforeWait = MonitorDelayAsyncGate()
        let taskEntered = expectation(description: "Task waits before registering its delay")
        let completion = MonitorDelayCompletion()
        let task = Task {
            taskEntered.fulfill()
            await beforeWait.wait() // Deliberately insensitive to task cancellation.
            await completion.run { try await delay.wait() }
        }
        defer { beforeWait.open(); task.cancel() }

        await fulfillment(of: [taskEntered], timeout: 3)
        task.cancel()
        beforeWait.open()
        await join(task, completion: completion)

        XCTAssertEqual(completion.outcome, .cancelled)
        XCTAssertEqual(completion.finishCount, 1)
        XCTAssertEqual(checkpoints.counts, .init(armed: 1, events: 0, cancellations: 1))
    }

    func testRepeatedCancellationAfterRegistrationDrainsExactlyOnce() async {
        let queue = makeQueue()
        let checkpoints = MonitorDelayCheckpoints()
        let armed = expectation(description: "Native source activated")
        let delay = BackgroundProcessingMonitorDelay(interval: .seconds(60), queue: queue) { checkpoint in
            checkpoints.record(checkpoint)
            if case .armed = checkpoint { armed.fulfill() }
        }
        let completion = MonitorDelayCompletion()
        let task = Task { await completion.run { try await delay.wait() } }
        defer { task.cancel() }

        await fulfillment(of: [armed], timeout: 3)
        for _ in 0..<20 { task.cancel() }
        await join(task, completion: completion)

        XCTAssertEqual(completion.outcome, .cancelled)
        XCTAssertEqual(completion.finishCount, 1)
        XCTAssertEqual(checkpoints.counts, .init(armed: 1, events: 0, cancellations: 1))
    }

    func testNativeFireCompletesOnlyAfterSourceCancellation() async {
        let queue = makeQueue()
        let checkpoints = MonitorDelayCheckpoints()
        let delay = BackgroundProcessingMonitorDelay(interval: .milliseconds(1), queue: queue,
                                                     checkpoint: checkpoints.record)
        let completion = MonitorDelayCompletion()
        let task = Task { await completion.run { try await delay.wait() } }
        defer { task.cancel() }

        await join(task, completion: completion)

        XCTAssertEqual(completion.outcome, .succeeded)
        XCTAssertEqual(completion.finishCount, 1)
        XCTAssertEqual(checkpoints.counts, .init(armed: 1, events: 1, cancellations: 1))
    }

    func testCancellationWhileActualEventHandlerIsHeldJoinsBeforeThrowing() async {
        let queue = makeQueue()
        let checkpoints = MonitorDelayCheckpoints()
        let event = MonitorDelayNativeGate("Actual timer event selected")
        let completion = MonitorDelayCompletion()
        let delay = BackgroundProcessingMonitorDelay(interval: .milliseconds(1), queue: queue) { checkpoint in
            checkpoints.record(checkpoint)
            if case .eventSelected = checkpoint { event.hold() }
        }
        let task = Task { await completion.run { try await delay.wait() } }
        defer { event.release(); task.cancel() }

        await fulfillment(of: [event.entered], timeout: 3)
        for _ in 0..<20 { task.cancel() }
        await monitorDelayTestPace(.milliseconds(50))
        XCTAssertEqual(completion.outcome, .pending, "Cancellation cannot return through a running event handler")
        XCTAssertEqual(checkpoints.counts.cancellations, 0, "The serial cancel handler must wait for its event")
        event.release()
        await join(task, completion: completion)

        XCTAssertFalse(event.timedOut)
        XCTAssertEqual(completion.outcome, .cancelled, "Cancellation after fire still throws at the joined wait boundary")
        XCTAssertEqual(completion.finishCount, 1)
        XCTAssertEqual(checkpoints.counts, .init(armed: 1, events: 1, cancellations: 1))
    }

    func testWaitJoinsCancelHandlerReturnAndItsSameQueueFinalizer() async {
        let queue = makeQueue()
        let checkpoints = MonitorDelayCheckpoints()
        let armed = expectation(description: "Native source activated")
        let cancelHandler = MonitorDelayNativeGate("Actual native cancel handler entered")
        let beforeFinalizer = MonitorDelayNativeGate("Serial successor after native cancel handler returned")
        let completion = MonitorDelayCompletion()
        let delay = BackgroundProcessingMonitorDelay(interval: .seconds(60), queue: queue) { checkpoint in
            checkpoints.record(checkpoint)
            switch checkpoint {
            case .armed:
                armed.fulfill()
            case .eventSelected:
                break
            case .cancelHandlerEntered:
                // Enqueued by the actual handler, before it can enqueue its finalizer.
                // Reaching this successor proves the native handler has returned.
                queue.async { beforeFinalizer.hold() }
                cancelHandler.hold()
            }
        }
        let task = Task { await completion.run { try await delay.wait() } }
        defer { cancelHandler.release(); beforeFinalizer.release(); task.cancel() }

        await fulfillment(of: [armed], timeout: 3)
        task.cancel()
        await fulfillment(of: [cancelHandler.entered], timeout: 3)
        XCTAssertEqual(completion.outcome, .pending, "The native cancel handler itself is still running")
        cancelHandler.release()
        await fulfillment(of: [beforeFinalizer.entered], timeout: 3)
        XCTAssertTrue(cancelHandler.didReturn)
        XCTAssertEqual(completion.outcome, .pending, "Handler return alone must not bypass its queued finalizer")
        beforeFinalizer.release()
        await join(task, completion: completion)

        XCTAssertFalse(cancelHandler.timedOut)
        XCTAssertFalse(beforeFinalizer.timedOut)
        XCTAssertEqual(completion.outcome, .cancelled)
        XCTAssertEqual(completion.finishCount, 1)
        XCTAssertEqual(checkpoints.counts, .init(armed: 1, events: 0, cancellations: 1))
    }

    func testHundredAlternatingFiresAndCancellationsLeaveNoOutstandingDelay() async {
        let queue = makeQueue()
        let checkpoints = MonitorDelayCheckpoints()
        var releasedDelays: [MonitorDelayWeakReference] = []
        for index in 0..<100 {
            releasedDelays.append(await runIteration(index: index, queue: queue, checkpoints: checkpoints))
        }
        // This barrier is ordered behind every native handler/finalizer on the owner queue.
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }

        XCTAssertEqual(checkpoints.counts, .init(armed: 100, events: 50, cancellations: 100))
        XCTAssertTrue(releasedDelays.allSatisfy { $0.value == nil }, "Joined sources must release every delay owner")
    }

    private func runIteration(index: Int, queue: DispatchQueue,
                              checkpoints: MonitorDelayCheckpoints) async -> MonitorDelayWeakReference {
        let cancelled = index.isMultiple(of: 2)
        let armed = expectation(description: "Iteration \(index) armed")
        let delay = BackgroundProcessingMonitorDelay(interval: cancelled ? .seconds(60) : .milliseconds(1),
                                                     queue: queue) { checkpoint in
            checkpoints.record(checkpoint)
            if case .armed = checkpoint { armed.fulfill() }
        }
        let weakReference = MonitorDelayWeakReference(delay)
        let completion = MonitorDelayCompletion()
        let task = Task { await completion.run { try await delay.wait() } }
        await fulfillment(of: [armed], timeout: 3)
        if cancelled { for _ in 0..<3 { task.cancel() } }
        await join(task, completion: completion)
        XCTAssertEqual(completion.outcome, cancelled ? .cancelled : .succeeded, "Iteration \(index)")
        XCTAssertEqual(completion.finishCount, 1, "Iteration \(index)")
        task.cancel()
        return weakReference
    }

    private func join(_ task: Task<Void, Never>, completion: MonitorDelayCompletion) async {
        await fulfillment(of: [completion.finished], timeout: 3)
        if completion.outcome != .pending {
            await task.value
        } else {
            // Do not replace the XCTest deadline with an unbounded task join on failure.
            task.cancel()
        }
    }

    private func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "com.retrace.tests.monitor-delay.\(UUID().uuidString)", qos: .utility)
    }
}

final class MonitorDelayCheckpoints: @unchecked Sendable {
    struct Counts: Equatable {
        var armed = 0
        var events = 0
        var cancellations = 0
    }
    private let lock = NSLock()
    private var value = Counts()
    var counts: Counts { lock.withLock { value } }
    func record(_ checkpoint: BackgroundProcessingMonitorDelay.Checkpoint) {
        lock.withLock {
            switch checkpoint {
            case .armed: value.armed += 1
            case .eventSelected: value.events += 1
            case .cancelHandlerEntered: value.cancellations += 1
            }
        }
    }
}

final class MonitorDelayCompletion: @unchecked Sendable {
    enum Outcome: Equatable { case pending, succeeded, cancelled, unexpectedError }
    let finished = XCTestExpectation(description: "Owned async operation finished")
    private let lock = NSLock()
    private var result = Outcome.pending
    private var count = 0
    var outcome: Outcome { lock.withLock { result } }
    var finishCount: Int { lock.withLock { count } }
    func run(_ operation: () async throws -> Void) async {
        let outcome: Outcome
        do { try await operation(); outcome = .succeeded }
        catch is CancellationError { outcome = .cancelled }
        catch { outcome = .unexpectedError }
        lock.withLock { result = outcome; count += 1 }
        finished.fulfill()
    }
}

final class MonitorDelayAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if opened { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
    func open() {
        let continuations = lock.withLock {
            opened = true
            let result = waiting
            waiting.removeAll()
            return result
        }
        continuations.forEach { $0.resume() }
    }
}

private final class MonitorDelayNativeGate: @unchecked Sendable {
    let entered: XCTestExpectation
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var released = false
    private var timeout = false
    private var returned = false
    var timedOut: Bool { lock.withLock { timeout } }
    var didReturn: Bool { lock.withLock { returned } }
    init(_ description: String) { entered = XCTestExpectation(description: description) }
    func hold() {
        entered.fulfill()
        // This runs only on the private native-delivery queue, never the main/UI queue.
        let result = semaphore.wait(timeout: .now() + .seconds(5))
        lock.withLock { timeout = result == .timedOut; returned = true }
    }
    func release() {
        let shouldSignal = lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        if shouldSignal { semaphore.signal() }
    }
}

private final class MonitorDelayWeakReference {
    weak var value: BackgroundProcessingMonitorDelay?
    init(_ value: BackgroundProcessingMonitorDelay) { self.value = value }
}

func monitorDelayTestPace(_ interval: DispatchTimeInterval) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval) { continuation.resume() }
    }
}
