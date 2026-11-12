import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database

final class ExactOCRRepairPersistenceTests: XCTestCase {
    func testRepairAppendsRevisionAndPreservesPriorExtraction() async throws {
        let fixture = try await Fixture.make()
        let target = try await fixture.target()
        let result = try await fixture.commit(target)
        XCTAssertEqual(result.reference.extractionRevision, target.snapshot.ref.extractionRevision + 1)
        let old = try await fixture.db.screenEvidence(target.snapshot.ref)
        let current = try await fixture.db.screenEvidence(result.reference)
        let document = try await fixture.db.getDocument(frameID: fixture.frame)
        XCTAssertEqual(old?.text?.fullText, "Original authored text")
        XCTAssertEqual(current?.text?.fullText, "Replacement authored text")
        XCTAssertEqual(document?.content, "Replacement authored text")
        try await fixture.db.close()
    }

    func testRevisionZeroIsDistinctFromMissingOrStaleExtraction() async throws {
        let fixture = try await Fixture.make(indexed: false)
        let target = try await fixture.target()
        XCTAssertEqual(target.snapshot.ref.extractionRevision, 0); XCTAssertNil(target.snapshot.text)
        let result = try await fixture.commit(target)
        XCTAssertEqual(result.reference.extractionRevision, 1)
        do { _ = try await fixture.commit(target); XCTFail("Old revision must not publish twice") }
        catch ExactOCRRepairError.staleTarget { }
        try await fixture.db.close()
    }

    func testCurrentVisibilityPolicyAndAutomaticClaimAreRequired() async throws {
        let fixture = try await Fixture.make(), target = try await fixture.target()
        let wrong = ScreenEvidenceRef(storeID: UUID(), source: .native, observationID: target.snapshot.ref.observationID,
            frameID: fixture.frame, extractionRevision: target.snapshot.ref.extractionRevision)
        do { _ = try await fixture.db.exactOCRRepairTarget(wrong, policy: fixture.policy); XCTFail("Wrong source") }
        catch ExactOCRRepairError.staleTarget { }
        do {
            _ = try await fixture.db.exactOCRRepairTarget(target.snapshot.ref,
                policy: .init(config: CaptureConfig(excludedAppBundleIDs: ["com.fixture.repair"])))
            XCTFail("Excluded source")
        } catch ExactOCRRepairError.invalidTarget { }
        let hiddenValue = try await fixture.db.getTag(name: "hidden"), hidden = try XCTUnwrap(hiddenValue)
        try await fixture.db.addTagToSegment(segmentId: .init(value: fixture.segment), tagId: hidden.id)
        do { _ = try await fixture.commit(target); XCTFail("Hidden source") }
        catch ExactOCRRepairError.staleTarget { }
        try await fixture.db.removeTagFromSegment(segmentId: .init(value: fixture.segment), tagId: hidden.id)
        try await fixture.db.updateFrameProcessingStatus(frameID: fixture.frame.value, status: 0)
        _ = try await fixture.db.enqueueFrameForProcessing(frameID: fixture.frame.value)
        do { _ = try await fixture.commit(target); XCTFail("Pending automatic claim") }
        catch ExactOCRRepairError.staleTarget { }
        _ = try await fixture.db.dequeueFrameForProcessing()
        do { _ = try await fixture.commit(target); XCTFail("Active automatic claim") }
        catch ExactOCRRepairError.staleTarget { }
        let original = try await fixture.db.screenEvidence(target.snapshot.ref)
        XCTAssertEqual(original?.text?.fullText, "Original authored text")
        try await fixture.db.close()
    }

    func testRevokedFenceAndFailedPublicationLeaveExistingTextIntact() async throws {
        let fixture = try await Fixture.make(), target = try await fixture.target()
        let fence = NativeMutationFence(); fence.invalidate()
        do { _ = try await fixture.commit(target, fence: fence); XCTFail("Revoked admission") }
        catch is CancellationError { }
        let connection = await fixture.db.getConnection(), db = try XCTUnwrap(connection)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TEMP TRIGGER reject_repair BEFORE UPDATE OF processingStatus ON frame WHEN NEW.processingStatus=2 BEGIN SELECT RAISE(ABORT,'authored failure'); END", nil, nil, nil), SQLITE_OK)
        do { _ = try await fixture.commit(target); XCTFail("Injected write failure") } catch { }
        let current = try await fixture.db.currentScreenEvidence(frameID: fixture.frame, storeID: target.snapshot.ref.storeID)
        let document = try await fixture.db.getDocument(frameID: fixture.frame)
        XCTAssertEqual(current?.ref, target.snapshot.ref)
        XCTAssertEqual(document?.content, "Original authored text")
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER reject_repair", nil, nil, nil), SQLITE_OK)
        try await fixture.db.deleteFrame(id: fixture.frame)
        do { _ = try await fixture.commit(target); XCTFail("Deleted source") }
        catch ExactOCRRepairError.staleTarget { }
        try await fixture.db.close()
    }

