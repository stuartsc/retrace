import AVFoundation
import CoreMedia
import Foundation
import Shared
import Speech
import XCTest
@testable import Processing

private actor NativeSpeechUpdateRecorder {
    var values: [NativeSpeechStreamingUpdate] = []
    func append(_ update: NativeSpeechStreamingUpdate) { values.append(update) }
}

final class NativeSpeechTranscriptionServiceTests: XCTestCase {
    func testExplicitSilenceScoresRealNativePCMWithoutInventingWER() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace-speech-silence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("silence.wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
        for index in 0..<8_000 { samples[index] = 0 }
        do {
            let file = try AVAudioFile(forWriting: path, settings: format.settings,
                commonFormat: .pcmFormatInt16, interleaved: false)
            try file.write(from: buffer)
        }
        let pcm = try Self.readPCM(at: path.path)
        XCTAssertEqual(pcm.count, 16_000)
        XCTAssertTrue(pcm.allSatisfy { $0 == 0 })
        let duration = Double(pcm.count) / 32_000
        let quiet = Self.referenceMetrics(reference: "", hypothesis: "", audioSeconds: duration)
        XCTAssertTrue(quiet["reference_word_error_rate"] is NSNull)
        XCTAssertEqual(quiet["expected_silence"] as? Bool, true)
        XCTAssertEqual(quiet["silence_passed"] as? Bool, true)
        XCTAssertEqual(quiet["false_positive_words"] as? Int, 0)
        XCTAssertEqual(quiet["false_positive_words_per_minute"] as? Double, 0)
        let hallucinated = Self.referenceMetrics(reference: "", hypothesis: "Thank you.", audioSeconds: duration)
        XCTAssertTrue(hallucinated["reference_word_error_rate"] is NSNull)
        XCTAssertEqual(hallucinated["silence_passed"] as? Bool, false)
        XCTAssertEqual(hallucinated["false_positive_words"] as? Int, 2)
        XCTAssertEqual(hallucinated["false_positive_words_per_minute"] as? Double, 240)
        let encoded = try JSONSerialization.data(withJSONObject: hallucinated, options: [.sortedKeys])
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertTrue(decoded["reference_word_error_rate"] is NSNull,
            "Empty-reference scoring must remain undefined in the actual exported JSON")
    }

    func testMissingReferenceDoesNotClaimSilenceAndSpeechWERStillMeasuresEdits() throws {
        let missing = Self.referenceMetrics(reference: nil, hypothesis: "", audioSeconds: 1)
        XCTAssertEqual(missing["reference_available"] as? Bool, false)
        XCTAssertNil(missing["silence_passed"])
        XCTAssertNil(missing["false_positive_words"])
        XCTAssertNil(Self.wordErrorRate(reference: "", hypothesis: "extra"))
        let speech = Self.referenceMetrics(reference: "Do not approve.", hypothesis: "Do approve.", audioSeconds: 1)
        XCTAssertEqual(speech["reference_word_error_rate"] as? Double, 1.0 / 3.0)
        XCTAssertEqual(speech["expected_silence"] as? Bool, false)
        XCTAssertNil(speech["silence_passed"])
    }

