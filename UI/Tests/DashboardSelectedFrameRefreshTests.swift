import XCTest
import Foundation
import Shared
import Database
import SQLCipher
@testable import Retrace

@MainActor
final class DashboardSelectedFrameRefreshTests: XCTestCase {
    func testSelectedOlderFramePublishesCompletedSQLiteOCRWithoutChangingSelectionOrOrder() async throws {
        let database = DatabaseManager(databasePath: "file:dashboard_selected_\(UUID().uuidString)?mode=memory&cache=private")
        try await database.initialize()
        let start = Date().addingTimeInterval(-120)
        let segment = try await database.insertSegment(bundleID: "com.test.dashboard", startDate: start, endDate: start.addingTimeInterval(30), windowName: "Selected history", browserUrl: nil, type: 0)
        for index in 0..<21 {
            let id = try await database.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: start.addingTimeInterval(Double(index)), segmentID: AppSegmentID(value: segment), frameIndexInSegment: index, metadata: FrameMetadata(appBundleID: "com.test.dashboard")))
            try await database.markFrameReadable(frameID: id)
        }
        var frames = try await database.getMostRecentFramesWithVideoInfo(limit: 30)
        let selected = try XCTUnwrap(frames.last)
        let selectedID = selected.frame.id.value
        let originalOrder = frames.map(\.frame.id)
        var cachedNodes: [Int64: [OCRNodeWithText]] = [selectedID: []]
        var loadedStatuses = [selectedID: 0]
        let text = ExtractedText(frameID: selected.frame.id, timestamp: selected.frame.timestamp, regions: [TextRegion(frameID: selected.frame.id, text: "Selected screenshot became searchable", bounds: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.1))])
        _ = try await database.commitFrameOCR(frameID: selected.frame.id, text: text, frameWidth: 640, frameHeight: 360)
        let latest = try await database.getMostRecentFramesWithVideoInfo(limit: DashboardLiveLayoutPolicy.screenshotPageSize)
        XCTAssertFalse(latest.contains { $0.frame.id == selected.frame.id })
        frames = DashboardLiveMemoryPolicy.mergedLatest(latest, into: frames, id: { $0.frame.id }, maxCount: nil)
        XCTAssertEqual(frames.last?.processingStatus, 0, "Latest-page merge alone retains the stale selected row")

        let refresher = DashboardSelectedFrameRefresher()
        let snapshot = try await refresher.refresh(selected, loadedStatus: loadedStatuses[selectedID], loadFrame: { try await database.getFrameWithVideoInfoByID(id: $0) }, loadNodes: { try await Self.loadNodes(database, frame: $0) })
        let result = try XCTUnwrap(snapshot)
        XCTAssertTrue(DashboardSelectedFrameRefresher.apply(result, selectedID: selectedID, frames: &frames, nodes: &cachedNodes, loadedStatuses: &loadedStatuses))

        XCTAssertEqual(frames.map(\.frame.id), originalOrder)
        XCTAssertEqual(frames.last?.frame.id.value, selectedID)
        XCTAssertEqual(frames.last?.processingStatus, 2)
        XCTAssertEqual(loadedStatuses[selectedID], 2)
        XCTAssertEqual(cachedNodes[selectedID]?.map(\.text), ["Selected screenshot became searchable"])
        try await database.close()
    }

    private static func loadNodes(_ database: DatabaseManager, frame: FrameWithVideoInfo) async throws -> [OCRNodeWithText] {
        try await database.getNodesWithText(frameID: frame.frame.id, frameWidth: 1, frameHeight: 1).map {
            OCRNodeWithText(id: $0.node.nodeOrder, frameId: frame.frame.id.value, x: $0.node.bounds.minX, y: $0.node.bounds.minY, width: $0.node.bounds.width, height: $0.node.bounds.height, text: $0.text)
        }
    }

    func testConcurrentSelectedReadsJoinAndCanceledWaiterDoesNotCancelOtherWaiter() async throws {
        let (database, selected) = try await makeCompletedFixture()
        let refresher = DashboardSelectedFrameRefresher()
        let gate = SelectedFrameReadGate()
        let loader: @Sendable (FrameID) async throws -> FrameWithVideoInfo? = { id in
            await gate.enterAndWait()
            return try await database.getFrameWithVideoInfoByID(id: id)
        }
        let first = Task { try await refresher.refresh(selected, loadedStatus: 0, loadFrame: loader, loadNodes: { try await Self.loadNodes(database, frame: $0) }) }
        await gate.waitUntilEntered()
        let joined = expectation(description: "Second request joined")
        let second = Task {
            joined.fulfill()
            return try await refresher.refresh(selected, loadedStatus: 0, loadFrame: loader, loadNodes: { try await Self.loadNodes(database, frame: $0) })
        }
        await fulfillment(of: [joined], timeout: 2)
        first.cancel()
        await gate.open()
        do {
            _ = try await first.value
            XCTFail("Canceled waiter must not publish")
        } catch is CancellationError { }
        let result = try await second.value
        let calls = await gate.readCount
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result?.frame.processingStatus, 2)
        XCTAssertEqual(result?.nodes?.map(\.text), ["Persisted selected text"])
        try await database.close()
    }

    func testHiddenOrReselectedFrameInvalidatesOlderReadAndAllowsFreshRead() async throws {
        let (database, selected) = try await makeCompletedFixture()
        let refresher = DashboardSelectedFrameRefresher()
        let gate = SelectedFrameReadGate()
        let old = Task {
            try await refresher.refresh(selected, loadedStatus: 0, loadFrame: { id in
                let value = try await database.getFrameWithVideoInfoByID(id: id)
                await gate.enterAndWait() // Deliberately ignores cancellation until the read returns.
                return value
            }, loadNodes: { try await Self.loadNodes(database, frame: $0) })
        }
        await gate.waitUntilEntered()
        refresher.cancel()
        let new = try await refresher.refresh(selected, loadedStatus: 0, loadFrame: { try await database.getFrameWithVideoInfoByID(id: $0) }, loadNodes: { try await Self.loadNodes(database, frame: $0) })
        await gate.open()
        do {
            _ = try await old.value
            XCTFail("A canceled older request must not publish after selecting the same ID again")
        } catch is CancellationError { }
        XCTAssertEqual(new?.nodes?.map(\.text), ["Persisted selected text"])
        try await database.close()
    }

    func testCompletedReadDoesNotResurrectRemovedFrameOrChangeAnotherSelection() async throws {
        let (database, selected) = try await makeCompletedFixture()
        let refresher = DashboardSelectedFrameRefresher()
        let result = try await refresher.refresh(selected, loadedStatus: 0, loadFrame: { try await database.getFrameWithVideoInfoByID(id: $0) }, loadNodes: { try await Self.loadNodes(database, frame: $0) })
        let snapshot = try XCTUnwrap(result)
        var frames = [selected]
        var nodes: [Int64: [OCRNodeWithText]] = [:]
        var statuses: [Int64: Int] = [:]
        XCTAssertFalse(DashboardSelectedFrameRefresher.apply(snapshot, selectedID: nil, frames: &frames, nodes: &nodes, loadedStatuses: &statuses))
        XCTAssertEqual(frames[0].processingStatus, 0)
        try await database.deleteFrame(id: selected.frame.id)
        frames.removeAll()
        XCTAssertFalse(DashboardSelectedFrameRefresher.apply(snapshot, selectedID: selected.frame.id.value, frames: &frames, nodes: &nodes, loadedStatuses: &statuses))
        XCTAssertTrue(frames.isEmpty)
        let deleted = try await refresher.refresh(selected, loadedStatus: 0, loadFrame: { try await database.getFrameWithVideoInfoByID(id: $0) }, loadNodes: { try await Self.loadNodes(database, frame: $0) })
        XCTAssertNil(deleted)
        try await database.close()
    }

    func testSQLiteNodeReadFailureRemainsRetryableInsteadOfCachingEmptyCompletion() async throws {
        let (database, selected) = try await makeCompletedFixture()
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        XCTAssertEqual(sqlite3_exec(db, "ALTER TABLE node RENAME TO saved_test_node", nil, nil, nil), SQLITE_OK)
        let refresher = DashboardSelectedFrameRefresher()
        do {
            _ = try await refresher.refresh(selected, loadedStatus: 0, loadFrame: { try await database.getFrameWithVideoInfoByID(id: $0) }, loadNodes: { try await Self.loadNodes(database, frame: $0) })
            XCTFail("Actual missing node table should fail the read")
        } catch { }
        XCTAssertEqual(sqlite3_exec(db, "ALTER TABLE saved_test_node RENAME TO node", nil, nil, nil), SQLITE_OK)
        let retry = try await refresher.refresh(selected, loadedStatus: 0, loadFrame: { try await database.getFrameWithVideoInfoByID(id: $0) }, loadNodes: { try await Self.loadNodes(database, frame: $0) })
        XCTAssertEqual(retry?.nodes?.map(\.text), ["Persisted selected text"])
        try await database.close()
    }

    private func makeCompletedFixture() async throws -> (DatabaseManager, FrameWithVideoInfo) {
        let database = DatabaseManager(databasePath: "file:dashboard_race_\(UUID().uuidString)?mode=memory&cache=private")
        try await database.initialize()
        let timestamp = Date().addingTimeInterval(-120)
        let segment = try await database.insertSegment(bundleID: "com.test.dashboard", startDate: timestamp, endDate: timestamp, windowName: "Selected history", browserUrl: nil, type: 0)
        let id = try await database.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: timestamp, segmentID: AppSegmentID(value: segment), frameIndexInSegment: 0, metadata: FrameMetadata(appBundleID: "com.test.dashboard")))
        try await database.markFrameReadable(frameID: id)
        let pending = try await database.getFrameWithVideoInfoByID(id: FrameID(value: id))
        let selected = try XCTUnwrap(pending)
        let text = ExtractedText(frameID: selected.frame.id, timestamp: timestamp, regions: [TextRegion(frameID: selected.frame.id, text: "Persisted selected text", bounds: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.1))])
        _ = try await database.commitFrameOCR(frameID: selected.frame.id, text: text, frameWidth: 640, frameHeight: 360)
        return (database, selected)
    }
}

private actor SelectedFrameReadGate {
    private(set) var readCount = 0
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func enterAndWait() async {
        readCount += 1
        enteredWaiter?.resume()
        enteredWaiter = nil
        guard !isOpen else { return }
        await withCheckedContinuation { blocked.append($0) }
    }

    func waitUntilEntered() async {
        guard readCount == 0 else { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func open() {
        isOpen = true
        for waiter in blocked { waiter.resume() }
        blocked.removeAll()
    }
}
