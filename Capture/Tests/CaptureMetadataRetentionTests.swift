import CoreGraphics
import XCTest
import Shared
@testable import Capture

/// Real CoreGraphics pixels pass through the production forwarding stream;
/// the external metadata provider represents an unrelated later focus.
final class CaptureMetadataRetentionTests: XCTestCase {
    func testDelayedEnrichmentCannotReplaceCapturedWindowOrDisplay() async throws {
        let late = LateFocusMetadataProvider()
        let manager = CaptureManager(config: CaptureConfig(adaptiveCaptureEnabled: false), metadataProvider: late)
        let saved = try renderedCaptureFixture(metadata: FrameMetadata(
            appBundleID: "com.test.saved", appName: "Saved document", windowName: "Retained invoice",
            browserURL: "https://example.test/invoice", displayID: 42))
        let session = await manager.startFrameProcessing { await manager.enrichFrameMetadata($0) }
        session.input.yield(saved)
        session.input.finish()
        var frames: [CapturedFrame] = []
        for await frame in session.output { frames.append(frame) }
        await session.task.value
        await manager.stopFrameProcessing()

        let result = try XCTUnwrap(frames.first)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(result.imageData, saved.imageData)
        XCTAssertEqual(result.timestamp, saved.timestamp)
        XCTAssertEqual(result.metadata, saved.metadata)
        let calls = await late.calls
        XCTAssertEqual(calls, 0, "Retained pixels must not trigger any query of the newly focused app")
    }

    func testMissingCaptureContextRemainsUnknownAfterFocusChanges() async throws {
        let late = LateFocusMetadataProvider()
        let manager = CaptureManager(metadataProvider: late)
        let saved = try renderedCaptureFixture(metadata: FrameMetadata(displayID: 77))
        let result = await manager.enrichFrameMetadata(saved)
        XCTAssertEqual(result.metadata, saved.metadata)
        let calls = await late.calls
        XCTAssertEqual(calls, 0, "Unknown capture context cannot be reconstructed from current focus")
    }

    func testRedactedPixelsNeverAcquireUnrelatedAppOrDocumentMetadata() async throws {
        let late = LateFocusMetadataProvider()
        let manager = CaptureManager(metadataProvider: late)
        let saved = try renderedCaptureFixture(metadata: FrameMetadata(redactionReason: "capture-policy", displayID: 42))
        let result = await manager.enrichFrameMetadata(saved)
        XCTAssertEqual(result.metadata, saved.metadata)
        let calls = await late.calls
        XCTAssertEqual(calls, 0)
    }
}

private actor LateFocusMetadataProvider: FrontmostMetadataProviding {
    private(set) var calls = 0
    func getFrontmostAppInfo(includeBrowserURL: Bool) async -> FrameMetadata {
        calls += 1
        return FrameMetadata(appBundleID: "com.test.later", appName: "Later focus",
            windowName: "Unrelated later window", browserURL: "https://example.test/later", displayID: 99)
    }
}

func renderedCaptureFixture(metadata: FrameMetadata = .empty) throws -> CapturedFrame {
    let width = 64, height = 48
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
    context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 12, y: 8, width: 22, height: 16))
    return CapturedFrame(timestamp: Date(timeIntervalSince1970: 1_780_000_000),
        imageData: Data(bytes: try XCTUnwrap(context.data), count: width * height * 4),
        width: width, height: height, bytesPerRow: width * 4, metadata: metadata)
}
