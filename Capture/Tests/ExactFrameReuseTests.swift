import Foundation
import Shared
import XCTest
@testable import Capture

final class ExactFrameReuseTests: XCTestCase {
    private func frame(_ bytes: Data, width: Int = 512, metadata: FrameMetadata? = nil) -> CapturedFrame {
        .init(imageData: bytes, width: width, height: 512, bytesPerRow: 2048,
              metadata: metadata ?? .init(appBundleID: "com.test.invoice", displayID: 42,
                                         capturePolicySHA256: String(repeating: "a", count: 64)))
    }

    func testEveryPixelMattersIncludingOneUnsampledDigitPixel() throws {
        let bytes = Data(repeating: 200, count: 512 * 512 * 4)
        let original = frame(bytes)
        let equal = try XCTUnwrap(ExactFrameReuse.comparison(frame(bytes), previous: original, directTextEnabled: false))
        XCTAssertEqual(equal.method, .exactPixelsV1)
        XCTAssertEqual(equal.exactPixelSHA256?.count, 64)
        for offset in [0, 17, 1023, bytes.count - 1] {
            var changed = bytes; changed[offset] ^= 1
            XCTAssertNil(ExactFrameReuse.comparison(frame(changed), previous: original, directTextEnabled: false))
        }
    }

    func testGeometryPolicyContextAndInvalidBuffersCannotAlias() {
        let bytes = Data(repeating: 0, count: 512 * 512 * 4)
        let original = frame(bytes)
        XCTAssertNil(ExactFrameReuse.comparison(frame(bytes, width: 511), previous: original, directTextEnabled: false))
        XCTAssertNil(ExactFrameReuse.comparison(frame(Data()), previous: frame(Data()), directTextEnabled: false))
        XCTAssertNil(ExactFrameReuse.comparison(frame(bytes), previous: nil, directTextEnabled: false))
        for metadata in [FrameMetadata(appBundleID: "com.test.other", displayID: 42),
                         FrameMetadata(appBundleID: "com.test.invoice", displayID: 43),
                         FrameMetadata(appBundleID: "com.test.invoice", redactionReason: "masked", displayID: 42),
                         FrameMetadata(appBundleID: "com.test.invoice", displayID: 42, capturePolicySHA256: String(repeating: "b", count: 64))] {
            XCTAssertNil(ExactFrameReuse.comparison(frame(bytes, metadata: metadata), previous: original, directTextEnabled: false))
        }
    }

    func testLegacySimilarityReceiptDoesNotBecomeExact() throws {
        let bytes = Data(#"{"method":"captureAdaptiveV1","pixelThreshold":0.01,"directTextEnabled":false}"#.utf8)
        let old = try JSONDecoder().decode(CaptureSimilarityComparison.self, from: bytes)
        XCTAssertEqual(old.method, .captureAdaptiveV1)
        XCTAssertNil(old.exactPixelSHA256)
    }
}
