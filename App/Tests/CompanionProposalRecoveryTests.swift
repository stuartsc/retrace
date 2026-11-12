import Database
import Foundation
import Shared
import XCTest
@testable import App

final class CompanionProposalRecoveryTests: XCTestCase {
    func testCompetingResultsInvalidateNeverCommittedLoserAndRecoverFreshRequestAcrossCrashWindows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), transport = ProposalRecoveryTransport(), admission = ProposalRecoveryAdmission()
        let database = ContextDatabase(databasePath: root.appendingPathComponent("context.db").path, nativeStoreID: native)
        let markers = TimelineMarkerService(factory: { database })
        let marker = try await markers.createManualMarker(.init(anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let importer = CompanionContextImporter(markers: markers)
        let makeService = {
            CompanionEnrichmentService(root: root.appendingPathComponent("delivery"), nativeStoreID: native,
                transport: transport, revalidate: { _ in try await admission.check() },
                importResult: { request, result, requestData, resultData in
                    try await CompanionController.importContext(request: request, result: result, requestData: requestData,
                        resultData: resultData, importer: importer, markers: markers)
                })
        }
        let first = makeService()
        let requestA = request(marker, text: "First snapshot", expectedHead: nil, priority: 1)
        let requestB = request(marker, text: "Fresh source snapshot", expectedHead: nil, priority: 2)
        let idA = try await first.publish(requestA), idB = try await first.publish(requestB)
        try await transport.complete(requestA, id: idA)
        _ = try await first.synchronize(limit: 8)
        let storedHeadA = try await markers.contextProposalHead(markerID: marker.id)
        let headA = try XCTUnwrap(storedHeadA)
        XCTAssertEqual(headA.jobID, idA)
        try await transport.complete(requestB, id: idB)
        _ = try await first.synchronize(limit: 8)
        let losing = try await first.status().first { $0.jobID == idB }
        XCTAssertEqual(losing?.state, .invalidated)
        let retainedLoser = try await markers.contextProposal(jobID: idB)
        XCTAssertNil(retainedLoser, "A stale head must never import B under a different parent")
        let staleCandidate = CompanionContextCandidate(jobID: idB, request: requestB, state: .received)
        let recollectedAtA = request(marker, text: "Fresh source snapshot", expectedHead: headA.revision, priority: 2.5)
        XCTAssertFalse(CompanionController.suppressesContextRefresh(staleCandidate, request: recollectedAtA, currentHead: headA),
                       "An unprocessed stale queued duplicate must not block fresh publication")
        let readCatalog = CompanionDeliveryDatabase(databasePath: root.appendingPathComponent("delivery/delivery.db").path, nativeStoreID: native, readOnly: true)
        try await readCatalog.initialize()
        let originalBytes = try await readCatalog.record(jobID: idB)?.requestPayload
        try await first.close()

        let reopened = makeService()
        let pending = try await reopened.pendingContextRefreshes()
        XCTAssertEqual(pending.map(\.markerID), [marker.id])
        XCTAssertEqual(pending.map(\.jobID), [idB])
        // A current source collection creates new immutable input; the old request is untouched.
        let fresh = request(marker, text: "Fresh source snapshot", expectedHead: headA.revision, priority: 3)
        let candidates = try await reopened.contextCandidates()
        XCTAssertFalse(candidates.contains { CompanionController.suppressesContextRefresh($0, request: fresh, currentHead: headA) })
        await admission.reject()
        do { _ = try await reopened.publish(fresh); XCTFail("Admission errors preserve the durable refresh") }
        catch is CompanionAdmissionUnavailable {}
        let retainedRefresh = try await reopened.pendingContextRefreshes()
        XCTAssertEqual(retainedRefresh.count, 1)
        await admission.restore()
        let freshID = try await reopened.publish(fresh)
        XCTAssertNotEqual(freshID, idB)
        try await reopened.close() // Crash window: new publication exists, completion receipt does not.

        let resumed = makeService()
        let pendingAgain = try await resumed.pendingContextRefreshes()
        XCTAssertEqual(pendingAgain.map(\.jobID), [idB])
        let collectedAgain = request(marker, text: "Fresh source snapshot", expectedHead: headA.revision, priority: 4)
        let afterCrash = try await resumed.contextCandidates(currentHeadJobID: headA.jobID)
        XCTAssertTrue(afterCrash.contains { CompanionController.suppressesContextRefresh($0, request: collectedAgain, currentHead: headA) })
        try await resumed.completeContextRefresh(jobID: idB)
        let completedRefreshes = try await resumed.pendingContextRefreshes()
        XCTAssertTrue(completedRefreshes.isEmpty)
        try await transport.complete(fresh, id: freshID)
        _ = try await resumed.synchronize(limit: 8)
        let storedHeadC = try await markers.contextProposalHead(markerID: marker.id)
        let headC = try XCTUnwrap(storedHeadC)
        XCTAssertEqual(headC.jobID, freshID)
        let sameInput = request(marker, text: "Fresh source snapshot", expectedHead: headC.revision, priority: 5)
        let accepted = try await resumed.contextCandidates(currentHeadJobID: headC.jobID)
        XCTAssertTrue(accepted.contains { CompanionController.suppressesContextRefresh($0, request: sameInput, currentHead: headC) }, "Import must not create a rerank feedback loop")
        let returningInput = request(marker, text: "First snapshot", expectedHead: headC.revision, priority: 6)
        XCTAssertFalse(accepted.contains { CompanionController.suppressesContextRefresh($0, request: returningInput, currentHead: headC) }, "A historical accepted input cannot block a new transition back to it")
        let unchanged = try await readCatalog.record(jobID: idB)?.requestPayload
        try await readCatalog.close()
        XCTAssertEqual(unchanged, originalBytes)
        let acknowledgements = await transport.acknowledged
        XCTAssertEqual(Set(acknowledgements), [idA, freshID])
        try await resumed.close(); try await markers.close()
    }

    func testUncompletedFreshRefreshesDoNotStarveOlderMarkers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), transport = ProposalRecoveryTransport()
        let markers = TimelineMarkerService(factory: { ContextDatabase(databasePath: ":memory:", nativeStoreID: native) })
        let service = CompanionEnrichmentService(root: root, nativeStoreID: native, transport: transport,
            revalidate: { _ in }, importResult: { request, _, _, _ in
                guard let markerID = request.context?.markerID else { throw CompanionError.invalidPayload }
                throw CompanionProposalSuperseded.marker(markerID)
            })
        var jobIDs = Set<String>()
        for index in 0..<10 {
            let marker = try await markers.createManualMarker(.init(anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)))
            let request = request(marker, text: "Authored pending source", expectedHead: nil, priority: Double(index))
            let id = try await service.publish(request); jobIDs.insert(id)
            try await transport.complete(request, id: id)
        }
        _ = try await service.synchronize(limit: 32)
        let first = try await service.pendingContextRefreshes(limit: 8)
        let second = try await service.pendingContextRefreshes(limit: 8)
        XCTAssertEqual(first.count, 8); XCTAssertEqual(second.count, 8)
        XCTAssertEqual(Set((first + second).map(\.jobID)), jobIDs,
                       "Failed first-pass entries remain pending but must not starve older marker refreshes")
        try await service.close(); try await markers.close()
    }

    func testPendingNewestJobsDoNotStarveOlderReadyDelivery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), transport = ProposalRecoveryTransport()
        let markers = TimelineMarkerService(factory: { ContextDatabase(databasePath: ":memory:", nativeStoreID: native) })
        let service = CompanionEnrichmentService(root: root, nativeStoreID: native, transport: transport,
            revalidate: { _ in }, importResult: { _, _, _, _ in })
        var oldest = ""
        for index in 0..<10 {
            let marker = try await markers.createManualMarker(.init(anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)))
            let value = request(marker, text: "Authored source", expectedHead: nil, priority: Double(index))
            let id = try await service.publish(value)
            if index == 0 { oldest = id; try await transport.complete(value, id: id) }
        }
        _ = try await service.synchronize(limit: 8)
        let before = await transport.acknowledged; XCTAssertFalse(before.contains(oldest))
        _ = try await service.synchronize(limit: 8)
        let after = await transport.acknowledged; XCTAssertTrue(after.contains(oldest))
        try await service.close(); try await markers.close()
    }

    private func request(_ marker: TimelineMarker, text: String, expectedHead: UUID?, priority: Double) -> CompanionJobRequest {
        let support = CompanionEvidenceItem(id: "source:" + text, reference: .init(v23Transcript: .init(nativeStoreID: marker.nativeStoreID,
            source: .microphone, rowID: 1, snapshotSHA256: CompanionWire.digest(Data(text.utf8)))),
            start: marker.anchoredAt, end: marker.anchoredAt.addingTimeInterval(1), text: text)
        return .init(sourceStoreID: marker.nativeStoreID, observedAt: marker.anchoredAt.addingTimeInterval(priority), context: .init(
            markerID: marker.id, markerRevision: marker.revision, snapshotID: UUID(), query: "Decision", verbatimExplanation: "",
            developing: true, incomplete: true, evidence: [support], expectedProposalHead: expectedHead))
    }
}

