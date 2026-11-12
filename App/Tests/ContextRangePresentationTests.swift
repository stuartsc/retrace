import Foundation
import Database
import Shared
import XCTest
@testable import App

final class ContextRangePresentationTests: XCTestCase {
    func testProcessLocalDependenciesNeverEnterPresentationWirePayload() throws {
        let page = ContextRangePresentationPage(markerID: UUID(), markerRevision: UUID(), items: [], incomplete: false,
            sourceDependencies: .init(targets: [.audioBatch("private/fixture-recording.m4a"), .audioRow(12)]))
        let encoded = try JSONEncoder().encode(page)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["markerID", "markerRevision", "items", "incomplete"])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("fixture-recording"))
        let decoded = try JSONDecoder().decode(ContextRangePresentationPage.self, from: encoded)
        XCTAssertEqual(decoded.sourceDependencies, .unknown, "A wire payload cannot grant selective local invalidation")
    }

    func testRetainedProvenanceSurvivesPinAndSuppressesDerivedTextAfterSourceRevocationAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), source = ContextPresentationSource()
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { native })
        let marker = try await markers.createManualMarker(.init(anchoredAt: Date(timeIntervalSince1970: 1_800_000_000.123456)))
        let fixture = try makeProposal(marker)
        try await CompanionContextImporter(markers: markers).apply(request: fixture.0, result: fixture.1, requestData: fixture.2, resultData: fixture.3)
        let owner = ContextRangePresentationService(markers: markers, validateEvidence: { try await source.validate($0) }, currentEpoch: { await source.epoch })
        let page = try await owner.list(markerID: marker.id)
        let item = try XCTUnwrap(page.items.first), range = try XCTUnwrap(item.range)
        XCTAssertEqual(range.explanation, "Sensitive retained source words")
        _ = try await markers.saveContextRange(markerID: marker.id, range: .init(id: range.id, start: range.start, end: range.end,
            explanation: range.explanation, ownership: .pinned, userNote: "My own note"), expectedRevision: range.revision, expectedMarkerRevision: marker.revision)
        await source.revoke(); owner.invalidate()
        let denied = try await owner.list(markerID: marker.id)
        XCTAssertEqual(denied.items.first?.availability, .sourceUnavailable)
        XCTAssertNil(denied.items.first?.range)
        XCTAssertEqual(denied.items.first?.userNote, "My own note")
        await owner.close(); try await markers.close()
        let reopened = TimelineMarkerService(storageRoot: root, nativeStoreID: { native })
        let offline = ContextRangePresentationService(markers: reopened, validateEvidence: { try await source.validate($0) }, currentEpoch: { await source.epoch })
        let stillDenied = try await offline.list(markerID: marker.id)
        XCTAssertNil(stillDenied.items.first?.range)
        await source.restore()
        let available = try await offline.list(markerID: marker.id)
        XCTAssertEqual(available.items.first?.range?.explanation, range.explanation)
        XCTAssertEqual(available.items.first?.range?.provenance, range.provenance)
        await offline.close(); try await reopened.close()
    }

    func testFinalEpochChangeRejectsBatchAndCloseIsTerminal() async throws {
        let native = UUID(), db = ContextDatabase(databasePath: ":memory:", nativeStoreID: native)
        let markers = TimelineMarkerService(factory: { db })
        let marker = try await markers.createManualMarker(.init(anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let fixture = try makeProposal(marker)
        try await CompanionContextImporter(markers: markers).apply(request: fixture.0, result: fixture.1, requestData: fixture.2, resultData: fixture.3)
        let gate = ContextPresentationGate()
        let owner = ContextRangePresentationService(markers: markers, validateEvidence: { _ in await gate.hold() }, currentEpoch: { await gate.epoch })
        let read = Task { try await owner.list(markerID: marker.id) }
        await gate.waitForRead()
        await gate.release()
        do { _ = try await read.value; XCTFail("An invalidated batch cannot disclose") }
        catch { XCTAssertTrue(error is CancellationError || error as? CompanionError == .staleEvidence) }
        await owner.close()
        do { _ = try await owner.list(markerID: marker.id); XCTFail("Close is terminal") }
        catch { XCTAssertEqual(error as? CompanionError, .closed) }
        try await markers.close()
    }

    private func makeProposal(_ marker: TimelineMarker) throws -> (CompanionJobRequest, CompanionResult, Data, Data) {
        let support = CompanionEvidenceItem(id: "retained-row", reference: .init(v23Transcript: .init(nativeStoreID: marker.nativeStoreID,
            source: .microphone, rowID: 1, snapshotSHA256: String(repeating: "a", count: 64))),
            start: marker.anchoredAt, end: marker.anchoredAt.addingTimeInterval(1), text: "Sensitive retained source words")
        let request = CompanionJobRequest(sourceStoreID: marker.nativeStoreID, observedAt: marker.anchoredAt, context: .init(
            markerID: marker.id, markerRevision: marker.revision, snapshotID: UUID(), query: "Decision", verbatimExplanation: "",
            developing: true, incomplete: true, evidence: [support]))
        let data = try CompanionWire.encode(request)
        let canonical = try CompanionWire.decode(CompanionJobRequest.self, data: data, limit: 768 * 1024)
        let source = try XCTUnwrap(canonical.context), item = try XCTUnwrap(source.evidence.first)
        let result = CompanionResult(jobID: CompanionWire.digest(data), sourceStoreID: marker.nativeStoreID,
            contextProposal: .init(markerID: marker.id, markerRevision: marker.revision, snapshotID: source.snapshotID,
                verbatimExplanation: "", developing: true, incomplete: true,
                ranges: [.init(id: UUID(), start: item.start, end: item.end, explanation: item.text, supportIDs: [item.id], score: 0.9)], method: "authored"))
        return (canonical, result, data, try CompanionWire.encode(result))
    }
}
private actor ContextPresentationSource {
    var epoch = "a", allowed = true
    func validate(_ request: CompanionJobRequest) throws { if !allowed { throw CompanionError.staleEvidence } }
    func revoke() { allowed = false; epoch = "b" }
    func restore() { allowed = true; epoch = "c" }
}
private actor ContextPresentationGate {
    var epoch = "a"
    var entered = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    var releaseRead: CheckedContinuation<Void, Never>?
    func waitForRead() async { if entered { return }; await withCheckedContinuation { waiters.append($0) } }
    func hold() async { entered = true; waiters.forEach { $0.resume() }; waiters = []; await withCheckedContinuation { releaseRead = $0 } }
    func release() { epoch = "b"; releaseRead?.resume(); releaseRead = nil }
}
