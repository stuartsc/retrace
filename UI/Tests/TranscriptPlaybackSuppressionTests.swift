import Shared
import XCTest
@testable import Retrace

@MainActor
final class TranscriptPlaybackSuppressionTests: XCTestCase {
    func testAudibleOwnershipSurvivesAnotherPlayerStoppingAndEndsAfterTail() async throws {
        let gate = RetracePlaybackGate()
        let first = TranscriptPlaybackSuppression(gate: gate)
        var second: TranscriptPlaybackSuppression? = TranscriptPlaybackSuppression(gate: gate)
        first.begin(isMuted: false)
        first.begin(isMuted: false)
        second?.begin(isMuted: false)
        XCTAssertTrue(gate.isSuppressed)
        first.end()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(gate.isSuppressed, "Another player still owns acoustic output")
        second = nil
        XCTAssertTrue(gate.isSuppressed, "Queued output retains a short suppression tail")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(gate.isSuppressed, "Deinitialization releases the final lease")
        first.begin(isMuted: false)
        XCTAssertTrue(gate.isSuppressed, "Resuming acquires suppression before audio starts")
        first.end()
    }

    func testMutedPreparationAndStopNeverAcquireAnAudibleLease() {
        let gate = RetracePlaybackGate()
        let owner = TranscriptPlaybackSuppression(gate: gate)
        owner.begin(isMuted: true)
        XCTAssertFalse(gate.isSuppressed)
        owner.end()
        XCTAssertFalse(gate.isSuppressed)
    }
}
