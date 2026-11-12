import Database
import Foundation
import Shared
import Storage
import XCTest
@testable import App

final class CompanionTurnPlaybackTests: XCTestCase {
    func testCommandRevokedWhileActualAACPreparationIsHeldCannotStartPlayback() async throws {
        let held = TurnReadHold(), entered = expectation(description: "Native turn read held before playback")
        let fixture = try await Fixture.make(metric: { action, _ in
            if action == "operation" { await held.waitIfArmed { entered.fulfill() } }
        })
        let saved = try await fixture.publish()
        let batch = try await fixture.owner.speakerPresentation(jobID: saved.jobID)
        let reference = try XCTUnwrap(batch?.turnReferences.first), fence = NativeMutationFence()
        let gate = RetracePlaybackGate()
        let playback = CompanionTurnPlayback(controller: fixture.owner, media: fixture.media, gate: gate, mutedForTesting: true)
        await held.arm()
        let playing = Task { try await playback.play(reference, commandFence: fence) }
        await fulfillment(of: [entered], timeout: 3)
        fence.invalidate(); await held.release()
        do { try await playing.value; XCTFail("Revoked command cannot start native output") }
        catch is CancellationError { }
        let state = await playback.snapshot()
        XCTAssertFalse(state.isPlaying); XCTAssertFalse(gate.isSuppressed)
        await playback.close(); try await fixture.close()
    }

    func testRetainedTurnUsesOriginalResultDigestExactSamplesAndFullFirstPass() async throws {
        let fixture = try await Fixture.make()
        let saved = try await fixture.publish()
        let value = try await fixture.owner.speakerPresentation(jobID: saved.jobID)
        let batch = try XCTUnwrap(value), reference = try XCTUnwrap(batch.turnReferences.first)
        XCTAssertEqual(reference.resultSHA256, CompanionWire.digest(saved.resultBytes))
        let decoded = try CompanionWire.decode(CompanionResult.self, data: saved.resultBytes, limit: 2 * 1024 * 1024)
        XCTAssertNotEqual(reference.resultSHA256, CompanionWire.digest(try CompanionWire.encode(decoded)), "Original bytes, not re-encoded JSON")
        let turn = try await fixture.owner.resolveTurn(reference)
        XCTAssertEqual(turn.firstPassReferences, batch.firstPassReferences)
        XCTAssertEqual(turn.firstPassText, "Full original first pass beyond the selected turn")
        XCTAssertEqual(turn.sourceIdentity.startSample, 0)
        XCTAssertEqual(turn.sourceIdentity.sampleCount, 17601)
        let actual = try await fixture.media.resolvePCM(.init(nativeStoreID: fixture.native, identity: turn.sourceIdentity))
        let original = try ExactAudioDecoder.decode(aac: Data(contentsOf: saved.file), expectedFrames: 32000)
        XCTAssertEqual(actual, original.subdata(in: 0..<(17601 * 2)))
        var wrong = turn.sourceIdentity
        wrong = .init(recordingGeneration: wrong.recordingGeneration, continuityID: UUID(), startSample: 0,
            sampleCount: 17601, sampleRate: 16000, approximateOrigin: wrong.approximateOrigin)
        do { _ = try await fixture.media.resolvePCM(.init(nativeStoreID: fixture.native, identity: wrong)); XCTFail("No nearby audio fallback") }
        catch { XCTAssertEqual(error as? MarkerAudioMediaError, .incompleteCoverage) }
        _ = try await fixture.audio.deleteTranscription(id: saved.rowID)
        fixture.owner.sourceChanged(.init(.init(targets: [.audioRow(saved.rowID)])))
        do { _ = try await fixture.owner.resolveTurn(reference); XCTFail("Retained AAC cannot replace a deleted first-pass proof") }
        catch { XCTAssertEqual(error as? CompanionError, .staleEvidence) }
        try await fixture.close()
    }

    func testCorrectionInvalidatesOldReferenceAndPersistsAcrossOfflineReopen() async throws {
        let fixture = try await Fixture.make()
        let saved = try await fixture.publish(), other = try await fixture.publish(offset: 10)
        let initial = try await fixture.owner.speakerPresentation(jobID: saved.jobID)
        let reference = try XCTUnwrap(initial?.turnReferences.first)
        let before = try await fixture.owner.resolveTurn(reference)
        XCTAssertEqual(before.displayLabel, "Speaker 1"); XCTAssertEqual(before.speakerStatus, .anonymous)
        let correction = try await fixture.owner.correctSpeaker(.init(jobID: saved.jobID, speakerID: before.turn.speakerID,
            displayName: "Alex", expectedRevision: nil))
        do { _ = try await fixture.owner.resolveTurn(reference); XCTFail("Old anonymous selection is stale") }
        catch { XCTAssertEqual(error as? CompanionError, .staleEvidence) }
        let updated = try await fixture.owner.speakerPresentation(jobID: saved.jobID)
        let currentReference = try XCTUnwrap(updated?.turnReferences.first)
        XCTAssertEqual(currentReference.correctionRevision, correction.revision)
        let current = try await fixture.owner.resolveTurn(currentReference)
        XCTAssertEqual(current.displayLabel, "Alex"); XCTAssertEqual(current.speakerStatus, .manualName)
        let another = try await fixture.owner.speakerPresentation(jobID: other.jobID)
        let unrelated = try await fixture.owner.resolveTurn(XCTUnwrap(another?.turnReferences.first))
        XCTAssertEqual(unrelated.speakerStatus, .anonymous, "Speaker 1 in another job is not the same person")
        try await fixture.owner.close()
        let reopened = fixture.makeOwner()
        let retained = try await reopened.resolveTurn(currentReference)
        XCTAssertEqual(retained.displayLabel, "Alex")
        XCTAssertEqual(retained.firstPassReferences, current.firstPassReferences)
        try await reopened.close(); try await fixture.close()
    }

