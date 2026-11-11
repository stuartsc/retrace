import Foundation
import XCTest
import Shared
import Database
@testable import Storage

final class OriginalFrameSpoolTests: XCTestCase {
    func testCorruptSessionDoesNotPreventIndependentAcknowledgedCleanup() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.storage.confirmOriginalArchive(video: fixture.video)
        _ = try await fixture.database.commitFrameOCR(frameID: fixture.frame.id,
            text: ExtractedText(frameID: fixture.frame.id, timestamp: fixture.frame.timestamp, regions: []),
            frameWidth: 64, frameHeight: 64)
        let wal = await fixture.storage.getWALManager()
        var damaged = try await wal.createSession(videoID: VideoSegmentID(value: 700))
        try await wal.appendFrame(frame(), to: &damaged)
        try await wal.finalizeSession(damaged)
        try Data("invalid receipt".utf8).write(to: damaged.sessionDir.appendingPathComponent("original-retention.json"))
        _ = try await fixture.storage.reconcileOriginalSpool { frameID in
            try await fixture.database.originalFrameDisposition(frameID: frameID)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.framesURL.path),
            "A damaged neighbour must not hold independently acknowledged originals")
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.framesURL.path),
            "Unproved originals remain retained")
        try await fixture.database.close()
    }

    func testFinalizationKeepsExactOriginalUntilArchiveAndDurableExtractionAreConfirmed() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try await fixture.storage.readOriginalFrameForProcessing(sourceStoreID: fixture.storeID,
            frame: fixture.frame, expectedWidth: 64, expectedHeight: 64)
        XCTAssertEqual(source?.imageData, fixture.pixels.imageData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.framesURL.path))

        _ = try await fixture.database.commitFrameOCR(frameID: fixture.frame.id,
            text: ExtractedText(frameID: fixture.frame.id, timestamp: fixture.frame.timestamp, regions: []),
            frameWidth: 64, frameHeight: 64)
        let extracted: @Sendable (FrameID) async throws -> OriginalFrameDisposition = { _ in
            .extracted(storeID: fixture.storeID, frame: fixture.frame, archive: fixture.video)
        }
        _ = try await fixture.storage.reconcileOriginalSpool(disposition: extracted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.framesURL.path),
                      "Durable blank OCR does not prove the archive mapping")
        try await fixture.storage.confirmOriginalArchive(video: fixture.video)
        _ = try await fixture.storage.reconcileOriginalSpool { _ in .pending }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.framesURL.path),
                      "An archive receipt does not prove extraction has committed")

        let reopened = StorageManager(storageRoot: fixture.root)
        try await reopened.initialize(config: StorageConfig(storageRootPath: fixture.root.path))
        _ = try await reopened.reconcileOriginalSpool(disposition: extracted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.framesURL.path))
        let missing = try await reopened.readOriginalFrameForProcessing(sourceStoreID: fixture.storeID,
            frame: fixture.frame, expectedWidth: 64, expectedHeight: 64)
        XCTAssertNil(missing)
        try await fixture.database.close()
    }

    func testCancellationKeepsPersistedPixelsRecoverableAndReleasesLiveOwnership() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: StorageConfig(storageRootPath: root.path))
        let writer = try await storage.createSegmentWriter()
        let id = await writer.segmentID
        let pixels = frame()
        try await writer.appendFrame(pixels)
        try await writer.cancel()
        let wal = await storage.getWALManager()
        let live = await wal.isLiveSession(videoID: id)
        XCTAssertFalse(live)
        let sessions = try await WALManager(walRoot: root.appendingPathComponent("wal")).listRecoverableSessions()
        XCTAssertEqual(sessions.map(\.videoID), [id])
        let retained = try await wal.readFrame(videoID: id, frameIndex: 0)
        XCTAssertEqual(retained.imageData, pixels.imageData)
    }

    func testChangedArchiveMappingCannotReleaseOriginals() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.storage.confirmOriginalArchive(video: fixture.video)
        let wrong = FrameReference(id: fixture.frame.id,
            timestamp: fixture.frame.timestamp.addingTimeInterval(1), segmentID: fixture.frame.segmentID,
            videoID: fixture.frame.videoID, frameIndexInSegment: fixture.frame.frameIndexInSegment,
            metadata: fixture.frame.metadata, source: .native)
        _ = try await fixture.storage.reconcileOriginalSpool { _ in
            .extracted(storeID: fixture.storeID, frame: wrong, archive: fixture.video)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.framesURL.path))
        let wrongVideo = VideoSegment(id: VideoSegmentID(value: fixture.video.id.value + 100),
            startTime: fixture.video.startTime, endTime: fixture.video.endTime,
            frameCount: fixture.video.frameCount, fileSizeBytes: fixture.video.fileSizeBytes,
            relativePath: fixture.video.relativePath, width: fixture.video.width, height: fixture.video.height)
        _ = try await fixture.storage.reconcileOriginalSpool { _ in
            .extracted(storeID: fixture.storeID, frame: fixture.frame, archive: wrongVideo)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.framesURL.path))
        try await fixture.database.close()
    }

    func testSpoolCeilingRejectsBeforeAppendAndNeverEvictsPendingOriginals() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let wal = WALManager(walRoot: root, maximumSpoolBytes: 24_000, minimumFreeBytes: 0,
                             availableBytes: { Int64.max })
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 700))
        try await wal.appendFrame(frame(), to: &session)
        let before = try Data(contentsOf: session.framesURL)
        do {
            try await wal.appendFrame(frame(value: 180), to: &session)
            XCTFail("The second original must exceed the injected spool ceiling")
        } catch let pressure as OriginalSpoolPressure {
            guard case .capacityLimit = pressure else { return XCTFail("Wrong pressure: \(pressure)") }
        }
        XCTAssertEqual(try Data(contentsOf: session.framesURL), before)
        XCTAssertEqual(session.metadata.frameCount, 1)
        let reopened = WALManager(walRoot: root)
        let preserved = try await reopened.readFrame(videoID: session.videoID, frameIndex: 0)
        XCTAssertEqual(preserved.imageData, frame().imageData)
    }

    func testFreeSpaceHeadroomRejectsBeforeWritingAnyPixel() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let headroom: Int64 = 20 * 1024 * 1024 * 1024
        let wal = WALManager(walRoot: root, maximumSpoolBytes: 5 * 1024 * 1024 * 1024,
                             minimumFreeBytes: headroom, availableBytes: { headroom + 100 })
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 701))
        do {
            try await wal.appendFrame(frame(), to: &session)
            XCTFail("Capture must preserve the free-space headroom")
        } catch let pressure as OriginalSpoolPressure {
            guard case .freeSpaceHeadroom = pressure else { return XCTFail("Wrong pressure: \(pressure)") }
        }
        XCTAssertEqual(try Data(contentsOf: session.framesURL).count, 0)
        XCTAssertEqual(session.metadata.frameCount, 0)
    }

    func testFreeSpaceHeadroomIncludesFutureAcknowledgementReserve() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pixels = frame()
        let metadataBytes = try JSONEncoder().encode(pixels.metadata).count
        let rawBytes = Int64(pixels.imageData.count + 76 + metadataBytes)
        let headroom: Int64 = 20 * 1024 * 1024 * 1024
        let wal = WALManager(walRoot: root, minimumFreeBytes: headroom,
                             availableBytes: { headroom + rawBytes })
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 702))
        do {
            try await wal.appendFrame(pixels, to: &session)
            XCTFail("Raw pixels fitting exactly cannot spend space reserved for their durable acknowledgement")
        } catch let pressure as OriginalSpoolPressure {
            guard case .freeSpaceHeadroom = pressure else { return XCTFail("Wrong pressure: \(pressure)") }
        }
        XCTAssertTrue(try Data(contentsOf: session.framesURL).isEmpty)
        XCTAssertEqual(session.metadata.frameCount, 0)
    }

    func testQuarantinePruningCannotEvictProtectedOriginals() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let wal = WALManager(walRoot: root)
        try await wal.configureOriginalStore(storeID: UUID())
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 703))
        let pixels = frame()
        try await wal.appendFrame(pixels, to: &session)
        try await wal.finalizeSession(session)
        let quarantined = try await wal.quarantineSession(session, reason: "authored recovery failure")
        let source = quarantined.appendingPathComponent("frames.bin")
        let before = try Data(contentsOf: source)
        let result = try await wal.pruneQuarantinedSessions(maxAge: -1, maxBytes: 0)
        XCTAssertEqual(result.deletedSessionCount, 0)
        XCTAssertEqual(try Data(contentsOf: source), before,
                       "Quarantine age and pressure cannot replace durable extraction or deletion evidence")
        let status = try await wal.originalSpoolStatus()
        XCTAssertGreaterThanOrEqual(status.retainedBytes, Int64(before.count))
    }

    func testDeletionTombstoneBlocksOriginalReadAndRecoveryAfterRestart() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.database.deleteFrames(olderThan: fixture.frame.timestamp.addingTimeInterval(1))
        _ = try await fixture.storage.reconcileOriginalSpool { _ in .deleted(storeID: fixture.storeID) }
        let reopened = StorageManager(storageRoot: fixture.root)
        try await reopened.initialize(config: StorageConfig(storageRootPath: fixture.root.path))
        let recovery = RecoveryManager(walManager: await reopened.getWALManager(),
                                       storage: reopened, database: fixture.database)
        await recovery.setFrameEnqueueCallback { _ in }
        _ = try await recovery.recoverAll()
        let count = try await fixture.database.getFrameCount()
        XCTAssertEqual(count, 0, "A deleted mapped original must never become a new recovered frame")
        let source = try await reopened.readOriginalFrameForProcessing(sourceStoreID: fixture.storeID,
            frame: fixture.frame, expectedWidth: 64, expectedHeight: 64)
        XCTAssertNil(source)
        try await fixture.database.close()
    }

    func testRecoveredFrameKeepsOriginalIdentityAcrossNewArchivePathAndRestart() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reopened = StorageManager(storageRoot: fixture.root)
        try await reopened.initialize(config: StorageConfig(storageRootPath: fixture.root.path))
        let recovery = RecoveryManager(walManager: await reopened.getWALManager(),
                                       storage: reopened, database: fixture.database)
        await recovery.setFrameEnqueueCallback { _ in }
        let result = try await recovery.recoverAll()
        XCTAssertEqual(result.sessionsRecovered, 1)
        let saved = try await fixture.database.getFrame(id: fixture.frame.id)
        let remapped = try XCTUnwrap(saved)
        XCTAssertNotEqual(remapped.videoID, fixture.frame.videoID)
        let exact = FrameReference(id: remapped.id, timestamp: remapped.timestamp,
            segmentID: remapped.segmentID, videoID: remapped.videoID,
            frameIndexInSegment: remapped.frameIndexInSegment, metadata: fixture.frame.metadata, source: .native)
        let original = try await reopened.readOriginalFrameForProcessing(sourceStoreID: fixture.storeID, frame: exact, expectedWidth: 64, expectedHeight: 64)
        XCTAssertEqual(original?.imageData, fixture.pixels.imageData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.framesURL.path))
        let videosBefore = try await fixture.database.getVideoSegments(from: .distantPast, to: .distantFuture)
        let next = RecoveryManager(walManager: WALManager(walRoot: fixture.root.appendingPathComponent("wal")),
                                   storage: reopened, database: fixture.database)
        await next.setFrameEnqueueCallback { _ in }
        let repeated = try await next.recoverAll()
        XCTAssertEqual(repeated.sessionsRecovered, 0)
        let videosAfter = try await fixture.database.getVideoSegments(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(videosAfter.map(\.id), videosBefore.map(\.id),
                       "Retained archive sessions must not encode duplicate archives on restart")
        try await fixture.database.close()
    }

    func testReaderCompletionPrecedesCleanupAcrossWALManagerInstances() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.storage.confirmOriginalArchive(video: fixture.video)
        _ = try await fixture.database.commitFrameOCR(frameID: fixture.frame.id,
            text: ExtractedText(frameID: fixture.frame.id, timestamp: fixture.frame.timestamp, regions: []),
            frameWidth: 64, frameHeight: 64)
        let sourceID = try XCTUnwrap(Int64(fixture.framesURL.deletingLastPathComponent().lastPathComponent.split(separator: "_").last ?? ""))
        let reader = WALManager(walRoot: fixture.root.appendingPathComponent("wal"))
        let entered = expectation(description: "Original reader owns a lease")
        let gate = OriginalReaderTestGate()
        let reading = Task {
            try await reader.withOriginalReadLease(videoID: VideoSegmentID(value: sourceID)) {
                entered.fulfill()
                await gate.wait()
                return try await reader.readExactFrame(videoID: VideoSegmentID(value: sourceID),
                    frameID: fixture.frame.id.value, expectedTimestamp: fixture.frame.timestamp,
                    expectedWidth: 64, expectedHeight: 64, expectedDisplayID: 1)
            }
        }
        await fulfillment(of: [entered], timeout: 10)
        let disposition: @Sendable (FrameID) async throws -> OriginalFrameDisposition = { _ in
            .extracted(storeID: fixture.storeID, frame: fixture.frame, archive: fixture.video)
        }
        _ = try await fixture.storage.reconcileOriginalSpool(disposition: disposition)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.framesURL.path))
        await gate.release()
        let pixels = try await reading.value
        XCTAssertEqual(pixels.imageData, fixture.pixels.imageData)
        _ = try await fixture.storage.reconcileOriginalSpool(disposition: disposition)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.framesURL.path))
        try await fixture.database.close()
    }

    func testArchiveDamageAfterAcknowledgementRetainsOriginals() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.storage.confirmOriginalArchive(video: fixture.video)
        let archiveURL = fixture.root.appendingPathComponent(fixture.video.relativePath)
        let file = try FileHandle(forWritingTo: archiveURL)
        try file.truncate(atOffset: 12)
        try file.close()
        _ = try await fixture.storage.reconcileOriginalSpool { _ in
            .extracted(storeID: fixture.storeID, frame: fixture.frame, archive: fixture.video)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.framesURL.path))
        let exact = try await fixture.storage.readOriginalFrameForProcessing(sourceStoreID: fixture.storeID, frame: fixture.frame,
                                                                           expectedWidth: 64, expectedHeight: 64)
        XCTAssertEqual(exact?.imageData, fixture.pixels.imageData)
        try await fixture.database.close()
    }

    func testMissingMappedDatabaseFrameIsNotRepublishedWithoutPriorReconciliation() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.database.deleteFrames(olderThan: fixture.frame.timestamp.addingTimeInterval(1))
        let reopened = StorageManager(storageRoot: fixture.root)
        try await reopened.initialize(config: StorageConfig(storageRootPath: fixture.root.path))
        let recovery = RecoveryManager(walManager: await reopened.getWALManager(),
                                       storage: reopened, database: fixture.database)
        await recovery.setFrameEnqueueCallback { _ in }
        _ = try await recovery.recoverAll()
        let count = try await fixture.database.getFrameCount()
        XCTAssertEqual(count, 0)
        let remaining = try await reopened.readOriginalFrameForProcessing(sourceStoreID: fixture.storeID, frame: fixture.frame,
                                                                         expectedWidth: 64, expectedHeight: 64)
        XCTAssertNil(remaining, "Recovery persists a deletion fence before any retry can disclose mapped pixels")
        try await fixture.database.close()
    }

    func testAnotherDatabaseCannotReadOrAcknowledgeRetainedOriginals() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.storage.confirmOriginalArchive(video: fixture.video)
        let otherStore = UUID()
        let hidden = try await fixture.storage.readOriginalFrameForProcessing(sourceStoreID: otherStore,
            frame: fixture.frame, expectedWidth: 64, expectedHeight: 64)
        XCTAssertNil(hidden)
        _ = try await fixture.storage.reconcileOriginalSpool { _ in .deleted(storeID: otherStore) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.framesURL.path))
        _ = try await fixture.storage.reconcileOriginalSpool { _ in
            .extracted(storeID: otherStore, frame: fixture.frame, archive: fixture.video)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.framesURL.path))
        let visible = try await fixture.storage.readOriginalFrameForProcessing(sourceStoreID: fixture.storeID,
            frame: fixture.frame, expectedWidth: 64, expectedHeight: 64)
        XCTAssertEqual(visible?.imageData, fixture.pixels.imageData)
        try await fixture.database.close()
    }

    func testNewOriginalNamespaceIsInvisibleToLegacyRecoveryEnumeration() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directories = try FileManager.default.contentsOfDirectory(at: fixture.root.appendingPathComponent("wal"),
                                                                       includingPropertiesForKeys: nil)
        XCTAssertTrue(directories.filter { $0.lastPathComponent.hasPrefix("active_segment_") }.isEmpty,
                      "The rollback reader enumerates active_segment_; it must not see new originals")
        XCTAssertEqual(directories.filter { $0.lastPathComponent.hasPrefix("original_segment_") }.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.framesURL.path))
        try await fixture.database.close()
    }

    func testUnboundOriginalCannotBeAdoptedByAnUnrelatedDatabase() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let legacy = WALManager(walRoot: fixture.root.appendingPathComponent("wal"))
        var session = try await legacy.createSession(videoID: VideoSegmentID(value: 777))
        try await legacy.appendFrame(frame(value: 210), to: &session)
        try await legacy.registerFrameID(videoID: session.videoID, frameID: fixture.frame.id.value, frameIndex: 0)
        try await legacy.finalizeSession(session)
        _ = try await fixture.database.deleteFrames(olderThan: fixture.frame.timestamp.addingTimeInterval(1))
        _ = try await fixture.storage.reconcileOriginalSpool { _ in .deleted(storeID: fixture.storeID) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.framesURL.path),
                      "Matching numeric IDs never bind an old journal to a new database")
        let recovery = RecoveryManager(walManager: legacy, storage: fixture.storage, database: fixture.database)
        await recovery.setFrameEnqueueCallback { _ in }
        let result = try await recovery.recoverAll()
        XCTAssertEqual(result.framesRecovered, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.framesURL.path))
        try await fixture.database.close()
    }

    func testDeletionAfterDatabaseInsertBeforeWALMappingCannotReappear() async throws {
        let fixture = try await makeFixture(registerMap: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.database.deleteFrames(olderThan: fixture.frame.timestamp.addingTimeInterval(1))
        let reopened = StorageManager(storageRoot: fixture.root)
        try await reopened.initialize(config: StorageConfig(storageRootPath: fixture.root.path))
        let recovery = RecoveryManager(walManager: await reopened.getWALManager(),
                                       storage: reopened, database: fixture.database)
        await recovery.setFrameEnqueueCallback { _ in }
        _ = try await recovery.recoverAll()
        let count = try await fixture.database.getFrameCount()
        XCTAssertEqual(count, 0, "The atomic SQLite source alias closes the insert-to-WAL-map crash window")
        let original = try await reopened.readOriginalFrameForProcessing(sourceStoreID: fixture.storeID,
            frame: fixture.frame, expectedWidth: 64, expectedHeight: 64)
        XCTAssertNil(original)
        _ = try await reopened.reconcileOriginalSpool { frameID in
            try await fixture.database.originalFrameDisposition(frameID: frameID)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.framesURL.path))
        try await fixture.database.close()
    }

    func testRestartRepairsDeletionReceiptWrittenBeforeFrameMap() async throws {
        let fixture = try await makeFixture(registerMap: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.database.deleteFrame(id: fixture.frame.id)
        let wal = await fixture.storage.getWALManager()
        let sessions = try await wal.listActiveSessions()
        let session = try XCTUnwrap(sessions.first)
        // Reproduce interruption after the deletion receipt's durable write but
        // before frame-ID registration. Recovery must repair this exact gap.
        try await wal.markOriginalDeleted(session: session, storeID: fixture.storeID,
            frameID: fixture.frame.id.value, sourceIndex: 0)
        let reopened = StorageManager(storageRoot: fixture.root)
        try await reopened.initialize(config: StorageConfig(storageRootPath: fixture.root.path))
        let recovery = RecoveryManager(walManager: await reopened.getWALManager(),
            storage: reopened, database: fixture.database)
        await recovery.setFrameEnqueueCallback { _ in XCTFail("Deleted pixels must not be enqueued") }
        _ = try await recovery.recoverAll()
        _ = try await reopened.reconcileOriginalSpool { frameID in
            try await fixture.database.originalFrameDisposition(frameID: frameID)
        }
        let count = try await fixture.database.getFrameCount()
        XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.framesURL.path),
            "The original must not remain held forever by its missing filesystem map")
        try await fixture.database.close()
    }

    func testUnmappedDeletionReceiptCannotClaimAnUnrelatedDeletedFrame() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.database.deleteFrame(id: fixture.frame.id)
        let wal = await fixture.storage.getWALManager()
        var unpublished = try await wal.createSession(videoID: VideoSegmentID(value: 701))
        try await wal.appendFrame(frame(value: 210), to: &unpublished)
        try await wal.finalizeSession(unpublished)
        // A structurally valid receipt cannot assign another source's deleted
        // identity to this unregistered raw record.
        try await wal.markOriginalDeleted(session: unpublished, storeID: fixture.storeID,
            frameID: fixture.frame.id.value, sourceIndex: 0)
        let recovery = RecoveryManager(walManager: wal, storage: fixture.storage, database: fixture.database)
        await recovery.setFrameEnqueueCallback { _ in XCTFail("Ambiguous originals must remain held") }
        _ = try await recovery.recoverAll()
        _ = try await fixture.storage.reconcileOriginalSpool { frameID in
            try await fixture.database.originalFrameDisposition(frameID: frameID)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unpublished.framesURL.path))
        let count = try await fixture.database.getFrameCount()
        XCTAssertEqual(count, 0)
        try await fixture.database.close()
    }

    func testDeletionDuringRecoveryEnqueueCannotReappearOnRetry() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reopened = StorageManager(storageRoot: fixture.root)
        try await reopened.initialize(config: StorageConfig(storageRootPath: fixture.root.path))
        let recovery = RecoveryManager(walManager: await reopened.getWALManager(),
                                       storage: reopened, database: fixture.database)
        await recovery.setFrameEnqueueCallback { _ in
            _ = try await fixture.database.deleteFrames(olderThan: fixture.frame.timestamp.addingTimeInterval(1))
            throw NSError(domain: "OriginalSpoolAuthoredInterruption", code: 1)
        }
        let interrupted = try await recovery.recoverAll()
        XCTAssertEqual(interrupted.sessionsRecovered, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.framesURL.path))
        await recovery.setFrameEnqueueCallback { _ in }
        _ = try await recovery.recoverAll()
        let count = try await fixture.database.getFrameCount()
        XCTAssertEqual(count, 0, "A retry must recheck the deletion committed after the previous archive publication")
        let original = try await reopened.readOriginalFrameForProcessing(sourceStoreID: fixture.storeID,
            frame: fixture.frame, expectedWidth: 64, expectedHeight: 64)
        XCTAssertNil(original)
        _ = try await reopened.reconcileOriginalSpool { frameID in
            try await fixture.database.originalFrameDisposition(frameID: frameID)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.framesURL.path))
        try await fixture.database.close()
    }

    func testPartialDeletionResumesCheckpointedSurvivorsWithoutRemovingPublishedOutput() async throws {
        let fixture = try await makeFixture(frameCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reopened = StorageManager(storageRoot: fixture.root)
        try await reopened.initialize(config: StorageConfig(storageRootPath: fixture.root.path))
        let recovery = RecoveryManager(walManager: await reopened.getWALManager(),
                                       storage: reopened, database: fixture.database)
        await recovery.setFrameEnqueueCallback { _ in
            _ = try await fixture.database.deleteFrames(olderThan: fixture.frame.timestamp.addingTimeInterval(0.5))
            throw NSError(domain: "OriginalSpoolPartialDeletion", code: 1)
        }
        let interrupted = try await recovery.recoverAll()
        XCTAssertEqual(interrupted.sessionsRecovered, 0)
        let survivor = fixture.frames[1]
        let firstPublication = try await fixture.database.getFrame(id: survivor.id)
        let publishedFrame = try XCTUnwrap(firstPublication)
        let firstArchive = try await fixture.database.getVideoSegment(id: publishedFrame.videoID)
        let publishedArchive = try XCTUnwrap(firstArchive)
        XCTAssertNotEqual(publishedArchive.id, fixture.video.id)

        await recovery.setFrameEnqueueCallback { _ in }
        let resumed = try await recovery.recoverAll()
        XCTAssertEqual(resumed.sessionsRecovered, 1)
        XCTAssertEqual(resumed.framesRecovered, 1)
        let after = try await fixture.database.getFrameWithVideoInfoByID(id: survivor.id)
        let current = try XCTUnwrap(after).frame
        XCTAssertNotEqual(current.videoID, publishedArchive.id)
        XCTAssertEqual(current.frameIndexInSegment, 0)
        let currentArchive = try await fixture.database.getVideoSegment(id: current.videoID)
        XCTAssertEqual(currentArchive?.frameCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(publishedArchive.relativePath).path),
                      "An older checkpoint may be published and cannot be removed as an abandoned output")
        let count = try await fixture.database.getFrameCount()
        XCTAssertEqual(count, 1)
        let original = try await reopened.readOriginalFrameForProcessing(sourceStoreID: fixture.storeID,
            frame: current, expectedWidth: 64, expectedHeight: 64)
        XCTAssertEqual(original?.imageData, fixture.capturedFrames[1].imageData)
        _ = try await fixture.database.commitFrameOCR(frameID: survivor.id,
            text: ExtractedText(frameID: survivor.id, timestamp: survivor.timestamp, regions: []),
            frameWidth: 64, frameHeight: 64)
        _ = try await reopened.reconcileOriginalSpool { id in
            try await fixture.database.originalFrameDisposition(frameID: id)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.framesURL.path))
        try await fixture.database.close()
    }

    func testUnrelatedCorruptOriginalDoesNotBlockValidArchiveOnlyFrame() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.storage.confirmOriginalArchive(video: fixture.video)
        _ = try await fixture.database.commitFrameOCR(frameID: fixture.frame.id,
            text: ExtractedText(frameID: fixture.frame.id, timestamp: fixture.frame.timestamp, regions: []),
            frameWidth: 64, frameHeight: 64)
        _ = try await fixture.storage.reconcileOriginalSpool { id in
            try await fixture.database.originalFrameDisposition(frameID: id)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.framesURL.path))
        let foreign = WALManager(walRoot: fixture.root.appendingPathComponent("wal"))
        try await foreign.configureOriginalStore(storeID: UUID())
        var other = try await foreign.createSession(videoID: VideoSegmentID(value: 780))
        try await foreign.appendFrame(frame(value: 220), to: &other)
        try await foreign.registerFrameID(videoID: other.videoID, frameID: fixture.frame.id.value, frameIndex: 0)
        try await foreign.finalizeSession(other)
        try Data("broken receipt".utf8).write(to: other.sessionDir.appendingPathComponent("original-retention.json"))
        let original = try await fixture.storage.readOriginalFrameForProcessing(sourceStoreID: fixture.storeID,
            frame: fixture.frame, expectedWidth: 64, expectedHeight: 64)
        XCTAssertNil(original, "A numeric ID in an unattributable spool cannot invalidate this archive")
        let decoded = try await fixture.storage.readFrameForProcessing(frame: fixture.frame, video: fixture.video)
        XCTAssertEqual(decoded.width, 64)
        XCTAssertEqual(decoded.height, 64)
        XCTAssertFalse(decoded.imageData.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.framesURL.path))
        try await fixture.database.close()
    }

    func testCorruptionForProvedStoreAndFrameStillFailsClosed() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let receipt = fixture.framesURL.deletingLastPathComponent().appendingPathComponent("original-retention.json")
        let malformed = try JSONSerialization.data(withJSONObject: [
            "sourceStoreID": fixture.storeID.uuidString, "version": "invalid"
        ])
        try malformed.write(to: receipt)
        do {
            _ = try await fixture.storage.readOriginalFrameForProcessing(sourceStoreID: fixture.storeID,
                frame: fixture.frame, expectedWidth: 64, expectedHeight: 64)
            XCTFail("A proved original identity cannot silently substitute archived pixels after integrity failure")
        } catch let error as ExactFrameReadError {
            XCTAssertEqual(error, .integrityFailure)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.framesURL.path))
        try await fixture.database.close()
    }

    func testLegacyNamespaceRemainsExactlyReadableWithoutAutomaticStoreAdoption() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let wal = WALManager(walRoot: root)
        var session = try await wal.createSession(videoID: VideoSegmentID(value: 778))
        let pixels = frame(value: 130)
        try await wal.appendFrame(pixels, to: &session)
        try await wal.registerFrameID(videoID: session.videoID, frameID: 55, frameIndex: 0)
        try await wal.finalizeSession(session)
        let legacyURL = root.appendingPathComponent("active_segment_778")
        try FileManager.default.moveItem(at: session.sessionDir, to: legacyURL)
        try FileManager.default.removeItem(at: legacyURL.appendingPathComponent("original-retention.json"))
        let reopened = WALManager(walRoot: root)
        let decoded = try await reopened.readExactFrame(videoID: session.videoID, frameID: 55,
            expectedTimestamp: pixels.timestamp, expectedWidth: 64, expectedHeight: 64, expectedDisplayID: 1)
        XCTAssertEqual(decoded.imageData, pixels.imageData)
        let unrelatedStore = UUID()
        try await reopened.configureOriginalStore(storeID: unrelatedStore)
        _ = try await reopened.reconcileOriginalSpool { _ in .deleted(storeID: unrelatedStore) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.appendingPathComponent("frames.bin").path))
    }

    private struct Fixture: Sendable {
        let root: URL
        let storage: StorageManager
        let database: DatabaseManager
        let storeID: UUID
        let frame: FrameReference
        let pixels: CapturedFrame
        let video: VideoSegment
        let framesURL: URL
        let frames: [FrameReference]
        let capturedFrames: [CapturedFrame]
    }

    private func makeFixture(registerMap: Bool = true, frameCount: Int = 1) async throws -> Fixture {
        let root = temporaryRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: StorageConfig(storageRootPath: root.path))
        let database = DatabaseManager(databasePath: root.appendingPathComponent("test.db").path)
        try await database.initialize()
        let storeID = try await database.originalStoreID()
        try await storage.configureOriginalStore(storeID: storeID)
        let writer = try await storage.createSegmentWriter()
        let pixels = frame()
        let path = await writer.relativePath
        let pathID = await writer.segmentID
        let videoID = try await database.insertVideoSegment(VideoSegment(id: VideoSegmentID(value: 0),
            startTime: pixels.timestamp, endTime: pixels.timestamp, frameCount: 0, fileSizeBytes: 0,
            relativePath: path, width: 64, height: 64))
        let appID = try await database.insertSegment(bundleID: "com.retrace.original-test",
            startDate: pixels.timestamp, endDate: pixels.timestamp, windowName: "Original 42 café",
            browserUrl: nil, type: 0)
        let wal = await storage.getWALManager()
        var frames: [FrameReference] = []
        var capturedFrames: [CapturedFrame] = []
        for index in 0..<frameCount {
            let source = frame(value: UInt8(90 + index * 60))
            let captured = CapturedFrame(timestamp: pixels.timestamp.addingTimeInterval(Double(index)),
                imageData: source.imageData, width: 64, height: 64, bytesPerRow: 256, metadata: source.metadata)
            try await writer.appendFrame(captured)
            let descriptor = FrameReference(id: FrameID(value: 0), timestamp: captured.timestamp,
                segmentID: AppSegmentID(value: appID), videoID: VideoSegmentID(value: videoID),
                frameIndexInSegment: index, metadata: captured.metadata, source: .native)
            let frameID = try await database.insertCapturedFrame(descriptor, originalVideoPathID: pathID)
            if registerMap {
                try await wal.registerFrameID(videoID: pathID, frameID: frameID, frameIndex: index)
            }
            frames.append(FrameReference(id: FrameID(value: frameID), timestamp: captured.timestamp,
                segmentID: descriptor.segmentID, videoID: descriptor.videoID,
                frameIndexInSegment: index, metadata: captured.metadata, source: .native))
            capturedFrames.append(captured)
        }
        let encoded = try await writer.finalize()
        try await database.markVideoFinalized(id: videoID, frameCount: frameCount, fileSize: encoded.fileSizeBytes)
        let savedVideo = try await database.getVideoSegment(id: VideoSegmentID(value: videoID))
        return Fixture(root: root, storage: storage, database: database, storeID: storeID, frame: frames[0],
            pixels: pixels, video: try XCTUnwrap(savedVideo),
            framesURL: root.appendingPathComponent("wal/original_segment_\(pathID.value)/frames.bin"),
            frames: frames, capturedFrames: capturedFrames)
    }

    private func frame(value: UInt8 = 90) -> CapturedFrame {
        CapturedFrame(timestamp: Date(timeIntervalSince1970: 1_780_000_000.125),
            imageData: Data(repeating: value, count: 64 * 64 * 4), width: 64, height: 64, bytesPerRow: 256,
            metadata: FrameMetadata(appBundleID: "com.retrace.original-test", appName: "Original 🦘",
                windowName: "Original 42 café", displayID: 1))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OriginalFrameSpool-\(UUID())")
    }
}

private actor OriginalReaderTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
