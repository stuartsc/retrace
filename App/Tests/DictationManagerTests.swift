import XCTest
import Shared
@testable import App

final class DictationManagerTests: XCTestCase {
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

    func insert(text: String, method: DictationInsertionMethod, restoreDelay: TimeInterval) async throws {
        insertedTexts.append(text)
    }

    func insertedTextsSnapshot() -> [String] {
        insertedTexts
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
