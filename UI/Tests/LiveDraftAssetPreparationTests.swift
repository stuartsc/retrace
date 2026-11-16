import App
import Shared
import XCTest
@testable import Retrace

@MainActor
final class LiveDraftAssetPreparationTests: XCTestCase {
    private func model(prepare: @escaping @Sendable () async throws -> Void) -> LiveContextWorkspaceModel {
        LiveContextWorkspaceModel(loadAudio: { _, _, _ in .init(entries: [], nextCursor: nil) },
            loadScreens: { _ in LiveContextScreenPage(rows: [], hasMore: false) },
            prepareDraftAssets: prepare)
    }

    func testPrepareRunsOnceAndReportsReady() async {
        let calls = PrepareCounter()
        let model = model { calls.increment() }
        await model.prepareDraftSpeech()
        XCTAssertEqual(calls.value, 1)
        XCTAssertFalse(model.preparingDraftAssets)
        XCTAssertEqual(model.draftAssetMessage, "Speech recognition ready")
    }

    func testPrepareFailureKeepsSavedAudioMessage() async {
        let model = model { throw VoiceRecognitionError.missingAssets }
        await model.prepareDraftSpeech()
        XCTAssertFalse(model.preparingDraftAssets)
        XCTAssertEqual(model.draftAssetMessage,
            "Could not prepare speech recognition. Saved-audio transcription continues.")
    }
}

private final class PrepareCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
