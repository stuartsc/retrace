import Foundation
import XCTest
import Shared
@testable import App

final class LiveTranscriptionControllerTests: XCTestCase {
    func testDisabledCandidateStartsNoRecognizerAndSystemPacketsAreIgnored() async throws {
        let recognizer = DraftFixtureRecognizer()
        let owner = LiveTranscriptionController(changed: {}, makeRecognizer: { recognizer })
        await owner.setRecording(true)
        let starts = await recognizer.starts
        XCTAssertEqual(starts, 0)
        await owner.setEnabled(true)
        try await wait { await owner.snapshot().state == .listening }
        owner.input.offer(packet(source: .system))
        try await Task.sleep(for: .milliseconds(20))
        let empty = await owner.snapshot()
        XCTAssertTrue(empty.spans.isEmpty)
        owner.input.offer(packet())
        try await wait { await owner.snapshot().text == "corrected draft" }
        let snapshot = await owner.snapshot()
        XCTAssertEqual(snapshot.spans.count, 1)
        XCTAssertTrue(snapshot.spans[0].isFinal)
        XCTAssertNotNil(snapshot.firstUpdateMilliseconds)
        await owner.close()
        let closed = await owner.snapshot()
        XCTAssertEqual(closed.state, .stopped)
        XCTAssertTrue(closed.spans.isEmpty)
    }

    func testMissingAssetsLeavesRecordingPipelineIndependentAndReportsFallback() async throws {
        let owner = LiveTranscriptionController(changed: {}, makeRecognizer: { MissingDraftRecognizer() })
        await owner.setRecording(true); await owner.setEnabled(true)
        try await wait { await owner.snapshot().state == .missingAssets }
        owner.input.offer(packet()) // No recorder/SQLite call exists on the preview owner.
        let value = await owner.snapshot()
        XCTAssertTrue(value.enabled)
        XCTAssertTrue(value.text.isEmpty)
        await owner.close()
    }

    func testPauseJoinsRecognizerAndClearsPreview() async throws {
        let recognizer = DraftFixtureRecognizer()
        let owner = LiveTranscriptionController(changed: {}, makeRecognizer: { recognizer })
        await owner.setEnabled(true); await owner.setRecording(true)
        try await wait { await owner.snapshot().state == .listening }
        owner.input.offer(packet())
        try await wait { await owner.snapshot().spans.count == 1 }
        await owner.setRecording(false)
        let stopped = await owner.snapshot(), running = await recognizer.running
        XCTAssertFalse(running)
        XCTAssertEqual(stopped.state, .waitingForMicrophone)
        XCTAssertTrue(stopped.spans.isEmpty)
        await owner.close()
    }

    func testSourceContinuityChangeClearsDraftInsteadOfCombiningDifferentRecordings() async throws {
        let recognizer = DraftFixtureRecognizer()
        let owner = LiveTranscriptionController(changed: {}, makeRecognizer: { recognizer })
        await owner.setEnabled(true); await owner.setRecording(true)
        try await wait { await owner.snapshot().state == .listening }
        owner.input.offer(packet())
        try await wait { await owner.snapshot().spans.count == 1 }
        owner.input.offer(packet()) // A different generation and continuity UUID.
        try await wait { await owner.snapshot().state == .interrupted }
        let state = await owner.snapshot()
        XCTAssertTrue(state.spans.isEmpty)
        await owner.close()
    }

    func testBoundedInputOverflowTerminatesCoverageInsteadOfJoiningDistantSamples() async {
        let input = LiveTranscriptionInput()
        let stream = input.install()
        for _ in 0..<34 { input.offer(packet()) }
        XCTAssertTrue(input.didDrop)
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 32)
    }

    private func wait(_ check: @escaping () async -> Bool) async throws {
        for _ in 0..<200 {
            if await check() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Draft state did not settle")
    }

    private func packet(source: AudioSource = .microphone) -> CapturedAudio {
        let identity = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(),
            startSample: 0, sampleCount: 160, sampleRate: 16_000, approximateOrigin: Date())
        // Authored Int16 PCM; the lifecycle fixture never invokes a microphone/model.
        return CapturedAudio(timestamp: identity.approximateOrigin, audioData: Data(repeating: 1, count: 320),
            duration: 0.01, source: source, sampleIdentity: identity)
    }
}

private actor DraftFixtureRecognizer: VoiceRecognitionProtocol {
    var starts = 0
    var running = false
    func run(input: AsyncStream<CapturedAudio>, receive: @escaping @Sendable (VoiceRecognitionEvent) async throws -> Void) async throws {
        starts += 1; running = true
        defer { running = false }
        try await receive(.ready)
        for await audio in input {
            try Task.checkCancellation()
            guard let source = audio.sampleIdentity else { throw VoiceRecognitionError.invalidInput }
            try await receive(.update(.init(source: source, startSample: 0, endSample: 160,
                text: "earlier guess", tokens: [], isFinal: false)))
            try await receive(.update(.init(source: source, startSample: 0, endSample: 160,
                text: "corrected draft", tokens: [], isFinal: true)))
        }
    }
}

private actor MissingDraftRecognizer: VoiceRecognitionProtocol {
    func run(input: AsyncStream<CapturedAudio>, receive: @escaping @Sendable (VoiceRecognitionEvent) async throws -> Void) async throws {
        throw VoiceRecognitionError.missingAssets
    }
}
