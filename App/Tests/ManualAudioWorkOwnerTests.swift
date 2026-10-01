import XCTest
import Database
@testable import App

final class ManualAudioWorkOwnerTests: XCTestCase {
    func testCloseCancelsAndJoinsWholeDatabaseTail() async throws {
        let services = ServiceContainer(inMemory: true)
        await services.setInitializationBoundaryForTesting(remainder: {})
        try await services.initialize()
        let database = await services.database
        let owner = await services.manualAudioWork
        let entered = expectation(description: "repair entered")
        let cancelled = expectation(description: "repair cancellation requested")
        let gate = ManualAudioOwnerGate()
        let finished = ManualAudioOwnerGate()
        await services.setBeforeDatabaseCloseForTesting {
            let tailFinished = await finished.isReleased
            XCTAssertTrue(tailFinished, "Service shutdown must join the full manual repair")
            let governor = await services.backgroundProcessing.snapshot()
            XCTAssertTrue(governor.isClosed)
        }
        let work = Task {
            try await owner.run {
                await withTaskCancellationHandler {
                    entered.fulfill()
                    await gate.wait()
                    // Represents an API/DB tail that cannot be interrupted.
                    try? await database.recordMetricEvent(metricType: .backgroundProcessing,
                                                          metadata: "{\"action\":\"testTail\"}")
                    await finished.release()
                } onCancel: { cancelled.fulfill() }
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        let closeReturned = ManualAudioOwnerGate()
        let close = Task { try await services.shutdown(); await closeReturned.release() }
        await fulfillment(of: [cancelled], timeout: 3)
        let early = await closeReturned.isReleased
        XCTAssertFalse(early, "SQLite must remain open until the cancelled repair's tail returns")
        await gate.release()
        _ = try? await work.value
        try await close.value
        let tailFinished = await finished.isReleased
        XCTAssertTrue(tailFinished)
    }

    func testCloseFencesNewManualRequestsUntilExplicitReopen() async throws {
        let owner = ManualAudioWorkOwner()
        await owner.close()
        do {
            _ = try await owner.run { 42 }
            XCTFail("A closed owner must reject new work")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        try await owner.reopen()
        let answer = try await owner.run { 42 }
        XCTAssertEqual(answer, 42)
        await owner.close()
    }

    func testConcurrentRequestRejectedAndCallerCancellationJoinsNativeTail() async throws {
        let owner = ManualAudioWorkOwner()
        let entered = expectation(description: "manual operation entered")
        let cancelled = expectation(description: "caller cancellation reached operation")
        let gate = ManualAudioOwnerGate()
        let returned = ManualAudioOwnerGate()
        let first = Task {
            _ = try? await owner.run {
                await withTaskCancellationHandler {
                    entered.fulfill()
                    await gate.wait()
                    return 42
                } onCancel: { cancelled.fulfill() }
            }
            await returned.release()
        }
        await fulfillment(of: [entered], timeout: 3)
        do {
            _ = try await owner.run { 0 }
            XCTFail("A second repair must not start concurrently")
        } catch ManualAudioWorkError.busy {} catch { XCTFail("Unexpected error: \(error)") }
        do {
            try await owner.reopen()
            XCTFail("Cannot reopen while an owned operation is still running")
        } catch ManualAudioWorkError.closeIncomplete {} catch { XCTFail("Unexpected error: \(error)") }
        first.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        let early = await returned.isReleased
        XCTAssertFalse(early)
        await gate.release()
        await first.value
        await owner.close()
    }
}

private actor ManualAudioOwnerGate {
    private(set) var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
