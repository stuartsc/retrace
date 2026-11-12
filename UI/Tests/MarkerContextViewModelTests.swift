import Foundation
import AppKit
import Shared
import XCTest
@testable import App
@testable import Retrace

@MainActor
final class MarkerContextViewModelTests: XCTestCase {
    func testMarkerWindowCloseDuringFinalAuthorizationCannotReopen() async throws {
        _ = NSApplication.shared
        let fixture = try await MarkerRangeUIFixture.make()
        let coordinator = AppCoordinator(services: ServiceContainer(databasePath: "file:marker-window-\(UUID())?mode=memory&cache=private",
            storageConfig: .init(storageRootPath: fixture.root.path)))
        let entered = expectation(description: "Marker final authorization held")
        let held = MarkerWindowAuthorizationHold(call: 2, entered: entered)
        var presentations = 0
        let controller = MarkerContextWindowController(makeModel: { _ in fixture.model() },
            playbackOwner: { _ in throw RetraceCommandError.unavailable }, presentWindow: { _ in presentations += 1 })
        let opening = Task { try await controller.open(markerID: fixture.marker.id, expectedRevision: fixture.marker.revision,
            coordinator: coordinator, authorization: .init(fence: NativeMutationFence(), validation: { await held.validate() })) }
        await fulfillment(of: [entered], timeout: 3)
        controller.windowWillClose(.init(name: NSWindow.willCloseNotification, object: controller.window))
        await held.release()
        do { try await opening.value; XCTFail("A closed marker destination cannot reopen after authorization resumes") }
        catch is CancellationError { }
        XCTAssertEqual(presentations, 0); XCTAssertNil(controller.test_markerID)
        await held.release(); try await fixture.close(); try? FileManager.default.removeItem(at: fixture.root)
    }

    func testMarkerWindowReplacementRejectsOlderFinalAuthorization() async throws {
        _ = NSApplication.shared
        let fixture = try await MarkerRangeUIFixture.make()
        let newer = try await fixture.markers.createManualMarker(.init(anchoredAt: fixture.time, title: "Newer selection"))
        let coordinator = AppCoordinator(services: ServiceContainer(databasePath: "file:marker-window-\(UUID())?mode=memory&cache=private",
            storageConfig: .init(storageRootPath: fixture.root.path)))
        let entered = expectation(description: "Older marker waits at final authorization")
        let held = MarkerWindowAuthorizationHold(call: 2, entered: entered)
        var presentations = 0
        let controller = MarkerContextWindowController(makeModel: { _ in fixture.model() },
            playbackOwner: { _ in throw RetraceCommandError.unavailable }, presentWindow: { _ in presentations += 1 })
        let old = Task { try await controller.open(markerID: fixture.marker.id, expectedRevision: fixture.marker.revision,
            coordinator: coordinator, authorization: .init(fence: NativeMutationFence(), validation: { await held.validate() })) }
        await fulfillment(of: [entered], timeout: 3)
        try await controller.open(markerID: newer.id, expectedRevision: newer.revision, coordinator: coordinator,
            authorization: .init(fence: NativeMutationFence(), validation: {}))
        await held.release()
        do { try await old.value; XCTFail("Older completion cannot replace the newer marker window") }
        catch is CancellationError { }
        XCTAssertEqual(controller.test_markerID, newer.id); XCTAssertEqual(presentations, 1)
        XCTAssertNotNil(controller.window?.contentView)
        controller.windowWillClose(.init(name: NSWindow.willCloseNotification, object: controller.window))
        controller.window?.close(); try await fixture.close(); try? FileManager.default.removeItem(at: fixture.root)
    }

