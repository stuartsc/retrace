import AppKit
import XCTest
import Shared
@testable import App

final class DictationManagerTests: XCTestCase {
    @MainActor
    func testDisableRevokesQueuedNativePasteEvenWhenInsertionIgnoresCancellation() async throws {
        let name = "io.retrace.dictation-test.\(UUID().uuidString)"
        let pasteboard = NSPasteboard(name: .init(name))
        pasteboard.setString("Authored previous clipboard", forType: .string)
        defer { pasteboard.releaseGlobally() }
        let entered = expectation(description: "Native paste waiting before its mutation")
        let gate = DictationPasteGate()
        let probe = DictationPasteProbe()
        let native = ClipboardDictationInsertionService(testingPasteboardName: name,
            beforeMutation: { entered.fulfill(); await gate.wait() },
            postPaste: { probe.posts += 1 })
        let insertion = UncancelledClipboardInsertionService(native)
        let buffer = DictationAudioBuffer()
        let manager = DictationManager(transcriptionService: StubDictationTranscriptionService(text: "private old speech"),
            insertionService: insertion, audioBuffer: buffer)
        let time = Date(timeIntervalSince1970: 2_000)
        await manager.ingest(.init(timestamp: time, audioData: Data(repeating: 1, count: 20), duration: 1,
            source: .microphone, sampleRate: 10, channels: 1))
        _ = await manager.beginDictation(at: time, targetContext: nil)
        let ending = Task { try await manager.endDictation(at: time.addingTimeInterval(1)) }
        await fulfillment(of: [entered], timeout: 3)
        let disabling = Task { await manager.setMicrophoneAllowed(false) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await buffer.slice(from: time, to: time.addingTimeInterval(1)) != nil, ContinuousClock.now < deadline {
            await Task.yield()
        }
        let cleared = await buffer.slice(from: time, to: time.addingTimeInterval(1))
        XCTAssertNil(cleared)
        // A new enabled generation must not make the queued old paste valid.
        await manager.setMicrophoneAllowed(true)
        await gate.release()
        await disabling.value
        let result = try await ending.value
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(probe.posts, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "Authored previous clipboard")
    }

    func testMicrophoneDisableClearsPreRollAndRefusesSamplesUntilReenabled() async throws {
        let service = StubDictationTranscriptionService(text: "Old microphone audio")
        let insertion = RecordingDictationInsertionService()
        let manager = DictationManager(transcriptionService: service, insertionService: insertion)
        let time = Date(timeIntervalSince1970: 2_000)
        let sample = CapturedAudio(timestamp: time, audioData: Data(repeating: 1, count: 20), duration: 1,
            source: .microphone, sampleRate: 10, channels: 1)
        await manager.ingest(sample)
        await manager.setMicrophoneAllowed(false)
        await manager.ingest(sample)
        await manager.setMicrophoneAllowed(true)
        _ = await manager.beginDictation(at: time, targetContext: nil)
        let result = try await manager.endDictation(at: time.addingTimeInterval(1))
        XCTAssertEqual(result.status, .empty)
        let inserted = await insertion.insertedTextsSnapshot()
        XCTAssertTrue(inserted.isEmpty)
    }

    func testDisableJoinsHeldRecognitionAndPreventsLateInsertion() async throws {
        let entered = expectation(description: "Dictation recognition held")
        let service = HeldDictationRecognition { entered.fulfill() }
        let insertion = RecordingDictationInsertionService()
        let buffer = DictationAudioBuffer()
        let manager = DictationManager(transcriptionService: service, insertionService: insertion, audioBuffer: buffer)
        let time = Date(timeIntervalSince1970: 2_000)
        await manager.ingest(.init(timestamp: time, audioData: Data(repeating: 1, count: 20), duration: 1,
            source: .microphone, sampleRate: 10, channels: 1))
        _ = await manager.beginDictation(at: time, targetContext: nil)
        let ending = Task { try await manager.endDictation(at: time.addingTimeInterval(1)) }
        await fulfillment(of: [entered], timeout: 3)
        let disabling = Task { await manager.setMicrophoneAllowed(false) }
        // The transcriber deliberately ignores cancellation; the joined owner must
        // still reject the old generation before any insertion can begin.
        let limit = ContinuousClock.now.advanced(by: .seconds(3))
        while await buffer.slice(from: time, to: time.addingTimeInterval(1)) != nil, ContinuousClock.now < limit {
            await Task.yield()
        }
        let cleared = await buffer.slice(from: time, to: time.addingTimeInterval(1))
        XCTAssertNil(cleared)
        await service.release()
        await disabling.value
        let result = try await ending.value
        XCTAssertEqual(result.status, .cancelled)
        let inserted = await insertion.insertedTextsSnapshot()
        XCTAssertTrue(inserted.isEmpty)
    }

    func testReleaseTranscribesHeldMicrophoneAudioAndInsertsFormattedText() async throws {
        let start = Date(timeIntervalSince1970: 2_000)
        let transcriptionService = StubDictationTranscriptionService(text: "hello from retrace")
        let insertionService = RecordingDictationInsertionService()
        let sessionStore = RecordingDictationSessionStore()
        let manager = DictationManager(
            transcriptionService: transcriptionService,
            insertionService: insertionService,
            sessionStore: sessionStore,
            config: DictationConfig(
                isEnabled: true,
                shortcut: .defaultDictation,
                preRollSeconds: 0,
                postRollSeconds: 0,
                restoreClipboardDelaySeconds: 0,
                insertionMethod: .clipboardPaste
            )
        )

        await manager.ingest(CapturedAudio(
            timestamp: start,
            audioData: Data(repeating: 1, count: 20),
            duration: 1,
            source: .microphone,
            sampleRate: 10,
            channels: 1
        ))

        let context = DictationTargetContext(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            windowTitle: "Untitled"
        )

        let sessionID = await manager.beginDictation(at: start.addingTimeInterval(0.2), targetContext: context)
        let result = try await manager.endDictation(at: start.addingTimeInterval(0.8))

        XCTAssertEqual(result.id, sessionID)
        XCTAssertEqual(result.text, "Hello from retrace.")
        XCTAssertEqual(result.status, .inserted)
        let insertedTexts = await insertionService.insertedTextsSnapshot()
        let receivedByteCounts = await transcriptionService.receivedAudioByteCountsSnapshot()
        let savedStatuses = await sessionStore.savedStatusesSnapshot()

        XCTAssertEqual(insertedTexts, ["Hello from retrace."])
        XCTAssertEqual(receivedByteCounts, [12])
        XCTAssertEqual(savedStatuses, [.capturing, .inserted])
    }

    func testSystemAudioIsBufferedByContinuousPipelineButIgnoredForDictationInsertion() async throws {
        let start = Date(timeIntervalSince1970: 3_000)
        let transcriptionService = StubDictationTranscriptionService(text: "microphone text")
        let insertionService = RecordingDictationInsertionService()
        let sessionStore = RecordingDictationSessionStore()
        let manager = DictationManager(
            transcriptionService: transcriptionService,
            insertionService: insertionService,
            sessionStore: sessionStore,
            config: .default
        )

        await manager.ingest(CapturedAudio(
            timestamp: start,
            audioData: Data(repeating: 9, count: 20),
            duration: 1,
            source: .system,
            sampleRate: 10,
            channels: 1
        ))

        _ = await manager.beginDictation(at: start, targetContext: nil)
        let result = try await manager.endDictation(at: start.addingTimeInterval(1))

        XCTAssertEqual(result.status, .empty)
        let insertedTexts = await insertionService.insertedTextsSnapshot()
        let receivedByteCounts = await transcriptionService.receivedAudioByteCountsSnapshot()

        XCTAssertEqual(insertedTexts, [])
        XCTAssertEqual(receivedByteCounts, [])
    }

    func testReleaseDoesNotInsertWhenFocusedAppChangedDuringDictation() async throws {
        let start = Date(timeIntervalSince1970: 4_000)
        let transcriptionService = StubDictationTranscriptionService(text: "private note")
        let insertionService = RecordingDictationInsertionService()
        let sessionStore = RecordingDictationSessionStore()
        let manager = DictationManager(
            transcriptionService: transcriptionService,
            insertionService: insertionService,
            sessionStore: sessionStore,
            config: .default
        )

        await manager.ingest(CapturedAudio(
            timestamp: start,
            audioData: Data(repeating: 7, count: 20),
            duration: 1,
            source: .microphone,
            sampleRate: 10,
            channels: 1
        ))

        let startedInTextEdit = DictationTargetContext(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            windowTitle: "Notes"
        )
        let endedInMessages = DictationTargetContext(
            bundleID: "com.apple.MobileSMS",
            appName: "Messages",
            windowTitle: "Private Chat"
        )

        _ = await manager.beginDictation(at: start, targetContext: startedInTextEdit)
        let result = try await manager.endDictation(
            at: start.addingTimeInterval(1),
            currentTargetContext: endedInMessages,
            validateInsertionTarget: true
        )

        XCTAssertEqual(result.status, .blockedFocusChanged)
        XCTAssertEqual(result.text, "Private note.")
        let insertedTexts = await insertionService.insertedTextsSnapshot()
        XCTAssertEqual(insertedTexts, [])
    }
}

private actor HeldDictationRecognition: TranscriptionProtocol {
    private let entered: @Sendable () -> Void
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(entered: @escaping @Sendable () -> Void) { self.entered = entered }
    func initialize() { }
    func cleanup() { }
    func release() { released = true; continuation?.resume(); continuation = nil }
    func transcribe(_ data: Data) async -> TranscriptionResult {
        entered()
        if !released { await withCheckedContinuation { continuation = $0 } }
        return .init(text: "Never insert this old recording", confidence: 1, language: "en", duration: 1)
    }
    func transcribeWithTimestamps(_ audioData: Data, wordLevel: Bool, initialPrompt: String?) async throws -> DetailedTranscriptionResult {
        throw CancellationError()
    }
}

private actor StubDictationTranscriptionService: TranscriptionProtocol {
    private let text: String
    private(set) var receivedAudioByteCounts: [Int] = []

    init(text: String) {
        self.text = text
    }

    func initialize() async throws {}
    func cleanup() {}

    func transcribe(_ audioData: Data) async throws -> TranscriptionResult {
        receivedAudioByteCounts.append(audioData.count)
        return TranscriptionResult(text: text, confidence: 0.9, language: "en", duration: nil)
    }

    func transcribeWithTimestamps(_ audioData: Data, wordLevel: Bool, initialPrompt: String?) async throws -> DetailedTranscriptionResult {
        receivedAudioByteCounts.append(audioData.count)
        return DetailedTranscriptionResult(text: text, words: [], language: "en", duration: nil)
    }

    func receivedAudioByteCountsSnapshot() -> [Int] {
        receivedAudioByteCounts
    }
}

private actor RecordingDictationInsertionService: DictationInsertionServicing {
    private(set) var insertedTexts: [String] = []

    func insert(text: String, method: DictationInsertionMethod, restoreDelay: TimeInterval,
                admission: NativeMutationFence) async throws {
        try admission.withAdmission { insertedTexts.append(text) }
    }

    func insertedTextsSnapshot() -> [String] {
        insertedTexts
    }
}

private actor DictationPasteGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor
private final class DictationPasteProbe { var posts = 0 }

/// Deliberately does not propagate cancellation, proving the microphone fence
/// reaches the real clipboard mutation instead of relying on Task cancellation.
private actor UncancelledClipboardInsertionService: DictationInsertionServicing {
    private let native: ClipboardDictationInsertionService
    init(_ native: ClipboardDictationInsertionService) { self.native = native }
    func insert(text: String, method: DictationInsertionMethod, restoreDelay: TimeInterval,
                admission: NativeMutationFence) async throws {
        let native = native
        let work = Task.detached {
            try await native.insert(text: text, method: method, restoreDelay: restoreDelay, admission: admission)
        }
        try await work.value
    }
}

private actor RecordingDictationSessionStore: DictationSessionStoring {
    private(set) var savedSessions: [DictationSession] = []

    func save(_ session: DictationSession) async throws {
        savedSessions.append(session)
    }

    func savedStatusesSnapshot() -> [DictationInsertionStatus] {
        savedSessions.map(\.status)
    }
}
