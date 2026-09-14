import Foundation
import XCTest
import Shared
import Database
import Storage
import SQLCipher
@testable import App

/// Phase 0 regression fixtures run the production adapter against real SQLite/FTS5.
/// These are synthetic records with independently specified expected evidence IDs;
/// they establish query correctness, not real-workload capture or Mac UX acceptance.
final class ProgressiveRecallSearchTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let modes: [(SearchMode, SearchSortOrder)] = [
        (.relevant, .newestFirst), (.all, .newestFirst), (.all, .oldestFirst)
    ]

    func testConstrainedEvidenceSurvivesTwoThousandStrongerOutOfScopeHits() async throws {
        for source in [FrameSource.native, .rewind] {
            try await withStore(source: source) { fixture in
                try fixture.insert((1...2_000).map {
                    Row(id: Int64($0), timestamp: start.addingTimeInterval(5_000), text: "contract contract contract",
                        app: "outside", title: "Outside", url: "https://outside.test")
                })
                let expected = (2_001...2_007).map(Int64.init)
                try fixture.insert(expected.map {
                    Row(id: $0, timestamp: start, text: "contract " + String(repeating: "detail ", count: 200),
                        app: "com.microsoft.Word", title: "Agreement", url: "https://example.test/agreement")
                })
                let filters = SearchFilters(startDate: start, endDate: start,
                    appBundleIDs: ["com.microsoft.Word"], hiddenFilter: .showAll,
                    windowNameFilter: "Agreement", browserUrlFilter: "example.test/agreement")
                for (mode, order) in modes {
                    let result = try await collect(fixture.adapter, text: "contract", filters: filters,
                        limit: 3, mode: mode, order: order)
                    let orderedIDs = mode == .all && order == .newestFirst ? expected.reversed().map { $0 } : expected
                    XCTAssertEqual(result.map(\.id.value), orderedIDs, "source=\(source), mode=\(mode), order=\(order)")
                }
            }
        }
    }

    func testSameTitleAndPositionKeepChangedAmountNegationAndStatusObservations() async throws {
        let texts = ["contract amount 100 approved", "contract amount 900 approved",
            "contract amount 900 not approved", "contract amount 900 pending"]
        for source in [FrameSource.native, .rewind] {
            try await withStore(source: source) { fixture in
                try fixture.insert(texts.enumerated().map {
                    Row(id: Int64($0.offset + 1), timestamp: start.addingTimeInterval(Double($0.offset)),
                        text: $0.element, title: "Contract 2026", node: true)
                })
                for (mode, order) in modes {
                    let result = try await collect(fixture.adapter, text: "contract", limit: 2, mode: mode, order: order)
                    XCTAssertEqual(Set(result.map(\.id.value)), Set([1, 2, 3, 4]), "source=\(source), mode=\(mode)")
                    XCTAssertEqual(result.count, 4, "Every retained observation must remain reachable")
                    for (index, text) in texts.enumerated() {
                        let matching = try await fixture.adapter.search(query: SearchQuery(text: "\"\(text)\"",
                            filters: SearchFilters(hiddenFilter: .showAll), mode: mode, sortOrder: order))
                        XCTAssertEqual(matching.results.map(\.id.value), [Int64(index + 1)])
                    }
                }
            }
        }
    }

    func testDateOnlyConstraintsPrecedeChronologicalCandidateLimit() async throws {
        for source in [FrameSource.native, .rewind] {
            try await withStore(source: source) { fixture in
                try fixture.insert((1...400).map {
                    Row(id: Int64($0), timestamp: start.addingTimeInterval(5_000), text: "contract")
                })
                try fixture.insert([Row(id: 201, timestamp: start, text: "contract")], replacing: true)
                for order in SearchSortOrder.allCases {
                    let result = try await collect(fixture.adapter, text: "contract",
                        filters: SearchFilters(startDate: start, endDate: start, hiddenFilter: .showAll),
                        limit: 3, mode: .all, order: order)
                    XCTAssertEqual(result.map(\.id.value), [201], "source=\(source), order=\(order)")
                }
            }
        }
    }

    func testChronologicalOrderUsesCaptureTimeWhenDocumentIDsAreOutOfOrder() async throws {
        for source in [FrameSource.native, .rewind] {
            try await withStore(source: source, rewindCutoff: nil) { fixture in
                try fixture.insert((1...401).map {
                    Row(id: Int64($0), timestamp: start.addingTimeInterval(Double(402 - $0)), text: "contract")
                })
                for order in SearchSortOrder.allCases {
                    let result = try await collect(fixture.adapter, text: "contract", limit: 41, mode: .all, order: order)
                    let expected = order == .newestFirst ? (1...401).map(Int64.init) : (1...401).reversed().map(Int64.init)
                    XCTAssertEqual(result.map(\.id.value), expected, "source=\(source), order=\(order)")
                }
            }
        }
    }

    func testRelevantKeysetsReachTenThousandRowsWithoutRankTieSkipsOrGlobalCaps() async throws {
        let benchmark = ProcessInfo.processInfo.environment["RETRACE_SEARCH_BENCHMARK"] == "1"
        let pageFirstExperiment = ProcessInfo.processInfo.environment["RETRACE_SEARCH_PAGE_FIRST_EXPERIMENT"] == "1"
        let repetitions = benchmark ? min(10, max(1, Int(ProcessInfo.processInfo.environment["RETRACE_SEARCH_BENCHMARK_RUNS"] ?? "3") ?? 3)) : 1
        let readOnlyPath = ProcessInfo.processInfo.environment["RETRACE_SEARCH_BENCHMARK_READONLY_DB"]
        let outputURL = try ProcessInfo.processInfo.environment["RETRACE_SEARCH_BENCHMARK_OUTPUT"].map {
            try SearchBenchmarkConnection.validatedOutputURL(outputPath: $0, readOnlySourcePath: readOnlyPath)
        }
        var profiler: SearchBenchmarkConnection?
        var reports: [[String: Any]] = []
        try await withStore(source: .native, nativeReadConnection: { connection in
            guard benchmark else { return connection }
            let instrumented = SearchBenchmarkConnection(connection)
            profiler = instrumented
            return instrumented
        }) { fixture in
            try fixture.insert((1...10_003).map {
                Row(id: Int64($0), timestamp: start, text: "contract")
            })
            for run in 0..<repetitions {
                profiler?.resetCounters()
                var samples: [Double] = []
                var fullPages: [Double] = []
                var countsCorrect = true
                let result = try await collect(fixture.adapter, text: "contract", limit: 127, mode: .relevant,
                    pageObserved: { page, elapsed in
                        samples.append(elapsed)
                        if page.results.count == 127 { fullPages.append(elapsed) }
                        XCTAssertEqual(page.totalCount, 10_003)
                        countsCorrect = countsCorrect && page.totalCount == 10_003
                    })
                let expected = (1...10_003).map(Int64.init)
                XCTAssertEqual(result.map(\.id.value), expected)
                XCTAssertEqual(samples.count, 79, "The final partial page is part of the complete traversal")
                XCTAssertEqual(fullPages.count, 78)
                guard result.map(\.id.value) == expected, samples.count == 79, fullPages.count == 78,
                      countsCorrect else { throw SearchBenchmarkError.invalidTraversal }
                if let profiler {
                    func percentile(_ values: [Double], _ fraction: Double) -> Double {
                        values.sorted()[max(0, Int(ceil(Double(values.count) * fraction)) - 1)]
                    }
                    let report: [String: Any] = [
                        "run": run + 1, "rows": result.count, "pages": samples.count, "fullPages": fullPages.count,
                        "limit": 127, "source": "native", "mode": "relevant", "hiddenFilter": "showAll",
                        "queryShape": pageFirstExperiment ? "pageBeforeMetadataExperiment" : "production",
                        "fixture": "10003 identical contract documents at Unix timestamp 1700000000, in memory",
                        "percentileDefinition": "nearest rank; all pages including final 97 rows",
                        "firstPageMs": samples[0], "p50Ms": percentile(samples, 0.5), "p95Ms": percentile(samples, 0.95),
                        "maxMs": samples.max()!, "fullPagesP50Ms": percentile(fullPages, 0.5),
                        "fullPagesP95Ms": percentile(fullPages, 0.95), "elapsedMs": samples.reduce(0, +),
                        "pageSamplesMs": samples, "sqliteStatementCounters": profiler.counters
                    ]
                    var logReport = report
                    logReport.removeValue(forKey: "pageSamplesMs")
                    let encoded = try JSONSerialization.data(withJSONObject: logReport, options: [.sortedKeys])
                    reports.append(report)
                    print("RECALL_SEARCH_BENCHMARK " + String(decoding: encoded, as: UTF8.self))
                }
            }
            if let profiler {
                let plans = try profiler.queryPlans()
                let encoded = try JSONSerialization.data(withJSONObject: plans, options: [.sortedKeys])
                print("RECALL_SEARCH_QUERY_PLANS " + String(decoding: encoded, as: UTF8.self))
                let live: [[String: Any]]
                if let path = readOnlyPath {
                    live = try SearchBenchmarkConnection.probeReadOnlyNativeLibrary(path: path)
                } else { live = [] }
                if let outputURL {
                    let artifact: [String: Any] = ["runs": reports, "queryPlans": plans,
                        "sqliteVersion": String(cString: sqlite3_libversion()), "schema": "phase1 synthetic native",
                        "readOnlyLegacyCoreProbes": live]
                    let data = try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: outputURL, options: [.atomic])
                }
            }
        }
    }

    func testBenchmarkReceiptCannotReplaceItsReadOnlySQLiteSourceOrSidecars() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecallReceiptGuard-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("library.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE fixture(id INTEGER)", nil, nil, nil), SQLITE_OK)
        let original = try Data(contentsOf: source)
        let alias = directory.appendingPathComponent("source-alias.sqlite")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        for databasePath in [source.path, source.absoluteString + "?mode=ro"] {
            for unsafeOutput in [source.path, alias.path, source.path + "-wal", source.path + "-shm", source.path + "-journal"] {
                XCTAssertThrowsError(try SearchBenchmarkConnection.validatedOutputURL(
                    outputPath: unsafeOutput, readOnlySourcePath: databasePath))
            }
        }
        let output = directory.appendingPathComponent("receipt.json")
        let validated = try SearchBenchmarkConnection.validatedOutputURL(outputPath: output.path, readOnlySourcePath: source.path)
        try Data("{}".utf8).write(to: validated, options: [.atomic])
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testOffsetIsAppliedAfterConstraintsAndCursorTakesPrecedence() async throws {
        try await withStore(source: .native) { fixture in
            try fixture.insert((1...301).map {
                Row(id: Int64($0), timestamp: start, text: "contract", app: $0 <= 250 ? "outside" : "inside")
            })
            for (mode, order) in modes {
                let filters = SearchFilters(appBundleIDs: ["inside"], hiddenFilter: .showAll)
                let page = try await fixture.adapter.search(query: SearchQuery(text: "contract", filters: filters,
                    limit: 5, offset: 10, mode: mode, sortOrder: order))
                let expected = mode == .all && order == .newestFirst ? [291, 290, 289, 288, 287] : [261, 262, 263, 264, 265]
                XCTAssertEqual(page.results.map(\.id.value), expected.map(Int64.init))
                let cursor = try XCTUnwrap(page.nextCursor)
                let next = try await fixture.adapter.search(query: SearchQuery(text: "contract", filters: filters,
                    limit: 5, offset: 999, cursor: cursor, mode: mode, sortOrder: order))
                let expectedNext = mode == .all && order == .newestFirst ? [286, 285, 284, 283, 282] : [266, 267, 268, 269, 270]
                XCTAssertEqual(next.results.map(\.id.value), expectedNext.map(Int64.init))
            }
        }
    }

    func testMatchingMultipleTagsDoesNotDuplicateASourceObservation() async throws {
        try await withStore(source: .native) { fixture in
            try fixture.insert([Row(id: 1, timestamp: start, text: "contract"),
                Row(id: 2, timestamp: start, text: "contract")])
            try fixture.connection.execute(sql: """
                INSERT INTO tag(id, name) VALUES(991, 'recall-one'), (992, 'recall-two');
                INSERT INTO segment_tag(segmentId, tagId) VALUES(1, 991), (1, 992), (2, 991);
                """)
            for (mode, order) in modes {
                let result = try await collect(fixture.adapter, text: "contract",
                    filters: SearchFilters(selectedTagIds: [991, 992], hiddenFilter: .showAll),
                    limit: 1, mode: mode, order: order)
                XCTAssertEqual(Set(result.map(\.id.value)), Set([1, 2]))
                XCTAssertEqual(result.count, 2)
            }
        }
    }

    func testDuplicateIntegerIDsRemainDistinctAcrossNativeAndRewindPages() async throws {
        try await withStore(source: .rewind) { fixture in
            try fixture.insert([Row(id: 1, timestamp: start, text: "contract"),
                Row(id: 2, timestamp: start, text: "contract")])
            try fixture.insert([Row(id: 1, timestamp: start.addingTimeInterval(100), text: "contract"),
                Row(id: 2, timestamp: start.addingTimeInterval(101), text: "contract")], intoNative: true)
            for (mode, order) in modes {
                let result = try await collect(fixture.adapter, text: "contract", limit: 1, mode: mode, order: order)
                XCTAssertEqual(Set(result.map { "\($0.source.rawValue):\($0.id.value)" }),
                    Set(["native:1", "native:2", "rewind:1", "rewind:2"]))
                XCTAssertEqual(result.count, 4)
            }
        }
    }

    func testQuerySemanticsPreservePhrasesExclusionsUnicodeAndTitleIsolation() async throws {
        for source in [FrameSource.native, .rewind] {
            try await withStore(source: source) { fixture in
                try fixture.insert([
                    Row(id: 1, timestamp: start, text: "café contract approved", title: "O'Brien 🧪"),
                    Row(id: 2, timestamp: start, text: "café contract not approved", title: "O'Brien 🧪"),
                    Row(id: 3, timestamp: start, text: "unrelated", title: "café contract approved")
                ])
                for (mode, order) in modes {
                    let result = try await collect(fixture.adapter, text: "\"café contract\" -not", limit: 2, mode: mode, order: order)
                    XCTAssertEqual(result.map(\.id.value), [1])
                    let empty = try await collect(fixture.adapter, text: "", limit: 2, mode: mode, order: order)
                    XCTAssertTrue(empty.isEmpty)
                }
            }
        }
    }

    func testLegacyOffsetsDoNotClaimVerifiedHighlightGeometry() async throws {
        for source in [FrameSource.native, .rewind] {
            try await withStore(source: source) { fixture in
                try fixture.insert([Row(id: 1, timestamp: start, text: "contract amount 900 not approved",
                    title: "Agreement", node: true)])
                for (mode, order) in modes {
                    let page = try await fixture.adapter.search(query: SearchQuery(text: "contract",
                        filters: SearchFilters(hiddenFilter: .showAll), limit: 1, mode: mode, sortOrder: order))
                    XCTAssertEqual(page.results.map(\.id.value), [1])
                    XCTAssertNil(page.results.first?.highlightNode,
                        "Legacy offsets have no extraction-revision proof and cannot establish an exact box")
                    XCTAssertEqual(page.results.first?.matchedText, "contract")
                    XCTAssertEqual(page.results.first?.snippet, mode == .all ? "contract" : "")
                }
            }
        }
    }

    func testNonpositivePageLimitsReturnAnEmptyExhaustedPage() async throws {
        try await withStore(source: .native) { fixture in
            try fixture.insert([Row(id: 1, timestamp: start, text: "contract")])
            for limit in [0, -1, Int.min] {
                for (mode, order) in modes {
                    let page = try await fixture.adapter.search(query: SearchQuery(text: "contract",
                        limit: limit, mode: mode, sortOrder: order))
                    XCTAssertTrue(page.results.isEmpty)
                    XCTAssertNil(page.nextCursor)
                }
            }
        }
    }

    func testAllConstraintsAndCountsUseTheSameEligibleObservationsInEveryMode() async throws {
        try await withStore(source: .native) { fixture in
            var rows: [Row] = []
            for id in 1...8 {
                let app = id == 3 ? "com.test.browser" : "com.microsoft.Word"
                let title = id == 2 ? "Draft" : "Agreement"
                let url = id == 3 ? "https://outside.test" : "https://example.test"
                rows.append(Row(id: Int64(id), timestamp: start.addingTimeInterval(Double(id)),
                    text: "contract", app: app, title: title, url: url))
            }
            try fixture.insert(rows)
            try fixture.connection.execute(sql: """
                INSERT INTO tag(id,name) VALUES(991,'include-recall'),(992,'exclude-recall');
                INSERT INTO segment_tag(segmentId,tagId) SELECT 4,id FROM tag WHERE name='hidden';
                INSERT INTO segment_tag(segmentId,tagId) VALUES(5,991),(6,992);
                INSERT INTO segment_comment(id,body,author) VALUES(999,'Review recorded evidence','fixture');
                INSERT INTO segment_comment_link(commentId,segmentId) VALUES(999,7);
                """)
            let cases: [(SearchFilters, [Int64])] = [
                (SearchFilters(), [1,2,3,5,6,7,8]),
                (SearchFilters(hiddenFilter: .onlyHidden), [4]),
                (SearchFilters(appBundleIDs: ["com.microsoft.Word"], hiddenFilter: .showAll), [1,2,4,5,6,7,8]),
                (SearchFilters(excludedAppBundleIDs: ["com.microsoft.Word"], hiddenFilter: .showAll), [3]),
                (SearchFilters(selectedTagIds: [991], hiddenFilter: .showAll), [5]),
                (SearchFilters(excludedTagIds: [992], hiddenFilter: .showAll), [1,2,3,4,5,7,8]),
                (SearchFilters(hiddenFilter: .showAll, commentFilter: .commentsOnly), [7]),
                (SearchFilters(hiddenFilter: .showAll, commentFilter: .noComments), [1,2,3,4,5,6,8]),
                (SearchFilters(hiddenFilter: .showAll, windowNameFilter: "Draft"), [2]),
                (SearchFilters(hiddenFilter: .showAll, browserUrlFilter: "outside.test"), [3]),
                (SearchFilters(dateRanges: [
                    DateRangeCriterion(start: start.addingTimeInterval(2), end: start.addingTimeInterval(1)),
                    DateRangeCriterion(start: start.addingTimeInterval(8), end: nil)
                ], hiddenFilter: .showAll), [1,2,8])
            ]
            for (mode, order) in modes {
                for (filters, expected) in cases {
                    let page = try await fixture.adapter.search(query: SearchQuery(text: "contract", filters: filters,
                        limit: 2, mode: mode, sortOrder: order))
                    XCTAssertEqual(page.totalCount, expected.count)
                    let result = try await collect(fixture.adapter, text: "contract", filters: filters,
                        limit: 2, mode: mode, order: order)
                    XCTAssertEqual(Set(result.map(\.id.value)), Set(expected))
                    XCTAssertEqual(result.count, expected.count)
                }
            }
        }
    }

    func testNativeOnlyConstraintsDoNotQueryMissingImportedTables() async throws {
        try await withStore(source: .rewind) { fixture in
            try fixture.insert([Row(id: 1, timestamp: start, text: "contract")])
            for (mode, order) in modes {
                for filters in [SearchFilters(selectedTagIds: [991]), SearchFilters(excludedTagIds: [991]),
                    SearchFilters(hiddenFilter: .onlyHidden), SearchFilters(commentFilter: .commentsOnly)] {
                    let page = try await fixture.adapter.search(query: SearchQuery(text: "contract", filters: filters,
                        limit: 1, mode: mode, sortOrder: order))
                    XCTAssertTrue(page.results.isEmpty)
                    XCTAssertNil(page.nextCursor)
                }
                let noComments = try await fixture.adapter.search(query: SearchQuery(text: "contract",
                    filters: SearchFilters(commentFilter: .noComments), limit: 1, mode: mode, sortOrder: order))
                XCTAssertEqual(noComments.results.map(\.id.value), [1])
                XCTAssertEqual(noComments.results.first?.source, .rewind)
            }
        }
    }

    func testDuplicateDocumentLinksDoNotDuplicateTheSameObservation() async throws {
        try await withStore(source: .native) { fixture in
            try fixture.insert([Row(id: 1, timestamp: start, text: "contract"),
                Row(id: 2, timestamp: start, text: "contract")])
            try fixture.connection.execute(sql: "INSERT INTO doc_segment(docid,segmentId,frameId) VALUES(1,1,1);")
            for (mode, order) in modes {
                let result = try await collect(fixture.adapter, text: "contract", limit: 1, mode: mode, order: order)
                XCTAssertEqual(Set(result.map(\.id.value)), Set([1,2]))
                XCTAssertEqual(result.count, 2)
            }
        }
    }

    func testDifferentMatchingDocumentsForOneFrameRemainOneObservation() async throws {
        try await withStore(source: .native) { fixture in
            try fixture.insert([Row(id: 1, timestamp: start, text: "contract details"),
                                Row(id: 2, timestamp: start, text: "contract")])
            try fixture.connection.execute(sql: """
                INSERT INTO searchRanking(rowid,text,otherText,title)
                    VALUES(999,'contract contract contract contract contract',NULL,NULL);
                INSERT INTO doc_segment(docid,segmentId,frameId) VALUES(999,1,1);
                """)
            for (mode, order) in modes {
                let result = try await collect(fixture.adapter, text: "contract", limit: 1, mode: mode, order: order)
                XCTAssertEqual(Set(result.map(\.id.value)), Set([1,2]))
                XCTAssertEqual(result.count, 2, "Several indexed documents cannot invent extra capture observations")
            }
        }
    }

    func testConcurrentConstraintQueriesKeepTheirOwnCursors() async throws {
        try await withStore(source: .native) { fixture in
            try fixture.insert((1...40).map {
                Row(id: Int64($0), timestamp: start, text: "contract", app: $0 <= 20 ? "first" : "second")
            })
            async let first = collect(fixture.adapter, text: "contract",
                filters: SearchFilters(appBundleIDs: ["first"], hiddenFilter: .showAll), limit: 3, mode: .relevant)
            async let second = collect(fixture.adapter, text: "contract",
                filters: SearchFilters(appBundleIDs: ["second"], hiddenFilter: .showAll), limit: 3, mode: .relevant)
            let (firstResults, secondResults) = try await (first, second)
            XCTAssertEqual(firstResults.map(\.id.value), (1...20).map(Int64.init))
            XCTAssertEqual(secondResults.map(\.id.value), (21...40).map(Int64.init))
        }
    }

    func testSourceQueryFailuresRemainErrorsInsteadOfEmptyExhaustion() async throws {
        for source in [FrameSource.native, .rewind] {
            try await withStore(source: source) { fixture in
                try fixture.insert([Row(id: 1, timestamp: start, text: "contract")])
                try fixture.connection.execute(sql: "DROP TABLE searchRanking;")
                for (mode, order) in modes {
                    do {
                        _ = try await fixture.adapter.search(query: SearchQuery(text: "contract",
                            limit: 1, mode: mode, sortOrder: order))
                        XCTFail("A failed source must not appear to have no matching evidence")
                    } catch {
                        XCTAssertTrue(error is DatabaseConnectionError)
                    }
                }
            }
        }
    }

    func testCancelledSearchDoesNotPublishACompletedPage() async throws {
        try await withStore(source: .native) { fixture in
            try fixture.insert([Row(id: 1, timestamp: start, text: "contract")])
            let search = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await fixture.adapter.search(query: SearchQuery(text: "contract", limit: 1))
            }
            do {
                _ = try await search.value
                XCTFail("A cancelled search must not publish a fresh result page")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
    }

    func testNativeResultsRetainTheExtractionRevisionIndexedAtSearchTime() async throws {
        try await withStore(source: .native) { fixture in
            try fixture.insert([Row(id: 1, timestamp: start, text: "contract amount 400 approved"),
                                Row(id: 2, timestamp: start, text: "contract legacy")])
            let frameID = FrameID(value: 1)
            let original = ExtractedText(frameID: frameID, timestamp: start, regions: [],
                                          fullText: "contract amount 400 approved")
            _ = try await fixture.database.commitFrameOCR(frameID: frameID, text: original,
                                                           frameWidth: 64, frameHeight: 64)
            var selected: [ScreenEvidenceRef] = []
            for (mode, order) in modes {
                let page = try await fixture.adapter.search(query: SearchQuery(text: "contract",
                    filters: SearchFilters(hiddenFilter: .showAll), mode: mode, sortOrder: order))
                let result = try XCTUnwrap(page.results.first(where: { $0.id == frameID }))
                let ref = try XCTUnwrap(result.evidenceRef, "Indexed evidence must retain its selected revision")
                XCTAssertEqual(ref.source, .native)
                XCTAssertEqual(ref.frameID, frameID)
                XCTAssertEqual(ref.extractionRevision, 0)
                selected.append(ref)
                XCTAssertNil(page.results.first(where: { $0.id.value == 2 })?.evidenceRef,
                             "Legacy rows remain explicit until materialized")
            }
            let changed = ExtractedText(frameID: frameID, timestamp: start, regions: [],
                                         fullText: "contract amount 900 not approved")
            _ = try await fixture.database.commitFrameOCR(frameID: frameID, text: changed,
                                                           frameWidth: 64, frameHeight: 64)
            for ref in selected {
                let retained = try await fixture.database.screenEvidence(ref)
                XCTAssertEqual(retained?.text?.fullText, "contract amount 400 approved")
            }
            let updated = try await fixture.adapter.search(query: SearchQuery(text: "900"))
            XCTAssertEqual(updated.results.first?.evidenceRef?.extractionRevision, 1)
            XCTAssertEqual(updated.results.first?.evidenceRef?.observationID, selected.first?.observationID)
        }
    }

    func testIndexedWritesBetweenPagesInvalidateInsteadOfLosingBM25OrChronologicalMatches() async throws {
        for source in [FrameSource.native, .rewind] {
            try await withStore(source: source) { fixture in
                try fixture.insert((1...5).map { Row(id: Int64($0), timestamp: start, text: "contract") })
                for (index, specification) in modes.enumerated() {
                    let (mode, order) = specification
                    let first = try await fixture.adapter.search(query: SearchQuery(text: "contract",
                        limit: 1, mode: mode, sortOrder: order))
                    let cursor = try XCTUnwrap(first.nextCursor)
                    // An unrelated long document changes BM25 corpus statistics for
                    // every matching document, even though it cannot match this query.
                    try fixture.insert([Row(id: Int64(100 + index), timestamp: start,
                                            text: String(repeating: "unrelated ", count: 1000))])
                    await assertDataChanged {
                        _ = try await fixture.adapter.search(query: SearchQuery(text: "contract",
                            limit: 1, cursor: cursor, mode: mode, sortOrder: order))
                    }
                    let refreshed = try await collect(fixture.adapter, text: "contract", limit: 2,
                                                      mode: mode, order: order)
                    XCTAssertEqual(Set(refreshed.map(\.id.value)), Set([1,2,3,4,5]))
                }
            }
        }
    }

    func testMetricsAndProcessingStatusDoNotInvalidateStableSearchPages() async throws {
        try await withStore(source: .native) { fixture in
            try fixture.insert((1...5).map { Row(id: Int64($0), timestamp: start, text: "contract") })
            for (mode, order) in modes {
                let first = try await fixture.adapter.search(query: SearchQuery(text: "contract",
                    limit: 1, mode: mode, sortOrder: order))
                try fixture.connection.execute(sql: """
                    INSERT INTO daily_metrics(metricType,timestamp,metadata) VALUES('search_completed',1700000000000,'{}');
                    UPDATE frame SET processingStatus=2 WHERE id=1;
                    """)
                let next = try await fixture.adapter.search(query: SearchQuery(text: "contract", limit: 1,
                    cursor: try XCTUnwrap(first.nextCursor), mode: mode, sortOrder: order))
                XCTAssertEqual(next.results.count, 1)
                XCTAssertNotEqual(next.results.first?.id, first.results.first?.id)
            }
        }
    }

    func testQueryAndMetadataChangesInvalidateCursorReuse() async throws {
        try await withStore(source: .native) { fixture in
            try fixture.insert((1...5).map { Row(id: Int64($0), timestamp: start, text: "contract approval") })
            let first = try await fixture.adapter.search(query: SearchQuery(text: "contract", limit: 1))
            let cursor = try XCTUnwrap(first.nextCursor)
            await assertDataChanged {
                _ = try await fixture.adapter.search(query: SearchQuery(text: "approval", limit: 1, cursor: cursor))
            }
            try fixture.connection.execute(sql: "UPDATE segment SET windowName='changed context' WHERE id=3")
            await assertDataChanged {
                _ = try await fixture.adapter.search(query: SearchQuery(text: "contract", limit: 1, cursor: cursor))
            }
        }
    }

    func testSourceSwitchPreservesStampsAndDisconnectCannotRestartAnotherSource() async throws {
        try await withStore(source: .rewind) { fixture in
            try fixture.insert([Row(id: 1, timestamp: start, text: "contract"),
                                Row(id: 2, timestamp: start, text: "contract")])
            try fixture.insert([Row(id: 1, timestamp: start, text: "contract")], intoNative: true)
            let first = try await fixture.adapter.search(query: SearchQuery(text: "contract", limit: 1, mode: .relevant))
            XCTAssertEqual(first.results.first?.source, .native)
            let cursor = try XCTUnwrap(first.nextCursor)
            try fixture.insert([Row(id: 2, timestamp: start, text: "unrelated")], intoNative: true)
            await assertDataChanged {
                _ = try await fixture.adapter.search(query: SearchQuery(text: "contract", limit: 1,
                                                                        cursor: cursor, mode: .relevant))
            }
            let refreshed = try await fixture.adapter.search(query: SearchQuery(text: "contract", limit: 1, mode: .relevant))
            await fixture.adapter.disconnectRewind()
            await assertDataChanged {
                _ = try await fixture.adapter.search(query: SearchQuery(text: "contract", limit: 1,
                    cursor: try XCTUnwrap(refreshed.nextCursor), mode: .relevant))
            }
        }
    }

    func testLegacyUnstampedCursorRequiresRefresh() async throws {
        try await withStore(source: .native) { fixture in
            try fixture.insert((1...3).map { Row(id: Int64($0), timestamp: start, text: "contract") })
            let legacy = SearchPageCursor(native: SearchSourceCursor(timestamp: start, frameID: 2))
            await assertDataChanged {
                _ = try await fixture.adapter.search(query: SearchQuery(text: "contract", cursor: legacy))
            }
        }
    }

    func testSourceReconfigurationInvalidatesEvenWhenItsSQLiteVersionIsUnchanged() async throws {
        try await withStore(source: .rewind) { fixture in
            try fixture.insert((1...3).map { Row(id: Int64($0), timestamp: start, text: "contract") })
            let first = try await fixture.adapter.search(query: SearchQuery(text: "contract", limit: 1,
                                                                            mode: .all, sortOrder: .oldestFirst))
            await fixture.adapter.configureRewind(connection: fixture.connection, config: fixture.config,
                imageExtractor: HEVCStorageExtractor(storageRoot: fixture.config.storageRoot), cutoffDate: .distantFuture)
            await assertDataChanged {
                _ = try await fixture.adapter.search(query: SearchQuery(text: "contract", limit: 1,
                    cursor: try XCTUnwrap(first.nextCursor), mode: .all, sortOrder: .oldestFirst))
            }
        }
    }

    func testWriteCommittedAsTheReadFinishesCannotPublishThatStalePage() async throws {
        var interleaved: FinalizationWriteConnection?
        try await withStore(source: .native, nativeReadConnection: { connection in
            let wrapper = FinalizationWriteConnection(connection)
            interleaved = wrapper
            return wrapper
        }) { fixture in
            try fixture.insert((1...3).map { Row(id: Int64($0), timestamp: start, text: "contract") })
            await assertDataChanged {
                _ = try await fixture.adapter.search(query: SearchQuery(text: "contract", limit: 1))
            }
            XCTAssertTrue(try XCTUnwrap(interleaved).didMutate)
            XCTAssertNil(interleaved?.writeError)
            let refreshed = try await collect(fixture.adapter, text: "contract", limit: 2, mode: .relevant)
            XCTAssertEqual(Set(refreshed.map(\.id.value)), Set([1,2,3]))
        }
    }

    private func assertDataChanged(file: StaticString = #filePath, line: UInt = #line,
                                    operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("A changed query/index/source must require refresh, not publish a stale page", file: file, line: line)
        } catch SearchPaginationError.dataChanged {
        } catch {
            XCTFail("Unexpected pagination error: \(type(of: error))", file: file, line: line)
        }
    }

    private func collect(_ adapter: DataAdapter, text: String,
        filters: SearchFilters = SearchFilters(hiddenFilter: .showAll), limit: Int,
        mode: SearchMode, order: SearchSortOrder = .newestFirst,
        pageObserved: ((SearchResults, Double) -> Void)? = nil,
        file: StaticString = #filePath, line: UInt = #line) async throws -> [SearchResult] {
        var cursor: SearchPageCursor?
        var results: [SearchResult] = []
        var previousCursors: [SearchPageCursor] = []
        for _ in 0..<150 {
            let started = DispatchTime.now().uptimeNanoseconds
            let page = try await adapter.search(query: SearchQuery(text: text, filters: filters,
                limit: limit, cursor: cursor, mode: mode, sortOrder: order))
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            pageObserved?(page, elapsed)
            XCTAssertLessThanOrEqual(page.results.count, limit, "A page must respect the requested limit", file: file, line: line)
            results.append(contentsOf: page.results)
            guard let next = page.nextCursor else { return results }
            guard !previousCursors.contains(next) else {
                XCTFail("A source cursor repeated instead of advancing or exhausting", file: file, line: line)
                throw SearchBenchmarkError.invalidTraversal
            }
            previousCursors.append(next)
            cursor = next
        }
        XCTFail("Search did not exhaust within the bounded fixture", file: file, line: line)
        throw SearchBenchmarkError.invalidTraversal
    }

    private struct Row {
        let id: Int64
        let timestamp: Date
        let text: String
        var app: String = "com.test.recall"
        var title: String? = nil
        var url: String? = nil
        var node: Bool = false
    }

    private final class Fixture {
        let database: DatabaseManager
        let adapter: DataAdapter
        let connection: SQLiteConnection
        let nativeConnection: SQLiteConnection
        let config: DatabaseConfig
        let nativeConfig: DatabaseConfig

        init(database: DatabaseManager, adapter: DataAdapter, connection: SQLiteConnection, nativeConnection: SQLiteConnection,
            config: DatabaseConfig, nativeConfig: DatabaseConfig) {
            self.database = database
            self.adapter = adapter
            self.connection = connection
            self.nativeConnection = nativeConnection
            self.config = config
            self.nativeConfig = nativeConfig
        }

        func insert(_ rows: [Row], replacing: Bool = false, intoNative: Bool = false) throws {
            let target = intoNative ? nativeConnection : connection
            let config = intoNative ? nativeConfig : config
            try target.beginTransaction()
            do {
                for row in rows {
                    if replacing {
                        try execute(target, "UPDATE frame SET createdAt = ? WHERE id = ?", [config.formatDate(row.timestamp), row.id])
                        continue
                    }
                    try execute(target, "INSERT INTO segment(id,bundleID,startDate,endDate,windowName,browserUrl,type) VALUES(?,?,?,?,?,?,0)",
                        [row.id, row.app, config.formatDate(row.timestamp), config.formatDate(row.timestamp), row.title, row.url])
                    try execute(target, "INSERT INTO frame(id,createdAt,imageFileName,segmentId,videoFrameIndex) VALUES(?,?,'fixture',?,0)",
                        [row.id, config.formatDate(row.timestamp), row.id])
                    try execute(target, "INSERT INTO searchRanking(rowid,text,otherText,title) VALUES(?,?,NULL,?)", [row.id, row.text, row.title])
                    try execute(target, "INSERT INTO doc_segment(docid,segmentId,frameId) VALUES(?,?,?)", [row.id, row.id, row.id])
                    if row.node {
                        try execute(target, "INSERT INTO node(id,frameId,nodeOrder,textOffset,textLength,leftX,topY,width,height) VALUES(?,?,0,0,?,0.1,0.2,0.6,0.1)",
                            [row.id, row.id, Int64(row.text.count)])
                    }
                }
                try target.commit()
            } catch {
                try? target.rollback()
                throw error
            }
        }

        private func execute(_ target: SQLiteConnection, _ sql: String, _ values: [Any?]) throws {
            let statement = try XCTUnwrap(target.prepare(sql: sql))
            defer { target.finalize(statement) }
            for (index, value) in values.enumerated() {
                let position = Int32(index + 1)
                if let text = value as? String {
                    sqlite3_bind_text(statement, position, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                } else if let number = value as? Int64 {
                    sqlite3_bind_int64(statement, position, number)
                } else {
                    sqlite3_bind_null(statement, position)
                }
            }
            let status = sqlite3_step(statement)
            guard status == SQLITE_DONE else {
                throw DatabaseConnectionError.executionFailed(sql: sql,
                    error: String(cString: sqlite3_errmsg(target.getConnection())))
            }
        }
    }

    private func withStore(source: FrameSource, rewindCutoff: Date? = Date(timeIntervalSince1970: 1_760_000_000),
        nativeReadConnection: ((SQLiteConnection) -> DatabaseConnection)? = nil,
        body: (Fixture) async throws -> Void) async throws {
        let database = DatabaseManager()
        try await database.initialize()
        let nativePointer = await database.getConnection()
        let native = SQLiteConnection(db: try XCTUnwrap(nativePointer))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecallSearch-\(UUID())").path
        let nativeConfig = DatabaseConfig(dateFormatter: nil, storageRoot: root, source: .native, cutoffDate: nil)
        let pageFirstExperiment = ProcessInfo.processInfo.environment["RETRACE_SEARCH_PAGE_FIRST_EXPERIMENT"] == "1"
        let nativeReader = nativeReadConnection?(native) ?? native
        let adapter = DataAdapter(retraceConnection: pageFirstExperiment ? PageFirstSearchConnection(nativeReader) : nativeReader,
            retraceConfig: nativeConfig,
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root), database: database)
        var rewindPointer: OpaquePointer?
        var selected = native
        var config = nativeConfig
        if source == .rewind {
            XCTAssertEqual(sqlite3_open(":memory:", &rewindPointer), SQLITE_OK)
            let rewind = SQLiteConnection(db: try XCTUnwrap(rewindPointer))
            // Imported shape intentionally omits native redaction, tag and comment tables.
            try rewind.execute(sql: """
                CREATE TABLE segment(id INTEGER PRIMARY KEY,bundleID TEXT,startDate TEXT,endDate TEXT,windowName TEXT,browserUrl TEXT,type INTEGER);
                CREATE TABLE frame(id INTEGER PRIMARY KEY,createdAt TEXT,imageFileName TEXT,segmentId INTEGER,videoId INTEGER,videoFrameIndex INTEGER);
                CREATE TABLE video(id INTEGER PRIMARY KEY,path TEXT,frameRate REAL);
                CREATE TABLE node(id INTEGER PRIMARY KEY,frameId INTEGER,nodeOrder INTEGER,textOffset INTEGER,textLength INTEGER,leftX REAL,topY REAL,width REAL,height REAL);
                CREATE VIRTUAL TABLE searchRanking USING fts5(text,otherText,title,tokenize=porter);
                CREATE TABLE doc_segment(docid INTEGER,segmentId INTEGER,frameId INTEGER);
                CREATE INDEX recall_doc_frame ON doc_segment(docid,frameId);
                CREATE INDEX recall_node_frame ON node(frameId);
                """)
            config = DatabaseConfig(dateFormatter: DatabaseConfig.rewind.dateFormatter, storageRoot: root,
                source: .rewind, cutoffDate: rewindCutoff)
            await adapter.configureRewind(connection: pageFirstExperiment ? PageFirstSearchConnection(rewind) : rewind, config: config,
                imageExtractor: HEVCStorageExtractor(storageRoot: root), cutoffDate: rewindCutoff ?? .distantFuture)
            selected = rewind
        }
        try await adapter.initialize()
        do {
            try await body(Fixture(database: database, adapter: adapter, connection: selected, nativeConnection: native,
                config: config, nativeConfig: nativeConfig))
        } catch {
            await adapter.shutdown()
            try await database.close()
            if let rewindPointer { sqlite3_close_v2(rewindPointer) }
            throw error
        }
        await adapter.shutdown()
        try await database.close()
        if let rewindPointer { sqlite3_close_v2(rewindPointer) }
    }
}

