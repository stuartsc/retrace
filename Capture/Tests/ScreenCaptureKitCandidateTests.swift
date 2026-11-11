import CoreGraphics
import AppKit
import ApplicationServices
import Foundation
import Shared
import XCTest
@testable import Capture

/// The native WindowServer boundary is controlled; the production sequencer,
/// lifecycle, bounded AsyncStreams and CoreGraphics pixels remain real.
final class ScreenCaptureKitCandidateTests: XCTestCase {
    func testPersistentEnvironmentStartsExplicitlyAndJoinsStopOnConfigurationChange() async throws {
        let events = CandidatePersistentEvents()
        let fixture = CandidateFixture(pixels: try renderedCaptureFixture())
        let base = fixture.environment()
        let environment = ScreenCaptureEnvironment(displays: base.displays, context: base.context,
            attributedPixels: { display, config, context, outcome, attempt in
                await events.add("pixels:\(display.displayID)")
                return try await base.attributedPixels(display, config, context, outcome, attempt)
            }, beginSession: { await events.add("begin") }, endSession: { await events.add("end") },
            retainDisplays: { displays in await events.add("retain:\(displays.map(\.displayID))") })
        let source = ScreenCaptureKitCapture(environment: environment, automaticallyPoll: false)
        let before = await events.values
        XCTAssertTrue(before.isEmpty, "Constructing the source must not acquire native streams")
        let pair = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingOldest(8))
        try await source.startCapture(config: candidateConfig(), frameContinuation: pair.continuation, displayID: 42)
        await source.captureImmediateAndResetTimer()
        try await source.updateConfig(candidateConfig(displayPolicy: .activeDisplay))
        await source.captureImmediateAndResetTimer()
        try await source.stopCapture()
        pair.continuation.finish()
        let values = await events.values
        XCTAssertEqual(values, ["begin", "retain:[42, 43]", "pixels:42", "pixels:43", "end", "begin", "retain:[42]", "pixels:42", "end"])
    }

    func testMissingDisplayInventoryInvalidatesPersistentNativeStreams() async throws {
        let events = CandidatePersistentEvents()
        let fixture = CandidateFixture(pixels: try renderedCaptureFixture())
        let base = fixture.environment()
        let environment = ScreenCaptureEnvironment(displays: { [] }, context: base.context,
            attributedPixels: base.attributedPixels,
            beginSession: { await events.add("begin") }, endSession: { await events.add("end") },
            retainDisplays: { _ in await events.add("retain") })
        let source = ScreenCaptureKitCapture(environment: environment, automaticallyPoll: false)
        let pair = AsyncStream<CapturedFrame>.makeStream()
        do {
            try await source.startCapture(config: candidateConfig(), frameContinuation: pair.continuation, displayID: 42)
            XCTFail("Empty inventory must not start capture")
        } catch {}
        try await source.stopCapture()
        pair.continuation.finish()
        let values = await events.values
        XCTAssertFalse(values.contains("begin"))
        XCTAssertFalse(values.contains("retain"))
    }
    func testOldSavedConfigurationKeepsLegacyBackendAndCandidateDefaultsToAllDisplays() throws {
        let original = CaptureConfig(captureIntervalSeconds: 3, excludedAppBundleIDs: ["com.test.secret"],
                                     redactWindowTitlePatterns: ["Private proposal"])
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "backend")
        object.removeValue(forKey: "displayPolicy")
        let restored = try JSONDecoder().decode(CaptureConfig.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.backend, .legacy)
        XCTAssertEqual(restored.displayPolicy, .allDisplays)
        XCTAssertEqual(restored.captureIntervalSeconds, 3)
        XCTAssertEqual(restored.excludedAppBundleIDs, ["com.test.secret"])
        XCTAssertEqual(restored.redactWindowTitlePatterns, ["Private proposal"])
        let candidate = CaptureConfig(backend: .screenCaptureKitCandidate, displayPolicy: .activeDisplay)
        let roundTrip = try JSONDecoder().decode(CaptureConfig.self, from: JSONEncoder().encode(candidate))
        XCTAssertEqual(roundTrip.backend, .screenCaptureKitCandidate)
        XCTAssertEqual(roundTrip.displayPolicy, .activeDisplay)
    }

    func testSamePixelsFromTwoDisplaysAreIndependentlyRetainedAndDeduplicated() async throws {
        let manager = CaptureManager()
        let retained = expectation(description: "one frame retained for each display")
        retained.expectedFulfillmentCount = 2
        let session = await manager.startFrameProcessing { frame in retained.fulfill(); return frame }
        session.input.yield(try renderedCaptureFixture(metadata: FrameMetadata(displayID: 42)))
        session.input.yield(try renderedCaptureFixture(metadata: FrameMetadata(displayID: 43)))
        // Join the actual consumer between batches so this tests deduplication,
        // independently of the intentionally bounded producer queue.
        await fulfillment(of: [retained], timeout: 2)
        session.input.yield(try renderedCaptureFixture(metadata: FrameMetadata(displayID: 42)))
        session.input.yield(try renderedCaptureFixture(metadata: FrameMetadata(displayID: 43)))
        session.input.finish()
        let frames = await collect(session.output)
        XCTAssertEqual(frames.map(\.metadata.displayID), [42, 43],
                       "Each display must compare against its own previous retained pixels")
        let stats = await manager.getStatistics()
        XCTAssertEqual(stats.totalFramesCaptured, 4)
        XCTAssertEqual(stats.framesDeduped, 2)
        await manager.stopFrameProcessing()
    }

    func testEveryDisplayRetainsItsCapturePolicyAcrossAConfigurationChange() async throws {
        let fixture = CandidateFixture(pixels: try renderedCaptureFixture())
        let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false)
        let pair = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingOldest(4))
        let original = candidateConfig()
        let changed = CaptureConfig(excludedAppBundleIDs: ["com.test.background"], backend: .screenCaptureKitCandidate)
        try await source.startCapture(config: original, frameContinuation: pair.continuation, displayID: 42)
        await source.captureImmediateAndResetTimer()
        try await source.updateConfig(changed)
        await source.captureImmediateAndResetTimer()
        try await source.stopCapture()
        pair.continuation.finish()
        let frames = await collect(pair.stream)
        let firstPolicy = ScreenEvidenceAccessPolicy(config: original)
        let laterPolicy = ScreenEvidenceAccessPolicy(config: changed)
        let firstFingerprint = try firstPolicy.fingerprintSHA256()
        let laterFingerprint = try laterPolicy.fingerprintSHA256()
        XCTAssertEqual(frames.map(\.metadata.displayID), [42, 43, 42, 43])
        XCTAssertEqual(frames.map(\.metadata.capturePolicySHA256),
                       [firstFingerprint, firstFingerprint, laterFingerprint, laterFingerprint])
        let displayOnly = try XCTUnwrap(frames.dropFirst().first)
        XCTAssertNil(displayOnly.metadata.appBundleID)
        XCTAssertTrue(firstPolicy.permits(displayOnly.metadata))
        XCTAssertFalse(laterPolicy.permits(displayOnly.metadata),
                       "Unknown foreground identity must not bypass a later background-app exclusion")
    }

    func testAllDisplaysUseTheSequencerAndUnknownWindowStaysUnknown() async throws {
        let fixture = CandidateFixture(pixels: try renderedCaptureFixture())
        let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false)
        let pair = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingOldest(4))
        try await source.startCapture(config: candidateConfig(), frameContinuation: pair.continuation, displayID: 42)
        await source.captureImmediateAndResetTimer()
        try await source.stopCapture()
        pair.continuation.finish()
        let frames = await collect(pair.stream)
        XCTAssertEqual(frames.map(\.metadata.displayID), [42, 43])
        XCTAssertEqual(frames.first?.metadata.captureContext, captureTestContext())
        XCTAssertNil(frames.last?.metadata.captureContext)
        XCTAssertNil(frames.last?.metadata.appBundleID)
        XCTAssertNil(frames.last?.metadata.windowName)
        XCTAssertEqual(frames.first?.imageData, frames.last?.imageData)
        XCTAssertTrue(frames.allSatisfy { $0.metadata.captureMonotonicTime != nil })
        let reads = await fixture.contextReads
        XCTAssertEqual(reads, [42: 2, 43: 2], "Native context must bracket every individual pixel read")
    }

    func testStorageRejectionInvalidatesOnlyItsDisplayAndRetriesIdenticalPixels() async throws {
        let manager = CaptureManager()
        let retained = expectation(description: "initial displays delivered")
        retained.expectedFulfillmentCount = 2
        let state = CandidateRetentionCounter()
        let session = await manager.startFrameProcessing { frame in
            if await state.increment() <= 2 { retained.fulfill() }
            return frame
        }
        session.input.yield(try renderedCaptureFixture(metadata: FrameMetadata(displayID: 42)))
        session.input.yield(try renderedCaptureFixture(metadata: FrameMetadata(displayID: 43)))
        await fulfillment(of: [retained], timeout: 2)
        var iterator = session.output.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        await manager.invalidateDeduplication(displayID: 42)
        session.input.yield(try renderedCaptureFixture(metadata: FrameMetadata(displayID: 42)))
        session.input.yield(try renderedCaptureFixture(metadata: FrameMetadata(displayID: 43)))
        session.input.finish()
        var retried: [CapturedFrame] = []
        while let frame = await iterator.next() { retried.append(frame) }
        XCTAssertEqual(retried.map(\.metadata.displayID), [42])
        await manager.stopFrameProcessing()
    }

    func testActiveDisplayComparisonPolicyOnlyCapturesSelectedDisplay() async throws {
        let fixture = CandidateFixture(pixels: try renderedCaptureFixture())
        let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false)
        let pair = AsyncStream<CapturedFrame>.makeStream()
        try await source.startCapture(config: candidateConfig(displayPolicy: .activeDisplay),
                                      frameContinuation: pair.continuation, displayID: 43)
        await source.captureImmediateAndResetTimer()
        try await source.stopCapture()
        pair.continuation.finish()
        let frames = await collect(pair.stream)
        XCTAssertEqual(frames.map(\.metadata.displayID), [43])
    }

    func testRuntimeDisplayPolicyRebindsToCurrentFocusRatherThanOriginalDisplay() async throws {
        let activeDisplay = CandidateActiveDisplay()
        let source = CandidateSourceReceipt()
        let manager = CaptureManager(config: candidateConfig(), metadataProvider: CandidateMetadataProvider(),
            source: source, lifecycleEnvironment: CaptureLifecycleEnvironment(hasPermission: { true },
                activeDisplayID: { await activeDisplay.value }, startDisplayMonitoring: { _ in }, stopDisplayMonitoring: {}))
        try await manager.startCapture(config: candidateConfig())
        await activeDisplay.set(43)
        try await manager.updateConfig(candidateConfig(displayPolicy: .activeDisplay))
        let receipts = await source.startedDisplays
        XCTAssertEqual(receipts, [42, 43])
        try await manager.stopCapture()
    }

    func testNativeSourceWaitsForCaptureObservationStartup() async throws {
        let entered = expectation(description: "capture observation startup entered")
        let gate = CandidateGate()
        let source = CandidateSourceReceipt()
        let manager = CaptureManager(config: candidateConfig(), metadataProvider: CandidateMetadataProvider(),
            source: source, lifecycleEnvironment: CaptureLifecycleEnvironment(hasPermission: { true },
                activeDisplayID: { 42 }, startDisplayMonitoring: { _ in entered.fulfill(); await gate.wait() },
                stopDisplayMonitoring: {}))
        let start = Task { try await manager.startCapture(config: candidateConfig()) }
        await fulfillment(of: [entered], timeout: 2)
        let pendingStarts = await source.startedDisplays
        XCTAssertTrue(pendingStarts.isEmpty, "Native pixels cannot start before capture-owned notifications are installed")
        await gate.release()
        try await start.value
        let starts = await source.startedDisplays
        XCTAssertEqual(starts, [42])
        try await manager.stopCapture()
    }

    func testFullOutputBufferReportsGapAndRetriesDroppedDisplay() async throws {
        let manager = CaptureManager()
        let firstTwo = expectation(description: "first two displays entered forwarding")
        firstTwo.expectedFulfillmentCount = 2
        let dropped = expectation(description: "third display cannot enter bounded output")
        let counter = CandidateRetentionCounter()
        let events = CandidateEvents()
        await manager.setCoverageHandler { event in
            events.append(event)
            if event.state == .gap(.consumerBackpressure) { dropped.fulfill() }
        }
        let session = await manager.startFrameProcessing { frame in
            if await counter.increment() <= 2 { firstTwo.fulfill() }
            return frame
        }
        for display in [UInt32(42), 43] {
            session.input.yield(try renderedCaptureFixture(metadata: FrameMetadata(displayID: display)))
        }
        await fulfillment(of: [firstTwo], timeout: 2)
        session.input.yield(try renderedCaptureFixture(metadata: FrameMetadata(displayID: 44)))
        await fulfillment(of: [dropped], timeout: 2)
        var iterator = session.output.makeAsyncIterator()
        _ = await iterator.next(); _ = await iterator.next()
        session.input.yield(try renderedCaptureFixture(metadata: FrameMetadata(displayID: 44)))
        session.input.finish()
        var retried: [CapturedFrame] = []
        while let frame = await iterator.next() { retried.append(frame) }
        XCTAssertEqual(retried.map(\.metadata.displayID), [44])
        XCTAssertTrue(events.values.contains { $0.displayID == 44 && $0.state == .recovered })
        await manager.stopFrameProcessing()
    }

    func testManagerCannotPublishHeldOldPolicyFrameAfterConfigurationUpdate() async throws {
        let manager = CaptureManager()
        let entered = expectation(description: "old frame forwarding entered")
        let gate = CandidateGate()
        let session = await manager.startFrameProcessing { frame in
            entered.fulfill(); await gate.wait(); return frame
        }
        session.input.yield(try renderedCaptureFixture(metadata: FrameMetadata(displayID: 42)))
        await fulfillment(of: [entered], timeout: 2)
        try await manager.updateConfig(CaptureConfig(excludedAppBundleIDs: ["com.test.capture"]))
        session.input.finish()
        await gate.release()
        let frames = await collect(session.output)
        XCTAssertTrue(frames.isEmpty)
        await manager.stopFrameProcessing()
    }

    func testCandidatePolicyKeepsUnprovenPrivateAndExcludedWindowsMasked() {
        let normal = CaptureConfig()
        XCTAssertTrue(CGWindowListCapture.candidateMustMaskWindow(bundleID: nil, title: "Document", config: normal))
        XCTAssertTrue(CGWindowListCapture.candidateMustMaskWindow(bundleID: "com.apple.loginwindow", title: nil, config: normal))
        XCTAssertTrue(CGWindowListCapture.candidateMustMaskWindow(bundleID: "com.google.Chrome", title: nil, config: normal))
        XCTAssertTrue(CGWindowListCapture.candidateMustMaskWindow(bundleID: "com.google.Chrome", title: "Account — Incognito", config: normal))
        XCTAssertTrue(CGWindowListCapture.candidateMustMaskWindow(bundleID: "com.google.Chrome", title: "Apparently ordinary page", config: normal),
                      "A title alone cannot prove a nonfocused browser window is nonprivate")
        XCTAssertFalse(CGWindowListCapture.candidateMustMaskWindow(bundleID: "com.google.Chrome", title: "Ordinary page",
            config: CaptureConfig(excludePrivateWindows: false)))
        XCTAssertFalse(CGWindowListCapture.candidateMustMaskWindow(bundleID: "com.apple.TextEdit", title: "Ordinary notes", config: normal))
        let excluded = CaptureConfig(excludedAppBundleIDs: ["com.apple.TextEdit"],
            redactWindowTitlePatterns: ["PRIVÉ", "  "], redactBrowserURLPatterns: ["secret.example"])
        XCTAssertTrue(CGWindowListCapture.candidateMustMaskWindow(bundleID: "com.apple.TextEdit", title: "Ordinary notes", config: excluded))
        XCTAssertTrue(CGWindowListCapture.candidateMustMaskWindow(bundleID: "com.example.writer", title: "Devis privé 💶", config: excluded))
        XCTAssertTrue(CGWindowListCapture.candidateMustMaskWindow(bundleID: "com.example.writer", title: nil, config: excluded))
        XCTAssertTrue(CGWindowListCapture.candidateMustMaskWindow(bundleID: "com.example.writer", title: "Public-looking background title", config: excluded),
                      "Unobserved background title changes can cross a redaction rule and return during screenshot capture")
        XCTAssertTrue(CGWindowListCapture.candidateMustMaskWindow(bundleID: "com.google.Chrome", title: "Apparently public tab", config: excluded),
                      "A focused browser URL cannot approve another window on another display")
    }

    func testCoverageRecoveryWaitsForBothNativeAndForwardingQueues() {
        let events = CandidateEvents()
        let delivery = CaptureCoverageDelivery()
        delivery.setHandler { events.append($0) }
        let gap = CaptureCoverageEvent(backend: .screenCaptureKitCandidate, displayID: 42,
                                       state: .gap(.consumerBackpressure))
        let recovered = CaptureCoverageEvent(backend: .screenCaptureKitCandidate, displayID: 42, state: .recovered)
        delivery.receive(gap, stage: .forwarding)
        delivery.receive(gap, stage: .source)
        delivery.receive(recovered, stage: .source)
        XCTAssertFalse(events.values.contains { $0.state == .recovered })
        delivery.receive(recovered, stage: .forwarding)
        XCTAssertEqual(events.values.last?.state, .recovered)
    }

    func testCaptureOwnedWorkspaceNotificationsRejectRoundTripWithoutActivityMonitor() async throws {
        let center = NotificationCenter()
        let fence = CaptureNotificationFence()
        _ = fence.start(workspaceCenter: center, displayCenter: center)
        defer { fence.stop() }
        let pixels = try renderedCaptureFixture(metadata: FrameMetadata(displayID: 42))
        let result = await CaptureSnapshotSequencer.capture(displayID: 42,
            readContext: { CapturedWindowSample(context: captureTestContext(), privacySignature: "unchanged-visible-windows") },
            capturePixels: {
                center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
                center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
                return pixels
            })
        XCTAssertNil(result, "A->B->A must invalidate pixels before delayed capture callbacks run, with activity capture disabled")
    }

    func testCoverageIdentityOverflowStaysVisibleUntilSessionReset() {
        let delivery = CaptureCoverageDelivery()
        let events = CandidateEvents()
        delivery.setHandler { events.append($0) }
        for id in UInt32(1)...129 {
            delivery.receive(.init(backend: .screenCaptureKitCandidate, displayID: id,
                                   state: .gap(.displayUnavailable)), stage: .source)
        }
        XCTAssertTrue(events.values.contains { $0.displayID == nil && $0.state == .gap(.consumerBackpressure) })
        delivery.receive(.init(backend: .screenCaptureKitCandidate, displayID: nil, state: .recovered), stage: .source)
        XCTAssertFalse(events.values.contains { $0.displayID == nil && $0.state == .recovered })
        delivery.reset()
        delivery.receive(.init(backend: .screenCaptureKitCandidate, displayID: nil, state: .recovered), stage: .source)
        XCTAssertEqual(events.values.last?.state, .recovered)
    }

    func testEndingSourceClosesItsGapsWithoutHidingPendingForwarding() {
        let delivery = CaptureCoverageDelivery()
        let events = CandidateEvents()
        delivery.setHandler { events.append($0) }
        delivery.receive(.init(backend: .screenCaptureKitCandidate, displayID: nil, state: .gap(.busy)), stage: .source)
        delivery.receive(.init(backend: .screenCaptureKitCandidate, displayID: 42, state: .gap(.displayUnavailable)), stage: .source)
        delivery.receive(.init(backend: .legacy, displayID: nil, state: .gap(.configurationChanged)), stage: .forwarding)
        delivery.endSource()
        XCTAssertTrue(events.values.contains { $0.displayID == 42 && $0.state == .ended })
        XCTAssertFalse(events.values.contains { $0.displayID == nil && $0.state == .ended })
        XCTAssertFalse(events.values.contains { $0.state == .recovered })
        delivery.receive(.init(backend: .legacy, displayID: nil, state: .recovered), stage: .forwarding)
        XCTAssertEqual(events.values.last?.state, .recovered, "An ended backend cannot suppress the replacement's actual fresh-frame recovery")
    }

    func testBackendReplacementEndsOldCoverageAndRecoversOnlyAfterNewPixelsReachSameStream() async throws {
        let source = CandidateSourceReceipt()
        let manager = CaptureManager(config: candidateConfig(), metadataProvider: CandidateMetadataProvider(),
            source: source, lifecycleEnvironment: .init(hasPermission: { true }, activeDisplayID: { 42 },
                startDisplayMonitoring: { _ in }, stopDisplayMonitoring: {}))
        let events = CandidateEvents()
        await manager.setCoverageHandler { events.append($0) }
        try await manager.startCapture(config: candidateConfig())
        let stream = await manager.frameStream
        await source.emitCoverage(.init(backend: .screenCaptureKitCandidate, displayID: nil, state: .gap(.busy)))
        await source.emitCoverage(.init(backend: .screenCaptureKitCandidate, displayID: 43, state: .gap(.displayUnavailable)))
        try await manager.updateConfig(CaptureConfig())
        XCTAssertTrue(events.values.contains { $0.displayID == 43 && $0.state == .ended })
        XCTAssertFalse(events.values.contains { $0.state == .recovered }, "Native restart alone does not prove capture resumed")
        let received = expectation(description: "replacement pixels arrive on the original stream")
        let collector = Task { () -> CapturedFrame? in
            for await frame in stream { received.fulfill(); return frame }
            return nil
        }
        let pixels = try renderedCaptureFixture(metadata: .init(displayID: 42,
            captureMonotonicTime: ProcessInfo.processInfo.systemUptime))
        await source.yield(pixels)
        await fulfillment(of: [received], timeout: 3)
        try await manager.stopCapture()
        let resumed = await collector.value
        XCTAssertEqual(resumed?.imageData, pixels.imageData)
        XCTAssertTrue(events.values.contains { $0.displayID == nil && $0.state == .recovered })
    }

    func testCaptureOwnedAXRevisionAndWorkspaceObserversStopWithTheirGeneration() {
        let center = NotificationCenter()
        let fence = CaptureNotificationFence()
        let original = fence.start(workspaceCenter: center, displayCenter: center)
        let beforeAX = ObservedWindowGenerations.shared.notificationRevision
        XCTAssertTrue(fence.noteWindowNotification(kAXTitleChangedNotification, token: original))
        XCTAssertGreaterThan(ObservedWindowGenerations.shared.notificationRevision, beforeAX)
        fence.stop()
        let stopped = ObservedWindowGenerations.shared.notificationRevision
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertFalse(fence.noteWindowNotification(kAXFocusedWindowChangedNotification, token: original))
        XCTAssertEqual(ObservedWindowGenerations.shared.notificationRevision, stopped)
        let replacement = fence.start(workspaceCenter: center, displayCenter: center)
        let restarted = ObservedWindowGenerations.shared.notificationRevision
        XCTAssertFalse(fence.noteWindowNotification(kAXMovedNotification, token: original))
        XCTAssertEqual(ObservedWindowGenerations.shared.notificationRevision, restarted)
        XCTAssertTrue(fence.noteWindowNotification(kAXFocusedWindowChangedNotification, token: replacement))
        XCTAssertGreaterThan(ObservedWindowGenerations.shared.notificationRevision, restarted)
        fence.stop()
    }

    func testNativeWindowAdmissionRefusesTransientReusedAndNowPrivateWindows() {
        let approved = CapturePermittedWindow(windowID: 7, processID: 123, bundleID: "com.apple.TextEdit")
        let config = CaptureConfig(excludedAppBundleIDs: ["com.test.secret"])
        XCTAssertTrue(approved.admits(windowID: 7, processID: 123, bundleID: "com.apple.TextEdit", title: "Notes", config: config))
        XCTAssertFalse(approved.admits(windowID: 8, processID: 123, bundleID: "com.apple.TextEdit", title: "Transient", config: config))
        XCTAssertFalse(approved.admits(windowID: 7, processID: 456, bundleID: "com.apple.TextEdit", title: "Reused", config: config))
        XCTAssertFalse(approved.admits(windowID: 7, processID: 123, bundleID: "com.test.secret", title: "Secret", config: config))
        let browser = CapturePermittedWindow(windowID: 9, processID: 789, bundleID: "com.google.Chrome")
        XCTAssertFalse(browser.admits(windowID: 9, processID: 789, bundleID: "com.google.Chrome", title: "Incognito", config: config))
    }

    func testLegacyCompatibilityRejectsInvalidRequestsWithoutReadingPixels() {
        XCTAssertNil(LegacyCaptureAPI.displayImage(0))
        XCTAssertNil(LegacyCaptureAPI.windowImage(bounds: .zero, windows: [] as CFArray, options: .bestResolution))
        XCTAssertNil(LegacyCaptureAPI.windowImage(bounds: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
                                                 windows: [NSNumber(value: 1)] as CFArray, options: .bestResolution))
        XCTAssertNil(LegacyCaptureAPI.belowWindowImage(bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                      windowID: 0, options: .boundsIgnoreFraming))
        XCTAssertNil(LegacyCaptureAPI.belowWindowImage(bounds: .zero, windowID: 1, options: .boundsIgnoreFraming))
        XCTAssertNil(LegacyCaptureAPI.belowWindowImage(bounds: CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100),
                                                      windowID: 1, options: .boundsIgnoreFraming))
    }

    func testCaptureWindowObservationRequiresCurrentRegistrationAfterNativeFocusChange() {
        let center = NotificationCenter()
        let registry = ObservedWindowGenerations()
        let fence = CaptureNotificationFence(registry: registry)
        let token = fence.start(workspaceCenter: center, displayCenter: center)
        defer { fence.stop() }
        let registeredRevision = registry.notificationRevision
        XCTAssertTrue(fence.confirmObservedProcess(123, token: token, revision: registeredRevision))
        XCTAssertTrue(registry.hasCaptureObservation(processID: 123))
        XCTAssertFalse(registry.hasCaptureObservation(processID: 456))
        XCTAssertTrue(fence.noteWindowNotification(kAXTitleChangedNotification, token: token))
        XCTAssertTrue(registry.hasCaptureObservation(processID: 123), "Title noise keeps a live focused-window registration")
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertFalse(registry.hasCaptureObservation(processID: 123))
        XCTAssertFalse(fence.confirmObservedProcess(123, token: token, revision: registeredRevision),
                       "An observer installation completing after focus changed cannot restore old attribution")
        XCTAssertTrue(fence.confirmObservedProcess(456, token: token, revision: registry.notificationRevision))
        XCTAssertTrue(registry.hasCaptureObservation(processID: 456))
        fence.stop()
        XCTAssertFalse(registry.hasCaptureObservation(processID: 456))
    }

    func testRemovedOrReplacedDisplayRejectsLatePixelsAndReportsGap() async throws {
        for replacement in [false, true] {
            let gate = CandidateGate()
            let entered = expectation(description: "native screenshot suspended")
            let fixture = CandidateFixture(pixels: try renderedCaptureFixture(), displays: [target(42)])
            await fixture.holdPixels(gate, entered: { entered.fulfill() })
            let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false)
            let events = CandidateEvents()
            await source.setCoverageHandler { events.append($0) }
            let pair = AsyncStream<CapturedFrame>.makeStream()
            try await source.startCapture(config: candidateConfig(), frameContinuation: pair.continuation, displayID: 42)
            let pending = Task { await source.captureImmediateAndResetTimer() }
            await fulfillment(of: [entered], timeout: 2)
            await fixture.setDisplays(replacement ? [target(42, identity: "replacement-monitor")] : [])
            await gate.release()
            await pending.value
            try await source.stopCapture()
            pair.continuation.finish()
            let frames = await collect(pair.stream)
            XCTAssertTrue(frames.isEmpty, "A display ID cannot admit pixels from a removed/replaced monitor")
            XCTAssertTrue(events.values.contains { $0.displayID == 42 && $0.state == .gap(.displayUnavailable) })
        }
    }

    func testConfigurationUpdateAndStopJoinAndDiscardSuspendedNativeCapture() async throws {
        for stop in [false, true] {
            let gate = CandidateGate()
            let entered = expectation(description: "pixel operation entered")
            let fixture = CandidateFixture(pixels: try renderedCaptureFixture(), displays: [target(42)])
            await fixture.holdPixels(gate, entered: { entered.fulfill() })
            let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false)
            let pair = AsyncStream<CapturedFrame>.makeStream()
            try await source.startCapture(config: candidateConfig(), frameContinuation: pair.continuation, displayID: 42)
            let pending = Task { await source.captureImmediateAndResetTimer() }
            await fulfillment(of: [entered], timeout: 2)
            let changed = expectation(description: "source lifecycle invalidated")
            await source.setInvalidationCheckpoint { changed.fulfill() }
            let boundary = Task {
                if stop { try await source.stopCapture() }
                else { try await source.updateConfig(candidateConfig(excluded: ["com.test.capture"])) }
            }
            await fulfillment(of: [changed], timeout: 2)
            await gate.release()
            try await boundary.value
            await pending.value
            await source.setInvalidationCheckpoint(nil)
            try await source.stopCapture()
            pair.continuation.finish()
            let frames = await collect(pair.stream)
            XCTAssertTrue(frames.isEmpty, "Pixels admitted before a privacy/lifecycle boundary cannot be published after it")
        }
    }

    func testRepeatedCaptureRequestsCoalesceAndBackpressureIsExplicit() async throws {
        let gate = CandidateGate()
        let entered = expectation(description: "first native pixels entered")
        let fixture = CandidateFixture(pixels: try renderedCaptureFixture(), displays: [target(42)])
        await fixture.holdPixels(gate, entered: { entered.fulfill() })
        let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false)
        let events = CandidateEvents()
        await source.setCoverageHandler { events.append($0) }
        let pair = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingOldest(1))
        try await source.startCapture(config: candidateConfig(), frameContinuation: pair.continuation, displayID: 42)
        let first = Task { await source.captureImmediateAndResetTimer() }
        await fulfillment(of: [entered], timeout: 2)
        let joined = expectation(description: "second trigger joined existing capture")
        await source.setCoalescingCheckpoint { joined.fulfill() }
        let second = Task { await source.captureImmediateAndResetTimer() }
        await fulfillment(of: [joined], timeout: 2)
        await gate.release()
        await first.value
        await second.value
        let callsAfterJoin = await fixture.pixelReads
        XCTAssertEqual(callsAfterJoin, 1)
        await fixture.clearPixelHold()
        await source.captureImmediateAndResetTimer()
        XCTAssertTrue(events.values.contains { $0.state == .gap(.consumerBackpressure) })
        try await source.stopCapture()
        pair.continuation.finish()
        let frames = await collect(pair.stream)
        XCTAssertEqual(frames.count, 1, "Native production cannot grow a queue without limit")
    }

    func testUnstableInventoryAndUnknownDeniedContextDoNotReadOrPublishPixels() async throws {
        let fixture = CandidateFixture(pixels: try renderedCaptureFixture(), displays: [target(42)])
        let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false)
        let events = CandidateEvents()
        await source.setCoverageHandler { events.append($0) }
        let pair = AsyncStream<CapturedFrame>.makeStream()
        try await source.startCapture(config: candidateConfig(), frameContinuation: pair.continuation, displayID: 42)
        await fixture.setDenied(true)
        await source.captureImmediateAndResetTimer()
        let deniedReads = await fixture.pixelReads
        XCTAssertEqual(deniedReads, 0)
        await fixture.setDenied(false)
        await fixture.setMutatingInventory(true)
        await source.captureImmediateAndResetTimer()
        await fixture.setMutatingInventory(false)
        await source.captureImmediateAndResetTimer()
        try await source.stopCapture()
        pair.continuation.finish()
        let frames = await collect(pair.stream)
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(events.values.contains { $0.state == .gap(.unstableContext) })
        XCTAssertTrue(events.values.contains { $0.displayID == 42 && $0.state == .recovered })
    }

    func testPrivacyMaskRemovesExcludedPixelsAtNativeScaleIncludingFractionalEdges() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 96,
            bitsPerComponent: 8, bytesPerRow: 512, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
        let input = try XCTUnwrap(context.makeImage())
        let masked = try XCTUnwrap(CapturePrivacyMask.apply(to: input,
            displayBounds: CGRect(x: 100, y: 200, width: 64, height: 48),
            excludedBounds: [CGRect(x: 110.25, y: 210.25, width: 12.5, height: 10.5)]))
        let rendered = try XCTUnwrap(CGContext(data: nil, width: 128, height: 96,
            bitsPerComponent: 8, bytesPerRow: 512, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        rendered.draw(masked, in: CGRect(x: 0, y: 0, width: 128, height: 96))
        let pixels = try XCTUnwrap(rendered.data).assumingMemoryBound(to: UInt8.self)
        // Raw bitmap rows start at the top, unlike Quartz drawing coordinates.
        // The real native context/provider/redraw probe confirms the entire
        // fractional WindowServer rectangle rounds out to rows 20..<42.
        for y in 20..<42 {
            for x in 20..<46 {
                let offset = y * 512 + x * 4
                XCTAssertEqual(pixels[offset], 0)
                XCTAssertEqual(pixels[offset + 1], 0)
                XCTAssertEqual(pixels[offset + 2], 0)
                XCTAssertEqual(pixels[offset + 3], 255)
            }
        }
        // A vertically mirrored mask would expose the excluded region while
        // destroying unrelated pixels; assert both sides of that boundary.
        for y in 54..<76 {
            for x in 20..<46 {
                let offset = y * 512 + x * 4
                XCTAssertEqual(pixels[offset], 255)
                XCTAssertEqual(pixels[offset + 1], 255)
                XCTAssertEqual(pixels[offset + 2], 255)
                XCTAssertEqual(pixels[offset + 3], 255)
            }
        }
        XCTAssertEqual(pixels[0], 255)
        XCTAssertNil(CapturePrivacyMask.apply(to: input, displayBounds: .zero,
                                             excludedBounds: [CGRect(x: 0, y: 0, width: 1, height: 1)]))
    }

    private func collect(_ stream: AsyncStream<CapturedFrame>) async -> [CapturedFrame] {
        var result: [CapturedFrame] = []
        for await frame in stream { result.append(frame) }
        return result
    }
}

