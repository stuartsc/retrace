import Foundation
import XCTest
import Shared
@testable import Storage

final class ExactWALFrameTests: XCTestCase {
    func testExactMapSelectsDistinctFrameAmongIdenticalTimestamps() async throws {
        let fixture = try await makeWAL()
        let first = try await read(fixture, frameID: 501)
        let second = try await read(fixture, frameID: 502)
        XCTAssertEqual(first.imageData, pixels(30))
        XCTAssertEqual(second.imageData, pixels(220))
        XCTAssertNotEqual(first.imageData, second.imageData)
    }

    func testMissingMapCannotFallBackToIndexAndLaterMappingBecomesReadable() async throws {
        let fixture = try await makeWAL(mapped: false)
        await assertError(.frameFinalising) { _ = try await self.read(fixture, frameID: 502) }
        try await fixture.manager.registerFrameID(videoID: fixture.session.videoID, frameID: 502, frameIndex: 1)
        let image = try await read(fixture, frameID: 502)
        XCTAssertEqual(image.imageData, pixels(220))
        await assertError(.frameFinalising) { _ = try await self.read(fixture, frameID: 999) }
    }

    func testTimestampAllowsOnlyDatabaseMillisecondPrecision() async throws {
        let fixture = try await makeWAL()
        let storedMilliseconds = Date(timeIntervalSince1970: floor(fixture.timestamp.timeIntervalSince1970 * 1000) / 1000)
        let image = try await read(fixture, frameID: 501, timestamp: storedMilliseconds)
        XCTAssertEqual(image.imageData, pixels(30))
        for delta in [-0.0011, 0.0011, 1] {
            await assertError(.integrityFailure) {
                _ = try await self.read(fixture, frameID: 501,
                                       timestamp: fixture.timestamp.addingTimeInterval(delta))
            }
        }
    }

    func testDimensionsDisplayAndUnknownIdentityFailClosed() async throws {
        let fixture = try await makeWAL()
        await assertError(.integrityFailure) { _ = try await self.read(fixture, frameID: 501, width: 63) }
        await assertError(.integrityFailure) { _ = try await self.read(fixture, frameID: 501, height: 65) }
        await assertError(.integrityFailure) { _ = try await self.read(fixture, frameID: 501, width: 0) }
        await assertError(.integrityFailure) { _ = try await self.read(fixture, frameID: 501, displayID: 2) }
        await assertError(.integrityFailure) { _ = try await self.read(fixture, frameID: 0) }
        await assertError(.integrityFailure) {
            _ = try await self.read(fixture, frameID: 501, timestamp: Date(timeIntervalSince1970: .nan))
        }
    }

    func testConflictingIdentityMapAndInteriorPayloadOffsetsAreRejected() async throws {
        let fixture = try await makeWAL()
        let map = fixture.session.sessionDir.appendingPathComponent("frame_id_map.bin")
        let original = try Data(contentsOf: map)
        var conflicting = original
        conflicting.append(record(id: 501, offset: UInt64(36 + 64 * 64 * 4)))
        try conflicting.write(to: map)
        await assertError(.integrityFailure) { _ = try await self.read(fixture, frameID: 501) }
        try record(id: 501, offset: 40).write(to: map)
        await assertError(.integrityFailure) { _ = try await self.read(fixture, frameID: 501) }
        try record(id: 501, offset: UInt64.max).write(to: map)
        await assertError(.integrityFailure) { _ = try await self.read(fixture, frameID: 501) }
    }

    func testOneOffsetCannotProveTwoDatabaseFrames() async throws {
        let fixture = try await makeWAL()
        let map = fixture.session.sessionDir.appendingPathComponent("frame_id_map.bin")
        var data = record(id: 501, offset: 0)
        data.append(record(id: 502, offset: 0))
        try data.write(to: map)
        await assertError(.integrityFailure) { _ = try await self.read(fixture, frameID: 502) }
    }

