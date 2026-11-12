import AVFoundation
import Foundation
import Processing
import Shared
import Storage
import XCTest
@testable import App

/// Explicit authored speech only. This does not access microphones, live files,
/// preferences or the installed app, and does not establish physical-Mac latency.
final class NativeSpokenMarkerValidationTests: XCTestCase {
    func testNativeAACStreamingRepeatedPhrasesAndNearMissWithDurableAcknowledgements() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        guard let path = ProcessInfo.processInfo.environment["RETRACE_STREAM_VALIDATION_AUDIO"] else {
            throw XCTSkip("Set an explicit authored speech file")
        }
        if ProcessInfo.processInfo.environment["RETRACE_STREAM_PREPARE_ASSETS"] == "1" {
            try await NativeStreamingSpeechService.prepareAssets()
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let inputFile = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard inputFile.length > 0, Double(inputFile.length) / inputFile.processingFormat.sampleRate <= 60 else {
            XCTFail("Authored input must be between zero and sixty seconds"); return
        }
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: AVAudioFrameCount(inputFile.length)))
        try inputFile.read(into: input)
        let pcm = try Self.convert(input)
        let saved = try await AudioSegmentWriter(storageRoot: root).writeFullBatch(audioData: pcm, timestamp: Date(), source: .microphone)
        let restored = try ExactAudioDecoder.decode(aac: Data(contentsOf: root.appendingPathComponent(saved.filePath)), expectedFrames: Int64(pcm.count / 2))
        let storeID = UUID(), generation = UUID(), continuity = UUID()
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { storeID })
        let rule = try await markers.saveKeywordRule(.init(phrase: "Purple banana", name: "Remember", meaning: "Preserve this context", enabled: true), expectedRevision: nil)
        let readiness = expectation(description: "real native streaming recognizer prepared")
        let collector = NativeMarkerCollector(markers: markers, storeID: storeID, rule: rule, ready: readiness)
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let recognition = Task {
            try await NativeStreamingSpeechService().run(input: stream) { try await collector.receive($0) }
        }
        // A failure before ready is surfaced by the task below, not interpreted as readiness.
        await fulfillment(of: [readiness], timeout: 30)
        let started = ContinuousClock.now
        let originalOffset: Int64 = 80_000
        let origin = Date().addingTimeInterval(-Double(originalOffset) / 16_000)
        var sample = 0
        do {
            while sample < restored.count / 2 {
                let count = min(1_600, restored.count / 2 - sample)
                let identity = LiveAudioSampleIdentity(recordingGeneration: generation, continuityID: continuity,
                    startSample: originalOffset + Int64(sample), sampleCount: Int64(count), sampleRate: 16_000, approximateOrigin: origin)
                let result = continuation.yield(CapturedAudio(timestamp: origin.addingTimeInterval(Double(identity.startSample) / 16_000),
                    audioData: restored.subdata(in: sample * 2..<(sample + count) * 2), duration: Double(count) / 16_000,
                    source: .microphone, sampleRate: 16_000, channels: 1, sampleIdentity: identity))
                if case .dropped = result { throw VoiceRecognitionError.droppedInput }
                sample += count
                try await ContinuousClock().sleep(until: started.advanced(by: .seconds(Double(sample) / 16_000)), tolerance: .milliseconds(2))
            }
            continuation.finish()
            try await recognition.value
        } catch {
            continuation.finish(); recognition.cancel(); _ = await recognition.result
            try await markers.close()
            throw error
        }
        let page = try await markers.listMarkers(.init())
        let expected = Int(ProcessInfo.processInfo.environment["RETRACE_STREAM_EXPECTED_MARKERS"] ?? "2") ?? 2
        XCTAssertEqual(page.markers.count, expected, "Repeated utterances remain separate; near-miss text does not trigger")
        for marker in page.markers {
            let observation = try XCTUnwrap(marker.spokenObservation)
            XCTAssertEqual(observation.status, .confirmed)
            XCTAssertEqual(observation.anchor.recordingGeneration, generation)
            XCTAssertEqual(observation.anchor.continuityID, continuity)
            XCTAssertGreaterThanOrEqual(observation.anchor.startSample, originalOffset)
            XCTAssertLessThanOrEqual(observation.anchor.endSample, originalOffset + Int64(restored.count / 2) + 1_600)
        }
        let report = await collector.report()
        print("NATIVE_STREAM_AUTHORED " + report)
        // A new, pre-cancelled run must not begin model work or retain a native task.
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await NativeStreamingSpeechService().run(input: AsyncStream { $0.finish() }) { _ in }
        }
        do { try await cancelled.value; XCTFail("Pre-cancelled native analysis") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await markers.close()
    }

    private static func convert(_ input: AVAudioPCMBuffer) throws -> Data {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let converter = try XCTUnwrap(AVAudioConverter(from: input.format, to: format))
        var delivered = false, output = Data()
        while true {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192))
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, state in
                if !delivered { delivered = true; state.pointee = .haveData; return input }
                state.pointee = .endOfStream; return nil
            }
            if let error { throw error }
            XCTAssertNotEqual(status, .error)
            if buffer.frameLength > 0 {
                output.append(Data(bytes: try XCTUnwrap(buffer.int16ChannelData?[0]), count: Int(buffer.frameLength) * 2))
            }
            if status == .endOfStream { return output }
            guard status != .error, buffer.frameLength > 0 else { throw VoiceRecognitionError.invalidInput }
        }
    }
}

