import AVFoundation
import CoreMedia
import Foundation
import Shared
import XCTest
@testable import Capture

final class AudioFormatConverterTests: XCTestCase {
    func testDownsamplingRejectsAboveNyquistAudio() throws {
        for rate in [44_100.0, 48_000.0] {
            let input = try Self.tone(sampleRate: rate, frequency: 12_000, frames: Int(rate))
            let converter = AudioFormatConverter()
            var data = try converter.convert(buffer: input)
            data.append(try converter.finish())
            XCTAssertEqual(data.count, 32_000)
            XCTAssertLessThan(Self.rms(data, trimmingFrames: 160), 0.002,
                              "12 kHz must not alias into 16 kHz speech input")
        }
    }

    func testChunkedResamplingMatchesContinuousSignalAndDuration() throws {
        for rate in [44_100.0, 48_000.0] {
            let frames = Int(rate) * 2
            let whole = try Self.tone(sampleRate: rate, frequency: 997, frames: frames)
            let reference = AudioFormatConverter()
            var expected = try reference.convert(buffer: whole)
            expected.append(try reference.finish())

            let chunked = AudioFormatConverter()
            var actual = Data()
            var offset = 0
            // Deliberately not divisible by either resampling ratio.
            while offset < frames {
                let count = min(257, frames - offset)
                let input = try Self.tone(sampleRate: rate, frequency: 997, frames: count, offset: offset)
                actual.append(try chunked.convert(buffer: input))
                offset += count
            }
            actual.append(try chunked.finish())
            XCTAssertEqual(actual.count, 64_000)
            XCTAssertEqual(actual.count, expected.count)
            XCTAssertLessThan(Self.meanAbsoluteDifference(actual, expected), 0.0001)
            XCTAssertTrue(try chunked.finish().isEmpty)
        }
    }