private actor ProposalRecoveryAdmission {
    var allowed = true
    func check() throws { if !allowed { throw CompanionAdmissionUnavailable.revoked } }
    func reject() { allowed = false }
    func restore() { allowed = true }
}
private actor ProposalRecoveryTransport: CompanionTransport {
    private var results: [String: Data] = [:]
    private(set) var acknowledged: [String] = []
    func complete(_ request: CompanionJobRequest, id: String) throws {
        guard let context = request.context, let support = context.evidence.first else { return }
        let result = CompanionResult(jobID: id, sourceStoreID: request.sourceStoreID, contextProposal: .init(
            markerID: context.markerID, markerRevision: context.markerRevision, snapshotID: context.snapshotID,
            verbatimExplanation: context.verbatimExplanation, developing: context.developing, incomplete: context.incomplete,
            ranges: [.init(id: UUID(), start: support.start, end: support.end, explanation: support.text, supportIDs: [support.id], score: 1)], method: "authored"))
        results[id] = try CompanionWire.encode(result)
    }
    func publishObject(sha256: String, data: Data) async throws {}
    func publishJob(id: String, data: Data) async throws {}
    func result(id: String) async throws -> Data? { results[id] }
    func acknowledge(id: String, resultSHA256: String) async throws { acknowledged.append(id) }
    func close() async {}
}
