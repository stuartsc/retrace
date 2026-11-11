import XCTest
import Shared
@testable import Capture

final class AudioStreamBufferingPolicyTests: XCTestCase {
    func testCapturedAudioStreamKeepsNewestSamplesWhenConsumerFallsBehind() async {
        let (stream, continuation) = AudioStreamBufferingPolicy.makeStream(limit: 2)

        for index in 0..<5 {
            continuation.yield(CapturedAudio(
                timestamp: Date(timeIntervalSince1970: Double(index)),
                audioData: Data([UInt8(index)]),
                duration: Double(index),
                source: .microphone
            ))
        }
        continuation.finish()

        var receivedDurations: [TimeInterval] = []
        for await audio in stream {
            receivedDurations.append(audio.duration)
        }

        XCTAssertEqual(receivedDurations, [3, 4])
    }

    func testSystemAudioCaptureUsesSerializedSampleQueueInsteadOfPerSampleTasks() {
        XCTAssertEqual(SystemAudioCaptureConcurrencyPolicy.sampleHandlerQueueLabel, "io.retrace.system-audio-capture")
        XCTAssertFalse(SystemAudioCaptureConcurrencyPolicy.usesPerSampleTasks)
    }

    func testIdleManagerStopFinishesEveryPreacquiredCombinedStream() async throws {
        let manager = AudioCaptureManager()
        // No device start, permissions, detector polling or captured content.
        for generation in 0..<2 {
            let stream = await manager.audioStream
            let finished = expectation(description: "idle combined stream \(generation) closes")
            let reader = Task {
                for await _ in stream { XCTFail("An unstarted capture cannot produce samples") }
                finished.fulfill()
            }
            try await manager.stopCapture()
            await fulfillment(of: [finished], timeout: 1)
            reader.cancel()
            await reader.value
        }
        let running = await manager.isCapturing
        XCTAssertFalse(running)
    }
}
