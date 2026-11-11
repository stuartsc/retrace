import AVFoundation
import CryptoKit
import Foundation
import Shared
import XCTest
@testable import Storage

final class AudioChunkMediaStoreTests: XCTestCase {
    func testExactDecodedLengthsAtAACPacketAndChunkBoundaries() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        for frames in [1, 1_023, 1_024, 1_025, 159_999, 160_000] {
            let input = AudioChunkInput(streamID: UUID(), source: .microphone, origin: fixture.origin,
                startFrame: 0, pcmData: fixture.input(start: 0, frames: frames).pcmData)
            let window = try await store.persistChunk(input, previous: nil)
            let lease = try await store.readWindow(window)
            XCTAssertEqual(lease.pcmData.count, frames * 2)
            XCTAssertEqual(window.manifest.ranges.last?.chunk.validFrames, Int64(frames))
            await store.release(lease)
        }
        await store.close()
    }

    func testNativeChunksShareExactDecodedContextWithoutStoringItAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        let firstInput = fixture.input(start: 0, frames: 160_000)
        let first = try await store.persistChunk(firstInput, previous: nil)
        let firstChunk = try XCTUnwrap(first.manifest.ranges.last?.chunk)
        let second = try await store.persistChunk(fixture.input(start: 160_000, frames: 160_000), previous: firstChunk)
        let secondChunk = try XCTUnwrap(second.manifest.ranges.last?.chunk)
        let tail = try await store.persistChunk(fixture.input(start: 320_000, frames: 17_731), previous: secondChunk)
        XCTAssertEqual(first.manifest.frameCount, 160_000)
        XCTAssertEqual(second.manifest.frameCount, 240_000)
        XCTAssertEqual(second.manifest.ownedStartFrame, 80_000)
        XCTAssertEqual(second.manifest.ranges.first?.chunk.id, firstChunk.id)
        XCTAssertEqual(second.manifest.ranges.first?.offsetFrames, 80_000)
        XCTAssertEqual(second.manifest.ranges.first?.frameCount, 80_000)
        XCTAssertEqual(tail.manifest.frameCount, 97_731)
        XCTAssertEqual(tail.manifest.ranges.map(\.frameCount), [80_000, 17_731])
        XCTAssertEqual(tail.manifest.ranges.first?.chunk.id, secondChunk.id)
        XCTAssertEqual(tail.manifest.ranges.first?.offsetFrames, 80_000)
        let firstRead = try await store.readWindow(first)
        let secondRead = try await store.readWindow(second)
        let tailRead = try await store.readWindow(tail)
        XCTAssertEqual(firstRead.pcmData.count, 320_000)
        assertEquivalentNativeSamples(Data(secondRead.pcmData.prefix(160_000)), Data(firstRead.pcmData.suffix(160_000)))
        assertEquivalentNativeSamples(Data(tailRead.pcmData.prefix(160_000)), Data(secondRead.pcmData.suffix(160_000)))
        for window in [first, second, tail] {
            let chunk = try XCTUnwrap(window.manifest.ranges.last?.chunk)
            XCTAssertEqual(chunk.validFrames, chunk.frameCount)
            XCTAssertGreaterThan(chunk.primingFrames, 0)
            XCTAssertGreaterThanOrEqual(chunk.remainderFrames, 0)
            XCTAssertEqual(chunk.packetCount * chunk.framesPerPacket,
                           chunk.validFrames + chunk.primingFrames + chunk.remainderFrames)
            XCTAssertEqual(chunk.trackStartSeconds, 0, accuracy: 1.0 / 16_000)
            XCTAssertEqual(sha(try Data(contentsOf: fixture.root.appendingPathComponent(chunk.relativePath))), chunk.encodedSHA256)
        }
        let media = try FileManager.default.contentsOfDirectory(at: fixture.streamDirectory,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "m4a" }
        XCTAssertEqual(media.count, 3)
        await store.release(firstRead)
        await store.release(secondRead)
        await store.release(tailRead)
        await store.close()
    }

    func testAuthoredSpeechAcrossNativeAACBoundaryHasExactTimelineAndBoundedSignalError() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authored = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Processing/Tests/Fixtures/WhisperTimedWords/authored.wav")
        let pcm = try AudioFileDecoder.decodeToPCM(fileURL: authored).data
        XCTAssertGreaterThan(pcm.count, 320_000)
        let store = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        let firstInput = AudioChunkInput(streamID: fixture.streamID, source: .microphone,
            origin: fixture.origin, startFrame: 0, pcmData: pcm.prefix(320_000))
        let first = try await store.persistChunk(firstInput, previous: nil)
        let secondInput = AudioChunkInput(streamID: fixture.streamID, source: .microphone,
            origin: fixture.origin, startFrame: 160_000, pcmData: pcm.dropFirst(320_000))
        let second = try await store.persistChunk(secondInput, previous: first.manifest.ranges.last?.chunk)
        let read = try await store.readWindow(second)
        XCTAssertEqual(read.pcmData.count, pcm.count - 160_000)
        let expected = Data(pcm.dropFirst(160_000))
        XCTAssertGreaterThan(signalToNoise(reference: expected, decoded: read.pcmData), 8,
            "A lost AAC priming correction creates a large shift around the actual chunk boundary")
        XCTAssertEqual(second.manifest.endTime.timeIntervalSince(fixture.origin), Double(pcm.count / 2) / 16_000, accuracy: 0.000_001)
        await store.release(read)
        await store.close()
    }

    func testSameIdentityRetryIsIdempotentAndConflictingPCMOrContextFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        let input = fixture.input(start: 0, frames: 16_000)
        let window = try await store.persistChunk(input, previous: nil)
        try await store.acknowledgePublished(window)
        let replay = try await store.persistChunk(input, previous: nil)
        XCTAssertEqual(replay, window)
        var changed = input.pcmData
        changed[0] ^= 1
        let conflict = AudioChunkInput(id: input.id, streamID: input.streamID, source: input.source,
            origin: input.origin, startFrame: input.startFrame, pcmData: changed)
        await assertThrows { _ = try await store.persistChunk(conflict, previous: nil) }
        let missingPredecessor = fixture.input(start: 32_000, frames: 8_000)
        await assertThrows { _ = try await store.persistChunk(missingPredecessor, previous: window.manifest.ranges.last?.chunk) }
        let pending = try await store.pendingWindows(limit: 4)
        XCTAssertTrue(pending.isEmpty, "Replaying an already acknowledged window must not requeue it")
        await store.close()
    }

    func testEncodedIdentityAndExactFramesSurviveRepeatedReopenAcrossTaskPriorities() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        let window = try await writer.persistChunk(fixture.input(start: 0, frames: 16_000), previous: nil)
        let chunk = try XCTUnwrap(window.manifest.ranges.last?.chunk)
        XCTAssertEqual(chunk.decodeContract, .nativeAACPCM16V1)
        await writer.close()
        var reference: Data?
        for priority: TaskPriority in [.background, .utility, .userInitiated, .high] {
            for _ in 0..<3 {
                let root = fixture.root
                let storeID = fixture.storeID
                let pcm = try await Task.detached(priority: priority) {
                    let reader = AudioChunkMediaStore(storageRoot: root, storeID: storeID)
                    do {
                        let lease = try await reader.readWindow(window)
                        let data = lease.pcmData
                        await reader.release(lease)
                        await reader.close()
                        return data
                    } catch {
                        await reader.close()
                        throw error
                    }
                }.value
                XCTAssertEqual(pcm.count, 32_000)
                if let reference { assertEquivalentNativeSamples(pcm, reference) }
                else { reference = pcm }
            }
        }
        let acknowledger = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        try await acknowledger.acknowledgePublished(window)
        let pending = try await acknowledger.pendingWindows(limit: 1)
        XCTAssertTrue(pending.isEmpty)
        await acknowledger.close()
    }

    func testDecodeContractRoundTripAndMissingContractKeepsStrictPCMReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        let input = AudioChunkInput(streamID: fixture.streamID, source: .microphone, origin: fixture.origin,
            startFrame: 0, pcmData: Data(repeating: 0, count: 32_000))
        let window = try await store.persistChunk(input, previous: nil)
        let encoded = try AudioChunkMediaValidation.encodedManifestData(window.manifest)
        let decoded = try JSONDecoder().decode(AudioWindowManifest.self, from: encoded)
        XCTAssertEqual(decoded, window.manifest)
        XCTAssertEqual(decoded.ranges.first?.chunk.decodeContract, .nativeAACPCM16V1)
        XCTAssertEqual(try AudioChunkMediaValidation.encodedManifestData(decoded), encoded)

        let legacy = try rewriteDecodeReceipt(window, root: fixture.root, contract: nil)
        XCTAssertNil(legacy.manifest.ranges.first?.chunk.decodeContract)
        let legacyBytes = try AudioChunkMediaValidation.encodedManifestData(legacy.manifest)
        XCTAssertFalse(String(decoding: legacyBytes, as: UTF8.self).contains("decodeContract"))
        let oldRead = try await store.readWindow(legacy)
        XCTAssertEqual(sha(oldRead.pcmData), legacy.manifest.ranges.first?.chunk.decodedPCMSHA256)
        await store.release(oldRead)
        let wrongStrict = try rewriteDecodeReceipt(legacy, root: fixture.root, contract: nil,
            diagnosticHash: String(repeating: "0", count: 64))
        await assertThrows { _ = try await store.readWindow(wrongStrict) }

        // The explicit contract makes the PCM hash an encode-time diagnostic.
        // It does not replace admission of the immutable encoded bytes.
        let diagnostic = try rewriteDecodeReceipt(wrongStrict, root: fixture.root, contract: .nativeAACPCM16V1)
        let diagnosticRead = try await store.readWindow(diagnostic)
        XCTAssertEqual(diagnosticRead.pcmData.count, 32_000)
        await store.release(diagnosticRead)
        let chunk = try XCTUnwrap(diagnostic.manifest.ranges.first?.chunk)
        let path = fixture.root.appendingPathComponent(chunk.relativePath)
        var damaged = try Data(contentsOf: path)
        damaged[damaged.count / 2] ^= 1
        try damaged.write(to: path)
        await assertThrows { _ = try await store.readWindow(diagnostic) }
        await store.close()
    }

    func testPendingWindowSurvivesStoreRestartAndAcknowledgementIsExact() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        let window = try await first.persistChunk(fixture.input(start: 0, frames: 12_345), previous: nil)
        await first.close()
        let reopened = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        let pending = try await reopened.pendingWindows(limit: 1)
        XCTAssertEqual(pending, [window])
        let changed = StoredAudioWindow(manifest: window.manifest, relativePath: window.relativePath,
            manifestSHA256: String(repeating: "0", count: 64), manifestBytes: window.manifestBytes)
        await assertThrows { try await reopened.acknowledgePublished(changed) }
        let stillPending = try await reopened.pendingWindows(limit: 1)
        XCTAssertEqual(stillPending, [window])
        try await reopened.acknowledgePublished(window)
        let acknowledged = try await reopened.pendingWindows(limit: 1)
        XCTAssertTrue(acknowledged.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(window.relativePath).path))
        await reopened.close()
    }

    func testRawJournalRecoversNativeEncodingFailureWithPreviousChunkContext() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        let preceding = try await first.persistChunk(fixture.input(start: 0, frames: 160_000), previous: nil)
        try await first.acknowledgePublished(preceding)
        let input = fixture.input(start: 160_000, frames: 11_111)
        let destination = fixture.streamDirectory.appendingPathComponent(input.id.uuidString.lowercased() + ".m4a")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        await assertThrows { _ = try await first.persistChunk(input, previous: preceding.manifest.ranges.last?.chunk) }
        await first.close()
        try FileManager.default.removeItem(at: destination)
        let reopened = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        let recovered = try await reopened.pendingWindows(limit: 1)
        XCTAssertEqual(recovered.count, 1)
        let window = try XCTUnwrap(recovered.first)
        XCTAssertEqual(window.manifest.id, input.id)
        XCTAssertEqual(window.manifest.frameCount, 91_111)
        XCTAssertEqual(window.manifest.ranges.first?.chunk, preceding.manifest.ranges.last?.chunk)
        let read = try await reopened.readWindow(window)
        XCTAssertEqual(read.pcmData.count, 182_222)
        await reopened.release(read)
        await reopened.close()
    }

    func testDamagedPredecessorDoesNotLoseNewRawChunkAcrossRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        let preceding = try await first.persistChunk(fixture.input(start: 0, frames: 16_000), previous: nil)
        try await first.acknowledgePublished(preceding)
        let previousChunk = try XCTUnwrap(preceding.manifest.ranges.last?.chunk)
        let previousURL = fixture.root.appendingPathComponent(previousChunk.relativePath)
        let original = try Data(contentsOf: previousURL)
        var damaged = original
        damaged[damaged.count / 2] ^= 1
        try damaged.write(to: previousURL)
        let input = fixture.input(start: 16_000, frames: 7_777)
        await assertThrows { _ = try await first.persistChunk(input, previous: previousChunk) }
        await first.close()
        try original.write(to: previousURL)
        let reopened = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        let recovered = try await reopened.pendingWindows(limit: 1)
        let window = try XCTUnwrap(recovered.first)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(window.manifest.id, input.id)
        XCTAssertEqual(window.manifest.frameCount, 23_777)
        let read = try await reopened.readWindow(window)
        XCTAssertEqual(read.pcmData.count, 47_554)
        await reopened.release(read)
        await reopened.close()
    }

    func testInvalidInputAndForeignPredecessorAreRejectedBeforePublication() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        for input in [fixture.input(start: 0, frames: 0), fixture.input(start: -1, frames: 1),
                      fixture.input(start: Int64.max, frames: 1), fixture.input(start: 0, frames: 160_001),
                      AudioChunkInput(streamID: fixture.streamID, source: .microphone, origin: fixture.origin,
                                      startFrame: 0, pcmData: Data([1]))] {
            await assertThrows { _ = try await store.persistChunk(input, previous: nil) }
        }
        let first = try await store.persistChunk(fixture.input(start: 0, frames: 4_096), previous: nil)
        let other = AudioChunkInput(streamID: UUID(), source: .microphone, origin: fixture.origin,
            startFrame: 4_096, pcmData: fixture.input(start: 4_096, frames: 4_096).pcmData)
        await assertThrows { _ = try await store.persistChunk(other, previous: first.manifest.ranges.last?.chunk) }
        let foreign = AudioChunkMediaStore(storageRoot: fixture.root, storeID: UUID())
        await assertThrows { _ = try await foreign.readWindow(first) }
        await store.close()
        await foreign.close()
    }

    func testTamperedMediaAndEscapingSymlinkAreNeverDecoded() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        let window = try await store.persistChunk(fixture.input(start: 0, frames: 8_000), previous: nil)
        let chunk = try XCTUnwrap(window.manifest.ranges.last?.chunk)
        let url = fixture.root.appendingPathComponent(chunk.relativePath)
        let original = try Data(contentsOf: url)
        var corrupt = original
        corrupt[corrupt.count / 2] ^= 1
        try corrupt.write(to: url)
        await assertThrows { _ = try await store.readWindow(window) }
        try FileManager.default.removeItem(at: url)
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: outside) }
        try original.write(to: outside)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        await assertThrows { _ = try await store.readWindow(window) }
        await store.close()
    }

    func testAuthorizedDeletionRevokesAndJoinsOtherStoreReaderBeforeUnlink() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        let reader = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        let window = try await writer.persistChunk(fixture.input(start: 0, frames: 8_000), previous: nil)
        let lease = try await reader.readWindow(window)
        let chunk = try XCTUnwrap(window.manifest.ranges.last?.chunk)
        let deletion = Task { try await writer.deleteAuthorized(windows: [window], chunks: [chunk]) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while lease.validity.isValid && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(lease.validity.isValid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(chunk.relativePath).path),
                      "Revocation must be followed by joined reader release before physical deletion")
        await assertThrows { _ = try await writer.readWindow(window) }
        await reader.release(lease)
        try await deletion.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(chunk.relativePath).path))
        let restarted = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        await assertThrows { _ = try await restarted.readWindow(window) }
        let pending = try await restarted.pendingWindows(limit: 8)
        XCTAssertTrue(pending.isEmpty, "A deleted window's publication journal must never resurrect it")
        await writer.close()
        await reader.close()
        await restarted.close()
    }

    func testCloseRevokesOutstandingLeasesAndRejectsFutureWork() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        let window = try await store.persistChunk(fixture.input(start: 0, frames: 2_048), previous: nil)
        let lease = try await store.readWindow(window)
        let closing = Task { await store.close() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while lease.validity.isValid && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(lease.validity.isValid)
        await assertThrows { _ = try await store.readWindow(window) }
        await assertThrows { _ = try await store.persistChunk(fixture.input(start: 2_048, frames: 2_048), previous: window.manifest.ranges.last?.chunk) }
        await store.release(lease)
        await closing.value
    }

    func testConcurrentStoreInstancesCoalesceExactPublicationAndRejectChangedPayload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        let second = AudioChunkMediaStore(storageRoot: fixture.root, storeID: fixture.storeID)
        let input = fixture.input(start: 0, frames: 16_000)
        async let a = first.persistChunk(input, previous: nil)
        async let b = second.persistChunk(input, previous: nil)
        let (left, right) = try await (a, b)
        XCTAssertEqual(left, right)
        let pending = try await second.pendingWindows(limit: 1)
        XCTAssertEqual(pending, [left])
        await first.close()
        await second.close()
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-chunk-test-\(UUID())")
        let storeID = UUID()
        let streamID = UUID()
        let origin = Date(timeIntervalSince1970: 1_700_000_000.125)
        var streamDirectory: URL { root.appendingPathComponent("audio/chunk-media/\(streamID.uuidString.lowercased())") }
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func input(start: Int64, frames: Int) -> AudioChunkInput {
            var data = Data(capacity: max(0, frames) * 2)
            for index in 0..<max(0, frames) {
                let phase = Double(index) / 16_000
                var sample = Int16((sin(2 * .pi * 431 * phase) * 8_000 + sin(2 * .pi * 719 * phase) * 3_000).rounded()).littleEndian
                withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
            }
            return AudioChunkInput(streamID: streamID, source: .microphone, origin: origin, startFrame: start, pcmData: data)
        }
    }

    private func assertThrows(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected an error", file: file, line: line) } catch { }
    }
    private func rewriteDecodeReceipt(_ window: StoredAudioWindow, root: URL,
                                      contract: AudioChunkDecodeContract?, diagnosticHash: String? = nil) throws -> StoredAudioWindow {
        let data = try AudioChunkMediaValidation.encodedManifestData(window.manifest)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var ranges = try XCTUnwrap(json["ranges"] as? [[String: Any]])
        var chunk = try XCTUnwrap(ranges[0]["chunk"] as? [String: Any])
        if let contract { chunk["decodeContract"] = contract.rawValue }
        else { chunk.removeValue(forKey: "decodeContract") }
        if let diagnosticHash { chunk["decodedPCMSHA256"] = diagnosticHash }
        ranges[0]["chunk"] = chunk
        json["ranges"] = ranges
        let manifest = try JSONDecoder().decode(AudioWindowManifest.self, from: JSONSerialization.data(withJSONObject: json))
        let replacement = try AudioChunkMediaValidation.encodedManifestData(manifest)
        try replacement.write(to: root.appendingPathComponent(window.relativePath))
        return StoredAudioWindow(manifest: manifest, relativePath: window.relativePath,
            manifestSHA256: sha(replacement), manifestBytes: Int64(replacement.count))
    }
    private func assertEquivalentNativeSamples(_ left: Data, _ right: Data,
                                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(left.count, right.count, file: file, line: line)
        guard left.count == right.count, left.count.isMultiple(of: 2) else { return }
        var maximumDifference = 0
        left.withUnsafeBytes { a in
            right.withUnsafeBytes { b in
                for index in 0..<(left.count / 2) {
                    let x = Int(Int16(littleEndian: a.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
                    let y = Int(Int16(littleEndian: b.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
                    maximumDifference = max(maximumDifference, abs(x - y))
                }
            }
        }
        XCTAssertLessThanOrEqual(maximumDifference, 2,
            "Test-only native decode comparison; exact encoded identity and integer sample ranges remain separate assertions",
            file: file, line: line)
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func signalToNoise(reference: Data, decoded: Data) -> Double {
        guard reference.count == decoded.count else { return -.infinity }
        var signal = 0.0, noise = 0.0
        reference.withUnsafeBytes { input in
            decoded.withUnsafeBytes { output in
                for index in 0..<(reference.count / 2) {
                    let a = Double(Int16(littleEndian: input.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
                    let b = Double(Int16(littleEndian: output.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
                    signal += a * a; noise += (a - b) * (a - b)
                }
            }
        }
        return 10 * log10(max(1, signal) / max(1, noise))
    }
}