private actor NativeMarkerCollector {
    let markers: TimelineMarkerService
    let storeID: UUID
    let ready: XCTestExpectation
    var matcher: VoicePhraseMatcher
    var revisions: [UUID: UUID] = [:]
    var acknowledgements: [Double] = []
    var updates = 0
    init(markers: TimelineMarkerService, storeID: UUID, rule: KeywordRule, ready: XCTestExpectation) {
        self.markers = markers; self.storeID = storeID; self.ready = ready
        matcher = VoicePhraseMatcher(rules: [rule])
    }
    func receive(_ event: VoiceRecognitionEvent) async throws {
        let changes: [VoicePhraseChange]
        switch event {
        case .ready: ready.fulfill(); return
        case .discontinuity: throw VoiceRecognitionError.discontinuity
        case .update(let update): updates += 1; changes = try matcher.receive(update)
        case .finalized(let generation, let continuity, let through):
            changes = matcher.finalize(recordingGeneration: generation, continuityID: continuity, throughSample: through)
        }
        for change in changes {
            let previous = revisions[change.occurrenceID]
            let anchor = SpokenMarkerAnchor(nativeStoreID: storeID, recordingGeneration: change.source.recordingGeneration,
                continuityID: change.source.continuityID, startSample: change.startSample, endSample: change.endSample,
                approximateOrigin: change.source.approximateOrigin, timingPrecision: change.precision)
            let receipt = try await markers.applySpokenObservation(.init(occurrenceID: change.occurrenceID,
                expectedRevision: previous, status: change.status, anchor: anchor, ruleSnapshot: change.rule,
                matchedPhrase: change.matchedPhrase, explanation: change.explanation))
            revisions[change.occurrenceID] = receipt.observation.revision
            if previous == nil {
                acknowledgements.append(Date().timeIntervalSince(anchor.approximateOrigin.addingTimeInterval(Double(anchor.endSample) / 16_000)) * 1_000)
            }
        }
    }
    func report() -> String {
        let object: [String: Any] = ["native_updates": updates, "durable_occurrences": revisions.count,
            "ack_ms_from_native_phrase_end": acknowledgements, "physical_microphone_acceptance": false]
        let bytes = (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? Data()
        return String(decoding: bytes, as: UTF8.self)
    }
}