private actor CandidatePersistentEvents {
    private(set) var values: [String] = []
    func add(_ event: String) { values.append(event) }
}

private func candidateConfig(excluded: Set<String> = [], displayPolicy: CaptureDisplayPolicy = .allDisplays) -> CaptureConfig {
    CaptureConfig(excludedAppBundleIDs: excluded, backend: .screenCaptureKitCandidate, displayPolicy: displayPolicy)
}

private func target(_ displayID: UInt32, identity: String? = nil) -> CaptureDisplayTarget {
    CaptureDisplayTarget(displayID: displayID, identity: identity ?? "monitor-\(displayID)")
}

private actor CandidateFixture {
    let pixels: CapturedFrame
    private var displays: [CaptureDisplayTarget]
    private var denied = false
    private var mutatingInventory = false
    private var inventoryRevision = 0
    private var gate: CandidateGate?
    private var entered: (@Sendable () -> Void)?
    private(set) var contextReads: [UInt32: Int] = [:]
    private(set) var pixelReads = 0

    init(pixels: CapturedFrame, displays: [CaptureDisplayTarget] = [target(42), target(43)]) {
        self.pixels = pixels; self.displays = displays
    }
    nonisolated func environment() -> ScreenCaptureEnvironment {
        ScreenCaptureEnvironment(displays: { await self.displaySnapshot() },
            context: { display, _ in await self.context(display) },
            pixels: { display, _ in await self.readPixels(display) })
    }
    func displaySnapshot() -> [CaptureDisplayTarget] { displays }
    func setDisplays(_ value: [CaptureDisplayTarget]) { displays = value }
    func setDenied(_ value: Bool) { denied = value }
    func setMutatingInventory(_ value: Bool) { mutatingInventory = value }
    func holdPixels(_ gate: CandidateGate, entered: @escaping @Sendable () -> Void) {
        self.gate = gate; self.entered = entered
    }
    func clearPixelHold() { gate = nil; entered = nil }
    func context(_ display: CaptureDisplayTarget) -> CapturedWindowSample {
        contextReads[display.displayID, default: 0] += 1
        guard !denied else { return CapturedWindowSample(context: nil) }
        return CapturedWindowSample(context: display.displayID == 42 ? captureTestContext() : nil,
            privacySignature: "visible-windows-\(inventoryRevision)",
            displayOnlyID: display.displayID == 42 ? nil : display.displayID)
    }
    func readPixels(_ display: CaptureDisplayTarget) async -> CapturedFrame {
        pixelReads += 1
        if let gate { entered?(); await gate.wait() }
        if mutatingInventory { inventoryRevision += 1 }
        return CapturedFrame(imageData: pixels.imageData, width: pixels.width, height: pixels.height,
                             bytesPerRow: pixels.bytesPerRow, metadata: FrameMetadata(displayID: display.displayID))
    }
}

