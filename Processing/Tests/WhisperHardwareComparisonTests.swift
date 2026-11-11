import AVFoundation
import CryptoKit
import Darwin
import Foundation
import XCTest
import Shared
@testable import Processing

/// Developer measurement only. No production backend, model, power setting or audio is changed.
final class WhisperHardwareComparisonTests: XCTestCase {
    #if DEBUG
    func testExplicitNativeCancellationBoundaryRetainsReusableModel() async throws {
        let model = try Self.requiredModel()
        let fixture = try await Task.detached(priority: .utility) { try Self.fixture() }.value
        let service = WhisperCppTranscriptionService(modelPath: model, useGPU: false)
        addTeardownBlock { await service.cleanup() }
        try await service.initialize()
        let entered = expectation(description: "Native call boundary reached with cancellation handler installed")
        await service.setNativeInferenceStartedForTesting { entered.fulfill() }
        var longerPCM = Data()
        for _ in 0..<3 { longerPCM.append(fixture.pcm) }
        let input = longerPCM
        let permit = BackgroundProcessingPermit(threadCount: 2)
        let inference = Task.detached(priority: .utility) {
            try await BackgroundProcessingContext.$permit.withValue(permit) {
                try await service.transcribeWithTimestamps(input, wordLevel: true,
                    initialPrompt: nil, languageHint: "en")
            }
        }
        await fulfillment(of: [entered], timeout: 30)
        // This delay creates an opportunity to enter whisper_full; the callback boundary alone
        // does not establish the exact native sampling operation running when cancellation lands.
        try await Task.sleep(for: .milliseconds(100))
        let cancellationStart = ContinuousClock.now
        inference.cancel()
        do { _ = try await inference.value; XCTFail("Cancelled native inference returned usable text") }
        catch is CancellationError {}
        let cancellationJoinSeconds = Self.seconds(cancellationStart.duration(to: .now))
        XCTAssertTrue(permit.cancellation.isCancelled)
        await service.setNativeInferenceStartedForTesting(nil)
        let reuseStart = ContinuousClock.now
        let recovered = try await service.transcribeWithTimestamps(fixture.pcm, wordLevel: true,
            initialPrompt: nil, languageHint: "en")
        XCTAssertFalse(recovered.text.isEmpty)
        Self.assertTimestamps(recovered, duration: fixture.duration)
        try Self.report(["case": "owned_CPU_cancellation_and_next_inference", "cancelled": permit.cancellation.isCancelled,
                         "boundary": "handler_installed_before_whisper_full", "exact_native_sampling_phase_unverified": true,
                         "cancellation_join_seconds": cancellationJoinSeconds,
                         "next_inference_seconds": Self.seconds(reuseStart.duration(to: .now)),
                         "joined_and_next_inference_seconds": Self.seconds(cancellationStart.duration(to: .now)),
                         "reused_model_returned_text": !recovered.text.isEmpty])
    }
    #endif

    func testComparisonFixtureDecoderDrainsExactAuthoredPCM() async throws {
        let fixture = try await Task.detached(priority: .utility) { try Self.fixture() }.value
        XCTAssertEqual(fixture.pcm.count, 343_414)
        XCTAssertEqual(Self.hash(fixture.pcm), "b1295d561ac7a320eec47d9f5e5ccb58ed4e1e20f52dc3119b445f1d88952b41")
        XCTAssertEqual(Self.words(fixture.reference).count, 32)
        XCTAssertEqual(Self.editDistance(["do", "not", "approve"], ["do", "approve"]), 1)
        XCTAssertEqual(Self.editDistance([], ["payment"]), 1)
    }

