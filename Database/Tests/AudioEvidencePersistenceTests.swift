import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database

/// Real private SQLite writer/reader transactions. No installed history or media
/// is opened, and declared transcript text is not an ASR accuracy oracle.
final class AudioEvidencePersistenceTests: XCTestCase {
    private var directory: URL!
    private var writer: OpaquePointer!
    private var queries: AudioTranscriptionQueries!
    private var reader: NativeAudioEvidenceStore!
    private let start = Date(timeIntervalSince1970: 1_700_000_000.125)
    private let batch = "audio/batch_1700000000125_system_authored.m4a"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-evidence-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("authored.sqlite").path
        XCTAssertEqual(sqlite3_open_v2(path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        try sql("PRAGMA journal_mode=WAL")
        try await MigrationRunner(db: writer).runMigrations()
        queries = AudioTranscriptionQueries(db: writer)
        reader = try NativeAudioEvidenceStore(connection: SQLiteConnection(readOnlyDatabasePath: path))
    }

    override func tearDown() async throws {
        await reader?.close()
        reader = nil; queries = nil
        if let writer { XCTAssertEqual(sqlite3_close_v2(writer), SQLITE_OK) }
        writer = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testReceiptBackedTranscriptHasExactStandaloneReferenceAndUnverifiedMedia() async throws {
        _ = try await raw()
        _ = try await sentence("Cedar pricing discussion")
        let page = try await reader.searchAudioEvidence(.init(terms: ["pricing"]))
        let hit = try XCTUnwrap(page.hits.first)
        XCTAssertEqual(page.hits.count, 1)
        XCTAssertEqual(hit.snapshot.reference.source, .native)
        XCTAssertNotNil(UUID(uuidString: hit.snapshot.reference.segmentID))
        XCTAssertEqual(hit.snapshot.reference.startTime, start.timeIntervalSince1970)
        XCTAssertEqual(hit.snapshot.reference.endTime, start.addingTimeInterval(2).timeIntervalSince1970)
        XCTAssertEqual(hit.snapshot.recordingSource, .system)
        XCTAssertEqual(hit.snapshot.mediaAvailability, .notVerified)
        XCTAssertEqual(hit.snapshot.provenance, .declaredOriginalSource)
        let resolved = try await reader.readAudioEvidence(hit.snapshot.reference)
        guard case .available(let snapshot, _) = resolved else { return XCTFail("Exact transcript must resolve") }
        XCTAssertEqual(snapshot.text, "Cedar pricing discussion")
    }

    func testEqualLengthMutationInvalidatesOldReferenceAndSearchStampWithoutSubstitution() async throws {
        _ = try await raw()
        let id = try await sentence("Cedar pricing discussion")
        let before = try await reader.searchAudioEvidence(.init(terms: ["pricing"]))
        let hit = try XCTUnwrap(before.hits.first)
        try await queries.updateTranscriptionText(id: id, text: "Birch pricing discussion")
        let old = try await reader.readAudioEvidence(hit.snapshot.reference)
        guard case .unavailable(.revisionUnavailable) = old else { return XCTFail("Must not substitute new text") }
        do { try await reader.revalidateAudioEvidence(try XCTUnwrap(before.stamp), references: [hit.snapshot.reference]); XCTFail("Stale read") }
        catch AudioEvidenceError.dataChanged { }
        let after = try await reader.searchAudioEvidence(.init(terms: ["pricing"]))
        XCTAssertEqual(after.hits.first?.snapshot.text, "Birch pricing discussion")
        XCTAssertNotEqual(after.hits.first?.snapshot.reference, hit.snapshot.reference)
    }

    func testWriterRollbackIsInvisibleToSeparateReaderAndPreservesRevision() async throws {
        _ = try await raw()
        let id = try await sentence("Cedar pricing discussion")
        let before = try await reader.searchAudioEvidence(.init(terms: ["pricing"]))
        try sql("BEGIN IMMEDIATE")
        try sql("UPDATE audio_captures SET text='Uncommitted private wording' WHERE id=\(id)")
        let during = try await reader.searchAudioEvidence(.init(terms: ["pricing"]))
        XCTAssertEqual(during.hits.first?.snapshot.text, before.hits.first?.snapshot.text)
        XCTAssertEqual(during.stamp, before.stamp)
        try sql("ROLLBACK")
        try await reader.revalidateAudioEvidence(try XCTUnwrap(before.stamp), references: before.hits.map { $0.snapshot.reference })
    }

    func testDeletingOneTranscriptPurgesCopiedLineageAndCannotRebindDeletedRowID() async throws {
        _ = try await raw()
        let id = try await sentence("Cedar pricing discussion")
        _ = try await sentence("Cedar follow up", offset: 2)
        let before = try await reader.searchAudioEvidence(.init(terms: ["Cedar"]))
        _ = try await queries.deleteTranscription(id: id)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_evidence_snapshot"), 0)
        for hit in before.hits {
            let outcome = try await reader.readAudioEvidence(hit.snapshot.reference)
            guard case .unavailable(.evidenceDeleted) = outcome else { return XCTFail("Deleted lineage resolved") }
        }
        XCTAssertNotEqual(sqlite3_exec(writer,
            "INSERT INTO audio_captures(id,text,start_time,end_time,source) VALUES(\(id),'reused',1,2,'system')", nil, nil, nil), SQLITE_OK)
    }

    func testUnknownLineageIsExplicitlyUncoveredAndDoesNotOccupyResultLimit() async throws {
        _ = try await queries.insertTranscription(sessionID: nil, text: "Cedar legacy pricing", startTime: start,
            endTime: start.addingTimeInterval(2), source: .microphone, confidence: nil, words: [],
            audioPath: "audio/unproven.m4a", batchAudioPath: "audio/unproven.m4a")
        _ = try await raw()
        _ = try await sentence("Cedar pricing discussion")
        let page = try await reader.searchAudioEvidence(.init(terms: ["Cedar"], limit: 1))
        XCTAssertEqual(page.hits.count, 1)
        XCTAssertEqual(page.hits.first?.snapshot.recordingSource, .system)
        XCTAssertEqual(page.coverage.scope, .provenNativeTranscripts)
    }

    func testApplicationAndCaptureAttestationRequirementsAreExplicitlyUnsupported() async throws {
        _ = try await raw(); _ = try await sentence("Cedar pricing discussion")
        let app = try await reader.searchAudioEvidence(.init(terms: ["Cedar"], filters: .init(appBundleIDs: ["com.example.editor"])))
        XCTAssertEqual(app.unavailableReason, .unsupportedApplicationScope)
        XCTAssertTrue(app.hits.isEmpty)
        let policy = try await reader.searchAudioEvidence(.init(terms: ["Cedar"], requiresCapturePolicyAttestation: true))
        XCTAssertEqual(policy.unavailableReason, .unattestedCapturePolicy)
        XCTAssertTrue(policy.hits.isEmpty)
    }

    func testRawPlaceholderRetirementKeepsExactTranscriptAvailable() async throws {
        let rawID = try await raw()
        _ = try await sentence("Cedar pricing discussion")
        let before = try await reader.searchAudioEvidence(.init(terms: ["pricing"]))
        let reference = try XCTUnwrap(before.hits.first?.snapshot.reference)
        try await queries.retireRawBatchAfterTranscription(id: rawID)
        let after = try await reader.readAudioEvidence(reference)
        guard case .available(let value, _) = after else { return XCTFail("Retirement is not user deletion") }
        XCTAssertEqual(value.reference, reference)
    }

    func testHigherPassDoesNotSubstituteForEarlierExactReference() async throws {
        _ = try await raw(); _ = try await sentence("Cedar original pricing")
        let before = try await reader.searchAudioEvidence(.init(terms: ["pricing"]))
        _ = try await sentence("Cedar refined pricing", pass: 2)
        let old = try await reader.readAudioEvidence(try XCTUnwrap(before.hits.first?.snapshot.reference))
        guard case .unavailable(.revisionUnavailable) = old else { return XCTFail("Preferred pass changed") }
        let after = try await reader.searchAudioEvidence(.init(terms: ["pricing"]))
        XCTAssertEqual(after.hits.map { $0.snapshot.text }, ["Cedar refined pricing"])
    }

    func testConflictingPassOneSourceInvalidatesAllLineageReads() async throws {
        _ = try await raw(); _ = try await sentence("Cedar pricing")
        let before = try await reader.searchAudioEvidence(.init(terms: ["pricing"]))
        _ = try await queries.insertTranscription(sessionID: nil, text: "Cedar disputed source",
            startTime: start, endTime: start.addingTimeInterval(2), source: .microphone,
            confidence: 0.9, words: [], audioPath: batch, transcriptionPass: 1, batchAudioPath: batch)
        let old = try await reader.readAudioEvidence(try XCTUnwrap(before.hits.first?.snapshot.reference))
        guard case .unavailable(.lineageConflicting) = old else { return XCTFail("No source borrowing") }
        let after = try await reader.searchAudioEvidence(.init(terms: ["Cedar"]))
        XCTAssertTrue(after.hits.isEmpty)
        XCTAssertGreaterThan(after.coverage.unprovenLineageRows, 0)
    }

    func testIndexedInspectionAdvancesPastUnavailableRowsBeforeResultLimit() async throws {
        _ = try await raw(); _ = try await sentence("Cedar pricing")
        for index in 0..<80 {
            _ = try await queries.insertTranscription(sessionID: nil, text: "Cedar legacy \(index)",
                startTime: start, endTime: start.addingTimeInterval(2), source: .system,
                confidence: 0.9, words: [], audioPath: nil, transcriptionPass: 1, batchAudioPath: nil)
        }
        let request = AudioEvidenceSearchRequest(terms: ["Cedar"], limit: 1, maximumInspectedRows: 64)
        let first = try await reader.searchAudioEvidence(request)
        XCTAssertTrue(first.hits.isEmpty)
        XCTAssertEqual(first.coverage.inspectedRows, 64)
        XCTAssertFalse(first.coverage.scanComplete)
        let cursor = try XCTUnwrap(first.nextCursor)
        let next = try await reader.searchAudioEvidence(.init(terms: ["Cedar"], limit: 1,
            maximumInspectedRows: 64, cursor: cursor))
        XCTAssertEqual(next.hits.map { $0.snapshot.text }, ["Cedar pricing"])
        do {
            _ = try await reader.searchAudioEvidence(.init(terms: ["different"], limit: 1,
                maximumInspectedRows: 64, cursor: cursor))
            XCTFail("A cursor cannot change its query")
        } catch AudioEvidenceError.invalidRequest { }
    }

    func testUnicodeExcerptIsAnExactUTF16SliceAndNoRawFTSOperatorEscapes() async throws {
        _ = try await raw(); _ = try await sentence("Cedar 👩🏽‍💻 café pricing says \"approve\" — AUD 42")
        let page = try await reader.searchAudioEvidence(.init(terms: ["café", "pricing"]))
        let hit = try XCTUnwrap(page.hits.first)
        let range = NSRange(location: hit.excerpt.utf16Range.location, length: hit.excerpt.utf16Range.length)
        XCTAssertEqual((hit.snapshot.text as NSString).substring(with: range), hit.excerpt.text)
        let literal = try await reader.searchAudioEvidence(.init(terms: ["pricing OR secret"]))
        XCTAssertTrue(literal.hits.isEmpty)
    }

    func testInvalidTimingAndOversizedTextAreUnavailableWithoutTruncation() async throws {
        _ = try await raw()
        let id = try await sentence("Cedar pricing")
        try sql("UPDATE audio_captures SET end_time=start_time WHERE id=\(id)")
        let badTime = try await reader.searchAudioEvidence(.init(terms: []))
        XCTAssertTrue(badTime.hits.isEmpty)
        try sql("UPDATE audio_captures SET end_time=start_time+2000,text=replace(hex(zeroblob(40000)),'0','x') WHERE id=\(id)")
        let oversized = try await reader.searchAudioEvidence(.init(terms: []))
        XCTAssertTrue(oversized.hits.isEmpty)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_evidence_snapshot"), 0)
    }

    func testCloseIsTerminalAndForeignReaderStampCannotBeReused() async throws {
        _ = try await raw(); _ = try await sentence("Cedar pricing")
        let page = try await reader.searchAudioEvidence(.init(terms: ["Cedar"]))
        let other = try NativeAudioEvidenceStore(connection: SQLiteConnection(
            readOnlyDatabasePath: directory.appendingPathComponent("authored.sqlite").path))
        do { try await other.revalidateAudioEvidence(try XCTUnwrap(page.stamp), references: []); XCTFail("Reader mismatch") }
        catch AudioEvidenceError.dataChanged { }
        await other.close()
        await reader.close(); await reader.close()
        do { _ = try await reader.searchAudioEvidence(.init(terms: [])); XCTFail("Closed") }
        catch AudioEvidenceError.readerClosed { }
    }

    func testWriterFailureRollsBackTranscriptSnapshotRevisionAndMetricsTogether() async throws {
        _ = try await raw(); let id = try await sentence("Cedar pricing")
        let before = try await reader.searchAudioEvidence(.init(terms: ["Cedar"]))
        let count = try scalar("SELECT COUNT(*) FROM daily_metrics WHERE metricType='audio_evidence'")
        try sql("""
            CREATE TRIGGER fail_audio_evidence_metric BEFORE INSERT ON daily_metrics
            WHEN NEW.metricType='audio_evidence' BEGIN SELECT RAISE(ABORT,'authored rollback'); END
            """)
        do { try await queries.updateTranscriptionText(id: id, text: "Birch pricing"); XCTFail("Expected transaction failure") }
        catch { }
        let after = try await reader.searchAudioEvidence(.init(terms: ["Cedar"]))
        XCTAssertEqual(after.stamp, before.stamp)
        XCTAssertEqual(after.hits.first?.snapshot.reference, before.hits.first?.snapshot.reference)
        XCTAssertEqual(after.hits.first?.snapshot.text, "Cedar pricing")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM daily_metrics WHERE metricType='audio_evidence'"), count)
    }

    func testDeletionDuringAwaitedMetricCannotReturnStaleTranscript() async throws {
        _ = try await raw(); let id = try await sentence("Cedar pricing")
        await reader.close()
        let queries = try XCTUnwrap(queries)
        reader = try NativeAudioEvidenceStore(connection: SQLiteConnection(
            readOnlyDatabasePath: directory.appendingPathComponent("authored.sqlite").path), metric: { _, _ in
                _ = try await queries.deleteTranscription(id: id)
            })
        do { _ = try await reader.searchAudioEvidence(.init(terms: ["Cedar"])); XCTFail("Deleted while suspended") }
        catch AudioEvidenceError.dataChanged { }
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_evidence_snapshot"), 0)
    }

    func testCancelledQueuedReadReturnsNoContent() async throws {
        _ = try await raw(); _ = try await sentence("Cedar pricing")
        let entered = expectation(description: "metric entered")
        let gate = AudioEvidenceReadGate(entered: entered)
        await reader.close()
        reader = try NativeAudioEvidenceStore(connection: SQLiteConnection(
            readOnlyDatabasePath: directory.appendingPathComponent("authored.sqlite").path), metric: { _, _ in await gate.hold() })
        let reader = try XCTUnwrap(reader)
        let task = Task { try await reader.searchAudioEvidence(.init(terms: ["Cedar"])) }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled read returned content") }
        catch is CancellationError { }
    }

    func testCloseJoinsEnteredMetricAndNoNewReadIsAdmitted() async throws {
        _ = try await raw(); _ = try await sentence("Cedar pricing")
        let entered = expectation(description: "metric entered")
        let gate = AudioEvidenceReadGate(entered: entered)
        await reader.close()
        reader = try NativeAudioEvidenceStore(connection: SQLiteConnection(
            readOnlyDatabasePath: directory.appendingPathComponent("authored.sqlite").path), metric: { _, _ in await gate.hold() })
        let reader = try XCTUnwrap(reader)
        let reading = Task { try await reader.searchAudioEvidence(.init(terms: ["Cedar"])) }
        await fulfillment(of: [entered], timeout: 3)
        let returned = AudioEvidenceCloseFlag()
        let closing = Task { await reader.close(); await returned.set() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await reader.closed), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let admittedClose = await reader.closed
        XCTAssertTrue(admittedClose)
        let completedEarly = await returned.value
        XCTAssertFalse(completedEarly)
        await gate.release()
        await closing.value
        do { _ = try await reading.value; XCTFail("Close invalidated entered read") }
        catch AudioEvidenceError.readerClosed { }
        do { _ = try await reader.audioEvidenceCoverage(); XCTFail("Post-close call") }
        catch AudioEvidenceError.readerClosed { }
        let calls = await gate.calls
        XCTAssertEqual(calls, 1, "No metric can arrive after joined close")
    }

    func testBootstrapHasFixedBoundaryAndResumesAfterReaderRestart() async throws {
        // Recreate only V30 in this private database so its real migration sees
        // authored V28 history. No installed database or legacy text is touched.
        await reader.close()
        let objects = try names("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'audio_evidence_%'")
        for name in objects { try sql("DROP TRIGGER \(name)") }
        try sql("DROP VIEW audio_evidence_projection")
        for table in ["audio_evidence_snapshot", "audio_evidence_materialization", "audio_evidence_alias", "audio_evidence_state"] {
            try sql("DROP TABLE \(table)")
        }
        try sql("DROP INDEX audio_evidence_preferred_pass")
        try sql("DROP INDEX audio_evidence_original_candidates")
        _ = try await raw()
        for index in 0..<65 { _ = try await sentence("Cedar historical \(index)") }
        try await V30_AudioEvidence().migrate(db: writer)
        let initial = try AudioEvidenceSQL.advanceBootstrap(writer, limit: 16)
        XCTAssertEqual(initial.historicalBoundary, 66)
        XCTAssertEqual(initial.throughRowID, 16)
        XCTAssertFalse(initial.complete)
        for index in 0..<20 { _ = try await sentence("Cedar fresh \(index)") }
        reader = try NativeAudioEvidenceStore(connection: SQLiteConnection(
            readOnlyDatabasePath: directory.appendingPathComponent("authored.sqlite").path))
        let resumed = try await reader.audioEvidenceCoverage()
        XCTAssertEqual(resumed.bootstrap.throughRowID, 16)
        var progress = initial
        while !progress.complete { progress = try AudioEvidenceSQL.advanceBootstrap(writer, limit: 16) }
        XCTAssertEqual(progress.historicalBoundary, 66)
        XCTAssertEqual(progress.throughRowID, 66)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_evidence_snapshot"), 85)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_captures"), 86)
    }

