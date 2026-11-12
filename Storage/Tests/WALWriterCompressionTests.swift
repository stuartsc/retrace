import Darwin
import Foundation
import Shared
import XCTest
@testable import Storage

/// Exercise the real configured WAL writer, retained journals and native readers.
final class WALWriterCompressionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-wal-compression-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        root = nil
    }

    func testOldStorageConfigurationDecodesWithConservativeCompressionDefault() throws {
        let old = Data(#"{"storageRootPath":"/private-fixture","retentionDays":null,"maxStorageGB":null,"segmentDurationSeconds":300}"#.utf8)
        let decoded = try JSONDecoder().decode(StorageConfig.self, from: old)
        XCTAssertEqual(decoded.originalPixelCompression, .disabled)
        XCTAssertNil(decoded.retentionDays)
        XCTAssertNil(decoded.maxStorageGB)
        XCTAssertEqual(StorageConfig.default.originalPixelCompression, .disabled)
        for policy in OriginalPixelCompression.allCases {
            let configured = StorageConfig(storageRootPath: "/private-fixture", originalPixelCompression: policy)
            let roundTrip = try JSONDecoder().decode(StorageConfig.self, from: JSONEncoder().encode(configured))
            XCTAssertEqual(roundTrip.originalPixelCompression, policy)
        }
        let invalid = Data(#"{"storageRootPath":"/private-fixture","segmentDurationSeconds":300,"originalPixelCompression":"unknown"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(StorageConfig.self, from: invalid))
    }

    func testConfiguredWALWriterAppendsCompressedRecordsAndRestartRestoresExactPixels() async throws {
        for (index, policy) in OriginalPixelCompression.allCases.enumerated() {
            let directory = root.appendingPathComponent(policy.rawValue)
            let wal = WALManager(walRoot: directory, minimumFreeBytes: 0, availableBytes: { .max },
                                 originalPixelCompression: policy)
            let source = frame(value: UInt8(index + 1))
            let storeID = UUID()
            try await wal.configureOriginalStore(storeID: storeID)
            var session = try await wal.createSession(videoID: .init(value: 800 + Int64(index)))
            try await wal.appendFrame(source, to: &session)
            try await wal.registerFrameID(videoID: session.videoID, frameID: 300 + Int64(index), frameIndex: 0)
            try await wal.finalizeSession(session)
            let data = try Data(contentsOf: session.framesURL)
            XCTAssertEqual(version(data, at: 0), policy == .disabled ? 2 : 3)
            if policy != .disabled { XCTAssertLessThan(data.count, source.imageData.count) }
            let restarted = WALManager(walRoot: directory)
            let restored = try await restarted.readExactFrame(videoID: session.videoID, frameID: 300 + Int64(index),
                expectedTimestamp: source.timestamp, expectedWidth: source.width, expectedHeight: source.height,
                expectedDisplayID: source.metadata.displayID)
            XCTAssertEqual(restored.imageData, source.imageData)
            XCTAssertEqual(restored.bytesPerRow, source.bytesPerRow)
            XCTAssertEqual(restored.metadata, source.metadata)
            XCTAssertEqual(restored.timestamp, source.timestamp)
            let status = try await restarted.reconcileOriginalSpool { _ in .pending }
            XCTAssertEqual(status.retainedSessions, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: session.framesURL.path), "Compressed bytes are still pending originals")
        }
    }

    func testStorageManagerForwardsSelectionToActualSegmentWriter() async throws {
        for policy in [OriginalPixelCompression.lzfse, .lz4] {
            let directory = root.appendingPathComponent(policy.rawValue)
            let storage = StorageManager(storageRoot: directory)
            try await storage.initialize(config: .init(storageRootPath: directory.path, originalPixelCompression: policy))
            let writer = try await storage.createSegmentWriter()
            let source = frame()
            try await writer.appendFrame(source)
            let id = await writer.segmentID
            try await writer.cancel()
            let wal = await storage.getWALManager()
            let sessions = try await wal.listActiveSessions()
            let session = try XCTUnwrap(sessions.first { $0.videoID == id })
            XCTAssertEqual(version(try Data(contentsOf: session.framesURL), at: 0), 3)
            let reopened = WALManager(walRoot: directory.appendingPathComponent("wal"))
            let restored = try await reopened.readFrame(videoID: id, frameIndex: 0)
            XCTAssertEqual(restored.imageData, source.imageData)
            XCTAssertEqual(restored.metadata, source.metadata)
        }
    }

    func testPolicyChangesMakeMixedV2V3RecordsWithExactOffsetsAndMappedSeeks() async throws {
        let wal = WALManager(walRoot: root, minimumFreeBytes: 0, availableBytes: { .max })
        var session = try await wal.createSession(videoID: .init(value: 900))
        let policies: [OriginalPixelCompression] = [.disabled, .lzfse, .lz4, .disabled]
        var offsets: [UInt64] = []
        for (index, policy) in policies.enumerated() {
            offsets.append(UInt64(try Data(contentsOf: session.framesURL).count))
            await wal.configureOriginalPixelCompression(policy)
            try await wal.appendFrame(frame(value: UInt8(index + 1)), to: &session)
            try await wal.registerFrameID(videoID: session.videoID, frameID: 400 + Int64(index), frameIndex: index)
        }
        let bytes = try Data(contentsOf: session.framesURL)
        XCTAssertEqual(offsets.map { version(bytes, at: Int($0)) }, [2, 3, 3, 2])
        let reader = try WALRecoveryReader(session: session)
        let scan = try await reader.scan()
        XCTAssertNil(scan.tailError)
        XCTAssertEqual(scan.frameCount, 4)
        XCTAssertEqual(scan.sourceSize, UInt64(bytes.count))
        let restarted = WALManager(walRoot: root)
        for index in [3, 1, 0, 2] {
            let source = frame(value: UInt8(index + 1))
            let descriptor = try await reader.readRecord(at: offsets[index], index: index, loadPixels: false)
            XCTAssertEqual(descriptor?.databaseFrameID, 400 + Int64(index))
            XCTAssertTrue(try XCTUnwrap(descriptor).frame.imageData.isEmpty)
            XCTAssertEqual(descriptor?.nextOffset, index == 3 ? UInt64(bytes.count) : offsets[index + 1])
            let restored = try await restarted.readExactFrame(videoID: session.videoID, frameID: 400 + Int64(index),
                expectedTimestamp: source.timestamp, expectedWidth: source.width, expectedHeight: source.height,
                expectedDisplayID: source.metadata.displayID)
            XCTAssertEqual(restored.imageData, source.imageData)
        }
    }

    func testSpoolPressureUsesEncodedStoredBytesAndStillRejectsBeforeAppend() async throws {
        let wal = WALManager(walRoot: root, maximumSpoolBytes: 5_000, minimumFreeBytes: 0,
                             availableBytes: { .max }, originalPixelCompression: .lzfse)
        var session = try await wal.createSession(videoID: .init(value: 901))
        let source = frame()
        XCTAssertGreaterThan(source.imageData.count, 5_000)
        try await wal.appendFrame(source, to: &session)
        let committed = try Data(contentsOf: session.framesURL)
        let encoded = try WALFrameCodec.encode(source, path: "fixture", compression: .lzfse)
        XCTAssertEqual(Int64(committed.count), encoded.byteCount)
        await wal.configureOriginalPixelCompression(.disabled)
        do {
            try await wal.appendFrame(frame(value: 17), to: &session)
            XCTFail("Raw admission must still respect the same original spool ceiling")
        } catch let error as OriginalSpoolPressure {
            guard case .capacityLimit = error else { return XCTFail("Unexpected pressure: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: session.framesURL), committed)
        XCTAssertEqual(session.metadata.frameCount, 1)
        let status = try await wal.originalSpoolStatus()
        XCTAssertLessThan(status.retainedBytes, 5_000)
        XCTAssertGreaterThanOrEqual(status.retainedBytes, encoded.byteCount)
    }

    func testCompressedHeadroomIncludesReserveAndRejectsAnAdditionalRecord() async throws {
        let source = frame()
        let record = try WALFrameCodec.encode(source, path: "fixture", compression: .lz4)
        let headroom: Int64 = 20 * 1_024 * 1_024 * 1_024
        let wal = WALManager(walRoot: root, minimumFreeBytes: headroom,
                             availableBytes: { headroom + record.byteCount + 1_024 },
                             originalPixelCompression: .lz4)
        var session = try await wal.createSession(videoID: .init(value: 902))
        try await wal.appendFrame(source, to: &session)
        let before = try Data(contentsOf: session.framesURL)
        do {
            try await wal.appendFrame(source, to: &session)
            XCTFail("Second frame must include the first frame's acknowledgement reserve")
        } catch let error as OriginalSpoolPressure {
            guard case .freeSpaceHeadroom = error else { return XCTFail("Unexpected pressure: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: session.framesURL), before)
        XCTAssertEqual(session.metadata.frameCount, 1)
    }

    func testMetadataWriteFailureRollsBackAppendedBytesAndSessionStateBeforeRetry() async throws {
        guard geteuid() != 0 else { throw XCTSkip("A real directory write denial requires a non-root test process") }
        let wal = WALManager(walRoot: root, minimumFreeBytes: 0, availableBytes: { .max },
                             originalPixelCompression: .lzfse)
        var session = try await wal.createSession(videoID: .init(value: 903))
        try await wal.appendFrame(frame(), to: &session)
        let before = try Data(contentsOf: session.framesURL)
        let metadataURL = session.sessionDir.appendingPathComponent("metadata.json")
        let metadata = try Data(contentsOf: metadataURL)
        XCTAssertEqual(chmod(session.sessionDir.path, 0o500), 0)
        defer { _ = chmod(session.sessionDir.path, 0o700) }
        do {
            try await wal.appendFrame(frame(value: 17), to: &session)
            XCTFail("Atomic metadata replacement must fail in a non-writable directory")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: session.framesURL), before)
        XCTAssertEqual(try Data(contentsOf: metadataURL), metadata)
        XCTAssertEqual(session.metadata.frameCount, 1)
        XCTAssertEqual(chmod(session.sessionDir.path, 0o700), 0)
        try await wal.appendFrame(frame(value: 17), to: &session)
        let recovered = try await WALManager(walRoot: root).readFrames(from: session)
        XCTAssertEqual(recovered.count, 2)
        XCTAssertEqual(recovered.map(\.imageData), [frame().imageData, frame(value: 17).imageData])
        XCTAssertEqual(session.metadata.frameCount, 2)
    }

    func testOpeningDeniedFramesFileLeavesMetadataAndPreviousPixelsUnchanged() async throws {
        guard geteuid() != 0 else { throw XCTSkip("A real file write denial requires a non-root test process") }
        let wal = WALManager(walRoot: root, minimumFreeBytes: 0, availableBytes: { .max },
                             originalPixelCompression: .lz4)
        var session = try await wal.createSession(videoID: .init(value: 904))
        try await wal.appendFrame(frame(), to: &session)
        let before = try Data(contentsOf: session.framesURL)
        XCTAssertEqual(chmod(session.framesURL.path, 0o400), 0)
        defer { _ = chmod(session.framesURL.path, 0o600) }
        do {
            try await wal.appendFrame(frame(value: 7), to: &session)
            XCTFail("Opening the read-only frames file must fail")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: session.framesURL), before)
        XCTAssertEqual(session.metadata.frameCount, 1)
    }

    func testIncompressibleWriterFallsBackToChecksummedRawAndTamperingFailsClosed() async throws {
        var seed: UInt64 = 0x18aba334da48973e
        let noise = Data((0..<(272 * 64)).map { _ -> UInt8 in
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return UInt8(truncatingIfNeeded: seed)
        })
        let source = frame(pixels: noise)
        let wal = WALManager(walRoot: root, minimumFreeBytes: 0, availableBytes: { .max },
                             originalPixelCompression: .lzfse)
        var session = try await wal.createSession(videoID: .init(value: 905))
        try await wal.appendFrame(source, to: &session)
        let stored = try Data(contentsOf: session.framesURL)
        XCTAssertEqual(version(stored, at: 0), 3)
        XCTAssertEqual(stored[80], 0, "Native incompressible input must use the explicit raw fallback")
        let restored = try await WALManager(walRoot: root).readFrame(videoID: session.videoID, frameIndex: 0)
        XCTAssertEqual(restored.imageData, noise)
        var corrupted = stored
        corrupted[corrupted.count - 1] ^= 1
        try corrupted.write(to: session.framesURL)
        do {
            _ = try await WALManager(walRoot: root).readFrame(videoID: session.videoID, frameIndex: 0)
            XCTFail("The raw fallback still verifies every stored and decoded byte")
        } catch {}
    }

    func testAlreadyCancelledAppendDoesNotEncodeOrPersistARecord() async throws {
        let wal = WALManager(walRoot: root, minimumFreeBytes: 0, availableBytes: { .max },
                             originalPixelCompression: .lzfse)
        let created = try await wal.createSession(videoID: .init(value: 906))
        let source = frame()
        let task = Task {
            var session = created
            withUnsafeCurrentTask { $0?.cancel() }
            try await wal.appendFrame(source, to: &session)
        }
        do {
            try await task.value
            XCTFail("A cancelled producer cannot admit another original record")
        } catch is CancellationError {}
        XCTAssertTrue(try Data(contentsOf: created.framesURL).isEmpty)
        let sessions = try await wal.listActiveSessions()
        XCTAssertEqual(sessions.first?.metadata.frameCount, 0)
    }

    func testInvalidCountsAndBoundedMetadataRejectBeforeWriting() async throws {
        let wal = WALManager(walRoot: root, minimumFreeBytes: 0, availableBytes: { .max },
                             originalPixelCompression: .lz4)
        var session = try await wal.createSession(videoID: .init(value: 907))
        let metadataURL = session.sessionDir.appendingPathComponent("metadata.json")
        let metadata = try Data(contentsOf: metadataURL)
        for count in [-1, Int.max] {
            session.metadata.frameCount = count
            do {
                try await wal.appendFrame(frame(), to: &session)
                XCTFail("An invalid frame count cannot be incremented or published")
            } catch {}
            XCTAssertTrue(try Data(contentsOf: session.framesURL).isEmpty)
            XCTAssertEqual(try Data(contentsOf: metadataURL), metadata)
            XCTAssertEqual(session.metadata.frameCount, count)
        }
        session.metadata.frameCount = 0
        for bytes in [Data(), Data(repeating: 0x41, count: 65_537)] {
            try bytes.write(to: metadataURL)
            do {
                try await wal.appendFrame(frame(), to: &session)
                XCTFail("Invalid metadata cannot be retained in an unbounded rollback allocation")
            } catch {}
            XCTAssertTrue(try Data(contentsOf: session.framesURL).isEmpty)
            XCTAssertEqual(session.metadata.frameCount, 0)
        }
        try metadata.write(to: metadataURL)
        try await wal.appendFrame(frame(), to: &session)
        XCTAssertEqual(session.metadata.frameCount, 1)
    }

    func testChangingCompressionCannotAppendToASealedOriginalSession() async throws {
        let wal = WALManager(walRoot: root, minimumFreeBytes: 0, availableBytes: { .max },
                             originalPixelCompression: .lzfse)
        var session = try await wal.createSession(videoID: .init(value: 908))
        try await wal.appendFrame(frame(), to: &session)
        try await wal.finalizeSession(session)
        let bytes = try Data(contentsOf: session.framesURL)
        await wal.configureOriginalPixelCompression(.lz4)
        do {
            try await wal.appendFrame(frame(value: 7), to: &session)
            XCTFail("Compression selection does not reopen a sealed original")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: session.framesURL), bytes)
        XCTAssertEqual(session.metadata.frameCount, 1)
    }

    private func frame(value: UInt8 = 3, pixels: Data? = nil) -> CapturedFrame {
        let image = pixels ?? Data((0..<(272 * 64)).map { UInt8(($0 % 272) / 4) &+ value })
        return CapturedFrame(timestamp: Date(timeIntervalSince1970: 1_790_000_000 + Double(value)),
            imageData: image, width: 64, height: 64, bytesPerRow: 272,
            metadata: FrameMetadata(appBundleID: "com.test.compressed-original", appName: "Authored Δ 🦘", displayID: 7))
    }

    private func version(_ data: Data, at offset: Int) -> UInt16 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 8, as: UInt16.self) }.littleEndian
    }
}
