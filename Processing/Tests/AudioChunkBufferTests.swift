import Foundation
import Shared
import XCTest
@testable import Processing

/// Authored sample ramps make lost, repeated or reordered PCM observable before
/// the lossy encoder boundary. Capture callbacks deliberately cross chunk edges.
final class AudioChunkBufferTests: XCTestCase {
    func testArbitraryCallbacksPersistEveryPCMFrameExactlyOnce() async throws {
        let buffer = AudioChunkBuffer()
        let origin = Date(timeIntervalSince1970: 1_800_000_000.125)
        let counts = [112_000, 176_000, 116_800]
        let original = Self.pcm(frames: counts.reduce(0, +))
        var position = 0
        var chunks: [AudioChunkInput] = []
        for count in counts {
            chunks += try await buffer.append(CapturedAudio(
                timestamp: origin.addingTimeInterval(Double(position) / 16_000),
                audioData: original.subdata(in: position * 2..<(position + count) * 2),
                duration: Double(count) / 16_000, source: .microphone))
            position += count
        }
        chunks += await buffer.finish()
        XCTAssertEqual(chunks.map { $0.pcmData.count / 2 }, [160_000, 160_000, 84_800])
        XCTAssertEqual(chunks.map(\.startFrame), [0, 160_000, 320_000])
        XCTAssertEqual(Set(chunks.map(\.streamID)).count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.origin == origin && $0.source == .microphone })
        XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1.pcmData) }, original)
        let repeated = await buffer.finish()
        XCTAssertTrue(repeated.isEmpty, "Finalization must not emit a retained overlap again")
    }

    func testExactSourcesStayIndependentAndFinalFlushIsBounded() async throws {
        let buffer = AudioChunkBuffer()
        let origin = Date(timeIntervalSince1970: 20_000)
        let sources: [AudioSource] = [.microphone, .system, .zoom]
        for (index, source) in sources.enumerated() {
            let emitted = try await buffer.append(Self.capture(frames: 8_000, at: origin,
                source: source, seed: index + 1))
            XCTAssertTrue(emitted.isEmpty)
        }
        let chunks = await buffer.finish()
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(Set(chunks.map(\.source)), Set(sources))
        XCTAssertEqual(Set(chunks.map(\.streamID)).count, 3)
        for (index, source) in sources.enumerated() {
            XCTAssertEqual(chunks.first { $0.source == source }?.pcmData, Self.pcm(frames: 8_000, seed: index + 1))
        }
    }

    func testGapAndBackwardsClockPreservePCMButBreakContextIdentity() async throws {
        let buffer = AudioChunkBuffer()
        let first = Date(timeIntervalSince1970: 30_000)
        var chunks: [AudioChunkInput] = []
        chunks += try await buffer.append(Self.capture(frames: 16_000, at: first))
        chunks += try await buffer.append(Self.capture(frames: 16_000, at: first.addingTimeInterval(3), seed: 2))
        chunks += try await buffer.append(Self.capture(frames: 16_000, at: first.addingTimeInterval(2), seed: 3))
        chunks += await buffer.finish()
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.origin), [first, first.addingTimeInterval(3), first.addingTimeInterval(2)])
        XCTAssertEqual(chunks.map(\.startFrame), [0, 0, 0])
        XCTAssertEqual(Set(chunks.map(\.streamID)).count, 3)
        XCTAssertEqual(chunks.map(\.pcmData), [1, 2, 3].map { Self.pcm(frames: 16_000, seed: $0) })
    }

    func testInvalidOrOversizedCaptureDoesNotConsumeAcceptedPCM() async throws {
        let buffer = AudioChunkBuffer()
        let origin = Date(timeIntervalSince1970: 40_000)
        _ = try await buffer.append(Self.capture(frames: 8_000, at: origin))
        let invalid = [
            CapturedAudio(timestamp: origin, audioData: Data(), duration: 0, source: .microphone),
            CapturedAudio(timestamp: origin, audioData: Data([1]), duration: 1.0 / 16_000, source: .microphone),
            CapturedAudio(timestamp: origin, audioData: Self.pcm(frames: 16), duration: 1, source: .microphone),
            CapturedAudio(timestamp: origin, audioData: Self.pcm(frames: 16), duration: .infinity, source: .microphone),
            CapturedAudio(timestamp: origin, audioData: Self.pcm(frames: 16), duration: 0.001, source: .microphone, sampleRate: 48_000),
            CapturedAudio(timestamp: origin, audioData: Self.pcm(frames: 16), duration: 0.001, source: .microphone, channels: 2),
            Self.capture(frames: 960_001, at: origin)
        ]
        for capture in invalid {
            do {
                _ = try await buffer.append(capture)
                XCTFail("Invalid capture must not allocate a growing queue or fabricate timing")
            } catch {}
        }
        let retained = await buffer.finish()
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.pcmData, Self.pcm(frames: 8_000))
    }

    func testLargestAdmittedCallbackEmitsSixCompleteChunksWithoutResidualOverlap() async throws {
        let buffer = AudioChunkBuffer()
        let capture = Self.capture(frames: 960_000, at: Date(timeIntervalSince1970: 50_000))
        let chunks = try await buffer.append(capture)
        XCTAssertEqual(chunks.count, 6)
        XCTAssertTrue(chunks.allSatisfy { $0.pcmData.count == 320_000 })
        XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1.pcmData) }, capture.audioData)
        let residual = await buffer.finish()
        XCTAssertTrue(residual.isEmpty)
    }

    static func capture(frames: Int, at timestamp: Date, source: AudioSource = .microphone, seed: Int = 1) -> CapturedAudio {
        CapturedAudio(timestamp: timestamp, audioData: pcm(frames: frames, seed: seed),
            duration: Double(frames) / 16_000, source: source)
    }

    static func pcm(frames: Int, seed: Int = 1) -> Data {
        let values = (0..<frames).map { Int16(truncatingIfNeeded: $0 &* 73 &+ seed &* 997) }
        return values.withUnsafeBytes { Data($0) }
    }
}
