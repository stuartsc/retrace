import CoreGraphics
import CoreText
import Database
import Foundation
import Search
import Shared
import SQLCipher
import Storage
import XCTest
@testable import Processing

/// Vision reads actual rasterised retained pixels; AX is a controlled external
/// dependency representing a different application focused much later.
final class HistoricalOCRIsolationTests: XCTestCase {
    func testHistoricalOCRNeverConsultsLiveAXInEitherRecognitionMode() async throws {
        let frame = try retainedOCRFrame()
        for incremental in [false, true] {
            let liveAX = UnrelatedLiveAccessibility()
            let processing = ProcessingManager(
                config: ProcessingConfig(accessibilityEnabled: true, minimumConfidence: 0.1),
                accessibility: liveAX
            )
            await processing.setRegionBasedOCR(enabled: incremental)

            let result = try await processing.extractText(from: frame)

            XCTAssertTrue(result.fullText.contains("4200.00"), "Exercise real Vision recognition of retained pixels")
            XCTAssertFalse(result.fullText.contains(UnrelatedLiveAccessibility.liveText))
            XCTAssertEqual(result.fullText, result.regions.map(\.text).joined(separator: " "))
            XCTAssertEqual(result.chromeText, result.chromeRegions.map(\.text).joined(separator: " "))
            XCTAssertFalse(result.chromeRegions.isEmpty, "Fixture includes visible menu chrome")
            XCTAssertEqual(result.metadata, frame.metadata)
            XCTAssertEqual(result.timestamp, frame.timestamp)
            let accesses = await liveAX.accesses
            XCTAssertEqual(accesses, 0, "Saved-frame extraction must not even check live AX permission")
        }
    }

    func testQueuedBlankFrameCannotAcquireUnrelatedLiveTextAfterConfigChange() async throws {
        let liveAX = UnrelatedLiveAccessibility()
        let processing = ProcessingManager(
            config: ProcessingConfig(accessibilityEnabled: false), accessibility: liveAX
        )
        await processing.updateConfig(ProcessingConfig(accessibilityEnabled: true))
        let frame = try retainedOCRFrame(blank: true)
        let result: Result<ExtractedText, ProcessingError> = await withCheckedContinuation { continuation in
            Task {
                await processing.queueFrame(frame) { continuation.resume(returning: $0) }
            }
        }
        let extracted = try result.get()

        XCTAssertTrue(extracted.isEmpty)
        XCTAssertTrue(extracted.regions.isEmpty)
        XCTAssertTrue(extracted.chromeRegions.isEmpty)
        XCTAssertEqual(extracted.metadata, frame.metadata)
        let accesses = await liveAX.accesses
        XCTAssertEqual(accesses, 0)
    }

    func testExplicitLiveAccessibilityAPIRemainsSeparateFromSavedFrameExtraction() async throws {
        let liveAX = UnrelatedLiveAccessibility()
        let processing = ProcessingManager(
            config: ProcessingConfig(accessibilityEnabled: true), accessibility: liveAX
        )
        let regions = try await processing.extractTextViaAccessibility()

        XCTAssertEqual(regions.map(\.text), [UnrelatedLiveAccessibility.liveText])
        let accesses = await liveAX.accesses
        XCTAssertEqual(accesses, 2, "Only the explicitly live API checks permission and reads focused AX")
    }

    func testUnchangedPixelsKeepEachHistoricalFramesOwnMetadata() async throws {
        let liveAX = UnrelatedLiveAccessibility()
        let processing = ProcessingManager(
            config: ProcessingConfig(accessibilityEnabled: true, minimumConfidence: 0.1), accessibility: liveAX
        )
        let first = try retainedOCRFrame()
        let second = CapturedFrame(timestamp: first.timestamp.addingTimeInterval(2), imageData: first.imageData,
            width: first.width, height: first.height, bytesPerRow: first.bytesPerRow,
            metadata: FrameMetadata(appBundleID: "com.test.other", windowName: "Same pixels, other saved context",
                browserURL: "https://example.test/other", displayID: 43))
        let firstText = try await processing.extractText(from: first)
        let secondText = try await processing.extractText(from: second)

        XCTAssertEqual(secondText.fullText, firstText.fullText)
        XCTAssertEqual(firstText.metadata, first.metadata)
        XCTAssertEqual(secondText.metadata, second.metadata)
        XCTAssertEqual(secondText.timestamp, second.timestamp)
        let accesses = await liveAX.accesses
        XCTAssertEqual(accesses, 0)
    }

