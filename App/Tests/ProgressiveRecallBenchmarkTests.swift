import CoreGraphics
import CryptoKit
import Darwin
import Database
import Foundation
import ImageIO
import Processing
import Shared
import SQLCipher
import Storage
import XCTest
@testable import App

/// Authored pixels only: no installed library, preferences, model or media reader.
/// The first timing is the first execution of that query, not a cold-process measurement.
final class ProgressiveRecallBenchmarkTests: XCTestCase {
    private static let datasetDigest = "93b521bf9f5fc9bcd621b9e91a485c8fcc0681c3057a9f5237effad91e41b694"
    private static let datasetDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/fixtures/progressive-recall/phase2d", isDirectory: true)

    func testAuthoredJPEGsProduceExactPrimarySearchBenchmark() async throws {
        // Admission precedes every production call that could initialize the logger.
        #if DEBUG
        try require(ProcessInfo.processInfo.environment["RETRACE_TEST_DISABLE_FILE_LOGGING"] == "1",
                    "Launch this test with RETRACE_TEST_DISABLE_FILE_LOGGING=1; it never changes logging or preferences itself")
        #else
        throw BenchmarkFailure.invalid("This isolated developer benchmark requires a debug test build")
        #endif
        let dataset = try Self.readDataset()
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        var adapter: DataAdapter?
        do {
            // Complete every fixture write before lending SQLite's FULLMUTEX handle to App.
            let snapshots = try await ingest(dataset, database: database)
            let opened = await database.getConnection()
            let pointer = try XCTUnwrap(opened)
            let filename = try XCTUnwrap(sqlite3_db_filename(pointer, "main"))
            try require(String(cString: filename) == "", "Only an in-memory database is allowed")
            try require(sqlite3_get_autocommit(pointer) == 1, "Ingestion left a transaction open")
            let storageRoot = "/private/tmp/retrace-authored-benchmark-unused-\(UUID().uuidString)"
            let reader = DataAdapter(retraceConnection: SQLiteConnection(db: pointer),
                retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: storageRoot, source: .native, cutoffDate: nil),
                retraceImageExtractor: HEVCStorageExtractor(storageRoot: storageRoot), database: database)
            adapter = reader
            try await reader.initialize()
            let policy = BenchmarkPolicy()
            let service = ProgressiveRecallService(database: database, adapter: reader,
                configuration: { await policy.configuration() }, imageReader: { _ in
                    throw BenchmarkFailure.invalid("The ranking benchmark must never request media")
                })
            let generation = try await service.sourceGeneration(source: .native)
            let screens = try await exportScreens(dataset, snapshots: snapshots, service: service)
            // Bind the complete oracle and eligible pools before executing any ranked query.
            var bound: [BoundQuestion] = []
            for question in dataset.questions {
                bound.append(try await bind(question, screens: screens, snapshots: snapshots, adapter: reader, service: service))
            }
            try await checkGeneration(generation, service: service)
            var questions: [QuestionExport] = []
            for item in bound {
                let full = try await measure(item.question.question, bound: item, screens: screens,
                    adapter: reader, service: service, generation: generation)
                let keywords = try await measure(item.question.keywordQuery, bound: item, screens: screens,
                    adapter: reader, service: service, generation: generation)
                questions.append(.init(id: item.question.id, question: item.question.question,
                    keywordQuery: item.question.keywordQuery, constraints: item.question.constraints,
                    expectedIDs: item.question.expectedIDs, expectedRefs: item.expectedRefs,
                    allowedIDs: item.allowedIDs, fullQuestion: full, authoredKeywords: keywords))
            }
            try await checkGeneration(generation, service: service)
            let readState = Self.statementState(pointer)
            let diagnostics = JSONEncoder()
            diagnostics.outputFormatting = [.sortedKeys]
            print("AUTHORED_RECALL_SQLITE_STATE \(String(decoding: try diagnostics.encode(readState), as: UTF8.self))")
            try Self.requireQuiescent(readState)
            // Destructive refusal checks run only after the immutable benchmark records are frozen.
            let checks = try await safetyChecks(dataset, snapshots: snapshots, database: database,
                                                adapter: reader, service: service, policy: policy)
            let export = BenchmarkExport(schemaVersion: 1, kind: "retrace-authored-recall-benchmark",
                datasetSHA256: Self.datasetDigest, screens: screens, questions: questions, safetyChecks: checks,
                timingScope: "First execution of each query, then three warm repetitions on one initialized private SQLite database; not cold process or cold filesystem",
                ocrConfiguration: "Vision via ProcessingManager; accurate; en-US; minimumConfidence=0.3; accessibilityEnabled=false; preferBackgroundProcessing=true",
                safetyScope: "Cross-source refusal uses the native numeric frame ID attributed to an unavailable Rewind source; no imported or installed library is opened",
                sqliteReadState: readState)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let bytes = try encoder.encode(export)
            try require(bytes.count <= 2 * 1_024 * 1_024, "Authored export exceeded its bounded size")
            if let destination = ProcessInfo.processInfo.environment["RETRACE_RECALL_BENCHMARK_EXPORT"] {
                try Self.writeExclusive(bytes, path: destination)
            }
            print("AUTHORED_RECALL_BENCHMARK screens=\(screens.count) questions=\(questions.count) datasetSHA256=\(Self.datasetDigest) exportSHA256=\(Self.sha256(bytes))")
            await reader.shutdown()
            try await database.close()
        } catch {
            if let adapter { await adapter.shutdown() }
            try? await database.close()
            throw error
        }
    }

    func testExportRefusesOverwriteAndSymlinkDestinations() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/retrace-benchmark-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("receipt.json")
        let first = Data("authored first receipt".utf8)
        try Self.writeExclusive(first, path: destination.path)
        XCTAssertThrowsError(try Self.writeExclusive(Data("replacement".utf8), path: destination.path))
        XCTAssertEqual(try Data(contentsOf: destination), first)
        let link = directory.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        XCTAssertThrowsError(try Self.writeExclusive(Data("replacement".utf8), path: link.path))
        let linkedDirectory = directory.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: directory)
        XCTAssertThrowsError(try Self.writeExclusive(first, path: linkedDirectory.appendingPathComponent("escape.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("escape.json").path))
        XCTAssertEqual(try Data(contentsOf: destination), first)
        XCTAssertThrowsError(try Self.writeExclusive(first, path: "/Users/benchmark-must-not-write.json"))
    }

    func testSQLiteReadGuardRejectsHeldCursorAndTransactionButAllowsResetStatements() throws {
        var opened: OpaquePointer?
        try require(sqlite3_open_v2(":memory:", &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
            "Could not open the private guard fixture")
        let database = try XCTUnwrap(opened)
        defer { sqlite3_close_v2(database) }
        try require(sqlite3_exec(database, """
            CREATE VIRTUAL TABLE guard_search USING fts5(text);
            INSERT INTO guard_search VALUES('Cedar proposal 42000'),('Cedar proposal 47000');
            """, nil, nil, nil) == SQLITE_OK, "Could not populate the real FTS guard fixture")
        var prepared: OpaquePointer?
        try require(sqlite3_prepare_v2(database,
            "SELECT rowid FROM guard_search WHERE guard_search MATCH 'Cedar' ORDER BY rowid", -1,
            &prepared, nil) == SQLITE_OK, "Could not prepare the actual FTS reader")
        let held = try XCTUnwrap(prepared)
        // This is our own statement; SQLite's internally cached FTS statements stay untouched.
        defer { sqlite3_finalize(held) }
        try require(sqlite3_step(held) == SQLITE_ROW, "The guard needs a real unfinished read cursor")
        let busy = Self.statementState(database)
        XCTAssertTrue(busy.autocommit, "An implicit active read can coexist with autocommit=true")
        XCTAssertTrue(busy.statements.contains { $0.busy && $0.readOnly })
        XCTAssertThrowsError(try Self.requireQuiescent(busy))
        try require(sqlite3_reset(held) == SQLITE_OK, "Could not release our held cursor")
        let reset = Self.statementState(database)
        XCTAssertFalse(reset.statements.isEmpty, "Prepared statements can remain without holding a read transaction")
        XCTAssertFalse(reset.statements.contains(where: \.busy))
        XCTAssertNoThrow(try Self.requireQuiescent(reset))
        try require(sqlite3_exec(database, "BEGIN DEFERRED", nil, nil, nil) == SQLITE_OK,
                    "Could not open the explicit transaction")
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        let transaction = Self.statementState(database)
        XCTAssertFalse(transaction.autocommit)
        XCTAssertFalse(transaction.statements.contains(where: \.busy))
        XCTAssertThrowsError(try Self.requireQuiescent(transaction))
    }

    private static func statementState(_ database: OpaquePointer) -> SQLiteReadState {
        var statements: [SQLiteStatementState] = []
        var cursor = sqlite3_next_stmt(database, nil)
        while let statement = cursor {
            let sql = sqlite3_sql(statement).map { String(cString: $0) } ?? "<unavailable>"
            let lower = sql.lowercased()
            let category: String
            if lower.contains("searchranking_") { category = "ftsShadowTable" }
            else if lower.hasPrefix("pragma") { category = "pragma" }
            else { category = "applicationOrOtherInternal" }
            statements.append(.init(busy: sqlite3_stmt_busy(statement) != 0,
                readOnly: sqlite3_stmt_readonly(statement) != 0, category: category, sql: sql))
            cursor = sqlite3_next_stmt(database, statement)
        }
        return SQLiteReadState(autocommit: sqlite3_get_autocommit(database) != 0,
            transactionState: sqlite3_txn_state(database, "main"), statements: statements)
    }

    private static func requireQuiescent(_ state: SQLiteReadState) throws {
        // A prepared/reset statement is not an active reader. FTS5 owns its cached statements;
        // never finalize/reset those. Check both explicit transactions and implicit busy cursors.
        try require(state.autocommit && state.transactionState == SQLITE_TXN_NONE
            && !state.statements.contains(where: \.busy),
            "Benchmark reads must close active cursors and transactions before export/model work")
    }

    private static func readDataset() throws -> Dataset {
        let bytes = try Data(contentsOf: datasetDirectory.appendingPathComponent("dataset.json"))
        try require(sha256(bytes) == datasetDigest, "The reviewed dataset changed; refreeze it before running")
        let dataset = try JSONDecoder().decode(Dataset.self, from: bytes)
        try require(dataset.schemaVersion == 1 && dataset.screens.count == 8 && dataset.questions.count == 12,
                    "Unexpected authored dataset shape")
        try require(dataset.ranking.warmRepetitions == 3, "Unexpected timing protocol")
        let ids = Set(dataset.screens.map(\.id))
        try require(ids.count == 8 && Set(dataset.questions.map(\.id)).count == 12, "Duplicate fixture identity")
        for question in dataset.questions {
            try require(question.constraints.source == .native && !question.question.isEmpty && !question.keywordQuery.isEmpty,
                        "Only explicit native authored questions are supported")
            try require(!question.expectedIDs.isEmpty && Set(question.expectedIDs).isSubset(of: ids), "Invalid predeclared oracle")
            for phrase in question.constraints.requiredPhrases ?? [] {
                try require(question.question.contains(phrase) && question.keywordQuery.contains(phrase),
                            "Required phrases must already be present in both frozen queries")
            }
        }
        return dataset
    }

    private func ingest(_ dataset: Dataset, database: DatabaseManager) async throws -> [String: ScreenEvidenceSnapshot] {
        var snapshots: [String: ScreenEvidenceSnapshot] = [:]
        let processing = ProcessingManager(config: ProcessingConfig(accessibilityEnabled: false,
            ocrAccuracyLevel: .accurate, recognitionLanguages: ["en-US"], minimumConfidence: 0.3,
            preferBackgroundProcessing: true))
        for screen in dataset.screens {
            let frame = try Self.decode(screen)
            let result = try await processing.extractText(from: frame)
            // Normalize only these visually interchangeable dash variants for assertions.
            // Stored/indexed/exported OCR bytes are never rewritten or supplied by the oracle.
            let observed = Self.visualHyphens(result.fullText + "\n" + result.chromeText)
            for required in screen.requiredOCR {
                try require(observed.contains(Self.visualHyphens(required)),
                            "Actual Vision OCR for \(screen.id) omitted required visible text: \(required); observed: \(observed)")
            }
            let segment = try await database.insertSegment(bundleID: screen.appBundleID, startDate: frame.timestamp,
                endDate: frame.timestamp, windowName: screen.title, browserUrl: nil, type: 0)
            let inserted = try await database.insertFrame(FrameReference(id: .init(value: 0), timestamp: frame.timestamp,
                segmentID: .init(value: segment), frameIndexInSegment: 0, metadata: frame.metadata))
            let frameID = FrameID(value: inserted)
            _ = try await database.commitFrameOCR(frameID: frameID, text: result, frameWidth: frame.width, frameHeight: frame.height)
            let storeID = try await database.activityStoreID()
            let saved = try await database.currentScreenEvidence(frameID: frameID, storeID: storeID)
            let snapshot = try XCTUnwrap(saved)
            try require(snapshot.ref.source == .native && snapshot.ref.frameID == frameID && snapshot.ref.storeID == storeID,
                        "Canonical extraction lost its source-qualified identity")
            try require(snapshot.ref.extractionRevision >= 0 && snapshot.ref.blockIDs.isEmpty && !snapshot.legacyContext,
                        "Expected a newly captured whole-screen immutable extraction")
            try require(snapshot.text?.fullText.utf8.elementsEqual(result.fullText.utf8) == true
                && snapshot.text?.chromeText.utf8.elementsEqual(result.chromeText.utf8) == true,
                "Persistence changed actual OCR bytes")
            try Self.validateStructure(snapshot)
            snapshots[screen.id] = snapshot
        }
        try require(Set(snapshots.values.map { $0.ref.observationID }).count == dataset.screens.count,
                    "Same-title frames were incorrectly collapsed")
        return snapshots
    }

    private static func decode(_ screen: Screen) throws -> CapturedFrame {
        let url = datasetDirectory.appendingPathComponent(screen.file).standardizedFileURL
        let approvedRoot = datasetDirectory.deletingLastPathComponent().standardizedFileURL.path + "/"
        try require(url.path.hasPrefix(approvedRoot) && url.resolvingSymlinksInPath().path == url.path,
                    "Fixture image must be an ordinary file within the authored corpus")
        let bytes = try Data(contentsOf: url)
        try require(bytes.count <= 2 * 1_024 * 1_024 && sha256(bytes) == screen.imageSHA256, "Reviewed image hash changed: \(screen.id)")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        try require(image.width == 1280 && image.height == 800, "Unexpected authored image dimensions")
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * image.height)
        return CapturedFrame(timestamp: Date(timeIntervalSince1970: screen.capturedAt), imageData: pixels,
            width: image.width, height: image.height, bytesPerRow: context.bytesPerRow,
            metadata: FrameMetadata(appBundleID: screen.appBundleID, windowName: screen.title, displayID: 0))
    }

    private static func validateStructure(_ snapshot: ScreenEvidenceSnapshot) throws {
        let observation = snapshot.observation
        try require(observation.provenance.origin == .ocr && snapshot.highlightsVerified && !observation.blocks.isEmpty,
                    "Actual OCR must publish coherent, verified blocks")
        let extent = CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height)
        for block in observation.blocks {
            let box = try XCTUnwrap(block.bounds)
            try require(!box.isEmpty && !box.isNull && !box.isInfinite && extent.contains(box), "Invalid OCR block geometry")
            let text = block.channel == .main ? observation.mainText : observation.chromeText
            let range = block.utf16Range
            try require(range.location >= 0 && range.length > 0 && range.location <= text.utf16.count - range.length,
                        "Invalid OCR block text range")
            let substring = (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
            try require(substring.utf8.elementsEqual(block.text.utf8), "Block does not address its exact retained text")
        }
    }

    private func exportScreens(_ dataset: Dataset, snapshots: [String: ScreenEvidenceSnapshot],
                               service: ProgressiveRecallService) async throws -> [ScreenExport] {
        var result: [ScreenExport] = []
        for screen in dataset.screens {
            let original = try XCTUnwrap(snapshots[screen.id])
            let reference = try await service.reference(frameID: original.ref.frameID, source: .native)
            try require(reference == original.ref, "Current selection does not match the frozen extraction")
            let saved = await service.retainedScreen(reference, for: .localUser)
            let retained = try XCTUnwrap(saved, "The real service must admit the authored evidence")
            try require(retained.ref == original.ref && retained.frame.timestamp == original.frame.timestamp,
                        "Retained evidence identity changed")
            try Self.validateStructure(retained)
            let observation = retained.observation
            result.append(.init(id: screen.id, imageSHA256: screen.imageSHA256, ref: retained.ref,
                capturedAt: retained.frame.timestamp.timeIntervalSince1970, appBundleID: screen.appBundleID,
                title: screen.title, mainText: observation.mainText, chromeText: observation.chromeText,
                textSHA256: Self.sha256(Data((observation.mainText + "\n" + observation.chromeText).utf8)),
                provenance: observation.provenance))
        }
        return result
    }

    private func bind(_ question: Question, screens: [ScreenExport], snapshots: [String: ScreenEvidenceSnapshot],
                      adapter: DataAdapter, service: ProgressiveRecallService) async throws -> BoundQuestion {
        let constraints = question.constraints
        let filter = FilterCriteria(selectedApps: constraints.appBundleIDs.map(Set.init), selectedSources: [.native],
            hiddenFilter: .showAll, startDate: constraints.startDate.map(Date.init(timeIntervalSince1970:)),
            endDate: constraints.endDate.map(Date.init(timeIntervalSince1970:)))
        let frames = try await adapter.getFrames(from: Date(timeIntervalSince1970: screens.map(\.capturedAt).min()! - 1),
            to: Date(timeIntervalSince1970: screens.map(\.capturedAt).max()! + 1), limit: screens.count + 1, filters: filter)
        let mapping = Dictionary(uniqueKeysWithValues: screens.map { ($0.ref, $0.id) })
        var allowed = Set<String>()
        for frame in frames {
            let ref = try await service.reference(frameID: frame.id, source: frame.source)
            allowed.insert(try XCTUnwrap(mapping[ref], "Adapter returned a frame outside the authored corpus"))
        }
        // Use the actual primary FTS phrase semantics, not a substring approximation.
        for phrase in constraints.requiredPhrases ?? [] {
            let matches = try await matchingIDs(Self.quoted(phrase), constraints: constraints,
                                               screens: screens, adapter: adapter, service: service)
            allowed.formIntersection(matches)
        }
        for term in constraints.excludedTerms ?? [] {
            let matches = try await matchingIDs(Self.quoted(term), constraints: constraints,
                                               screens: screens, adapter: adapter, service: service)
            allowed.subtract(matches)
        }
        let expectedRefs = try question.expectedIDs.map { try XCTUnwrap(snapshots[$0]).ref }
        try require(Set(question.expectedIDs).isSubset(of: allowed), "Frozen oracle is outside \(question.id)'s allowed pool")
        return BoundQuestion(question: question, expectedRefs: expectedRefs, allowedIDs: allowed.sorted())
    }

    private func matchingIDs(_ text: String, constraints: Constraints, screens: [ScreenExport],
                             adapter: DataAdapter, service: ProgressiveRecallService) async throws -> Set<String> {
        let page = try await adapter.search(query: SearchQuery(text: text, filters: constraints.searchFilters,
            limit: screens.count, mode: .all))
        try require(page.nextCursor == nil && page.totalCount == page.results.count, "Authored eligibility page was truncated")
        return Set(try await validate(page.results, screens: screens, service: service).map(\.id))
    }

    private func measure(_ text: String, bound: BoundQuestion, screens: [ScreenExport], adapter: DataAdapter,
                         service: ProgressiveRecallService, generation: String) async throws -> RankingExport {
        var elapsed: [Double] = []
        var baseline: [ScreenEvidenceRef]?
        var orderedIDs: [String] = []
        let allowed = Set(bound.allowedIDs)
        for _ in 0...3 {
            try await checkGeneration(generation, service: service)
            let start = ProcessInfo.processInfo.systemUptime
            let page = try await adapter.search(query: SearchQuery(text: text, filters: bound.question.constraints.searchFilters,
                limit: screens.count, mode: .relevant))
            elapsed.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            try require(page.nextCursor == nil && page.totalCount == page.results.count, "A rank cutoff hid an allowed candidate")
            let validated = try await validate(page.results, screens: screens, service: service)
            let admitted = validated.filter { allowed.contains($0.id) }
            let refs = admitted.map(\.ref)
            if let baseline { try require(refs == baseline, "Repeated primary rankings changed without fixture writes") }
            else { baseline = refs; orderedIDs = admitted.map(\.id) }
            try await checkGeneration(generation, service: service)
        }
        return RankingExport(orderedIDs: orderedIDs, orderedRefs: baseline ?? [], elapsedMs: elapsed)
    }

    private func validate(_ results: [SearchResult], screens: [ScreenExport],
                          service: ProgressiveRecallService) async throws -> [ScreenExport] {
        let mapping = Dictionary(uniqueKeysWithValues: screens.map { ($0.ref, $0) })
        var validated: [ScreenExport] = []
        for result in results {
            // Always validate the entire result, including already-populated references.
            let reference = try await service.reference(searchResult: result)
            let screen = try XCTUnwrap(mapping[reference], "Search returned an unbound source/revision")
            let value = await service.retainedScreen(reference, for: .localUser)
            let snapshot = try XCTUnwrap(value)
            let text = snapshot.observation
            try require(snapshot.ref == screen.ref && snapshot.frame.timestamp.timeIntervalSince1970 == screen.capturedAt
                && Self.sha256(Data((text.mainText + "\n" + text.chromeText).utf8)) == screen.textSHA256,
                "Ranked reference changed source, timestamp or immutable text")
            validated.append(screen)
        }
        try require(Set(validated.map(\.ref)).count == validated.count, "Duplicate exact evidence in a ranking")
        return validated
    }

    private func safetyChecks(_ dataset: Dataset, snapshots: [String: ScreenEvidenceSnapshot], database: DatabaseManager,
                              adapter: DataAdapter, service: ProgressiveRecallService, policy: BenchmarkPolicy) async throws -> SafetyChecks {
        let original = try XCTUnwrap(snapshots[dataset.screens[0].id])
        let page = try await adapter.search(query: SearchQuery(text: "42000", limit: dataset.screens.count, mode: .relevant))
        let hit = try XCTUnwrap(page.results.first { $0.evidenceRef == original.ref })
        let actual = try await service.reference(searchResult: hit)
        try require(actual == original.ref, "Safety controls require a positively resolved real search result")
        let wrongStore = ScreenEvidenceRef(storeID: UUID(), source: .native, observationID: actual.observationID,
            frameID: actual.frameID, extractionRevision: actual.extractionRevision)
        try await requireRefusal(Self.copy(hit, ref: wrongStore), reason: .sourceDisconnected, service: service)
        let crossSource = ScreenEvidenceRef(storeID: actual.storeID, source: .rewind, observationID: actual.observationID,
            frameID: actual.frameID, extractionRevision: actual.extractionRevision)
        try await requireRefusal(Self.copy(hit, ref: crossSource), reason: .sourceDisconnected, service: service)
        await policy.exclude(dataset.screens[0].appBundleID)
        try await requireRefusal(hit, reason: .notPermitted, service: service)
        await policy.clear()
        let restored = try await service.reference(searchResult: hit)
        try require(restored == actual, "Clearing the private test policy must restore the same exact evidence")
        try await database.deleteFrame(id: actual.frameID)
        try await requireRefusal(hit, reason: .extractionUnavailable, service: service)
        let resolution = await service.resolve(.screen(actual), for: .localUser)
        guard case .unavailable(.evidenceDeleted) = resolution else {
            throw BenchmarkFailure.invalid("Deleted exact evidence was not refused by the resolver")
        }
        return SafetyChecks(wrongStoreRefused: true, sameNumericCrossSourceRefused: true,
                            excludedAppRefused: true, deletedRefRefused: true)
    }

    private func requireRefusal(_ hit: SearchResult, reason: EvidenceUnavailableReason, service: ProgressiveRecallService) async throws {
        do {
            _ = try await service.reference(searchResult: hit)
            throw BenchmarkFailure.invalid("An invalid or denied search selection was accepted")
        } catch let failure as EvidenceUnavailableReason {
            try require(failure == reason, "Unexpected exact-selection refusal: \(failure), expected \(reason)")
        }
        let retained = await service.retainedScreen(try XCTUnwrap(hit.evidenceRef), for: .localUser)
        try require(retained == nil, "Denied/deleted evidence leaked retained text")
    }

    private static func copy(_ result: SearchResult, ref: ScreenEvidenceRef) -> SearchResult {
        SearchResult(id: result.id, timestamp: result.timestamp, snippet: result.snippet, matchedText: result.matchedText,
            relevanceScore: result.relevanceScore, metadata: result.metadata, segmentID: result.segmentID,
            videoID: result.videoID, frameIndex: result.frameIndex, videoPath: result.videoPath,
            videoFrameRate: result.videoFrameRate, source: ref.source, evidenceRef: ref)
    }

    private func checkGeneration(_ expected: String, service: ProgressiveRecallService) async throws {
        let current = try await service.sourceGeneration(source: .native)
        try require(current == expected, "The source changed while freezing or ranking authored evidence")
    }

    private static func quoted(_ value: String) throws -> String {
        try require(!value.isEmpty && !value.contains("\"") && !value.contains("\0"), "Unsupported authored phrase")
        return "\"\(value)\""
    }

    private static func visualHyphens(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{2010}", with: "-")
            .replacingOccurrences(of: "\u{2011}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2212}", with: "-")
    }

    private static func sha256(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }

    /// Descend from the fixed temporary directory using directory descriptors, rejecting symlinks.
    /// O_EXCL refuses both existing receipts and final-component symlinks without overwriting them.
    private static func writeExclusive(_ data: Data, path: String) throws {
        let suffix: String
        if path.hasPrefix("/private/tmp/") { suffix = String(path.dropFirst("/private/tmp/".count)) }
        else if path.hasPrefix("/tmp/") { suffix = String(path.dropFirst("/tmp/".count)) }
        else { throw BenchmarkFailure.invalid("Export must be a new file beneath /tmp") }
        let parts = suffix.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        try require(!parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") },
                    "Invalid export path")
        var directory = Darwin.open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw BenchmarkFailure.posix(errno) }
        defer { Darwin.close(directory) }
        for part in parts.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw BenchmarkFailure.posix(errno) }
            Darwin.close(directory)
            directory = next
        }
        let file = openat(directory, parts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw BenchmarkFailure.posix(errno) }
        defer { Darwin.close(file) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw BenchmarkFailure.posix(errno) }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw BenchmarkFailure.posix(errno) }
    }
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw BenchmarkFailure.invalid(message) }
}

