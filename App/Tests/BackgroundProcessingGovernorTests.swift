import Foundation
import XCTest
import Shared
@testable import App

final class BackgroundProcessingGovernorTests: XCTestCase {
    func testAlternatingFreshAndSpeechCannotResetTheHistoricalFairnessBudget() async throws {
        let governor = BackgroundProcessingGovernor(observeSystem: false)
        await governor.updateEnvironment(.init(idleSeconds: 600, pressureAllowsProcessing: false))
        let history = Task { try await governor.acquire(.historicalOCR) }
        try await waitForQueue(governor, count: 1)
        let firstFresh = Task { try await governor.acquire(.freshOCR) }
        try await waitForQueue(governor, count: 2)
        let firstSpeech = Task { try await governor.acquire(.ambientSpeech) }
        try await waitForQueue(governor, count: 3)
        await governor.updateEnvironment(.init(idleSeconds: 600))
        await governor.release(try await firstFresh.value)
        let nextFresh = Task { try await governor.acquire(.freshOCR) }
        try await waitForQueue(governor, count: 2)
        await governor.release(try await firstSpeech.value)
        let nextSpeech = Task { try await governor.acquire(.ambientSpeech) }
        try await waitForQueue(governor, count: 2)
        await governor.release(try await nextFresh.value)
        let snapshot = await governor.snapshot()
        XCTAssertEqual(snapshot.activeKind, .historicalOCR)
        if snapshot.activeKind != .historicalOCR { await governor.release(try await nextSpeech.value) }
        await governor.release(try await history.value)
        if snapshot.activeKind == .historicalOCR { await governor.release(try await nextSpeech.value) }
        await governor.close()
    }

    func testQueuedOCRGetsATurnAgainstContinuousSpeechAndFreshWork() async throws {
        for kind in [BackgroundProcessingKind.ambientSpeech, .freshOCR] {
            let governor = BackgroundProcessingGovernor(observeSystem: false)
            await governor.updateEnvironment(.init(idleSeconds: 600, pressureAllowsProcessing: false))
            var work: [Task<BackgroundProcessingPermit, Error>] = []
            for count in 1...4 {
                work.append(Task { try await governor.acquire(kind) })
                try await waitForQueue(governor, count: count)
            }
            let history = Task { try await governor.acquire(.historicalOCR) }
            try await waitForQueue(governor, count: 5)
            await governor.updateEnvironment(.init(idleSeconds: 600))
            for request in work.prefix(3) { await governor.release(try await request.value) }
            let next = await governor.snapshot()
            XCTAssertEqual(next.activeKind, .historicalOCR)
            if next.activeKind != .historicalOCR { await governor.release(try await work[3].value) }
            await governor.release(try await history.value)
            if next.activeKind == .historicalOCR { await governor.release(try await work[3].value) }
            await governor.close()
        }
    }

