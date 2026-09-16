import Foundation
import Shared
import Database
import Storage
import SQLCipher
import XCTest
@testable import App

/// These tests own their SQLite writers, source text and lifecycle gates. They
/// never initialize native capture/audio/storage or open an installed library.
final class ScreenEvidenceAdmissionIntegrationTests: XCTestCase {
    private var fixture: AdmissionFixture?
    private var containers: [ServiceContainer] = []
    private var gates: [InitializationGate] = []
    private var tasks: [Task<Void, Error>] = []

    override func tearDown() async throws {
        for task in tasks { task.cancel() }
        for gate in gates { await gate.release() }
        for task in tasks { _ = try? await task.value }
        for container in containers { try await container.shutdown() }
        if let fixture {
            try? await fixture.bridge.endSession()
            await fixture.adapter.shutdown()
            try await fixture.database.close()
        }
        fixture = nil
    }

    func testLocalArtifactRoundTripKeepsBothIndexesUnreadyAndMetricsContentFree() async throws {
        let f = try await makeFixture()
        let token = try await f.bridge.beginSession(config: CaptureConfig())
        await assertAdmissionError(.inactive) { _ = try await f.service.claimScreenEvidenceDerivation(f.request, for: .localUser) }
        try await f.bridge.activate(token)
        let claim = try await f.service.claimScreenEvidenceDerivation(f.request, for: .localUser)
        let receipt = try await f.service.stageScreenEvidenceArtifact(claim: claim, data: f.artifact, for: .localUser)
        let result = try await f.service.readScreenEvidenceArtifact(receipt, for: .localUser)
        XCTAssertEqual(result.data, f.artifact)
        XCTAssertEqual(receipt.status, .stagedUnpublished)
        let duplicate = try await f.service.stageScreenEvidenceArtifact(claim: claim, data: f.artifact, for: .localUser)
        XCTAssertEqual(duplicate.receiptID, receipt.receiptID)
        let connection = await f.database.getConnection()
        let pointer = try XCTUnwrap(connection)
        XCTAssertEqual(try scalar(pointer, "SELECT COUNT(*) FROM screen_evidence_work WHERE state='blocked'"), 2)
        let page = try await f.database.advanceScreenEvidenceConsumer(cursor: f.request.cursor, limit: 10)
        XCTAssertTrue(page.work.allSatisfy { $0.lexicalReadyRevision == nil && $0.vectorReadyRevision == nil })
        try await f.service.cancelScreenEvidenceDerivation(claim, for: .localUser)
        _ = try await f.service.compactScreenEvidenceArtifacts(limit: 10, for: .localUser)
        let rows = try strings(pointer, "SELECT metadata FROM daily_metrics WHERE metricType='progressive_recall_action'")
        let events = try rows.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        for action in ["evidencePolicySessionBegan", "evidencePolicyActivated", "evidenceDerivationClaimed",
                       "evidenceArtifactStaged", "evidenceDerivationCancelled", "evidenceArtifactsCompacted"] {
            XCTAssertTrue(events.contains { $0["action"] as? String == action && $0["outcome"] as? String == "success" }, action)
        }
        // The read's entry metric is joined before the final authority check;
        // its outcome is best effort and must not delay returning checked bytes.
        XCTAssertTrue(events.contains { $0["action"] as? String == "evidenceArtifactRead" && $0["outcome"] as? String == "pending" })
        XCTAssertTrue(events.allSatisfy { Set($0.keys) == ["action", "outcome", "count"] })
        XCTAssertFalse(rows.contains { $0.contains("Cedar") || $0.contains(f.request.cursor.consumerID.uuidString) })
    }

