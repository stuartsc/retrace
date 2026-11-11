import CoreGraphics
import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database
@testable import Search

/// Real canonical SQLCipher publication and retrieval. The deterministic runtime
/// replays the pinned authored model oracle for scheduling tests; the separately
/// gated integration case runs the actual verified native Core ML model.
final class SemanticRecallEngineTests: XCTestCase {
    private var store: SemanticEngineTestStore!
    private var oracle: EngineOracle!
    private var runtime: SemanticEngineFixtureRuntime!
    private var engine: SemanticRecallEngine!
    private var metrics: EngineTestMetrics!
    private var responseGate: EnginePublicResponseGate?

    override func setUp() async throws {
        store = SemanticEngineTestStore()
        try await store.initialize()
        oracle = try MiniLMFixture.read(EngineOracle.self, "embedding-oracle.json")
        runtime = SemanticEngineFixtureRuntime(oracle: oracle)
        metrics = EngineTestMetrics()
        let runtime = runtime!, metrics = metrics!
        engine = SemanticRecallEngine(store: store, makeRuntime: { runtime }, recordMetric: { metrics.append($0) },
            configuration: .init(backgroundPagesPerYield: 64, backgroundYieldMilliseconds: 0))
    }
    override func tearDown() async throws {
        if let responseGate { await responseGate.release() }
        if let store { await store.releaseRevalidation() }
        if let engine { try await engine.stop() }
        if let store { try await store.close() }
    }

    func testRealSQLiteRanksAllAuthoredScreensAndPreservesExactSupportingReferences() async throws {
        var references: [String: ScreenEvidenceRef] = [:]
        for item in oracle.cases where item.kind == "screen" { references[item.id] = try await store.insert(item.text) }
        try await engine.start()
        try await waitForCompleted(references.count)
        for item in oracle.cases where item.kind == "question" {
            let response = try await engine.search(.init(text: item.text, limit: 8, maximumDuration: 30))
            let expected = try XCTUnwrap(oracle.rankings[item.id]).compactMap { references[$0] }
            XCTAssertEqual(response.matches.map(\.reference), expected, item.id)
            XCTAssertTrue(response.scanComplete)
            XCTAssertTrue(response.matches.allSatisfy { !$0.spans.isEmpty && $0.reference.source == .native })
            try await store.revalidateSemanticRecallRead(stamp: response.stamp)
        }
        let maximumConcurrent = await runtime.maximumConcurrentPredictions()
        XCTAssertEqual(maximumConcurrent, 1)
    }

