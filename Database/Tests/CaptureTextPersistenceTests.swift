import Foundation
import Shared
import XCTest
@testable import Database

/// Real SQLite transactions exercise admission, retained JSON, OCR revisions and
/// mutable legacy frame hydration. Native AX acquisition has separate tests.
final class CaptureTextPersistenceTests: XCTestCase {
    private var database: DatabaseManager!
    private var segmentID: Int64 = 0
    private var videoID: Int64 = 0
    private let timestamp = Date(timeIntervalSince1970: 1_790_000_000.1234567)
    private let originalID = VideoSegmentID(value: 1_790_000_000_123)
    private let attemptID = UUID()
    private let directText = "Revenue 12,345.67 — approved ✅"

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:capture-text-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        segmentID = try await database.insertSegment(bundleID: "com.test.visible-text", startDate: timestamp,
            endDate: timestamp, windowName: "Authored text fixture", browserUrl: nil, type: 0)
        videoID = try await database.insertVideoSegment(VideoSegment(id: VideoSegmentID(value: 0),
            startTime: timestamp, endTime: timestamp, frameCount: 1, fileSizeBytes: 100,
            relativePath: "chunks/\(originalID.value)", width: 640, height: 480))
    }

    override func tearDown() async throws { try await database.close() }

    func testDirectTextSurvivesCanonicalCaptureAndOCRWithoutBecomingAnOCRBlock() async throws {
        let id = FrameID(value: try await database.insertCapturedFrame(frame(metadata: metadata()), originalVideoPathID: originalID))
        let storeID = try await database.originalStoreID()
        let beforeValue = try await database.currentScreenEvidence(frameID: id, storeID: storeID)
        let before = try XCTUnwrap(beforeValue)
        let captured = try XCTUnwrap(before.validatedCaptureText)
        XCTAssertEqual(captured.runs.map(\.text), [directText])
        XCTAssertNil(before.text)
        XCTAssertTrue(before.observation.blocks.isEmpty)

        let ocrText = "Revenue 12,345.67"
        let region = TextRegion(frameID: id, text: ocrText,
            bounds: CGRect(x: 10, y: 20, width: 240, height: 25), confidence: 0.9)
        _ = try await database.commitFrameOCR(frameID: id,
            text: ExtractedText(frameID: id, timestamp: timestamp, regions: [region], fullText: ocrText,
                                metadata: .empty), frameWidth: 640, frameHeight: 480)
        let afterValue = try await database.currentScreenEvidence(frameID: id, storeID: storeID)
        let after = try XCTUnwrap(afterValue)
        XCTAssertGreaterThan(after.ref.extractionRevision, before.ref.extractionRevision)
        XCTAssertEqual(after.validatedCaptureText, captured)
        XCTAssertEqual(after.observation.blocks.count, 1)
        XCTAssertEqual(after.text?.fullText, ocrText)
        let hydrated = try await database.getFrameWithVideoInfoByID(id: id)
        XCTAssertEqual(hydrated?.frame.metadata.captureText, captured)
        XCTAssertEqual(hydrated?.frame.metadata.pixelReceipt, metadata().pixelReceipt)
        let exactOld = try await database.screenEvidence(before.ref)
        XCTAssertEqual(exactOld?.validatedCaptureText, captured)
        XCTAssertNil(exactOld?.text, "Appending OCR must not rewrite the retained capture revision")
    }

    func testWrongReceiptTimestampContextGeometryAndOverlappingRangesRollbackCapture() async throws {
        let badMetadata: [FrameMetadata] = [
            metadata(receiptID: UUID()),
            metadata(captureUptime: 500.25),
            metadata(policyHash: nil),
            metadata(context: ActivityContext(appBundleID: "com.test.other", appName: "Other", processID: 55,
                processGeneration: "other", windowID: 100, windowGeneration: "other-window", displayID: 42)),
            metadata(observation: observation(runs: [run(bounds: CGRect(x: 630, y: 20, width: 240, height: 25))])),
            metadata(observation: observation(runs: [run(), run(id: 1, location: 4)]))
        ]
        for (index, metadata) in badMetadata.enumerated() {
            do {
                _ = try await database.insertCapturedFrame(frame(metadata: metadata), originalVideoPathID: originalID)
                XCTFail("Malformed direct-text case \(index) must not commit")
            } catch { }
            let count = try await database.getFrameCount()
            XCTAssertEqual(count, 0, "Failed admission must roll back the frame as well as its snapshot")
        }
        do {
            _ = try await database.insertCapturedFrame(frame(metadata: metadata(), timestamp: timestamp.addingTimeInterval(0.001)),
                                                       originalVideoPathID: originalID)
            XCTFail("A nearby timestamp cannot reuse a different native pixel receipt")
        } catch { }
        let count = try await database.getFrameCount()
        XCTAssertEqual(count, 0)
    }

    func testLegacyMetadataWithoutDirectTextOrPixelReceiptRemainsReadable() async throws {
        let oldMetadata = FrameMetadata(appBundleID: "com.test.visible-text", displayID: 42)
        let id = FrameID(value: try await database.insertCapturedFrame(frame(metadata: oldMetadata), originalVideoPathID: originalID))
        let storeID = try await database.originalStoreID()
        let loaded = try await database.currentScreenEvidence(frameID: id, storeID: storeID)
        XCTAssertNotNil(loaded)
        XCTAssertNil(loaded?.validatedCaptureText)
        XCTAssertNil(loaded?.frame.metadata.pixelReceipt)
    }

    func testUnavailableDirectTextRetainsReasonWithoutGrantingTextOrOCRProvenance() async throws {
        let unavailable = CaptureTextObservation(captureAttemptID: attemptID, sourceContext: nil,
            preRead: nil, pixelRead: interval(start: 500, duration: 0.01), postRead: nil,
            availability: .unavailable, reasons: [.permissionUnavailable], consistency: nil, runs: [])
        let id = FrameID(value: try await database.insertCapturedFrame(frame(metadata: metadata(observation: unavailable)),
                                                                     originalVideoPathID: originalID))
        let store = try await database.originalStoreID()
        let result = try await database.currentScreenEvidence(frameID: id, storeID: store)
        XCTAssertEqual(result?.validatedCaptureText?.availability, .unavailable)
        XCTAssertEqual(result?.validatedCaptureText?.reasons, [.permissionUnavailable])
        XCTAssertTrue(result?.validatedCaptureText?.runs.isEmpty == true)
        XCTAssertTrue(result?.observation.blocks.isEmpty == true)
    }

    func testMinimalUnavailableFallbackPersistsWithoutBorrowingWindowOrReadIntervals() async throws {
        let fallback = CaptureTextObservation(captureAttemptID: nil, sourceContext: nil,
            preRead: nil, pixelRead: nil, postRead: nil, availability: .unavailable,
            reasons: [.captureFailed], consistency: nil, runs: [])
        let id = FrameID(value: try await database.insertCapturedFrame(frame(metadata: metadata(observation: fallback)),
                                                                     originalVideoPathID: originalID))
        let store = try await database.originalStoreID()
        let result = try await database.currentScreenEvidence(frameID: id, storeID: store)
        XCTAssertEqual(result?.validatedCaptureText, fallback)
        XCTAssertNil(result?.validatedCaptureText?.sourceContext)
        XCTAssertNil(result?.validatedCaptureText?.pixelRead)
    }

    private var context: ActivityContext {
        ActivityContext(appBundleID: "com.test.visible-text", appName: "Fixture", processID: 123,
            processGeneration: "authored-process-1", windowID: 100, windowGeneration: "authored-window-1",
            windowTitle: "Authored text fixture", displayID: 42)
    }

    private func interval(start: TimeInterval, duration: TimeInterval) -> CaptureReadInterval {
        CaptureReadInterval(startedAt: timestamp.addingTimeInterval(start - 500),
            endedAt: timestamp.addingTimeInterval(start - 500 + duration), startedUptime: start,
            endedUptime: start + duration)
    }

    private func run(id: Int = 0, location: Int = 0,
                     bounds: CGRect = CGRect(x: 10, y: 20, width: 300, height: 25)) -> CaptureTextRun {
        CaptureTextRun(id: id, elementOrdinal: 0, text: directText,
            elementUTF16Range: EvidenceUTF16Range(location: location, length: directText.utf16.count),
            boundsInFramePixels: bounds, role: .textArea, ancestors: [.window, .scrollArea])
    }

    private func observation(runs: [CaptureTextRun]? = nil) -> CaptureTextObservation {
        CaptureTextObservation(captureAttemptID: attemptID, sourceContext: context,
            preRead: interval(start: 499.99, duration: 0.005), pixelRead: interval(start: 500, duration: 0.01),
            postRead: interval(start: 500.02, duration: 0.005), availability: .available, reasons: [],
            consistency: .sameWindowBracketed, runs: runs ?? [run()])
    }

    private func metadata(receiptID: UUID? = nil, captureUptime: TimeInterval = 500,
                          policyHash: String? = String(repeating: "a", count: 64),
                          context: ActivityContext? = nil, observation: CaptureTextObservation? = nil) -> FrameMetadata {
        FrameMetadata(appBundleID: "com.test.visible-text", windowName: "Authored text fixture", displayID: 42,
            captureContext: context ?? self.context, captureMonotonicTime: captureUptime,
            capturePolicySHA256: policyHash,
            pixelReceipt: CapturePixelReceipt(attemptID: receiptID ?? attemptID, interval: interval(start: 500, duration: 0.01)),
            captureText: observation ?? self.observation())
    }

    private func frame(metadata: FrameMetadata, timestamp: Date? = nil) -> FrameReference {
        FrameReference(id: FrameID(value: 0), timestamp: timestamp ?? self.timestamp,
            segmentID: AppSegmentID(value: segmentID), videoID: VideoSegmentID(value: videoID),
            frameIndexInSegment: 0, metadata: metadata)
    }
}
