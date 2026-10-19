import XCTest
import ApplicationServices
import Shared
@testable import Capture

final class CaptureContextSequencingTests: XCTestCase {
    func testSlowDiagnosticWriterCoalescesPendingIntervalsWithoutBlockingCapture() async {
        let started = expectation(description: "Diagnostic writer entered")
        let drained = expectation(description: "Coalesced diagnostics drained")
        let releaseWriter = DispatchSemaphore(value: 0)
        defer { releaseWriter.signal() }
        let fixture = SamplingDiagnosticFixture()
        let delivery = CaptureSamplingDiagnosticDelivery { summary in
            fixture.append(summary)
            if fixture.values.count == 1 {
                started.fulfill()
                _ = releaseWriter.wait(timeout: .now() + 5)
            } else { drained.fulfill() }
        }
        let diagnostics = CaptureSamplingDiagnostics(now: { fixture.time }, emit: { delivery.enqueue($0) })
        diagnostics.record(.accepted)
        await fulfillment(of: [started], timeout: 3)
        for interval in 1...1_000 {
            fixture.time = Double(interval) * 30
            diagnostics.record(.displayMismatch)
        }
        XCTAssertEqual(fixture.values.count, 1, "Capture can continue while the file sink is held")
        releaseWriter.signal()
        await fulfillment(of: [drained], timeout: 3)
        XCTAssertEqual(fixture.values.count, 2, "Only one coalesced pending summary may be retained")
        XCTAssertEqual(fixture.values.last?.counts[.displayMismatch], 1_000)
    }

    func testCancellationDuringMetadataDoesNotStartPixelCapture() async throws {
        let pixels = try renderedCaptureFixture()
        let outcomes = CaptureOutcomeFixture()
        let task = Task {
            await CaptureSnapshotSequencer.capture(displayID: 42, readContext: {
                withUnsafeCurrentTask { $0?.cancel() }
                return CapturedWindowSample(context: captureTestContext(), privacySignature: "inventory")
            }, capturePixels: {
                XCTFail("Cancelled metadata work must not start a native pixel read")
                return pixels
            }, recordOutcome: { outcomes.append($0) })
        }
        let frame = await task.value
        XCTAssertNil(frame)
        XCTAssertEqual(outcomes.values, [.cancelled])
    }

    func testSamplingDiagnosticsAggregateConcurrentAttemptsAtBoundedCadence() {
        let fixture = SamplingDiagnosticFixture()
        let diagnostics = CaptureSamplingDiagnostics(now: { fixture.time }, emit: { fixture.append($0) })
        diagnostics.record(.accepted)
        DispatchQueue.concurrentPerform(iterations: 10_000) { index in
            diagnostics.record(index.isMultiple(of: 2) ? .displayMismatch : .inventoryChanged)
        }
        XCTAssertEqual(fixture.values.count, 1)
        fixture.time = 29.99
        diagnostics.record(.notificationChangedDuringPixels)
        XCTAssertEqual(fixture.values.count, 1)
        fixture.time = 30
        diagnostics.record(.accepted)
        XCTAssertEqual(fixture.values.count, 2)
        let summary = fixture.values[1]
        XCTAssertEqual(summary.counts[.displayMismatch], 5_000)
        XCTAssertEqual(summary.counts[.inventoryChanged], 5_000)
        XCTAssertEqual(summary.counts[.notificationChangedDuringPixels], 1)
        XCTAssertEqual(summary.counts[.accepted], 1)
        XCTAssertFalse(summary.countsClamped)
        // A slow/noisy interval cannot produce a line per capture, and the
        // production formatter has no window/app/URL input to disclose.
        XCTAssertLessThan(summary.message.utf8.count, 512)
        XCTAssertFalse(summary.message.contains("Same document label"))
    }

    func testRejectionDiagnosticsDistinguishDisplayIdentityAndPrivacyWithoutReadingPixels() async throws {
        let pixels = try renderedCaptureFixture()
        let samples: [(CapturedWindowSample, CaptureSamplingOutcome)] = [
            (.init(context: nil), .contextUnavailable),
            (.init(context: nil, failure: .focusedApplicationChanged), .focusedApplicationChanged),
            (.init(context: captureTestContext(display: 43), privacySignature: "inventory"), .displayMismatch),
            (.init(context: captureTestContext(generation: nil), privacySignature: "inventory"), .windowIdentityUnavailable),
            (.init(context: captureTestContext()), .inventoryUnavailable)
        ]
        for (sample, expected) in samples {
            let outcomes = CaptureOutcomeFixture()
            let frame = await CaptureSnapshotSequencer.capture(displayID: 42, readContext: { sample }, capturePixels: {
                XCTFail("Rejected metadata must not admit native pixels")
                return pixels
            }, recordOutcome: { outcomes.append($0) })
            XCTAssertNil(frame)
            XCTAssertEqual(outcomes.values, [expected])
        }
    }

