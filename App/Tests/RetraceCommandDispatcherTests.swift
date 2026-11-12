import XCTest
import Foundation
import Shared
@testable import App

final class RetraceCommandDispatcherTests: XCTestCase {
    func testDurableOutcomeSurvivesReopenWithoutRepeatingEffect() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = CommandEffectRecorder()
        let grant = RetraceClientGrant(clientID: "test", tokenSHA256: RetraceCommandDispatcher.tokenDigest("test-token-32-characters-minimum-length"), capabilities: [.markersWrite])
        let handler = RetraceCommandHandler(operation: .markerCreate) { _ in
            await recorder.record()
            return .object(["created": .bool(true)])
        }
        let request = RetraceCommandRequest(requestID: UUID(), operation: .markerCreate, arguments: .object([:]))
        let first = try RetraceCommandDispatcher(directory: folder, grants: [grant], handlers: [handler])
        let response = await first.execute(request, bearerToken: "test-token-32-characters-minimum-length")
        XCTAssertEqual(response.status, .succeeded)
        await first.close()
        let second = try RetraceCommandDispatcher(directory: folder, grants: [grant], handlers: [handler])
        let replay = await second.execute(request, bearerToken: "test-token-32-characters-minimum-length")
        XCTAssertEqual(replay.status, .succeeded)
        XCTAssertTrue(replay.replayed)
        let count = await recorder.count
        XCTAssertEqual(count, 1)
        await second.close()
    }

    func testUnknownPostEffectFailureNeverRetriesAfterReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let effectFile = folder.appendingPathComponent("native-effect.txt")
        let token = "test-token-32-characters-minimum-length"
        let grant = RetraceClientGrant(clientID: "test", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.markersWrite])
        let handler = RetraceCommandHandler(operation: .markerCreate) { _ in
            let existing = (try? Data(contentsOf: effectFile)) ?? Data()
            try (existing + Data("effect\n".utf8)).write(to: effectFile)
            throw CocoaError(.fileWriteUnknown)
        }
        let request = RetraceCommandRequest(requestID: UUID(), operation: .markerCreate)
        let first = try RetraceCommandDispatcher(directory: folder, grants: [grant], handlers: [handler])
        let failed = await first.execute(request, bearerToken: token)
        XCTAssertEqual(failed.status, .indeterminate)
        await first.close()
        let reopened = try RetraceCommandDispatcher(directory: folder, grants: [grant], handlers: [handler])
        let retry = await reopened.execute(request, bearerToken: token)
        XCTAssertEqual(retry.status, .indeterminate)
        XCTAssertEqual(try String(contentsOf: effectFile), "effect\n")
        await reopened.close()
    }

    func testStaleRevisionCannotConsumePreview() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let revisionFile = folder.appendingPathComponent("current-revision.txt")
        try Data("one".utf8).write(to: revisionFile)
        let token = "test-token-32-characters-minimum-length"
        let recorder = CommandEffectRecorder()
        let handler = RetraceCommandHandler(operation: .markerRemove, preview: { _ in
            .init(summary: "Remove marker", revision: try String(contentsOf: revisionFile), affectedCount: 1)
        }) { _ in await recorder.record(); return .null }
        let dispatcher = try RetraceCommandDispatcher(directory: folder,
            grants: [.init(clientID: "test", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.markersWrite])], handlers: [handler])
        let response = await dispatcher.execute(.init(requestID: UUID(), operation: .markerRemove, mode: .preview), bearerToken: token)
        let preview = try XCTUnwrap(response.preview)
        try Data("two".utf8).write(to: revisionFile)
        let rejected = await dispatcher.execute(.init(requestID: UUID(), operation: .markerRemove,
            confirmation: .init(previewID: preview.id, digest: preview.digest)), bearerToken: token)
        XCTAssertEqual(rejected.code, "invalid_preview")
        let count = await recorder.count
        XCTAssertEqual(count, 0)
        await dispatcher.close()
    }

    func testGrantAndPayloadConflictAreCheckedBeforeEffects() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = CommandEffectRecorder()
        let token = "test-token-32-characters-minimum-length"
        let dispatcher = try RetraceCommandDispatcher(directory: folder,
            grants: [.init(clientID: "test", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.markersWrite])],
            handlers: [.init(operation: .markerCreate) { _ in await recorder.record(); return .null }])
        let id = UUID()
        let denied = await dispatcher.execute(.init(requestID: id, operation: .markerCreate), bearerToken: "wrong")
        XCTAssertEqual(denied.status, .denied)
        let accepted = await dispatcher.execute(.init(requestID: id, operation: .markerCreate), bearerToken: token)
        XCTAssertEqual(accepted.status, .succeeded)
        let conflict = await dispatcher.execute(.init(requestID: id, operation: .markerCreate, arguments: .object(["different": .bool(true)])), bearerToken: token)
        XCTAssertEqual(conflict.code, "request_conflict")
        let count = await recorder.count
        XCTAssertEqual(count, 1)
        await dispatcher.close()
    }

    func testPreviewIsClientRevisionBoundAndOneUse() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let token = "test-token-32-characters-minimum-length"
        let recorder = CommandEffectRecorder()
        let handler = RetraceCommandHandler(operation: .markerRemove, preview: { _ in
            .init(summary: "Remove one marker", revision: "revision-one", affectedCount: 1)
        }) { _ in await recorder.record(); return .null }
        let dispatcher = try RetraceCommandDispatcher(directory: folder,
            grants: [.init(clientID: "test", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.markersWrite])], handlers: [handler])
        let preview = await dispatcher.execute(.init(requestID: UUID(), operation: .markerRemove, mode: .preview), bearerToken: token)
        XCTAssertEqual(preview.status, .preview)
        let proof = try XCTUnwrap(preview.preview)
        let confirmed = await dispatcher.execute(.init(requestID: UUID(), operation: .markerRemove,
            confirmation: .init(previewID: proof.id, digest: proof.digest)), bearerToken: token)
        XCTAssertEqual(confirmed.status, .succeeded)
        let repeated = await dispatcher.execute(.init(requestID: UUID(), operation: .markerRemove,
            confirmation: .init(previewID: proof.id, digest: proof.digest)), bearerToken: token)
        XCTAssertEqual(repeated.code, "invalid_preview")
        let count = await recorder.count
        XCTAssertEqual(count, 1)
        await dispatcher.close()
    }
}

