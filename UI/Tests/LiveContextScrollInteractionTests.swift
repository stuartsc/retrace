import AppKit
import XCTest
@testable import Retrace

@MainActor
final class LiveContextScrollInteractionTests: XCTestCase {
    func testGenericReadingOwnerSurvivesSameWindowReparentAndStopsOnDetach() async throws {
        let fixture = NativeLiveScrollFixture(enablesInitialFollow: true)
        defer { fixture.close() }
        await settleNativeLayout()
        try fixture.sendReadingKey(121)
        XCTAssertFalse(fixture.following)
        let origin = fixture.scroll.contentView.bounds.origin
        let originalWindow = try XCTUnwrap(fixture.observer.window)
        let content = try XCTUnwrap(fixture.panel.contentView)
        let parent = NSView(frame: content.bounds)
        content.addSubview(parent)
        parent.addSubview(fixture.observer)
        XCTAssertTrue(fixture.observer.window === originalWindow)
        await settleNativeLayout()
        XCTAssertEqual(fixture.scroll.contentView.bounds.origin.y, origin.y, accuracy: 0.5,
            "A same-window native reparent must preserve the pinned document")
        let notifications = fixture.readingNotifications
        fixture.following = true
        try fixture.sendReadingKey(121)
        XCTAssertFalse(fixture.following)
        XCTAssertEqual(fixture.readingNotifications, notifications + 1,
            "Reparenting must retain exactly one native input observer")

        fixture.observer.removeFromSuperview()
        XCTAssertNil(fixture.observer.window)
        fixture.following = true
        try fixture.sendReadingKey(121)
        XCTAssertTrue(fixture.following, "A detached owner must no longer process native reading input")
        XCTAssertEqual(fixture.readingNotifications, notifications + 1)
    }

    func testKeyboardLiveScrollStartWithoutEndCannotResumeFollowingOrBlockLaterReading() async throws {
        let fixture = NativeLiveScrollFixture(enablesInitialFollow: true)
        defer { fixture.close() }
        await settleNativeLayout()
        try fixture.sendReadingKey(121)
        let pinned = fixture.scroll.contentView.bounds.origin
        // AppKit can emit start after Page Up without an end. Native input
        // remains authoritative; this notification must not own reading state.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: fixture.scroll)
        fixture.observer.scheduleInitialFollow()
        await settleNativeLayout()
        XCTAssertFalse(fixture.following)
        XCTAssertEqual(fixture.scroll.contentView.bounds.origin.y, pinned.y, accuracy: 0.5)
        let notifications = fixture.readingNotifications
        try fixture.sendReadingKey(121)
        XCTAssertFalse(fixture.following)
        XCTAssertEqual(fixture.readingNotifications, notifications + 1)
    }

