import Foundation
import XCTest
import Shared
import Database
@testable import Storage

final class WALRecoveryTests: XCTestCase {
    func testLiveSessionOwnershipIsNotInferredFromRetainedJournalFiles() async throws {
        let root = try temporaryRoot()
        let manager = WALManager(walRoot: root)
        let id = VideoSegmentID(value: 110)
        let session = try await manager.createSession(videoID: id)
        let isLive = await manager.isLiveSession(videoID: id)
        XCTAssertTrue(isLive)
        let reopened = WALManager(walRoot: root)
        let retainedIsLive = await reopened.isLiveSession(videoID: id)
        XCTAssertFalse(retainedIsLive, "A retained journal is not proof that a writer will append more pixels")
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.framesURL.path))
        try await manager.finalizeSession(session)
        let deletedIsLive = await manager.isLiveSession(videoID: id)
        XCTAssertFalse(deletedIsLive)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WALRecoveryTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func frame(at timestamp: Date = Date(), value: UInt8 = 0) -> CapturedFrame {
        CapturedFrame(timestamp: timestamp, imageData: Data(repeating: value, count: 64 * 64 * 4),
                      width: 64, height: 64, bytesPerRow: 256,
                      metadata: FrameMetadata(appBundleID: "com.retrace.recovery-test", windowName: "Recovery Δ", displayID: 1))
    }

    func testStreamingRecoveryEncodesValidSparseWALAbove512MiB() async throws {
        let root = try temporaryRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: StorageConfig(storageRootPath: root.path))
        let manager = await storage.getWALManager()
        let session = try await manager.createSession(videoID: VideoSegmentID(value: 101))
        let handle = try FileHandle(forWritingTo: session.framesURL)
        defer { try? handle.close() }
        // Real WAL headers with sparse zero-filled 4K BGRA payloads: >512 MiB logically,
        // while the test neither allocates nor physically writes the whole archive.
        let pixelBytes: UInt32 = 4096 * 2048 * 4
        for index in 0..<17 {
            var header = Data()
            var timestamp = Double(1_700_000_000 + index)
            withUnsafeBytes(of: &timestamp) { header.append(contentsOf: $0) }
            for field: UInt32 in [4096, 2048, 4096 * 4, pixelBytes, 1] {
                var value = field
                withUnsafeBytes(of: &value) { header.append(contentsOf: $0) }
            }
            header.append(Data(repeating: 0, count: 8))
            try handle.write(contentsOf: header)
            try handle.seek(toOffset: handle.offset() + UInt64(pixelBytes))
        }
        try handle.truncate(atOffset: handle.offset())
        let reader = try WALRecoveryReader(session: session)
        let scan = try await reader.scan()
        XCTAssertGreaterThan(scan.sourceSize, UInt64(512 * 1024 * 1024))
        XCTAssertEqual(scan.frameCount, 17)
        XCTAssertNil(scan.tailError)
        let record = try await reader.readRecord(at: UInt64(16) * (UInt64(pixelBytes) + 36), index: 16, loadPixels: true)
        XCTAssertEqual(record?.frame.imageData.count, Int(pixelBytes))
        XCTAssertEqual(record?.frame.timestamp, Date(timeIntervalSince1970: 1_700_000_016))
        let database = DatabaseManager(databasePath: root.appendingPathComponent("test.db").path)
        try await database.initialize()
        let recovery = RecoveryManager(walManager: WALManager(walRoot: root.appendingPathComponent("wal")), storage: storage, database: database)
        await recovery.setFrameEnqueueCallback { _ in }
        let result = try await recovery.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 17)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.framesURL.path))
        let frames = try await database.getFrames(from: .distantPast, to: .distantFuture, limit: 20)
        XCTAssertEqual(frames.count, 17)
        XCTAssertEqual(Set(frames.map(\.frameIndexInSegment)), Set(0..<17))
        try await database.close()
    }

    func testTruncatedHeaderRetainsCompletePrefixAndReportsTail() async throws {
        let root = try temporaryRoot()
        let manager = WALManager(walRoot: root)
        var session = try await manager.createSession(videoID: VideoSegmentID(value: 102))
        try await manager.appendFrame(frame(), to: &session)
        let reading = try FileHandle(forReadingFrom: session.framesURL)
        let completeSize = try reading.seekToEnd()
        try reading.close()
        let handle = try FileHandle(forWritingTo: session.framesURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1, 2, 3]))
        try handle.close()
        let scan = try await WALRecoveryReader(session: session).scan()
        XCTAssertEqual(scan.frameCount, 1)
        XCTAssertEqual(scan.completeBytes, completeSize)
        XCTAssertNotNil(scan.tailError)
    }

    func testTruncatedPixelsAndCorruptLengthDoNotAllocateUntrustedPayload() async throws {
        let root = try temporaryRoot()
        let manager = WALManager(walRoot: root)
        var session = try await manager.createSession(videoID: VideoSegmentID(value: 103))
        try await manager.appendFrame(frame(), to: &session)
        var data = try Data(contentsOf: session.framesURL)
        try data.dropLast(1).write(to: session.framesURL)
        let truncated = try await WALRecoveryReader(session: session).scan()
        XCTAssertEqual(truncated.frameCount, 0)
        XCTAssertNotNil(truncated.tailError)
        data.replaceSubrange(20..<24, with: [255, 255, 255, 255])
        try data.write(to: session.framesURL)
        let corrupt = try await WALRecoveryReader(session: session).scan()
        XCTAssertEqual(corrupt.frameCount, 0)
        XCTAssertNotNil(corrupt.tailError)
    }

    func testFrameIDMapSurvivesPartialFinalRecordWithoutTimestampMatching() async throws {
        let root = try temporaryRoot()
        let manager = WALManager(walRoot: root)
        var session = try await manager.createSession(videoID: VideoSegmentID(value: 104))
        let timestamp = Date()
        try await manager.appendFrame(frame(at: timestamp), to: &session)
        try await manager.appendFrame(frame(at: timestamp, value: 20), to: &session)
        try await manager.registerFrameID(videoID: session.videoID, frameID: 501, frameIndex: 0)
        try await manager.registerFrameID(videoID: session.videoID, frameID: 502, frameIndex: 1)
        let handle = try FileHandle(forWritingTo: session.sessionDir.appendingPathComponent("frame_id_map.bin"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1, 2]))
        try handle.close()
        let reader = try WALRecoveryReader(session: session)
        let first = try await reader.readRecord(at: 0, index: 0, loadPixels: false)
        let second = try await reader.readRecord(at: XCTUnwrap(first).nextOffset, index: 1, loadPixels: false)
        XCTAssertEqual(first?.databaseFrameID, 501)
        XCTAssertEqual(second?.databaseFrameID, 502)
        XCTAssertEqual(second?.frame.metadata.windowName, "Recovery Δ")
    }

    func testRecoveryRestartAfterEnqueueFailureReusesVideoAndDatabaseFrames() async throws {
        let root = try temporaryRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: StorageConfig(storageRootPath: root.path))
        let database = DatabaseManager(databasePath: root.appendingPathComponent("test.db").path)
        try await database.initialize()
        let wal = await storage.getWALManager()
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 105))
        let timestamp = Date().addingTimeInterval(-100)
        for index in 0..<151 {
            try await wal.appendFrame(frame(at: timestamp.addingTimeInterval(Double(index)), value: UInt8((index % 10) * 20)), to: &session)
        }
        let recoveryWAL = WALManager(walRoot: root.appendingPathComponent("wal"))
        let firstRecovery = RecoveryManager(walManager: recoveryWAL, storage: storage, database: database)
        await firstRecovery.setFrameEnqueueCallback { _ in throw TestFailure.enqueue }
        let failed = try await firstRecovery.recoverAll()
        XCTAssertEqual(failed.sessionsRecovered, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.framesURL.path))
        let countBefore = try await database.getFrameCount()
        XCTAssertEqual(countBefore, 150)
        let videosBefore = try await database.getVideoSegments(from: .distantPast, to: .distantFuture)
        let alreadyIndexedFrames = try await database.getFrames(from: .distantPast, to: .distantFuture, limit: 1)
        let alreadyIndexed = try XCTUnwrap(alreadyIndexedFrames.first)
        _ = try await database.commitFrameOCR(frameID: alreadyIndexed.id,
            text: ExtractedText(frameID: alreadyIndexed.id, timestamp: alreadyIndexed.timestamp, regions: [
                TextRegion(frameID: alreadyIndexed.id, text: "Previously indexed evidence", bounds: CGRect(x: 0, y: 0, width: 1, height: 1))]),
            frameWidth: 64, frameHeight: 64)
        let secondRecovery = RecoveryManager(walManager: recoveryWAL, storage: storage, database: database)
        let delivered = RecoveredIDs()
        await secondRecovery.setFrameEnqueueCallback { await delivered.append($0) }
        let recovered = try await secondRecovery.recoverAll()
        XCTAssertEqual(recovered.sessionsRecovered, 1)
        let countAfter = try await database.getFrameCount()
        let videosAfter = try await database.getVideoSegments(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(countAfter, 151)
        XCTAssertEqual(videosAfter.count, 2)
        XCTAssertTrue(Set(videosBefore.map(\.id)).isSubset(of: Set(videosAfter.map(\.id))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.framesURL.path))
        let ids = await delivered.ids
        XCTAssertEqual(Set(ids).count, 150)
        XCTAssertFalse(ids.contains(alreadyIndexed.id.value))
        let statuses = try await database.getFrameProcessingStatuses(frameIDs: [alreadyIndexed.id.value])
        XCTAssertEqual(statuses[alreadyIndexed.id.value], 2)
        try await database.close()
    }

    func testCancellingRecoveryOwnerRetainsWALAndRetryReusesPublishedFrameAndVideo() async throws {
        let root = try temporaryRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: StorageConfig(storageRootPath: root.path))
        let database = DatabaseManager(databasePath: root.appendingPathComponent("test.db").path)
        try await database.initialize()
        let captureWAL = await storage.getWALManager()
        var session = try await captureWAL.createSession(videoID: VideoSegmentID(value: 108))
        try await captureWAL.appendFrame(frame(at: Date().addingTimeInterval(-100)), to: &session)
        let recoveryWAL = WALManager(walRoot: root.appendingPathComponent("wal"))
        let recovery = RecoveryManager(walManager: recoveryWAL, storage: storage, database: database)
        let callbackStarted = expectation(description: "Recovery published its chunk and entered OCR enqueue")
        await recovery.setFrameEnqueueCallback { _ in
            callbackStarted.fulfill()
            // A callback may consume cancellation. Recovery must still check
            // its task before marking the journal complete or deleting the WAL.
            try? await Task.sleep(for: .seconds(2), clock: .continuous)
        }

        let owner = Task { try await recovery.recoverAll() }
        await fulfillment(of: [callbackStarted], timeout: 10)
        owner.cancel()
        do {
            _ = try await owner.value
            XCTFail("Cancelling the recovery owner must cancel its coalesced work")
        } catch is CancellationError {
            // Expected: the original WAL remains the source of truth for retry.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: session.framesURL.path))
        let framesBefore = try await database.getFrames(from: .distantPast, to: .distantFuture, limit: 10)
        let videosBefore = try await database.getVideoSegments(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(framesBefore.count, 1)
        XCTAssertEqual(videosBefore.count, 1)
        let journalURL = session.sessionDir.appendingPathComponent("recovery-progress.json")
        if FileManager.default.fileExists(atPath: journalURL.path) {
            let journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
            let chunks = try XCTUnwrap(journal["chunks"] as? [[String: Any]])
            XCTAssertEqual(chunks.first?["committed"] as? Bool, false)
        } else {
            XCTFail("Cancellation must retain the recovery checkpoint")
        }

        let retry = RecoveryManager(walManager: recoveryWAL, storage: storage, database: database)
        let delivered = RecoveredIDs()
        await retry.setFrameEnqueueCallback { await delivered.append($0) }
        let result = try await retry.recoverAll()
        let framesAfter = try await database.getFrames(from: .distantPast, to: .distantFuture, limit: 10)
        let videosAfter = try await database.getVideoSegments(from: .distantPast, to: .distantFuture)
        let deliveredIDs = await delivered.ids
        XCTAssertEqual(result.sessionsRecovered, 1)
        XCTAssertEqual(result.framesRecovered, 1)
        XCTAssertEqual(result.videoSegmentsCreated, 0, "Retry must reuse the already verified HEVC output")
        XCTAssertEqual(framesAfter.map(\.id), framesBefore.map(\.id))
        XCTAssertEqual(videosAfter.map(\.id), videosBefore.map(\.id))
        XCTAssertEqual(deliveredIDs, framesBefore.map { $0.id.value })
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.framesURL.path))
        try await database.close()
    }

    func testAlreadyCancelledRecoveryDoesNotPublishOrRemoveWAL() async throws {
        let root = try temporaryRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: StorageConfig(storageRootPath: root.path))
        let database = DatabaseManager(databasePath: root.appendingPathComponent("test.db").path)
        try await database.initialize()
        let captureWAL = await storage.getWALManager()
        var session = try await captureWAL.createSession(videoID: VideoSegmentID(value: 109))
        try await captureWAL.appendFrame(frame(), to: &session)
        let recovery = RecoveryManager(walManager: WALManager(walRoot: root.appendingPathComponent("wal")), storage: storage, database: database)
        await recovery.setFrameEnqueueCallback { _ in }

        let owner = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await recovery.recoverAll()
        }
        do {
            _ = try await owner.value
            XCTFail("A pre-cancelled caller must not start recovery")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let count = try await database.getFrameCount()
        XCTAssertEqual(count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.framesURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.sessionDir.appendingPathComponent("recovery-progress.json").path))
        try await database.close()
    }

    func testRecoveryPublishesCompletePrefixButRetainsTruncatedTailOnRepeatedLaunch() async throws {
        let root = try temporaryRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: StorageConfig(storageRootPath: root.path))
        let database = DatabaseManager(databasePath: root.appendingPathComponent("test.db").path)
        try await database.initialize()
        let wal = await storage.getWALManager()
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 106))
        try await wal.appendFrame(frame(), to: &session)
        let handle = try FileHandle(forWritingTo: session.framesURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1, 2, 3]))
        try handle.close()
        for _ in 0..<2 {
            let recovery = RecoveryManager(walManager: WALManager(walRoot: root.appendingPathComponent("wal")), storage: storage, database: database)
            await recovery.setFrameEnqueueCallback { _ in }
            let result = try await recovery.recoverAll()
            XCTAssertEqual(result.sessionsRecovered, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: session.framesURL.path))
            let count = try await database.getFrameCount()
            XCTAssertEqual(count, 1)
        }
        try await database.close()
    }

    func testLiveSessionIsExcludedButFreshManagerFindsPriorProcessSession() async throws {
        let root = try temporaryRoot()
        let wal = WALManager(walRoot: root)
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 107))
        try await wal.appendFrame(frame(), to: &session)
        let active = try await wal.listActiveSessions()
        let recoverable = try await wal.listRecoverableSessions()
        XCTAssertEqual(active.map(\.videoID), [session.videoID])
        XCTAssertTrue(recoverable.isEmpty)
        let previousProcessSessions = try await WALManager(walRoot: root).listRecoverableSessions()
        XCTAssertEqual(previousProcessSessions.map(\.videoID), [session.videoID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.framesURL.path))
    }

    private enum TestFailure: Error { case enqueue }
    private actor RecoveredIDs {
        var ids: [Int64] = []
        func append(_ values: [Int64]) { ids.append(contentsOf: values) }
    }
}
