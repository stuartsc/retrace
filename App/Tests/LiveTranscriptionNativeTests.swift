import AVFoundation
import CryptoKit
import Foundation
import Processing
import Shared
import Speech
import XCTest

/// Explicit, silent authored-PCM replay. No capture device, playback, UI, download or live store.
final class LiveTranscriptionNativeTests: XCTestCase {
    func testPacedAuthoredPCMReportsActualDraftLatency() async throws {
        guard ProcessInfo.processInfo.environment["RETRACE_LIVE_DRAFT_NATIVE_TEST"] == "1" else {
            throw XCTSkip("Opt-in authored on-device streaming comparison")
        }
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-AU")) else {
            throw XCTSkip("Native Australian English speech unavailable")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw XCTSkip("Configured native speech assets not installed; this test never downloads them")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("Processing/Tests/Fixtures/WhisperTimedWords/authored.wav")
        let bytes = try Data(contentsOf: fixture)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "271a49fc227c083978627f4ea436d4f5c155514542d9089390a6885182c3cd00")
        let file = try AVAudioFile(forReading: fixture, commonFormat: .pcmFormatInt16, interleaved: true)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
        let pcm = Data(bytes: samples, count: Int(buffer.frameLength) * 2)
        let generation = UUID(), continuity = UUID()
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream(bufferingPolicy: .bufferingOldest(32))
        let collector = DraftNativeReceipt()
        let recognition = Task {
            try await NativeStreamingSpeechService().run(input: stream) { try await collector.receive($0) }
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            continuation.finish(); recognition.cancel()
        }
        do {
            for _ in 0..<1_000 {
                if await collector.ready { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard await collector.ready else {
                continuation.finish(); recognition.cancel(); _ = await recognition.result
                deadline.cancel(); await deadline.value
                XCTFail("Native preparation did not become ready in ten seconds"); return
            }
            let started = ContinuousClock.now, origin = Date()
            await collector.begin(started)
            var sample = 0
            while sample < pcm.count / 2 {
                let count = min(1_600, pcm.count / 2 - sample)
                let identity = LiveAudioSampleIdentity(recordingGeneration: generation, continuityID: continuity,
                    startSample: Int64(sample), sampleCount: Int64(count), sampleRate: 16_000, approximateOrigin: origin)
                let result = continuation.yield(CapturedAudio(timestamp: origin.addingTimeInterval(Double(sample) / 16_000),
                    audioData: pcm.subdata(in: sample * 2..<(sample + count) * 2), duration: Double(count) / 16_000,
                    source: .microphone, sampleIdentity: identity))
                if case .dropped = result { throw VoiceRecognitionError.droppedInput }
                sample += count
                try await ContinuousClock().sleep(until: started.advanced(by: .seconds(Double(sample) / 16_000)), tolerance: .milliseconds(2))
            }
            continuation.finish()
            try await recognition.value
            deadline.cancel(); await deadline.value
        } catch {
            continuation.finish(); recognition.cancel(); deadline.cancel()
            _ = await recognition.result; await deadline.value
            throw error
        }
        let receipt = await collector.report()
        // Numeric/categorical output only; do not log recognised content.
        let report = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        print("LIVE_DRAFT_NATIVE_AUTHORED " + String(decoding: report, as: UTF8.self))
        XCTAssertGreaterThan(receipt["updates"] ?? 0, 0)
        XCTAssertGreaterThan(receipt["final_updates"] ?? 0, 0)
        XCTAssertGreaterThanOrEqual(receipt["first_update_seconds"] ?? -1, 0)
        XCTAssertLessThanOrEqual(receipt["first_update_seconds"] ?? .infinity, 5,
            "A paced authored first update must meet the five-second target; a failure blocks promotion")
        XCTAssertEqual(receipt["critical_phrase_preserved"], 1,
            "Negation/payment phrase must survive before promoting this native candidate")
    }
}

private actor DraftNativeReceipt {
    var ready = false
    private var started: ContinuousClock.Instant?
    private var first: Double?
    private var updates = 0
    private var finals = 0
    private var finalElapsed: Double?
    private var finalText = ""
    func begin(_ clock: ContinuousClock.Instant) { started = clock }
    func receive(_ event: VoiceRecognitionEvent) throws {
        switch event {
        case .ready: ready = true
        case .discontinuity: throw VoiceRecognitionError.discontinuity
        case .finalized: break
        case .update(let update):
            guard let started else { throw VoiceRecognitionError.invalidInput }
            let d = started.duration(to: .now)
            let elapsed = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            updates += 1
            if first == nil, !update.text.isEmpty { first = elapsed }
            if update.isFinal { finals += 1; finalElapsed = elapsed; finalText += " " + update.text }
        }
    }
    func report() -> [String: Double] {
        let normal = finalText.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        return ["updates": Double(updates), "final_updates": Double(finals),
            "first_update_seconds": first ?? -1, "last_final_seconds": finalElapsed ?? -1,
            "critical_phrase_preserved": normal.contains("do not approve the payment") ? 1 : 0,
            "final_word_count": Double(normal.split(separator: " ").count), "audio_seconds": 10.7316875]
    }
}