    func testExpiredMarkerCommandPreservesExistingViewAndDoesNotAcquirePlaybackOwner() async throws {
        _ = NSApplication.shared
        let fixture = try await MarkerRangeUIFixture.make()
        let next = try await fixture.markers.createManualMarker(.init(anchoredAt: fixture.time, title: "Expired replacement"))
        let coordinator = AppCoordinator(services: ServiceContainer(databasePath: "file:marker-window-\(UUID())?mode=memory&cache=private",
            storageConfig: .init(storageRootPath: fixture.root.path)))
        let entered = expectation(description: "Loaded replacement awaits grant deadline check")
        let held = MarkerWindowAuthorizationHold(call: 1, entered: entered), clock = MarkerWindowClock()
        var presentations = 0, playbackReads = 0
        let controller = MarkerContextWindowController(makeModel: { _ in fixture.model() },
            playbackOwner: { _ in playbackReads += 1; throw RetraceCommandError.unavailable },
            presentWindow: { _ in presentations += 1 })
        try await controller.open(markerID: fixture.marker.id, expectedRevision: fixture.marker.revision,
            coordinator: coordinator)
        let oldContent = controller.window?.contentView
        let fence = NativeMutationFence(expiresAt: Date(timeIntervalSince1970: 10), clock: { clock.now })
        let expired = Task { try await controller.open(markerID: next.id, expectedRevision: next.revision,
            coordinator: coordinator, authorization: .init(fence: fence, validation: { await held.validate() })) }
        await fulfillment(of: [entered], timeout: 3)
        clock.advance(); await held.release()
        do { try await expired.value; XCTFail("Expired command must not disturb prior UI or playback") }
        catch is CancellationError { }
        XCTAssertEqual(controller.test_markerID, fixture.marker.id)
        XCTAssertTrue(controller.window?.contentView === oldContent)
        XCTAssertEqual(presentations, 1); XCTAssertEqual(playbackReads, 0)
        controller.windowWillClose(.init(name: NSWindow.willCloseNotification, object: controller.window))
        controller.window?.close(); try await fixture.close(); try? FileManager.default.removeItem(at: fixture.root)
    }

    func testDeletingAnOpenMarkerClearsItsHeaderAndRetainedPayload() async throws {
        let fixture = try await MarkerRangeUIFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.model()
        try await model.load(id: fixture.marker.id)
        XCTAssertNotNil(model.marker)
        let invalidated = expectation(description: "Deleted marker header cleared")
        let observation = model.$marker.dropFirst().filter { $0 == nil }.prefix(1).sink { _ in invalidated.fulfill() }
        let observerID = try await fixture.markers.addChangeObserver(invalidate: { _ in fixture.reader.invalidate() })
        _ = try await fixture.markers.setMarkerDeleted(id: fixture.marker.id,
            expectedRevision: fixture.marker.revision, deleted: true)
        await fulfillment(of: [invalidated], timeout: 3)
        observation.cancel()
        await model.finishPendingRefresh()
        XCTAssertNil(model.marker)
        XCTAssertTrue(model.ranges.isEmpty)
        XCTAssertNotNil(model.message)
        do {
            try await model.load(id: fixture.marker.id)
            XCTFail("A deleted marker must not refresh its header")
        } catch { XCTAssertNil(model.marker) }
        await fixture.markers.removeChangeObserver(observerID)
        model.hide(); try await fixture.close()
    }

    func testDurableSaveReportsRefreshFailureWithoutPublishingRawReceipt() async throws {
        let fixture = try await MarkerRangeUIFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let access = MarkerRangeReaderAccess(owner: fixture.reader)
        let model = MarkerContextViewModel(service: { fixture.markers }, presentations: { try await access.get() })
        try await model.load(id: fixture.marker.id)
        await access.failReads()
        model.save(start: fixture.time, end: fixture.time.addingTimeInterval(10), explanation: "Durably saved", editing: nil, pinned: true)
        await model.finishPendingWrite()
        let stored = try await fixture.markers.listContextRanges(markerID: fixture.marker.id)
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(model.ranges.isEmpty, "A raw write receipt must not bypass the presentation reader")
        XCTAssertTrue(model.message?.contains("Range saved, but") == true)
        XCTAssertEqual(model.saveRevision, 1)
        model.hide(); try await fixture.close()
    }

