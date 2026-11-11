import CoreGraphics
import CoreText
import Foundation
import Shared
import XCTest
@testable import Capture

/// Native CoreText rasters pass through the actual manager AsyncStream. These
/// tests exercise the validated producer boundary; AX ownership/visibility is
/// separately covered by the owned AppKit fixture in CaptureVisibleTextTests.
final class CaptureDirectTextDeduplicationTests: XCTestCase {
    private let pixels: any DeduplicationProtocol = FrameDeduplicator()

    func testSmallLowContrastDigitsAndStatusChangesSurvivePixelDeduplication() async throws {
        for (first, next) in [("Price 42", "Price 47"), ("Build PENDING", "Build FAILED")] {
            let original = try render([first])
            let changed = try render([next])
            XCTAssertNotEqual(original.imageData, changed.imageData)
            XCTAssertFalse(pixels.shouldKeepFrame(changed, comparedTo: original,
                threshold: CaptureConfig.defaultDeduplicationThreshold), "Verify this real raster is missed by pixels")
            let output = await forwardPair(original, changed, enabled: true)
            XCTAssertEqual(output.map(\.imageData), [original.imageData, changed.imageData])
            XCTAssertEqual(output.last?.metadata.captureText?.runs.first?.text, next)
        }
    }

    func testEquivalentRunMultisetDeduplicatesDespiteFreshIDsClocksAndTraversalOrder() async throws {
        let original = try render(["Price 42", "Build READY"])
        let another = try render(["Price 42", "Build READY"], reverseObservationOrder: true)
        XCTAssertEqual(original.imageData, another.imageData)
        XCTAssertNotEqual(original.metadata.pixelReceipt?.attemptID, another.metadata.pixelReceipt?.attemptID)
        XCTAssertNotEqual(original.metadata.captureText?.id, another.metadata.captureText?.id)
        XCTAssertNotEqual(original.metadata.captureText?.runs.map(\.id), another.metadata.captureText?.runs.map(\.id))
        let output = await forwardPair(original, another, enabled: true)
        XCTAssertEqual(output.count, 1, "Equivalent evidence must not retain every native read")
    }

    func testChangedRunGeometryAndElementLocalRangeRemainSignificant() async throws {
        let original = try render(["Status READY"])
        let moved = try render(["Status READY"], x: 143)
        XCTAssertFalse(pixels.shouldKeepFrame(moved, comparedTo: original,
            threshold: CaptureConfig.defaultDeduplicationThreshold))
        let movedOutput = await forwardPair(original, moved, enabled: true)
        XCTAssertEqual(movedOutput.count, 2)
        let scrolled = try render(["Status READY"], elementOffset: 900)
        XCTAssertEqual(original.imageData, scrolled.imageData)
        let rangeOutput = await forwardPair(original, scrolled, enabled: true)
        XCTAssertEqual(rangeOutput.count, 2)
    }

    func testCanonicalUnicodeEquivalenceDoesNotEraseAnExactCodeUnitChange() async throws {
        let first = "A\u{301}\u{327}", next = "A\u{327}\u{301}"
        XCTAssertEqual(first, next, "Swift String equality alone would collapse this change")
        XCTAssertEqual(first.utf16.count, next.utf16.count)
        XCTAssertNotEqual(Array(first.utf16), Array(next.utf16))
        let original = try render([first]), changed = try render([next])
        XCTAssertFalse(pixels.shouldKeepFrame(changed, comparedTo: original,
            threshold: CaptureConfig.defaultDeduplicationThreshold))
        let output = await forwardPair(original, changed, enabled: true)
        XCTAssertEqual(output.count, 2)
    }