    private func settleNativeLayout() async {
        let settled = expectation(description: "Native layout callbacks settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 1)
    }

    func testInactiveMountedObserverIgnoresReadingKeysUntilLiveResumes() throws {
        let fixture = NativeLiveScrollFixture()
        defer { fixture.close() }
        XCTAssertTrue(fixture.panel.makeFirstResponder(fixture.document))
        // NSEvent.keyEvent has an explicit native window contract. Converting a
        // fabricated CGEvent wheel produced windowNumber == 0 on this Mac, so
        // wheel delivery remains the real-input native fixture's responsibility.
        for code: UInt16 in [116, 115, 121, 119, 126, 125] {
            fixture.active = false
            fixture.following = true
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: fixture.panel.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            XCTAssertEqual(key.windowNumber, fixture.panel.windowNumber)
            XCTAssertTrue(fixture.panel.firstResponder === fixture.document,
                "The event must exercise the retained native transcript responder")
            NSApp.sendEvent(key)
            XCTAssertTrue(fixture.following, "Inactive Live must ignore native reading key \(code)")
            fixture.active = true
            NSApp.sendEvent(key)
            XCTAssertFalse(fixture.following,
                "The same window-associated reading key \(code) must pause following after Live resumes")
        }
    }

    func testNativeInitialFollowingResumesAfterInactivityWithoutReattaching() async {
        for initiallyActive in [false, true] {
            let fixture = NativeLiveScrollFixture(initiallyActive: initiallyActive, enablesInitialFollow: true)
            defer { fixture.close() }
            let originalWindow = fixture.observer.window
            XCTAssertNotNil(originalWindow)
            XCTAssertEqual(fixture.document.authoredRowCount, 100)
            XCTAssertGreaterThan(fixture.document.bounds.height, fixture.scroll.contentView.bounds.height)
            fixture.scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
            fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
            let originalOrigin = fixture.scroll.contentView.bounds.origin
            // Cover both inactive attachment and becoming inactive after the
            // first deferred attempt was queued. No native view is recreated.
            fixture.active = false
            let stayedInactive = expectation(description: "Inactive native attachment settles: \(initiallyActive)")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { stayedInactive.fulfill() }
            await fulfillment(of: [stayedInactive], timeout: 1)
            XCTAssertEqual(fixture.scroll.contentView.bounds.origin, originalOrigin,
                "An inactive populated document must not consume its pending initial follow")

            fixture.active = true
            fixture.observer.scheduleInitialFollow() // The production representable's update hook.
            let resumed = expectation(description: "Native initial follow resumes: \(initiallyActive)")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { resumed.fulfill() }
            await fulfillment(of: [resumed], timeout: 1)
            XCTAssertTrue(fixture.observer.window === originalWindow, "Activation must use the same attachment")
            XCTAssertTrue(fixture.following, "Programmatic initial following must not become a reading event")
            XCTAssertLessThan(fixture.scroll.contentView.bounds.origin.y, originalOrigin.y)
            XCTAssertEqual(fixture.scroll.documentVisibleRect.minY, fixture.document.bounds.minY, accuracy: 1,
                "The real native document must reveal its newest row at the top after activation")
        }
    }

    func testNativeReadingKeysPauseFollowingButProgrammaticScrollingAndOtherFieldsDoNot() throws {
        let fixture = NativeLiveScrollFixture()
        defer { fixture.close() }
        for code: UInt16 in [116, 115, 121, 119, 126, 125] {
            fixture.following = true
            XCTAssertTrue(fixture.panel.makeFirstResponder(fixture.document))
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: fixture.panel.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            NSApp.sendEvent(event)
            XCTAssertFalse(fixture.following, "Native reading key \(code) must pin the visible history")
        }
        fixture.following = true
        fixture.document.scroll(NSPoint(x: 0, y: 600))
        fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
        XCTAssertTrue(fixture.following, "Return to live and layout scrolling must not pause themselves")
        XCTAssertTrue(fixture.panel.makeFirstResponder(fixture.field))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: fixture.panel.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 115))
        NSApp.sendEvent(event)
        XCTAssertTrue(fixture.following, "Editing another field must not change transcript following")
    }

    func testNativeScrollbarTrackingPausesBeforeItsPositionChanges() throws {
        let fixture = NativeLiveScrollFixture()
        defer { fixture.close() }
        let scroller = try XCTUnwrap(fixture.scroll.verticalScroller)
        XCTAssertTrue(scroller.isEnabled, "The authored document must have enough rows for native scrolling")
        XCTAssertLessThan(scroller.knobProportion, 1)
        let knob = scroller.rect(for: .knob)
        let rect = try XCTUnwrap(knob.isEmpty ? nil : knob, "A nonoverflowing document has no draggable knob")
        let point = scroller.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let content = try XCTUnwrap(fixture.panel.contentView)
        var hit = content.hitTest(content.convert(point, from: nil))
        while let view = hit, view !== scroller { hit = view.superview }
        XCTAssertTrue(hit === scroller, "The native mouse event must hit the actual scrollbar")
        let originalOrigin = fixture.scroll.contentView.bounds.origin
        let timestamp = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: y), modifierFlags: [],
                timestamp: timestamp, windowNumber: fixture.panel.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        // NSScroller owns a native tracking loop; queue its drag/release first so
        // the test exercises that loop without waiting for physical user input.
        NSApp.postEvent(try event(.leftMouseDragged, y: point.y - 30), atStart: false)
        NSApp.postEvent(try event(.leftMouseUp, y: point.y - 30), atStart: false)
        NSApp.sendEvent(try event(.leftMouseDown, y: point.y))
        XCTAssertNotEqual(fixture.scroll.contentView.bounds.origin, originalOrigin, "The real NSScroller drag must move the document")
        XCTAssertFalse(fixture.following)
    }
}

