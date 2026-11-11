import AVFoundation
import CryptoKit
import Foundation
import XCTest
import Shared
@testable import Storage

/// Developer-only authored-audio comparison. No production settings or recordings are changed.
final class AudioCodecComparisonTests: XCTestCase {
    func testExistingAACWriterPreservesAuthoredAudioDurationAndDecodableSignal() async throws {
        let input = try authoredInput()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aac-correctness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = AudioSegmentWriter(storageRoot: root)
        let result = try await writer.writeAudioSegment(audioData: input.data, startTime: 0,
            endTime: input.duration, timestamp: Date(timeIntervalSince1970: 1_700_000_000), source: .microphone)
        let url = root.appendingPathComponent(result.filePath)
        let decoded = try AudioFileDecoder.decodeToPCM(fileURL: url)
        XCTAssertEqual(decoded.sampleRate, 16_000)
        XCTAssertLessThanOrEqual(abs(decoded.data.count - input.data.count), 2048 * 2,
            "Report AAC priming/padding separately; never assume identical sample counts")
        XCTAssertGreaterThan(energy(decoded.data), 0)
        XCTAssertGreaterThan(result.fileSize, 0)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        let range = try await XCTUnwrap(tracks.first).load(.timeRange)
        XCTAssertTrue(range.start.seconds.isFinite)
        XCTAssertEqual(range.duration.seconds, input.duration, accuracy: 2048.0 / 16_000)
    }