    func testConfigurationRoundTripCannotRevivePreviouslyStagedArtifact() async throws {
        let f = try await makeFixture()
        let first = try await f.bridge.beginSession(config: CaptureConfig())
        try await f.bridge.activate(first)
        let claim = try await f.service.claimScreenEvidenceDerivation(f.request, for: .localUser)
        let receipt = try await f.service.stageScreenEvidenceArtifact(claim: claim, data: f.artifact, for: .localUser)
        let excluded = try await f.bridge.prepareConfiguration(CaptureConfig(excludedAppBundleIDs: ["com.authored.admission"]))
        await assertAdmissionError(.inactive) { _ = try await f.service.readScreenEvidenceArtifact(receipt, for: .localUser) }
        try await f.bridge.activate(excluded)
        let restored = try await f.bridge.prepareConfiguration(CaptureConfig())
        try await f.bridge.activate(restored)
        XCTAssertNotEqual(first.policyEpoch, restored.policyEpoch)
        await assertRefused { _ = try await f.service.readScreenEvidenceArtifact(receipt, for: .localUser) }
        try await f.bridge.endSession()
        await assertAdmissionError(.inactive) { _ = try await f.service.claimScreenEvidenceDerivation(f.request, for: .localUser) }
    }

    func testSharedPrivacyInputsDenyStagingAndRetainedPresentation() async throws {
        let f = try await makeFixture(windowTitle: "Cedar confidential pane")
        for config in [
            CaptureConfig(excludedAppBundleIDs: ["com.authored.admission"]),
            CaptureConfig(customPrivateWindowPatterns: ["CONFIDENTIAL"]),
            CaptureConfig(redactWindowTitlePatterns: ["cedar"]),
            CaptureConfig(redactBrowserURLPatterns: [""])
        ] {
            let token = try await f.bridge.beginSession(config: config)
            try await f.bridge.activate(token)
            await assertAdmissionError(.notPermitted) { _ = try await f.service.claimScreenEvidenceDerivation(f.request, for: .localUser) }
            let presentation = ProgressiveRecallService(database: f.database, adapter: f.adapter,
                configuration: { config }, imageReader: { _ in throw EvidenceUnavailableReason.unsupported })
            let retained = await presentation.retainedScreen(f.request.expansion.reference, for: .localUser)
            XCTAssertNil(retained)
            try await f.bridge.endSession()
        }
    }

    func testAgentDeniedBeforeClosedWriterOrMetricsAccess() async throws {
        let f = try await makeFixture()
        let token = ScreenEvidencePolicyTransition(session: .init(feedID: f.request.cursor.feedID,
            storeID: f.request.cursor.storeID, writerID: UUID()), policyEpoch: 1, policySHA256: String(repeating: "a", count: 64))
        let claim = ScreenEvidenceDerivationClaim(attemptID: UUID(), request: f.request, policy: token,
            sourceSequence: 1, metadataEpoch: 1, inputSHA256: String(repeating: "b", count: 64),
            inputUTF8Bytes: 4, fragmentCount: 1, nextCursor: nil,
            issuedAt: Date(), deadline: Date().addingTimeInterval(10))
        let receipt = ScreenEvidenceArtifactReceipt(receiptID: UUID(), claim: claim,
            artifactSHA256: String(repeating: "c", count: 64), artifactBytes: 1, stagedAt: Date())
        try await f.database.close()
        let audience = EvidenceAudience.agent(clientID: "ungranted-authored-client")
        await assertAudienceDenied { _ = try await f.service.claimScreenEvidenceDerivation(f.request, for: audience) }
        await assertAudienceDenied { try await f.service.cancelScreenEvidenceDerivation(claim, for: audience) }
        await assertAudienceDenied { _ = try await f.service.stageScreenEvidenceArtifact(claim: claim, data: Data([0]), for: audience) }
        await assertAudienceDenied { _ = try await f.service.readScreenEvidenceArtifact(receipt, for: audience) }
        await assertAudienceDenied { _ = try await f.service.compactScreenEvidenceArtifacts(for: audience) }
    }

