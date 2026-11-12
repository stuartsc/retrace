import Foundation
import Shared
import XCTest
@testable import Database

final class RetraceDisclosureReadTests: XCTestCase {
    func testExactCitationIsDeniedAfterHideAndOldReadStampRejectsHideUndoABA() async throws {
        let database = DatabaseManager(databasePath: "file:disclosure_\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let segment = try await database.insertSegment(bundleID: "com.fixture", startDate: time,
            endDate: time, windowName: "Fixture", browserUrl: nil, type: 0)
        let frame = FrameID(value: try await database.insertFrame(.init(id: .init(value: 0), timestamp: time,
            segmentID: .init(value: segment), frameIndexInSegment: 0,
            metadata: .init(appBundleID: "com.fixture", windowName: "Fixture"))))
        _ = try await database.commitFrameOCR(frameID: frame, text: .init(frameID: frame, timestamp: time,
            regions: [], fullText: "Authored private evidence"), frameWidth: 100, frameHeight: 100)
        let store = try await database.activityStoreID()
        let saved = try await database.currentScreenEvidence(frameID: frame, storeID: store)
        let reference = try XCTUnwrap(saved?.ref)
        let policy = ScreenEvidenceAccessPolicy(config: .default)
        let stamp = try await database.validateNativeDisclosure(reference, policy: policy)
        let hiddenValue = try await database.getTag(name: "hidden")
        let hidden = try XCTUnwrap(hiddenValue)
        try await database.addTagToSegment(segmentId: .init(value: segment), tagId: hidden.id)
        do {
            _ = try await database.validateNativeDisclosure(reference, policy: policy)
            XCTFail("A retained exact reference cannot disclose a hidden segment")
        } catch EvidenceUnavailableReason.notPermitted { }
        try await database.removeTagFromSegment(segmentId: .init(value: segment), tagId: hidden.id)
        do {
            _ = try await database.validateNativeDisclosure(reference, policy: policy, expectedReadRevision: stamp)
            XCTFail("Hide/undo must invalidate the earlier read fence")
        } catch EvidenceUnavailableReason.evidenceDeleted { }
        _ = try await database.validateNativeDisclosure(reference, policy: policy)
        let excluded = ScreenEvidenceAccessPolicy(config: .init(excludedAppBundleIDs: ["com.fixture"]))
        do {
            _ = try await database.validateNativeDisclosure(reference, policy: excluded)
            XCTFail("The current exclusion must cover retained exact evidence")
        } catch EvidenceUnavailableReason.notPermitted { }
        let wrongStore = ScreenEvidenceRef(storeID: UUID(), source: .native, observationID: reference.observationID,
            frameID: frame, extractionRevision: reference.extractionRevision)
        do {
            _ = try await database.validateNativeDisclosure(wrongStore, policy: policy)
            XCTFail("A numeric frame ID does not establish source identity")
        } catch EvidenceUnavailableReason.notPermitted { }
        try await database.deleteFrame(id: frame)
        do {
            _ = try await database.validateNativeDisclosure(reference, policy: policy)
            XCTFail("A deleted source cannot remain readable")
        } catch EvidenceUnavailableReason.notPermitted { }
        try await database.close()
    }
}
