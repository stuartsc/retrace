import AppKit
import ApplicationServices
import Database
import Foundation
import Shared
import XCTest
@testable import Capture

/// External workspace/AX delivery is controlled, while the actual monitor,
/// AsyncStream and canonical SQLite activity writer execute the workflow.
final class ActivityMonitorAttributionTests: XCTestCase {
    private var root: URL!
    private var database: DatabaseManager!
    private var monitor: ActivityMonitor!
    private var source: ControlledActivitySource!
    private var settings: ActivityTestSettings!
    private var observations: ActivityObservationBuffer!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ActivityAttribution-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = DatabaseManager(databasePath: root.appendingPathComponent("fixture.db").path)
        try await database.initialize()
        source = ControlledActivitySource(context: captureTestContext())
        settings = ActivityTestSettings()
        let settings = settings!
        monitor = ActivityMonitor(store: database, configuration: { await settings.config }, source: await source.environment())
        observations = ActivityObservationBuffer(capacity: 8)
        await monitor.start(observations: observations)
    }

    override func tearDown() async throws {
        await source?.releaseWindow()
        await source?.releaseDocument()
        await monitor?.stop()
        try await database?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testDelayedWindowSampleCannotBeBackdatedToNotification() async throws {
        await source.blockWindow()
        let signal = ActivityObservationSignal(kind: .focus, app: await source.app)
        observations.send(signal)
        try await waitUntil { await self.source.windowRequests > 0 }
        let beforeWindow = try await database.searchActivity(ActivityQuery())
        let appOnly = beforeWindow.events.first { $0.event.context?.appBundleID == "com.test.capture" }
        XCTAssertNotNil(appOnly, "The bounded app notification must be durable before AX/window work")
        XCTAssertNil(appOnly?.event.context?.windowID)
        XCTAssertEqual(appOnly?.event.observedAt, signal.wallTime)

        let releasedAt = Date()
        let releasedMonotonic = ProcessInfo.processInfo.systemUptime
        await source.releaseWindow()
        let sampled = try await waitForWindow()
        XCTAssertGreaterThanOrEqual(sampled.event.observedAt, releasedAt)
        XCTAssertGreaterThanOrEqual(sampled.event.monotonicTime, releasedMonotonic)
        XCTAssertTrue(sampled.event.coverage == .uncertain)
    }

    func testCaptureLinkRequiresCurrentDurableGenerationAndMatchingSurface() async throws {
        observations.send(.init(kind: .focus, app: await source.app))
        let event = try await waitForWindow()
        try await waitUntil { await self.monitor.captureIdentity(for: self.metadata(at: Date()), at: Date()) != nil }
        let now = Date()
        let captured = metadata(at: now)
        let capturedIdentity = await monitor.captureIdentity(for: captured, at: now)
        let identity = try XCTUnwrap(capturedIdentity)
        XCTAssertEqual(identity.activityEventID, event.id)
        XCTAssertEqual(identity.sessionID, event.event.sessionID)

        let conflicts = [captureTestContext(window: 8), captureTestContext(generation: nil),
            captureTestContext(generation: "reused"), captureTestContext(document: "other-document"),
            captureTestContext(display: 43), captureTestContext(app: "com.test.other")]
        for context in conflicts {
            let proof = await monitor.captureIdentity(for: metadata(at: now, context: context), at: now)
            XCTAssertNil(proof)
        }
        let beforeObservation = event.event.observedAt.addingTimeInterval(-1)
        let old = metadata(at: beforeObservation, monotonic: event.event.monotonicTime - 1)
        let oldProof = await monitor.captureIdentity(for: old, at: beforeObservation)
        XCTAssertNil(oldProof, "Nearest time must never attach an older frame to a newer activity event")
    }

    func testPendingWindowChangeImmediatelyPreventsLinkingToOldEvent() async throws {
        observations.send(.init(kind: .focus, app: await source.app))
        _ = try await waitForWindow()
        await source.blockWindow()
        let initialReads = await source.windowRequests
        observations.send(.init(kind: .focus, app: await source.app))
        try await waitUntil { await self.source.windowRequests > initialReads }
        let now = Date()
        let proof = await monitor.captureIdentity(for: metadata(at: now), at: now)
        XCTAssertNil(proof, "A queued transition invalidates old context before expensive sampling completes")
        await source.releaseWindow()
    }

    func testConfigurationChangeFencesQueuedContentAndLateEnrichment() async throws {
        await source.blockDocument()
        observations.send(.init(kind: .focus, app: await source.app))
        _ = try await waitForWindow()
        try await waitUntil { await self.source.documentRequests > 0 }
        await settings.exclude("com.test.capture")
        await monitor.configurationChanged()
        await source.releaseDocument()
        observations.send(.init(kind: .reconciliation, app: await source.app))
        try await waitUntil {
            let page = try await self.database.searchActivity(ActivityQuery())
            return page.events.contains { $0.event.kind == .excluded }
        }
        let page = try await database.searchActivity(ActivityQuery())
        let gap = try XCTUnwrap(page.events.first { $0.event.method == "capture-policy-changed" })
        XCTAssertNil(gap.event.context)
        XCTAssertFalse(page.events.contains { $0.commitSequence > gap.commitSequence && $0.event.context != nil })
        XCTAssertFalse(page.events.contains { $0.event.context?.documentID == "late-enrichment" })
        let now = Date()
        let proof = await monitor.captureIdentity(for: metadata(at: now), at: now)
        XCTAssertNil(proof)
    }

    func testPauseDuringWindowSamplingDropsLateContextAndDrainsWorker() async throws {
        await source.blockWindow()
        observations.send(.init(kind: .focus, app: await source.app))
        try await waitUntil { await self.source.windowRequests > 0 }
        let stopped = Task { await monitor.stop() }
        try await waitUntil { !self.observations.permitsContent(generation: 0) }
        await source.releaseWindow()
        await stopped.value
        let page = try await database.searchActivity(ActivityQuery())
        XCTAssertFalse(page.events.contains { $0.event.context?.windowID != nil })
        XCTAssertEqual(page.events.last?.event.kind, .pause)
        let health = await monitor.health()
        XCTAssertFalse(health.collecting)
    }

    func testObserverFailureInvalidatesCaptureLinksAndReportsDegradedHealth() async throws {
        observations.send(.init(kind: .focus, app: await source.app))
        _ = try await waitForWindow()
        observations.send(.init(kind: .observerFailure, app: nil))
        try await waitUntil {
            let events = try await self.database.searchActivity(ActivityQuery()).events
            return events.contains { $0.event.kind == .observerFailure }
        }
        let degraded = await monitor.health()
        XCTAssertTrue(degraded.degraded)
        let now = Date()
        let proof = await monitor.captureIdentity(for: metadata(at: now), at: now)
        XCTAssertNil(proof)

        observations.send(.init(kind: .resume, app: nil, administrativeMethod: "accessibility-observer-restored"))
        observations.send(.init(kind: .reconciliation, app: await source.app))
        try await waitUntil {
            let events = try await self.database.searchActivity(ActivityQuery()).events
            guard let restored = events.last(where: { $0.event.kind == .resume }) else { return false }
            return events.contains { $0.commitSequence > restored.commitSequence && $0.event.context?.windowID != nil }
        }
        let restored = await monitor.health()
        XCTAssertFalse(restored.degraded)
    }

    func testUnprovenPrivateWindowPublishesImmediateContentFreeCoverage() async throws {
        await settings.redactWindowTitles()
        await source.denyWindowSamples()
        observations.send(.init(kind: .focus, app: await source.app))
        try await waitUntil {
            let events = try await self.database.searchActivity(ActivityQuery()).events
            return events.contains { $0.event.kind == .excluded }
        }
        let events = try await database.searchActivity(ActivityQuery()).events
        XCTAssertTrue(events.allSatisfy { $0.event.context == nil })
        XCTAssertEqual(events.last?.event.coverage, .excluded)
    }

    private func waitForWindow() async throws -> PersistedActivityEvent {
        var result: PersistedActivityEvent?
        try await waitUntil {
            let page = try await self.database.searchActivity(ActivityQuery())
            result = page.events.last { $0.event.context?.windowGeneration != nil }
            return result != nil
        }
        return try XCTUnwrap(result)
    }

    private func metadata(at date: Date, context: ActivityContext = captureTestContext(), monotonic: Double? = nil) -> FrameMetadata {
        FrameMetadata(appBundleID: context.appBundleID, appName: context.appName,
            windowName: context.windowTitle, browserURL: context.safeURL, displayID: context.displayID ?? 0,
            captureContext: context, captureMonotonicTime: monotonic ?? ProcessInfo.processInfo.systemUptime)
    }

    private func waitUntil(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while try await !predicate() {
            guard ContinuousClock.now < deadline else { throw ActivityTestFailure.timeout }
            try await Task.sleep(for: .milliseconds(10), clock: .continuous)
        }
    }
}

