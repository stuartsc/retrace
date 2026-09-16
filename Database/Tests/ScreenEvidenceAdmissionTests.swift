import CoreGraphics
import CryptoKit
import DatabaseTestSupport
import Foundation
import ImageIO
import Processing
import SQLCipher
import Shared
import XCTest
@testable import Database

/// Private SQLCipher files exercise the same synchronous writer engine used by
/// DatabaseManager. No production preferences, Keychain, library or model is read.
final class ScreenEvidenceAdmissionTests: XCTestCase {
    private var directory: URL!
    private var db: OpaquePointer!
    private var storeID: UUID!
    private var reference: ScreenEvidenceRef!
    private var consumer: ScreenEvidenceConsumerStatus!
    private var capability = ScreenEvidenceAdmissionCapability()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let uptime: TimeInterval = 10_000
    private let authoredText = "Authored invoice 42000. Café 👩🏽‍💻 日本語 e\u{301}."
    private var path: String { directory.appendingPathComponent("admission.sqlite").path }
    private var policy: ScreenEvidenceAccessPolicy { .init(config: CaptureConfig()) }
    private var transform: ScreenEvidenceTransformation {
        .init(identifier: "authored-receipt-fixture-v1", fingerprintSHA256: String(repeating: "a", count: 64),
              artifactFormat: "application/vnd.retrace.authored-test")
    }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("screen-admission-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        db = try openWriter(path)
        try await MigrationRunner(db: db).runMigrations()
        storeID = try RecallSQL.nativeStore(db)
        try PipelineSQL.execute(db, """
            INSERT INTO segment(id,bundleID,startDate,endDate,windowName,browserUrl,type)
            VALUES(1,'com.test.admission',1800000000000,1800000000000,'Authored retained context','https://authored.test',0)
            """)
        reference = try capture(authoredText)
        consumer = try ScreenEvidenceConsumerSQL.begin(db, consumerID: UUID(), leaseDuration: 7 * 24 * 60 * 60, now: now)
        try drain()
    }

    override func tearDown() async throws {
        if let db {
            sqlite3_commit_hook(db, nil, nil)
            sqlite3_trace_v2(db, 0, nil, nil)
            XCTAssertEqual(sqlite3_close_v2(db), SQLITE_OK)
        }
        db = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testV23MigrationIsAdditiveInactiveAndDoesNotScanV22Evidence() async throws {
        let legacy = try openWriter(directory.appendingPathComponent("legacy.sqlite").path)
        defer { sqlite3_close_v2(legacy) }
        try await migrateThroughV22(legacy)
        let legacyStore = try RecallSQL.nativeStore(legacy)
        try PipelineSQL.execute(legacy, "INSERT INTO segment(id,bundleID,startDate,endDate,type) VALUES(1,'authored',1,1,0)")
        let descriptor = FrameReference(id: .init(value: 0), timestamp: now, segmentID: .init(value: 1),
                                       frameIndexInSegment: 0, metadata: .empty)
        let id = try FrameQueries.insert(db: legacy, frame: descriptor)
        try ScreenEvidenceSQL.capture(legacy, frameID: id, descriptor: descriptor)
        _ = try ScreenEvidenceSQL.commitLegacyText(legacy, frameID: .init(value: id), mainText: authoredText, chromeText: nil)
        let before = try PipelineSQL.query(legacy, "SELECT payload FROM screen_extraction ORDER BY revision") { RecallSQL.string($0, 0) }
        try PipelineSQL.execute(legacy, """
            WITH RECURSIVE n(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM n WHERE value<3000)
            INSERT INTO frame(createdAt,imageFileName,segmentId) SELECT 1800000000000,'',1 FROM n
            """)
        let head = try ScreenEvidenceFeedSQL.status(legacy)
        let trace = AdmissionSQLTrace()
        installTrace(legacy, trace)
        defer { sqlite3_trace_v2(legacy, 0, nil, nil) }
        try await MigrationRunner(db: legacy).runMigrations()
        sqlite3_trace_v2(legacy, 0, nil, nil)
        XCTAssertEqual(try scalar(legacy, "SELECT MAX(version) FROM schema_migrations"), 23)
        let names = try PipelineSQL.query(legacy, "SELECT name FROM sqlite_schema WHERE type='table'") { RecallSQL.string($0, 0) }
        XCTAssertTrue(names.contains("screen_evidence_admission_state"))
        XCTAssertTrue(names.contains("screen_evidence_derivation"))
        XCTAssertEqual(try RecallSQL.nativeStore(legacy), legacyStore)
        XCTAssertEqual(try ScreenEvidenceFeedSQL.status(legacy).latestSequence, head.latestSequence)
        XCTAssertEqual(try PipelineSQL.query(legacy, "SELECT payload FROM screen_extraction ORDER BY revision") { RecallSQL.string($0, 0) }, before)
        XCTAssertLessThan(trace.steps, 30_000, "Admission migration must not enumerate retained frames/OCR")
        var fresh = ScreenEvidenceAdmissionCapability()
        assertAdmissionError(.inactive) {
            _ = try ScreenEvidenceAdmissionSQL.claim(legacy, capability: &fresh, request: request(), now: now, uptime: uptime)
        }
    }

    func testProtocolUsesActorOwnedCapabilityAndNeverMarksWorkReady() async throws {
        let manager = DatabaseManager()
        try await manager.initialize()
        do {
            let store: any ScreenEvidenceAdmissionStoreProtocol = manager
            let transition = try await store.beginScreenEvidenceWriterSession(policy: policy)
            try await store.activateScreenEvidencePolicy(transition)
            try await store.revokeScreenEvidencePolicy(transition)
            do { try await store.activateScreenEvidencePolicy(transition); XCTFail("Revoked policy must not reactivate") }
            catch { XCTAssertNotEqual(error as? ScreenEvidenceAdmissionError, .unsupported) }
            try await manager.close()
        } catch {
            try await manager.close()
            throw error
        }
    }

    func testClaimsRequireFreshLocalActivationEvenWhenDiskPolicyIsActive() throws {
        assertAdmissionError(.inactive) { _ = try claim() }
        let transition = try begin()
        assertAdmissionError(.inactive) { _ = try claim() }
        try activate(transition)
        var unauthorised = ScreenEvidenceAdmissionCapability()
        assertAdmissionError(.inactive) {
            _ = try ScreenEvidenceAdmissionSQL.claim(db, capability: &unauthorised, request: request(), now: now, uptime: uptime)
        }
        let acquired = try claim()
        XCTAssertEqual(acquired.policy, transition)
        XCTAssertEqual(acquired.request.expansion.reference, reference)
        XCTAssertEqual(acquired.inputSHA256.count, 64)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM screen_evidence_work WHERE state='blocked'"), 2)
    }

    func testPolicyABACannotReviveClaimAndStaleRevokeCannotCloseNewEpoch() throws {
        let a = try start()
        let old = try claim()
        let b = try ScreenEvidenceAdmissionSQL.prepare(db, capability: &capability, session: a.session,
            policy: .init(config: CaptureConfig(excludedAppBundleIDs: ["com.test.unrelated"])))
        try activate(b)
        let restored = try ScreenEvidenceAdmissionSQL.prepare(db, capability: &capability, session: a.session, policy: policy)
        try activate(restored)
        XCTAssertGreaterThan(restored.policyEpoch, b.policyEpoch)
        XCTAssertEqual(restored.policySHA256, a.policySHA256)
        try ScreenEvidenceAdmissionSQL.revoke(db, capability: &capability, transition: a)
        assertAdmissionError(.stalePolicy) { _ = try stage(old) }
        _ = try claim()
    }

    func testSecondWriterFencesFirstAndStaleEndDoesNotCloseReplacementOwner() throws {
        let a = try start()
        let old = try claim()
        let b = try begin()
        try activate(b)
        XCTAssertNotEqual(a.session.writerID, b.session.writerID)
        try ScreenEvidenceAdmissionSQL.end(db, capability: &capability, session: a.session)
        assertAdmissionError(.staleSession) { _ = try stage(old) }
        _ = try claim()
        var other = ScreenEvidenceAdmissionCapability()
        let c = try ScreenEvidenceAdmissionSQL.begin(db, capability: &other, policy: policy)
        try ScreenEvidenceAdmissionSQL.activate(db, capability: &other, transition: c)
        assertAdmissionError(.staleSession) { _ = try claim() }
    }

    func testPrepareCommitFailureClosesLocalAdmissionBeforeTheDurableWrite() throws {
        let active = try start()
        let old = try claim()
        sqlite3_commit_hook(db, { _ in 1 }, nil)
        XCTAssertThrowsError(try ScreenEvidenceAdmissionSQL.prepare(db, capability: &capability,
            session: active.session, policy: policy))
        sqlite3_commit_hook(db, nil, nil)
        assertAdmissionError(.inactive) { _ = try stage(old) }
        assertAdmissionError(.inactive) { _ = try claim() }
        let fresh = try begin()
        try activate(fresh)
        _ = try claim()
    }

    func testRevokeAndEndCommitFailuresCannotLeaveLocalAdmissionOpen() throws {
        var active = try start()
        var held = try claim()
        sqlite3_commit_hook(db, { _ in 1 }, nil)
        XCTAssertThrowsError(try ScreenEvidenceAdmissionSQL.revoke(db, capability: &capability, transition: active))
        sqlite3_commit_hook(db, nil, nil)
        assertAdmissionError(.inactive) { _ = try stage(held) }
        active = try begin()
        try activate(active)
        held = try claim()
        sqlite3_commit_hook(db, { _ in 1 }, nil)
        XCTAssertThrowsError(try ScreenEvidenceAdmissionSQL.end(db, capability: &capability, session: active.session))
        sqlite3_commit_hook(db, nil, nil)
        assertAdmissionError(.inactive) { _ = try stage(held) }
    }

    func testActivationCommitFailureRequiresFreshPreparation() throws {
        let prepared = try begin()
        sqlite3_commit_hook(db, { _ in 1 }, nil)
        XCTAssertThrowsError(try activate(prepared))
        sqlite3_commit_hook(db, nil, nil)
        assertAdmissionError(.inactive) { _ = try claim() }
        XCTAssertThrowsError(try activate(prepared), "A failed activation must not retain a reusable local grant")
    }

    func testCancellationInsensitiveCleanupStillRevokesDurably() async throws {
        let active = try start()
        let held = try claim()
        let task = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            try ScreenEvidenceAdmissionSQL.revoke(self.db, capability: &self.capability, transition: active)
        }
        try await task.value
        assertAdmissionError(.inactive) { _ = try stage(held) }
        XCTAssertThrowsError(try activate(active))
    }

