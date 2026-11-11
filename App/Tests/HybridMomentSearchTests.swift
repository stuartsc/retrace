import CoreGraphics
import CryptoKit
import Foundation
import SQLCipher
import Shared
import Database
import Search
import Storage
import XCTest
@testable import App

/// Actual private SQLite/FTS/canonical evidence and the pinned authored vector
/// oracle. No screenshot decoding, live database, model download or fake ranker.
final class HybridMomentSearchTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var adapter: DataAdapter!
    private var evidence: ProgressiveRecallService!
    private var engine: SemanticRecallEngine?
    private var oracle: HybridOracle!
    private let policy = HybridPolicy()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hybrid-moments-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        database = DatabaseManager(databasePath: "file:hybrid-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let connection = await database.getConnection()
        let pointer = try XCTUnwrap(connection)
        adapter = DataAdapter(retraceConnection: SQLiteConnection(db: pointer),
            retraceConfig: .init(dateFormatter: nil, storageRoot: directory.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: directory.path), database: database)
        try await adapter.initialize()
        let policy = policy
        evidence = ProgressiveRecallService(database: database, adapter: adapter,
            configuration: { await policy.config() }, imageReader: { _ in
                XCTFail("Moment search must never decode media")
                throw EvidenceUnavailableReason.recordingMissing
            })
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let oracleBytes = try Data(contentsOf: root.appendingPathComponent("Search/Tests/Fixtures/MiniLM/embedding-oracle.json"))
        XCTAssertEqual(SHA256.hash(data: oracleBytes).map { String(format: "%02x", $0) }.joined(),
                       "9436ed5fde8039612f1a9355da0999a02f659622cb9e8838824c0672a9facf8f")
        oracle = try JSONDecoder().decode(HybridOracle.self, from: oracleBytes)
        let transition = try await database.beginScreenEvidenceWriterSession(policy: .init(config: CaptureConfig()))
        try await database.activateScreenEvidencePolicy(transition)
    }

    override func tearDown() async throws {
        if let engine { try await engine.stop() }
        evidence = nil
        if let adapter { await adapter.shutdown() }
        if let database { try await database.close() }
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testIdeaQuestionReturnsExactAuthoredEvidenceAndSupportingExcerptWithoutMedia() async throws {
        var references: [String: ScreenEvidenceRef] = [:]
        for item in oracle.cases where item.kind == "screen" { references[item.id] = try await insert(item.text) }
        try await startIndex(expected: references.count)
        let question = try XCTUnwrap(oracle.cases.first { $0.id == "Q01" })
        let result = try await search(.init(text: question.text, limit: 3))
        XCTAssertEqual(result.results.first?.evidenceRef, references[try XCTUnwrap(oracle.rankings[question.id]?.first)])
        XCTAssertEqual(result.results.count, 3)
        XCTAssertEqual(result.momentCoverage?.nativeSemanticUsed, true)
        XCTAssertEqual(result.momentCoverage?.semanticScanComplete, true)
        for match in result.results {
            let explanation = try XCTUnwrap(match.matchExplanation)
            XCTAssertTrue(explanation.bases.contains(.semanticSimilarity))
            XCTAssertFalse(explanation.supportingSpans.isEmpty)
            XCTAssertFalse(match.snippet.isEmpty)
            let reference = try XCTUnwrap(match.evidenceRef)
            XCTAssertTrue(explanation.supportingSpans.allSatisfy { $0.fragmentID.reference == reference })
            XCTAssertEqual(reference.source, .native)
        }
    }

    func testActualWholeIdentifierIsReservedWithoutCallingItsPrefixAnExactMatch() async throws {
        let prefix = try await insert("Build JOB-1234 pending. JOB-1234 JOB-1234 JOB-1234")
        let exact = try await insert("Build JOB-123 complete.")
        let page = try await search(.init(text: "JOB-123", limit: 10), enableSemantic: false)
        XCTAssertEqual(page.results.first?.evidenceRef, exact)
        let exactResult = try XCTUnwrap(page.results.first { $0.evidenceRef == exact })
        XCTAssertEqual(exactResult.matchExplanation?.exactIdentifiers, ["JOB-123"])
        if let other = page.results.first(where: { $0.evidenceRef == prefix }) {
            XCTAssertTrue(other.matchExplanation?.exactIdentifiers.isEmpty == true)
            XCTAssertFalse(other.matchExplanation?.bases.contains(.exactIdentifier) == true)
        }
        XCTAssertEqual(page.momentCoverage?.nativeSemanticUsed, false)
    }

    func testIdentifierProbeReservesActualMatchBehindALargePrefixCandidateSet() async throws {
        for _ in 0..<150 { _ = try await insert("JOB-1234 JOB-1234 JOB-1234 pending") }
        let exact = try await insert("The task JOB-123 is complete")
        let result = try await search(.init(text: "find JOB-123", limit: 1), enableSemantic: false)
        XCTAssertEqual(result.results.first?.evidenceRef, exact)
        XCTAssertEqual(result.results.first?.matchExplanation?.exactIdentifiers, ["JOB-123"])
    }

    func testUnicodeIdentifierExcerptIsAnActualSourceSubstring() async throws {
        let text = "🧠 cafe\u{301} 東京 status JOB-123 complete"
        let reference = try await insert(text)
        let page = try await search(.init(text: "JOB-123", limit: 1), enableSemantic: false)
        let result = try XCTUnwrap(page.results.first)
        XCTAssertEqual(result.evidenceRef, reference)
        XCTAssertTrue(text.contains(result.snippet))
        XCTAssertTrue(result.snippet.contains("JOB-123"))
    }

    func testHiddenPrefixIsExcludedBeforeSemanticCandidateLimit() async throws {
        let screen = try XCTUnwrap(oracle.cases.first { $0.kind == "screen" })
        for _ in 0..<40 { _ = try await insert(screen.text, hidden: true) }
        let visible = try await insert(screen.text)
        try await startIndex(expected: 41)
        let question = try XCTUnwrap(oracle.cases.first { $0.kind == "question" })
        let result = try await search(.init(text: question.text, limit: 1))
        XCTAssertEqual(result.results.map(\.evidenceRef), [visible])
        let hidden = try await search(.init(text: question.text, filters: .init(hiddenFilter: .onlyHidden), limit: 1))
        XCTAssertEqual(hidden.results.count, 1)
        XCTAssertNotEqual(hidden.results.first?.evidenceRef, visible)
    }

    func testRecreatedHiddenTagUsesItsCurrentIdentityBeforeLexicalLimit() async throws {
        let hidden = try await insert("contract contract contract")
        let visible = try await insert("contract retained visible text")
        let oldTag = try await database.getTag(name: "hidden")
        try await database.deleteTag(tagId: XCTUnwrap(oldTag).id)
        let replacement = try await database.createTag(name: "hidden")
        XCTAssertNotEqual(replacement.id, oldTag?.id)
        let frame = try await database.getFrame(id: hidden.frameID)
        try await database.addTagToSegment(segmentId: .init(value: XCTUnwrap(frame).segmentID.value), tagId: replacement.id)
        let hiddenByDefault = try await search(.init(text: "contract", limit: 1), enableSemantic: false)
        XCTAssertEqual(hiddenByDefault.results.map(\.evidenceRef), [visible])
        let only = try await search(.init(text: "contract", filters: .init(hiddenFilter: .onlyHidden), limit: 1), enableSemantic: false)
        XCTAssertEqual(only.results.map(\.evidenceRef), [hidden])
        let all = try await search(.init(text: "contract", filters: .init(hiddenFilter: .showAll), limit: 10), enableSemantic: false)
        XCTAssertEqual(Set(all.results.compactMap(\.evidenceRef)), [hidden, visible])
    }

    func testSingleDateAndAppExclusionsReachBothChannels() async throws {
        let screen = try XCTUnwrap(oracle.cases.first { $0.kind == "screen" })
        _ = try await insert(screen.text, app: "com.authored.excluded")
        _ = try await insert(screen.text, timestamp: now.addingTimeInterval(-10))
        let allowed = try await insert(screen.text, timestamp: now.addingTimeInterval(10))
        try await startIndex(expected: 3)
        let question = try XCTUnwrap(oracle.cases.first { $0.kind == "question" })
        let result = try await search(.init(text: question.text,
            filters: .init(startDate: now, excludedAppBundleIDs: ["com.authored.excluded"]), limit: 1))
        XCTAssertEqual(result.results.map(\.evidenceRef), [allowed])
    }

    func testUnsupportedConstraintsUseTheExistingLexicalPageIntact() async throws {
        _ = try await insert("Build JOB-123 complete")
        let counter = HybridCallCounter()
        let queries = [SearchQuery(text: "\"JOB-123\""), .init(text: "Build -pending"),
            .init(text: "Build", filters: .init(windowNameFilter: "Authored")),
            .init(text: "Build", filters: .init(commentFilter: .commentsOnly)),
            .init(text: "Build", filters: .init(selectedTagIds: [999])),
            .init(text: "Build", filters: .init(dateRanges: [.init(start: now, end: now), .init(start: now.addingTimeInterval(10))]))]
        for query in queries {
            let expected = try await adapter.search(query: query)
            let result = try await HybridMomentSearch.search(query: query, adapter: adapter, evidence: evidence,
                semantic: { _ in await counter.called(); return nil }, revalidate: { _ in XCTFail("Unsupported query reached semantic revalidation") })
            XCTAssertEqual(result.results.map(\.sourceQualifiedID), expected.results.map(\.sourceQualifiedID))
            XCTAssertEqual(result.totalCount, expected.totalCount)
            XCTAssertEqual(result.nextCursor, expected.nextCursor)
            XCTAssertNil(result.momentCoverage)
        }
        let calls = await counter.count()
        XCTAssertEqual(calls, 0)
    }

    func testDeletionAfterSemanticReadFailsTheWholeBatchClosed() async throws {
        let screen = try XCTUnwrap(oracle.cases.first { $0.kind == "screen" })
        let reference = try await insert(screen.text)
        try await startIndex(expected: 1)
        let question = try XCTUnwrap(oracle.cases.first { $0.kind == "question" })
        let engine = try XCTUnwrap(engine), database = database!
        do {
            _ = try await HybridMomentSearch.search(query: .init(text: question.text), adapter: adapter, evidence: evidence,
                semantic: { request in
                    let response = try await engine.search(request)
                    try await database.deleteFrame(id: reference.frameID)
                    return response
                }, revalidate: { try await database.revalidateSemanticRecallRead(stamp: $0) })
            XCTFail("Deleted evidence escaped")
        } catch is CancellationError { throw CancellationError() }
        catch { }
    }

    func testPrivacyChangeAfterSemanticReadReturnsNoRetainedExcerpt() async throws {
        let screen = try XCTUnwrap(oracle.cases.first { $0.kind == "screen" })
        _ = try await insert(screen.text)
        try await startIndex(expected: 1)
        let question = try XCTUnwrap(oracle.cases.first { $0.kind == "question" })
        let engine = try XCTUnwrap(engine), database = database!, policy = policy
        do {
            _ = try await HybridMomentSearch.search(query: .init(text: question.text), adapter: adapter, evidence: evidence,
                semantic: { request in
                    let response = try await engine.search(request)
                    await policy.exclude("com.authored.hybrid")
                    return response
                }, revalidate: { try await database.revalidateSemanticRecallRead(stamp: $0) })
            XCTFail("Newly excluded retained text escaped")
        } catch is CancellationError { throw CancellationError() }
        catch { }
    }

    func testMalformedSemanticSupportingSpanFailsClosed() async throws {
        let screen = try XCTUnwrap(oracle.cases.first { $0.kind == "screen" })
        _ = try await insert(screen.text)
        try await startIndex(expected: 1)
        let question = try XCTUnwrap(oracle.cases.first { $0.kind == "question" })
        let engine = try XCTUnwrap(engine), database = database!
        do {
            _ = try await HybridMomentSearch.search(query: .init(text: question.text), adapter: adapter, evidence: evidence,
                semantic: { request in
                    let response = try await engine.search(request)
                    let match = try XCTUnwrap(response.matches.first), span = try XCTUnwrap(match.spans.first)
                    let bad = SemanticRecallSpan(fragmentID: span.fragmentID,
                        sourceUTF16Range: .init(location: Int.max, length: 10), inputUTF16Range: span.inputUTF16Range)
                    let forged = SemanticRecallMatch(reference: match.reference, captureTimestamp: match.captureTimestamp,
                        cosine: match.cosine, spans: [bad], queryUTF16Range: match.queryUTF16Range,
                        pageOrdinal: match.pageOrdinal, windowOrdinal: match.windowOrdinal)
                    return .init(matches: [forged], stamp: response.stamp, coverage: response.coverage,
                        scanComplete: response.scanComplete, inspectedCount: response.inspectedCount,
                        scannedWindowCount: response.scannedWindowCount, elapsedMilliseconds: response.elapsedMilliseconds)
                }, revalidate: { try await database.revalidateSemanticRecallRead(stamp: $0) })
            XCTFail("Forged supporting span escaped")
        } catch { XCTAssertEqual(error as? EvidenceUnavailableReason, .integrityFailure) }
    }

    func testPartialSemanticScanRemainsVisibleInMomentCoverage() async throws {
        let screen = try XCTUnwrap(oracle.cases.first { $0.kind == "screen" })
        for _ in 0..<140 { _ = try await insert(screen.text) }
        try await startIndex(expected: 140)
        let question = try XCTUnwrap(oracle.cases.first { $0.kind == "question" })
        let engine = try XCTUnwrap(engine), database = database!
        let result = try await HybridMomentSearch.search(query: .init(text: question.text, limit: 3), adapter: adapter, evidence: evidence,
            semantic: { request in
                try await engine.search(.init(text: request.text, filter: request.filter, limit: request.limit,
                                             maximumPages: 1, maximumDuration: 30))
            }, revalidate: { try await database.revalidateSemanticRecallRead(stamp: $0) })
        XCTAssertEqual(result.momentCoverage?.semanticScanComplete, false)
        XCTAssertEqual(result.momentCoverage?.indexedObservations, 140)
        XCTAssertEqual(result.results.count, 3)
    }

    func testImportedAndNativeEqualFrameIDsRemainDistinctLexicalMoments() async throws {
        let native = try await insert("contract native authored text")
        let path = directory.appendingPathComponent("authored-import.sqlite").path
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &pointer), SQLITE_OK)
        let db = try XCTUnwrap(pointer)
        var writerClosed = false
        defer { if !writerClosed { sqlite3_close_v2(db) } }
        let writer = SQLiteConnection(db: db)
        try writer.execute(sql: """
            CREATE TABLE segment(id INTEGER PRIMARY KEY,bundleID TEXT,startDate TEXT,endDate TEXT,windowName TEXT,browserUrl TEXT,type INTEGER);
            CREATE TABLE frame(id INTEGER PRIMARY KEY,createdAt TEXT,imageFileName TEXT,segmentId INTEGER,videoId INTEGER,videoFrameIndex INTEGER,encodingStatus TEXT);
            CREATE TABLE video(id INTEGER PRIMARY KEY,path TEXT,frameRate REAL,width INTEGER,height INTEGER);
            CREATE TABLE node(id INTEGER PRIMARY KEY,frameId INTEGER,nodeOrder INTEGER,textOffset INTEGER,textLength INTEGER,leftX REAL,topY REAL,width REAL,height REAL);
            CREATE VIRTUAL TABLE searchRanking USING fts5(text,otherText,title);
            CREATE TABLE doc_segment(docid INTEGER,segmentId INTEGER,frameId INTEGER);
            INSERT INTO segment VALUES(1,'com.authored.import','2023-11-14T22:13:20.000','2023-11-14T22:13:20.000','Imported contract',NULL,0);
            INSERT INTO video VALUES(7,'authored-missing.mp4',30,640,360);
            INSERT INTO frame VALUES(\(native.frameID.value),'2023-11-14T22:13:20.000','authored',1,7,0,'success');
            INSERT INTO searchRanking(rowid,text,otherText,title) VALUES(1,'contract imported authored text',NULL,'Imported contract');
            INSERT INTO doc_segment VALUES(1,1,\(native.frameID.value));
            """)
        XCTAssertEqual(sqlite3_close_v2(db), SQLITE_OK); writerClosed = true
        let imported = try SQLiteConnection(readOnlyDatabasePath: path)
        await adapter.configureRewind(connection: imported,
            config: .init(dateFormatter: DatabaseConfig.rewind.dateFormatter, storageRoot: directory.path,
                          source: .rewind, cutoffDate: .distantFuture),
            imageExtractor: HEVCStorageExtractor(storageRoot: directory.path), cutoffDate: .distantFuture)
        let result = try await search(.init(text: "contract", limit: 10), enableSemantic: false)
        XCTAssertEqual(result.results.count, 2)
        XCTAssertEqual(Set(result.results.map(\.id.value)), [native.frameID.value])
        XCTAssertEqual(Set(result.results.map(\.sourceQualifiedID)).count, 2)
        XCTAssertEqual(Set(result.results.compactMap { $0.evidenceRef?.source }), [.native, .rewind])
        let importedMatch = try XCTUnwrap(result.results.first { $0.source == .rewind })
        XCTAssertEqual(importedMatch.matchExplanation?.bases, [.textMatch])
    }

    func testCancellationDuringSemanticHandoffReturnsNoPartialResults() async throws {
        let screen = try XCTUnwrap(oracle.cases.first { $0.kind == "screen" })
        _ = try await insert(screen.text)
        try await startIndex(expected: 1)
        let question = try XCTUnwrap(oracle.cases.first { $0.kind == "question" })
        let engine = try XCTUnwrap(engine), database = database!, adapter = adapter!, evidence = evidence!
        let reached = expectation(description: "Actual semantic response reached hybrid handoff")
        let (stream, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let request = Task {
            try await HybridMomentSearch.search(query: .init(text: question.text), adapter: adapter, evidence: evidence,
                semantic: { value in
                    let result = try await engine.search(value)
                    reached.fulfill()
                    for await _ in stream { break }
                    try Task.checkCancellation()
                    return result
                }, revalidate: { try await database.revalidateSemanticRecallRead(stamp: $0) })
        }
        await fulfillment(of: [reached], timeout: 10)
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled hybrid returned partial data") }
        catch is CancellationError { }
    }

    func testLegacySearchJSONDecodesWithoutMomentFields() async throws {
        _ = try await insert("contract authored text")
        let legacy = try await adapter.search(query: .init(text: "contract"))
        let bytes = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(SearchResults.self, from: bytes)
        XCTAssertNil(decoded.momentCoverage)
        XCTAssertNil(try XCTUnwrap(decoded.results.first).matchExplanation)
        XCTAssertEqual(decoded.results.map(\.sourceQualifiedID), legacy.results.map(\.sourceQualifiedID))
    }

    private func insert(_ text: String, app: String = "com.authored.hybrid", timestamp: Date? = nil,
                        hidden: Bool = false) async throws -> ScreenEvidenceRef {
        let timestamp = timestamp ?? now
        let segment = try await database.insertSegment(bundleID: app, startDate: timestamp, endDate: timestamp,
                                                       windowName: "Authored context", browserUrl: nil, type: 0)
        let video = try await database.insertVideoSegment(.init(id: .init(value: 0), startTime: timestamp,
            endTime: timestamp, frameCount: 1, fileSizeBytes: 100, relativePath: "authored-\(segment).mp4", width: 640, height: 360))
        let metadata = FrameMetadata(appBundleID: app, windowName: "Authored context")
        let id = try await database.insertFrame(.init(id: .init(value: 0), timestamp: timestamp,
            segmentID: .init(value: segment), videoID: .init(value: video), frameIndexInSegment: 0,
            encodingStatus: .success, metadata: metadata))
        let frameID = FrameID(value: id)
        let extracted = ExtractedText(frameID: frameID, timestamp: timestamp, regions: [], fullText: text, metadata: metadata)
        _ = try await database.commitFrameOCR(frameID: frameID, text: extracted, frameWidth: 640, frameHeight: 360)
        if hidden {
            let connection = await database.getConnection()
            let pointer = try XCTUnwrap(connection)
            let statement = try XCTUnwrap(SQLiteConnection(db: pointer).prepare(sql:
                "INSERT INTO segment_tag(segmentId,tagId) SELECT ?,id FROM tag WHERE name='hidden'"))
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, segment)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
        let store = try await database.activityStoreID()
        let snapshot = try await database.currentScreenEvidence(frameID: frameID, storeID: store)
        return try XCTUnwrap(snapshot).ref
    }

    private func startIndex(expected: Int) async throws {
        let runtime = HybridOracleRuntime(oracle: oracle)
        let candidate = SemanticRecallEngine(store: database, makeRuntime: { runtime }, recordMetric: { _ in },
            configuration: .init(backgroundPagesPerYield: 64, backgroundYieldMilliseconds: 0))
        engine = candidate
        try await candidate.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if await candidate.status().coverage?.completedObservations == expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Real index did not complete within the fixture bound")
        throw SemanticRecallEngineError.stopped
    }

    private func search(_ query: SearchQuery, enableSemantic: Bool = true) async throws -> SearchResults {
        let engine = engine, database = database!
        return try await HybridMomentSearch.search(query: query, adapter: adapter, evidence: evidence,
            semantic: { request in
                guard enableSemantic, let engine else { return nil }
                return try await engine.search(.init(text: request.text, filter: request.filter, limit: request.limit,
                                                    maximumPages: request.maximumPages, maximumDuration: 30))
            }, revalidate: { try await database.revalidateSemanticRecallRead(stamp: $0) })
    }
}