private enum ActivityTestFailure: Error { case timeout }

private actor ActivityTestSettings {
    private(set) var config = CaptureConfig()
    func exclude(_ bundleID: String) { config = CaptureConfig(excludedAppBundleIDs: [bundleID]) }
    func redactWindowTitles() { config = CaptureConfig(redactWindowTitlePatterns: ["private"]) }
}

private actor ControlledActivitySource {
    let context: ActivityContext
    let app: ActivityApplicationSnapshot
    private var windowBlocked = false
    private var documentBlocked = false
    private var denyWindow = false
    private var windowWaiter: CheckedContinuation<Void, Never>?
    private var documentWaiter: CheckedContinuation<Void, Never>?
    private(set) var windowRequests = 0
    private(set) var documentRequests = 0

    init(context: ActivityContext) {
        self.context = context
        self.app = ActivityApplicationSnapshot(bundleID: context.appBundleID, name: context.appName,
            pid: context.processID, generation: context.processGeneration)
    }
    func blockWindow() { windowBlocked = true }
    func denyWindowSamples() { denyWindow = true }
    func releaseWindow() { windowBlocked = false; windowWaiter?.resume(); windowWaiter = nil }
    func blockDocument() { documentBlocked = true }
    func releaseDocument() { documentBlocked = false; documentWaiter?.resume(); documentWaiter = nil }
    func environment() -> ActivityContextSource {
        ActivityContextSource(frontmost: { await self.app }, window: { _, _, config in
            await self.sampleWindow(config: config)
        }, document: { _, _ in await self.sampleDocument() }, permission: { true })
    }
    private func sampleWindow(config: CaptureConfig) async -> ActivityContext? {
        windowRequests += 1
        if windowBlocked { await withCheckedContinuation { windowWaiter = $0 } }
        return denyWindow || config.excludedAppBundleIDs.contains(context.appBundleID) ? nil : context
    }
    private func sampleDocument() async -> ActivityContext? {
        documentRequests += 1
        guard documentBlocked else { return nil }
        await withCheckedContinuation { documentWaiter = $0 }
        return captureTestContext(document: "late-enrichment")
    }
}

