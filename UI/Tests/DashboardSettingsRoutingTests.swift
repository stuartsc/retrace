import AppKit
import SwiftUI
import XCTest
@testable import Retrace

@MainActor
final class DashboardSettingsRoutingTests: XCTestCase {
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
