import XCTest
import Shared
@testable import App

final class AudioPipelineBufferPolicyTests: XCTestCase {
    func testCancelledStartupDrainsPublishedAudioBeforeRecordingBecameRunning() async throws {
        try await assertCancelledStartupDrains(cancelDuringNativeStart: false)
    }

    func testCancelledNativeStartupStillInstallsAndDrainsItsLateAudioConsumer() async throws {
        try await assertCancelledStartupDrains(cancelDuringNativeStart: true)
    }

    private func assertCancelledStartupDrains(cancelDuringNativeStart: Bool) async throws {
        let lifecycle = RecordingLifecycle()
        let source = AsyncStream<CapturedAudio>.makeStream()
        let heldConsumer = AsyncStream<Void>.makeStream()
        let pendingPolicy = AsyncStream<Void>.makeStream()
        let nativeStart = CapturedNativeStartupGate()
        let nativeEntered = cancelDuringNativeStart ? expectation(description: "Native startup held after yielding audio") : nil
        let entered = expectation(description: "Native startup published captured audio")
        let draining = expectation(description: "Cancelled startup entered joined rollback")
        let result = CapturedBridgeResult()
        let finished = expectation(description: "Startup cannot return before captured PCM drains")
        finished.isInverted = true
        let start = Task {
            defer { finished.fulfill() }
            try await lifecycle.start(operation: {
                for byte in UInt8(1)...3 {
                    source.continuation.yield(CapturedAudio(timestamp: Date(), audioData: Data([byte, 0]),
                        duration: 1.0 / 16_000, source: .microphone))
                }
                if cancelDuringNativeStart {
                    nativeEntered?.fulfill()
                    // Native startup can finish after its caller was cancelled.
                    await nativeStart.hold()
                }
                let consumer = Task {
                    var first = true
                    for await audio in source.stream {
                        if first {
                            first = false; entered.fulfill()
                            for await _ in heldConsumer.stream { break }
                        }
                        await result.append(audio.audioData)
                    }
                }
                await result.install(consumer)
                // Represents policy activation after the source consumer is
                // owned, but before App marks the full pipeline running.
                for await _ in pendingPolicy.stream { }
                try Task.checkCancellation()
            }, rollback: {
                let consumer = await result.consumer
                _ = await RecordingLifecycle.stopCapturedAudio(stopSource: {
                    source.continuation.finish()
                }, finishInput: {
                    draining.fulfill()
                    await RecordingLifecycle.finishCapturedStreams(capture: nil, audio: consumer,
                        finishAudioInput: { await result.markInferenceStopped() })
                })
            })
        }
        if cancelDuringNativeStart {
            await fulfillment(of: [try XCTUnwrap(nativeEntered)], timeout: 2)
            start.cancel()
            await nativeStart.release()
            await fulfillment(of: [entered], timeout: 2)
        } else {
            await fulfillment(of: [entered], timeout: 2)
            start.cancel()
        }
        await fulfillment(of: [draining], timeout: 2)
        await fulfillment(of: [finished], timeout: 0.05)
        heldConsumer.continuation.yield(()); heldConsumer.continuation.finish()
        do { try await start.value; XCTFail("Cancelled startup must report cancellation") }
        catch is CancellationError { }
        let bytes = await result.bytes
        let stopped = await result.inferenceStopped
        XCTAssertEqual(bytes, Data([1, 0, 2, 0, 3, 0]))
        XCTAssertTrue(stopped)
    }

