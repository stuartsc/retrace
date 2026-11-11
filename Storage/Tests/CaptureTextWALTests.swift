import CryptoKit
import Foundation
import Shared
import XCTest
@testable import Storage

final class CaptureTextWALTests: XCTestCase {
    func testNativeTimestampAndCompleteDirectTextSurviveActualWALRecordRead() throws {
        let fixture = makeFrame()
        let record = try WALFrameCodec.encode(fixture, path: "private-fixture")
        let loaded = try read(record: record)
        XCTAssertEqual(loaded.metadata, fixture.metadata)
        XCTAssertEqual(loaded.imageData, fixture.imageData)
        XCTAssertEqual(loaded.timestamp.timeIntervalSince1970, fixture.timestamp.timeIntervalSince1970)
        let direct = try loaded.metadata.validatedCaptureText(frameWidth: loaded.width, frameHeight: loaded.height,
                                                               timestamp: loaded.timestamp)
        XCTAssertEqual(direct?.runs.first?.text, "Invoice INV-8042 $12,345.67 ✅")
        XCTAssertEqual(direct?.runs.first?.elementUTF16Range.location, 140)
    }

    func testRehashedWrongAttemptCannotUpgradeCorruptMetadataIntoValidDirectText() throws {
        let fixture = makeFrame()
        let record = try WALFrameCodec.encode(fixture, path: "private-fixture")
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: record.metadata) as? [String: Any])
        var observation = try XCTUnwrap(metadata["captureText"] as? [String: Any])
        observation["captureAttemptID"] = UUID().uuidString
        metadata["captureText"] = observation
        let changed = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        var header = record.header
        var count = UInt32(changed.count).littleEndian
        withUnsafeBytes(of: &count) { header.replaceSubrange(12..<16, with: $0) }
        header.replaceSubrange(44..<76, with: Data(SHA256.hash(data: changed)))
        let tampered = WALFrameCodec.EncodedRecord(header: header, metadata: changed, pixels: record.pixels)
        XCTAssertThrowsError(try read(record: tampered), "A checksum does not replace exact attempt validation")
    }

    func testGroupedPixelIdentitySurvivesWALAndRehashedWrongAttemptIsRejected() throws {
        let original = makeFrame()
        let pixels = try XCTUnwrap(original.metadata.pixelReceipt)
        let member = CaptureGroupFrameReceipt(groupID: UUID(), sessionID: UUID(), configurationGeneration: 1,
            attemptID: pixels.attemptID, attachmentID: UUID(), displayID: original.metadata.displayID)
        let frame = CapturedFrame(timestamp: original.timestamp, imageData: original.imageData,
            width: original.width, height: original.height, bytesPerRow: original.bytesPerRow,
            metadata: original.metadata.linkingCaptureGroup(member))
        let record = try WALFrameCodec.encode(frame, path: "private-fixture")
        let loaded = try read(record: record)
        XCTAssertEqual(loaded.metadata.captureGroup, member)
        XCTAssertEqual(loaded.imageData, original.imageData)
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: record.metadata) as? [String: Any])
        var group = try XCTUnwrap(metadata["captureGroup"] as? [String: Any])
        group["attemptID"] = UUID().uuidString
        metadata["captureGroup"] = group
        let changed = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        var header = record.header
        var count = UInt32(changed.count).littleEndian
        withUnsafeBytes(of: &count) { header.replaceSubrange(12..<16, with: $0) }
        header.replaceSubrange(44..<76, with: Data(SHA256.hash(data: changed)))
        XCTAssertThrowsError(try read(record: .init(header: header, metadata: changed, pixels: record.pixels)),
            "A recomputed checksum cannot bind pixels to a different display attempt")
    }

    func testDifferentPixelTimestampRejectsWriteBeforeCreatingARecord() throws {
        let fixture = makeFrame()
        let different = CapturedFrame(timestamp: fixture.timestamp.addingTimeInterval(0.0001), imageData: fixture.imageData,
            width: fixture.width, height: fixture.height, bytesPerRow: fixture.bytesPerRow, metadata: fixture.metadata)
        XCTAssertThrowsError(try WALFrameCodec.encode(different, path: "private-fixture"))
    }

    func testUnavailableDiagnosticsCannotCarryAnotherAttemptOrPixelInterval() throws {
        let fixture = makeFrame()
        let record = try WALFrameCodec.encode(fixture, path: "private-fixture")
        for mismatch in ["attempt", "interval"] {
            var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: record.metadata) as? [String: Any])
            var observation = try XCTUnwrap(metadata["captureText"] as? [String: Any])
            observation["availability"] = "unavailable"
            observation["reasons"] = ["captureFailed"]
            observation["runs"] = []
            observation.removeValue(forKey: "sourceContext")
            observation.removeValue(forKey: "consistency")
            if mismatch == "attempt" {
                observation["captureAttemptID"] = UUID().uuidString
            } else {
                var interval = try XCTUnwrap(observation["pixelRead"] as? [String: Any])
                interval["endedUptime"] = 101
                observation["pixelRead"] = interval
            }
            metadata["captureText"] = observation
            let changed = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            var header = record.header
            var count = UInt32(changed.count).littleEndian
            withUnsafeBytes(of: &count) { header.replaceSubrange(12..<16, with: $0) }
            header.replaceSubrange(44..<76, with: Data(SHA256.hash(data: changed)))
            XCTAssertThrowsError(try read(record: .init(header: header, metadata: changed, pixels: record.pixels)))
        }
    }

    func testMinimalUnavailableFallbackSurvivesWALWithItsIndependentPixelReceipt() throws {
        let fixture = makeFrame()
        let original = fixture.metadata
        let fallback = CaptureTextObservation(captureAttemptID: nil, sourceContext: nil,
            preRead: nil, pixelRead: nil, postRead: nil, availability: .unavailable,
            reasons: [.captureFailed], consistency: nil, runs: [])
        let metadata = FrameMetadata(appBundleID: original.appBundleID, displayID: original.displayID,
            captureContext: original.captureContext, captureMonotonicTime: original.captureMonotonicTime,
            capturePolicySHA256: original.capturePolicySHA256, pixelReceipt: original.pixelReceipt, captureText: fallback)
        let frame = CapturedFrame(timestamp: fixture.timestamp, imageData: fixture.imageData,
            width: fixture.width, height: fixture.height, bytesPerRow: fixture.bytesPerRow, metadata: metadata)
        let loaded = try read(record: WALFrameCodec.encode(frame, path: "private-fixture"))
        XCTAssertEqual(loaded.metadata.captureText, fallback)
        XCTAssertEqual(loaded.metadata.pixelReceipt, original.pixelReceipt)
    }

    private func read(record: WALFrameCodec.EncodedRecord) throws -> CapturedFrame {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-text-wal-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("frames.raw")
        var data = record.header; data.append(record.metadata); data.append(record.pixels)
        try data.write(to: file, options: [.withoutOverwriting])
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        // Propagate malformed-record errors to the caller's XCTAssertThrowsError.
        // XCTUnwrap's throwing autoclosure records a failure before rethrowing,
        // which incorrectly fails deliberate corruption cases in this helper.
        guard let loaded = try WALFrameCodec.read(handle: handle, path: file.path,
            sourceSize: UInt64(data.count), offset: 0, loadPixels: true) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return loaded.frame
    }

    private func makeFrame() -> CapturedFrame {
        let time = Date(timeIntervalSince1970: 1_790_000_000.1234567)
        let context = ActivityContext(appBundleID: "com.test.capture-text", appName: "Authored fixture", processID: 234,
            processGeneration: "fixture-process-1", windowID: 15, windowGeneration: "fixture-window-1", displayID: 42)
        func interval(_ offset: Double) -> CaptureReadInterval {
            CaptureReadInterval(startedAt: time.addingTimeInterval(offset), endedAt: time.addingTimeInterval(offset + 0.005),
                startedUptime: 100 + offset, endedUptime: 100 + offset + 0.005)
        }
        let receipt = CapturePixelReceipt(attemptID: UUID(), interval: interval(0))
        let text = "Invoice INV-8042 $12,345.67 ✅"
        let direct = CaptureTextObservation(captureAttemptID: receipt.attemptID, sourceContext: context,
            preRead: interval(-0.01), pixelRead: receipt.interval, postRead: interval(0.01),
            availability: .available, reasons: [], consistency: .sameWindowBracketed,
            runs: [CaptureTextRun(id: 0, elementOrdinal: 2, text: text,
                elementUTF16Range: EvidenceUTF16Range(location: 140, length: text.utf16.count),
                boundsInFramePixels: CGRect(x: 2, y: 3, width: 60, height: 12), role: .textArea,
                ancestors: [.window, .scrollArea])])
        let metadata = FrameMetadata(appBundleID: context.appBundleID, displayID: 42, captureContext: context,
            captureMonotonicTime: 100, capturePolicySHA256: String(repeating: "a", count: 64),
            pixelReceipt: receipt, captureText: direct)
        return CapturedFrame(timestamp: time, imageData: Data(repeating: 127, count: 64 * 64 * 4),
            width: 64, height: 64, bytesPerRow: 64 * 4, metadata: metadata)
    }
}
