import AppKit
import ApplicationServices
import CoreGraphics
import XCTest
@testable import Capture

@MainActor
final class ObservedWindowGenerationTests: XCTestCase {
    func testWindowServerIdentityGetsANewGenerationAfterObservedDisappearance() throws {
        let window = makeWindow()
        defer { window.close() }
        let id = UInt32(window.windowNumber)
        // AppKit allocates the genuine WindowServer ID even when an offscreen
        // test window is omitted from the composited on-screen window list.
        XCTAssertGreaterThan(id, 0)
        let pid = ProcessInfo.processInfo.processIdentifier
        let registry = ObservedWindowGenerations()
        let first = registry.generation(processID: pid, processGeneration: "actual-window-test-session", windowID: id, visibleWindowIDs: [id])
        let repeated = registry.generation(processID: pid, processGeneration: "actual-window-test-session", windowID: id, visibleWindowIDs: [id])
        XCTAssertNotNil(first)
        XCTAssertEqual(first, repeated)
        _ = registry.generation(processID: pid, processGeneration: "actual-window-test-session", windowID: id, visibleWindowIDs: [])
        let reused = registry.generation(processID: pid, processGeneration: "actual-window-test-session", windowID: id, visibleWindowIDs: [id])
        XCTAssertNotEqual(first, reused, "A disappeared/reused WindowServer ID must not inherit old activity identity")
    }

    func testProcessAndObservationSessionChangesFencePreviouslyObservedWindow() throws {
        let window = makeWindow()
        defer { window.close() }
        let id = UInt32(window.windowNumber)
        let pid = ProcessInfo.processInfo.processIdentifier
        let registry = ObservedWindowGenerations()
        let first = registry.generation(processID: pid, processGeneration: "first-process", windowID: id, visibleWindowIDs: [id])
        let restarted = registry.generation(processID: pid, processGeneration: "second-process", windowID: id, visibleWindowIDs: [id])
        XCTAssertNotEqual(first, restarted)
        registry.reset()
        let resumed = registry.generation(processID: pid, processGeneration: "second-process", windowID: id, visibleWindowIDs: [id])
        XCTAssertNotEqual(restarted, resumed)
    }

    func testAXMetadataNoisePreservesNativeWindowLifetimeButFocusAndDestructionInvalidateIt() throws {
        let window = makeWindow()
        defer { window.close() }
        let id = UInt32(window.windowNumber)
        let pid = ProcessInfo.processInfo.processIdentifier
        let registry = ObservedWindowGenerations()
        let buffer = ActivityObservationBuffer(capacity: 2)
        defer { buffer.finish() }
        let generation = {
            registry.generation(processID: pid, processGeneration: "native-metadata-noise-session",
                                windowID: id, visibleWindowIDs: [id])
        }
        let first = generation()
        for index in 0..<10_001 {
            ActivityAXNotificationHandler.handle(index.isMultiple(of: 2) ? kAXTitleChangedNotification : kAXMovedNotification,
                                                 app: nil, buffer: buffer, registry: registry)
        }
        XCTAssertEqual(first, generation(), "A burst of metadata notifications must retain the actual window's lifetime")
        XCTAssertEqual(buffer.takeDroppedCount(), 9_999, "The callback retains bounded observation delivery")
        ActivityAXNotificationHandler.handle(kAXFocusedWindowChangedNotification, app: nil, buffer: buffer, registry: registry)
        let focused = generation()
        XCTAssertNotEqual(first, focused)
        ActivityAXNotificationHandler.handle(kAXUIElementDestroyedNotification, app: nil, buffer: buffer, registry: registry)
        XCTAssertNotEqual(focused, generation())
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 64, height: 48),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Retrace generated window fixture"
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }
}
