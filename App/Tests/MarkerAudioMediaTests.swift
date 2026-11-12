import Foundation
import Processing
import Shared
import Storage
import XCTest
@testable import App

final class MarkerAudioMediaTests: XCTestCase {
    func testNativePlaybackUsesSuppressionAndDeletionStopsBeforeAcknowledgement() async throws {
        guard ProcessInfo.processInfo.environment["RETRACE_TEST_NATIVE_MARKER_PLAYBACK"] == "1" else {
            throw XCTSkip("Explicit native output fixture; plays authored PCM muted")
        }
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.save(start: 0, count: 32_003)
        let marker = try await fixture.marker(start: 0, end: 32_000)
        let gate = RetracePlaybackGate()
        let playback = MarkerAudioPlayback(media: fixture.media, markers: fixture.markers,
            gate: gate, mutedForTesting: true)
        try await playback.play(markerID: marker.id, expectedRevision: marker.revision)
        let playing = await playback.snapshot()
        XCTAssertTrue(playing.isPlaying)
        XCTAssertTrue(gate.isSuppressed)
        _ = try await fixture.markers.setMarkerDeleted(id: marker.id, expectedRevision: marker.revision, deleted: true)
        let stopped = await playback.snapshot()
        XCTAssertFalse(stopped.isPlaying, "Durable delete joins native playback stop")
        await playback.close()
        try await fixture.markers.close()
    }

    func testExactPhraseAcrossTwoOriginalAACFilesAndIdempotentPublication() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try await fixture.save(start: 0, count: 32_003)
        let second = try await fixture.save(start: 32_003, count: 32_003)
        let repeated = try await fixture.media.register(first.receipt)
        XCTAssertEqual(repeated, first.manifest)
        let marker = try await fixture.marker(start: 24_000, end: 40_000)
        let selected = try await fixture.media.resolve(markerID: marker.id, expectedRevision: marker.revision)
        let a = try ExactAudioDecoder.decode(aac: Data(contentsOf: first.receipt.fileURL), expectedFrames: 32_003)
        let b = try ExactAudioDecoder.decode(aac: Data(contentsOf: second.receipt.fileURL), expectedFrames: 32_003)
        var expected = a.subdata(in: 48_000..<64_006)
        expected.append(b.subdata(in: 0..<15_994))
        let identical = selected.pcm == expected
        let selectedSamples = selected.pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let expectedSamples = expected.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let differences = zip(selectedSamples, expectedSamples).map { abs(Int($0.0) - Int($0.1)) }
        XCTAssertTrue(identical, "Different samples: \(differences.filter { $0 != 0 }.count), peak: \(differences.max() ?? 0), first: \(differences.firstIndex { $0 != 0 } ?? -1)")
        XCTAssertEqual(selected.pcm.count, 32_000)
        _ = try await fixture.markers.setMarkerDeleted(id: marker.id, expectedRevision: marker.revision, deleted: true)
        do { _ = try await fixture.media.resolve(markerID: marker.id, expectedRevision: marker.revision); XCTFail("Deleted marker") }
        catch { XCTAssertEqual(error as? MarkerAudioMediaError, .staleMarker) }
        try await fixture.markers.close()
    }

    func testMissingSamplesAndReplacedMediaCannotSilentlyPlayNearbyAudio() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try await fixture.save(start: 0, count: 16_000)
        _ = try await fixture.save(start: 16_007, count: 16_000)
        let gap = try await fixture.marker(start: 12_000, end: 20_000)
        do { _ = try await fixture.media.resolve(markerID: gap.id, expectedRevision: gap.revision); XCTFail("Seven missing original samples") }
        catch { XCTAssertEqual(error as? MarkerAudioMediaError, .incompleteCoverage) }
        let exact = try await fixture.marker(start: 1_000, end: 8_000)
        try Data("replaced original".utf8).write(to: first.receipt.fileURL)
        do { _ = try await fixture.media.resolve(markerID: exact.id, expectedRevision: exact.revision); XCTFail("Hash must match") }
        catch { XCTAssertEqual(error as? MarkerAudioMediaError, .invalidMedia) }
        try await fixture.markers.close()
    }

    func testSymbolicLinkCannotSubstituteRegisteredOriginal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let saved = try await fixture.save(start: 0, count: 16_000)
        let marker = try await fixture.marker(start: 0, end: 8_000)
        let moved = fixture.root.appendingPathComponent("elsewhere.m4a")
        try FileManager.default.moveItem(at: saved.receipt.fileURL, to: moved)
        try FileManager.default.createSymbolicLink(at: saved.receipt.fileURL, withDestinationURL: moved)
        do { _ = try await fixture.media.resolve(markerID: marker.id, expectedRevision: marker.revision); XCTFail("Symlink substitution") }
        catch { XCTAssertEqual(error as? VoiceRecognitionError, .invalidInput) }
        try await fixture.markers.close()
    }

    private struct Fixture {
        let root: URL
        let storeID = UUID()
        let generation = UUID()
        let continuity = UUID()
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let markers: TimelineMarkerService
        let media: MarkerAudioMediaService
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let id = storeID
            markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { id })
            media = MarkerAudioMediaService(storageRoot: root, markers: markers, nativeStoreID: { id })
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func save(start: Int64, count: Int) async throws -> (receipt: PersistedAudioBatchReceipt, manifest: AudioMediaManifest) {
            let samples = (0..<count).map { Int16(sin(Double(Int64($0) + start) * 2 * .pi * 440 / 16_000) * 10_000) }
            let bytes = samples.withUnsafeBytes { Data($0) }
            let timestamp = origin.addingTimeInterval(Double(start) / 16_000)
            let saved = try await AudioSegmentWriter(storageRoot: root).writeFullBatch(audioData: bytes,
                timestamp: timestamp, source: .microphone)
            let receipt = PersistedAudioBatchReceipt(rawBatchID: start + 1, relativePath: saved.filePath,
                fileURL: root.appendingPathComponent(saved.filePath), fileSize: saved.fileSize, frameCount: Int64(count),
                sampleRate: 16_000, channels: 1, source: .microphone, startTimestamp: timestamp,
                endTimestamp: timestamp.addingTimeInterval(Double(count) / 16_000), sourceRanges: [
                    .init(source: .init(recordingGeneration: generation, continuityID: continuity, startSample: start,
                        sampleCount: Int64(count), sampleRate: 16_000, approximateOrigin: origin), batchStartSample: 0)])
            return (receipt, try await media.register(receipt))
        }
        func marker(start: Int64, end: Int64) async throws -> TimelineMarker {
            let rule = try await markers.saveKeywordRule(.init(phrase: "purple banana", name: "Remember", meaning: "Context", enabled: true), expectedRevision: nil)
            return try await markers.applySpokenObservation(.init(occurrenceID: UUID(), status: .confirmed,
                anchor: .init(nativeStoreID: storeID, recordingGeneration: generation, continuityID: continuity,
                    startSample: start, endSample: end, approximateOrigin: origin, timingPrecision: .phraseAligned),
                ruleSnapshot: rule, matchedPhrase: "purple banana", explanation: "")).marker
        }
    }
}
