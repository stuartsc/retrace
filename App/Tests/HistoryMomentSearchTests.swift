import Foundation
import SQLCipher
import Shared
import Storage
import XCTest
@testable import App
@testable import Database

/// Actual SQLite/FTS, canonical screen revisions and a separate read-only V30
/// transcript database. No history, graphics, media or model runtime is opened.
final class HistoryMomentSearchTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var adapter: DataAdapter!
    private var evidence: ProgressiveRecallService!
    private var audioDB: OpaquePointer!
    private var audioQueries: AudioTranscriptionQueries!
    private var audioReader: NativeAudioEvidenceStore!
    private let policy = HistorySearchTestPolicy()
    private let now = Date(timeIntervalSince1970: 1_700_000_000.125)
    private var gates: [HistorySearchTestGate] = []
    private var searches: [Task<HistorySearchResults, Error>] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-search-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        database = DatabaseManager(databasePath: "file:history-screen-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let pointer = await database.getConnection()
        adapter = DataAdapter(retraceConnection: SQLiteConnection(db: try XCTUnwrap(pointer)),
            retraceConfig: .init(dateFormatter: nil, storageRoot: directory.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: directory.path), database: database)
        try await adapter.initialize()
        let path = directory.appendingPathComponent("authored-audio.sqlite").path
        XCTAssertEqual(sqlite3_open_v2(path, &audioDB, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(audioDB, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        try await MigrationRunner(db: audioDB).runMigrations()
        audioQueries = AudioTranscriptionQueries(db: audioDB)
        audioReader = try NativeAudioEvidenceStore(connection: SQLiteConnection(readOnlyDatabasePath: path))
        let policy = policy
        evidence = ProgressiveRecallService(database: database, adapter: adapter,
            configuration: { await policy.read() }, audioHistory: audioReader, imageReader: { _ in
                XCTFail("Merged history search and refresh must not decode any image")
                throw EvidenceUnavailableReason.recordingMissing
            })
    }

    override func tearDown() async throws {
        for gate in gates { await gate.release() }
        for search in searches { search.cancel(); _ = try? await search.value }
        searches.removeAll(); gates.removeAll()
        await evidence?.setMetricCheckpointForTesting(nil)
        evidence = nil
        await audioReader?.close(); audioReader = nil; audioQueries = nil
        if let audioDB { XCTAssertEqual(sqlite3_close_v2(audioDB), SQLITE_OK) }
        audioDB = nil
        await adapter?.shutdown()
        if let database { try await database.close() }
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testMergedHitsKeepExactSeparateIdentitiesAndCanonicalUnicodeExcerpts() async throws {
        let text = "Cedar 👩🏽‍💻 cafe\u{301} pricing needs approval"
        let screen = try await insertScreen(text)
        let (_, audio) = try await insertAudio(text)
        let page = try await search("Cedar")
        XCTAssertEqual(page.results.count, 2)
        XCTAssertEqual(Set(page.results.map(\.reference)), [.screen(screen), .audio(audio)])
        XCTAssertEqual(Set(page.results.map(\.id)).count, 2)
        XCTAssertNotEqual(screen.storeID, audio.storeID)
        for result in page.results {
            switch result {
            case .screen(let hit):
                XCTAssertEqual(hit.result.evidenceRef, screen)
                XCTAssertEqual(hit.excerpt.reference, screen)
                assertSlice(hit.excerpt.text, range: hit.excerpt.utf16Range, in: text)
                XCTAssertEqual(result.rankBasis, .existingScreenOrder)
            case .audio(let hit):
                XCTAssertEqual(hit.snapshot.reference, audio)
                assertSlice(hit.excerpt.text, range: hit.excerpt.utf16Range, in: text)
                XCTAssertEqual(hit.snapshot.mediaAvailability, .notVerified)
                XCTAssertEqual(hit.snapshot.provenance, .declaredOriginalSource)
                XCTAssertEqual(result.rankBasis, .transcriptTextAndRowOrder)
            }
        }
        XCTAssertEqual(page.coverage.audioState, .searched)
        XCTAssertEqual(page.coverage.audio?.scope, .provenNativeTranscripts)
        XCTAssertEqual(page.coverage.screen?.nativeSemanticUsed, false)
        try await revalidate(page)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".mp4") || $0.hasSuffix(".m4a") })
    }

    func testExactScreenIdentifierKeepsPriorityWhenARealTranscriptAlsoMatches() async throws {
        _ = try await insertScreen("JOB-1234 JOB-1234 JOB-1234 pending")
        let exact = try await insertScreen("Build JOB-123 complete")
        let (_, audio) = try await insertAudio("The build JOB-123 completed")
        let page = try await search("JOB-123", limit: 2)
        XCTAssertEqual(page.results.first?.reference, .screen(exact))
        XCTAssertEqual(page.results.last?.reference, .audio(audio))
        guard case .screen(let first) = try XCTUnwrap(page.results.first) else { return XCTFail("Expected exact screen") }
        XCTAssertEqual(first.result.matchExplanation?.exactIdentifiers, ["JOB-123"])
        XCTAssertGreaterThanOrEqual(page.coverage.screenHitsOmittedByLimit, 1)
    }

    func testChannelOrderIsPreservedWithoutComparingScreenAndTranscriptScores() async throws {
        for offset in 0..<3 {
            _ = try await insertScreen("Cedar pricing screen \(offset)", offset: Double(offset))
            _ = try await insertAudio("Cedar pricing transcript \(offset)", offset: Double(offset))
        }
        let query = SearchQuery(text: "Cedar", limit: 10, mode: .relevant)
        let expectedScreen = try await screenSearch(query)
        let expectedAudio = try await audioReader.searchAudioEvidence(.init(terms: ["Cedar"], limit: 10))
        let result = try await search(query)
        XCTAssertEqual(result.results.compactMap { if case .screen(let hit) = $0 { return hit.reference }; return nil },
                       expectedScreen.results.compactMap(\.evidenceRef))
        XCTAssertEqual(result.results.compactMap { if case .audio(let hit) = $0 { return hit.snapshot.reference }; return nil },
                       expectedAudio.hits.map { $0.snapshot.reference })
        XCTAssertEqual(result.results.map(\.rankBasis), [.existingScreenOrder, .transcriptTextAndRowOrder,
            .existingScreenOrder, .transcriptTextAndRowOrder, .existingScreenOrder, .transcriptTextAndRowOrder])
    }

    func testUnsupportedAudioSyntaxPreservesTheActualScreenQueryRoute() async throws {
        _ = try await insertScreen("Cedar pricing approved")
        _ = try await insertScreen("Cedar pricing pending")
        _ = try await insertAudio("Cedar pricing approved")
        for text in ["\"Cedar pricing\"", "Cedar -pending", "Cedar OR pricing", "Cedar*"] {
            let query = SearchQuery(text: text, limit: 10, mode: .relevant)
            let expected = try await screenSearch(query)
            let page = try await search(query)
            XCTAssertEqual(page.coverage.audioState, .unsupportedQuerySyntax)
            XCTAssertNil(page.coverage.audio)
            XCTAssertNil(page.readStamp.audio)
            XCTAssertEqual(page.results.compactMap { if case .screen(let hit) = $0 { return hit.result.id }; return nil },
                           expected.results.map(\.id))
        }
    }

    func testUnsupportedAudioFiltersRemainExplicitAndDoNotBroadenScreenResults() async throws {
        _ = try await insertScreen("Cedar pricing", app: "com.authored.keep")
        _ = try await insertScreen("Cedar pricing", app: "com.authored.other")
        _ = try await insertAudio("Cedar pricing")
        let cases: [(SearchFilters, AudioEvidenceUnavailableReason)] = [
            (.init(appBundleIDs: ["com.authored.keep"]), .unsupportedApplicationScope),
            (.init(excludedAppBundleIDs: ["com.authored.other"]), .unsupportedApplicationScope),
            (.init(windowNameFilter: "Authored"), .unsupportedWindowScope),
            (.init(browserUrlFilter: "cedar"), .unsupportedURLScope),
            (.init(selectedTagIds: [999]), .unsupportedTagScope),
            (.init(commentFilter: .commentsOnly), .unsupportedCommentScope),
            (.init(hiddenFilter: .onlyHidden), .unsupportedHiddenScope),
            (.init(dateRanges: [.init(start: now, end: now), .init(start: now.addingTimeInterval(10))]), .unsupportedDateScope)
        ]
        for (filters, reason) in cases {
            let query = SearchQuery(text: "Cedar", filters: filters, limit: 10, mode: .relevant)
            let expected = try await screenSearch(query)
            let page = try await search(query)
            XCTAssertEqual(page.coverage.audioState, .unavailable(reason))
            XCTAssertEqual(page.results.compactMap { if case .screen(let hit) = $0 { return hit.result.id }; return nil },
                           expected.results.map(\.id))
            XCTAssertFalse(page.results.contains { if case .audio = $0 { return true }; return false })
        }
    }

    func testDateConstraintsReachBothRealStoresBeforeTheResultLimit() async throws {
        _ = try await insertScreen("Cedar old pricing", offset: -20)
        let screen = try await insertScreen("Cedar current pricing", offset: 20)
        _ = try await insertAudio("Cedar old pricing", offset: -20)
        let (_, audio) = try await insertAudio("Cedar current pricing", offset: 20)
        let query = SearchQuery(text: "Cedar", filters: .init(startDate: now), limit: 2, mode: .relevant)
        let page = try await search(query)
        XCTAssertEqual(Set(page.results.map(\.reference)), [.screen(screen), .audio(audio)])
    }

    func testBoundedAudioScanExposesUnknownLineageWithoutPretendingItIsComplete() async throws {
        _ = try await insertScreen("Cedar visible screen")
        _ = try await insertAudio("Cedar older proven transcript")
        XCTAssertEqual(sqlite3_exec(audioDB, """
            WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<520)
            INSERT INTO audio_captures(text,start_time,end_time,source,audio_path,batch_audio_path)
              SELECT 'Cedar unknown legacy',1700000000125,1700000002125,'system',
                     'audio/legacy_'||i||'.m4a','audio/legacy_'||i||'.m4a' FROM n
            """, nil, nil, nil), SQLITE_OK)
        let page = try await search("Cedar", limit: 2)
        XCTAssertEqual(page.coverage.audioState, .searched)
        XCTAssertEqual(page.coverage.audio?.scanComplete, false)
        XCTAssertEqual(page.coverage.audio?.inspectedRows, 512)
        XCTAssertGreaterThan(page.coverage.audio?.unprovenLineageRows ?? 0, 0)
        XCTAssertFalse(page.results.contains { if case .audio = $0 { return true }; return false })
        XCTAssertEqual(page.results.count, 1)
    }

    func testNoAudioOwnerIsExplicitAndDoesNotDisableScreenSearch() async throws {
        let screen = try await insertScreen("Cedar pricing")
        let page = try await search(.init(text: "Cedar", mode: .relevant), audio: nil)
        XCTAssertEqual(page.results.map(\.reference), [.screen(screen)])
        XCTAssertEqual(page.coverage.audioState, .notConfigured)
        XCTAssertNil(page.readStamp.audio)
    }

    func testTooManyLiteralTermsDoNotSilentlyTruncateTranscriptSearch() async throws {
        let text = (1...17).map { "term\($0)" }.joined(separator: " ")
        _ = try await insertScreen(text)
        _ = try await insertAudio(text)
        let page = try await search(text)
        XCTAssertEqual(page.coverage.audioState, .queryExceedsAudioLimits)
        XCTAssertNil(page.readStamp.audio)
        XCTAssertFalse(page.results.contains { if case .audio = $0 { return true }; return false })
    }

    func testAudioDeletionMakesTheCompleteCachedBatchUnavailable() async throws {
        _ = try await insertScreen("Cedar pricing")
        let (row, _) = try await insertAudio("Cedar pricing")
        let page = try await search("Cedar")
        _ = try await audioQueries.deleteTranscription(id: row)
        await assertChanged { try await self.revalidate(page) }
    }

    func testScreenDeletionMakesTheCompleteCachedBatchUnavailable() async throws {
        let screen = try await insertScreen("Cedar pricing")
        _ = try await insertAudio("Cedar pricing")
        let page = try await search("Cedar")
        try await database.deleteFrame(id: screen.frameID)
        await assertChanged { try await self.revalidate(page) }
    }

    func testEqualLengthTranscriptRevisionNeverReplacesAPinnedExcerpt() async throws {
        _ = try await insertScreen("Cedar pricing")
        let (row, _) = try await insertAudio("Cedar pricing")
        let page = try await search("pricing")
        try await audioQueries.updateTranscriptionText(id: row, text: "Birch pricing")
        await assertChanged { try await self.revalidate(page) }
    }

    func testForeignAndClosedReaderCannotRefreshAnOldBatch() async throws {
        _ = try await insertAudio("Cedar pricing")
        let page = try await search("Cedar")
        let other = try NativeAudioEvidenceStore(connection: SQLiteConnection(
            readOnlyDatabasePath: directory.appendingPathComponent("authored-audio.sqlite").path))
        addTeardownBlock { await other.close() }
        await assertChanged {
            try await HistoryMomentSearch.revalidate(page, adapter: self.adapter, evidence: self.evidence, audioHistory: other)
        }
        await audioReader.close()
        await assertChanged { try await self.revalidate(page) }
    }

    func testConfigurationChangeInvalidatesTheCompleteBatch() async throws {
        _ = try await insertScreen("Cedar pricing", app: "com.authored.screen")
        _ = try await insertAudio("Cedar pricing")
        let page = try await search("Cedar")
        await policy.exclude("com.authored.screen")
        await assertChanged { try await self.revalidate(page) }
    }

    func testDeletionDuringFinalMetricsCannotPublishATranscript() async throws {
        _ = try await insertScreen("Cedar pricing")
        let (row, _) = try await insertAudio("Cedar pricing")
        let reached = expectation(description: "Real final history metric")
        let gate = HistorySearchTestGate(reached: reached)
        gates.append(gate)
        await evidence.setMetricCheckpointForTesting { action in
            if action == .historySearched { await gate.waitOnce() }
        }
        let task = Task { try await self.search("Cedar") }
        searches.append(task)
        await fulfillment(of: [reached], timeout: 10)
        _ = try await audioQueries.deleteTranscription(id: row)
        await gate.release()
        await assertChanged { _ = try await task.value }
    }

    func testScreenDeletionDuringFinalAudioRevalidationCannotPublishAStaleScreen() async throws {
        let screen = try await insertScreen("Cedar pricing")
        _ = try await insertAudio("Cedar pricing")
        let reached = expectation(description: "Actual V30 revalidation metric")
        let gate = HistorySearchTestGate(reached: reached)
        gates.append(gate)
        await audioReader.close()
        audioReader = try NativeAudioEvidenceStore(connection: SQLiteConnection(
            readOnlyDatabasePath: directory.appendingPathComponent("authored-audio.sqlite").path), metric: { operation, _ in
                if operation == "revalidate" { await gate.waitOnce() }
            })
        let task = Task { try await self.search("Cedar") }
        searches.append(task)
        await fulfillment(of: [reached], timeout: 10)
        try await database.deleteFrame(id: screen.frameID)
        await gate.release()
        await assertChanged { _ = try await task.value }
    }

    func testCancelledFinalMetricWaitReturnsNoPartialBatch() async throws {
        _ = try await insertScreen("Cedar pricing")
        _ = try await insertAudio("Cedar pricing")
        let reached = expectation(description: "History final metric before cancellation")
        let gate = HistorySearchTestGate(reached: reached)
        gates.append(gate)
        await evidence.setMetricCheckpointForTesting { action in
            if action == .historySearched { await gate.waitOnce() }
        }
        let task = Task { try await self.search("Cedar") }
        searches.append(task)
        await fulfillment(of: [reached], timeout: 10)
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled batch escaped") }
        catch is CancellationError { }
    }

    func testRevalidationRejectsAlteredSourceExcerptCharacters() async throws {
        _ = try await insertScreen("Cedar pricing")
        _ = try await insertAudio("Cedar pricing")
        let original = try await search("Cedar")
        for index in original.results.indices {
            var results = original.results
            switch results[index] {
            case .screen(let hit):
                results[index] = .screen(.init(result: hit.result, excerpt: .init(reference: hit.reference,
                    channel: hit.excerpt.channel, utf16Range: hit.excerpt.utf16Range,
                    text: "invented", provenance: hit.excerpt.provenance)))
            case .audio(let hit):
                results[index] = .audio(.init(snapshot: hit.snapshot, excerpt: .init(reference: hit.snapshot.reference,
                    utf16Range: hit.excerpt.utf16Range, text: "invented")))
            }
            let changed = HistorySearchResults(query: original.query, results: results, coverage: original.coverage,
                readStamp: original.readStamp, searchTimeMs: original.searchTimeMs)
            await assertChanged { try await self.revalidate(changed) }
        }
    }

    func testRevalidationRejectsAChangedSnapshotEvenWhenItsExcerptMatchesTheForgery() async throws {
        _ = try await insertAudio("Cedar pricing")
        let original = try await search("Cedar")
        guard case .audio(let hit) = try XCTUnwrap(original.results.first) else { return XCTFail("Exact audio result missing") }
        let source = hit.snapshot
        let changed = AudioEvidenceSnapshot(reference: source.reference, recordingID: source.recordingID,
            recordingSource: source.recordingSource, recordingStartedAt: source.recordingStartedAt,
            recordingEndedAt: source.recordingEndedAt, text: "Birch pricing", transcriptStatus: source.transcriptStatus,
            transcriptionPass: source.transcriptionPass, detectedLanguage: source.detectedLanguage,
            audioVariant: source.audioVariant, confidence: source.confidence)
        let forged = AudioEvidenceSearchHit(snapshot: changed, excerpt: .init(reference: source.reference,
            utf16Range: .init(location: 0, length: changed.text.utf16.count), text: changed.text))
        let page = HistorySearchResults(query: original.query, results: [.audio(forged)], coverage: original.coverage,
            readStamp: original.readStamp, searchTimeMs: original.searchTimeMs)
        await assertChanged { try await self.revalidate(page) }
    }

    func testHidingAnActualScreenAfterSearchInvalidatesTheWholeCachedBatch() async throws {
        let screen = try await insertScreen("Cedar pricing")
        _ = try await insertAudio("Cedar pricing")
        let page = try await search("Cedar")
        let frame = try await database.getFrame(id: screen.frameID)
        let tag = try await database.getTag(name: "hidden")
        try await database.addTagToSegment(segmentId: .init(value: XCTUnwrap(frame).segmentID.value),
                                          tagId: XCTUnwrap(tag).id)
        await assertChanged { try await self.revalidate(page) }
    }

    func testPresentationDigestChangesWithRealMutationAndCurrentPolicy() async throws {
        let first = try await evidence.presentationStamp(sources: [.native]).fingerprintSHA256()
        _ = try await insertScreen("Cedar pricing")
        let second = try await evidence.presentationStamp(sources: [.native]).fingerprintSHA256()
        XCTAssertNotEqual(first, second)
        await policy.exclude("com.private.authored")
        let third = try await evidence.presentationStamp(sources: [.native]).fingerprintSHA256()
        XCTAssertNotEqual(second, third)
        XCTAssertEqual(third.count, 64)
        XCTAssertFalse(third.contains("com.private.authored"))
    }

    func testInvalidBoundsAndChronologicalPaginationNeverReachAnySourceRoute() async throws {
        let counter = HistorySearchTestCounter()
        let invalid = [SearchQuery(text: "", mode: .relevant), .init(text: "Cedar\0", mode: .relevant),
            .init(text: String(repeating: "a", count: 32_769), mode: .relevant),
            .init(text: "Cedar", limit: 0, mode: .relevant), .init(text: "Cedar", limit: 101, mode: .relevant),
            .init(text: "Cedar", offset: 1, mode: .relevant), .init(text: "Cedar", mode: .all)]
        for query in invalid {
            do {
                _ = try await HistoryMomentSearch.search(query: query, adapter: adapter, evidence: evidence,
                    screenSearch: { query in await counter.called(); return try await self.screenSearch(query) },
                    audioHistory: audioReader)
                XCTFail("Invalid bounded moments request was accepted")
            } catch is CancellationError { throw CancellationError() }
            catch { }
        }
        let calls = await counter.value
        XCTAssertEqual(calls, 0)
    }

    func testHistoryDailyMetricsNeverIncludeCapturedOrQueryText() async throws {
        _ = try await insertScreen("Cedar private authored screen")
        _ = try await insertAudio("Cedar private authored transcript")
        let page = try await search("Cedar")
        try await revalidate(page)
        let pointer = await database.getConnection()
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(try XCTUnwrap(pointer),
            "SELECT metadata FROM daily_metrics WHERE metricType='progressive_recall_action'", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var history: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let text = String(cString: sqlite3_column_text(statement, 0))
            if text.contains("historySearched") || text.contains("historyRevalidated") { history.append(text) }
        }
        XCTAssertGreaterThanOrEqual(history.count, 2)
        XCTAssertTrue(history.allSatisfy { !$0.contains("Cedar") && !$0.contains("private authored") && !$0.contains("authored-audio") })
    }

    private func search(_ text: String, limit: Int = 50) async throws -> HistorySearchResults {
        try await search(.init(text: text, limit: limit, mode: .relevant))
    }
    private func search(_ query: SearchQuery) async throws -> HistorySearchResults {
        try await search(query, audio: audioReader)
    }
    private func search(_ query: SearchQuery, audio: (any AudioEvidenceStoreProtocol)?) async throws -> HistorySearchResults {
        try await HistoryMomentSearch.search(query: query, adapter: adapter, evidence: evidence,
            screenSearch: { try await self.screenSearch($0) }, audioHistory: audio)
    }
    private func screenSearch(_ query: SearchQuery) async throws -> SearchResults {
        try await HybridMomentSearch.search(query: query, adapter: adapter, evidence: evidence,
            semantic: { _ in nil }, revalidate: { _ in XCTFail("No model/index is enabled in this fixture") })
    }
    private func revalidate(_ page: HistorySearchResults) async throws {
        try await HistoryMomentSearch.revalidate(page, adapter: adapter, evidence: evidence, audioHistory: audioReader)
    }
    private func insertScreen(_ text: String, app: String = "com.authored.screen", offset: TimeInterval = 0) async throws -> ScreenEvidenceRef {
        let timestamp = now.addingTimeInterval(offset)
        let segment = try await database.insertSegment(bundleID: app, startDate: timestamp, endDate: timestamp,
            windowName: "Authored context", browserUrl: nil, type: 0)
        let video = try await database.insertVideoSegment(.init(id: .init(value: 0), startTime: timestamp,
            endTime: timestamp, frameCount: 1, fileSizeBytes: 100, relativePath: "absent-authored-\(segment).mp4", width: 640, height: 360))
        let metadata = FrameMetadata(appBundleID: app, windowName: "Authored context")
        let rawID = try await database.insertFrame(.init(id: .init(value: 0), timestamp: timestamp,
            segmentID: .init(value: segment), videoID: .init(value: video), frameIndexInSegment: 0,
            encodingStatus: .success, metadata: metadata))
        let id = FrameID(value: rawID)
        _ = try await database.commitFrameOCR(frameID: id, text: .init(frameID: id, timestamp: timestamp,
            regions: [], fullText: text, metadata: metadata), frameWidth: 640, frameHeight: 360)
        let store = try await database.activityStoreID()
        let snapshot = try await database.currentScreenEvidence(frameID: id, storeID: store)
        return try XCTUnwrap(snapshot).ref
    }
    private func insertAudio(_ text: String, offset: TimeInterval = 0) async throws -> (Int64, AudioEvidenceRef) {
        let timestamp = now.addingTimeInterval(offset)
        let path = "audio/batch_authored_\(UUID()).m4a"
        _ = try await audioQueries.insertRawBatch(startTime: timestamp, endTime: timestamp.addingTimeInterval(4),
            source: .system, audioPath: path, audioSize: 4096)
        let row = try await audioQueries.insertTranscription(sessionID: nil, text: text, startTime: timestamp,
            endTime: timestamp.addingTimeInterval(2), source: .system, confidence: 0.9,
            words: [], audioPath: path, transcriptionPass: 1, batchAudioPath: path)
        let page = try await audioReader.searchAudioEvidence(.init(terms: [], limit: 50))
        let hit = try XCTUnwrap(page.hits.first { $0.snapshot.text == text && $0.snapshot.startTime == timestamp })
        return (row, hit.snapshot.reference)
    }
    private func assertSlice(_ text: String, range: EvidenceUTF16Range, in source: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let string = source as NSString
        guard range.location >= 0, range.length > 0, range.location <= string.length,
              range.length <= string.length - range.location else { return XCTFail("Invalid exact source range", file: file, line: line) }
        XCTAssertEqual(Array(string.substring(with: NSRange(location: range.location, length: range.length)).utf16),
                       Array(text.utf16), file: file, line: line)
    }
    private func assertChanged(_ operation: () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Changed cached history escaped", file: file, line: line) }
        catch SearchPaginationError.dataChanged { }
        catch { XCTFail("Unexpected error type \(type(of: error))", file: file, line: line) }
    }
}

private actor HistorySearchTestPolicy {
    private var value = CaptureConfig()
    func read() -> CaptureConfig { value }
    func exclude(_ app: String) { value = CaptureConfig(excludedAppBundleIDs: [app]) }
}
private actor HistorySearchTestCounter {
    private(set) var value = 0
    func called() { value += 1 }
}
private actor HistorySearchTestGate {
    private let reached: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var used = false
    private var released = false
    init(reached: XCTestExpectation) { self.reached = reached }
    func waitOnce() async {
        guard !used else { return }
        used = true
        reached.fulfill()
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(); continuation = nil
    }
}
