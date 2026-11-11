import App
import Shared
import XCTest
@testable import Retrace

@MainActor
final class MeetingStatusModelTests: XCTestCase {
    func testDisplayedCallExpiresWithoutAnotherSourcePollAndReplacementOwnsItsTimer() async throws {
        let model = MeetingStatusModel()
        let now = ProcessInfo.processInfo.systemUptime
        model.update(snapshot(phase: .supportedActive, now: now, expiry: now + 0.05))
        XCTAssertEqual(model.summary, "Call supported by current signals")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.summary, "Call state unavailable")
        let later = ProcessInfo.processInfo.systemUptime
        model.update(snapshot(phase: .supportedActive, now: later, expiry: later + 0.05))
        model.update(snapshot(phase: .possible, now: later, expiry: later + 2))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.summary, "Possible call", "A cancelled old expiry cannot overwrite a later assessment")
        model.close()
        XCTAssertEqual(model.summary, "Call state unavailable")
    }

    private func snapshot(phase: MeetingPhase, now: TimeInterval, expiry: TimeInterval) -> MeetingHealthSnapshot {
        let assessment = MeetingAssessment(monitoringSessionID: UUID(), revision: 1, phase: phase,
            application: nil, observedAt: Date(), observedUptime: now, validUntilUptime: expiry,
            possibleSince: nil, supportedSince: nil, endedAt: nil, observations: [], uncertainties: [])
        return MeetingHealthSnapshot(comparisonEnabled: true, monitoring: true, assessment: assessment)
    }
}
