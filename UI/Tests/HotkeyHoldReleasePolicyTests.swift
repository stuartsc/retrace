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
        XCTAssertTrue(HotkeyHoldReleasePolicy.shouldReleaseActiveHoldOnKeyUp(
            eventType: .keyUp,
            keyMatches: true,
            isActiveHold: true,
            requiredModifiersStillPressed: false,
            elapsedSeconds: 1.0
        ))
    }

    func testNonMatchingKeyUpDoesNotReleaseActiveHold() {
        XCTAssertFalse(HotkeyHoldReleasePolicy.shouldReleaseActiveHoldOnKeyUp(
            eventType: .keyUp,
            keyMatches: false,
            isActiveHold: true,
            requiredModifiersStillPressed: false,
            elapsedSeconds: 1.0
        ))
    }

    func testShortTriggerKeyTapDoesNotEndHoldWhileRequiredModifierIsStillPressed() {
        XCTAssertFalse(HotkeyHoldReleasePolicy.shouldReleaseActiveHoldOnKeyUp(
            eventType: .keyUp,
            keyMatches: true,
            isActiveHold: true,
            requiredModifiersStillPressed: true,
            elapsedSeconds: 0.18
        ))
    }

    func testModifierReleaseEndsActiveHoldAfterShortTriggerKeyTap() {
        XCTAssertTrue(HotkeyHoldReleasePolicy.shouldReleaseActiveHoldOnModifierChange(
            eventType: .flagsChanged,
            isActiveHold: true,
            requiredModifiersStillPressed: false
        ))
    }
}
