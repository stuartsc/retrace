import CoreGraphics
import DatabaseTestSupport
import Foundation
import ImageIO
import Processing
import SQLCipher
import Shared
import XCTest
@testable import Database

/// Real native writer transactions, ordinary-table triggers and private SQLite files.
final class ScreenEvidenceFeedPublicationTests: XCTestCase {
    private var database: DatabaseManager!
    private var db: OpaquePointer!
    private var segmentID: Int64 = 0
    private let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        database = DatabaseManager()
        try await database.initialize()
        let connection = await database.getConnection()
        db = try XCTUnwrap(connection)
        segmentID = try await database.insertSegment(bundleID: "authored.fixture", startDate: capturedAt,
            endDate: capturedAt, windowName: "Private authored title", browserUrl: "https://authored.test/document", type: 0)
    }

    override func tearDown() async throws {
        try await database.close()
        db = nil
    }

    func testCapturePublishesRevisionZeroWithNoCopiedContext() async throws {
        let frame = try await insertFrame()
        let snapshot = try await current(frame)
        let rows = try events()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.kind, "extraction_published")
        XCTAssertEqual(rows.first?.reference, snapshot.ref)
        XCTAssertEqual(snapshot.ref.extractionRevision, 0)
        XCTAssertEqual(try scalar("SELECT latestSequence FROM screen_evidence_feed_state"), rows.last?.sequence)
        XCTAssertEqual(try scalar("SELECT latestSequence FROM screen_evidence_source_state"), rows.last?.sequence)
        let columns = try PipelineSQL.query(db, "PRAGMA table_info(screen_evidence_feed)") { RecallSQL.string($0, 1) }
        XCTAssertEqual(Set(columns), Set(["sequence", "kind", "storeID", "source", "observationID", "frameID", "extractionRevision"]))
        XCTAssertFalse(try rowsAsText("screen_evidence_feed").contains("Private authored title"))
        XCTAssertFalse(try rowsAsText("screen_evidence_source_state").contains("authored.test"))
    }

    func testRenderedOCRPublishesTheExactImmutableRevisionWithFTS() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("feed-rendered-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try RenderedRecallFixture.write(to: directory)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(directory.appendingPathComponent("1700000000.jpeg") as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let frame = try await insertFrame()
        let pixels = Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * image.height)
        let text = try await ProcessingManager().extractText(from: CapturedFrame(timestamp: capturedAt,
            imageData: pixels, width: image.width, height: image.height, bytesPerRow: context.bytesPerRow,
            metadata: frame.metadata))
        XCTAssertTrue(text.fullText.contains("42000"))
        let docID = try await database.commitFrameOCR(frameID: frame.id, text: text,
            frameWidth: image.width, frameHeight: image.height)
        let snapshot = try await current(frame)
        let indexed = try await database.getFTSContent(docid: docID)
        XCTAssertEqual(try events().last?.reference, snapshot.ref)
        XCTAssertEqual(snapshot.text?.fullText, indexed?.mainText)
        XCTAssertEqual(snapshot.text?.fullText, text.fullText)
        XCTAssertEqual(try scalar("SELECT processingStatus FROM frame WHERE id=\(frame.id.value)"), 2)
    }

    func testPublicationFailureRollsBackOCRSearchNodesStatusAndPreferredRevision() async throws {
        let frame = try await insertFrame()
        _ = try await commit(frame, "Retained amount 42000")
        let previous = try await current(frame)
        let previousFeed = try events()
        let previousNodes = try scalar("SELECT COUNT(*) FROM node")
        try PipelineSQL.execute(db, "UPDATE frame SET processingStatus=1 WHERE id=?", [.integer(frame.id.value)])
        try PipelineSQL.execute(db, """
            CREATE TEMP TRIGGER reject_feed BEFORE INSERT ON screen_evidence_feed
            BEGIN SELECT RAISE(ABORT,'authored publication failure'); END
            """)
        do { _ = try await commit(frame, "Must roll back 47000"); XCTFail("Expected publication rejection") }
        catch { XCTAssertTrue(String(describing: error).contains("authored publication failure")) }
        let retained = try await current(frame)
        XCTAssertEqual(retained.ref, previous.ref)
        XCTAssertEqual(retained.text?.fullText, previous.text?.fullText)
        XCTAssertEqual(try events(), previousFeed)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM node"), previousNodes)
        XCTAssertEqual(try scalar("SELECT processingStatus FROM frame WHERE id=\(frame.id.value)"), 1)
        let documentID = try await database.getDocidForFrame(frameId: frame.id.value)
        let doc = try XCTUnwrap(documentID)
        let indexed = try await database.getFTSContent(docid: doc)
        XCTAssertEqual(indexed?.mainText, "Retained amount 42000")
    }

    func testCapturePublicationFailureRollsBackTheFrameAndObservation() async throws {
        try PipelineSQL.execute(db, """
            CREATE TEMP TRIGGER reject_feed BEFORE INSERT ON screen_evidence_feed
            BEGIN SELECT RAISE(ABORT,'capture publication failure'); END
            """)
        do { _ = try await insertFrame(); XCTFail("Expected capture rejection") }
        catch { XCTAssertTrue(String(describing: error).contains("capture publication failure")) }
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM frame"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_observation"), 0)
        XCTAssertEqual(try scalar("SELECT latestSequence FROM screen_evidence_feed_state"), 0)
    }

    func testDownstreamFailureRollsBackAlreadyPublishedFeedStateAndWork() async throws {
        let frame = try await insertFrame()
        let documentID = try await commit(frame, "Retained before downstream failure")
        let previous = try await current(frame)
        try seedBlockedWork(previous)
        let oldFeed = try events()
        let oldState = try rowsAsText("screen_evidence_source_state")
        let oldWork = try rowsAsText("screen_evidence_work")
        let oldHead = try scalar("SELECT latestSequence FROM screen_evidence_feed_state")
        try PipelineSQL.execute(db, """
            CREATE TEMP TRIGGER reject_completed_status BEFORE UPDATE OF processingStatus ON frame
            WHEN NEW.processingStatus=2 BEGIN SELECT RAISE(ABORT,'downstream status failure'); END
            """)
        do { _ = try await commit(frame, "Replacement that must roll back"); XCTFail("Expected downstream failure") }
        catch { XCTAssertTrue(String(describing: error).contains("downstream status failure")) }
        XCTAssertEqual(try events(), oldFeed)
        XCTAssertEqual(try scalar("SELECT latestSequence FROM screen_evidence_feed_state"), oldHead)
        XCTAssertEqual(try rowsAsText("screen_evidence_source_state"), oldState)
        XCTAssertEqual(try rowsAsText("screen_evidence_work"), oldWork)
        let retained = try await current(frame)
        let indexed = try await database.getFTSContent(docid: documentID)
        let nodes = try await database.getNodesWithText(frameID: frame.id, frameWidth: 1920, frameHeight: 1080)
        XCTAssertEqual(retained.ref, previous.ref)
        XCTAssertEqual(indexed?.mainText, "Retained before downstream failure")
        XCTAssertEqual(nodes.map(\.text), ["Retained before downstream failure"])
    }

    func testEmptyFeedPinsNativeStoreAndRejectsSupportedDeletion() async throws {
        let status = try await database.screenEvidenceFeedStatus()
        XCTAssertEqual(status.latestSequence, 0)
        XCTAssertEqual(status.storeID.uuidString, try string("SELECT storeID FROM screen_evidence_feed_state"))
        XCTAssertThrowsError(try PipelineSQL.execute(db, "DELETE FROM evidence_store WHERE source='native'"))
        let unchanged = try await database.screenEvidenceFeedStatus()
        XCTAssertEqual(unchanged.feedID, status.feedID)
        XCTAssertEqual(unchanged.storeID, status.storeID)
    }

    func testCorruptRegistryReplacementCannotRebindAnExistingFeedIdentity() async throws {
        let original = try await database.screenEvidenceFeedStatus()
        // This private fixture intentionally simulates an unsupported writer with
        // foreign keys disabled. A normal writer is rejected by the preceding test.
        try PipelineSQL.execute(db, "PRAGMA foreign_keys=OFF")
        try PipelineSQL.execute(db, "DELETE FROM evidence_store WHERE source='native'")
        let replacement = UUID()
        try PipelineSQL.execute(db, "INSERT INTO evidence_store(storeID,source,identity) VALUES(?,'native','native')",
            [.text(replacement.uuidString)])
        do { _ = try await database.screenEvidenceFeedStatus(); XCTFail("Feed must not adopt another registry identity") }
        catch { XCTAssertEqual(error as? ScreenEvidenceFeedError, .integrityFailure) }
        XCTAssertEqual(try string("SELECT feedID FROM screen_evidence_feed_state"), original.feedID.uuidString)
        XCTAssertEqual(try string("SELECT storeID FROM screen_evidence_feed_state"), original.storeID.uuidString)
    }

    func testLegacyWritersAndDimensionMaterializationEachPublishOnlyNewRevisions() async throws {
        let frame = try await insertFrame()
        let initial = try await current(frame)
        let materialized = try await database.materializeScreenEvidence(frame: frame, storeID: initial.ref.storeID,
            width: 1920, height: 1080, text: nil)
        _ = try await database.materializeScreenEvidence(frame: frame, storeID: initial.ref.storeID,
            width: 1920, height: 1080, text: nil)
        XCTAssertEqual(try events().count, 2, "Repeated materialization is not a new revision")
        XCTAssertEqual(try events().last?.reference, materialized.ref)
        let doc = try await database.insertDocument(IndexedDocument(id: 0, frameID: frame.id,
            timestamp: capturedAt, content: "First legacy text"))
        try await database.updateDocument(id: doc, content: "Changed legacy text")
        _ = try await database.indexFrameText(mainText: "Third legacy text", chromeText: "CHROME",
            windowTitle: "Must not replace capture context", segmentId: segmentID, frameId: frame.id.value)
        let rows = try events()
        XCTAssertEqual(rows.map { $0.reference.extractionRevision }, [0, 1, 2, 3, 4])
        XCTAssertEqual(rows.map(\.kind), Array(repeating: "extraction_published", count: 5))
        let retained = try await database.screenEvidence(initial.ref)
        XCTAssertEqual(retained?.frame.metadata.windowName, "Private authored title")
    }

    func testLegacyNativeMaterializationPublishesButImportedMaterializationDoesNot() async throws {
        let descriptor = descriptor()
        let id = try FrameQueries.insert(db: db, frame: descriptor)
        let frame = reference(id)
        let native = try RecallSQL.nativeStore(db)
        let nativeSnapshot = try await database.materializeScreenEvidence(frame: frame, storeID: native,
            width: 1920, height: 1080, text: extraction(frame, "Legacy native"))
        let importedID = try await database.evidenceStoreID(source: .rewind, identity: "authored-import")
        let importedFrame = FrameReference(id: frame.id, timestamp: capturedAt, segmentID: frame.segmentID,
            frameIndexInSegment: 0, metadata: frame.metadata, source: .rewind)
        _ = try await database.materializeScreenEvidence(frame: importedFrame, storeID: importedID,
            width: 1920, height: 1080, text: nil)
        XCTAssertEqual(try events().map(\.reference), [nativeSnapshot.ref])
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_source_state"), 1)
    }

    func testMediaFailureAndRestorationAdvanceStateWithoutDeletingText() async throws {
        let frame = try await insertFrame()
        _ = try await commit(frame, "Retain this text")
        let snapshot = try await current(frame)
        try await database.recordFrameMediaUnavailable(frameID: frame.id, reason: .recordingMissing)
        let once = try events()
        try await database.recordFrameMediaUnavailable(frameID: frame.id, reason: .recordingMissing)
        XCTAssertEqual(try events(), once, "Observation timestamp refresh alone must not republish")
        XCTAssertEqual(once.last?.kind, "media_unavailable")
        XCTAssertEqual(once.last?.reference, snapshot.ref)
        XCTAssertEqual(try string("SELECT mediaUnavailableReason FROM screen_evidence_source_state"), "recordingMissing")
        _ = try await commit(frame, "Retain this text")
        let restored = try await current(frame)
        XCTAssertEqual(try events().suffix(2).map(\.kind), ["extraction_published", "media_restored"])
        XCTAssertEqual(try events().last?.reference, restored.ref)
        XCTAssertEqual(try scalar("SELECT mediaUnavailableReason IS NULL FROM screen_evidence_source_state"), 1)
        let retained = try await database.screenEvidence(snapshot.ref)
        XCTAssertEqual(retained?.text?.fullText, "Retain this text")
    }

    func testMediaLinkAndRedactionChangesInvalidateBothChannelsImmediately() async throws {
        let frame = try await insertFrame()
        let snapshot = try await current(frame)
        try seedBlockedWork(snapshot)
        let videoID = try await insertVideo()
        try await database.updateFrameVideoLink(frameID: frame.id, videoID: VideoSegmentID(value: videoID), frameIndex: 0)
        let linked = try events()
        XCTAssertEqual(linked.last?.kind, "media_link_changed")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work WHERE state='invalidated'"), 2)
        try await database.updateFrameVideoLink(frameID: frame.id, videoID: VideoSegmentID(value: videoID), frameIndex: 0)
        XCTAssertEqual(try events(), linked)
        try PipelineSQL.execute(db, "UPDATE screen_evidence_work SET state='blocked'")
        try PipelineSQL.execute(db, "UPDATE frame SET redactionReason='authored privacy rule' WHERE id=?", [.integer(frame.id.value)])
        XCTAssertEqual(try events().last?.kind, "redaction_changed")
        XCTAssertEqual(try events().last?.reference, snapshot.ref)
        XCTAssertEqual(try scalar("SELECT redacted FROM screen_evidence_source_state"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work WHERE state='invalidated'"), 2)
        try PipelineSQL.execute(db, "UPDATE frame SET redactionReason=NULL WHERE id=?", [.integer(frame.id.value)])
        XCTAssertEqual(try scalar("SELECT redacted FROM screen_evidence_source_state"), 0)
        XCTAssertFalse(try rowsAsText("screen_evidence_feed").contains("authored privacy rule"))
    }

    func testVideoFactsAdvanceOnlyLinkedMaterializedNativeState() async throws {
        let frame = try await insertFrame()
        let videoID = try await insertVideo()
        try await database.updateFrameVideoLink(frameID: frame.id, videoID: VideoSegmentID(value: videoID), frameIndex: 0)
        let before = try events()
        try PipelineSQL.execute(db, "UPDATE video SET path='authored-recovered.mp4' WHERE id=?", [.integer(videoID)])
        XCTAssertEqual(try events().count, before.count + 1)
        XCTAssertEqual(try events().last?.kind, "media_link_changed")
        let unchanged = try events()
        try PipelineSQL.execute(db, "UPDATE video SET path=path,fileSize=fileSize+1 WHERE id=?", [.integer(videoID)])
        XCTAssertEqual(try events(), unchanged, "Unchanged media identity and size-only bookkeeping are not source changes")
    }

    func testDeletionRoutesPublishOneTombstoneAndCannotRestoreCascadeState() async throws {
        for route in ["direct", "retention", "video", "segment"] {
            let frame = try await insertFrame()
            let snapshot = try await current(frame)
            try seedBlockedWork(snapshot)
            try await database.recordFrameMediaUnavailable(frameID: frame.id, reason: .integrityFailure)
            let importedStore = try await database.evidenceStoreID(source: .rewind, identity: "import-\(route)")
            let imported = FrameReference(id: frame.id, timestamp: capturedAt, segmentID: frame.segmentID,
                frameIndexInSegment: 0, metadata: .empty, source: .rewind)
            let other = try await database.materializeScreenEvidence(frame: imported, storeID: importedStore,
                width: 1920, height: 1080, text: nil)
            switch route {
            case "direct": try await database.deleteFrame(id: frame.id)
            case "retention": _ = try await database.performRetentionBatch(olderThan: capturedAt.addingTimeInterval(1))
            case "video":
                let videoID = try await insertVideo()
                try await database.updateFrameVideoLink(frameID: frame.id, videoID: VideoSegmentID(value: videoID), frameIndex: 0)
                try await database.deleteVideoSegment(id: VideoSegmentID(value: videoID))
            default: try PipelineSQL.execute(db, "DELETE FROM segment WHERE id=?", [.integer(segmentID)])
            }
            let rows = try events().filter { $0.reference.observationID == snapshot.ref.observationID }
            XCTAssertEqual(rows.filter { $0.kind == "deleted" }.count, 1, route)
            XCTAssertEqual(rows.last?.kind, "deleted", "Cascade cleanup cannot publish restoration after deletion")
            XCTAssertEqual(try scalar("SELECT deleted FROM screen_evidence_source_state WHERE observationID='\(snapshot.ref.observationID)'"), 1)
            XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work WHERE observationID='\(snapshot.ref.observationID)' AND state='deleted'"), 2)
            let retainedImport = try await database.screenEvidence(other.ref)
            XCTAssertNotNil(retainedImport)
            if route == "retention" {
                segmentID = try await database.insertSegment(bundleID: "authored.fixture", startDate: capturedAt,
                    endDate: capturedAt, windowName: "Replacement fixture segment", browserUrl: nil, type: 0)
            }
        }
    }

    func testDeletionPublicationFailureRollsBackCanonicalRowsAndWork() async throws {
        let frame = try await insertFrame()
        let snapshot = try await current(frame)
        try seedBlockedWork(snapshot)
        try PipelineSQL.execute(db, """
            CREATE TEMP TRIGGER reject_tombstone BEFORE INSERT ON screen_evidence_feed
            WHEN NEW.kind='deleted' BEGIN SELECT RAISE(ABORT,'tombstone failure'); END
            """)
        do { try await database.deleteFrame(id: frame.id); XCTFail("Expected deletion rollback") }
        catch { XCTAssertTrue(String(describing: error).contains("tombstone failure")) }
        let retained = try await database.screenEvidence(snapshot.ref)
        XCTAssertNotNil(retained)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_deleted"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_work WHERE state='blocked'"), 2)
    }

    func testNativeIdentityEditsAreRejectedWhileImportedRegistryIsUnaffected() async throws {
        let frame = try await insertFrame()
        let snapshot = try await current(frame)
        let originalEvents = try events()
        XCTAssertThrowsError(try PipelineSQL.execute(db, "UPDATE frame SET createdAt=createdAt+1 WHERE id=?", [.integer(frame.id.value)]))
        for assignment in ["observationID='replacement'", "storeID='replacement'", "source='rewind'", "frameID=frameID+1", "nativeFrameID=NULL"] {
            XCTAssertThrowsError(try PipelineSQL.execute(db, "UPDATE screen_observation SET \(assignment) WHERE observationID=?", [.text(snapshot.ref.observationID.uuidString)]))
        }
        XCTAssertThrowsError(try PipelineSQL.execute(db, "UPDATE evidence_store SET identity='replacement' WHERE source='native'"))
        let importedStore = try await database.evidenceStoreID(source: .rewind, identity: "imported-identity")
        try PipelineSQL.execute(db, "UPDATE evidence_store SET identity='authored-import-replacement' WHERE storeID=?", [.text(importedStore.uuidString)])
        XCTAssertEqual(try events(), originalEvents)
        let retained = try await database.screenEvidence(snapshot.ref)
        XCTAssertEqual(retained?.frame.timestamp, capturedAt)
    }

    func testOlderExtractionInsertionCannotDowngradeCurrentSourceRevision() async throws {
        let frame = try await insertFrame()
        let initial = try await current(frame)
        try PipelineSQL.transaction(db) {
            _ = try ScreenEvidenceSQL.append(db, frame: frame, storeID: initial.ref.storeID,
                observationID: initial.ref.observationID, revision: 7, width: 1920, height: 1080,
                text: extraction(frame, "Latest retained revision"), legacy: true)
        }
        let latest = try await current(frame)
        let older = ScreenEvidenceSnapshot(ref: ScreenEvidenceRef(storeID: initial.ref.storeID, source: .native,
            observationID: initial.ref.observationID, frameID: frame.id, extractionRevision: 3), frame: frame,
            width: 1920, height: 1080, text: extraction(frame, "Late historical insertion"), legacyContext: true,
            highlightsVerified: false)
        try PipelineSQL.execute(db, "INSERT INTO screen_extraction(observationID,revision,payload) VALUES(?,?,?)", [
            .text(initial.ref.observationID.uuidString), .integer(3), .text(try RecallSQL.encode(older))
        ])
        XCTAssertEqual(try scalar("SELECT extractionRevision FROM screen_evidence_source_state"), 7)
        let retained = try await current(frame)
        XCTAssertEqual(retained.ref, latest.ref)
    }

    func testV22MigrationIsAdditiveBoundedAndPreservesV21PayloadBytes() async throws {
        let fixture = try FeedPublicationDiskFixture()
        defer { fixture.close() }
        try await installV21(fixture.db)
        let frame = try seedRawFrame(fixture.db)
        let store = try RecallSQL.nativeStore(fixture.db)
        let before = try ScreenEvidenceSQL.current(fixture.db, frameID: frame.id, storeID: store)
        let bytes = try rawPayload(fixture.db)
        try PipelineSQL.execute(fixture.db, """
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<20000)
            INSERT INTO frame(createdAt,imageFileName,processingStatus) SELECT x,'authored-legacy',0 FROM n
            """)
        let trace = FeedPublicationTrace()
        sqlite3_trace_v2(fixture.db, UInt32(SQLITE_TRACE_PROFILE), FeedPublicationTrace.callback,
            Unmanaged.passUnretained(trace).toOpaque())
        defer { sqlite3_trace_v2(fixture.db, 0, nil, nil) }
        // Keep this historical upgrade fixture pinned to V22 even after later
        // migrations are registered. Its VM budget measures this migration only.
        try PipelineSQL.execute(fixture.db, "BEGIN IMMEDIATE")
        do {
            try await V22_ScreenEvidenceFeed().migrate(db: fixture.db)
            try PipelineSQL.execute(fixture.db, "INSERT INTO schema_migrations(version,applied_at) VALUES(22,0)")
            try PipelineSQL.execute(fixture.db, "COMMIT")
        } catch {
            try? PipelineSQL.execute(fixture.db, "ROLLBACK")
            throw error
        }
        sqlite3_trace_v2(fixture.db, 0, nil, nil)
        XCTAssertEqual(try rawScalar(fixture.db, "SELECT MAX(version) FROM schema_migrations"), 22)
        XCTAssertEqual(try rawPayload(fixture.db), bytes)
        XCTAssertEqual(try ScreenEvidenceSQL.current(fixture.db, frameID: frame.id, storeID: store)?.ref, before?.ref)
        XCTAssertEqual(try rawScalar(fixture.db, "SELECT COUNT(*) FROM screen_evidence_feed"), 0)
        XCTAssertEqual(try rawScalar(fixture.db, "SELECT COUNT(*) FROM screen_evidence_source_state"), 0)
        XCTAssertEqual(try rawScalar(fixture.db, "SELECT COUNT(*) FROM screen_observation"), 1)
        XCTAssertLessThan(trace.steps, 30_000, "Migration must not scale with retained frame/extraction rows")
        let feedID = try rawString(fixture.db, "SELECT feedID FROM screen_evidence_feed_state")
        try await MigrationRunner(db: fixture.db).runMigrations()
        XCTAssertEqual(try rawScalar(fixture.db, "SELECT MAX(version) FROM schema_migrations"), 23)
        try await MigrationRunner(db: fixture.db).runMigrations()
        XCTAssertEqual(try rawString(fixture.db, "SELECT feedID FROM screen_evidence_feed_state"), feedID)
    }

    func testReopenedV21ShapedWriterPublishesAndDefensiveReaderSeesOnlyCommit() async throws {
        let fixture = try FeedPublicationDiskFixture()
        defer { fixture.close() }
        try await installV21(fixture.db)
        let frame = try seedRawFrame(fixture.db)
        try await MigrationRunner(db: fixture.db).runMigrations()
        let writer = try fixture.open(SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close_v2(writer) }
        try PipelineSQL.execute(writer, "PRAGMA foreign_keys=ON")
        let reader = try fixture.open(SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close_v2(reader) }
        var enabled: Int32 = 0
        XCTAssertEqual(retrace_test_enable_defensive(reader, &enabled), SQLITE_OK)
        XCTAssertEqual(enabled, 1)
        XCTAssertEqual(try rawScalar(reader, "SELECT MAX(version) FROM schema_migrations"), 23)
        try PipelineSQL.execute(writer, "BEGIN IMMEDIATE")
        _ = try ScreenEvidenceSQL.commitLegacyText(writer, frameID: frame.id, mainText: "V21 writer new revision", chromeText: nil)
        XCTAssertEqual(try rawScalar(reader, "SELECT COUNT(*) FROM screen_evidence_feed"), 0)
        XCTAssertEqual(try rawScalar(writer, "SELECT COUNT(*) FROM screen_evidence_feed"), 1)
        try PipelineSQL.execute(writer, "COMMIT")
        XCTAssertEqual(try rawScalar(reader, "SELECT COUNT(*) FROM screen_evidence_feed"), 1)
        try PipelineSQL.execute(writer, "BEGIN IMMEDIATE")
        _ = try ScreenEvidenceSQL.commitLegacyText(writer, frameID: frame.id, mainText: "Rolled back revision", chromeText: nil)
        try PipelineSQL.execute(writer, "ROLLBACK")
        XCTAssertEqual(try rawScalar(reader, "SELECT COUNT(*) FROM screen_evidence_feed"), 1)
        XCTAssertEqual(try rawScalar(reader, "SELECT COUNT(*) FROM sqlite_schema WHERE type='trigger' AND tbl_name='searchRanking_content'"), 0)
    }

    private struct Event: Equatable {
        let sequence: Int64
        let kind: String
        let reference: ScreenEvidenceRef
    }

    private func events() throws -> [Event] {
        try PipelineSQL.query(db, "SELECT sequence,kind,storeID,source,observationID,frameID,extractionRevision FROM screen_evidence_feed ORDER BY sequence") {
            Event(sequence: sqlite3_column_int64($0, 0), kind: RecallSQL.string($0, 1),
                reference: ScreenEvidenceRef(storeID: try XCTUnwrap(UUID(uuidString: RecallSQL.string($0, 2))),
                    source: try XCTUnwrap(FrameSource(rawValue: RecallSQL.string($0, 3))),
                    observationID: try XCTUnwrap(UUID(uuidString: RecallSQL.string($0, 4))),
                    frameID: FrameID(value: sqlite3_column_int64($0, 5)), extractionRevision: sqlite3_column_int64($0, 6)))
        }
    }

    private func descriptor() -> FrameReference {
        FrameReference(id: FrameID(value: 0), timestamp: capturedAt, segmentID: AppSegmentID(value: segmentID),
            frameIndexInSegment: 0, metadata: FrameMetadata(appBundleID: "authored.fixture",
                windowName: "Private authored title", browserURL: "https://authored.test/document"), source: .native)
    }

    private func reference(_ id: Int64) -> FrameReference {
        let original = descriptor()
        return FrameReference(id: FrameID(value: id), timestamp: original.timestamp, segmentID: original.segmentID,
            frameIndexInSegment: original.frameIndexInSegment, metadata: original.metadata, source: .native)
    }

    private func insertFrame() async throws -> FrameReference { reference(try await database.insertFrame(descriptor())) }
    private func current(_ frame: FrameReference) async throws -> ScreenEvidenceSnapshot {
        let snapshot = try await database.currentScreenEvidence(frameID: frame.id, storeID: RecallSQL.nativeStore(db))
        return try XCTUnwrap(snapshot)
    }
    private func extraction(_ frame: FrameReference, _ text: String) -> ExtractedText {
        ExtractedText(frameID: frame.id, timestamp: capturedAt,
            regions: [TextRegion(frameID: frame.id, text: text, bounds: CGRect(x: 30, y: 40, width: 900, height: 50))],
            fullText: text, metadata: frame.metadata)
    }
    private func commit(_ frame: FrameReference, _ text: String) async throws -> Int64 {
        try await database.commitFrameOCR(frameID: frame.id, text: extraction(frame, text), frameWidth: 1920, frameHeight: 1080)
    }
    private func insertVideo() async throws -> Int64 {
        try await database.insertVideoSegment(VideoSegment(id: VideoSegmentID(value: 0), startTime: capturedAt,
            endTime: capturedAt, frameCount: 1, fileSizeBytes: 100, relativePath: "authored-\(UUID()).mp4", width: 1920, height: 1080))
    }
    private func scalar(_ sql: String) throws -> Int64 { try rawScalar(db, sql) }
    private func string(_ sql: String) throws -> String { try rawString(db, sql) }
    private func rawScalar(_ db: OpaquePointer, _ sql: String) throws -> Int64 { try XCTUnwrap(PipelineSQL.integers(db, sql).first) }
    private func rawString(_ db: OpaquePointer, _ sql: String) throws -> String {
        try XCTUnwrap(PipelineSQL.query(db, sql) { RecallSQL.string($0, 0) }.first)
    }
    private func rowsAsText(_ table: String) throws -> String {
        try PipelineSQL.query(db, "SELECT * FROM \(table)") { row in
            (0..<sqlite3_column_count(row)).map { RecallSQL.string(row, $0) }.joined(separator: "|")
        }.joined(separator: "\n")
    }
    private func rawPayload(_ db: OpaquePointer) throws -> String {
        try rawString(db, "SELECT payload FROM screen_extraction ORDER BY observationID,revision LIMIT 1")
    }

    private func seedBlockedWork(_ snapshot: ScreenEvidenceSnapshot) throws {
        let consumer = UUID().uuidString, lease = UUID().uuidString
        try PipelineSQL.execute(db, """
            INSERT INTO screen_evidence_consumer(consumerID,feedID,storeID,leaseID,phase,bootstrapBoundary,maxFrameID,lastFrameID,checkpoint,expiresAt)
            SELECT ?,feedID,?,?,'replay',latestSequence,?, ?,latestSequence,? FROM screen_evidence_feed_state
            """, [.text(consumer), .text(snapshot.ref.storeID.uuidString), .text(lease),
                .integer(snapshot.ref.frameID.value), .integer(snapshot.ref.frameID.value), .real(Date().timeIntervalSince1970 + 3600)])
        for channel in ["lexical", "vector"] {
            try PipelineSQL.execute(db, """
                INSERT INTO screen_evidence_work(consumerID,storeID,observationID,frameID,leaseID,channel,extractionRevision,sourceSequence,state)
                SELECT ?,?,?,?,?,?,?,latestSequence,'blocked' FROM screen_evidence_feed_state
                """, [.text(consumer), .text(snapshot.ref.storeID.uuidString), .text(snapshot.ref.observationID.uuidString),
                    .integer(snapshot.ref.frameID.value), .text(lease), .text(channel), .integer(snapshot.ref.extractionRevision)])
        }
    }

    private func seedRawFrame(_ db: OpaquePointer) throws -> FrameReference {
        let segment = try AppSegmentQueries.insert(db: db, bundleID: "authored.raw", startDate: capturedAt,
            endDate: capturedAt, windowName: "V21 retained context", browserUrl: nil)
        let descriptor = FrameReference(id: FrameID(value: 0), timestamp: capturedAt,
            segmentID: AppSegmentID(value: segment), frameIndexInSegment: 0, metadata: .empty, source: .native)
        return try PipelineSQL.transaction(db) {
            let id = try FrameQueries.insert(db: db, frame: descriptor)
            try ScreenEvidenceSQL.capture(db, frameID: id, descriptor: descriptor)
            return try XCTUnwrap(FrameQueries.getByID(db: db, id: FrameID(value: id)))
        }
    }

    private func installV21(_ db: OpaquePointer) async throws {
        try PipelineSQL.execute(db, Schema.createSchemaMigrationsTable)
        let migrations: [any Migration] = [V1_InitialSchema(), V2_UnfinalisedVideoTracking(), V3_TagSystem(),
            V4_DailyMetrics(), V5_FTSUnicode61(), V6_FrameProcessedAt(), V7_FrameRedactionReason(),
            V8_SegmentComments(), V9_SegmentCommentFrameAnchor(), V10_SegmentCommentSearchIndex(),
            V11_SegmentCommentLinkCompositeIndex(), V12_AudioCaptures(), V13_TranscriptionPass(),
            V14_ContextualRefinement(), V15_PipelineVersion(), V16_DictationSessions(), V17_AudioTranscriptMetadata(),
            V18_NodeText(), V19_ProcessingQueueFrameIndex(), V20_OCRBackfillState(), V21_ProgressiveRecall()]
        for migration in migrations {
            try PipelineSQL.execute(db, "BEGIN IMMEDIATE")
            do {
                try await migration.migrate(db: db)
                try PipelineSQL.execute(db, "INSERT INTO schema_migrations(version,applied_at) VALUES(?,?)", [.integer(Int64(migration.version)), .integer(0)])
                try PipelineSQL.execute(db, "COMMIT")
            } catch {
                try? PipelineSQL.execute(db, "ROLLBACK")
                throw error
            }
        }
    }
}

private final class FeedPublicationDiskFixture {
    let directory: URL
    private(set) var db: OpaquePointer!
    private var path: String { directory.appendingPathComponent("authored.sqlite").path }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("feed-publication-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            db = try open(SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
            try PipelineSQL.execute(db, "PRAGMA foreign_keys=ON")
            _ = try PipelineSQL.query(db, "PRAGMA journal_mode=WAL") { RecallSQL.string($0, 0) }
        } catch { close(); throw error }
    }

    func open(_ flags: Int32) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(path, &pointer, flags, nil)
        guard result == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw DatabaseError.connectionFailed(underlying: "Authored fixture open failed: \(result)")
        }
        return pointer
    }

    func close() {
        if let db { sqlite3_close_v2(db); self.db = nil }
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class FeedPublicationTrace {
    var steps = 0
    static let callback: @convention(c) (UInt32, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32 = { _, context, statement, _ in
        guard let context, let statement else { return 0 }
        let trace = Unmanaged<FeedPublicationTrace>.fromOpaque(context).takeUnretainedValue()
        trace.steps += Int(sqlite3_stmt_status(OpaquePointer(statement), SQLITE_STMTSTATUS_VM_STEP, 0))
        return 0
    }
}
