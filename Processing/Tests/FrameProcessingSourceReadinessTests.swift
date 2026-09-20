import Foundation
import CoreGraphics
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

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameSourceReadiness-\(UUID())")
        database = DatabaseManager(databasePath: root.appendingPathComponent("test.db").path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await database.initialize()
        storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: StorageConfig(storageRootPath: root.path))
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

    func testFinalizedVideoDeliversExactDecodedPixelsWithoutJPEGRecompression() async throws {
        let writer = try await storage.createSegmentWriter()
        let path = await writer.relativePath
        try await writer.appendFrame(rawFrame(value: 20))
        var pixels = Data(count: 64 * 64 * 4)
        pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for y in 0..<64 {
                for x in 0..<64 {
                    let offset = (y * 64 + x) * 4
                    bytes[offset] = UInt8((x * 13 + y * 3) % 256)
                    bytes[offset + 1] = UInt8((x * 7 + y * 17) % 256)
                    bytes[offset + 2] = (x + y) % 3 == 0 ? 255 : 0
                    bytes[offset + 3] = 255
                }
            }
        }
        try await writer.appendFrame(CapturedFrame(imageData: pixels, width: 64, height: 64, bytesPerRow: 256))
        let video = try await writer.finalize()
        let videoID = try await database.insertVideoSegment(video)
        try await database.markVideoFinalized(id: videoID, frameCount: 2, fileSize: video.fileSizeBytes)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let segmentID = try await database.insertSegment(bundleID: "com.test.saved-context", startDate: timestamp,
            endDate: timestamp, windowName: "Saved window", browserUrl: nil, type: 0)
        let frameID = try await database.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: timestamp,
            segmentID: AppSegmentID(value: segmentID), videoID: VideoSegmentID(value: videoID), frameIndexInSegment: 1,
            metadata: FrameMetadata(appBundleID: "com.test.saved-context", windowName: "Saved window")))
        try await database.markFrameReadable(frameID: frameID)

        // Independent reference pixels from the exact HEVC sample, before any
        // presentation JPEG encoding. Coloured thin edges make that loss visible.
        let image = try await ExactFrameReader.readFrame(videoURL: root.appendingPathComponent(path),
            frameIndex: 1, frameRate: 30, expectedWidth: 64, expectedHeight: 64)
        var decoded = Data(count: 64 * 64 * 4)
        try decoded.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 64, height: 64,
                bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        try await queue.enqueue(frameID: frameID)
        await queue.startWorkers()
        let status = try await waitForTerminalStatus(frameID)
        await queue.stopWorkers()
        let delivered = await processor.frames
        XCTAssertEqual(status, 2)
        let actual = try XCTUnwrap(delivered.first)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(actual.imageData, decoded, "OCR must receive the decoded sample without another lossy codec")
        XCTAssertNotEqual(decoded, pixels, "The fixture distinguishes source pixels from HEVC's own loss")
        XCTAssertEqual(actual.timestamp, timestamp)
        XCTAssertEqual(actual.metadata.appBundleID, "com.test.saved-context")
        XCTAssertEqual(actual.metadata.windowName, "Saved window")
        let metrics = try await database.sourceReadinessMetricPayloads()
        XCTAssertEqual(metrics.compactMap { $0["source"] }, ["archive_bgra", "archive_bgra"])
        XCTAssertEqual(metrics.compactMap { $0["outcome"] }, ["started", "completed"])
        XCTAssertTrue(metrics.allSatisfy { Set($0.keys) == ["source", "outcome"] },
                      "Quality telemetry must contain no screen text, identities or paths")
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

    private func makeFinalizedFixture(createEmptyVideo: Bool) async throws -> (frameID: Int64, pathID: VideoSegmentID, videoURL: URL) {
        let writer = try await storage.createSegmentWriter()
        let pathID = await writer.segmentID
        let relativePath = await writer.relativePath
        let videoURL = root.appendingPathComponent(relativePath)
        if createEmptyVideo { try Data().write(to: videoURL) }
        let timestamp = Date()
        let videoID = try await database.insertVideoSegment(VideoSegment(id: VideoSegmentID(value: 0), startTime: timestamp,
            endTime: timestamp, frameCount: 1, fileSizeBytes: 0, relativePath: relativePath, width: 64, height: 64))
        try await database.markVideoFinalized(id: videoID, frameCount: 1, fileSize: 0)
        let segmentID = try await database.insertSegment(bundleID: "com.test.source-readiness", startDate: timestamp,
            endDate: timestamp, windowName: nil, browserUrl: nil, type: 0)
        let frameID = try await database.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: timestamp,
            segmentID: AppSegmentID(value: segmentID), videoID: VideoSegmentID(value: videoID), frameIndexInSegment: 0,
            metadata: FrameMetadata(appBundleID: "com.test.source-readiness")))
        try await database.markFrameReadable(frameID: frameID)
        return (frameID, pathID, videoURL)
    }

    private func rawFrame(value: UInt8) -> CapturedFrame {
        CapturedFrame(timestamp: Date(), imageData: Data(repeating: value, count: 64 * 64 * 4),
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
    func initialize(config: ProcessingConfig) async throws { }
    func extractText(from frame: CapturedFrame) async throws -> ExtractedText {
        frames.append(frame)
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
    func sourceReadinessMetricPayloads() throws -> [[String: String]] {
        let db = try XCTUnwrap(getConnection())
        let sql = "SELECT metadata FROM daily_metrics WHERE metricType='ocr_source_processing' ORDER BY id"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        var result: [[String: String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let text = try XCTUnwrap(sqlite3_column_text(statement, 0))
            result.append(try JSONDecoder().decode([String: String].self, from: Data(String(cString: text).utf8)))
        }
        return result
    }

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
