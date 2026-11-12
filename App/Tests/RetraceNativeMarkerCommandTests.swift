import Foundation
import Shared
import XCTest
@testable import App

final class RetraceNativeMarkerCommandTests: XCTestCase {
    func testMarkerEditSharesUIOwnerAndReplayDoesNotRepeatMutationOrExposeText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let services = ServiceContainer(databasePath: root.appendingPathComponent("unused.db").path,
            storageConfig: .init(storageRootPath: root.path))
        let coordinator = AppCoordinator(services: services), nativeID = UUID()
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { nativeID })
        let marker = try await markers.createManualMarker(.init(anchoredAt: Date(), title: "Original"))
        let handlers = await RetraceNativeCommandHandlers.make(coordinator: coordinator, markers: markers)
            .filter { $0.operation == .markerUpdate }
        let token = "editing-token-32-characters-minimum-length"
        let dispatcher = try RetraceCommandDispatcher(directory: root, grants: [.init(clientID: "editor",
            tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.markersWrite])], handlers: handlers)
        let arguments = RetraceJSON.object(["id": .string(marker.id.uuidString), "expectedRevision": .string(marker.revision.uuidString),
            "title": .string("Private reviewed title"), "note": .string("A private manual note")])
        let request = RetraceCommandRequest(requestID: UUID(), operation: .markerUpdate, arguments: arguments)
        let response = await dispatcher.execute(request, bearerToken: token)
        XCTAssertEqual(response.status, .succeeded)
        let editedValue = try await markers.marker(id: marker.id)
        let edited = try XCTUnwrap(editedValue)
        XCTAssertEqual(edited.title, "Private reviewed title")
        XCTAssertEqual(edited.anchoredAt, marker.anchoredAt)
        let replay = await dispatcher.execute(request, bearerToken: token)
        XCTAssertTrue(replay.replayed)
        let unchanged = try await markers.marker(id: marker.id)
        XCTAssertEqual(unchanged, edited)
        XCTAssertFalse(String(decoding: try RetraceWire.encoder().encode(replay), as: UTF8.self).contains("Private reviewed title"))
        let stale = await dispatcher.execute(.init(requestID: UUID(), operation: .markerUpdate, arguments: arguments), bearerToken: token)
        XCTAssertEqual(stale.status, .conflict)
        await dispatcher.close(); try await markers.close()
    }

    func testDeletionPreviewReplayRetainsIdentityWithoutDeletedTitle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let services = ServiceContainer(databasePath: root.appendingPathComponent("unused.db").path,
            storageConfig: .init(storageRootPath: root.path))
        let coordinator = AppCoordinator(services: services)
        let nativeID = UUID()
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { nativeID })
        let title = "Authored private title that must leave no command receipt"
        let marker = try await markers.createManualMarker(.init(anchoredAt: Date(), title: title))
        let handlers = await RetraceNativeCommandHandlers.make(coordinator: coordinator, markers: markers)
            .filter { $0.operation == .markerRemove }
        let token = "test-token-32-characters-minimum-length"
        let dispatcher = try RetraceCommandDispatcher(directory: root,
            grants: [.init(clientID: "fixture", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.markersWrite])], handlers: handlers)
        let arguments = RetraceJSON.object(["id": .string(marker.id.uuidString), "expectedRevision": .string(marker.revision.uuidString)])
        let request = RetraceCommandRequest(requestID: UUID(), operation: .markerRemove, arguments: arguments, mode: .preview)
        let previewResult = await dispatcher.execute(request, bearerToken: token)
        let preview = try XCTUnwrap(previewResult.preview)
        XCTAssertTrue(preview.summary.contains(marker.id.uuidString))
        XCTAssertFalse(preview.summary.contains(title))
        let removed = await dispatcher.execute(.init(requestID: UUID(), operation: .markerRemove,
            arguments: arguments, confirmation: .init(previewID: preview.id, digest: preview.digest)), bearerToken: token)
        XCTAssertEqual(removed.status, .succeeded)
        let replay = await dispatcher.execute(request, bearerToken: token)
        XCTAssertTrue(replay.replayed)
        XCTAssertFalse(String(decoding: try RetraceWire.encoder().encode(replay), as: UTF8.self).contains(title))
        await dispatcher.close()
        try await markers.close()
    }
}
