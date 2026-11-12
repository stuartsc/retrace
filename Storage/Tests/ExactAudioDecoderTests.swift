import Foundation
import Shared
import XCTest
@testable import Storage

final class ExactAudioDecoderTests: XCTestCase {
    func testNativeAACPreservesNonPacketAlignedSampleCountAndRejectsIncorrectIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let count = 32_003
        let samples = (0..<count).map { Int16(sin(Double($0) * 2 * .pi * 440 / 16_000) * 10_000) }
        let pcm = samples.withUnsafeBytes { Data($0) }
        let saved = try await AudioSegmentWriter(storageRoot: root).writeFullBatch(audioData: pcm,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000), source: .microphone)
        let aac = try Data(contentsOf: root.appendingPathComponent(saved.filePath))
        let decoded = try ExactAudioDecoder.decode(aac: aac, expectedFrames: Int64(count))
        XCTAssertEqual(decoded.count, pcm.count)
        let energy = decoded.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).reduce(0.0) { $0 + pow(Double($1), 2) }
        }
        XCTAssertGreaterThan(energy / Double(count), 10_000_000)
        XCTAssertThrowsError(try ExactAudioDecoder.decode(aac: aac, expectedFrames: Int64(count + 1))) {
            XCTAssertEqual($0 as? ExactAudioDecodeError, .frameCountMismatch)
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ExactAudioDecoder.decode(aac: aac, expectedFrames: Int64(count))
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled decode must not open native resources") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testInvalidContainersAndUnboundedRequestsFailClosed() {
        XCTAssertThrowsError(try ExactAudioDecoder.decode(aac: Data(), expectedFrames: 1))
        XCTAssertThrowsError(try ExactAudioDecoder.decode(aac: Data("not AAC".utf8), expectedFrames: 1))
        XCTAssertThrowsError(try ExactAudioDecoder.decode(aac: Data([0]), expectedFrames: 1_920_001))
    }
}
