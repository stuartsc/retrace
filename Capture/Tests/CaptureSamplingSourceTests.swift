import Foundation
import Shared
import XCTest
@testable import Capture

/// Exercises the real sampler and pixel sequencer with authored external metadata.
/// No desktop enumeration, permission prompts or native screen capture.
final class CaptureSamplingSourceTests: XCTestCase {
    func testCaptureAdmissionDoesNotJoinHeldOptionalDocumentLookup() async throws {
        let base = windowContext()
        let app = application(for: base)
        let pixels = try renderedCaptureFixture()
        let documentEntered = expectation(description: "Optional document lookup held")
        let captureFinished = expectation(description: "Capture finishes while optional lookup remains held")
        let gate = CaptureDocumentGate(entered: { documentEntered.fulfill() })
        let source = ActivityContextSource(frontmost: { app }, window: { _, _, _ in base },
            document: { _, _ in await gate.read() }, permission: { true })
        let optionalLookup = Task { await source.document(base, app) }
        await fulfillment(of: [documentEntered], timeout: 2)

        let capture = Task {
            let result = await CaptureSnapshotSequencer.capture(displayID: 42,
                readContext: {
                    await source.sampleCapture(config: CaptureConfig(), displayID: 42,
                        readInventory: { _ in "authored-stable-inventory" })
                }, capturePixels: { pixels })
            captureFinished.fulfill()
            return result
        }
        await fulfillment(of: [captureFinished], timeout: 1)
        let requestsBeforeRelease = await gate.requests
        let wasHeld = await gate.isHeld
        // Join both tasks even on the expected RED timeout; no suspended lookup escapes the test.
        await gate.release()
        _ = await optionalLookup.value
        let result = await capture.value

        XCTAssertEqual(requestsBeforeRelease, 1, "Sampling must not start a second optional AX lookup")
        XCTAssertTrue(wasHeld, "Capture availability must not depend on optional document completion")
        let frame = try XCTUnwrap(result)
        XCTAssertEqual(frame.imageData, pixels.imageData)
        XCTAssertEqual(frame.metadata.captureContext, base)
        XCTAssertEqual(frame.metadata.appBundleID, base.appBundleID)
        XCTAssertEqual(frame.metadata.appName, base.appName)
        XCTAssertEqual(frame.metadata.windowName, base.windowTitle)
        XCTAssertEqual(frame.metadata.displayID, 42)
        XCTAssertNil(frame.metadata.browserURL)
        XCTAssertNil(frame.metadata.captureContext?.documentID)
        XCTAssertNil(frame.metadata.captureContext?.paneID)
    }

    func testCaptureSourceStillRejectsInventoryAndApplicationChanges() async throws {
        let base = windowContext()
        let app = application(for: base)
        let otherApp = ActivityApplicationSnapshot(bundleID: "com.test.other", name: "Other fixture",
            pid: 102, generation: "other-fixture-process")
        let pixels = try renderedCaptureFixture()
        let cases: [(applications: [ActivityApplicationSnapshot], inventories: [String], outcome: CaptureSamplingOutcome)] = [
            ([app, app], ["before", "after"], .inventoryChangedDuringMetadata),
            ([app, otherApp], ["stable", "stable"], .focusedApplicationChanged)
        ]
        for item in cases {
            let fixture = CaptureSamplingSourceFixture(applications: item.applications, inventories: item.inventories)
            let source = ActivityContextSource(frontmost: { fixture.nextApplication() },
                window: { _, _, _ in base }, document: { _, _ in nil }, permission: { true })
            let frame = await CaptureSnapshotSequencer.capture(displayID: 42,
                readContext: {
                    await source.sampleCapture(config: CaptureConfig(), displayID: 42,
                        readInventory: { _ in fixture.nextInventory() })
                }, capturePixels: {
                    XCTFail("Changed metadata must reject admission before pixels are read")
                    return pixels
                }, recordOutcome: { fixture.record($0) })
            XCTAssertNil(frame)
            XCTAssertEqual(fixture.outcomes, [item.outcome])
        }
    }

    private func windowContext() -> ActivityContext {
        ActivityContext(appBundleID: "com.test.capture", appName: "Capture fixture",
            processID: 101, processGeneration: "fixture-process", windowID: 7,
            windowGeneration: "fixture-window", windowTitle: "Authored window", displayID: 42,
            adapter: "window-metadata-v1", uncertainty: ["Document identity unavailable"])
    }

    private func application(for context: ActivityContext) -> ActivityApplicationSnapshot {
        ActivityApplicationSnapshot(bundleID: context.appBundleID, name: context.appName,
            pid: context.processID, generation: context.processGeneration)
    }
}

private actor CaptureDocumentGate {
    private let entered: @Sendable () -> Void
    private var waiters: [CheckedContinuation<ActivityContext?, Never>] = []
    private var released = false
    private(set) var requests = 0
    var isHeld: Bool { !released && !waiters.isEmpty }

    init(entered: @escaping @Sendable () -> Void) { self.entered = entered }

    func read() async -> ActivityContext? {
        requests += 1
        if requests == 1 { entered() }
        guard !released else { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: nil) }
    }
}

private final class CaptureSamplingSourceFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let applications: [ActivityApplicationSnapshot]
    private let inventories: [String]
    private var applicationReads = 0
    private var inventoryReads = 0
    private var recorded: [CaptureSamplingOutcome] = []
    var outcomes: [CaptureSamplingOutcome] { lock.withLock { recorded } }

    init(applications: [ActivityApplicationSnapshot], inventories: [String]) {
        precondition(!applications.isEmpty && !inventories.isEmpty)
        self.applications = applications
        self.inventories = inventories
    }

    func nextApplication() -> ActivityApplicationSnapshot {
        lock.withLock {
            defer { applicationReads += 1 }
            return applications[min(applicationReads, applications.count - 1)]
        }
    }

    func nextInventory() -> String {
        lock.withLock {
            defer { inventoryReads += 1 }
            return inventories[min(inventoryReads, inventories.count - 1)]
        }
    }

    func record(_ outcome: CaptureSamplingOutcome) { lock.withLock { recorded.append(outcome) } }
}
