import XCTest
@testable import Processing

final class AudioRefinementSchedulingPolicyTests: XCTestCase {
    func testPass2RefinementYieldsWhenPass1IsActive() {
        let decision = AudioRefinementSchedulingPolicy.decision(
            isPass1Active: true,
            busyWaitDuration: 30
        )

        XCTAssertTrue(decision.shouldYield)
        XCTAssertEqual(decision.delaySeconds, 30)
    }

    func testPass2RefinementProcessesWhenPass1IsIdle() {
        let decision = AudioRefinementSchedulingPolicy.decision(
            isPass1Active: false,
            busyWaitDuration: 30,
            isCancelled: false
        )

        XCTAssertFalse(decision.shouldYield)
        XCTAssertFalse(decision.shouldExit)
        XCTAssertEqual(decision.delaySeconds, 0)
    }

    func testPass2RefinementExitsPromptlyWhenCancelled() {
        let decision = AudioRefinementSchedulingPolicy.decision(
            isPass1Active: true,
            busyWaitDuration: 30,
            isCancelled: true
        )

        XCTAssertFalse(decision.shouldYield)
        XCTAssertTrue(decision.shouldExit)
        XCTAssertEqual(decision.delaySeconds, 0)
    }
}
