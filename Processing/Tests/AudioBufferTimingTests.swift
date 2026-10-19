import XCTest
import Shared
@testable import Processing

final class AudioBufferTimingTests: XCTestCase {
    private func sample(start: Double, seconds: Int) -> CapturedAudio {
        .init(timestamp: Date(timeIntervalSince1970: start), audioData: Data(count: seconds * 32_000),
              duration: Double(seconds), source: .microphone)
    }

    func testBatchEndIncludesTheLastCapturedPacketAndOverlapKeepsItsSampleOrigin() async throws {
        let buffer = AudioBufferManager(maxBufferDuration: 6)
        let firstValue = await buffer.addSample(sample(start: 100, seconds: 6))
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.endTimestamp, Date(timeIntervalSince1970: 106))
        let secondValue = await buffer.addSample(sample(start: 106, seconds: 1))
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(second.startTimestamp, Date(timeIntervalSince1970: 101))
        XCTAssertEqual(second.endTimestamp, Date(timeIntervalSince1970: 107))
        XCTAssertEqual(second.duration, 6)
    }

    func testStopDoesNotPersistAnOverlapOnlyCopyAndFlushConsumesPartialTailOnce() async throws {
        let complete = AudioBufferManager(maxBufferDuration: 6)
        _ = await complete.addSample(sample(start: 100, seconds: 6))
        let overlapOnly = await complete.flush()
        XCTAssertTrue(overlapOnly.isEmpty, "Already saved overlap is not a new recording")
        let partial = AudioBufferManager(maxBufferDuration: 15)
        _ = await partial.addSample(sample(start: 200, seconds: 8))
        let first = await partial.flush()
        let second = await partial.flush()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.endTimestamp, Date(timeIntervalSince1970: 208))
        XCTAssertTrue(second.isEmpty, "Joined shutdown may be retried without writing the tail twice")
    }
}