    func testNativeStopErrorStillDrainsFinishedSourceAndReportsErrorAfterJoining() async {
        let source = AsyncStream<CapturedAudio>.makeStream()
        let bridge = AudioPipelineBufferPolicy.makeStream(limit: 4)
        let held = AsyncStream<Void>.makeStream()
        let entered = expectation(description: "First captured sample held before bridge")
        let result = CapturedBridgeResult()
        let forwarder = Task {
            var first = true
            for await audio in source.stream {
                if first {
                    first = false; entered.fulfill()
                    for await _ in held.stream { break }
                }
                if Task.isCancelled { break }
                bridge.continuation.yield(audio)
            }
            bridge.continuation.finish()
        }
        let consumer = Task {
            for await audio in bridge.stream { await result.append(audio.audioData) }
            await forwarder.value
        }
        for byte in UInt8(1)...3 {
            source.continuation.yield(CapturedAudio(timestamp: Date(), audioData: Data([byte, 0]),
                duration: 1.0 / 16_000, source: .microphone))
        }
        await fulfillment(of: [entered], timeout: 2)
        let returned = expectation(description: "Native stop error waits for queued PCM")
        returned.isInverted = true
        let stopped = Task {
            let error = await RecordingLifecycle.stopCapturedAudio(stopSource: {
                source.continuation.finish()
                throw CapturedSourceStopError.nativeStop
            }, finishInput: {
                await RecordingLifecycle.finishCapturedStreams(capture: nil, audio: consumer,
                    finishAudioInput: { await result.markInferenceStopped() })
            })
            returned.fulfill()
            return error
        }
        await fulfillment(of: [returned], timeout: 0.05)
        held.continuation.yield(()); held.continuation.finish()
        let error = await stopped.value
        XCTAssertEqual(error as? CapturedSourceStopError, .nativeStop)
        let values = await result.bytes
        let inferenceStopped = await result.inferenceStopped
        XCTAssertEqual(values, Data([1, 0, 2, 0, 3, 0]))
        XCTAssertTrue(inferenceStopped)
    }

    func testFinishedCaptureBridgeDrainsQueuedSamplesBeforeNormalStopReturns() async {
        let source = AsyncStream<CapturedAudio>.makeStream()
        let bridge = AudioPipelineBufferPolicy.makeStream(limit: 4)
        let held = AsyncStream<Void>.makeStream()
        let entered = expectation(description: "Captured sample waiting at bridge")
        let result = CapturedBridgeResult()
        let forwarder = Task {
            var first = true
            for await audio in source.stream {
                if first {
                    first = false; entered.fulfill()
                    for await _ in held.stream { break }
                }
                if Task.isCancelled { break }
                bridge.continuation.yield(audio)
            }
            bridge.continuation.finish()
        }
        let consumer = Task {
            for await audio in bridge.stream { await result.append(audio.audioData) }
            await forwarder.value
        }
        for byte in UInt8(1)...3 {
            source.continuation.yield(CapturedAudio(timestamp: Date(), audioData: Data([byte, 0]),
                duration: 1.0 / 16_000, source: .microphone))
        }
        source.continuation.finish()
        await fulfillment(of: [entered], timeout: 2)
        let stopped = Task {
            await RecordingLifecycle.finishCapturedStreams(capture: nil, audio: consumer,
                finishAudioInput: { await result.markInferenceStopped() })
        }
        held.continuation.yield(()); held.continuation.finish()
        await stopped.value
        let values = await result.bytes
        XCTAssertEqual(values, Data([1, 0, 2, 0, 3, 0]))
        let inferenceStopped = await result.inferenceStopped
        XCTAssertTrue(inferenceStopped)
    }
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

        XCTAssertTrue(plan.stopScreenCapture, "Owned cleanup must finish the screen output before draining it")
        XCTAssertTrue(plan.stopAudioCapture)
        XCTAssertTrue(plan.cancelPipelineTasks)
        XCTAssertTrue(plan.cancelRefinementLoop)
        XCTAssertTrue(plan.persistStoppedRecordingState)
    }
}

private enum CapturedSourceStopError: Error, Equatable { case nativeStop }

private actor CapturedNativeStartupGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(); continuation = nil
    }
}

private actor CapturedBridgeResult {
    var bytes = Data()
    var inferenceStopped = false
    var consumer: Task<Void, Never>?
    func install(_ task: Task<Void, Never>) { consumer = task }
    func append(_ data: Data) { bytes.append(data) }
    func markInferenceStopped() { inferenceStopped = true }
}