    func testPixelBracketReportsSuccessAndChangedInventoryExactlyOnce() async throws {
        let pixels = try renderedCaptureFixture()
        for changed in [false, true] {
            let source = CaptureSampleFixture(captureTestContext())
            let outcomes = CaptureOutcomeFixture()
            let frame = await CaptureSnapshotSequencer.capture(displayID: 42,
                readContext: { await source.sample() }, capturePixels: {
                    if changed { await source.changeInventory() }
                    return pixels
                }, recordOutcome: { outcomes.append($0) })
            XCTAssertEqual(outcomes.values, [changed ? .inventoryChanged : .accepted])
            XCTAssertEqual(frame?.imageData, changed ? nil : pixels.imageData)
        }
    }

    func testMatchingSamplesBindActualPixelsToCaptureTimeContext() async throws {
        let context = captureTestContext()
        let source = CaptureSampleFixture(context)
        let pixels = try renderedCaptureFixture()
        let before = Date()
        let captured = try await CaptureSnapshotSequencer.capture(
            displayID: 42, readContext: { await source.sample() }, capturePixels: { pixels })
        let result = try XCTUnwrap(captured)
        XCTAssertEqual(result.imageData, pixels.imageData)
        XCTAssertEqual(result.metadata.captureContext, context)
        XCTAssertEqual(result.metadata.appBundleID, context.appBundleID)
        XCTAssertEqual(result.metadata.windowName, context.windowTitle)
        XCTAssertEqual(result.metadata.displayID, 42)
        XCTAssertGreaterThanOrEqual(result.timestamp, before)
        XCTAssertLessThanOrEqual(result.timestamp, Date())
        XCTAssertNotNil(result.metadata.captureMonotonicTime)
        let reads = await source.readCount
        XCTAssertEqual(reads, 2, "Context must bracket the pixel operation")
    }

    func testFocusDocumentWindowAndGenerationChangesCannotAttributeOldPixels() async throws {
        let original = captureTestContext()
        let changed = [
            captureTestContext(app: "com.test.other"),
            captureTestContext(window: 8),
            captureTestContext(generation: "reused-window-generation"),
            captureTestContext(document: "different-document-same-label"),
            captureTestContext(display: 43)
        ]
        for next in changed {
            let source = CaptureSampleFixture(original)
            let pixels = try renderedCaptureFixture()
            let captured = try await CaptureSnapshotSequencer.capture(
                displayID: 42, readContext: { await source.sample() }, capturePixels: {
                    await source.change(to: next)
                    return pixels
                })
            XCTAssertNil(captured, "An app/window/document/display transition invalidates the earlier privacy mask")
        }
    }

    func testUnknownWindowGenerationOrDifferentDisplayCannotClaimContext() async throws {
        for context in [captureTestContext(generation: nil), captureTestContext(display: 43)] {
            let source = CaptureSampleFixture(context)
            let pixels = try renderedCaptureFixture()
            let captured = try await CaptureSnapshotSequencer.capture(
                displayID: 42, readContext: { await source.sample() }, capturePixels: { pixels })
            XCTAssertNil(captured)
        }
    }

    func testRedactionSuppressesMetadataEvenWhenFocusIsStable() async throws {
        let source = CaptureSampleFixture(captureTestContext())
        let pixels = try renderedCaptureFixture(metadata: FrameMetadata(redactionReason: "capture-policy", displayID: 42))
        let captured = try await CaptureSnapshotSequencer.capture(
            displayID: 42, readContext: { await source.sample() }, capturePixels: { pixels })
        let result = try XCTUnwrap(captured)
        XCTAssertNil(result.metadata.captureContext)
        XCTAssertNil(result.metadata.appBundleID)
        XCTAssertNil(result.metadata.windowName)
        XCTAssertEqual(result.metadata.redactionReason, "capture-policy")
    }

    func testMissingPixelsDoNotManufactureACapture() async throws {
        let source = CaptureSampleFixture(captureTestContext())
        let result = try await CaptureSnapshotSequencer.capture(
            displayID: 42, readContext: { await source.sample() }, capturePixels: { nil })
        XCTAssertNil(result)
    }

