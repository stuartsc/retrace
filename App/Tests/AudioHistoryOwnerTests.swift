import Foundation
import Shared
import SQLCipher
import XCTest
@testable import App
@testable import Database

/// The only injected boundary is factory/read scheduling. Evidence always comes
/// from a real private V30 SQLite writer and separately owned committed reader.
final class AudioHistoryOwnerTests: XCTestCase {
    private var directory: URL!
    private var db: OpaquePointer!
    private var owners: [AudioHistoryOwner] = []
    private var gates: [AudioOwnerGate] = []
    private var path: String { directory.appendingPathComponent("authored.sqlite").path }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-owner-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        try await MigrationRunner(db: db).runMigrations()
        let queries = AudioTranscriptionQueries(db: db)
        let start = Date(timeIntervalSince1970: 1_700_000_000.125)
        let batch = "audio/batch_1700000000125_system_authored.m4a"
        _ = try await queries.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(3),
            source: .system, audioPath: batch, audioSize: 4096)
        _ = try await queries.insertTranscription(sessionID: nil, text: "Cedar pricing discussion",
            startTime: start, endTime: start.addingTimeInterval(2), source: .system, confidence: 0.9,
            words: [], audioPath: batch, transcriptionPass: 1, batchAudioPath: batch)
    }
    override func tearDown() async throws {
        // Release externally owned scheduling gates even when an assertion throws.
        for gate in gates { await gate.release() }
        for owner in owners { await owner.close() }
        owners.removeAll(); gates.removeAll()
        if let db { XCTAssertEqual(sqlite3_close_v2(db), SQLITE_OK) }
        db = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testConstructionAndCloseWithoutReadNeverOpenEvidenceOrRunBootstrap() async throws {
        let factory = AudioOwnerFactory(path: path)
        let owner = makeOwner(factory)
        let before = await factory.calls
        XCTAssertEqual(before, 0)
        await owner.close()
        let after = await factory.calls
        XCTAssertEqual(after, 0)
        XCTAssertEqual(try scalar("SELECT throughRowID FROM audio_evidence_state"), 0)
    }

    func testJoinedRollbackCanExplicitlyReopenWithFreshNativeReader() async throws {
        let factory = AudioOwnerFactory(path: path)
        let owner = makeOwner(factory)
        let first = try await owner.searchAudioEvidence(.init(terms: ["Cedar"]))
        await owner.close()
        try await owner.reopenAfterJoinedClose()
        let second = try await owner.searchAudioEvidence(.init(terms: ["Cedar"]))
        XCTAssertEqual(first.hits.first?.snapshot.reference, second.hits.first?.snapshot.reference)
        let calls = await factory.calls
        XCTAssertEqual(calls, 2)
    }

    func testConcurrentExplicitReadsCoalesceOneActualReaderFactory() async throws {
        let entered = expectation(description: "factory entered")
        let gate = makeGate(entered)
        let factory = AudioOwnerFactory(path: path, gate: gate)
        let owner = makeOwner(factory)
        let first = Task { try await owner.searchAudioEvidence(.init(terms: ["pricing"])) }
        await fulfillment(of: [entered], timeout: 3)
        let second = Task { try await owner.searchAudioEvidence(.init(terms: ["Cedar"])) }
        await gate.release()
        let a = try await first.value, b = try await second.value
        let calls = await factory.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(a.hits.first?.snapshot.text, "Cedar pricing discussion")
        XCTAssertEqual(a.stamp?.readerID, b.stamp?.readerID)
        XCTAssertEqual(a.hits.first?.snapshot.reference, b.hits.first?.snapshot.reference)
    }

    func testCloseWaitsForLateFactoryAndDisposesItsReaderWithoutExposingText() async throws {
        let entered = expectation(description: "factory entered")
        let gate = makeGate(entered)
        let factory = AudioOwnerFactory(path: path, gate: gate)
        let owner = makeOwner(factory)
        let pending = Task { try await owner.searchAudioEvidence(.init(terms: ["pricing"])) }
        await fulfillment(of: [entered], timeout: 3)
        let closed = AudioOwnerFlag()
        let closing = Task { await owner.close(); await closed.set() }
        await waitForCloseAdmission(owner)
        let premature = await closed.value
        XCTAssertFalse(premature)
        do { _ = try await owner.audioEvidenceCoverage(); XCTFail("Closed owner admitted new work") }
        catch AudioEvidenceError.readerClosed { }
        await gate.release()
        await closing.value
        do { _ = try await pending.value; XCTFail("Late factory returned text") }
        catch AudioEvidenceError.readerClosed { }
        let created = await factory.createdReader()
        let reader = try XCTUnwrap(created)
        let readerClosed = await reader.closed
        XCTAssertTrue(readerClosed)
        let calls = await factory.calls
        XCTAssertEqual(calls, 1)
    }

    func testCancellingOneCallerDoesNotCancelAnotherCoalescedRead() async throws {
        let entered = expectation(description: "factory entered")
        let gate = makeGate(entered)
        let factory = AudioOwnerFactory(path: path, gate: gate)
        let owner = makeOwner(factory)
        let cancelled = Task { try await owner.searchAudioEvidence(.init(terms: ["pricing"])) }
        await fulfillment(of: [entered], timeout: 3)
        let retained = Task { try await owner.searchAudioEvidence(.init(terms: ["pricing"])) }
        cancelled.cancel()
        await gate.release()
        do { _ = try await cancelled.value; XCTFail("Cancelled caller returned text") }
        catch is CancellationError { }
        let page = try await retained.value
        XCTAssertEqual(page.hits.first?.snapshot.text, "Cedar pricing discussion")
        let calls = await factory.calls
        XCTAssertEqual(calls, 1)
    }

    func testJoinedCloseWaitsForRealReaderMetricAndCanBeCalledTwice() async throws {
        let entered = expectation(description: "reader metric entered")
        let gate = makeGate(entered)
        let factory = AudioOwnerFactory(path: path, metricGate: gate)
        let owner = makeOwner(factory)
        let reading = Task { try await owner.searchAudioEvidence(.init(terms: ["pricing"])) }
        await fulfillment(of: [entered], timeout: 3)
        let flag = AudioOwnerFlag()
        let closing = Task { await owner.close(); await flag.set() }
        let alsoClosing = Task { await owner.close() }
        await waitForCloseAdmission(owner)
        let early = await flag.value
        XCTAssertFalse(early)
        closing.cancel()
        await gate.release()
        await closing.value; await alsoClosing.value
        do { _ = try await reading.value; XCTFail("Closed during actual read") }
        catch AudioEvidenceError.readerClosed { }
        let calls = await gate.calls
        do { _ = try await owner.searchAudioEvidence(.init(terms: ["pricing"])); XCTFail("No reopened owner") }
        catch AudioEvidenceError.readerClosed { }
        let after = await gate.calls
        XCTAssertEqual(after, calls, "No callbacks after joined close")
    }

    func testFactoryFailureCanRetryButReplacementCannotReuseOldReaderStamp() async throws {
        let failed = AudioOwnerFactory(path: path, failFirst: true)
        let old = makeOwner(failed)
        do { _ = try await old.audioEvidenceCoverage(); XCTFail("Factory should fail") }
        catch AudioEvidenceError.integrityFailure { }
        let page = try await old.searchAudioEvidence(.init(terms: ["pricing"]))
        await old.close()
        let replacement = makeOwner(AudioOwnerFactory(path: path))
        let fresh = try await replacement.searchAudioEvidence(.init(terms: ["pricing"]))
        XCTAssertNotEqual(fresh.stamp?.readerID, page.stamp?.readerID)
        do { try await replacement.revalidateAudioEvidence(try XCTUnwrap(page.stamp), references: []); XCTFail("Retired stamp reused") }
        catch AudioEvidenceError.dataChanged { }
        XCTAssertEqual(fresh.hits.first?.snapshot.reference, page.hits.first?.snapshot.reference)
    }

    private func makeOwner(_ factory: AudioOwnerFactory) -> AudioHistoryOwner {
        let owner = AudioHistoryOwner(factory: { try await factory.open() }); owners.append(owner); return owner
    }
    private func makeGate(_ entered: XCTestExpectation) -> AudioOwnerGate {
        let gate = AudioOwnerGate(entered: entered); gates.append(gate); return gate
    }
    private func waitForCloseAdmission(_ owner: AudioHistoryOwner) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await owner.isClosed), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        let isClosed = await owner.isClosed; XCTAssertTrue(isClosed)
    }
    private func scalar(_ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw AudioEvidenceError.integrityFailure }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw AudioEvidenceError.integrityFailure }
        return sqlite3_column_int64(statement, 0)
    }
}

