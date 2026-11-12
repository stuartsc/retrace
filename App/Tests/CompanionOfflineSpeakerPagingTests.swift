import Database
import Foundation
import Shared
import Storage
import XCTest
@testable import App

final class CompanionOfflineSpeakerPagingTests: XCTestCase {
    func testDeletedFirstImportedJobCannotStarveValidSpeakerHistoryAfterDisconnect() async throws {
        try await exerciseDeletedFirst(indexed: false)
    }

    func testIndexedRetainedSpeakerHistoryWorksAfterLegacyFilesAreRemovedAndTransportDisconnects() async throws {
        try await exerciseDeletedFirst(indexed: true)
    }

    private func exerciseDeletedFirst(indexed: Bool) async throws {
        let fixture = try await Fixture.make()
        let older = try await fixture.publish(offset: 0, text: "Retained older recording")
        let newer = try await fixture.publish(offset: 10, text: "Deleted newer recording")
        if indexed { try await fixture.indexAndRemoveLegacyFiles([older.jobID, newer.jobID]) }
        let first = try await fixture.owner.speakerPresentations(from: fixture.time.addingTimeInterval(-1),
            to: fixture.time.addingTimeInterval(20), limit: 1)
        XCTAssertEqual(first.items.map(\.jobID), [newer.jobID])
        XCTAssertNotNil(first.nextCursor)
        _ = try await fixture.audio.deleteTranscription(id: newer.rowID)
        fixture.owner.sourceChanged(refreshContext: false)
        try await fixture.owner.configure(nil)
        let offline = try await fixture.owner.speakerPresentations(from: fixture.time.addingTimeInterval(-1),
            to: fixture.time.addingTimeInterval(20), limit: 1)
        XCTAssertEqual(offline.items.map(\.jobID), [older.jobID])
        XCTAssertEqual(offline.items.first?.firstPassText, "Retained older recording")
        XCTAssertTrue(offline.incomplete)
        XCTAssertNil(offline.nextCursor, "The deleted request must advance the bounded cursor")
        let resumed = try await fixture.owner.speakerPresentations(from: fixture.time.addingTimeInterval(-1),
            to: fixture.time.addingTimeInterval(20), before: first.nextCursor, limit: 1)
        XCTAssertEqual(resumed.items.map(\.jobID), [older.jobID])
        let state = await fixture.owner.status()
        XCTAssertEqual(state.state, .unconfigured)
        try await fixture.close()
    }