private actor CommandEffectRecorder {
    var count = 0
    func record() { count += 1 }
}

final class RetraceNativeBridgeParsingTests: XCTestCase {
    func testIncrementalBodyAndDuplicateHeaderRejection() throws {
        let body = "{\"requestID\":\"00000000-0000-4000-8000-000000000001\",\"operation\":\"capabilities.read\"}"
        let header = "POST /v1/command HTTP/1.1\r\nHost: 127.0.0.1:9013\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nAuthorization: Bearer test-token-32-characters-minimum-length\r\n\r\n"
        XCTAssertNil(try RetraceBridgeHTTPRequest.parse(Data(header.utf8), port: 9013))
        let request = try XCTUnwrap(RetraceBridgeHTTPRequest.parse(Data((header + body).utf8), port: 9013))
        XCTAssertEqual(request.body, Data(body.utf8))
        XCTAssertThrowsError(try RetraceBridgeHTTPRequest.parse(Data((header.replacingOccurrences(of: "Content-Length:", with: "content-length: 1\r\nContent-Length:") + body).utf8), port: 9013))
        XCTAssertThrowsError(try RetraceBridgeHTTPRequest.parse(Data((header.replacingOccurrences(of: "Host: 127.0.0.1:9013", with: "Host: example.com") + body).utf8), port: 9013))
        XCTAssertThrowsError(try RetraceBridgeHTTPRequest.parse(Data((header + body + body).utf8), port: 9013))
    }
}
