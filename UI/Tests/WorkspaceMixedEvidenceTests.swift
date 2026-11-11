import Foundation
import Combine
import XCTest
import Shared
import Database
@testable import Retrace

/// Canonical private SQLite job receipts; no screenshots, process discovery,
/// native command launch, live preferences or installed application access.
@MainActor
final class WorkspaceMixedEvidenceTests: XCTestCase {
    private var database: DatabaseManager!
    private var writer: JobWriterSession!

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:mixed-workspace-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let transition = try await database.beginScreenEvidenceWriterSession(policy: .init(config: CaptureConfig()))
        try await database.activateScreenEvidencePolicy(transition)
        writer = try await database.openJobWriter(admission: .init(masterGeneration: UUID(), policy: transition))
    }
    override func tearDown() async throws {
        if let writer { try? await database.closeJobWriter(writer, reason: .serviceStopped) }
        if let database { try await database.close() }
    }

    func testExactJobWithoutAnyScreenPinsAndSurvivesHistoryRefresh() async throws {
        let receipt = try await finishedJob(status: 2)
        let model = makeModel()
        await model.selectEvidence(.job(receipt.reference))
        XCTAssertEqual(model.mode, .history)
        XCTAssertNil(model.selection, "A job must never manufacture a screenshot selection")
        XCTAssertEqual(model.presentedReference, .job(receipt.reference))
        XCTAssertEqual(model.selectedTimestamp, receipt.observation.observedAt)
        let admission = try XCTUnwrap(model.selectionAdmission)
        await model.refresh()
        XCTAssertEqual(model.presentedReference, .job(receipt.reference))
        XCTAssertTrue(model.admits(admission))
        guard case .job(let exact) = model.evidence.resolution else { return XCTFail("Exact job payload absent") }
        XCTAssertEqual(exact, receipt)
        model.close()
    }

    func testCrossSourceHistoryAndBookmarkKeepExactJobIdentity() async throws {
        let first = try await finishedJob(status: 1)
        let second = try await finishedJob(status: 0)
        let model = makeModel()
        await model.selectEvidence(.job(first.reference))
        await model.toggleBookmark()
        XCTAssertEqual(model.bookmarks.count, 1)
        let bookmark = try XCTUnwrap(model.bookmarks.first)
        XCTAssertEqual(bookmark.reference, .job(first.reference))
        await model.selectEvidence(.job(second.reference))
        await model.goBack()
        XCTAssertEqual(model.presentedReference, .job(first.reference))
        await model.goForward()
        XCTAssertEqual(model.presentedReference, .job(second.reference))
        await model.openBookmark(bookmark)
        XCTAssertEqual(model.presentedReference, .job(first.reference))
        await model.returnToNow()
        XCTAssertEqual(model.mode, .now)
        XCTAssertNil(model.presentedReference, "No screen exists to substitute for this job")
        model.close()
    }

    func testDeletedPinnedJobRevokesContentAdmissionWithoutSubstitution() async throws {
        let receipt = try await finishedJob(status: 0)
        let model = makeModel()
        await model.selectEvidence(.job(receipt.reference))
        let admitted = try XCTUnwrap(model.selectionAdmission)
        try await database.deleteJobRun(receipt.observation.runID, storeID: receipt.reference.storeID)
        await model.refresh()
        XCTAssertNil(model.presentedReference)
        XCTAssertFalse(model.admits(admitted))
        XCTAssertEqual(model.evidence.evidenceReference, .job(receipt.reference), "Retain only the original retry target")
        guard case .unavailable = model.evidence.resolution else { return XCTFail("Deleted job remained visible") }
        XCTAssertNil(model.selectedTimestamp)
        model.close()
    }

    func testWrongStoreReferenceCannotAliasSameNativeJob() async throws {
        let receipt = try await finishedJob(status: 0)
        let wrong = JobEvidenceRef(storeID: UUID(), producerID: receipt.reference.producerID,
            eventID: receipt.reference.eventID, revision: receipt.reference.revision)
        let model = makeModel()
        await model.selectEvidence(.job(wrong))
        XCTAssertNil(model.presentedReference)
        XCTAssertNil(model.selectionAdmission)
        guard case .unavailable = model.evidence.resolution else { return XCTFail("Wrong-store job resolved") }
        model.close()
    }

    func testRefreshDuringHeldInitialSelectionCannotRepublishDeletedJob() async throws {
        let receipt = try await finishedJob(status: 0)
        let entered = expectation(description: "Canonical initial job snapshot read")
        let gate = MixedEvidenceReadGate(entered: entered)
        let reader = makeClient().resolve
        var client = makeClient()
        client.resolve = { reference in
            let result = await reader(reference)
            await gate.holdFirst()
            return result
        }
        let evidence = EvidenceViewModel(client: client)
        let selecting = Task { await evidence.openEvidence(.job(receipt.reference)) }
        await fulfillment(of: [entered], timeout: 3)
        try await database.deleteJobRun(receipt.observation.runID, storeID: receipt.reference.storeID)
        let refreshing = expectation(description: "Refresh owns publication")
        let observation = evidence.$resolvingEvidence.dropFirst().first(where: { $0 }).sink { _ in refreshing.fulfill() }
        let refresh = Task { await evidence.refreshCurrentRevision() }
        await fulfillment(of: [refreshing], timeout: 3)
        var publishedDeleted = false
        let payloadObservation = evidence.$resolution.sink { result in
            if case .job = result { publishedDeleted = true }
        }
        await gate.release()
        await selecting.value; await refresh.value
        XCTAssertFalse(publishedDeleted, "An old read must not flash deleted content before the fresh denial")
        guard case .unavailable(.evidenceDeleted) = evidence.resolution else {
            return XCTFail("Fresh canonical deletion must own the final result")
        }
        XCTAssertFalse(evidence.resolvingEvidence)
        XCTAssertEqual(evidence.evidenceReference, .job(receipt.reference))
        withExtendedLifetime((observation, payloadObservation)) { }
        evidence.closeEvidence()
    }

    func testJoinedRefreshCannotPublishAfterCloseOrDifferentSelection() async throws {
        for replace in [false, true] {
            let first = try await finishedJob(status: 1)
            let second = try await finishedJob(status: 0)
            let entered = expectation(description: "Canonical refresh held")
            let gate = MixedEvidenceReadGate(entered: entered, heldRead: 2)
            let reader = makeClient().resolve
            var client = makeClient()
            client.resolve = { reference in
                let result = await reader(reference)
                await gate.holdFirst()
                return result
            }
            let evidence = EvidenceViewModel(client: client)
            await evidence.openEvidence(.job(first.reference))
            let refresh = Task { await evidence.refreshCurrentRevision() }
            await fulfillment(of: [entered], timeout: 3)
            if replace { await evidence.openEvidence(.job(second.reference)) }
            else { evidence.closeEvidence() }
            await gate.release(); await refresh.value
            if replace {
                guard case .job(let result) = evidence.resolution else { return XCTFail("New selection was lost") }
                XCTAssertEqual(result.reference, second.reference)
            } else {
                XCTAssertNil(evidence.resolution)
                XCTAssertNil(evidence.evidenceReference)
                XCTAssertFalse(evidence.isPresentingEvidence)
            }
            evidence.closeEvidence()
        }
    }

    private func finishedJob(status: Int32) async throws -> JobEventSnapshot {
        let start = JobObservation(runID: UUID(), kind: .build, phase: .started)
        _ = try await database.appendJobStart(start, session: writer)
        return try await database.appendJobEnd(.init(runID: start.runID, kind: .build, phase: .terminal,
            outcome: status == 0 ? .succeeded : .failed, terminationStatus: status), session: writer)
    }

    private func makeClient() -> EvidenceClient {
        let db = database!
        return EvidenceClient(reference: { _ in throw EvidenceUnavailableReason.unsupported },
            frameReference: { _, _ in throw EvidenceUnavailableReason.unsupported }, resolve: { reference in
                guard case .job(let job) = reference else { return .unavailable(.unsupported) }
                do {
                    switch try await db.resolveJobEvidence(job) {
                    case .available(let snapshot, let stamp):
                        guard try await db.validateJobRead(stamp) else { return .unavailable(.integrityFailure) }
                        return .job(snapshot)
                    case .unavailable(let reason):
                        return .unavailable(reason == .deleted ? .evidenceDeleted : .notPermitted)
                    }
                } catch { return .unavailable(.integrityFailure) }
            }, currentRevision: { _ in nil }, track: { _, _, _ in })
    }

    private func makeModel() -> UnifiedWorkspaceModel {
        return UnifiedWorkspaceModel(evidence: EvidenceViewModel(client: makeClient()), latest: { [] },
            search: { _ in [] }, track: { _ in }, seek: { _ in
                XCTFail("Exact job selection must never seek a nearby frame")
                return []
            })
    }
}

private actor MixedEvidenceReadGate {
    private let entered: XCTestExpectation
    private let heldRead: Int
    private var count = 0
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation, heldRead: Int = 1) {
        self.entered = entered; self.heldRead = heldRead
    }
    func holdFirst() async {
        count += 1
        guard count == heldRead, !opened else { return }
        await withCheckedContinuation { continuation = $0; entered.fulfill() }
    }
    func release() { opened = true; continuation?.resume(); continuation = nil }
}