    func testStreamingSilenceCountsTransientOutputEvenWhenFinalTextIsEmpty() throws {
        let update = NativeSpeechStreamingUpdate(text: "Thank you", start: 0, end: 0.2,
            isFinal: false, observedAfterSeconds: 0.3)
        let report = Self.referenceMetrics(reference: " \n", hypothesis: "", audioSeconds: 1,
            streamingUpdates: [update])
        XCTAssertEqual(report["silence_passed"] as? Bool, false)
        XCTAssertEqual(report["false_positive_words"] as? Int, 0)
        XCTAssertEqual(report["nonempty_streaming_updates"] as? Int, 1)
        XCTAssertEqual(report["streaming_update_words_total"] as? Int, 2,
            "This counts words across updates, not distinct spoken words or a diarization result")
        let noUpdates = Self.referenceMetrics(reference: "", hypothesis: "", audioSeconds: 1,
            streamingUpdates: [])
        XCTAssertEqual(noUpdates["silence_passed"] as? Bool, true)
        XCTAssertEqual(noUpdates["nonempty_streaming_updates"] as? Int, 0)
        let punctuation = Self.referenceMetrics(reference: "", hypothesis: "...", audioSeconds: 1)
        XCTAssertEqual(punctuation["false_positive_words"] as? Int, 0)
        XCTAssertEqual(punctuation["silence_passed"] as? Bool, false)
        let zeroDuration = Self.referenceMetrics(reference: "", hypothesis: "one", audioSeconds: 0)
        XCTAssertTrue(zeroDuration["false_positive_words_per_minute"] is NSNull)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: zeroDuration))
    }

    func testPacedStreamingWaitsForEachChunksFinalSampleBeforeDelivery() async throws {
        let buffer = try NativeSpeechPCMConverter.makeBuffer(Data(count: 2_000))
        let sequence = try NativeSpeechComparisonChunks(buffer: buffer, chunkDuration: 0.02, paceRealTime: true)
        let started = ContinuousClock.now
        var deliveredFrames = 0
        for try await chunk in sequence {
            let expectedStart = Double(deliveredFrames) / 16_000
            deliveredFrames += Int(chunk.buffer.frameLength)
            let elapsed = Self.seconds(started.duration(to: .now))
            XCTAssertEqual(CMTimeGetSeconds(try XCTUnwrap(chunk.bufferStartTime)), expectedStart, accuracy: 0.00001)
            XCTAssertGreaterThanOrEqual(elapsed + 0.001, Double(deliveredFrames) / 16_000,
                "A real-time comparison cannot provide samples before they could have been captured")
        }
        XCTAssertEqual(deliveredFrames, 1_000)
    }

    func testStreamingChunksPreserveActualConvertedPCMSamplesAndSourceTimes() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100, channels: 1, interleaved: false))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 45_731))
        input.frameLength = 45_731
        let samples = try XCTUnwrap(input.floatChannelData?[0])
        for index in 0..<45_731 { samples[index] = 0.4 * sin(Float(index) * 0.03) }
        let pcm = try NativeSpeechPCMConverter.pcm16Data(from: input)
        let converted = try NativeSpeechPCMConverter.makeBuffer(pcm)
        let sequence = try NativeSpeechComparisonChunks(buffer: converted, chunkDuration: 0.25, paceRealTime: false)
        var received = Data()
        var expectedOffset: Int64 = 0
        var count = 0
        for try await chunk in sequence {
            XCTAssertEqual(chunk.bufferStartTime, CMTime(value: expectedOffset, timescale: 16_000))
            XCTAssertGreaterThan(chunk.buffer.frameLength, 0)
            XCTAssertLessThanOrEqual(chunk.buffer.frameLength, 4_000)
            received.append(try NativeSpeechPCMConverter.pcm16Data(from: chunk.buffer))
            expectedOffset += Int64(chunk.buffer.frameLength)
            count += 1
        }
        XCTAssertEqual(received, pcm, "Streaming must not drop or repeat resampler tail samples")
        XCTAssertGreaterThan(count, 4)
    }

    func testStreamingComparisonRejectsUninitializedAndPrecancelledRequests() async throws {
        let native = NativeSpeechTranscriptionService()
        do {
            _ = try await native.compareStreaming(Data(count: 32_000))
            XCTFail("Streaming must not implicitly install assets")
        } catch TranscriptionError.notInitialized { }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await native.compareStreaming(Data(count: 32_000))
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled input must not start analysis") }
        catch is CancellationError { }
    }

    func testInstalledNativeStreamingComparisonKeepsFinalSpansAndReportsProgress() async throws {
        let audioPath = try Self.requiredEnvironment("RETRACE_SPEECH_BENCHMARK_AUDIO_PATH")
        let pcm = try Self.readPCM(at: audioPath)
        _ = try await Self.prepareBenchmarkAssetsIfRequested()
        let native = NativeSpeechTranscriptionService()
        try await native.initialize()
        let updates = NativeSpeechUpdateRecorder()
        let result = try await native.compareStreaming(pcm, paceRealTime: true) { update in
            await updates.append(update)
        }
        let received = await updates.values
        let reference = try ProcessInfo.processInfo.environment["RETRACE_SPEECH_BENCHMARK_REFERENCE_PATH"].map {
            try String(contentsOfFile: $0, encoding: .utf8)
        }
        let metrics = Self.referenceMetrics(reference: reference, hypothesis: result.text,
            audioSeconds: Double(pcm.count) / 32_000, streamingUpdates: received)
        if metrics["expected_silence"] as? Bool != true {
            XCTAssertFalse(result.text.isEmpty)
            XCTAssertTrue(received.contains { $0.isFinal })
        }
        XCTAssertTrue(received.allSatisfy { $0.start >= 0 && $0.end >= $0.start && $0.end <= Double(pcm.count) / 32_000 + 0.1 })
        var report: [String: Any] = ["backend": "native_streaming_en_AU", "input_seconds": Double(pcm.count) / 32_000,
            "updates": received.count, "first_update_seconds": received.first?.observedAfterSeconds ?? -1,
            "final_characters": result.text.count, "timed_spans": result.words.count,
            "comparison": "paced_authored_stream_not_live_microphone"]
        report.merge(metrics) { _, measured in measured }
        if ProcessInfo.processInfo.environment["RETRACE_SPEECH_BENCHMARK_INCLUDE_TEXT"] == "1" {
            report["hypothesis"] = result.text
            report["spans"] = result.words.map { ["text": $0.word, "start": $0.start, "end": $0.end] as [String: Any] }
            report["stream_updates"] = received.map {
                ["text": $0.text, "start": $0.start, "end": $0.end,
                 "final": $0.isFinal, "observed_after_seconds": $0.observedAfterSeconds] as [String: Any]
            }
        }
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("NATIVE_SPEECH_STREAMING_COMPARISON " + String(decoding: json, as: UTF8.self))
        await native.cleanup()
        if metrics["expected_silence"] as? Bool == true {
            XCTAssertEqual(metrics["silence_passed"] as? Bool, true,
                "Declared silence emitted text; retain the failed comparison receipt")
        }
    }

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
        let streaming = NativeSpeechTranscriptionService.makeTranscriber(locale: locale, streaming: true)
        let streamingStatus = await AssetInventory.status(forModules: [streaming])
        let readiness = try JSONSerialization.data(withJSONObject: [
            "locale": locale.identifier, "batch": String(describing: status),
            "streaming": String(describing: streamingStatus)
        ], options: [.sortedKeys])
        print("NATIVE_SPEECH_ASSET_READINESS " + String(decoding: readiness, as: UTF8.self))
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
            let metrics = Self.referenceMetrics(reference: reference, hypothesis: result.text,
                audioSeconds: Double(pcm.count) / 32_000)
            report.merge(metrics) { _, measured in measured }
            transcripts[name] = result.text
            if ProcessInfo.processInfo.environment["RETRACE_SPEECH_BENCHMARK_INCLUDE_TEXT"] == "1" {
                report["hypothesis"] = result.text
                report["spans"] = result.words.map { ["text": $0.word, "start": $0.start, "end": $0.end] as [String: Any] }
            }
            let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print("NATIVE_SPEECH_COMPARISON " + String(decoding: json, as: UTF8.self))
            await service.cleanup()
            if metrics["expected_silence"] as? Bool == true {
                XCTAssertEqual(metrics["silence_passed"] as? Bool, true,
                    "Declared silence emitted text for \(name); retain the failed comparison receipt")
            }
        }
        if let nativeText = transcripts["native"], let whisperText = transcripts["whisper_cpu"] {
            if let disagreement = Self.wordErrorRate(reference: whisperText, hypothesis: nativeText) {
                print("NATIVE_SPEECH_AGREEMENT no_ground_truth=true native_vs_whisper_word_disagreement=\(disagreement)")
            } else {
                print("NATIVE_SPEECH_AGREEMENT no_ground_truth=true native_vs_whisper_word_disagreement=null reason=empty_whisper_reference")
            }
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

    private static func referenceMetrics(
        reference: String?, hypothesis: String, audioSeconds: Double,
        streamingUpdates: [NativeSpeechStreamingUpdate]? = nil
    ) -> [String: Any] {
        var report: [String: Any] = ["reference_available": reference != nil]
        guard let reference else { return report }
        let expectedSilence = reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        report["expected_silence"] = expectedSilence
        report["reference_words"] = wordTokens(reference).count
        report["hypothesis_words"] = wordTokens(hypothesis).count
        if let score = wordErrorRate(reference: reference, hypothesis: hypothesis) {
            report["reference_word_error_rate"] = score
        } else {
            // WER has no denominator for zero reference words, even for perfect silence.
            report["reference_word_error_rate"] = NSNull()
        }
        guard expectedSilence else { return report }
        let falseWords = wordTokens(hypothesis).count
        report["false_positive_words"] = falseWords
        if audioSeconds.isFinite, audioSeconds > 0 {
            report["false_positive_words_per_minute"] = Double(falseWords) * 60 / audioSeconds
        } else {
            report["false_positive_words_per_minute"] = NSNull()
        }
        let nonemptyUpdates = streamingUpdates?.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let streamingUpdates, let nonemptyUpdates {
            report["nonempty_streaming_updates"] = nonemptyUpdates.count
            // Repeated volatile updates can contain the same words. This is not a
            // distinct false-word count and must not be used as a speech rate.
            report["streaming_update_words_total"] = streamingUpdates.reduce(0) { $0 + wordTokens($1.text).count }
        }
        report["silence_passed"] = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (nonemptyUpdates?.isEmpty ?? true)
        return report
    }

    private static func wordTokens(_ text: String) -> [Substring] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }
    }

    private static func wordErrorRate(reference: String, hypothesis: String) -> Double? {
        let expected = wordTokens(reference)
        let actual = wordTokens(hypothesis)
        guard !expected.isEmpty else { return nil }
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