private enum BenchmarkFailure: Error, CustomStringConvertible {
    case invalid(String), posix(Int32)
    var description: String {
        switch self {
        case .invalid(let message): return message
        case .posix(let code): return "Private benchmark export failed with POSIX error \(code)"
        }
    }
}

private actor BenchmarkPolicy {
    private var excluded: Set<String> = []
    func configuration() -> CaptureConfig { CaptureConfig(excludedAppBundleIDs: excluded) }
    func exclude(_ bundleID: String) { excluded = [bundleID] }
    func clear() { excluded = [] }
}

private struct Dataset: Decodable {
    let schemaVersion: Int
    let screens: [Screen]
    let questions: [Question]
    let ranking: Ranking
    struct Ranking: Decodable { let warmRepetitions: Int }
}

private struct Screen: Decodable {
    let id: String
    let file: String
    let imageSHA256: String
    let capturedAt: Double
    let appBundleID: String
    let title: String
    let requiredOCR: [String]
}

private struct Question: Decodable {
    let id: String
    let question: String
    let keywordQuery: String
    let constraints: Constraints
    let expectedIDs: [String]
}

private struct Constraints: Codable {
    let source: FrameSource
    let startDate: Double?
    let endDate: Double?
    let appBundleIDs: [String]?
    let requiredPhrases: [String]?
    let excludedTerms: [String]?

