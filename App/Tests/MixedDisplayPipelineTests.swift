import CoreGraphics
import CoreText
import Foundation
import Shared
import Database
import Processing
import Storage
import XCTest
import Vision
@testable import App

/// Feeds native-rendered pixels through the actual App writer path. This proves
/// archive/source mapping across resolutions, not physical display capture.
final class MixedDisplayPipelineTests: XCTestCase {
    private var services: ServiceContainer!
    private var database: DatabaseManager!
    private var storage: StorageManager!
    private var queue: FrameProcessingQueue!
    private var root: URL!

    override func setUp() async throws {
        services = ServiceContainer(inMemory: true)
        database = await services.database
        storage = await services.storage
        root = await storage.getStorageDirectory()
        try await database.initialize()
        try await storage.initialize(config: StorageConfig(storageRootPath: root.path))
        let storeID = try await database.originalStoreID()
        try await storage.configureOriginalStore(storeID: storeID)
        let processing = await services.processing
        try await processing.initialize(config: ProcessingConfig(accessibilityEnabled: false))
        queue = FrameProcessingQueue(database: database, storage: storage, processing: processing,
                                     search: await services.search)
        await services.installMixedDisplayTestQueue(queue)
    }

    override func tearDown() async throws {
        await queue?.stopWorkers()
        try await database?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testInterleavedResolutionsKeepExactOriginalsArchiveIndicesAndExtractionAcknowledgements() async throws {
        let frames = try (0..<4).map(Self.render)
        let stream = AsyncStream<CapturedFrame> { continuation in
            for frame in frames { continuation.yield(frame) }
            continuation.finish()
        }
        let coordinator = AppCoordinator(services: services)
        await coordinator.runAuthoredCapturePipelineForTesting(stream)

        let rows = try await database.getFrames(from: .distantPast, to: .distantFuture, limit: 10)
        let videos = try await database.getVideoSegments(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(rows.count, 4, "The real App pipeline must admit every authored frame")
        XCTAssertEqual(videos.count, 2, "Each native resolution needs its own archive writer")
        XCTAssertEqual(Set(videos.map { "\($0.width)x\($0.height)" }), ["640x360", "960x540"])
        let ordered = rows.sorted { $0.timestamp < $1.timestamp }
        let storeID = try await database.originalStoreID()
        let wal = await storage.getWALManager()
        var expectedIndices: [UInt32: Int] = [:]
        for (index, row) in ordered.enumerated() {
            let value = try await database.getFrameWithVideoInfoByID(id: row.id)
            let saved = try XCTUnwrap(value)
            let original = frames[index]
            let video = try XCTUnwrap(videos.first { $0.id == saved.frame.videoID })
            XCTAssertEqual(saved.frame.metadata.displayID, original.metadata.displayID)
            XCTAssertEqual(video.width, original.width)
            XCTAssertEqual(video.height, original.height)
            let expectedIndex = expectedIndices[original.metadata.displayID, default: 0]
            XCTAssertEqual(saved.frame.frameIndexInSegment, expectedIndex)
            expectedIndices[original.metadata.displayID] = expectedIndex + 1
            let retained = try await wal.readOriginalFrameForProcessing(sourceStoreID: storeID, frame: saved.frame,
                expectedWidth: original.width, expectedHeight: original.height)
            let exact = try XCTUnwrap(retained)
            XCTAssertEqual(exact.imageData, original.imageData)
            XCTAssertEqual(exact.timestamp, original.timestamp)
            let decoded = try await storage.readFrameForProcessing(frame: saved.frame, video: video)
            XCTAssertEqual(decoded.width, original.width)
            XCTAssertEqual(decoded.height, original.height)
            try Self.assertDecodedIdentifier(decoded, identifier: 47_101 + index)

            let processing = await services.processing
            let text = try await processing.extractText(from: exact)
            XCTAssertTrue(text.fullText.contains("\(47_101 + index)"), "Vision must read this frame's authored identifier")
            _ = try await database.commitFrameOCR(frameID: row.id, text: text,
                frameWidth: original.width, frameHeight: original.height)
            let snapshot = try await database.currentScreenEvidence(frameID: row.id, storeID: storeID)
            XCTAssertEqual(snapshot?.frame.metadata.displayID, original.metadata.displayID)
            XCTAssertEqual(snapshot?.width, original.width)
        }

        let writer = try XCTUnwrap(database)
        let remaining = try await storage.reconcileOriginalSpool { id in
            try await writer.originalFrameDisposition(frameID: id)
        }
        XCTAssertEqual(remaining.retainedSessions, 0,
            "Durable OCR and verified current archive mappings must acknowledge both writers")
        for (index, row) in ordered.enumerated() {
            let value = try await database.getFrameWithVideoInfoByID(id: row.id)
            let saved = try XCTUnwrap(value)
            let video = try XCTUnwrap(videos.first { $0.id == saved.frame.videoID })
            let released = try await wal.readOriginalFrameForProcessing(sourceStoreID: storeID, frame: saved.frame,
                expectedWidth: frames[index].width, expectedHeight: frames[index].height)
            XCTAssertNil(released)
            let decoded = try await storage.readFrameForProcessing(frame: saved.frame, video: video)
            try Self.assertDecodedIdentifier(decoded, identifier: 47_101 + index)
        }
    }

    private static func render(_ index: Int) throws -> CapturedFrame {
        let width = index.isMultiple(of: 2) ? 640 : 960
        let height = index.isMultiple(of: 2) ? 360 : 540
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
            context.setFillColor(CGColor(red: CGFloat(index + 1) / 10, green: index.isMultiple(of: 2) ? 0.2 : 0.5,
                                         blue: 0.15, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let line = NSAttributedString(string: "Invoice \(47_101 + index)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 36, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 40, y: CGFloat(height) / 2)
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
        }
        return CapturedFrame(timestamp: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)),
            imageData: pixels, width: width, height: height, bytesPerRow: bytesPerRow,
            metadata: FrameMetadata(appBundleID: "com.test.mixed-display", appName: "Authored display fixture",
                windowName: "Display \(41 + index % 2)", displayID: UInt32(41 + index % 2)))
    }

    /// Frame identity is the independently authored identifier, not equality of
    /// RGB values after lossy HEVC and native color conversion. Exact original
    /// bytes are checked above; codec quality has its own measurement fixture.
    private static func assertDecodedIdentifier(_ actual: CapturedFrame, identifier: Int,
                                                file: StaticString = #filePath, line: UInt = #line) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: actual.imageData as CFData), file: file, line: line)
        let image = try XCTUnwrap(CGImage(width: actual.width, height: actual.height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: actual.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue |
                CGImageAlphaInfo.premultipliedFirst.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent), file: file, line: line)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        let identifiers = text.split(whereSeparator: { !$0.isNumber }).filter { $0.count == 5 }.map(String.init)
        XCTAssertEqual(identifiers, [String(identifier)],
            "Decoded archive must contain exactly this frame's critical identifier, including after original release",
            file: file, line: line)
    }
}

private extension ServiceContainer {
    func installMixedDisplayTestQueue(_ queue: FrameProcessingQueue) { processingQueue = queue }
}
