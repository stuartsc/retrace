import Foundation
import Database
import Shared
import XCTest
@testable import App

final class RetentionCommandServiceTests: XCTestCase {
    func testExistingFilesAreExplicitlyDeferredWhileExactScreenRowsAreDeleted() async throws {
        let fixture = try await RetentionCommandFixture.make(file: Data([1, 2, 3]))
        let preview = try await fixture.owner.preview(clientID: fixture.client, cutoff: fixture.cutoff)
        XCTAssertEqual(preview.frames, 1); XCTAssertEqual(preview.videoCandidates, 1)
        XCTAssertTrue(preview.fileDeletionDeferred); XCTAssertTrue(preview.retainsAudio)
        let result = try await fixture.owner.execute(preview: preview, clientID: fixture.client, commandFence: .init())
        XCTAssertEqual(result.deletedFrames, 1); XCTAssertEqual(result.deletedSessions, 1)
        XCTAssertEqual(result.pendingVideoFiles, 1); XCTAssertEqual(result.deletedVideoRows, 0)
        XCTAssertEqual(result.reclaimedBytes, 0); XCTAssertTrue(result.partial)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("chunks/authored")), Data([1, 2, 3]))
        let video = try await fixture.database.getVideoSegment(id: .init(value: fixture.videoID))
        XCTAssertNotNil(video, "Deferred files retain their durable cleanup row")
        try await fixture.close()
    }

    func testAlreadyMissingFilesPermitGuardedVideoRowCleanup() async throws {
        let fixture = try await RetentionCommandFixture.make()
        let preview = try await fixture.owner.preview(clientID: fixture.client, cutoff: fixture.cutoff)
        let result = try await fixture.owner.execute(preview: preview, clientID: fixture.client, commandFence: .init())
        XCTAssertEqual(result.deletedFrames, 1); XCTAssertEqual(result.deletedVideoRows, 1)
        XCTAssertEqual(result.pendingVideoFiles, 0); XCTAssertEqual(result.reclaimedBytes, 0)
        XCTAssertFalse(result.partial)
        let video = try await fixture.database.getVideoSegment(id: .init(value: fixture.videoID))
        XCTAssertNil(video)
        try await fixture.close()
    }

    func testFileAppearingAfterPreviewRemainsWithItsVideoRow() async throws {
        let fixture = try await RetentionCommandFixture.make()
        let preview = try await fixture.owner.preview(clientID: fixture.client, cutoff: fixture.cutoff)
        try Data([9]).write(to: fixture.root.appendingPathComponent("chunks/authored.mp4"))
        let result = try await fixture.owner.execute(preview: preview, clientID: fixture.client, commandFence: .init())
        XCTAssertEqual(result.deletedVideoRows, 0); XCTAssertEqual(result.pendingVideoFiles, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("chunks/authored.mp4")), Data([9]))
        let video = try await fixture.database.getVideoSegment(id: .init(value: fixture.videoID))
        XCTAssertNotNil(video)
        try await fixture.close()
    }

    func testClientMismatchAndPolicyABAInvalidatePreviewWithoutDeletion() async throws {
        let fixture = try await RetentionCommandFixture.make()
        let preview = try await fixture.owner.preview(clientID: fixture.client, cutoff: fixture.cutoff)
        do { _ = try await fixture.owner.execute(preview: preview, clientID: UUID().uuidString, commandFence: .init()); XCTFail("Wrong client") }
        catch RetentionCommandError.stalePreview { }
        fixture.owner.invalidate()
        do { _ = try await fixture.owner.execute(preview: preview, clientID: fixture.client, commandFence: .init()); XCTFail("Policy epoch was revoked") }
        catch is CancellationError { }
        let frame = try await fixture.database.getFrame(id: .init(value: fixture.frameID))
        XCTAssertNotNil(frame)
        try await fixture.close()
    }

    func testCancellationAfterCommitJoinsDrainAndReportsCommittedCounts() async throws {
        let gate = RetentionCommandGate(), fixture = try await RetentionCommandFixture.make(drain: { await gate.wait() })
        let preview = try await fixture.owner.preview(clientID: fixture.client, cutoff: fixture.cutoff)
        let operation = Task { try await fixture.owner.execute(preview: preview, clientID: fixture.client, commandFence: .init()) }
        try await gate.entered()
        let frame = try await fixture.database.getFrame(id: .init(value: fixture.frameID))
        XCTAssertNil(frame, "Database commit precedes the joined output drain")
        operation.cancel()
        let completion = RetentionCommandCompletion()
        let closing = Task { await fixture.owner.close(); await completion.mark() }
        await Task.yield()
        let premature = await completion.finished
        XCTAssertFalse(premature)
        await gate.release()
        let result = try await operation.value
        XCTAssertEqual(result.deletedFrames, 1); XCTAssertTrue(result.partial)
        await closing.value
        do { _ = try await fixture.owner.preview(clientID: fixture.client, cutoff: fixture.cutoff); XCTFail("Terminal close") }
        catch RetentionCommandError.closed { }
        try await fixture.close()
    }

    func testContinuationReachesMissingVideoBeyondOneHundredDeferredFiles() async throws {
        let fixture = try await RetentionCommandFixture.make(file: Data([1, 2, 3]))
        for index in 1...100 {
            let path = "chunks/later-\(index)"
            _ = try await fixture.addVideo(path: path)
            if index < 100 { try Data([1]).write(to: fixture.root.appendingPathComponent(path)) }
        }
        let first = try await fixture.owner.preview(clientID: fixture.client, cutoff: fixture.cutoff)
        XCTAssertEqual(first.videoCandidates, 100); XCTAssertEqual(first.deferredVideoFiles, 100)
        XCTAssertEqual(first.scannedVideos, 100); XCTAssertTrue(first.hasMore)
        let firstOutcome = try await fixture.owner.execute(preview: first, clientID: fixture.client, commandFence: .init())
        XCTAssertEqual(firstOutcome.pendingVideoFiles, 100)
        let second = try await fixture.owner.preview(clientID: fixture.client, cutoff: fixture.cutoff,
            continuationID: XCTUnwrap(first.nextContinuationID))
        XCTAssertEqual(second.frames, 0); XCTAssertEqual(second.videoCandidates, 1)
        XCTAssertEqual(second.scannedVideos, 1); XCTAssertEqual(second.deferredVideoFiles, 0)
        XCTAssertFalse(second.hasMore); XCTAssertNil(second.nextContinuationID)
        let secondOutcome = try await fixture.owner.execute(preview: second, clientID: fixture.client, commandFence: .init())
        XCTAssertEqual(secondOutcome.deletedVideoRows, 1); XCTAssertEqual(secondOutcome.pendingVideoFiles, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("chunks/authored")), Data([1, 2, 3]))
        let firstVideo = try await fixture.database.getVideoSegment(id: .init(value: fixture.videoID))
        XCTAssertNotNil(firstVideo, "A later page must not reclaim earlier deferred media")
        try await fixture.close()
    }

    func testContinuationIsClientAndCutoffBoundAndSupersedesEarlierConfirmation() async throws {
        let fixture = try await RetentionCommandFixture.make()
        for index in 1...100 { _ = try await fixture.addVideo(path: "chunks/page-\(index)") }
        let first = try await fixture.owner.preview(clientID: fixture.client, cutoff: fixture.cutoff)
        let token = try XCTUnwrap(first.nextContinuationID)
        do {
            _ = try await fixture.owner.preview(clientID: "different-client", cutoff: fixture.cutoff, continuationID: token)
            XCTFail("A different client cannot use the discovery token")
        } catch RetentionCommandError.stalePreview { }
        do {
            _ = try await fixture.owner.preview(clientID: fixture.client, cutoff: fixture.cutoff.addingTimeInterval(1), continuationID: token)
            XCTFail("A token cannot broaden the cutoff")
        } catch RetentionCommandError.stalePreview { }
        _ = try await fixture.owner.preview(clientID: fixture.client, cutoff: fixture.cutoff, continuationID: token)
        do {
            _ = try await fixture.owner.execute(preview: first, clientID: fixture.client, commandFence: .init())
            XCTFail("Advancing discovery supersedes the earlier unexecuted preview")
        } catch RetentionCommandError.stalePreview { }
        do {
            _ = try await fixture.owner.preview(clientID: fixture.client, cutoff: fixture.cutoff, continuationID: token)
            XCTFail("Discovery tokens are consumed once")
        } catch RetentionCommandError.stalePreview { }
        let frame = try await fixture.database.getFrame(id: .init(value: fixture.frameID))
        XCTAssertNotNil(frame, "Paging does not confirm deletion")
        try await fixture.close()
    }

    func testVideoABAWhileOutputDrainIsHeldPreservesChangedVideoAndCleansOtherCandidate() async throws {
        let gate = RetentionCommandGate(), fixture = try await RetentionCommandFixture.make(drain: { await gate.wait() })
        let other = try await fixture.addVideo(path: "chunks/unchanged")
        let preview = try await fixture.owner.preview(clientID: fixture.client, cutoff: fixture.cutoff)
        let operation = Task { try await fixture.owner.execute(preview: preview, clientID: fixture.client, commandFence: .init()) }
        try await gate.entered()
        try await fixture.database.markVideoFinalized(id: fixture.videoID, frameCount: 1, fileSize: 4)
        try await fixture.database.markVideoFinalized(id: fixture.videoID, frameCount: 1, fileSize: 3)
        await gate.release()
        let result = try await operation.value
        XCTAssertEqual(result.deletedFrames, 1); XCTAssertEqual(result.deletedVideoRows, 1)
        XCTAssertEqual(result.pendingVideoFiles, 1); XCTAssertTrue(result.partial)
        let changed = try await fixture.database.getVideoSegment(id: .init(value: fixture.videoID))
        let unchanged = try await fixture.database.getVideoSegment(id: .init(value: other))
        XCTAssertNotNil(changed); XCTAssertNil(unchanged)
        try await fixture.close()
    }
}

