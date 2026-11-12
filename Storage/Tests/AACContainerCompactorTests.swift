import AudioToolbox
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Shared
import XCTest
@testable import Storage

final class AACContainerCompactorTests: XCTestCase {
    func testNativeAuthoredAACPaddingRemovalPreservesPacketsTimingPCMAndSeeking() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aac-padding-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pcm = try authoredPCM()
        let doubled = pcm + pcm
        let writer = AudioSegmentWriter(storageRoot: root)
        for frames in [160_000, 240_000, doubled.count / 2] {
            let written = try await writer.writeFullBatch(audioData: doubled.prefix(frames * 2),
                timestamp: Date(timeIntervalSince1970: 1_700_000_000), source: .microphone)
            let originalURL = root.appendingPathComponent(written.filePath)
            let original = try Data(contentsOf: originalURL)
            let compacted = try XCTUnwrap(AACContainerCompactor.compact(original), "Native AAC shape must be supported in this comparison")
            let compactURL = root.appendingPathComponent("compact-\(frames).m4a")
            try compacted.write(to: compactURL, options: .withoutOverwriting)
            XCTAssertLessThan(compacted.count, original.count)
            XCTAssertLessThanOrEqual(Double(compacted.count) / Double(original.count), 0.8,
                "Authored byte savings must meet the promotion gate before enabling this option")
            XCTAssertEqual(try packetSnapshot(originalURL), try packetSnapshot(compactURL),
                "AAC packets, cookie and valid/priming/remainder frames must be identical")
            let before = try decodedPCM(originalURL)
            XCTAssertEqual(before, try decodedPCM(originalURL), "An unstable native control cannot establish bit-exact acceptance")
            XCTAssertEqual(before, try decodedPCM(compactURL), "Padding removal must not change decoded samples")
            XCTAssertEqual(before.count, frames * 2)
            for start in [0, 1_024, frames / 2, frames - 1_024] {
                XCTAssertEqual(try decodedPCM(originalURL, start: Int64(start), count: 1_024),
                    try decodedPCM(compactURL, start: Int64(start), count: 1_024), "Exact seeks must stay aligned")
            }
            let originalTracks = try await AVURLAsset(url: originalURL).loadTracks(withMediaType: .audio)
            let compactTracks = try await AVURLAsset(url: compactURL).loadTracks(withMediaType: .audio)
            let originalTrack = try XCTUnwrap(originalTracks.first)
            let compactTrack = try XCTUnwrap(compactTracks.first)
            let beforeTime = try await originalTrack.load(.timeRange), afterTime = try await compactTrack.load(.timeRange)
            XCTAssertEqual(CMTimeCompare(beforeTime.start, afterTime.start), 0)
            XCTAssertEqual(CMTimeCompare(beforeTime.duration, afterTime.duration), 0)
            XCTAssertNil(AACContainerCompactor.compact(compacted), "Second compaction is a no-op")
            print("AAC_PADDING_AUTHORED frames=\(frames) originalBytes=\(original.count) compactBytes=\(compacted.count) savedBytes=\(original.count - compacted.count)")
        }
    }

    func testUnknownMalformedAndNonzeroPaddingRemainUntouched() throws {
        let original = try fixtureAAC()
        XCTAssertNotNil(AACContainerCompactor.compact(original))
        XCTAssertNil(AACContainerCompactor.compact(Data()))
        XCTAssertNil(AACContainerCompactor.compact(original.prefix(7)))
        XCTAssertNil(AACContainerCompactor.compact(Data(repeating: 0, count: 2 * 1_024 * 1_024 + 1)))
        var invalid = original
        invalid[0] = 0xff; invalid[1] = 0xff; invalid[2] = 0xff; invalid[3] = 0xff
        XCTAssertNil(AACContainerCompactor.compact(invalid))
        let free = try XCTUnwrap(original.range(of: Data("free".utf8)))
        invalid = original; invalid[free.upperBound] = 1
        XCTAssertNil(AACContainerCompactor.compact(invalid), "Do not remove nonzero or unknown payloads")
        invalid = original; invalid.replaceSubrange(free, with: Data("skip".utf8))
        XCTAssertNil(AACContainerCompactor.compact(invalid))
        let stco = try XCTUnwrap(original.range(of: Data("stco".utf8)))
        invalid = original
        // First offset must address mdat payload, never metadata or padding.
        invalid.replaceSubrange(stco.upperBound + 8..<stco.upperBound + 12, with: Data(repeating: 0, count: 4))
        XCTAssertNil(AACContainerCompactor.compact(invalid))
    }

    func testCompactingNewFileIsAtomicNoOpForUnknownProfilesAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aac-padding-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a"), link = root.appendingPathComponent("link.m4a")
        let original = try fixtureAAC()
        try original.write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        try AACContainerCompactor.compactNewFile(at: link)
        XCTAssertEqual(try Data(contentsOf: source), original)
        try AACContainerCompactor.compactNewFile(at: source)
        let compacted = try Data(contentsOf: source)
        XCTAssertEqual(compacted, AACContainerCompactor.compact(original))
        try AACContainerCompactor.compactNewFile(at: source)
        XCTAssertEqual(try Data(contentsOf: source), compacted)
        let unknown = Data("unsupported container".utf8)
        try unknown.write(to: source)
        try AACContainerCompactor.compactNewFile(at: source)
        XCTAssertEqual(try Data(contentsOf: source), unknown)
    }

    func testLegacyWriterCompactionIsExplicitAndPreservesNativeDecoding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aac-padding-writer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let pcm = try authoredPCM()
        let writer = AudioSegmentWriter(storageRoot: root, compactContainerPadding: true)
        let written = try await writer.writeFullBatch(audioData: pcm, timestamp: Date(), source: .microphone)
        let url = root.appendingPathComponent(written.filePath)
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(written.fileSize, Int64(bytes.count))
        XCTAssertNil(AACContainerCompactor.compact(bytes), "Enabled writer already removed supported padding")
        XCTAssertEqual(try decodedPCM(url).count, pcm.count)
    }

    func testDeniedAtomicStagingRetainsAndPublishesVerifiedOriginal() throws {
        guard geteuid() != 0 else { throw XCTSkip("Filesystem denial requires an unprivileged test process") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aac-padding-denial-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("saved-original.m4a")
        let original = try fixtureAAC()
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        XCTAssertThrowsError(try Data([1]).write(to: root.appendingPathComponent("denied-stage")))
        XCTAssertNoThrow(try AACContainerCompactor.compactNewFile(at: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try packetSnapshot(url).packets.count > 0, true)
        XCTAssertGreaterThan(try decodedPCM(url).count, 0)
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func authoredPCM() throws -> Data {
        try decodedPCM(projectRoot.appendingPathComponent("Processing/Tests/Fixtures/WhisperTimedWords/authored.wav"))
    }
    private func fixtureAAC() throws -> Data {
        let url = projectRoot.appendingPathComponent("docs/fixtures/responsiveness/2026-09-28/authored-codec-output/existing-quality-based.m4a")
        return try Data(contentsOf: url)
    }
    private func decodedPCM(_ url: URL, start: Int64 = 0, count: UInt32? = nil) throws -> Data {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        file.framePosition = start
        let frames = count ?? UInt32(file.length)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        try file.read(into: buffer, frameCount: frames)
        let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
        return Data(bytes: samples, count: Int(buffer.frameLength) * 2)
    }

    private struct PacketSnapshot: Equatable {
        let packets: Data
        let sizes: [UInt32]
        let variableFrames: [UInt32]
        let cookie: Data
        let valid: Int64
        let priming: Int32
        let remainder: Int32
    }
    private func packetSnapshot(_ url: URL) throws -> PacketSnapshot {
        var handle: AudioFileID?
        XCTAssertEqual(AudioFileOpenURL(url as CFURL, .readPermission, 0, &handle), noErr)
        let file = try XCTUnwrap(handle)
        defer { AudioFileClose(file) }
        var timing = AudioFilePacketTableInfo()
        var size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        XCTAssertEqual(AudioFileGetProperty(file, kAudioFilePropertyPacketTableInfo, &size, &timing), noErr)
        var count: UInt64 = 0; size = 8
        XCTAssertEqual(AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &size, &count), noErr)
        guard count > 0, count <= 1_024 else { throw CocoaError(.fileReadCorruptFile) }
        var cookieSize: UInt32 = 0
        XCTAssertEqual(AudioFileGetPropertyInfo(file, kAudioFilePropertyMagicCookieData, &cookieSize, nil), noErr)
        guard cookieSize > 0, cookieSize < 65_536 else { throw CocoaError(.fileReadCorruptFile) }
        var cookie = Data(count: Int(cookieSize))
        let cookieStatus = cookie.withUnsafeMutableBytes { AudioFileGetProperty(file, kAudioFilePropertyMagicCookieData, &cookieSize, $0.baseAddress!) }
        XCTAssertEqual(cookieStatus, noErr)
        var packets = Data(count: 2 * 1_024 * 1_024)
        var descriptions = [AudioStreamPacketDescription](repeating: .init(), count: Int(count))
        var byteCount = UInt32(packets.count), packetCount = UInt32(count)
        let read = packets.withUnsafeMutableBytes { bytes in
            descriptions.withUnsafeMutableBufferPointer { desc in
                AudioFileReadPacketData(file, false, &byteCount, desc.baseAddress, 0, &packetCount, bytes.baseAddress!)
            }
        }
        XCTAssertEqual(read, noErr); XCTAssertEqual(UInt64(packetCount), count)
        return PacketSnapshot(packets: packets.prefix(Int(byteCount)), sizes: descriptions.map(\.mDataByteSize),
            variableFrames: descriptions.map(\.mVariableFramesInPacket), cookie: cookie,
            valid: timing.mNumberValidFrames, priming: timing.mPrimingFrames, remainder: timing.mRemainderFrames)
    }
}
