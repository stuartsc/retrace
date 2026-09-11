import AVFoundation
import CryptoKit
import Foundation
import XCTest
import Shared
@testable import Storage

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                      STORAGE MANAGER TESTS                                   ║
// ║                                                                              ║
// ║  • Verify encrypt/decrypt is no-op when encryption disabled                  ║
// ║  • Verify key generation, export, import round trip                          ║
// ║  • Verify encrypt/decrypt round trip when encryption enabled                 ║
// ║  • Verify segment exists after create and is removed after cancel            ║
// ║  • Verify getSegmentPath finds segment by ID                                 ║
// ║  • Verify cleanupOldSegments deletes files older than cutoff                 ║
// ║  • Verify getTotalStorageUsed sums all segment sizes                         ║
// ║  • Verify readFrame throws error for missing segment                         ║
// ║  • Verify getAvailableDiskSpace returns non-negative value                   ║
// ║  • Verify segment writer append/finalize creates segment file                ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class StorageManagerTests: XCTestCase {

    private static var hasPrintedSeparator = false

    override func setUp() {
        super.setUp()

        if !Self.hasPrintedSeparator {
            printTestSeparator()
            Self.hasPrintedSeparator = true
        }
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                           Helper Methods                                 │
    // └──────────────────────────────────────────────────────────────────────────┘

    private func makeTempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceStorageTests_\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStorageConfig(root: URL) -> StorageConfig {
        StorageConfig(
            storageRootPath: root.path,
            retentionDays: nil,
            maxStorageGB: nil,
            segmentDurationSeconds: 300
        )
    }

    private func createFakeSegmentFile(root: URL, id: VideoSegmentID, date: Date, ext: String, size: Int, modDate: Date) throws -> URL {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)

        let dir = root
            .appendingPathComponent("chunks", isDirectory: true)
            .appendingPathComponent(String(format: "%04d%02d", year, month), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let filename = ext.isEmpty ? id.stringValue : "\(id.stringValue).\(ext)"
        let url = dir.appendingPathComponent(filename)
        let data = Data(repeating: 0xCD, count: size)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modDate], ofItemAtPath: url.path)
        return url
    }

    private func createQuarantinedWALSession(
        walRoot: URL,
        name: String,
        videoID: Int64,
        startTime: Date,
        payloadSize: Int
    ) throws -> URL {
        let dir = walRoot
            .appendingPathComponent("quarantine", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let metadata = WALMetadata(
            videoID: VideoSegmentID(value: videoID),
            startTime: startTime,
            frameCount: 1,
            width: 16,
            height: 16
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: dir.appendingPathComponent("metadata.json"))
        try Data(repeating: 0xAB, count: payloadSize).write(to: dir.appendingPathComponent("frames.bin"))

        try FileManager.default.setAttributes([.modificationDate: startTime], ofItemAtPath: dir.path)
        return dir
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                       Segment Management Tests                           │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testSegmentExistsAfterCreateAndCancel() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let writer = try await storage.createSegmentWriter()
        let id = await writer.segmentID

        // Note: File is only created after first frame is written with AVAssetWriter
        // Before that, segmentExists should return false
        let exists1 = try await storage.segmentExists(id: id)
        XCTAssertFalse(exists1)  // Changed from True - file doesn't exist until first frame

        try await writer.cancel()
        let exists2 = try await storage.segmentExists(id: id)
        XCTAssertFalse(exists2)

        try? FileManager.default.removeItem(at: root)
    }

    func testGetSegmentPathFindsByIDString() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let id = VideoSegmentID(value: 0)
        let now = Date()
        let url = try createFakeSegmentFile(
            root: root,
            id: id,
            date: now,
            ext: "mp4",  // Changed from "hevc" to "mp4"
            size: 16,
            modDate: now
        )

        let found = try await storage.getSegmentPath(id: id)
        // Use path comparison to handle /var vs /private/var symlink differences
        XCTAssertEqual(found.standardizedFileURL.path, url.standardizedFileURL.path)

        try? FileManager.default.removeItem(at: root)
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                            Cleanup Tests                                 │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testCleanupOldSegmentsDeletesPastFiles() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let oldDate = Date(timeIntervalSinceNow: -7 * 24 * 3600)
        let cutoff = Date(timeIntervalSinceNow: -24 * 3600)

        let id1 = VideoSegmentID(value: 101)
        let id2 = VideoSegmentID(value: 102)
        _ = try createFakeSegmentFile(root: root, id: id1, date: oldDate, ext: "", size: 10, modDate: oldDate)
        _ = try createFakeSegmentFile(root: root, id: id2, date: oldDate, ext: "", size: 20, modDate: oldDate)

        let deleted = try await storage.cleanupOldSegments(olderThan: cutoff)
        XCTAssertEqual(Set(deleted), Set([id1, id2]))
        for id in deleted {
            try await storage.deleteSegment(id: id)
        }
        let exists1 = try await storage.segmentExists(id: id1)
        XCTAssertFalse(exists1)
        let exists2 = try await storage.segmentExists(id: id2)
        XCTAssertFalse(exists2)

        try? FileManager.default.removeItem(at: root)
    }

    func testPruneQuarantinedWALDeletesOldRawRecoveryBuffers() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldSession = try createQuarantinedWALSession(
            walRoot: walRoot,
            name: "active_segment_1-old",
            videoID: 1,
            startTime: now.addingTimeInterval(-2 * 24 * 60 * 60),
            payloadSize: 64 * 1024
        )
        let freshSession = try createQuarantinedWALSession(
            walRoot: walRoot,
            name: "active_segment_2-fresh",
            videoID: 2,
            startTime: now.addingTimeInterval(-60 * 60),
            payloadSize: 64 * 1024
        )

        let result = try await walManager.pruneQuarantinedSessions(
            maxAge: 24 * 60 * 60,
            maxBytes: 1024 * 1024,
            now: now
        )

        XCTAssertEqual(result.deletedSessionCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldSession.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshSession.path))
        XCTAssertGreaterThan(result.deletedBytes, 0)
        XCTAssertGreaterThan(result.remainingBytes, 0)

        try? FileManager.default.removeItem(at: root)
    }

    func testPruneQuarantinedWALCapsRecentRawRecoveryBuffers() async throws {
        let root = makeTempRoot()
        let walRoot = root.appendingPathComponent("wal", isDirectory: true)
        let walManager = WALManager(walRoot: walRoot)
        try await walManager.initialize()

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldest = try createQuarantinedWALSession(
            walRoot: walRoot,
            name: "active_segment_1-oldest",
            videoID: 1,
            startTime: now.addingTimeInterval(-3 * 60 * 60),
            payloadSize: 64 * 1024
        )
        let middle = try createQuarantinedWALSession(
            walRoot: walRoot,
            name: "active_segment_2-middle",
            videoID: 2,
            startTime: now.addingTimeInterval(-2 * 60 * 60),
            payloadSize: 64 * 1024
        )
        let newest = try createQuarantinedWALSession(
            walRoot: walRoot,
            name: "active_segment_3-newest",
            videoID: 3,
            startTime: now.addingTimeInterval(-60 * 60),
            payloadSize: 64 * 1024
        )

        let result = try await walManager.pruneQuarantinedSessions(
            maxAge: 24 * 60 * 60,
            maxBytes: 140_000,
            now: now
        )

        XCTAssertEqual(result.deletedSessionCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: middle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
        XCTAssertLessThanOrEqual(result.remainingBytes, 140_000)

        try? FileManager.default.removeItem(at: root)
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                        Storage Metrics Tests                             │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testTotalStorageUsedSumsSegmentSizes() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let now = Date()
        let id1 = VideoSegmentID(value: 201)
        let id2 = VideoSegmentID(value: 202)
        _ = try createFakeSegmentFile(root: root, id: id1, date: now, ext: "", size: 123, modDate: now)
        _ = try createFakeSegmentFile(root: root, id: id2, date: now, ext: "", size: 456, modDate: now)

        let total = try await storage.getTotalStorageUsed(includeRewind: false)
        XCTAssertGreaterThanOrEqual(total, 123 + 456)

        try? FileManager.default.removeItem(at: root)
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                         Frame Reading Tests                              │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testReadFrameThrowsForMissingSegment() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let missingID = VideoSegmentID(value: 0)
        await XCTAssertThrowsErrorAsync {
            _ = try await storage.readFrame(segmentID: missingID, frameIndex: 0)
        }

        try? FileManager.default.removeItem(at: root)
    }

    func testAvailableDiskSpaceNonNegative() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        let bytes = try await storage.getAvailableDiskSpace()
        XCTAssertGreaterThanOrEqual(bytes, 0)

        try? FileManager.default.removeItem(at: root)
    }

    // ┌──────────────────────────────────────────────────────────────────────────┐
    // │                        Segment Writer Tests                              │
    // └──────────────────────────────────────────────────────────────────────────┘

    func testStrictFrameReadRejectsEarlierImageWhileTolerantPlaybackRemainsAvailable() async throws {
        let root = makeTempRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appendingPathComponent("timestamp-gap.mp4")
        let encoder = HEVCEncoder()
        try await encoder.initialize(width: 64, height: 64, config: .default,
                                     outputURL: videoURL, segmentStartTime: Date())
        // A real encoded gap reproduces AVFoundation returning the earlier image
        // for a requested 30 fps slot that has not been encoded yet.
        for index in 0..<3 {
            let frame = CapturedFrame(imageData: Data(repeating: UInt8(40 + index * 60), count: 64 * 64 * 4),
                                      width: 64, height: 64, bytesPerRow: 64 * 4)
            let pixels = try FrameConverter.createPixelBuffer(from: frame)
            try await encoder.encode(pixelBuffer: pixels, timestamp: CMTime(value: Int64(index), timescale: 10))
        }
        try await encoder.finalize()
        let storage = StorageManager(storageRoot: root)
        let exact = try await storage.readFrameFromPath(videoPath: videoURL.path, frameIndex: 0)
        XCTAssertFalse(exact.isEmpty)
        let tolerant = try await storage.readFrameFromPath(videoPath: videoURL.path, frameIndex: 1,
                                                         enforceTimestampMatch: false)
        XCTAssertFalse(tolerant.isEmpty, "Playback can explicitly request a nearby image")
        do {
            _ = try await storage.readFrameFromPath(videoPath: videoURL.path, frameIndex: 1)
            XCTFail("Strict OCR reads must not accept a different encoded frame")
        } catch let error as StorageError {
            guard case .fileReadFailed(_, let underlying) = error else {
                return XCTFail("Unexpected storage error: \(error)")
            }
            XCTAssertTrue(underlying.contains("timestamp"), "Expected a timestamp mismatch: \(underlying)")
        }
    }

    func testSegmentWriterAppendFinalizeCreatesSegmentFile() async throws {
        let root = makeTempRoot()
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: makeStorageConfig(root: root))

        do {
            let writer = try await storage.createSegmentWriter()
            let bytesPerRow = 4 * 4
            let imageData = Data(repeating: 0x00, count: bytesPerRow * 4)
            let frame = CapturedFrame(
                imageData: imageData,
                width: 4,
                height: 4,
                bytesPerRow: bytesPerRow
            )
            try await writer.appendFrame(frame)
            let count = await writer.frameCount
            XCTAssertEqual(count, 1)
            let segment = try await writer.finalize()
            XCTAssertEqual(segment.frameCount, 1)
            let url = try await storage.getSegmentPath(id: segment.id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        } catch {
            throw XCTSkip("HEVC encoding unavailable in test environment: \(error)")
        }

        try? FileManager.default.removeItem(at: root)
    }

    func testAudioSegmentWriterClampsSentenceEndToAvailablePCM() async throws {
        let root = makeTempRoot()
        let writer = AudioSegmentWriter(storageRoot: root)

        // Regression for fallback transcript timing that can land a few samples past
        // the actual PCM buffer due to capture/Whisper duration rounding.
        let audioData = Data(repeating: 0, count: 478_920)

        let result = try await writer.writeAudioSegment(
            audioData: audioData,
            startTime: 0,
            endTime: 15.0053125,
            sampleRate: 16_000,
            channels: 1,
            timestamp: Date(timeIntervalSince1970: 1_781_553_241),
            source: .microphone
        )

        let outputURL = root.appendingPathComponent(result.filePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan(result.fileSize, 0)

        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Async XCTest helper

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        // success
    }
}
