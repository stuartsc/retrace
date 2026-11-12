import Database
import Foundation
import Shared
import Storage
import XCTest
@testable import App

/// Real private SQLite transcript identities and command receipts; no device or model starts.
final class RetraceForegroundCommandTests: XCTestCase {
    private var root: URL!
    private var database: DatabaseManager!
    private var audio: AudioTranscriptionQueries!
    private var adapter: DataAdapter!
    private var markers: TimelineMarkerService!
    private var companion: CompanionController!
    private var dispatcher: RetraceCommandDispatcher!
    private var reference: V23TranscriptReference!
    private var router: RetraceForegroundRouter!
    private let token = "foreground-fixture-token-at-least-32-characters"
    private var grants: [RetraceClientGrant] {
        [.init(clientID: "foreground-fixture", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token),
               capabilities: [.foregroundControl, .evidenceRead, .markersRead])]
    }
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("foreground-command-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = "file:foreground-command-\(UUID())?mode=memory&cache=private"
        database = DatabaseManager(databasePath: path); try await database.initialize()
        let pointer = await database.getConnection()
        audio = AudioTranscriptionQueries(db: try XCTUnwrap(pointer))
        adapter = DataAdapter(retraceConnection: try await database.makeRecallReadConnection(),
            retraceConfig: .init(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
        try await adapter.initialize()
        let native = try await database.activityStoreID()
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { native }); self.markers = markers
        let policy = NativeCaptureState(config: Shared.CaptureConfig(), revision: UUID())
        let recall = ProgressiveRecallService(database: database, adapter: adapter, configuration: { policy.config },
            disclosureState: { policy }, imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
        let companion = CompanionController(storageRoot: root.appendingPathComponent("companion"), nativeStoreID: native,
            databasePath: path, adapter: adapter, recall: recall, markers: markers,
            verifiedBytes: { _ in XCTFail("Navigation must not read audio bytes"); throw CompanionError.unavailable }, policy: {})
        self.companion = companion
        let reader = LiveContextSearchService(database: database, audio: audio, adapter: adapter, recall: recall,
            markers: markers, captureState: { policy })
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let rowID = try await audio.insertTranscription(sessionID: nil, text: "Private authored transcript", startTime: time,
            endTime: time.addingTimeInterval(3), source: .microphone, confidence: nil, words: [])
        let row = try await audio.getContextEntry(id: rowID)
        reference = try CompanionTranscriptSnapshot.recordingReference(for: XCTUnwrap(row), nativeStoreID: native)
        let router = RetraceForegroundRouter(); self.router = router
        dispatcher = try RetraceCommandDispatcher(directory: root, grants: grants,
            handlers: RetraceForegroundCommands.handlers(.init(reader: { reader }, recall: { recall },
                companion: { companion }, markers: markers, router: router)))
    }
    override func tearDown() async throws {
        await dispatcher?.close(); try await companion?.close(); try await markers?.close()
        await adapter?.shutdown(); try await database?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }
    private func request(_ reference: V23TranscriptReference) throws -> RetraceCommandRequest {
        .init(requestID: UUID(), operation: .navigate, arguments: .object(["kind": .string("transcript"), "reference": try .encode(reference)]))
    }

    func testExactTranscriptNavigationAndRetryInvokeForegroundOnce() async throws {
        let expected = reference!, effect = ForegroundEffectCount()
        let registration = await router.register(open: { target, authorization in
            guard case .transcript(let reference) = target else { return XCTFail("Wrong native target") }
            XCTAssertEqual(reference, expected)
            try await authorization.validate()
            try authorization.effect { effect.increment() }
        }, playback: { _, _ in XCTFail("Navigation must not play") })
        let command = try request(reference)
        let first = await dispatcher.execute(command, bearerToken: token)
        XCTAssertEqual(first.status, .succeeded); XCTAssertEqual(effect.count, 1)
        let second = await dispatcher.execute(command, bearerToken: token)
        XCTAssertEqual(second.status, .succeeded); XCTAssertTrue(second.replayed); XCTAssertEqual(effect.count, 1)
        await router.unregister(registration)
    }

    func testTranscriptNavigationRequiresEvidenceGrantAndRejectsForgedOrDeletedIdentity() async throws {
        let registration = await router.register(open: { _, _ in XCTFail("Unauthorized or stale input cannot reach UI") }, playback: { _, _ in })
        try await dispatcher.replaceGrants([.init(clientID: "foreground-fixture", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.foregroundControl])])
        let denied = await dispatcher.execute(try request(reference), bearerToken: token)
        XCTAssertEqual(denied.status, .denied)
        try await dispatcher.replaceGrants(grants)
        let forged = V23TranscriptReference(nativeStoreID: reference.nativeStoreID, source: .microphone,
            rowID: reference.rowID, snapshotSHA256: String(repeating: "a", count: 64))
        let mismatch = await dispatcher.execute(try request(forged), bearerToken: token)
        XCTAssertEqual(mismatch.status, .conflict)
        _ = try await audio.deleteTranscription(id: reference.rowID)
        let deleted = await dispatcher.execute(try request(reference), bearerToken: token)
        XCTAssertEqual(deleted.status, .conflict)
        await router.unregister(registration)
    }

    func testSourceMutationAfterValidationRevokesHeldUIEffect() async throws {
        let hold = ForegroundCommandHold(), entered = expectation(description: "Prepared exact transcript waits before window publication")
        let registration = await router.register(open: { _, authorization in
            await hold.wait { entered.fulfill() }
            try authorization.effect { XCTFail("Changed source cannot be published after a held await") }
        }, playback: { _, _ in })
        let command = try request(reference), dispatcher = self.dispatcher!, token = self.token
        let result = Task { await dispatcher.execute(command, bearerToken: token) }
        await fulfillment(of: [entered], timeout: 3)
        _ = try await audio.deleteTranscription(id: reference.rowID)
        companion.sourceChanged(.init(.init(targets: [.audioRow(reference.rowID)])))
        await hold.release()
        let response = await result.value
        XCTAssertEqual(response.status, .indeterminate)
        XCTAssertEqual(response.code, "reserved_outcome_unknown")
        await router.unregister(registration)
    }

    func testLegacyTranscriptCannotBePassedAsExactPlaybackAndStopNeedsNoEvidenceGrant() async throws {
        let stop = expectation(description: "Explicit shared stop routed")
        let registration = await router.register(open: { _, _ in }, playback: { request, authorization in
            guard case .stop = request else { return XCTFail("Legacy transcript must not become PCM playback") }
            try authorization.effect { stop.fulfill() }
        })
        let invalid = await dispatcher.execute(.init(requestID: UUID(), operation: .playback,
            arguments: .object(["action": .string("playTranscript"), "reference": try .encode(reference!)])), bearerToken: token)
        XCTAssertEqual(invalid.status, .failed)
        try await dispatcher.replaceGrants([.init(clientID: "foreground-fixture", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.foregroundControl])])
        let stopped = await dispatcher.execute(.init(requestID: UUID(), operation: .playback,
            arguments: .object(["action": .string("stop")])), bearerToken: token)
        XCTAssertEqual(stopped.status, .succeeded)
        await fulfillment(of: [stop], timeout: 3)
        await router.unregister(registration)
    }
}

private final class ForegroundEffectCount: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
private actor ForegroundCommandHold {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait(entered: @Sendable () -> Void) async { await withCheckedContinuation { continuation = $0; entered() } }
    func release() { continuation?.resume(); continuation = nil }
}
