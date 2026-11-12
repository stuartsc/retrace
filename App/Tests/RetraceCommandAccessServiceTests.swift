import Foundation
import XCTest
import Shared
@testable import App

final class RetraceCommandAccessServiceTests: XCTestCase {
    func testProvisioningPersistsOnlyDigestAndRevocationSurvivesReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RetraceCommandAccessService(storageRoot: directory, handlers: { [] })
        let empty = await service.state()
        XCTAssertFalse(empty.enabled)
        XCTAssertFalse(empty.listening)
        XCTAssertTrue(empty.clients.isEmpty)
        let issued = try await service.createClient(name: "Fixture inspector", capabilities: [.operationsRead])
        let bytes = try Data(contentsOf: directory.appendingPathComponent("context/native-access/clients.json"))
        let encoded = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(encoded.contains(issued.bearerToken))
        XCTAssertTrue(encoded.contains(RetraceCommandDispatcher.tokenDigest(issued.bearerToken)))
        await service.close()
        let reopened = RetraceCommandAccessService(storageRoot: directory, handlers: { [] })
        let state = await reopened.state()
        XCTAssertEqual(state.clients.first?.id, issued.summary.id)
        XCTAssertEqual(state.clients.first?.capabilities, [.operationsRead])
        try await reopened.revokeClient(id: issued.summary.id)
        await reopened.close()
        let third = RetraceCommandAccessService(storageRoot: directory, handlers: { [] })
        let final = await third.state()
        XCTAssertTrue(final.clients.isEmpty)
        XCTAssertFalse(final.listening)
        await third.close()
    }

    func testSymlinkedConfigurationFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = RetraceCommandAccessService(storageRoot: directory, handlers: { [] })
        _ = await initial.state()
        await initial.close()
        let outside = directory.appendingPathComponent("unrelated.txt")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("context/native-access/clients.json"), withDestinationURL: outside)
        let service = RetraceCommandAccessService(storageRoot: directory, handlers: { [] })
        let state = await service.state()
        XCTAssertFalse(state.enabled)
        XCTAssertFalse(state.listening)
        XCTAssertNotNil(state.lastError)
        XCTAssertEqual(try String(contentsOf: outside), "{}")
        await service.close()
    }
}

final class RetraceNativeBridgeHTTPTests: XCTestCase {
    func testRealLoopbackHTTPAuthenticatesAndReturnsOnlyRegisteredCapabilities() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = "test-token-32-characters-minimum-length"
        let dispatcher = try RetraceCommandDispatcher(directory: directory,
            grants: [.init(clientID: "test", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.operationsRead])],
            handlers: [.init(operation: .health) { _ in .object(["fixture": .bool(true)]) }])
        let port = UInt16.random(in: 42_000...52_000)
        let bridge = RetraceNativeBridge(dispatcher: dispatcher, port: port)
        try await bridge.start()
        let listening = await bridge.isListening()
        XCTAssertTrue(listening)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/command")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try RetraceWire.encoder().encode(RetraceCommandRequest(requestID: UUID(), operation: .manifest))
        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let result = try RetraceWire.decoder().decode(RetraceCommandResponse.self, from: data)
        let manifest = try XCTUnwrap(result.data).decode(RetraceCapabilityManifest.self)
        XCTAssertEqual(Set(manifest.operations.map(\.operation)), [.manifest, .health])
        request.setValue("Bearer unknown-client-bearer-at-least-32-bytes", forHTTPHeaderField: "Authorization")
        let (_, denied) = try await session.data(for: request)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 403)
        session.invalidateAndCancel()
        await bridge.close()
        await dispatcher.close()
        let closed = await bridge.isListening()
        XCTAssertFalse(closed)
    }
}
