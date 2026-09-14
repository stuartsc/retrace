import Foundation
import XCTest
import Shared
import Database
import Storage
import SQLCipher
@testable import App

final class FrameDeletionRoutingTests: XCTestCase {
    private var services: ServiceContainer!
    private var coordinator: AppCoordinator!
    private var database: DatabaseManager!
    private var adapter: DataAdapter!
    private var storageRoot: URL!
    private let timestamp = Date(timeIntervalSince1970: 1_702_406_400)

    override func setUp() async throws {
        storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FrameDeletionRouting-\(UUID())")
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        services = ServiceContainer(databasePath: storageRoot.appendingPathComponent("test.db").path,
            storageConfig: StorageConfig(storageRootPath: storageRoot.path))
        database = await services.database
        // Initialize only the isolated database. Full service initialization
        // would start storage, capture-related services and retention.
        try await database.initialize()
        let connection = try await database.makeRecallReadConnection()
        XCTAssertEqual(sqlite3_db_readonly(connection.getConnection(), "main"), 1)
        let root = storageRoot.path
        adapter = DataAdapter(
            retraceConnection: connection,
            retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: root, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root),
            database: database
        )
        try await adapter.initialize()
        await services.installFrameDeletionTestAdapter(adapter)
        coordinator = AppCoordinator(services: services)
    }

    override func tearDown() async throws {
        await adapter?.shutdown()
        try await database?.close()
        coordinator = nil
        adapter = nil
        database = nil
        services = nil
        try FileManager.default.removeItem(at: storageRoot)
    }

    func testNativeDeletionWithAdapterCleansIndexNodesAndQueueAndPreservesSameTimestampNeighbor() async throws {
        let selected = try await insertIndexedQueuedFrame(text: "routingselected", index: 0)
        let neighbor = try await insertIndexedQueuedFrame(text: "routingneighbor", index: 1)
        try await assertStoredFrame(selected, content: "routingselected")
        try await assertStoredFrame(neighbor, content: "routingneighbor")

        try await coordinator.deleteFrame(frameID: selected, timestamp: timestamp, source: .native)

        let frame = try await database.getFrame(id: selected)
        let document = try await database.getDocument(frameID: selected)
        let nodes = try await database.getNodes(frameID: selected, frameWidth: 640, frameHeight: 360)
        let queuePosition = try await database.getFrameQueuePosition(frameID: selected.value)
        let statistics = try await database.getStatistics()
        XCTAssertNil(frame)
        XCTAssertNil(document)
        XCTAssertTrue(nodes.isEmpty)
        XCTAssertNil(queuePosition)
        XCTAssertEqual(statistics.documentCount, 1, "The deleted frame must not leave an orphaned FTS row")
        try await assertStoredFrame(neighbor, content: "routingneighbor")
    }

    func testNativeDeletionWithAdapterPropagatesSQLiteFailureAndRollsBackCleanup() async throws {
        let selected = try await insertIndexedQueuedFrame(text: "routingrollback", index: 0)
        try await database.installFrameDeletionFailureTrigger()

        do {
            try await coordinator.deleteFrame(frameID: selected, timestamp: timestamp, source: .native)
            XCTFail("The timeline needs the deletion error so it can restore its staged frame")
        } catch {
            // The trigger rejects the final frame delete after earlier cleanup.
        }

        try await assertStoredFrame(selected, content: "routingrollback")
        let statistics = try await database.getStatistics()
        XCTAssertEqual(statistics.documentCount, 1)
    }

    func testAdapterNativeDeletionUsesCanonicalWriterDespiteReadOnlySearchConnection() async throws {
        let selected = try await insertIndexedQueuedFrame(text: "canonicalwriter", index: 0)
        try await adapter.deleteFrame(frameID: selected, source: .native)
        let frame = try await database.getFrame(id: selected)
        let document = try await database.getDocument(frameID: selected)
        let queue = try await database.getFrameQueuePosition(frameID: selected.value)
        XCTAssertNil(frame)
        XCTAssertNil(document)
        XCTAssertNil(queue)
    }

    func testAdapterBulkDeletionRollsBackAllSelectedFrames() async throws {
        let first = try await insertIndexedQueuedFrame(text: "firstbulk", index: 0)
        let second = try await insertIndexedQueuedFrame(text: "secondbulk", index: 1)
        try await database.installFrameDeletionFailureTrigger(only: second)
        do {
            try await adapter.deleteFrames([(first, .native), (second, .native)])
            XCTFail("A failed deletion must not report success or leave a partly deleted selection")
        } catch {}
        try await assertStoredFrame(first, content: "firstbulk")
        try await assertStoredFrame(second, content: "secondbulk")
    }

    func testDisconnectedImportedSourceNeverDeletesSameNativeID() async throws {
        let selected = try await insertIndexedQueuedFrame(text: "sourcecollision", index: 0)
        do {
            try await adapter.deleteFrame(frameID: selected, source: .rewind)
            XCTFail("Disconnected source must remain explicit")
        } catch DataAdapterError.sourceNotAvailable(.rewind) {
        } catch { XCTFail("Expected requested-source failure, received \(type(of: error))") }
        try await assertStoredFrame(selected, content: "sourcecollision")
    }

    private func insertIndexedQueuedFrame(text: String, index: Int) async throws -> FrameID {
        let sessionID = try await database.insertSegment(bundleID: "com.test.routing", startDate: timestamp,
            endDate: timestamp.addingTimeInterval(2), windowName: "Deletion routing", browserUrl: nil, type: 0)
        let frameID = FrameID(value: try await database.insertFrame(FrameReference(
            id: FrameID(value: 0), timestamp: timestamp, segmentID: AppSegmentID(value: sessionID),
            videoID: VideoSegmentID(value: 0), frameIndexInSegment: index, metadata: .empty
        )))
        try await database.markFrameReadable(frameID: frameID.value)
        let extracted = ExtractedText(frameID: frameID, timestamp: timestamp, regions: [
            TextRegion(frameID: frameID, text: text, bounds: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1))
        ])
        _ = try await database.commitFrameOCR(frameID: frameID, text: extracted, frameWidth: 640, frameHeight: 360)
        // A queued reprocessing attempt must be removed along with indexed text.
        try await database.updateFrameProcessingStatus(frameID: frameID.value, status: 0)
        let enqueued = try await database.enqueueFrameForProcessing(frameID: frameID.value)
        XCTAssertTrue(enqueued)
        return frameID
    }

    private func assertStoredFrame(_ id: FrameID, content: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let frame = try await database.getFrame(id: id)
        let document = try await database.getDocument(frameID: id)
        let nodes = try await database.getNodes(frameID: id, frameWidth: 640, frameHeight: 360)
        let queuePosition = try await database.getFrameQueuePosition(frameID: id.value)
        XCTAssertEqual(frame?.id, id, file: file, line: line)
        XCTAssertEqual(document?.content, content, file: file, line: line)
        XCTAssertEqual(nodes.count, 1, file: file, line: line)
        XCTAssertNotNil(queuePosition, file: file, line: line)
    }
}

private extension ServiceContainer {
    func installFrameDeletionTestAdapter(_ adapter: DataAdapter) {
        dataAdapter = adapter
    }
}

private extension DatabaseManager {
    func installFrameDeletionFailureTrigger(only frameID: FrameID? = nil) throws {
        let db = try XCTUnwrap(getConnection())
        let sql = """
            CREATE TRIGGER reject_routing_frame_delete BEFORE DELETE ON frame
            \(frameID.map { "WHEN OLD.id = \($0.value)" } ?? "")
            BEGIN SELECT RAISE(ABORT, 'routing delete blocked'); END;
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }
}
