import Foundation
import Database
import Storage
import Shared
import XCTest
@testable import App

final class RetraceTimelineCommandTests: XCTestCase {
    func testTimelinePagesDuplicateTimestampsWithExactReferencesAndClientBoundCursors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let services = ServiceContainer(databasePath: root.appendingPathComponent("recordings.db").path, storageConfig: .init(storageRootPath: root.path))
        let database = await services.database
        try await database.initialize()
        let adapter = DataAdapter(retraceConnection: try await database.makeRecallReadConnection(),
            retraceConfig: .init(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
        try await adapter.initialize()
        await services.installTimelineCommandTestAdapter(adapter)
        let coordinator = AppCoordinator(services: services)
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = FrameMetadata(appBundleID: "com.fixture.timeline", windowName: "Authored window")
        let segment = try await database.insertSegment(bundleID: "com.fixture.timeline", startDate: time,
            endDate: time, windowName: "Authored window", browserUrl: nil, type: 0)
        var expected: Set<FrameID> = []
        for text in ["First authored observation", "Second authored observation"] {
            let frame = FrameID(value: try await database.insertFrame(.init(id: .init(value: 0), timestamp: time,
                segmentID: .init(value: segment), frameIndexInSegment: 0, metadata: metadata)))
            expected.insert(frame)
            _ = try await database.commitFrameOCR(frameID: frame, text: .init(frameID: frame, timestamp: time,
                regions: [], fullText: text, metadata: metadata), frameWidth: 100, frameHeight: 100)
        }
        let timeline = RetraceTimelineCommands(coordinator: coordinator)
        let token = "owner-token-32-characters-minimum-length"
        let other = "other-token-32-characters-minimum-length"
        let dispatcher = try RetraceCommandDispatcher(directory: root,
            grants: [.init(clientID: "owner", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.evidenceRead]),
                     .init(clientID: "other", tokenSHA256: RetraceCommandDispatcher.tokenDigest(other), capabilities: [.evidenceRead])],
            handlers: [.init(operation: .timeline) { try await timeline.read($0) }])
        let from = time.addingTimeInterval(-1).timeIntervalSince1970 * 1000
        let to = time.addingTimeInterval(1).timeIntervalSince1970 * 1000
        let arguments: [String: RetraceJSON] = ["from": .number(from), "to": .number(to), "limit": .integer(1)]
        let first = await dispatcher.execute(.init(requestID: UUID(), operation: .timeline, arguments: .object(arguments)), bearerToken: token)
        XCTAssertEqual(first.status, .succeeded)
        let firstPage = try XCTUnwrap(first.data).decode(Page.self)
        let cursor = try XCTUnwrap(firstPage.nextCursor)
        var next = arguments; next["cursor"] = .string(cursor.uuidString)
        let denied = await dispatcher.execute(.init(requestID: UUID(), operation: .timeline, arguments: .object(next)), bearerToken: other)
        XCTAssertEqual(denied.status, .conflict)
        let second = await dispatcher.execute(.init(requestID: UUID(), operation: .timeline, arguments: .object(next)), bearerToken: token)
        let secondPage = try XCTUnwrap(second.data).decode(Page.self)
        XCTAssertNil(secondPage.nextCursor)
        XCTAssertEqual(Set((firstPage.entries + secondPage.entries).map { $0.reference.frameID }), expected)
        XCTAssertEqual(firstPage.entries.first?.reference.storeID, secondPage.entries.first?.reference.storeID)
        let hiddenValue = try await database.getTag(name: "hidden")
        let hidden = try XCTUnwrap(hiddenValue)
        try await database.addTagToSegment(segmentId: .init(value: segment), tagId: hidden.id)
        let hiddenRead = await dispatcher.execute(.init(requestID: UUID(), operation: .timeline, arguments: .object(arguments)), bearerToken: token)
        XCTAssertEqual(try XCTUnwrap(hiddenRead.data).decode(Page.self).entries.count, 0)
        await dispatcher.close()
        await adapter.shutdown()
        try await database.close()
    }
    private struct Entry: Decodable { let reference: ScreenEvidenceRef }
    private struct Page: Decodable { let entries: [Entry]; let nextCursor: UUID? }
}

private extension ServiceContainer {
    func installTimelineCommandTestAdapter(_ adapter: DataAdapter) { dataAdapter = adapter }
}
