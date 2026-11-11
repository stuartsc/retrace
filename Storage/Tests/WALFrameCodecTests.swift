import CryptoKit
import Foundation
import XCTest
import Shared
@testable import Storage

final class WALFrameCodecTests: XCTestCase {
    func testCompleteMetadataSurvivesRestartAndEveryReader() async throws {
        let (root, manager, initial) = try await fixture()
        var session = initial
        let source = frame(metadata: completeMetadata())
        try await manager.appendFrame(source, to: &session)
        try await manager.registerFrameID(videoID: session.videoID, frameID: 501, frameIndex: 0)
        try await manager.finalizeSession(session)
        let reopened = WALManager(walRoot: root)
        let direct = try await reopened.readFrame(videoID: session.videoID, frameIndex: 0)
        let mapped = try await reopened.readFrame(videoID: session.videoID, frameID: 501, fallbackFrameIndex: 99)
        let exact = try await reopened.readExactFrame(videoID: session.videoID, frameID: 501,
            expectedTimestamp: source.timestamp, expectedWidth: 64, expectedHeight: 64, expectedDisplayID: 7)
        let all = try await reopened.readFrames(from: session)
        let recovery = try await WALRecoveryReader(session: session).readRecord(at: 0, index: 0, loadPixels: true)
        for recovered in [direct, mapped, exact, try XCTUnwrap(all.first), try XCTUnwrap(recovery).frame] {
            XCTAssertEqual(recovered.imageData, source.imageData)
            XCTAssertEqual(recovered.timestamp, source.timestamp)
            XCTAssertEqual(recovered.metadata, source.metadata)
        }
        XCTAssertTrue(session.sessionDir.lastPathComponent.hasPrefix("original_segment_"))
    }

    func testCrashBeforeDatabaseRegistrationRetainsPolicyAndContext() async throws {
        let (root, manager, initial) = try await fixture()
        var session = initial
        let source = frame(metadata: completeMetadata())
        try await manager.appendFrame(source, to: &session)
        let restarted = WALManager(walRoot: root)
        let sessions = try await restarted.listRecoverableSessions()
        let retained = try XCTUnwrap(sessions.first)
        let reader = try WALRecoveryReader(session: retained)
        let descriptor = try await reader.readRecord(at: 0, index: 0, loadPixels: false)
        XCTAssertNil(descriptor?.databaseFrameID)
        XCTAssertEqual(descriptor?.frame.metadata, source.metadata)
        XCTAssertTrue(try XCTUnwrap(descriptor).frame.imageData.isEmpty)
        XCTAssertEqual(descriptor?.frame.metadata.capturePolicySHA256, source.metadata.capturePolicySHA256)
    }

