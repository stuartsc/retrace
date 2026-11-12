import AppKit
import SwiftUI
import XCTest
@testable import Retrace

@MainActor
final class DashboardSettingsRoutingTests: XCTestCase {
    func testVoiceMarkerSettingsRoundTripRetainsNativeListAndPinnedViewportAtBothWidths() async throws {
        for width: CGFloat in [1_280, 820] {
            _ = NSApplication.shared
            let navigation = DashboardNavigationState()
            let panel = NSPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 500),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let content = DashboardDestinationView(navigation: navigation,
                dashboard: { NativePinnedDestinationList() },
                settings: { destination in NativeSettingsRouteReceipt(text: "settings:\(destination.scrollTargetID ?? "none")") },
                changelog: { Text("Changelog") }, monitor: { Text("Monitor") })
            let hosting = NSHostingView(rootView: content.frame(width: width, height: 500))
            panel.contentView = hosting
            panel.orderFront(nil)
            defer { panel.orderOut(nil); panel.contentView = nil; panel.close() }
            func tables(_ view: NSView) -> [NSTableView] {
                (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
            }
            let deadline = ContinuousClock.now + .seconds(2)
            while tables(hosting).isEmpty, ContinuousClock.now < deadline {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            let original = try XCTUnwrap(tables(hosting).first)
            let scroll = try XCTUnwrap(original.enclosingScrollView)
            original.scrollRowToVisible(50)
            hosting.layoutSubtreeIfNeeded()
            let pinnedOrigin = scroll.contentView.bounds.origin
            XCTAssertGreaterThan(pinnedOrigin.y, 0)
            navigation.openSettings(tab: .audio, scrollTargetID: SettingsView.voiceMarkersTargetID)
            try await Task.sleep(for: .milliseconds(40))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertTrue(tables(hosting).contains { $0 === original }, "Settings must retain the mounted transcript list at width \(width)")
            _ = navigation.receive(Notification(name: .toggleSettings))
            try await Task.sleep(for: .milliseconds(40))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertTrue(tables(hosting).first === original, "Back must reuse the actual native table")
            XCTAssertEqual(scroll.contentView.bounds.origin.y, pinnedOrigin.y, accuracy: 0.5)
            XCTAssertEqual(original.numberOfRows, 100)
        }
    }

    func testSettingsNotificationBeforeFirstWindowSurvivesLazyHosting() async {
        let fixture = SettingsRoutingWindowFixture()
        defer { fixture.close() }

        fixture.center.post(name: .openSettings, object: nil)
        XCTAssertNotNil(fixture.controller.window, "The controller must receive Settings before any view subscribes")
        // Mount only after the request. This reproduces the first-open ordering
        // without depending on how quickly SwiftUI happens to subscribe.
        fixture.controller.show()
        fixture.mountContent()
        await assertRendered("settings:default:none", in: fixture)
    }

    func testDirectSettingsRequestPrecedesFirstHostedContent() async {
        let fixture = SettingsRoutingWindowFixture()
        defer { fixture.close() }

        fixture.controller.showSettings()
        fixture.mountContent()
        await assertRendered("settings:default:none", in: fixture)
        XCTAssertEqual(fixture.windowCreationCount, 1)
        XCTAssertFalse(fixture.panel?.isKeyWindow ?? true)
    }

    func testVoiceMarkerActionOpensExistingAudioEditorBeforeAndAfterMounting() async {
        let fixture = SettingsRoutingWindowFixture()
        defer { fixture.close() }
        fixture.controller.showVoiceMarkerSettings()
        fixture.mountContent()
        await assertRendered("settings:Audio:settings.voiceMarkers", in: fixture)
        let host = fixture.hostingController?.view
        fixture.controller.showSettings()
        fixture.controller.showVoiceMarkerSettings()
        await assertRendered("settings:Audio:settings.voiceMarkers", in: fixture)
        XCTAssertTrue(fixture.hostingController?.view === host)
        XCTAssertEqual(fixture.windowCreationCount, 1)
    }

    func testRealSettingsMenuActionOpensAndRepeatedActionsStayInSettings() async {
        let fixture = SettingsRoutingWindowFixture()
        defer { fixture.close() }
        let menu = NSMenu(title: "Fixture commands")
        let item = MenuBarManager.makeSettingsMenuItem(target: fixture.controller,
                                                       action: #selector(DashboardWindowController.showSettings))
        menu.addItem(item)
        XCTAssertEqual(item.keyEquivalent, ",")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)

        menu.performActionForItem(at: 0)
        fixture.mountContent()
        await assertRendered("settings:default:none", in: fixture)
        let hostedView = fixture.hostingController?.view
        menu.performActionForItem(at: 0)
        menu.performActionForItem(at: 0)
        await assertRendered("settings:default:none", in: fixture)
        XCTAssertTrue(fixture.hostingController?.view === hostedView)
        XCTAssertEqual(fixture.windowCreationCount, 1)
    }

    func testSpecificSettingsNotificationsKeepTheirDestinationBeforeMounting() async {
        for route in Self.specificRoutes {
            let fixture = SettingsRoutingWindowFixture()
            fixture.center.post(name: route.name, object: nil)
            fixture.controller.show()
            fixture.mountContent()
            await assertRendered(route.receipt, in: fixture)
            fixture.close()
        }
    }

    func testMountedSettingsReceivesNewAnchorsWithoutReplacingTheHost() async {
        let fixture = SettingsRoutingWindowFixture()
        defer { fixture.close() }
        fixture.controller.show()
        fixture.mountContent()
        await assertRendered("dashboard", in: fixture)
        let hostedView = fixture.hostingController?.view

        for route in Self.specificRoutes {
            fixture.center.post(name: route.name, object: nil)
            await assertRendered(route.receipt, in: fixture)
            XCTAssertTrue(fixture.hostingController?.view === hostedView)
        }
        XCTAssertEqual(fixture.windowCreationCount, 1)
    }

    func testSettingsRequestAfterHideReusesWindowAndKeepsTheRequestedAnchor() async {
        let fixture = SettingsRoutingWindowFixture()
        defer { fixture.close() }
        fixture.controller.show()
        fixture.mountContent()
        await assertRendered("dashboard", in: fixture)
        fixture.controller.hide()
        XCTAssertFalse(fixture.panel?.isVisible ?? true)

        fixture.center.post(name: .openSettingsPauseReminderInterval, object: nil)
        await assertRendered("settings:Capture:settings.pauseReminderInterval", in: fixture)
        XCTAssertTrue(fixture.panel?.isVisible ?? false)
        XCTAssertEqual(fixture.windowCreationCount, 1)
    }

    func testSettingsOpenPublishesCompatibilityNotificationExactlyOnce() async {
        let fixture = SettingsRoutingWindowFixture()
        defer { fixture.close() }
        let received = SettingsNotificationReceipt()
        let observer = fixture.center.addObserver(forName: .openSettings, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { received.count += 1 }
        }
        defer { fixture.center.removeObserver(observer) }

        fixture.controller.showSettings()
        fixture.mountContent()
        await assertRendered("settings:default:none", in: fixture)
        XCTAssertEqual(received.count, 1, "Timeline's existing Settings observer must still receive one request")
    }

    private static let specificRoutes: [(name: Notification.Name, receipt: String)] = [
        (.openSettingsAppearance, "settings:General:none"),
        (.openSettingsPower, "settings:Power:none"),
        (.openSettingsTags, "settings:Tags:none"),
        (.openSettingsPauseReminderInterval, "settings:Capture:settings.pauseReminderInterval"),
        (.openSettingsPowerOCRCard, "settings:Power:settings.powerOCRCard"),
        (.openSettingsPowerOCRPriority, "settings:Power:settings.powerOCRPriority"),
        (.openSettingsTimelineScrollOrientation, "settings:General:settings.timelineScrollOrientation")
    ]

    private func assertRendered(_ expected: String, in fixture: SettingsRoutingWindowFixture,
                                file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !fixture.renderedLabels.contains(expected), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20), clock: .continuous)
            fixture.hostingController?.view.layoutSubtreeIfNeeded()
        }
        XCTAssertTrue(fixture.renderedLabels.contains(expected),
                      "Expected native hosted destination \(expected); rendered \(fixture.renderedLabels)",
                      file: file, line: line)
    }
}

