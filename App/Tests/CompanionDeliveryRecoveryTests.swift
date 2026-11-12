import Database
import Foundation
import Shared
import XCTest
@testable import App

final class CompanionDeliveryRecoveryTests: XCTestCase {
    func testInteriorCoveragePublishesEveryFragmentWithOriginalFirstPassAndExactOffsets() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rows = try await fixture.insertRows()
        let plan = try CompanionBatchPlan(manifest: fixture.manifest, records: rows, nativeStoreID: fixture.native, enrollmentID: UUID())
        let middle = fixture.identity(start: 16000, count: 16000)
        let windows = try CompanionSpeakerWindow.uncovered(plan.identity, covered: [middle])
        XCTAssertEqual(windows.map(\.startSample), [0, 32000])
        XCTAssertEqual(windows.map(\.sampleCount), [16000, 32000])
        let requests = windows.map { plan.request(window: $0, byteCount: fixture.bytes.count) }
        for request in requests { try request.validate() }
        XCTAssertEqual(requests.compactMap { $0.speaker?.media.first?.offsetSamples }, [0, 32000])
        XCTAssertTrue(requests.allSatisfy { $0.speaker?.firstPassText == "Original complete first pass" && $0.speaker?.firstPassSourceIdentity == plan.identity })
        let semantic = try plan.planPayload(dependencyIDs: [])
        let service = fixture.service()
        let receipt = try await service.publishGroup(semanticPayload: semantic, requests: requests,
            objects: [.init(sha256: fixture.manifest.sha256, data: fixture.bytes)], batchKey: plan.key)
        XCTAssertEqual(receipt.jobIDs.count, 2)
        try await service.close()
        let reopened = fixture.service()
        let retry = try await reopened.publishGroup(semanticPayload: semantic, requests: requests,
            objects: [.init(sha256: fixture.manifest.sha256, data: fixture.bytes)], batchKey: plan.key)
        XCTAssertEqual(retry, receipt)
        let retained = try await reopened.speakerCoverage(intersecting: plan.identity)
        XCTAssertEqual(retained.count, 2)
        XCTAssertEqual(retained.map { $0.1.speaker!.sourceIdentity.startSample }.sorted(), [0, 32000])
        try await reopened.close(); try await fixture.close()
    }

    func testCallbackOmissionPendingTextAndFullOutboxRetainEligibilityAcrossReopen() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let contextPath = fixture.root.appendingPathComponent("context.db").path
        let markers = TimelineMarkerService(factory: { ContextDatabase(databasePath: contextPath, nativeStoreID: fixture.native) })
        _ = try await markers.setCompanionEnrollment(enabled: true)
        _ = try await markers.registerAudioManifest(fixture.manifest)
        let service = fixture.service()
        let full = RecoveryPublicationFailure()
        let run: @Sendable (TimelineMarkerService) async throws -> Void = { owner in
            try await CompanionBatchReconciler.run(markers: owner,
                readFirstPass: { try await fixture.audio.getContextBatchEntries(batchAudioPath: $0.relativePath) },
                publish: { candidate, rows in
                    try await full.check()
                    let plan = try CompanionBatchPlan(manifest: candidate.manifest, records: rows,
                        nativeStoreID: fixture.native, enrollmentID: candidate.enrollmentID)
                    return try await service.publishGroup(semanticPayload: plan.planPayload(dependencyIDs: []),
                        requests: [plan.request(window: plan.identity, byteCount: fixture.bytes.count)],
                        objects: [.init(sha256: fixture.manifest.sha256, data: fixture.bytes)], batchKey: plan.key)
                }, checkAdmission: {}, terminalSourceFailure: { _ in false })
        }
        // No callback, and no first-pass row yet: durable waiting, no empty-text inference.
        try await run(markers)
        let empty = try await service.status(); XCTAssertTrue(empty.isEmpty)
        _ = try await fixture.insertRows()
        try await makeDue(markers, manifest: fixture.manifest)
        do { try await run(markers); XCTFail("Full outbox remains retryable") }
        catch { XCTAssertEqual(error as? CompanionError, .capacityExceeded) }
        try await markers.close()
        let resumed = TimelineMarkerService(factory: { ContextDatabase(databasePath: contextPath, nativeStoreID: fixture.native) })
        _ = try await resumed.setCompanionEnrollment(enabled: true)
        try await makeDue(resumed, manifest: fixture.manifest)
        await full.allow()
        try await run(resumed)
        let pending = try await resumed.companionBatchCandidates(now: Date().addingTimeInterval(60), limit: 8)
        XCTAssertTrue(pending.isEmpty)
        let states = try await service.status(); XCTAssertEqual(states.count, 1)
        try await run(resumed)
        let stillOne = try await service.status(); XCTAssertEqual(stillOne.count, 1)
        try await service.close(); try await resumed.close(); try await fixture.close()
    }

    func testAcknowledgementCollectsOnlyUnreferencedStagedCopyAndKeepsOriginalAndHistory() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rows = try await fixture.insertRows(), transport = RecoveryResultTransport()
        let plan = try CompanionBatchPlan(manifest: fixture.manifest, records: rows, nativeStoreID: fixture.native, enrollmentID: UUID())
        let first = fixture.identity(start: 0, count: 32000), second = fixture.identity(start: 32000, count: 32000)
        let requests = [plan.request(window: first, byteCount: fixture.bytes.count), plan.request(window: second, byteCount: fixture.bytes.count)]
        let original = fixture.root.appendingPathComponent("original.m4a"); try fixture.bytes.write(to: original)
        let root = fixture.root.appendingPathComponent("delivery")
        let service = CompanionEnrichmentService(root: root, nativeStoreID: fixture.native, transport: transport,
            revalidate: { _ in }, importResult: { _, _, _, _ in })
        let receipt = try await service.publishGroup(semanticPayload: plan.planPayload(dependencyIDs: []), requests: requests,
            objects: [.init(sha256: fixture.manifest.sha256, data: fixture.bytes)], batchKey: plan.key)
        let staged = root.appendingPathComponent("objects/" + fixture.manifest.sha256 + ".m4a")
        _ = try await service.synchronize(limit: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path), "Another active fragment still needs the staged AAC")
        _ = try await service.synchronize(limit: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(try Data(contentsOf: original), fixture.bytes)
        for id in receipt.jobIDs { let result = try await service.retainedResult(jobID: id); XCTAssertNotNil(result) }
        try await service.close(); try await fixture.close()
    }

    func testLegacyFileMigrationPreservesImportedBytesAndDoesNotRepeatImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), spool = CompanionSpool(root: root, nativeStoreID: native)
        try spool.initialize()
        let request = CompanionJobRequest(sourceStoreID: native, observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            context: .init(markerID: UUID(), markerRevision: UUID(), snapshotID: UUID(), query: "Authored", verbatimExplanation: "", developing: true, incomplete: true, evidence: []))
        let bytes = try CompanionWire.encode(request), id = CompanionWire.digest(bytes), source = try XCTUnwrap(request.context)
        let result = CompanionResult(jobID: id, sourceStoreID: native, contextProposal: .init(markerID: source.markerID,
            markerRevision: source.markerRevision, snapshotID: source.snapshotID, verbatimExplanation: "", developing: true, incomplete: true, ranges: [], method: "authored"))
        let resultBytes = try CompanionWire.encode(result)
        try spool.publish(bytes, to: spool.path("requests", id))
        try spool.publish(resultBytes, to: spool.path("results", id))
        try spool.publish(Data(CompanionWire.digest(resultBytes).utf8), to: spool.path("receipts", id, suffix: ".imported"))
        let service = CompanionEnrichmentService(root: root, nativeStoreID: native, transport: RecoveryTransport(),
            revalidate: { _ in }, importResult: { _, _, _, _ in XCTFail("Already imported legacy result must not import again") })
        _ = try await service.synchronize()
        let catalog = CompanionDeliveryDatabase(databasePath: root.appendingPathComponent("delivery.db").path, nativeStoreID: native, readOnly: true)
        try await catalog.initialize()
        let stored = try await catalog.record(jobID: id)
        XCTAssertEqual(stored?.requestPayload, bytes); XCTAssertEqual(stored?.resultPayload, resultBytes)
        XCTAssertEqual(stored?.stage, .acknowledged)
        try await catalog.close(); try await service.close()
    }

    func testMarkerRefreshPressureRetainsFailedIDsAndStillDrainsDelivery() async throws {
        let dirty = Set([UUID(), UUID(), UUID()]), recent = UUID(), probe = RefreshPassProbe()
        do {
            try await CompanionRefreshPass.run(all: true, ids: dirty, recent: { [recent] },
                refresh: { id, force in try await probe.refresh(id, force: force) },
                retry: { id, force in probe.retry(id, force: force) }, retryAll: {}, drain: { await probe.drain() })
            XCTFail("Pressure remains visible while work is retained")
        } catch { XCTAssertEqual(error as? CompanionError, .capacityExceeded) }
        let state = probe.snapshot()
        XCTAssertEqual(state.retried, dirty.union([recent])); XCTAssertEqual(state.drains, 1)
        XCTAssertEqual(state.attempted, dirty.union([recent]))
    }

    private func makeDue(_ markers: TimelineMarkerService, manifest: AudioMediaManifest) async throws {
        let candidate = try await markers.companionBatchCandidate(manifestID: manifest.id)
        let current = try XCTUnwrap(candidate)
        try await markers.finishCompanionBatch(current, disposition: .waiting, groupID: nil, retryAfter: Date(timeIntervalSince1970: 1))
    }
    private struct Fixture: Sendable {
        let root: URL, native: UUID, database: DatabaseManager, audio: AudioTranscriptionQueries
        let manifest: AudioMediaManifest, bytes: Data
        static func make() async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let database = DatabaseManager(databasePath: root.appendingPathComponent("recording.db").path)
            try await database.initialize()
            let connection = await database.getConnection(), audio = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
            let native = UUID(), bytes = Data("Authored staged bytes; original recording is untouched".utf8)
            let identity = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(), startSample: 0,
                sampleCount: 64000, sampleRate: 16000, approximateOrigin: Date(timeIntervalSince1970: 1_800_000_000))
            let manifest = AudioMediaManifest(nativeStoreID: native, relativePath: "audio/authored.m4a", sha256: CompanionWire.digest(bytes), frameCount: 64000,
                sourceRanges: [.init(source: identity, batchStartSample: 0)])
            return .init(root: root, native: native, database: database, audio: audio, manifest: manifest, bytes: bytes)
        }
        func identity(start: Int64, count: Int64) -> LiveAudioSampleIdentity {
            let source = manifest.sourceRanges[0].source
            return .init(recordingGeneration: source.recordingGeneration, continuityID: source.continuityID, startSample: start,
                sampleCount: count, sampleRate: 16000, approximateOrigin: source.approximateOrigin)
        }
        func insertRows() async throws -> [AudioTranscription] {
            let source = manifest.sourceRanges[0].source
            _ = try await audio.insertTranscription(sessionID: nil, text: "Original complete first pass", startTime: source.approximateOrigin,
                endTime: source.approximateOrigin.addingTimeInterval(4), source: .microphone, confidence: nil, words: [], audioPath: manifest.relativePath,
                transcriptionPass: 1, batchAudioPath: manifest.relativePath)
            return try await audio.getContextBatchEntries(batchAudioPath: manifest.relativePath)
        }
        func service() -> CompanionEnrichmentService {
            CompanionEnrichmentService(root: root.appendingPathComponent("delivery"), nativeStoreID: native, transport: RecoveryTransport(),
                revalidate: { request in
                    if let speaker = request.speaker {
                        let rows = try await audio.getContextBatchEntries(batchAudioPath: manifest.relativePath)
                        guard try CompanionTranscriptSnapshot.firstPassReferences(for: rows, nativeStoreID: native) == speaker.firstPassReferences else { throw CompanionError.staleEvidence }
                    }
                }, importResult: { _, _, _, _ in })
        }
        func close() async throws { try await database.close() }
    }
}
private actor RecoveryPublicationFailure {
    var full = true
    func check() throws { if full { throw CompanionError.capacityExceeded } }
    func allow() { full = false }
}
private struct RecoveryTransport: CompanionTransport {
    func publishObject(sha256: String, data: Data) async throws {}
    func publishJob(id: String, data: Data) async throws {}
    func result(id: String) async throws -> Data? { nil }
    func acknowledge(id: String, resultSHA256: String) async throws {}
    func close() async {}
}

