import XCTest
import Database
@testable import Retrace

final class TranscriptCursorPolicyTests: XCTestCase {
    func testTranscriptRefreshDoesNotStartWhileHiddenOrInFlight() {
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(TranscriptRefreshPolicy.shouldStartRefresh(
            isVisible: false,
            isRefreshInFlight: false,
            currentTimestamp: now,
            lastRefreshedTimestamp: nil
        ))
        XCTAssertFalse(TranscriptRefreshPolicy.shouldStartRefresh(
            isVisible: true,
            isRefreshInFlight: true,
            currentTimestamp: now,
            lastRefreshedTimestamp: nil
        ))
    }

    func testTranscriptRefreshRequiresTimestampMovement() {
        let last = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(TranscriptRefreshPolicy.shouldStartRefresh(
            isVisible: true,
            isRefreshInFlight: false,
            currentTimestamp: last.addingTimeInterval(4),
            lastRefreshedTimestamp: last
        ))
        XCTAssertTrue(TranscriptRefreshPolicy.shouldStartRefresh(
            isVisible: true,
            isRefreshInFlight: false,
            currentTimestamp: last.addingTimeInterval(5),
            lastRefreshedTimestamp: last
        ))
    }

    func testLeavingNonAudioRowDoesNotPopCursor() {
        XCTAssertNil(
            TranscriptCursorPolicy.action(
                hovering: false,
                hasAudioFile: false,
                cursorIsPushed: false
            )
        )
    }

    func testEnteringAudioRowPushesOnlyWhenNotAlreadyPushed() {
        XCTAssertEqual(
            TranscriptCursorPolicy.action(
                hovering: true,
                hasAudioFile: true,
                cursorIsPushed: false
            ),
            .pushPointingHand
        )

        XCTAssertNil(
            TranscriptCursorPolicy.action(
                hovering: true,
                hasAudioFile: true,
                cursorIsPushed: true
            )
        )
    }

    func testLeavingAudioRowPopsOnlyWhenPreviouslyPushed() {
        XCTAssertEqual(
            TranscriptCursorPolicy.action(
                hovering: false,
                hasAudioFile: true,
                cursorIsPushed: true
            ),
            .pop
        )

        XCTAssertNil(
            TranscriptCursorPolicy.action(
                hovering: false,
                hasAudioFile: true,
                cursorIsPushed: false
            )
        )
    }

    func testAudioAvailabilityChangingWhileHoveredPopsExistingCursor() {
        XCTAssertEqual(
            TranscriptCursorPolicy.action(
                hovering: true,
                hasAudioFile: false,
                cursorIsPushed: true
            ),
            .pop
        )
    }

    func testTranscriptPresentationCollapsesConsecutiveAmbientCaptions() {
        let rows = [
            makeTranscription(id: 1, text: "*sound of camera*", offset: 0),
            makeTranscription(id: 2, text: "*sound of camera*", offset: 10),
            makeTranscription(id: 3, text: "*sound of camera*", offset: 20),
            makeTranscription(id: 4, text: "This is real speech.", offset: 30)
        ]

        let presented = TranscriptPresentationPolicy.presentationRows(from: rows)

        XCTAssertEqual(presented.count, 2)
        XCTAssertEqual(presented[0].repeatedCount, 3)
        XCTAssertEqual(presented[0].displayText, "Ambient audio: sound of camera (3 entries)")
        XCTAssertEqual(presented[1].displayText, "This is real speech.")
    }

    func testTranscriptPresentationNormalizesRepeatedCaptionWordsInsideRows() {
        let rows = [
            makeTranscription(id: 1, text: "*typing* *typing* *typing* *typing*", offset: 0),
            makeTranscription(id: 2, text: "*typing*", offset: 10)
        ]

        let presented = TranscriptPresentationPolicy.presentationRows(from: rows)

        XCTAssertEqual(presented.count, 1)
        XCTAssertEqual(presented[0].repeatedCount, 2)
        XCTAssertEqual(presented[0].displayText, "Ambient audio: typing (2 entries)")
    }

    func testTranscriptPresentationDoesNotCollapseRepeatedRealSpeech() {
        let rows = [
            makeTranscription(id: 1, text: "No.", offset: 0),
            makeTranscription(id: 2, text: "No.", offset: 10)
        ]

        let presented = TranscriptPresentationPolicy.presentationRows(from: rows)

        XCTAssertEqual(presented.count, 2)
        XCTAssertEqual(presented.map(\.displayText), ["No.", "No."])
    }

    private func makeTranscription(id: Int64, text: String, offset: TimeInterval) -> AudioTranscription {
        let start = Date(timeIntervalSince1970: 1_781_580_000 + offset)
        return AudioTranscription(
            id: id,
            sessionID: nil,
            text: text,
            startTime: start,
            endTime: start.addingTimeInterval(8),
            source: .microphone,
            confidence: 0.5,
            createdAt: start,
            audioPath: nil,
            transcriptStatus: "transcribed",
            detectedLanguage: "en",
            audioVariant: "raw",
            qualityFlags: nil,
            transcriptionPass: 1
        )
    }
}