    private struct Fixture {
        let root: URL
        let database: DatabaseManager
        let adapter: DataAdapter
        let audio: AudioTranscriptionQueries
        let markers: TimelineMarkerService
        let media: MarkerAudioMediaService
        let owner: CompanionController
        let native: UUID
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        static func make() async throws -> Self {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
            let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { native })
            let media = MarkerAudioMediaService(storageRoot: root, markers: markers, nativeStoreID: { native })
            let recall = ProgressiveRecallService(database: database, adapter: adapter, configuration: { Shared.CaptureConfig() },
                imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
            let owner = CompanionController(storageRoot: root.appendingPathComponent("companion"), nativeStoreID: native,
                databasePath: path, adapter: adapter, recall: recall, markers: markers,
                verifiedBytes: { try await media.verifiedBytes(for: $0) }, policy: {})
            let spool = CompanionSpool(root: root.appendingPathComponent("companion/delivery"), nativeStoreID: native)
            try spool.initialize()
            return .init(root: root, database: database, adapter: adapter, audio: audio, markers: markers, media: media, owner: owner, native: native)
        }
        func publish(offset: TimeInterval, text: String) async throws -> (jobID: String, rowID: Int64) {
            let start = time.addingTimeInterval(offset)
            let samples = (0..<32000).map { Int16(sin(Double($0) * 2 * .pi * 220 / 16000) * 4000) }
            let pcm = samples.withUnsafeBytes { Data($0) }
            let saved = try await AudioSegmentWriter(storageRoot: root).writeFullBatch(audioData: pcm, timestamp: start, source: .microphone)
            let rowID = try await audio.insertTranscription(sessionID: nil, text: text, startTime: start,
                endTime: start.addingTimeInterval(2), source: .microphone, confidence: nil, words: [],
                audioPath: saved.filePath, transcriptionPass: 1, batchAudioPath: saved.filePath)
            let identity = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(),
                startSample: 0, sampleCount: 32000, sampleRate: 16000, approximateOrigin: start)
            let manifest = try await media.register(.init(rawBatchID: rowID, relativePath: saved.filePath,
                fileURL: root.appendingPathComponent(saved.filePath), fileSize: saved.fileSize, frameCount: 32000,
                sampleRate: 16000, channels: 1, source: .microphone, startTimestamp: start,
                endTimestamp: start.addingTimeInterval(2), sourceRanges: [.init(source: identity, batchStartSample: 0)]))
            let rows = try await audio.getContextBatchEntries(batchAudioPath: saved.filePath)
            let request = CompanionJobRequest(sourceStoreID: native, observedAt: start,
                speaker: .init(sourceIdentity: identity, firstPassText: text,
                    media: [.init(sha256: manifest.sha256, byteCount: Int(saved.fileSize),
                        mediaID: CompanionWire.digest(Data(manifest.id.uuidString.lowercased().utf8)),
                        offsetSamples: 0, countSamples: 32000, sourceStartSample: 0)],
                    firstPassReferences: try CompanionTranscriptSnapshot.firstPassReferences(for: rows, nativeStoreID: native)))
            let bytes = try CompanionWire.encode(request), id = CompanionWire.digest(bytes)
            let sourceObject = try JSONSerialization.jsonObject(with: CompanionWire.encode(identity))
            let result: [String: Any] = ["version": 1, "jobID": id, "kind": "speaker", "sourceStoreID": native.uuidString,
                "speakerEnrichment": ["sourceIdentity": sourceObject, "firstPassSHA256": CompanionWire.digest(Data(text.utf8)),
                    "enhancedText": text, "automaticNamesCalibrated": false, "modelFingerprint": String(repeating: "a", count: 64),
                    "turns": [["start": 0, "end": 2, "text": text, "speakerID": id + ":state:unknown",
                               "speakerLabel": "Unknown speaker", "speakerStatus": "unknown"]]]]
            let resultBytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            let spool = CompanionSpool(root: root.appendingPathComponent("companion/delivery"), nativeStoreID: native)
            try spool.publish(bytes, to: spool.path("requests", id))
            try spool.publish(resultBytes, to: spool.path("results", id))
            try spool.publish(Data(CompanionWire.digest(resultBytes).utf8), to: spool.path("receipts", id, suffix: ".imported"))
            return (id, rowID)
        }
        func indexAndRemoveLegacyFiles(_ ids: [String]) async throws {
            let spool = CompanionSpool(root: root.appendingPathComponent("companion/delivery"), nativeStoreID: native)
            let index = CompanionDeliveryDatabase(databasePath: spool.root.appendingPathComponent("delivery.db").path, nativeStoreID: native)
            try await index.initialize()
            for id in ids {
                try await index.importLegacy(requestPayload: spool.read(spool.path("requests", id), limit: 768 * 1024),
                    resultPayload: spool.read(spool.path("results", id), limit: 2 * 1024 * 1024), stage: .imported)
            }
            try await index.completeLegacyMigration(); try await index.close()
            for id in ids {
                try FileManager.default.removeItem(at: spool.path("requests", id))
                try FileManager.default.removeItem(at: spool.path("results", id))
                try FileManager.default.removeItem(at: spool.path("receipts", id, suffix: ".imported"))
            }
        }
        func close() async throws {
            try await owner.close(); try await markers.close(); await adapter.shutdown(); try await database.close()
            try FileManager.default.removeItem(at: root)
        }
    }
}