    var searchFilters: SearchFilters {
        SearchFilters(startDate: startDate.map(Date.init(timeIntervalSince1970:)),
            endDate: endDate.map(Date.init(timeIntervalSince1970:)), appBundleIDs: appBundleIDs, hiddenFilter: .showAll)
    }
}

private struct BoundQuestion {
    let question: Question
    let expectedRefs: [ScreenEvidenceRef]
    let allowedIDs: [String]
}

private struct BenchmarkExport: Encodable {
    let schemaVersion: Int
    let kind: String
    let datasetSHA256: String
    let screens: [ScreenExport]
    let questions: [QuestionExport]
    let safetyChecks: SafetyChecks
    let timingScope: String
    let ocrConfiguration: String
    let safetyScope: String
    let sqliteReadState: SQLiteReadState
}

private struct SQLiteReadState: Encodable {
    let autocommit: Bool
    let transactionState: Int32
    let statements: [SQLiteStatementState]
}

private struct SQLiteStatementState: Encodable {
    let busy: Bool
    let readOnly: Bool
    let category: String
    /// sqlite3_sql, never expanded SQL/bound values; this database contains only authored fixtures.
    let sql: String
}

private struct ScreenExport: Encodable {
    let id: String
    let imageSHA256: String
    let ref: ScreenEvidenceRef
    let capturedAt: Double
    let appBundleID: String
    let title: String
    let mainText: String
    let chromeText: String
    let textSHA256: String
    let provenance: EvidenceExtractionProvenance
}

private struct QuestionExport: Encodable {
    let id: String
    let question: String
    let keywordQuery: String
    let constraints: Constraints
    let expectedIDs: [String]
    let expectedRefs: [ScreenEvidenceRef]
    let allowedIDs: [String]
    let fullQuestion: RankingExport
    let authoredKeywords: RankingExport
}

private struct RankingExport: Encodable {
    let orderedIDs: [String]
    let orderedRefs: [ScreenEvidenceRef]
    let elapsedMs: [Double]
}

private struct SafetyChecks: Encodable {
    let wrongStoreRefused: Bool
    let sameNumericCrossSourceRefused: Bool
    let excludedAppRefused: Bool
    let deletedRefRefused: Bool
}