    func testSourceInvalidationDrainsWithoutJoiningReadButStopJoinsPreparation() async throws {
        let held = TurnReadHold(), entered = expectation(description: "Turn read held at final metric")
        let fixture = try await Fixture.make(metric: { action, _ in
            if action == "operation" { await held.waitIfArmed { entered.fulfill() } }
        })
        let saved = try await fixture.publish()
        let batch = try await fixture.owner.speakerPresentation(jobID: saved.jobID)
        let reference = try XCTUnwrap(batch?.turnReferences.first)
        let gate = RetracePlaybackGate()
        let playback = CompanionTurnPlayback(controller: fixture.owner, media: fixture.media, gate: gate, mutedForTesting: true)
        await held.arm()
        let playing = Task { try await playback.play(reference) }
        await fulfillment(of: [entered], timeout: 3)
        fixture.owner.sourceChanged(.init(.init(targets: [.audioRow(saved.rowID)])))
        await playback.drainOutput()
        let stopped = await playback.snapshot(); XCTAssertFalse(stopped.isPlaying); XCTAssertFalse(gate.isSuppressed)
        let completed = expectation(description: "Stop waits for preparation metric"); completed.isInverted = true
        let stopping = Task { await playback.stop(); completed.fulfill() }
        await fulfillment(of: [completed], timeout: 0.05)
        await held.release()
        do { try await playing.value; XCTFail("Invalidated preparation cannot start output") }
        catch { XCTAssertTrue(error is CancellationError || error as? CompanionError == .staleEvidence) }
        await stopping.value; await playback.close(); try await fixture.close()
    }

    func testNativeTurnPlaybackSuppressionAndCorrectionDrain() async throws {
        guard ProcessInfo.processInfo.environment["RETRACE_TEST_NATIVE_MARKER_PLAYBACK"] == "1" else {
            throw XCTSkip("Explicit native output fixture; authored AAC is played muted")
        }
        let fixture = try await Fixture.make(), saved = try await fixture.publish()
        let batch = try await fixture.owner.speakerPresentation(jobID: saved.jobID)
        let reference = try XCTUnwrap(batch?.turnReferences.first)
        let gate = RetracePlaybackGate()
        let playback = CompanionTurnPlayback(controller: fixture.owner, media: fixture.media, gate: gate, mutedForTesting: true)
        try await playback.play(reference)
        let started = await playback.snapshot(); XCTAssertTrue(started.isPlaying); XCTAssertTrue(gate.isSuppressed)
        _ = try await fixture.owner.correctSpeaker(.init(jobID: saved.jobID,
            speakerID: saved.jobID + ":cluster:1", displayName: "Authored name", expectedRevision: nil))
        let stopped = await playback.snapshot(); XCTAssertFalse(stopped.isPlaying, "Correction joins output stop before acknowledgement")
        await playback.close(); try await fixture.close()
    }

