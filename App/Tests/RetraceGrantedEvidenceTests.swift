import Foundation
import XCTest
import Database
import Storage
import Shared
@testable import App

final class RetraceGrantedEvidenceTests: XCTestCase {
    func testExplicitGrantHonoursCurrentExclusionsAndCannotEscapeCommandScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let database = DatabaseManager(databasePath: root.appendingPathComponent("fixture.db").path)
        try await database.initialize()
        let connection = try await database.makeRecallReadConnection()
        let adapter = DataAdapter(retraceConnection: connection,
            retraceConfig: .init(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
        try await adapter.initialize()
        let config = EvidenceGrantConfiguration()
        let service = ProgressiveRecallService(database: database, adapter: adapter, configuration: { await config.get() },
            disclosureState: { await config.state() },
            imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = FrameMetadata(appBundleID: "com.fixture.retrace", appName: "Fixture", windowName: "Private source")
        let segment = try await database.insertSegment(bundleID: "com.fixture.retrace", startDate: date, endDate: date, windowName: "Private source", browserUrl: nil, type: 0)
        let frame = FrameID(value: try await database.insertFrame(.init(id: .init(value: 0), timestamp: date, segmentID: .init(value: segment), frameIndexInSegment: 0, metadata: metadata)))
        _ = try await database.commitFrameOCR(frameID: frame, text: ExtractedText(frameID: frame, timestamp: date,
            regions: [TextRegion(frameID: frame, text: "Authored evidence", bounds: CGRect(x: 1, y: 1, width: 50, height: 20))], metadata: metadata), frameWidth: 100, frameHeight: 100)
        let reference = try await service.reference(frameID: frame, source: .native)
        let escaped = EvidenceGrantContextCapture()
        let token = "test-token-32-characters-minimum-length"
        let dispatcher = try RetraceCommandDispatcher(directory: root,
            grants: [.init(clientID: "fixture", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.evidenceRead])],
            handlers: [.init(operation: .evidence) { context in
                await escaped.save(context)
                return try .encode(await service.grantedScreen(reference, context: context))
            }])
        let allowed = await dispatcher.execute(.init(requestID: UUID(), operation: .evidence), bearerToken: token)
        XCTAssertEqual(allowed.status, .succeeded)
        let stored = await escaped.context
        do {
            _ = try await service.grantedScreen(reference, context: try XCTUnwrap(stored))
            XCTFail("A completed command cannot retain its disclosure authority")
        } catch { }
        if case .unavailable(.notPermitted) = await service.resolve(.screen(reference), for: .agent(clientID: "fixture")) { }
        else { XCTFail("An agent identity without the explicit scope must still be denied") }
        #if DEBUG
        let policyReached = expectation(description: "Final read is held before disclosure")
        let policyReads = EvidenceGrantReadCounter()
        let (policyStream, policyRelease) = AsyncStream<Void>.makeStream()
        await service.setExpansionFinalReadCheckpoint {
            if await policyReads.next() == 2 {
                policyReached.fulfill()
                for await _ in policyStream { break }
            }
        }
        let policyRead = Task { await dispatcher.execute(.init(requestID: UUID(), operation: .evidence), bearerToken: token) }
        await fulfillment(of: [policyReached], timeout: 10)
        await config.exclude()
        await config.exclude(false)
        policyRelease.yield(()); policyRelease.finish()
        let policyResult = await policyRead.value
        XCTAssertNotEqual(policyResult.status, .succeeded, "A policy ABA during the final read must discard the snapshot")
        XCTAssertNil(policyResult.data)

        let hiddenReached = expectation(description: "Final read is held before hidden-state check")
        let hiddenReads = EvidenceGrantReadCounter()
        let (hiddenStream, hiddenRelease) = AsyncStream<Void>.makeStream()
        await service.setExpansionFinalReadCheckpoint {
            if await hiddenReads.next() == 2 {
                hiddenReached.fulfill()
                for await _ in hiddenStream { break }
            }
        }
        let hiddenRead = Task { await dispatcher.execute(.init(requestID: UUID(), operation: .evidence), bearerToken: token) }
        await fulfillment(of: [hiddenReached], timeout: 10)
        let hiddenValue = try await database.getTag(name: "hidden")
        let hidden = try XCTUnwrap(hiddenValue)
        try await database.addTagToSegment(segmentId: .init(value: segment), tagId: hidden.id)
        hiddenRelease.yield(()); hiddenRelease.finish()
        let hiddenResult = await hiddenRead.value
        XCTAssertNotEqual(hiddenResult.status, .succeeded)
        XCTAssertNil(hiddenResult.data)
        await service.setExpansionFinalReadCheckpoint(nil)
        let hiddenAgain = await dispatcher.execute(.init(requestID: UUID(), operation: .evidence), bearerToken: token)
        XCTAssertNotEqual(hiddenAgain.status, .succeeded, "A previously acquired reference remains denied while hidden")
        try await database.removeTagFromSegment(segmentId: .init(value: segment), tagId: hidden.id)
        #endif
        await config.exclude()
        let denied = await dispatcher.execute(.init(requestID: UUID(), operation: .evidence), bearerToken: token)
        XCTAssertNotEqual(denied.status, .succeeded)
        XCTAssertNil(denied.data)
        await dispatcher.close()
        await adapter.shutdown()
        try await database.close()
    }
}
private actor EvidenceGrantConfiguration {
    var excluded = false
    var revision = UUID()
    func get() -> CaptureConfig { .init(excludedAppBundleIDs: excluded ? ["com.fixture.retrace"] : []) }
    func state() -> NativeCaptureState { .init(config: get(), revision: revision) }
    func exclude(_ value: Bool = true) { excluded = value; revision = UUID() }
}
private actor EvidenceGrantContextCapture {
    var context: RetraceCommandContext?
    func save(_ context: RetraceCommandContext) { self.context = context }
}
private actor EvidenceGrantReadCounter {
    var value = 0
    func next() -> Int { value += 1; return value }
}
