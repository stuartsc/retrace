import XCTest
@testable import App

final class DictationTextFormatterTests: XCTestCase {
    func testNormalizesPunctuationSpacingAndSentenceCapitalization() {
        let formatted = DictationTextFormatter.formatted(" check . one, two, three.this is pretty cool  thanks.. okay ")

        XCTAssertEqual(formatted, "Check. One, two, three. This is pretty cool thanks. Okay.")
    }

    func testRemovesKnownNonSpeechCaptionsWithoutDroppingAdjacentSpeech() {
        let formatted = DictationTextFormatter.formatted("(click) tech *sound of wind* thanks [BLANK_AUDIO]")

        XCTAssertEqual(formatted, "Tech thanks.")
    }

    func testRejectsPunctuationOnlyAndStandaloneDecoderArtifacts() {
        XCTAssertNil(DictationTextFormatter.formatted("]"))
        XCTAssertNil(DictationTextFormatter.formatted("[ ]"))
        XCTAssertNil(DictationTextFormatter.formatted("*sound of camera*"))
    }

    func testPreservesIntentionalRepeatedSpeech() {
        let formatted = DictationTextFormatter.formatted("wicked, wicked, wicked, whack")

        XCTAssertEqual(formatted, "Wicked, wicked, wicked, whack.")
    }
}
