@testable import Database
import Foundation
import Shared
import SQLCipher
import XCTest

/// Private SQLite tests. Source provenance is not consent, app ownership or ASR accuracy.
final class AudioOriginalSourceTests: XCTestCase {
    private var database: DatabaseManager!
    private var queries: AudioTranscriptionQueries!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let path = "audio/batch_1700000000000_system_original.m4a"

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:original-audio-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let pointer = await database.getConnection()
        queries = AudioTranscriptionQueries(db: try XCTUnwrap(pointer))
    }

    override func tearDown() async throws {
        try await database.close()
        queries = nil; database = nil
    }

    func testPendingFirstPassSourceRejectsAlreadyPublishedRecordingBeforeModelWork() async throws {
        let raw = try await insertRaw(.system)
        let receipt = try await queries.pendingFirstPassSource(rawBatchID: raw, path: path)
        _ = try await queries.commitFirstPass(rawBatchID: raw, records: [record(pass: 1, source: .system)], originalSource: receipt)
        await assertSourceError(.changed) {
            _ = try await self.queries.pendingFirstPassSource(rawBatchID: raw, path: self.path)
        }
        let retained = try await queries.originalSourceReceipt(forBatchPath: path)
        XCTAssertEqual(retained.source, .system, "Refinement still resolves intentionally retired original source")
    }

    func testPendingKeysetSeeksPartialIndexWithoutSortingTenThousandRows() async throws {
        try await database.audioSourceFixtureSQL("""
            WITH RECURSIVE authored(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM authored WHERE n<10000)
            INSERT INTO audio_captures(text,start_time,end_time,source,audio_path,audio_size,transcription_pass,transcript_status)
            SELECT '',1700000000000+n,1700000000001+n,'system','audio/batch_index_'||n||'.m4a',100,1,'pending' FROM authored
            """)
        let inspected = try await database.audioPendingFixtureInspectPage(after: 9_000)
        XCTAssertEqual(inspected.ids, Array(Int64(9_001)...Int64(9_016)))
        XCTAssertLessThan(inspected.steps, 1000)
        XCTAssertTrue(inspected.plan.contains { $0.contains("audio_pending_raw_id") && $0.contains("id>?") })
        XCTAssertFalse(inspected.plan.contains { $0.contains("TEMP B-TREE") || $0.contains("SCAN audio_captures") })
    }

    func testNoTextOutcomeRejectsRevokedPermitAndStaleSource() async throws {
        let raw = try await insertRaw(.system)
        let receipt = try await queries.originalSourceReceipt(forBatchPath: path)
        let permit = BackgroundProcessingPermit(threadCount: 2)
        permit.cancellation.cancel()
        do {
            try await BackgroundProcessingContext.$permit.withValue(permit) {
                try await self.queries.updateBatchOutcome(id: raw, text: "", transcriptStatus: "probable_silence",
                    detectedLanguage: nil, audioVariant: "raw", qualityFlags: nil, originalSource: receipt)
            }
            XCTFail("Cancelled permit must preserve pending raw row")
        } catch is CancellationError { }
        let count = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(count, 1)
        _ = try await queries.commitFirstPass(rawBatchID: raw, records: [record(pass: 1, source: .system)], originalSource: receipt)
        await assertSourceError(.changed) {
            try await self.queries.updateBatchOutcome(id: raw, text: "", transcriptStatus: "probable_silence",
                detectedLanguage: nil, audioVariant: "raw", qualityFlags: nil, originalSource: receipt)
        }
    }

    func testFirstPassFailedWritePreservesPendingSourceAndCanRetry() async throws {
        let raw = try await insertRaw(.system)
        let receipt = try await queries.originalSourceReceipt(forBatchPath: path)
        try await database.audioSourceFixtureSQL("CREATE TRIGGER audio_first_pass_fail BEFORE INSERT ON audio_captures WHEN NEW.text='deny second sentence' BEGIN SELECT RAISE(ABORT,'fixture'); END")
        do {
            _ = try await queries.commitFirstPass(rawBatchID: raw,
                records: [record(pass: 1, source: .system), record(pass: 1, source: .system, text: "deny second sentence")],
                originalSource: receipt)
            XCTFail("Actual second SQLite insertion must fail")
        } catch { }
        let pending = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 1)
        let unchanged = try await queries.originalSourceReceipt(forBatchPath: path)
        XCTAssertEqual(unchanged, receipt)
        try await database.audioSourceFixtureSQL("DROP TRIGGER audio_first_pass_fail")
        _ = try await queries.commitFirstPass(rawBatchID: raw, records: [record(pass: 1, source: .system)], originalSource: receipt)
    }

    func testFirstPassPublishesAndRetiresAtomicallyRejectingReplay() async throws {
        let raw = try await insertRaw(.system)
        let receipt = try await queries.originalSourceReceipt(forBatchPath: path)
        let ids = try await queries.commitFirstPass(rawBatchID: raw, records: [record(pass: 1, source: .system)], originalSource: receipt)
        XCTAssertEqual(ids.count, 1)
        await assertSourceError(.changed) {
            _ = try await self.queries.commitFirstPass(rawBatchID: raw, records: [self.record(pass: 1, source: .system)], originalSource: receipt)
        }
        let remaining = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(remaining, 0)
        let count = try await database.audioSourceFixtureCount("audio_captures")
        XCTAssertEqual(count, 1)
    }

    func testSourceSurvivesIntendedRawRetirementAndBothRefinements() async throws {
        let raw = try await insertRaw(.system)
        _ = try await queries.insertTranscriptionsBatch([record(pass: 1, source: .system)])
        try await queries.retireRawBatchAfterTranscription(id: raw)
        let original = try await queries.originalSourceReceipt(forBatchPath: path)
        XCTAssertEqual(original.source, .system)
        _ = try await queries.replacePass1RecordsForBatch(batchAudioPath: path,
            with: [record(pass: 2, source: .system)], originalSource: original)
        let refreshed = try await queries.originalSourceReceipt(forBatchPath: path)
        _ = try await queries.replacePass2RecordsForBatch(batchAudioPath: path,
            with: [record(pass: 3, source: .system)], originalSource: refreshed)
        let rows = try await queries.getTranscriptions(from: start, to: start.addingTimeInterval(5), limit: 20)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.source, .system)
        XCTAssertEqual(rows.first?.transcriptionPass, 3)
        let actual1 = try await database.audioSourceFixtureCount("audio_captures")
        XCTAssertEqual(actual1, 3)
    }

    func testDeletedTranscriptInvalidatesReceiptAndRejectsSamePathReuse() async throws {
        let raw = try await insertRaw(.system)
        let ids = try await queries.insertTranscriptionsBatch([record(pass: 1, source: .system)])
        try await queries.retireRawBatchAfterTranscription(id: raw)
        let receipt = try await queries.originalSourceReceipt(forBatchPath: path)
        _ = try await queries.deleteTranscription(id: try XCTUnwrap(ids.first))
        await assertSourceError(.unavailable) { _ = try await self.queries.originalSourceReceipt(forBatchPath: self.path) }
        await assertSourceError(.changed) {
            _ = try await self.queries.replacePass1RecordsForBatch(batchAudioPath: self.path,
                with: [self.record(pass: 2, source: .system)], originalSource: receipt)
        }
        do { _ = try await insertRaw(.system); XCTFail("A reused deleted path must not become a new original") }
        catch { }
        let actual2 = try await database.audioSourceFixtureCount("audio_captures")
        XCTAssertEqual(actual2, 0)
    }

    func testOrdinaryPendingRawDeletionIsNotProcessingRetirement() async throws {
        let raw = try await insertRaw(.system)
        _ = try await queries.deleteTranscription(id: raw)
        await assertSourceError(.unavailable) { _ = try await self.queries.originalSourceReceipt(forBatchPath: self.path) }
        do { _ = try await insertRaw(.system); XCTFail("Pending recording deletion must remain deleted") }
        catch { }
    }

    func testRetirementRequiresMatchingCommittedSentenceRows() async throws {
        let raw = try await insertRaw(.system)
        await assertSourceError(.unavailable) { try await self.queries.retireRawBatchAfterTranscription(id: raw) }
        let actual3 = try await database.audioSourceFixtureCount("audio_captures")
        XCTAssertEqual(actual3, 1)
        _ = try await queries.insertTranscriptionsBatch([record(pass: 1, source: .microphone)])
        await assertSourceError(.conflicting) { try await self.queries.retireRawBatchAfterTranscription(id: raw) }
        let actual4 = try await database.audioSourceFixtureCount("audio_captures")
        XCTAssertEqual(actual4, 2)
    }

    func testPassOneAndResetThenVersionRestampCannotManufactureOriginalSource() async throws {
        let id = try await queries.insertTranscription(sessionID: nil, text: "Cedar proposal needs approval",
            startTime: start, endTime: start.addingTimeInterval(2), source: .microphone,
            confidence: 0.9, words: [], audioPath: path, transcriptionPass: 2, batchAudioPath: path,
            pipelineVersion: CURRENT_PIPELINE_VERSION - 1)
        _ = try await queries.resetStalePipelineRecords()
        try await queries.updateTranscriptionText(id: id, text: "Cedar proposal needs approval")
        await assertSourceError(.unavailable) { _ = try await self.queries.originalSourceReceipt(forBatchPath: self.path) }
        _ = try await queries.insertTranscriptionsBatch([record(pass: 1, source: .system)])
        await assertSourceError(.unavailable) { _ = try await self.queries.originalSourceReceipt(forBatchPath: self.path) }
    }

    func testConflictWithRetainedPassOneIsRejectedBeforePublication() async throws {
        _ = try await insertRaw(.system)
        _ = try await queries.insertTranscriptionsBatch([record(pass: 1, source: .system), record(pass: 1, source: .microphone)])
        await assertSourceError(.conflicting) { _ = try await self.queries.originalSourceReceipt(forBatchPath: self.path) }
    }

    func testOutputCannotRelabelOriginalSource() async throws {
        _ = try await insertRaw(.system)
        _ = try await queries.insertTranscriptionsBatch([record(pass: 1, source: .system)])
        let receipt = try await queries.originalSourceReceipt(forBatchPath: path)
        await assertSourceError(.invalidInput) {
            _ = try await self.queries.replacePass1RecordsForBatch(batchAudioPath: self.path,
                with: [self.record(pass: 2, source: .microphone)], originalSource: receipt)
        }
        let actual5 = try await database.audioSourceFixtureCount("audio_captures")
        XCTAssertEqual(actual5, 2)
    }

    func testResetWhileModelWorksRejectsStaleReceipt() async throws {
        _ = try await insertRaw(.system)
        _ = try await queries.insertTranscriptionsBatch([record(pass: 1, source: .system)])
        _ = try await queries.insertTranscription(sessionID: nil, text: "Older refined wording",
            startTime: start, endTime: start.addingTimeInterval(2), source: .system,
            confidence: 0.9, words: [], audioPath: path, transcriptionPass: 2, batchAudioPath: path,
            pipelineVersion: CURRENT_PIPELINE_VERSION - 1)
        let receipt = try await queries.originalSourceReceipt(forBatchPath: path)
        _ = try await queries.resetStalePipelineRecords()
        await assertSourceError(.changed) {
            _ = try await self.queries.replacePass2RecordsForBatch(batchAudioPath: self.path,
                with: [self.record(pass: 3, source: .system)], originalSource: receipt)
        }
        let actual6 = try await database.audioSourceFixtureCount("audio_captures", pass: 3)
        XCTAssertEqual(actual6, 0)
    }

    func testGuardedPublicationRollsBackAllRowsAfterActualSQLiteFailure() async throws {
        _ = try await insertRaw(.system)
        _ = try await queries.insertTranscriptionsBatch([record(pass: 1, source: .system)])
        let receipt = try await queries.originalSourceReceipt(forBatchPath: path)
        try await database.audioSourceFixtureSQL("CREATE TRIGGER audio_source_fixture_fail BEFORE INSERT ON audio_captures WHEN NEW.text='deny second sentence' BEGIN SELECT RAISE(ABORT,'fixture'); END")
        do {
            _ = try await queries.replacePass1RecordsForBatch(batchAudioPath: path,
                with: [record(pass: 2, source: .system), record(pass: 2, source: .system, text: "deny second sentence")],
                originalSource: receipt)
            XCTFail("The second insert must fail the owned transaction")
        } catch { }
        let actual7 = try await database.audioSourceFixtureCount("audio_captures", pass: 2)
        XCTAssertEqual(actual7, 0)
        try await database.audioSourceFixtureSQL("DROP TRIGGER audio_source_fixture_fail")
        _ = try await queries.replacePass1RecordsForBatch(batchAudioPath: path,
            with: [record(pass: 2, source: .system)], originalSource: receipt)
    }

    func testReceiptCannotCrossDatabasesWithIdenticalLegacyRows() async throws {
        _ = try await insertRaw(.system)
        _ = try await queries.insertTranscriptionsBatch([record(pass: 1, source: .system)])
        let receipt = try await queries.originalSourceReceipt(forBatchPath: path)
        let other = DatabaseManager(databasePath: "file:other-audio-\(UUID())?mode=memory&cache=private")
        try await other.initialize()
        addTeardownBlock { try? await other.close() }
        let pointer = await other.getConnection()
        let writer = AudioTranscriptionQueries(db: try XCTUnwrap(pointer))
        _ = try await writer.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(5),
            source: .system, audioPath: path, audioSize: 4_096)
        _ = try await writer.insertTranscriptionsBatch([record(pass: 1, source: .system)])
        await assertSourceError(.changed) {
            _ = try await writer.replacePass1RecordsForBatch(batchAudioPath: self.path,
                with: [self.record(pass: 2, source: .system)], originalSource: receipt)
        }
    }

    func testAlreadyOpenTransactionIsNeitherJoinedNorRolledBack() async throws {
        _ = try await insertRaw(.system)
        try await database.audioSourceFixtureSQL("BEGIN TRANSACTION")
        await assertSourceError(.connectionBusy) { _ = try await self.queries.originalSourceReceipt(forBatchPath: self.path) }
        let actual8 = try await database.audioSourceFixtureAutocommit()
        XCTAssertFalse(actual8)
        try await database.audioSourceFixtureSQL("ROLLBACK")
        let actual9 = try await queries.originalSourceReceipt(forBatchPath: path).source
        XCTAssertEqual(actual9, .system)
    }

    func testLegacyRawCanBeAdoptedButAmbiguousRawRowsCannot() async throws {
        let legacy = try await makeLegacyAudioFixture()
        _ = try await legacy.queries.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(5),
            source: .system, audioPath: path, audioSize: 4_096)
        try await legacy.upgradeToCurrent()
        let receipt = try await legacy.queries.originalSourceReceipt(forBatchPath: path)
        XCTAssertEqual(receipt.source, .system)
        let metrics = try await legacy.metrics()
        XCTAssertTrue(metrics.contains("{\"outcome\":\"legacyAdopted\"}"))
    }

    func testLegacyRawConflictIsNotChosenByFirstRowOrPass() async throws {
        let legacy = try await makeLegacyAudioFixture()
        for source in [AudioSource.system, .microphone] {
            _ = try await legacy.queries.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(5),
                source: source, audioPath: path, audioSize: 4_096)
        }
        try await legacy.upgradeToCurrent()
        await assertSourceError(.conflicting) {
            _ = try await legacy.queries.originalSourceReceipt(forBatchPath: self.path)
        }
        let count = try await legacy.scalar("SELECT COUNT(*) FROM audio_captures")
        XCTAssertEqual(count, 2, "Conflicting legacy originals remain intact for inspection")
    }

    func testLegacySchemaUpgradeKeepsOriginalRowsAndTheirTextIndex() async throws {
        let legacy = try await makeLegacyAudioFixture()
        let raw = try await legacy.queries.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(5),
            source: .system, audioPath: path, audioSize: 4_096)
        let sentences = try await legacy.queries.insertTranscriptionsBatch([record(pass: 1, source: .system)])
        let sentence = try XCTUnwrap(sentences.first)
        let before = try await legacy.scalar("SELECT COUNT(*) FROM audio_captures_fts WHERE audio_captures_fts MATCH 'Cedar'")
        XCTAssertEqual(before, 1)
        try await legacy.upgradeToCurrent()
        let after = try await legacy.scalar("SELECT COUNT(*) FROM audio_captures_fts WHERE audio_captures_fts MATCH 'Cedar'")
        let retained = try await legacy.scalar("SELECT COUNT(*) FROM audio_captures WHERE id IN (\(raw),\(sentence))")
        let origins = try await legacy.scalar("SELECT COUNT(*) FROM audio_original_source")
        let boundary = try await legacy.scalar("SELECT historicalBoundary FROM audio_evidence_state")
        XCTAssertEqual(after, 1)
        XCTAssertEqual(retained, 2)
        XCTAssertEqual(origins, 0, "Migration must not invent historical source receipts")
        XCTAssertEqual(boundary, sentence, "The actual current migration observes the retained legacy rows")
        let receipt = try await legacy.queries.originalSourceReceipt(forBatchPath: path)
        XCTAssertEqual(receipt.source, .system)
        _ = try await legacy.queries.replacePass1RecordsForBatch(batchAudioPath: path,
            with: [record(pass: 2, source: .system)], originalSource: receipt)
        let snapshots = try await legacy.scalar("SELECT COUNT(*) FROM audio_evidence_snapshot WHERE recordingSource='system' AND transcriptionPass=2")
        XCTAssertEqual(snapshots, 1, "Current evidence triggers still guard and materialize the new refinement")
    }

    func testRawSourceMutationCannotRewriteDurableSource() async throws {
        let id = try await insertRaw(.system)
        try await database.audioSourceFixtureSQL("UPDATE audio_captures SET source='microphone' WHERE id=\(id)")
        await assertSourceError(.unavailable) { _ = try await self.queries.originalSourceReceipt(forBatchPath: self.path) }
        let original = try await database.audioSourceFixtureRawSource()
        XCTAssertEqual(original, "system")
    }

    func testSourceReceiptHasExplicitCandidateCapacityAndInvalidInputBoundaries() async throws {
        await assertSourceError(.invalidInput) { _ = try await self.queries.originalSourceReceipt(forBatchPath: "") }
        await assertSourceError(.invalidInput) { _ = try await self.queries.originalSourceReceipt(forBatchPath: String(repeating: "a", count: 4_097)) }
        _ = try await insertRaw(.system)
        _ = try await queries.insertTranscriptionsBatch(Array(repeating: record(pass: 1, source: .system), count: 513))
        await assertSourceError(.capacityExceeded) { _ = try await self.queries.originalSourceReceipt(forBatchPath: self.path) }
    }

    func testTwoBorrowedPointerActorsCannotPublishTheSameReceiptTwice() async throws {
        _ = try await insertRaw(.system)
        _ = try await queries.insertTranscriptionsBatch([record(pass: 1, source: .system)])
        let receipt = try await queries.originalSourceReceipt(forBatchPath: path)
        let pointer = await database.getConnection()
        let other = AudioTranscriptionQueries(db: try XCTUnwrap(pointer))
        let first = try XCTUnwrap(queries)
        let values = [record(pass: 2, source: .system)]
        let targetPath = path
        let one = Task { () -> Bool in
            do { _ = try await first.replacePass1RecordsForBatch(batchAudioPath: targetPath, with: values, originalSource: receipt); return true }
            catch { return false }
        }
        let two = Task { () -> Bool in
            do { _ = try await other.replacePass1RecordsForBatch(batchAudioPath: targetPath, with: values, originalSource: receipt); return true }
            catch { return false }
        }
        let firstResult = await one.value
        let secondResult = await two.value
        let results = [firstResult, secondResult]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let count = try await database.audioSourceFixtureCount("audio_captures", pass: 2)
        XCTAssertEqual(count, 1)
    }

    func testSourceMethodsRejectUnserializedConnection() async throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(":memory:", &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil), SQLITE_OK)
        let pointer = try XCTUnwrap(connection)
        defer { sqlite3_close(pointer) }
        XCTAssertNil(sqlite3_db_mutex(pointer))
        let unsafe = AudioTranscriptionQueries(db: pointer)
        await assertSourceError(.connectionUnsupported) { _ = try await unsafe.originalSourceReceipt(forBatchPath: self.path) }
    }

    func testFailedPublicationDoesNotCommitSuccessMetric() async throws {
        _ = try await insertRaw(.system)
        _ = try await queries.insertTranscriptionsBatch([record(pass: 1, source: .system)])
        let receipt = try await queries.originalSourceReceipt(forBatchPath: path)
        try await database.audioSourceFixtureSQL("CREATE TRIGGER source_metric_fail BEFORE INSERT ON audio_captures WHEN NEW.transcription_pass=2 BEGIN SELECT RAISE(ABORT,'fixture'); END")
        do {
            _ = try await queries.replacePass1RecordsForBatch(batchAudioPath: path,
                with: [record(pass: 2, source: .system)], originalSource: receipt)
            XCTFail("Publication must fail")
        } catch { }
        let metrics = try await database.audioSourceFixtureMetrics()
        XCTAssertTrue(metrics.contains("{\"outcome\":\"receipt\"}"))
        XCTAssertFalse(metrics.contains(where: { $0.contains("published") }))
        XCTAssertTrue(metrics.allSatisfy { !$0.contains(path) && !$0.contains("Cedar") && !$0.contains("1700000000") })
    }

    func testReceiptSurvivesARealSQLiteCloseAndReopenAfterRawRetirement() async throws {
        let raw = try await insertRaw(.system)
        _ = try await queries.insertTranscriptionsBatch([record(pass: 1, source: .system)])
        try await queries.retireRawBatchAfterTranscription(id: raw)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-reopen-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("private.db")
        // Backup only this authored private in-memory DB. Do not invoke the
        // app's file-DB initializer, which also probes installed import state.
        try await database.audioSourceFixtureBackup(to: file.path)
        var opened: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(file.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        let pointer = try XCTUnwrap(opened)
        defer { sqlite3_close(pointer) }
        let reopened = AudioTranscriptionQueries(db: pointer)
        let receipt = try await reopened.originalSourceReceipt(forBatchPath: path)
        XCTAssertEqual(receipt.source, .system)
        _ = try await reopened.replacePass1RecordsForBatch(batchAudioPath: path,
            with: [record(pass: 2, source: .system)], originalSource: receipt)
        let rows = try await reopened.getTranscriptions(from: start, to: start.addingTimeInterval(5))
        XCTAssertEqual(rows.first?.source, .system)
        XCTAssertEqual(rows.first?.transcriptionPass, 2)
    }

    func testNewRawCannotReuseUnadoptedLegacyRawPath() async throws {
        let legacy = try await makeLegacyAudioFixture()
        _ = try await legacy.queries.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(5),
            source: .system, audioPath: path, audioSize: 4_096)
        try await legacy.upgradeToCurrent()
        do {
            _ = try await legacy.queries.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(5),
                source: .microphone, audioPath: path, audioSize: 4_096)
            XCTFail("A new raw insertion must not claim an existing legacy path")
        } catch { }
        let receipt = try await legacy.queries.originalSourceReceipt(forBatchPath: path)
        XCTAssertEqual(receipt.source, .system)
        let count = try await legacy.scalar("SELECT COUNT(*) FROM audio_captures")
        XCTAssertEqual(count, 1)
    }

    func testRefinementInspectionAdvancesThroughFilteredRowsAndDuplicatePaths() async throws {
        for pass in [1, 2] {
            var expected: [String?] = []
            for index in 0..<4 {
                let candidatePath = "audio/legacy_\(pass)_\(index).m4a"
                for copy in 0..<2 {
                    let filtered = index == 0 && copy == 0
                    expected.append(filtered ? nil : candidatePath)
                    _ = try await queries.insertTranscription(sessionID: nil,
                        text: filtered ? "[silence]" : "Cedar legacy discussion",
                        startTime: start.addingTimeInterval(Double(-index)), endTime: start.addingTimeInterval(2),
                        source: .system, confidence: 0.9, words: [], audioPath: candidatePath,
                        transcriptionPass: pass, batchAudioPath: candidatePath)
                }
            }
            var after: Int64 = 0
            var found: [String?] = []
            for _ in 0..<4 {
                let page = try await queries.originalSourceRefinementPage(transcriptionPass: pass, afterRowID: after, limit: 2)
                XCTAssertEqual(page.count, 2)
                XCTAssertTrue(page.allSatisfy { $0.rowID > after })
                after = try XCTUnwrap(page.last).rowID
                found.append(contentsOf: page.map(\.batchAudioPath))
            }
            let end = try await queries.originalSourceRefinementPage(transcriptionPass: pass, afterRowID: after, limit: 2)
            XCTAssertEqual(found, expected)
            XCTAssertTrue(end.isEmpty)
        }
    }

    func testRefinementInspectionSeeksPastTenThousandRowsWithBoundedVMWork() async throws {
        try await database.audioSourceFixtureSQL("""
            WITH RECURSIVE authored(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM authored WHERE n<10000)
            INSERT INTO audio_captures(text,start_time,end_time,source,batch_audio_path,transcription_pass,transcript_status)
            SELECT 'Cedar retained words',n*1000,n*1000+500,'system','audio/prefix_'||n||'.m4a',1,'transcribed' FROM authored
            """)
        let inspected = try await database.audioSourceFixtureInspectPage(after: 9_000)
        XCTAssertEqual(inspected.ids, Array(9_001...9_010).map { Int64($0) })
        XCTAssertLessThan(inspected.steps, 5_000, "A small page must not regroup the whole historical prefix")
        XCTAssertTrue(inspected.plan.contains { $0.contains("idx_audio_captures_pass") && $0.contains("rowid>?") })
    }

    func testRefinementKeysetRejectsInvalidBoundsAndPass() async throws {
        await assertSourceError(.invalidInput) {
            _ = try await self.queries.originalSourceRefinementPage(transcriptionPass: 3, afterRowID: 0, limit: 10)
        }
        await assertSourceError(.invalidInput) {
            _ = try await self.queries.originalSourceRefinementPage(transcriptionPass: 1, afterRowID: -1, limit: 10)
        }
        await assertSourceError(.invalidInput) {
            _ = try await self.queries.originalSourceRefinementPage(transcriptionPass: 1, afterRowID: 0, limit: 257)
        }
        let empty = try await queries.originalSourceRefinementPage(transcriptionPass: 1, afterRowID: 0, limit: 0)
        XCTAssertTrue(empty.isEmpty)
    }

    func testAlreadyCancelledCallerCannotPublishButCanRecordCancellationOutcome() async throws {
        _ = try await insertRaw(.system)
        _ = try await queries.insertTranscriptionsBatch([record(pass: 1, source: .system)])
        let receipt = try await queries.originalSourceReceipt(forBatchPath: path)
        let target = queries!
        let candidatePath = path
        let records = [record(pass: 2, source: .system)]
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await target.replacePass1RecordsForBatch(batchAudioPath: candidatePath,
                    with: records, originalSource: receipt)
                return false
            } catch is CancellationError {
                try await target.recordOriginalSourceFailure(.cancelled, pass: 2)
                return true
            }
        }
        let wasCancelled = try await task.value
        let count = try await database.audioSourceFixtureCount("audio_captures", pass: 2)
        let metrics = try await database.audioSourceFixtureMetrics()
        let after = try await queries.originalSourceReceipt(forBatchPath: path)
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(after, receipt)
        XCTAssertTrue(metrics.contains("{\"outcome\":\"cancelled\",\"pass\":2}"))
        XCTAssertFalse(metrics.contains { $0.contains("published") })
    }

    func testCancellationFromActualSQLiteInsertRollsBackRowsGenerationAndSuccessMetric() async throws {
        _ = try await insertRaw(.system)
        _ = try await queries.insertTranscriptionsBatch([record(pass: 1, source: .system)])
        let receipt = try await queries.originalSourceReceipt(forBatchPath: path)
        let gate = OriginalSourcePublicationGate()
        let target = queries!
        let owner = database!
        let candidatePath = path
        let records = [record(pass: 2, source: .system)]
        let task = Task {
            await gate.wait()
            do {
                _ = try await target.replacePass1RecordsForBatch(batchAudioPath: candidatePath,
                    with: records, originalSource: receipt)
                return false
            } catch is CancellationError {
                try await target.recordOriginalSourceFailure(.cancelled, pass: 2)
                return true
            }
        }
        let hook = OriginalSourceInsertCancellation { task.cancel() }
        addTeardownBlock {
            task.cancel()
            await gate.open()
            _ = try? await task.value
            await owner.audioSourceFixtureClearInsertHook()
            withExtendedLifetime(hook) { }
        }
        try await database.audioSourceFixtureCancelOnInsert(hook)
        await gate.open()
        let wasCancelled = try await task.value
        await database.audioSourceFixtureClearInsertHook()
        withExtendedLifetime(hook) { }
        let count = try await database.audioSourceFixtureCount("audio_captures", pass: 2)
        let metrics = try await database.audioSourceFixtureMetrics()
        let after = try await queries.originalSourceReceipt(forBatchPath: path)
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(after, receipt)
        XCTAssertTrue(metrics.contains("{\"outcome\":\"cancelled\",\"pass\":2}"))
        XCTAssertFalse(metrics.contains { $0.contains("published") })
    }

    private func makeLegacyAudioFixture() async throws -> OriginalAudioLegacyFixture {
        let fixture = try OriginalAudioLegacyFixture()
        addTeardownBlock { await fixture.close() }
        try await fixture.initializeBeforeSourceReceipts()
        return fixture
    }

    private func insertRaw(_ source: AudioSource) async throws -> Int64 {
        try await queries.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(5),
            source: source, audioPath: path, audioSize: 4_096)
    }
    private func record(pass: Int, source: AudioSource, text: String = "Cedar proposal needs approval") -> AudioTranscriptionQueries.TranscriptionBatchRecord {
        (nil, text, start, start.addingTimeInterval(2), source, 0.9, [], path, pass, path,
         "transcribed", "en", "raw", nil)
    }
    private func assertSourceError(_ expected: AudioOriginalSourceError,
        operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch let error as AudioOriginalSourceError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line) }
    }
}

