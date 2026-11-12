import Foundation
import XCTest
import Database
import Shared
@testable import App

final class VoiceMarkerControllerTests: XCTestCase {
    private func eventually(_ predicate: @escaping () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func testCloseDuringHeldRecognizerRetirementJoinsForEveryCaller() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeID = UUID()
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { storeID })
        _ = try await markers.saveKeywordRule(.init(phrase: "purple banana", name: "Remember", meaning: "Context", enabled: true), expectedRevision: nil)
        let exiting = expectation(description: "native cancellation held before joined exit")
        let release = VoiceTestGate()
        let recognizer = HeldVoiceRecognizer(exiting: exiting, release: release)
        let controller = VoiceMarkerController(markers: markers, nativeStoreID: { storeID }, makeRecognizer: { recognizer })
        await controller.start(); await controller.setRecording(true)
        let ready = await eventually { await controller.status().state == .listening }
        XCTAssertTrue(ready)
        let pause = Task { await controller.setRecording(false) }
        await fulfillment(of: [exiting], timeout: 3)
        let firstDone = VoiceTestGate(), secondDone = VoiceTestGate()
        let first = Task { await controller.close(); await firstDone.release() }
        let second = Task { await controller.close(); await secondDone.release() }
        try await Task.sleep(for: .milliseconds(30))
        let earlyFirst = await firstDone.isOpen, earlySecond = await secondDone.isOpen
        XCTAssertFalse(earlyFirst); XCTAssertFalse(earlySecond)
        await release.release()
        await pause.value; await first.value; await second.value
        let final = await controller.status()
        XCTAssertEqual(final.state, .stopped)
        try await markers.close()
    }

    func testDisabledRulesStartNoRecognizerAndSystemAudioCannotTrigger() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeID = UUID()
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { storeID })
        let recognizer = AuthoredVoiceRecognizer()
        let playback = RetracePlaybackGate()
        let controller = VoiceMarkerController(markers: markers, nativeStoreID: { storeID },
            playback: playback, makeRecognizer: { recognizer })
        await controller.start(); await controller.setRecording(true)
        let disabled = await controller.status()
        let starts = await recognizer.starts
        XCTAssertEqual(disabled.state, .disabled); XCTAssertEqual(starts, 0)
        _ = try await markers.saveKeywordRule(.init(phrase: "purple banana", name: "Remember", meaning: "Context", enabled: true), expectedRevision: nil)
        let listening = await eventually { await controller.status().state == .listening }
        XCTAssertTrue(listening)
        controller.input.offer(sample(source: .system, playback: playback))
        try await Task.sleep(for: .milliseconds(30))
        let empty = try await markers.listMarkers(.init())
        XCTAssertTrue(empty.markers.isEmpty)
        controller.input.offer(sample(source: .microphone, playback: playback))
        let acknowledged = await eventually { await controller.status().lastMarkerID != nil }
        XCTAssertTrue(acknowledged)
        let page = try await markers.listMarkers(.init())
        XCTAssertEqual(page.markers.count, 1)
        XCTAssertEqual(page.markers.first?.spokenObservation?.status, .provisional)
        XCTAssertEqual(page.markers.first?.spokenObservation?.anchor.startSample, 0)
        await controller.close(); try await markers.close()
    }

    func testAcknowledgementWaitsForDurableOwnerAndPlaybackSuppressesNextPhrase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeID = UUID()
        let database = ContextDatabase(databasePath: root.appendingPathComponent("test.db").path, nativeStoreID: storeID)
        let entered = expectation(description: "committed spoken receipt before acknowledgement")
        let gate = VoiceTestGate()
        let markers = TimelineMarkerService(factory: { database }, metrics: { action, outcome in
            if action == .spokenObservation && outcome == .succeeded { entered.fulfill(); await gate.wait() }
        })
        _ = try await markers.saveKeywordRule(.init(phrase: "purple banana", name: "Remember", meaning: "Context", enabled: true), expectedRevision: nil)
        let playback = RetracePlaybackGate()
        let recognizer = AuthoredVoiceRecognizer()
        let controller = VoiceMarkerController(markers: markers, nativeStoreID: { storeID },
            playback: playback, makeRecognizer: { recognizer })
        await controller.start(); await controller.setRecording(true)
        let listening = await eventually { await controller.status().state == .listening }
        XCTAssertTrue(listening)
        controller.input.offer(sample(source: .microphone, playback: playback))
        await fulfillment(of: [entered], timeout: 3)
        let before = await controller.status()
        XCTAssertNil(before.lastMarkerID)
        let durable = try await database.listMarkers(.init())
        XCTAssertEqual(durable.markers.count, 1)
        await gate.release()
        let acknowledged = await eventually { await controller.status().lastMarkerID != nil }
        XCTAssertTrue(acknowledged)
        let lease = playback.acquire()
        controller.input.offer(sample(source: .microphone, start: 16_000, playback: playback))
        try await Task.sleep(for: .milliseconds(30))
        let page = try await markers.listMarkers(.init())
        XCTAssertEqual(page.markers.count, 1)
        playback.release(lease)
        await controller.close(); try await markers.close()
    }

    func testRecognizerRestartCannotJoinPhraseAcrossUnobservedInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeID = UUID(), generation = UUID(), continuity = UUID()
        let origin = Date()
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { storeID })
        _ = try await markers.saveKeywordRule(.init(phrase: "purple banana", name: "Remember", meaning: "Context", enabled: true), expectedRevision: nil)
        let playback = RetracePlaybackGate()
        let recognizer = AuthoredVoiceRecognizer(splitPhrase: true)
        let controller = VoiceMarkerController(markers: markers, nativeStoreID: { storeID }, playback: playback, makeRecognizer: { recognizer })
        func packet(_ start: Int64) -> CapturedAudio {
            .init(timestamp: origin.addingTimeInterval(Double(start) / 16_000), audioData: Data(count: 32_000), duration: 1,
                source: .microphone, sampleIdentity: .init(recordingGeneration: generation, continuityID: continuity,
                    startSample: start, sampleCount: 16_000, sampleRate: 16_000, approximateOrigin: origin),
                voiceMarkerPlaybackAdmission: playback.admission)
        }
        await controller.start(); await controller.setRecording(true)
        let initialReady = await eventually { await controller.status().state == .listening }
        XCTAssertTrue(initialReady)
        controller.input.offer(packet(0))
        let firstConsumed = await eventually { await recognizer.consumed == 1 }
        XCTAssertTrue(firstConsumed)
        // Captured PCM identity deliberately stays unchanged, as during playback/pressure.
        await controller.setRecording(false); await controller.setRecording(true)
        let restarted = await eventually { await recognizer.starts == 2 }
        XCTAssertTrue(restarted)
        controller.input.offer(packet(16_000))
        let secondConsumed = await eventually { await recognizer.consumed == 2 }
        XCTAssertTrue(secondConsumed)
        let page = try await markers.listMarkers(.init())
        XCTAssertTrue(page.markers.isEmpty, "A recognition gap cannot join two halves of a trigger")
        await controller.close(); try await markers.close()
    }

    func testQueuedMicrophonePacketFromPlaybackCannotTriggerAfterRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeID = UUID()
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { storeID })
        _ = try await markers.saveKeywordRule(.init(phrase: "purple banana", name: "Remember", meaning: "Context", enabled: true), expectedRevision: nil)
        let playback = RetracePlaybackGate()
        let recognizer = AuthoredVoiceRecognizer()
        let controller = VoiceMarkerController(markers: markers, nativeStoreID: { storeID }, playback: playback, makeRecognizer: { recognizer })
        let lease = playback.acquire()
        let delayed = sample(source: .microphone, playback: playback)
        playback.release(lease)
        try await Task.sleep(for: .milliseconds(800))
        await controller.start(); await controller.setRecording(true)
        let ready = await eventually { await controller.status().state == .listening }
        XCTAssertTrue(ready)
        controller.input.offer(delayed)
        try await Task.sleep(for: .milliseconds(30))
        let page = try await markers.listMarkers(.init())
        let consumed = await recognizer.consumed
        XCTAssertTrue(page.markers.isEmpty); XCTAssertEqual(consumed, 0)
        await controller.close(); try await markers.close()
    }

    private func sample(source: AudioSource, start: Int64 = 0, playback: RetracePlaybackGate) -> CapturedAudio {
        let identity = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(),
            startSample: start, sampleCount: 16_000, sampleRate: 16_000, approximateOrigin: Date())
        return CapturedAudio(timestamp: identity.approximateOrigin, audioData: Data(count: 32_000), duration: 1,
            source: source, sampleRate: 16_000, channels: 1, sampleIdentity: identity, voiceMarkerPlaybackAdmission: playback.admission)
    }
}

