import Foundation
import Shared
import SQLCipher
import XCTest
@testable import Database

final class LocalContextVisibilityTests: XCTestCase {
    private var database: DatabaseManager!
    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:context-visibility-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
    }
    override func tearDown() async throws { try await database.close() }

    func testSelectionHidePendingAndRevokeApplyToExactCanonicalEvent() async throws {
        let first = try await event(), other = try await event()
        let hide = try await database.submitActivityCorrection(.init(targetEventIDs: [first.id], expectedRevision: 0, action: .hide, confirmed: true))
        let hidden = try await database.isActivityHiddenForLocalContext(eventID: first.id)
        let visible = try await database.isActivityHiddenForLocalContext(eventID: other.id)
        XCTAssertTrue(hidden); XCTAssertFalse(visible)
        _ = try await database.submitActivityCorrection(.init(targetEventIDs: [first.id], expectedRevision: hide.revision,
            action: .revoke, confirmed: true, revokesCommandID: hide.command.id))
        let revoked = try await database.isActivityHiddenForLocalContext(eventID: first.id)
        XCTAssertFalse(revoked)
    }

    func testDocumentHideRequiresAppliedStatusAndStableDocumentIdentity() async throws {
        let first = try await event(document: "doc/🧭?x=';"), same = try await event(document: "doc/🧭?x=';"),
            different = try await event(document: "different"), titleOnly = try await event()
        let key = try XCTUnwrap(first.event.context?.stableDocumentKey)
        let hide = try await database.submitActivityCorrection(.init(targetEventIDs: [first.id], expectedRevision: 0,
            action: .hide, scope: .document, documentKey: key, confirmed: true))
        let before = try await database.isActivityHiddenForLocalContext(eventID: same.id)
        XCTAssertFalse(before)
        let revisionBefore = try await database.localContextActivityRevision()
        try await database.acknowledgeActivityCorrection(id: hide.command.id, expectedRevision: hide.revision, applied: true)
        let revisionAfter = try await database.localContextActivityRevision()
        XCTAssertGreaterThan(revisionAfter, revisionBefore)
        let after = try await database.isActivityHiddenForLocalContext(eventID: same.id)
        let other = try await database.isActivityHiddenForLocalContext(eventID: different.id)
        let noIdentity = try await database.isActivityHiddenForLocalContext(eventID: titleOnly.id)
        XCTAssertTrue(after); XCTAssertFalse(other); XCTAssertFalse(noIdentity)
    }

    func testDraftConflictAndFailedAcknowledgementDoNotHide() async throws {
        let first = try await event()
        _ = try await database.submitActivityCorrection(.init(targetEventIDs: [first.id], expectedRevision: 0, action: .hide, confirmed: false))
        let draft = try await database.isActivityHiddenForLocalContext(eventID: first.id)
        XCTAssertFalse(draft)
        _ = try await database.submitActivityCorrection(.init(targetEventIDs: [first.id], expectedRevision: 0, action: .hide, confirmed: true))
        let conflict = try await database.isActivityHiddenForLocalContext(eventID: first.id)
        XCTAssertFalse(conflict)
        let health = try await database.activityHealth()
        let pending = try await database.submitActivityCorrection(.init(targetEventIDs: [first.id], expectedRevision: health.correctionRevision, action: .hide, confirmed: true))
        try await database.acknowledgeActivityCorrection(id: pending.command.id, expectedRevision: pending.revision, applied: false)
        let rejected = try await database.isActivityHiddenForLocalContext(eventID: first.id)
        XCTAssertFalse(rejected)
    }

    func testDeletedAndMissingActivityFailClosed() async throws {
        let first = try await event()
        let before = try await database.localContextActivityRevision()
        try await database.deleteActivity(eventIDs: [first.id])
        let hidden = try await database.isActivityHiddenForLocalContext(eventID: first.id)
        let missing = try await database.isActivityHiddenForLocalContext(eventID: UUID())
        let after = try await database.localContextActivityRevision()
        XCTAssertTrue(hidden); XCTAssertTrue(missing); XCTAssertGreaterThan(after, before)
    }

    func testQueriesUseSelectionDocumentAndRevocationIndexesWithoutHistoryScan() async throws {
        let raw = await database.getConnection()
        let db = try XCTUnwrap(raw)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + LocalContextVisibilitySQL.hiddenActivity, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var details: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            details.append(String(cString: sqlite3_column_text(statement, 3)))
        }
        let plan = details.joined(separator: "\n")
        XCTAssertTrue(plan.contains("activity_correction_target_event"), plan)
        XCTAssertTrue(plan.contains("activity_correction_hide_document"), plan)
        XCTAssertTrue(plan.contains("activity_correction_revoke_target"), plan)
        XCTAssertFalse(plan.contains("SCAN c"), plan)
        XCTAssertFalse(plan.contains("SCAN r"), plan)
    }

    func testPolicyIdentityRequiresLiveCapabilityAndChangesAcrossEqualPolicyEpochs() async throws {
        do { _ = try await database.localContextPolicyIdentity(); XCTFail("Disk-only state granted authority") } catch { }
        let first = try await database.beginScreenEvidenceWriterSession(policy: .init(config: CaptureConfig()))
        try await database.activateScreenEvidencePolicy(first)
        let checked = try await database.localContextPolicyIdentity()
        XCTAssertEqual(checked, first)
        let next = try await database.prepareScreenEvidencePolicy(session: first.session, policy: .init(config: CaptureConfig()))
        try await database.activateScreenEvidencePolicy(next)
        let current = try await database.localContextPolicyIdentity()
        XCTAssertEqual(current.policySHA256, first.policySHA256)
        XCTAssertNotEqual(current.policyEpoch, first.policyEpoch)
        try await database.endScreenEvidenceWriterSession(next.session)
        do { _ = try await database.localContextPolicyIdentity(); XCTFail("Ended capability admitted context") } catch { }
    }

    func testReadIdentityIncludesDimensionOnlyExtractionPublication() async throws {
        let active = try await database.beginScreenEvidenceWriterSession(policy: .init(config: CaptureConfig()))
        try await database.activateScreenEvidencePolicy(active)
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let segment = try await database.insertSegment(bundleID: "com.authored.context", startDate: time, endDate: time,
            windowName: "Authored dimensions", browserUrl: nil, type: 0)
        let video = try await database.insertVideoSegment(.init(id: .init(value: 0), startTime: time, endTime: time,
            frameCount: 1, fileSizeBytes: 0, relativePath: "authored-pending.mp4", width: 0, height: 0))
        let id = try await database.insertFrame(.init(id: .init(value: 0), timestamp: time, segmentID: .init(value: segment),
            videoID: .init(value: video), frameIndexInSegment: 0, encodingStatus: .pending,
            metadata: .init(appBundleID: "com.authored.context")))
        let stored = try await database.getFrame(id: .init(value: id))
        let frame = try XCTUnwrap(stored)
        let before = try await database.localContextReadIdentity()
        _ = try await database.materializeScreenEvidence(frame: frame, storeID: before.storeID, width: 640, height: 360, text: nil)
        let after = try await database.localContextReadIdentity()
        XCTAssertEqual(after.screenRevision, before.screenRevision)
        XCTAssertGreaterThan(after.nativeFeedSequence, before.nativeFeedSequence)
        XCTAssertNotEqual(after, before)
    }

    private func event(document: String? = nil) async throws -> PersistedActivityEvent {
        try await database.appendActivity(.init(sessionID: UUID(), sequence: 1, monotonicTime: 1,
            kind: .focus, coverage: .observed,
            context: .init(appBundleID: "com.authored.context", appName: "Authored", processID: 1,
                processGeneration: "run", windowID: 1, windowGeneration: "window", windowTitle: "Same title", documentID: document), method: "authored"))
    }
}
