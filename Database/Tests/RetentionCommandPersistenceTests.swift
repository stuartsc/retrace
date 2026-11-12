import Foundation
import Shared
import XCTest
@testable import Database

final class RetentionCommandPersistenceTests: XCTestCase {
    private var database: DatabaseManager!
    private let cutoff = Date(timeIntervalSince1970: 1_780_000_000)
    private var access: ScreenEvidenceAccessPolicy { .init(config: Shared.CaptureConfig()) }
    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:retention_command_\(UUID())?mode=memory&cache=private")
        try await database.initialize()
    }
    override func tearDown() async throws { try await database.close() }
    private func item(path: String = "chunks/authored", offset: Double = -10) async throws -> (frame: Int64, segment: Int64, video: Int64) {
        let date = cutoff.addingTimeInterval(offset)
        let video = try await database.insertVideoSegment(.init(id: .init(value: 0), startTime: date, endTime: date,
            frameCount: 1, fileSizeBytes: 3, relativePath: path, width: 64, height: 64))
        try await database.markVideoFinalized(id: video, frameCount: 1, fileSize: 3)
        let segment = try await database.insertSegment(bundleID: "com.authored.retention", startDate: date, endDate: date,
            windowName: "Authored fixture", browserUrl: nil, type: 0)
        let frame = try await database.insertFrame(.init(id: .init(value: 0), timestamp: date, segmentID: .init(value: segment),
            videoID: .init(value: video), frameIndexInSegment: 0, metadata: .init(appBundleID: "com.authored.retention")))
        return (frame, segment, video)
    }
    private func preview() async throws -> RetentionCommandSelection {
        try await database.previewRetentionCommand(cutoff: cutoff, policy: .init(), access: access)
    }
    private func execute(_ selection: RetentionCommandSelection, fence: NativeMutationFence = .init()) async throws -> (frames: Int, sessions: Int) {
        try await database.executeRetentionCommand(selection, policy: .init(), access: access, fences: [fence])
    }

    func testOnlyFrozenTargetsAreDeletedAndNewOldCaptureSurvives() async throws {
        let original = try await item(), selection = try await preview()
        let later = try await item(path: "chunks/later-old", offset: -5)
        let result = try await execute(selection)
        XCTAssertEqual(result.frames, 1); XCTAssertEqual(result.sessions, 1)
        let gone = try await database.getFrame(id: .init(value: original.frame))
        let retained = try await database.getFrame(id: .init(value: later.frame))
        XCTAssertNil(gone); XCTAssertNotNil(retained)
        XCTAssertEqual(selection.frameIDs, [original.frame]); XCTAssertEqual(selection.videos.map(\.id.value), [original.video])
        do { _ = try await execute(selection); XCTFail("Consumed preview must not repeat") } catch { }
    }

    func testSelectedFrameABAAndVideoMutationRejectWholeBatch() async throws {
        let first = try await item(), second = try await item(path: "chunks/second")
        let selection = try await preview()
        try await database.retentionCommandTestSQL("UPDATE frame SET isStarred=1 WHERE id=\(first.frame)")
        try await database.retentionCommandTestSQL("UPDATE frame SET isStarred=0 WHERE id=\(first.frame)")
        do { _ = try await execute(selection); XCTFail("ABA must revoke exact preview") } catch RetentionCommandError.stalePreview { }
        let firstRetained = try await database.getFrame(id: .init(value: first.frame))
        let secondRetained = try await database.getFrame(id: .init(value: second.frame))
        XCTAssertNotNil(firstRetained); XCTAssertNotNil(secondRetained)
        let renewed = try await preview()
        try await database.retentionCommandTestSQL("UPDATE video SET path='chunks/replaced' WHERE id=\(first.video)")
        do { _ = try await execute(renewed); XCTFail("Video path changes must revoke") } catch RetentionCommandError.stalePreview { }
    }

    func testNewAudioOrNoteProtectionRevokesAndAudioBearingSessionIsPreserved() async throws {
        let original = try await item(), selection = try await preview()
        try await database.retentionCommandTestSQL("INSERT INTO audio(segmentId,path,startTime,duration) VALUES(\(original.segment),'authored.m4a',0,1000)")
        do { _ = try await execute(selection); XCTFail("New audio must revoke") } catch RetentionCommandError.stalePreview { }
        let renewed = try await preview()
        XCTAssertTrue(renewed.segmentIDs.isEmpty)
        let result = try await execute(renewed)
        XCTAssertEqual(result.frames, 1); XCTAssertEqual(result.sessions, 0)
        let audioCount = try await database.retentionCommandTestCount("audio")
        let sessionCount = try await database.retentionCommandTestCount("segment")
        XCTAssertEqual(audioCount, 1); XCTAssertEqual(sessionCount, 1)
    }

    func testExpiryAndRevokedCommandFenceLeaveFramesUntouched() async throws {
        let original = try await item(), selection = try await preview()
        let fence = NativeMutationFence(); fence.invalidate()
        do { _ = try await execute(selection, fence: fence); XCTFail("Revoked client") } catch is CancellationError { }
        try await database.retentionCommandTestSQL("UPDATE temp.retention_command_selection SET expires=0")
        do { _ = try await execute(selection); XCTFail("Expired selection") } catch RetentionCommandError.stalePreview { }
        let retained = try await database.getFrame(id: .init(value: original.frame))
        XCTAssertNotNil(retained)
    }

    func testFailedDeleteRollsBackTextAndSelectionForSafeRetry() async throws {
        let original = try await item()
        _ = try await database.commitFrameOCR(frameID: .init(value: original.frame), text: .init(frameID: .init(value: original.frame),
            timestamp: cutoff.addingTimeInterval(-10), regions: [TextRegion(frameID: .init(value: original.frame), text: "Retain on rollback", bounds: CGRect(x: 0, y: 0, width: 1, height: 1))]), frameWidth: 64, frameHeight: 64)
        let selection = try await preview()
        try await database.retentionCommandTestSQL("CREATE TEMP TRIGGER reject_command_retention BEFORE DELETE ON frame BEGIN SELECT RAISE(ABORT,'authored failure'); END")
        do { _ = try await execute(selection); XCTFail("Injected failure") } catch { }
        for table in ["frame", "node", "searchRanking", "doc_segment"] {
            let count = try await database.retentionCommandTestCount(table)
            XCTAssertEqual(count, 1, table)
        }
        try await database.retentionCommandTestSQL("DROP TRIGGER reject_command_retention")
        let result = try await execute(selection)
        XCTAssertEqual(result.frames, 1)
    }

    func testSelectedVideoNewReferenceRevokesPreviewAndUnfinalizedFramesAreExcluded() async throws {
        let original = try await item(), selection = try await preview()
        try await database.retentionCommandTestSQL("UPDATE video SET processingState=1 WHERE id=\(original.video)")
        do { _ = try await execute(selection); XCTFail("Active writer must stay protected") } catch RetentionCommandError.stalePreview { }
        let renewed = try await preview()
        XCTAssertTrue(renewed.frameIDs.isEmpty); XCTAssertTrue(renewed.videos.isEmpty)
    }

    func testExcludedAppsCannotBeSelectedAndForgedFingerprintFails() async throws {
        _ = try await item()
        let excluded = try await database.previewRetentionCommand(cutoff: cutoff, policy: .init(excludedApps: ["com.authored.retention"]), access: access)
        XCTAssertTrue(excluded.frameIDs.isEmpty)
        let selection = try await preview()
        let forged = RetentionCommandSelection(id: selection.id, nativeStoreID: selection.nativeStoreID, cutoff: selection.cutoff,
            expiresAt: selection.expiresAt, fingerprint: "invented", frameIDs: selection.frameIDs, segmentIDs: selection.segmentIDs,
            videos: selection.videos, hasMoreFrames: false, hasMoreVideos: false, externalVersion: selection.externalVersion)
        do { _ = try await execute(forged); XCTFail("Only the writer's fingerprint is admitted") } catch RetentionCommandError.stalePreview { }
    }

    func testKeysetScanAdvancesPastFiveHundredPolicyDeniedFrames() async throws {
        let denied = try await item(path: "chunks/denied")
        try await database.retentionCommandTestSQL("UPDATE segment SET windowName='Private Browsing' WHERE id=\(denied.segment)")
        try await database.retentionCommandTestSQL("""
            WITH RECURSIVE copies(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM copies WHERE n<499)
            INSERT INTO frame(createdAt,imageFileName,segmentId,videoId,videoFrameIndex)
            SELECT createdAt,imageFileName,segmentId,videoId,videoFrameIndex FROM frame,copies WHERE frame.id=\(denied.frame)
            """)
        let allowed = try await item(path: "chunks/allowed", offset: -5)
        let first = try await preview()
        XCTAssertTrue(first.frameIDs.isEmpty)
        XCTAssertEqual(first.scannedFrames, 500); XCTAssertEqual(first.skippedFrames, 500)
        XCTAssertTrue(first.hasMoreFrames); XCTAssertEqual(first.scannedVideos, 0)
        let next = try XCTUnwrap(first.nextCursor)
        let second = try await database.previewRetentionCommand(cutoff: cutoff, policy: .init(), access: access, after: next)
        XCTAssertEqual(second.frameIDs, [allowed.frame])
        XCTAssertEqual(second.scannedFrames, 1); XCTAssertEqual(second.skippedFrames, 0)
        XCTAssertFalse(second.hasMoreFrames)
        XCTAssertEqual(second.videos.map(\.id.value), [allowed.video])
        _ = try await execute(second)
        let retained = try await database.getFrame(id: .init(value: denied.frame))
        XCTAssertNotNil(retained)
    }

    func testVideoKeysetAdvancesOverEarlierCandidatesWithoutDeletingThem() async throws {
        try await database.retentionCommandTestSQL("""
            WITH RECURSIVE copies(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM copies WHERE n<101)
            INSERT INTO video(path,width,height,processingState,frameCount,fileSize,frameRate)
            SELECT 'chunks/retained-'||n,64,64,0,1,3,30 FROM copies
            """)
        let first = try await preview()
        XCTAssertEqual(first.scannedVideos, 100); XCTAssertEqual(first.videos.count, 100)
        XCTAssertTrue(first.hasMoreVideos)
        let second = try await database.previewRetentionCommand(cutoff: cutoff, policy: .init(), access: access,
            after: XCTUnwrap(first.nextCursor))
        XCTAssertEqual(second.scannedVideos, 1); XCTAssertEqual(second.videos.count, 1)
        XCTAssertFalse(second.hasMoreVideos); XCTAssertNil(second.nextCursor)
        XCTAssertTrue(Set(first.videos.map(\.id)).isDisjoint(with: second.videos.map(\.id)))
        let count = try await database.retentionCommandTestCount("video")
        XCTAssertEqual(count, 101, "Discovery never deletes deferred files or their rows")
    }

    func testVideoAuthoritySurvivesScreenCommitAndRejectsUpdateAndReplacementABA() async throws {
        for replace in [false, true] {
            let original = try await item(path: "chunks/aba-\(replace)")
            let selection = try await preview()
            _ = try await execute(selection)
            let candidate = try XCTUnwrap(selection.videos.first { $0.id.value == original.video })
            if replace {
                try await database.retentionCommandTestSQL("""
                    INSERT OR REPLACE INTO video(id,path,width,height,processingState,frameCount,fileSize,frameRate)
                    VALUES(\(original.video),'chunks/aba-true',64,64,0,1,3,30)
                    """)
            } else {
                try await database.retentionCommandTestSQL("UPDATE video SET fileSize=4 WHERE id=\(original.video)")
                try await database.retentionCommandTestSQL("UPDATE video SET fileSize=3 WHERE id=\(original.video)")
            }
            do {
                _ = try await database.completeRetentionCommandMissingVideo(selection: selection, candidate: candidate, fences: [.init()]) {
                    XCTFail("A stale video must fail before the missing-file check"); return true
                }
                XCTFail("Video ABA after screen COMMIT must revoke cleanup")
            } catch RetentionCommandError.stalePreview { }
            let retained = try await database.getVideoSegment(id: candidate.id)
            XCTAssertNotNil(retained)
            try await database.discardRetentionCommand(selection.id)
        }
    }

    func testVideoAuthorityRejectsTransientNewReferenceAndIsConsumedExactlyOnce() async throws {
        let first = try await item(), second = try await item(path: "chunks/other")
        let selection = try await preview()
        _ = try await execute(selection)
        try await database.retentionCommandTestSQL("INSERT INTO frame(createdAt,imageFileName,videoId,videoFrameIndex) VALUES(1,'authored',\(first.video),0)")
        try await database.retentionCommandTestSQL("DELETE FROM frame WHERE videoId=\(first.video)")
        let firstCandidate = try XCTUnwrap(selection.videos.first { $0.id.value == first.video })
        do {
            _ = try await database.completeRetentionCommandMissingVideo(selection: selection, candidate: firstCandidate, fences: [.init()]) { true }
            XCTFail("A transient frame reference must revoke this video only")
        } catch RetentionCommandError.stalePreview { }
        let secondCandidate = try XCTUnwrap(selection.videos.first { $0.id.value == second.video })
        let removed = try await database.completeRetentionCommandMissingVideo(selection: selection, candidate: secondCandidate, fences: [.init()]) { true }
        XCTAssertTrue(removed)
        do {
            _ = try await database.completeRetentionCommandMissingVideo(selection: selection, candidate: secondCandidate, fences: [.init()]) {
                XCTFail("Consumed authority cannot check or delete twice"); return true
            }
            XCTFail("Consumed authority cannot be replayed")
        } catch RetentionCommandError.stalePreview { }
    }
}

private extension DatabaseManager {
    func retentionCommandTestSQL(_ sql: String) throws { try PipelineSQL.execute(requireRecallConnection(), sql) }
    func retentionCommandTestCount(_ table: String) throws -> Int64 {
        try PipelineSQL.integers(requireRecallConnection(), "SELECT COUNT(*) FROM \(table)").first ?? 0
    }
}
