import CoreGraphics
import XCTest
import Shared
@testable import Capture

/// Render deterministic BGRA images through CoreGraphics and exercise the production
/// pixel-sampling deduplicator through its protocol. This is not the unused dHash helper.
final class DeduplicationTests: XCTestCase {
    private let deduplicator: any DeduplicationProtocol = FrameDeduplicator()

    func testComputeHash_SameImage_ProducesSameHash() throws {
        let first = try renderedFrame(changedRect: CGRect(x: 0, y: 0, width: 25, height: 100))
        let second = try renderedFrame(changedRect: CGRect(x: 0, y: 0, width: 25, height: 100))
        XCTAssertEqual(deduplicator.computeHash(for: first), deduplicator.computeHash(for: second))
    }

    func testComputeHash_DifferentBrightness_ProducesDifferentHash() throws {
        let dark = try renderedFrame(background: 0)
        let light = try renderedFrame(background: 255)
        XCTAssertNotEqual(deduplicator.computeHash(for: dark), deduplicator.computeHash(for: light))
    }

    func testComputeSimilarity_IdenticalFrames_ReturnsOne() throws {
        let first = try renderedFrame(changedRect: CGRect(x: 0, y: 0, width: 25, height: 100))
        let second = try renderedFrame(changedRect: CGRect(x: 0, y: 0, width: 25, height: 100))
        XCTAssertEqual(deduplicator.computeSimilarity(first, second), 1)
    }

    func testComputeSimilarity_CompletelyDifferent_ReturnsZero() throws {
        let dark = try renderedFrame(background: 0)
        let light = try renderedFrame(background: 255)
        XCTAssertEqual(deduplicator.computeSimilarity(dark, light), 0)
    }

    func testComputeSimilarity_SlightlyDifferent_ReturnsOneWithinColorTolerance() throws {
        let first = try renderedFrame(background: 100)
        let second = try renderedFrame(background: 112)
        XCTAssertEqual(deduplicator.computeSimilarity(first, second), 1,
                       "RGB differences below 13 are treated as matching pixels")
    }

    func testComputeSimilarity_ColorDifferenceAtToleranceBoundaryCountsAsChanged() throws {
        let first = try renderedFrame(background: 100)
        let second = try renderedFrame(background: 113)
        XCTAssertEqual(deduplicator.computeSimilarity(first, second), 0)
    }

    func testComputeSimilarity_DifferentSizes_ReturnsZero() throws {
        let first = try renderedFrame(width: 100, height: 100)
        let second = try renderedFrame(width: 200, height: 200)
        XCTAssertEqual(deduplicator.computeSimilarity(first, second), 0)
    }

    func testShouldKeepFrame_NoReference_ReturnsTrue() throws {
        XCTAssertTrue(deduplicator.shouldKeepFrame(
            try renderedFrame(), comparedTo: nil, threshold: CaptureConfig.defaultDeduplicationThreshold
        ))
    }

    func testShouldKeepFrame_IdenticalFrames_DefaultThreshold_ReturnsFalse() throws {
        let frame = try renderedFrame()
        XCTAssertFalse(deduplicator.shouldKeepFrame(
            frame, comparedTo: frame, threshold: CaptureConfig.defaultDeduplicationThreshold
        ))
    }

    func testShouldKeepFrame_DifferentFrames_LowThreshold_ReturnsTrue() throws {
        let dark = try renderedFrame(background: 0)
        let light = try renderedFrame(background: 255)
        XCTAssertTrue(deduplicator.shouldKeepFrame(light, comparedTo: dark, threshold: 0.02))
    }

    func testShouldKeepFrame_DifferentSizes_ReturnsTrue() throws {
        let first = try renderedFrame(width: 100, height: 100)
        let second = try renderedFrame(width: 200, height: 200)
        XCTAssertTrue(deduplicator.shouldKeepFrame(second, comparedTo: first, threshold: 0.98))
    }

    func testThresholdSemantics_HigherThresholdKeepsSmallerChanges() throws {
        let reference = try renderedFrame()
        // A one-pixel-wide column changes exactly 1% of this real 100 x 100 bitmap.
        let edited = try renderedFrame(changedRect: CGRect(x: 0, y: 0, width: 1, height: 100))
        XCTAssertEqual(deduplicator.computeSimilarity(reference, edited), 0.99, accuracy: 0.000001)
        XCTAssertFalse(deduplicator.shouldKeepFrame(edited, comparedTo: reference, threshold: 0.98),
                       "Lower sensitivity discards the small edit")
        XCTAssertTrue(deduplicator.shouldKeepFrame(edited, comparedTo: reference, threshold: 0.995),
                      "Higher sensitivity records the same edit")
    }

    func testThresholdSemantics_KeepsSimilarityExactlyAtThreshold() throws {
        let reference = try renderedFrame()
        let edited = try renderedFrame(changedRect: CGRect(x: 0, y: 0, width: 25, height: 100))
        XCTAssertEqual(deduplicator.computeSimilarity(reference, edited), 0.75)
        XCTAssertFalse(deduplicator.shouldKeepFrame(edited, comparedTo: reference, threshold: 0.749))
        XCTAssertTrue(deduplicator.shouldKeepFrame(edited, comparedTo: reference, threshold: 0.75))
    }

    func testThresholdSemantics_OneDisablesDeduplication() throws {
        let frame = try renderedFrame()
        XCTAssertTrue(deduplicator.shouldKeepFrame(frame, comparedTo: frame, threshold: 1),
                      "The settings slider's 100% position records every frame")
    }

    func testHashPerformance() throws {
        let frame = try renderedFrame(width: 1920, height: 1080, background: 128)
        measure { _ = deduplicator.computeHash(for: frame) }
    }

    func testSimilarityPerformance() throws {
        let first = try renderedFrame(width: 1920, height: 1080, background: 128)
        let second = try renderedFrame(
            width: 1920, height: 1080, background: 128,
            changedRect: CGRect(x: 0, y: 0, width: 480, height: 1080)
        )
        measure { _ = deduplicator.computeSimilarity(first, second) }
    }

    private func renderedFrame(
        width: Int = 100, height: Int = 100, background: UInt8 = 0,
        changedRect: CGRect? = nil
    ) throws -> CapturedFrame {
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ))
            context.setShouldAntialias(false)
            let brightness = CGFloat(background) / 255
            context.setFillColor(red: brightness, green: brightness, blue: brightness, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let changedRect {
                context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                context.fill(changedRect)
            }
        }
        return CapturedFrame(
            timestamp: Date(timeIntervalSince1970: 0), imageData: pixels,
            width: width, height: height, bytesPerRow: bytesPerRow, metadata: .empty
        )
    }
}
