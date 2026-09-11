import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database

final class IntegrationTests: XCTestCase {
    private var database: DatabaseManager!
    private var ftsManager: FTSManager!
    private var testRoot: URL!
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    override func setUp() async throws {
        testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("RetraceIntegrationTests_\(UUID())")
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        let path = testRoot.appendingPathComponent("test.db").path
        database = DatabaseManager(databasePath: path)
        ftsManager = FTSManager(databasePath: path)
        try await database.initialize()
        try await ftsManager.initialize()
    }

    override func tearDown() async throws {
        try await ftsManager.close()
        try await database.close()
        try FileManager.default.removeItem(at: testRoot)
    }

    private func video(count: Int = 1) async throws -> VideoSegmentID {
        let id = try await database.insertVideoSegment(VideoSegment(id: VideoSegmentID(value: 0),
            startTime: now, endTime: now.addingTimeInterval(300), frameCount: count,
            fileSizeBytes: 1_024, relativePath: "chunks/\(UUID())", width: 1920, height: 1080))
        try await database.markVideoFinalized(id: id, frameCount: count, fileSize: 1_024)
        return VideoSegmentID(value: id)
    }

    /// Real SQLite capture and OCR publication, using IDs returned by the database.
    private func capture(_ content: String? = nil, videoID: VideoSegmentID? = nil,
                         offset: Double = 0, app: String = "com.apple.Safari",
                         title: String? = "Retrace", url: String? = "https://example.test/retrace",
                         index: Int = 0) async throws -> FrameReference {
        let resolvedVideoID: VideoSegmentID
        if let videoID {
            resolvedVideoID = videoID
        } else {
            resolvedVideoID = try await video()
        }
        let timestamp = now.addingTimeInterval(offset)
        let segmentID = try await database.insertSegment(bundleID: app, startDate: timestamp,
            endDate: timestamp.addingTimeInterval(2), windowName: title, browserUrl: url, type: 0)
        let id = FrameID(value: try await database.insertFrame(FrameReference(id: FrameID(value: 0),
            timestamp: timestamp, segmentID: AppSegmentID(value: segmentID), videoID: resolvedVideoID,
            frameIndexInSegment: index, metadata: FrameMetadata(appBundleID: app, windowName: title, browserURL: url))))
        try await database.markFrameReadable(frameID: id.value)
        if let content {
            _ = try await database.commitFrameOCR(frameID: id, text: ExtractedText(frameID: id,
                timestamp: timestamp, regions: [TextRegion(frameID: id, text: content,
                    bounds: CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.1))]), frameWidth: 1920, frameHeight: 1080)
        }
        let frame = try await database.getFrame(id: id)
        return try XCTUnwrap(frame)
    }

    func testFullCaptureToSearchFlow() async throws {
        let frame = try await capture("screen recording application searchable evidence")
        let results = try await ftsManager.search(query: "screen recording", limit: 10, offset: 0)
        let nodes = try await database.getNodesWithText(frameID: frame.id, frameWidth: 1920, frameHeight: 1080)
        let statuses = try await database.getFrameProcessingStatuses(frameIDs: [frame.id.value])
        XCTAssertEqual(results.map(\.frameID), [frame.id])
        XCTAssertEqual(results.first?.videoID, frame.videoID)
        XCTAssertEqual(results.first?.windowName, "Retrace")
        XCTAssertEqual(nodes.map(\.text), ["screen recording application searchable evidence"])
        XCTAssertEqual(statuses[frame.id.value], 2)
    }

    func testSearchWithDateFilter_FindsOnlyRecentContent() async throws {
        _ = try await capture("searchable history", offset: -86_400)
        let recent = try await capture("searchable history")
        let results = try await ftsManager.search(query: "searchable",
            filters: SearchFilters(startDate: now.addingTimeInterval(-60), endDate: now.addingTimeInterval(60)), limit: 10, offset: 0)
        XCTAssertEqual(results.map(\.frameID), [recent.id])
    }

    func testMultipleAppsSharingVideo_SearchByApp() async throws {
        let videoID = try await video(count: 2)
        let safari = try await capture("shared code content", videoID: videoID, app: "com.apple.Safari")
        let xcode = try await capture("shared code content", videoID: videoID, offset: 2, app: "com.apple.dt.Xcode", index: 1)
        let frames = try await database.getFrames(appBundleID: "com.apple.dt.Xcode", limit: 10, offset: 0)
        let results = try await ftsManager.search(query: "code", filters: SearchFilters(appBundleIDs: ["Xcode"]), limit: 10, offset: 0)
        XCTAssertEqual(frames.map(\.id), [xcode.id])
        XCTAssertEqual(results.map(\.frameID), [xcode.id])
        XCTAssertEqual(safari.videoID, xcode.videoID)
        XCTAssertNotEqual(safari.segmentID, xcode.segmentID)
    }

    func testDeleteSegment_CascadesToFramesAndDocuments() async throws {
        let deleted = try await capture("discarded evidence")
        let retained = try await capture("retained evidence")
        try await database.deleteVideoSegment(id: deleted.videoID)
        let deletedVideo = try await database.getVideoSegment(id: deleted.videoID)
        let deletedFrame = try await database.getFrame(id: deleted.id)
        let deletedDocument = try await database.getDocument(frameID: deleted.id)
        let oldResults = try await ftsManager.search(query: "discarded", limit: 10, offset: 0)
        let keptResults = try await ftsManager.search(query: "retained", limit: 10, offset: 0)
        XCTAssertNil(deletedVideo)
        XCTAssertNil(deletedFrame)
        XCTAssertNil(deletedDocument)
        XCTAssertTrue(oldResults.isEmpty)
        XCTAssertEqual(keptResults.map(\.frameID), [retained.id])
        try await assertNoOrphanedFrameEvidence()
    }

    func testDeleteOldFrames_RemovesAssociatedDocuments() async throws {
        let videoID = try await video(count: 2)
        let old = try await capture("expired record", videoID: videoID, offset: -100)
        let recent = try await capture("recent record", videoID: videoID, index: 1)
        let deleted = try await database.deleteFrames(olderThan: now.addingTimeInterval(-10))
        let oldDoc = try await database.getDocument(frameID: old.id)
        let recentDoc = try await database.getDocument(frameID: recent.id)
        let results = try await ftsManager.search(query: "record", limit: 10, offset: 0)
        XCTAssertEqual(deleted, 1)
        XCTAssertNil(oldDoc)
        XCTAssertEqual(recentDoc?.content, "recent record")
        XCTAssertEqual(results.map(\.frameID), [recent.id])
        try await assertNoOrphanedFrameEvidence()
    }

    func testDeleteRecentAndSingleFramesRemovesAllEvidence() async throws {
        let old = try await capture("older evidence", offset: -20)
        _ = try await capture("newer evidence", offset: 20)
        let count = try await database.deleteFrames(newerThan: now)
        XCTAssertEqual(count, 1)
        try await database.deleteFrame(id: old.id)
        let remaining = try await database.getFrameCount()
        XCTAssertEqual(remaining, 0)
        try await assertNoOrphanedFrameEvidence()
    }

    func testFailedDeletionRollsBackFrameAndSearchEvidence() async throws {
        let frame = try await capture("transaction evidence")
        try await database.updateFrameProcessingStatus(frameID: frame.id.value, status: 0)
        try await database.enqueueFrameForProcessing(frameID: frame.id.value)
        try await database.integrationExecute("CREATE TEMP TRIGGER reject_frame_delete BEFORE DELETE ON frame BEGIN SELECT RAISE(ABORT,'test failure'); END")
        do {
            try await database.deleteVideoSegment(id: frame.videoID)
            XCTFail("Injected deletion failure must escape")
        } catch is DatabaseError { }
        let keptFrame = try await database.getFrame(id: frame.id)
        let keptVideo = try await database.getVideoSegment(id: frame.videoID)
        let nodes = try await database.getNodesWithText(frameID: frame.id, frameWidth: 1920, frameHeight: 1080)
        let results = try await ftsManager.search(query: "transaction", limit: 10, offset: 0)
        XCTAssertNotNil(keptFrame)
        XCTAssertNotNil(keptVideo)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(results.map(\.frameID), [frame.id])
        let queued = try await database.integrationCount("SELECT COUNT(*) FROM processing_queue")
        XCTAssertEqual(queued, 1)
        try await database.integrationExecute("DROP TRIGGER reject_frame_delete")
        try await database.deleteVideoSegment(id: frame.videoID)
        try await assertNoOrphanedFrameEvidence()
    }

    func testDeletingOneFramePreservesSharedSearchDocumentAndUserComment() async throws {
        let first = try await capture("shared document")
        let second = try await capture()
        let document = try await database.getDocument(frameID: first.id)
        let docid = try XCTUnwrap(document?.id)
        try await database.integrationExecute("INSERT INTO doc_segment(docid,segmentId,frameId) VALUES(\(docid),\(second.segmentID.value),\(second.id.value))")
        try await database.integrationExecute("INSERT INTO segment_comment(body,author,frameId) VALUES('retained user note','test',\(first.id.value))")
        try await database.updateFrameProcessingStatus(frameID: first.id.value, status: 0)
        try await database.enqueueFrameForProcessing(frameID: first.id.value)
        try await database.deleteFrame(id: first.id)
        let results = try await ftsManager.search(query: "shared", limit: 10, offset: 0)
        let comments = try await database.integrationCount("SELECT COUNT(*) FROM segment_comment WHERE body='retained user note' AND frameId IS NULL")
        XCTAssertEqual(results.map(\.frameID), [second.id])
        XCTAssertEqual(comments, 1)
        try await assertNoOrphanedFrameEvidence()
        try await database.deleteFrame(id: second.id)
        let documents = try await database.integrationCount("SELECT COUNT(*) FROM searchRanking")
        XCTAssertEqual(documents, 0)
    }

    func testDeletingFramePreservesSessionOnlyDocumentLink() async throws {
        let frame = try await capture("session evidence")
        let document = try await database.getDocument(frameID: frame.id)
        let docid = try XCTUnwrap(document?.id)
        try await database.integrationExecute("INSERT INTO doc_segment(docid,segmentId,frameId) VALUES(\(docid),\(frame.segmentID.value),NULL)")
        try await database.deleteFrame(id: frame.id)
        let documents = try await database.integrationCount("SELECT COUNT(*) FROM searchRanking WHERE rowid=\(docid)")
        let sessionLinks = try await database.integrationCount("SELECT COUNT(*) FROM doc_segment WHERE docid=\(docid) AND frameId IS NULL")
        let frameLinks = try await database.integrationCount("SELECT COUNT(*) FROM doc_segment WHERE frameId=\(frame.id.value)")
        XCTAssertEqual(documents, 1)
        XCTAssertEqual(sessionLinks, 1)
        XCTAssertEqual(frameLinks, 0)
    }

    func testVideoRowDeletionFailureRollsBackCompletedFrameCleanup() async throws {
        let frame = try await capture("restored evidence")
        try await database.integrationExecute("CREATE TEMP TRIGGER reject_video_delete BEFORE DELETE ON video BEGIN SELECT RAISE(ABORT,'test failure'); END")
        do {
            try await database.deleteVideoSegment(id: frame.videoID)
            XCTFail("Video deletion failure must roll back frame cleanup")
        } catch is DatabaseError { }
        let keptFrame = try await database.getFrame(id: frame.id)
        let keptVideo = try await database.getVideoSegment(id: frame.videoID)
        let nodes = try await database.getNodesWithText(frameID: frame.id, frameWidth: 1920, frameHeight: 1080)
        let results = try await ftsManager.search(query: "restored", limit: 10, offset: 0)
        XCTAssertNotNil(keptFrame)
        XCTAssertNotNil(keptVideo)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(results.map(\.frameID), [frame.id])
        try await database.integrationExecute("DROP TRIGGER reject_video_delete")
        try await database.deleteVideoSegment(id: frame.videoID)
        try await assertNoOrphanedFrameEvidence()
    }

    func testLegacyDocumentCRUDUsesCanonicalSearchIndex() async throws {
        let frame = try await capture()
        let docid = try await database.insertDocument(IndexedDocument(id: 0, frameID: frame.id,
            timestamp: frame.timestamp, content: "originaltoken"))
        let original = try await ftsManager.search(query: "originaltoken", limit: 10, offset: 0)
        XCTAssertEqual(original.map(\.documentID), [docid])
        try await database.updateDocument(id: docid, content: "replacementtoken")
        let old = try await ftsManager.search(query: "originaltoken", limit: 10, offset: 0)
        let updated = try await ftsManager.search(query: "replacementtoken", limit: 10, offset: 0)
        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(updated.map(\.frameID), [frame.id])
        try await database.deleteDocument(id: docid)
        let deleted = try await ftsManager.search(query: "replacementtoken", limit: 10, offset: 0)
        let links = try await database.integrationCount("SELECT COUNT(*) FROM doc_segment")
        let persisted = try await database.getFrame(id: frame.id)
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(links, 0)
        XCTAssertNotNil(persisted)
    }

    func testLegacyDocumentFailureDoesNotLeaveUnlinkedSearchContent() async throws {
        let frame = try await capture()
        try await database.integrationExecute("CREATE TEMP TRIGGER reject_document_link BEFORE INSERT ON doc_segment BEGIN SELECT RAISE(ABORT,'test failure'); END")
        do {
            _ = try await database.insertDocument(IndexedDocument(id: 0, frameID: frame.id, timestamp: frame.timestamp, content: "orphan candidate"))
            XCTFail("Junction failure must roll back indexed content")
        } catch is DatabaseError { }
        let count = try await database.integrationCount("SELECT COUNT(*) FROM searchRanking")
        XCTAssertEqual(count, 0)
    }

    func testLegacyTextUpdateInvalidatesOldHighlights() async throws {
        let frame = try await capture("old region")
        let existing = try await database.getDocument(frameID: frame.id)
        let doc = try XCTUnwrap(existing)
        try await database.updateDocument(id: doc.id, content: "replacement with different offsets")
        let nodes = try await database.getNodesWithText(frameID: frame.id, frameWidth: 1920, frameHeight: 1080)
        XCTAssertTrue(nodes.isEmpty)
    }

    func testStatistics_AccurateAfterMultipleOperations() async throws {
        for videoIndex in 0..<3 {
            let videoID = try await video(count: 5)
            for index in 0..<5 {
                let text = index < 3 ? "indexed row \(videoIndex) \(index)" : nil
                _ = try await capture(text, videoID: videoID, offset: Double(videoIndex * 5 + index), index: index)
            }
        }
        let stats = try await database.getStatistics()
        XCTAssertEqual(stats.frameCount, 15)
        XCTAssertEqual(stats.documentCount, 9)
        XCTAssertEqual(stats.segmentCount, 3)
        XCTAssertEqual(stats.oldestFrameDate, now)
        XCTAssertEqual(stats.newestFrameDate, now.addingTimeInterval(14))
        let bytes = try await database.getTotalStorageBytes()
        XCTAssertEqual(bytes, 3_072)
    }

    func testConcurrentInserts_NoDataCorruption() async throws {
        let videoID = try await video(count: 25)
        let segmentID = try await database.insertSegment(bundleID: "com.test.concurrent", startDate: now,
            endDate: now.addingTimeInterval(25), windowName: nil, browserUrl: nil, type: 0)
        let database = try XCTUnwrap(database)
        let now = now
        let ids = try await withThrowingTaskGroup(of: Int64.self) { group in
            for index in 0..<25 {
                group.addTask {
                    try await database.insertFrame(FrameReference(id: FrameID(value: 0),
                        timestamp: now.addingTimeInterval(Double(index)), segmentID: AppSegmentID(value: segmentID),
                        videoID: videoID, frameIndexInSegment: index, metadata: .empty))
                }
            }
            var ids: [Int64] = []
            for try await id in group { ids.append(id) }
            return ids
        }
        let count = try await database.getFrameCount()
        XCTAssertEqual(Set(ids).count, 25)
        XCTAssertEqual(count, 25)
    }

    func testConcurrentReadsAndWrites_NoDeadlock() async throws {
        let seed = try await capture("concurrent seed")
        let database = try XCTUnwrap(database)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = try await database.insertFrame(FrameReference(id: FrameID(value: 0),
                        timestamp: seed.timestamp.addingTimeInterval(Double(index)), segmentID: seed.segmentID,
                        videoID: seed.videoID, frameIndexInSegment: index + 1, metadata: .empty))
                }
                group.addTask { _ = try await database.getFrames(from: seed.timestamp, to: seed.timestamp.addingTimeInterval(30), limit: 100) }
            }
            try await group.waitForAll()
        }
        let count = try await database.getFrameCount()
        XCTAssertEqual(count, 21)
    }

    func testVacuum_CompletesSuccessfully() async throws {
        let removed = try await capture("discard before vacuum")
        let kept = try await capture("retained after vacuum")
        try await database.deleteVideoSegment(id: removed.videoID)
        try await database.vacuum()
        let frames = try await database.getFrameCount()
        let results = try await ftsManager.search(query: "retained", limit: 10, offset: 0)
        XCTAssertEqual(frames, 1)
        XCTAssertEqual(results.map(\.frameID), [kept.id])
    }

    func testAnalyze_CompletesSuccessfully() async throws {
        let frame = try await capture("analyze evidence")
        try await database.analyze()
        let retrieved = try await database.getVideoSegment(id: frame.videoID)
        let results = try await ftsManager.search(query: "analyze", limit: 10, offset: 0)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(results.map(\.frameID), [frame.id])
    }

    func testCheckpoint_CompletesSuccessfully() async throws {
        let frame = try await capture("checkpoint evidence")
        try await database.checkpoint()
        let retrieved = try await database.getFrame(id: frame.id)
        XCTAssertNotNil(retrieved)
        let results = try await ftsManager.search(query: "checkpoint", limit: 10, offset: 0)
        XCTAssertEqual(results.map(\.frameID), [frame.id])
    }

    private func assertNoOrphanedFrameEvidence() async throws {
        for table in ["node", "doc_segment", "processing_queue"] {
            let count = try await database.integrationCount("SELECT COUNT(*) FROM \(table) t WHERE t.frameId IS NOT NULL AND NOT EXISTS(SELECT 1 FROM frame f WHERE f.id=t.frameId)")
            XCTAssertEqual(count, 0, "No orphaned \(table)")
        }
        let unlinked = try await database.integrationCount("SELECT COUNT(*) FROM searchRanking r WHERE NOT EXISTS(SELECT 1 FROM doc_segment d WHERE d.docid=r.rowid)")
        XCTAssertEqual(unlinked, 0, "No unlinked FTS content")
    }
}

private extension DatabaseManager {
    func integrationExecute(_ sql: String) throws {
        guard let db = getConnection() else { throw DatabaseError.connectionFailed(underlying: "Test database closed") }
        try PipelineSQL.execute(db, sql)
    }

    func integrationCount(_ sql: String) throws -> Int64 {
        guard let db = getConnection() else { throw DatabaseError.connectionFailed(underlying: "Test database closed") }
        return try PipelineSQL.integers(db, sql).first ?? 0
    }
}