private actor HybridPolicy {
    private var value = CaptureConfig()
    func config() -> CaptureConfig { value }
    func exclude(_ app: String) { value = CaptureConfig(excludedAppBundleIDs: [app]) }
}
private actor HybridCallCounter {
    private var value = 0
    func called() { value += 1 }
    func count() -> Int { value }
}
private struct HybridOracle: Decodable, Sendable {
    let cases: [Item]
    let rankings: [String: [String]]
    struct Item: Decodable, Sendable { let id: String; let kind: String; let text: String; let windows: [Window] }
    struct Window: Decodable, Sendable { let tokenStart: Int; let tokenEnd: Int; let utf16Range: EvidenceUTF16Range; let vector: [Float] }
}
private actor HybridOracleRuntime: LocalEmbeddingRuntimeProtocol {
    let oracle: HybridOracle
    init(oracle: HybridOracle) { self.oracle = oracle }
    func prepare() -> LocalEmbeddingDescriptor { .miniLM }
    func embed(_ text: String) throws -> LocalEmbeddingBatch {
        try Task.checkCancellation()
        guard let item = oracle.cases.first(where: { $0.text == text }) else { throw LocalEmbeddingError.invalidOutput }
        return .init(descriptor: .miniLM, windows: item.windows.map {
            .init(tokenStart: $0.tokenStart, tokenEnd: $0.tokenEnd, inputUTF16Range: $0.utf16Range, vector: $0.vector)
        })
    }
    func status() -> LocalEmbeddingStatus { .init(isPrepared: true, isEmbedding: false, completedWindowCount: 0, totalWindowCount: 0) }
    func close() { }
}
