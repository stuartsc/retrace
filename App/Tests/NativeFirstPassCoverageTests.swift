import Foundation
import XCTest
import Shared
@testable import App

final class NativeFirstPassCoverageTests: XCTestCase {
    func testFinalTextAndSilenceNeverInventCoverage() throws {
        let source = identity(), batch = try proof(source)
        var ledger = NativeFirstPassCoverage()
        try ledger.receive(.update(update(source, text: "Twelve dollars", final: true)))
        XCTAssertNil(ledger.result(for: batch), "Final text is not a coverage barrier")
        try ledger.receive(.finalized(recordingGeneration: source.recordingGeneration,
            continuityID: source.continuityID, throughSample: 8_000))
        XCTAssertNil(ledger.result(for: batch), "A partial acknowledgement cannot cover silence after it")
        try ledger.receive(.finalized(recordingGeneration: source.recordingGeneration,
            continuityID: source.continuityID, throughSample: 16_000))
        XCTAssertEqual(ledger.result(for: batch)?.text, "Twelve dollars")
        let other = identity()
        XCTAssertNil(ledger.result(for: try proof(other)))
        ledger.reset()
        XCTAssertNil(ledger.result(for: batch))
    }

    func testRevisedDraftReplacesTextBeforeFinalizationAndCannotRewriteSettledWords() throws {
        let source = identity(), batch = try proof(source)
        var ledger = NativeFirstPassCoverage()
        try ledger.receive(.update(update(source, text: "Twenty dollars")))
        try ledger.receive(.update(update(source, text: "Twelve dollars", final: true)))
        try ledger.receive(.finalized(recordingGeneration: source.recordingGeneration,
            continuityID: source.continuityID, throughSample: 16_000))
        XCTAssertEqual(ledger.result(for: batch)?.text, "Twelve dollars")
        XCTAssertThrowsError(try ledger.receive(.update(update(source, text: "Wrong amount"))))
        XCTAssertNil(ledger.result(for: batch))
    }

    func testCrossingBatchEdgesRequireCompleteExactTokens() throws {
        let source = identity()
        let request = LiveAudioSampleIdentity(recordingGeneration: source.recordingGeneration,
            continuityID: source.continuityID, startSample: 8_000, sampleCount: 8_000,
            sampleRate: 16_000, approximateOrigin: source.approximateOrigin)
        var ledger = NativeFirstPassCoverage()
        try ledger.receive(.update(update(source, text: "First Second")))
        try ledger.receive(.finalized(recordingGeneration: source.recordingGeneration,
            continuityID: source.continuityID, throughSample: 16_000))
        XCTAssertNil(ledger.result(for: try proof(request)))
        ledger.reset()
        try ledger.receive(.update(.init(source: source, startSample: 0, endSample: 16_000,
            text: "First Second", tokens: [
                .init(text: "First ", startSample: 0, endSample: 8_000, hasStartBoundary: true, hasEndBoundary: true),
                .init(text: "Second", startSample: 8_000, endSample: 16_000, hasStartBoundary: true, hasEndBoundary: true)
            ], isFinal: true)))
        try ledger.receive(.finalized(recordingGeneration: source.recordingGeneration,
            continuityID: source.continuityID, throughSample: 16_000))
        XCTAssertEqual(ledger.result(for: try proof(request))?.text, "Second")
    }

    func testProofRejectsUnmappedSystemAndPartialCoverage() throws {
        let source = identity()
        XCTAssertNil(NativeFirstPassBatch(rawBatchID: 1, relativePath: "audio/test.m4a",
            encodedSHA256: String(repeating: "a", count: 64), frameCount: 16_000, source: .system,
            sampleRate: 16_000, channels: 1, ranges: [.init(source: source, batchStartSample: 0)], mappingIncomplete: false))
        XCTAssertNil(NativeFirstPassBatch(rawBatchID: 1, relativePath: "audio/test.m4a",
            encodedSHA256: String(repeating: "a", count: 64), frameCount: 16_001, source: .microphone,
            sampleRate: 16_000, channels: 1, ranges: [.init(source: source, batchStartSample: 0)], mappingIncomplete: false))
    }