    func testQueuedTruncatedPixelsFailWithoutFallingBackToLiveAX() async throws {
        let liveAX = UnrelatedLiveAccessibility()
        let processing = ProcessingManager(config: ProcessingConfig(accessibilityEnabled: true), accessibility: liveAX)
        let truncated = CapturedFrame(imageData: Data(repeating: 255, count: 16), width: 64, height: 64, bytesPerRow: 256)
        let result: Result<ExtractedText, ProcessingError> = await withCheckedContinuation { continuation in
            Task { await processing.queueFrame(truncated) { continuation.resume(returning: $0) } }
        }
        do {
            _ = try result.get()
            XCTFail("Incomplete retained pixels must fail extraction")
        } catch ProcessingError.imageConversionFailed { }
        let accesses = await liveAX.accesses
        let statistics = await processing.getStatistics()
        XCTAssertEqual(accesses, 0)
        XCTAssertEqual(statistics.errorCount, 1)
    }

    func testConcurrentHistoricalExtractionsDoNotExchangeUnchangedText() async throws {
        let processing = ProcessingManager(config: ProcessingConfig(accessibilityEnabled: false, minimumConfidence: 0.1))
        for _ in 0..<2 {
            await processing.invalidateTileCache()
            _ = try await processing.extractText(from: retainedOCRFrame(decision: "Decision PENDING"))
            try await withThrowingTaskGroup(of: (String, String).self) { group in
                for index in 0..<16 {
                    let amount = index.isMultiple(of: 2) ? "9200.00" : "4200.00"
                    let decision = index.isMultiple(of: 2) ? "Decision PENDING" : "Decision APPROVED"
                    let frame = try retainedOCRFrame(amount: amount, decision: decision)
                    group.addTask {
                        let result = try await processing.extractText(from: frame)
                        return (result.fullText, "Retained invoice \(amount) \(decision)")
                    }
                }
                for try await (actual, expected) in group {
                    XCTAssertEqual(actual, expected, "An incremental cache must belong to the exact prior pixels used for change detection")
                }
            }
        }
    }
}

