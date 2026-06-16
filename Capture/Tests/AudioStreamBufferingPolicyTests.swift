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
}