/// An opt-in SQL experiment, never part of production routing. It preserves the
/// adapter's constraints and binding order and hydrates only its final ID page.
/// Run the existing independent result oracles with the flag to compare semantics.
private final class PageFirstSearchConnection: DatabaseConnection, @unchecked Sendable {
    private let backing: DatabaseConnection
    init(_ backing: DatabaseConnection) { self.backing = backing }
    func getConnection() -> OpaquePointer? { backing.getConnection() }
    func prepare(sql: String) throws -> OpaquePointer? {
        guard sql.hasPrefix("WITH matched_documents AS MATERIALIZED") else { return try backing.prepare(sql: sql) }
        guard let projection = sql.range(of: "\nSELECT DISTINCT\n"),
              let from = sql.range(of: "\nFROM matched_frames\n", range: projection.upperBound..<sql.endIndex),
              let condition = sql.range(of: "\nWHERE ", options: .backwards),
              let order = sql.range(of: "\nORDER BY ", options: .backwards),
              let limit = sql.range(of: "\nLIMIT ", options: .backwards),
              from.upperBound < condition.lowerBound, condition.upperBound < order.lowerBound,
              order.upperBound < limit.lowerBound else { throw DataAdapterError.parseFailed }
        let predicate = sql[condition.upperBound..<order.lowerBound]
            .replacingOccurrences(of: "f.id", with: "matched_frames.frame_id")
        let pagination = String(sql[limit.lowerBound...])
        let pageCTE = """
            , page_frames AS MATERIALIZED (
                SELECT frame_id, result_rank FROM matched_frames
                WHERE \(predicate)
                ORDER BY result_rank ASC, frame_id ASC
                \(pagination)
            )
            """
        let hydrated = sql[from.lowerBound..<condition.lowerBound]
            .replacingOccurrences(of: "FROM matched_frames", with: "FROM page_frames AS matched_frames")
        let rewritten = String(sql[..<projection.lowerBound]) + pageCTE
            + String(sql[projection.lowerBound..<from.lowerBound]) + hydrated
            + String(sql[order.lowerBound..<limit.lowerBound])
        return try backing.prepare(sql: rewritten)
    }
    func execute(sql: String) throws -> Int { try backing.execute(sql: sql) }
    func beginTransaction() throws { try backing.beginTransaction() }
    func commit() throws { try backing.commit() }
    func rollback() throws { try backing.rollback() }
    func finalize(_ statement: OpaquePointer?) { backing.finalize(statement) }
}