@MainActor
private final class SettingsNotificationReceipt { var count = 0 }

/// Owns a real native window and the production destination switch, with inert
/// destination bodies so no Settings preferences or application services start.
@MainActor
private final class SettingsRoutingWindowFixture {
    let center = NotificationCenter()
    private(set) var panel: NSPanel?
    private(set) var hostingController: NSHostingController<AnyView>?
    private(set) var windowCreationCount = 0
    lazy var controller = DashboardWindowController(
        notificationCenter: center,
        windowFactory: { [unowned self] _ in makeWindow() },
        presentWindow: { $0.orderFront(nil) },
        hideApplication: {}
    )

    init() {
        _ = NSApplication.shared
        // Match app startup: the controller is configured before a request,
        // while its native window and SwiftUI subscriptions remain absent.
        _ = controller
    }

    func mountContent() {
        guard let panel, hostingController == nil else { return }
        let content = DashboardDestinationView(
            navigation: controller.navigation,
            dashboard: { NativeSettingsRouteReceipt(text: "dashboard") },
            settings: { destination in
                NativeSettingsRouteReceipt(text: "settings:\(destination.tab?.rawValue ?? "default"):\(destination.scrollTargetID ?? "none")")
            },
            changelog: { NativeSettingsRouteReceipt(text: "changelog") },
            monitor: { NativeSettingsRouteReceipt(text: "monitor") }
        )
        let hosting = NSHostingController(rootView: AnyView(content))
        hostingController = hosting
        panel.contentViewController = hosting
        panel.setFrame(NSRect(x: -20_000, y: -20_000, width: 200, height: 80), display: false)
        hosting.view.layoutSubtreeIfNeeded()
    }

    var renderedLabels: [String] {
        guard let view = hostingController?.view else { return [] }
        func labels(in view: NSView) -> [String] {
            let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
            return own + view.subviews.flatMap { labels(in: $0) }
        }
        return labels(in: view)
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 200, height: 80),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.ignoresCycle]
        self.panel = panel
        windowCreationCount += 1
        return panel
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        hostingController = nil
        panel?.close()
        panel = nil
    }
}

private struct NativeSettingsRouteReceipt: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSTextField { NSTextField(labelWithString: text) }
    func updateNSView(_ view: NSTextField, context: Context) { view.stringValue = text }
}

private struct NativePinnedDestinationList: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("retained-reading-history")))
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = context.coordinator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        table.reloadData()
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {}
    final class Coordinator: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 100 }
        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
            "Authored pinned transcript \(row)"
        }
    }
}