    func testExplicitCPUAndMetalComparisonOnSamePinnedModelAndAuthoredPCM() async throws {
        let model = try Self.requiredModel()
        let prepared = try await Task.detached(priority: .utility) {
            (try Self.fixture(), try Self.hashFile(model))
        }.value
        let fixture = prepared.0
        let modelHash = prepared.1
        let repeats = min(3, max(1, Int(ProcessInfo.processInfo.environment["RETRACE_WHISPER_COMPARISON_REPEATS"] ?? "1") ?? 1))
        var measurements: [[String: Any]] = []
        var decoded: [String: [DetailedTranscriptionResult]] = [:]
        for (name, gpu) in [("cpu_requested", false), ("metal_requested", true)] {
            let service = WhisperCppTranscriptionService(modelPath: model, useGPU: gpu)
            let initializationStart = ContinuousClock.now
            do {
                try await service.initialize()
                let initialization = Self.seconds(initializationStart.duration(to: .now))
                for iteration in 1...repeats {
                    let before = Self.resources()
                    let start = ContinuousClock.now
                    let permit = BackgroundProcessingPermit(threadCount: 2)
                    let result = try await BackgroundProcessingContext.$permit.withValue(permit) {
                        try await service.transcribeWithTimestamps(fixture.pcm, wordLevel: true,
                            initialPrompt: nil, languageHint: "en")
                    }
                    let elapsed = Self.seconds(start.duration(to: .now))
                    let after = Self.resources()
                    Self.assertTimestamps(result, duration: fixture.duration)
                    let tokens = Self.words(result.text)
                    XCTAssertFalse(tokens.isEmpty, "Authored speech must yield a nonempty decode")
                    decoded[name, default: []].append(result)
                    measurements.append([
                        "backend_configuration": name, "actual_gpu_execution_verified": false,
                        "iteration": iteration, "threads_requested": 2,
                        "initialization_seconds": initialization, "inference_seconds": elapsed,
                        "inference_process_cpu_seconds": max(0, after.cpuSeconds - before.cpuSeconds),
                        "process_lifetime_peak_rss_bytes": after.peakRSS,
                        "peak_rss_scope": "cumulative_test_process_high_water_not_backend_allocation",
                        "system_before": before.system, "system_after": after.system,
                        "reference_word_error_rate": Double(Self.editDistance(Self.words(fixture.reference), tokens)) / Double(Self.words(fixture.reference).count),
                        "words": tokens,
                        "timestamps": result.words.map { ["word": $0.word, "start": $0.start, "end": $0.end] as [String: Any] }
                    ])
                }
                await service.cleanup()
            } catch {
                await service.cleanup()
                throw error
            }
        }
        let cpu = try XCTUnwrap(decoded["cpu_requested"])
        let metal = try XCTUnwrap(decoded["metal_requested"])
        let comparisons = zip(cpu, metal).enumerated().map { index, pair -> [String: Any] in
            let left = Self.words(pair.0.text)
            let right = Self.words(pair.1.text)
            return ["iteration": index + 1, "text_identical": pair.0.text == pair.1.text,
                    "normalized_words_identical": left == right,
                    "cpu_to_metal_word_edits": Self.editDistance(left, right),
                    "agreement_is_not_accuracy": true]
        }
        try Self.report([
            "fixture": "WhisperTimedWords/authored.wav", "fixture_kind": "authored_Karen_en_AU_TTS",
            "pcm_sha256": Self.hash(fixture.pcm), "model_sha256": modelHash,
            "audio_seconds": fixture.duration, "measurements": measurements, "comparisons": comparisons,
            "core_ml": "untested_no_pinned_encoder_or_verified_backend_in_this_comparison",
            "quantization": "only_the_explicit_model_tested_no_cross_model_quality_claim",
            "apple_speech": "untested_no_assets_prepared_or_installed",
            "whole_system_energy": "not_measured", "helper_process_memory": "not_measured",
            "scope": "single_authored_fixture_not_names_numbers_quiet_speech_overlap_or_promotion_acceptance"
        ])
    }

    private struct Fixture: Sendable {
        let pcm: Data
        let reference: String
        var duration: Double { Double(pcm.count) / 32_000 }
    }

    private static func requiredModel() throws -> String {
        guard let value = ProcessInfo.processInfo.environment["RETRACE_WHISPER_COMPARISON_MODEL"], !value.isEmpty else {
            throw XCTSkip("Set RETRACE_WHISPER_COMPARISON_MODEL to an existing local model for explicit hardware comparison")
        }
        return NSString(string: value).expandingTildeInPath
    }