    func testNewAndPartialValidatedTextIsPreservedWhileUnavailableTextUsesPixels() async throws {
        let original = try render(["Price 42"]), changed = try render(["Price 47"])
        let unavailable = replacingObservation(original, availability: .unavailable,
            reasons: [.budgetExceeded], runs: [], sourceContext: nil)
        let firstText = await forwardPair(unavailable, original, enabled: true)
        XCTAssertEqual(firstText.count, 2, "Previously unavailable text becoming proved is new evidence")
        let partial = replacingObservation(changed, availability: .partial, reasons: [.budgetExceeded])
        let partialOutput = await forwardPair(original, partial, enabled: true)
        XCTAssertEqual(partialOutput.count, 2)
        let unavailableChanged = replacingObservation(changed, availability: .unavailable,
            reasons: [.visibilityUnverified], runs: [], sourceContext: nil)
        let unavailableOutput = await forwardPair(original, unavailableChanged, enabled: true)
        XCTAssertEqual(unavailableOutput.count, 1)
    }

    func testDisabledOrInvalidDirectTextDoesNotOverrideTheExistingPixelPolicy() async throws {
        let original = try render(["Price 42"]), changed = try render(["Price 47"])
        let disabledOutput = await forwardPair(original, changed, enabled: false)
        XCTAssertEqual(disabledOutput.count, 1)
        let missingText = await forwardPair(original, replacingObservation(changed, omitText: true), enabled: true)
        XCTAssertEqual(missingText.count, 1)
        let observation = try XCTUnwrap(changed.metadata.captureText)
        let run = try XCTUnwrap(observation.runs.first)
        let invalidBounds = CaptureTextRun(id: run.id, elementOrdinal: run.elementOrdinal, text: run.text,
            elementUTF16Range: run.elementUTF16Range, boundsInFramePixels: CGRect(x: -1, y: 4, width: 20, height: 20),
            role: run.role, ancestors: run.ancestors)
        let cases = [
            replacingObservation(changed, attempt: UUID()),
            replacingObservation(changed, sourceContext: captureTestContext(window: 999)),
            replacingObservation(changed, runs: [invalidBounds]),
            replacingObservation(changed, availability: .available, reasons: [.budgetExceeded]),
            replacingObservation(changed, runs: []),
            replacingObservation(changed, runs: Array(repeating: run, count: 129)),
            replacingObservation(changed, omitPolicy: true),
            replacingObservation(changed, policyOverride: String(repeating: "g", count: 64)),
            replacingObservation(changed, policyOverride: "too-short"),
            replacingObservation(changed, appOverride: "com.test.other")
        ]
        for invalid in cases {
            XCTAssertThrowsError(try invalid.metadata.validatedCaptureText(frameWidth: invalid.width,
                frameHeight: invalid.height, timestamp: invalid.timestamp))
            let output = await forwardPair(original, invalid, enabled: true)
            XCTAssertEqual(output.count, 1, "Unvalidated producer claims cannot influence retention")
        }
    }

    func testLowerPixelSensitivityStillSuppressesPixelOnlyTextButValidatedTextCanOverrideIt() async throws {
        let original = try render(["1111111111111111"], gray: 0.1)
        let changed = try render(["8888888888888888"], gray: 0.1)
        XCTAssertTrue(pixels.shouldKeepFrame(changed, comparedTo: original,
            threshold: CaptureConfig.defaultDeduplicationThreshold), "Exercise the existing local high-contrast safeguard")
        XCTAssertFalse(pixels.shouldKeepFrame(changed, comparedTo: original, threshold: 0.9))
        let pixelOnly = await forwardPair(original, changed, enabled: false, threshold: 0.9)
        XCTAssertEqual(pixelOnly.count, 1)
        let withText = await forwardPair(original, changed, enabled: true, threshold: 0.9)
        XCTAssertEqual(withText.count, 2)
    }

