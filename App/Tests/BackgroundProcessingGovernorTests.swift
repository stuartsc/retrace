import Foundation
import XCTest
import Shared
@testable import App

final class BackgroundProcessingGovernorTests: XCTestCase {
    func testFreshTranscriptionRunsDuringInputAndKeepsNativeSchedulerGrant() async throws {
        let scheduler = ConsumableBackgroundGrant()
        let governor = BackgroundProcessingGovernor(scheduler: scheduler)
        await governor.updateEnvironment(.init(idleSeconds: 0, lowPowerMode: true,
                                               systemAllowsProcessing: false))
        scheduler.grant()
        let admitted = try await governor.tryAcquire(.freshTranscription)
        let permit = try XCTUnwrap(admitted)
        XCTAssertEqual(permit.threadCount, 1)
        await governor.updateEnvironment(.init(idleSeconds: 0, systemAllowsProcessing: false))
        await governor.setProcessNow(false)
        XCTAssertFalse(permit.cancellation.isCancelled, "Typing and cancelling catch-up do not cancel fresh text")
        await governor.release(permit)
        XCTAssertTrue(scheduler.allowsProcessing)
        let history = try await governor.tryAcquire(.ambientSpeech)
        XCTAssertNil(history, "Historical audio still waits for quiet time")
        await governor.close()
    }

