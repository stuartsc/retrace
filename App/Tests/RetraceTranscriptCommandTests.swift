import Foundation
import XCTest
import Database
import Storage
import Shared
@testable import App

final class RetraceTranscriptCommandTests: XCTestCase {
    func testCursorAndSelectionAreClientBoundAndDeletionInvalidatesCopy() async throws {
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
        await services.installTranscriptCommandTestAdapter(adapter)
        let coordinator = AppCoordinator(services: services)
        let queriesValue = await coordinator.getAudioTranscriptionQueries()
        let queries = try XCTUnwrap(queriesValue)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await queries.insertTranscription(sessionID: nil, text: "Earlier authored explanation", startTime: start,
            endTime: start.addingTimeInterval(1), source: .microphone, confidence: nil, words: [], audioPath: "private/audio/first.m4a")
        let selectedID = try await queries.insertTranscription(sessionID: nil, text: "Later authored explanation", startTime: start.addingTimeInterval(2),
            endTime: start.addingTimeInterval(3), source: .microphone, confidence: nil, words: [], audioPath: "private/audio/second.m4a")
        let reader = RetraceTranscriptCommands(coordinator: coordinator)
        let token = "test-token-32-characters-minimum-length"
        let other = "other-token-32-characters-minimum-length"
        let dispatcher = try RetraceCommandDispatcher(directory: root,
            grants: [.init(clientID: "owner", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.evidenceRead]),
                     .init(clientID: "other", tokenSHA256: RetraceCommandDispatcher.tokenDigest(other), capabilities: [.evidenceRead])],
            handlers: [.init(operation: .transcript) { try await reader.read($0) }, .init(operation: .copyContext) { try await reader.copy($0) }])
        let arguments = RetraceJSON.object(["from": .number(start.timeIntervalSince1970 * 1000), "to": .number(start.addingTimeInterval(5).timeIntervalSince1970 * 1000), "limit": .integer(1)])
        let response = await dispatcher.execute(.init(requestID: UUID(), operation: .transcript, arguments: arguments), bearerToken: token)
        XCTAssertEqual(response.status, .succeeded)
        let encoded = try RetraceWire.encoder().encode(XCTUnwrap(response.data))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private/audio"))
        let page = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let entries = try XCTUnwrap(page["entries"] as? [[String: Any]])
        let selection = try XCTUnwrap(entries.first?["selectionID"] as? String)
        let cursor = try XCTUnwrap(page["nextCursor"] as? String)
        let nextArguments = RetraceJSON.object(["from": .number(start.timeIntervalSince1970 * 1000), "to": .number(start.addingTimeInterval(5).timeIntervalSince1970 * 1000), "limit": .integer(1), "cursor": .string(cursor)])
        let wrongClient = await dispatcher.execute(.init(requestID: UUID(), operation: .transcript, arguments: nextArguments), bearerToken: other)
        XCTAssertEqual(wrongClient.status, .conflict)
        let copyArguments = RetraceJSON.object(["selectionIDs": .array([.string(selection)])])
        let copied = await dispatcher.execute(.init(requestID: UUID(), operation: .copyContext, arguments: copyArguments), bearerToken: token)
        XCTAssertEqual(copied.status, .succeeded)
        try await queries.deleteTranscription(id: selectedID)
        let stale = await dispatcher.execute(.init(requestID: UUID(), operation: .copyContext, arguments: copyArguments), bearerToken: token)
        XCTAssertEqual(stale.status, .conflict)
        XCTAssertNil(stale.data)
        // Sparse filtering can yield no accepted entries while bounded raw
        // candidates remain. The actual MCP route must retain its continuation
        // and distinguish unchecked history from a proven matching next page.
        for index in 0..<520 {
            let time = start.addingTimeInterval(Double(index + 10))
            _ = try await queries.insertTranscription(sessionID: nil, text: "Unrelated authored recording",
                startTime: time, endTime: time.addingTimeInterval(1), source: .microphone,
                confidence: nil, words: [])
        }
        var sparseArguments: [String: RetraceJSON] = ["from": .number(start.timeIntervalSince1970 * 1000),
            "to": .number(start.addingTimeInterval(1_000).timeIntervalSince1970 * 1000),
            "limit": .integer(1), "query": .string("Earlier")]
        let sparse = await dispatcher.execute(.init(requestID: UUID(), operation: .transcript,
            arguments: .object(sparseArguments)), bearerToken: token)
        XCTAssertEqual(sparse.status, .succeeded)
        let sparseData = try RetraceWire.encoder().encode(XCTUnwrap(sparse.data))
        let sparsePage = try XCTUnwrap(JSONSerialization.jsonObject(with: sparseData) as? [String: Any])
        XCTAssertEqual((sparsePage["entries"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(sparsePage["scanIncomplete"] as? Bool, true)
        XCTAssertEqual(sparsePage["hasMoreMatches"] as? Bool, false)
        XCTAssertEqual(sparsePage["scannedCandidates"] as? Int, 512)
        sparseArguments["cursor"] = .string(try XCTUnwrap(sparsePage["nextCursor"] as? String))
        let continued = await dispatcher.execute(.init(requestID: UUID(), operation: .transcript,
            arguments: .object(sparseArguments)), bearerToken: token)
        XCTAssertEqual(continued.status, .succeeded)
        let continuedData = try RetraceWire.encoder().encode(XCTUnwrap(continued.data))
        let continuedPage = try XCTUnwrap(JSONSerialization.jsonObject(with: continuedData) as? [String: Any])
        XCTAssertEqual((continuedPage["entries"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(continuedPage["scanIncomplete"] as? Bool, false)
        XCTAssertTrue(continuedPage["nextCursor"] is NSNull)
        await dispatcher.close()
        await adapter.shutdown()
        try await database.close()
    }
}
private extension ServiceContainer {
    func installTranscriptCommandTestAdapter(_ adapter: DataAdapter) { dataAdapter = adapter }
}