    private static func fixture() throws -> Fixture {
        let audio = try XCTUnwrap(Bundle.module.url(forResource: "authored", withExtension: "wav", subdirectory: "WhisperTimedWords"))
        let reference = try XCTUnwrap(Bundle.module.url(forResource: "reference", withExtension: "txt", subdirectory: "WhisperTimedWords"))
        let file = try AVAudioFile(forReading: audio, commonFormat: .pcmFormatInt16, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              file.length == 171_707,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000) else {
            throw ComparisonError.invalidFixture
        }
        var pcm = Data()
        while pcm.count / 2 < Int(file.length) {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(16_000, Int(file.length) - pcm.count / 2)))
            guard buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] else { throw ComparisonError.invalidFixture }
            pcm.append(Data(bytes: samples, count: Int(buffer.frameLength) * 2))
        }
        guard hash(pcm) == "b1295d561ac7a320eec47d9f5e5ccb58ed4e1e20f52dc3119b445f1d88952b41",
              (try reference.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 4_096 else { throw ComparisonError.invalidFixture }
        return Fixture(pcm: pcm, reference: try String(contentsOf: reference, encoding: .utf8))
    }

    private static func hashFile(_ path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var digest = SHA256()
        var bytes = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            bytes += data.count
            guard bytes <= 5 * 1_024 * 1_024 * 1_024 else { throw ComparisonError.modelTooLarge }
            digest.update(data: data)
        }
        guard bytes > 0 else { throw ComparisonError.emptyModel }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func words(_ value: String) -> [String] { value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
    private static func seconds(_ duration: Duration) -> Double { Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 }

    private static func editDistance(_ left: [String], _ right: [String]) -> Int {
        var previous = Array(0...right.count)
        for (i, word) in left.enumerated() {
            var row = [i + 1] + Array(repeating: 0, count: right.count)
            for (j, other) in right.enumerated() { row[j + 1] = min(previous[j + 1] + 1, row[j] + 1, previous[j] + (word == other ? 0 : 1)) }
            previous = row
        }
        return previous[right.count]
    }

    private static func assertTimestamps(_ result: DetailedTranscriptionResult, duration: Double) {
        XCTAssertEqual(result.words.flatMap { words($0.word) }, words(result.text))
        for word in result.words {
            XCTAssertTrue(word.start.isFinite && word.end.isFinite)
            XCTAssertGreaterThanOrEqual(word.start, 0)
            XCTAssertGreaterThanOrEqual(word.end, word.start)
            XCTAssertLessThanOrEqual(word.end, duration + 0.1)
        }
        for (previous, next) in zip(result.words, result.words.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.start, previous.start)
            XCTAssertGreaterThanOrEqual(next.end, previous.end)
        }
    }

    private struct Resources {
        let cpuSeconds: Double
        let peakRSS: Int
        let system: [String: Any]
    }
    private static func resources() -> Resources {
        var usage = rusage()
        let validUsage = getrusage(RUSAGE_SELF, &usage) == 0
        var loads = [Double](repeating: 0, count: 3)
        let validLoad = getloadavg(&loads, 3) == 3
        let process = ProcessInfo.processInfo
        return Resources(cpuSeconds: Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6,
            peakRSS: Int(usage.ru_maxrss), system: ["getrusage_valid": validUsage, "load_valid": validLoad,
                "load_1_5_15_minutes": loads, "low_power_mode": process.isLowPowerModeEnabled,
                "thermal_state": process.thermalState.rawValue, "logical_cores": process.processorCount,
                "active_cores": process.activeProcessorCount, "physical_memory_bytes": process.physicalMemory,
                "os": process.operatingSystemVersionString])
    }
    private static func report(_ value: [String: Any]) throws {
        let json = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print("WHISPER_HARDWARE_COMPARISON " + String(decoding: json, as: UTF8.self))
        fflush(stdout)
    }
    private enum ComparisonError: Error { case invalidFixture, modelTooLarge, emptyModel }
}