    func testPolicyUsesBothRetainedAndCurrentMetadataAndRefusesScrubbedURLRules() throws {
        let denied = ScreenEvidenceAccessPolicy(config: CaptureConfig(excludedAppBundleIDs: ["com.test.admission"]))
        try PipelineSQL.execute(db, "UPDATE segment SET bundleID='com.test.safe' WHERE id=1")
        _ = try start(denied)
        assertAdmissionError(.notPermitted) { _ = try claim() }
        let currentDeny = ScreenEvidenceAccessPolicy(config: CaptureConfig(redactWindowTitlePatterns: ["Current blocked"]))
        _ = try start(currentDeny)
        try PipelineSQL.execute(db, "UPDATE segment SET windowName='Current blocked context' WHERE id=1")
        assertAdmissionError(.notPermitted) { _ = try claim() }
        _ = try start(.init(config: CaptureConfig(redactBrowserURLPatterns: ["credential"])))
        assertAdmissionError(.notPermitted) { _ = try claim() }
    }

    func testRetainedMetadataMutationGuardsAndMonotonicPreferencePreserveSupportedOCR() throws {
        assertSQLRejected("UPDATE screen_extraction SET payload=replace(payload,'42000','47000') WHERE observationID=?",
                          [.text(reference.observationID.uuidString)])
        assertSQLRejected("UPDATE screen_observation SET framePayload=replace(framePayload,'Authored','Forged') WHERE observationID=?",
                          [.text(reference.observationID.uuidString)])
        assertSQLRejected("UPDATE screen_observation SET preferredRevision=0 WHERE observationID=?",
                          [.text(reference.observationID.uuidString)])
        let next = try revise("Legitimate appended OCR 47000")
        XCTAssertGreaterThan(next.extractionRevision, reference.extractionRevision)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM screen_extraction WHERE observationID='\(reference.observationID.uuidString)'"), 3)
        try PipelineSQL.execute(db, "DELETE FROM frame WHERE id=?", [.integer(reference.frameID.value)])
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM screen_extraction"), 0)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM screen_deleted"), 1)
    }

    func testMetadataABAMutationsFenceHeldClaimsWithoutChangingV22Feed() throws {
        _ = try start()
        let held = try claim()
        let feed = try ScreenEvidenceFeedSQL.status(db).latestSequence
        for (column, changed, original) in [
            ("bundleID", "com.test.other", "com.test.admission"),
            ("windowName", "Different authored title", "Authored retained context"),
            ("browserUrl", "https://other.authored.test", "https://authored.test")
        ] {
            let before = try metadataEpoch()
            try PipelineSQL.execute(db, "UPDATE segment SET \(column)=? WHERE id=1", [.text(changed)])
            try PipelineSQL.execute(db, "UPDATE segment SET \(column)=? WHERE id=1", [.text(original)])
            XCTAssertEqual(try metadataEpoch(), before + 2)
        }
        XCTAssertEqual(try ScreenEvidenceFeedSQL.status(db).latestSequence, feed)
        assertAdmissionError(.sourceChanged) { _ = try stage(held) }
    }

    func testFrameSegmentABAFencesClaimsAndNoOpOrEndDateChangesDoNot() throws {
        try PipelineSQL.execute(db, "INSERT INTO segment(id,bundleID,startDate,endDate,windowName,type) VALUES(2,'com.test.admission',1,1,'Same',0)")
        _ = try start()
        let held = try claim()
        let before = try metadataEpoch()
        try PipelineSQL.execute(db, "UPDATE segment SET endDate=endDate+1,windowName=windowName WHERE id=1")
        _ = try capture("Ordinary new capture")
        XCTAssertEqual(try metadataEpoch(), before)
        try PipelineSQL.execute(db, "UPDATE frame SET segmentId=2 WHERE id=?", [.integer(reference.frameID.value)])
        try PipelineSQL.execute(db, "UPDATE frame SET segmentId=1 WHERE id=?", [.integer(reference.frameID.value)])
        XCTAssertEqual(try metadataEpoch(), before + 2)
        assertAdmissionError(.sourceChanged) { _ = try stage(held) }
    }

    func testRedactionAndMediaABARejectHeldClaimBeforeConsumerReplay() throws {
        _ = try start()
        var held = try claim()
        try PipelineSQL.execute(db, "UPDATE frame SET redactionReason='authored' WHERE id=?", [.integer(reference.frameID.value)])
        try PipelineSQL.execute(db, "UPDATE frame SET redactionReason=NULL WHERE id=?", [.integer(reference.frameID.value)])
        assertAdmissionError(.sourceChanged) { _ = try stage(held) }
        try drain()
        held = try claim()
        try PipelineSQL.execute(db, "INSERT INTO frame_media_unavailable(frameID,reason,observedAt) VALUES(?,'recordingMissing',?)",
                                [.integer(reference.frameID.value), .real(now.timeIntervalSince1970)])
        try PipelineSQL.execute(db, "DELETE FROM frame_media_unavailable WHERE frameID=?", [.integer(reference.frameID.value)])
        assertAdmissionError(.sourceChanged) { _ = try stage(held) }
    }

    func testExtractionReplacementAndDeletionInvalidateArtifactsWithoutReplay() throws {
        _ = try start()
        let held = try claim()
        let receipt = try stage(held)
        let revised = try revise("New immutable amount 47000")
        assertAdmissionError(.sourceChanged) { _ = try read(receipt) }
        try drain()
        let fresh = try claim(request(reference: revised))
        let freshReceipt = try stage(fresh)
        try PipelineSQL.execute(db, "DELETE FROM frame WHERE id=?", [.integer(reference.frameID.value)])
        assertAdmissionError(.sourceChanged) { _ = try read(freshReceipt) }
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM screen_evidence_work WHERE state='deleted'"), 2)
        XCTAssertEqual(try scalar(db, "SELECT COALESCE(SUM(artifactBytes),0) FROM screen_evidence_derivation"), 0,
                       "Explicit source deletion must remove quarantined copies in the same transaction")
    }

    func testReplacedConsumerLeaseAndExpiredLeaseDenyArtifacts() throws {
        _ = try start()
        let held = try claim()
        let receipt = try stage(held)
        try PipelineSQL.execute(db, "UPDATE screen_evidence_consumer SET expiresAt=? WHERE consumerID=?",
                                [.real(now.timeIntervalSince1970), .text(consumer.cursor.consumerID.uuidString)])
        assertAdmissionError(.invalidConsumer) { _ = try read(receipt) }
        consumer = try ScreenEvidenceConsumerSQL.begin(db, consumerID: consumer.cursor.consumerID,
                                                      leaseDuration: 100, now: now.addingTimeInterval(1))
        try drain(at: now.addingTimeInterval(1))
        assertAdmissionError(.invalidConsumer) { _ = try stage(held) }
    }

    func testForgedCursorReferenceClaimAndReceiptAreRejectedAgainstCanonicalRows() throws {
        _ = try start()
        let forgedCursor = ScreenEvidenceConsumerCursor(feedID: UUID(), storeID: storeID,
            consumerID: consumer.cursor.consumerID, leaseID: consumer.cursor.leaseID)
        assertAdmissionError(.invalidConsumer) { _ = try claim(request(cursor: forgedCursor)) }
        let wrong = ScreenEvidenceRef(storeID: storeID, source: .native, observationID: UUID(),
            frameID: reference.frameID, extractionRevision: reference.extractionRevision)
        assertAdmissionError(.invalidReference) { _ = try claim(request(reference: wrong)) }
        let held = try claim()
        let forged: ScreenEvidenceDerivationClaim = try tamper(held) { $0["inputSHA256"] = String(repeating: "0", count: 64) }
        assertAdmissionError(.invalidClaim) { _ = try stage(forged) }
        let receipt = try stage(held)
        let badReceipt: ScreenEvidenceArtifactReceipt = try tamper(receipt) { $0["artifactBytes"] = receipt.artifactBytes + 1 }
        assertAdmissionError(.invalidClaim) { _ = try read(badReceipt) }
    }

    func testImportedReferenceAndMissingTextCannotBecomeNativeWork() throws {
        _ = try start()
        let importedStore = UUID(), observation = UUID()
        try PipelineSQL.execute(db, "INSERT INTO evidence_store(storeID,source,identity) VALUES(?,'rewind','authored-import')",
                                [.text(importedStore.uuidString)])
        let frame = FrameReference(id: reference.frameID, timestamp: now, segmentID: .init(value: 1),
                                   frameIndexInSegment: 0, metadata: .empty, source: .rewind)
        try ScreenEvidenceSQL.insertObservation(db, frame: frame, storeID: importedStore, observationID: observation,
                                               width: 100, height: 100, legacy: true)
        let imported = try ScreenEvidenceSQL.append(db, frame: frame, storeID: importedStore, observationID: observation,
                                                   revision: 0, width: 100, height: 100, text: nil, legacy: true)
        assertAdmissionError(.invalidReference) { _ = try claim(request(reference: imported.ref)) }
        let empty = try capture(nil)
        try drain()
        assertAdmissionError(.invalidRequest) { _ = try claim(request(reference: empty)) }
    }

    func testClaimProjectsRealVisionTextAndAllowsInitialDimensionEstablishment() async throws {
        let fixture = directory.appendingPathComponent("authored-images")
        try RenderedRecallFixture.write(to: fixture)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(fixture.appendingPathComponent("1700000000.jpeg") as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let frame = try XCTUnwrap(FrameQueries.getByID(db: db, id: reference.frameID))
        let pixels = Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * image.height)
        let text = try await ProcessingManager().extractText(from: CapturedFrame(timestamp: now, imageData: pixels,
            width: image.width, height: image.height, bytesPerRow: context.bytesPerRow, metadata: frame.metadata))
        XCTAssertTrue(text.fullText.contains("42000"))
        let before = try metadataEpoch()
        _ = try PipelineSQL.transaction(db) {
            try ScreenEvidenceSQL.commitOCR(db, frame: frame, text: text, width: image.width, height: image.height)
        }
        XCTAssertEqual(try metadataEpoch(), before, "Normal OCR dimensions must not invalidate unrelated admission")
        let snapshot = try XCTUnwrap(ScreenEvidenceSQL.current(db, frameID: frame.id, storeID: storeID))
        try drain()
        _ = try start()
        let requested = request(reference: snapshot.ref, bytes: 128)
        let expectedPage = try snapshot.expansionPage(for: requested.expansion)
        let held = try claim(requested)
        XCTAssertEqual(held.inputUTF8Bytes, expectedPage.textUTF8Bytes)
        XCTAssertEqual(held.fragmentCount, expectedPage.fragments.count)
        XCTAssertEqual(held.nextCursor, expectedPage.nextCursor)
        XCTAssertGreaterThan(held.inputUTF8Bytes, 0)
        _ = try stage(held, data: Data("Authored transport receipt; not model quality".utf8))
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM screen_evidence_work WHERE state='blocked'"), 2)
    }

    func testUnicodeChunkClaimsProgressAndPartialResultsNeverImplyReadiness() throws {
        _ = try start()
        let snapshot = try XCTUnwrap(ScreenEvidenceSQL.current(db, frameID: reference.frameID, storeID: storeID))
        var cursor: ScreenEvidenceExpansionCursor?
        var reconstructed = ""
        var hashes: Set<String> = []
        for _ in 0..<100 {
            let requested = request(bytes: 7, continuation: cursor)
            let page = try snapshot.expansionPage(for: requested.expansion)
            let held = try claim(requested)
            XCTAssertLessThanOrEqual(held.inputUTF8Bytes, 7)
            XCTAssertGreaterThan(held.inputUTF8Bytes, 0)
            XCTAssertTrue(hashes.insert(held.inputSHA256).inserted, "Byte ranges must distinguish fragments of the same original block")
            reconstructed += page.fragments.map(\.text).joined()
            _ = try stage(held)
            cursor = held.nextCursor
            if cursor == nil { break }
        }
        XCTAssertNil(cursor)
        XCTAssertTrue(reconstructed.utf8.elementsEqual(authoredText.utf8))
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM screen_evidence_work WHERE state<>'blocked'"), 0)
    }

    func testWallDeadlineAndMonotonicDeadlineIndependentlyRejectLateResults() throws {
        _ = try start()
        var held = try claim(request(duration: 10))
        assertAdmissionError(.claimExpired) { _ = try stage(held, date: now.addingTimeInterval(11), clock: uptime + 1) }
        held = try claim(request(channel: .vector, duration: 10))
        assertAdmissionError(.claimExpired) { _ = try stage(held, date: now.addingTimeInterval(1), clock: uptime + 11) }
        XCTAssertEqual(try scalar(db, "SELECT COALESCE(SUM(artifactBytes),0) FROM screen_evidence_derivation"), 0)
    }

    func testCompletedIdenticalRetryOutlivesExecutionButNotReceiptRetentionOrFences() throws {
        _ = try start()
        let held = try claim(request(duration: 1))
        let receipt = try stage(held)
        let replay = try stage(held, date: now.addingTimeInterval(120), clock: uptime + 120)
        XCTAssertEqual(replay, receipt)
        XCTAssertEqual(try read(receipt, date: now.addingTimeInterval(120)).data, Data("authored artifact".utf8))
        assertAdmissionError(.conflictingResult) { _ = try stage(held, data: Data("different".utf8), date: now.addingTimeInterval(120), clock: uptime + 120) }
        assertAdmissionError(.artifactUnavailable) { _ = try read(receipt, date: now.addingTimeInterval(24 * 60 * 60 + 1)) }
        try PipelineSQL.execute(db, "UPDATE segment SET windowName='Changed' WHERE id=1")
        assertAdmissionError(.sourceChanged) { _ = try stage(held) }
    }

    func testCancellationAndOneLiveAttemptPerChannelAreDurable() throws {
        _ = try start()
        let held = try claim()
        assertAdmissionError(.attemptInProgress) { _ = try claim() }
        let vector = try claim(request(channel: .vector))
        try ScreenEvidenceAdmissionSQL.cancel(db, capability: &capability, claim: held)
        assertAdmissionError(.claimCancelled) { _ = try stage(held) }
        _ = try claim()
        let receipt = try stage(vector)
        try ScreenEvidenceAdmissionSQL.cancel(db, capability: &capability, claim: vector)
        assertAdmissionError(.claimCancelled) { _ = try read(receipt) }
    }

    func testInvalidPolicyRequestAndArtifactBoundsNeverPartiallyPersist() throws {
        let hugePolicy = ScreenEvidenceAccessPolicy(config: CaptureConfig(redactWindowTitlePatterns: [String(repeating: "x", count: 65_537)]))
        assertAdmissionError(.invalidRequest) { _ = try begin(hugePolicy) }
        _ = try start()
        for duration in [0, -1, 30.001, Double.infinity, Double.nan] {
            assertAdmissionError(.invalidRequest) { _ = try claim(request(duration: duration)) }
        }
        assertAdmissionError(.invalidRequest) { _ = try claim(request(bytes: 3)) }
        let invalidTransform = ScreenEvidenceTransformation(identifier: "", fingerprintSHA256: "not-sha256", artifactFormat: "")
        let invalid = ScreenEvidenceDerivationRequest(cursor: consumer.cursor,
            expansion: .init(reference: reference), channel: .lexical, transformation: invalidTransform)
        assertAdmissionError(.invalidRequest) { _ = try claim(invalid) }
        let held = try claim()
        assertAdmissionError(.invalidRequest) { _ = try stage(held, data: Data(repeating: 7, count: 262_145)) }
        XCTAssertEqual(try scalar(db, "SELECT COALESCE(SUM(artifactBytes),0) FROM screen_evidence_derivation"), 0)
        _ = try stage(held)
    }

    func testAttemptCapacityAndBoundedExplicitCleanupPreserveActiveWork() throws {
        _ = try start()
        for _ in 0..<255 {
            let held = try claim()
            try ScreenEvidenceAdmissionSQL.cancel(db, capability: &capability, claim: held)
        }
        let live = try claim()
        assertAdmissionError(.capacityExceeded) { _ = try claim(request(channel: .vector)) }
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM screen_evidence_derivation"), 256)
        assertAdmissionError(.invalidRequest) {
            _ = try ScreenEvidenceAdmissionSQL.compact(db, capability: &capability, limit: 101, now: now, uptime: uptime)
        }
        let cleanup = try ScreenEvidenceAdmissionSQL.compact(db, capability: &capability, limit: 100, now: now, uptime: uptime)
        XCTAssertEqual(cleanup.removedClaims, 100)
        XCTAssertEqual(cleanup.removedArtifacts, 0)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM screen_evidence_derivation"), 156)
        _ = try stage(live)
    }

    func testAggregateArtifactLimitIsIndependentOfClaimCount() throws {
        _ = try start()
        let payload = Data(repeating: 0x5a, count: 256 * 1024)
        for _ in 0..<64 { _ = try stage(try claim(), data: payload) }
        let held = try claim()
        assertAdmissionError(.capacityExceeded) { _ = try stage(held, data: Data([1])) }
        XCTAssertEqual(try scalar(db, "SELECT SUM(artifactBytes) FROM screen_evidence_derivation"), 16 * 1024 * 1024)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM screen_evidence_derivation"), 65)
    }

    func testRejectedCommitCannotLeaveReceiptOrArtifactAndRetryRemainsPossible() throws {
        _ = try start()
        let held = try claim()
        sqlite3_commit_hook(db, { _ in 1 }, nil)
        XCTAssertThrowsError(try stage(held))
        sqlite3_commit_hook(db, nil, nil)
        XCTAssertEqual(try scalar(db, "SELECT COALESCE(SUM(artifactBytes),0) FROM screen_evidence_derivation"), 0)
        let receipt = try stage(held)
        let reader = try openReader(path)
        defer { sqlite3_close_v2(reader) }
        var enabled: Int32 = 0
        XCTAssertEqual(retrace_test_enable_defensive(reader, &enabled), SQLITE_OK)
        XCTAssertEqual(enabled, 1)
        XCTAssertEqual(try scalar(reader, "SELECT COUNT(*) FROM screen_evidence_derivation WHERE artifactBytes>0"), 1)
        XCTAssertEqual(try read(receipt).receipt, receipt)
        var reopenedCapability = ScreenEvidenceAdmissionCapability()
        let reopened = try openWriter(path)
        defer { sqlite3_close_v2(reopened) }
        assertAdmissionError(.inactive) {
            _ = try ScreenEvidenceAdmissionSQL.read(reopened, capability: &reopenedCapability, receipt: receipt, now: now)
        }
    }

    func testV22WriterMetadataChangesStillFenceAdmissionAfterReopen() throws {
        _ = try start()
        let held = try claim()
        let writer = try openWriter(path)
        defer { sqlite3_close_v2(writer) }
        try AppSegmentQueries.updateBrowserURL(db: writer, id: 1, browserURL: "https://changed.authored.test", onlyIfNull: false)
        try AppSegmentQueries.updateBrowserURL(db: writer, id: 1, browserURL: "https://authored.test", onlyIfNull: false)
        assertAdmissionError(.sourceChanged) { _ = try stage(held) }
    }

    func testSameDatabaseActorCloseAndReinitializeRequiresFreshCapability() async throws {
        let manager = DatabaseManager()
        try await manager.initialize()
        do {
            let initial = try await actorRequest(manager)
            let active = try await manager.beginScreenEvidenceWriterSession(policy: policy)
            try await manager.activateScreenEvidencePolicy(active)
            _ = try await manager.claimScreenEvidenceDerivation(initial)
            try await manager.close()
            // A failed shutdown's delayed cleanup may revisit the closed actor.
            // Empty local authority makes both operations idempotent without SQL.
            try await manager.revokeScreenEvidencePolicy(active)
            try await manager.endScreenEvidenceWriterSession(active.session)
            try await manager.initialize()
            let fresh = try await actorRequest(manager)
            do {
                _ = try await manager.claimScreenEvidenceDerivation(fresh)
                XCTFail("Reopening the same actor must not retain local admission")
            } catch { XCTAssertEqual(error as? ScreenEvidenceAdmissionError, .inactive) }
            let replacement = try await manager.beginScreenEvidenceWriterSession(policy: policy)
            try await manager.activateScreenEvidencePolicy(replacement)
            try await manager.revokeScreenEvidencePolicy(active)
            try await manager.endScreenEvidenceWriterSession(active.session)
            _ = try await manager.claimScreenEvidenceDerivation(fresh)
            XCTAssertNotEqual(replacement.session.writerID, active.session.writerID)
            try await manager.close()
        } catch {
            try await manager.close()
            throw error
        }
    }

    func testClaimStageAndReadReleaseStatementsAndPermitIndependentWALCheckpoint() throws {
        _ = try start()
        let second = try openWriter(path)
        defer { sqlite3_close_v2(second) }
        let held = try claim()
        try assertConnectionReleased(second)
        let receipt = try stage(held)
        try assertConnectionReleased(second)
        XCTAssertEqual(try read(receipt).data, Data("authored artifact".utf8))
        try assertConnectionReleased(second)
    }

    func testWriterLockWaitCannotAdmitAnExpiredResultUsingEntryClocks() async throws {
        _ = try start()
        let held = try claim(request(duration: 0.5))
        let second = try openWriter(path)
        defer { sqlite3_close_v2(second) }
        try PipelineSQL.execute(second, "BEGIN IMMEDIATE")
        let busy = AdmissionHeldWriterSignal(expectation: expectation(description: "Real competing SQLite writer reached"))
        let clock = AdmissionMutableClock(date: now, uptime: uptime)
        sqlite3_busy_handler(db, { context, _ in
            guard let context else { return 0 }
            return Unmanaged<AdmissionHeldWriterSignal>.fromOpaque(context).takeUnretainedValue().waitForRelease()
        }, Unmanaged.passUnretained(busy).toOpaque())
        let operation = AdmissionStageOperation(connection: db, capability: capability)
        let staged = Task.detached {
            operation.stage(held, clock: clock.provider)
        }
        // The busy callback is reached only after SQLite observes the actual
        // other writer's lock. Advance clocks there, without timing sleeps.
        await fulfillment(of: [busy.expectation], timeout: 5)
        clock.advance(by: 1)
        // Always release and join before touching/finalizing the first handle.
        var releaseError: Error?
        do { try PipelineSQL.execute(second, "ROLLBACK") } catch { releaseError = error }
        busy.release()
        let result = await staged.value
        sqlite3_busy_handler(db, nil, nil)
        sqlite3_busy_timeout(db, 1000)
        if let releaseError { throw releaseError }
        switch result {
        case .success: XCTFail("Staging must resample both clocks after waiting for the real writer lock")
        case .failure(let error): XCTAssertEqual(error as? ScreenEvidenceAdmissionError, .claimExpired)
        }
        XCTAssertEqual(try scalar(db, "SELECT COALESCE(SUM(artifactBytes),0) FROM screen_evidence_derivation"), 0)
        try ScreenEvidenceAdmissionSQL.cancel(db, capability: &capability, claim: held)

        // A second boundary uses SQLite's actual completed canonical-input read,
        // rather than a counter of fake model calls, to advance the clock.
        let afterReadClaim = try claim()
        let afterReadClock = AdmissionMutableClock(date: now, uptime: uptime)
        let stageRead = AdmissionInputReadClockAdvance(clock: afterReadClock, interval: 11)
        installInputReadClockAdvance(stageRead)
        do {
            _ = try ScreenEvidenceAdmissionSQL.stage(db, capability: &capability, claim: afterReadClaim,
                data: Data("authored post-read expiry".utf8), clock: afterReadClock.provider)
            XCTFail("Staging must recheck execution expiry after actual canonical reads")
        } catch { XCTAssertEqual(error as? ScreenEvidenceAdmissionError, .claimExpired) }
        sqlite3_trace_v2(db, 0, nil, nil)
        XCTAssertTrue(stageRead.observed)
        XCTAssertEqual(try scalar(db, "SELECT COALESCE(SUM(artifactBytes),0) FROM screen_evidence_derivation"), 0)
        try ScreenEvidenceAdmissionSQL.cancel(db, capability: &capability, claim: afterReadClaim)

        let completed = try stage(try claim(request(channel: .vector)))
        let readClock = AdmissionMutableClock(date: now.addingTimeInterval(1), uptime: uptime + 1)
        let artifactRead = AdmissionInputReadClockAdvance(clock: readClock, interval: 24 * 60 * 60)
        installInputReadClockAdvance(artifactRead)
        do {
            _ = try ScreenEvidenceAdmissionSQL.read(db, capability: &capability, receipt: completed, clock: readClock.provider)
            XCTFail("A read must not return bytes whose retention expires during canonical validation")
        } catch { XCTAssertEqual(error as? ScreenEvidenceAdmissionError, .artifactUnavailable) }
        sqlite3_trace_v2(db, 0, nil, nil)
        XCTAssertTrue(artifactRead.observed)
    }

    func testCloseCheckpointRetryCannotMintReplacementAdmission() async throws {
        let manager = DatabaseManager()
        let connection: OpaquePointer
        do {
            try await manager.initialize()
            let initial = try await actorRequest(manager)
            let active = try await manager.beginScreenEvidenceWriterSession(policy: policy)
            try await manager.activateScreenEvidencePolicy(active)
            _ = try await manager.claimScreenEvidenceDerivation(initial)
            let pointer = await manager.getConnection()
            connection = try XCTUnwrap(pointer)
        } catch {
            try? await manager.close()
            throw error
        }
        await manager.setCloseCheckpointForTesting(true)
        let denial = AdmissionCheckpointDenial(expectation: expectation(description: "Real checkpoint PRAGMA denied"))
        sqlite3_set_authorizer(connection, { context, action, first, _, _, _ in
            guard action == SQLITE_PRAGMA, let first, String(cString: first).lowercased() == "wal_checkpoint",
                  let context else { return SQLITE_OK }
            return Unmanaged<AdmissionCheckpointDenial>.fromOpaque(context).takeUnretainedValue().deny()
        }, Unmanaged.passUnretained(denial).toOpaque())
        let closing = Task { () -> Result<Void, Error> in
            do { try await manager.close(); return .success(()) }
            catch { return .failure(error) }
        }
        var authorizerInstalled = true
        do {
            await fulfillment(of: [denial.expectation], timeout: 5)
            // The production checkpoint method is now in its ordinary async
            // retry delay. This proves close reentrancy, not disk I/O timing.
            do {
                let replacement = try await manager.beginScreenEvidenceWriterSession(policy: policy)
                try await manager.activateScreenEvidencePolicy(replacement)
                XCTFail("Close must deny replacement authority throughout checkpoint retry")
            } catch { XCTAssertEqual(error as? ScreenEvidenceAdmissionError, .inactive) }
            await manager.setCloseCheckpointForTesting(false)
            sqlite3_set_authorizer(connection, nil, nil)
            authorizerInstalled = false
            try await closing.value.get()
            try await manager.initialize()
            let fresh = try await actorRequest(manager)
            do {
                _ = try await manager.claimScreenEvidenceDerivation(fresh)
                XCTFail("No authority minted during closing may survive reopening")
            } catch { XCTAssertEqual(error as? ScreenEvidenceAdmissionError, .inactive) }
            try await manager.close()
        } catch {
            if authorizerInstalled { sqlite3_set_authorizer(connection, nil, nil) }
            await manager.setCloseCheckpointForTesting(false)
            _ = await closing.value
            try? await manager.close()
            throw error
        }
    }

    func testPolicyAndMetadataRevocationHaveConstantWorkWithUnrelatedHistory() throws {
        for index in 0..<350 { _ = try capture("Authored unrelated row \(index)") }
        try drain()
        let active = try start()
        _ = try claim()
        let trace = AdmissionSQLTrace()
        installTrace(db, trace)
        defer { sqlite3_trace_v2(db, 0, nil, nil) }
        try ScreenEvidenceAdmissionSQL.revoke(db, capability: &capability, transition: active)
        try PipelineSQL.execute(db, "UPDATE segment SET windowName='Changed title' WHERE id=1")
        sqlite3_trace_v2(db, 0, nil, nil)
        XCTAssertLessThan(trace.steps, 1500, "Policy and metadata invalidation must not enumerate 702 work rows")
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM screen_evidence_work"), 702)
    }

    private func request(reference selected: ScreenEvidenceRef? = nil, cursor: ScreenEvidenceConsumerCursor? = nil,
                         channel: ScreenEvidenceDerivationChannel = .lexical, bytes: Int = 65_536,
                         continuation: ScreenEvidenceExpansionCursor? = nil, duration: TimeInterval = 10) -> ScreenEvidenceDerivationRequest {
        .init(cursor: cursor ?? consumer.cursor,
              expansion: .init(reference: selected ?? reference, maximumUTF8Bytes: bytes, cursor: continuation),
              channel: channel, transformation: transform, executionDuration: duration)
    }

    private func begin(_ requestedPolicy: ScreenEvidenceAccessPolicy? = nil) throws -> ScreenEvidencePolicyTransition {
        try ScreenEvidenceAdmissionSQL.begin(db, capability: &capability, policy: requestedPolicy ?? policy)
    }

    private func activate(_ transition: ScreenEvidencePolicyTransition) throws {
        try ScreenEvidenceAdmissionSQL.activate(db, capability: &capability, transition: transition)
    }

    @discardableResult private func start(_ requestedPolicy: ScreenEvidenceAccessPolicy? = nil) throws -> ScreenEvidencePolicyTransition {
        let prepared = try begin(requestedPolicy)
        try activate(prepared)
        return prepared
    }

    private func claim(_ requested: ScreenEvidenceDerivationRequest? = nil) throws -> ScreenEvidenceDerivationClaim {
        try ScreenEvidenceAdmissionSQL.claim(db, capability: &capability, request: requested ?? request(), now: now, uptime: uptime)
    }

    private func stage(_ claim: ScreenEvidenceDerivationClaim, data: Data = Data("authored artifact".utf8),
                       date: Date? = nil, clock: TimeInterval? = nil) throws -> ScreenEvidenceArtifactReceipt {
        try ScreenEvidenceAdmissionSQL.stage(db, capability: &capability, claim: claim, data: data,
                                             now: date ?? now, uptime: clock ?? uptime)
    }

    private func read(_ receipt: ScreenEvidenceArtifactReceipt, date: Date? = nil) throws -> ScreenEvidenceStagedArtifact {
        try ScreenEvidenceAdmissionSQL.read(db, capability: &capability, receipt: receipt, now: date ?? now)
    }

    private func capture(_ text: String?) throws -> ScreenEvidenceRef {
        try PipelineSQL.transaction(db) {
            let descriptor = FrameReference(id: .init(value: 0), timestamp: now, segmentID: .init(value: 1),
                frameIndexInSegment: 0, metadata: FrameMetadata(appBundleID: "com.test.admission", windowName: "Authored retained context"))
            let id = try FrameQueries.insert(db: db, frame: descriptor)
            try ScreenEvidenceSQL.capture(db, frameID: id, descriptor: descriptor)
            if let text { _ = try ScreenEvidenceSQL.commitLegacyText(db, frameID: .init(value: id), mainText: text, chromeText: nil) }
            return try XCTUnwrap(ScreenEvidenceSQL.current(db, frameID: .init(value: id), storeID: storeID)).ref
        }
    }

    private func revise(_ text: String) throws -> ScreenEvidenceRef {
        try PipelineSQL.transaction(db) {
            _ = try ScreenEvidenceSQL.commitLegacyText(db, frameID: reference.frameID, mainText: text, chromeText: nil)
            return try XCTUnwrap(ScreenEvidenceSQL.current(db, frameID: reference.frameID, storeID: storeID)).ref
        }
    }

    private func drain(at date: Date? = nil) throws {
        for _ in 0..<10 {
            let page = try ScreenEvidenceConsumerSQL.advance(db, cursor: consumer.cursor, limit: 200, now: date ?? now)
            if page.status.phase == .replay && page.inspectedCount == 0 { return }
        }
        XCTFail("Bounded authored consumer fixture did not finish")
    }

    private func metadataEpoch() throws -> Int64 {
        try scalar(db, "SELECT metadataEpoch FROM screen_evidence_admission_state WHERE id=1")
    }

    private func actorRequest(_ manager: DatabaseManager) async throws -> ScreenEvidenceDerivationRequest {
        let capturedAt = Date()
        let segment = try await manager.insertSegment(bundleID: "com.test.admission", startDate: capturedAt,
            endDate: capturedAt, windowName: "Authored actor reopen", browserUrl: nil, type: 0)
        let descriptor = FrameReference(id: .init(value: 0), timestamp: capturedAt,
            segmentID: .init(value: segment), frameIndexInSegment: 0,
            metadata: FrameMetadata(appBundleID: "com.test.admission", windowName: "Authored actor reopen"))
        let frameID = FrameID(value: try await manager.insertFrame(descriptor))
        _ = try await manager.commitFrameOCR(frameID: frameID,
            text: ExtractedText(frameID: frameID, timestamp: capturedAt,
                regions: [TextRegion(frameID: frameID, text: authoredText, bounds: CGRect(x: 1, y: 1, width: 30, height: 10))],
                fullText: authoredText, metadata: descriptor.metadata), frameWidth: 32, frameHeight: 32)
        let currentStore = try await manager.activityStoreID()
        let current = try await manager.currentScreenEvidence(frameID: frameID, storeID: currentStore)
        let saved = try XCTUnwrap(current)
        let registered = try await manager.beginScreenEvidenceBootstrap(consumerID: UUID(), leaseDuration: 120)
        _ = try await manager.advanceScreenEvidenceConsumer(cursor: registered.cursor, limit: 10)
        _ = try await manager.advanceScreenEvidenceConsumer(cursor: registered.cursor, limit: 10)
        return ScreenEvidenceDerivationRequest(cursor: registered.cursor, expansion: .init(reference: saved.ref),
                                                channel: .lexical, transformation: transform)
    }

    private func assertConnectionReleased(_ second: OpaquePointer, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(sqlite3_get_autocommit(db), 1, file: file, line: line)
        XCTAssertEqual(sqlite3_txn_state(db, nil), SQLITE_TXN_NONE, file: file, line: line)
        var statement = sqlite3_next_stmt(db, nil)
        while let current = statement {
            XCTAssertEqual(sqlite3_stmt_busy(current), 0, file: file, line: line)
            statement = sqlite3_next_stmt(db, current)
        }
        try PipelineSQL.transaction(second) {
            try PipelineSQL.execute(second, "UPDATE segment SET endDate=endDate+1 WHERE id=1")
        }
        let checkpoint = try PipelineSQL.query(second, "PRAGMA wal_checkpoint(TRUNCATE)") {
            (sqlite3_column_int($0, 0), sqlite3_column_int($0, 1), sqlite3_column_int($0, 2))
        }
        XCTAssertEqual(checkpoint.count, 1, file: file, line: line)
        XCTAssertEqual(checkpoint.first?.0, 0, "No upstream reader/writer may retain WAL after returning", file: file, line: line)
        XCTAssertEqual(checkpoint.first?.1, 0, file: file, line: line)
        XCTAssertEqual(checkpoint.first?.2, 0, file: file, line: line)
    }

    private func assertAdmissionError(_ expected: ScreenEvidenceAdmissionError, file: StaticString = #filePath,
                                      line: UInt = #line, _ operation: () throws -> Void) {
        do { try operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? ScreenEvidenceAdmissionError, expected, "Unexpected \(error)", file: file, line: line) }
    }

    private func assertSQLRejected(_ sql: String, _ values: [PipelineSQL.Value], file: StaticString = #filePath, line: UInt = #line) {
        do {
            try PipelineSQL.execute(db, "BEGIN IMMEDIATE")
            defer { try? PipelineSQL.execute(db, "ROLLBACK") }
            XCTAssertThrowsError(try PipelineSQL.execute(db, sql, values), file: file, line: line)
        } catch { XCTFail("Fixture transaction failed: \(error)", file: file, line: line) }
    }

    private func scalar(_ connection: OpaquePointer, _ sql: String) throws -> Int64 {
        try XCTUnwrap(PipelineSQL.integers(connection, sql).first)
    }

    private func tamper<T: Codable>(_ input: T, _ change: (inout [String: Any]) -> Void) throws -> T {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        change(&object)
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func openWriter(_ path: String) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw DatabaseError.connectionFailed(underlying: "Private admission fixture open failed")
        }
        do {
            try PipelineSQL.execute(pointer, "PRAGMA foreign_keys=ON")
            _ = try PipelineSQL.query(pointer, "PRAGMA journal_mode=WAL") { _ in () }
            sqlite3_busy_timeout(pointer, 1000)
            return pointer
        } catch { sqlite3_close_v2(pointer); throw error }
    }

    private func openReader(_ path: String) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw DatabaseError.connectionFailed(underlying: "Private reader open failed")
        }
        sqlite3_busy_timeout(pointer, 1000)
        return pointer
    }

    private func installTrace(_ connection: OpaquePointer, _ trace: AdmissionSQLTrace) {
        sqlite3_trace_v2(connection, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
            guard let context, let statement else { return 0 }
            let value = Unmanaged<AdmissionSQLTrace>.fromOpaque(context).takeUnretainedValue()
            value.steps += Int(sqlite3_stmt_status(OpaquePointer(statement), SQLITE_STMTSTATUS_VM_STEP, 0))
            return 0
        }, Unmanaged.passUnretained(trace).toOpaque())
    }

    private func installInputReadClockAdvance(_ trace: AdmissionInputReadClockAdvance) {
        sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
            guard let context, let statement else { return 0 }
            Unmanaged<AdmissionInputReadClockAdvance>.fromOpaque(context).takeUnretainedValue()
                .observe(OpaquePointer(statement))
            return 0
        }, Unmanaged.passUnretained(trace).toOpaque())
    }

    private func migrateThroughV22(_ connection: OpaquePointer) async throws {
        try PipelineSQL.execute(connection, Schema.createSchemaMigrationsTable)
        let migrations: [any Migration] = [V1_InitialSchema(), V2_UnfinalisedVideoTracking(), V3_TagSystem(),
            V4_DailyMetrics(), V5_FTSUnicode61(), V6_FrameProcessedAt(), V7_FrameRedactionReason(),
            V8_SegmentComments(), V9_SegmentCommentFrameAnchor(), V10_SegmentCommentSearchIndex(),
            V11_SegmentCommentLinkCompositeIndex(), V12_AudioCaptures(), V13_TranscriptionPass(),
            V14_ContextualRefinement(), V15_PipelineVersion(), V16_DictationSessions(), V17_AudioTranscriptMetadata(),
            V18_NodeText(), V19_ProcessingQueueFrameIndex(), V20_OCRBackfillState(), V21_ProgressiveRecall(), V22_ScreenEvidenceFeed()]
        for migration in migrations {
            try PipelineSQL.execute(connection, "BEGIN")
            do {
                try await migration.migrate(db: connection)
                try PipelineSQL.execute(connection, "INSERT INTO schema_migrations(version,applied_at) VALUES(?,?)",
                    [.integer(Int64(migration.version)), .real(now.timeIntervalSince1970)])
                try PipelineSQL.execute(connection, "COMMIT")
            } catch { try? PipelineSQL.execute(connection, "ROLLBACK"); throw error }
        }
        try RecallSearchRevisionHooks.install(db: connection)
    }
}

