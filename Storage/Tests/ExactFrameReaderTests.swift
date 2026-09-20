import AVFoundation
import CoreGraphics
import Foundation
import XCTest
import Shared
@testable import Storage

/// Real HEVC inputs exercise the same decoder used for retained screen evidence.
final class ExactFrameReaderTests: XCTestCase {
    func testProcessingPixelReaderRejectsWrongIdentityAndEscapingArchivePaths() async throws {
        let url = try await makeVideo()
        let originalBytes = try Data(contentsOf: url)
        let root = url.deletingLastPathComponent()
        let storage = StorageManager(storageRoot: root)
        func video(id: Int64 = 17, path: String) -> VideoSegment {
            VideoSegment(id: VideoSegmentID(value: id), startTime: Date(), endTime: Date(),
                frameCount: 3, fileSizeBytes: Int64(originalBytes.count), relativePath: path, width: 64, height: 64)
        }
        let frame = FrameReference(id: FrameID(value: 4), timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            segmentID: AppSegmentID(value: 2), videoID: VideoSegmentID(value: 17), frameIndexInSegment: 1, metadata: .empty)
        let decoded = try await storage.readFrameForProcessing(frame: frame, video: video(path: url.lastPathComponent))
        XCTAssertEqual(decoded.imageData.count, 64 * 64 * 4)
        XCTAssertEqual(decoded.timestamp, frame.timestamp)
        await assertError(.integrityFailure) {
            _ = try await storage.readFrameForProcessing(frame: frame, video: video(id: 18, path: url.lastPathComponent))
        }
        await assertError(.integrityFailure) {
            _ = try await storage.readFrameForProcessing(frame: frame, video: video(path: "../\(url.lastPathComponent)"))
        }
        let otherRoot = try temporaryRoot()
        try FileManager.default.createSymbolicLink(at: otherRoot.appendingPathComponent("escape.mp4"), withDestinationURL: url)
        let otherStorage = StorageManager(storageRoot: otherRoot)
        await assertError(.integrityFailure) {
            _ = try await otherStorage.readFrameForProcessing(frame: frame, video: video(path: "escape.mp4"))
        }
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
    }

    func testExactSamplesReturnTheirDistinctPixelsIncludingExtensionlessRecordings() async throws {
        let video = try await makeVideo()
        let extensionless = video.deletingLastPathComponent().appendingPathComponent("1726000000000")
        try FileManager.default.moveItem(at: video, to: extensionless)
        for (index, expected) in [30, 120, 220].enumerated() {
            let image = try await read(extensionless, index: index)
            XCTAssertEqual(image.width, 64)
            XCTAssertEqual(image.height, 64)
            XCTAssertEqual(try centerGray(image), Double(expected), accuracy: 15)
        }
    }

    func testMissingEncodedSlotRejectsNearbyImageWhilePlaybackCanStillUseIt() async throws {
        let video = try await makeVideo(ticks: [0, 3, 6])
        let storage = StorageManager(storageRoot: video.deletingLastPathComponent())
        let playback = try await storage.readFrameFromPath(videoPath: video.path, frameIndex: 1,
                                                          enforceTimestampMatch: false)
        XCTAssertFalse(playback.isEmpty)
        await assertError(.integrityFailure) { _ = try await self.read(video, index: 1) }
    }

    func testWrongTimebaseAndDimensionsCannotResolveAFrame() async throws {
        let video = try await makeVideo()
        await assertError(.integrityFailure) { _ = try await self.read(video, index: 1, rate: 60) }
        await assertError(.integrityFailure) { _ = try await self.read(video, index: 0, width: 63) }
        await assertError(.integrityFailure) { _ = try await self.read(video, index: 0, height: 65) }
        await assertError(.integrityFailure) { _ = try await self.read(video, index: 10_000) }
    }

    func testUnknownDimensionsAndInvalidIndicesOrRatesFailExplicitly() async throws {
        let video = try await makeVideo()
        await assertError(.integrityFailure) { _ = try await self.read(video, index: 0, width: 0) }
        await assertError(.integrityFailure) { _ = try await self.read(video, index: 0, height: 0) }
        await assertError(.integrityFailure) { _ = try await self.read(video, index: -1) }
        for rate in [0, -30, Double.nan, Double.infinity] {
            await assertError(.integrityFailure) { _ = try await self.read(video, index: 0, rate: rate) }
        }
    }

    func testMissingAndUnfinishedRecordingsAreExplicitlyUnavailable() async throws {
        let root = try temporaryRoot()
        let missing = root.appendingPathComponent("missing.mp4")
        await assertError(.recordingMissing) { _ = try await self.read(missing, index: 0) }
        let empty = root.appendingPathComponent("unfinished.mp4")
        try Data().write(to: empty)
        await assertError(.frameFinalising) { _ = try await self.read(empty, index: 0) }
        try Data("not a media container".utf8).write(to: empty)
        await assertError(.integrityFailure) { _ = try await self.read(empty, index: 0) }
    }

