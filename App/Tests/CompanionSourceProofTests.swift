import Database
import Darwin
import Foundation
import Shared
import Storage
import XCTest
@testable import App

final class CompanionSourceProofTests: XCTestCase {
    func testOriginalFirstPassSurvivesHigherPassAndReopenButMutationRevokesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await Fixture.make(root)
        let rows = try await first.insertFirstPass()
        let request = try first.request(rows)
        try await first.reader.revalidate(request)
        _ = try await first.audio.insertTranscription(sessionID: nil, text: "Later improved wording",
            startTime: first.time, endTime: first.time.addingTimeInterval(2), source: .microphone,
            confidence: nil, words: [], audioPath: first.batch, transcriptionPass: 2, batchAudioPath: first.batch)
        try await first.reader.revalidate(request)
        try await first.close()
        let reopened = try await Fixture.make(root)
        try await reopened.reader.revalidate(request)
        try await reopened.audio.updateTranscriptionText(id: rows[0].id, text: "Changed original text")
        do { try await reopened.reader.revalidate(request); XCTFail("Changed first pass must revoke publication") }
        catch { XCTAssertEqual(error as? CompanionError, .staleEvidence) }
        try await reopened.close()
    }

    func testDeletedFirstPassCannotUseRetainedMediaAndTextCannotBeSubstituted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Fixture.make(root)
        let rows = try await fixture.insertFirstPass(), request = try fixture.request(rows)
        let original = try XCTUnwrap(request.speaker)
        let changed = CompanionJobRequest(sourceStoreID: fixture.native, observedAt: fixture.time,
            speaker: .init(sourceIdentity: original.sourceIdentity, firstPassText: "Substituted words",
                media: original.media, firstPassReferences: original.firstPassReferences))
        do { try await fixture.reader.revalidate(changed); XCTFail("Text must equal the ordered exact row proof") }
        catch { XCTAssertEqual(error as? CompanionError, .staleEvidence) }
        // A retained file is deliberately not a substitute for a retained canonical row.
        let media = root.appendingPathComponent("retained-media-fixture")
        try Data("opaque retained media fixture".utf8).write(to: media)
        _ = try await fixture.audio.deleteTranscription(id: rows[0].id)
        do { try await fixture.reader.revalidate(request); XCTFail("Deleted first pass must revoke publication") }
        catch { XCTAssertEqual(error as? CompanionError, .staleEvidence) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
        try await fixture.close()
    }

    func testReadOnlyCatalogSharesActiveWriterLeaseAndRevokesDeletedFirstPass() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Fixture.make(root)
        let rows = try await fixture.insertFirstPass(), request = try fixture.request(rows)
        let spool = CompanionSpool(root: root.appendingPathComponent("delivery"), nativeStoreID: fixture.native)
        let writer = try spool.acquire(); defer { Darwin.close(writer) }
        try spool.initialize()
        let bytes = try CompanionWire.encode(request), id = CompanionWire.digest(bytes)
        let canonical = try CompanionWire.decode(CompanionJobRequest.self, data: bytes, limit: 768 * 1024)
        let source = try XCTUnwrap(canonical.speaker)
        let sourceObject = try JSONSerialization.jsonObject(with: CompanionWire.encode(source.sourceIdentity))
        let result: [String: Any] = ["version": 1, "jobID": id, "kind": "speaker", "sourceStoreID": fixture.native.uuidString,
            "speakerEnrichment": ["sourceIdentity": sourceObject,
                "firstPassSHA256": CompanionWire.digest(Data(source.firstPassText.utf8)), "enhancedText": "Separate refined words",
                "automaticNamesCalibrated": false, "modelFingerprint": String(repeating: "c", count: 64),
                "turns": [["start": 0, "end": 2, "text": "Separate refined words", "speakerID": id + ":state:unknown",
                           "speakerLabel": "Unknown speaker", "speakerStatus": "unknown"]]]]
        let resultBytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        try spool.publish(bytes, to: spool.path("requests", id))
        try spool.publish(resultBytes, to: spool.path("results", id))
        try spool.publish(Data(CompanionWire.digest(resultBytes).utf8), to: spool.path("receipts", id, suffix: ".imported"))
        let catalog = CompanionSpeakerCatalog(spool: spool, reader: fixture.reader)
        XCTAssertEqual(try catalog.requests().count, 1)
        let retained = try await catalog.retained(id)
        XCTAssertEqual(retained?.0.speaker?.firstPassText, source.firstPassText)
        XCTAssertEqual(retained?.1.speakerEnrichment?.enhancedText, "Separate refined words")
        _ = try await fixture.audio.deleteTranscription(id: rows[0].id)
        do { _ = try await catalog.retained(id); XCTFail("Retained files cannot replace a deleted native first pass") }
        catch { XCTAssertEqual(error as? CompanionError, .staleEvidence) }
        try await fixture.close()
    }

    func testContextPresentationRejectsChangedAndDeletedRealV23SourceRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await Fixture.make(root)
        let rows = try await fixture.insertFirstPass(), row = try XCTUnwrap(rows.first)
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { fixture.native })
        let marker = try await markers.createManualMarker(.init(anchoredAt: row.startTime))
        let reference = try CompanionTranscriptSnapshot.reference(for: row, nativeStoreID: fixture.native)
        let request = CompanionJobRequest(sourceStoreID: fixture.native, observedAt: row.startTime, context: .init(
            markerID: marker.id, markerRevision: marker.revision, snapshotID: UUID(), query: "Original sentence",
            verbatimExplanation: "", developing: true, incomplete: true,
            evidence: [.init(id: "original", reference: .init(v23Transcript: reference), start: row.startTime, end: row.endTime, text: row.text)]))
        let bytes = try CompanionWire.encode(request)
        let canonical = try CompanionWire.decode(CompanionJobRequest.self, data: bytes, limit: 768 * 1024)
        let source = try XCTUnwrap(canonical.context), support = try XCTUnwrap(source.evidence.first)
        let result = CompanionResult(jobID: CompanionWire.digest(bytes), sourceStoreID: fixture.native,
            contextProposal: .init(markerID: marker.id, markerRevision: marker.revision, snapshotID: source.snapshotID,
                verbatimExplanation: "", developing: true, incomplete: true,
                ranges: [.init(id: UUID(), start: support.start, end: support.end, explanation: support.text, supportIDs: [support.id], score: 1)], method: "authored"))
        try await CompanionContextImporter(markers: markers).apply(request: canonical, result: result,
            requestData: bytes, resultData: CompanionWire.encode(result))
        let presentation = ContextRangePresentationService(markers: markers, validateEvidence: { try await fixture.reader.revalidate($0) }, currentEpoch: { "fixture" })
        let visible = try await presentation.list(markerID: marker.id)
        XCTAssertEqual(visible.items.first?.range?.explanation, row.text)
        try await fixture.audio.updateTranscriptionText(id: row.id, text: "Changed exact source")
        let changed = try await presentation.list(markerID: marker.id)
        XCTAssertEqual(changed.items.first?.availability, .sourceUnavailable)
        XCTAssertNil(changed.items.first?.range)
        _ = try await fixture.audio.deleteTranscription(id: row.id)
        let deleted = try await presentation.list(markerID: marker.id)
        XCTAssertNil(deleted.items.first?.range)
        await presentation.close(); try await markers.close(); try await fixture.close()
    }

    func testFractionalNativeOriginRetainsWireIdentityWithoutRelaxingSampleIdentity() throws {
        let origin = Date(timeIntervalSinceReferenceDate: 814_235_789.1234567)
        let source = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(), startSample: 987,
            sampleCount: 32000, sampleRate: 16000, approximateOrigin: origin)
        let retained = try CompanionWire.decode(LiveAudioSampleIdentity.self, data: CompanionWire.encode(source), limit: 4096)
        XCTAssertTrue(CompanionController.sameWire(source, retained))
        XCTAssertTrue(CompanionController.sameWire(source.approximateOrigin, retained.approximateOrigin))
        let wrong = LiveAudioSampleIdentity(recordingGeneration: source.recordingGeneration, continuityID: source.continuityID,
            startSample: source.startSample + 1, sampleCount: source.sampleCount, sampleRate: 16000, approximateOrigin: retained.approximateOrigin)
        XCTAssertFalse(CompanionController.sameWire(source, wrong), "One sample is an identity change, never timing tolerance")
    }

    private struct Fixture {
        let database: DatabaseManager
        let adapter: DataAdapter
        let reader: CompanionEvidenceReader
        let audio: AudioTranscriptionQueries
        let native: UUID
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let batch = "audio/authored-original-batch.m4a"
        static func make(_ root: URL) async throws -> Fixture {
            let path = root.appendingPathComponent("recording.db").path
            let database = DatabaseManager(databasePath: path)
            try await database.initialize()
            let pointer = await database.getConnection()
            let audio = AudioTranscriptionQueries(db: try XCTUnwrap(pointer))
            let adapter = DataAdapter(retraceConnection: try await database.makeRecallReadConnection(),
                retraceConfig: .init(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
                retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
            try await adapter.initialize()
            let native = try await adapter.evidenceStoreID(source: .native)
            let recall = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() },
                imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
            let reader = CompanionEvidenceReader(databasePath: path, nativeStoreID: native, adapter: adapter,
                recall: recall, admission: {}, validateSpeaker: { _, _ in })
            return .init(database: database, adapter: adapter, reader: reader, audio: audio, native: native)
        }
        func insertFirstPass() async throws -> [AudioTranscription] {
            _ = try await audio.insertTranscription(sessionID: nil, text: "Original first sentence",
                startTime: time, endTime: time.addingTimeInterval(1), source: .microphone, confidence: nil,
                words: [], audioPath: batch, transcriptionPass: 1, batchAudioPath: batch)
            _ = try await audio.insertTranscription(sessionID: nil, text: "Original second sentence",
                startTime: time.addingTimeInterval(1), endTime: time.addingTimeInterval(2), source: .microphone,
                confidence: nil, words: [], audioPath: batch, transcriptionPass: 1, batchAudioPath: batch)
            return try await audio.getContextBatchEntries(batchAudioPath: batch)
        }
        func request(_ rows: [AudioTranscription]) throws -> CompanionJobRequest {
            let identity = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(),
                startSample: 0, sampleCount: 32000, sampleRate: 16000, approximateOrigin: time)
            return .init(sourceStoreID: native, observedAt: time,
                speaker: .init(sourceIdentity: identity, firstPassText: rows.map(\.text).joined(separator: "\n"),
                    media: [.init(sha256: String(repeating: "a", count: 64), byteCount: 128,
                        mediaID: String(repeating: "b", count: 64), offsetSamples: 0, countSamples: 32000, sourceStartSample: 0)],
                    firstPassReferences: try CompanionTranscriptSnapshot.firstPassReferences(for: rows, nativeStoreID: native)))
        }
        func close() async throws { await reader.close(); await adapter.shutdown(); try await database.close() }
    }
}