    func testContinuousInputUsesOnlyOrderedAcknowledgementAndPauseRevokesReuse() async throws {
        let recognizer = FirstPassFixtureRecognizer()
        let owner = LiveTranscriptionController(changed: {}, makeRecognizer: { recognizer })
        await owner.setNativeFirstPassEnabled(true)
        await owner.setEnabled(true); await owner.setRecording(true)
        try await wait { await owner.snapshot().state == .listening }
        let source = identity()
        owner.input.offer(.init(timestamp: source.approximateOrigin, audioData: Data(repeating: 1, count: 32_000),
            duration: 1, source: .microphone, sampleIdentity: source))
        try await wait { await owner.snapshot().spans.count == 1 }
        let batch = try proof(source)
        let request = Task { try await owner.firstPass(for: batch) }
        try await wait { await recognizer.requested }
        let before = await recognizer.running
        XCTAssertTrue(before, "The microphone input stream must stay open during finalization")
        await recognizer.acknowledge()
        let result = try await request.value
        XCTAssertEqual(result?.text, "Native first pass")
        await owner.setRecording(false)
        let after = try await owner.firstPass(for: batch)
        XCTAssertNil(after)
        let running = await recognizer.running
        XCTAssertFalse(running, "Pause must join the native owner")
        await owner.close()
    }

    func testNoAcknowledgementFallsBackAndSourceStopRetiresThenRestarts() async throws {
        let recognizer = FirstPassFixtureRecognizer()
        let owner = LiveTranscriptionController(sourceIdleTimeout: .milliseconds(30), changed: {}, makeRecognizer: { recognizer })
        await owner.setNativeFirstPassEnabled(true)
        await owner.setEnabled(true); await owner.setRecording(true)
        try await wait { await owner.snapshot().state == .listening }
        let source = identity()
        let packet = CapturedAudio(timestamp: source.approximateOrigin, audioData: Data(repeating: 1, count: 32_000),
            duration: 1, source: .microphone, sampleIdentity: source)
        owner.input.offer(packet)
        try await wait { await owner.snapshot().spans.count == 1 }
        let start = ContinuousClock.now
        let result = try await owner.firstPass(for: try proof(source))
        XCTAssertNil(result, "Request completion cannot stand in for consumed result acknowledgement")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        await owner.checkConditions()
        let stopped = await owner.snapshot(), running = await recognizer.running
        XCTAssertEqual(stopped.state, .waitingForMicrophone)
        XCTAssertFalse(running)
        await owner.checkConditions()
        let starts = await recognizer.starts
        XCTAssertEqual(starts, 1, "No model restart loop while the microphone is disabled")
        owner.input.offer(packet)
        await owner.checkConditions()
        try await wait { await recognizer.starts == 2 }
        await owner.close()
    }

    private func identity() -> LiveAudioSampleIdentity {
        .init(recordingGeneration: UUID(), continuityID: UUID(), startSample: 0, sampleCount: 16_000,
            sampleRate: 16_000, approximateOrigin: Date())
    }
    private func proof(_ source: LiveAudioSampleIdentity) throws -> NativeFirstPassBatch {
        try XCTUnwrap(.init(rawBatchID: 1, relativePath: "audio/test.m4a", encodedSHA256: String(repeating: "a", count: 64),
            frameCount: source.sampleCount, source: .microphone, sampleRate: 16_000, channels: 1,
            ranges: [.init(source: source, batchStartSample: 0)], mappingIncomplete: false))
    }
    private func update(_ source: LiveAudioSampleIdentity, text: String, final: Bool = false) -> VoiceRecognitionUpdate {
        .init(source: source, startSample: 0, endSample: 16_000, text: text, tokens: [], isFinal: final)
    }
    private func wait(_ check: () async -> Bool) async throws {
        for _ in 0..<200 { if await check() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Native fixture did not settle")
    }
}

private actor FirstPassFixtureRecognizer: VoiceRecognitionProtocol {
    var running = false
    var requested = false
    var starts = 0
    private var receipt: (@Sendable (VoiceRecognitionEvent) async throws -> Void)?
    private var source: LiveAudioSampleIdentity?
    func requestFinalization(source: LiveAudioSampleIdentity, throughSample: Int64) { requested = true }
    func acknowledge() async {
        guard let source else { return }
        try? await receipt?(.finalized(recordingGeneration: source.recordingGeneration,
            continuityID: source.continuityID, throughSample: source.startSample + source.sampleCount))
    }
    func run(input: AsyncStream<CapturedAudio>, receive: @escaping @Sendable (VoiceRecognitionEvent) async throws -> Void) async throws {
        starts += 1; running = true; receipt = receive
        defer { running = false; receipt = nil; source = nil }
        try await receive(.ready)
        for await audio in input {
            try Task.checkCancellation()
            guard let source = audio.sampleIdentity else { throw VoiceRecognitionError.invalidInput }
            self.source = source
            try await receive(.update(.init(source: source, startSample: source.startSample,
                endSample: source.startSample + source.sampleCount, text: "Native first pass", tokens: [], isFinal: false)))
        }
    }
}