    func testLegacyRecordAndMixedVersionOffsetsRemainReadable() async throws {
        let (root, manager, initial) = try await fixture()
        var session = initial
        let legacy = frame(metadata: FrameMetadata(appBundleID: "test.legacy", appName: "Legacy Δ", displayID: 7))
        let bytes = legacyRecord(legacy)
        try bytes.write(to: session.framesURL)
        session.metadata.frameCount = 1
        let current = frame(value: 180, metadata: completeMetadata())
        try await manager.appendFrame(current, to: &session)
        try await manager.registerFrameID(videoID: session.videoID, frameID: 501, frameIndex: 0)
        try await manager.registerFrameID(videoID: session.videoID, frameID: 502, frameIndex: 1)
        let reopened = WALManager(walRoot: root)
        let all = try await reopened.readFrames(from: session)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].metadata, legacy.metadata)
        XCTAssertNil(all[0].metadata.capturePolicySHA256)
        XCTAssertNil(all[0].metadata.captureContext)
        XCTAssertEqual(all[1].metadata, current.metadata)
        let exact = try await reopened.readExactFrame(videoID: session.videoID, frameID: 502,
            expectedTimestamp: current.timestamp, expectedWidth: 64, expectedHeight: 64, expectedDisplayID: 7)
        XCTAssertEqual(exact.imageData, current.imageData)
        let reader = try WALRecoveryReader(session: session)
        let first = try await reader.readRecord(at: 0, index: 0, loadPixels: false)
        XCTAssertEqual(first?.nextOffset, UInt64(bytes.count))
        let second = try await reader.readRecord(at: UInt64(bytes.count), index: 1, loadPixels: false)
        XCTAssertEqual(second?.databaseFrameID, 502)
        XCTAssertEqual(second?.frame.metadata, current.metadata)
    }

    func testUnknownVersionReservedBitsLengthsAndMetadataHashFailClosed() async throws {
        let (root, manager, initial) = try await fixture()
        var session = initial
        try await manager.appendFrame(frame(metadata: completeMetadata()), to: &session)
        try await manager.registerFrameID(videoID: session.videoID, frameID: 501, frameIndex: 0)
        let original = try Data(contentsOf: session.framesURL)
        // The format is a protocol: marker8/version2/reserved2/length4/identity28/hash32.
        XCTAssertEqual(original.prefix(8), scalar(UInt64(0x7ff8_5254_5741_4c32)))
        for (range, replacement) in [(8..<10, scalar(UInt16(99))), (10..<12, scalar(UInt16(1))),
                                     (12..<16, scalar(UInt32(0))), (12..<16, scalar(UInt32(65_537))),
                                     (36..<40, scalar(UInt32.max)), (40..<44, scalar(UInt32(8))),
                                     (44..<76, Data(repeating: 0, count: 32))] {
            var corrupted = original
            corrupted.replaceSubrange(range, with: replacement)
            try corrupted.write(to: session.framesURL)
            let reopened = WALManager(walRoot: root)
            await assertReadFailure { _ = try await reopened.readFrames(from: session) }
            await assertReadFailure { _ = try await reopened.readFrame(videoID: session.videoID, frameIndex: 0) }
            await assertReadFailure {
                _ = try await reopened.readExactFrame(videoID: session.videoID, frameID: 501,
                    expectedTimestamp: self.frame().timestamp, expectedWidth: 64, expectedHeight: 64, expectedDisplayID: 7)
            }
            let scan = try await WALRecoveryReader(session: session).scan()
            XCTAssertEqual(scan.frameCount, 0)
            XCTAssertNotNil(scan.tailError)
        }
    }

    func testChecksummedButMalformedMetadataCannotBecomeLegacyNil() async throws {
        let (_, manager, initial) = try await fixture()
        var session = initial
        try await manager.appendFrame(frame(metadata: completeMetadata()), to: &session)
        let original = try Data(contentsOf: session.framesURL)
        let metadataLength = Int(original.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) })
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: original.subdata(in: 76..<(76 + metadataLength))) as? [String: Any])
        var wrongDisplay = valid; wrongDisplay["displayID"] = 8
        var malformedPolicy = valid; malformedPolicy["capturePolicySHA256"] = String(repeating: "A", count: 64)
        for payload in [Data("{}".utf8), Data("null".utf8), Data("[1,2]".utf8),
                        try JSONSerialization.data(withJSONObject: wrongDisplay),
                        try JSONSerialization.data(withJSONObject: malformedPolicy)] {
            var corrupted = original.prefix(76)
            corrupted.replaceSubrange(12..<16, with: scalar(UInt32(payload.count)))
            corrupted.replaceSubrange(44..<76, with: Data(SHA256.hash(data: payload)))
            corrupted.append(payload)
            corrupted.append(original.suffix(64 * 64 * 4))
            try corrupted.write(to: session.framesURL)
            let scan = try await WALRecoveryReader(session: session).scan()
            XCTAssertEqual(scan.frameCount, 0)
            XCTAssertNotNil(scan.tailError)
        }
    }

    func testInvalidPolicyAndOversizedCompleteMetadataAreRejectedBeforeAppend() async throws {
        let (_, manager, initial) = try await fixture()
        var session = initial
        for metadata in [FrameMetadata(displayID: 7, capturePolicySHA256: "not-a-digest"),
                         FrameMetadata(displayID: 7, capturePolicySHA256: String(repeating: "A", count: 64)),
                         FrameMetadata(redactionReason: String(repeating: "a", count: 65_536), displayID: 7)] {
            await assertReadFailure { try await manager.appendFrame(self.frame(metadata: metadata), to: &session) }
            XCTAssertTrue(try Data(contentsOf: session.framesURL).isEmpty)
            XCTAssertEqual(session.metadata.frameCount, 0)
        }
    }

    func testAdmissionCountsFullMetadataBeforeSpendingFreeHeadroom() async throws {
        let root = try temporaryRoot()
        let headroom: Int64 = 20 * 1024 * 1024 * 1024
        let manager = WALManager(walRoot: root, minimumFreeBytes: headroom,
                                 availableBytes: { headroom + 64 * 64 * 4 + 36 + 1_024 + 100 })
        var session = try await manager.createSession(videoID: VideoSegmentID(value: 704))
        let source = frame(metadata: FrameMetadata(redactionReason: String(repeating: "x", count: 8_192),
                                                   displayID: 7, capturePolicySHA256: String(repeating: "a", count: 64)))
        do {
            try await manager.appendFrame(source, to: &session)
            XCTFail("Complete metadata bytes must participate in pre-write headroom admission")
        } catch let pressure as OriginalSpoolPressure {
            guard case .freeSpaceHeadroom = pressure else { return XCTFail("Unexpected pressure") }
        }
        XCTAssertTrue(try Data(contentsOf: session.framesURL).isEmpty)
    }

    func testMappedReadRejectsValidLookingRecordInsidePixels() async throws {
        let (root, manager, initial) = try await fixture()
        var session = initial
        let nested = CapturedFrame(timestamp: frame().timestamp, imageData: Data(repeating: 1, count: 4),
            width: 1, height: 1, bytesPerRow: 4, metadata: FrameMetadata(displayID: 7))
        var pixels = legacyRecord(nested)
        pixels.append(Data(repeating: 0, count: 64 * 64 * 4 - pixels.count))
        let outer = CapturedFrame(timestamp: frame().timestamp, imageData: pixels,
            width: 64, height: 64, bytesPerRow: 256, metadata: completeMetadata())
        try await manager.appendFrame(outer, to: &session)
        let binary = try Data(contentsOf: session.framesURL)
        let length = binary.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }
        var map = scalar(Int64(501))
        map.append(scalar(UInt64(76) + UInt64(length)))
        try map.write(to: session.sessionDir.appendingPathComponent("frame_id_map.bin"))
        let reopened = WALManager(walRoot: root)
        await assertReadFailure {
            _ = try await reopened.readFrame(videoID: session.videoID, frameID: 501, fallbackFrameIndex: 0)
        }
    }

    func testValidMixedPrefixMapsAndReadsBeforeDamagedTail() async throws {
        let (root, manager, initial) = try await fixture()
        var session = initial
        let legacy = frame(metadata: FrameMetadata(appBundleID: "test.legacy", displayID: 7))
        try legacyRecord(legacy).write(to: session.framesURL)
        session.metadata.frameCount = 1
        let current = frame(value: 180, metadata: completeMetadata())
        try await manager.appendFrame(current, to: &session)
        let handle = try FileHandle(forWritingTo: session.framesURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1, 2, 3]))
        try handle.close()
        let damaged = try Data(contentsOf: session.framesURL)
        let restarted = WALManager(walRoot: root)
        try await restarted.registerFrameID(videoID: session.videoID, frameID: 501, frameIndex: 0)
        try await restarted.registerFrameID(videoID: session.videoID, frameID: 502, frameIndex: 1)
        let first = try await restarted.readFrame(videoID: session.videoID, frameIndex: 0)
        let second = try await restarted.readFrame(videoID: session.videoID, frameID: 502, fallbackFrameIndex: 99)
        let exact = try await restarted.readExactFrame(videoID: session.videoID, frameID: 502,
            expectedTimestamp: current.timestamp, expectedWidth: 64, expectedHeight: 64, expectedDisplayID: 7)
        XCTAssertEqual(first.metadata, legacy.metadata)
        XCTAssertEqual(second.metadata, current.metadata)
        XCTAssertEqual(exact.imageData, current.imageData)
        let map = session.sessionDir.appendingPathComponent("frame_id_map.bin")
        let before = try Data(contentsOf: map)
        await assertReadFailure {
            try await restarted.registerFrameID(videoID: session.videoID, frameID: 503, frameIndex: 2)
        }
        await assertReadFailure { _ = try await restarted.readFrames(from: session) }
        XCTAssertEqual(try Data(contentsOf: map), before)
        XCTAssertEqual(try Data(contentsOf: session.framesURL), damaged)
        let scan = try await WALRecoveryReader(session: session).scan()
        XCTAssertEqual(scan.frameCount, 2)
        XCTAssertNotNil(scan.tailError)
    }

    func testCorruptionBeforeRequestedRecordCannotBeSkippedAfterPriorRead() async throws {
        let (_, manager, initial) = try await fixture()
        var session = initial
        try await manager.appendFrame(frame(metadata: completeMetadata()), to: &session)
        try await manager.appendFrame(frame(value: 180, metadata: completeMetadata()), to: &session)
        try await manager.registerFrameID(videoID: session.videoID, frameID: 501, frameIndex: 0)
        try await manager.registerFrameID(videoID: session.videoID, frameID: 502, frameIndex: 1)
        _ = try await manager.readFrame(videoID: session.videoID, frameID: 502, fallbackFrameIndex: 1)
        var damaged = try Data(contentsOf: session.framesURL)
        damaged[44] ^= 0xff
        try damaged.write(to: session.framesURL)
        let map = session.sessionDir.appendingPathComponent("frame_id_map.bin")
        let before = try Data(contentsOf: map)
        await assertReadFailure {
            try await manager.registerFrameID(videoID: session.videoID, frameID: 502, frameIndex: 1)
        }
        await assertReadFailure { _ = try await manager.readFrame(videoID: session.videoID, frameIndex: 1) }
        await assertReadFailure {
            _ = try await manager.readFrame(videoID: session.videoID, frameID: 502, fallbackFrameIndex: 1)
        }
        await assertReadFailure {
            _ = try await manager.readExactFrame(videoID: session.videoID, frameID: 502,
                expectedTimestamp: self.frame().timestamp, expectedWidth: 64, expectedHeight: 64, expectedDisplayID: 7)
        }
        XCTAssertEqual(try Data(contentsOf: map), before)
    }

    private func completeMetadata() -> FrameMetadata {
        let context = ActivityContext(appBundleID: "test.codec", appName: "Café", processID: 42,
            processGeneration: "42-start", windowID: 73, windowGeneration: "73-start", windowTitle: "Proposal Δ",
            displayID: 7, documentID: "doc-42000", paneID: "main", safeURL: "https://example.test/proposal", uncertainty: ["authored"])
        let identity = ActivityCaptureIdentity(activityEventID: UUID(), sessionID: UUID(), processID: 42,
            processGeneration: "42-start", windowID: 73, windowGeneration: "73-start", captureMonotonicTime: 120.25,
            documentID: "doc-42000", paneID: "main")
        return FrameMetadata(appBundleID: "test.codec", appName: "Café", windowName: "Proposal Δ",
            browserURL: "https://example.test/proposal", redactionReason: "authored reason", displayID: 7,
            captureContext: context, captureMonotonicTime: 120.25, activityIdentity: identity,
            capturePolicySHA256: String(repeating: "a", count: 64))
    }

    private func frame(value: UInt8 = 70, metadata: FrameMetadata = FrameMetadata(displayID: 7)) -> CapturedFrame {
        CapturedFrame(timestamp: Date(timeIntervalSince1970: 1_780_000_000.125),
            imageData: Data(repeating: value, count: 64 * 64 * 4), width: 64, height: 64, bytesPerRow: 256, metadata: metadata)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wal-codec-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func fixture() async throws -> (URL, WALManager, WALSession) {
        let root = try temporaryRoot()
        let manager = WALManager(walRoot: root, minimumFreeBytes: 0, availableBytes: { Int64.max })
        let session = try await manager.createSession(videoID: VideoSegmentID(value: 705))
        return (root, manager, session)
    }

    private func scalar<T>(_ value: T) -> Data {
        var value = value
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private func legacyRecord(_ frame: CapturedFrame) -> Data {
        var data = scalar(frame.timestamp.timeIntervalSince1970)
        for value in [UInt32(frame.width), UInt32(frame.height), UInt32(frame.bytesPerRow), UInt32(frame.imageData.count), frame.metadata.displayID] {
            data.append(scalar(value))
        }
        let strings = [frame.metadata.appBundleID, frame.metadata.appName, frame.metadata.windowName, frame.metadata.browserURL]
        for value in strings { data.append(scalar(UInt16(value?.utf8.count ?? 0))) }
        for value in strings { data.append(Data((value ?? "").utf8)) }
        data.append(frame.imageData)
        return data
    }

    private func assertReadFailure(file: StaticString = #filePath, line: UInt = #line,
                                   _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Malformed or incomplete WAL must fail closed", file: file, line: line)
        } catch { }
    }
}
