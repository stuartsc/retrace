import XCTest
@testable import Capture

final class WindowChangeCapturePolicyTests: XCTestCase {
    func testAllowsFirstWindowChangeCapture() {
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(WindowChangeCapturePolicy.shouldCaptureWindowChange(lastCaptureAt: nil, now: now))
    }

    func testSuppressesRapidWindowChangeCaptureBursts() {
        let first = Date(timeIntervalSince1970: 100)
        let burst = first.addingTimeInterval(0.45)

        XCTAssertFalse(WindowChangeCapturePolicy.shouldCaptureWindowChange(lastCaptureAt: first, now: burst))
    }

    func testAllowsWindowChangeCaptureAfterCooldown() {
        let first = Date(timeIntervalSince1970: 100)
        let settled = first.addingTimeInterval(WindowChangeCapturePolicy.minimumIntervalSeconds + 0.01)

        XCTAssertTrue(WindowChangeCapturePolicy.shouldCaptureWindowChange(lastCaptureAt: first, now: settled))
    }
}