private enum SearchBenchmarkError: Error { case invalidTraversal, unsafeOutputLocation }

/// Opt-in benchmark instrumentation. Reports contain numeric work counters and
/// query-plan shapes; no captured text, titles or URLs are emitted.
private final class SearchBenchmarkConnection: DatabaseConnection, @unchecked Sendable {
    private let backing: SQLiteConnection
    private let lock = NSLock()
    private var totals: [String: [String: Int64]] = [:]
    private var planSQL: [String: String] = [:]
    init(_ backing: SQLiteConnection) { self.backing = backing }
    var counters: [String: [String: Int64]] { lock.withLock { totals } }
    func resetCounters() { lock.withLock { totals.removeAll() } }
    func getConnection() -> OpaquePointer? { backing.getConnection() }
    func prepare(sql: String) throws -> OpaquePointer? { try backing.prepare(sql: sql) }
    func execute(sql: String) throws -> Int { try backing.execute(sql: sql) }
    func beginTransaction() throws { try backing.beginTransaction() }
    func commit() throws { try backing.commit() }
    func rollback() throws { try backing.rollback() }
    func finalize(_ statement: OpaquePointer?) {
        defer { backing.finalize(statement) }
        guard let statement, let sqlPointer = sqlite3_sql(statement) else { return }
        let sql = String(cString: sqlPointer)
        let kind: String
        if sql.contains("WITH matched_documents") { kind = sql.contains("OFFSET ?") ? "rankFirstPage" : "rankFollowingPage" }
        else if sql.contains("SELECT COUNT(DISTINCT f.id)") { kind = "eligibleCount" }
        else { return }
        let values: [String: Int64] = [
            "statements": 1,
            "vmSteps": Int64(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0)),
            "fullScanSteps": Int64(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0)),
            "sorts": Int64(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_SORT, 0)),
            "automaticIndexRows": Int64(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_AUTOINDEX, 0))
        ]
        lock.withLock {
            for (key, value) in values { totals[kind, default: [:]][key, default: 0] += value }
            if planSQL[kind] == nil, let expanded = sqlite3_expanded_sql(statement) {
                planSQL[kind] = String(cString: expanded)
                sqlite3_free(expanded)
            }
        }
    }
    func queryPlans() throws -> [String: [String]] {
        let statements = lock.withLock { planSQL }
        var plans: [String: [String]] = [:]
        for (kind, sql) in statements {
            let statement = try XCTUnwrap(backing.prepare(sql: "EXPLAIN QUERY PLAN " + sql))
            defer { backing.finalize(statement) }
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                if let value = sqlite3_column_text(statement, 3) { plans[kind, default: []].append(String(cString: value)) }
                status = sqlite3_step(statement)
            }
            XCTAssertEqual(status, SQLITE_DONE)
        }
        return plans
    }

    static func validatedOutputURL(outputPath: String, readOnlySourcePath: String?) throws -> URL {
        guard !outputPath.isEmpty, !outputPath.contains("\0") else { throw SearchBenchmarkError.unsafeOutputLocation }
        let output = URL(fileURLWithPath: outputPath).standardizedFileURL.resolvingSymlinksInPath()
        guard let readOnlySourcePath else { return output }
        // Ask SQLite for the opened filename so file: URIs, escaping and aliases
        // use the same identity as the measured read-only connection.
        let source = try SQLiteConnection(readOnlyDatabasePath: readOnlySourcePath)
        guard let filename = sqlite3_db_filename(source.getConnection(), "main") else {
            throw SearchBenchmarkError.unsafeOutputLocation
        }
        let openedPath = String(cString: filename)
        let resolvedPath = URL(fileURLWithPath: openedPath).standardizedFileURL.resolvingSymlinksInPath().path
        for databasePath in Set([openedPath, resolvedPath]) {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let protected = URL(fileURLWithPath: databasePath + suffix).standardizedFileURL.resolvingSymlinksInPath()
                guard output != protected else { throw SearchBenchmarkError.unsafeOutputLocation }
            }
        }
        return output
    }

    /// The installed library may predate V21. Measure the same legacy FTS/frame
    /// work without migrating it or pretending missing evidence joins were tested.
    /// The opt-in path is supplied by the caller; no captured strings are returned.
    static func probeReadOnlyNativeLibrary(path: String) throws -> [[String: Any]] {
        let connection = try SQLiteConnection(readOnlyDatabasePath: path)
        try connection.execute(sql: "PRAGMA query_only=ON")
        let db = try XCTUnwrap(connection.getConnection())
        XCTAssertEqual(sqlite3_db_readonly(db, "main"), 1)
        let cutoff = Int64((Date().timeIntervalSince1970 - 7 * 86_400) * 1_000)
        let joins = """
            FROM searchRanking JOIN doc_segment ds ON ds.docid=searchRanking.rowid
            JOIN frame f ON f.id=ds.frameId JOIN segment s ON s.id=f.segmentId
            """
        var reports: [[String: Any]] = []
        let queries = [
            (label: "commonPrefix", match: "{text otherText}: (\"contract\"*)"),
            (label: "exactAuthoredPhrase", match: "{text otherText}: (\"contract amount\")")
        ]
        for query in queries {
            for recent in [false, true] {
                let conditions = "searchRanking MATCH ?" + (recent ? " AND f.createdAt>=\(cutoff)" : "")
                let count = "SELECT COUNT(DISTINCT f.id) \(joins) WHERE \(conditions)"
                let rankCTE = """
                    WITH matched_documents AS MATERIALIZED (
                      SELECT f.id AS frame_id,bm25(searchRanking) AS document_rank \(joins) WHERE \(conditions)
                    ), matched_frames AS (SELECT frame_id,MIN(document_rank) AS result_rank FROM matched_documents GROUP BY frame_id)
                    """
                let hydration = """
                    SELECT DISTINCT f.id,f.createdAt,f.segmentId,f.videoId,f.videoFrameIndex,v.path,v.frameRate,
                      f.redactionReason,s.bundleID,s.windowName,s.browserUrl,matched_frames.result_rank
                    FROM matched_frames JOIN frame f ON f.id=matched_frames.frame_id JOIN segment s ON s.id=f.segmentId
                    LEFT JOIN video v ON v.id=f.videoId ORDER BY matched_frames.result_rank,f.id
                    """
                let ranked = rankCTE + "\n" + hydration + " LIMIT 128"
                let pageCTE = """
                    , page_frames AS MATERIALIZED (
                      SELECT frame_id,result_rank FROM matched_frames ORDER BY result_rank,frame_id LIMIT 128
                    )
                    """
                let pageFirstRanked = rankCTE + pageCTE + "\n"
                    + hydration.replacingOccurrences(of: "FROM matched_frames", with: "FROM page_frames AS matched_frames")
                for run in 1...3 {
                    var rankReference: (rows: [[UInt64]], version: Int64)?
                    for (kind, sql) in [("eligibleCount", count), ("rankedFirstPage", ranked), ("rankedPageBeforeMetadata", pageFirstRanked)] {
                        let before = try dataVersion(connection)
                        let statement = try XCTUnwrap(connection.prepare(sql: sql))
                        sqlite3_bind_text(statement, 1, query.match, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        var ignored: Int32 = 0, ignoredHighWater: Int32 = 0
                        sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_HIT, &ignored, &ignoredHighWater, 1)
                        sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_MISS, &ignored, &ignoredHighWater, 1)
                        let began = DispatchTime.now().uptimeNanoseconds
                        var deadline = began + 3_000_000_000
                        var status = SQLITE_OK
                        var rows = 0
                        var eligible: Int64?
                        var ids: Set<Int64> = []
                        var rankedRows: [[UInt64]] = []
                        var duplicateIDs = false
                        withUnsafeMutablePointer(to: &deadline) { deadlinePointer in
                            // Synchronous progress cancellation cannot leak a delayed
                            // interrupt into the following query. Disk I/O can still
                            // exceed the budget before SQLite next checks progress.
                            sqlite3_progress_handler(db, 10_000, { context in
                                guard let context else { return 1 }
                                return DispatchTime.now().uptimeNanoseconds >= context.load(as: UInt64.self) ? 1 : 0
                            }, deadlinePointer)
                            defer { sqlite3_progress_handler(db, 0, nil, nil) }
                            status = sqlite3_step(statement)
                            while status == SQLITE_ROW {
                                rows += 1
                                if kind == "eligibleCount" { eligible = sqlite3_column_int64(statement, 0) }
                                else {
                                    let id = sqlite3_column_int64(statement, 0)
                                    if !ids.insert(id).inserted { duplicateIDs = true }
                                    rankedRows.append([UInt64(bitPattern: id), sqlite3_column_double(statement, 11).bitPattern])
                                }
                                status = sqlite3_step(statement)
                            }
                        }
                        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
                        var hits: Int32 = 0, misses: Int32 = 0, highWater: Int32 = 0
                        sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_HIT, &hits, &highWater, 0)
                        sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_MISS, &misses, &highWater, 0)
                        let vmSteps = sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0)
                        let sorts = sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_SORT, 0)
                        // Release the read snapshot before checking for concurrent writes.
                        connection.finalize(statement)
                        var moved: Int32 = 0
                        let moveStatus = sqlite3_file_control(db, "main", SQLITE_FCNTL_HAS_MOVED, &moved)
                        let after = try dataVersion(connection)
                        let sourceChanged = before != after || moveStatus != SQLITE_OK || moved != 0
                        var report: [String: Any] = ["kind": kind, "run": run, "scope": recent ? "last7Days" : "allDates",
                            "queryKind": query.label,
                            "elapsedMs": elapsed, "budgetMs": 3_000, "sqliteStatus": status, "completed": status == SQLITE_DONE,
                            "sourceChanged": sourceChanged, "rows": rows, "duplicateFrameIDs": duplicateIDs,
                            "cacheHits": hits, "cacheMisses": misses,
                            "vmSteps": vmSteps, "sorts": sorts,
                            "candidateAdapterMeasured": false, "recordedTextEmitted": false]
                        if recent { report["startDateMs"] = cutoff }
                        if let eligible { report["eligibleFrames"] = eligible }
                        if kind == "rankedFirstPage", !sourceChanged, status == SQLITE_DONE {
                            rankReference = (rankedRows, after)
                        } else if kind == "rankedPageBeforeMetadata" {
                            let comparable = rankReference?.version == before && !sourceChanged && status == SQLITE_DONE
                            report["sameSourceComparisonAvailable"] = comparable
                            if comparable, let reference = rankReference {
                                let matches = reference.rows == rankedRows
                                report["sameOrderedIDsAndRankBits"] = matches
                                XCTAssertTrue(matches, "Page-first experiment changed the same-snapshot ranked page")
                            }
                        }
                        reports.append(report)
                    }
                }
            }
        }
        return reports
    }

    private static func dataVersion(_ connection: SQLiteConnection) throws -> Int64 {
        let statement = try XCTUnwrap(connection.prepare(sql: "PRAGMA data_version"))
        defer { connection.finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw DataAdapterError.parseFailed }
        return sqlite3_column_int64(statement, 0)
    }
}

