import XCTest
@testable import App

final class RefinementLoopPolicyTests: XCTestCase {
    func testAutomaticRefinementLoopIsDisabledByDefault() {
        XCTAssertFalse(AppCoordinator.shouldStartAutomaticRefinementLoop(
            defaultsValue: nil,
            environmentValue: nil
        ))
    }

    func testAutomaticRefinementLoopCanBeEnabledExplicitlyForManualDiagnostics() {
        XCTAssertTrue(AppCoordinator.shouldStartAutomaticRefinementLoop(
            defaultsValue: nil,
            environmentValue: "true"
        ))
    }
}
