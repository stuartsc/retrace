import AppKit
import Combine
import SwiftUI
import XCTest
import Shared
import Database
import Storage
import App
import SQLCipher
@testable import Retrace

/// Authored OCR is committed through the real SQLite/FTS writer. The actual
/// search model and native field delegate dispatch to that private database;
/// no window, system pasteboard, production cache or recording is opened.
@MainActor
final class SearchQueryPreservationTests: XCTestCase {
    private let fifteenWords = "Cedar proposal finance review project draft prepared for the team after our planning meeting Tuesday"
    private let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private var database: DatabaseManager!
    private var adapter: DataAdapter!
    private var probe: QueryDispatchProbe!
    private var coordinator: AppCoordinator!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var cacheDirectory: URL!
    private var models: [SearchViewModel] = []
    private var metricTasks: [Task<Void, Never>] = []
    private var submissions: [(query: String, filters: String?)] = []
    private var nextFrame = 0

    override func setUp() async throws {
        defaultsName = "SearchQueryPreservationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(defaultsName, isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let pointer = await database.getConnection()
        adapter = DataAdapter(retraceConnection: SQLiteConnection(db: try XCTUnwrap(pointer)),
            retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: cacheDirectory.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: cacheDirectory.path), database: database)
        try await adapter.initialize()
        probe = QueryDispatchProbe(adapter: adapter)
        // This constructor uses mock transcription and does not initialize any
        // production service. Search and metrics below use only our own SQLite.
        coordinator = AppCoordinator(services: ServiceContainer(inMemory: true))
    }

    override func tearDown() async throws {
        for model in models { model.cancelSearch() }
        models.removeAll()
        await finishMetrics()
        await adapter.shutdown()
        try await database.close()
        defaults.removePersistentDomain(forName: defaultsName)
        try FileManager.default.removeItem(at: cacheDirectory)
    }

    func testTypedQuestionKeepsMeaningfulQuotedConditionAfterWordFifteen() async throws {
        XCTAssertEqual(fifteenWords.split(separator: " ").count, 15)
        let accepted = try await insert("\(fifteenWords) approval not granted")
        _ = try await insert("\(fifteenWords) approval already granted")
        let question = "\(fifteenWords) \"approval not granted\""
        let model = makeModel()
        let field = nativeField(model)
        let textField = NSTextField()
        for character in question {
            textField.stringValue.append(character)
            field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: textField))
        }
        try await submit(model) {
            XCTAssertTrue(field.control(textField, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        }
        try assertResults(model, ids: [accepted])
        let queries = await probe.queries
        let dispatched = try XCTUnwrap(queries.last)
        XCTAssertEqual(dispatched.text, question)
        XCTAssertEqual(model.searchQuery, question)
        XCTAssertEqual(model.committedSearchQuery, question)
        await finishMetrics()
        XCTAssertEqual(submissions.map(\.query), [question])
        let count = try await metricCount(.searches)
        XCTAssertEqual(count, 1, "Explicit Enter remains one existing submitted-search event")
    }

    func testNativePasteKeepsUnicodeNewlinesAndCompleteQuotedSuffix() async throws {
        let accepted = try await insert("\(fifteenWords) café résumé 承認 保留 🧭")
        _ = try await insert("\(fifteenWords) café résumé 承認 完了 🧭")
        let question = "  \(fifteenWords)\n  café\t\"承認 保留 🧭\"  "
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.setString(question, forType: .string))
        let editor = NSTextView()
        XCTAssertTrue(editor.readSelection(from: pasteboard, type: .string))
        XCTAssertEqual(editor.string, question, "The authored paste is read through AppKit, without a system pasteboard")
        let model = makeModel()
        let delegate = nativeField(model)
        let textField = NSTextField()
        textField.stringValue = editor.string
        delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: textField))
        try await submit(model) {
            XCTAssertTrue(delegate.control(textField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        }
        try assertResults(model, ids: [accepted])
        let queries = await probe.queries
        let dispatched = try XCTUnwrap(queries.last)
        XCTAssertEqual(Array(dispatched.text.utf8), Array(question.utf8), "Input representation must survive dispatch byte for byte")
    }

    func testLiteralExclusionAfterWordFifteenStillRejectsMatchingRecord() async throws {
        let accepted = try await insert("\(fifteenWords) approval pending")
        _ = try await insert("\(fifteenWords) approval granted")
        let question = "\(fifteenWords) -\"approval granted\""
        let model = makeModel()
        await model.performSearch(query: question)
        try assertResults(model, ids: [accepted])
        XCTAssertEqual(model.results?.query.text, question)
    }

    func testExclusionChipConversionRetainsPhraseAndDoesNotChangeTypedQuestion() async throws {
        let accepted = try await insert("\(fifteenWords) approval pending")
        _ = try await insert("\(fifteenWords) approval granted")
        let model = makeModel()
        model.searchQuery = fifteenWords
        model.addExcludedSearchTerm("\n  approval\tgranted  ")
        model.addExcludedSearchTerm("APPROVAL GRANTED")
        try await submit(model) { model.submitSearch() }
        try assertResults(model, ids: [accepted])
        XCTAssertEqual(model.searchQuery, fifteenWords, "Explicit exclusion chips stay separate from the editable question")
        XCTAssertEqual(model.excludedSearchTerms, ["approval granted"], "Existing chip whitespace/case deduplication stays intact")
        XCTAssertEqual(model.results?.query.text, "\(fifteenWords) -\"approval granted\"")
        await finishMetrics()
        XCTAssertEqual(submissions.count, 1)
        let filters = try XCTUnwrap(submissions.first?.filters)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(filters.utf8)) as? [String: Any])
        XCTAssertEqual(json["excludedTerms"] as? [String], ["approval granted"])
        let searches = try await metricCount(.searches), filtered = try await metricCount(.filteredSearchQuery)
        XCTAssertEqual(searches, 1)
        XCTAssertEqual(filtered, 1)
    }

    func testLongQuestionKeepsExplicitAppDateAndMetadataRestrictions() async throws {
        let content = "\(fifteenWords) approval not granted"
        let question = "\(fifteenWords) \"approval not granted\""
        let accepted = try await insert(content)
        _ = try await insert(content, bundleID: "com.test.other")
        _ = try await insert(content, title: "Private draft")
        _ = try await insert(content, url: "https://other.example.test")
        _ = try await insert(content, time: capturedAt.addingTimeInterval(500))
        let model = makeModel()
        model.selectedAppFilters = ["com.test.cedar"]
        model.setDateRange(start: capturedAt.addingTimeInterval(-1), end: capturedAt.addingTimeInterval(100))
        model.windowNameTerms = [" Cedar   proposal "]
        model.windowNameExcludedTerms = ["private"]
        model.browserUrlTerms = ["cedar.example.test"]
        model.browserUrlExcludedTerms = ["/cancelled"]
        await model.performSearch(query: question)
        try assertResults(model, ids: [accepted])
        let query = try XCTUnwrap(model.results?.query)
        XCTAssertEqual(query.text, question)
        XCTAssertEqual(query.filters.appBundleIDs, ["com.test.cedar"])
        XCTAssertNil(query.filters.excludedAppBundleIDs)
        XCTAssertEqual(query.filters.effectiveDateRanges.count, 1)
        XCTAssertEqual(query.limit, 50)
        model.appFilterMode = .exclude
        await model.performSearch(query: question)
        let excluded = try XCTUnwrap(model.results)
        XCTAssertEqual(excluded.results.count, 1)
        XCTAssertEqual(excluded.results.first?.metadata.appBundleID, "com.test.other")
        XCTAssertNil(excluded.query.filters.appBundleIDs)
        XCTAssertEqual(excluded.query.filters.excludedAppBundleIDs, ["com.test.cedar"])
    }

    func testRecentEntryPersistenceAndReplayKeepOriginalWhitespaceAndQuotes() async throws {
        let accepted = try await insert("\(fifteenWords) approval not granted café")
        _ = try await insert("\(fifteenWords) approval already granted café")
        let question = "  \(fifteenWords)\n\"approval  not granted\"\tcafé  "
        makeModel().recordRecentSearchEntry(question)
        let data = try XCTUnwrap(defaults.data(forKey: "search.recentEntries.v1"))
        let stored = try JSONDecoder().decode([SearchViewModel.RecentSearchEntry].self, from: data)
        XCTAssertEqual(stored.first?.query, question)
        let reloaded = makeModel()
        let entry = try XCTUnwrap(reloaded.recentSearchEntries.first)
        try await submit(reloaded) { reloaded.submitRecentSearchEntry(entry) }
        try assertResults(reloaded, ids: [accepted])
        XCTAssertEqual(reloaded.searchQuery, question)
        XCTAssertEqual(reloaded.results?.query.text, question)
    }

    func testCacheRestoreAndResubmitKeepTheFullPersistedQuestion() async throws {
        let accepted = try await insert("\(fifteenWords) approval not granted")
        _ = try await insert("\(fifteenWords) approval already granted")
        let question = " \(fifteenWords)\n\"approval not granted\" "
        let actualResults = try await adapter.search(query: SearchQuery(text: question))
        XCTAssertEqual(actualResults.results.map(\.id), [accepted])
        let cacheURL = cacheDirectory.appendingPathComponent("search_results_cache.json")
        let encoded = try JSONEncoder().encode(actualResults)
        try await Task.detached { try encoded.write(to: cacheURL) }.value
        defaults.set(6, forKey: "search.cacheVersion")
        defaults.set(Date().timeIntervalSince1970, forKey: "search.cachedSearchSavedAt")
        defaults.set(question, forKey: "search.cachedSearchQuery")
        let restored = makeModel()
        XCTAssertTrue(restored.restoreCachedSearchResults())
        XCTAssertEqual(restored.searchQuery, question)
        try await submit(restored) { restored.submitSearch() }
        try assertResults(restored, ids: [accepted])
        XCTAssertEqual(restored.results?.query.text, question)
    }

    func testCorrectiveRerunKeepsQuestionRepresentationWithoutAnotherSubmitMetric() async throws {
        let accepted = try await insert("café approval not granted")
        let question = " \ncafé  \"approval not granted\"\t "
        let model = makeModel()
        model.searchQuery = question
        try await submit(model) { model.submitSearch() }
        try await submit(model) { model.rerunSearchImmediately() }
        try assertResults(model, ids: [accepted])
        let queries = await probe.queries
        XCTAssertEqual(queries.map(\.text), [question, question])
        XCTAssertEqual(model.searchQuery, question)
        XCTAssertEqual(model.committedSearchQuery, question)
        await finishMetrics()
        XCTAssertEqual(submissions.count, 1)
        let count = try await metricCount(.searches)
        XCTAssertEqual(count, 1)
    }

    func testContinuationUsesCommittedQuestionWhileAnUnsubmittedDraftIsEdited() async throws {
        let question = "\(fifteenWords) \"approval not granted\""
        var expected = Set<FrameID>()
        for _ in 0..<53 { expected.insert(try await insert("\(fifteenWords) approval not granted")) }
        _ = try await insert("\(fifteenWords) approval already granted")
        let model = makeModel()
        model.searchQuery = question
        await model.performSearch(query: question)
        XCTAssertEqual(model.results?.results.count, 50)
        XCTAssertTrue(model.canLoadMore)
        model.searchQuery = "an unfinished different question"
        await model.loadMore()
        XCTAssertNil(model.error)
        let result = try XCTUnwrap(model.results)
        XCTAssertEqual(Set(result.results.map(\.id)), expected)
        XCTAssertEqual(result.results.count, expected.count, "Continuation must not duplicate a capture")
        XCTAssertEqual(model.searchQuery, "an unfinished different question")
        XCTAssertEqual(model.committedSearchQuery, question)
        let queries = await probe.queries
        XCTAssertEqual(queries.map(\.text), [question, question])
        XCTAssertNotNil(queries.last?.cursor)
    }

    func testContinuationStillRejectsChangedExplicitFilters() async throws {
        for _ in 0..<51 { _ = try await insert("cedar") }
        let model = makeModel()
        model.searchQuery = "cedar"
        await model.performSearch(query: "cedar")
        XCTAssertTrue(model.canLoadMore)
        model.selectedAppFilters = ["com.test.other"]
        await model.loadMore()
        XCTAssertNotNil(model.error, "Changing explicit restrictions still invalidates the original cursor")
        XCTAssertEqual(model.results?.results.count, 50)
        XCTAssertFalse(model.canLoadMore)
    }

    func testFifteenWordBoundaryAndEmptyQueryDoNotInventSearchWork() async throws {
        let accepted = try await insert(fifteenWords)
        let model = makeModel()
        await model.performSearch(query: fifteenWords)
        try assertResults(model, ids: [accepted])
        XCTAssertEqual(model.results?.query.text, fifteenWords)
        await model.performSearch(query: "")
        XCTAssertNil(model.results)
        let queries = await probe.queries
        XCTAssertEqual(queries.count, 1)
        XCTAssertTrue(submissions.isEmpty)
    }

    func testRealFilteredSearchMetricRoundTripsQuotedMultilineQuestionAndFilters() async throws {
        let services = ServiceContainer(inMemory: true)
        let metricsDatabase = await services.database
        try await metricsDatabase.initialize()
        do {
            let metricsCoordinator = AppCoordinator(services: services)
            let question = "  \(fifteenWords)\n\"approval not granted\" café 🧭 \\archive\t "
            let expectedFilters = ["excludedTerms": ["approval granted"], "apps": ["com.test.cedar"]]
            let filtersData = try JSONEncoder().encode(expectedFilters)
            let filters = try XCTUnwrap(String(data: filtersData, encoding: .utf8))
            await DashboardViewModel.recordFilteredSearch(coordinator: metricsCoordinator,
                query: question, filters: filters).value
            let count = try await metricsDatabase.getDailyMetricCount(metricType: .filteredSearchQuery,
                from: Date().addingTimeInterval(-60), to: Date().addingTimeInterval(60))
            XCTAssertEqual(count, 1)

            let pointer = await metricsDatabase.getConnection()
            let connection = SQLiteConnection(db: try XCTUnwrap(pointer))
            let stored = try await Task.detached { () throws -> String in
                let statement = try XCTUnwrap(connection.prepare(sql:
                    "SELECT metadata FROM daily_metrics WHERE metricType='filtered_search_query' ORDER BY id DESC LIMIT 1"))
                defer { connection.finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
                    throw DatabaseError.queryFailed(query: "read authored filtered search receipt", underlying: "No metric row")
                }
                return String(cString: text)
            }.value
            let storedData = Data(stored.utf8)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: storedData),
                "The actual stored metric must remain valid JSON for quoted, multiline and backslash input")
            if let decoded = try? JSONSerialization.jsonObject(with: storedData) as? [String: Any] {
                XCTAssertEqual(decoded["query"] as? String, question)
                XCTAssertEqual(decoded["filters"] as? [String: [String]], expectedFilters)
            }
            for invalidFilters in ["{broken", "[]", "null", "\"not an object\""] {
                await DashboardViewModel.recordFilteredSearch(coordinator: metricsCoordinator,
                    query: question, filters: invalidFilters).value
            }
            let afterRefusals = try await metricsDatabase.getDailyMetricCount(metricType: .filteredSearchQuery,
                from: Date().addingTimeInterval(-60), to: Date().addingTimeInterval(60))
            XCTAssertEqual(afterRefusals, 1,
                "After joining the actual writer, malformed and non-object filters must not create misleading metric rows")
            try await metricsDatabase.close()
        } catch {
            try? await metricsDatabase.close()
            throw error
        }
    }

    private func makeModel() -> SearchViewModel {
        let probe = probe!, database = database!
        let model = SearchViewModel(coordinator: coordinator, defaults: defaults, cacheDirectory: cacheDirectory,
            startBackgroundWork: false, searchDispatch: { query in try await probe.search(query) },
            submissionMetrics: { [weak self] query, filters in
                self?.submissions.append((query, filters))
                let task = Task {
                    do {
                        try await database.recordMetricEvent(metricType: .searches, metadata: query)
                        if let filters {
                            try await database.recordMetricEvent(metricType: .filteredSearchQuery, metadata: filters)
                        }
                    } catch { XCTFail("Isolated metric write failed: \(error)") }
                }
                self?.metricTasks.append(task)
            })
        models.append(model)
        return model
    }

    private func nativeField(_ model: SearchViewModel) -> SpotlightSearchField.Coordinator {
        SpotlightSearchField(text: Binding(get: { model.searchQuery }, set: { model.searchQuery = $0 }),
            onSubmit: { model.submitSearch() }, onEscape: {}).makeCoordinator()
    }

    private func submit(_ model: SearchViewModel, action: () -> Void) async throws {
        let completed = expectation(description: "Actual search dispatch completes")
        let result = model.$results.dropFirst().compactMap { $0 }.prefix(1).sink { _ in completed.fulfill() }
        let failure = model.$error.dropFirst().compactMap { $0 }.prefix(1).sink { _ in completed.fulfill() }
        action()
        await fulfillment(of: [completed], timeout: 5)
        withExtendedLifetime((result, failure)) {}
        XCTAssertNil(model.error)
    }

    private func assertResults(_ model: SearchViewModel, ids: Set<FrameID>, file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try XCTUnwrap(model.results, file: file, line: line)
        XCTAssertEqual(Set(result.results.map(\.id)), ids, file: file, line: line)
        XCTAssertTrue(result.results.allSatisfy { $0.source == .native && $0.evidenceRef != nil },
            "Assertions use real source-qualified indexed evidence", file: file, line: line)
    }

    private func insert(_ text: String, bundleID: String = "com.test.cedar", title: String = "Cedar proposal",
                        url: String = "https://cedar.example.test/proposal", time: Date? = nil) async throws -> FrameID {
        let timestamp = time ?? capturedAt.addingTimeInterval(Double(nextFrame))
        nextFrame += 1
        let metadata = FrameMetadata(appBundleID: bundleID, appName: "Authored", windowName: title, browserURL: url)
        let segment = try await database.insertSegment(bundleID: bundleID, startDate: timestamp, endDate: timestamp,
            windowName: title, browserUrl: url, type: 0)
        let id = FrameID(value: try await database.insertFrame(FrameReference(id: .init(value: 0), timestamp: timestamp,
            segmentID: .init(value: segment), frameIndexInSegment: 0, metadata: metadata)))
        _ = try await database.commitFrameOCR(frameID: id,
            text: ExtractedText(frameID: id, timestamp: timestamp,
                regions: [TextRegion(frameID: id, text: text, bounds: CGRect(x: 10, y: 10, width: 500, height: 100))],
                metadata: metadata), frameWidth: 640, frameHeight: 360)
        return id
    }

    private func finishMetrics() async {
        let pending = metricTasks
        metricTasks.removeAll()
        for task in pending { await task.value }
    }

    private func metricCount(_ type: DailyMetricsQueries.MetricType) async throws -> Int64 {
        try await database.getDailyMetricCount(metricType: type, from: Date().addingTimeInterval(-60), to: Date().addingTimeInterval(60))
    }
}

private actor QueryDispatchProbe {
    let adapter: DataAdapter
    private(set) var queries: [SearchQuery] = []
    init(adapter: DataAdapter) { self.adapter = adapter }
    func search(_ query: SearchQuery) async throws -> SearchResults {
        queries.append(query)
        return try await adapter.search(query: query)
    }
}
