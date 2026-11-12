import Darwin
import Foundation
import XCTest
import Shared
import Database
import Storage
@testable import App

final class CompanionLifecycleTests: XCTestCase {
    func testOfflineCatalogDuringInitialDirectoryPublicationIsEmptyWithoutCreatingFiles() async throws {
        let fixture = try await CompanionLifecycleFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let delivery = fixture.root.appendingPathComponent("companion/delivery")
        try FileManager.default.createDirectory(at: delivery, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let first = try await fixture.owner.speakerPresentations(from: Date(timeIntervalSince1970: 1), to: Date())
        XCTAssertTrue(first.items.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: delivery.path), [])
        for name in ["requests", "results", "receipts"] {
            try FileManager.default.createDirectory(at: delivery.appendingPathComponent(name), withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        let withoutBinding = try await fixture.owner.speakerPresentations(from: Date(timeIntervalSince1970: 1), to: Date())
        XCTAssertTrue(withoutBinding.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: delivery.appendingPathComponent("native-store").path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: delivery.appendingPathComponent("requests").path)
        do {
            _ = try await fixture.owner.speakerPresentations(from: Date(timeIntervalSince1970: 1), to: Date())
            XCTFail("Existing unsafe directories must not look like unpublished storage")
        } catch { XCTAssertEqual(error as? CompanionError, .unsafeStorage) }
        try await fixture.finish()
    }

    func testConcurrentOfflineReadAtEachFirstPublicationBoundaryNeverSeesUnsafeOwnership() async throws {
        for component in ["delivery", "requests", "native-store"] {
            let fixture = try await CompanionLifecycleFixture.make()
            let delivery = fixture.root.appendingPathComponent("companion/delivery")
            let native = try await fixture.adapter.evidenceStoreID(source: .native)
            let published = expectation(description: "Writer published \(component) atomically")
            let release = DispatchSemaphore(value: 0)
            let spool = CompanionSpool(root: delivery, nativeStoreID: native, publicationObserver: { url in
                if url.lastPathComponent == component {
                    published.fulfill()
                    XCTAssertEqual(release.wait(timeout: .now() + 3), .success, "Reader must finish before publication resumes")
                }
            })
            let writer = Task.detached { try spool.initialize() }
            await fulfillment(of: [published], timeout: 3)
            do {
                let path = component == "delivery" ? delivery : delivery.appendingPathComponent(component)
                var info = stat()
                XCTAssertEqual(lstat(path.path, &info), 0)
                XCTAssertEqual(info.st_mode & 0o077, 0, "Published objects are private from their first visible instant")
                if component == "native-store" {
                    XCTAssertEqual(info.st_nlink, 1, "Readers never need to accept a temporary second hardlink")
                    XCTAssertEqual(try spool.read(path, limit: 64), Data(native.uuidString.utf8))
                }
                let page = try await fixture.owner.speakerPresentations(from: Date(timeIntervalSince1970: 1), to: Date())
                XCTAssertTrue(page.items.isEmpty)
                release.signal()
                try await writer.value
                try await fixture.finish()
                try FileManager.default.removeItem(at: fixture.root)
            } catch {
                release.signal()
                _ = try? await writer.value
                try? await fixture.finish()
                try? FileManager.default.removeItem(at: fixture.root)
                throw error
            }
        }
    }

    func testUnconfiguredSpeakerHistoryDoesNotCreateDeliveryOrActivateTransport() async throws {
        let fixture = try await CompanionLifecycleFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let page = try await fixture.owner.speakerPresentations(from: Date(timeIntervalSince1970: 1), to: Date())
        XCTAssertTrue(page.items.isEmpty)
        let status = await fixture.owner.status()
        XCTAssertEqual(status.state, .unconfigured)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("companion/delivery").path))
        try await fixture.finish()
    }