    func testFreshTranscriptionPreemptsHistoryButJoinsItsNativeExit() async throws {
        let governor = BackgroundProcessingGovernor(observeSystem: false)
        await governor.updateEnvironment(.init(idleSeconds: 600))
        let history = try await governor.acquire(.indexing)
        let fresh = Task { try await governor.acquire(.freshTranscription) }
        try await waitForQueue(governor, count: 1)
        XCTAssertTrue(history.cancellation.isCancelled)
        let beforeRelease = await governor.snapshot()
        XCTAssertEqual(beforeRelease.activeKind, .indexing)
        await governor.release(history)
        let permit = try await fresh.value
        await governor.updateEnvironment(.init(idleSeconds: 0, pressureAllowsProcessing: false))
        XCTAssertTrue(permit.cancellation.isCancelled, "Native pressure still revokes fresh work")
        await governor.release(permit)
        await governor.close()
    }

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
        XCTAssertTrue(scheduler.allowsProcessing, "A completed job leaves the bounded quiet-time grant available for more work")
        await governor.close()
    }
    func testQuietGrantProcessesMultipleJobsThenEndsAtBudgetWithoutAbortingInference() async throws {
        let scheduler = ConsumableBackgroundGrant()
        let clock = QuietGrantClock()
        let governor = BackgroundProcessingGovernor(scheduler: scheduler, monotonicNow: { clock.now })
        await governor.updateEnvironment(.init(idleSeconds: 600))
        for _ in 0..<3 {
            let optional = try await governor.tryAcquire(.refinement)
            await governor.release(try XCTUnwrap(optional))
            XCTAssertTrue(scheduler.allowsProcessing, "Multiple jobs must fit in one native grant")
        }
        let optional = try await governor.tryAcquire(.refinement)
        let finishing = try XCTUnwrap(optional)
        clock.advance(21)
        await governor.updateEnvironment(.init(idleSeconds: 600))
        XCTAssertFalse(finishing.cancellation.isCancelled, "Budget ends new admission, not a bounded inference already in flight")
        await governor.release(finishing)
        XCTAssertFalse(scheduler.allowsProcessing)
        let denied = try await governor.tryAcquire(.refinement)
        XCTAssertNil(denied, "Cached environment cannot reuse a finished native grant")
        scheduler.grant()
        let next = try await governor.tryAcquire(.refinement)
        await governor.release(try XCTUnwrap(next))
        XCTAssertTrue(scheduler.allowsProcessing, "A new native grant starts a new budget")
        await governor.close()
    }

    func testQuietGrantDefersOnRenewedInputAndJoinsRunningInference() async throws {
        let scheduler = ConsumableBackgroundGrant()
        let governor = BackgroundProcessingGovernor(scheduler: scheduler)
        await governor.updateEnvironment(.init(idleSeconds: 600))
        let optional = try await governor.tryAcquire(.refinement)
        let permit = try XCTUnwrap(optional)
        await governor.updateEnvironment(.init(idleSeconds: 0))
        XCTAssertTrue(permit.cancellation.isCancelled)
        XCTAssertTrue(scheduler.allowsProcessing, "The native callback remains owned until the active inference exits")
        await governor.release(permit)
        XCTAssertFalse(scheduler.allowsProcessing)
        await governor.close()
    }

    func testPacedOverdueFirstPassCannotBlockFreshSpeechAndEventuallyProgresses() async throws {
        let scheduler = ConsumableBackgroundGrant()
        let clock = QuietGrantClock()
        let governor = BackgroundProcessingGovernor(scheduler: scheduler, monotonicNow: { clock.now })
        let sample = ResourceUsageSnapshot(observedAt: Date(), sampleUptime: 1, cpuPercent: 40,
            systemCPUPercent: 50, systemFiveSecondCPUPercent: 50, logicalCoreCount: 10,
            oneMinute: .init(cpuPercent: 40, sampledSeconds: 60, elapsedSeconds: 60), isCurrent: true)
        await governor.updateEnvironment(.init(idleSeconds: 0, resourceUsage: sample))
        let optional = try await governor.tryAcquire(.overdueTranscription)
        let first = try XCTUnwrap(optional, "Old audio can progress above the app-only soft target")
        XCTAssertEqual(first.threadCount, 1)
        await governor.release(first)
        let old = Task { try await governor.acquire(.overdueTranscription) }
        try await waitForQueue(governor, count: 1)
        let waiting = await governor.snapshot()
        XCTAssertEqual(waiting.waitReason, .audioPacing)
        let freshOptional = try await governor.tryAcquire(.freshTranscription)
        await governor.release(try XCTUnwrap(freshOptional, "Fresh speech bypasses old-audio pacing"))
        clock.advance(29)
        await governor.updateEnvironment(.init(idleSeconds: 0, resourceUsage: sample))
        let before = await governor.snapshot()
        XCTAssertFalse(before.isRunning)
        clock.advance(1)
        await governor.updateEnvironment(.init(idleSeconds: 0, resourceUsage: sample))
        let after = await governor.snapshot()
        XCTAssertEqual(after.activeKind, .overdueTranscription)
        await governor.release(try await old.value)
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

    func testMonitorWaitsForHeldResourceRefreshBeforeRearmingNativeDelay() async throws {
        let resources = HeldMonitorGovernorResources()
        let checkpoints = MonitorDelayCheckpoints()
        let governor = BackgroundProcessingGovernor(resourceUsage: resources,
            monitorDelayInterval: .milliseconds(20), monitorDelayCheckpoint: checkpoints.record)
        if let permit = try await governor.tryAcquire(.indexing) {
            await governor.release(permit) // Admission probe only; no indexed work is executed.
        }
        resources.resetMaximumConcurrentReads()
        let heldRead = resources.holdNextRead()
        defer { heldRead.release() }
        await fulfillment(of: [heldRead.entered], timeout: 3)
        guard heldRead.wasEntered else {
            heldRead.release()
            await joinMonitorGovernorClose(governor)
            return
        }
        let heldCounts = resources.counts
        let heldTimerCounts = checkpoints.counts

        // Six nominal timer intervals pass while the actual monitor read is held.
        await monitorDelayTestPace(.milliseconds(120))
        XCTAssertEqual(resources.counts.calls, heldCounts.calls, "A suspended refresh cannot launch another monitor read")
        XCTAssertEqual(resources.counts.active, 1)
        XCTAssertEqual(resources.counts.maximumActive, 1)
        XCTAssertEqual(checkpoints.counts, heldTimerCounts, "The next one-shot must not be armed before refresh returns")

        let followingRead = resources.holdNextRead()
        defer { followingRead.release() }
        heldRead.release()
        await fulfillment(of: [followingRead.entered], timeout: 3)
        guard followingRead.wasEntered else {
            followingRead.release()
            await joinMonitorGovernorClose(governor)
            return
        }
        XCTAssertEqual(resources.counts.calls, heldCounts.calls + 1)
        XCTAssertEqual(resources.counts.maximumActive, 1)
        XCTAssertEqual(checkpoints.counts.armed, heldTimerCounts.armed + 1)
        followingRead.release()
        await joinMonitorGovernorClose(governor)
        XCTAssertEqual(resources.counts.active, 0)
        XCTAssertEqual(checkpoints.counts.armed, checkpoints.counts.cancellations,
                       "Joined close must drain every native one-shot source")
    }

    func testConcurrentCloseJoinsHeldMonitorReadAndFencesReopenUntilRestartIsSafe() async throws {
        let resources = HeldMonitorGovernorResources()
        let checkpoints = MonitorDelayCheckpoints()
        let governor = BackgroundProcessingGovernor(resourceUsage: resources,
            monitorDelayInterval: .milliseconds(20), monitorDelayCheckpoint: checkpoints.record)
        if let permit = try await governor.tryAcquire(.indexing) {
            await governor.release(permit)
        }
        let heldRead = resources.holdNextRead()
        defer { heldRead.release() }
        await fulfillment(of: [heldRead.entered], timeout: 3)
        guard heldRead.wasEntered else {
            heldRead.release()
            await joinMonitorGovernorClose(governor)
            return
        }
        let readsBeforeClose = resources.counts.calls
        let timersBeforeClose = checkpoints.counts

        await governor.cancelAutomaticWork()
        let firstCompletion = MonitorDelayCompletion()
        let secondCompletion = MonitorDelayCompletion()
        let firstClose = Task { await firstCompletion.run { await governor.close() } }
        let secondClose = Task { await secondCompletion.run { await governor.close() } }
        defer { firstClose.cancel(); secondClose.cancel() }
        await monitorDelayTestPace(.milliseconds(120))

        XCTAssertEqual(firstCompletion.outcome, .pending, "Close must join the suspended monitor reader")
        XCTAssertEqual(secondCompletion.outcome, .pending, "Concurrent close must join the same reader")
        XCTAssertEqual(resources.counts.calls, readsBeforeClose)
        XCTAssertEqual(checkpoints.counts, timersBeforeClose)
        do {
            try await governor.reopenAfterJoinedClose()
            XCTFail("Reopen admitted a second observer before the held monitor read returned")
        } catch BackgroundProcessingAdmissionError.closeIncomplete { }
        do {
            if let permit = try await governor.tryAcquire(.indexing) { await governor.release(permit) }
            XCTFail("Closed governor admitted an observation request")
        } catch is CancellationError { }

        heldRead.release()
        await fulfillment(of: [firstCompletion.finished, secondCompletion.finished], timeout: 3)
        if firstCompletion.outcome != .pending { await firstClose.value }
        if secondCompletion.outcome != .pending { await secondClose.value }
        XCTAssertEqual(firstCompletion.outcome, .succeeded)
        XCTAssertEqual(secondCompletion.outcome, .succeeded)
        XCTAssertEqual(firstCompletion.finishCount, 1)
        XCTAssertEqual(secondCompletion.finishCount, 1)
        XCTAssertEqual(resources.counts.active, 0)
        XCTAssertEqual(checkpoints.counts.armed, checkpoints.counts.cancellations)
        guard firstCompletion.outcome == .succeeded, secondCompletion.outcome == .succeeded else { return }

        try await governor.reopenAfterJoinedClose()
        let reopened = await governor.snapshot()
        XCTAssertFalse(reopened.isClosed)
        XCTAssertFalse(reopened.isRunning)
        XCTAssertEqual(reopened.waitingCount, 0)
        XCTAssertNil(reopened.resourceUsage.sampleUptime, "Reopen must discard the previous observation")
        let countsAfterReopen = resources.counts.calls
        let timersAfterReopen = checkpoints.counts
        await monitorDelayTestPace(.milliseconds(120))
        XCTAssertEqual(resources.counts.calls, countsAfterReopen, "Reopen itself must not start an observer")
        XCTAssertEqual(checkpoints.counts, timersAfterReopen)

        if let permit = try await governor.tryAcquire(.indexing) { await governor.release(permit) }
        let restartedRead = resources.holdNextRead()
        defer { restartedRead.release() }
        await fulfillment(of: [restartedRead.entered], timeout: 3)
        XCTAssertGreaterThan(resources.counts.calls, countsAfterReopen)
        XCTAssertGreaterThan(checkpoints.counts.events, timersAfterReopen.events,
                             "Restart must receive a new actual native timer event")
        restartedRead.release()
        await joinMonitorGovernorClose(governor)
        XCTAssertEqual(resources.counts.active, 0)
        XCTAssertEqual(checkpoints.counts.armed, checkpoints.counts.cancellations)
    }

    private func joinMonitorGovernorClose(_ governor: BackgroundProcessingGovernor) async {
        let completion = MonitorDelayCompletion()
        let close = Task { await completion.run { await governor.close() } }
        await fulfillment(of: [completion.finished], timeout: 3)
        if completion.outcome != .pending { await close.value }
        else { close.cancel() }
        XCTAssertEqual(completion.outcome, .succeeded)
    }

    func testNativeObserverSustainedWakeAndJoinedRestart() async throws {
        guard ProcessInfo.processInfo.environment["RETRACE_TEST_NATIVE_GOVERNOR_SOAK"] == "1" else {
            throw XCTSkip("Explicit native governor soak is not enabled")
        }

        // The real governor, resource probe/series and scheduling bridges contain no Log calls.
        // No metric callback, service container, store, preference, capture or inference is used;
        // release builds therefore do not rely on the debug-only file-logging switch for isolation.
        let sampler = ResourceUsageMonitor()
        let governor = BackgroundProcessingGovernor(resourceUsage: sampler)
        let pacingQueue = DispatchQueue(label: "com.retrace.tests.native-governor-soak", qos: .utility)
        do {
            await sampler.start(recordMinute: nil)
            if let permit = try await governor.tryAcquire(.indexing) {
                await governor.release(permit) // Probe admission only; never execute indexed work.
            }

            let started = NativeResourceUsageProbe.uptime
            var samples = Set<Double>()
            var lastSample: Double?
            while NativeResourceUsageProbe.uptime - started < 90 {
                try Task.checkCancellation()
                let snapshot = await governor.snapshot()
                let observed = NativeResourceUsageProbe.uptime
                try requireNativeSoak(!snapshot.isClosed && !snapshot.isRunning &&
                    snapshot.activeKind == nil && snapshot.waitingCount == 0,
                    "Native observation unexpectedly closed, acquired work or retained waiters")
                if let sample = snapshot.resourceUsage.sampleUptime {
                    try requireNativeSoak(sample.isFinite && sample > 0 &&
                        sample <= observed && sample >= (lastSample ?? sample),
                        "Cached native resource sample has invalid or regressing uptime")
                    samples.insert(sample)
                    lastSample = sample
                }
                if observed - started >= 3 {
                    let age = snapshot.resourceUsage.sampleUptime.map { observed - $0 } ?? .infinity
                    try requireNativeSoak(age >= 0 && age <= 3,
                                          "Native observer exceeded the three-second sample freshness bound")
                }
                await nativeSoakPace(on: pacingQueue)
            }
            try requireNativeSoak(samples.count >= 60,
                                  "Native observation did not deliver 60 distinct cached resource samples")
            let finalObservation = await governor.snapshot()
            let finished = NativeResourceUsageProbe.uptime
            let finalAge = finalObservation.resourceUsage.sampleUptime.map { finished - $0 } ?? .infinity
            try requireNativeSoak(finalAge >= 0 && finalAge <= 3,
                                  "Native observer stopped refreshing before the 90-second observation ended")

            await governor.close()
            let closed = await governor.snapshot()
            try requireNativeSoak(closed.isClosed && !closed.isRunning &&
                closed.activeKind == nil && closed.waitingCount == 0,
                "Joined governor close retained active work or waiters")
            var terminalAdmissionDenied = false
            do {
                if let permit = try await governor.tryAcquire(.indexing) {
                    await governor.release(permit)
                }
            } catch is CancellationError {
                terminalAdmissionDenied = true
            }
            try requireNativeSoak(terminalAdmissionDenied, "Joined close did not deny further admission")

            try await governor.reopenAfterJoinedClose()
            let reopened = await governor.snapshot()
            try requireNativeSoak(!reopened.isClosed && !reopened.isRunning &&
                reopened.waitingCount == 0 && reopened.resourceUsage.sampleUptime == nil,
                "Reopened governor retained observations or started work before admission")
            let restarted = NativeResourceUsageProbe.uptime
            if let permit = try await governor.tryAcquire(.indexing) {
                await governor.release(permit)
            }
            var restartedSamples = Set<Double>()
            while NativeResourceUsageProbe.uptime - restarted < 6 && restartedSamples.count < 3 {
                try Task.checkCancellation()
                let snapshot = await governor.snapshot()
                let observed = NativeResourceUsageProbe.uptime
                try requireNativeSoak(!snapshot.isClosed && !snapshot.isRunning &&
                    snapshot.activeKind == nil && snapshot.waitingCount == 0,
                    "Restarted native observation unexpectedly closed or started work")
                if observed - restarted < 6, let sample = snapshot.resourceUsage.sampleUptime,
                   sample.isFinite && sample > restarted && sample <= observed {
                    restartedSamples.insert(sample)
                }
                if restartedSamples.count < 3 { await nativeSoakPace(on: pacingQueue) }
            }
            try requireNativeSoak(restartedSamples.count >= 3,
                                  "Restarted observer did not deliver three fresh samples within six seconds")
            await governor.close()
            await sampler.close()
            let stoppedSampler = await sampler.snapshot()
            try requireNativeSoak(!stoppedSampler.isCurrent, "Joined sampler close left current measurements")
            try Task.checkCancellation()
            print("RETRACE_NATIVE_GOVERNOR_SOAK_COMPLETE")
        } catch {
            // Join in ownership order even when an assertion, admission or cancellation fails.
            await governor.close()
            await sampler.close()
            throw error
        }
    }

    private func requireNativeSoak(_ condition: Bool, _ message: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        guard condition else {
            XCTFail(message, file: file, line: line)
            throw NativeGovernorSoakFailure.failedAssertion
        }
    }

    private func nativeSoakPace(on queue: DispatchQueue) async {
        // Sequential dispatch pacing avoids adding another Task.sleep loop to this diagnostic.
        await withCheckedContinuation { continuation in
            queue.asyncAfter(deadline: .now() + .milliseconds(500)) { continuation.resume() }
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

private enum NativeGovernorSoakFailure: Error { case failedAssertion }

/// Only the cached resource-read boundary is held. The governor's scheduler,
/// memory-pressure source, monitor queue and one-shot timers remain native.
private final class HeldMonitorGovernorResources: ResourceUsageProviding, @unchecked Sendable {
    struct Counts {
        var calls = 0
        var active = 0
        var maximumActive = 0
    }
    final class HeldRead: @unchecked Sendable {
        let entered = XCTestExpectation(description: "Actual governor monitor requested its resource snapshot")
        private let gate = MonitorDelayAsyncGate()
        private let lock = NSLock()
        private var observed = false
        var wasEntered: Bool { lock.withLock { observed } }
        func markEntered() {
            lock.withLock { observed = true }
            entered.fulfill()
        }
        func wait() async { await gate.wait() }
        func release() { gate.open() }
    }
    private let lock = NSLock()
    private var value = Counts()
    private var nextHold: HeldRead?
    var counts: Counts { lock.withLock { value } }
    func resetMaximumConcurrentReads() {
        lock.withLock { value.maximumActive = value.active }
    }
    func holdNextRead() -> HeldRead {
        lock.withLock {
            precondition(nextHold == nil, "A pending hold must first be consumed by a native read")
            let hold = HeldRead()
            nextHold = hold
            return hold
        }
    }
    func snapshot() async -> ResourceUsageSnapshot {
        let (hold, readNumber) = lock.withLock {
            value.calls += 1
            value.active += 1
            value.maximumActive = max(value.maximumActive, value.active)
            let hold = nextHold
            nextHold = nil
            return (hold, value.calls)
        }
        if let hold {
            hold.markEntered()
            await hold.wait() // Cancellation cannot stand in for the owner's joined reader return.
        }
        lock.withLock { value.active -= 1 }
        return .init(sampleUptime: Double(readNumber))
    }
}

private final class ConsumableBackgroundGrant: BackgroundActivityScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var available = true
    var allowsProcessing: Bool { lock.withLock { available } }
    func grant() { lock.withLock { available = true } }
    func start() { }
    func finish(deferred: Bool) { lock.withLock { available = false } }
    func invalidate() { finish(deferred: true) }
}

private final class QuietGrantClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}
