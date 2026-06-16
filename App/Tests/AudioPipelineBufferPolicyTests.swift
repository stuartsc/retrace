import XCTest
import Shared
@testable import App

final class AudioPipelineBufferPolicyTests: XCTestCase {
    func testAudioPipelineBridgeKeepsNewestSamplesWhenProcessingFallsBehind() async {
        let (stream, continuation) = AudioPipelineBufferPolicy.makeStream(limit: 2)

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

    func testUnexpectedScreenCaptureStopStillTearsDownAudioAndBackgroundWork() {
        let plan = PipelineStopTeardownPolicy.plan(
            for: .unexpectedScreenCaptureStop,
            persistState: true
        )

        XCTAssertFalse(plan.stopScreenCapture)
        XCTAssertTrue(plan.stopAudioCapture)
        XCTAssertTrue(plan.cancelPipelineTasks)
        XCTAssertTrue(plan.cancelRefinementLoop)
        XCTAssertTrue(plan.persistStoppedRecordingState)
    }
}