    func testExplicitRangePinAndStaleMarkerConflictPreserveCanonicalState() async throws {
        let fixture = try await MarkerRangeUIFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.model()
        try await model.load(id: fixture.marker.id, expectedRevision: fixture.marker.revision)
        XCTAssertTrue(model.ranges.isEmpty, "Opening must not invent a context interval")
        model.save(start: fixture.time.addingTimeInterval(-13), end: fixture.time.addingTimeInterval(7),
            explanation: "My chosen context", editing: nil, pinned: true)
        await model.finishPendingWrite()
        let saved = try XCTUnwrap(model.ranges.first)
        let reference = try XCTUnwrap(model.presentations.first?.reference)
        XCTAssertEqual(saved.ownership, .pinned)
        XCTAssertEqual(saved.effectiveExplanationOrigin, .userAuthored)
        XCTAssertEqual(saved.start, fixture.time.addingTimeInterval(-13))
        XCTAssertEqual(saved.end, fixture.time.addingTimeInterval(7))
        let deleted = try await fixture.markers.setMarkerDeleted(id: fixture.marker.id,
            expectedRevision: fixture.marker.revision, deleted: true)
        model.save(start: saved.start, end: saved.end, explanation: "Must not replace after deletion", editing: reference, pinned: false)
        await model.finishPendingWrite()
        do {
            _ = try await fixture.markers.listContextRanges(markerID: fixture.marker.id)
            XCTFail("Deleted markers must not expose their context ranges")
        } catch { XCTAssertEqual(error as? ContextStoreError, .markerNotFound) }
        _ = try await fixture.markers.setMarkerDeleted(id: fixture.marker.id, expectedRevision: deleted.revision, deleted: false)
        let retained = try await fixture.markers.listContextRanges(markerID: fixture.marker.id)
        XCTAssertEqual(retained, [saved])
        XCTAssertNotNil(model.message)
        model.hide(); try await fixture.close()
    }

    func testPinPreservesInheritedProofAndInvalidationClearsPayloadBeforeHeldRefresh() async throws {
        let fixture = try await MarkerRangeUIFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.importProposal()
        let model = fixture.model()
        try await model.load(id: fixture.marker.id)
        let original = try XCTUnwrap(model.ranges.first)
        let reference = try XCTUnwrap(model.presentations.first?.reference)
        XCTAssertEqual(original.effectiveExplanationOrigin, .companionDerived)
        model.save(start: original.start.addingTimeInterval(-2), end: original.end.addingTimeInterval(2),
            explanation: "My separate note", editing: reference, pinned: true)
        await model.finishPendingWrite()
        let pinned = try XCTUnwrap(model.ranges.first)
        XCTAssertEqual(pinned.ownership, .pinned)
        XCTAssertEqual(pinned.explanation, original.explanation)
        XCTAssertEqual(pinned.effectiveExplanationOrigin, .companionDerived)
        XCTAssertEqual(pinned.provenance, original.provenance)
        XCTAssertEqual(pinned.userNote, "My separate note")
        let pinnedReference = try XCTUnwrap(model.presentations.first?.reference)

        await fixture.source.revokeAndHoldNextRead()
        fixture.reader.invalidate()
        await fixture.source.waitForHeldRead()
        XCTAssertTrue(model.ranges.isEmpty, "Invalidation must clear source text and times before awaiting its replacement")
        XCTAssertNil(model.presentations.first?.range)
        XCTAssertEqual(model.presentations.first?.availability, .sourceUnavailable)
        XCTAssertEqual(model.presentations.first?.userNote, "My separate note")
        model.hide()
        await fixture.source.releaseRead()
        await model.finishPendingRefresh()
        XCTAssertTrue(model.ranges.isEmpty, "A hidden view cannot accept the delayed source read")
        try await model.load(id: fixture.marker.id)
        XCTAssertNil(model.presentations.first?.range)
        XCTAssertEqual(model.presentations.first?.userNote, "My separate note")
        do {
            _ = try await model.resolveForAction(pinnedReference)
            XCTFail("A saved reference does not authorize reviewing or editing unavailable source content")
        } catch { }
        model.hide(); try await fixture.close()
    }

    func testLegacyContextShowsOnlyExplicitUserNote() async throws {
        let fixture = try await MarkerRangeUIFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.markers.saveContextRange(markerID: fixture.marker.id,
            range: .init(start: fixture.time, end: fixture.time.addingTimeInterval(1), explanation: "Unverified earlier source text",
                ownership: .proposed, userNote: "My retained note"), expectedRevision: nil, expectedMarkerRevision: fixture.marker.revision)
        let model = fixture.model()
        try await model.load(id: fixture.marker.id)
        XCTAssertTrue(model.ranges.isEmpty)
        XCTAssertEqual(model.presentations.first?.availability, .legacyUnverified)
        XCTAssertNil(model.presentations.first?.range)
        XCTAssertEqual(model.presentations.first?.userNote, "My retained note")
        model.hide(); try await fixture.close()
    }
}

