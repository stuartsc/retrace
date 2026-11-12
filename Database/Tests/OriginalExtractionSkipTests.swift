import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database

final class OriginalExtractionSkipTests: XCTestCase {
    private var database: DatabaseManager!
    private var frameID: FrameID!
    private var videoID: Int64 = 0
    private let sourcePath = VideoSegmentID(value: 1_790_000_007_000)
    private let capturedAt = Date(timeIntervalSince1970: 1_790_000_007)

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:original-skip-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let segment = try await database.insertSegment(bundleID: "com.test.excluded", startDate: capturedAt,
            endDate: capturedAt, windowName: "Saved window", browserUrl: nil, type: 0)
        videoID = try await database.insertVideoSegment(VideoSegment(id: VideoSegmentID(value: 0),
            startTime: capturedAt, endTime: capturedAt, frameCount: 1, fileSizeBytes: 100,
            relativePath: "chunks/\(sourcePath.value)", width: 64, height: 64))
        let id = try await database.insertCapturedFrame(FrameReference(id: FrameID(value: 0),
            timestamp: capturedAt, segmentID: AppSegmentID(value: segment),
            videoID: VideoSegmentID(value: videoID), frameIndexInSegment: 0,
            metadata: FrameMetadata(appBundleID: "com.test.excluded", displayID: 42)),
            originalVideoPathID: sourcePath)
        frameID = FrameID(value: id)
    }

    override func tearDown() async throws { try await database.close() }

    func testSkipRequiresFinalArchiveAndDoesNotInventOCR() async throws {
        let store = try await database.originalStoreID()
        let before = try await database.currentScreenEvidence(frameID: frameID, storeID: store)
        try await database.recordOriginalExtractionSkipped(frameID: frameID, expectedAppBundleID: "com.test.excluded")
        guard case .pending = try await database.originalFrameDisposition(frameID: frameID) else {
            return XCTFail("Skipping OCR cannot release an unfinalised archive")
        }
        try await database.markVideoFinalized(id: videoID, frameCount: 1, fileSize: 100)
        guard case .skippedByAppFilter(let actualStore, let frame, let archive) =
            try await database.originalFrameDisposition(frameID: frameID) else {
            return XCTFail("An explicit durable skip should reach archive verification")
        }
        XCTAssertEqual(actualStore, store)
        XCTAssertEqual(frame.id, frameID)
        XCTAssertEqual(frame.metadata.displayID, 42)
        XCTAssertEqual(archive.id.value, videoID)
        let after = try await database.currentScreenEvidence(frameID: frameID, storeID: store)
        XCTAssertEqual(after?.ref, before?.ref)
        XCTAssertNil(after?.text, "An app exclusion must not publish a fabricated empty OCR result")
    }

    func testStatusOnlyCompletionCannotReleaseAndResetRevokesSkipProof() async throws {
        try await database.markVideoFinalized(id: videoID, frameCount: 1, fileSize: 100)
        try await database.updateFrameProcessingStatus(frameID: frameID.value, status: 2)
        guard case .pending = try await database.originalFrameDisposition(frameID: frameID) else {
            return XCTFail("Legacy completed status does not prove an intentional skip")
        }
        try await database.recordOriginalExtractionSkipped(frameID: frameID, expectedAppBundleID: "com.test.excluded")
        try await database.updateFrameProcessingStatus(frameID: frameID.value, status: 0)
        // A later legacy completion must not resurrect an earlier policy decision.
        try await database.updateFrameProcessingStatus(frameID: frameID.value, status: 2)
        guard case .pending = try await database.originalFrameDisposition(frameID: frameID) else {
            return XCTFail("Reprocessing must invalidate the old skip receipt")
        }
        let receipts = try await database.skipTestCount()
        XCTAssertEqual(receipts, 0)
    }

    func testConflictingAppDecisionCannotCommitSkip() async throws {
        do {
            try await database.recordOriginalExtractionSkipped(frameID: frameID, expectedAppBundleID: "com.test.other")
            XCTFail("The skip decision belongs to a different captured app")
        } catch { }
        let statuses = try await database.getFrameProcessingStatuses(frameIDs: [frameID.value])
        XCTAssertEqual(statuses[frameID.value], 4)
        let receipts = try await database.skipTestCount()
        XCTAssertEqual(receipts, 0)
    }

    func testReceiptFailureRollsBackCompletedStatus() async throws {
        try await database.skipTestSQL("CREATE TRIGGER reject_skip BEFORE INSERT ON original_frame_extraction_skip BEGIN SELECT RAISE(ABORT,'injected skip failure'); END")
        do {
            try await database.recordOriginalExtractionSkipped(frameID: frameID, expectedAppBundleID: "com.test.excluded")
            XCTFail("Receipt failure must not leave completed queue state")
        } catch { }
        let statuses = try await database.getFrameProcessingStatuses(frameIDs: [frameID.value])
        XCTAssertEqual(statuses[frameID.value], 4)
        let receipts = try await database.skipTestCount()
        XCTAssertEqual(receipts, 0)
    }

    func testLegacyUnattributedSkipDoesNotInventOriginalReleaseProof() async throws {
        let retained = try await database.getFrame(id: frameID)
        let frame = try XCTUnwrap(retained)
        let legacyID = FrameID(value: try await database.skipTestInsertLegacy(FrameReference(id: FrameID(value: 0),
            timestamp: capturedAt.addingTimeInterval(1), segmentID: frame.segmentID,
            videoID: frame.videoID, frameIndexInSegment: 1, metadata: frame.metadata)))
        // Before immutable observations existed, retained frames had no snapshot.
        try await database.recordOriginalExtractionSkipped(frameID: legacyID, expectedAppBundleID: "com.test.excluded")
        let statuses = try await database.getFrameProcessingStatuses(frameIDs: [legacyID.value])
        XCTAssertEqual(statuses[legacyID.value], 2)
        let source = try await database.originalFrameLocation(frameID: legacyID)
        XCTAssertNil(source)
        guard case .pending = try await database.originalFrameDisposition(frameID: legacyID) else {
            return XCTFail("Unattributed legacy status cannot authorise original removal")
        }
    }

    func testDeletionRemovesSkipProofButRetainsSourceTombstone() async throws {
        try await database.recordOriginalExtractionSkipped(frameID: frameID, expectedAppBundleID: "com.test.excluded")
        let source = try await database.originalFrameLocation(frameID: frameID)
        XCTAssertEqual(source, sourcePath)
        try await database.deleteFrame(id: frameID)
        let deletedSource = try await database.originalFrameLocation(frameID: frameID)
        XCTAssertNil(deletedSource)
        let receipts = try await database.skipTestCount()
        XCTAssertEqual(receipts, 0)
        guard case .deleted = try await database.originalFrameDisposition(frameID: frameID) else {
            return XCTFail("Deletion proof must survive removal of its processing receipt")
        }
        do {
            try await database.recordOriginalExtractionSkipped(frameID: frameID, expectedAppBundleID: "com.test.excluded")
            XCTFail("A skip cannot recreate a deleted frame")
        } catch { }
    }
}

private extension DatabaseManager {
    func skipTestInsertLegacy(_ frame: FrameReference) throws -> Int64 {
        try FrameQueries.insert(db: XCTUnwrap(getConnection()), frame: frame)
    }
    func skipTestSQL(_ sql: String) throws { try PipelineSQL.execute(XCTUnwrap(getConnection()), sql) }
    func skipTestCount() throws -> Int64 {
        try XCTUnwrap(PipelineSQL.integers(XCTUnwrap(getConnection()),
            "SELECT COUNT(*) FROM original_frame_extraction_skip").first)
    }
}