private struct RetentionCommandFixture {
    let root: URL
    let database: DatabaseManager
    let owner: RetentionCommandService
    let client: String
    let cutoff: Date
    let frameID: Int64
    let videoID: Int64
    static func make(file: Data? = nil, drain: @escaping @Sendable () async -> Void = {}) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RetentionCommandService-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chunks"), withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        if let file { try file.write(to: root.appendingPathComponent("chunks/authored")) }
        let database = DatabaseManager(databasePath: "file:retention_service_\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let cutoff = Date(timeIntervalSince1970: 1_780_000_000), date = cutoff.addingTimeInterval(-10)
        let video = try await database.insertVideoSegment(.init(id: .init(value: 0), startTime: date, endTime: date,
            frameCount: 1, fileSizeBytes: 3, relativePath: "chunks/authored", width: 64, height: 64))
        try await database.markVideoFinalized(id: video, frameCount: 1, fileSize: 3)
        let segment = try await database.insertSegment(bundleID: "com.authored.retention", startDate: date, endDate: date,
            windowName: "Authored fixture", browserUrl: nil, type: 0)
        let frame = try await database.insertFrame(.init(id: .init(value: 0), timestamp: date, segmentID: .init(value: segment),
            videoID: .init(value: video), frameIndexInSegment: 0, metadata: .init(appBundleID: "com.authored.retention")))
        let state = NativeCaptureState(config: Shared.CaptureConfig(), revision: UUID())
        let owner = RetentionCommandService(database: database, captureState: { state }, retentionPolicy: { .init() },
            storageRoot: { root }, drainOutput: drain)
        return .init(root: root, database: database, owner: owner, client: UUID().uuidString, cutoff: cutoff, frameID: frame, videoID: video)
    }
    func close() async throws {
        await owner.close(); try await database.close(); try FileManager.default.removeItem(at: root)
    }
    func addVideo(path: String) async throws -> Int64 {
        let date = cutoff.addingTimeInterval(-10)
        let id = try await database.insertVideoSegment(.init(id: .init(value: 0), startTime: date, endTime: date,
            frameCount: 1, fileSizeBytes: 3, relativePath: path, width: 64, height: 64))
        try await database.markVideoFinalized(id: id, frameCount: 1, fileSize: 3)
        return id
    }
}

private actor RetentionCommandGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var observed = false
    private var released = false
    func wait() async {
        guard !released else { return }
        observed = true; await withCheckedContinuation { waiting = $0 }
    }
    func release() { released = true; waiting?.resume(); waiting = nil }
    func entered() async throws {
        for _ in 0..<400 {
            if observed { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RetentionCommandError.unavailable
    }
}
private actor RetentionCommandCompletion {
    var finished = false
    func mark() { finished = true }
}