    func testCancelledOwnerCanReleaseItsClaimBeforeDeadline() async throws {
        let f = try await makeFixture()
        let token = try await f.bridge.beginSession(config: CaptureConfig())
        try await f.bridge.activate(token)
        let claim = try await f.service.claimScreenEvidenceDerivation(f.request, for: .localUser)
        let gate = makeGate()
        let cancellation = launch {
            await gate.hold()
            try await f.service.cancelScreenEvidenceDerivation(claim, for: .localUser)
        }
        guard await requireEntry(gate) else { return }
        cancellation.cancel()
        await gate.release()
        do { try await cancellation.value }
        catch { XCTFail("Owned cleanup must reach SQLite despite caller cancellation: \(error)") }
        let replacement = try await f.service.claimScreenEvidenceDerivation(f.request, for: .localUser)
        XCTAssertNotEqual(replacement.attemptID, claim.attemptID)
    }

    func testPolicyRevocationDuringReadMetricCannotDiscloseStagedBytes() async throws {
        let f = try await makeFixture()
        let token = try await f.bridge.beginSession(config: CaptureConfig())
        try await f.bridge.activate(token)
        let claim = try await f.service.claimScreenEvidenceDerivation(f.request, for: .localUser)
        let receipt = try await f.service.stageScreenEvidenceArtifact(claim: claim, data: f.artifact, for: .localUser)
        let gate = makeGate()
        await f.service.setMetricCheckpointForTesting { action in
            if action == .evidenceArtifactRead { await gate.hold() }
        }
        let reader = launch { _ = try await f.service.readScreenEvidenceArtifact(receipt, for: .localUser) }
        guard await requireEntry(gate) else { return }
        try await f.bridge.revoke(token)
        await gate.release()
        await assertAdmissionError(.inactive) { try await reader.value }
    }

    func testCancellationDuringReadMetricCannotDiscloseStagedBytes() async throws {
        let f = try await makeFixture()
        let token = try await f.bridge.beginSession(config: CaptureConfig())
        try await f.bridge.activate(token)
        let claim = try await f.service.claimScreenEvidenceDerivation(f.request, for: .localUser)
        let receipt = try await f.service.stageScreenEvidenceArtifact(claim: claim, data: f.artifact, for: .localUser)
        let gate = makeGate()
        await f.service.setMetricCheckpointForTesting { action in
            if action == .evidenceArtifactRead { await gate.hold() }
        }
        let reader = launch { _ = try await f.service.readScreenEvidenceArtifact(receipt, for: .localUser) }
        guard await requireEntry(gate) else { return }
        reader.cancel()
        await gate.release()
        do { try await reader.value; XCTFail("Cancelled artifact read must not return bytes") }
        catch is CancellationError {}
    }

    func testConcurrentInitializationJoinsOneServiceStartup() async throws {
        let services = makeContainer()
        let requests = expectation(description: "both initialization callers entered")
        requests.expectedFulfillmentCount = 2
        let gate = makeGate()
        await services.setInitializationBoundaryForTesting(request: { requests.fulfill() }) { await gate.hold() }
        let first = launch { try await services.initialize() }
        guard await requireEntry(gate) else { return }
        let second = launch { try await services.initialize() }
        await fulfillment(of: [requests], timeout: 3)
        await gate.release()
        try await first.value
        try await second.value
        let calls = await gate.entries
        XCTAssertEqual(calls, 1, "Concurrent startup must install one capable owner and initialize remaining services once")
        try await services.shutdown()
    }