/// Deterministically interleaves a real SQLite write after the result read releases
/// its statements. No query results or database behavior are mocked.
private final class FinalizationWriteConnection: DatabaseConnection, @unchecked Sendable {
    private let backing: SQLiteConnection
    private let lock = NSLock()
    private var mutated = false
    private var failure: Error?
    init(_ backing: SQLiteConnection) { self.backing = backing }
    var didMutate: Bool { lock.withLock { mutated } }
    var writeError: Error? { lock.withLock { failure } }
    func getConnection() -> OpaquePointer? { backing.getConnection() }
    func prepare(sql: String) throws -> OpaquePointer? { try backing.prepare(sql: sql) }
    func execute(sql: String) throws -> Int { try backing.execute(sql: sql) }
    func beginTransaction() throws { try backing.beginTransaction() }
    func commit() throws { try backing.commit() }
    func rollback() throws { try backing.rollback() }
    func finalize(_ statement: OpaquePointer?) {
        let isResult = statement.flatMap(sqlite3_sql).map { String(cString: $0).contains("SELECT DISTINCT") } ?? false
        backing.finalize(statement)
        let shouldMutate = lock.withLock { () -> Bool in
            guard isResult, !mutated else { return false }
            mutated = true
            return true
        }
        if shouldMutate {
            do { try backing.execute(sql: "UPDATE segment SET windowName='changed during read' WHERE id=2") }
            catch { lock.withLock { failure = error } }
        }
    }
}
