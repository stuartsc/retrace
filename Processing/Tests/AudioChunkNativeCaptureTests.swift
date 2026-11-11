import AVFoundation
import CoreMedia
import Foundation
import Shared
import XCTest
@testable import Capture
@testable import Processing

/// The actual production native delegates feed the candidate chunker. Callback
/// jitter must not turn ordinary microphone/system packets into tiny AAC chunks.
final class AudioChunkNativeCaptureTests: XCTestCase {
    func testNativeDelegateToChunkerKeepsTenSecondChunksDespiteDeliveryJitter() async throws {
        for source in [AudioSource.microphone, .system] {
            let stream = AsyncStream<CapturedAudio>.makeStream()
            let converter = AudioFormatConverter()
            let microphone = MicAudioDelegate(continuation: stream.continuation, formatConverter: converter)
            let system = SystemAudioStreamOutput(continuation: stream.continuation, formatConverter: converter, muteState: SystemAudioMuteState())
            for index in 0..<21 {
                let packet = try Self.packet(rate: 48_000, pts: index)
                let jitter = [0.0, 0.011, -0.031, 0.2][index % 4]
                let receipt = Date(timeIntervalSince1970: 100 + Double(index) + jitter)
                if source == .microphone { microphone.receive(packet, receivedAt: receipt) }
                else { system.receive(packet, receivedAt: receipt) }
            }
            if source == .microphone { microphone.finish() } else { system.finish() }
            stream.continuation.finish()
            let buffer = AudioChunkBuffer()
            var emitted: [AudioChunkInput] = []
            var original = Data()
            for await packet in stream.stream {
                original.append(packet.audioData)
                emitted += try await buffer.append(packet)
            }
            emitted += await buffer.finish()
            XCTAssertEqual(emitted.map { $0.pcmData.count / 2 }, [160_000, 160_000, 16_000])
            XCTAssertEqual(Set(emitted.map(\.streamID)).count, 1)
            XCTAssertTrue(emitted.allSatisfy { $0.source == source })
            XCTAssertEqual(emitted.reduce(into: Data()) { $0.append($1.pcmData) }, original)
        }
    }

    func testNativeFormatBoundaryCannotBeJoinedByAdjacentWallDates() async throws {
        let stream = AsyncStream<CapturedAudio>.makeStream()
        let microphone = MicAudioDelegate(continuation: stream.continuation, formatConverter: AudioFormatConverter())
        microphone.receive(try Self.packet(rate: 48_000, pts: 0), receivedAt: Date(timeIntervalSince1970: 100))
        microphone.receive(try Self.packet(rate: 44_100, pts: 1), receivedAt: Date(timeIntervalSince1970: 105))
        microphone.finish(); stream.continuation.finish()
        let buffer = AudioChunkBuffer()
        var chunks: [AudioChunkInput] = []
        for await packet in stream.stream { chunks += try await buffer.append(packet) }
        chunks += await buffer.finish()
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.map { $0.pcmData.count / 2 }, [16_000, 16_000])
        XCTAssertEqual(chunks.map(\.origin), [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 101)])
        XCTAssertEqual(Set(chunks.map(\.streamID)).count, 2)
        XCTAssertEqual(chunks.map(\.startFrame), [0, 0])
    }

    private static func packet(rate: Double, pts: Int) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)))
        buffer.frameLength = AVAudioFrameCount(rate)
        for index in 0..<Int(rate) { buffer.floatChannelData![0][index] = Float(0.25 * sin(Double(index) * 2 * .pi * 220 / rate)) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
            presentationTimeStamp: CMTime(seconds: Double(pts), preferredTimescale: CMTimeScale(rate)), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: Int(rate), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result), noErr)
        let sample = try XCTUnwrap(result)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: buffer.audioBufferList), noErr)
        return sample
    }
}
