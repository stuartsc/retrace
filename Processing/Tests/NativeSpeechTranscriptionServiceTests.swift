import AVFoundation
import Foundation
import Shared
import Speech
import XCTest
@testable import Processing

final class NativeSpeechTranscriptionServiceTests: XCTestCase {
    func testPCMConversionPreservesRealAudioDurationAndEnergy() throws {
        let input = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<44_100 {
            samples[index] = 0.4 * sin(2 * .pi * 440 * Float(index) / 44_100)
        }
        let pcm = try NativeSpeechPCMConverter.pcm16Data(from: buffer)
        XCTAssertEqual(pcm.count, 32_000)
        let restored = try NativeSpeechPCMConverter.makeBuffer(pcm)
        XCTAssertEqual(restored.frameLength, 16_000)
        let restoredSamples = try XCTUnwrap(restored.int16ChannelData?[0])
        let rms = sqrt((0..<16_000).reduce(0.0) {
            $0 + pow(Double(restoredSamples[$1]) / 32_768, 2)
        } / 16_000)
        XCTAssertEqual(rms, 0.4 / sqrt(2), accuracy: 0.005)
    }

    func testPCMValidationRejectsIncompleteSamplesAndOversizedBatches() throws {
        XCTAssertThrowsError(try NativeSpeechPCMConverter.makeBuffer(Data([1])))
        XCTAssertThrowsError(try NativeSpeechPCMConverter.makeBuffer(Data()))
        XCTAssertThrowsError(try NativeSpeechPCMConverter.makeBuffer(Data(count: 32_000 * 121)))
    }

