import App
import Shared
import XCTest
@testable import Retrace

final class LiveContextCopyBudgetTests: XCTestCase {
    func testCombinedSourcesShareOneLimitAndOmissionsRemainVisibleInCopiedText() {
        let turn = CompanionTurnReference(nativeStoreID: UUID(), jobID: String(repeating: "a", count: 64),
            resultSHA256: String(repeating: "b", count: 64), turnIndex: 0, correctionRevision: nil)
        let transcripts: [LiveContextReference] = (1...500).map {
            .transcript(V23TranscriptReference(nativeStoreID: turn.nativeStoreID, source: .microphone,
                rowID: Int64($0), snapshotSHA256: String(repeating: "c", count: 64), recordingGeneration: nil))
        }
        let screen = ScreenEvidenceRef(storeID: turn.nativeStoreID, source: .native, observationID: UUID(),
            frameID: FrameID(value: 1), extractionRevision: 1)
        let selection = LiveContextCopyBudget(references: [.screen(screen)] + Array(repeating: .speakerTurn(turn), count: 64) + transcripts)
        XCTAssertEqual(selection.references.count, LiveContextSearchService.maximumCopyReferences)
        XCTAssertEqual(selection.omittedCount, 65)
        XCTAssertTrue(selection.notice?.contains("65 transcript references omitted") == true)
        XCTAssertTrue(selection.notice?.contains("500 of 565") == true)
        if case .screen(let retained)? = selection.references.first { XCTAssertEqual(retained, screen) }
        else { XCTFail("The explicit screen selection must survive the total budget") }
        let copied = LiveContextCopyBudget.text("Revalidated source text", notice: selection.notice)
        XCTAssertTrue(copied.contains("65 transcript references omitted"))
        XCTAssertTrue(copied.hasSuffix("Revalidated source text"))
    }

    func testWithinLimitSelectionDoesNotClaimOmissions() {
        let selection = LiveContextCopyBudget(references: [])
        XCTAssertEqual(selection.omittedCount, 0)
        XCTAssertNil(selection.notice)
        XCTAssertEqual(LiveContextCopyBudget.text("Source text", notice: selection.notice), "Source text")
    }
}
