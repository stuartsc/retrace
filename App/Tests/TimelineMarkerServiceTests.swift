import Foundation
import XCTest
import Shared
import Database
@testable import App

final class TimelineMarkerServiceTests: XCTestCase {
    private var directory: URL!
    private let nativeID = UUID()
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("marker-service-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try FileManager.default.removeItem(at: directory) }

    func testConstructionIsLazyAndFirstActionCreatesPrivateStore() async throws {
        let root = try XCTUnwrap(directory)
        let owner = TimelineMarkerService(storageRoot: root, nativeStoreID: { self.nativeID })
        let context = root.appendingPathComponent("context")
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.path))
        let marker = try await owner.createManualMarker(.init(anchoredAt: anchor))
        XCTAssertEqual(marker.nativeStoreID, nativeID)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: context.path)[.posixPermissions] as? NSNumber
        let databaseMode = try FileManager.default.attributesOfItem(atPath: context.appendingPathComponent("context.db").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)
        XCTAssertEqual(databaseMode?.intValue, 0o600)
        try await owner.close()
    }

    func testConcurrentCallersShareLazyInitializationAndCloseJoinsHeldFactory() async throws {
        let db = ContextDatabase(databasePath: directory.appendingPathComponent("private.db").path, nativeStoreID: nativeID)
        let entered = expectation(description: "factory entered once")
        entered.expectedFulfillmentCount = 1
        let factoryGate = MarkerServiceGate()
        let owner = TimelineMarkerService(factory: {
            entered.fulfill()
            await factoryGate.wait()
            return db
        })
        let first = Task { try await owner.listMarkers(.init()) }
        let second = Task { try await owner.listMarkers(.init()) }
        await fulfillment(of: [entered], timeout: 3)
        let closed = MarkerServiceGate()
        let close = Task { try await owner.close(); await closed.release() }
        await owner.beginClose()
        let returnedEarly = await closed.released
        XCTAssertFalse(returnedEarly)
        await factoryGate.release()
        _ = try? await first.value
        _ = try? await second.value
        try await close.value
        do { _ = try await db.contextStoreID(); XCTFail("Late acquired store must be closed") }
        catch { XCTAssertEqual(error as? ContextStoreError, .closed) }
    }

    func testDeletedCreationReplayNeverAcknowledgesAnActiveMarkerAndUndoIsCurrent() async throws {
        let owner = makeOwner()
        let command = ManualTimelineMarkerCommand(anchoredAt: anchor)
        let first = try await owner.createManualMarker(command)
        let deleted = try await owner.setMarkerDeleted(id: first.id, expectedRevision: first.revision, deleted: true)
        do { _ = try await owner.createManualMarker(command); XCTFail("Deleted replay must not look active") }
        catch { XCTAssertEqual(error as? TimelineMarkerServiceError, .inactiveMarker) }
        let restored = try await owner.setMarkerDeleted(id: first.id, expectedRevision: deleted.revision, deleted: false)
        let replay = try await owner.createManualMarker(command)
        XCTAssertEqual(replay, restored)
        try await owner.close()
    }

    func testDurableDeletionInvalidatesObserversAndJoinsPlaybackBeforeAcknowledgement() async throws {
        let owner = makeOwner()
        let marker = try await owner.createManualMarker(.init(anchoredAt: anchor))
        let signals = MarkerRuleSignals()
        let entered = expectation(description: "drain after durable delete")
        let gate = MarkerServiceGate()
        let completed = MarkerServiceGate()
        let token = try await owner.addChangeObserver(invalidate: { id in
            if id == marker.id { signals.record() }
        }, drain: { id in
            if id == marker.id { entered.fulfill(); await gate.wait() }
        })
        let deletion = Task {
            let result = try await owner.setMarkerDeleted(id: marker.id, expectedRevision: marker.revision, deleted: true)
            await completed.release()
            return result
        }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(signals.count, 1)
        let current = try await owner.marker(id: marker.id)
        let acknowledgedEarly = await completed.released
        XCTAssertNil(current)
        XCTAssertFalse(acknowledgedEarly)
        await gate.release()
        _ = try await deletion.value
        await owner.removeChangeObserver(token)
        try await owner.close()
    }

    func testFailedWriteLeavesServiceUsableAndUnsupportedScreenIsRejected() async throws {
        let owner = makeOwner()
        do { _ = try await owner.createManualMarker(.init(anchoredAt: anchor, title: "")); XCTFail("Invalid write") }
        catch { XCTAssertEqual(error as? ContextStoreError, .invalidInput) }
        let reference = ScreenEvidenceRef(storeID: nativeID, source: .native, observationID: UUID(),
                                          frameID: FrameID(value: 1), extractionRevision: 1)
        do { _ = try await owner.createManualMarker(.init(anchoredAt: anchor, screenReference: reference)); XCTFail("Unvalidated screen") }
        catch { XCTAssertEqual(error as? TimelineMarkerServiceError, .screenReferenceUnsupported) }
        let retained = try await owner.createManualMarker(.init(anchoredAt: anchor))
        let page = try await owner.listMarkers(.init())
        XCTAssertEqual(page.markers, [retained])
        try await owner.close()
    }

    func testCloseJoinsMetricTailBeforeReleasingStoreAndRejectsNewActions() async throws {
        let db = ContextDatabase(databasePath: directory.appendingPathComponent("private.db").path, nativeStoreID: nativeID)
        let metricEntered = expectation(description: "outcome metric entered")
        let metricGate = MarkerServiceGate()
        let owner = TimelineMarkerService(factory: { db }, metrics: { action, outcome in
            if action == .create && outcome == .succeeded {
                metricEntered.fulfill()
                await metricGate.wait()
            }
        })
        let action = Task { try await owner.createManualMarker(.init(anchoredAt: self.anchor)) }
        await fulfillment(of: [metricEntered], timeout: 3)
        await owner.beginClose()
        let closed = MarkerServiceGate()
        let close = Task { try await owner.close(); await closed.release() }
        do { _ = try await owner.listMarkers(.init()); XCTFail("Close must fence actions immediately") }
        catch { XCTAssertEqual(error as? ContextStoreError, .closed) }
        let early = await closed.released
        XCTAssertFalse(early)
        let stillOpen = try await db.contextStoreID()
        XCTAssertNotNil(stillOpen)
        await metricGate.release()
        do { _ = try await action.value; XCTFail("Cancelled completion must not acknowledge") } catch { }
        try await close.value
    }

    func testFailedCloseRetainsCapabilityForRetryAndRemainsTerminal() async throws {
        let db = ContextDatabase(databasePath: directory.appendingPathComponent("private.db").path, nativeStoreID: nativeID)
        let attempts = MarkerCloseAttempts()
        let owner = TimelineMarkerService(factory: { db }, closeStore: { store in
            if await attempts.isFirst() { throw MarkerTestFailure.close }
            try await store.close()
        })
        _ = try await owner.listMarkers(.init())
        do { try await owner.close(); XCTFail("Injected close failure") } catch { }
        _ = try await db.contextStoreID()
        do { _ = try await owner.listMarkers(.init()); XCTFail("Failed close still fences admission") }
        catch { XCTAssertEqual(error as? ContextStoreError, .closed) }
        try await owner.close()
        do { _ = try await db.contextStoreID(); XCTFail("Retry must close the original store") }
        catch { XCTAssertEqual(error as? ContextStoreError, .closed) }
    }

    func testWrongStoreReopenFailsWithoutAlteringPersistedMarker() async throws {
        let path = directory.appendingPathComponent("private.db").path
        let original = ContextDatabase(databasePath: path, nativeStoreID: nativeID)
        try await original.initialize()
        let retained = try await original.createManualMarker(.init(anchoredAt: anchor))
        try await original.close()
        let wrong = TimelineMarkerService(factory: { ContextDatabase(databasePath: path, nativeStoreID: UUID()) })
        do { _ = try await wrong.listMarkers(.init()); XCTFail("Wrong native store") }
        catch { XCTAssertEqual(error as? ContextStoreError, .nativeStoreMismatch) }
        try await wrong.close()
        let check = ContextDatabase(databasePath: path, nativeStoreID: nativeID)
        try await check.initialize()
        let marker = try await check.marker(id: retained.id, includeDeleted: false)
        XCTAssertEqual(marker, retained)
        try await check.close()
    }

    func testRuleChangeSignalFollowsSuccessfulSaveAndIsNotSentForRejectedWrite() async throws {
        let owner = makeOwner()
        let signals = MarkerRuleSignals()
        await owner.setRulesChangedHandler { signals.record() }
        let saved = try await owner.saveKeywordRule(.init(phrase: "remember this", name: "Remember", meaning: "Keep this moment"), expectedRevision: nil)
        XCTAssertEqual(signals.count, 1)
        let rules = try await owner.listKeywordRules()
        XCTAssertEqual(rules, [saved])
        do {
            _ = try await owner.saveKeywordRule(.init(phrase: "", name: "Invalid", meaning: ""), expectedRevision: nil)
            XCTFail("Invalid rule must not commit or signal")
        } catch { }
        XCTAssertEqual(signals.count, 1)
        try await owner.close()
    }

    private func makeOwner() -> TimelineMarkerService {
        let path = directory.appendingPathComponent("private.db").path
        let id = nativeID
        return TimelineMarkerService(factory: { ContextDatabase(databasePath: path, nativeStoreID: id) })
    }
}

private enum MarkerTestFailure: Error { case close }
private final class MarkerRuleSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func record() { lock.lock(); defer { lock.unlock() }; value += 1 }
}
private actor MarkerCloseAttempts {
    private var attempts = 0
    func isFirst() -> Bool { attempts += 1; return attempts == 1 }
}
private actor MarkerServiceGate {
    private(set) var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