private extension DatabaseManager {
    func audioPendingFixtureInspectPage(after: Int64) throws -> (ids: [Int64], steps: Int32, plan: [String]) {
        let pointer = try XCTUnwrap(getConnection())
        let sql = AudioTranscriptionQueries.pendingRawSQL
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(pointer, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, after)
        sqlite3_bind_int(statement, 2, 16)
        var ids: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW { ids.append(sqlite3_column_int64(statement, 0)) }
        let steps = sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0)
        var explain: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(pointer, "EXPLAIN QUERY PLAN " + sql, -1, &explain, nil), SQLITE_OK)
        defer { sqlite3_finalize(explain) }
        var plan: [String] = []
        while sqlite3_step(explain) == SQLITE_ROW { plan.append(String(cString: sqlite3_column_text(explain, 3))) }
        return (ids, steps, plan)
    }
    func audioSourceFixtureInspectPage(after: Int64) throws -> (ids: [Int64], steps: Int32, plan: [String]) {
        let pointer = try XCTUnwrap(getConnection())
        let sql = AudioTranscriptionQueries.originalSourceRefinementSQL
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(pointer, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, 1)
        sqlite3_bind_int64(statement, 2, after)
        sqlite3_bind_int(statement, 3, 10)
        var ids: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW { ids.append(sqlite3_column_int64(statement, 0)) }
        let steps = sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0)
        var explain: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(pointer, "EXPLAIN QUERY PLAN " + sql, -1, &explain, nil), SQLITE_OK)
        defer { sqlite3_finalize(explain) }
        sqlite3_bind_int(explain, 1, 1)
        sqlite3_bind_int64(explain, 2, after)
        sqlite3_bind_int(explain, 3, 10)
        var plan: [String] = []
        while sqlite3_step(explain) == SQLITE_ROW { plan.append(String(cString: sqlite3_column_text(explain, 3))) }
        return (ids, steps, plan)
    }
    func audioSourceFixtureCancelOnInsert(_ hook: OriginalSourceInsertCancellation) throws {
        let pointer = try XCTUnwrap(getConnection())
        sqlite3_update_hook(pointer, { context, operation, _, table, _ in
            guard operation == SQLITE_INSERT, let context, let table,
                  String(cString: table) == "audio_captures" else { return }
            Unmanaged<OriginalSourceInsertCancellation>.fromOpaque(context).takeUnretainedValue().cancel()
        }, Unmanaged.passUnretained(hook).toOpaque())
    }
    func audioSourceFixtureClearInsertHook() {
        if let pointer = getConnection() { sqlite3_update_hook(pointer, nil, nil) }
    }
    func audioSourceFixtureCount(_ table: String, pass: Int? = nil) throws -> Int {
        let pointer = try XCTUnwrap(getConnection())
        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM \(table)" + (pass.map { " WHERE transcription_pass=\($0)" } ?? "")
        XCTAssertEqual(sqlite3_prepare_v2(pointer, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return Int(sqlite3_column_int(statement, 0))
    }
    func audioSourceFixtureSQL(_ sql: String) throws {
        let pointer = try XCTUnwrap(getConnection())
        XCTAssertEqual(sqlite3_exec(pointer, sql, nil, nil, nil), SQLITE_OK)
    }
    func audioSourceFixtureMetrics() throws -> [String] {
        let pointer = try XCTUnwrap(getConnection())
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(pointer,
            "SELECT metadata FROM daily_metrics WHERE metricType='audio_original_source' ORDER BY id", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { values.append(String(cString: sqlite3_column_text(statement, 0))) }
        return values
    }
    func audioSourceFixtureRawSource() throws -> String? {
        let pointer = try XCTUnwrap(getConnection())
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(pointer, "SELECT source FROM audio_original_source LIMIT 1", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(statement, 0))
    }
    func audioSourceFixtureBackup(to path: String) throws {
        let source = try XCTUnwrap(getConnection())
        var destination: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        let target = try XCTUnwrap(destination)
        defer { sqlite3_close(target) }
        let backup = try XCTUnwrap(sqlite3_backup_init(target, "main", source, "main"))
        XCTAssertEqual(sqlite3_backup_step(backup, -1), SQLITE_DONE)
        XCTAssertEqual(sqlite3_backup_finish(backup), SQLITE_OK)
    }
    func audioSourceFixtureAutocommit() throws -> Bool { sqlite3_get_autocommit(try XCTUnwrap(getConnection())) != 0 }
}

private final class OriginalSourceInsertCancellation: Sendable {
    let cancel: @Sendable () -> Void
    init(_ cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
}

private actor OriginalSourcePublicationGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// Build a real pinned V27 database, then let the production runner perform the
/// complete current upgrade. Dropping V28 from a current schema leaves newer
/// dependent triggers behind and does not represent any supported old writer.
private actor OriginalAudioLegacyFixture {
    nonisolated let queries: AudioTranscriptionQueries
    private var db: OpaquePointer?

    init() throws {
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(":memory:", &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw DatabaseConnectionError.openingFailed(error: "Private legacy fixture unavailable")
        }
        guard sqlite3_exec(opened, "PRAGMA foreign_keys=ON", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close_v2(opened)
            throw DatabaseConnectionError.openingFailed(error: "Private legacy fixture setup failed")
        }
        db = opened
        queries = AudioTranscriptionQueries(db: opened)
    }

    func initializeBeforeSourceReceipts() async throws {
        let pointer = try XCTUnwrap(db)
        // This historical boundary is deliberately fixed. Never derive it by
        // removing tables/triggers from the current production schema.
        let migrations: [Migration] = [
            V1_InitialSchema(), V2_UnfinalisedVideoTracking(), V3_TagSystem(),
            V4_DailyMetrics(), V5_FTSUnicode61(), V6_FrameProcessedAt(),
            V7_FrameRedactionReason(), V8_SegmentComments(), V9_SegmentCommentFrameAnchor(),
            V10_SegmentCommentSearchIndex(), V11_SegmentCommentLinkCompositeIndex(),
            V12_AudioCaptures(), V13_TranscriptionPass(), V14_ContextualRefinement(),
            V15_PipelineVersion(), V16_DictationSessions(), V17_AudioTranscriptMetadata(),
            V18_NodeText(), V19_ProcessingQueueFrameIndex(), V20_OCRBackfillState(),
            V21_ProgressiveRecall(), V22_ScreenEvidenceFeed(), V23_ScreenEvidenceAdmission(),
            V24_OriginalFrameSources(), V25_SemanticRecall(), V26_CaptureGroups(),
            V27_LocalContextVisibility()
        ]
        try sql(Schema.createSchemaMigrationsTable)
        for migration in migrations {
            try sql("BEGIN TRANSACTION")
            do {
                try await migration.migrate(db: pointer)
                try sql("INSERT INTO schema_migrations(version,applied_at) VALUES(\(migration.version),0)")
                try sql("COMMIT")
            } catch {
                try? sql("ROLLBACK")
                throw error
            }
        }
        XCTAssertEqual(try scalar("SELECT MAX(version) FROM schema_migrations"), 27)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'audio_original_source_%' OR name LIKE 'audio_evidence_%'"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('audio_captures_ai','audio_captures_ad','audio_captures_au')"), 3)
    }

    func upgradeToCurrent() async throws {
        try await MigrationRunner(db: try XCTUnwrap(db)).runMigrations()
    }

    func scalar(_ query: String) throws -> Int64 {
        let pointer = try XCTUnwrap(db)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(pointer, query, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseConnectionError.statementPreparationFailed(sql: query, error: String(cString: sqlite3_errmsg(pointer)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseConnectionError.executionFailed(sql: query, error: String(cString: sqlite3_errmsg(pointer)))
        }
        return sqlite3_column_int64(statement, 0)
    }

    func metrics() throws -> [String] {
        let pointer = try XCTUnwrap(db)
        let query = "SELECT metadata FROM daily_metrics WHERE metricType='audio_original_source' ORDER BY id"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(pointer, query, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseConnectionError.statementPreparationFailed(sql: query, error: String(cString: sqlite3_errmsg(pointer)))
        }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            values.append(String(cString: sqlite3_column_text(statement, 0)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw DatabaseConnectionError.executionFailed(sql: query, error: String(cString: sqlite3_errmsg(pointer)))
        }
        return values
    }

    func close() {
        if let db { XCTAssertEqual(sqlite3_close_v2(db), SQLITE_OK) }
        db = nil
    }

    private func sql(_ query: String) throws {
        let pointer = try XCTUnwrap(db)
        guard sqlite3_exec(pointer, query, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseConnectionError.executionFailed(sql: query, error: String(cString: sqlite3_errmsg(pointer)))
        }
    }
}
