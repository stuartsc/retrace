import XCTest
import ApplicationServices
import Shared
@testable import Capture

final class CaptureContextSequencingTests: XCTestCase {
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
        let captured = await CaptureSnapshotSequencer.capture(displayID: 42, readContext: {
            let sample = await source.sample()
            ActivityAXNotificationHandler.handle(kAXTitleChangedNotification, app: nil, buffer: observations)
            return sample
        }, capturePixels: {
            XCTFail("Pixels must not be read after the initial metadata admission was invalidated")
            return pixels
        })
        XCTAssertNil(captured)
        let reads = await source.readCount
        XCTAssertEqual(reads, 1)
    }
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