    func testNativeServiceRequiresInitialization() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let service: any TranscriptionProtocol = NativeSpeechTranscriptionService()
        do {
            _ = try await service.transcribe(Data(count: 32_000))
            XCTFail("Uninitialized service should reject transcription")
        } catch TranscriptionError.notInitialized {
            // The service does not silently start or download assets.
        }
    }

    func testInitializationChecksConfiguredModuleAssets() async throws {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else {
            throw XCTSkip("Requires native Speech on macOS 26")
        }
        let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-AU"))
        let locale = try XCTUnwrap(supportedLocale)
        let transcriber = NativeSpeechTranscriptionService.makeTranscriber(locale: locale)
        let status = await AssetInventory.status(forModules: [transcriber])
        let service: any TranscriptionProtocol = NativeSpeechTranscriptionService()
        do {
            try await service.initialize()
            XCTAssertEqual(status, .installed, "Initialization must reject unavailable configured assets before analysis")
        } catch NativeSpeechError.assetsNotInstalled {
            XCTAssertNotEqual(status, .installed)
        }
        await service.cleanup()
    }

    func testInstalledNativeSpeechTranscribesExplicitAudioAndHonorsCancellation() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let audioPath = try Self.requiredEnvironment("RETRACE_SPEECH_BENCHMARK_AUDIO_PATH")
        let pcm = try Self.readPCM(at: audioPath)
        _ = try await Self.prepareBenchmarkAssetsIfRequested()
        let service: any TranscriptionProtocol = NativeSpeechTranscriptionService()
        try await service.initialize()
        let result = try await service.transcribeWithTimestamps(pcm, wordLevel: true, initialPrompt: nil)
        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(result.words.isEmpty, "Timed recognition must produce real spans")
        XCTAssertEqual(try XCTUnwrap(result.duration), Double(pcm.count) / 32_000, accuracy: 0.0001)
        for word in result.words {
            XCTAssertGreaterThanOrEqual(word.start, 0)
            XCTAssertGreaterThanOrEqual(word.end, word.start)
            XCTAssertLessThanOrEqual(word.end, Double(pcm.count) / 32_000 + 0.1)
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.transcribe(pcm)
        }
        do {
            _ = try await cancelled.value
            XCTFail("Pre-cancelled request should not perform inference")
        } catch is CancellationError {
            // Expected.
        }
        var longAudio = pcm
        while longAudio.count < 32_000 * 30 && longAudio.count + pcm.count <= 32_000 * 120 {
            longAudio.append(pcm)
        }
        let inFlight = Task { try await service.transcribe(longAudio) }
        try await Task.sleep(for: .milliseconds(25), clock: .continuous)
        inFlight.cancel()
        do {
            _ = try await inFlight.value
            XCTFail("Cancelled in-flight native analysis should stop and discard partial text")
        } catch is CancellationError {
            // Exercise cancellation while framework analysis is underway, not only the entry guard.
        }
        await service.cleanup()
    }

    func testCompareNativeSpeechWithCPUWhisperOnExplicitAudio() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let audioPath = try Self.requiredEnvironment("RETRACE_SPEECH_BENCHMARK_AUDIO_PATH")
        let modelPath = try Self.requiredEnvironment("RETRACE_SPEECH_BENCHMARK_WHISPER_MODEL_PATH")
        let pcm = try Self.readPCM(at: audioPath)
        let assetPreparation = try await Self.prepareBenchmarkAssetsIfRequested()
        let native: any TranscriptionProtocol = NativeSpeechTranscriptionService()
        let whisper: any TranscriptionProtocol = WhisperCppTranscriptionService(modelPath: modelPath, useGPU: false)
        let reference = try ProcessInfo.processInfo.environment["RETRACE_SPEECH_BENCHMARK_REFERENCE_PATH"].map {
            try String(contentsOfFile: $0, encoding: .utf8)
        }
        var transcripts: [String: String] = [:]
        for (name, service) in [("native", native), ("whisper_cpu", whisper)] {
            let initStart = ContinuousClock.now
            try await service.initialize()
            let initialization = Self.seconds(initStart.duration(to: .now))
            let start = ContinuousClock.now
            let result = try await service.transcribeWithTimestamps(
                pcm, wordLevel: true, initialPrompt: nil, languageHint: "en"
            )
            let elapsed = Self.seconds(start.duration(to: .now))
            var report: [String: Any] = [
                "backend": name,
                "audio_seconds": Double(pcm.count) / 32_000,
                "initialization_seconds": initialization,
                "transcription_seconds": elapsed,
                "total_seconds": initialization + elapsed,
                "real_time_factor": elapsed / (Double(pcm.count) / 32_000),
                "characters": result.text.count,
                "timed_spans": result.words.count,
                "source_start_seconds": 0,
                "asset_preparation_seconds": name == "native" ? assetPreparation : 0,
                "comparison": "batch_cold_start_excludes_asset_installation"
            ]
            if let reference {
                report["reference_word_error_rate"] = Self.wordErrorRate(reference: reference, hypothesis: result.text)
            }
            transcripts[name] = result.text
            let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print("NATIVE_SPEECH_COMPARISON " + String(decoding: json, as: UTF8.self))
            await service.cleanup()
        }
        if let nativeText = transcripts["native"], let whisperText = transcripts["whisper_cpu"] {
            let disagreement = Self.wordErrorRate(reference: whisperText, hypothesis: nativeText)
            print("NATIVE_SPEECH_AGREEMENT no_ground_truth=true native_vs_whisper_word_disagreement=\(disagreement)")
        }
    }

    @available(macOS 26.0, *)
    private static func prepareBenchmarkAssetsIfRequested() async throws -> Double {
        guard ProcessInfo.processInfo.environment["RETRACE_SPEECH_BENCHMARK_PREPARE_ASSETS"] == "1" else {
            return 0
        }
        let start = ContinuousClock.now
        let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-AU"))
        let locale = try XCTUnwrap(supportedLocale)
        // This explicit test-only opt-in registers and, if necessary, installs the exact
        // module assets in the calling process. The service never downloads assets itself.
        _ = try await AssetInventory.reserve(locale: locale)
        let transcriber = NativeSpeechTranscriptionService.makeTranscriber(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw NativeSpeechError.assetsNotInstalled(locale.identifier)
        }
        return seconds(start.duration(to: .now))
    }

    private static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let tokenize: (String) -> [Substring] = {
            $0.lowercased().split { !$0.isLetter && !$0.isNumber }
        }
        let expected = tokenize(reference)
        let actual = tokenize(hypothesis)
        guard !expected.isEmpty else { return actual.isEmpty ? 0 : 1 }
        var previous = Array(0...actual.count)
        for (row, expectedWord) in expected.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: actual.count)
            for (column, actualWord) in actual.enumerated() {
                current[column + 1] = min(
                    previous[column + 1] + 1,
                    current[column] + 1,
                    previous[column] + (expectedWord == actualWord ? 0 : 1)
                )
            }
            previous = current
        }
        return Double(previous[actual.count]) / Double(expected.count)
    }

    private static func requiredEnvironment(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw XCTSkip("Explicit local audio/model paths are required; asset preparation also requires PREPARE_ASSETS=1")
        }
        return value
    }

    private static func readPCM(at path: String) throws -> Data {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard file.length > 0, Double(file.length) / file.processingFormat.sampleRate <= 120 else {
            throw TranscriptionError.audioFormatError
        }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        return try NativeSpeechPCMConverter.pcm16Data(from: buffer)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
