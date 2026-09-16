import Foundation
import XCTest
import SQLCipher
import Shared
import Processing
import Database
import Storage
@testable import App

final class StartupRecoverySequencingTests: XCTestCase {
    private var services: ServiceContainer!
    private var coordinator: AppCoordinator!
    private var database: DatabaseManager!
    private var queue: FrameProcessingQueue!

    override func setUp() async throws {
        services = ServiceContainer(inMemory: true)
        database = await services.database
        try await database.initialize()
        let storage = StorageManager(storageRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent("StartupRecoverySequencing-\(UUID())"))
        queue = FrameProcessingQueue(database: database, storage: storage,
            processing: await services.processing, search: await services.search)
        await services.installStartupTestQueue(queue)
        coordinator = AppCoordinator(services: services)
    }

    override func tearDown() async throws {
        try await coordinator?.shutdown()
        await queue?.stopWorkers()
        try await database?.close()
    }

    func testStartupLegacyMaintenanceDoesNotRunGlobalCandidateCounts() async throws {
        let databaseConnection = await database.getConnection()
        let connection = try XCTUnwrap(databaseConnection)
        let trace = StartupMaintenanceSQLTrace()
        sqlite3_trace_v2(connection, UInt32(SQLITE_TRACE_STMT), { _, context, statement, _ in
            guard let context, let statement,
                  let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
            Unmanaged<StartupMaintenanceSQLTrace>.fromOpaque(context)
                .takeUnretainedValue().record(String(cString: sql))
            return 0
        }, Unmanaged.passUnretained(trace).toOpaque())
        defer { sqlite3_trace_v2(connection, 0, nil, nil) }

        // Even an empty real database must not issue the whole-library query:
        // its cost grows with historical node count, not the batch limit.
        await coordinator.enqueueLegacyOCRNodeTextBackfillIfNeeded()
        XCTAssertFalse(trace.statements.contains {
            $0.uppercased().contains("COUNT(DISTINCT F.ID)") && $0.lowercased().contains("join node")
        }, "Startup maintenance must inspect a bounded page, without a global node count")
    }

    func testLegacyMaintenanceRepeatsBoundedWorkAndStopsBeforeDatabaseTeardown() async throws {
        let databaseConnection = await database.getConnection()
        let connection = try XCTUnwrap(databaseConnection)
        let committedPages = expectation(description: "Two bounded maintenance pages committed")
        committedPages.expectedFulfillmentCount = 2
        // A further tick may finish before stop joins the task.
        committedPages.assertForOverFulfill = false
        let trace = StartupMaintenanceSQLTrace { statement in
            if statement == "COMMIT" { committedPages.fulfill() }
        }
        // PROFILE observes completed statements. Metrics autocommit individually;
        // only the actual maintenance pages issue explicit COMMIT statements.
        sqlite3_trace_v2(connection, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
            guard let context, let statement,
                  let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
            Unmanaged<StartupMaintenanceSQLTrace>.fromOpaque(context)
                .takeUnretainedValue().record(String(cString: sql))
            return 0
        }, Unmanaged.passUnretained(trace).toOpaque())
        defer { sqlite3_trace_v2(connection, 0, nil, nil) }

        // Exercise repetition rather than background timer coalescing. A 20 ms
        // background sleep can be delayed enough to exhaust a wall-time poll.
        await coordinator.startLegacyOCRNodeTextMaintenance(interval: .zero)
        // This checks committed repetition and joined shutdown, not background
        // scheduling latency. Allow admission under concurrent desktop/test work
        // without raising production priority or weakening the SQL assertions.
        await fulfillment(of: [committedPages], timeout: 20)
        await coordinator.stopLegacyOCRNodeTextMaintenance()
        let finishedStatements = trace.statements
        XCTAssertGreaterThanOrEqual(finishedStatements.filter {
            $0 == "COMMIT"
        }.count, 2, "Maintenance must commit another page after an empty page")
        XCTAssertGreaterThanOrEqual(finishedStatements.filter {
            $0 == "UPDATE ocr_backfill_state SET nodeCursor=0,nodeUpperBound=NULL WHERE id=1"
        }.count, 2, "The completed transactions must include repeated empty-page maintenance")
        let nodePages = finishedStatements.filter { $0.contains("FROM node WHERE id>") }
        XCTAssertGreaterThanOrEqual(nodePages.count, 2)
        XCTAssertTrue(nodePages.allSatisfy { $0.hasSuffix("ORDER BY id LIMIT ?") },
                      "Every repeat must retain the bounded node-page query")

