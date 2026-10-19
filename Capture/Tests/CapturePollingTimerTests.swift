import AppKit
import CoreFoundation
import XCTest
@testable import Capture

/// Real native run-loop modes; no desktop reads, input events or capture devices.
final class CapturePollingTimerTests: XCTestCase {
    @MainActor
    func testPeriodicCaptureTicksInTheDefaultMode() {
        let ticks = CaptureTimerTicks()
        let timer = CapturePollingTimer.schedule(interval: 0.01) { ticks.record() }
        defer { timer.invalidate() }

        run(mode: .default)

        XCTAssertGreaterThanOrEqual(ticks.count, 2)
        XCTAssertTrue(ticks.allOnMainThread)
    }

    @MainActor
    func testPeriodicCaptureContinuesDuringMenuTracking() {
        _ = NSApplication.shared
        let ticks = CaptureTimerTicks()
        let timer = CapturePollingTimer.schedule(interval: 0.01) { ticks.record() }
        defer { timer.invalidate() }

        run(mode: .eventTracking)

        XCTAssertGreaterThanOrEqual(ticks.count, 2,
            "Recording must not wait for a menu or mouse-tracking session to close")
        XCTAssertTrue(ticks.allOnMainThread)
    }

    @MainActor
    func testInvalidationStopsTicksAcrossRunLoopModes() {
        _ = NSApplication.shared
        let ticks = CaptureTimerTicks()
        let timer = CapturePollingTimer.schedule(interval: 0.01) { ticks.record() }
        defer { timer.invalidate() }
        run(mode: .default)
        XCTAssertGreaterThanOrEqual(ticks.count, 2)

        timer.invalidate()
        let stoppedCount = ticks.count
        run(mode: .eventTracking)
        run(mode: .default)

        XCTAssertEqual(ticks.count, stoppedCount)
        XCTAssertFalse(timer.isValid)
    }

    @MainActor
    private func run(mode: RunLoop.Mode) {
        // Keep the native mode alive even for the failing default-only timer.
        let deadline = Timer(timeInterval: 0.1, repeats: false) { _ in }
        RunLoop.main.add(deadline, forMode: mode)
        defer { deadline.invalidate() }
        CFRunLoopRunInMode(CFRunLoopMode(mode.rawValue as CFString), 0.12, false)
    }
}

private final class CaptureTimerTicks: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var mainThreadOnly = true
    var count: Int { lock.withLock { value } }
    var allOnMainThread: Bool { lock.withLock { mainThreadOnly } }

    func record() {
        lock.withLock {
            value += 1
            mainThreadOnly = mainThreadOnly && Thread.isMainThread
        }
    }
}
