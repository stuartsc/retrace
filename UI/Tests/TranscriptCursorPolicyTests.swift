import XCTest
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
}
