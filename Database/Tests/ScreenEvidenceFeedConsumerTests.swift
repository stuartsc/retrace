import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database

/// Real privately owned SQLite files exercise the exact synchronous writer engine.
/// Opening them directly avoids production encryption preferences and Keychain access.
final class ScreenEvidenceFeedConsumerTests: XCTestCase {
    private var directory: URL!
    private var db: OpaquePointer!
    private var storeID: UUID!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var path: String { directory.appendingPathComponent("consumer.sqlite").path }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("screen-consumer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        db = try openWriter()
        try await MigrationRunner(db: db).runMigrations()
        storeID = try RecallSQL.nativeStore(db)
        try execute("""
            INSERT INTO segment(id,bundleID,startDate,endDate,windowName,type)
            VALUES(1,'com.test.consumer',1700000000000,1700000000000,'Authored retained context',0)
            """)
    }

    override func tearDown() async throws {
        if let db { XCTAssertEqual(sqlite3_close_v2(db), SQLITE_OK) }
        db = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testPublicProtocolUsesTheSameEngineWithoutStartingWork() async throws {
        let manager = DatabaseManager()
        try await manager.initialize()
        do {
            let store: any ScreenEvidenceFeedStoreProtocol = manager
            let initial = try await store.beginScreenEvidenceBootstrap(consumerID: UUID(), leaseDuration: 60)
            let page = try await store.advanceScreenEvidenceConsumer(cursor: initial.cursor, limit: 1)
            XCTAssertEqual(page.status.phase, .replay)
            XCTAssertEqual(page.inspectedCount, 0)
            XCTAssertEqual(page.appliedCount, 0)
            XCTAssertTrue(page.work.isEmpty)
            let state = try await store.screenEvidenceConsumerStatus(cursor: initial.cursor)
            XCTAssertEqual(state.cursor, initial.cursor)
            XCTAssertEqual(state.coverage, .materializedNativeObservations)
            try await manager.close()
        } catch {
            try await manager.close()
            throw error
        }
    }

    func testBootstrapPagesOnlyMaterializedNativeObservationsAndNeverReadsContent() async throws {
        let first = try capture(text: "Authored secret OCR 42000")
        let second = try capture()
        try execute("INSERT INTO frame(createdAt,imageFileName,segmentId) VALUES(1700000000000,'',1)")
        try importedObservation(collidingWith: first.frameID)
        let initial = try begin()
        XCTAssertEqual(initial.maximumFrameID, second.frameID.value)
        XCTAssertEqual(initial.boundarySequence, try feed().latestSequence)
        denyContentReads()
        defer { sqlite3_set_authorizer(db, nil, nil) }
        let a = try advance(initial.cursor, limit: 1)
        let b = try advance(initial.cursor, limit: 1)
        let end = try advance(initial.cursor, limit: 1)
        XCTAssertEqual(a.work.map(\.reference.frameID), [first.frameID])
        XCTAssertEqual(b.work.map(\.reference.frameID), [second.frameID])
        XCTAssertTrue(end.work.isEmpty)
        XCTAssertEqual(end.status.phase, .replay)
        XCTAssertEqual(end.status.checkpointSequence, initial.boundarySequence)
        for work in a.work + b.work {
            XCTAssertEqual(work.reference.source, .native)
            XCTAssertEqual(work.reference.storeID, storeID)
            XCTAssertEqual(work.lexicalState, .blocked)
            XCTAssertEqual(work.vectorState, .blocked)
            XCTAssertNil(work.lexicalReadyRevision)
            XCTAssertNil(work.vectorReadyRevision)
        }
        let encoded = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Authored"))
        XCTAssertFalse(encoded.contains("42000"))
        XCTAssertFalse(encoded.contains("payload"))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work"), 4)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_applied"), 0,
                       "Bootstrap positions are not fabricated feed event zero")
    }

    func testBeginResumesAnUnexpiredLeaseWithoutResettingOrExtendingIt() async throws {
        _ = try capture()
        _ = try capture()
        let initial = try begin(lease: 120)
        let first = try advance(initial.cursor, limit: 1)
        let repeated = try ScreenEvidenceConsumerSQL.begin(db, consumerID: initial.cursor.consumerID,
            leaseDuration: 600, now: now.addingTimeInterval(30))
        XCTAssertEqual(repeated.cursor, initial.cursor)
        XCTAssertEqual(repeated.lastFrameID, first.status.lastFrameID)
        XCTAssertEqual(repeated.expiresAt, initial.expiresAt)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_consumer"), 1)
    }

    func testRegistrationCapsAllConsumersIncludingExpiredIDsButPermitsReuse() async throws {
        let registered = try (0..<32).map { _ in try begin(lease: 1) }
        assertFeedError(.consumerLimitReached) { _ = try begin() }
        let later = now.addingTimeInterval(2)
        let expired = try ScreenEvidenceConsumerSQL.compact(db, limit: 1000, now: later)
        XCTAssertEqual(expired.expiredConsumerCount, 32)
        assertFeedError(.consumerLimitReached) {
            _ = try ScreenEvidenceConsumerSQL.begin(db, consumerID: UUID(), leaseDuration: 60, now: later)
        }
        let original = try XCTUnwrap(registered.first)
        let reused = try ScreenEvidenceConsumerSQL.begin(db, consumerID: original.cursor.consumerID,
                                                        leaseDuration: 60, now: later)
        XCTAssertEqual(reused.cursor.consumerID, original.cursor.consumerID)
        XCTAssertNotEqual(reused.cursor.leaseID, original.cursor.leaseID)
        XCTAssertEqual(reused.phase, .bootstrap)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_consumer"), 32)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_consumer WHERE phase='expired'"), 31)
    }

    func testInvalidLimitsAndLeasesDoNotMutateDurablePositions() async throws {
        for duration in [0, -1, .infinity, .nan, 604_801] {
            assertFeedError(.invalidLease) { _ = try begin(lease: duration) }
        }
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_consumer"), 0)
        let initial = try begin()
        for limit in [0, -1, 201, Int.max] {
            assertFeedError(.invalidLimits) { _ = try advance(initial.cursor, limit: limit) }
        }
        for limit in [0, -1, 1001, Int.max] {
            assertFeedError(.invalidLimits) { _ = try ScreenEvidenceConsumerSQL.compact(db, limit: limit, now: now) }
        }
        let unchanged = try status(initial.cursor)
        XCTAssertEqual(unchanged.lastFrameID, 0)
        XCTAssertEqual(unchanged.checkpointSequence, initial.checkpointSequence)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work"), 0)
    }

    func testEveryCursorIdentityIsValidatedBeforeAdvancement() async throws {
        _ = try capture()
        let initial = try begin()
        let cursor = initial.cursor
        let invalid = [
            ScreenEvidenceConsumerCursor(feedID: UUID(), storeID: cursor.storeID, consumerID: cursor.consumerID, leaseID: cursor.leaseID),
            ScreenEvidenceConsumerCursor(feedID: cursor.feedID, storeID: UUID(), consumerID: cursor.consumerID, leaseID: cursor.leaseID),
            ScreenEvidenceConsumerCursor(feedID: cursor.feedID, storeID: cursor.storeID, consumerID: UUID(), leaseID: cursor.leaseID),
            ScreenEvidenceConsumerCursor(feedID: cursor.feedID, storeID: cursor.storeID, consumerID: cursor.consumerID, leaseID: UUID())
        ]
        for cursor in invalid {
            assertFeedError(.invalidCursor) { _ = try advance(cursor) }
            assertFeedError(.invalidCursor) { _ = try status(cursor) }
        }
        XCTAssertEqual(try status(initial.cursor).lastFrameID, 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work"), 0)
    }

    func testCommittedBootstrapPositionSurvivesWriterCloseAndReopen() async throws {
        let first = try capture()
        let second = try capture()
        let third = try capture()
        let initial = try begin()
        let page = try advance(initial.cursor, limit: 1)
        XCTAssertEqual(page.work.map(\.reference.frameID), [first.frameID])
        try await reopen()
        let resumed = try status(initial.cursor)
        XCTAssertEqual(resumed.lastFrameID, first.frameID.value)
        XCTAssertEqual(resumed.expiresAt, initial.expiresAt)
        let next = try advance(initial.cursor, limit: 2)
        XCTAssertEqual(next.work.map(\.reference.frameID), [second.frameID, third.frameID])
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work"), 6)
    }

    func testBootstrapAndReplayPagesReleaseTransactionsAndWALReaders() async throws {
        _ = try capture()
        let initial = try begin()
        let secondWriter = try openWriter()
        defer { XCTAssertEqual(sqlite3_close_v2(secondWriter), SQLITE_OK) }
        try PipelineSQL.execute(secondWriter, "CREATE TABLE authored_wal_probe(value INTEGER NOT NULL)")

        _ = try advance(initial.cursor, limit: 1)
        XCTAssertEqual(sqlite3_get_autocommit(db), 1)
        try assertWriterCanTruncateWAL(secondWriter)

        _ = try advance(initial.cursor, limit: 1)
        XCTAssertEqual(try status(initial.cursor).phase, .replay)
        _ = try capture()
        let replay = try advance(initial.cursor, limit: 1)
        XCTAssertEqual(replay.appliedCount, 1)
        XCTAssertEqual(sqlite3_get_autocommit(db), 1)
        try assertWriterCanTruncateWAL(secondWriter)
    }

    func testSecondChannelFailureRollsBackTheWholeBootstrapPage() async throws {
        let first = try capture()
        let second = try capture()
        let initial = try begin()
        try execute("""
            CREATE TEMP TRIGGER fail_consumer_work BEFORE INSERT ON screen_evidence_work
            WHEN NEW.frameID=\(second.frameID.value) AND NEW.channel='vector'
            BEGIN SELECT RAISE(ABORT,'authored work failure'); END
            """)
        XCTAssertThrowsError(try advance(initial.cursor, limit: 2))
        XCTAssertEqual(try status(initial.cursor).lastFrameID, 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_applied"), 0)
        XCTAssertNotNil(try ScreenEvidenceSQL.current(db, frameID: first.frameID, storeID: storeID))
        try execute("DROP TRIGGER fail_consumer_work")
        let retried = try advance(initial.cursor, limit: 2)
        XCTAssertEqual(retried.work.map(\.reference.frameID), [first.frameID, second.frameID])
    }

    func testCheckpointFailureRollsBackAppliedEventsAndBothWorkChannels() async throws {
        let initial = try begin()
        _ = try advance(initial.cursor)
        let frame = try capture()
        try execute("""
            CREATE TEMP TRIGGER fail_consumer_checkpoint BEFORE UPDATE OF checkpoint ON screen_evidence_consumer
            WHEN NEW.checkpoint>OLD.checkpoint
            BEGIN SELECT RAISE(ABORT,'authored checkpoint failure'); END
            """)
        XCTAssertThrowsError(try advance(initial.cursor))
        XCTAssertEqual(try status(initial.cursor).checkpointSequence, 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_applied"), 0)
        try execute("DROP TRIGGER fail_consumer_checkpoint")
        let retried = try advance(initial.cursor)
        XCTAssertEqual(retried.appliedCount, 1)
        XCTAssertEqual(retried.work.first?.reference, frame)
        XCTAssertEqual(retried.status.checkpointSequence, try feed().latestSequence)
    }

    func testRejectedCommitThenReopenCannotLeaveAnAcknowledgedPartialPage() async throws {
        let initial = try begin()
        _ = try advance(initial.cursor)
        _ = try capture()
        sqlite3_commit_hook(db, { _ in 1 }, nil)
        XCTAssertThrowsError(try advance(initial.cursor))
        sqlite3_commit_hook(db, nil, nil)
        try await reopen()
        XCTAssertEqual(try status(initial.cursor).checkpointSequence, 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_applied"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work"), 0)
        XCTAssertEqual(try advance(initial.cursor).appliedCount, 1)
    }

    func testLostPageReplyRetryResumesCanonicalNextPageWithoutDuplicateWork() async throws {
        let initial = try begin()
        _ = try advance(initial.cursor)
        let first = try capture()
        let second = try capture()
        _ = try advance(initial.cursor, limit: 1) // Deliberately discard the returned receipt.
        let retry = try advance(initial.cursor, limit: 1)
        XCTAssertEqual(retry.work.map(\.reference), [second])
        XCTAssertEqual(retry.appliedCount, 1)
        let caughtUp = try advance(initial.cursor)
        XCTAssertEqual(caughtUp.inspectedCount, 0)
        XCTAssertEqual(caughtUp.appliedCount, 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_applied"), 2)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work"), 4)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work WHERE frameID=\(first.frameID.value)"), 2)
    }

    func testReviseDeleteAndInsertDuringBootstrapReplayCannotDowngradeOrResurrect() async throws {
        let first = try capture()
        let second = try capture()
        let initial = try begin()
        _ = try advance(initial.cursor, limit: 1)
        _ = try revise(first.frameID, text: "New first revision")
        let latestSecond = try revise(second.frameID, text: "New second revision")
        try execute("DELETE FROM frame WHERE id=\(first.frameID.value)")
        let insertedLater = try capture()
        let lastBootstrap = try advance(initial.cursor, limit: 1)
        XCTAssertEqual(lastBootstrap.work.map(\.reference), [latestSecond])
        XCTAssertLessThanOrEqual(lastBootstrap.status.lastFrameID, initial.maximumFrameID)
        let pages = try drain(initial.cursor, limit: 1)
        XCTAssertTrue(pages.flatMap(\.work).contains { $0.reference == insertedLater })
        let surviving = try workRows(consumer: initial.cursor.consumerID)
        XCTAssertEqual(surviving.filter { $0.frameID == first.frameID.value }.map(\.state), ["deleted", "deleted"])
        XCTAssertEqual(surviving.filter { $0.frameID == second.frameID.value }.map(\.revision),
                       [latestSecond.extractionRevision, latestSecond.extractionRevision])
        XCTAssertEqual(try status(initial.cursor).checkpointSequence, try feed().latestSequence)
    }

    func testSameRevisionRedactionSeenInBootstrapCannotBeUndoneByOlderReplay() async throws {
        let frame = try capture()
        let initial = try begin()
        let revised = try revise(frame.frameID, text: "Retained before redaction")
        try execute("UPDATE frame SET redactionReason='authored protected window' WHERE id=\(frame.frameID.value)")
        let latest = try feed().latestSequence
        let bootstrap = try advance(initial.cursor)
        XCTAssertEqual(bootstrap.work.first?.reference, revised)
        XCTAssertEqual(bootstrap.work.first?.sourceSequence, latest)
        XCTAssertEqual(bootstrap.work.first?.lexicalState, .invalidated)
        XCTAssertEqual(bootstrap.work.first?.vectorState, .invalidated)
        _ = try drain(initial.cursor, limit: 1)
        let rows = try workRows(consumer: initial.cursor.consumerID)
        XCTAssertEqual(rows.map(\.sequence), [latest, latest])
        XCTAssertEqual(rows.map(\.revision), [revised.extractionRevision, revised.extractionRevision])
        XCTAssertEqual(rows.map(\.state), ["invalidated", "invalidated"])
    }

    func testExpiredLeaseIsRecordedAndCannotAdvanceBeforeExplicitRebootstrap() async throws {
        _ = try capture()
        let initial = try begin(lease: 10)
        let later = now.addingTimeInterval(10)
        let expired = try ScreenEvidenceConsumerSQL.status(db, cursor: initial.cursor, now: later)
        XCTAssertEqual(expired.phase, .expired)
        assertFeedError(.cursorExpired) {
            _ = try ScreenEvidenceConsumerSQL.advance(db, cursor: initial.cursor, limit: 1, now: later)
        }
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_consumer WHERE phase='expired'"), 1)
        let renewed = try ScreenEvidenceConsumerSQL.begin(db, consumerID: initial.cursor.consumerID,
            leaseDuration: 60, now: later)
        XCTAssertNotEqual(renewed.cursor.leaseID, initial.cursor.leaseID)
        assertFeedError(.invalidCursor) { _ = try status(initial.cursor) }
    }

    func testCompactionProtectsLiveBootstrapBoundaryAndReplayCheckpoint() async throws {
        let slow = try begin(lease: 10)
        _ = try advance(slow.cursor)
        for _ in 0..<5 { _ = try capture() }
        let bootstrapping = try begin(lease: 600)
        let blocked = try ScreenEvidenceConsumerSQL.compact(db, limit: 2, now: now)
        XCTAssertEqual(blocked.deletedEventCount, 0)
        let allowed = try ScreenEvidenceConsumerSQL.compact(db, limit: 2, now: now.addingTimeInterval(11))
        XCTAssertEqual(allowed.expiredConsumerCount, 1)
        XCTAssertEqual(allowed.deletedEventCount, 2)
        XCTAssertEqual(allowed.feed.retainedThrough, 2)
        XCTAssertEqual(allowed.feed.latestSequence, 5)
        XCTAssertLessThanOrEqual(allowed.feed.retainedThrough, bootstrapping.boundarySequence)
        _ = try ScreenEvidenceConsumerSQL.compact(db, limit: 1000, now: now.addingTimeInterval(11))
        let empty = try feed()
        XCTAssertEqual(empty.latestSequence, 5, "High water survives removal of every retained event")
        XCTAssertEqual(empty.retainedThrough, 5)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_feed"), 0)
        let page = try ScreenEvidenceConsumerSQL.advance(db, cursor: bootstrapping.cursor, limit: 200,
                                                       now: now.addingTimeInterval(11))
        XCTAssertEqual(page.work.count, 5)
    }

    func testCompactionBoundsExpiryMarkingAsWellAsEventDeletion() async throws {
        for _ in 0..<12 { _ = try begin(lease: 1) }
        for _ in 0..<6 { _ = try capture() }
        let result = try ScreenEvidenceConsumerSQL.compact(db, limit: 3, now: now.addingTimeInterval(2))
        XCTAssertLessThanOrEqual(result.expiredConsumerCount, 3)
        XCTAssertGreaterThan(result.expiredConsumerCount, 0)
        XCTAssertLessThanOrEqual(result.deletedEventCount, 3)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_consumer WHERE phase='expired'"),
                       Int64(result.expiredConsumerCount))
    }

    func testRebootstrapAfterDeleteAndCompactionDoesNotExposeOldLeaseWorkOrPurgeIt() async throws {
        let frame = try capture()
        let initial = try begin(lease: 1)
        _ = try advance(initial.cursor)
        try execute("DELETE FROM frame WHERE id=\(frame.frameID.value)")
        _ = try ScreenEvidenceConsumerSQL.compact(db, limit: 1000, now: now.addingTimeInterval(2))
        sqlite3_set_authorizer(db, { _, action, table, _, _, _ in
            if action == SQLITE_DELETE, let table, String(cString: table) == "screen_evidence_work" { return SQLITE_DENY }
            return SQLITE_OK
        }, nil)
        defer { sqlite3_set_authorizer(db, nil, nil) }
        let renewed = try ScreenEvidenceConsumerSQL.begin(db, consumerID: initial.cursor.consumerID,
            leaseDuration: 60, now: now.addingTimeInterval(3))
        let page = try ScreenEvidenceConsumerSQL.advance(db, cursor: renewed.cursor, limit: 1,
                                                       now: now.addingTimeInterval(3))
        XCTAssertTrue(page.work.isEmpty)
        XCTAssertEqual(page.status.phase, .replay)
        XCTAssertNotEqual(renewed.cursor.leaseID, initial.cursor.leaseID)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work"), 2,
                       "Rebootstrap cannot hide an unbounded cascading purge")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work WHERE leaseID='\(renewed.cursor.leaseID)'"), 0)
    }

    func testCheckpointAtFloorIsValidButBehindFloorRequiresExplicitRebootstrap() async throws {
        _ = try capture()
        let initial = try begin()
        _ = try drain(initial.cursor)
        let compacted = try ScreenEvidenceConsumerSQL.compact(db, limit: 1000, now: now)
        XCTAssertEqual(compacted.feed.retainedThrough, try status(initial.cursor).checkpointSequence)
        XCTAssertEqual(try advance(initial.cursor).inspectedCount, 0)
        _ = try capture()
        let head = try feed().latestSequence
        try execute("DELETE FROM screen_evidence_feed WHERE sequence<=\(head)")
        try execute("UPDATE screen_evidence_feed_state SET retainedThrough=\(head) WHERE id=1")
        assertFeedError(.feedGap) { _ = try advance(initial.cursor) }
        let reset = try begin(consumer: initial.cursor.consumerID)
        XCTAssertNotEqual(reset.cursor.leaseID, initial.cursor.leaseID)
        XCTAssertEqual(reset.boundarySequence, head)
    }

    func testMissingInteriorEventCannotBeSilentlySkipped() async throws {
        let initial = try begin()
        _ = try advance(initial.cursor)
        for _ in 0..<3 { _ = try capture() }
        try execute("DELETE FROM screen_evidence_feed WHERE sequence=2")
        assertFeedError(.feedGap) { _ = try advance(initial.cursor) }
        XCTAssertEqual(try scalar("SELECT checkpoint FROM screen_evidence_consumer"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_applied"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work"), 0)
        XCTAssertEqual(try status(initial.cursor).phase, .expired)
        let renewed = try begin(consumer: initial.cursor.consumerID)
        XCTAssertNotEqual(renewed.cursor.leaseID, initial.cursor.leaseID)
        XCTAssertEqual(renewed.boundarySequence, try feed().latestSequence)
    }

    func testMissingOnlyTailEventIsAGapEvenWhenNextSelectReturnsNoRows() async throws {
        let initial = try begin()
        _ = try advance(initial.cursor)
        _ = try capture()
        let published = try feed()
        XCTAssertEqual(published.latestSequence, 1)
        XCTAssertEqual(published.retainedThrough, 0)
        try execute("DELETE FROM screen_evidence_feed WHERE sequence=1")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_feed"), 0)
        assertFeedError(.feedGap) { _ = try advance(initial.cursor) }
        XCTAssertEqual(try scalar("SELECT checkpoint FROM screen_evidence_consumer"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_applied"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work"), 0)
        XCTAssertEqual(try feed().latestSequence, published.latestSequence)
        XCTAssertEqual(try feed().retainedThrough, published.retainedThrough)
        XCTAssertEqual(try status(initial.cursor).phase, .expired)
        let renewed = try begin(consumer: initial.cursor.consumerID)
        XCTAssertNotEqual(renewed.cursor.leaseID, initial.cursor.leaseID)
        XCTAssertEqual(renewed.boundarySequence, published.latestSequence)
    }

    func testSparseLegacyFramesAreNotScannedAndLateMaterializationReplaysBehindCursor() async throws {
        let first = try capture()
        try execute("""
            WITH RECURSIVE rows(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM rows WHERE n<12000)
            INSERT INTO frame(createdAt,imageFileName,segmentId)
            SELECT 1700000000000+n,'',1 FROM rows
            """)
        let last = try capture()
        XCTAssertEqual(last.frameID.value - first.frameID.value, 12_001)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_observation WHERE source='native'"), 2)
        let initial = try begin()
        XCTAssertEqual(try advance(initial.cursor, limit: 1).work.map(\.reference), [first])
        let trace = ConsumerSQLTrace()
        sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
            guard let context, let statement else { return 0 }
            Unmanaged<ConsumerSQLTrace>.fromOpaque(context).takeUnretainedValue().record(OpaquePointer(statement))
            return 0
        }, Unmanaged.passUnretained(trace).toOpaque())
        defer { sqlite3_trace_v2(db, 0, nil, nil) }
        let end = try advance(initial.cursor, limit: 1)
        sqlite3_trace_v2(db, 0, nil, nil)
        XCTAssertEqual(end.work.map(\.reference), [last])
        XCTAssertEqual(end.status.lastFrameID, last.frameID.value)
        XCTAssertLessThan(trace.steps, 20_000, "A materialized keyset page must not scan 12,000 raw legacy frames")

        let oldFrame = FrameID(value: first.frameID.value + 1)
        let materialized = try revise(oldFrame, text: "Authored late materialization behind the bootstrap cursor")
        XCTAssertLessThan(materialized.frameID.value, end.status.lastFrameID)
        XCTAssertGreaterThan(try feed().latestSequence, initial.boundarySequence)
        let replay = try drain(initial.cursor, limit: 1)
        XCTAssertTrue(replay.flatMap(\.work).contains { $0.reference == materialized })
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work WHERE frameID=\(oldFrame.value)"), 2)
        XCTAssertEqual(try status(initial.cursor).checkpointSequence, try feed().latestSequence)
    }

    func testV21MaterializedObservationBootstrapsAtBaselineZeroWithoutInventingFeedEvent() async throws {
        let legacy = try openWriter(at: directory.appendingPathComponent("legacy-v21.sqlite").path)
        defer { XCTAssertEqual(sqlite3_close_v2(legacy), SQLITE_OK) }
        try await installV21(legacy)
        let legacyStore = try RecallSQL.nativeStore(legacy)
        let segment = try AppSegmentQueries.insert(db: legacy, bundleID: "com.test.v21-consumer", startDate: now,
            endDate: now, windowName: "Authored V21 context", browserUrl: nil)
        let retained = try PipelineSQL.transaction(legacy) {
            let descriptor = FrameReference(id: .init(value: 0), timestamp: now, segmentID: .init(value: segment),
                                           frameIndexInSegment: 0, metadata: .empty)
            let id = try FrameQueries.insert(db: legacy, frame: descriptor)
            try ScreenEvidenceSQL.capture(legacy, frameID: id, descriptor: descriptor)
            _ = try ScreenEvidenceSQL.commitLegacyText(legacy, frameID: .init(value: id),
                mainText: "Authored retained extraction before V22", chromeText: nil)
            return try XCTUnwrap(ScreenEvidenceSQL.current(legacy, frameID: .init(value: id), storeID: legacyStore)).ref
        }
        try await MigrationRunner(db: legacy).runMigrations()
        let feed = try ScreenEvidenceFeedSQL.status(legacy)
        XCTAssertEqual(feed.latestSequence, 0)
        XCTAssertEqual(try PipelineSQL.integers(legacy, "SELECT COUNT(*) FROM screen_evidence_source_state"), [0])
        let initial = try ScreenEvidenceConsumerSQL.begin(legacy, consumerID: UUID(), leaseDuration: 60, now: now)
        let page = try ScreenEvidenceConsumerSQL.advance(legacy, cursor: initial.cursor, limit: 1, now: now)
        XCTAssertEqual(initial.boundarySequence, 0)
        XCTAssertEqual(page.work.map(\.reference), [retained])
        XCTAssertEqual(page.work.first?.sourceSequence, 0)
        XCTAssertEqual(page.work.first?.lexicalState, .blocked)
        XCTAssertEqual(page.work.first?.vectorState, .blocked)
        XCTAssertNil(page.work.first?.lexicalReadyRevision)
        XCTAssertNil(page.work.first?.vectorReadyRevision)
        XCTAssertEqual(try PipelineSQL.integers(legacy, "SELECT COUNT(*) FROM screen_evidence_applied"), [0])
        XCTAssertEqual(try PipelineSQL.integers(legacy, "SELECT COUNT(*) FROM screen_evidence_feed"), [0])
    }

    func testKeysetPageDoesNotScanLargeUnrelatedWorkOrDecodeRetainedPayloads() async throws {
        let first = try capture()
        let second = try capture()
        let initial = try begin()
        try execute("""
            WITH RECURSIVE rows(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM rows WHERE n<30000)
            INSERT INTO screen_evidence_work(consumerID,storeID,observationID,frameID,leaseID,channel,
                                            extractionRevision,sourceSequence,state)
            SELECT '\(initial.cursor.consumerID)','\(storeID!)',printf('00000000-0000-0000-0000-%012d',n),n+1000,
                   '\(initial.cursor.leaseID)','lexical',0,0,'blocked' FROM rows
            """)
        let trace = ConsumerSQLTrace()
        sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
            guard let context, let statement else { return 0 }
            Unmanaged<ConsumerSQLTrace>.fromOpaque(context).takeUnretainedValue().record(OpaquePointer(statement))
            return 0
        }, Unmanaged.passUnretained(trace).toOpaque())
        denyContentReads()
        defer { sqlite3_trace_v2(db, 0, nil, nil); sqlite3_set_authorizer(db, nil, nil) }
        let page = try advance(initial.cursor, limit: 2)
        sqlite3_trace_v2(db, 0, nil, nil)
        XCTAssertEqual(page.work.map(\.reference.frameID), [first.frameID, second.frameID])
        XCTAssertLessThan(trace.steps, 20_000, "A two-observation page must not visit all consumer work")
        let observationQueries = trace.statements.filter { $0.lowercased().contains("from screen_observation") }
        XCTAssertFalse(observationQueries.isEmpty)
        for sql in observationQueries {
            let plan = try PipelineSQL.query(db, "EXPLAIN QUERY PLAN \(sql)") { RecallSQL.string($0, 3) }
            XCTAssertFalse(plan.contains { $0.contains("TEMP B-TREE") }, "\(plan)")
            XCTAssertFalse(plan.contains { $0.contains("SCAN screen_observation") }, "\(plan)")
        }
    }

    func testAlreadyCancelledPublicAdvanceCannotWriteWorkOrPosition() async throws {
        let manager = DatabaseManager()
        try await manager.initialize()
        do {
            let initial = try await manager.beginScreenEvidenceBootstrap(consumerID: UUID(), leaseDuration: 60)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await manager.advanceScreenEvidenceConsumer(cursor: initial.cursor, limit: 1)
            }
            do { _ = try await task.value; XCTFail("Expected cancellation before the transaction") }
            catch is CancellationError { }
            let state = try await manager.screenEvidenceConsumerStatus(cursor: initial.cursor)
            XCTAssertEqual(state.phase, .bootstrap)
            XCTAssertEqual(state.lastFrameID, 0)
            try await manager.close()
        } catch {
            try await manager.close()
            throw error
        }
    }

    private func begin(consumer: UUID = UUID(), lease: TimeInterval = 3600) throws -> ScreenEvidenceConsumerStatus {
        try ScreenEvidenceConsumerSQL.begin(db, consumerID: consumer, leaseDuration: lease, now: now)
    }

    private func advance(_ cursor: ScreenEvidenceConsumerCursor, limit: Int = 200) throws -> ScreenEvidenceConsumerPage {
        try ScreenEvidenceConsumerSQL.advance(db, cursor: cursor, limit: limit, now: now)
    }

    private func status(_ cursor: ScreenEvidenceConsumerCursor) throws -> ScreenEvidenceConsumerStatus {
        try ScreenEvidenceConsumerSQL.status(db, cursor: cursor, now: now)
    }

    private func feed() throws -> ScreenEvidenceFeedStatus { try ScreenEvidenceFeedSQL.status(db) }

    private func drain(_ cursor: ScreenEvidenceConsumerCursor, limit: Int = 200) throws -> [ScreenEvidenceConsumerPage] {
        var pages: [ScreenEvidenceConsumerPage] = []
        for _ in 0..<100 {
            let page = try advance(cursor, limit: limit)
            pages.append(page)
            if page.status.phase == .replay && page.inspectedCount == 0 { return pages }
        }
        XCTFail("Bounded authored fixture failed to make cursor progress")
        return pages
    }

    private func capture(text: String? = nil) throws -> ScreenEvidenceRef {
        try PipelineSQL.transaction(db) {
            let descriptor = FrameReference(id: .init(value: 0), timestamp: now, segmentID: .init(value: 1),
                frameIndexInSegment: 0, metadata: FrameMetadata(appBundleID: "com.test.consumer", windowName: "Authored retained context"))
            let id = try FrameQueries.insert(db: db, frame: descriptor)
            try ScreenEvidenceSQL.capture(db, frameID: id, descriptor: descriptor)
            if let text { _ = try ScreenEvidenceSQL.commitLegacyText(db, frameID: .init(value: id), mainText: text, chromeText: nil) }
            return try XCTUnwrap(ScreenEvidenceSQL.current(db, frameID: .init(value: id), storeID: storeID)).ref
        }
    }

    private func revise(_ frameID: FrameID, text: String) throws -> ScreenEvidenceRef {
        try PipelineSQL.transaction(db) {
            _ = try ScreenEvidenceSQL.commitLegacyText(db, frameID: frameID, mainText: text, chromeText: nil)
            return try XCTUnwrap(ScreenEvidenceSQL.current(db, frameID: frameID, storeID: storeID)).ref
        }
    }

    private func importedObservation(collidingWith frameID: FrameID) throws {
        let importedStore = UUID()
        try PipelineSQL.transaction(db) {
            try PipelineSQL.execute(db, "INSERT INTO evidence_store(storeID,source,identity) VALUES(?,'rewind','authored-import')",
                                    [.text(importedStore.uuidString)])
            let frame = FrameReference(id: frameID, timestamp: now, segmentID: .init(value: 1),
                                       frameIndexInSegment: 0, metadata: .empty, source: .rewind)
            let observation = UUID()
            try ScreenEvidenceSQL.insertObservation(db, frame: frame, storeID: importedStore,
                observationID: observation, width: 100, height: 100, legacy: true)
            _ = try ScreenEvidenceSQL.append(db, frame: frame, storeID: importedStore,
                observationID: observation, revision: 0, width: 100, height: 100, text: nil, legacy: true)
        }
    }

    private struct WorkRow {
        let frameID: Int64
        let revision: Int64
        let sequence: Int64
        let state: String
    }

    private func workRows(consumer: UUID) throws -> [WorkRow] {
        try PipelineSQL.query(db, """
            SELECT w.frameID,w.extractionRevision,w.sourceSequence,w.state FROM screen_evidence_work w
            JOIN screen_evidence_consumer c ON c.consumerID=w.consumerID AND c.leaseID=w.leaseID
            WHERE w.consumerID=? ORDER BY w.frameID,w.channel
            """, [.text(consumer.uuidString)]) {
            WorkRow(frameID: sqlite3_column_int64($0, 0), revision: sqlite3_column_int64($0, 1),
                    sequence: sqlite3_column_int64($0, 2), state: RecallSQL.string($0, 3))
        }
    }

    private func denyContentReads() {
        sqlite3_set_authorizer(db, { _, action, table, column, _, _ in
            guard action == SQLITE_READ, let table else { return SQLITE_OK }
            let tableName = String(cString: table).lowercased()
            let columnName = column.map { String(cString: $0).lowercased() } ?? ""
            if tableName == "node" || tableName.hasPrefix("searchranking") || tableName == "doc_segment" { return SQLITE_DENY }
            if tableName == "screen_extraction" && columnName == "payload" { return SQLITE_DENY }
            if tableName == "screen_observation" && columnName == "framepayload" { return SQLITE_DENY }
            return SQLITE_OK
        }, nil)
    }

    private func openWriter(at requestedPath: String? = nil) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        let rc = sqlite3_open_v2(requestedPath ?? path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw DatabaseError.connectionFailed(underlying: "Authored consumer fixture unavailable")
        }
        do {
            try PipelineSQL.execute(pointer, "PRAGMA foreign_keys=ON")
            _ = try PipelineSQL.query(pointer, "PRAGMA journal_mode=WAL") { _ in () }
        }
        catch { sqlite3_close_v2(pointer); throw error }
        sqlite3_busy_timeout(pointer, 100)
        return pointer
    }

    private func assertWriterCanTruncateWAL(_ writer: OpaquePointer, file: StaticString = #filePath,
                                            line: UInt = #line) throws {
        var busyCalls: Int32 = 0
        try withUnsafeMutablePointer(to: &busyCalls) { counter in
            sqlite3_busy_handler(writer, { context, _ in
                guard let context else { return 0 }
                context.assumingMemoryBound(to: Int32.self).pointee += 1
                return 0
            }, counter)
            defer { sqlite3_busy_handler(writer, nil, nil) }
            try PipelineSQL.execute(writer, "INSERT INTO authored_wal_probe(value) VALUES(1)")
            var logFrames: Int32 = -1, checkpointedFrames: Int32 = -1
            XCTAssertEqual(sqlite3_wal_checkpoint_v2(writer, nil, SQLITE_CHECKPOINT_TRUNCATE,
                                                   &logFrames, &checkpointedFrames), SQLITE_OK, file: file, line: line)
            XCTAssertEqual(logFrames, 0, file: file, line: line)
            XCTAssertEqual(checkpointedFrames, 0, file: file, line: line)
        }
        XCTAssertEqual(busyCalls, 0, file: file, line: line)
    }

    private func installV21(_ database: OpaquePointer) async throws {
        try PipelineSQL.execute(database, Schema.createSchemaMigrationsTable)
        let migrations: [any Migration] = [V1_InitialSchema(), V2_UnfinalisedVideoTracking(), V3_TagSystem(),
            V4_DailyMetrics(), V5_FTSUnicode61(), V6_FrameProcessedAt(), V7_FrameRedactionReason(),
            V8_SegmentComments(), V9_SegmentCommentFrameAnchor(), V10_SegmentCommentSearchIndex(),
            V11_SegmentCommentLinkCompositeIndex(), V12_AudioCaptures(), V13_TranscriptionPass(),
            V14_ContextualRefinement(), V15_PipelineVersion(), V16_DictationSessions(), V17_AudioTranscriptMetadata(),
            V18_NodeText(), V19_ProcessingQueueFrameIndex(), V20_OCRBackfillState(), V21_ProgressiveRecall()]
        for migration in migrations {
            try PipelineSQL.execute(database, "BEGIN IMMEDIATE")
            do {
                try await migration.migrate(db: database)
                try PipelineSQL.execute(database, "INSERT INTO schema_migrations(version,applied_at) VALUES(?,?)",
                                        [.integer(Int64(migration.version)), .integer(0)])
                try PipelineSQL.execute(database, "COMMIT")
            } catch {
                try? PipelineSQL.execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    private func reopen() async throws {
        XCTAssertEqual(sqlite3_close_v2(db), SQLITE_OK)
        db = nil
        db = try openWriter()
        try await MigrationRunner(db: db).runMigrations()
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: "authored consumer fixture", underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func scalar(_ sql: String) throws -> Int64 {
        try XCTUnwrap(PipelineSQL.integers(db, sql).first)
    }

    private func assertFeedError(_ expected: ScreenEvidenceFeedError, file: StaticString = #filePath,
                                 line: UInt = #line, _ operation: () throws -> Void) {
        do { try operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch let error as ScreenEvidenceFeedError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("Unexpected \(type(of: error))", file: file, line: line) }
    }
}

private final class ConsumerSQLTrace {
    private(set) var statements: [String] = []
    private(set) var steps = 0

    func record(_ statement: OpaquePointer) {
        guard let sql = sqlite3_expanded_sql(statement) else { return }
        defer { sqlite3_free(sql) }
        statements.append(String(cString: sql))
        steps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
    }
}
