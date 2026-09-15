import Foundation
import Shared
import Database
import Storage
import SQLCipher
import XCTest
@testable import App

/// Authored native SQLite evidence only; these operations never decode recordings.
final class ScreenEvidenceFeedIntegrationTests: XCTestCase {
    private var database: DatabaseManager!
    private var adapter: DataAdapter!
    private var service: ProgressiveRecallService!
    private var connection: OpaquePointer!

    override func setUp() async throws {
        database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        connection = await database.getConnection()
        let pointer = try XCTUnwrap(connection)
        adapter = DataAdapter(retraceConnection: SQLiteConnection(db: pointer),
            retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: "/authored-feed-fixture",
                source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: "/authored-feed-fixture"), database: database)
        service = ProgressiveRecallService(database: database, adapter: adapter,
            configuration: { XCTFail("Feed bookkeeping must not claim a read-time privacy check is an acceptance fence"); return CaptureConfig() },
            imageReader: { _ in XCTFail("Feed bookkeeping must never read pixels"); throw EvidenceUnavailableReason.unsupported })
    }

    override func tearDown() async throws {
        service = nil
        await adapter.shutdown()
        adapter = nil
        try await database.close()
        database = nil
        connection = nil
    }

    func testLocalConsumerResumesDurablyWithoutClaimingEitherIndexReady() async throws {
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_consumer"), 0,
            "Creating the presentation service must not start an automatic consumer")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let segmentID = try await database.insertSegment(bundleID: "com.test.feed", startDate: timestamp,
            endDate: timestamp, windowName: "Authored feed fixture", browserUrl: nil, type: 0)
        _ = try await database.insertFrame(FrameReference(id: .init(value: 0), timestamp: timestamp,
            segmentID: .init(value: segmentID), videoID: .init(value: 0), frameIndexInSegment: 0,
            metadata: FrameMetadata(appBundleID: "com.test.feed", windowName: "Authored feed fixture")))

        let feed = try await service.screenEvidenceFeedStatus(for: .localUser)
        XCTAssertEqual(feed.coverage, .materializedNativeObservations)
        let consumerID = UUID()
        let first = try await service.beginScreenEvidenceBootstrap(consumerID: consumerID, for: .localUser)
        let page = try await service.advanceScreenEvidenceConsumer(cursor: first.cursor, limit: 10, for: .localUser)
        XCTAssertEqual(page.work.count, 1)
        let work = try XCTUnwrap(page.work.first)
        XCTAssertEqual(work.reference.source, .native)
        XCTAssertEqual(work.reference.storeID, feed.storeID)
        XCTAssertEqual(work.lexicalState, .blocked)
        XCTAssertEqual(work.vectorState, .blocked)
        XCTAssertNil(work.lexicalReadyRevision)
        XCTAssertNil(work.vectorReadyRevision)

        let resumed = try await service.beginScreenEvidenceBootstrap(consumerID: consumerID, for: .localUser)
        XCTAssertEqual(resumed.cursor, first.cursor)
        XCTAssertEqual(resumed.lastFrameID, page.status.lastFrameID)
        _ = try await service.advanceScreenEvidenceConsumer(cursor: first.cursor, limit: 10, for: .localUser)
        let empty = try await service.advanceScreenEvidenceConsumer(cursor: first.cursor, limit: 10, for: .localUser)
        XCTAssertEqual(empty.inspectedCount, 0)
        XCTAssertTrue(empty.work.isEmpty)
        let status = try await service.screenEvidenceConsumerStatus(cursor: first.cursor, for: .localUser)
        XCTAssertEqual(status.phase, .replay)
        let compacted = try await service.compactScreenEvidenceFeed(limit: 100, for: .localUser)
        XCTAssertEqual(compacted.feed.latestSequence, feed.latestSequence)

        let metadata = try strings("SELECT metadata FROM daily_metrics WHERE metricType='progressive_recall_action'")
        let events = try metadata.map { value -> [String: Any] in
            let data = try XCTUnwrap(value.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertTrue(events.contains { $0["action"] as? String == "evidenceFeedAdvanced" && $0["outcome"] as? String == "no_results" })
        XCTAssertTrue(events.contains { $0["action"] as? String == "evidenceFeedCompacted" })
        XCTAssertTrue(events.allSatisfy { Set($0.keys) == ["action", "outcome", "count"] })
        XCTAssertFalse(metadata.contains { $0.contains("Authored feed fixture") || $0.contains(consumerID.uuidString) })
    }

    func testAgentIsDeniedBeforeAnyFeedCursorOrSourceLookup() async throws {
        let forged = ScreenEvidenceConsumerCursor(feedID: UUID(), storeID: UUID(), consumerID: UUID(), leaseID: UUID())
        // A closed real writer would fail every attempted lookup. Denial must win.
        try await database.close()
        let audience = EvidenceAudience.agent(clientID: "authored-ungranted-client")
        await assertDenied { _ = try await self.service.screenEvidenceFeedStatus(for: audience) }
        await assertDenied { _ = try await self.service.beginScreenEvidenceBootstrap(consumerID: UUID(), for: audience) }
        await assertDenied { _ = try await self.service.advanceScreenEvidenceConsumer(cursor: forged, for: audience) }
        await assertDenied { _ = try await self.service.screenEvidenceConsumerStatus(cursor: forged, for: audience) }
        await assertDenied { _ = try await self.service.compactScreenEvidenceFeed(for: audience) }
    }

    func testFailedLocalRequestRecordsOnlyCategoricalOutcome() async throws {
        do {
            _ = try await service.beginScreenEvidenceBootstrap(consumerID: UUID(), leaseDuration: .infinity, for: .localUser)
            XCTFail("Expected a bounded lease")
        } catch let error as ScreenEvidenceFeedError {
            XCTAssertEqual(error, .invalidLease)
        }
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM screen_evidence_consumer"), 0)
        let metadata = try strings("SELECT metadata FROM daily_metrics WHERE metricType='progressive_recall_action'")
        let data = try XCTUnwrap(metadata.last?.data(using: .utf8))
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(event["action"] as? String, "evidenceBootstrapRequested")
        XCTAssertEqual(event["outcome"] as? String, "failed")
        XCTAssertEqual(Set(event.keys), ["action", "outcome", "count"])
    }

    private func assertDenied(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected disclosure denial", file: file, line: line) }
        catch let error as EvidenceUnavailableReason { XCTAssertEqual(error, .notPermitted, file: file, line: line) }
        catch { XCTFail("Lookup preceded disclosure denial: \(error)", file: file, line: line) }
    }

    private func scalar(_ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw FixtureError.sql }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw FixtureError.sql }
        return sqlite3_column_int64(statement, 0)
    }

    private func strings(_ sql: String) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw FixtureError.sql }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) { values.append(String(cString: value)) }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw FixtureError.sql }
        return values
    }

    private enum FixtureError: Error { case sql }
}