    func testInterleavedDisplaysKeepIndependentLastRetainedTextAndInvalidateTogetherWithPixels() async throws {
        let manager = CaptureManager(config: CaptureConfig(captureVisibleTextEnabled: true))
        addTeardownBlock { await manager.stopFrameProcessing() }
        let session = await manager.startFrameProcessing { $0 }
        var iterator = session.output.makeAsyncIterator()
        let a = try render(["Price 42"], display: 42)
        let b = try render(["Price 47"], display: 43)
        session.input.yield(a); session.input.yield(b)
        let firstA = await iterator.next(), firstB = await iterator.next()
        XCTAssertEqual([firstA?.metadata.displayID, firstB?.metadata.displayID], [42, 43])
        session.input.yield(try render(["Price 47"], display: 42))
        session.input.yield(try render(["Price 47"], display: 43))
        session.input.finish()
        var remaining: [CapturedFrame] = []
        while let frame = await iterator.next() { remaining.append(frame) }
        await session.task.value
        XCTAssertEqual(remaining.map(\.metadata.displayID), [42])
        let stats = await manager.getStatistics()
        XCTAssertEqual(stats.totalFramesCaptured, 4)
        XCTAssertEqual(stats.framesDeduped, 1)
        await manager.stopFrameProcessing()

        let retry = await manager.startFrameProcessing { $0 }
        var next = retry.output.makeAsyncIterator()
        retry.input.yield(a)
        _ = await next.next()
        await manager.invalidateDeduplication(displayID: 42)
        retry.input.yield(a); retry.input.finish()
        let recovered = await next.next()
        XCTAssertEqual(recovered?.metadata.pixelReceipt, a.metadata.pixelReceipt,
                       "Invalidation must retry an unchanged proof as well as unchanged pixels")
        await retry.task.value
        await manager.stopFrameProcessing()
    }

    private func forwardPair(_ first: CapturedFrame, _ next: CapturedFrame, enabled: Bool,
                             threshold: Double = CaptureConfig.defaultDeduplicationThreshold) async -> [CapturedFrame] {
        let manager = CaptureManager(config: CaptureConfig(deduplicationThreshold: threshold,
                                                           captureVisibleTextEnabled: enabled))
        let session = await manager.startFrameProcessing { $0 }
        session.input.yield(first); session.input.yield(next); session.input.finish()
        var result: [CapturedFrame] = []
        for await frame in session.output { result.append(frame) }
        await session.task.value
        let stats = await manager.getStatistics()
        XCTAssertEqual(stats.totalFramesCaptured, 2, "No input may be hidden by the bounded producer queue")
        await manager.stopFrameProcessing()
        return result
    }