@MainActor
private final class NativeLiveScrollFixture {
    let panel: NSPanel
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 40, width: 300, height: 200))
    let document = ReadingDocument(frame: NSRect(x: 0, y: 0, width: 280, height: 2_000))
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 25))
    let observer = LiveContextScrollInteractionObserver.ObserverView(frame: NSRect(x: 0, y: 40, width: 300, height: 200))
    var following = true
    var readingNotifications = 0
    var active: Bool
    init(initiallyActive: Bool = true, enablesInitialFollow: Bool = false) {
        active = initiallyActive
        _ = NSApplication.shared
        panel = NSPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 300, height: 240),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.documentView = document
        panel.contentView?.addSubview(scroll)
        panel.contentView?.addSubview(field)
        observer.onScroll = { [weak self] in self?.following = false; self?.readingNotifications += 1 }
        observer.isActive = { [weak self] in self?.active == true }
        if enablesInitialFollow {
            observer.shouldInitiallyFollow = { [weak self] in
                self?.active == true && self?.following == true
            }
        }
        panel.contentView?.addSubview(observer)
        panel.orderFront(nil)
        panel.makeKey()
        panel.contentView?.layoutSubtreeIfNeeded()
    }
    func close() { observer.stop(); panel.orderOut(nil); panel.close() }
    func sendReadingKey(_ code: UInt16) throws {
        panel.makeKey()
        XCTAssertTrue(panel.isKeyWindow)
        XCTAssertTrue(panel.makeFirstResponder(document))
        let deliveries = document.receivedReadingKeys
        let origin = scroll.documentVisibleRect.minY
        let characters = code == 116 ? "\u{F72C}" : "\u{F72D}"
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        NSApp.sendEvent(event)
        XCTAssertEqual(document.receivedReadingKeys, deliveries + 1,
            "The actual generic document must receive the reading key")
        XCTAssertGreaterThan(abs(scroll.documentVisibleRect.minY - origin), 1,
            "Native reading input must move the real document")
    }

    final class ReadingDocument: NSView {
        let authoredRowCount = 100
        private(set) var receivedReadingKeys = 0
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            for index in 0..<authoredRowCount {
                let row = NSView(frame: NSRect(x: 0, y: CGFloat(index) * 20, width: frameRect.width, height: 20))
                let label = NSTextField(labelWithString: "Authored transcript row \(index)")
                label.frame = row.bounds
                row.addSubview(label)
                let marker = LiveContextTranscriptRowIdentity.MarkerView(rowID: "authored-row-\(index)")
                marker.frame = row.bounds
                row.addSubview(marker)
                addSubview(row)
            }
        }
        required init?(coder: NSCoder) { fatalError("Authored fixture is constructed programmatically") }
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            guard let scroll = enclosingScrollView else { return }
            receivedReadingKeys += 1
            let visible = scroll.documentVisibleRect
            let lastOrigin = max(0, bounds.maxY - visible.height)
            let desired: CGFloat
            switch event.keyCode {
            case 115: desired = 0
            case 119: desired = lastOrigin
            case 116: desired = visible.minY - visible.height * 0.75
            case 121: desired = visible.minY + visible.height * 0.75
            case 126: desired = visible.minY - 20
            case 125: desired = visible.minY + 20
            default: super.keyDown(with: event); return
            }
            self.scroll(NSPoint(x: 0, y: max(0, min(lastOrigin, desired))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
