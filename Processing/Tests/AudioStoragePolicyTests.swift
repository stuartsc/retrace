import XCTest
@testable import Processing

final class AudioStoragePolicyTests: XCTestCase {
    func testCanonicalTranscriptPathUsesRawBatch() {
        let batchPath = "audio/2026/08/26/batch_123_microphone_test.m4a"

        XCTAssertEqual(
            AudioStoragePolicy.canonicalTranscriptPath(batchAudioPath: batchPath),
            batchPath
        )
    }

    func testCanonicalTranscriptPathRejectsMissingBatch() {
        XCTAssertNil(AudioStoragePolicy.canonicalTranscriptPath(batchAudioPath: nil))
        XCTAssertNil(AudioStoragePolicy.canonicalTranscriptPath(batchAudioPath: ""))
        XCTAssertNil(AudioStoragePolicy.canonicalTranscriptPath(batchAudioPath: "   "))
    }
}