    func testGrantExpiryDuringNativePublicationRollsBackBeforeCommit() async throws {
        let fixture = try await Fixture.make()
        try await fixture.db.updateFrameProcessingStatus(frameID: fixture.frame.value, status: 3)
        let target = try await fixture.target()
        let now = Date(timeIntervalSince1970: 1_800_000_000), clock = RepairExpiryClock(now)
        let fence = NativeMutationFence(expiresAt: now.addingTimeInterval(1), clock: { clock.now() })
        let connection = await fixture.db.getConnection(), db = try XCTUnwrap(connection)
        let context = Unmanaged.passRetained(clock).toOpaque()
        XCTAssertEqual(sqlite3_create_function_v2(db, "advance_repair_clock", 0, SQLITE_UTF8,
            context, { context, _, _ in
                guard let context, let stored = sqlite3_user_data(context) else { return }
                Unmanaged<RepairExpiryClock>.fromOpaque(stored).takeUnretainedValue().advance()
                sqlite3_result_int(context, 1)
            }, nil, nil, { context in
                if let context { Unmanaged<RepairExpiryClock>.fromOpaque(context).release() }
            }), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TEMP TRIGGER expire_repair AFTER UPDATE OF processingStatus ON frame WHEN NEW.processingStatus=2 BEGIN SELECT advance_repair_clock(); END", nil, nil, nil), SQLITE_OK)
        do { _ = try await fixture.commit(target, fence: fence); XCTFail("Publication crossed the admitted grant deadline") }
        catch is CancellationError { }
        XCTAssertEqual(clock.now(), now.addingTimeInterval(2), "The real SQLite publication must have advanced the clock")
        let current = try await fixture.db.currentScreenEvidence(frameID: fixture.frame, storeID: fixture.ref.storeID)
        let document = try await fixture.db.getDocument(frameID: fixture.frame)
        let status = try await fixture.db.getFrameProcessingStatus(frameID: fixture.frame.value)
        XCTAssertEqual(current?.ref, target.snapshot.ref)
        XCTAssertEqual(current?.text?.fullText, "Original authored text")
        XCTAssertEqual(document?.content, "Original authored text")
        XCTAssertEqual(status, 3)
        let oldHits = try PipelineSQL.integers(db, "SELECT count(*) FROM searchRanking WHERE searchRanking MATCH 'Original'")
        let newHits = try PipelineSQL.integers(db, "SELECT count(*) FROM searchRanking WHERE searchRanking MATCH 'Replacement'")
        XCTAssertEqual(oldHits, [1]); XCTAssertEqual(newHits, [0])
        try await fixture.db.close()
    }

    private struct Fixture {
        let db: DatabaseManager, frame: FrameID, segment: Int64, ref: ScreenEvidenceRef
        let policy = ScreenEvidenceAccessPolicy(config: CaptureConfig.default)
        static func make(indexed: Bool = true) async throws -> Self {
            let db = DatabaseManager(databasePath: "file:repair_\(UUID())?mode=memory&cache=private")
            try await db.initialize()
            let time = Date(timeIntervalSince1970: 1_800_000_000)
            let segment = try await db.insertSegment(bundleID: "com.fixture.repair", startDate: time,
                endDate: time, windowName: "Repair fixture", browserUrl: nil, type: 0)
            let frame = FrameID(value: try await db.insertFrame(.init(id: .init(value: 0), timestamp: time,
                segmentID: .init(value: segment), frameIndexInSegment: 0,
                metadata: .init(appBundleID: "com.fixture.repair", windowName: "Repair fixture"))))
            try await db.markFrameReadable(frameID: frame.value)
            if indexed {
                _ = try await db.commitFrameOCR(frameID: frame, text: .init(frameID: frame, timestamp: time,
                    regions: [], fullText: "Original authored text"), frameWidth: 100, frameHeight: 100)
            }
            let store = try await db.activityStoreID(), saved = try await db.currentScreenEvidence(frameID: frame, storeID: store)
            return .init(db: db, frame: frame, segment: segment, ref: try XCTUnwrap(saved).ref)
        }
        func target() async throws -> ExactOCRRepairTarget { try await db.exactOCRRepairTarget(ref, policy: policy) }
        func commit(_ target: ExactOCRRepairTarget, fence: NativeMutationFence = .init()) async throws -> ExactOCRRepairOutcome {
            try await db.commitExactOCRRepair(target, text: .init(frameID: frame, timestamp: target.snapshot.frame.timestamp,
                regions: [], fullText: "Replacement authored text"), width: 100, height: 100, policy: policy, fences: [fence])
        }
    }
}

private final class RepairExpiryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); value = value.addingTimeInterval(2); lock.unlock() }
}
