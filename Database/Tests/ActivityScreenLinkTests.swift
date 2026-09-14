import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database

final class ActivityScreenLinkTests: XCTestCase {
    private var database: DatabaseManager!
    private var store: (any ActivityStoreProtocol) { database }
    private let sessionID = UUID()
    private let time = Date(timeIntervalSince1970: 1_800_000_000)
    private var segmentID: Int64 = 0

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:links_\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        segmentID = try await database.insertSegment(bundleID: "com.microsoft.Word", startDate: time, endDate: time.addingTimeInterval(60),
                                                     windowName: "Budget", browserUrl: nil, type: 0)
    }
    override func tearDown() async throws { try await database.close() }

    func testIdentityProvenLinkIsAtomicIdempotentAndRetainsActualCaptureTime() async throws {
        let event = try await appendEvent()
        let ref = try await insertScreen(event: event)
        let link = try await store.linkActivityScreen(eventID: event.id, screen: ref, capturedAt: time.addingTimeInterval(1), method: "captured-surface-v1")
        let repeated = try await store.linkActivityScreen(eventID: event.id, screen: ref, capturedAt: time.addingTimeInterval(1), method: "captured-surface-v1")
        expectEqual(link.id, repeated.id)
        expectEqual(link.capturedAt, time.addingTimeInterval(1))
        let links = try await store.activityScreenLinks(eventID: event.id, afterSequence: 0, limit: 20)
        expectEqual(links.count, 1)
        expectEqual(links.first?.screen, ref)
        expectNotEqual(links.first?.capturedAt, event.event.observedAt)
        let feed = try await store.activityFeed(after: event.commitSequence, limit: 20)
        expectEqual(feed.filter { $0.kind == "activity_screen_link" }.count, 1)
    }

    func testTimestampProximityWithoutCapturedIdentityNeverCreatesALink() async throws {
        let event = try await appendEvent()
        let ref = try await insertScreen(event: event, includeIdentity: false)
        await assertThrows { _ = try await self.store.linkActivityScreen(eventID: event.id, screen: ref,
            capturedAt: self.time.addingTimeInterval(1), method: "captured-surface-v1") }
        expectTrue(try await store.activityScreenLinks(eventID: event.id, afterSequence: 0, limit: 20).isEmpty)
    }

    func testWrongSessionProcessWindowAndDocumentIdentitiesAreRejected() async throws {
        let event = try await appendEvent()
        let identities = [identity(event, session: UUID()), identity(event, processGeneration: "reused-pid"),
                          identity(event, windowGeneration: "reused-window"), identity(event, documentID: "different-document"),
                          identity(event, paneID: "different-pane")]
        for proof in identities {
            let ref = try await insertScreen(event: event, suppliedIdentity: proof)
            await assertThrows { _ = try await self.store.linkActivityScreen(eventID: event.id, screen: ref,
                capturedAt: self.time.addingTimeInterval(1), method: "captured-surface-v1") }
        }
    }

    func testUnknownWindowGenerationAndWrongCaptureTimeAreNotProof() async throws {
        let event = try await appendEvent(windowGeneration: nil)
        let ref = try await insertScreen(event: event)
        await assertThrows { _ = try await self.store.linkActivityScreen(eventID: event.id, screen: ref,
            capturedAt: self.time.addingTimeInterval(1), method: "captured-surface-v1") }
        let next = try await appendEvent(sequence: 2, windowGeneration: "window-1")
        let nextRef = try await insertScreen(event: next)
        await assertThrows { _ = try await self.store.linkActivityScreen(eventID: next.id, screen: nextRef,
            capturedAt: self.time.addingTimeInterval(2), method: "captured-surface-v1") }
    }

    func testInterveningUnknownCoveragePreventsLinkEvenWhenWindowMatches() async throws {
        let event = try await appendEvent()
        _ = try await store.appendActivity(ActivityEvent(sessionID: sessionID, sequence: 2, observedAt: time.addingTimeInterval(0.5),
            monotonicTime: 10.5, kind: .gap, coverage: .unknown, method: "observer-failure"))
        let ref = try await insertScreen(event: event)
        await assertThrows { _ = try await self.store.linkActivityScreen(eventID: event.id, screen: ref,
            capturedAt: self.time.addingTimeInterval(1), method: "captured-surface-v1") }
    }

    func testLatePersistedGapInvalidatesAnEarlierLinkWhoseCaptureCrossedThatGap() async throws {
        let event = try await appendEvent()
        let ref = try await insertScreen(event: event)
        let link = try await store.linkActivityScreen(eventID: event.id, screen: ref, capturedAt: time.addingTimeInterval(1), method: "captured-surface-v1")
        _ = try await store.appendActivity(ActivityEvent(sessionID: sessionID, sequence: 2, observedAt: time.addingTimeInterval(0.5),
            monotonicTime: 10.5, kind: .gap, coverage: .unknown, method: "late-storage-reconciliation"))
        expectTrue(try await store.activityScreenLinks(eventID: event.id, afterSequence: 0, limit: 20).isEmpty)
        expectNotNil(try await database.screenEvidence(ref))
        let feed = try await store.activityFeed(after: link.commitSequence, limit: 20)
        expectTrue(feed.contains { $0.kind == "activity_screen_link_deleted" && $0.entityID == link.id })
    }

    func testLateSameSurfaceHeartbeatAndGapAfterCapturePreserveTheLink() async throws {
        let event = try await appendEvent()
        let ref = try await insertScreen(event: event)
        _ = try await store.linkActivityScreen(eventID: event.id, screen: ref, capturedAt: time.addingTimeInterval(1), method: "captured-surface-v1")
        _ = try await store.appendActivity(ActivityEvent(sessionID: sessionID, sequence: 2, observedAt: time.addingTimeInterval(0.5),
            monotonicTime: 10.5, kind: .heartbeat, coverage: .observed, context: context(), method: "heartbeat"))
        _ = try await store.appendActivity(ActivityEvent(sessionID: sessionID, sequence: 3, observedAt: time.addingTimeInterval(2),
            monotonicTime: 12, kind: .gap, coverage: .unknown, method: "observer-failure"))
        expectEqual(try await store.activityScreenLinks(eventID: event.id, afterSequence: 0, limit: 20).count, 1)
    }

    func testFeedFailureRollsBackLinkAndRetryPublishesOnce() async throws {
        let event = try await appendEvent()
        let ref = try await insertScreen(event: event)
        try await sql("CREATE TEMP TRIGGER reject_link_feed BEFORE INSERT ON activity_feed WHEN NEW.kind='activity_screen_link' BEGIN SELECT RAISE(ABORT,'injected'); END")
        await assertThrows { _ = try await self.store.linkActivityScreen(eventID: event.id, screen: ref,
            capturedAt: self.time.addingTimeInterval(1), method: "captured-surface-v1") }
        expectTrue(try await store.activityScreenLinks(eventID: event.id, afterSequence: 0, limit: 20).isEmpty)
        try await sql("DROP TRIGGER reject_link_feed")
        _ = try await store.linkActivityScreen(eventID: event.id, screen: ref, capturedAt: time.addingTimeInterval(1), method: "captured-surface-v1")
        expectEqual(try await store.activityScreenLinks(eventID: event.id, afterSequence: 0, limit: 20).count, 1)
    }

    func testFrameDeletionRevokesLinksSanitizesFeedAndRetainsActivity() async throws {
        let event = try await appendEvent()
        let ref = try await insertScreen(event: event)
        let linked = try await store.linkActivityScreen(eventID: event.id, screen: ref, capturedAt: time.addingTimeInterval(1), method: "captured-surface-v1")
        try await database.deleteFrame(id: ref.frameID)
        expectTrue(try await store.activityScreenLinks(eventID: event.id, afterSequence: 0, limit: 20).isEmpty)
        expectNotNil(try await store.activityEvent(id: event.id))
        let feed = try await store.activityFeed(after: 0, limit: 50)
        expectTrue(feed.contains { $0.kind == "activity_screen_link_deleted" && $0.entityID == linked.id })
        expectTrue(feed.filter { $0.entityID == linked.id && $0.kind == "redacted" }.allSatisfy { $0.payload == Data("{}".utf8) })
    }

    func testActivityDeletionRevokesLinksWhileRetainingTheRecordedScreen() async throws {
        let event = try await appendEvent()
        let ref = try await insertScreen(event: event)
        _ = try await store.linkActivityScreen(eventID: event.id, screen: ref, capturedAt: time.addingTimeInterval(1), method: "captured-surface-v1")
        try await store.deleteActivity(eventIDs: [event.id])
        expectTrue(try await store.activityScreenLinks(eventID: event.id, afterSequence: 0, limit: 20).isEmpty)
        expectNotNil(try await database.screenEvidence(ref))
        await assertThrows { _ = try await self.store.linkActivityScreen(eventID: event.id, screen: ref,
            capturedAt: self.time.addingTimeInterval(1), method: "captured-surface-v1") }
    }

    func testLinkPagesAreBoundedAndContinueOverEveryLinkedScreen() async throws {
        let event = try await appendEvent()
        var refs: [ScreenEvidenceRef] = []
        for _ in 0..<5 {
            let ref = try await insertScreen(event: event)
            refs.append(ref)
            _ = try await store.linkActivityScreen(eventID: event.id, screen: ref, capturedAt: time.addingTimeInterval(1), method: "captured-surface-v1")
        }
        let first = try await store.activityScreenLinks(eventID: event.id, afterSequence: 0, limit: 2)
        let second = try await store.activityScreenLinks(eventID: event.id, afterSequence: try requireValue(first.last?.commitSequence), limit: 3)
        expectEqual((first + second).map(\.screen), refs)
        await assertThrows { _ = try await self.store.activityScreenLinks(eventID: event.id, afterSequence: 0, limit: 501) }
    }

    private func appendEvent(sequence: Int64 = 1, windowGeneration: String? = "window-1") async throws -> PersistedActivityEvent {
        try await store.appendActivity(ActivityEvent(sessionID: sessionID, sequence: sequence, observedAt: time,
            monotonicTime: 10, kind: .focus, coverage: .observed, context: context(windowGeneration: windowGeneration), method: "fixture"))
    }
    private func context(windowGeneration: String? = "window-1") -> ActivityContext {
        ActivityContext(appBundleID: "com.microsoft.Word", appName: "Word", processID: 17, processGeneration: "process-1",
            windowID: 22, windowGeneration: windowGeneration, windowTitle: "Budget", displayID: 2, documentID: "document-1", paneID: "pane-1")
    }
    private func identity(_ event: PersistedActivityEvent, session: UUID? = nil, processGeneration: String = "process-1",
                          windowGeneration: String = "window-1", documentID: String = "document-1", paneID: String = "pane-1") -> ActivityCaptureIdentity {
        ActivityCaptureIdentity(activityEventID: event.id, sessionID: session ?? sessionID, processID: 17,
            processGeneration: processGeneration, windowID: 22, windowGeneration: windowGeneration,
            captureMonotonicTime: 11, documentID: documentID, paneID: paneID)
    }
    private func insertScreen(event: PersistedActivityEvent, includeIdentity: Bool = true,
                              suppliedIdentity: ActivityCaptureIdentity? = nil) async throws -> ScreenEvidenceRef {
        let metadata = FrameMetadata(appBundleID: "com.microsoft.Word", appName: "Word", windowName: "Budget", displayID: 2,
            captureContext: context(), captureMonotonicTime: 11,
            activityIdentity: includeIdentity ? (suppliedIdentity ?? identity(event)) : nil)
        let frameID = try await database.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: time.addingTimeInterval(1),
            segmentID: AppSegmentID(value: segmentID), frameIndexInSegment: 0, metadata: metadata))
        return try requireValue(try await database.currentScreenEvidence(frameID: FrameID(value: frameID), storeID: database.activityStoreID())).ref
    }
    private func sql(_ value: String) async throws { try PipelineSQL.execute(try requireValue(await database.getConnection()), value) }
    private func assertThrows(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected unproven screen link rejection", file: file, line: line) } catch { }
    }
}
