import AppKit
import XCTest
@testable import Capture

final class DisplaySwitchMonitorTests: XCTestCase {
    func testOlderDisplayLookupCannotOverwriteNewerReconciliation() async {
        let center = NotificationCenter()
        let initialized = expectation(description: "Initial display committed")
        let held = expectation(description: "Older geometry lookup held")
        let geometry = OrderedDisplayGeometry(held: held)
        let transitions = DisplayTransitionFixture()
        let display = DisplayMonitor(environment: .init(
            frontmostWindowBounds: { await geometry.read() }, displayForBounds: { UInt32($0.minX) },
            mainDisplayID: { 7 }, accessibilityPermission: { false }))
        let monitor = DisplaySwitchMonitor(displayMonitor: display, environment: .init(
            activationObservation: { await DisplayActivationObservation(center: center) },
            makeAXObservation: { _ in nil }, accessibilityPermission: { false }))
        monitor.onDisplaySwitch = { _, new in
            transitions.append(new)
            if transitions.values.count == 1 { initialized.fulfill() }
        }
        await monitor.startMonitoring(initialDisplayID: 6)
        await fulfillment(of: [initialized], timeout: 3)
        await geometry.holdNextRead()
        let older = Task { await monitor.checkForDisplaySwitch() }
        await fulfillment(of: [held], timeout: 3)
        await monitor.checkForDisplaySwitch()
        await geometry.release()
        await older.value
        XCTAssertEqual(transitions.values, [7, 8], "The late display-7 read must not reverse the display-8 switch")
        let current = await monitor.getCurrentDisplayID()
        XCTAssertEqual(current, 8)
        await monitor.stopMonitoring()
    }

    func testActivationDuringInitialReconciliationIsObserved() async throws {
        let center = NotificationCenter()
        let firstSwitch = expectation(description: "Initial reconciliation")
        let secondSwitch = expectation(description: "Activation during reconciliation")
        let gate = DisplaySwitchTestGate()
        let position = DisplaySwitchTestPosition(8)
        let monitor = DisplaySwitchMonitor(displayMonitor: display(position), environment: .init(
            activationObservation: { await DisplayActivationObservation(center: center) },
            makeAXObservation: { _ in nil }, accessibilityPermission: { false }))
        monitor.onDisplaySwitch = { _, new in
            if new == 8 {
                firstSwitch.fulfill()
                await gate.wait()
            } else if new == 9 { secondSwitch.fulfill() }
        }
        await monitor.startMonitoring(initialDisplayID: 7)
        await fulfillment(of: [firstSwitch], timeout: 3)
        await position.set(9)
        // A real Foundation notification arrives while the callback is held.
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await gate.open()
        await fulfillment(of: [secondSwitch], timeout: 3)
        await monitor.stopMonitoring()
        let current = await monitor.getCurrentDisplayID()
        XCTAssertNil(current)
    }

    func testStopOwnsHeldNativeRegistrationAndOldCallbackCannotReachRestart() async throws {
        let center = NotificationCenter()
        let installing = expectation(description: "Native installation entered")
        let installationReturned = expectation(description: "Stale native installation returned")
        let native = await HeldDisplayAXObservation(installing: installing, returned: installationReturned)
        let factory = DisplaySwitchTestFactory(native)
        let monitor = DisplaySwitchMonitor(displayMonitor: display(DisplaySwitchTestPosition(7)), environment: .init(
            activationObservation: { await DisplayActivationObservation(center: center) },
            makeAXObservation: { callback in await factory.make(callback) }, accessibilityPermission: { true }))
        monitor.onWindowChange = { XCTFail("Old native callback cannot reach the restarted owner") }
        await monitor.startMonitoring(initialDisplayID: 7)
        await fulfillment(of: [installing], timeout: 3)
        await monitor.stopMonitoring()
        let closed = await native.closed
        XCTAssertTrue(closed, "Stop must close the owned registration while installation is suspended")
        await monitor.startMonitoring(initialDisplayID: 7)
        await factory.fireOldCallback()
        await native.releaseInstallation()
        await fulfillment(of: [installationReturned], timeout: 3)
        await monitor.stopMonitoring()
        let current = await monitor.getCurrentDisplayID()
        XCTAssertNil(current)
        let installed = await native.installed
        XCTAssertFalse(installed)
    }

    private func display(_ position: DisplaySwitchTestPosition) -> DisplayMonitor {
        DisplayMonitor(environment: .init(frontmostWindowBounds: {
            CGRect(x: Double(await position.value), y: 0, width: 10, height: 10)
        }, displayForBounds: { UInt32($0.minX) }, mainDisplayID: { 7 }, accessibilityPermission: { true }))
    }
}

private final class DisplayTransitionFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var displays: [UInt32] = []
    var values: [UInt32] { lock.withLock { displays } }
    func append(_ value: UInt32) { lock.withLock { displays.append(value) } }
}

private actor OrderedDisplayGeometry {
    private let held: XCTestExpectation
    private var shouldHold = false
    private var newer = false
    private var continuation: CheckedContinuation<CGRect, Never>?
    init(held: XCTestExpectation) { self.held = held }
    func holdNextRead() { shouldHold = true }
    func read() async -> CGRect {
        if shouldHold {
            shouldHold = false
            newer = true
            return await withCheckedContinuation { continuation = $0; held.fulfill() }
        }
        return CGRect(x: newer ? 8 : 7, y: 0, width: 10, height: 10)
    }
    func release() { continuation?.resume(returning: CGRect(x: 7, y: 0, width: 10, height: 10)); continuation = nil }
}

private actor DisplaySwitchTestPosition {
    private(set) var value: UInt32
    init(_ value: UInt32) { self.value = value }
    func set(_ value: UInt32) { self.value = value }
}

private actor DisplaySwitchTestGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@MainActor
private final class HeldDisplayAXObservation: DisplayAXObserving {
    private let installing: XCTestExpectation
    private let returned: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var closed = false
    private(set) var installed = false
    init(installing: XCTestExpectation, returned: XCTestExpectation) {
        self.installing = installing; self.returned = returned
    }
    func install() async -> Bool {
        installing.fulfill()
        await withCheckedContinuation { continuation = $0 }
        installed = !closed
        returned.fulfill()
        return installed
    }
    func close() { closed = true; installed = false }
    func releaseInstallation() { continuation?.resume(); continuation = nil }
}

private actor DisplaySwitchTestFactory {
    private let native: HeldDisplayAXObservation
    private var callback: (@Sendable () -> Void)?
    init(_ native: HeldDisplayAXObservation) { self.native = native }
    func make(_ callback: @escaping @Sendable () -> Void) -> (any DisplayAXObserving)? {
        guard self.callback == nil else { return nil }
        self.callback = callback
        return native
    }
    func fireOldCallback() { callback?() }
}
