import AVFoundation
import CryptoKit
import Darwin
import Foundation
import XCTest
import Shared
@testable import Processing

final class WhisperModelResidencyTests: XCTestCase {
    /// Opt-in real inference on the reviewed, authored (never recorded) fixture.
    /// The decoder's full text is the oracle for its independently extracted
    /// timed words, so this regression does not require perfect speech accuracy.
    func testTimedWordsCoverReturnedTextOnExplicitAuthoredAudio() async throws {
        let modelPath = try Self.requiredEnvironment("RETRACE_WHISPER_WORD_TEST_MODEL_PATH")
        let (audio, reference) = try await Task.detached(priority: .utility) {
            let audioURL = try XCTUnwrap(Bundle.module.url(
                forResource: "authored", withExtension: "wav", subdirectory: "WhisperTimedWords"
            ), "The reviewed authored audio must be bundled with ProcessingTests")
            let referenceURL = try XCTUnwrap(Bundle.module.url(
                forResource: "reference", withExtension: "txt", subdirectory: "WhisperTimedWords"
            ), "The authored reference must be bundled with ProcessingTests")
            guard (try referenceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 4_096 else {
                throw AuthoredAudioFailure.invalidReference
            }
            return (try Self.readAuthoredPCM(at: audioURL.path), try String(contentsOf: referenceURL, encoding: .utf8))
        }.value
        XCTAssertEqual(audio.frames, 171_707, "This opt-in case uses the reviewed 10.73-second authored fixture")
        XCTAssertEqual(audio.pcm.count, audio.frames * MemoryLayout<Int16>.size)
        let pcmHash = SHA256.hash(data: audio.pcm).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(pcmHash, "b1295d561ac7a320eec47d9f5e5ccb58ed4e1e20f52dc3119b445f1d88952b41",
                       "Short AVAudioFile reads must be drained before inference")

        let concreteService = WhisperCppTranscriptionService(modelPath: modelPath, useGPU: false)
        let service: any TranscriptionProtocol = concreteService
        addTeardownBlock { await service.cleanup() }
        try await service.initialize()
        let result = try await service.transcribeWithTimestamps(
            audio.pcm, wordLevel: true, initialPrompt: nil, languageHint: nil
        )
        try Self.assertTimedWordCoverage(result, audio: audio, reference: reference, pcmHash: pcmHash, entryPoint: "timestamps")
        // The contextual entry point is not part of TranscriptionProtocol. Use
        // the same initialized CPU service, without loading a second model.
        let contextual = try await concreteService.transcribeWithContext(
            audio.pcm, wordLevel: true, initialPrompt: "The blue proposal and the green proposal."
        )
        try Self.assertTimedWordCoverage(contextual, audio: audio, reference: reference, pcmHash: pcmHash, entryPoint: "context")
    }

    private static func assertTimedWordCoverage(_ result: DetailedTranscriptionResult, audio: AuthoredPCM,
                                               reference: String, pcmHash: String, entryPoint: String) throws {
        let textWords = Self.normalizedWords(result.text)
        let timedWords = result.words.flatMap { Self.normalizedWords($0.word) }
        let referenceWords = Self.normalizedWords(reference)
        XCTAssertFalse(referenceWords.isEmpty)
        XCTAssertGreaterThanOrEqual(Set(textWords).intersection(referenceWords).count, max(1, Set(referenceWords).count / 2),
                                    "The authored reference establishes a meaningful decode, not exact recognition accuracy")
        XCTAssertEqual(try XCTUnwrap(result.duration), Double(audio.frames) / 16_000, accuracy: 0.0001)

        // This receipt contains only explicitly supplied authored fixture content.
        // Run the opt-in case with the documented live-log write denial.
        let report: [String: Any] = [
            "fixture_kind": "authored_TTS_not_human_recording",
            "backend": "cpu", "entry_point": entryPoint, "frames": audio.frames, "read_calls": audio.readCalls,
            "pcm_sha256": pcmHash, "reference_words": referenceWords,
            "full_text_words": textWords, "timed_words": timedWords,
            "spans": result.words.map { ["word": $0.word, "start": $0.start, "end": $0.end] as [String: Any] }
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("WHISPER_TIMED_WORD_REGRESSION " + String(decoding: json, as: UTF8.self))
        fflush(stdout)
        XCTAssertEqual(timedWords, textWords,
                       "\(entryPoint): Every decoded lexical word, including each segment tail, needs its own timed-word representation")
        for word in result.words {
            XCTAssertTrue(word.start.isFinite && word.end.isFinite)
            XCTAssertGreaterThanOrEqual(word.start, 0)
            XCTAssertGreaterThanOrEqual(word.end, word.start)
            XCTAssertLessThanOrEqual(word.end, Double(audio.frames) / 16_000 + 0.1)
        }
        for (previous, next) in zip(result.words, result.words.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.start, previous.start)
            XCTAssertGreaterThanOrEqual(next.end, previous.end)
        }
    }

    func testResidentModelStillRequiresExplicitInitialization() async {
        let service = WhisperCppTranscriptionService(
            modelPath: Self.missingModelPath(),
            modelResidency: .resident
        )

        do {
            _ = try await service.transcribe(Data())
            XCTFail("Expected transcription to require explicit initialization")
        } catch TranscriptionError.notInitialized {
            // Expected.
        } catch {
            XCTFail("Expected notInitialized, received \(error)")
        }
    }

    func testOnDemandModelAttemptsToLoadForFirstTranscription() async {
        let modelPath = Self.missingModelPath()
        let service = WhisperCppTranscriptionService(
            modelPath: modelPath,
            modelResidency: .onDemand(idleTimeout: .seconds(1))
        )

        do {
            _ = try await service.transcribe(Data())
            XCTFail("Expected the missing model load to fail")
        } catch TranscriptionError.modelLoadFailed(let message) {
            XCTAssertTrue(message.contains(modelPath))
        } catch {
            XCTFail("Expected modelLoadFailed, received \(error)")
        }
    }

    private static func missingModelPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-whisper-\(UUID().uuidString).bin")
            .path
    }

    private enum AuthoredAudioFailure: Error { case invalidAudio, invalidReference, prematureEndOfAudio }

    private struct AuthoredPCM: Sendable {
        let pcm: Data
        let frames: Int
        let readCalls: Int
    }

    private static func requiredEnvironment(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            throw XCTSkip("Real Whisper word coverage requires an explicit local model path")
        }
        return value
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func readAuthoredPCM(at path: String) throws -> AuthoredPCM {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatInt16, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              file.length > 0, file.length <= 16_000 * 30,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AuthoredAudioFailure.invalidAudio
        }
        let expectedFrames = Int(file.length)
        var pcm = Data()
        pcm.reserveCapacity(expectedFrames * MemoryLayout<Int16>.size)
        var reads = 0
        while pcm.count / MemoryLayout<Int16>.size < expectedFrames {
            let remaining = expectedFrames - pcm.count / MemoryLayout<Int16>.size
            try file.read(into: buffer, frameCount: AVAudioFrameCount(remaining))
            guard buffer.frameLength > 0, Int(buffer.frameLength) <= remaining,
                  let samples = buffer.int16ChannelData?[0] else { throw AuthoredAudioFailure.prematureEndOfAudio }
            pcm.append(Data(bytes: samples, count: Int(buffer.frameLength) * MemoryLayout<Int16>.size))
            reads += 1
        }
        return AuthoredPCM(pcm: pcm, frames: expectedFrames, readCalls: reads)
    }
}