    func testExportSupportedAACBitrateComparison() async throws {
        guard let path = ProcessInfo.processInfo.environment["RETRACE_AUDIO_CODEC_EXPORT"], !path.isEmpty else {
            throw XCTSkip("Set RETRACE_AUDIO_CODEC_EXPORT to a new directory for authored codec comparison")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else {
            XCTFail("Export must use a new directory; existing evidence is never overwritten")
            return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = try authoredInput()
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        let aacSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1]
        let outputFormat = try XCTUnwrap(AVAudioFormat(settings: aacSettings))
        let converter = try XCTUnwrap(AVAudioConverter(from: format, to: outputFormat))
        let supported = (converter.applicableEncodeBitRates ?? []).map { $0.intValue }.filter { $0 > 0 }.sorted()
        XCTAssertFalse(supported.isEmpty, "The native converter must report supported rates")
        let rates = Array(Set([supported.first, supported.dropFirst(supported.count / 2).first, supported.last].compactMap { $0 })).sorted()
        var rows: [[String: Any]] = []
        let baselineStart = ProcessInfo.processInfo.systemUptime
        let writer = AudioSegmentWriter(storageRoot: root)
        let baseline = try await writer.writeAudioSegment(audioData: input.data, startTime: 0,
            endTime: input.duration, timestamp: Date(timeIntervalSince1970: 1_700_000_000), source: .microphone)
        let baselineEncode = ProcessInfo.processInfo.systemUptime - baselineStart
        rows.append(try await metrics(root.appendingPathComponent(baseline.filePath), label: "existing_quality_based",
            input: input.data, encodeSeconds: baselineEncode))
        for bitrate in rates {
            let url = root.appendingPathComponent("aac-\(bitrate).m4a")
            var settings = aacSettings
            settings[AVEncoderBitRateKey] = bitrate
            let start = ProcessInfo.processInfo.systemUptime
            do {
                try encode(input.data, format: format, settings: settings, url: url)
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                rows.append(try await metrics(url, label: "aac_\(bitrate)", input: input.data, encodeSeconds: elapsed))
            } catch {
                rows.append(["candidate": "aac_\(bitrate)", "status": "native_encode_or_decode_failed", "error": String(describing: error)])
            }
        }
        let wav = try Data(contentsOf: authoredURL)
        let opusSettings: [String: Any] = [AVFormatIDKey: kAudioFormatOpus,
            AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1]
        let opusFormat = AVAudioFormat(settings: opusSettings)
        let opusConverter = opusFormat.flatMap { AVAudioConverter(from: format, to: $0) }
        let opusRates = (opusConverter?.applicableEncodeBitRates ?? []).map { $0.intValue }.filter { $0 > 0 }.sorted()
        if opusConverter != nil {
            // CAF supports variable packet audio. Let the native encoder choose its default
            // when it does not enumerate rates; never invent an assumed supported bitrate.
            let selectedRate = opusRates.dropFirst(opusRates.count / 2).first
            var settings = opusSettings
            if let selectedRate { settings[AVEncoderBitRateKey] = selectedRate }
            let url = root.appendingPathComponent("experimental-opus.caf")
            let start = ProcessInfo.processInfo.systemUptime
            var encodeSeconds: Double?
            do {
                try encode(input.data, format: format, settings: settings, url: url)
                encodeSeconds = ProcessInfo.processInfo.systemUptime - start
                var row = try await metrics(url, label: "experimental_opus_caf", input: input.data,
                    encodeSeconds: encodeSeconds!, tolerateTrackMetadataFailure: true)
                row["requested_bitrate"] = selectedRate.map { $0 as Any } ?? "native_default"
                rows.append(row)
            } catch {
                var row: [String: Any] = ["candidate": "experimental_opus_caf",
                    "status": encodeSeconds == nil ? "native_encode_failed" : "native_decode_failed",
                    "error": String(describing: error),
                    "attempt_seconds": ProcessInfo.processInfo.systemUptime - start]
                row["encode_seconds"] = encodeSeconds
                row["bytes"] = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size])
                row["requested_bitrate"] = selectedRate.map { $0 as Any } ?? "native_default"
                rows.append(row)
            }
        }
        let report: [String: Any] = ["schema": 1, "input": authoredURL.lastPathComponent,
            "input_sha256": SHA256.hash(data: wav).map { String(format: "%02x", $0) }.joined(),
            "pcm_frames": input.data.count / 2, "sample_rate": 16_000,
            "applicable_aac_bitrates": supported, "candidates": rows,
            "opus": opusConverter != nil ? "experimental_native_CAF_attempted" : "native_converter_unavailable",
            "applicable_opus_bitrates": opusRates,
            "quality_metric": "unaligned_PCM_SNR_dB_and_frame_delta; not listening or transcription accuracy",
            "promotion": "none; representative speech accuracy, listening, timing and latency acceptance remain required"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("comparison.json"), options: .withoutOverwriting)
    }

    private var authoredURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Processing/Tests/Fixtures/WhisperTimedWords/authored.wav")
    }

    private func authoredInput() throws -> AudioFileDecoder.DecodedAudio {
        let input = try AudioFileDecoder.decodeToPCM(fileURL: authoredURL)
        XCTAssertEqual(input.sampleRate, 16_000)
        XCTAssertFalse(input.data.isEmpty)
        return input
    }

    private func encode(_ pcm: Data, format: AVAudioFormat, settings: [String: Any], url: URL) throws {
        let frames = pcm.count / 2
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let output = try XCTUnwrap(buffer.floatChannelData)[0]
        pcm.withUnsafeBytes { bytes in
            for index in 0..<frames {
                output[index] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
            }
        }
        // Scoped file ownership finalizes the encoded container before decode/time/size measurement.
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }

    private func metrics(_ url: URL, label: String, input: Data, encodeSeconds: Double, tolerateTrackMetadataFailure: Bool = false) async throws -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        let decoded = try AudioFileDecoder.decodeToPCM(fileURL: url)
        let decodeSeconds = ProcessInfo.processInfo.systemUptime - started
        var trackMetrics: [String: Any] = [:]
        do {
            let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
            guard let track = tracks.first else {
                throw NSError(domain: "AudioCodecComparison", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No AVAsset audio track for encoded container"])
            }
            let range = try await track.load(.timeRange)
            trackMetrics["track_start_seconds"] = range.start.seconds
            trackMetrics["track_duration_seconds"] = range.duration.seconds
            trackMetrics["track_timing_status"] = "available"
        } catch {
            guard tolerateTrackMetadataFailure else { throw error }
            trackMetrics["track_timing_status"] = "unavailable"
            trackMetrics["track_timing_error"] = String(describing: error)
        }
        let count = min(input.count, decoded.data.count) / 2
        var signal = 0.0, noise = 0.0
        input.withUnsafeBytes { original in
            decoded.data.withUnsafeBytes { restored in
                for index in 0..<count {
                    let x = Double(Int16(littleEndian: original.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
                    let y = Double(Int16(littleEndian: restored.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
                    signal += x * x
                    noise += (x - y) * (x - y)
                }
            }
        }
        let snr = 10 * log10(max(signal, 1) / max(noise, 1))
        var result: [String: Any] = ["candidate": label, "status": "decoded", "bytes": try Data(contentsOf: url).count,
            "encode_seconds": encodeSeconds, "decode_seconds": decodeSeconds,
            "decoded_frames": decoded.data.count / 2, "frame_delta": (decoded.data.count - input.count) / 2,
            "decoded_duration_seconds": decoded.duration,
            "unaligned_pcm_snr_db": snr, "compared_frames": count]
        result.merge(trackMetrics) { _, measured in measured }
        return result
    }

    private func energy(_ pcm: Data) -> Double {
        pcm.withUnsafeBytes { bytes in
            (0..<(pcm.count / 2)).reduce(0.0) { sum, index in
                let value = Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
                return sum + value * value
            }
        }
    }
}