    func testFailedInitializationRevokesTheOwningSession() async throws {
        let services = makeContainer()
        let f = try await makeFixture(database: services.database)
        let observed = ObservedClaims()
        await services.setInitializationBoundaryForTesting {
            let claim = try await f.service.claimScreenEvidenceDerivation(f.request, for: .localUser)
            await observed.append(claim)
            throw FixtureError.interrupted
        }
        do { try await services.initialize(); XCTFail("Expected authored initialization failure") }
        catch FixtureError.interrupted {} catch { XCTFail("Unexpected initialization error: \(error)") }
        let initialized = await services.initialized
        XCTAssertFalse(initialized)
        await assertRefused { _ = try await f.service.claimScreenEvidenceDerivation(f.request, for: .localUser) }
        let claims = await observed.values
        XCTAssertEqual(claims.count, 1, "The owning policy must exist before unrelated service initialization begins")
        try await services.shutdown()
    }

    func testShutdownJoinsAndCancelsIncompleteInitialization() async throws {
        let services = makeContainer()
        let gate = makeGate()
        let shutdownRequested = expectation(description: "shutdown requested")
        let shutdownReceipt = AdmissionOneShotExpectation(shutdownRequested)
        await services.setInitializationBoundaryForTesting(shutdownRequest: { shutdownReceipt.fulfill() }) {
            await gate.hold()
        }
        let startup = launch { try await services.initialize() }
        guard await requireEntry(gate) else { return }
        let shutdown = launch { try await services.shutdown() }
        await fulfillment(of: [shutdownRequested], timeout: 3)
        await gate.release()
        do { try await startup.value; XCTFail("Shutdown must cancel the incomplete owner") }
        catch is CancellationError {} catch RecordingLifecycleError.shuttingDown {}
        try await shutdown.value
        let ready = await services.database.isReady()
        let initialized = await services.initialized
        XCTAssertFalse(ready)
        XCTAssertFalse(initialized)
        do { try await services.initialize(); XCTFail("A shut-down container cannot reactivate an owner") }
        catch RecordingLifecycleError.shuttingDown {}
    }

    func testOwningCallerCancellationRevokesAnAlreadyActivatedInitialization() async throws {
        let services = makeContainer()
        let gate = makeGate()
        await services.setInitializationBoundaryForTesting { await gate.hold() }
        let startup = launch { try await services.initialize() }
        guard await requireEntry(gate) else { return }
        startup.cancel()
        await gate.release()
        do { try await startup.value; XCTFail("Owner cancellation must propagate") }
        catch is CancellationError {}
        let initialized = await services.initialized
        let ready = await services.database.isReady()
        XCTAssertFalse(initialized)
        XCTAssertFalse(ready, "Cancellation joins owner revocation and private writer closure")
        try await services.shutdown()
    }

