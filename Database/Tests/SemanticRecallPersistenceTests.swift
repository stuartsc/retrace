import CryptoKit
import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database

/// Real private SQLCipher files, canonical capture/extraction publication and
/// retained authored MiniLM vectors. No model, live history or network is used.
final class SemanticRecallPersistenceTests: XCTestCase {
    private var directory: URL!
    private var db: OpaquePointer!
    private var storeID: UUID!
    private var capability = ScreenEvidenceAdmissionCapability()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let uptime: TimeInterval = 10_000
    private var clock: ScreenEvidenceAdmissionClock {
        let instant = ScreenEvidenceAdmissionClock.Instant(date: now, uptime: uptime)
        return .init(sample: { instant })
    }
    private var path: String { directory.appendingPathComponent("semantic.sqlite").path }
    private var policy: ScreenEvidenceAccessPolicy { .init(config: CaptureConfig()) }
    private var oracle: OracleCase!
    private var pageOracle: CanonicalPageOracle!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-index-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        db = try openWriter()
        try await MigrationRunner(db: db).runMigrations()
        storeID = try RecallSQL.nativeStore(db)
        try PipelineSQL.execute(db, """
            INSERT INTO segment(id,bundleID,startDate,endDate,windowName,type)
            VALUES(1,'com.test.semantic',1800000000000,1800000000000,'Authored retained context',0)
            """)
        // This fixture is committed with the Search runtime. It is the same
        // authored PyTorch oracle independently checked by native Core ML.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: root.appendingPathComponent("Search/Tests/Fixtures/MiniLM/embedding-oracle.json"))
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                       "9436ed5fde8039612f1a9355da0999a02f659622cb9e8838824c0672a9facf8f")
        oracle = try XCTUnwrap(JSONDecoder().decode(Oracle.self, from: bytes).cases.first { $0.id == "cedar-draft" })
        let pageBytes = try Data(contentsOf: root.appendingPathComponent("Search/Tests/Fixtures/MiniLM/canonical-page-oracle.json"))
        XCTAssertEqual(SHA256.hash(data: pageBytes).map { String(format: "%02x", $0) }.joined(),
                       "0dc3fde15d7530f1d4154b98763daad30c2f7764b32c8a5114a60d919b37e910")
        pageOracle = try JSONDecoder().decode(CanonicalPageOracle.self, from: pageBytes)
        try activate()
    }

    override func tearDown() async throws {
        if let db { sqlite3_commit_hook(db, nil, nil); XCTAssertEqual(sqlite3_close_v2(db), SQLITE_OK) }
        db = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testFreshMaterialBeatsTenThousandHistoricalObservationsAndResumesFixedBoundary() throws {
        let historical = try PipelineSQL.transaction(db) {
            try (0..<10_000).map { _ in try capture(oracle.text, transaction: false) }
        }
        let firstHistorical = try XCTUnwrap(historical.first)
        let lastHistorical = try XCTUnwrap(historical.last)
        let cursor = try begin()
        let initial = try coverage(cursor)
        XCTAssertEqual(initial.maximumBackfillFrameID, lastHistorical.frameID.value)
        let fresh = try capture(oracle.text)
        let page = try claim(cursor, inspected: 1)
        let input = try XCTUnwrap(page.input)
        XCTAssertEqual(input.claim.reference, fresh)
        XCTAssertEqual(input.claim.lane, .fresh)
        XCTAssertEqual(page.inspectedCount, 1)
        _ = try publish(input)
        let history = try XCTUnwrap(claim(cursor, inspected: 1).input)
        XCTAssertEqual(history.claim.reference, firstHistorical)
        XCTAssertEqual(history.claim.lane, .backfill)
        XCTAssertFalse(try coverage(cursor).caughtUp)
        XCTAssertEqual(try coverage(cursor).maximumBackfillFrameID, lastHistorical.frameID.value)
    }

    func testDeletedAndRedactedFreshChangesAdvanceWithoutClaimingBackfillIsFinished() throws {
        _ = try capture(oracle.text)
        _ = try capture(oracle.text)
        let cursor = try begin()
        let deleted = try capture(oracle.text)
        let redacted = try capture(oracle.text)
        try PipelineSQL.execute(db, "DELETE FROM frame WHERE id=?", [.integer(deleted.frameID.value)])
        try PipelineSQL.execute(db, "UPDATE frame SET redactionReason='authored exclusion' WHERE id=?", [.integer(redacted.frameID.value)])
        let page = try claim(cursor, inspected: 2)
        XCTAssertNil(page.input)
        XCTAssertEqual(page.inspectedCount, 2)
        XCTAssertEqual(page.coverage.freshSequence, page.coverage.latestSequence)
        XCTAssertEqual(page.coverage.lastBackfillFrameID, 0)
        XCTAssertFalse(page.coverage.caughtUp)
    }

    func testOriginalV22WorkAndV23ArtifactsStayBlockedAndUnpublished() throws {
        _ = try capture(oracle.text)
        let existing = try ScreenEvidenceConsumerSQL.begin(db, consumerID: UUID(), leaseDuration: 3600, now: now)
        _ = try ScreenEvidenceConsumerSQL.advance(db, cursor: existing.cursor, limit: 200, now: now)
        let cursor = try begin()
        _ = try publish(try XCTUnwrap(claim(cursor).input))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work WHERE state='blocked'"), 2)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_derivation"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_recall_window"), 1)
    }

    func testCompletedVectorsSurviveReopenButPersistedActivePolicyIsNotAuthority() throws {
        let reference = try capture(oracle.text)
        let cursor = try begin()
        _ = try publish(try XCTUnwrap(claim(cursor).input))
        let before = try coverage(cursor)
        XCTAssertEqual(sqlite3_close_v2(db), SQLITE_OK); db = nil
        db = try openWriter()
        capability = ScreenEvidenceAdmissionCapability()
        XCTAssertThrowsError(try read()) { XCTAssertEqual($0 as? ScreenEvidenceAdmissionError, .inactive) }
        try activate()
        let resumed = try begin()
        XCTAssertEqual(resumed.indexID, cursor.indexID)
        XCTAssertNotEqual(resumed.leaseID, cursor.leaseID)
        let after = try coverage(resumed)
        XCTAssertEqual(after.lastBackfillFrameID, before.lastBackfillFrameID)
        XCTAssertEqual(after.completedObservations, 1)
        XCTAssertEqual(try read().candidates.first?.reference, reference)
    }

    func testPageContinuationIsDurableAndPartialObservationNeverEntersRetrieval() throws {
        let text = String(repeating: oracle.text, count: 80)
        let reference = try capture(text)
        let cursor = try begin()
        let first = try XCTUnwrap(claim(cursor).input)
        XCTAssertNotNil(first.claim.nextExpansion)
        _ = try publish(first, canonicalPageFixture: true)
        XCTAssertEqual(try read().candidates.count, 0)
        XCTAssertEqual(try coverage(cursor).pendingObservations, 1)
        XCTAssertEqual(sqlite3_close_v2(db), SQLITE_OK); db = nil
        db = try openWriter(); capability = ScreenEvidenceAdmissionCapability(); try activate()
        let resumed = try begin()
        let next = try XCTUnwrap(claim(resumed).input)
        XCTAssertEqual(next.claim.pageOrdinal, 1)
        XCTAssertEqual(next.claim.expansion.cursor, first.claim.nextExpansion)
        XCTAssertNotEqual(next.text, first.text)
        XCTAssertNil(next.claim.nextExpansion)
        let publication = try publish(next, canonicalPageFixture: true)
        XCTAssertTrue(publication.observationComplete)
        let complete = try coverage(resumed)
        XCTAssertTrue(complete.fullyIndexed)
        XCTAssertEqual(complete.pendingObservations, 0)
        XCTAssertEqual(complete.completedObservations, 1)
        XCTAssertEqual(complete.publishedWindows, 6)
        let candidates = try read().candidates
        XCTAssertEqual(candidates.count, 6)
        XCTAssertTrue(candidates.allSatisfy { $0.reference == reference })
        for candidate in candidates {
            let input = candidate.pageOrdinal == 0 ? first : next
            let saved = pageOracle.pages[candidate.pageOrdinal].windows[candidate.windowOrdinal]
            XCTAssertEqual(candidate.window.inputUTF16Range, saved.utf16Range)
            XCTAssertEqual(candidate.window.spans, try input.spans(for: saved.utf16Range))
            XCTAssertEqual(candidate.window.vector, saved.vector)
        }
    }

    func testFreshArrivalPreemptsAnOlderPageContinuation() throws {
        _ = try capture(String(repeating: oracle.text, count: 80))
        let cursor = try begin()
        _ = try publish(try XCTUnwrap(claim(cursor).input), canonicalPageFixture: true)
        let fresh = try capture(oracle.text)
        let selected = try XCTUnwrap(claim(cursor).input)
        XCTAssertEqual(selected.claim.reference, fresh)
        XCTAssertEqual(selected.claim.lane, .fresh)
    }

    func testEmptyExtractionCompletesExplicitlyWithoutInventingAVector() throws {
        _ = try capture("")
        let cursor = try begin()
        let input = try XCTUnwrap(claim(cursor).input)
        XCTAssertTrue(input.text.isEmpty)
        let receipt = try SemanticRecallSQL.publish(db, capability: &capability, claim: input.claim, windows: [], clock: clock)
        XCTAssertTrue(receipt.observationComplete)
        XCTAssertEqual(try coverage(cursor).emptyObservations, 1)
        XCTAssertEqual(try coverage(cursor).publishedWindows, 0)
        XCTAssertTrue(try coverage(cursor).caughtUp)
    }

    func testCaptureBeforeOCRIsSkippedInsteadOfClaimingEmptySearchableCoverage() throws {
        _ = try capture(nil)
        let cursor = try begin()
        let page = try claim(cursor)
        XCTAssertNil(page.input)
        XCTAssertEqual(page.coverage.emptyObservations, 0)
        XCTAssertEqual(page.coverage.completedObservations, 0)
        XCTAssertEqual(page.coverage.skippedObservations, 1)
    }

    func testIdenticalPublicationRetryIsIdempotentAndConflictingRetryFails() throws {
        _ = try capture(oracle.text)
        let input = try XCTUnwrap(claim(begin()).input)
        let first = try publish(input)
        XCTAssertEqual(try publish(input), first)
        var vector = oracle.windows[0].vector; vector[0] = -vector[0]
        XCTAssertThrowsError(try SemanticRecallSQL.publish(db, capability: &capability, claim: input.claim,
            windows: [try window(input, vector: vector)], clock: clock)) {
            XCTAssertEqual($0 as? SemanticRecallError, .conflictingResult)
        }
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_recall_window"), 1)
    }

    func testFailedCommitCannotPublishVectorsOrAdvancePage() throws {
        _ = try capture(oracle.text)
        let cursor = try begin()
        let input = try XCTUnwrap(claim(cursor).input)
        sqlite3_commit_hook(db, { _ in 1 }, nil)
        XCTAssertThrowsError(try publish(input))
        sqlite3_commit_hook(db, nil, nil)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_recall_window"), 0)
        XCTAssertEqual(try coverage(cursor).pendingObservations, 1)
        _ = try publish(input)
        XCTAssertEqual(try coverage(cursor).completedObservations, 1)
    }

    func testActualDeletionPurgesPublishedBytesAndInvalidatesAnAlreadyReadStamp() throws {
        let reference = try capture(oracle.text)
        let input = try XCTUnwrap(claim(begin()).input)
        _ = try publish(input)
        let fetched = try read()
        XCTAssertEqual(fetched.candidates.count, 1)
        try PipelineSQL.execute(db, "DELETE FROM frame WHERE id=?", [.integer(reference.frameID.value)])
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_recall_window"), 0)
        XCTAssertThrowsError(try SemanticRecallSQL.revalidate(db, capability: &capability, stamp: fetched.stamp)) {
            XCTAssertEqual($0 as? SemanticRecallError, .staleRead)
        }
        XCTAssertTrue(try read().candidates.isEmpty)
        XCTAssertThrowsError(try publish(input))
    }

    func testDeletionRollbackRetainsVectorsAndReadStamp() throws {
        let reference = try capture(oracle.text)
        _ = try publish(try XCTUnwrap(claim(begin()).input))
        let fetched = try read()
        try PipelineSQL.execute(db, "BEGIN IMMEDIATE")
        try PipelineSQL.execute(db, "DELETE FROM frame WHERE id=?", [.integer(reference.frameID.value)])
        try PipelineSQL.execute(db, "ROLLBACK")
        XCTAssertEqual(try read().candidates.count, 1)
        XCTAssertNoThrow(try SemanticRecallSQL.revalidate(db, capability: &capability, stamp: fetched.stamp))
    }

    func testRevisionMediaAndRedactionChangesCannotPublishOldInference() throws {
        for mutation in ["revision", "media", "redaction"] {
            let reference = try capture(oracle.text)
            let cursor = try begin()
            let input = try XCTUnwrap(claim(cursor).input)
            switch mutation {
            case "revision":
                _ = try ScreenEvidenceSQL.commitLegacyText(db, frameID: reference.frameID, mainText: "Changed authored amount 51000", chromeText: nil)
            case "media":
                try PipelineSQL.execute(db, "INSERT INTO frame_media_unavailable(frameID,reason,observedAt) VALUES(?,'recordingMissing',?)",
                                        [.integer(reference.frameID.value), .real(now.timeIntervalSince1970)])
            default:
                try PipelineSQL.execute(db, "UPDATE frame SET redactionReason='authored exclusion' WHERE id=?", [.integer(reference.frameID.value)])
            }
            XCTAssertThrowsError(try publish(input), mutation)
            XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_recall_window"), 0)
            try PipelineSQL.execute(db, "DELETE FROM frame WHERE id=?", [.integer(reference.frameID.value)])
        }
    }

    func testMetadataABAInvalidatesClaimAndCompletedBytes() throws {
        _ = try capture(oracle.text)
        let cursor = try begin()
        let input = try XCTUnwrap(claim(cursor).input)
        _ = try publish(input)
        try PipelineSQL.execute(db, "UPDATE segment SET windowName='Different authored context' WHERE id=1")
        try PipelineSQL.execute(db, "UPDATE segment SET windowName='Authored retained context' WHERE id=1")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_recall_window"), 0)
        XCTAssertThrowsError(try publish(input))
        XCTAssertNotNil(try claim(cursor).input)
    }

    func testContextResetPurgesOnlyAffectedIndexedDocumentsWithoutWalkingLegacyFrames() throws {
        try PipelineSQL.execute(db, """
            INSERT INTO segment(id,bundleID,startDate,endDate,windowName,type)
            VALUES(2,'com.test.later',1800000000000,1800000000000,'Authored retained context',0)
            """)
        let affected = try capture(oracle.text)
        let unaffected = try capture(oracle.text, segmentID: 2)
        let cursor = try begin()
        let first = try XCTUnwrap(claim(cursor).input)
        _ = try publish(first)
        let second = try XCTUnwrap(claim(cursor).input)
        _ = try publish(second)
        XCTAssertEqual(Set([first.claim.reference, second.claim.reference]), Set([affected, unaffected]))
        // Actual unmaterialized legacy frames share the changed context. They
        // have no semantic document to purge and must not dominate foreground work.
        try PipelineSQL.execute(db, """
            WITH RECURSIVE legacy(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM legacy WHERE n<3000)
            INSERT INTO frame(createdAt,imageFileName,segmentId)
            SELECT 1800000000000,'',1 FROM legacy
            """)
        let before = try scalar("SELECT generation FROM semantic_recall_index")
        let bytes = try PipelineSQL.query(db, "SELECT vector FROM semantic_recall_window ORDER BY rowID") {
            Data(bytes: sqlite3_column_blob($0, 0)!, count: Int(sqlite3_column_bytes($0, 0)))
        }
        try PipelineSQL.execute(db, "BEGIN IMMEDIATE")
        let steps = try measuredContextUpdate()
        XCTAssertLessThan(steps, 5000, "Unindexed legacy frames must not dominate indexed context invalidation")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_recall_page"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_recall_window"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_recall_attempt"), 1)
        XCTAssertEqual(try scalar("SELECT completedCount FROM semantic_recall_index"), 1)
        XCTAssertEqual(try scalar("SELECT pendingCount FROM semantic_recall_index"), 1)
        XCTAssertGreaterThan(try scalar("SELECT generation FROM semantic_recall_index"), before)
        let retained = try PipelineSQL.integers(db, "SELECT frameID FROM semantic_recall_document WHERE status='complete'")
        XCTAssertEqual(retained, [unaffected.frameID.value])
        XCTAssertEqual(try scalar("SELECT pageCount FROM semantic_recall_document WHERE status='pending'"), 0)
        try PipelineSQL.execute(db, "ROLLBACK")
        let restored = try PipelineSQL.query(db, "SELECT vector FROM semantic_recall_window ORDER BY rowID") {
            Data(bytes: sqlite3_column_blob($0, 0)!, count: Int(sqlite3_column_bytes($0, 0)))
        }
        XCTAssertEqual(restored, bytes)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_recall_attempt"), 2)
        XCTAssertEqual(try scalar("SELECT generation FROM semantic_recall_index"), before)
        _ = try measuredContextUpdate()
        let affectedClaim = first.claim.reference == affected ? first : second
        XCTAssertThrowsError(try publish(affectedClaim))
        XCTAssertEqual(try PipelineSQL.integers(db,
            "SELECT frameID FROM semantic_recall_document WHERE status='complete'"), [unaffected.frameID.value])
    }

    private func measuredContextUpdate() throws -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "UPDATE segment SET windowName='Different authored context' WHERE id=1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0)
    }

    func testPolicyABACannotResurrectRemovedVectorsOrClaims() throws {
        _ = try capture(oracle.text)
        let cursor = try begin()
        let input = try XCTUnwrap(claim(cursor).input)
        _ = try publish(input)
        let owner = try XCTUnwrap(capability.session)
        var transition = try ScreenEvidenceAdmissionSQL.prepare(db, capability: &capability, session: owner,
            policy: .init(config: CaptureConfig(excludedAppBundleIDs: ["com.test.semantic"])))
        try ScreenEvidenceAdmissionSQL.activate(db, capability: &capability, transition: transition)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_recall_window"), 0)
        XCTAssertTrue(try read().candidates.isEmpty)
        transition = try ScreenEvidenceAdmissionSQL.prepare(db, capability: &capability, session: owner, policy: policy)
        try ScreenEvidenceAdmissionSQL.activate(db, capability: &capability, transition: transition)
        XCTAssertTrue(try read().candidates.isEmpty)
        XCTAssertThrowsError(try publish(input))
        XCTAssertNotNil(try claim(cursor).input)
    }

    func testTimeAndAppFiltersAreAppliedBeforeTheOutputLimit() throws {
        let first = try capture(oracle.text)
        try PipelineSQL.execute(db, "INSERT INTO segment(id,bundleID,startDate,endDate,windowName,type) VALUES(2,'com.test.later',1800000001000,1800000001000,'Later',0)")
        let later = try capture(oracle.text, segmentID: 2, timestamp: now.addingTimeInterval(1))
        let cursor = try begin()
        _ = try publish(try XCTUnwrap(claim(cursor).input))
        _ = try publish(try XCTUnwrap(claim(cursor).input))
        let page = try SemanticRecallSQL.read(db, capability: &capability,
            request: .init(filter: .init(from: now.addingTimeInterval(0.5), appBundleIDs: ["com.test.later"]), maximumWindows: 1), clock: clock)
        XCTAssertEqual(page.candidates.map(\.reference), [later])
        XCTAssertNotEqual(page.candidates.first?.reference, first)
    }

    func testHiddenFilteringPrecedesInspectionAndOutputBudgets() throws {
        let hidden = try capture(oracle.text)
        _ = try capture(oracle.text)
        try PipelineSQL.execute(db, "INSERT INTO segment(id,bundleID,startDate,endDate,windowName,type) VALUES(2,'com.test.later',1800000000000,1800000000000,'Visible',0)")
        let visible = try capture(oracle.text, segmentID: 2)
        try PipelineSQL.execute(db, "INSERT INTO segment_tag(segmentId,tagId) SELECT 1,id FROM tag WHERE name='hidden'")
        let cursor = try begin()
        for _ in 0..<3 { _ = try publish(try XCTUnwrap(claim(cursor).input)) }
        let page = try SemanticRecallSQL.read(db, capability: &capability,
            request: .init(maximumWindows: 1, maximumInspected: 1), clock: clock)
        XCTAssertEqual(page.candidates.map(\.reference), [visible])
        XCTAssertEqual(page.inspectedCount, 1)
        XCTAssertNil(page.nextCursor)
        let onlyHidden = try SemanticRecallSQL.read(db, capability: &capability,
            request: .init(filter: .init(hiddenFilter: .onlyHidden), maximumWindows: 1, maximumInspected: 1), clock: clock)
        XCTAssertEqual(onlyHidden.candidates.map(\.reference), [hidden])
        let all = try SemanticRecallSQL.read(db, capability: &capability,
            request: .init(filter: .init(hiddenFilter: .showAll), maximumWindows: 1), clock: clock)
        XCTAssertEqual(all.candidates.map(\.reference), [hidden])
    }

    func testExcludedAppFilteringPrecedesInspectionAndOutputBudgets() throws {
        _ = try capture(oracle.text)
        _ = try capture(oracle.text)
        try PipelineSQL.execute(db, "INSERT INTO segment(id,bundleID,startDate,endDate,windowName,type) VALUES(2,'com.test.later',1800000000000,1800000000000,'Included app',0)")
        let visible = try capture(oracle.text, segmentID: 2)
        let cursor = try begin()
        for _ in 0..<3 { _ = try publish(try XCTUnwrap(claim(cursor).input)) }
        let page = try SemanticRecallSQL.read(db, capability: &capability,
            request: .init(filter: .init(excludedAppBundleIDs: ["com.test.semantic"]), maximumWindows: 1, maximumInspected: 1), clock: clock)
        XCTAssertEqual(page.candidates.map(\.reference), [visible])
        XCTAssertEqual(page.inspectedCount, 1)
        XCTAssertNil(page.nextCursor)
        let contradiction = try SemanticRecallSQL.read(db, capability: &capability,
            request: .init(filter: .init(appBundleIDs: ["com.test.semantic"], excludedAppBundleIDs: ["com.test.semantic"])), clock: clock)
        XCTAssertTrue(contradiction.candidates.isEmpty)
    }

    func testHiddenMutationAndABAInvalidateReadWithoutDeletingVectors() throws {
        _ = try capture(oracle.text)
        _ = try publish(try XCTUnwrap(claim(begin()).input))
        let stamp = try read().stamp
        try PipelineSQL.execute(db, "INSERT INTO segment_tag(segmentId,tagId) SELECT 1,id FROM tag WHERE name='hidden'")
        XCTAssertTrue(try read().candidates.isEmpty)
        XCTAssertThrowsError(try SemanticRecallSQL.revalidate(db, capability: &capability, stamp: stamp)) {
            XCTAssertEqual($0 as? SemanticRecallError, .staleRead)
        }
        try PipelineSQL.execute(db, "DELETE FROM segment_tag WHERE segmentId=1")
        XCTAssertEqual(try read().candidates.count, 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_recall_window"), 1)
        XCTAssertThrowsError(try SemanticRecallSQL.revalidate(db, capability: &capability, stamp: stamp))
        let renamed = try read().stamp
        try PipelineSQL.execute(db, "UPDATE tag SET name='renamed hidden' WHERE name='hidden'")
        XCTAssertThrowsError(try SemanticRecallSQL.revalidate(db, capability: &capability, stamp: renamed))
    }

    func testVectorReadContinuationIsBoundToFilterAndGeneration() throws {
        for _ in 0..<3 { _ = try capture(oracle.text) }
        let cursor = try begin()
        for _ in 0..<3 { _ = try publish(try XCTUnwrap(claim(cursor).input)) }
        let first = try SemanticRecallSQL.read(db, capability: &capability, request: .init(maximumWindows: 1), clock: clock)
        let next = try XCTUnwrap(first.nextCursor)
        XCTAssertThrowsError(try SemanticRecallSQL.read(db, capability: &capability,
            request: .init(filter: .init(appBundleIDs: ["different"]), cursor: next), clock: clock))
        for filter in [SemanticRecallFilter(hiddenFilter: .showAll),
                       SemanticRecallFilter(excludedAppBundleIDs: ["different"])] {
            XCTAssertThrowsError(try SemanticRecallSQL.read(db, capability: &capability,
                request: .init(filter: filter, cursor: next), clock: clock)) {
                XCTAssertEqual($0 as? SemanticRecallError, .invalidLimits)
            }
        }
        let second = try SemanticRecallSQL.read(db, capability: &capability, request: .init(cursor: next, maximumWindows: 1), clock: clock)
        XCTAssertNotEqual(second.candidates.first?.rowID, first.candidates.first?.rowID)
        _ = try capture(oracle.text)
        XCTAssertThrowsError(try SemanticRecallSQL.read(db, capability: &capability, request: .init(cursor: next), clock: clock))
    }

    func testInvalidVectorsNeverWriteAnyBytes() throws {
        _ = try capture(oracle.text)
        let input = try XCTUnwrap(claim(begin()).input)
        let originals = oracle.windows[0].vector
        var nonfinite = originals; nonfinite[0] = .nan
        var infinity = originals; infinity[0] = .infinity
        for vector in [Array(originals.dropLast()), Array(repeating: Float(0), count: 384), nonfinite, infinity] {
            XCTAssertThrowsError(try SemanticRecallSQL.publish(db, capability: &capability, claim: input.claim,
                windows: [try window(input, vector: vector)], clock: clock)) {
                XCTAssertEqual($0 as? SemanticRecallError, .invalidVector)
            }
        }
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_recall_window"), 0)
    }

    func testForgedSourceSpansAndMissingInitialWindowAreRejected() throws {
        _ = try capture(oracle.text)
        let input = try XCTUnwrap(claim(begin()).input)
        let real = try window(input)
        let wrong = SemanticRecallVectorWindow(tokenStart: real.tokenStart, tokenEnd: real.tokenEnd,
            inputUTF16Range: real.inputUTF16Range, spans: [], vector: real.vector)
        XCTAssertThrowsError(try SemanticRecallSQL.publish(db, capability: &capability, claim: input.claim, windows: [wrong], clock: clock)) {
            XCTAssertEqual($0 as? SemanticRecallError, .invalidSpan)
        }
        let missing = SemanticRecallVectorWindow(tokenStart: 1, tokenEnd: real.tokenEnd,
            inputUTF16Range: real.inputUTF16Range, spans: real.spans, vector: real.vector)
        XCTAssertThrowsError(try SemanticRecallSQL.publish(db, capability: &capability, claim: input.claim, windows: [missing], clock: clock)) {
            XCTAssertEqual($0 as? SemanticRecallError, .incompleteWindows)
        }
    }

    func testClaimExpiryCancellationAndNewWriterCannotPublish() throws {
        _ = try capture(oracle.text)
        let cursor = try begin()
        var input = try XCTUnwrap(claim(cursor).input)
        let expired = ScreenEvidenceAdmissionClock.Instant(date: now.addingTimeInterval(31), uptime: uptime + 31)
        XCTAssertThrowsError(try SemanticRecallSQL.publish(db, capability: &capability, claim: input.claim,
            windows: [try window(input)], clock: .init(sample: { expired }))) {
                XCTAssertEqual($0 as? SemanticRecallError, .claimExpired)
        }
        try SemanticRecallSQL.cancel(db, capability: &capability, claim: input.claim)
        XCTAssertThrowsError(try publish(input))
        input = try XCTUnwrap(claim(cursor).input)
        try activate()
        XCTAssertThrowsError(try publish(input)) { XCTAssertEqual($0 as? ScreenEvidenceAdmissionError, .staleSession) }
        XCTAssertNotNil(try claim(begin()).input)
    }

    func testCancellationProvesDeletedOrRetiredClaimsWithoutTouchingReplacementWork() throws {
        let removed = try capture(oracle.text)
        let first = try XCTUnwrap(claim(begin()).input)
        try PipelineSQL.execute(db, "DELETE FROM frame WHERE id=?", [.integer(removed.frameID.value)])
        XCTAssertNoThrow(try SemanticRecallSQL.cancel(db, capability: &capability, claim: first.claim))
        _ = try capture(oracle.text)
        let second = try XCTUnwrap(claim(begin()).input)
        XCTAssertNoThrow(try SemanticRecallSQL.cancel(db, capability: &capability, claim: first.claim))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_recall_attempt WHERE status='claimed'"), 1)
        var unrelated = ScreenEvidenceAdmissionCapability()
        XCTAssertThrowsError(try SemanticRecallSQL.cancel(db, capability: &unrelated, claim: second.claim)) {
            XCTAssertEqual($0 as? ScreenEvidenceAdmissionError, .staleSession)
        }
        try SemanticRecallSQL.cancel(db, capability: &capability, claim: second.claim)
        XCTAssertNoThrow(try SemanticRecallSQL.cancel(db, capability: &unrelated, claim: second.claim))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_recall_attempt WHERE status='claimed'"), 0)
    }

    func testClaimCannotReturnTextAfterItsFinalResponseWorkCrossesTheDeadline() throws {
        _ = try capture(oracle.text)
        let cursor = try begin()
        let clock = SemanticFinalBoundaryClock(now: now, uptime: uptime)
        XCTAssertThrowsError(try SemanticRecallSQL.claim(db, capability: &capability, cursor: cursor,
            maximumInspected: 10, executionDuration: 30, clock: .init(sample: { clock.sample() }))) {
            XCTAssertEqual($0 as? SemanticRecallError, .claimExpired)
        }
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM semantic_recall_attempt"), 0)
        XCTAssertEqual(try coverage(cursor).lastBackfillFrameID, 0)
    }

    func testCorruptedStoredVectorFailsClosedInsteadOfReachingRanking() throws {
        _ = try capture(oracle.text)
        _ = try publish(try XCTUnwrap(claim(begin()).input))
        try PipelineSQL.execute(db, "UPDATE semantic_recall_window SET vector=zeroblob(1536)")
        XCTAssertThrowsError(try read()) { XCTAssertEqual($0 as? SemanticRecallError, .integrityFailure) }
    }

    func testFreshTailStillWorksAfterRawV22FeedCompaction() throws {
        _ = try capture(oracle.text)
        let cursor = try begin()
        let fresh = try capture(oracle.text)
        _ = try ScreenEvidenceConsumerSQL.compact(db, limit: 1000, now: now)
        XCTAssertGreaterThan(try ScreenEvidenceFeedSQL.status(db).retainedThrough, 0)
        XCTAssertEqual(try claim(cursor).input?.claim.reference, fresh)
    }

    private func begin() throws -> SemanticRecallCursor {
        try SemanticRecallSQL.begin(db, capability: &capability, transformation: .miniLMNativeV1, leaseDuration: 3600, clock: clock)
    }
    private func claim(_ cursor: SemanticRecallCursor, inspected: Int = 200) throws -> SemanticRecallWorkPage {
        try SemanticRecallSQL.claim(db, capability: &capability, cursor: cursor, maximumInspected: inspected,
                                    executionDuration: 30, clock: clock)
    }
    private func coverage(_ cursor: SemanticRecallCursor) throws -> SemanticRecallCoverage {
        try SemanticRecallSQL.coverage(db, capability: &capability, cursor: cursor, clock: clock)
    }
    private func read() throws -> SemanticRecallVectorPage {
        try SemanticRecallSQL.read(db, capability: &capability, request: .init(), clock: clock)
    }
    @discardableResult private func publish(_ input: SemanticRecallInput, canonicalPageFixture: Bool = false) throws -> SemanticRecallPublication {
        let windows: [SemanticRecallVectorWindow]
        if canonicalPageFixture {
            let page = try XCTUnwrap(pageOracle.pages.first { $0.ordinal == input.claim.pageOrdinal })
            XCTAssertEqual(input.text, page.text, "Actual canonical page must match the independently generated tokenizer/model oracle")
            windows = try page.windows.map { saved in
                .init(tokenStart: saved.tokenStart, tokenEnd: saved.tokenEnd, inputUTF16Range: saved.utf16Range,
                      spans: try input.spans(for: saved.utf16Range), vector: saved.vector)
            }
        } else { windows = [try window(input)] }
        return try SemanticRecallSQL.publish(db, capability: &capability, claim: input.claim, windows: windows, clock: clock)
    }
    private func window(_ input: SemanticRecallInput, vector: [Float]? = nil) throws -> SemanticRecallVectorWindow {
        let saved = oracle.windows[0]
        return .init(tokenStart: saved.tokenStart, tokenEnd: saved.tokenEnd, inputUTF16Range: saved.utf16Range,
                     spans: try input.spans(for: saved.utf16Range), vector: vector ?? saved.vector)
    }
    private func activate() throws {
        let transition = try ScreenEvidenceAdmissionSQL.begin(db, capability: &capability, policy: policy)
        try ScreenEvidenceAdmissionSQL.activate(db, capability: &capability, transition: transition)
    }
    private func capture(_ text: String?, segmentID: Int64 = 1, timestamp: Date? = nil, transaction: Bool = true) throws -> ScreenEvidenceRef {
        let operation = {
            let bundleID = segmentID == 1 ? "com.test.semantic" : "com.test.later"
            let descriptor = FrameReference(id: .init(value: 0), timestamp: timestamp ?? self.now,
                segmentID: .init(value: segmentID), frameIndexInSegment: 0,
                metadata: FrameMetadata(appBundleID: bundleID, windowName: "Authored retained context"))
            let id = try FrameQueries.insert(db: self.db, frame: descriptor)
            try ScreenEvidenceSQL.capture(self.db, frameID: id, descriptor: descriptor)
            if let text { _ = try ScreenEvidenceSQL.commitLegacyText(self.db, frameID: .init(value: id), mainText: text, chromeText: nil) }
            return try XCTUnwrap(ScreenEvidenceSQL.current(self.db, frameID: .init(value: id), storeID: self.storeID)).ref
        }
        if transaction { return try PipelineSQL.transaction(db, operation) }
        return try operation()
    }
    private func scalar(_ sql: String) throws -> Int64 { try XCTUnwrap(PipelineSQL.integers(db, sql).first) }
    private func openWriter() throws -> OpaquePointer {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else { throw SemanticRecallError.integrityFailure }
        do {
            try PipelineSQL.execute(connection, "PRAGMA foreign_keys=ON")
            _ = try PipelineSQL.query(connection, "PRAGMA journal_mode=WAL") { _ in () }
            sqlite3_busy_timeout(connection, 1000)
            return connection
        } catch { sqlite3_close_v2(connection); throw error }
    }
    private struct CanonicalPageOracle: Decodable {
        let pages: [Page]
        struct Page: Decodable { let ordinal: Int; let text: String; let windows: [OracleWindow] }
    }
    private struct Oracle: Decodable { let cases: [OracleCase] }
    private struct OracleCase: Decodable { let id: String; let text: String; let windows: [OracleWindow] }
    private struct OracleWindow: Decodable {
        let tokenStart: Int; let tokenEnd: Int; let utf16Range: EvidenceUTF16Range; let vector: [Float]
    }
}

/// The fourth clock sample is the final claim result boundary, after input
/// projection and both write-time deadline checks. Its lease remains valid.
private final class SemanticFinalBoundaryClock: @unchecked Sendable {
    private let lock = NSLock()
    private let now: Date
    private let uptime: TimeInterval
    private var samples = 0
    init(now: Date, uptime: TimeInterval) { self.now = now; self.uptime = uptime }
    func sample() -> ScreenEvidenceAdmissionClock.Instant {
        lock.lock(); defer { lock.unlock() }; samples += 1
        let advance: TimeInterval = samples >= 4 ? 31 : 0
        return .init(date: now.addingTimeInterval(advance), uptime: uptime + advance)
    }
}
