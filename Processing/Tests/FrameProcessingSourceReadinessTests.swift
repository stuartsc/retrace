import Foundation
import XCTest
import SQLCipher
import Shared
import Database
import Storage
import Search
@testable import Processing

final class FrameProcessingSourceReadinessTests: XCTestCase {
    private var root: URL!
    private var database: DatabaseManager!
    private var storage: StorageManager!
    private var processor: FrameSourceRecordingProcessor!
    private var queue: FrameProcessingQueue!
    private var captureTime = Date()

    override func setUp() async throws {
        captureTime = Date()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameSourceReadiness-\(UUID())")
        database = DatabaseManager(databasePath: root.appendingPathComponent("test.db").path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await database.initialize()
        storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: StorageConfig(storageRootPath: root.path))
        try await storage.configureOriginalStore(storeID: database.originalStoreID())
        processor = FrameSourceRecordingProcessor()
        let search = SearchManager(database: database, ftsEngine: FTSManager(databasePath: root.appendingPathComponent("test.db").path))
        queue = FrameProcessingQueue(database: database, storage: storage, processing: processor, search: search,
            config: ProcessingQueueConfig(workerCount: 1))
    }

    override func tearDown() async throws {
        await queue?.stopWorkers()
        try await database?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testGovernedFreshOCRPassesHistoryAndCancellationLeavesDurableRetry() async throws {
        let old = try await makeFinalizedFixture(createEmptyVideo: false, capturedAt: Date().addingTimeInterval(-3600))
        let fresh = try await makeFinalizedFixture(createEmptyVideo: true)
        let wal = await storage.getWALManager()
        var session = try await wal.createSession(videoID: fresh.pathID)
        try await wal.appendFrame(rawFrame(value: 37), to: &session)
        try await wal.registerFrameID(videoID: fresh.pathID, frameID: fresh.frameID, frameIndex: 0)
        let governor = FreshOnlySourceGovernor()
        await processor.cancelNextGovernedRead()
        let search = SearchManager(database: database,
            ftsEngine: FTSManager(databasePath: root.appendingPathComponent("test.db").path))
        queue = FrameProcessingQueue(database: database, storage: storage, processing: processor, search: search,
            config: ProcessingQueueConfig(workerCount: 4), governor: governor)
        try await queue.enqueue(frameID: old.frameID, priority: 0)
        try await queue.enqueue(frameID: fresh.frameID, priority: 10)
        await queue.startWorkers()
        let workers = await queue.getStatistics()
        XCTAssertEqual(workers.workerCount, 1, "The shared governor owns a single automatic OCR worker")
        let status = try await waitForTerminalStatus(fresh.frameID)
        await queue.stopWorkers()
        XCTAssertEqual(status, 2)
        let history = try await database.sourceReadinessQueueState(frameID: old.frameID)
        XCTAssertEqual(history.status, 0, "Deferred history must never occupy the sole OCR worker")
        XCTAssertNotNil(history.queueID)
        let frames = await processor.frames
        XCTAssertEqual(frames.count, 2, "The first cancellation must retry the same original without failing it")
        XCTAssertTrue(frames.allSatisfy { $0.imageData == rawFrame(value: 37).imageData })
        let outstanding = await governor.outstanding
        XCTAssertEqual(outstanding, 0, "Every empty lane, cancellation and success releases its permit")
    }

    func testExactWALFrameOverridesFinalizedMetadataAndEmptyEncodedVideo() async throws {
        let fixture = try await makeFinalizedFixture(createEmptyVideo: true)
        let wal = await storage.getWALManager()
        var session = try await wal.createSession(videoID: fixture.pathID)
        try await wal.appendFrame(rawFrame(value: 21), to: &session)
        let expected = rawFrame(value: 42)
        try await wal.appendFrame(expected, to: &session)
        // Deliberately differ from the database's fallback index: the exact map
        // must select this second raw frame, not the preceding encoded frame.
        try await wal.registerFrameID(videoID: fixture.pathID, frameID: fixture.frameID, frameIndex: 1)
        try await queue.enqueue(frameID: fixture.frameID)
        await queue.startWorkers()

        let status = try await waitForTerminalStatus(fixture.frameID)
        let delivered = await processor.frames
        XCTAssertEqual(status, 2, "A complete raw frame remains processable while its encoded file is empty")
        XCTAssertEqual(delivered.map(\.imageData), [expected.imageData])
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.framesURL.path))
        XCTAssertEqual((try Data(contentsOf: fixture.videoURL)).count, 0, "OCR must not rewrite the encoder's file")
    }

    func testIncompleteWALDefersWithoutRetryPenaltyThenProcessesWhenWritten() async throws {
        let backlog = try await makeFinalizedFixture(createEmptyVideo: false)
        try await queue.enqueue(frameID: backlog.frameID, priority: 0)
        let fixture = try await makeFinalizedFixture(createEmptyVideo: true)
        let wal = await storage.getWALManager()
        var session = try await wal.createSession(videoID: fixture.pathID)
        try await queue.enqueue(frameID: fixture.frameID)
        let initialQueueID = try await database.sourceReadinessQueueState(frameID: fixture.frameID).queueID
        await queue.startWorkers()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var state = try await database.sourceReadinessQueueState(frameID: fixture.frameID)
        while !(state.status == 0 && state.queueID != nil && state.queueID != initialQueueID)
            && state.status != 3 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50), clock: .continuous)
            state = try await database.sourceReadinessQueueState(frameID: fixture.frameID)
        }
        await queue.stopWorkers()
        XCTAssertEqual(state.status, 0, "Not-yet-written pixels must stay pending")
        XCTAssertEqual(state.priority, 10, "A fresh source retry must not move behind the historical backlog")
        XCTAssertEqual(state.retryCount, 0, "Waiting for capture does not consume processing-error retries")
        let deferredStatistics = await queue.getStatistics()
        XCTAssertEqual(deferredStatistics.totalFailed, 0, "Source deferral itself is not a processing failure")
        guard state.status == 0 else { return }

        let expected = rawFrame(value: 63)
        try await wal.appendFrame(expected, to: &session)
        try await wal.registerFrameID(videoID: fixture.pathID, frameID: fixture.frameID, frameIndex: 0)
        let nextClaim = try await database.dequeueFrameForProcessing()
        XCTAssertEqual(nextClaim?.frameID, fixture.frameID, "After pixels arrive, the actual SQLite scheduler must choose the fresh retry before older priority-zero work")
        guard let nextClaim, nextClaim.frameID == fixture.frameID else { return }
        try await database.releaseFrameProcessingClaim(frameID: fixture.frameID, priority: 10, retryCount: nextClaim.retryCount)
        await queue.startWorkers()
        let status = try await waitForTerminalStatus(fixture.frameID)
        let delivered = await processor.frames
        XCTAssertEqual(status, 2)
        XCTAssertEqual(delivered.map(\.imageData), [expected.imageData])
    }

    func testFinalizedMissingVideoWithoutWALRemainsTerminalAndPreservesFrameRecord() async throws {
        let fixture = try await makeFinalizedFixture(createEmptyVideo: false)
        try await queue.enqueue(frameID: fixture.frameID)
        await queue.startWorkers()
        let status = try await waitForTerminalStatus(fixture.frameID)
        let frame = try await database.getFrame(id: FrameID(value: fixture.frameID))
        let queuePosition = try await database.getFrameQueuePosition(frameID: fixture.frameID)
        let delivered = await processor.frames
        XCTAssertEqual(status, 3)
        XCTAssertNotNil(frame)
        XCTAssertNil(queuePosition, "A finalized source with neither video nor WAL must not loop forever")
        XCTAssertTrue(delivered.isEmpty)
        let statistics = await queue.getStatistics()
        XCTAssertEqual(statistics.totalFailed, 1)
        XCTAssertEqual(statistics.totalProcessed, 0, "Missing media must not be counted as completed OCR")
    }

    func testRetainedIncompleteWALAfterRestartDoesNotRetryFinalizedMissingVideoForever() async throws {
        let fixture = try await makeFinalizedFixture(createEmptyVideo: false)
        let originalWAL = await storage.getWALManager()
        let session = try await originalWAL.createSession(videoID: fixture.pathID)
        let sourceBefore = try Data(contentsOf: session.framesURL)
        let metadataURL = session.sessionDir.appendingPathComponent("metadata.json")
        let metadataBefore = try Data(contentsOf: metadataURL)

        // A new StorageManager does not own the old process's WAL as live capture.
        storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: StorageConfig(storageRootPath: root.path))
        let search = SearchManager(database: database, ftsEngine: FTSManager(databasePath: root.appendingPathComponent("test.db").path))
        queue = FrameProcessingQueue(database: database, storage: storage, processing: processor, search: search,
            config: ProcessingQueueConfig(workerCount: 1))
        try await queue.enqueue(frameID: fixture.frameID)
        await queue.startWorkers()

        let status = try await waitForTerminalStatus(fixture.frameID)
        let frame = try await database.getFrame(id: FrameID(value: fixture.frameID))
        let queuePosition = try await database.getFrameQueuePosition(frameID: fixture.frameID)
        XCTAssertEqual(status, 3, "A retained unreadable WAL must not make finalized missing media retry forever")
        XCTAssertNotNil(frame)
        XCTAssertNil(queuePosition)
        XCTAssertEqual(try Data(contentsOf: session.framesURL), sourceBefore)
        XCTAssertEqual(try Data(contentsOf: metadataURL), metadataBefore)
    }

    func testExcludedAppCommitsSkipProofReleasesOriginalsAndCanLaterPrepareFromArchive() async throws {
        let bundleID = "com.test.source-readiness"
        let captured = CapturedFrame(timestamp: captureTime, imageData: rawFrame(value: 73).imageData,
            width: 64, height: 64, bytesPerRow: 256, metadata: FrameMetadata(appBundleID: bundleID))
        let writer = try await storage.createSegmentWriter()
        let path = await writer.relativePath
        let pathID = await writer.segmentID
        let videoID = try await database.insertVideoSegment(VideoSegment(id: .init(value: 0),
            startTime: captureTime, endTime: captureTime, frameCount: 0, fileSizeBytes: 0,
            relativePath: path, width: 64, height: 64))
        let segmentID = try await database.insertSegment(bundleID: bundleID, startDate: captureTime,
            endDate: captureTime, windowName: nil, browserUrl: nil, type: 0)
        try await writer.appendFrame(captured)
        let id = try await database.insertCapturedFrame(FrameReference(id: .init(value: 0), timestamp: captureTime,
            segmentID: .init(value: segmentID), videoID: .init(value: videoID), frameIndexInSegment: 0,
            metadata: captured.metadata), originalVideoPathID: pathID)
        let wal = await storage.getWALManager()
        try await wal.registerFrameID(videoID: pathID, frameID: id, frameIndex: 0)
        let video = try await writer.finalize()
        try await database.markVideoFinalized(id: videoID, frameCount: 1, fileSize: video.fileSizeBytes)
        try await database.markFrameReadable(frameID: id)
        await queue.updatePowerConfig(ocrEnabled: true, pauseOnBattery: false, pauseOnLowPowerMode: false,
            isLowPowerModeEnabled: false, currentPowerSource: .ac, maxFPS: 0, workerCount: 1,
            taskPriority: .utility, excludedBundleIDs: [bundleID], includedBundleIDs: [])
        try await queue.enqueue(frameID: id)
        await queue.startWorkers()
        let skippedStatus = try await waitForTerminalStatus(id)
        await queue.stopWorkers()
        XCTAssertEqual(skippedStatus, 2)
        let delivered = await processor.frames
        XCTAssertTrue(delivered.isEmpty, "Exclusion must not invent a blank OCR inference")
        guard case .skippedByAppFilter = try await database.originalFrameDisposition(frameID: .init(value: id)) else {
            return XCTFail("The actual exclusion path must publish its own durable disposition")
        }
        _ = try await storage.reconcileOriginalSpool(prepareArchives: true) { [database] frameID in
            try await database!.originalFrameDisposition(frameID: frameID)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("wal/original_segment_\(pathID.value)/frames.bin").path))
        // An explicit later preparation request invalidates skip authority and
        // can still use the retained archive after settings permit the app.
        try await database.updateFrameProcessingStatus(frameID: id, status: 0)
        guard case .pending = try await database.originalFrameDisposition(frameID: .init(value: id)) else {
            return XCTFail("Requeued extraction must invalidate the old skip proof")
        }
        await queue.updatePowerConfig(ocrEnabled: true, pauseOnBattery: false, pauseOnLowPowerMode: false,
            isLowPowerModeEnabled: false, currentPowerSource: .ac, maxFPS: 0, workerCount: 1,
            taskPriority: .utility, excludedBundleIDs: [], includedBundleIDs: [])
        try await queue.enqueue(frameID: id)
        await queue.startWorkers()
        let preparedStatus = try await waitForTerminalStatus(id)
        XCTAssertEqual(preparedStatus, 2)
        let prepared = await processor.frames
        XCTAssertEqual(prepared.count, 1)
    }

    private func makeFinalizedFixture(createEmptyVideo: Bool, capturedAt: Date? = nil) async throws -> (frameID: Int64, pathID: VideoSegmentID, videoURL: URL) {
        let writer = try await storage.createSegmentWriter()
        let pathID = await writer.segmentID
        let relativePath = await writer.relativePath
        let videoURL = root.appendingPathComponent(relativePath)
        if createEmptyVideo { try Data().write(to: videoURL) }
        let timestamp = capturedAt ?? captureTime
        let videoID = try await database.insertVideoSegment(VideoSegment(id: VideoSegmentID(value: 0), startTime: timestamp,
            endTime: timestamp, frameCount: 1, fileSizeBytes: 0, relativePath: relativePath, width: 64, height: 64))
        try await database.markVideoFinalized(id: videoID, frameCount: 1, fileSize: 0)
        let segmentID = try await database.insertSegment(bundleID: "com.test.source-readiness", startDate: timestamp,
            endDate: timestamp, windowName: nil, browserUrl: nil, type: 0)
        let frameID = try await database.insertCapturedFrame(FrameReference(id: FrameID(value: 0), timestamp: timestamp,
            segmentID: AppSegmentID(value: segmentID), videoID: VideoSegmentID(value: videoID), frameIndexInSegment: 0,
            metadata: FrameMetadata(appBundleID: "com.test.source-readiness")), originalVideoPathID: pathID)
        try await database.markFrameReadable(frameID: frameID)
        return (frameID, pathID, videoURL)
    }

    private func rawFrame(value: UInt8) -> CapturedFrame {
        CapturedFrame(timestamp: captureTime, imageData: Data(repeating: value, count: 64 * 64 * 4),
            width: 64, height: 64, bytesPerRow: 256, metadata: .empty)
    }

    private func waitForTerminalStatus(_ frameID: Int64) async throws -> Int {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var status = 0
        repeat {
            status = try await database.getFrameProcessingStatuses(frameIDs: [frameID])[frameID] ?? -1
            if status == 2 || status == 3 { return status }
            try await Task.sleep(for: .milliseconds(50), clock: .continuous)
        } while ContinuousClock.now < deadline
        return status
    }
}