    private func makeFixture(database supplied: DatabaseManager? = nil,
                             windowTitle: String = "Cedar proposal") async throws -> AdmissionFixture {
        let database = supplied ?? DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let segment = try await database.insertSegment(bundleID: "com.authored.admission", startDate: timestamp,
            endDate: timestamp, windowName: windowTitle, browserUrl: nil, type: 0)
        let frameID = FrameID(value: try await database.insertFrame(FrameReference(id: .init(value: 0), timestamp: timestamp,
            segmentID: .init(value: segment), videoID: .init(value: 0), frameIndexInSegment: 0,
            metadata: FrameMetadata(appBundleID: "com.authored.admission", windowName: windowTitle))))
        let text = "Cedar proposal — amount 47000. Approval NOT GRANTED."
        _ = try await database.indexFrameText(mainText: text, chromeText: nil, windowTitle: windowTitle,
                                             segmentId: segment, frameId: frameID.value)
        let consumer = try await database.beginScreenEvidenceBootstrap(consumerID: UUID(), leaseDuration: 3600)
        let page = try await database.advanceScreenEvidenceConsumer(cursor: consumer.cursor, limit: 200)
        let work = try XCTUnwrap(page.work.first(where: { $0.reference.frameID == frameID }))
        let connection = await database.getConnection()
        let pointer = try XCTUnwrap(connection)
        let adapter = DataAdapter(retraceConnection: SQLiteConnection(db: pointer),
            retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: "/authored-admission-fixture", source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: "/authored-admission-fixture"), database: database)
        let service = ProgressiveRecallService(database: database, adapter: adapter,
            configuration: { XCTFail("Admission must use the writer's atomic policy fence"); return CaptureConfig() },
            imageReader: { _ in XCTFail("Artifact bookkeeping must not decode media"); throw EvidenceUnavailableReason.unsupported })
        let request = ScreenEvidenceDerivationRequest(cursor: consumer.cursor,
            expansion: .init(reference: work.reference, maximumUTF8Bytes: 16), channel: .lexical,
            transformation: .init(identifier: "authored-byte-receipt-v1", fingerprintSHA256: String(repeating: "d", count: 64),
                                  artifactFormat: "authored-utf8-v1"))
        let result = AdmissionFixture(database: database, adapter: adapter, service: service,
            bridge: ScreenEvidenceAdmissionCoordinator(database: database), request: request, artifact: Data(text.utf8))
        fixture = result
        return result
    }

    private func makeContainer() -> ServiceContainer {
        let result = ServiceContainer(inMemory: true)
        containers.append(result)
        return result
    }

    private func makeGate() -> InitializationGate {
        let result = InitializationGate(entered: expectation(description: "private initialization boundary entered"))
        gates.append(result)
        return result
    }

    private func requireEntry(_ gate: InitializationGate) async -> Bool {
        await fulfillment(of: [gate.entered], timeout: 3)
        return await gate.entries > 0
    }

    private func launch(_ operation: @escaping @Sendable () async throws -> Void) -> Task<Void, Error> {
        let task = Task { try await operation() }
        tasks.append(task)
        return task
    }

    private func assertAdmissionError(_ expected: ScreenEvidenceAdmissionError,
        file: StaticString = #filePath, line: UInt = #line, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch let error as ScreenEvidenceAdmissionError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }

    private func assertAudienceDenied(file: StaticString = #filePath, line: UInt = #line,
                                     _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected audience denial", file: file, line: line) }
        catch let error as EvidenceUnavailableReason { XCTAssertEqual(error, .notPermitted, file: file, line: line) }
        catch { XCTFail("Writer accessed before audience denial: \(error)", file: file, line: line) }
    }

    private func assertRefused(file: StaticString = #filePath, line: UInt = #line,
                               _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected revoked admission", file: file, line: line) }
        catch {}
    }

    private func scalar(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw FixtureError.sql }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw FixtureError.sql }
        return sqlite3_column_int64(statement, 0)
    }

    private func strings(_ db: OpaquePointer, _ sql: String) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw FixtureError.sql }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { result.append(String(cString: text)) }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw FixtureError.sql }
        return result
    }

    private enum FixtureError: Error { case sql, interrupted }
}

private struct AdmissionFixture: Sendable {
    let database: DatabaseManager
    let adapter: DataAdapter
    let service: ProgressiveRecallService
    let bridge: ScreenEvidenceAdmissionCoordinator
    let request: ScreenEvidenceDerivationRequest
    let artifact: Data
}

private actor InitializationGate {
    nonisolated let entered: XCTestExpectation
    private(set) var entries = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(entered: XCTestExpectation) { self.entered = entered }

    func hold() async {
        entries += 1
        if entries == 1 { entered.fulfill() }
        if !released { await withCheckedContinuation { held.append($0) } }
    }

    func release() {
        released = true
        let waiters = held; held.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor ObservedClaims {
    private(set) var values: [ScreenEvidenceDerivationClaim] = []
    func append(_ claim: ScreenEvidenceDerivationClaim) { values.append(claim) }
}

/// Teardown may repeat shutdown after this boundary was already observed.
private final class AdmissionOneShotExpectation: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: XCTestExpectation?
    init(_ expectation: XCTestExpectation) { pending = expectation }
    func fulfill() {
        lock.lock()
        let expectation = pending
        pending = nil
        lock.unlock()
        expectation?.fulfill()
    }
}
