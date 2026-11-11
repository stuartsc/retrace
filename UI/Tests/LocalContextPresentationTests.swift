import Foundation
import App
import Database
import Storage
import Shared
import XCTest
@testable import Retrace

/// Real private SQLite and the production context service; no native model loads.
@MainActor
final class LocalContextPresentationTests: XCTestCase {
    private var database: DatabaseManager!
    private var adapter: DataAdapter!
    private var service: LocalContextService!
    private var presentation: LocalContextPresentationModel!

    override func setUp() async throws {
        database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        adapter = DataAdapter(retraceConnection: SQLiteConnection(db: try XCTUnwrap(connection)),
            retraceConfig: .init(dateFormatter: nil, storageRoot: "/tmp", source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: "/tmp"), database: database)
        try await adapter.initialize()
        let evidence = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() },
            imageReader: { _ in XCTFail("Context must not decode images"); throw EvidenceUnavailableReason.unsupported })
        let policy = try await database.beginScreenEvidenceWriterSession(policy: .init(config: CaptureConfig()))
        try await database.activateScreenEvidencePolicy(policy)
        service = LocalContextService(database: database, evidence: evidence,
            externalRevalidator: { _ in true }, recordMetric: { _ in })
        let owner = service!
        presentation = LocalContextPresentationModel(load: { try await owner.refresh($0) })
    }

    override func tearDown() async throws {
        presentation?.clear()
        if let service { await service.stop() }
        if let adapter { await adapter.shutdown() }
        if let database { try await database.close() }
    }

    func testDeletedCanonicalScreenClearsPreviouslyPresentedCardsOnRefresh() async throws {
        let ref = try await insert("Cedar approval NOT GRANTED")
        let request = LocalContextRequest(screenReferences: [ref])
        await presentation.refresh(request)
        XCTAssertTrue(presentation.snapshot?.items.contains { $0.excerpt == "Cedar approval NOT GRANTED" } == true)
        try await database.deleteFrame(id: ref.frameID)
        await presentation.refresh(request)
        XCTAssertNil(presentation.snapshot)
        XCTAssertFalse(presentation.isRefreshing)
        XCTAssertEqual(presentation.status, "Context unavailable for this selection")
    }

    func testNativeTimerExpiresCanonicalSnapshotWithoutAnotherRefresh() async throws {
        let ref = try await insert("A short-lived authored context")
        let now = Date()
        // A real admitted provider lease bounds the complete service result.
        let external = LocalContextExternalSnapshot(providerID: "authored", revision: "r1", generatedAt: now,
            expiresAt: now.addingTimeInterval(2), items: [])
        await presentation.refresh(.init(screenReferences: [ref], externalSnapshot: external))
        XCTAssertNotNil(presentation.snapshot)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while presentation.snapshot != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(presentation.snapshot)
        XCTAssertEqual(presentation.status, "Context expired")
    }

    func testDelayedPublicationAndWallRollbackCannotExtendOriginalMonotonicLease() async throws {
        let ref = try await insert("Original monotonic deadline survives publication")
        let now = Date(), owner = service!
        let external = LocalContextExternalSnapshot(providerID: "authored", revision: "rollback-r1", generatedAt: now,
            expiresAt: now.addingTimeInterval(3), items: [])
        let model = LocalContextPresentationModel(load: { request in
            let value = try await owner.refresh(request)
            // Real async hop after canonical admission; a clock correction at
            // presentation must not renew its original process-local lease.
            try await Task.sleep(for: .milliseconds(200))
            return value
        }, clock: { .init(wall: Date().addingTimeInterval(-2), uptime: ProcessInfo.processInfo.systemUptime) })
        await model.refresh(.init(screenReferences: [ref], externalSnapshot: external))
        let value = try XCTUnwrap(model.snapshot)
        let wait = max(0, value.expiresAtUptime - ProcessInfo.processInfo.systemUptime) + 0.1
        try await Task.sleep(for: .seconds(wait))
        XCTAssertNil(model.snapshot, "Wall-clock rollback must not add two seconds to the lease")
        model.clear()
    }

    func testFreshnessTriggerReturnsAndCoalescesWhileContextReadIsHeld() async throws {
        let ref = try await insert("Slow context must not block the workspace poll")
        let entered = expectation(description: "Canonical context held after read")
        let gate = ContextPresentationGate(entered: entered)
        let owner = service!, count = ContextPresentationCalls()
        let model = LocalContextPresentationModel(load: { request in
            await count.increment()
            let value = try await owner.refresh(request)
            await gate.wait()
            return value
        })
        let request = LocalContextRequest(screenReferences: [ref])
        model.requestRefresh(request)
        await fulfillment(of: [entered], timeout: 10)
        model.clearPresentation()
        model.requestRefresh(request)
        // This code must execute while the canonical result is still held.
        XCTAssertTrue(model.isRefreshing)
        let calls = await count.value
        XCTAssertEqual(calls, 1)
        await gate.release()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.isRefreshing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(model.snapshot)
        model.clear()
    }

    func testClearFencesHeldCanonicalReadAndAllowsTheNextSelection() async throws {
        let first = try await insert("First authored selection")
        let second = try await insert("Second authored selection")
        let entered = expectation(description: "Real canonical read finished before presentation")
        let gate = ContextPresentationGate(entered: entered)
        let owner = service!
        let model = LocalContextPresentationModel(load: { request in
            let value = try await owner.refresh(request)
            if request.screenReferences == [first] { await gate.wait() }
            return value
        })
        let pending = Task { await model.refresh(.init(screenReferences: [first])) }
        await fulfillment(of: [entered], timeout: 10)
        model.clear()
        XCTAssertNil(model.snapshot)
        let next = Task { await model.refresh(.init(screenReferences: [second])) }
        await gate.release()
        await pending.value; await next.value
        XCTAssertTrue(model.snapshot?.items.contains { $0.excerpt == "Second authored selection" } == true)
        XCTAssertFalse(model.snapshot?.items.contains { $0.excerpt == "First authored selection" } == true)
        model.clear()
    }

    private func insert(_ text: String) async throws -> ScreenEvidenceRef {
        let at = Date()
        let segment = try await database.insertSegment(bundleID: "com.authored.context-ui", startDate: at,
            endDate: at, windowName: "Authored", browserUrl: nil, type: 0)
        let frame = try await database.insertFrame(.init(id: .init(value: 0), timestamp: at,
            segmentID: .init(value: segment), frameIndexInSegment: 0,
            metadata: .init(appBundleID: "com.authored.context-ui", windowName: "Authored")))
        let frameID = FrameID(value: frame)
        _ = try await database.commitFrameOCR(frameID: frameID,
            text: .init(frameID: frameID, timestamp: at, regions: [], fullText: text,
                metadata: .init(appBundleID: "com.authored.context-ui")), frameWidth: 640, frameHeight: 360)
        let store = try await database.activityStoreID()
        let snapshot = try await database.currentScreenEvidence(frameID: frameID, storeID: store)
        return try XCTUnwrap(snapshot).ref
    }
}

private actor ContextPresentationGate {
    let entered: XCTestExpectation
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation) { self.entered = entered }
    func wait() async { entered.fulfill(); if !released { await withCheckedContinuation { waiter = $0 } } }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private actor ContextPresentationCalls {
    private(set) var value = 0
    func increment() { value += 1 }
}