    func testConcurrentStartCallsCoalesceOnePrepareAndJoinedStopHasNoLateMetrics() async throws {
        let current = engine!
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { try await current.start() } }
            try await group.waitForAll()
        }
        let preparationCount = await runtime.preparationCount()
        XCTAssertEqual(preparationCount, 1)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { try await current.stop() } }
            try await group.waitForAll()
        }
        let atClose = metrics.snapshot().count
        let stoppedStatus = await engine.status()
        XCTAssertEqual(stoppedStatus.phase, .stopped)
        do { _ = try await engine.search(.init(text: "after explicit stop")); XCTFail("Stopped engine cannot reactivate from a query") }
        catch { XCTAssertEqual(error as? SemanticRecallEngineError, .stopped) }
        await Task.yield()
        XCTAssertEqual(metrics.snapshot().count, atClose)
        let closeCount = await runtime.closeCount()
        XCTAssertEqual(closeCount, 1)
    }

    func testForegroundQuestionCancelsAndJoinsBackgroundInferenceBeforePredicting() async throws {
        let screen = try XCTUnwrap(oracle.cases.first { $0.kind == "screen" })
        let question = try XCTUnwrap(oracle.cases.first { $0.kind == "question" })
        _ = try await store.insert(screen.text)
        await runtime.pauseNextEmbedding()
        try await engine.start()
        try await waitForRuntimePause()
        let response = try await engine.search(.init(text: question.text, maximumDuration: 30))
        XCTAssertTrue(response.matches.isEmpty, "Cancelled unpublished inference must not become a candidate")
        let cancellationCount = await runtime.cancellationCount()
        XCTAssertEqual(cancellationCount, 1)
        let maximumConcurrent = await runtime.maximumConcurrentPredictions()
        XCTAssertEqual(maximumConcurrent, 1)
        try await waitForCompleted(1)
    }

    func testStopJoinsAnActiveQuestionAndPostStopCallsCannotEmitMetrics() async throws {
        let question = try XCTUnwrap(oracle.cases.first { $0.kind == "question" })
        try await engine.start()
        await runtime.pauseNextEmbedding()
        let current = engine!
        let query = Task { try await current.search(.init(text: question.text)) }
        try await waitForRuntimePause()
        try await engine.stop()
        let snapshot = metrics.snapshot()
        do { _ = try await query.value; XCTFail("Stopped query escaped") } catch { }
        let stoppedStatus = await engine.status()
        XCTAssertEqual(stoppedStatus.phase, .stopped)
        XCTAssertEqual(metrics.snapshot().count, snapshot.count)
        XCTAssertEqual(snapshot.last?.operation, .shutdown)
    }

    func testCallerCancellationAfterCompletedPredictionCannotEscapePublicReturn() async throws {
        let question = try XCTUnwrap(oracle.cases.first { $0.kind == "question" })
        try await engine.start()
        let gate = EnginePublicResponseGate(); responseGate = gate
        await engine.setPublicResponseCheckpointForTesting { await gate.enter() }
        let current = engine!
        let request = Task { try await current.search(.init(text: question.text, maximumDuration: 30)) }
        try await eventually { await gate.isEntered() }
        request.cancel()
        await gate.release()
        do { _ = try await request.value; XCTFail("Cancelled completed response escaped") }
        catch is CancellationError { }
    }

    func testNewerQuestionAfterCompletedPredictionSuppressesOlderPublicReturn() async throws {
        let questions = oracle.cases.filter { $0.kind == "question" }
        try await engine.start()
        let gate = EnginePublicResponseGate(); responseGate = gate
        await engine.setPublicResponseCheckpointForTesting { await gate.enter() }
        let current = engine!
        let older = Task { try await current.search(.init(text: questions[0].text, maximumDuration: 30)) }
        try await eventually { await gate.isEntered() }
        _ = try await engine.search(.init(text: questions[1].text, maximumDuration: 30))
        await gate.release()
        do { _ = try await older.value; XCTFail("Superseded completed response escaped") }
        catch is CancellationError { }
    }

    func testStopAfterCompletedPredictionSuppressesPendingPublicReturn() async throws {
        let question = try XCTUnwrap(oracle.cases.first { $0.kind == "question" })
        try await engine.start()
        let gate = EnginePublicResponseGate(); responseGate = gate
        await engine.setPublicResponseCheckpointForTesting { await gate.enter() }
        let current = engine!
        let request = Task { try await current.search(.init(text: question.text, maximumDuration: 30)) }
        try await eventually { await gate.isEntered() }
        try await engine.stop()
        let count = metrics.snapshot().count
        await gate.release()
        do { _ = try await request.value; XCTFail("Stopped completed response escaped") }
        catch is CancellationError { }
        XCTAssertEqual(metrics.snapshot().count, count)
    }

    func testForegroundPreemptionRetriesARealFailedClaimCancellationBeforePrediction() async throws {
        let screen = try XCTUnwrap(oracle.cases.first { $0.kind == "screen" })
        let question = try XCTUnwrap(oracle.cases.first { $0.kind == "question" })
        _ = try await store.insert(screen.text)
        await runtime.pauseNextEmbedding()
        try await engine.start(); try await waitForRuntimePause()
        await store.failCancellationWrites(1)
        _ = try await engine.search(.init(text: question.text, maximumDuration: 30))
        let failures = await store.cancellationWriteFailures()
        XCTAssertEqual(failures, 1)
        XCTAssertTrue(metrics.snapshot().contains { $0.operation == .work && $0.outcome == .failed })
        try await waitForCompleted(1)
        let claimed = try await store.claimedCount()
        XCTAssertEqual(claimed, 0)
    }

    func testFailedClaimCleanupRetainsExactSQLiteAttemptUntilJoinedStopRetry() async throws {
        let screen = try XCTUnwrap(oracle.cases.first { $0.kind == "screen" })
        _ = try await store.insert(screen.text)
        await runtime.pauseNextEmbedding()
        try await engine.start(); try await waitForRuntimePause()
        await store.failCancellationWrites(2)
        do { try await engine.stop(); XCTFail("Unresolved claimed row was discarded") }
        catch { XCTAssertEqual(error as? SemanticRecallEngineError, .cleanupFailed) }
        let retained = try await store.claimedCount(), state = await engine.status()
        XCTAssertEqual(retained, 1)
        XCTAssertEqual(state.phase, .failed)
        try await engine.stop()
        let remaining = try await store.claimedCount(), closes = await runtime.closeCount()
        XCTAssertEqual(remaining, 0)
        XCTAssertEqual(closes, 1)
    }

    func testDeletionBetweenReadAndFinalRevalidationReturnsNoAnswer() async throws {
        let screen = try XCTUnwrap(oracle.cases.first { $0.kind == "screen" })
        let question = try XCTUnwrap(oracle.cases.first { $0.kind == "question" })
        let reference = try await store.insert(screen.text)
        try await engine.start(); try await waitForCompleted(1)
        await store.pauseNextRevalidation()
        let current = engine!
        let query = Task { try await current.search(.init(text: question.text, maximumDuration: 30)) }
        try await eventually { await self.store.isRevalidationPaused() }
        try await store.delete(reference.frameID)
        await store.releaseRevalidation()
        do { _ = try await query.value; XCTFail("Deleted evidence escaped") }
        catch { XCTAssertEqual(error as? SemanticRecallEngineError, .staleEvidence) }
        let storedWindows = try await store.windowCount()
        XCTAssertEqual(storedWindows, 0)
    }

    func testBoundedScanReportsPartialInsteadOfClaimingCompleteTopResults() async throws {
        let screen = try XCTUnwrap(oracle.cases.first { $0.kind == "screen" })
        let question = try XCTUnwrap(oracle.cases.first { $0.kind == "question" })
        for _ in 0..<140 { _ = try await store.insert(screen.text) }
        try await engine.start(); try await waitForCompleted(140)
        let response = try await engine.search(.init(text: question.text, limit: 5, maximumPages: 1, maximumDuration: 30))
        XCTAssertFalse(response.scanComplete)
        XCTAssertEqual(response.scannedWindowCount, 128)
        XCTAssertEqual(response.matches.count, 5)
    }

    func testInvalidAndOversizedQuestionsNeverReachPrediction() async throws {
        try await engine.start()
        for request in [SemanticRecallQuestion(text: " \n"), .init(text: String(repeating: "a", count: 32_769)),
                        .init(text: "valid authored input", limit: 0), .init(text: "valid authored input", maximumPages: 0)] {
            do { _ = try await engine.search(request); XCTFail("Invalid request accepted") }
            catch { XCTAssertEqual(error as? SemanticRecallEngineError, .invalidQuestion) }
        }
        let embeddingCount = await runtime.embeddingCount()
        XCTAssertEqual(embeddingCount, 0)
    }

    func testIncompleteQuestionWindowPlanIsRejectedWithoutSearchingAPrefix() async throws {
        let question = try XCTUnwrap(oracle.cases.first { $0.kind == "long" })
        try await engine.start()
        await runtime.truncateNextOutput()
        do { _ = try await engine.search(.init(text: question.text)); XCTFail("Incomplete query windows accepted") }
        catch { XCTAssertEqual(error as? LocalEmbeddingError, .invalidOutput) }
    }

    func testNewestQuestionSupersedesAndJoinsThePreviousNativeRequest() async throws {
        let questions = oracle.cases.filter { $0.kind == "question" }
        try await engine.start()
        await runtime.pauseNextEmbedding()
        let current = engine!
        let older = Task { try await current.search(.init(text: questions[0].text, maximumDuration: 30)) }
        try await waitForRuntimePause()
        _ = try await engine.search(.init(text: questions[1].text, maximumDuration: 30))
        do { _ = try await older.value; XCTFail("Superseded request escaped") } catch is CancellationError { }
        let maximum = await runtime.maximumConcurrentPredictions()
        XCTAssertEqual(maximum, 1)
    }

    func testFailedRuntimeCleanupKeepsOwnershipForExplicitStopRetry() async throws {
        try await engine.start()
        await runtime.failNextClose()
        do { try await engine.stop(); XCTFail("Expected injected cleanup failure") }
        catch { XCTAssertEqual(error as? SemanticRecallEngineError, .cleanupFailed) }
        let failed = await engine.status()
        XCTAssertEqual(failed.phase, .failed)
        try await engine.stop()
        let stopped = await engine.status(), closes = await runtime.closeCount()
        XCTAssertEqual(stopped.phase, .stopped)
        XCTAssertEqual(closes, 2)
    }

    func testActualNativeRuntimeAndRealSQLiteResolveTheAuthoredMoment() async throws {
        guard let path = ProcessInfo.processInfo.environment["RETRACE_MINILM_MODEL_PACKAGE"], !path.isEmpty else {
            throw XCTSkip("Native semantic integration requires the explicit pinned local model package")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SemanticNative-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let config = LocalEmbeddingConfiguration(modelPackageURL: URL(fileURLWithPath: path),
            tokenizerURL: try MiniLMFixture.url("tokenizer.json"), privateCacheParentURL: root)
        let native = SemanticRecallEngine(store: store, makeRuntime: { LocalEmbeddingRuntime(configuration: config, recordMetric: { _ in }) },
                                          recordMetric: { _ in })
        let screen = try XCTUnwrap(oracle.cases.first { $0.kind == "screen" })
        let question = try XCTUnwrap(oracle.cases.first { $0.kind == "question" })
        let reference = try await store.insert(screen.text)
        do {
            try await native.start()
            try await eventually(seconds: 120) { await native.status().coverage?.completedObservations == 1 }
            let result = try await native.search(.init(text: question.text, maximumDuration: 30))
            XCTAssertEqual(result.matches.first?.reference, reference)
            XCTAssertTrue(result.scanComplete)
            XCTAssertFalse(try XCTUnwrap(result.matches.first).spans.isEmpty)
            try await native.stop()
        } catch { try? await native.stop(); throw error }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func waitForCompleted(_ count: Int) async throws {
        try await eventually(seconds: 60) { await self.engine.status().coverage?.completedObservations == count }
    }
    private func waitForRuntimePause() async throws {
        try await eventually { await self.runtime.isPaused() }
    }
    private func eventually(seconds: TimeInterval = 10, _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Bounded asynchronous condition did not complete")
        throw SemanticRecallEngineError.stopped
    }
}

private struct EngineOracle: Decodable, Sendable {
    let cases: [Item]
    let rankings: [String: [String]]
    struct Item: Decodable, Sendable {
        let id: String; let kind: String; let text: String; let windows: [Window]
    }
    struct Window: Decodable, Sendable {
        let tokenStart: Int; let tokenEnd: Int; let utf16Range: EvidenceUTF16Range; let vector: [Float]
    }
}

private actor SemanticEngineFixtureRuntime: LocalEmbeddingRuntimeProtocol {
    let oracle: EngineOracle
    var prepares = 0, embeds = 0, active = 0, maximumActive = 0, cancelled = 0, closes = 0
    var shouldPause = false, paused = false
    var shouldTruncate = false, shouldFailClose = false
    init(oracle: EngineOracle) { self.oracle = oracle }
    func prepare() async throws -> LocalEmbeddingDescriptor { try Task.checkCancellation(); prepares += 1; return .miniLM }
    func embed(_ text: String) async throws -> LocalEmbeddingBatch {
        active += 1; maximumActive = max(maximumActive, active); embeds += 1
        defer { active -= 1; paused = false }
        do {
            if shouldPause {
                shouldPause = false; paused = true
                let stream = AsyncStream<Void> { _ in }
                for await _ in stream { break }
            }
            try Task.checkCancellation()
            guard let item = oracle.cases.first(where: { $0.text == text }) else { throw LocalEmbeddingError.invalidOutput }
            let selected = shouldTruncate ? Array(item.windows.dropLast()) : item.windows
            shouldTruncate = false
            return .init(descriptor: .miniLM, windows: selected.map {
                .init(tokenStart: $0.tokenStart, tokenEnd: $0.tokenEnd, inputUTF16Range: $0.utf16Range, vector: $0.vector)
            })
        } catch is CancellationError { cancelled += 1; throw CancellationError() }
    }
    func status() -> LocalEmbeddingStatus { .init(isPrepared: prepares > 0, isEmbedding: active > 0, completedWindowCount: 0, totalWindowCount: 0) }
    func close() async throws {
        closes += 1
        if shouldFailClose { shouldFailClose = false; throw LocalEmbeddingError.cleanupFailed }
    }
    func pauseNextEmbedding() { shouldPause = true }
    func truncateNextOutput() { shouldTruncate = true }
    func failNextClose() { shouldFailClose = true }
    func isPaused() -> Bool { paused }
    func preparationCount() -> Int { prepares }
    func embeddingCount() -> Int { embeds }
    func cancellationCount() -> Int { cancelled }
    func maximumConcurrentPredictions() -> Int { maximumActive }
    func closeCount() -> Int { closes }
}

private final class EngineTestMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SemanticRecallMetric] = []
    func append(_ value: SemanticRecallMetric) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [SemanticRecallMetric] { lock.lock(); defer { lock.unlock() }; return values }
}