    func testCMSampleBufferHandlesPlanarAndInterleavedStereo() throws {
        for commonFormat in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16] {
            var results: [Data] = []
            for interleaved in [false, true] {
                let input = try Self.tone(
                    sampleRate: 48_000, frequency: 880, frames: 48_000,
                    channels: 2, interleaved: interleaved, commonFormat: commonFormat, rightChannelOnly: true
                )
                let sample = try Self.sampleBuffer(input)
                let converter = AudioFormatConverter()
                var data = try converter.convert(sampleBuffer: sample)
                data.append(try converter.finish())
                XCTAssertEqual(data.count, 32_000)
                XCTAssertGreaterThan(Self.rms(data, trimmingFrames: 160), 0.10,
                                     "Speech in the second channel must reach mono output")
                results.append(data)
            }
            XCTAssertLessThan(Self.meanAbsoluteDifference(results[0], results[1]), 0.0001)
        }
    }

    func testLegacyProtocolUsesNativeFilteringAndRejectsTruncatedSamples() throws {
        let input = try Self.tone(sampleRate: 48_000, frequency: 12_000, frames: 48_000)
        let pointer = try XCTUnwrap(input.floatChannelData?[0])
        let converter = AudioFormatConverter()
        let protocolConverter: any AudioFormatConverterProtocol = converter
        var result = try protocolConverter.convertToStandardFormat(
            inputData: pointer, inputLength: 48_000 * 4, inputSampleRate: 48_000,
            inputChannels: 1, inputFormat: .float32
        )
        result.append(try converter.finish())
        XCTAssertLessThan(Self.rms(result, trimmingFrames: 160), 0.002)
        XCTAssertThrowsError(try protocolConverter.convertToStandardFormat(
            inputData: pointer, inputLength: 3, inputSampleRate: 48_000,
            inputChannels: 1, inputFormat: .int16
        ))
    }

    func testResetDiscardsPreviousStreamAndFormatChangePreservesCompletedAudio() throws {
        let converter = AudioFormatConverter()
        _ = try converter.convert(buffer: Self.tone(sampleRate: 44_100, frequency: 440, frames: 257))
        converter.reset()
        var data = try converter.convert(buffer: Self.tone(sampleRate: 48_000, frequency: 880, frames: 48_000))
        // Changing source format drains prior filter samples before the new format begins.
        data.append(try converter.convert(buffer: Self.tone(sampleRate: 44_100, frequency: 880, frames: 44_100)))
        data.append(try converter.finish())
        XCTAssertEqual(data.count, 64_000)
        XCTAssertGreaterThan(Self.rms(data, trimmingFrames: 160), 0.25)
    }

    func testSourceShutdownDrainsResamplerTailThroughDelayedForwarder() async throws {
        let converter = AudioFormatConverter()
        let input = try Self.tone(sampleRate: 44_100, frequency: 440, frames: 44_100)
        let head = try converter.convert(buffer: input)
        let tail = try converter.finish()
        XCTAssertFalse(tail.isEmpty, "The native filter has pending samples to preserve at shutdown")
        let (source, sourceContinuation) = AudioStreamBufferingPolicy.makeStream(limit: 10)
        let (combined, combinedContinuation) = AudioStreamBufferingPolicy.makeStream(limit: 10)
        let gate = AudioConversionForwardingGate()
        let forwarding = AudioStreamForwarding.start(source) { audio in
            await gate.wait()
            combinedContinuation.yield(audio)
        }
        for data in [head, tail] where !data.isEmpty {
            sourceContinuation.yield(CapturedAudio(
                timestamp: Date(timeIntervalSince1970: 0), audioData: data,
                duration: Double(data.count) / 32_000, source: .microphone
            ))
        }
        sourceContinuation.finish()
        let shutdown = Task {
            await AudioStreamForwarding.drain([forwarding])
            combinedContinuation.finish()
        }
        await gate.release()
        await shutdown.value
        var received = Data()
        for await audio in combined { received.append(audio.audioData) }
        XCTAssertEqual(received.count, 32_000)
        XCTAssertEqual(received, head + tail)
    }

    func testStoppingUnstartedMicrophoneClosesPreacquiredStream() async {
        let microphone = MicrophoneAudioCapture(config: .default)
        let source = await microphone.audioStream
        let finished = expectation(description: "Unstarted source stream finishes")
        let consumer = Task {
            for await _ in source {}
            finished.fulfill()
        }
        await microphone.stopCapture()
        await fulfillment(of: [finished], timeout: 1)
        consumer.cancel()
    }

    func testFailedMicrophoneStartupThrowsAndClosesStreamWithoutRecording() async {
        let microphone = MicrophoneAudioCapture(config: .default)
        let source = await microphone.audioStream
        let finished = expectation(description: "Failed startup stream finishes")
        let consumer = Task {
            for await _ in source {}
            finished.fulfill()
        }
        // An actual AVCaptureSession has never been started: exercise completion of a
        // failed start without requesting permission, opening a device, or recording.
        do {
            try await microphone.finishStartingCapture()
            XCTFail("A session that is not running must not report successful startup")
        } catch AudioCaptureError.captureSessionFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected startup failure: \(error)")
        }
        await fulfillment(of: [finished], timeout: 1)
        consumer.cancel()
    }

    func testDelegatesResetPendingTimeAndFilterAfterInvalidPCM() async throws {
        let priming = try Self.sampleBuffer(Self.tone(sampleRate: 48_000, frequency: 440, frames: 1))
        let invalid = try Self.sampleBuffer(
            Self.tone(sampleRate: 48_000, frequency: 440, frames: 1), ready: false
        )
        let valid = try Self.sampleBuffer(Self.tone(sampleRate: 48_000, frequency: 880, frames: 48_000))
        for source in [AudioSource.microphone, .system] {
            let (stream, continuation) = AudioStreamBufferingPolicy.makeStream(limit: 10)
            let converter = AudioFormatConverter()
            let microphone = MicAudioDelegate(continuation: continuation, formatConverter: converter)
            let system = SystemAudioStreamOutput(
                continuation: continuation, formatConverter: converter, muteState: SystemAudioMuteState()
            )
            let receive: (CMSampleBuffer, Date) -> Void = source == .microphone
                ? { microphone.receive($0, receivedAt: $1) } : { system.receive($0, receivedAt: $1) }
            receive(priming, Date(timeIntervalSince1970: 10))
            receive(invalid, Date(timeIntervalSince1970: 11))
            receive(valid, Date(timeIntervalSince1970: 1_000))
            if source == .microphone { microphone.finish() } else { system.finish() }
            continuation.finish()
            var received: [CapturedAudio] = []
            for await audio in stream { received.append(audio) }
            XCTAssertEqual(try XCTUnwrap(received.first).timestamp, Date(timeIntervalSince1970: 1_000))
            let reference = AudioFormatConverter()
            var expected = try reference.convert(sampleBuffer: valid)
            expected.append(try reference.finish())
            XCTAssertEqual(received.reduce(into: Data()) { $0.append($1.audioData) }, expected)
        }
    }

    func testDelegatesPreservePendingTimeWhileNativeConverterPrimes() async throws {
        let priming = try Self.sampleBuffer(Self.tone(sampleRate: 48_000, frequency: 440, frames: 1))
        XCTAssertTrue(try AudioFormatConverter().convert(sampleBuffer: priming).isEmpty)
        let remainder = try Self.sampleBuffer(
            Self.tone(sampleRate: 48_000, frequency: 440, frames: 47_999, offset: 1)
        )
        for source in [AudioSource.microphone, .system] {
            let (stream, continuation) = AudioStreamBufferingPolicy.makeStream(limit: 10)
            let converter = AudioFormatConverter()
            let microphone = MicAudioDelegate(continuation: continuation, formatConverter: converter)
            let system = SystemAudioStreamOutput(
                continuation: continuation, formatConverter: converter, muteState: SystemAudioMuteState()
            )
            let receive: (CMSampleBuffer, Date) -> Void = source == .microphone
                ? { microphone.receive($0, receivedAt: $1) } : { system.receive($0, receivedAt: $1) }
            receive(priming, Date(timeIntervalSince1970: 10))
            receive(remainder, Date(timeIntervalSince1970: 11))
            if source == .microphone { microphone.finish() } else { system.finish() }
            continuation.finish()
            var received: [CapturedAudio] = []
            for await audio in stream { received.append(audio) }
            XCTAssertEqual(try XCTUnwrap(received.first).timestamp, Date(timeIntervalSince1970: 10))
            XCTAssertEqual(received.reduce(0) { $0 + $1.audioData.count }, 32_000)
        }
    }

    func testStoppingUnstartedSystemAudioClosesPreacquiredStream() async throws {
        let system = SystemAudioCapture(config: .default)
        let source = await system.audioStream
        let finished = expectation(description: "Unstarted system source stream finishes")
        let consumer = Task {
            for await _ in source {}
            finished.fulfill()
        }
        try await system.stopCapture()
        await fulfillment(of: [finished], timeout: 1)
        consumer.cancel()
    }

    private static func tone(
        sampleRate: Double, frequency: Double, frames: Int, offset: Int = 0,
        channels: Int = 1, interleaved: Bool = false,
        commonFormat: AVAudioCommonFormat = .pcmFormatFloat32, rightChannelOnly: Bool = false
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: commonFormat, sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels), interleaved: interleaved
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            for channel in 0..<channels {
                let sample = rightChannelOnly && channel == 0 ? 0 :
                    0.4 * sin(2 * .pi * frequency * Double(offset + frame) / sampleRate)
                let plane = interleaved ? 0 : channel
                let index = interleaved ? frame * channels + channel : frame
                if commonFormat == .pcmFormatFloat32 {
                    buffer.floatChannelData![plane][index] = Float(sample)
                } else {
                    buffer.int16ChannelData![plane][index] = Int16(sample * 32_767)
                }
            }
        }
        return buffer
    }

    private static func sampleBuffer(_ input: AVAudioPCMBuffer, ready: Bool = true) throws -> CMSampleBuffer {
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(input.format.sampleRate)),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid
        )
        let creation = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: input.format.formatDescription, sampleCount: Int(input.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
        )
        XCTAssertEqual(creation, noErr)
        let buffer = try XCTUnwrap(sample)
        guard ready else { return buffer }
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: input.audioBufferList
        ), noErr)
        return buffer
    }

    private static func rms(_ data: Data, trimmingFrames: Int) -> Double {
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let interior = samples.dropFirst(trimmingFrames).dropLast(trimmingFrames)
        guard !interior.isEmpty else { return 0 }
        return sqrt(interior.reduce(0.0) { $0 + pow(Double($1) / 32_768, 2) } / Double(interior.count))
    }

    private static func meanAbsoluteDifference(_ lhs: Data, _ rhs: Data) -> Double {
        let left = lhs.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let right = rhs.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        guard left.count == right.count, !left.isEmpty else { return .infinity }
        let total = zip(left, right).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) / 32_768 }
        return total / Double(left.count)
    }
}

private actor AudioConversionForwardingGate {
    private var isReleased = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        isReleased = true
        for waiter in waiting { waiter.resume() }
        waiting.removeAll()
    }
}