    private func render(_ text: [String], display: UInt32 = 42, x: CGFloat = 131,
                        gray: CGFloat = 0.48, elementOffset: Int = 0,
                        reverseObservationOrder: Bool = false) throws -> CapturedFrame {
        let width = 1280, height = 800
        let preStart = (Date(), ProcessInfo.processInfo.systemUptime)
        let font = CTFontCreateWithName("Helvetica" as CFString, 9, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1)]
        let lines = text.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes)) }
        let pre = CaptureReadInterval(startedAt: preStart.0, endedAt: Date(),
            startedUptime: preStart.1, endedUptime: ProcessInfo.processInfo.systemUptime)
        let pixelStart = (Date(), ProcessInfo.processInfo.systemUptime)
        let raster = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        raster.setFillColor(CGColor(gray: 0.5, alpha: 1))
        raster.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, line) in lines.enumerated() {
            raster.textPosition = CGPoint(x: x, y: CGFloat(640 - index * 28))
            CTLineDraw(line, raster)
        }
        let bytes = Data(bytes: try XCTUnwrap(raster.data), count: width * height * 4)
        let pixel = CaptureReadInterval(startedAt: pixelStart.0, endedAt: Date(),
            startedUptime: pixelStart.1, endedUptime: ProcessInfo.processInfo.systemUptime)
        let postStart = (Date(), ProcessInfo.processInfo.systemUptime)
        var runs = text.enumerated().map { index, value in
            CaptureTextRun(id: index, elementOrdinal: index + 1, text: value,
                elementUTF16Range: EvidenceUTF16Range(location: elementOffset, length: value.utf16.count),
                boundsInFramePixels: CGRect(x: x - 1, y: CGFloat(148 + index * 28), width: 220, height: 20),
                role: .staticText, ancestors: [.window, .group])
        }
        if reverseObservationOrder {
            runs = runs.reversed().enumerated().map { index, run in
                CaptureTextRun(id: index + 100, elementOrdinal: index + 40, text: run.text,
                    elementUTF16Range: run.elementUTF16Range, boundsInFramePixels: run.boundsInFramePixels,
                    role: run.role, ancestors: run.ancestors)
            }
        }
        let post = CaptureReadInterval(startedAt: postStart.0, endedAt: Date(),
            startedUptime: postStart.1, endedUptime: ProcessInfo.processInfo.systemUptime)
        let receipt = CapturePixelReceipt(attemptID: UUID(), interval: pixel)
        let context = captureTestContext(display: display)
        let observation = CaptureTextObservation(captureAttemptID: receipt.attemptID, sourceContext: context,
            preRead: pre, pixelRead: pixel, postRead: post, availability: .available,
            reasons: [], consistency: .sameWindowBracketed, runs: runs)
        _ = try observation.retainedTextEncoding(frameWidth: width, frameHeight: height, displayID: display,
            frameTimestamp: pixel.startedAt, frameMonotonicTime: pixel.startedUptime,
            pixelReceipt: receipt, sourceContext: context)
        let policy = try ScreenEvidenceAccessPolicy(config: CaptureConfig()).fingerprintSHA256()
        let metadata = FrameMetadata(appBundleID: context.appBundleID, displayID: display, captureContext: context,
            captureMonotonicTime: pixel.startedUptime, capturePolicySHA256: policy,
            pixelReceipt: receipt, captureText: observation)
        _ = try metadata.validatedCaptureText(frameWidth: width, frameHeight: height, timestamp: pixel.startedAt)
        return CapturedFrame(timestamp: pixel.startedAt, imageData: bytes, width: width, height: height,
            bytesPerRow: width * 4, metadata: metadata)
    }

    /// Mutates only the controlled producer's claim, retaining its actual raster
    /// and pixel receipt so validation failures exercise production admission.
    private func replacingObservation(_ frame: CapturedFrame, attempt: UUID? = nil,
        availability: CaptureTextAvailability? = nil, reasons: [CaptureTextReason]? = nil,
        runs: [CaptureTextRun]? = nil, sourceContext: ActivityContext? = nil,
        omitText: Bool = false, omitPolicy: Bool = false, policyOverride: String? = nil,
        appOverride: String? = nil) -> CapturedFrame {
        let original = frame.metadata.captureText!
        let availability = availability ?? original.availability
        let observation = CaptureTextObservation(captureAttemptID: attempt ?? original.captureAttemptID,
            sourceContext: availability == .unavailable ? nil : (sourceContext ?? original.sourceContext),
            preRead: original.preRead, pixelRead: original.pixelRead, postRead: original.postRead,
            availability: availability, reasons: reasons ?? original.reasons,
            consistency: availability == .unavailable ? nil : original.consistency, runs: runs ?? original.runs)
        return CapturedFrame(timestamp: frame.timestamp, imageData: frame.imageData, width: frame.width,
            height: frame.height, bytesPerRow: frame.bytesPerRow,
            metadata: FrameMetadata(appBundleID: appOverride ?? frame.metadata.appBundleID,
                displayID: frame.metadata.displayID, captureContext: frame.metadata.captureContext,
                captureMonotonicTime: frame.metadata.captureMonotonicTime,
                capturePolicySHA256: omitPolicy ? nil : (policyOverride ?? frame.metadata.capturePolicySHA256),
                pixelReceipt: frame.metadata.pixelReceipt, captureText: omitText ? nil : observation))
    }
}