    func testInvalidActualTimeRetriesWithFreshDecoderAndNeverPublishesUnprovedImage() async throws {
        let video = try await makeVideo()
        // Faults are injected only into the timestamp returned by the real decoder.
        // The image itself always comes from the real encoded asset.
        for time in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity,
                     CMTime(value: 0, timescale: 30)] {
            let probe = DecoderProbe(reportedTimes: [time, time])
            await assertError(.integrityFailure) {
                _ = try await ExactFrameReader.readFrame(videoURL: video, frameIndex: 1,
                                                        frameRate: 30, expectedWidth: 64, expectedHeight: 64,
                                                        decoder: { try probe.decode($0, $1) })
            }
            XCTAssertEqual(probe.calls, 2)
            XCTAssertFalse(probe.ranOnMainThread)
        }
    }

    func testFreshRetryCanRecoverAfterInvalidCachedDecoderOutput() async throws {
        let video = try await makeVideo()
        let probe = DecoderProbe(reportedTimes: [.invalid, nil])
        let image = try await ExactFrameReader.readFrame(videoURL: video, frameIndex: 1,
                                                        frameRate: 30, expectedWidth: 64, expectedHeight: 64,
                                                        decoder: { try probe.decode($0, $1) })
        XCTAssertEqual(probe.calls, 2)
        XCTAssertEqual(try centerGray(image), 120, accuracy: 15)
        XCTAssertFalse(probe.ranOnMainThread)
    }

    func testSubTenMillisecondNeighborIsStillTheWrongSample() async throws {
        let video = try await makeVideo(timescale: 120)
        let exact = try await read(video, index: 1, rate: 120)
        XCTAssertEqual(try centerGray(exact), 120, accuracy: 15)
        let probe = DecoderProbe(reportedTimes: [.zero, .zero])
        await assertError(.integrityFailure) {
            _ = try await ExactFrameReader.readFrame(videoURL: video, frameIndex: 1,
                                                     frameRate: 120, expectedWidth: 64, expectedHeight: 64,
                                                     decoder: { try probe.decode($0, $1) })
        }
    }

    func testCancelledReadNeverPublishesAnImage() async throws {
        let video = try await makeVideo()
        let task = Task {
            return try await self.read(video, index: 0)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled exact read must not publish an image")
        } catch is CancellationError {
            // Cancellation before entry is also valid.
        } catch let error as ExactFrameReadError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testCancellationDuringDecodeDiscardsAlreadyDecodedPixels() async throws {
        let video = try await makeVideo()
        await assertError(.cancelled) {
            _ = try await ExactFrameReader.readFrame(videoURL: video, frameIndex: 1,
                frameRate: 30, expectedWidth: 64, expectedHeight: 64, decoder: { url, time in
                    let decoded = try ExactFrameReader.decodeFrame(videoURL: url, at: time)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return decoded
                })
        }
    }

    func testRecordingChangedDuringDecodeCannotPublishTheOldImage() async throws {
        let video = try await makeVideo()
        await assertError(.frameFinalising) {
            _ = try await ExactFrameReader.readFrame(videoURL: video, frameIndex: 1,
                frameRate: 30, expectedWidth: 64, expectedHeight: 64, decoder: { url, time in
                    let decoded = try ExactFrameReader.decodeFrame(videoURL: url, at: time)
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data([0]))
                    return decoded
                })
        }
    }

    private func read(_ video: URL, index: Int, rate: Double = 30,
                      width: Int = 64, height: Int = 64) async throws -> CGImage {
        try await ExactFrameReader.readFrame(videoURL: video, frameIndex: index,
                                             frameRate: rate, expectedWidth: width, expectedHeight: height)
    }

    private func makeVideo(ticks: [Int64] = [0, 1, 2], timescale: CMTimeScale = 30) async throws -> URL {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("real-samples.mp4")
        let encoder = HEVCEncoder()
        try await encoder.initialize(width: 64, height: 64, config: .default,
                                     outputURL: url, segmentStartTime: Date())
        for (index, tick) in ticks.enumerated() {
            let value = [UInt8(30), 120, 220][index]
            var pixels = Data(count: 64 * 64 * 4)
            pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    bytes[offset] = value
                    bytes[offset + 1] = value
                    bytes[offset + 2] = value
                    bytes[offset + 3] = 255
                }
            }
            let frame = CapturedFrame(imageData: pixels, width: 64, height: 64, bytesPerRow: 256)
            let buffer = try FrameConverter.createPixelBuffer(from: frame)
            try await encoder.encode(pixelBuffer: buffer, timestamp: CMTime(value: tick, timescale: timescale))
        }
        try await encoder.finalize()
        return url
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("exact-media-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func centerGray(_ image: CGImage) throws -> Double {
        var bytes = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw XCTSkip("Could not create a CoreGraphics inspection context")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Double(bytes[0])
    }

    private func assertError(_ expected: ExactFrameReadError,
                             file: StaticString = #filePath, line: UInt = #line,
                             operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected exact-media error \(expected)", file: file, line: line)
        } catch let error as ExactFrameReadError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line)
        }
    }
}

private final class DecoderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let reportedTimes: [CMTime?]
    private var callCount = 0
    private var onMain = false
    init(reportedTimes: [CMTime?]) { self.reportedTimes = reportedTimes }
    var calls: Int { lock.withLock { callCount } }
    var ranOnMainThread: Bool { lock.withLock { onMain } }

    func decode(_ url: URL, _ requested: CMTime) throws -> ExactDecodedFrame {
        let reportedTime = lock.withLock { () -> CMTime? in
            let index = callCount
            callCount += 1
            onMain = onMain || Thread.isMainThread
            return reportedTimes[min(index, reportedTimes.count - 1)]
        }
        let decoded = try ExactFrameReader.decodeFrame(videoURL: url, at: requested)
        return ExactDecodedFrame(image: decoded.image, actualTime: reportedTime ?? decoded.actualTime)
    }
}
