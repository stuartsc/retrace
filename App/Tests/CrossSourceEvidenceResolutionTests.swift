import Foundation
import Shared
import SQLCipher
import Storage
import XCTest
@testable import App
@testable import Database

/// Real private canonical job/audio stores. Audio deliberately lives in a
/// different native database from the screen adapter; no frame/media is created.
final class CrossSourceEvidenceResolutionTests: XCTestCase {
    private var root: URL!
    private var database: DatabaseManager!
    private var adapter: DataAdapter!
    private var audioDB: OpaquePointer!
    private var audioQueries: AudioTranscriptionQueries!
    private var audioReader: NativeAudioEvidenceStore!
    private var audioRowID: Int64 = 0
    private var audioSnapshot: AudioEvidenceSnapshot!
    private var jobWriter: JobWriterSession!
    private var jobPolicy: ScreenEvidencePolicyTransition!
    private var gates: [CrossSourceConfigurationGate] = []
    private var resolutions: [Task<EvidenceResolution, Never>] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cross-source-resolution-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = DatabaseManager(databasePath: "file:cross-source-screen-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let pointer = await database.getConnection()
        adapter = DataAdapter(retraceConnection: SQLiteConnection(db: try XCTUnwrap(pointer)),
            retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
        try await adapter.initialize()
        let path = root.appendingPathComponent("authored-audio.sqlite").path
        XCTAssertEqual(sqlite3_open_v2(path, &audioDB, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(audioDB, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        try await MigrationRunner(db: audioDB).runMigrations()
        audioQueries = AudioTranscriptionQueries(db: audioDB)
        let start = Date(timeIntervalSince1970: 1_700_000_000.125)
        let batch = "audio/batch_1700000000125_system_authored.m4a"
        _ = try await audioQueries.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(3),
            source: .system, audioPath: batch, audioSize: 4096)
        audioRowID = try await audioQueries.insertTranscription(sessionID: nil, text: "Cedar pricing needs approval",
            startTime: start, endTime: start.addingTimeInterval(2), source: .system, confidence: 0.95,
            words: [], audioPath: batch, transcriptionPass: 1, batchAudioPath: batch)
        audioReader = try NativeAudioEvidenceStore(connection: SQLiteConnection(readOnlyDatabasePath: path))
        let page = try await audioReader.searchAudioEvidence(.init(terms: ["pricing"]))
        audioSnapshot = try XCTUnwrap(page.hits.first?.snapshot)
        jobPolicy = try await database.beginScreenEvidenceWriterSession(policy: .init(config: CaptureConfig()))
        try await database.activateScreenEvidencePolicy(jobPolicy)
        jobWriter = try await database.openJobWriter(admission: .init(masterGeneration: UUID(), policy: jobPolicy))
    }
    override func tearDown() async throws {
        for gate in gates { await gate.release() }
        for task in resolutions { _ = await task.value }
        resolutions.removeAll(); gates.removeAll()
        await audioReader?.close(); audioReader = nil; audioQueries = nil
        if let audioDB { XCTAssertEqual(sqlite3_close_v2(audioDB), SQLITE_OK) }
        audioDB = nil
        if let jobWriter { try? await database.closeJobWriter(jobWriter, reason: .serviceStopped) }
        await adapter?.shutdown()
        if let database { try await database.close() }
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testExactAudioUsesItsOwnNativeStoreAndDeclaredTimesWithoutAFrame() async throws {
        let screenStore = try await database.originalStoreID()
        XCTAssertNotEqual(screenStore, audioSnapshot.reference.storeID)
        let outcome = await service().resolve(.audio(audioSnapshot.reference), for: .localUser)
        guard case .audio(let value) = outcome else { return XCTFail("Expected standalone exact transcript") }
        XCTAssertEqual(value.reference, audioSnapshot.reference)
        XCTAssertEqual(value.text, "Cedar pricing needs approval")
        XCTAssertEqual(value.startTime, audioSnapshot.startTime)
        XCTAssertEqual(value.endTime, audioSnapshot.endTime)
        XCTAssertEqual(value.mediaAvailability, .notVerified)
        XCTAssertEqual(value.provenance, .declaredOriginalSource)
    }

    func testAudioDeletedLineageCannotResolveOrFallBackToNearbyScreen() async throws {
        _ = try await audioQueries.deleteTranscription(id: audioRowID)
        assertUnavailable(await service().resolve(.audio(audioSnapshot.reference), for: .localUser), .evidenceDeleted)
    }

    func testOldAudioRevisionNeverSubstitutesNewText() async throws {
        try await audioQueries.updateTranscriptionText(id: audioRowID, text: "Birch pricing needs approval")
        assertUnavailable(await service().resolve(.audio(audioSnapshot.reference), for: .localUser), .extractionUnavailable)
        let page = try await audioReader.searchAudioEvidence(.init(terms: ["pricing"]))
        let current = try XCTUnwrap(page.hits.first?.snapshot)
        let outcome = await service().resolve(.audio(current.reference), for: .localUser)
        guard case .audio(let value) = outcome else { return XCTFail("New exact revision must be independently readable") }
        XCTAssertEqual(value.text, "Birch pricing needs approval")
        XCTAssertNotEqual(value.reference, audioSnapshot.reference)
    }

    func testWrongAudioStoreAndClosedReaderReturnUnavailable() async throws {
        let ref = audioSnapshot.reference
        let wrong = AudioEvidenceRef(storeID: UUID(), source: ref.source, segmentID: ref.segmentID,
            transcriptRevision: ref.transcriptRevision, startTime: ref.startTime, endTime: ref.endTime)
        assertUnavailable(await service().resolve(.audio(wrong), for: .localUser), .sourceDisconnected)
        await audioReader.close()
        assertUnavailable(await service().resolve(.audio(ref), for: .localUser), .sourceDisconnected)
    }

    func testMissingAudioReaderIsUnavailableWithoutMediaGuessing() async {
        let resolver = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() },
            imageReader: { _ in XCTFail("Standalone audio never requests pixels"); throw EvidenceUnavailableReason.recordingMissing })
        assertUnavailable(await resolver.resolve(.audio(audioSnapshot.reference), for: .localUser))
    }

    func testStableScreenExclusionsDoNotInventAudioAppAttribution() async {
        let resolver = service(configuration: { CaptureConfig(excludedAppBundleIDs: ["com.authored.screen-only-rule"]) })
        let outcome = await resolver.resolve(.audio(audioSnapshot.reference), for: .localUser)
        guard case .audio(let value) = outcome else { return XCTFail("An unrelated screen rule is not original audio provenance") }
        XCTAssertEqual(value.recordingSource, .system)
        XCTAssertEqual(value.provenance, .declaredOriginalSource)
        XCTAssertEqual(value.mediaAvailability, .notVerified)
    }

    func testAudioDeletionDuringSecondConfigurationReadIsRevalidatedBeforeReturn() async throws {
        let entered = expectation(description: "second configuration read")
        let gate = configurationGate(entered)
        let resolver = service(configuration: { await gate.read() })
        let reference = audioSnapshot.reference
        let task = Task { await resolver.resolve(.audio(reference), for: .localUser) }
        resolutions.append(task)
        await fulfillment(of: [entered], timeout: 3)
        _ = try await audioQueries.deleteTranscription(id: audioRowID)
        await gate.release()
        assertUnavailable(await task.value)
        let canonical = try await audioReader.readAudioEvidence(reference)
        guard case .unavailable(.evidenceDeleted) = canonical else { return XCTFail("Actual canonical deletion required") }
    }

    func testAudioConfigurationChangeDuringReadDiscardsCapturedResult() async throws {
        let entered = expectation(description: "second configuration read")
        let gate = configurationGate(entered)
        let resolver = service(configuration: { await gate.read() })
        let reference = audioSnapshot.reference
        let task = Task { await resolver.resolve(.audio(reference), for: .localUser) }
        resolutions.append(task)
        await fulfillment(of: [entered], timeout: 3)
        await gate.replace(CaptureConfig(excludedAppBundleIDs: ["com.authored.changed-policy"]))
        await gate.release()
        assertUnavailable(await task.value, .notPermitted)
    }

    func testExactJobTerminalResolvesItsCanonicalEventWithoutAFrame() async throws {
        let snapshot = try await job()
        let outcome = await service().resolve(.job(snapshot.reference), for: .localUser)
        guard case .job(let value) = outcome else { return XCTFail("Expected standalone exact job receipt") }
        XCTAssertEqual(value, snapshot)
        XCTAssertEqual(value.observation.outcome, .failed)
        XCTAssertEqual(value.observation.terminationStatus, 2)
    }

    func testJobReadWhilePausedUsesRetainedPolicyWithoutRestartingCapture() async throws {
        let snapshot = try await job()
        try await database.closeJobWriter(jobWriter, reason: .recordingPaused)
        try await database.endScreenEvidenceWriterSession(jobPolicy.session)
        let outcome = await service().resolve(.job(snapshot.reference), for: .localUser)
        guard case .job(let value) = outcome else { return XCTFail("Paused local history must remain readable") }
        XCTAssertEqual(value.reference, snapshot.reference)
        guard case .available(_, let stamp) = try await database.resolveJobEvidence(snapshot.reference) else {
            return XCTFail("Expected retained canonical read")
        }
        XCTAssertEqual(stamp.policyPhase, .revoked)
    }

    func testJobPolicyMismatchAndWrongStoreNeverResolveCurrentReceipt() async throws {
        let snapshot = try await job()
        let restricted = service(configuration: { CaptureConfig(excludedAppBundleIDs: ["com.authored.later-policy"]) })
        assertUnavailable(await restricted.resolve(.job(snapshot.reference), for: .localUser), .notPermitted)
        let ref = snapshot.reference
        let wrong = JobEvidenceRef(storeID: UUID(), producerID: ref.producerID, eventID: ref.eventID, revision: ref.revision)
        assertUnavailable(await service().resolve(.job(wrong), for: .localUser))
        let old = JobEvidenceRef(storeID: ref.storeID, producerID: ref.producerID, eventID: ref.eventID, revision: ref.revision + 1)
        assertUnavailable(await service().resolve(.job(old), for: .localUser))
    }

    func testJobDeletionDuringSecondConfigurationReadIsRevalidatedBeforeReturn() async throws {
        let snapshot = try await job()
        let entered = expectation(description: "second configuration read")
        let gate = configurationGate(entered)
        let resolver = service(configuration: { await gate.read() })
        let task = Task { await resolver.resolve(.job(snapshot.reference), for: .localUser) }
        resolutions.append(task)
        await fulfillment(of: [entered], timeout: 3)
        try await database.deleteJobRun(snapshot.observation.runID, storeID: snapshot.reference.storeID)
        await gate.release()
        assertUnavailable(await task.value)
        let canonical = try await database.resolveJobEvidence(snapshot.reference)
        XCTAssertEqual(canonical, .unavailable(.deleted))
    }

    func testOrdinaryJobDeletionIsReportedAsDeleted() async throws {
        let snapshot = try await job()
        try await database.deleteJobRun(snapshot.observation.runID, storeID: snapshot.reference.storeID)
        assertUnavailable(await service().resolve(.job(snapshot.reference), for: .localUser), .evidenceDeleted)
    }

    func testAgentDenialPrecedesClosedSourceAndConfigurationReads() async throws {
        let snapshot = try await job()
        let resolver = service(configuration: { XCTFail("Agent denial must precede configuration access"); return CaptureConfig() })
        await audioReader.close(); await adapter.shutdown(); try await database.close()
        assertUnavailable(await resolver.resolve(.audio(audioSnapshot.reference), for: .agent(clientID: "authored-broker")), .notPermitted)
        assertUnavailable(await resolver.resolve(.job(snapshot.reference), for: .agent(clientID: "authored-broker")), .notPermitted)
    }

    private func service(configuration: @escaping @Sendable () async -> CaptureConfig = { CaptureConfig() }) -> ProgressiveRecallService {
        ProgressiveRecallService(database: database, adapter: adapter, configuration: configuration, audioHistory: audioReader,
            imageReader: { _ in XCTFail("Audio/job evidence never decodes pixels or guesses a screen"); throw EvidenceUnavailableReason.recordingMissing })
    }
    private func configurationGate(_ expectation: XCTestExpectation) -> CrossSourceConfigurationGate {
        let gate = CrossSourceConfigurationGate(entered: expectation); gates.append(gate); return gate
    }
    private func job() async throws -> JobEventSnapshot {
        let run = JobObservation(runID: UUID(), kind: .build, phase: .started)
        _ = try await database.appendJobStart(run, session: jobWriter)
        return try await database.appendJobEnd(.init(runID: run.runID, kind: .build, phase: .terminal,
            outcome: .failed, terminationStatus: 2), session: jobWriter)
    }
    private func assertUnavailable(_ value: EvidenceResolution, _ reason: EvidenceUnavailableReason? = nil,
                                   file: StaticString = #filePath, line: UInt = #line) {
        guard case .unavailable(let actual) = value else { return XCTFail("Unavailable exact evidence must not return a payload", file: file, line: line) }
        if let reason { XCTAssertEqual(actual, reason, file: file, line: line) }
    }
}

private actor CrossSourceConfigurationGate {
    private let entered: XCTestExpectation
    private var calls = 0
    private var config = CaptureConfig()
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation) { self.entered = entered }
    func read() async -> CaptureConfig {
        calls += 1
        if calls == 2 {
            entered.fulfill()
            if !released { await withCheckedContinuation { continuation = $0 } }
        }
        return config
    }
    func replace(_ next: CaptureConfig) { config = next }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
