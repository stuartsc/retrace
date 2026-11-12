import Foundation
import XCTest
import Shared
import Database
import Storage
@testable import App

final class CompanionCorrectionTests: XCTestCase {
    func testControllerConstructionIsInertAndCloseIsTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("recording.db").path
        let database = DatabaseManager(databasePath: path)
        try await database.initialize()
        let adapter = DataAdapter(retraceConnection: try await database.makeRecallReadConnection(),
            retraceConfig: .init(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
        try await adapter.initialize()
        let native = try await adapter.evidenceStoreID(source: .native)
        let recall = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() },
            imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { native })
        let companionRoot = root.appendingPathComponent("companion")
        let owner = CompanionController(storageRoot: companionRoot, nativeStoreID: native, databasePath: path,
            adapter: adapter, recall: recall, markers: markers, verifiedBytes: { _ in throw CompanionError.unavailable }, policy: {})
        let state = await owner.status()
        XCTAssertEqual(state.state, .unconfigured)
        XCTAssertFalse(FileManager.default.fileExists(atPath: companionRoot.path))
        try await owner.close()
        do { try await owner.configure(nil); XCTFail("Closed owner must stay closed") }
        catch { XCTAssertEqual(error as? CompanionError, .closed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: companionRoot.path))
        try await markers.close(); await adapter.shutdown(); try await database.close()
    }
    func testV23FullRowProofSurvivesReopenAndRejectsReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("recording.db").path, native = UUID()
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let first = DatabaseManager(databasePath: path)
        try await first.initialize()
        let pointer = await first.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(pointer))
        let id = try await queries.insertTranscription(sessionID: "session", text: "Original first pass",
            startTime: time, endTime: time.addingTimeInterval(2), source: .microphone, confidence: 0.8, words: [])
        let value = try await queries.getContextEntry(id: id)
        let row = try XCTUnwrap(value)
        let proof = try CompanionTranscriptSnapshot.reference(for: row, nativeStoreID: native)
        try await first.close()
        let second = DatabaseManager(databasePath: path)
        try await second.initialize()
        let secondPointer = await second.getConnection()
        let reopened = AudioTranscriptionQueries(db: try XCTUnwrap(secondPointer))
        let currentValue = try await reopened.getContextEntry(id: id)
        let current = try XCTUnwrap(currentValue)
        XCTAssertTrue(try CompanionTranscriptSnapshot.matches(proof, record: current, nativeStoreID: native))
        XCTAssertFalse(try CompanionTranscriptSnapshot.matches(proof, record: current, nativeStoreID: UUID()))
        let changed = AudioTranscription(id: id, sessionID: current.sessionID, text: current.text,
            startTime: current.startTime, endTime: current.endTime, source: current.source, confidence: current.confidence,
            createdAt: current.createdAt, transcriptStatus: "needs_repair")
        XCTAssertFalse(try CompanionTranscriptSnapshot.matchesRecording(proof, record: changed, nativeStoreID: native))
        let pendingProof = try CompanionTranscriptSnapshot.recordingReference(for: changed, nativeStoreID: native)
        XCTAssertTrue(try CompanionTranscriptSnapshot.matchesRecording(pendingProof, record: changed, nativeStoreID: native))
        XCTAssertThrowsError(try CompanionTranscriptSnapshot.reference(for: changed, nativeStoreID: native))
        try await second.close()
    }
    func testCorrectionRetryConflictUndoAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), source = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(),
            startSample: 0, sampleCount: 16000, sampleRate: 16000, approximateOrigin: Date())
        let job = String(repeating: "a", count: 64), speaker = job + ":cluster:0"
        let command = CompanionSpeakerCorrectionCommand(jobID: job, speakerID: speaker, displayName: "Alex", expectedRevision: nil)
        let first = CompanionSpeakerCorrectionStore(root: root, nativeStoreID: native)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let saved = try await first.apply(command, sourceIdentity: source)
        let retry = try await first.apply(command, sourceIdentity: source)
        XCTAssertEqual(retry, saved)
        do {
            _ = try await first.apply(.init(clientID: command.clientID, requestID: command.requestID,
                jobID: job, speakerID: speaker, displayName: "Different", expectedRevision: nil), sourceIdentity: source)
            XCTFail("Conflicting retry must fail")
        } catch { XCTAssertEqual(error as? CompanionError, .conflictingPublication) }
        await first.close()
        let second = CompanionSpeakerCorrectionStore(root: root, nativeStoreID: native)
        let retained = try await second.list(speakerIDs: [speaker], sourceIdentity: source)
        XCTAssertEqual(retained, [saved])
        let undone = try await second.apply(.init(jobID: job, speakerID: speaker, displayName: nil,
            expectedRevision: saved.revision), sourceIdentity: source)
        let lateRetry = try await second.apply(command, sourceIdentity: source)
        XCTAssertEqual(lateRetry, undone)
        await second.close()
        let third = CompanionSpeakerCorrectionStore(root: root, nativeStoreID: native)
        let final = try await third.list(speakerIDs: [speaker], sourceIdentity: source)
        XCTAssertEqual(final, [undone]); XCTAssertNil(final.first?.displayName)
        await third.close()
    }

    func testTransportAdmissionRevocationIsSynchronous() throws {
        let gate = CompanionAdmissionGate(), old = gate.replace(allowed: true)
        var resumed = false
        try gate.admit(old) { resumed = true }
        XCTAssertTrue(resumed)
        _ = gate.replace(allowed: false)
        resumed = false
        XCTAssertThrowsError(try gate.admit(old) { resumed = true })
        XCTAssertFalse(resumed)
    }
    func testFiveSecondLeadingOverlapUsesOnlyFreshPCMAndPreservesOriginalScope() throws {
        let generation = UUID(), continuity = UUID(), origin = Date()
        let old = LiveAudioSampleIdentity(recordingGeneration: generation, continuityID: continuity,
            startSample: 0, sampleCount: 480000, sampleRate: 16000, approximateOrigin: origin)
        let full = LiveAudioSampleIdentity(recordingGeneration: generation, continuityID: continuity,
            startSample: 400000, sampleCount: 480000, sampleRate: 16000, approximateOrigin: origin)
        let fresh = try CompanionSpeakerWindow.fresh(full, covered: [old])
        XCTAssertEqual(fresh?.startSample, 480000)
        XCTAssertEqual(fresh?.sampleCount, 400000)
        let other = LiveAudioSampleIdentity(recordingGeneration: generation, continuityID: UUID(),
            startSample: 0, sampleCount: 480000, sampleRate: 16000, approximateOrigin: origin)
        XCTAssertEqual(try CompanionSpeakerWindow.fresh(full, covered: [other]), full)
        XCTAssertNil(try CompanionSpeakerWindow.fresh(old, covered: [old]))
    }
}
