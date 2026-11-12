import XCTest
import Shared
@testable import App

final class ResourceProcessingPolicyTests: XCTestCase {
    func testCaptureNearBudgetCanRecoverWithoutFallingBelowFifteenPercent() {
        var policy = ResourceProcessingPolicy()
        policy.update(sample(0, cpu: 40), idleSeconds: 0)
        for time in 1...15 {
            policy.update(sample(Double(time), cpu: 19), idleSeconds: 0)
            XCTAssertEqual(policy.reason, .cpuBudget)
        }
        policy.update(sample(16, cpu: 19), idleSeconds: 0)
        XCTAssertNil(policy.reason, "Capture alone can use 15–20%; recovery must not permanently starve fresh text")
        policy.update(sample(17, cpu: 21), idleSeconds: 0)
        XCTAssertEqual(policy.reason, .cpuBudget, "New work still stops above the target")
        for time in 18...33 { policy.update(sample(Double(time), cpu: 20), idleSeconds: 0) }
        XCTAssertEqual(policy.reason, .cpuBudget, "The target itself leaves no measured capacity")
    }

    func testActiveBudgetAndContinuousRecoveryHysteresis() {
        var policy = ResourceProcessingPolicy()
        policy.update(sample(10, cpu: 25), idleSeconds: 0)
        XCTAssertEqual(policy.reason, .cpuBudget)
        for time in 11...25 {
            policy.update(sample(Double(time), cpu: 10), idleSeconds: 0)
            XCTAssertEqual(policy.reason, .cpuBudget)
        }
        policy.update(sample(26, cpu: 10), idleSeconds: 0)
        XCTAssertNil(policy.reason)
    }

    func testMissingSampleBreaksRecoveryAndDoesNotMeanIdle() {
        var policy = ResourceProcessingPolicy()
        policy.update(sample(0, cpu: 25), idleSeconds: 0)
        for time in 1...10 { policy.update(sample(Double(time), cpu: 10), idleSeconds: 0) }
        policy.update(.unavailable, idleSeconds: 0)
        XCTAssertEqual(policy.reason, .measurementsUnavailable)
        for time in 11...25 { policy.update(sample(Double(time), cpu: 10), idleSeconds: 0) }
        XCTAssertEqual(policy.reason, .cpuBudget)
        policy.update(sample(26, cpu: 10), idleSeconds: 0)
        XCTAssertNil(policy.reason)
    }

    func testQuietCatchUpDoesNotUseActiveBudgetButHonoursSystemOverload() {
        var policy = ResourceProcessingPolicy()
        policy.update(sample(0, cpu: 300), idleSeconds: 600)
        XCTAssertNil(policy.reason)
        policy.update(sample(1, cpu: 300, system: 85), idleSeconds: 600)
        XCTAssertEqual(policy.reason, .systemBusy)
        for time in 2...17 { policy.update(sample(Double(time), cpu: 300, system: 50), idleSeconds: 600) }
        XCTAssertNil(policy.reason)
        policy.update(sample(18, cpu: 300), idleSeconds: 0)
        XCTAssertEqual(policy.reason, .cpuBudget)
    }

    func testFreshOCRCanPassQueuedHistoricalWorkDuringInteraction() async throws {
        let governor = BackgroundProcessingGovernor(observeSystem: false)
        await governor.updateEnvironment(.init(idleSeconds: 0, resourceUsage: sample(1, cpu: 10)))
        let historical = Task { try await governor.acquire(.historicalOCR) }
        for _ in 0..<100 {
            if await governor.snapshot().waitingCount == 1 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let optional = try await governor.tryAcquire(.freshOCR)
        let permit = try XCTUnwrap(optional, "A deferred history waiter must not block fresh OCR")
        await governor.updateEnvironment(.init(idleSeconds: 0, resourceUsage: sample(2, cpu: 30)))
        XCTAssertFalse(permit.cancellation.isCancelled, "An admitted bounded fresh job can finish its own CPU burst")
        await governor.release(permit)
        let blocked = try await governor.tryAcquire(.freshOCR)
        XCTAssertNil(blocked)
        historical.cancel()
        do { _ = try await historical.value; XCTFail("History admitted during input") } catch is CancellationError {}
        await governor.close()
    }

    func testFirstPassProgressesAboveAppSoftBudgetButHonoursHostPressure() async throws {
        let governor = BackgroundProcessingGovernor(observeSystem: false)
        await governor.updateEnvironment(.init(idleSeconds: 0, resourceUsage: sample(1, cpu: 40)))
        let optional = try await governor.tryAcquire(.freshTranscription)
        let permit = try XCTUnwrap(optional, "Recording CPU above the soft target cannot suppress all first-pass text")
        await governor.release(permit)
        let refinement = try await governor.tryAcquire(.refinement)
        XCTAssertNil(refinement)
        let ocr = try await governor.tryAcquire(.freshOCR)
        XCTAssertNil(ocr, "Only first-pass audio has the protected admission")
        await governor.updateEnvironment(.init(idleSeconds: 0, resourceUsage: sample(2, cpu: 40, system: 85)))
        let overloaded = try await governor.tryAcquire(.freshTranscription)
        XCTAssertNil(overloaded, "System overload still prevents admission")
        await governor.updateEnvironment(.init(idleSeconds: 0, pressureAllowsProcessing: false))
        let pressure = try await governor.tryAcquire(.freshTranscription)
        XCTAssertNil(pressure)
        await governor.close()
    }

    private func sample(_ time: Double, cpu: Double, system: Double = 50) -> ResourceUsageSnapshot {
        .init(observedAt: Date(), sampleUptime: time, cpuPercent: cpu,
              systemCPUPercent: system, systemFiveSecondCPUPercent: system,
              logicalCoreCount: 10, oneMinute: .init(cpuPercent: cpu, sampledSeconds: 60, elapsedSeconds: 60),
              isCurrent: true)
    }
}