/// Exercise the installed AX callback body with genuine WindowServer identities.
/// Only external app/window/document reads are controlled; visits are queried
/// through the real SQLite activity writer after the observation queue drains.
final class ActivityAXNotificationRegressionTests: XCTestCase {
    private var root: URL!
    private var database: DatabaseManager!
    private var monitor: ActivityMonitor!
    private var observations: ActivityObservationBuffer!
    private var windows: NotificationNativeWindows!
    private var source: NotificationWindowSource!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AXNotification-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for folder in ["A", "B", "C"] {
            let directory = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{\\rtf1\\ansi Reviewed document \(folder)}".utf8)
                .write(to: directory.appendingPathComponent("Same label.rtf"))
        }
        windows = await NotificationNativeWindows(root: root)
        source = await NotificationWindowSource(snapshot: windows.snapshot(0))
        database = DatabaseManager(databasePath: root.appendingPathComponent("fixture.db").path)
        try await database.initialize()
        observations = ActivityObservationBuffer(capacity: 32)
        monitor = ActivityMonitor(store: database, configuration: { CaptureConfig() }, source: await source.environment())
        await monitor.start(observations: observations)
        // Wait for the real startup boundary before deriving window generations.
        try await waitUntil { try await self.database.searchActivity(ActivityQuery()).events.contains { $0.event.kind == .startup } }
    }

    override func tearDown() async throws {
        await source?.releaseDocument()
        await source?.releaseFrontmost()
        await source?.releaseWindow()
        await monitor?.stop()
        await windows?.close()
        try await database?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testRepeatedTitleAndMoveCallbacksKeepOneDurableWindowVisit() async throws {
        let refreshes = NotificationRefreshCounter()
        observations.setObserverRefresh { refreshes.increment() }
        await notify(kAXFocusedWindowChangedNotification)
        let initial = try await waitForDocument("A")
        for notification in [kAXTitleChangedNotification, kAXMovedNotification] {
            for _ in 0..<6 {
                let reads = await source.documentRequests
                await notify(notification)
                try await waitUntil { await self.source.documentRequests > reads }
                _ = try await waitForDocument("A")
            }
        }
        await monitor.stop()
        let events = try await database.searchActivity(ActivityQuery()).events
        let visits = events.filter { $0.event.kind == .focus && $0.event.context?.windowID != nil }
        XCTAssertEqual(visits.count, 1, "Unchanged title/move notifications must not manufacture visits")
        XCTAssertEqual(Set(events.compactMap { $0.event.context?.windowGeneration }).count, 1)
        XCTAssertEqual(events.filter { $0.event.kind == .enrichment }.count, 1)
        XCTAssertEqual(refreshes.count, 1, "Metadata changes do not replace a healthy focused-window observer")
        XCTAssertEqual(visits.first?.event.context?.windowGeneration, initial.event.context?.windowGeneration)
    }

    func testSameTitleDocumentNavigationStillCreatesANewFocus() async throws {
        await notify(kAXFocusedWindowChangedNotification)
        let initial = try await waitForDocument("A")
        await windows.setDocument("B", on: 0)
        await source.select(windows.snapshot(0))
        await notify(kAXTitleChangedNotification)
        let navigated = try await waitForDocument("B")
        XCTAssertEqual(navigated.event.kind, .focus, "A changed AXDocument remains a new visit even with the same title")
        XCTAssertNil(navigated.event.relatedEventID)
        XCTAssertEqual(initial.event.context?.windowTitle, navigated.event.context?.windowTitle)
        XCTAssertEqual(initial.event.context?.windowID, navigated.event.context?.windowID)
        XCTAssertEqual(initial.event.context?.windowGeneration, navigated.event.context?.windowGeneration)
        XCTAssertNotEqual(initial.event.context?.documentID, navigated.event.context?.documentID)
    }

    func testSameTitleTwoWindowRoundTripRetainsDistinctFocusVisits() async throws {
        await notify(kAXFocusedWindowChangedNotification)
        let first = try await waitForDocument("A")
        await source.select(windows.snapshot(1))
        await notify(kAXFocusedWindowChangedNotification)
        let second = try await waitForDocument("B")
        await source.select(windows.snapshot(0))
        await notify(kAXFocusedWindowChangedNotification)
        let returned = try await waitForDocument("A")
        let events = try await database.searchActivity(ActivityQuery()).events
        let visits = events.filter { $0.event.kind == .focus && $0.event.context?.windowID != nil }
        XCTAssertEqual(visits.map { $0.event.context?.windowID },
                       [first.event.context?.windowID, second.event.context?.windowID, returned.event.context?.windowID])
        XCTAssertNotEqual(first.event.context?.windowID, second.event.context?.windowID)
        XCTAssertEqual(first.event.context?.windowID, returned.event.context?.windowID)
        XCTAssertNotEqual(first.event.context?.windowGeneration, returned.event.context?.windowGeneration)
        XCTAssertEqual(first.event.context?.windowTitle, second.event.context?.windowTitle)
    }

    func testMetadataRoundTripInsidePixelReadIsRejectedAfterObservationQueueDrains() async throws {
        await notify(kAXFocusedWindowChangedNotification)
        _ = try await waitForDocument("A")
        let source = source!
        let before = await source.captureSample()
        let pixels = try renderedCaptureFixture()
        let captured = try await CaptureSnapshotSequencer.capture(displayID: 42,
            readContext: { await source.captureSample() }, capturePixels: {
                await self.windows.setDocument("B", on: 0)
                await source.select(self.windows.snapshot(0))
                await self.notify(kAXTitleChangedNotification)
                _ = try await self.waitForDocument("B")
                await self.windows.setDocument("A", on: 0)
                await source.select(self.windows.snapshot(0))
                await self.notify(kAXMovedNotification)
                _ = try await self.waitForDocument("A")
                return pixels
            })
        let after = await source.captureSample()
        XCTAssertEqual(before.context, after.context, "The durable context returns to A without rotating its window generation")
        XCTAssertEqual(before.privacySignature, after.privacySignature)
        XCTAssertNil(captured, "The intervening notification revision must reject pixels even after the queue fully drains")
    }

    func testLateDocumentReadIsRejectedAndLatestSameTitleSignalGetsFreshEnrichment() async throws {
        await notify(kAXFocusedWindowChangedNotification)
        _ = try await waitForDocument("A")
        await source.holdNextDocument()
        await windows.setDocument("B", on: 0)
        await source.select(windows.snapshot(0))
        await notify(kAXTitleChangedNotification)
        try await waitUntil { await self.source.documentIsHeld }
        let reads = await source.windowRequests
        await windows.setDocument("C", on: 0)
        await source.select(windows.snapshot(0))
        await notify(kAXMovedNotification)
        try await waitUntil { await self.source.windowRequests > reads }
        await source.releaseDocument()
        let latest = try await waitForDocument("C")
        let events = try await database.searchActivity(ActivityQuery()).events
        XCTAssertFalse(events.contains { $0.event.context?.documentID == self.documentID("B") })
        XCTAssertEqual(latest.event.kind, .focus)
    }

    func testEnqueuedDocumentReadIsRecheckedAfterNewSameTitleNotification() async throws {
        await notify(kAXFocusedWindowChangedNotification)
        _ = try await waitForDocument("A")
        await source.holdNextDocument()
        await windows.setDocument("B", on: 0)
        await source.select(windows.snapshot(0))
        await notify(kAXTitleChangedNotification)
        try await waitUntil { await self.source.documentIsHeld }
        // Let B enter the production buffer, then suspend its consumption on the
        // external app read. C arrives before that consumed result can be admitted.
        await source.holdNextFrontmost()
        await source.releaseDocument()
        try await waitUntil { await self.source.frontmostIsHeld }
        await windows.setDocument("C", on: 0)
        await source.select(windows.snapshot(0))
        await notify(kAXTitleChangedNotification)
        await source.releaseFrontmost()
        _ = try await waitForDocument("C")
        let events = try await database.searchActivity(ActivityQuery()).events
        XCTAssertFalse(events.contains { $0.event.context?.documentID == self.documentID("B") },
                       "Enqueue-time validation alone cannot admit a result across a later AX signal")
    }

    func testPendingDocumentRetryCannotReplayAnObsoleteAppFocusAfterAnotherAppActivates() async throws {
        await notify(kAXFocusedWindowChangedNotification)
        _ = try await waitForDocument("A")
        await source.holdNextDocument()
        await notify(kAXTitleChangedNotification)
        try await waitUntil { await self.source.documentIsHeld }

        await source.selectApplication("com.test.pending-b", snapshot: windows.snapshot(1))
        await notify(kAXFocusedWindowChangedNotification)
        _ = try await waitForBaseWindow(appBundleID: "com.test.pending-b")

        await windows.setDocument("C", on: 0)
        await source.selectApplication("com.test.current-c", snapshot: windows.snapshot(0))
        await source.holdNextWindow()
        await notify(kAXFocusedWindowChangedNotification)
        try await waitUntil { await self.source.windowIsHeld }
        let beforeRelease = try await database.searchActivity(ActivityQuery()).events
        let activatedC = try XCTUnwrap(beforeRelease.last {
            $0.event.context?.appBundleID == "com.test.current-c" && $0.event.method == "workspace-app-notification"
        })

        // Finish A while C's window read is held, so C's sample cannot replace
        // pending B before the production completion path schedules its retry.
        await source.releaseDocument()
        await monitor.waitForCurrentEnrichmentForTesting()
        await source.releaseWindow()
        _ = try await waitForDocument("C")
        let events = try await database.searchActivity(ActivityQuery()).events
        XCTAssertFalse(events.contains {
            $0.commitSequence > activatedC.commitSequence && $0.event.context?.appBundleID == "com.test.pending-b"
        }, "A fresh retry must sample the current application, not replay an old app notification with a new timestamp")
    }

    func testPendingDocumentRetryDiscoversCurrentAppWithResampleProvenance() async throws {
        await notify(kAXFocusedWindowChangedNotification)
        _ = try await waitForDocument("A")
        await source.holdNextDocument()
        await notify(kAXTitleChangedNotification)
        try await waitUntil { await self.source.documentIsHeld }
        await notify(kAXMovedNotification)
        _ = try await waitForBaseWindow(appBundleID: "com.test.capture")

        // Simulate a missed app activation while the pending resample is held.
        // Its completion must discover the current source, not replay the old app.
        await windows.setDocument("C", on: 0)
        await source.selectApplication("com.test.current-c", snapshot: windows.snapshot(0))
        await source.releaseDocument()
        await monitor.waitForCurrentEnrichmentForTesting()
        _ = try await waitForDocument("C")
        let events = try await database.searchActivity(ActivityQuery()).events
        let resampled = try XCTUnwrap(events.first {
            $0.event.context?.appBundleID == "com.test.current-c" && $0.event.kind == .reconciliation
        })
        XCTAssertEqual(resampled.event.method, "document-enrichment-retry",
                       "An immediate retry must not claim to have come from the two-second timer")
    }

    private func notify(_ notification: String) async {
        ActivityAXNotificationHandler.handle(notification, app: await source.app, buffer: observations)
    }

    private func documentID(_ folder: String) -> String? {
        CapturedURLPolicy.navigationIdentity(root.appendingPathComponent(folder).appendingPathComponent("Same label.rtf").absoluteString)
    }

    private func waitForDocument(_ folder: String) async throws -> PersistedActivityEvent {
        var result: PersistedActivityEvent?
        try await waitUntil {
            let events = try await self.database.searchActivity(ActivityQuery()).events
            guard let event = events.last(where: { $0.event.context?.documentID == self.documentID(folder) }),
                  event.event.context == (await self.source.context(enriched: true)) else { return false }
            let context = event.event.context!
            let metadata = FrameMetadata(appBundleID: context.appBundleID, appName: context.appName,
                windowName: context.windowTitle, browserURL: context.safeURL, displayID: context.displayID ?? 0,
                captureContext: context, captureMonotonicTime: ProcessInfo.processInfo.systemUptime)
            guard await self.monitor.captureIdentity(for: metadata, at: Date()) != nil else { return false }
            result = event
            return true
        }
        return try XCTUnwrap(result)
    }

    private func waitForBaseWindow(appBundleID: String) async throws -> PersistedActivityEvent {
        var result: PersistedActivityEvent?
        try await waitUntil {
            let events = try await self.database.searchActivity(ActivityQuery()).events
            guard let event = events.last(where: { $0.event.context?.appBundleID == appBundleID && $0.event.context?.windowID != nil }),
                  let context = event.event.context else { return false }
            let metadata = FrameMetadata(appBundleID: context.appBundleID, appName: context.appName,
                windowName: context.windowTitle, browserURL: context.safeURL, displayID: context.displayID ?? 0,
                captureContext: context, captureMonotonicTime: ProcessInfo.processInfo.systemUptime)
            guard await self.monitor.captureIdentity(for: metadata, at: Date()) != nil else { return false }
            result = event
            return true
        }
        return try XCTUnwrap(result)
    }

    private func waitUntil(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while try await !predicate() {
            guard ContinuousClock.now < deadline else { throw ActivityTestFailure.timeout }
            try await Task.sleep(for: .milliseconds(10), clock: .continuous)
        }
    }
}

