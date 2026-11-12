import Foundation
import XCTest
import Shared
import Database
@testable import App

final class CompanionEnrichmentTests: XCTestCase {
    func testRevocationDuringFirstUploadPreventsRemainingObjectsAndJob() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CompanionAdmissionGate(), generation = gate.replace(allowed: true), transport = BlockingUploadTransport()
        let native = UUID()
        let active = CompanionEnrichmentService(root: root, nativeStoreID: native, transport: transport,
            revalidate: { _ in try gate.check(generation) }, importResult: { _, _, _, _ in })
        let first = Data("first authored AAC object".utf8), second = Data("second authored AAC object".utf8)
        let a = CompanionWire.digest(first), b = CompanionWire.digest(second)
        let source = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(), startSample: 0,
            sampleCount: 32000, sampleRate: 16000, approximateOrigin: Date())
        let request = CompanionJobRequest(sourceStoreID: native, observedAt: Date(), speaker: .init(sourceIdentity: source,
            firstPassText: "Original", media: [.init(sha256: a, byteCount: first.count, mediaID: a,
                offsetSamples: 0, countSamples: 16000, sourceStartSample: 0),
                .init(sha256: b, byteCount: second.count, mediaID: b, offsetSamples: 0, countSamples: 16000, sourceStartSample: 16000)],
            firstPassReferences: [.init(nativeStoreID: native, source: .microphone, rowID: 1, snapshotSHA256: String(repeating: "c", count: 64))]))
        _ = try await active.publish(request, objects: [.init(sha256: a, data: first), .init(sha256: b, data: second)])
        let synchronize = Task { try await active.synchronize() }
        await transport.entered.waitForEntry()
        gate.replace(allowed: false)
        await transport.entered.release()
        do { _ = try await synchronize.value; XCTFail("Revoked publication must stop") }
        catch { XCTAssertEqual(error as? CompanionError, .staleEvidence) }
        let uploads = await transport.uploads, jobs = await transport.jobs
        XCTAssertEqual(uploads, 1); XCTAssertEqual(jobs, 0)
        try await active.close()
    }
    func testDurableDeliveryReplayImportAndAcknowledgementAcrossReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UUID(), transport = HeldCompanionTransport(), imports = CompanionImportCounter()
        let request = CompanionJobRequest(sourceStoreID: store, observedAt: Date(), context: .init(
            markerID: UUID(), markerRevision: UUID(), snapshotID: UUID(), query: "Budget decision",
            verbatimExplanation: "Discussed pricing", developing: true, incomplete: true, evidence: []))
        let first = CompanionEnrichmentService(root: root, nativeStoreID: store, transport: transport,
            revalidate: { _ in }, importResult: { _, _, _, _ in await imports.record() })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let id = try await first.publish(request)
        let retryID = try await first.publish(request)
        XCTAssertEqual(id, retryID)
        try await transport.complete(request: request, id: id)
        _ = try await first.synchronize(limit: 2)
        try await first.close()
        let second = CompanionEnrichmentService(root: root, nativeStoreID: store, transport: transport,
            revalidate: { _ in }, importResult: { _, _, _, _ in await imports.record() })
        _ = try await second.synchronize(limit: 2)
        let count = await imports.count
        XCTAssertEqual(count, 1)
        let states = try await second.status()
        XCTAssertEqual(states.first?.state, .acknowledged)
        let retained = try await second.retainedResult(jobID: id)
        XCTAssertNotNil(retained)
        try await second.close()
        let wrong = CompanionEnrichmentService(root: root, nativeStoreID: UUID(), transport: transport,
            revalidate: { _ in }, importResult: { _, _, _, _ in })
        do { _ = try await wrong.status(); XCTFail("Must reject a different native store") }
        catch { XCTAssertEqual(error as? CompanionError, .nativeStoreMismatch) }
        try await wrong.close()
    }

    func testCloseJoinsHeldPublicationAndRejectsNewAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CompanionGate(), store = UUID(), transport = HeldCompanionTransport()
        let service = CompanionEnrichmentService(root: root, nativeStoreID: store, transport: transport,
            revalidate: { _ in await gate.hold() }, importResult: { _, _, _, _ in })
        let request = CompanionJobRequest(sourceStoreID: store, observedAt: Date(), context: .init(
            markerID: UUID(), markerRevision: UUID(), snapshotID: UUID(), query: "Decision",
            verbatimExplanation: "", developing: false, incomplete: true, evidence: []))
        let publish = Task { try await service.publish(request) }
        await gate.waitForEntry()
        await service.beginClose()
        let close = Task { try await service.close() }
        do { _ = try await service.publish(request); XCTFail("closed") } catch {}
        await gate.release()
        do { _ = try await publish.value; XCTFail("cancelled") } catch is CancellationError {}
        try await close.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("requests").path))
    }

    func testPinnedContextSurvivesLateImportAndReferencesRemainInResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID()
        let markers = TimelineMarkerService(factory: { ContextDatabase(databasePath: root.appendingPathComponent("context.db").path, nativeStoreID: native) })
        let marker = try await markers.createManualMarker(.init(anchoredAt: Date()))
        let range = MarkerContextRange(start: Date(timeIntervalSince1970: 1_800_000_000),
            end: Date(timeIntervalSince1970: 1_800_000_003), explanation: "My correction", ownership: .pinned)
        let saved = try await markers.saveContextRange(markerID: marker.id, range: range, expectedRevision: nil)
        let proposal = CompanionContextProposal(markerID: marker.id, markerRevision: marker.revision,
            snapshotID: UUID(), verbatimExplanation: "Original spoken explanation", developing: true, incomplete: false,
            ranges: [.init(id: saved.id, start: range.start, end: range.end,
                           explanation: "Automatic proposal", supportIDs: ["screen-exact"], score: 0.9)], method: "authored")
        let request = CompanionJobRequest(sourceStoreID: native, observedAt: marker.anchoredAt, context: .init(
            markerID: marker.id, markerRevision: marker.revision, snapshotID: proposal.snapshotID,
            query: "Decision", verbatimExplanation: proposal.verbatimExplanation, developing: true, incomplete: false,
            evidence: [.init(id: "screen-exact", reference: .init(v23Transcript: .init(nativeStoreID: native,
                source: .microphone, rowID: 1, snapshotSHA256: String(repeating: "a", count: 64))),
                start: range.start, end: range.end, text: "Automatic proposal")]))
        let requestData = try CompanionWire.encode(request)
        let canonical = try CompanionWire.decode(CompanionJobRequest.self, data: requestData, limit: 768 * 1024)
        let result = CompanionResult(jobID: CompanionWire.digest(requestData), sourceStoreID: native, contextProposal: proposal)
        try await CompanionContextImporter(markers: markers).apply(request: canonical, result: result,
            requestData: requestData, resultData: CompanionWire.encode(result))
        let retained = try await markers.listContextRanges(markerID: marker.id)
        XCTAssertEqual(retained, [saved])
        let deleted = try await markers.setMarkerDeleted(id: marker.id, expectedRevision: marker.revision, deleted: true)
        _ = try await markers.setMarkerDeleted(id: marker.id, expectedRevision: deleted.revision, deleted: false)
        do {
            _ = try await markers.saveContextRange(markerID: marker.id,
                range: .init(start: range.start, end: range.end, explanation: "Stale proposal", ownership: .proposed),
                expectedRevision: nil, expectedMarkerRevision: marker.revision)
            XCTFail("The marker revision must be checked in the range transaction")
        } catch { XCTAssertEqual(error as? ContextStoreError, .revisionConflict) }
        try await markers.close()
    }

    func testFailedAcknowledgementReplaysWithoutRepeatingImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UUID(), transport = HeldCompanionTransport(), imports = CompanionImportCounter()
        let service = CompanionEnrichmentService(root: root, nativeStoreID: store, transport: transport,
            revalidate: { _ in }, importResult: { _, _, _, _ in await imports.record() })
        let request = CompanionJobRequest(sourceStoreID: store, observedAt: Date(), context: .init(
            markerID: UUID(), markerRevision: UUID(), snapshotID: UUID(), query: "Decision",
            verbatimExplanation: "", developing: false, incomplete: true, evidence: []))
        let id = try await service.publish(request)
        try await transport.complete(request: request, id: id)
        await transport.rejectNextAcknowledgement()
        do { _ = try await service.synchronize(); XCTFail("Expected offline acknowledgement") }
        catch { XCTAssertEqual(error as? CompanionError, .unavailable) }
        let pending = try await service.status()
        XCTAssertEqual(pending.first?.state, .imported)
        _ = try await service.synchronize()
        let count = await imports.count
        XCTAssertEqual(count, 1)
        try await service.close()
    }
}