    private struct Saved { let jobID: String; let rowID: Int64; let file: URL; let resultBytes: Data }
    private struct Fixture {
        let root: URL
        let database: DatabaseManager
        let adapter: DataAdapter
        let recall: ProgressiveRecallService
        let audio: AudioTranscriptionQueries
        let markers: TimelineMarkerService
        let media: MarkerAudioMediaService
        let owner: CompanionController
        let native: UUID
        static func make(metric: @escaping CompanionController.Metric = { _, _ in }) async throws -> Self {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let path = root.appendingPathComponent("recording.db").path
            let database = DatabaseManager(databasePath: path); try await database.initialize()
            let pointer = await database.getConnection(), audio = AudioTranscriptionQueries(db: try XCTUnwrap(pointer))
            let adapter = DataAdapter(retraceConnection: try await database.makeRecallReadConnection(),
                retraceConfig: .init(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
                retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
            try await adapter.initialize()
            let native = try await adapter.evidenceStoreID(source: .native)
            let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { native })
            let media = MarkerAudioMediaService(storageRoot: root, markers: markers, nativeStoreID: { native })
            let recall = ProgressiveRecallService(database: database, adapter: adapter, configuration: { Shared.CaptureConfig() },
                imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
            let owner = CompanionController(storageRoot: root.appendingPathComponent("companion"), nativeStoreID: native,
                databasePath: path, adapter: adapter, recall: recall, markers: markers,
                verifiedBytes: { try await media.verifiedBytes(for: $0) }, policy: {}, metric: metric)
            try CompanionSpool(root: root.appendingPathComponent("companion/delivery"), nativeStoreID: native).initialize()
            return .init(root: root, database: database, adapter: adapter, recall: recall, audio: audio, markers: markers, media: media, owner: owner, native: native)
        }
        func makeOwner() -> CompanionController {
            CompanionController(storageRoot: root.appendingPathComponent("companion"), nativeStoreID: native,
                databasePath: root.appendingPathComponent("recording.db").path, adapter: adapter, recall: recall, markers: markers,
                verifiedBytes: { try await media.verifiedBytes(for: $0) }, policy: {})
        }
        func publish(offset: Double = 0) async throws -> Saved {
            let start = Date(timeIntervalSince1970: 1_800_000_000.123456 + offset)
            let samples = (0..<32000).map { Int16(sin(Double($0) * 2 * .pi * 220 / 16000) * 4000) }
            let saved = try await AudioSegmentWriter(storageRoot: root).writeFullBatch(audioData: samples.withUnsafeBytes { Data($0) }, timestamp: start, source: .microphone)
            let text = "Full original first pass beyond the selected turn"
            let row = try await audio.insertTranscription(sessionID: nil, text: text, startTime: start, endTime: start.addingTimeInterval(2),
                source: .microphone, confidence: nil, words: [], audioPath: saved.filePath, transcriptionPass: 1, batchAudioPath: saved.filePath)
            let source = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(), startSample: 0, sampleCount: 32000,
                sampleRate: 16000, approximateOrigin: start)
            let file = root.appendingPathComponent(saved.filePath)
            let manifest = try await media.register(.init(rawBatchID: row, relativePath: saved.filePath, fileURL: file, fileSize: saved.fileSize,
                frameCount: 32000, sampleRate: 16000, channels: 1, source: .microphone, startTimestamp: start, endTimestamp: start.addingTimeInterval(2),
                sourceRanges: [.init(source: source, batchStartSample: 0)]))
            let rows = try await audio.getContextBatchEntries(batchAudioPath: saved.filePath)
            let request = CompanionJobRequest(sourceStoreID: native, observedAt: start, speaker: .init(sourceIdentity: source, firstPassText: text,
                media: [.init(sha256: manifest.sha256, byteCount: Int(saved.fileSize), mediaID: CompanionController.mediaID(manifest),
                    offsetSamples: 0, countSamples: 32000, sourceStartSample: 0)],
                firstPassReferences: try CompanionTranscriptSnapshot.firstPassReferences(for: rows, nativeStoreID: native)))
            let bytes = try CompanionWire.encode(request), id = CompanionWire.digest(bytes)
            let object = try JSONSerialization.jsonObject(with: CompanionWire.encode(source))
            let result: [String: Any] = ["version": 1, "jobID": id, "kind": "speaker", "sourceStoreID": native.uuidString,
                "speakerEnrichment": ["sourceIdentity": object, "firstPassSHA256": CompanionWire.digest(Data(text.utf8)),
                    "enhancedText": "Inferred selected words", "automaticNamesCalibrated": false, "modelFingerprint": String(repeating: "a", count: 64),
                    "turns": [["start": 0.00001, "end": 1.10001, "text": "Inferred selected words", "speakerID": id + ":cluster:1",
                        "speakerLabel": "Speaker 1", "speakerStatus": "unknown"]]]]
            let resultBytes = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            let spool = CompanionSpool(root: root.appendingPathComponent("companion/delivery"), nativeStoreID: native)
            try spool.publish(bytes, to: spool.path("requests", id)); try spool.publish(resultBytes, to: spool.path("results", id))
            try spool.publish(Data(CompanionWire.digest(resultBytes).utf8), to: spool.path("receipts", id, suffix: ".imported"))
            return .init(jobID: id, rowID: row, file: file, resultBytes: resultBytes)
        }
        func close() async throws {
            try await owner.close(); try await markers.close(); await adapter.shutdown(); try await database.close()
            try FileManager.default.removeItem(at: root)
        }
    }
}

private actor TurnReadHold {
    private var armed = false
    private var released = false
    private var held: CheckedContinuation<Void, Never>?
    func arm() { armed = true }
    func waitIfArmed(_ entered: @Sendable () -> Void) async {
        guard armed else { return }; armed = false; entered()
        if !released { await withCheckedContinuation { held = $0 } }
    }
    func release() { released = true; held?.resume(); held = nil }
}