        try await Task.sleep(for: .milliseconds(80), clock: .continuous)
        XCTAssertEqual(trace.statements, finishedStatements,
                       "Stopping maintenance must join it before database teardown")
    }

    func testRecoveryFinishesBeforeWorkersClaimFreshFramesEvenWhenPowerSettingsChange() async throws {
        let interrupted = try await insertPendingFrame(priority: 0, offset: 0)
        let oldClaim = try await database.dequeueFrameForProcessing()
        XCTAssertEqual(oldClaim?.frameID, interrupted)
        let fresh = try await insertPendingFrame(priority: 10, offset: 1)
        let gate = StartupRecoveryGate()
        let entered = expectation(description: "Recovery entered")
        let database = try XCTUnwrap(database)
        await coordinator.startFrameProcessingAfterRecovery {
            entered.fulfill()
            await gate.wait()
            // Exercise the real crash recovery query/reset against SQLite.
            let interruptedIDs = try await database.getCrashedProcessingFrameIDs()
            for id in interruptedIDs {
                try await database.releaseFrameProcessingClaim(frameID: id, priority: 0, retryCount: 0)
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        await coordinator.applyPowerSettings(snapshot: powerSettings(level: 1))
        await coordinator.applyPowerSettings(snapshot: powerSettings(level: 3))
        let waitingStatistics = await queue.getStatistics()
        XCTAssertEqual(waitingStatistics.workerCount, 0, "Power updates must not start workers during recovery")
        // Exceed the actual worker startup delay: this detects concurrent startup,
        // rather than merely observing a task before it has had time to run.
        try await Task.sleep(for: .seconds(16), clock: .continuous)
        let duringRecovery = try await database.getFrameProcessingStatuses(frameIDs: [interrupted, fresh])
        XCTAssertEqual(duringRecovery[interrupted], 1)
        XCTAssertEqual(duringRecovery[fresh], 0, "Fresh work must remain unclaimed while old claims are reset")

        await gate.release()
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var freshStatus = 0
        repeat {
            freshStatus = try await database.getFrameProcessingStatuses(frameIDs: [fresh])[fresh] ?? -1
            if freshStatus == 2 { break }
            try await Task.sleep(for: .milliseconds(50), clock: .continuous)
        } while ContinuousClock.now < deadline
        XCTAssertEqual(freshStatus, 2, "After recovery, the real queue must claim and finish fresh work")
        let remainingInterrupted = try await database.getFrameProcessingStatuses(frameIDs: [interrupted])
        XCTAssertEqual(remainingInterrupted[interrupted], 0, "Fresh priority must precede recovered backlog")
    }

    func testShutdownCancelsRecoveryWithoutStartingWorkers() async throws {
        let fresh = try await insertPendingFrame(priority: 10, offset: 0)
        let database = try XCTUnwrap(database)
        let finalReceipt = StartupFrameStatusReceipt()
        await services.setBeforeDatabaseCloseForTesting {
            let statuses = try await database.getFrameProcessingStatuses(frameIDs: [fresh])
            await finalReceipt.record(statuses)
        }
        let entered = expectation(description: "Recovery entered")
        await coordinator.startFrameProcessingAfterRecovery {
            entered.fulfill()
            try await Task.sleep(for: .seconds(3600), clock: .continuous)
        }
        await fulfillment(of: [entered], timeout: 2)
        try await coordinator.shutdown()
        let statistics = await queue.getStatistics()
        let recorded = await finalReceipt.statuses
        let statuses = try XCTUnwrap(recorded, "Capture the real SQLite state after worker join, before writer closure")
        let ready = await database.isReady()
        XCTAssertFalse(ready, "Even a partially initialized container must close its writer")
        XCTAssertEqual(statistics.workerCount, 0)
        XCTAssertEqual(statuses[fresh], 0)
    }

    func testRecoveryFailureStillStartsWorkersAfterRecoveryReturns() async throws {
        let entered = expectation(description: "Recovery failure handled")
        await coordinator.startFrameProcessingAfterRecovery {
            entered.fulfill()
            throw CocoaError(.fileReadCorruptFile)
        }
        await fulfillment(of: [entered], timeout: 2)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var workers = 0
        repeat {
            workers = await queue.getStatistics().workerCount
            if workers == 1 { break }
            try await Task.sleep(for: .milliseconds(10), clock: .continuous)
        } while ContinuousClock.now < deadline
        XCTAssertEqual(workers, 1, "A completed recovery failure must not permanently disable new OCR")
    }

    func testEfficiencyPowerUpdatesDoNotSuspendAnAlreadyWarmWorker() async throws {
        await coordinator.applyPowerSettings(snapshot: powerSettings(level: 3))
        let warmup = try await insertPendingFrame(priority: 10, offset: 0)
        await coordinator.startFrameProcessingAfterRecovery { }
        try await assertFrameCompletes(warmup, within: .seconds(20))
        for level in [1, 2] {
            await coordinator.applyPowerSettings(snapshot: powerSettings(level: level))
            let frame = try await insertPendingFrame(priority: 10, offset: TimeInterval(level))
            // Keep the configured 4s/2s pacing but reject another 15s startup
            // suspension when switching between normal background OCR levels.
            try await assertFrameCompletes(frame, within: .seconds(6))
        }
    }

    func testCancelledInterruptedClaimRecoveryPreservesSQLiteClaim() async throws {
        let interrupted = try await insertPendingFrame(priority: 0, offset: 0)
        _ = try await database.dequeueFrameForProcessing()
        let gate = StartupRecoveryGate()
        let queue = try XCTUnwrap(queue)
        let recovery = Task {
            await gate.wait()
            try await queue.requeueCrashedFrames()
        }
        recovery.cancel()
        await gate.release()
        do {
            try await recovery.value
            XCTFail("A cancelled recovery must not continue resetting interrupted claims")
        } catch is CancellationError { }
        let statuses = try await database.getFrameProcessingStatuses(frameIDs: [interrupted])
        XCTAssertEqual(statuses[interrupted], 1, "Cancellation must leave the existing claim available for the next recovery")
    }

    func testInterruptedExtensionlessVideoInspectionPreservesRecoverableWAL() async throws {
        try await assertInterruptedVideoInspectionPreservesWAL(legacyExtension: false)
    }

    func testInterruptedLegacyVideoInspectionPreservesRecoverableWAL() async throws {
        try await assertInterruptedVideoInspectionPreservesWAL(legacyExtension: true)
    }

    private func assertInterruptedVideoInspectionPreservesWAL(legacyExtension: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InterruptedWriterWAL-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let timestampID: Int64 = 1_788_700_000_000
        let relativePath = "chunks/202609/07/\(timestampID)"
        let primaryVideo = root.appendingPathComponent(relativePath)
        let video = legacyExtension ? primaryVideo.appendingPathExtension("mp4") : primaryVideo
        try FileManager.default.createDirectory(at: video.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A nonempty interrupted encoder output is not proof that all WAL frames
        // reached the container. Exercise the same size check on an incomplete file.
        let partialVideo = Data([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70])
        try partialVideo.write(to: video)
        let wal = WALManager(walRoot: root.appendingPathComponent("wal"))
        var session = try await wal.createSession(videoID: VideoSegmentID(value: timestampID))
        for index in 0..<2 {
            try await wal.appendFrame(CapturedFrame(
                timestamp: Date(timeIntervalSince1970: 1_788_700_000 + Double(index)),
                imageData: Data(repeating: UInt8(index + 1), count: 64 * 64 * 4),
                width: 64, height: 64, bytesPerRow: 256, metadata: .empty
            ), to: &session)
        }
        let sourceBefore = try Data(contentsOf: session.framesURL)
        let metadataBefore = try Data(contentsOf: session.sessionDir.appendingPathComponent("metadata.json"))
        let journal = session.sessionDir.appendingPathComponent("recovery-progress.json")
        let checkpoint = Data("{\"recovery\":\"still-in-progress\"}".utf8)
        try checkpoint.write(to: journal)
        let interrupted = UnfinalisedVideo(id: 17, relativePath: relativePath, frameCount: 2, width: 64, height: 64)

        let size = AppCoordinator.interruptedVideoFileSize(from: interrupted, storageDir: root)

        XCTAssertEqual(size, Int64(partialVideo.count))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.sessionDir.path), "Capture rollover must not delete recovery's source")
        XCTAssertEqual(try Data(contentsOf: session.framesURL), sourceBefore)
        XCTAssertEqual(try Data(contentsOf: session.sessionDir.appendingPathComponent("metadata.json")), metadataBefore)
        XCTAssertEqual(try Data(contentsOf: journal), checkpoint)
        let recovered = try await wal.readFrames(from: session)
        XCTAssertEqual(recovered.count, 2, "All actual WAL frames must remain readable by recovery")
        XCTAssertEqual(recovered.map(\.imageData), [Data(repeating: 1, count: 64 * 64 * 4), Data(repeating: 2, count: 64 * 64 * 4)])
    }

    private func assertFrameCompletes(_ frame: Int64, within timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var status = 0
        repeat {
            status = try await database.getFrameProcessingStatuses(frameIDs: [frame])[frame] ?? -1
            if status == 2 { break }
            try await Task.sleep(for: .milliseconds(50), clock: .continuous)
        } while ContinuousClock.now < deadline
        XCTAssertEqual(status, 2, "An enabled, warm queue must not restart its startup delay after a power-level update")
    }

    private func powerSettings(level: Int) -> OCRPowerSettingsSnapshot {
        OCRPowerSettingsSnapshot(ocrEnabled: true, pauseOnBattery: false, pauseOnLowPowerMode: false,
            processingLevel: level, appFilterModeRaw: "exclude",
            filteredAppsJSON: "[{\"bundleID\":\"com.test.startup-recovery\"}]")
    }

    private func insertPendingFrame(priority: Int, offset: TimeInterval) async throws -> Int64 {
        let date = Date(timeIntervalSince1970: 1_780_000_000 + offset)
        let segment = try await database.insertSegment(bundleID: "com.test.startup-recovery",
            startDate: date, endDate: date, windowName: nil, browserUrl: nil, type: 0)
        let video = try await database.insertVideoSegment(VideoSegment(id: VideoSegmentID(value: 0),
            startTime: date, endTime: date, frameCount: 1, fileSizeBytes: 1,
            relativePath: "chunks/202605/01/1780000000000", width: 640, height: 360))
        let frame = try await database.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: date,
            segmentID: AppSegmentID(value: segment), videoID: VideoSegmentID(value: video),
            frameIndexInSegment: 0, metadata: FrameMetadata(appBundleID: "com.test.startup-recovery")))
        try await database.markFrameReadable(frameID: frame)
        try await database.enqueueFrameForProcessing(frameID: frame, priority: priority)
        return frame
    }
}