private actor CompanionImportCounter { var count = 0; func record() { count += 1 } }
private actor CompanionGate {
    var waiter: CheckedContinuation<Void, Never>?
    var entered: CheckedContinuation<Void, Never>?
    var didEnter = false
    func hold() async { didEnter = true; entered?.resume(); entered = nil; await withCheckedContinuation { waiter = $0 } }
    func waitForEntry() async { if !didEnter { await withCheckedContinuation { entered = $0 } } }
    func release() { waiter?.resume(); waiter = nil }
}
private actor HeldCompanionTransport: CompanionTransport {
    var results: [String: Data] = [:]
    var rejectAck = false
    func rejectNextAcknowledgement() { rejectAck = true }
    func complete(request: CompanionJobRequest, id: String) throws {
        let context = try XCTUnwrap(request.context)
        results[id] = try CompanionWire.encode(CompanionResult(jobID: id, sourceStoreID: request.sourceStoreID,
            contextProposal: .init(markerID: context.markerID, markerRevision: context.markerRevision,
                snapshotID: context.snapshotID, verbatimExplanation: context.verbatimExplanation,
                developing: context.developing, incomplete: context.incomplete, ranges: [], method: "authored")))
    }
    func publishObject(sha256: String, data: Data) async throws {}
    func publishJob(id: String, data: Data) async throws {}
    func result(id: String) async throws -> Data? { results[id] }
    func acknowledge(id: String, resultSHA256: String) async throws {
        if rejectAck { rejectAck = false; throw CompanionError.unavailable }
    }
    func close() async {}
}
private actor BlockingUploadTransport: CompanionTransport {
    let entered = CompanionGate()
    var uploads = 0
    var jobs = 0
    func publishObject(sha256: String, data: Data) async throws { uploads += 1; if uploads == 1 { await entered.hold() } }
    func publishJob(id: String, data: Data) { jobs += 1 }
    func result(id: String) -> Data? { nil }
    func acknowledge(id: String, resultSHA256: String) {}
    func close() {}
}