    func testConcurrentControllerCloseWaitsForRetiringWorker() async throws {
        let policy = CompanionLifecyclePolicy()
        let fixture = try await CompanionLifecycleFixture.make(policy: { await policy.check() })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.markers.createManualMarker(.init(anchoredAt: Date(), title: "Authored decision"))
        try await fixture.owner.configure(.init(endpoint: URL(string: "http://127.0.0.1:1/retrace-companion")!,
                                                bearerToken: String(repeating: "a", count: 32)))
        await policy.held.waitForEntry()
        let completed = CompanionLifecycleCounter()
        let first = Task { try await fixture.owner.close(); await completed.increment() }
        for _ in 0..<20 { await Task.yield() }
        let secondEntered = CompanionLifecycleLatch()
        let second = Task {
            await secondEntered.enter()
            try await fixture.owner.close()
            await completed.increment()
        }
        await secondEntered.waitForEntry()
        try await Task.sleep(for: .milliseconds(30))
        let beforeRelease = await completed.value
        XCTAssertEqual(beforeRelease, 0, "Every close caller must join the retiring loop")
        await policy.held.release()
        try await first.value; try await second.value
        let afterRelease = await completed.value
        XCTAssertEqual(afterRelease, 2)
        try await fixture.finish()
    }

    func testSupersededReservationCannotReactivateAndCancelledConfigureCannotRevokeNewerReservation() async throws {
        let fixture = try await CompanionLifecycleFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let old = fixture.owner.reserveConfiguration()
        let current = fixture.owner.reserveConfiguration()
        do { try await fixture.owner.configure(nil, reservation: old); XCTFail("Superseded settings must fail") }
        catch { XCTAssertEqual(error as? CompanionError, .staleEvidence) }
        let latch = CompanionLifecycleLatch()
        let cancelled = Task {
            await latch.hold()
            try await fixture.owner.configure(.init(endpoint: URL(string: "http://127.0.0.1:1")!,
                                                    bearerToken: String(repeating: "b", count: 32)))
        }
        await latch.waitForEntry(); cancelled.cancel(); await latch.release()
        do { try await cancelled.value; XCTFail("Cancelled configuration must not begin") }
        catch is CancellationError {}
        try await fixture.owner.configure(nil, reservation: current)
        let state = await fixture.owner.status()
        XCTAssertEqual(state.state, .unconfigured)
        try await fixture.finish()
    }

    func testCloseJoinsOperationMetricBeforeReturning() async throws {
        try await assertCloseJoinsOperationMetric(configured: true)
    }

    func testOfflineCloseJoinsOperationMetricWithoutInitializingDelivery() async throws {
        try await assertCloseJoinsOperationMetric(configured: false)
    }