private actor StartupFrameStatusReceipt {
    private(set) var statuses: [Int64: Int]?
    func record(_ statuses: [Int64: Int]) { self.statuses = statuses }
}

final class OrphanVideoFinalizationTests: XCTestCase {
    private var services: ServiceContainer!
    private var coordinator: AppCoordinator!
    private var database: DatabaseManager!

    override func setUp() async throws {
        services = ServiceContainer(inMemory: true)
        database = await services.database
        try await database.initialize()
        coordinator = AppCoordinator(services: services)
    }

    override func tearDown() async throws {
        try await database?.close()
    }

    func testFinishedWriterRemainsRepairableAfterSQLiteFinalizationFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinishedWriter-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: StorageConfig(storageRootPath: root.path))
        let writer = try await storage.createSegmentWriter()
        let path = await writer.relativePath
        let now = Date()
        let id = try await coordinator.insertLiveVideoSegment(VideoSegment(
            id: VideoSegmentID(value: 0), startTime: now, endTime: now, frameCount: 0,
            fileSizeBytes: 0, relativePath: path, width: 64, height: 64))
        try await writer.appendFrame(CapturedFrame(imageData: Data(repeating: 90, count: 64 * 64 * 4),
            width: 64, height: 64, bytesPerRow: 256))
        try await database.executeFinalizationFailureSQL("CREATE TRIGGER fail_video_finish BEFORE UPDATE OF processingState ON video WHEN NEW.id=\(id) BEGIN SELECT RAISE(ABORT, 'injected finalization failure'); END")
        do {
            try await coordinator.finalizeLiveVideoWriter(writer, videoDBID: id, frameCount: 1)
            XCTFail("Expected the real SQLite update failure")
        } catch { }
        let wal = await storage.getWALManager()
        let sessions = try await wal.listActiveSessions()
        XCTAssertTrue(sessions.isEmpty, "The successful encoder finalization already removed its raw journal")
        try await database.executeFinalizationFailureSQL("DROP TRIGGER fail_video_finish")
        let repaired = try await coordinator.finalizeOrphanedVideoSnapshot {
            try await wal.listActiveSessions()
        }
        XCTAssertEqual(repaired, 1, "An idle finalized writer must not retain a live ownership reservation")
        let remaining = try await database.getAllUnfinalisedVideos()
        XCTAssertFalse(remaining.contains { $0.id == id })
    }

    func testOrphanSweepNeverFinalizesVideoInsertedAfterCandidateSnapshot() async throws {
        let orphan = try await database.insertVideoSegment(video(pathID: 1_788_710_000_001))
        let database = try XCTUnwrap(database)
        let newVideo = video(pathID: 1_788_710_000_002)

        let finalized = try await coordinator.finalizeOrphanedVideoSnapshot {
            // Real SQLite insertion during WAL enumeration reproduces startup's
            // stale filesystem snapshot without depending on scheduler timing.
            _ = try await database.insertVideoSegment(newVideo)
            return []
        }

        let remaining = try await database.getAllUnfinalisedVideos()
        XCTAssertEqual(finalized, 1)
        XCTAssertFalse(remaining.contains { $0.id == orphan })
        XCTAssertEqual(remaining.map(\.relativePath), [newVideo.relativePath],
            "A sweep must not update a live placeholder absent from its candidate snapshot")
    }

    func testOrphanSweepProtectsLivePlaceholderBeforeFirstWALAppend() async throws {
        let live = try await coordinator.insertLiveVideoSegment(video(pathID: 1_788_710_000_003))
        let orphan = try await database.insertVideoSegment(video(pathID: 1_788_710_000_004))

        let finalized = try await coordinator.finalizeOrphanedVideoSnapshot { [] }

        let remaining = try await database.getAllUnfinalisedVideos()
        XCTAssertEqual(finalized, 1)
        XCTAssertEqual(remaining.map(\.id), [live],
            "Capture owns its placeholder even before the writer creates its first WAL session")
        let finalizedOrphan = try await database.getVideoSegment(id: VideoSegmentID(value: orphan))
        XCTAssertEqual(finalizedOrphan?.frameCount, 7)
        XCTAssertEqual(finalizedOrphan?.fileSizeBytes, 1_234,
            "Bounded cleanup must retain the stored file metadata")
    }

    func testOrphanSweepPreservesRealWALCandidateAndFinalizesOnlyOrphan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OrphanVideoWAL-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let wal = WALManager(walRoot: root)
        let pathID: Int64 = 1_788_710_000_005
        _ = try await wal.createSession(videoID: VideoSegmentID(value: pathID))
        let active = try await database.insertVideoSegment(video(pathID: pathID))
        _ = try await database.insertVideoSegment(video(pathID: 1_788_710_000_006))

        let finalized = try await coordinator.finalizeOrphanedVideoSnapshot {
            try await wal.listActiveSessions()
        }

        let remaining = try await database.getAllUnfinalisedVideos()
        XCTAssertEqual(finalized, 1)
        XCTAssertEqual(remaining.map(\.id), [active])
        let sessions = try await wal.listActiveSessions()
        XCTAssertEqual(sessions.map(\.videoID.value), [pathID])
    }

    func testOrphanSweepPreservesMetadataUpdatedDuringWALLookup() async throws {
        let orphan = try await database.insertVideoSegment(video(pathID: 1_788_710_000_008))
        let database = try XCTUnwrap(database)

        let finalized = try await coordinator.finalizeOrphanedVideoSnapshot {
            try await database.updateVideoSegment(id: orphan, width: 64, height: 64,
                fileSize: 5_678, frameCount: 11)
            return []
        }

        XCTAssertEqual(finalized, 1)
        let result = try await database.getVideoSegment(id: VideoSegmentID(value: orphan))
        XCTAssertEqual(result?.frameCount, 11)
        XCTAssertEqual(result?.fileSizeBytes, 5_678)
    }

    func testCancelledWriterInsertionReleasesOwnershipReservation() async throws {
        let coordinator = try XCTUnwrap(coordinator)
        let placeholder = video(pathID: 1_788_710_000_009)
        let gate = StartupRecoveryGate()
        let insertion = Task {
            await gate.wait()
            return try await coordinator.insertLiveVideoSegment(placeholder)
        }
        insertion.cancel()
        await gate.release()
        do {
            _ = try await insertion.value
            XCTFail("A cancelled insertion must not publish a writer placeholder")
        } catch is CancellationError { }
        let afterCancellation = try await database.getAllUnfinalisedVideos()
        XCTAssertTrue(afterCancellation.isEmpty)

        // The failed attempt must not leave a phantom live writer protecting a
        // later orphan with the same actual persisted path.
        _ = try await database.insertVideoSegment(placeholder)
        let finalized = try await coordinator.finalizeOrphanedVideoSnapshot { [] }
        XCTAssertEqual(finalized, 1)
        let remaining = try await database.getAllUnfinalisedVideos()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCancelledOrphanSweepPreservesCandidateAfterWALLookup() async throws {
        let orphan = try await database.insertVideoSegment(video(pathID: 1_788_710_000_007))
        let coordinator = try XCTUnwrap(coordinator)
        let gate = StartupRecoveryGate()
        let entered = expectation(description: "WAL lookup started")
        let sweep = Task {
            try await coordinator.finalizeOrphanedVideoSnapshot {
                entered.fulfill()
                await gate.wait()
                return []
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        sweep.cancel()
        await gate.release()
        do {
            _ = try await sweep.value
            XCTFail("Cancellation must prevent the pending orphan update")
        } catch is CancellationError { }
        let remaining = try await database.getAllUnfinalisedVideos()
        XCTAssertEqual(remaining.map(\.id), [orphan])
    }

    private func video(pathID: Int64) -> VideoSegment {
        let date = Date(timeIntervalSince1970: Double(pathID) / 1_000)
        return VideoSegment(id: VideoSegmentID(value: 0), startTime: date, endTime: date,
            frameCount: 7, fileSizeBytes: 1_234,
            relativePath: "chunks/202609/07/\(pathID)", width: 64, height: 64)
    }
}

private actor StartupRecoveryGate {
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

private extension DatabaseManager {
    func executeFinalizationFailureSQL(_ sql: String) throws {
        let db = try XCTUnwrap(getConnection())
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }
}

private extension ServiceContainer {
    func installStartupTestQueue(_ queue: FrameProcessingQueue) {
        processingQueue = queue
    }
}

private final class StartupMaintenanceSQLTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let onStatement: (@Sendable (String) -> Void)?

    init(onStatement: (@Sendable (String) -> Void)? = nil) {
        self.onStatement = onStatement
    }

    func record(_ statement: String) {
        lock.lock()
        recorded.append(statement)
        lock.unlock()
        onStatement?(statement)
    }

    var statements: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