/// Real temporary SQLite databases, real HEVC media and actual StorageManager
/// errors are sent through the production durable OCR worker.
final class OCRRepairEvidencePreservationTests: XCTestCase {
    private var root: URL!
    private var database: DatabaseManager!
    private var storage: StorageManager!
    private var fts: FTSManager!
    private var queue: FrameProcessingQueue?

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OCRRepair-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = DatabaseManager(databasePath: root.appendingPathComponent("test.db").path)
        try await database.initialize()
        fts = FTSManager(databasePath: root.appendingPathComponent("test.db").path)
        try await fts.initialize()
        storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: StorageConfig(storageRootPath: root.path))
    }

    override func tearDown() async throws {
        await queue?.stopWorkers()
        try await fts?.close()
        try await database?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testActualOutOfRangeVideoRepairRetainsFrameTextGeometryAndFTS() async throws {
        let fixture = try await makeFixture(frameIndex: 20, emptyVideo: false)
        let source = RepairStorage(storage: storage, mode: .decodeAll, root: root)
        try await runRepair(fixture.frameID, source: source)

        let failure = await source.failureDescription
        XCTAssertTrue(try XCTUnwrap(failure).contains("Frame index 20 out of range"), "Exercise the actual decoder bounds failure")
        try await assertEvidencePreserved(fixture, reason: .integrityFailure)
    }

    func testActualEmptyVideoRepairRetainsEvidenceWhenMediaDisappearsBeforeVerification() async throws {
        let fixture = try await makeFixture(frameIndex: 0, emptyVideo: true)
        let source = RepairStorage(storage: storage, mode: .removeEmptyAfterRead, root: root)
        try await runRepair(fixture.frameID, source: source)

        let failure = await source.failureDescription
        XCTAssertTrue(try XCTUnwrap(failure).contains("Video file is empty"), "Exercise the actual empty-file failure")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.videoURL.path))
        try await assertEvidencePreserved(fixture, reason: .recordingMissing)
    }

    func testActualEmptyVideoRemainingOnDiskRetainsEvidence() async throws {
        let fixture = try await makeFixture(frameIndex: 0, emptyVideo: true)
        let source = RepairStorage(storage: storage, mode: .strict, root: root)
        try await runRepair(fixture.frameID, source: source)

        let failure = await source.failureDescription
        XCTAssertTrue(try XCTUnwrap(failure).contains("Video file is empty"))
        XCTAssertEqual(try Data(contentsOf: fixture.videoURL), Data())
        try await assertEvidencePreserved(fixture, reason: .recordingMissing)
    }

    func testExplicitDeletionDuringOCRCannotResurrectEvidenceOrRetryRows() async throws {
        let fixture = try await makeFixture(frameIndex: 0, emptyVideo: false)
        let processor = SuspendedRepairProcessor()
        queue = makeQueue(source: storage, processor: processor)
        try await queue!.enqueue(frameID: fixture.frameID)
        await queue!.startWorkers()
        let startDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !(await processor.started) && ContinuousClock.now < startDeadline {
            try await Task.sleep(for: .milliseconds(20), clock: .continuous)
        }
        let started = await processor.started
        XCTAssertTrue(started, "Production worker must reach OCR before the deletion race")
        guard started else { return }

        do {
            try await database.deleteFrame(id: FrameID(value: fixture.frameID))
        } catch {
            await processor.finish()
            throw error
        }
        await processor.finish()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await queue!.getStatistics().totalFailed == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20), clock: .continuous)
        }
        await queue!.stopWorkers()

        let frame = try await database.getFrame(id: FrameID(value: fixture.frameID))
        let nodes = try await database.getNodesWithText(frameID: FrameID(value: fixture.frameID), frameWidth: 1200, frameHeight: 700)
        let matches = try await fts.search(query: "invoice", limit: 10, offset: 0)
        let depth = try await database.getProcessingQueueDepth()
        let unavailable = try await database.frameMediaUnavailable(frameID: FrameID(value: fixture.frameID))
        XCTAssertNil(frame)
        XCTAssertTrue(nodes.isEmpty)
        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(depth, 0)
        XCTAssertNil(unavailable, "A late worker must not create a receipt for deleted evidence")
    }

    private struct Fixture {
        let frameID: Int64
        let docID: Int64
        let videoURL: URL
        let text: ExtractedText
        let nodes: [OCRNode]
    }

    private func makeFixture(frameIndex: Int, emptyVideo: Bool) async throws -> Fixture {
        let captured = try retainedOCRFrame()
        // No live WAL owns these finalized historical fixtures.
        let writer = try await storage.createRecoverySegmentWriter()
        let videoURL = await root.appendingPathComponent(writer.relativePath)
        let video: VideoSegment
        if emptyVideo {
            try Data().write(to: videoURL)
            video = await VideoSegment(id: writer.segmentID, startTime: captured.timestamp, endTime: captured.timestamp,
                frameCount: 1, fileSizeBytes: 0, relativePath: writer.relativePath, width: 1200, height: 700)
        } else {
            try await writer.appendFrame(captured)
            video = try await writer.finalize()
        }
        let videoID = try await database.insertVideoSegment(video)
        try await database.markVideoFinalized(id: videoID, frameCount: video.frameCount, fileSize: video.fileSizeBytes)
        let segmentID = try await database.insertSegment(bundleID: "com.test.retained", startDate: captured.timestamp,
            endDate: captured.timestamp, windowName: "Saved invoice", browserUrl: nil, type: 0)
        let frameID = try await database.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: captured.timestamp,
            segmentID: AppSegmentID(value: segmentID), videoID: VideoSegmentID(value: videoID),
            frameIndexInSegment: frameIndex, metadata: captured.metadata))
        let text = try await ProcessingManager(config: ProcessingConfig(accessibilityEnabled: false, minimumConfidence: 0.1)).extractText(from: captured)
        let docID = try await database.commitFrameOCR(frameID: FrameID(value: frameID), text: text, frameWidth: 1200, frameHeight: 700)
        let nodes = try await database.getNodesWithText(frameID: FrameID(value: frameID), frameWidth: 1200, frameHeight: 700)
        try await database.updateFrameProcessingStatus(frameID: frameID, status: 0)
        return Fixture(frameID: frameID, docID: docID, videoURL: videoURL, text: text, nodes: nodes.map(\.node))
    }

    private func makeQueue(source: any StorageProtocol, processor: any ProcessingProtocol) -> FrameProcessingQueue {
        let search = SearchManager(database: database, ftsEngine: FTSManager(databasePath: root.appendingPathComponent("test.db").path))
        return FrameProcessingQueue(database: database, storage: source, processing: processor, search: search,
            config: ProcessingQueueConfig(workerCount: 1, maxRetryAttempts: 0))
    }

    private func runRepair(_ frameID: Int64, source: any StorageProtocol) async throws {
        queue = makeQueue(source: source, processor: ProcessingManager(config: ProcessingConfig(accessibilityEnabled: false)))
        try await queue!.enqueue(frameID: frameID)
        await queue!.startWorkers()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        repeat {
            let status = try await database.getFrameProcessingStatuses(frameIDs: [frameID])[frameID]
            if status == 3 || status == nil { break }
            try await Task.sleep(for: .milliseconds(50), clock: .continuous)
        } while ContinuousClock.now < deadline
        await queue!.stopWorkers()
    }

    private func assertEvidencePreserved(_ fixture: Fixture, reason: EvidenceUnavailableReason, file: StaticString = #filePath, line: UInt = #line) async throws {
        let status = try await database.getFrameProcessingStatuses(frameIDs: [fixture.frameID])[fixture.frameID]
        let frame = try await database.getFrame(id: FrameID(value: fixture.frameID))
        let content = try await database.getFTSContent(docid: fixture.docID)
        let nodes = try await database.getNodesWithText(frameID: FrameID(value: fixture.frameID), frameWidth: 1200, frameHeight: 700)
        let matches = try await fts.search(query: "invoice", limit: 10, offset: 0)
        let depth = try await database.getProcessingQueueDepth()
        let unavailable = try await database.frameMediaUnavailable(frameID: FrameID(value: fixture.frameID))
        XCTAssertEqual(status, 3, "Unavailable media is a failed repair, never deletion", file: file, line: line)
        XCTAssertNotNil(frame, file: file, line: line)
        XCTAssertEqual(content?.mainText, fixture.text.fullText, file: file, line: line)
        XCTAssertEqual(content?.chromeText, fixture.text.chromeText, file: file, line: line)
        XCTAssertEqual(nodes.map(\.text), (fixture.text.regions + fixture.text.chromeRegions).map(\.text), file: file, line: line)
        XCTAssertEqual(nodes.map(\.node), fixture.nodes, "Repair must preserve existing node identity, offsets and geometry", file: file, line: line)
        XCTAssertTrue(nodes.allSatisfy { $0.node.width > 0 && $0.node.height > 0 }, file: file, line: line)
        XCTAssertEqual(matches.count, 1, file: file, line: line)
        XCTAssertEqual(depth, 0, file: file, line: line)
        XCTAssertEqual(unavailable, reason, "The terminal repair reason must survive queue removal", file: file, line: line)
    }
}