private actor AuthoredVoiceRecognizer: VoiceRecognitionProtocol {
    private(set) var starts = 0
    private(set) var consumed = 0
    private let splitPhrase: Bool
    init(splitPhrase: Bool = false) { self.splitPhrase = splitPhrase }
    func run(input: AsyncStream<CapturedAudio>, receive: @escaping @Sendable (VoiceRecognitionEvent) async throws -> Void) async throws {
        starts += 1
        try await receive(.ready)
        for await audio in input {
            try Task.checkCancellation()
            guard let source = audio.sampleIdentity else { throw VoiceRecognitionError.invalidInput }
            let words = splitPhrase ? [source.startSample == 0 ? "Purple" : "banana"] : ["Purple", "banana"]
            try await receive(.update(.init(source: source, startSample: source.startSample,
                endSample: source.startSample + Int64(words.count) * 8_000, text: words.joined(separator: " "),
                tokens: words.enumerated().map { index, word in
                    .init(text: word, startSample: source.startSample + Int64(index) * 8_000,
                        endSample: source.startSample + Int64(index + 1) * 8_000, hasStartBoundary: true, hasEndBoundary: true)
                }, isFinal: false)))
            consumed += 1
        }
    }
}

private actor VoiceTestGate {
    private var opened = false
    var isOpen: Bool { opened }
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { opened = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}

private actor HeldVoiceRecognizer: VoiceRecognitionProtocol {
    let exiting: XCTestExpectation
    let release: VoiceTestGate
    init(exiting: XCTestExpectation, release: VoiceTestGate) { self.exiting = exiting; self.release = release }
    func run(input: AsyncStream<CapturedAudio>, receive: @escaping @Sendable (VoiceRecognitionEvent) async throws -> Void) async throws {
        try await receive(.ready)
        for await _ in input { try Task.checkCancellation() }
        exiting.fulfill()
        await release.wait()
        try Task.checkCancellation()
    }
}
