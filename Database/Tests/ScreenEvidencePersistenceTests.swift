import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database

final class ScreenEvidencePersistenceTests: XCTestCase {
    private var database: DatabaseManager!
    private var store: (any EvidenceStoreProtocol) { database }
    private let time = Date(timeIntervalSince1970: 1_800_000_000)
    private var segmentID: Int64 = 0

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:evidence_\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        segmentID = try await database.insertSegment(bundleID: "com.microsoft.Word", startDate: time, endDate: time,
                                                     windowName: "Mutable segment title", browserUrl: nil, type: 0)
    }
    override func tearDown() async throws { try await database.close() }

    func testCaptureMetadataAndOldExtractionRemainImmutableAfterSegmentAndOCRUpdates() async throws {
        let frame = try await insertFrame()
        let storeID = try await database.activityStoreID()
        _ = try await database.commitFrameOCR(frameID: frame.id, text: text(frame.id, "Invoice 42 café"), frameWidth: 1920, frameHeight: 1080)
        let old = try requireValue(try await store.currentScreenEvidence(frameID: frame.id, storeID: storeID))
        try await sql("UPDATE segment SET windowName='Later unrelated title',browserUrl='https://later.test' WHERE id=\(segmentID)")
        _ = try await database.commitFrameOCR(frameID: frame.id, text: text(frame.id, "Invoice 43 café"), frameWidth: 1920, frameHeight: 1080)
        let retained = try requireValue(try await store.screenEvidence(old.ref))
        let latest = try requireValue(try await store.currentScreenEvidence(frameID: frame.id, storeID: storeID))
        expectEqual(retained.text?.fullText, "Invoice 42 café")
        expectEqual(retained.frame.metadata.windowName, "Original captured title")
        expectEqual(retained.frame.metadata.displayID, 2)
        expectEqual(latest.text?.fullText, "Invoice 43 café")
        expectEqual(retained.ref.observationID, latest.ref.observationID)
        expectGreaterThan(latest.ref.extractionRevision, retained.ref.extractionRevision)
        expectTrue(retained.highlightsVerified)
        let documentID = try requireValue(try await database.getDocidForFrame(frameId: frame.id.value))
        let indexed = try await database.getFTSContent(docid: documentID)
        expectEqual(indexed?.windowTitle, "Original captured title")
    }

    func testMismatchedFrameAndDimensionRevisionsAreRejectedWithoutChangingFTS() async throws {
        let frame = try await insertFrame()
        _ = try await database.commitFrameOCR(frameID: frame.id, text: text(frame.id, "Retained"), frameWidth: 1920, frameHeight: 1080)
        await assertThrows { _ = try await self.database.commitFrameOCR(frameID: frame.id, text: self.text(FrameID(value: frame.id.value + 1), "Wrong frame"), frameWidth: 1920, frameHeight: 1080) }
        await assertThrows { _ = try await self.database.commitFrameOCR(frameID: frame.id, text: self.text(frame.id, "Wrong dimensions"), frameWidth: 1280, frameHeight: 720) }
        let current = try await store.currentScreenEvidence(frameID: frame.id, storeID: database.activityStoreID())
        expectEqual(current?.text?.fullText, "Retained")
    }

    func testLegacyDocumentWritersAdvanceTextRevisionWithoutBorrowingOldGeometry() async throws {
        let frame = try await insertFrame()
        let storeID = try await database.activityStoreID()
        let docID = try await database.insertDocument(IndexedDocument(id: 0, frameID: frame.id, timestamp: time,
            content: "First amount 42000"))
        let first = try requireValue(try await store.currentScreenEvidence(frameID: frame.id, storeID: storeID))
        expectEqual(first.text?.fullText, "First amount 42000")
        try await database.updateDocument(id: docID, content: "Later amount 47000")
        let later = try requireValue(try await store.currentScreenEvidence(frameID: frame.id, storeID: storeID))
        expectEqual(later.text?.fullText, "Later amount 47000")
        expectGreaterThan(later.ref.extractionRevision, first.ref.extractionRevision)
        expectFalse(later.highlightsVerified)
        expectEqual(try await store.screenEvidence(first.ref)?.text?.fullText, "First amount 42000")
    }

    func testLegacyIndexerPublishesTextAndSnapshotInOneTransaction() async throws {
        let frame = try await insertFrame()
        let storeID = try await database.activityStoreID()
        _ = try await database.commitFrameOCR(frameID: frame.id, text: text(frame.id, "Original 42000"), frameWidth: 1920, frameHeight: 1080)
        let old = try requireValue(try await store.currentScreenEvidence(frameID: frame.id, storeID: storeID))
        _ = try await database.indexFrameText(mainText: "Replacement 47000", chromeText: "DRAFT", windowTitle: "Unrelated current window",
            segmentId: frame.segmentID.value, frameId: frame.id.value)
        let current = try requireValue(try await store.currentScreenEvidence(frameID: frame.id, storeID: storeID))
        expectEqual(current.text?.fullText, "Replacement 47000")
        expectEqual(current.text?.chromeText, "DRAFT")
        expectFalse(current.highlightsVerified)
        expectEqual(try await store.screenEvidence(old.ref)?.text?.fullText, "Original 42000")
        let docID = try requireValue(try await database.getDocidForFrame(frameId: frame.id.value))
        expectEqual(try await database.getFTSContent(docid: docID)?.windowTitle, "Original captured title")
        try await sql("CREATE TEMP TRIGGER reject_legacy_extraction BEFORE INSERT ON screen_extraction BEGIN SELECT RAISE(ABORT,'injected'); END")
        await assertThrows {
            _ = try await self.database.indexFrameText(mainText: "Must roll back", chromeText: nil, windowTitle: nil,
                segmentId: frame.segmentID.value, frameId: frame.id.value)
        }
        expectEqual(try await database.getFTSContent(docid: docID)?.mainText, "Replacement 47000")
        expectEqual(try await store.currentScreenEvidence(frameID: frame.id, storeID: storeID)?.ref, current.ref)
    }

    func testFailedSnapshotWriteRollsBackSearchNodesAndPreferredRevision() async throws {
        let frame = try await insertFrame()
        _ = try await database.commitFrameOCR(frameID: frame.id, text: text(frame.id, "Retained"), frameWidth: 1920, frameHeight: 1080)
        let old = try requireValue(try await store.currentScreenEvidence(frameID: frame.id, storeID: database.activityStoreID()))
        try await sql("CREATE TEMP TRIGGER reject_extraction BEFORE INSERT ON screen_extraction BEGIN SELECT RAISE(ABORT,'injected'); END")
        await assertThrows { _ = try await self.database.commitFrameOCR(frameID: frame.id, text: self.text(frame.id, "Lost"), frameWidth: 1920, frameHeight: 1080) }
        let current = try await store.currentScreenEvidence(frameID: frame.id, storeID: database.activityStoreID())
        let doc = try await database.getDocidForFrame(frameId: frame.id.value)
        let content = try await database.getFTSContent(docid: try requireValue(doc))
        expectEqual(current?.ref, old.ref)
        expectEqual(content?.mainText, "Retained")
    }

    func testLegacyImportsAreBoundedSourceQualifiedAndHaveNoHighlightProof() async throws {
        let frame = FrameReference(id: FrameID(value: 77), timestamp: time, segmentID: AppSegmentID(value: 9), frameIndexInSegment: 2,
                                   metadata: .empty, source: .rewind)
        let firstStore = try await store.evidenceStoreID(source: .rewind, identity: "readonly-import-a")
        let otherStore = try await store.evidenceStoreID(source: .rewind, identity: "readonly-import-b")
        let first = try await store.materializeScreenEvidence(frame: frame, storeID: firstStore, width: 1920, height: 1080, text: text(frame.id, "Legacy"))
        let repeated = try await store.materializeScreenEvidence(frame: frame, storeID: firstStore, width: 1920, height: 1080, text: text(frame.id, "Legacy"))
        let changed = try await store.materializeScreenEvidence(frame: frame, storeID: firstStore, width: 1920, height: 1080, text: text(frame.id, "Changed later"))
        let other = try await store.materializeScreenEvidence(frame: frame, storeID: otherStore, width: 1920, height: 1080, text: nil)
        expectEqual(first.ref, repeated.ref)
        expectEqual(changed.ref.observationID, first.ref.observationID)
        expectEqual(changed.ref.extractionRevision, first.ref.extractionRevision + 1)
        expectEqual(changed.text?.fullText, "Changed later")
        expectEqual(try await store.screenEvidence(first.ref)?.text?.fullText, "Legacy")
        expectNotEqual(first.ref.storeID, other.ref.storeID)
        expectTrue(first.legacyContext)
        expectFalse(first.highlightsVerified)
        expectFalse(changed.highlightsVerified)
        expectEqual(try await scalar("SELECT COUNT(*) FROM frame"), 0)
        expectEqual(try await scalar("SELECT COUNT(*) FROM screen_observation"), 2)
    }

    func testResolutionRejectsWrongSourceObservationRevisionAndUnsupportedBlocks() async throws {
        let frame = try await insertFrame()
        _ = try await database.commitFrameOCR(frameID: frame.id, text: text(frame.id, "Exact"), frameWidth: 1920, frameHeight: 1080)
        let snap = try requireValue(try await store.currentScreenEvidence(frameID: frame.id, storeID: database.activityStoreID()))
        for ref in [ScreenEvidenceRef(storeID: snap.ref.storeID, source: .rewind, observationID: snap.ref.observationID, frameID: frame.id, extractionRevision: snap.ref.extractionRevision),
                    ScreenEvidenceRef(storeID: snap.ref.storeID, source: .native, observationID: UUID(), frameID: frame.id, extractionRevision: snap.ref.extractionRevision),
                    ScreenEvidenceRef(storeID: snap.ref.storeID, source: .native, observationID: snap.ref.observationID, frameID: frame.id, extractionRevision: 999),
                    ScreenEvidenceRef(storeID: snap.ref.storeID, source: .native, observationID: snap.ref.observationID, frameID: frame.id, extractionRevision: snap.ref.extractionRevision, blockIDs: [999])] {
            expectNil(try await store.screenEvidence(ref))
        }
        let block = ScreenEvidenceRef(storeID: snap.ref.storeID, source: .native, observationID: snap.ref.observationID, frameID: frame.id,
                                       extractionRevision: snap.ref.extractionRevision, blockIDs: [0])
        expectNotNil(try await store.screenEvidence(block))
    }

    func testExplicitDeletionInvalidatesEverySnapshotAndCannotMaterializeDeletedFrame() async throws {
        let frame = try await insertFrame()
        _ = try await database.commitFrameOCR(frameID: frame.id, text: text(frame.id, "Delete me"), frameWidth: 1920, frameHeight: 1080)
        let snapshot = try requireValue(try await store.currentScreenEvidence(frameID: frame.id, storeID: database.activityStoreID()))
        try await database.deleteFrame(id: frame.id)
        expectNil(try await store.screenEvidence(snapshot.ref))
        expectEqual(try await scalar("SELECT COUNT(*) FROM screen_extraction"), 0)
        await assertThrows { _ = try await self.store.materializeScreenEvidence(frame: frame, storeID: snapshot.ref.storeID, width: 1920, height: 1080, text: nil) }
    }

    func testMediaUnavailablePreservesTextAndSnapshotAndHasDurableReason() async throws {
        let frame = try await insertFrame()
        _ = try await database.commitFrameOCR(frameID: frame.id, text: text(frame.id, "Retain readable text"), frameWidth: 1920, frameHeight: 1080)
        let snapshot = try requireValue(try await store.currentScreenEvidence(frameID: frame.id, storeID: database.activityStoreID()))
        try await database.recordFrameMediaUnavailable(frameID: frame.id, reason: .recordingMissing)
        expectEqual(try await database.frameMediaUnavailable(frameID: frame.id), .recordingMissing)
        expectNotNil(try await store.screenEvidence(snapshot.ref))
        expectNotNil(try await database.getFrame(id: frame.id))
        expectEqual(try await scalar("SELECT processingStatus FROM frame WHERE id=\(frame.id.value)"), 3)
        _ = try await database.commitFrameOCR(frameID: frame.id, text: text(frame.id, "Restored"), frameWidth: 1920, frameHeight: 1080)
        expectNil(try await database.frameMediaUnavailable(frameID: frame.id))
    }

    func testSnapshotFailureRollsBackNativeFrameInsertion() async throws {
        try await sql("CREATE TEMP TRIGGER reject_observation BEFORE INSERT ON screen_observation BEGIN SELECT RAISE(ABORT,'injected'); END")
        await assertThrows { _ = try await self.insertFrame() }
        expectEqual(try await scalar("SELECT COUNT(*) FROM frame"), 0)
    }

    func testMetadataOnlyCaptureGainsVerifiedDimensionsWithoutRewritingItsOldRevision() async throws {
        let frame = try await insertFrame()
        let id = try await database.activityStoreID()
        let initial = try requireValue(try await store.currentScreenEvidence(frameID: frame.id, storeID: id))
        expectEqual(initial.width, 0)
        let materialized = try await store.materializeScreenEvidence(frame: frame, storeID: id, width: 1920, height: 1080, text: nil)
        expectEqual(materialized.width, 1920)
        expectEqual(materialized.ref.observationID, initial.ref.observationID)
        expectGreaterThan(materialized.ref.extractionRevision, initial.ref.extractionRevision)
        expectEqual(try await store.screenEvidence(initial.ref)?.width, 0)
    }

    func testIncoherentFlatTextSuppressesHighlightPrecisionButRetainsText() async throws {
        let frame = try await insertFrame()
        let incoherent = ExtractedText(frameID: frame.id, timestamp: time, regions: text(frame.id, "Region").regions,
                                       fullText: "Region plus ungrounded extension")
        _ = try await database.commitFrameOCR(frameID: frame.id, text: incoherent, frameWidth: 1920, frameHeight: 1080)
        let snapshot = try requireValue(try await store.currentScreenEvidence(frameID: frame.id, storeID: database.activityStoreID()))
        expectFalse(snapshot.highlightsVerified)
        expectEqual(snapshot.text?.fullText, incoherent.fullText)
    }

    func testRetentionDeletionDoesNotEraseImportedSnapshotWithTheSameNumericFrameID() async throws {
        let native = try await insertFrame()
        let importedStore = try await store.evidenceStoreID(source: .rewind, identity: "read-only-import")
        let imported = FrameReference(id: native.id, timestamp: native.timestamp, segmentID: native.segmentID,
                                      frameIndexInSegment: 0, metadata: .empty, source: .rewind)
        let saved = try await store.materializeScreenEvidence(frame: imported, storeID: importedStore, width: 1920, height: 1080, text: nil)
        _ = try await database.performRetentionBatch(olderThan: time.addingTimeInterval(1))
        expectNil(try await store.currentScreenEvidence(frameID: native.id, storeID: database.activityStoreID()))
        expectNotNil(try await store.screenEvidence(saved.ref))
    }

    func testReceiptAfterDeletionDoesNotResurrectFrameOrOrphanReason() async throws {
        let frame = try await insertFrame()
        try await database.deleteFrame(id: frame.id)
        try await database.recordFrameMediaUnavailable(frameID: frame.id, reason: .integrityFailure)
        expectNil(try await database.frameMediaUnavailable(frameID: frame.id))
        expectEqual(try await scalar("SELECT COUNT(*) FROM frame_media_unavailable"), 0)
    }

    func testProcessingProtocolUnassignedIDsBindToTheRequestedExistingFrame() async throws {
        let frame = try await insertFrame()
        // CapturedFrame deliberately carries no DB ID; real ProcessingProtocol output
        // uses zero until the durable queue's requested frame identity is assigned here.
        let unassigned = ExtractedText(frameID: FrameID(value: 0), timestamp: time,
            regions: [TextRegion(frameID: FrameID(value: 0), text: "Real OCR pipeline contract",
                                 bounds: CGRect(x: 40, y: 80, width: 700, height: 48))])
        _ = try await database.commitFrameOCR(frameID: frame.id, text: unassigned, frameWidth: 1920, frameHeight: 1080)
        let snapshot = try requireValue(try await store.currentScreenEvidence(frameID: frame.id, storeID: database.activityStoreID()))
        expectEqual(snapshot.text?.frameID, frame.id)
        expectEqual(snapshot.text?.regions.map(\.frameID), [frame.id])
        expectTrue(snapshot.highlightsVerified)
        let nodes = try await database.getNodesWithText(frameID: frame.id, frameWidth: 1920, frameHeight: 1080)
        expectEqual(nodes.map(\.text), ["Real OCR pipeline contract"])
    }

    func testConflictingAssignedRegionIDCannotEnterAnExtraction() async throws {
        let frame = try await insertFrame()
        let contradictory = ExtractedText(frameID: frame.id, timestamp: time,
            regions: [TextRegion(frameID: FrameID(value: frame.id.value + 1), text: "Different frame",
                                 bounds: CGRect(x: 40, y: 80, width: 700, height: 48))])
        await assertThrows { _ = try await self.database.commitFrameOCR(frameID: frame.id, text: contradictory, frameWidth: 1920, frameHeight: 1080) }
        expectEqual(try await scalar("SELECT COUNT(*) FROM searchRanking"), 0)
    }

    private func insertFrame() async throws -> FrameReference {
        let metadata = FrameMetadata(appBundleID: "com.microsoft.Word", appName: "Word", windowName: "Original captured title", displayID: 2)
        let id = try await database.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: time, segmentID: AppSegmentID(value: segmentID),
                                                               frameIndexInSegment: 0, metadata: metadata))
        return FrameReference(id: FrameID(value: id), timestamp: time, segmentID: AppSegmentID(value: segmentID), frameIndexInSegment: 0, metadata: metadata)
    }
    private func text(_ frameID: FrameID, _ value: String) -> ExtractedText {
        ExtractedText(frameID: frameID, timestamp: time, regions: [TextRegion(frameID: frameID, text: value,
                                                                            bounds: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1), confidence: 0.99, createdAt: time)])
    }
    private func sql(_ value: String) async throws { try PipelineSQL.execute(try requireValue(await database.getConnection()), value) }
    private func scalar(_ value: String) async throws -> Int64 { try PipelineSQL.integers(try requireValue(await database.getConnection()), value).first ?? 0 }
    private func assertThrows(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected evidence rejection", file: file, line: line) } catch { }
    }
}
