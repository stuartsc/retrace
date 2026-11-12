import App
import Foundation
import Shared
import XCTest
@testable import Retrace

@MainActor
final class VoiceMarkerStatusModelTests: XCTestCase {
    func testAcknowledgementRequiresRetainedSpokenMarkerAndTracksConfirmationAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-status-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nativeID = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let owner = TimelineMarkerService(storageRoot: root, nativeStoreID: { nativeID })
        let rule = try await owner.saveKeywordRule(KeywordRule(phrase: "mark this", name: "Decision", meaning: "Review", enabled: true), expectedRevision: nil)
        let anchor = SpokenMarkerAnchor(nativeStoreID: nativeID, recordingGeneration: UUID(), continuityID: UUID(),
            startSample: 0, endSample: 16_000, approximateOrigin: now, timingPrecision: .phraseAligned)
        let occurrence = UUID()
        let saved = try await owner.applySpokenObservation(SpokenObservationCommand(occurrenceID: occurrence,
            status: .provisional, anchor: anchor, ruleSnapshot: rule, matchedPhrase: "mark this", explanation: "Authored fixture"))
        let model = VoiceMarkerStatusModel(readStatus: { VoiceMarkerStatus(state: .listening, enabledRuleCount: 1,
            lastMarkerID: saved.marker.id, lastAcknowledgedAt: now, acknowledgedProvisional: true) },
            readMarker: { try await owner.marker(id: $0) })
        await model.refresh()
        XCTAssertEqual(model.acknowledgedMarker?.id, saved.marker.id)
        XCTAssertEqual(model.acknowledgedMarker?.spokenObservation?.status, .provisional)
        let confirmed = try await owner.applySpokenObservation(SpokenObservationCommand(occurrenceID: occurrence,
            expectedRevision: saved.observation.revision, status: .confirmed, anchor: anchor, ruleSnapshot: rule,
            matchedPhrase: "mark this", explanation: "Authored confirmed fixture"))
        await model.refresh()
        XCTAssertEqual(model.acknowledgedMarker?.spokenObservation?.status, .confirmed,
            "Current durable recognition outranks an older provisional status snapshot")
        _ = try await owner.setMarkerDeleted(id: confirmed.marker.id, expectedRevision: confirmed.marker.revision, deleted: true)
        await model.refresh()
        XCTAssertNil(model.acknowledgedMarker, "A deleted marker cannot retain a success acknowledgement")
        try await owner.close()
    }

    func testUnavailableStatusDoesNotPretendToBeListening() async {
        let model = VoiceMarkerStatusModel(readStatus: { throw ContextStoreError.closed })
        await model.refresh()
        XCTAssertTrue(model.readFailed)
        XCTAssertNil(model.status)
        XCTAssertNil(model.acknowledgedMarker)
        XCTAssertEqual(model.title, "Voice status unavailable")
    }
}
