import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database

final class OriginalFrameAliasTests: XCTestCase {
    private var database: DatabaseManager!
    private var segment: Int64 = 0
    private var videoID: Int64 = 0
    private let pathID = VideoSegmentID(value: 1_790_000_000_123)
    private let timestamp = Date(timeIntervalSince1970: 1_790_000_000.123)

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:original-alias-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        segment = try await database.insertSegment(bundleID: "com.test.alias", startDate: timestamp,
            endDate: timestamp, windowName: nil, browserUrl: nil, type: 0)
        videoID = try await database.insertVideoSegment(video(path: "chunks/\(pathID.value)"))
    }

    override func tearDown() async throws { try await database.close() }

    func testV24MigrationPreservesExistingFramesAndDoesNotBackfillAliases() async throws {
        // Recreate the exact V23 surface without changing any retained rows.
        for sql in ["DROP TRIGGER original_frame_source_deleted",
                    "DROP TRIGGER original_frame_source_identity",
                    "DROP TRIGGER original_frame_source_retained",
                    "DROP TABLE original_frame_source", "DELETE FROM schema_migrations WHERE version=24"] {
            try await database.aliasTestSQL(sql)
        }
        let id = try await database.insertFrame(frame())
        let before = try await database.getFrame(id: FrameID(value: id))
        let store = try await database.originalStoreID()
        let opened = await database.getConnection()
        let connection = try XCTUnwrap(opened)
        // This fixture isolates V24 even when newer migrations are registered.
        try await database.aliasTestSQL("BEGIN IMMEDIATE")
        do {
            try await V24_OriginalFrameSources().migrate(db: connection)
            try await database.aliasTestSQL("INSERT INTO schema_migrations(version,applied_at) VALUES(24,0)")
            try await database.aliasTestSQL("COMMIT")
        } catch {
            try? await database.aliasTestSQL("ROLLBACK")
            throw error
        }
        let after = try await database.getFrame(id: FrameID(value: id))
        let afterStore = try await database.originalStoreID()
        XCTAssertEqual(after, before)
        XCTAssertEqual(afterStore, store)
        let aliasCount = try await database.aliasTestCount("original_frame_source")
        XCTAssertEqual(aliasCount, 0, "Migration must not invent source provenance for existing frames")
        try await MigrationRunner(db: connection).runMigrations()
        let frameCount = try await database.getFrameCount()
        XCTAssertEqual(frameCount, 1)
    }

    func testCaptureAliasSurvivesDeletionBeforeFilesystemMapRegistration() async throws {
        let storeID = try await database.originalStoreID()
        let id = try await database.insertCapturedFrame(frame(), originalVideoPathID: pathID)
        let retained = try await database.lookupOriginalFrame(sourceStoreID: storeID,
            originalVideoPathID: pathID, sourceIndex: 0)
        XCTAssertEqual(retained, .retained(frameID: FrameID(value: id)))
        // No filesystem frame-ID registration occurred before this canonical delete.
        try await database.deleteFrame(id: FrameID(value: id))
        let deleted = try await database.lookupOriginalFrame(sourceStoreID: storeID,
            originalVideoPathID: pathID, sourceIndex: 0)
        XCTAssertEqual(deleted, .deleted(frameID: FrameID(value: id)))
        let unrelated = try await database.lookupOriginalFrame(sourceStoreID: UUID(),
            originalVideoPathID: pathID, sourceIndex: 0)
        XCTAssertEqual(unrelated, .unknown)
    }

    func testAliasFailureRollsBackFrameAndCaptureSnapshot() async throws {
        try await database.aliasTestSQL("CREATE TRIGGER reject_alias BEFORE INSERT ON original_frame_source BEGIN SELECT RAISE(ABORT,'injected alias failure'); END")
        do {
            _ = try await database.insertCapturedFrame(frame(), originalVideoPathID: pathID)
            XCTFail("Capture and alias must commit together")
        } catch { }
        let count = try await database.getFrameCount()
        XCTAssertEqual(count, 0)
        let observations = try await database.aliasTestCount("screen_observation")
        XCTAssertEqual(observations, 0)
    }

    func testDuplicateOriginalIdentityCannotInsertAnotherFrame() async throws {
        let id = try await database.insertCapturedFrame(frame(), originalVideoPathID: pathID)
        do {
            _ = try await database.insertCapturedFrame(frame(), originalVideoPathID: pathID)
            XCTFail("One original position cannot acquire a second database identity")
        } catch { }
        let count = try await database.getFrameCount()
        XCTAssertEqual(count, 1)
        let storeID = try await database.originalStoreID()
        let alias = try await database.lookupOriginalFrame(sourceStoreID: storeID,
            originalVideoPathID: pathID, sourceIndex: 0)
        XCTAssertEqual(alias, .retained(frameID: FrameID(value: id)))
    }

    func testCaptureRejectsAnOriginalPathThatDoesNotOwnTheArchivePlaceholder() async throws {
        do {
            _ = try await database.insertCapturedFrame(frame(),
                originalVideoPathID: VideoSegmentID(value: pathID.value + 1))
            XCTFail("Capture cannot bind a different writer's original source")
        } catch { }
        let count = try await database.getFrameCount()
        XCTAssertEqual(count, 0)
    }

    func testRecoveryCannotRecreateDeletedOriginalWithoutFilesystemID() async throws {
        let id = try await database.insertCapturedFrame(frame(), originalVideoPathID: pathID)
        try await database.deleteFrame(id: FrameID(value: id))
        do {
            _ = try await database.commitRecoveredFrames(video: video(path: "chunks/1790000000999"),
                originalVideoPathID: pathID, originalFrameIndices: [0], frames: [frame()])
            XCTFail("Recovery must recheck the source tombstone inside its transaction")
        } catch { }
        let count = try await database.getFrameCount()
        XCTAssertEqual(count, 0)
    }

    func testRecoveryPublishesAliasWithItsNewArchiveMapping() async throws {
        let ids = try await database.commitRecoveredFrames(video: video(path: "chunks/1790000000999"),
            originalVideoPathID: pathID, originalFrameIndices: [37], frames: [frame()])
        let storeID = try await database.originalStoreID()
        let alias = try await database.lookupOriginalFrame(sourceStoreID: storeID,
            originalVideoPathID: pathID, sourceIndex: 37)
        XCTAssertEqual(alias, .retained(frameID: FrameID(value: try XCTUnwrap(ids.first))))
        _ = try await database.deleteFrames(olderThan: timestamp.addingTimeInterval(1))
        let deleted = try await database.lookupOriginalFrame(sourceStoreID: storeID,
            originalVideoPathID: pathID, sourceIndex: 37)
        XCTAssertEqual(deleted, .deleted(frameID: FrameID(value: ids[0])))
    }

    func testRecoveryCanRemapSurvivorUsingItsOriginalAliasAfterPriorPublication() async throws {
        let first = try await database.commitRecoveredFrames(video: video(path: "chunks/1790000000999"),
            originalVideoPathID: pathID, originalFrameIndices: [37], frames: [frame()])
        let id = try XCTUnwrap(first.first)
        let store = try await database.originalStoreID()
        let originalCapture = try await database.currentScreenEvidence(frameID: FrameID(value: id), storeID: store)
        // A retry that omits a deleted neighbour has a new archive path/index.
        // The alias must still identify the survivor even without a filesystem ID.
        let second = try await database.commitRecoveredFrames(video: video(path: "chunks/1790000001999"),
            originalVideoPathID: pathID, originalFrameIndices: [37], frames: [frame()])
        XCTAssertEqual(second, first)
        let count = try await database.getFrameCount()
        XCTAssertEqual(count, 1)
        let current = try await database.getFrameWithVideoInfoByID(id: FrameID(value: id))
        let remappedVideoID = try XCTUnwrap(current?.frame.videoID)
        let remappedVideo = try await database.getVideoSegment(id: remappedVideoID)
        XCTAssertEqual(remappedVideo?.relativePath, "chunks/1790000001999")
        let sameCapture = try await database.currentScreenEvidence(frameID: FrameID(value: id), storeID: store)
        XCTAssertEqual(sameCapture?.ref, originalCapture?.ref)
        let alias = try await database.lookupOriginalFrame(sourceStoreID: store,
            originalVideoPathID: pathID, sourceIndex: 37)
        XCTAssertEqual(alias, .retained(frameID: FrameID(value: id)))
    }

    func testRecoveryAliasDoesNotAuthorizeAChangedCaptureTimestamp() async throws {
        let ids = try await database.commitRecoveredFrames(video: video(path: "chunks/1790000000999"),
            originalVideoPathID: pathID, originalFrameIndices: [37], frames: [frame()])
        let changed = FrameReference(id: FrameID(value: ids[0]), timestamp: timestamp.addingTimeInterval(2),
            segmentID: AppSegmentID(value: segment), frameIndexInSegment: 0, metadata: frame().metadata)
        do {
            _ = try await database.commitRecoveredFrames(video: video(path: "chunks/1790000001999"),
                originalVideoPathID: pathID, originalFrameIndices: [37], frames: [changed])
            XCTFail("An original alias cannot authorize a different captured moment")
        } catch { }
        let retained = try await database.getFrameWithVideoInfoByID(id: FrameID(value: ids[0]))
        let retainedVideoID = try XCTUnwrap(retained?.frame.videoID)
        let retainedVideo = try await database.getVideoSegment(id: retainedVideoID)
        XCTAssertEqual(retainedVideo?.relativePath, "chunks/1790000000999")
    }

    private func frame() -> FrameReference {
        FrameReference(id: FrameID(value: 0), timestamp: timestamp,
            segmentID: AppSegmentID(value: segment), videoID: VideoSegmentID(value: videoID),
            frameIndexInSegment: 0, metadata: FrameMetadata(appBundleID: "com.test.alias", displayID: 42))
    }

    private func video(path: String) -> VideoSegment {
        VideoSegment(id: VideoSegmentID(value: 0), startTime: timestamp, endTime: timestamp,
            frameCount: 1, fileSizeBytes: 100, relativePath: path, width: 64, height: 64)
    }
}

private extension DatabaseManager {
    func aliasTestSQL(_ sql: String) throws { try PipelineSQL.execute(XCTUnwrap(getConnection()), sql) }
    func aliasTestCount(_ table: String) throws -> Int64 {
        try XCTUnwrap(PipelineSQL.integers(XCTUnwrap(getConnection()), "SELECT COUNT(*) FROM \(table)").first)
    }
}
