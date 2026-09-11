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
    private let timestamp = Date(timeIntervalSince1970: 1_702_406_400)

    override func setUp() async throws {
        services = ServiceContainer(inMemory: true)
        database = await services.database
        // Initialize only the isolated database. Full service initialization
        // would start storage, capture-related services and retention.
        try await database.initialize()
        let pointer = await database.getConnection()
        let connection = SQLiteConnection(db: try XCTUnwrap(pointer))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameDeletionRouting-\(UUID())").path
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
    func installFrameDeletionFailureTrigger() throws {
        let db = try XCTUnwrap(getConnection())
        let sql = """
            CREATE TRIGGER reject_routing_frame_delete BEFORE DELETE ON frame
            BEGIN SELECT RAISE(ABORT, 'routing delete blocked'); END;
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }
}