private actor CandidateGate {
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { released = true; waiting?.resume(); waiting = nil }
}

private actor CandidateRetentionCounter {
    private var count = 0
    func increment() -> Int { count += 1; return count }
}

private actor CandidateActiveDisplay {
    private(set) var value: UInt32 = 42
    func set(_ value: UInt32) { self.value = value }
}

private struct CandidateMetadataProvider: FrontmostMetadataProviding {
    func getFrontmostAppInfo(includeBrowserURL: Bool) async -> FrameMetadata { .empty }
}

private actor CandidateSourceReceipt: CaptureFrameSource {
    private(set) var startedDisplays: [UInt32] = []
    private var continuation: AsyncStream<CapturedFrame>.Continuation?
    private var coverage: (@Sendable (CaptureCoverageEvent) -> Void)?
    func startCapture(config: CaptureConfig, frameContinuation: AsyncStream<CapturedFrame>.Continuation,
                      displayID: CGDirectDisplayID?) {
        startedDisplays.append(displayID ?? 0)
        continuation = frameContinuation
    }
    func stopCapture() { continuation = nil }
    func updateConfig(_ config: CaptureConfig) { }
    func captureImmediateAndResetTimer() { }
    func setCoverageHandler(_ handler: (@Sendable (CaptureCoverageEvent) -> Void)?) { coverage = handler }
    func emitCoverage(_ event: CaptureCoverageEvent) { coverage?(event) }
    func yield(_ frame: CapturedFrame) { continuation?.yield(frame) }
}

private final class CandidateEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CaptureCoverageEvent] = []
    var values: [CaptureCoverageEvent] { lock.withLock { storage } }
    func append(_ event: CaptureCoverageEvent) { lock.withLock { storage.append(event) } }
}
