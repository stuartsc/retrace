import Foundation
import Shared
import XCTest
@testable import Database

final class RetentionPersistenceTests: XCTestCase {
    private var database: DatabaseManager!
    private let cutoff = Date(timeIntervalSince1970: 1_780_000_000)

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:retention_\(UUID())?mode=memory&cache=private")
        try await database.initialize()
    }

    override func tearDown() async throws { try await database.close() }

    private func video(finalized: Bool = true, path: String = "chunks/202601/01/1700000000001") async throws -> Int64 {
        let value = VideoSegment(id: VideoSegmentID(value: 1_700_000_000_001), startTime: cutoff.addingTimeInterval(-100),
                                 endTime: cutoff, frameCount: 2, fileSizeBytes: 1024,
                                 relativePath: path, width: 64, height: 64)
        let id = try await database.insertVideoSegment(value)
        if finalized { try await database.markVideoFinalized(id: id, frameCount: 2, fileSize: 1024) }
        return id
    }

    private func frame(videoID: Int64, offset: Double = -10, app: String = "com.test.expired") async throws -> (id: Int64, segmentID: Int64) {
        let date = cutoff.addingTimeInterval(offset)
        let segmentID = try await database.insertSegment(bundleID: app, startDate: date, endDate: date, windowName: "Test", browserUrl: nil, type: 0)
        let id = try await database.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: date,
            segmentID: AppSegmentID(value: segmentID), videoID: VideoSegmentID(value: videoID), frameIndexInSegment: 0,
            metadata: FrameMetadata(appBundleID: app)))
        return (id, segmentID)
    }

    func testOldAndRecentFramesSharingVideoPreserveTheVideo() async throws {
        let videoID = try await video()
        let old = try await frame(videoID: videoID)
        let recent = try await frame(videoID: videoID, offset: 10)
        let result = try await database.performRetentionBatch(olderThan: cutoff)
        XCTAssertEqual(result.deletedFrames, 1)
        XCTAssertTrue(result.videos.isEmpty)
        let oldFrame = try await database.getFrame(id: FrameID(value: old.id))
        let recentFrame = try await database.getFrame(id: FrameID(value: recent.id))
        XCTAssertNil(oldFrame)
        XCTAssertNotNil(recentFrame)
        let videoRow = try await database.getVideoSegment(id: VideoSegmentID(value: videoID))
        XCTAssertNotNil(videoRow)
    }

    func testRetentionDeletesSearchNodesLinksAndQueueInSameTransaction() async throws {
        let videoID = try await video()
        let expired = try await frame(videoID: videoID)
        let text = ExtractedText(frameID: FrameID(value: expired.id), timestamp: cutoff.addingTimeInterval(-10),
                                regions: [TextRegion(frameID: FrameID(value: expired.id), text: "expired invoice",
                                                     bounds: CGRect(x: 0, y: 0, width: 1, height: 1))])
        _ = try await database.commitFrameOCR(frameID: FrameID(value: expired.id), text: text, frameWidth: 64, frameHeight: 64)
        try await database.updateFrameProcessingStatus(frameID: expired.id, status: 0)
        try await database.enqueueFrameForProcessing(frameID: expired.id)
        let result = try await database.performRetentionBatch(olderThan: cutoff)
        XCTAssertEqual(result.deletedFrames, 1)
        for table in ["frame", "node", "doc_segment", "searchRanking", "processing_queue"] {
            let count = try await database.retentionTestCount(table)
            XCTAssertEqual(count, 0, "Retention must explicitly clean \(table)")
        }
        XCTAssertEqual(result.videos.first?.id.value, videoID)
        XCTAssertEqual(result.videos.first?.relativePath, "chunks/202601/01/1700000000001")
        XCTAssertNotEqual(result.videos.first?.id.value, 1_700_000_000_001)
    }

    func testExclusionsAndUnfinalizedVideosRemainProtected() async throws {
        let videoID = try await video()
        let appFrame = try await frame(videoID: videoID, app: "com.test.protected")
        let taggedFrame = try await frame(videoID: videoID)
        let hiddenFrame = try await frame(videoID: videoID)
        let removable = try await frame(videoID: videoID)
        let activeVideoID = try await video(finalized: false)
        let activeFrame = try await frame(videoID: activeVideoID)
        let tag = try await database.createTag(name: "keep")
        try await database.addTagToSegment(segmentId: SegmentID(value: taggedFrame.segmentID), tagId: tag.id)
        try await database.retentionTestExecute("INSERT INTO segment_tag(segmentId,tagId) SELECT \(hiddenFrame.segmentID),id FROM tag WHERE name='hidden'")
        let result = try await database.performRetentionBatch(olderThan: cutoff,
            excludingApps: ["com.test.protected"], excludingTagIDs: [tag.id.value], excludeHidden: true)
        XCTAssertEqual(result.deletedFrames, 1)
        for id in [appFrame.id, taggedFrame.id, hiddenFrame.id, activeFrame.id] {
            let retained = try await database.getFrame(id: FrameID(value: id))
            XCTAssertNotNil(retained)
        }
        let removed = try await database.getFrame(id: FrameID(value: removable.id))
        XCTAssertNil(removed)
        XCTAssertTrue(result.videos.isEmpty)
    }

    func testFailedFileDeletionKeepsCandidateForRetryThenDeletesCorrectDBID() async throws {
        _ = try await video()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("retention-file-\(UUID())")
        try Data(repeating: 7, count: 1024).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let candidates = try await database.performRetentionBatch(olderThan: cutoff)
        let candidate = try XCTUnwrap(candidates.videos.first)
        do {
            _ = try await database.completeRetentionVideoDeletion(candidate: candidate) { throw TestFailure.fileDeletion }
            XCTFail("Expected file deletion failure")
        } catch { }
        let repeated = try await database.performRetentionBatch(olderThan: cutoff)
        XCTAssertEqual(repeated.videos.map(\.id), [candidate.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let result = try await database.completeRetentionVideoDeletion(candidate: candidate) {
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            try FileManager.default.removeItem(at: file)
            return size
        }
        XCTAssertEqual(result, 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let third = try await database.completeRetentionVideoDeletion(candidate: candidate) { XCTFail("Already removed candidate must not delete twice"); return 0 }
        XCTAssertNil(third)
        let remaining = try await database.retentionTestCount("video")
        XCTAssertEqual(remaining, 0)
    }

    func testDatabaseFailureAfterFileUnlinkKeepsPathForMissingFileRetry() async throws {
        _ = try await video()
        let result = try await database.performRetentionBatch(olderThan: cutoff)
        let candidate = try XCTUnwrap(result.videos.first)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("retention-retry-\(UUID())")
        try Data([1, 2, 3]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        try await database.retentionTestExecute("CREATE TEMP TRIGGER reject_video_delete BEFORE DELETE ON video BEGIN SELECT RAISE(ABORT, 'injected database failure'); END")
        do {
            _ = try await database.completeRetentionVideoDeletion(candidate: candidate) {
                try FileManager.default.removeItem(at: file)
                return 3
            }
            XCTFail("Expected database deletion failure")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let count = try await database.retentionTestCount("video")
        XCTAssertEqual(count, 1)
        try await database.retentionTestExecute("DROP TRIGGER reject_video_delete")
        let retried = try await database.completeRetentionVideoDeletion(candidate: candidate) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            return 0
        }
        XCTAssertEqual(retried, 0)
        let remaining = try await database.retentionTestCount("video")
        XCTAssertEqual(remaining, 0)
    }

    func testStaleCandidateCannotDeleteChangedPathOrNewlyReferencedVideo() async throws {
        let videoID = try await video()
        let result = try await database.performRetentionBatch(olderThan: cutoff)
        let candidate = try XCTUnwrap(result.videos.first)
        try await database.retentionTestExecute("UPDATE video SET path='chunks/changed' WHERE id=\(videoID)")
        let changed = try await database.completeRetentionVideoDeletion(candidate: candidate) { XCTFail("Changed path must not be deleted"); return 0 }
        XCTAssertNil(changed)
        try await database.retentionTestExecute("UPDATE video SET path='\(candidate.relativePath)' WHERE id=\(videoID)")
        _ = try await frame(videoID: videoID, offset: 10)
        let referenced = try await database.completeRetentionVideoDeletion(candidate: candidate) { XCTFail("Referenced file must not be deleted"); return 0 }
        XCTAssertNil(referenced)
    }

    func testReferencedMP4AliasesProtectCandidatesInBothDirections() async throws {
        for (index, candidateHasExtension) in [false, true].enumerated() {
            let base = "chunks/202601/01/170000000010\(index)"
            let candidatePath = candidateHasExtension ? base + ".mp4" : base
            let referencedPath = candidateHasExtension ? base : base + ".mp4"
            let candidateID = try await video(path: candidatePath)
            let initial = try await database.performRetentionBatch(olderThan: cutoff)
            let candidate = try XCTUnwrap(initial.videos.first { $0.id.value == candidateID })
            let referencedID = try await video(path: referencedPath)
            _ = try await frame(videoID: referencedID, offset: 10)

            let refreshed = try await database.performRetentionBatch(olderThan: cutoff)
            XCTAssertFalse(refreshed.videos.contains { $0.id.value == candidateID }, "Referenced filename alias must protect candidate selection")
            let result = try await database.completeRetentionVideoDeletion(candidate: candidate) {
                XCTFail("An alias gained a frame after selection; file deletion must not run")
                return 0
            }
            XCTAssertNil(result)
            let retained = try await database.getVideoSegment(id: VideoSegmentID(value: candidateID))
            XCTAssertNotNil(retained)
        }
    }

    func testReferencedDoubleExtensionFallbackAlsoProtectsCandidate() async throws {
        let candidateID = try await video(path: "chunks/202601/01/1700000000200.mp4")
        let initial = try await database.performRetentionBatch(olderThan: cutoff)
        let candidate = try XCTUnwrap(initial.videos.first { $0.id.value == candidateID })
        let referencedID = try await video(path: candidate.relativePath + ".mp4")
        _ = try await frame(videoID: referencedID, offset: 10)
        let result = try await database.completeRetentionVideoDeletion(candidate: candidate) {
            XCTFail("The reader can append .mp4 to an existing extension; that fallback must stay protected")
            return 0
        }
        XCTAssertNil(result)
    }

    func testFrameDeleteFailureRollsBackRelatedSearchCleanup() async throws {
        let videoID = try await video()
        let expired = try await frame(videoID: videoID)
        _ = try await database.commitFrameOCR(frameID: FrameID(value: expired.id),
            text: ExtractedText(frameID: FrameID(value: expired.id), timestamp: cutoff, regions: [
                TextRegion(frameID: FrameID(value: expired.id), text: "preserve on failure", bounds: CGRect(x: 0, y: 0, width: 1, height: 1))]),
            frameWidth: 64, frameHeight: 64)
        try await database.retentionTestExecute("CREATE TEMP TRIGGER reject_retention BEFORE DELETE ON frame BEGIN SELECT RAISE(ABORT, 'injected retention failure'); END")
        do {
            _ = try await database.performRetentionBatch(olderThan: cutoff)
            XCTFail("Expected database transaction failure")
        } catch { }
        for table in ["frame", "node", "doc_segment", "searchRanking"] {
            let count = try await database.retentionTestCount(table)
            XCTAssertEqual(count, 1)
        }
    }

    private enum TestFailure: Error { case fileDeletion }
}

private extension DatabaseManager {
    func retentionTestExecute(_ sql: String) throws {
        guard let db = getConnection() else { throw DatabaseError.connectionFailed(underlying: "No test database") }
        try PipelineSQL.execute(db, sql)
    }
    func retentionTestCount(_ table: String) throws -> Int64 {
        guard let db = getConnection() else { throw DatabaseError.connectionFailed(underlying: "No test database") }
        return try PipelineSQL.integers(db, "SELECT COUNT(*) FROM \(table)").first ?? 0
    }
}
