import XCTest
@testable import App
import Shared

final class VoicePhraseMatcherTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)
    private func rule(_ phrase: String = "Purple banana") -> KeywordRule {
        KeywordRule(phrase: phrase, name: "Remember", meaning: "Keep this explanation", enabled: true)
    }
    private func update(_ words: [String], at start: Int64 = 0, final: Bool = false,
                        source: LiveAudioSampleIdentity? = nil, coarse: Bool = false) -> VoiceRecognitionUpdate {
        let source = source ?? LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(),
            startSample: 0, sampleCount: 160_000, sampleRate: 16_000, approximateOrigin: origin)
        let end = start + Int64(words.count) * 8_000
        return .init(source: source, startSample: start, endSample: end,
            text: words.joined(separator: " "), tokens: words.enumerated().map { i, word in
                .init(text: word, startSample: coarse ? start : start + Int64(i) * 8_000,
                    endSample: coarse ? end : start + Int64(i + 1) * 8_000,
                    hasStartBoundary: !coarse || i == 0, hasEndBoundary: !coarse || i == words.count - 1)
            }, isFinal: final)
    }
    func testWholePhraseNormalizationAndNearMiss() throws {
        var matcher = VoicePhraseMatcher(rules: [rule()])
        XCTAssertTrue(try matcher.receive(update(["purplish", "banana"])).isEmpty)
        XCTAssertEqual(try matcher.receive(update(["PURPLE,", "Banana!"])).count, 1)
        XCTAssertTrue(VoicePhraseMatcher(rules: [rule()]).matchesForTesting("purple bananas").isEmpty)
    }
    func testPartialFinalAndDuplicateRevisionAreOneOccurrence() throws {
        var matcher = VoicePhraseMatcher(rules: [rule()])
        let first = update(["purple", "banana"])
        let provisional = try XCTUnwrap(matcher.receive(first).first)
        let final = VoiceRecognitionUpdate(source: first.source, startSample: 0, endSample: 16_000,
            text: first.text, tokens: first.tokens, isFinal: true)
        let confirmed = try XCTUnwrap(matcher.receive(final).first)
        XCTAssertEqual(provisional.occurrenceID, confirmed.occurrenceID)
        XCTAssertEqual(confirmed.status, .confirmed)
        XCTAssertTrue(try matcher.receive(final).isEmpty)
    }
    func testSeparateRepeatedPhrasesRemainSeparateEvenInOneCoarseRun() throws {
        var matcher = VoicePhraseMatcher(rules: [rule()])
        let changes = try matcher.receive(update(["purple", "banana", "purple", "banana"], coarse: true))
        XCTAssertEqual(Set(changes.map(\.occurrenceID)).count, 2)
        XCTAssertTrue(changes.allSatisfy { $0.precision == .enclosingTimedSpan })
    }
    func testPhraseCrossesResultChunksButNotContinuityGaps() throws {
        var matcher = VoicePhraseMatcher(rules: [rule()])
        let first = update(["purple"])
        XCTAssertTrue(try matcher.receive(first).isEmpty)
        let second = update(["banana"], at: 8_000, source: first.source)
        XCTAssertEqual(try matcher.receive(second).count, 1)
        var other = VoicePhraseMatcher(rules: [rule()])
        XCTAssertTrue(try other.receive(first).isEmpty)
        XCTAssertTrue(try other.receive(update(["banana"], at: 8_000)).isEmpty)
    }
    func testCorrectionWithdrawsProvisionalAndNativeFinalizationConfirmsWithoutRepeat() throws {
        var matcher = VoicePhraseMatcher(rules: [rule()])
        let first = update(["purple", "banana"])
        let heard = try XCTUnwrap(matcher.receive(first).first)
        let corrected = update(["purple", "bandana"], source: first.source)
        XCTAssertEqual(try matcher.receive(corrected).first?.status, .withdrawn)
        let again = try XCTUnwrap(matcher.receive(first).first)
        XCTAssertEqual(heard.occurrenceID, again.occurrenceID)
        let finalized = matcher.finalize(recordingGeneration: first.source.recordingGeneration,
            continuityID: first.source.continuityID, throughSample: 16_000)
        XCTAssertEqual(finalized.first?.status, .confirmed)
        XCTAssertTrue(matcher.finalize(recordingGeneration: first.source.recordingGeneration,
            continuityID: first.source.continuityID, throughSample: 16_000).isEmpty)
    }
    func testCorrectedResultPrecedesItsFinalizationWatermark() throws {
        var matcher = VoicePhraseMatcher(rules: [rule()])
        let provisional = update(["purple", "banana"])
        XCTAssertEqual(try matcher.receive(provisional).first?.status, .provisional)
        let correction = update(["purple", "bandana"], final: true, source: provisional.source)
        XCTAssertEqual(try matcher.receive(correction).first?.status, .withdrawn)
        XCTAssertTrue(matcher.finalize(recordingGeneration: provisional.source.recordingGeneration,
            continuityID: provisional.source.continuityID, throughSample: 16_000).isEmpty)
    }

    func testSentenceTimestampDoesNotInventPhraseEdges() throws {
        var matcher = VoicePhraseMatcher(rules: [rule()])
        let change = try XCTUnwrap(matcher.receive(update(["please", "purple", "banana", "now"], coarse: true)).first)
        XCTAssertEqual(change.startSample, 0)
        XCTAssertEqual(change.endSample, 32_000)
        XCTAssertEqual(change.precision, .enclosingTimedSpan)
    }

    func testLongFollowingExplanationFitsDurableUTF8BudgetWithoutChangingAnchor() throws {
        var matcher = VoicePhraseMatcher(rules: [rule()])
        let first = update(["purple", "banana"])
        let initial = try XCTUnwrap(matcher.receive(first).first)
        XCTAssertEqual(initial.explanation, "")
        let text = String(repeating: "A café 🟣 explanation. ", count: 400)
        let later = VoiceRecognitionUpdate(source: first.source, startSample: 16_000, endSample: 32_000,
            text: text, tokens: [.init(text: "explanation", startSample: 16_000, endSample: 32_000,
                hasStartBoundary: true, hasEndBoundary: true)], isFinal: false)
        let expanded = try XCTUnwrap(matcher.receive(later).first)
        XCTAssertEqual(expanded.occurrenceID, initial.occurrenceID)
        XCTAssertEqual(expanded.startSample, initial.startSample)
        XCTAssertEqual(expanded.endSample, initial.endSample)
        XCTAssertLessThanOrEqual(expanded.explanation.utf8.count, 4_096)
        XCTAssertTrue(text.hasPrefix(expanded.explanation))
        XCTAssertFalse(expanded.explanation.contains("�"))
    }
}