private actor UnrelatedLiveAccessibility: AccessibilityProtocol {
    static let liveText = "Unrelated live password manager content"
    private(set) var accesses = 0
    func hasPermission() -> Bool { accesses += 1; return true }
    func requestPermission() { accesses += 1 }
    func getFocusedAppText() async throws -> AccessibilityResult {
        accesses += 1
        return AccessibilityResult(appInfo: AppInfo(bundleID: "com.test.live", name: "Unrelated live app", windowName: "Live private window"),
            textElements: [AccessibilityTextElement(text: Self.liveText)])
    }
    func getAppText(bundleID: String) async throws -> AccessibilityResult { try await getFocusedAppText() }
    func getFrontmostAppInfo() async throws -> AppInfo { try await getFocusedAppText().appInfo }
}

private actor SuspendedRepairProcessor: ProcessingProtocol {
    private(set) var started = false
    private var finishWaiter: CheckedContinuation<Void, Never>?
    func finish() { finishWaiter?.resume(); finishWaiter = nil }
    func initialize(config: ProcessingConfig) async throws { }
    func extractText(from frame: CapturedFrame) async throws -> ExtractedText {
        started = true
        await withCheckedContinuation { finishWaiter = $0 }
        return ExtractedText(frameID: FrameID(value: 0), timestamp: frame.timestamp,
            regions: [TextRegion(frameID: FrameID(value: 0), text: "Late invoice result", bounds: CGRect(x: 10, y: 10, width: 100, height: 20))])
    }
    func extractTextViaOCR(from frame: CapturedFrame) async throws -> [TextRegion] { [] }
    func extractTextViaAccessibility() async throws -> [TextRegion] { [] }
    func queueFrame(_ frame: CapturedFrame, completion: @escaping @Sendable (Result<ExtractedText, ProcessingError>) -> Void) async { }
    var queuedFrameCount: Int { 0 }
    func waitForQueueDrain() async { }
    func updateConfig(_ config: ProcessingConfig) async { }
    func getConfig() async -> ProcessingConfig { .default }
}

