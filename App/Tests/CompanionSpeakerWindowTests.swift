import Foundation
import Shared
import XCTest
@testable import App

final class CompanionSpeakerWindowTests: XCTestCase {
    private let generation = UUID(), continuity = UUID()
    private let origin = Date(timeIntervalSinceReferenceDate: 814_000_000.1234567)

    private func interval(_ start: Int64, _ end: Int64) -> LiveAudioSampleIdentity {
        .init(recordingGeneration: generation, continuityID: continuity, startSample: start,
            sampleCount: end - start, sampleRate: 16_000, approximateOrigin: origin)
    }

    func testNewestFirstAndOldestFirstBothExcludeFiveSecondOverlap() throws {
        let older = interval(0, 960_000), newer = interval(880_000, 1_840_000)
        XCTAssertEqual(try CompanionSpeakerWindow.uncovered(older, covered: [newer]), [interval(0, 880_000)])
        XCTAssertEqual(try CompanionSpeakerWindow.uncovered(newer, covered: [older]), [interval(960_000, 1_840_000)])
    }

    func testInteriorDisjointAndAdjacentCoveragePreserveEveryUncoveredSample() throws {
        let source = interval(0, 100)
        let covered = [interval(20, 30), interval(70, 80), interval(25, 40), interval(40, 50)]
        let expected = [interval(0, 20), interval(50, 70), interval(80, 100)]
        XCTAssertEqual(try CompanionSpeakerWindow.uncovered(source, covered: covered), expected)
        XCTAssertEqual(try CompanionSpeakerWindow.uncovered(source, covered: Array(covered.reversed())), expected)
        XCTAssertThrowsError(try CompanionSpeakerWindow.fresh(source, covered: covered)) {
            XCTAssertEqual($0 as? CompanionError, .capacityExceeded)
        }
        XCTAssertThrowsError(try CompanionSpeakerWindow.uncovered(source, covered: covered, limit: 2)) {
            XCTAssertEqual($0 as? CompanionError, .capacityExceeded)
        }
    }

    func testCompleteContainmentAndTouchingRangesDoNotCreateFalseGaps() throws {
        let source = interval(20, 80)
        XCTAssertEqual(try CompanionSpeakerWindow.uncovered(source, covered: [interval(0, 100)]), [])
        XCTAssertEqual(try CompanionSpeakerWindow.uncovered(source, covered: [interval(20, 40), interval(40, 80)]), [])
        XCTAssertEqual(try CompanionSpeakerWindow.uncovered(source, covered: [interval(0, 20), interval(80, 100)]), [source])
    }

    func testWireRoundTripPreservesCoverageButDifferentRecordingCannotSuppressIt() throws {
        let source = interval(0, 100)
        let retained = try CompanionWire.decode(LiveAudioSampleIdentity.self,
            data: CompanionWire.encode(source), limit: 4_096)
        XCTAssertTrue(try CompanionSpeakerWindow.uncovered(source, covered: [retained]).isEmpty)
        let other = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: continuity,
            startSample: 0, sampleCount: 100, sampleRate: 16_000, approximateOrigin: origin)
        XCTAssertEqual(try CompanionSpeakerWindow.uncovered(source, covered: [other]), [source])
        XCTAssertThrowsError(try CompanionSpeakerWindow.uncovered(source, covered: [interval(100, 100)]))
    }
}
