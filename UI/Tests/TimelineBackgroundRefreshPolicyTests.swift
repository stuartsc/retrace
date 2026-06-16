import XCTest
@testable import Retrace

final class TimelineBackgroundRefreshPolicyTests: XCTestCase {
    func testHiddenBackgroundRefreshIsDisabledByDefault() {
        XCTAssertFalse(TimelineWindowController.shouldRunHiddenBackgroundRefresh(
            defaultsValue: nil,
            environmentValue: nil
        ))
    }

    func testHiddenBackgroundRefreshCanBeEnabledForDiagnostics() {
        XCTAssertTrue(TimelineWindowController.shouldRunHiddenBackgroundRefresh(
            defaultsValue: nil,
            environmentValue: "true"
        ))
    }

    func testEnvironmentCanDisableDefaultsValue() {
        XCTAssertFalse(TimelineWindowController.shouldRunHiddenBackgroundRefresh(
            defaultsValue: true,
            environmentValue: "off"
        ))
    }

    func testTimelinePrerenderIsDisabledByDefault() {
        XCTAssertFalse(TimelineWindowController.shouldPrerenderTimeline(
            defaultsValue: nil,
            environmentValue: nil
        ))
    }

    func testTimelinePrerenderCanBeEnabledForDiagnostics() {
        XCTAssertTrue(TimelineWindowController.shouldPrerenderTimeline(
            defaultsValue: nil,
            environmentValue: "on"
        ))
    }
}