    func testIncompleteMapTailRetainsProvedPrefixButCannotInventMissingIdentity() async throws {
        let fixture = try await makeWAL()
        let map = fixture.session.sessionDir.appendingPathComponent("frame_id_map.bin")
        var data = try Data(contentsOf: map)
        data.append(Data([0x03, 0x02]))
        try data.write(to: map)
        let image = try await read(fixture, frameID: 502)
        XCTAssertEqual(image.imageData, pixels(220))
        await assertError(.frameFinalising) { _ = try await self.read(fixture, frameID: 999) }
    }

    func testCorruptPayloadSizesAreRejectedWithoutUnboundedAllocation() async throws {
        let fixture = try await makeWAL()
        var data = try Data(contentsOf: fixture.session.framesURL)
        var invalidSize = UInt32.max
        withUnsafeBytes(of: &invalidSize) { data.replaceSubrange(20..<24, with: $0) }
        try data.write(to: fixture.session.framesURL)
        await assertError(.integrityFailure) { _ = try await self.read(fixture, frameID: 501) }
    }

    func testTruncatedRequestedPixelsAreUnavailableAndRemovedRecordingIsMissing() async throws {
        let fixture = try await makeWAL()
        let handle = try FileHandle(forWritingTo: fixture.session.framesURL)
        try handle.truncate(atOffset: 100)
        try handle.close()
        await assertError(.integrityFailure) { _ = try await self.read(fixture, frameID: 501) }
        try FileManager.default.removeItem(at: fixture.session.sessionDir)
        await assertError(.recordingMissing) { _ = try await self.read(fixture, frameID: 501) }
    }

    func testCancelledWALReadDoesNotPublishPixels() async throws {
        let fixture = try await makeWAL()
        let task = Task { try await self.read(fixture, frameID: 501) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled evidence must not publish pixels")
        } catch let error as ExactFrameReadError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    private struct Fixture {
        let manager: WALManager
        let session: WALSession
        let timestamp: Date
    }

    private func makeWAL(mapped: Bool = true) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("exact-wal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let manager = WALManager(walRoot: root)
        var session = try await manager.createSession(videoID: VideoSegmentID(value: 1726000000000))
        let timestamp = Date(timeIntervalSince1970: 1_726_000_000.0006)
        for value in [UInt8(30), 220] {
            let frame = CapturedFrame(timestamp: timestamp, imageData: pixels(value), width: 64,
                                      height: 64, bytesPerRow: 256,
                                      metadata: FrameMetadata(displayID: 1))
            try await manager.appendFrame(frame, to: &session)
        }
        if mapped {
            try await manager.registerFrameID(videoID: session.videoID, frameID: 501, frameIndex: 0)
            try await manager.registerFrameID(videoID: session.videoID, frameID: 502, frameIndex: 1)
        }
        return Fixture(manager: manager, session: session, timestamp: timestamp)
    }

    private func read(_ fixture: Fixture, frameID: Int64, timestamp: Date? = nil,
                      width: Int = 64, height: Int = 64, displayID: UInt32 = 1) async throws -> CapturedFrame {
        try await fixture.manager.readExactFrame(videoID: fixture.session.videoID, frameID: frameID,
                                                 expectedTimestamp: timestamp ?? fixture.timestamp,
                                                 expectedWidth: width, expectedHeight: height,
                                                 expectedDisplayID: displayID)
    }

    private func pixels(_ value: UInt8) -> Data { Data(repeating: value, count: 64 * 64 * 4) }

    private func record(id: Int64, offset: UInt64) -> Data {
        var id = id
        var offset = offset
        var data = Data()
        withUnsafeBytes(of: &id) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &offset) { data.append(contentsOf: $0) }
        return data
    }

    private func assertError(_ expected: ExactFrameReadError,
                             file: StaticString = #filePath, line: UInt = #line,
                             operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected exact-WAL error \(expected)", file: file, line: line)
        } catch let error as ExactFrameReadError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line)
        }
    }
}
