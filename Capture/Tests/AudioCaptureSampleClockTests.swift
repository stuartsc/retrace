import AVFoundation
import CoreMedia
import Foundation
import Shared
import XCTest
@testable import Capture

/// Actual CMSampleBuffers and native resampling exercise the delegate boundary.
/// Supplied receipt times represent queue delay; no capture device is started.
final class AudioCaptureSampleClockTests: XCTestCase {
    func testDelayedCallbacksUseNativeSampleClockIncludingConverterDrain() async throws {
        let packets = try [
            Self.packet(rate: 48_000, frames: 1, pts: CMTime(value: 0, timescale: 48_000)),
            Self.packet(rate: 48_000, frames: 23_456, pts: CMTime(value: 1, timescale: 48_000)),
            Self.packet(rate: 48_000, frames: 72_543, pts: CMTime(value: 23_457, timescale: 48_000))
        ]
        for source in [AudioSource.microphone, .system] {
            let audio = collect(source: source, packets: packets, receiptTimes: [10, 14, 13])
            let chunks = await audio.value
            XCTAssertEqual(chunks.first?.timestamp, Date(timeIntervalSince1970: 10))
            XCTAssertEqual(Set(chunks.compactMap(\.continuityID)).count, 1)
            XCTAssertTrue(chunks.allSatisfy { $0.continuityID != nil })
            var emittedFrames = 0
            for chunk in chunks {
                XCTAssertEqual(chunk.timestamp.timeIntervalSince1970, 10 + Double(emittedFrames) / 16_000, accuracy: 0.000_001)
                emittedFrames += chunk.audioData.count / 2
            }
            XCTAssertEqual(emittedFrames, 32_000)
            let reference = AudioFormatConverter()
            var expected = Data()
            for packet in packets { expected.append(try reference.convert(sampleBuffer: packet)) }
            expected.append(try reference.finish())
            XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1.audioData) }, expected)
        }
    }

    func testNativeGapsFormatChangesAndClockResetRetainSeparateIntervals() async throws {
        let packets = try [
            Self.packet(rate: 48_000, frames: 24_000, pts: .zero),
            Self.packet(rate: 48_000, frames: 24_000, pts: CMTime(seconds: 2, preferredTimescale: 48_000)),
            Self.packet(rate: 44_100, frames: 22_050, pts: CMTime(seconds: 2.5, preferredTimescale: 44_100)),
            Self.packet(rate: 44_100, frames: 22_050, pts: .zero)
        ]
        for source in [AudioSource.microphone, .system] {
            let chunks = await collect(source: source, packets: packets, receiptTimes: [10, 14, 20, 30]).value
            let groups = groupsByContinuity(chunks)
            XCTAssertEqual(groups.count, 4)
            XCTAssertEqual(groups.compactMap { $0.first?.timestamp.timeIntervalSince1970 }, [10, 12, 12.5, 30])
            for group in groups {
                XCTAssertEqual(group.reduce(0) { $0 + $1.audioData.count / 2 }, 8_000,
                    "Drain belongs to the prior native interval, never to the new gap or format")
                try assertContiguous(group)
            }
        }
    }

    func testSystemMuteResetsNativeClockAndCannotCarryResamplerHistory() async throws {
        let stream = AsyncStream<CapturedAudio>.makeStream()
        let output = SystemAudioStreamOutput(continuation: stream.continuation,
            formatConverter: AudioFormatConverter(), muteState: SystemAudioMuteState())
        output.receive(try Self.packet(rate: 48_000, frames: 24_000, pts: .zero), receivedAt: Date(timeIntervalSince1970: 10))
        output.setMuted(true)
        output.receive(try Self.packet(rate: 48_000, frames: 24_000, pts: CMTime(seconds: 0.5, preferredTimescale: 48_000)), receivedAt: Date(timeIntervalSince1970: 11))
        output.setMuted(false)
        output.receive(try Self.packet(rate: 48_000, frames: 24_000, pts: CMTime(seconds: 1, preferredTimescale: 48_000)), receivedAt: Date(timeIntervalSince1970: 1_000))
        output.receive(try Self.packet(rate: 48_000, frames: 24_000, pts: CMTime(seconds: 1.5, preferredTimescale: 48_000)), receivedAt: Date(timeIntervalSince1970: 1_005))
        output.finish(); stream.continuation.finish()
        var chunks: [CapturedAudio] = []
        for await chunk in stream.stream { chunks.append(chunk) }
        let groups = groupsByContinuity(chunks)
        XCTAssertEqual(groups.count, 2)
        let resumed = try XCTUnwrap(groups.last)
        XCTAssertEqual(resumed.first?.timestamp, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(resumed.reduce(0) { $0 + $1.audioData.count / 2 }, 16_000)
        try assertContiguous(resumed)
    }

    func testInvalidPresentationTimeCannotFabricateContinuity() async throws {
        let packets = try [
            Self.packet(rate: 48_000, frames: 4_800, pts: .invalid),
            Self.packet(rate: 48_000, frames: 4_800, pts: CMTime(seconds: 42, preferredTimescale: 48_000))
        ]
        for source in [AudioSource.microphone, .system] {
            let chunks = await collect(source: source, packets: packets, receiptTimes: [20, 123]).value
            XCTAssertEqual(chunks.first?.timestamp, Date(timeIntervalSince1970: 123))
            XCTAssertEqual(chunks.reduce(0) { $0 + $1.audioData.count / 2 }, 1_600)
        }
    }

    func testInvalidMetadataDrainsAlreadyAcceptedNativePrefixBeforeReset() async throws {
        let prefix = try Self.packet(rate: 48_000, frames: 4_800, pts: .zero)
        let invalid = try Self.packet(rate: 48_000, frames: 4_800, pts: .invalid)
        let resumed = try Self.packet(rate: 48_000, frames: 4_800,
            pts: CMTime(seconds: 42, preferredTimescale: 48_000))
        let reference = AudioFormatConverter()
        var accepted = try reference.convert(sampleBuffer: prefix)
        accepted.append(try reference.finish())
        XCTAssertEqual(accepted.count, 3_200)
        for source in [AudioSource.microphone, .system] {
            let chunks = await collect(source: source, packets: [prefix, invalid, resumed], receiptTimes: [10, 20, 123]).value
            let groups = groupsByContinuity(chunks)
            XCTAssertEqual(groups.count, 2)
            let first = try XCTUnwrap(groups.first)
            XCTAssertEqual(first.first?.timestamp, Date(timeIntervalSince1970: 10))
            XCTAssertEqual(first.reduce(into: Data()) { $0.append($1.audioData) }, accepted,
                "Rejecting a later packet's metadata must preserve the entire previously accepted resampler interval")
            try assertContiguous(first)
            XCTAssertEqual(groups.last?.first?.timestamp, Date(timeIntervalSince1970: 123))
            XCTAssertEqual(groups.last?.reduce(0) { $0 + $1.audioData.count }, 3_200)
        }
    }

    private func collect(source: AudioSource, packets: [CMSampleBuffer], receiptTimes: [Double]) -> Task<[CapturedAudio], Never> {
        let stream = AsyncStream<CapturedAudio>.makeStream()
        let converter = AudioFormatConverter()
        let microphone = MicAudioDelegate(continuation: stream.continuation, formatConverter: converter)
        let system = SystemAudioStreamOutput(continuation: stream.continuation, formatConverter: converter, muteState: SystemAudioMuteState())
        for (packet, receipt) in zip(packets, receiptTimes) {
            if source == .microphone { microphone.receive(packet, receivedAt: Date(timeIntervalSince1970: receipt)) }
            else { system.receive(packet, receivedAt: Date(timeIntervalSince1970: receipt)) }
        }
        if source == .microphone { microphone.finish() } else { system.finish() }
        stream.continuation.finish()
        return Task {
            var result: [CapturedAudio] = []
            for await chunk in stream.stream { result.append(chunk) }
            return result
        }
    }

    private func groupsByContinuity(_ chunks: [CapturedAudio]) -> [[CapturedAudio]] {
        var result: [[CapturedAudio]] = []
        for chunk in chunks {
            if let prior = result.last?.last, prior.continuityID == chunk.continuityID {
                result[result.count - 1].append(chunk)
            } else { result.append([chunk]) }
        }
        return result
    }

    private func assertContiguous(_ chunks: [CapturedAudio]) throws {
        let start = try XCTUnwrap(chunks.first?.timestamp)
        var frames = 0
        for chunk in chunks {
            XCTAssertEqual(chunk.timestamp.timeIntervalSince(start), Double(frames) / 16_000, accuracy: 0.000_001)
            frames += chunk.audioData.count / 2
        }
    }

    private static func packet(rate: Double, frames: Int, pts: CMTime) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames { pcm.floatChannelData![0][index] = Float(0.3 * sin(Double(index) * 2 * .pi * 220 / rate)) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let result = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
        return result
    }
}