/// Adapter routes a real storage read through the existing decode-all API or
/// removes the real empty file after the read error to exercise repair races.
private actor RepairStorage: StorageProtocol {
    enum Mode { case strict, decodeAll, removeEmptyAfterRead }
    let storage: StorageManager
    let mode: Mode
    let root: URL
    private(set) var failureDescription: String?
    init(storage: StorageManager, mode: Mode, root: URL) { self.storage = storage; self.mode = mode; self.root = root }
    func readFrameForProcessing(frame: FrameReference, video: VideoSegment) async throws -> CapturedFrame {
        // Preserve the intentionally exercised legacy decoder failures and the
        // real file-removal race while conforming to the new worker contract.
        let name = URL(fileURLWithPath: video.relativePath).deletingPathExtension().lastPathComponent
        let pathID = try XCTUnwrap(Int64(name))
        _ = try await readFrame(segmentID: VideoSegmentID(value: pathID), frameIndex: frame.frameIndexInSegment)
        return try await storage.readFrameForProcessing(frame: frame, video: video)
    }
    func readFrame(segmentID: VideoSegmentID, frameIndex: Int) async throws -> Data {
        do {
            if mode == .decodeAll { return try await storage.readFrameDecodeAll(segmentID: segmentID, frameIndex: frameIndex) }
            return try await storage.readFrame(segmentID: segmentID, frameIndex: frameIndex)
        } catch {
            failureDescription = error.localizedDescription
            if mode == .removeEmptyAfterRead { try await storage.deleteSegment(id: segmentID) }
            throw error
        }
    }
    func initialize(config: StorageConfig) async throws { try await storage.initialize(config: config) }
    func createSegmentWriter() async throws -> any SegmentWriter { try await storage.createSegmentWriter() }
    func getSegmentPath(id: VideoSegmentID) async throws -> URL { try await storage.getSegmentPath(id: id) }
    func deleteSegment(id: VideoSegmentID) async throws { try await storage.deleteSegment(id: id) }
    func segmentExists(id: VideoSegmentID) async throws -> Bool { try await storage.segmentExists(id: id) }
    func countFramesInSegment(id: VideoSegmentID) async throws -> Int { try await storage.countFramesInSegment(id: id) }
    func isVideoValid(id: VideoSegmentID) async throws -> Bool { try await storage.isVideoValid(id: id) }
    func getTotalStorageUsed(includeRewind: Bool) async throws -> Int64 { try await storage.getTotalStorageUsed(includeRewind: includeRewind) }
    func getStorageUsedForDateRange(from startDate: Date, to endDate: Date) async throws -> Int64 { try await storage.getStorageUsedForDateRange(from: startDate, to: endDate) }
    func getAvailableDiskSpace() async throws -> Int64 { try await storage.getAvailableDiskSpace() }
    func cleanupOldSegments(olderThan date: Date) async throws -> [VideoSegmentID] { try await storage.cleanupOldSegments(olderThan: date) }
    func getStorageDirectory() -> URL { root }
}

private func retainedOCRFrame(blank: Bool = false, amount: String = "4200.00", decision: String? = nil) throws -> CapturedFrame {
    let width = 1200
    let height = 700
    let bytesPerRow = width * 4
    var data = Data(count: bytesPerRow * height)
    try data.withUnsafeMutableBytes { bytes in
        let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if !blank {
            var lines: [(String, CGFloat, CGFloat)] = [("Saved menu", 24, 18), ("Retained invoice \(amount)", 320, 32)]
            if let decision { lines.append((decision, 550, 32)) }
            for (text, baseline, size) in lines {
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, size, nil),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
                ]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                context.textPosition = CGPoint(x: 80, y: CGFloat(height) - baseline)
                CTLineDraw(line, context)
            }
        }
    }
    return CapturedFrame(timestamp: Date(timeIntervalSince1970: 1_780_000_000), imageData: data,
        width: width, height: height, bytesPerRow: bytesPerRow,
        metadata: FrameMetadata(appBundleID: "com.test.retained", appName: "Saved app", windowName: "Saved invoice",
            browserURL: "https://example.test/saved", displayID: 42))
}