private actor MarkerWindowAuthorizationHold {
    let call: Int
    let entered: XCTestExpectation
    private var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    init(call: Int, entered: XCTestExpectation) { self.call = call; self.entered = entered }
    func validate() async {
        count += 1
        guard count == call else { return }
        await withCheckedContinuation { continuation = $0; entered.fulfill() }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private final class MarkerWindowClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 0)
    var now: Date { lock.withLock { date } }
    func advance() { lock.withLock { date = Date(timeIntervalSince1970: 20) } }
}

private struct MarkerRangeUIFixture: Sendable {
    let root: URL
    let markers: TimelineMarkerService
    let marker: TimelineMarker
    let reader: ContextRangePresentationService
    let source: MarkerRangeSourceGate
    var time: Date { marker.anchoredAt }
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marker-range-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let storeID = UUID(), source = MarkerRangeSourceGate()
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { storeID })
        let marker = try await markers.createManualMarker(.init(anchoredAt: Date(timeIntervalSince1970: 1_800_000_000.123)))
        let reader = ContextRangePresentationService(markers: markers, validateEvidence: { try await source.validate($0) },
            currentEpoch: { await source.epoch })
        return .init(root: root, markers: markers, marker: marker, reader: reader, source: source)
    }
    @MainActor func model() -> MarkerContextViewModel { .init(service: { self.markers }, presentations: { self.reader }) }
    func close() async throws { await reader.close(); try await markers.close() }
    func importProposal() async throws {
        let support = CompanionEvidenceItem(id: "retained-row", reference: .init(v23Transcript: .init(nativeStoreID: marker.nativeStoreID,
            source: .microphone, rowID: 1, snapshotSHA256: String(repeating: "a", count: 64))),
            start: time, end: time.addingTimeInterval(1), text: "Sensitive retained source words")
        let request = CompanionJobRequest(sourceStoreID: marker.nativeStoreID, observedAt: time, context: .init(
            markerID: marker.id, markerRevision: marker.revision, snapshotID: UUID(), query: "Decision", verbatimExplanation: "",
            developing: true, incomplete: true, evidence: [support]))
        let data = try CompanionWire.encode(request)
        let canonical = try CompanionWire.decode(CompanionJobRequest.self, data: data, limit: 768 * 1024)
        let context = try XCTUnwrap(canonical.context), item = try XCTUnwrap(context.evidence.first)
        let result = CompanionResult(jobID: CompanionWire.digest(data), sourceStoreID: marker.nativeStoreID,
            contextProposal: .init(markerID: marker.id, markerRevision: marker.revision, snapshotID: context.snapshotID,
                verbatimExplanation: "", developing: true, incomplete: true,
                ranges: [.init(id: UUID(), start: item.start, end: item.end, explanation: CompanionProposedRange.supportedExplanation(item),
                    supportIDs: [item.id], score: 0.9)], method: "authored"))
        try await CompanionContextImporter(markers: markers).apply(request: canonical, result: result,
            requestData: data, resultData: CompanionWire.encode(result))
    }
}

private actor MarkerRangeReaderAccess {
    let owner: ContextRangePresentationService
    private var unavailable = false
    init(owner: ContextRangePresentationService) { self.owner = owner }
    func failReads() { unavailable = true }
    func get() throws -> ContextRangePresentationService {
        if unavailable { throw ContextStoreError.notInitialized }
        return owner
    }
}

private actor MarkerRangeSourceGate {
    var epoch = "initial"
    private var allowed = true
    private var holdNextRead = false
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldRead: CheckedContinuation<Void, Never>?
    func validate(_ request: CompanionJobRequest) async throws {
        if holdNextRead {
            holdNextRead = false; entered = true
            enteredWaiters.forEach { $0.resume() }; enteredWaiters = []
            await withCheckedContinuation { heldRead = $0 }
        }
        if !allowed { throw CompanionError.staleEvidence }
    }
    func revokeAndHoldNextRead() { allowed = false; epoch = "revoked"; holdNextRead = true }
    func waitForHeldRead() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func releaseRead() { heldRead?.resume(); heldRead = nil }
}