private actor RecoveryResultTransport: CompanionTransport {
    var requests: [String: Data] = [:]
    func publishObject(sha256: String, data: Data) async throws {}
    func publishJob(id: String, data: Data) async throws { requests[id] = data }
    func result(id: String) async throws -> Data? {
        guard let bytes = requests[id] else { return nil }
        let request = try CompanionWire.decode(CompanionJobRequest.self, data: bytes, limit: 768 * 1024)
        guard let speaker = request.speaker else { return nil }
        let source = try JSONSerialization.jsonObject(with: CompanionWire.encode(speaker.sourceIdentity))
        let result: [String: Any] = ["version": 1, "jobID": id, "kind": "speaker", "sourceStoreID": request.sourceStoreID.uuidString,
            "speakerEnrichment": ["sourceIdentity": source, "firstPassSHA256": CompanionWire.digest(Data(speaker.firstPassText.utf8)),
                "enhancedText": "Authored refinement", "turns": [], "automaticNamesCalibrated": false, "modelFingerprint": String(repeating: "d", count: 64)]]
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }
    func acknowledge(id: String, resultSHA256: String) async throws {}
    func close() async {}
}

private final class RefreshPassProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var attempted = Set<UUID>(), retried = Set<UUID>(), drains = 0
    func refresh(_ id: UUID, force: Bool) async throws {
        lock.withLock { attempted.insert(id) }; throw CompanionError.capacityExceeded
    }
    func retry(_ id: UUID, force: Bool) { lock.withLock { retried.insert(id) } }
    func drain() async { lock.withLock { drains += 1 } }
    func snapshot() -> (attempted: Set<UUID>, retried: Set<UUID>, drains: Int) { lock.withLock { (attempted, retried, drains) } }
}
