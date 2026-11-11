import AVFoundation
import CryptoKit
import Foundation
import Shared
import Storage
import XCTest
@testable import Processing

/// Explicit developer measurement on versioned authored Australian TTS only.
/// Recognition differences are recorded, never turned into a promotion assertion.
final class AudioChunkBoundaryComparisonTests: XCTestCase {
    func testPinnedBoundaryInputAndLegacyWindowGeometry() async throws {
        let fixture = try Self.fixture()
        XCTAssertEqual(fixture.pcm.count, 686_828)
        XCTAssertEqual(Self.tokens(fixture.reference).count, 64)
        let batches = await Self.legacyBatches(fixture.pcm)
        XCTAssertEqual(batches.map { $0.audioData.count / 2 }, [240_000, 183_414])
        XCTAssertEqual(batches.map { $0.startTimestamp.timeIntervalSince(Self.origin) }, [0, 10])
        XCTAssertEqual(batches[0].audioData.suffix(160_000), batches[1].audioData.prefix(160_000))
        XCTAssertEqual(Self.distance(["before", "sending", "reply"], ["before", "reply"]), 1)
    }

    func testExplicitNativeCPUComparisonAcrossTenSecondChunkBoundaries() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelValue = environment["RETRACE_WHISPER_COMPARISON_MODEL"], !modelValue.isEmpty,
              let exportValue = environment["RETRACE_AUDIO_BOUNDARY_EXPORT"], !exportValue.isEmpty else {
            throw XCTSkip("Set RETRACE_WHISPER_COMPARISON_MODEL and RETRACE_AUDIO_BOUNDARY_EXPORT to compare authored native CPU boundary accuracy")
        }
        let model = NSString(string: modelValue).expandingTildeInPath
        let export = URL(fileURLWithPath: NSString(string: exportValue).expandingTildeInPath, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: export.path) else {
            XCTFail("The boundary export directory must be new; retained measurements are never overwritten")
            return
        }
        let fixture = try Self.fixture()
        let modelHash = try Self.hashFile(URL(fileURLWithPath: model), maximum: 5 * 1_024 * 1_024 * 1_024)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        let repeats = min(3, max(1, Int(environment["RETRACE_AUDIO_BOUNDARY_REPEATS"] ?? "1") ?? 1))
        let media = AudioChunkMediaStore(storageRoot: export.appendingPathComponent("chunked"), storeID: UUID())
        let legacyWriter = AudioSegmentWriter(storageRoot: export.appendingPathComponent("legacy"))
        let service = WhisperCppTranscriptionService(modelPath: model, useGPU: false)
        var windows: [StoredAudioWindow] = []
        let stream = UUID()
        var previous: AudioChunkDescriptor?
        for first in stride(from: 0, to: fixture.pcm.count / 2, by: 160_000) {
            let end = min(fixture.pcm.count / 2, first + 160_000)
            let input = AudioChunkInput(streamID: stream, source: .system, origin: Self.origin,
                startFrame: Int64(first), pcmData: fixture.pcm.subdata(in: first * 2..<end * 2))
            let window = try await media.persistChunk(input, previous: previous)
            windows.append(window)
            previous = window.manifest.ranges.last?.chunk
        }
        var legacy: [(batch: AudioBatch, pcm: Data, bytes: Int64, path: String)] = []
        for batch in await Self.legacyBatches(fixture.pcm) {
            let file = try await legacyWriter.writeFullBatch(audioData: batch.audioData,
                timestamp: batch.startTimestamp, source: batch.source)
            let decoded = try AudioFileDecoder.decodeToPCM(fileURL: legacyWriter.storageRoot.appendingPathComponent(file.filePath))
            XCTAssertEqual(decoded.data.count, batch.audioData.count)
            legacy.append((batch, decoded.data, file.fileSize, file.filePath))
        }
        var comparisons: [[String: Any]] = []
        do {
            try await service.initialize()
            for repeatIndex in 1...repeats {
                var legacyRows: [[String: Any]] = []
                var legacyWords: [TimedWord] = []
                var previousLegacyWords: [TranscriptionWord] = []
                var previousLegacyDuration = 0.0
                for item in legacy {
                    let started = ContinuousClock.now
                    let result = try await Self.transcribeLegacyTimedGeometry(service, pcm: item.pcm)
                    let elapsed = Self.seconds(started.duration(to: .now))
                    Self.checkTimestamps(result, frames: item.pcm.count / 2)
                    // Frozen existing five-second timestamp/text overlap rule.
                    // This comparison does not substitute it into production.
                    let kept = result.words.filter { word in
                        guard word.start < 5 else { return true }
                        let previousTime = previousLegacyDuration - 5 + word.start
                        return !previousLegacyWords.contains {
                            abs($0.start - previousTime) < 0.3 && $0.word.lowercased() == word.word.lowercased()
                        }
                    }
                    let offset = item.batch.startTimestamp.timeIntervalSince(Self.origin)
                    legacyWords.append(contentsOf: Self.absolute(kept, offset: offset))
                    legacyRows.append(Self.row(result, kept: kept, offset: offset, elapsed: elapsed,
                        frames: item.pcm.count / 2, path: "legacy/" + item.path))
                    previousLegacyDuration = Double(item.pcm.count) / 32_000
                    previousLegacyWords = result.words.filter { $0.start >= previousLegacyDuration - 5 }
                }
                var candidateRows: [[String: Any]] = []
                var candidateWords: [TimedWord] = []
                for window in windows {
                    let lease = try await media.readWindow(window)
                    do {
                        let started = ContinuousClock.now
                        let decision = try await Self.transcribeCandidateFirstPass(service, pcm: lease.pcmData)
                        let result = decision.transcription
                        let elapsed = Self.seconds(started.duration(to: .now))
                        Self.checkTimestamps(result, frames: lease.pcmData.count / 2)
                        let input = AudioTranscriptionInput(data: lease.pcmData, sampleRate: 16_000,
                            duration: Double(window.manifest.frameCount) / 16_000,
                            startTime: window.manifest.startTime, window: window, lease: lease)
                        let kept: [TranscriptionWord]
                        let ownershipError: String?
                        do { kept = try input.ownedTranscript(result).words; ownershipError = nil }
                        catch { kept = []; ownershipError = String(describing: error) }
                        let offset = window.manifest.startTime.timeIntervalSince(Self.origin)
                        candidateWords.append(contentsOf: Self.absolute(kept, offset: offset))
                        var row = Self.row(result, kept: kept, offset: offset, elapsed: elapsed,
                            frames: lease.pcmData.count / 2, path: "chunked/" + window.relativePath)
                        row["owned_start_frame"] = window.manifest.ownedStartFrame
                        row["ownership_error"] = ownershipError ?? "none"
                        row["profile"] = "liveFirstPass"
                        row["require_word_timings"] = true
                        row["attempts"] = decision.attempts
                        row["selected_audio_variant"] = decision.audioVariant.rawValue
                        row["selected_language_hint"] = decision.languageHint.rawValue
                        row["status"] = decision.status.rawValue
                        row["quality_flags"] = decision.qualityFlags
                        candidateRows.append(row)
                        await media.release(lease)
                    } catch {
                        await media.release(lease)
                        throw error
                    }
                }
                let expected = Self.tokens(fixture.reference)
                let old = legacyWords.flatMap { Self.tokens($0.word) }
                let new = candidateWords.flatMap { Self.tokens($0.word) }
                var boundaries: [[String: Any]] = []
                for boundary: Double in [10.0, 20.0] {
                    var legacyNear: [[String: Any]] = []
                    var candidateNear: [[String: Any]] = []
                    var crossing: [[String: Any]] = []
                    for word in legacyWords {
                        if word.end >= boundary - 1 && word.start <= boundary + 1 { legacyNear.append(word.json) }
                        if word.start < boundary && word.end > boundary { crossing.append(word.json) }
                    }
                    for word in candidateWords {
                        if word.end >= boundary - 1 && word.start <= boundary + 1 { candidateNear.append(word.json) }
                    }
                    var entry: [String: Any] = [:]
                    entry["second"] = boundary
                    entry["legacy_words_near_boundary"] = legacyNear
                    entry["candidate_owned_words_near_boundary"] = candidateNear
                    entry["legacy_model_spans_crossing_boundary"] = crossing
                    boundaries.append(entry)
                }
                comparisons.append([
                    "iteration": repeatIndex, "legacy_windows": legacyRows, "candidate_windows": candidateRows,
                    "legacy_word_error_rate": Double(Self.distance(expected, old)) / Double(expected.count),
                    "candidate_word_error_rate": Double(Self.distance(expected, new)) / Double(expected.count),
                    "legacy_to_candidate_word_edits": Self.distance(old, new),
                    "legacy_words": old, "candidate_owned_words": new,
                    "matched_token_timing_differences": Self.timingDifferences(legacyWords, candidateWords),
                    "boundaries": boundaries
                ])
            }
            await service.cleanup()
            await media.close()
        } catch {
            await service.cleanup()
            await media.close()
            throw error
        }
        let chunks = windows.compactMap { $0.manifest.ranges.last?.chunk }
        let legacyBytes = legacy.reduce(Int64(0)) { $0 + $1.bytes }
        let candidateBytes = chunks.reduce(Int64(0)) { $0 + $1.encodedBytes }
        let report: [String: Any] = [
            "schema": 2, "fixture": "two_sequential_copies_of_WhisperTimedWords/authored.wav",
            "fixture_kind": "authored_Karen_en_AU_TTS_not_human_accent_coverage",
            "source_pcm_sha256": Self.sha(fixture.pcm), "source_pcm_frames": fixture.pcm.count / 2,
            "reference": fixture.reference, "model_file": URL(fileURLWithPath: model).lastPathComponent,
            "model_sha256": modelHash, "backend": "CPU_requested", "threads": 2,
            "legacy_arm": "native_forced_timed_word_geometry_with_frozen_overlap_rule",
            "candidate_arm": "liveFirstPass_retry_quality_policy_with_required_word_timings_and_exact_window_ownership",
            "legacy_window_frames": legacy.map { $0.pcm.count / 2 },
            "candidate_unique_chunk_frames": chunks.map(\.frameCount),
            "candidate_decode_contracts": Array(Set(chunks.compactMap { $0.decodeContract?.rawValue })).sorted(),
            "candidate_pcm_hash_scope": "encode_time_native_verification_diagnostic_for_nativeAACPCM16V1",
            "candidate_media_read_integrity": "exact_encoded_SHA256_bytes_packet_and_valid_frame_metadata_bounded_finite_decode_and_file_identity",
            "legacy_encoded_bytes": legacyBytes, "candidate_encoded_bytes": candidateBytes,
            "encoded_media_byte_saving_fraction": 1 - Double(candidateBytes) / Double(legacyBytes),
            "byte_scope": "AAC_files_only_excludes_manifests_receipts_journals_filesystem_allocation",
            "comparisons": comparisons,
            "limits": ["Native ASR timestamps are hypotheses, not a word-timing oracle.",
                       "The legacy arm forces timed words for geometry comparison; existing live first pass requests text-only timing and also uses retry/quality policy.",
                       "The candidate arm uses its retry/quality path, but neither arm runs segmentation, database publication or the complete live capture lifecycle.",
                       "Word-start ownership prevents duplicate attribution but does not guarantee recovery of words truncated at a chunk boundary.",
                       "This single authored repeated phrase is not representative codec/recognition/latency acceptance.",
                       "Candidate stays default-off; no backend, model or storage setting is promoted."]
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: export.appendingPathComponent("boundary-comparison.json"), options: .withoutOverwriting)
        print("AUDIO_CHUNK_BOUNDARY_COMPARISON exported \(repeats) authored native CPU comparison(s)")
    }

    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private struct Fixture { let pcm: Data; let reference: String }
    private static func fixture() throws -> Fixture {
        let audio = try XCTUnwrap(Bundle.module.url(forResource: "authored", withExtension: "wav", subdirectory: "WhisperTimedWords"))
        let reference = try XCTUnwrap(Bundle.module.url(forResource: "reference", withExtension: "txt", subdirectory: "WhisperTimedWords"))
        let file = try AVAudioFile(forReading: audio, commonFormat: .pcmFormatInt16, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              file.length == 171_707,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000) else {
            throw AudioChunkMediaError.invalidReceipt
        }
        var pcm = Data()
        while pcm.count / 2 < Int(file.length) {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(16_000, Int(file.length) - pcm.count / 2)))
            guard buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] else { throw AudioChunkMediaError.invalidReceipt }
            pcm.append(Data(bytes: samples, count: Int(buffer.frameLength) * 2))
        }
        guard sha(pcm) == "b1295d561ac7a320eec47d9f5e5ccb58ed4e1e20f52dc3119b445f1d88952b41" else {
            throw AudioChunkMediaError.invalidReceipt
        }
        let text = try String(contentsOf: reference, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return Fixture(pcm: pcm + pcm, reference: text + " " + text)
    }
    private static func legacyBatches(_ pcm: Data) async -> [AudioBatch] {
        let buffer = AudioBufferManager(maxBufferDuration: 15)
        var batches: [AudioBatch] = []
        for first in stride(from: 0, to: pcm.count / 2, by: 16_000) {
            let end = min(pcm.count / 2, first + 16_000)
            let capture = CapturedAudio(timestamp: origin.addingTimeInterval(Double(first) / 16_000),
                audioData: pcm.subdata(in: first * 2..<end * 2), duration: Double(end - first) / 16_000, source: .system)
            if let batch = await buffer.addSample(capture) { batches.append(batch) }
        }
        batches.append(contentsOf: await buffer.flush())
        return batches
    }
    private static func transcribeLegacyTimedGeometry(_ service: WhisperCppTranscriptionService, pcm: Data) async throws -> DetailedTranscriptionResult {
        let permit = BackgroundProcessingPermit(threadCount: 2)
        return try await BackgroundProcessingContext.$permit.withValue(permit) {
            try await service.transcribeWithTimestamps(pcm, wordLevel: true, initialPrompt: nil, languageHint: "en")
        }
    }
    private static func transcribeCandidateFirstPass(_ service: WhisperCppTranscriptionService, pcm: Data) async throws -> AudioTranscriptionDecision {
        let permit = BackgroundProcessingPermit(threadCount: 2)
        return try await BackgroundProcessingContext.$permit.withValue(permit) {
            try await AudioTranscriptionRetryPipeline.transcribeBest(audioData: pcm, sampleRate: 16_000,
                channels: 1, transcriptionService: service, wordLevel: true, initialPrompt: nil,
                profile: .liveFirstPass, requireWordTimings: true)
        }
    }
    private struct TimedWord {
        let word: String; let start: Double; let end: Double
        var json: [String: Any] { ["word": word, "start": start, "end": end] }
    }
    private static func absolute(_ words: [TranscriptionWord], offset: Double) -> [TimedWord] {
        words.map { TimedWord(word: $0.word, start: $0.start + offset, end: $0.end + offset) }
    }
    private static func row(_ result: DetailedTranscriptionResult, kept: [TranscriptionWord], offset: Double,
                            elapsed: Double, frames: Int, path: String) -> [String: Any] {
        ["path": path, "decoded_frames": frames, "window_start_seconds": offset,
         "inference_seconds": elapsed, "raw_text": result.text,
         "raw_absolute_words": absolute(result.words, offset: offset).map(\.json),
         "kept_absolute_words": absolute(kept, offset: offset).map(\.json)]
    }
    private static func checkTimestamps(_ result: DetailedTranscriptionResult, frames: Int) {
        for word in result.words {
            XCTAssertTrue(word.start.isFinite && word.end.isFinite)
            XCTAssertGreaterThanOrEqual(word.start, 0)
            XCTAssertGreaterThanOrEqual(word.end, word.start)
            XCTAssertLessThanOrEqual(word.end, Double(frames) / 16_000 + 0.1)
        }
    }
    private static func timingDifferences(_ left: [TimedWord], _ right: [TimedWord]) -> [[String: Any]] {
        let a = left.flatMap { word in tokens(word.word).map { TimedWord(word: $0, start: word.start, end: word.end) } }
        let b = right.flatMap { word in tokens(word.word).map { TimedWord(word: $0, start: word.start, end: word.end) } }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in (0..<a.count).reversed() {
            for j in (0..<b.count).reversed() {
                table[i][j] = a[i].word == b[j].word ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var i = 0, j = 0
        var matched: [[String: Any]] = []
        while i < a.count, j < b.count {
            if a[i].word == b[j].word {
                matched.append(["token": a[i].word, "legacy_token_index": i, "candidate_token_index": j,
                    "candidate_minus_legacy_start_seconds": b[j].start - a[i].start,
                    "candidate_minus_legacy_end_seconds": b[j].end - a[i].end])
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return matched
    }
    private static func distance(_ a: [String], _ b: [String]) -> Int {
        var previous = Array(0...b.count)
        for (i, word) in a.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, other) in b.enumerated() { next[j + 1] = min(previous[j + 1] + 1, next[j] + 1, previous[j] + (word == other ? 0 : 1)) }
            previous = next
        }
        return previous[b.count]
    }
    private static func hashFile(_ url: URL, maximum: Int) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256(), size = 0
        while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty {
            size += bytes.count
            guard size <= maximum else { throw AudioChunkMediaError.invalidReceipt }
            hash.update(data: bytes)
        }
        guard size > 0 else { throw AudioChunkMediaError.invalidReceipt }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func tokens(_ value: String) -> [String] { value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
    private static func seconds(_ value: Duration) -> Double { Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18 }
}