    private func assertCloseJoinsOperationMetric(configured: Bool) async throws {
        let metric = CompanionLifecycleLatch()
        let metricEntered = expectation(description: "Speaker read reaches its joined outcome metric")
        let fixture = try await CompanionLifecycleFixture.make(metric: { action, _ in
            if action == "operation" { metricEntered.fulfill(); await metric.hold() }
        })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        if configured {
            // This test owns metric-drain ordering, not first-publication
            // timing. Publish an empty real catalog before starting concurrent
            // writer/reader owners; startup races have separate regressions.
            let native = try await fixture.adapter.evidenceStoreID(source: .native)
            let preparation = CompanionEnrichmentService(root: fixture.root.appendingPathComponent("companion/delivery"),
                nativeStoreID: native, transport: CompanionLifecycleTransport(), revalidate: { _ in },
                importResult: { _, _, _, _ in })
            _ = try await preparation.status()
            try await preparation.close()
            try await fixture.owner.configure(.init(endpoint: URL(string: "http://127.0.0.1:1/retrace-companion")!,
                                                    bearerToken: String(repeating: "a", count: 32)))
        }
        let read = Task { try await fixture.owner.speakerPresentations(from: Date(timeIntervalSince1970: 1), to: Date()) }
        await fulfillment(of: [metricEntered], timeout: 3)
        let completed = CompanionLifecycleCounter()
        let close = Task { try await fixture.owner.close(); await completed.increment() }
        try await Task.sleep(for: .milliseconds(30))
        let beforeRelease = await completed.value
        XCTAssertEqual(beforeRelease, 0, "Close must join the metric callback before its database owner can close")
        await metric.release()
        do { _ = try await read.value; XCTFail("Shutdown must cancel the in-flight read") }
        catch is CancellationError {}
        try await close.value
        if !configured {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("companion/delivery").path))
        }
        try await fixture.finish()
    }

    func testMutationBetweenRevalidationAndTransportResumeBlocksUploadWithoutLosingRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = CompanionEvidenceAdmission(), transport = CompanionLifecycleTransport(holdFirst: true)
        let native = UUID(), request = Self.request(store: native, time: Date())
        let service = CompanionEnrichmentService(root: root, nativeStoreID: native, transport: transport,
            revalidate: { _ in }, importResult: { _, _, _, _ in }, transmissionAdmission: { admission.permit() })
        let id = try await service.publish(request)
        let synchronize = Task { try await service.synchronize() }
        await transport.held.waitForEntry()
        admission.invalidate()
        await transport.held.release()
        do { _ = try await synchronize.value; XCTFail("Old source admission must not resume") }
        catch is CompanionTransmissionRevoked {}
        let blockedUploads = await transport.published
        XCTAssertTrue(blockedUploads.isEmpty)
        let queued = try await service.status()
        XCTAssertEqual(queued.first?.state, .queued)
        _ = try await service.synchronize()
        let retried = await transport.published
        XCTAssertEqual(retried, [id])
        try await service.close()
    }

    func testSourceMutationDuringMetricTailInvalidatesSpeakerRead() async throws {
        let metric = CompanionLifecycleLatch()
        let metricEntered = expectation(description: "Speaker read reaches its joined outcome metric")
        let fixture = try await CompanionLifecycleFixture.make(metric: { action, _ in
            if action == "operation" { metricEntered.fulfill(); await metric.hold() }
        })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.owner.configure(.init(endpoint: URL(string: "http://127.0.0.1:1/retrace-companion")!,
                                                bearerToken: String(repeating: "a", count: 32)))
        let read = Task { try await fixture.owner.speakerPresentations(from: Date(timeIntervalSince1970: 1), to: Date()) }
        await fulfillment(of: [metricEntered], timeout: 3)
        fixture.owner.sourceChanged(.indexOnly)
        await metric.release()
        do { _ = try await read.value; XCTFail("Even an index-only change must invalidate the whole read, including its metric tail") }
        catch is CompanionTransmissionRevoked {}
        try await fixture.finish()
    }

    func testDeletedSourceIsTerminalAndDoesNotBlockUnrelatedQueuedJob() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), now = Date(), state = CompanionLifecycleValidation()
        let fresh = Self.request(store: native, time: now), older = Self.request(store: native, time: now.addingTimeInterval(-1))
        let transport = CompanionLifecycleTransport()
        let service = CompanionEnrichmentService(root: root, nativeStoreID: native, transport: transport,
            revalidate: { request in try await state.validate(request) }, importResult: { _, _, _, _ in })
        let freshID = try await service.publish(fresh), olderID = try await service.publish(older)
        await state.reject(fresh.context!.markerID, terminal: true)
        _ = try await service.synchronize(limit: 2)
        let states = try await service.status()
        XCTAssertEqual(states.first(where: { $0.jobID == freshID })?.state, .invalidated)
        XCTAssertEqual(states.first(where: { $0.jobID == olderID })?.state, .published)
        let published = await transport.published
        XCTAssertEqual(published, [olderID])
        try await service.close()
    }

    func testTemporaryAdmissionFailurePreservesRequestAndAllowsOtherJobProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), now = Date(), state = CompanionLifecycleValidation()
        let fresh = Self.request(store: native, time: now), older = Self.request(store: native, time: now.addingTimeInterval(-1))
        let transport = CompanionLifecycleTransport()
        let service = CompanionEnrichmentService(root: root, nativeStoreID: native, transport: transport,
            revalidate: { request in try await state.validate(request) }, importResult: { _, _, _, _ in })
        let freshID = try await service.publish(fresh), olderID = try await service.publish(older)
        await state.reject(fresh.context!.markerID, terminal: false)
        do { _ = try await service.synchronize(limit: 2); XCTFail("Admission failure remains visible") }
        catch is CompanionAdmissionUnavailable {}
        let states = try await service.status()
        XCTAssertEqual(states.first(where: { $0.jobID == freshID })?.state, .queued)
        XCTAssertEqual(states.first(where: { $0.jobID == olderID })?.state, .published)
        try await service.close()
    }

    func testMountedPrivateTransportIsAcceptedWithoutStartingARequest() async throws {
        for path in ["", "/retrace-companion", "/retrace-companion/"] {
            let transport = try CompanionHTTPTransport(baseURL: URL(string: "http://127.0.0.1:1" + path)!,
                bearerToken: String(repeating: "c", count: 32))
            await transport.close()
        }
        XCTAssertThrowsError(try CompanionHTTPTransport(baseURL: URL(string: "http://127.0.0.1:1/unrelated")!,
            bearerToken: String(repeating: "c", count: 32)))
    }

    private static func request(store: UUID, time: Date) -> CompanionJobRequest {
        .init(sourceStoreID: store, observedAt: time, context: .init(markerID: UUID(), markerRevision: UUID(),
            snapshotID: UUID(), query: "Authored decision", verbatimExplanation: "", developing: true,
            incomplete: true, evidence: []))
    }
}