private final class AdmissionSQLTrace {
    var steps = 0
}

private final class AdmissionMutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ScreenEvidenceAdmissionClock.Instant
    init(date: Date, uptime: TimeInterval) { value = .init(date: date, uptime: uptime) }
    var provider: ScreenEvidenceAdmissionClock {
        .init { [self] in
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value = .init(date: value.date.addingTimeInterval(interval), uptime: value.uptime + interval)
    }
}

/// Owns the only use of this test handle/capability while the detached SQL call
/// runs. The test always joins before restoring callbacks or touching the handle.
private final class AdmissionStageOperation: @unchecked Sendable {
    let connection: OpaquePointer
    var capability: ScreenEvidenceAdmissionCapability
    init(connection: OpaquePointer, capability: ScreenEvidenceAdmissionCapability) {
        self.connection = connection; self.capability = capability
    }
    func stage(_ claim: ScreenEvidenceDerivationClaim, clock: ScreenEvidenceAdmissionClock)
        -> Result<ScreenEvidenceArtifactReceipt, Error> {
        Result { try ScreenEvidenceAdmissionSQL.stage(connection, capability: &capability, claim: claim,
            data: Data("authored artifact after real writer wait".utf8), clock: clock) }
    }
}

/// SQLite invokes this only on the owned background test operation. The bounded
/// condition keeps that native busy callback parked until the test rolls back
/// the competing writer; no UI path or production busy handler uses this gate.
private final class AdmissionHeldWriterSignal: @unchecked Sendable {
    let expectation: XCTestExpectation
    private let condition = NSCondition()
    private var observed = false
    private var released = false
    init(expectation: XCTestExpectation) { self.expectation = expectation }
    func waitForRelease() -> Int32 {
        condition.lock(); defer { condition.unlock() }
        if !observed { observed = true; expectation.fulfill() }
        let deadline = Date().addingTimeInterval(10)
        while !released {
            if !condition.wait(until: deadline) { return 0 }
        }
        return 1
    }
    func release() {
        condition.lock(); defer { condition.unlock() }
        released = true; condition.broadcast()
    }
}

private final class AdmissionCheckpointDenial: @unchecked Sendable {
    let expectation: XCTestExpectation
    private let lock = NSLock()
    private var observed = false
    init(expectation: XCTestExpectation) { self.expectation = expectation }
    func deny() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        if !observed { observed = true; expectation.fulfill() }
        return SQLITE_DENY
    }
}

private final class AdmissionInputReadClockAdvance {
    let clock: AdmissionMutableClock
    let interval: TimeInterval
    private(set) var observed = false
    init(clock: AdmissionMutableClock, interval: TimeInterval) { self.clock = clock; self.interval = interval }
    func observe(_ statement: OpaquePointer) {
        guard !observed, let raw = sqlite3_sql(statement),
              String(cString: raw).contains("CASE WHEN length(CAST(o.framePayload AS BLOB))") else { return }
        observed = true
        clock.advance(by: interval)
    }
}
