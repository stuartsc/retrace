import XCTest
import CoreGraphics
@testable import Retrace

final class HotkeyHoldReleasePolicyTests: XCTestCase {
    func testKeyUpWithoutModifierIsStillProcessedWhenHoldIsActive() {
        XCTAssertFalse(HotkeyHoldReleasePolicy.shouldSkipBeforeKeyTranslation(
            eventType: .keyUp,
            hasModifierLessHotkey: false,
            hasRelevantModifiers: false,
            hasActiveHold: true
        ))
    }

    func testKeyDownWithoutRelevantModifierStillUsesFastPathWhenNoHoldIsActive() {
        XCTAssertTrue(HotkeyHoldReleasePolicy.shouldSkipBeforeKeyTranslation(
            eventType: .keyDown,
            hasModifierLessHotkey: false,
            hasRelevantModifiers: false,
            hasActiveHold: false
        ))
    }

    func testActiveHoldReleaseDoesNotRequireCurrentModifiersToMatch() {
        XCTAssertTrue(HotkeyHoldReleasePolicy.shouldReleaseActiveHold(
            eventType: .keyUp,
            keyMatches: true,
            isActiveHold: true
        ))
    }

    func testNonMatchingKeyUpDoesNotReleaseActiveHold() {
        XCTAssertFalse(HotkeyHoldReleasePolicy.shouldReleaseActiveHold(
            eventType: .keyUp,
            keyMatches: false,
            isActiveHold: true
        ))
    }
}
