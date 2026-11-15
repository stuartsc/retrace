import CoreGraphics
import Foundation
import Shared
import XCTest
@testable import Capture

final class CaptureRefusalTrackerTests: XCTestCase {
    private let bundle = "com.apple.finder"

    private func refuse(_ tracker: inout CaptureRefusalTracker, at time: TimeInterval,
                        active: Bool = true) -> CaptureRefusalEvent? {
        tracker.recordRefusal(reason: .windowUnavailable, bundleID: bundle, displayActive: active, now: time)
    }

    func testNoWarningBeforeSixtySeconds() {
        var tracker = CaptureRefusalTracker()
        for time in stride(from: 0.0, to: 60.0, by: 2.0) {
            XCTAssertNil(refuse(&tracker, at: time))
        }
        XCTAssertEqual(tracker.status?.since, 0)
    }

    func testWarnsOnceAtSixtySecondsWithReasonAndBundleOnly() throws {
        var tracker = CaptureRefusalTracker()
        var events: [CaptureRefusalEvent] = []
        for time in stride(from: 0.0, through: 120.0, by: 2.0) {
            if let event = refuse(&tracker, at: time) { events.append(event) }
        }
        XCTAssertEqual(events, [.sustained(duration: 60, reason: .windowUnavailable, bundleID: bundle)])
        let message = try XCTUnwrap(events.first).message
        XCTAssertTrue(message.contains("windowUnavailable"))
        XCTAssertTrue(message.contains(bundle))
        XCTAssertTrue(message.contains("60s"))
    }

    func testQuietWhileDisplayAsleepOrSessionLocked() {
        var tracker = CaptureRefusalTracker()
        for time in stride(from: 0.0, through: 3600.0, by: 2.0) {
            XCTAssertNil(refuse(&tracker, at: time, active: false))
        }
        XCTAssertNil(tracker.status)
        // Waking restarts the streak rather than inheriting the sleeping time.
        XCTAssertNil(refuse(&tracker, at: 3602))
        XCTAssertNil(refuse(&tracker, at: 3640))
        XCTAssertNotNil(refuse(&tracker, at: 3662))
    }

    func testRepeatsNoMoreThanOncePerTenMinutes() {
        var tracker = CaptureRefusalTracker()
        var warningTimes: [TimeInterval] = []
        for time in stride(from: 0.0, through: 1500.0, by: 2.0) {
            if refuse(&tracker, at: time) != nil { warningTimes.append(time) }
        }
        XCTAssertEqual(warningTimes, [60, 660, 1260])
    }

    func testRestoreReportsTotalAndResets() {
        var tracker = CaptureRefusalTracker()
        for time in stride(from: 0.0, through: 100.0, by: 2.0) { _ = refuse(&tracker, at: time) }
        XCTAssertEqual(tracker.recordAccepted(now: 102), .restored(totalDuration: 102))
        XCTAssertNil(tracker.status)
        XCTAssertNil(tracker.recordAccepted(now: 104))
        XCTAssertNil(refuse(&tracker, at: 106))
        XCTAssertEqual(tracker.status?.since, 106)
    }

    func testShortRefusalRestoreIsSilent() {
        var tracker = CaptureRefusalTracker()
        _ = refuse(&tracker, at: 0)
        XCTAssertNil(tracker.recordAccepted(now: 10))
    }

    func testRealSamplerRefusalFeedsTracker() async throws {
        let app = ActivityApplicationSnapshot(bundleID: bundle, name: "Finder fixture", pid: 101, generation: "fixture")
        let source = ActivityContextSource(frontmost: { app }, window: { _, _, _ in nil },
                                           document: { _, _ in nil }, permission: { true })
        let sample = await source.sampleCapture(config: CaptureConfig(), displayID: 42,
                                                readInventory: { _ in "stable" })
        let reason = try XCTUnwrap(sample.failure)
        XCTAssertEqual(reason, .windowUnavailable)
        var tracker = CaptureRefusalTracker()
        _ = tracker.recordRefusal(reason: reason, bundleID: app.bundleID, displayActive: true, now: 0)
        let event = tracker.recordRefusal(reason: reason, bundleID: app.bundleID, displayActive: true, now: 60)
        XCTAssertEqual(event, .sustained(duration: 60, reason: .windowUnavailable, bundleID: bundle))
    }

    func testResetDropsCarriedStreak() {
        var tracker = CaptureRefusalTracker()
        _ = refuse(&tracker, at: 0)
        _ = refuse(&tracker, at: 2)
        tracker.reset()
        XCTAssertNil(tracker.status)
        XCTAssertNil(refuse(&tracker, at: 3600))
        XCTAssertEqual(tracker.status?.since, 3600)
    }

    func testLargeTickGapRestartsStreak() {
        var tracker = CaptureRefusalTracker()
        _ = refuse(&tracker, at: 0)
        _ = refuse(&tracker, at: 2)
        XCTAssertNil(refuse(&tracker, at: 3600))
        XCTAssertEqual(tracker.status?.since, 3600)
        XCTAssertNil(refuse(&tracker, at: 3658))
        XCTAssertNotNil(refuse(&tracker, at: 3660))
    }

    func testNotOnConsoleOrMissingSessionIsQuiet() {
        let active: [String: Any] = [kCGSessionOnConsoleKey as String: true]
        XCTAssertTrue(CaptureDisplayActivity.isActive(displayAsleep: false, session: active))
        XCTAssertFalse(CaptureDisplayActivity.isActive(displayAsleep: false,
            session: [kCGSessionOnConsoleKey as String: false]))
        XCTAssertFalse(CaptureDisplayActivity.isActive(displayAsleep: false, session: [:]))
        XCTAssertFalse(CaptureDisplayActivity.isActive(displayAsleep: false, session: nil))
        XCTAssertFalse(CaptureDisplayActivity.isActive(displayAsleep: false,
            session: [kCGSessionOnConsoleKey as String: true, "CGSSessionScreenIsLocked": true]))
        XCTAssertFalse(CaptureDisplayActivity.isActive(displayAsleep: true, session: active))
    }
}