/// No DatabaseManager initialization, which historically probes the user's
/// Rewind path to offset IDs. This actor owns a private raw SQLCipher handle and
/// runs the exact production migration, admission and V25 transaction engines.
private actor SemanticEngineTestStore: SemanticRecallStoreProtocol {
    private var db: OpaquePointer!
    private var capability = ScreenEvidenceAdmissionCapability()
    private var storeID: UUID!
    private var pauseRevalidation = false
    private var revalidationPaused = false
    private var revalidationContinuation: CheckedContinuation<Void, Never>?
    private var cancellationFailuresRemaining = 0
    private var cancellationFailures = 0
    func initialize() async throws {
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else { throw SemanticRecallError.integrityFailure }
        try PipelineSQL.execute(db, "PRAGMA foreign_keys=ON")
        try await MigrationRunner(db: db).runMigrations()
        storeID = try RecallSQL.nativeStore(db)
        try PipelineSQL.execute(db, "INSERT INTO segment(id,bundleID,startDate,endDate,windowName,type) VALUES(1,'com.authored.semantic',1800000000000,1800000000000,'Authored context',0)")
        let transition = try ScreenEvidenceAdmissionSQL.begin(db, capability: &capability, policy: .init(config: CaptureConfig()))
        try ScreenEvidenceAdmissionSQL.activate(db, capability: &capability, transition: transition)
    }
    func insert(_ text: String) throws -> ScreenEvidenceRef {
        try PipelineSQL.transaction(db) {
            let frame = FrameReference(id: .init(value: 0), timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                segmentID: .init(value: 1), frameIndexInSegment: 0,
                metadata: .init(appBundleID: "com.authored.semantic", windowName: "Authored context"))
            let id = try FrameQueries.insert(db: db, frame: frame)
            try ScreenEvidenceSQL.capture(db, frameID: id, descriptor: frame)
            _ = try ScreenEvidenceSQL.commitLegacyText(db, frameID: .init(value: id), mainText: text, chromeText: nil)
            return try XCTUnwrap(ScreenEvidenceSQL.current(db, frameID: .init(value: id), storeID: storeID)).ref
        }
    }
    func delete(_ frameID: FrameID) throws { try PipelineSQL.execute(db, "DELETE FROM frame WHERE id=?", [.integer(frameID.value)]) }
    func windowCount() throws -> Int64 { try XCTUnwrap(PipelineSQL.integers(db, "SELECT COUNT(*) FROM semantic_recall_window").first) }
    func close() throws { if let db { XCTAssertEqual(sqlite3_close_v2(db), SQLITE_OK); self.db = nil } }
    func beginSemanticRecall(transformation: SemanticRecallTransformation, leaseDuration: TimeInterval) throws -> SemanticRecallCursor {
        try SemanticRecallSQL.begin(db, capability: &capability, transformation: transformation, leaseDuration: leaseDuration)
    }
    func claimSemanticRecallWork(cursor: SemanticRecallCursor, maximumInspected: Int, executionDuration: TimeInterval) throws -> SemanticRecallWorkPage {
        try SemanticRecallSQL.claim(db, capability: &capability, cursor: cursor, maximumInspected: maximumInspected, executionDuration: executionDuration)
    }
    func publishSemanticRecall(claim: SemanticRecallClaim, windows: [SemanticRecallVectorWindow]) throws -> SemanticRecallPublication {
        try SemanticRecallSQL.publish(db, capability: &capability, claim: claim, windows: windows)
    }
    func cancelSemanticRecall(claim: SemanticRecallClaim) throws {
        if cancellationFailuresRemaining > 0 {
            cancellationFailuresRemaining -= 1; cancellationFailures += 1
            sqlite3_commit_hook(db, { _ in 1 }, nil)
            defer { sqlite3_commit_hook(db, nil, nil) }
            try SemanticRecallSQL.cancel(db, capability: &capability, claim: claim)
        } else { try SemanticRecallSQL.cancel(db, capability: &capability, claim: claim) }
    }
    func failCancellationWrites(_ count: Int) { cancellationFailuresRemaining = count }
    func cancellationWriteFailures() -> Int { cancellationFailures }
    func claimedCount() throws -> Int64 {
        try XCTUnwrap(PipelineSQL.integers(db, "SELECT COUNT(*) FROM semantic_recall_attempt WHERE status='claimed'").first)
    }
    func semanticRecallCoverage(cursor: SemanticRecallCursor) throws -> SemanticRecallCoverage {
        try SemanticRecallSQL.coverage(db, capability: &capability, cursor: cursor)
    }
    func readSemanticRecallVectors(request: SemanticRecallVectorReadRequest) throws -> SemanticRecallVectorPage {
        try SemanticRecallSQL.read(db, capability: &capability, request: request)
    }
    func revalidateSemanticRecallRead(stamp: SemanticRecallReadStamp) async throws {
        if pauseRevalidation {
            pauseRevalidation = false; revalidationPaused = true
            await withCheckedContinuation { revalidationContinuation = $0 }
            revalidationPaused = false
        }
        try SemanticRecallSQL.revalidate(db, capability: &capability, stamp: stamp)
    }
    func pauseNextRevalidation() { pauseRevalidation = true }
    func isRevalidationPaused() -> Bool { revalidationPaused }
    func releaseRevalidation() { revalidationContinuation?.resume(); revalidationContinuation = nil }
}

/// One-shot gate between the owned query Task's completion and public return.
/// Teardown always releases it before joining the engine.
private actor EnginePublicResponseGate {
    private var shouldPause = true
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func enter() async {
        guard shouldPause else { return }
        shouldPause = false; entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func isEntered() -> Bool { entered }
    func release() { shouldPause = false; continuation?.resume(); continuation = nil }
}