    func testExcludedOrPrivateFocusBeforeAndAfterPixelsDiscardsTheCapture() async throws {
        let pixels = try renderedCaptureFixture()
        for deniedBefore in [false, true] {
            let source = CaptureSampleFixture(deniedBefore ? nil : captureTestContext())
            let captured = try await CaptureSnapshotSequencer.capture(
                displayID: 42, readContext: { await source.sample() }, capturePixels: {
                    await source.change(to: nil)
                    return pixels
                })
            XCTAssertNil(captured, "A denied or unproven focus must never retain pixels under stale exclusions")
        }
    }

    func testBackgroundWindowChangeInvalidatesEarlierPrivacyMask() async throws {
        let pixels = try renderedCaptureFixture()
        let source = CaptureSampleFixture(captureTestContext())
        let captured = try await CaptureSnapshotSequencer.capture(
            displayID: 42, readContext: { await source.sample() }, capturePixels: {
                await source.changeInventory()
                return pixels
            })
        XCTAssertNil(captured, "A new background private window must not escape an earlier exclusion list")
    }

    func testLifecycleBoundaryInsidePixelsRejectsMatchingMetadata() async throws {
        let pixels = try renderedCaptureFixture()
        for resumeBeforeReturn in [false, true] {
            let source = CaptureSampleFixture(captureTestContext())
            let observations = ActivityObservationBuffer()
            defer { observations.finish() }
            let captured = await CaptureSnapshotSequencer.capture(displayID: 42,
                readContext: { await source.sample() }, capturePixels: {
                    observations.suspend()
                    if resumeBeforeReturn { observations.resume() }
                    return pixels
                })
            XCTAssertNil(captured, "A pause or pause/resume during pixels cannot inherit the earlier capture admission")
        }
    }

    func testNotificationDuringInitialMetadataReadPreventsPixelAdmission() async throws {
        let source = CaptureSampleFixture(captureTestContext())
        let observations = ActivityObservationBuffer()
        defer { observations.finish() }
        let pixels = try renderedCaptureFixture()
        let outcomes = CaptureOutcomeFixture()
        let captured = await CaptureSnapshotSequencer.capture(displayID: 42, readContext: {
            let sample = await source.sample()
            ActivityAXNotificationHandler.handle(kAXTitleChangedNotification, app: nil, buffer: observations)
            return sample
        }, capturePixels: {
            XCTFail("Pixels must not be read after the initial metadata admission was invalidated")
            return pixels
        }, recordOutcome: { outcomes.append($0) })
        XCTAssertNil(captured)
        XCTAssertEqual(outcomes.values, [.notificationChangedBeforePixels])
        let reads = await source.readCount
        XCTAssertEqual(reads, 1)
        let retry = await CaptureSnapshotSequencer.capture(displayID: 42,
            readContext: { await source.sample() }, capturePixels: { pixels },
            recordOutcome: { outcomes.append($0) })
        XCTAssertEqual(retry?.imageData, pixels.imageData)
        XCTAssertEqual(outcomes.values, [.notificationChangedBeforePixels, .accepted])
    }
}

private final class SamplingDiagnosticFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var clock: TimeInterval = 0
    private var summaries: [CaptureSamplingSummary] = []
    var time: TimeInterval {
        get { lock.withLock { clock } }
        set { lock.withLock { clock = newValue } }
    }
    var values: [CaptureSamplingSummary] { lock.withLock { summaries } }
    func append(_ value: CaptureSamplingSummary) { lock.withLock { summaries.append(value) } }
}

private final class CaptureOutcomeFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CaptureSamplingOutcome] = []
    var values: [CaptureSamplingOutcome] { lock.withLock { recorded } }
    func append(_ value: CaptureSamplingOutcome) { lock.withLock { recorded.append(value) } }
}

private actor CaptureSampleFixture {
    private var context: ActivityContext?
    private var signature = "original-visible-window-inventory"
    private(set) var readCount = 0
    init(_ context: ActivityContext?) { self.context = context }
    func change(to context: ActivityContext?) { self.context = context }
    func changeInventory() { signature = "new-background-window-inventory" }
    func sample() -> CapturedWindowSample {
        readCount += 1
        return CapturedWindowSample(context: context, privacySignature: signature)
    }
}

func captureTestContext(app: String = "com.test.capture", window: UInt32 = 7,
                        generation: String? = "observed-window-generation", document: String = "document-one",
                        display: UInt32 = 42) -> ActivityContext {
    ActivityContext(appBundleID: app, appName: "Capture fixture", processID: 101,
        processGeneration: "fixture-process-generation", windowID: window, windowGeneration: generation,
        windowTitle: "Same document label", displayID: display, documentID: document,
        safeURL: "https://example.test/document", adapter: "test-visible-document")
}
