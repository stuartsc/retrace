import Database
import Darwin
import Foundation
import Shared
import Storage
import XCTest
@testable import App
@testable import Retrace

@MainActor
final class CompanionWorkspaceModelTests: XCTestCase {
    func testUnconfiguredAndDisconnectedCatalogRetainsValidatedLabelsAndManualCorrection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-workspace-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("recordings.db").path
        let database = DatabaseManager(databasePath: path)
        try await database.initialize()
        let connection = await database.getConnection()
        let audio = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let adapter = DataAdapter(retraceConnection: try await database.makeRecallReadConnection(),
            retraceConfig: .init(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
        try await adapter.initialize()
        let native = try await adapter.evidenceStoreID(source: .native)
        let recall = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() },
            imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { native })
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (0..<32_000).map { Int16(sin(Double($0) * 2 * .pi * 440 / 16_000) * 4_000) }
        let media = try await AudioSegmentWriter(storageRoot: root).writeFullBatch(
            audioData: samples.withUnsafeBytes { Data($0) }, timestamp: time, source: .microphone)
        let bytes = try Data(contentsOf: root.appendingPathComponent(media.filePath))
        let identity = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(),
            startSample: 0, sampleCount: 32_000, sampleRate: 16_000, approximateOrigin: time)
        let manifest = try await markers.registerAudioManifest(.init(nativeStoreID: native,
            relativePath: media.filePath, sha256: CompanionWire.digest(bytes), frameCount: 32_000,
            sourceRanges: [.init(source: identity, batchStartSample: 0)]))
        let rowID = try await audio.insertTranscription(sessionID: nil, text: "Authored first pass words", startTime: time,
            endTime: time.addingTimeInterval(2), source: .microphone, confidence: nil, words: [],
            audioPath: media.filePath, transcriptionPass: 1, batchAudioPath: media.filePath)
        let rows = try await audio.getContextBatchEntries(batchAudioPath: media.filePath)
        let request = CompanionJobRequest(sourceStoreID: native, observedAt: time,
            speaker: .init(sourceIdentity: identity, firstPassText: rows.map(\.text).joined(separator: "\n"),
                media: [.init(sha256: manifest.sha256, byteCount: bytes.count,
                    mediaID: CompanionWire.digest(Data(manifest.id.uuidString.lowercased().utf8)),
                    offsetSamples: 0, countSamples: 32_000, sourceStartSample: 0)],
                firstPassReferences: try CompanionTranscriptSnapshot.firstPassReferences(for: rows, nativeStoreID: native)))
        let requestData = try CompanionWire.encode(request), id = CompanionWire.digest(requestData)
        let canonical = try CompanionWire.decode(CompanionJobRequest.self, data: requestData, limit: 768 * 1024)
        let source = try XCTUnwrap(canonical.speaker)
        let sourceObject = try JSONSerialization.jsonObject(with: CompanionWire.encode(source.sourceIdentity))
        let speakerID = id + ":state:unknown"
        let result: [String: Any] = ["version": 1, "jobID": id, "kind": "speaker", "sourceStoreID": native.uuidString,
            "speakerEnrichment": ["sourceIdentity": sourceObject,
                "firstPassSHA256": CompanionWire.digest(Data(source.firstPassText.utf8)), "enhancedText": "Authored refined words",
                "automaticNamesCalibrated": false, "modelFingerprint": String(repeating: "c", count: 64),
                "turns": [["start": 0, "end": 2, "text": "Authored refined words", "speakerID": speakerID,
                           "speakerLabel": "Unknown speaker", "speakerStatus": "unknown"]]]]
        let resultData = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        let companionRoot = root.appendingPathComponent("companion")
        let spool = CompanionSpool(root: companionRoot.appendingPathComponent("delivery"), nativeStoreID: native)
        do {
            let writer = try spool.acquire()
            defer { Darwin.close(writer) }
            try spool.initialize()
            try spool.publish(requestData, to: spool.path("requests", id))
            try spool.publish(resultData, to: spool.path("results", id))
            try spool.publish(Data(CompanionWire.digest(resultData).utf8), to: spool.path("receipts", id, suffix: ".imported"))
        }
        let owner = CompanionController(storageRoot: companionRoot, nativeStoreID: native, databasePath: path,
            adapter: adapter, recall: recall, markers: markers, verifiedBytes: { retained in
                guard retained == manifest else { throw CompanionError.staleEvidence }
                let current = try Data(contentsOf: root.appendingPathComponent(retained.relativePath))
                guard CompanionWire.digest(current) == retained.sha256 else { throw CompanionError.staleEvidence }
                return current
            }, policy: {})
        let model = CompanionWorkspaceModel(service: { owner })
        let interval = DateInterval(start: time, duration: 2)
        await model.refresh(interval: interval)
        XCTAssertEqual(model.presentations.map(\.jobID), [id], "Saved labels must be available before any connection is configured")
        XCTAssertEqual(model.title, "Companion not configured")
        try await model.select(jobID: id)
        let presentation = try XCTUnwrap(model.selectedPresentation)
        XCTAssertEqual(presentation.firstPassText, "Authored first pass words")
        model.correct(presentation, speakerID: speakerID, name: "Alex (authored fixture)")
        await model.finishPendingWrite()
        try await owner.configure(nil)
        await model.refresh(interval: interval)
        XCTAssertEqual(model.presentations.map(\.jobID), [id])
        XCTAssertEqual(model.selectedPresentation?.corrections.first?.displayName, "Alex (authored fixture)")
        XCTAssertEqual(model.selectedPresentation?.firstPassText, "Authored first pass words")
        let state = await owner.status()
        XCTAssertEqual(state.state, .unconfigured, "Reading retained labels must not configure a transport")
        _ = try await audio.deleteTranscription(id: rowID)
        await model.refresh(interval: interval)
        XCTAssertTrue(model.presentations.isEmpty, "Disconnection cannot bypass current canonical source validation")
        XCTAssertNil(model.selectedPresentation)
        model.hide()
        try await owner.close(); try await markers.close(); await adapter.shutdown(); try await database.close()
    }
}