    func testReadOnlyContractRejectsBorrowedWriterAndInvalidRequestBounds() async throws {
        XCTAssertThrowsError(try NativeAudioEvidenceStore(connection: SQLiteConnection(db: writer)))
        for request in [AudioEvidenceSearchRequest(terms: [], limit: 0),
                        .init(terms: [String(repeating: "x", count: 257)]),
                        .init(terms: [], maximumInspectedRows: 513),
                        .init(terms: ["bad\0value"])] {
            do { _ = try await reader.searchAudioEvidence(request); XCTFail("Bounds must be enforced") }
            catch AudioEvidenceError.invalidRequest { }
        }
    }

    private func names(_ value: String) throws -> [String] {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(writer, value, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(String(cString: sqlite3_column_text(statement, 0))) }
        return result
    }

    private func raw() async throws -> Int64 {
        try await queries.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(5),
            source: .system, audioPath: batch, audioSize: 4096)
    }
    private func sentence(_ text: String, offset: TimeInterval = 0, pass: Int = 1) async throws -> Int64 {
        try await queries.insertTranscription(sessionID: nil, text: text,
            startTime: start.addingTimeInterval(offset), endTime: start.addingTimeInterval(offset + 2),
            source: .system, confidence: 0.95, words: [], audioPath: batch,
            transcriptionPass: pass, batchAudioPath: batch)
    }
    private func sql(_ value: String) throws {
        guard sqlite3_exec(writer, value, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryExecutionFailed(String(cString: sqlite3_errmsg(writer)))
        }
    }
    private func scalar(_ value: String) throws -> Int64 {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(writer, value, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return sqlite3_column_int64(statement, 0)
    }
}

private actor AudioEvidenceReadGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var calls = 0
    init(entered: XCTestExpectation) { self.entered = entered }
    func hold() async {
        calls += 1; entered.fulfill()
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor AudioEvidenceCloseFlag {
    private(set) var value = false
    func set() { value = true }
}