private actor AudioOwnerFactory {
    let path: String
    let gate: AudioOwnerGate?
    let metricGate: AudioOwnerGate?
    let failFirst: Bool
    private(set) var calls = 0
    private var reader: NativeAudioEvidenceStore?
    init(path: String, gate: AudioOwnerGate? = nil, metricGate: AudioOwnerGate? = nil, failFirst: Bool = false) {
        self.path = path; self.gate = gate; self.metricGate = metricGate; self.failFirst = failFirst
    }
    func open() async throws -> any AudioEvidenceStoreProtocol {
        calls += 1
        if failFirst && calls == 1 { throw AudioEvidenceError.integrityFailure }
        await gate?.hold()
        // Intentionally complete a non-cooperative late factory after cancel;
        // the owner must join and dispose this genuinely acquired reader.
        let metric: (@Sendable (String, Int) async throws -> Void)?
        if let gate = metricGate { metric = { _, _ in await gate.hold() } }
        else { metric = nil }
        let result = try NativeAudioEvidenceStore(connection: SQLiteConnection(readOnlyDatabasePath: path), metric: metric)
        reader = result; return result
    }
    func createdReader() -> NativeAudioEvidenceStore? { reader }
}
private actor AudioOwnerGate {
    let entered: XCTestExpectation
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    init(entered: XCTestExpectation) { self.entered = entered }
    func hold() async { calls += 1; entered.fulfill(); if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor AudioOwnerFlag { private(set) var value = false; func set() { value = true } }