    func testEmptyManualAndFreshProbesPreserveHistoricalSchedulerGrant() async throws {
        let scheduler = ConsumableBackgroundGrant()
        let governor = BackgroundProcessingGovernor(scheduler: scheduler)
        await governor.updateEnvironment(.init(idleSeconds: 600, systemAllowsProcessing: scheduler.allowsProcessing))
        let manual = try await BackgroundProcessingContext.$explicitRequest.withValue(true) {
            try await governor.tryAcquire(.historicalOCR)
        }
        await governor.release(try XCTUnwrap(manual))
        XCTAssertTrue(scheduler.allowsProcessing, "Empty manual probing does not own macOS background time")
        let fresh = try await governor.tryAcquire(.freshOCR)
        await governor.release(try XCTUnwrap(fresh))
        XCTAssertTrue(scheduler.allowsProcessing, "Fresh OCR does not consume the history window")
        await governor.updateEnvironment(.init(idleSeconds: 600, systemAllowsProcessing: scheduler.allowsProcessing))
        let historical = try await governor.tryAcquire(.historicalOCR)
        await governor.release(try XCTUnwrap(historical))
        XCTAssertFalse(scheduler.allowsProcessing, "Actual scheduled work discharges its native grant")
        await governor.close()
    }
    func testExplicitRequestRunsDuringInteractionAndCancellationReleasesSharedSlot() async throws {
        let governor = BackgroundProcessingGovernor(observeSystem: false)
        await governor.updateEnvironment(.init(idleSeconds: 0, systemAllowsProcessing: false))
        let entered = expectation(description: "Explicit request entered shared slot")
        let request = Task {
            try await BackgroundProcessingContext.$explicitRequest.withValue(true) {
                try await BackgroundProcessingContext.run(governor: governor, kind: .refinement) {
                    entered.fulfill()
                    try await Task.sleep(for: .seconds(60))
                }
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        let automatic = Task { try await governor.acquire(.ambientSpeech) }
        try await waitForQueue(governor, count: 1)
        let running = await governor.snapshot()
        XCTAssertEqual(running.activeKind, .refinement)
        XCTAssertFalse(running.processNow)
        request.cancel()
        do { try await request.value; XCTFail("Explicit request ignored task cancellation") } catch is CancellationError {}
        let stopped = await governor.snapshot()
        XCTAssertFalse(stopped.isRunning)
        XCTAssertEqual(stopped.waitingCount, 1)
        automatic.cancel()
        do { _ = try await automatic.value; XCTFail("Automatic work admitted during input") } catch is CancellationError {}
        await governor.close()
    }

    func testExplicitRequestCannotBypassPressureAndKeepsItsRequestScope() async throws {
        let governor = BackgroundProcessingGovernor(observeSystem: false)
        await governor.updateEnvironment(.init(idleSeconds: 0, pressureAllowsProcessing: false))
        let request = Task {
            try await BackgroundProcessingContext.$explicitRequest.withValue(true) { try await governor.acquire(.refinement) }
        }
        try await waitForQueue(governor, count: 1)
        let optional = try await BackgroundProcessingContext.$explicitRequest.withValue(true) { try await governor.tryAcquire(.refinement) }
        XCTAssertNil(optional)
        await governor.updateEnvironment(.init(idleSeconds: 0, systemAllowsProcessing: false))
        let permit = try await request.value
        await governor.updateEnvironment(.init(idleSeconds: 0, systemAllowsProcessing: false))
        await governor.setProcessNow(false)
        XCTAssertFalse(permit.cancellation.isCancelled, "Input and global override cancellation cannot cancel a separate explicit request")
        await governor.updateEnvironment(.init(idleSeconds: 0, pressureAllowsProcessing: false))
        XCTAssertTrue(permit.cancellation.isCancelled)
        await governor.release(permit)
        await governor.close()
    }

    func testExplicitRequestPreemptsAutomaticWorkWithoutChangingGlobalOverride() async throws {
        let governor = BackgroundProcessingGovernor(observeSystem: false)
        await governor.setProcessNow(true)
        let automatic = try await governor.acquire(.indexing)
        let queuedAutomatic = Task { try await governor.acquire(.ambientSpeech) }
        try await waitForQueue(governor, count: 1)
        let explicit = Task {
            try await BackgroundProcessingContext.$explicitRequest.withValue(true) { try await governor.acquire(.refinement) }
        }
        try await waitForQueue(governor, count: 2)
        XCTAssertTrue(automatic.cancellation.isCancelled)
        let preempting = await governor.snapshot()
        XCTAssertTrue(preempting.processNow)
        await governor.release(automatic)
        let permit = try await explicit.value
        let admitted = await governor.snapshot()
        XCTAssertEqual(admitted.activeKind, .refinement)
        XCTAssertEqual(admitted.waitingCount, 1)
        await governor.setProcessNow(false)
        XCTAssertFalse(permit.cancellation.isCancelled)
        await governor.release(permit)
        queuedAutomatic.cancel()
        do { _ = try await queuedAutomatic.value; XCTFail("Override unexpectedly persisted") } catch is CancellationError {}
        let optional = try await BackgroundProcessingContext.$explicitRequest.withValue(true) { try await governor.tryAcquire(.refinement) }
        await governor.release(try XCTUnwrap(optional))
        await governor.close()
    }

    private func waitForQueue(_ governor: BackgroundProcessingGovernor, count: Int) async throws {
        for _ in 0..<100 {
            if await governor.snapshot().waitingCount == count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Waiter did not enter queue")
    }

    func testIdleBoundaryAndLowPowerPermitThenInteractionCancelsNativeToken() async throws {
        let governor = BackgroundProcessingGovernor(observeSystem: false)
        await governor.updateEnvironment(.init(idleSeconds: 299, lowPowerMode: true))
        let request = Task { try await governor.acquire(.ambientSpeech) }
        try await waitForQueue(governor, count: 1)
        await governor.updateEnvironment(.init(idleSeconds: 300, lowPowerMode: true))
        let permit = try await request.value
        XCTAssertEqual(permit.threadCount, 2)
        XCTAssertFalse(permit.cancellation.isCancelled)
        await governor.updateEnvironment(.init(idleSeconds: 0))
        XCTAssertTrue(permit.cancellation.isCancelled)
        await governor.release(permit)
        await governor.close()
    }

    func testSingleFlightWaiterCancellationAndShutdownJoin() async throws {
        let governor = BackgroundProcessingGovernor(observeSystem: false)
        await governor.updateEnvironment(.init(idleSeconds: 600))
        let first = try await governor.acquire(.ambientSpeech)
        XCTAssertEqual(first.threadCount, 4)
        let second = Task { try await governor.acquire(.indexing) }
        try await waitForQueue(governor, count: 1)
        second.cancel()
        do { _ = try await second.value; XCTFail("Cancelled waiter admitted") } catch is CancellationError {}
        let closing = Task { await governor.close() }
        for _ in 0..<100 {
            if first.cancellation.isCancelled { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(first.cancellation.isCancelled)
        let beforeRelease = await governor.snapshot()
        XCTAssertTrue(beforeRelease.isRunning)
        await governor.release(first)
        await closing.value
        do { _ = try await governor.acquire(.ambientSpeech); XCTFail("Closed governor admitted work") } catch is CancellationError {}
    }

    func testOverrideCancellationAndPressureCannotBeBypassed() async throws {
        let governor = BackgroundProcessingGovernor(observeSystem: false)
        await governor.updateEnvironment(.init(idleSeconds: 0, pressureAllowsProcessing: false))
        await governor.setProcessNow(true)
        let request = Task { try await governor.acquire(.refinement) }
        try await waitForQueue(governor, count: 1)
        await governor.updateEnvironment(.init(idleSeconds: 0))
        let permit = try await request.value
        await governor.setProcessNow(false)
        XCTAssertTrue(permit.cancellation.isCancelled)
        await governor.release(permit)
        await governor.close()
    }

    func testSpeechPriorityStillEventuallyAdmitsSilence() async throws {
        let governor = BackgroundProcessingGovernor(observeSystem: false)
        var speech: [Task<BackgroundProcessingPermit, Error>] = []
        for count in 1...4 {
            speech.append(Task { try await governor.acquire(.ambientSpeech) })
            try await waitForQueue(governor, count: count)
        }
        let silence = Task { try await governor.acquire(.ambientSilence) }
        try await waitForQueue(governor, count: 5)
        await governor.updateEnvironment(.init(idleSeconds: 600))
        for job in speech.prefix(3) { await governor.release(try await job.value) }
        let fourth = await governor.snapshot()
        XCTAssertEqual(fourth.activeKind, .ambientSilence)
        // Make a fairness failure terminate rather than leaving the test hung on its waiter.
        if fourth.activeKind != .ambientSilence { await governor.release(try await speech[3].value) }
        let silencePermit = try await silence.value
        XCTAssertFalse(silencePermit.cancellation.isCancelled)
        await governor.release(silencePermit)
        await governor.release(try await speech[3].value)
        await governor.close()
    }

    func testStartupRollbackCanReopenOnlyAfterJoinedClose() async throws {
        let governor = BackgroundProcessingGovernor(observeSystem: false)
        try await governor.reopenAfterJoinedClose() // An unused/open governor remains inert.
        await governor.updateEnvironment(.init(idleSeconds: 600))
        let permit = try await governor.acquire(.indexing)
        let running = await governor.snapshot()
        XCTAssertEqual(running.activeKind, .indexing)
        await governor.cancelAutomaticWork()
        do { try await governor.reopenAfterJoinedClose(); XCTFail("Reopened before close") }
        catch BackgroundProcessingAdmissionError.closeIncomplete {}
        let closing = Task { await governor.close() }
        do { try await governor.reopenAfterJoinedClose(); XCTFail("Reopened with native work") }
        catch BackgroundProcessingAdmissionError.closeIncomplete {}
        await governor.release(permit)
        await closing.value
        try await governor.reopenAfterJoinedClose()
        let fresh = await governor.snapshot()
        XCTAssertFalse(fresh.isClosed)
        XCTAssertNil(fresh.activeKind)
        let staleIdle = try await governor.tryAcquire(.localSummary)
        XCTAssertNil(staleIdle, "Reopen must discard the previous idle observation")
        await governor.updateEnvironment(.init(idleSeconds: 600))
        let resumed = try await governor.acquire(.ambientSpeech)
        XCTAssertFalse(resumed.cancellation.isCancelled)
        await governor.release(resumed)
        await governor.close()
    }

    func testQueueBoundAndCancelledOwnerDoesNotReleaseNextOwner() async throws {
        let governor = BackgroundProcessingGovernor(observeSystem: false)
        var requests: [Task<BackgroundProcessingPermit, Error>] = []
        for count in 1...64 {
            requests.append(Task { try await governor.acquire(.indexing) })
            try await waitForQueue(governor, count: count)
        }
        do {
            _ = try await governor.acquire(.ambientSpeech)
            XCTFail("Unbounded admission")
        } catch BackgroundProcessingAdmissionError.queueFull {}
        requests.forEach { $0.cancel() }
        for request in requests {
            do { _ = try await request.value; XCTFail("Cancelled request admitted") } catch is CancellationError {}
        }
        await governor.updateEnvironment(.init(idleSeconds: 600))
        let old = try await governor.acquire(.indexing)
        await governor.release(old)
        let current = try await governor.acquire(.indexing)
        await governor.release(old)
        let snapshot = await governor.snapshot()
        XCTAssertTrue(snapshot.isRunning)
        await governor.release(current)
        await governor.close()
    }

    func testSystemDeferralAndInvalidIdleFailClosed() async throws {
        let governor = BackgroundProcessingGovernor(observeSystem: false)
        await governor.updateEnvironment(.init(idleSeconds: .nan))
        let request = Task { try await governor.acquire(.historicalOCR) }
        try await waitForQueue(governor, count: 1)
        await governor.updateEnvironment(.init(idleSeconds: 600, systemAllowsProcessing: false))
        let deferred = await governor.snapshot()
        XCTAssertFalse(deferred.isRunning)
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled waiter admitted") } catch is CancellationError {}
        await governor.close()
    }

    func testOriginalPressurePrioritizesExtractionWithoutBypassingInteraction() async throws {
        let governor = BackgroundProcessingGovernor(observeSystem: false)
        let speech = Task { try await governor.acquire(.ambientSpeech) }
        try await waitForQueue(governor, count: 1)
        let extraction = Task { try await governor.acquire(.historicalOCR) }
        try await waitForQueue(governor, count: 2)
        await governor.setOriginalSpoolPressure(true)
        let waiting = await governor.snapshot()
        XCTAssertTrue(waiting.originalSpoolUnderPressure)
        XCTAssertFalse(waiting.isRunning)
        await governor.updateEnvironment(.init(idleSeconds: 600))
        await governor.release(try await extraction.value)
        await governor.release(try await speech.value)
        await governor.close()
    }

    func testNativeObserverLifecycleAndTerminalAdmissionFence() async throws {
        // Uses real CGEventSource, load/thermal readings and native scheduler/pressure sources.
        // No inference or capture is started and no user preference is changed.
        for _ in 0..<3 {
            let governor = BackgroundProcessingGovernor()
            let request = Task { try await governor.acquire(.indexing) }
            try await waitForQueue(governor, count: 1)
            await governor.cancelAutomaticWork()
            do { _ = try await request.value; XCTFail("Fenced work admitted") } catch is CancellationError {}
            do { _ = try await governor.acquire(.indexing); XCTFail("Terminal fence reopened") } catch is CancellationError {}
            async let firstClose: Void = governor.close()
            async let secondClose: Void = governor.close()
            _ = await (firstClose, secondClose)
            try await governor.reopenAfterJoinedClose()
            await governor.close()
        }
    }

    func testOptionalWorkNeverWaitsOrJumpsQueuedWork() async throws {
        let governor = BackgroundProcessingGovernor(observeSystem: false)
        let unavailable = try await governor.tryAcquire(.localSummary)
        XCTAssertNil(unavailable)
        await governor.updateEnvironment(.init(idleSeconds: 600))
        let available = try await governor.tryAcquire(.localSummary)
        let permit = try XCTUnwrap(available)
        let busy = try await governor.tryAcquire(.localSummary)
        XCTAssertNil(busy)
        await governor.release(permit)
        await governor.close()
        do { _ = try await governor.tryAcquire(.localSummary); XCTFail("Closed optional admission") } catch is CancellationError {}
    }
}

private final class ConsumableBackgroundGrant: BackgroundActivityScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var available = true
    var allowsProcessing: Bool { lock.withLock { available } }
    func start() { }
    func finish(deferred: Bool) { lock.withLock { available = false } }
    func invalidate() { finish(deferred: true) }
}