private struct CompanionLifecycleFixture: Sendable {
    let root: URL
    let database: DatabaseManager
    let adapter: DataAdapter
    let markers: TimelineMarkerService
    let owner: CompanionController
    static func make(policy: @escaping @Sendable () async throws -> Void = {},
                     metric: @escaping CompanionController.Metric = { _, _ in }) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("recording.db").path
        let database = DatabaseManager(databasePath: path); try await database.initialize()
        let adapter = DataAdapter(retraceConnection: try await database.makeRecallReadConnection(),
            retraceConfig: .init(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
        try await adapter.initialize()
        let native = try await adapter.evidenceStoreID(source: .native)
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { native })
        let recall = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() },
            imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
        let owner = CompanionController(storageRoot: root.appendingPathComponent("companion"), nativeStoreID: native,
            databasePath: path, adapter: adapter, recall: recall, markers: markers,
            verifiedBytes: { _ in throw CompanionError.unavailable }, policy: policy, metric: metric)
        return .init(root: root, database: database, adapter: adapter, markers: markers, owner: owner)
    }
    func finish() async throws {
        try await owner.close(); try await markers.close(); await adapter.shutdown(); try await database.close()
    }
}
private actor CompanionLifecycleCounter {
    var value = 0
    func increment() { value += 1 }
}
private actor CompanionLifecycleLatch {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var held: CheckedContinuation<Void, Never>?
    func enter() { entered = true; let waiters = entryWaiters; entryWaiters = []; waiters.forEach { $0.resume() } }
    func hold() async { enter(); if !released { await withCheckedContinuation { held = $0 } } }
    func waitForEntry() async { if !entered { await withCheckedContinuation { entryWaiters.append($0) } } }
    func release() { released = true; held?.resume(); held = nil }
}
private actor CompanionLifecyclePolicy {
    let held = CompanionLifecycleLatch()
    private var calls = 0
    func check() async { calls += 1; if calls == 2 { await held.hold() } }
}
private actor CompanionLifecycleValidation {
    private var rejected: UUID?
    private var terminal = false
    func reject(_ id: UUID, terminal: Bool) { rejected = id; self.terminal = terminal }
    func validate(_ request: CompanionJobRequest) throws {
        guard request.context?.markerID == rejected else { return }
        if terminal { throw CompanionSourceInvalidated.unavailable }
        throw CompanionAdmissionUnavailable.revoked
    }
}
private actor CompanionLifecycleTransport: CompanionTransport {
    let held = CompanionLifecycleLatch()
    private var holdFirst: Bool
    private(set) var published: [String] = []
    init(holdFirst: Bool = false) { self.holdFirst = holdFirst }
    func publishObject(sha256: String, data: Data) async throws {}
    func publishJob(id: String, data: Data) async throws {
        if holdFirst { holdFirst = false; await held.hold() }
        if let permit = CompanionTransportAdmission.current { try permit {} }
        published.append(id)
    }
    func result(id: String) async throws -> Data? { nil }
    func acknowledge(id: String, resultSHA256: String) async throws {}
    func close() async {}
}