private struct NotificationWindowSnapshot: Sendable {
    let id: UInt32
    let title: String
    let document: URL
    let visibleIDs: Set<UInt32>
}

@MainActor
private final class NotificationNativeWindows {
    private let root: URL
    private let windows: [NSPanel]

    init(root: URL) {
        self.root = root
        _ = NSApplication.shared
        windows = ["A", "B"].map { folder in
            let window = NSPanel(contentRect: CGRect(x: -10_000, y: -10_000, width: 64, height: 48),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "Same document label 📄 '"
            window.representedURL = root.appendingPathComponent(folder).appendingPathComponent("Same label.rtf")
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            return window
        }
    }

    func snapshot(_ index: Int) -> NotificationWindowSnapshot {
        let window = windows[index]
        return .init(id: UInt32(window.windowNumber), title: window.title, document: window.representedURL!,
                     visibleIDs: Set(windows.map { UInt32($0.windowNumber) }))
    }

    func setDocument(_ folder: String, on index: Int) {
        windows[index].representedURL = root.appendingPathComponent(folder).appendingPathComponent("Same label.rtf")
    }

    func close() { windows.forEach { $0.close() } }
}

private actor NotificationWindowSource {
    private(set) var app = ActivityApplicationSnapshot(bundleID: "com.test.capture", name: "Native AX fixture",
        pid: ProcessInfo.processInfo.processIdentifier, generation: "native-ax-fixture-process")
    private var snapshot: NotificationWindowSnapshot
    private var holdDocument = false
    private var holdFrontmost = false
    private var holdWindow = false
    private var documentWaiter: CheckedContinuation<Void, Never>?
    private var frontmostWaiter: CheckedContinuation<Void, Never>?
    private var windowWaiter: CheckedContinuation<Void, Never>?
    private(set) var windowRequests = 0
    private(set) var documentRequests = 0
    var documentIsHeld: Bool { documentWaiter != nil }
    var frontmostIsHeld: Bool { frontmostWaiter != nil }
    var windowIsHeld: Bool { windowWaiter != nil }

    init(snapshot: NotificationWindowSnapshot) { self.snapshot = snapshot }
    func select(_ snapshot: NotificationWindowSnapshot) { self.snapshot = snapshot }
    func selectApplication(_ bundleID: String, snapshot: NotificationWindowSnapshot) {
        app = ActivityApplicationSnapshot(bundleID: bundleID, name: "Native AX fixture",
            pid: ProcessInfo.processInfo.processIdentifier, generation: "native-ax-fixture-\(bundleID)")
        self.snapshot = snapshot
    }
    func holdNextDocument() { holdDocument = true }
    func holdNextFrontmost() { holdFrontmost = true }
    func holdNextWindow() { holdWindow = true }
    func releaseDocument() { holdDocument = false; documentWaiter?.resume(); documentWaiter = nil }
    func releaseFrontmost() { holdFrontmost = false; frontmostWaiter?.resume(); frontmostWaiter = nil }
    func releaseWindow() { holdWindow = false; windowWaiter?.resume(); windowWaiter = nil }

    func environment() -> ActivityContextSource {
        .init(frontmost: { await self.frontmost() }, window: { _, _, _ in await self.window() },
              document: { context, _ in await self.document(context) }, permission: { true })
    }

    func context(enriched: Bool) -> ActivityContext {
        let generation = ObservedWindowGenerations.shared.generation(processID: app.pid, processGeneration: app.generation,
            windowID: snapshot.id, visibleWindowIDs: snapshot.visibleIDs)
        return ActivityContext(appBundleID: app.bundleID, appName: app.name, processID: app.pid,
            processGeneration: app.generation, windowID: snapshot.id, windowGeneration: generation,
            windowTitle: snapshot.title, displayID: 42,
            documentID: enriched ? CapturedURLPolicy.navigationIdentity(snapshot.document.absoluteString) : nil,
            safeURL: enriched ? snapshot.document.absoluteString : nil, adapter: "native-window-fixture")
    }

    func captureSample() -> CapturedWindowSample {
        .init(context: context(enriched: true), privacySignature: "unchanged-native-window-inventory")
    }

    private func frontmost() async -> ActivityApplicationSnapshot {
        if holdFrontmost {
            holdFrontmost = false
            await withCheckedContinuation { frontmostWaiter = $0 }
        }
        return app
    }

    private func window() async -> ActivityContext {
        windowRequests += 1
        if holdWindow {
            holdWindow = false
            await withCheckedContinuation { windowWaiter = $0 }
        }
        return context(enriched: false)
    }

    private func document(_ base: ActivityContext) async -> ActivityContext {
        documentRequests += 1
        let sampled = ActivityContext(appBundleID: base.appBundleID, appName: base.appName, processID: base.processID,
            processGeneration: base.processGeneration, windowID: base.windowID, windowGeneration: base.windowGeneration,
            windowTitle: base.windowTitle, displayID: base.displayID,
            documentID: CapturedURLPolicy.navigationIdentity(snapshot.document.absoluteString),
            safeURL: snapshot.document.absoluteString, adapter: base.adapter)
        if holdDocument {
            holdDocument = false
            await withCheckedContinuation { documentWaiter = $0 }
        }
        return sampled
    }
}

private final class NotificationRefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