private actor FrameSourceRecordingProcessor: ProcessingProtocol {
    private(set) var frames: [CapturedFrame] = []
    private var cancelNext = false
    func cancelNextGovernedRead() { cancelNext = true }
    func initialize(config: ProcessingConfig) async throws { }
    func extractText(from frame: CapturedFrame) async throws -> ExtractedText {
        frames.append(frame)
        if cancelNext {
            cancelNext = false
            BackgroundProcessingContext.permit?.cancellation.cancel()
        }
        return ExtractedText(frameID: FrameID(value: 0), timestamp: frame.timestamp, regions: [])
    }
    func extractTextViaOCR(from frame: CapturedFrame) async throws -> [TextRegion] { [] }
    func extractTextViaAccessibility() async throws -> [TextRegion] { [] }
    func queueFrame(_ frame: CapturedFrame, completion: @escaping @Sendable (Result<ExtractedText, ProcessingError>) -> Void) async { }
    var queuedFrameCount: Int { 0 }
    func waitForQueueDrain() async { }
    func updateConfig(_ config: ProcessingConfig) async { }
    func getConfig() async -> ProcessingConfig { .default }
}

private extension DatabaseManager {
    func sourceReadinessQueueState(frameID: Int64) throws -> (status: Int, priority: Int?, retryCount: Int?, queueID: Int64?) {
        let db = try XCTUnwrap(getConnection())
        let sql = "SELECT f.processingStatus, q.priority, q.retryCount, q.id FROM frame f LEFT JOIN processing_queue q ON q.frameId=f.id WHERE f.id=?"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(statement, 1, frameID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return (-1, nil, nil, nil) }
        return (Int(sqlite3_column_int(statement, 0)),
            sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 1)),
            sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 2)),
            sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 3))
    }
}

private actor FreshOnlySourceGovernor: BackgroundProcessingProtocol {
    private(set) var outstanding = 0
    func acquire(_ kind: BackgroundProcessingKind) async throws -> BackgroundProcessingPermit {
        while kind != .freshOCR { try await Task.sleep(for: .seconds(60)) }
        let value = try await tryAcquire(kind)
        return try XCTUnwrap(value)
    }
    func tryAcquire(_ kind: BackgroundProcessingKind) async throws -> BackgroundProcessingPermit? {
        guard kind == .freshOCR else { return nil }
        XCTAssertEqual(outstanding, 0)
        outstanding += 1
        return .init(threadCount: 2)
    }
    func release(_ permit: BackgroundProcessingPermit) { outstanding -= 1 }
}
