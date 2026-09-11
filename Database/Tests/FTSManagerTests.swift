import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database
@testable import Search

final class FTSManagerTests: XCTestCase {
    private var database: DatabaseManager!
    private var ftsManager: FTSManager!
    private var testRoot: URL!
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    override func setUp() async throws {
        testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("RetraceFTSTests_\(UUID())")
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        let path = testRoot.appendingPathComponent("test.db").path
        database = DatabaseManager(databasePath: path)
        ftsManager = FTSManager(databasePath: path)
        try await database.initialize()
        try await ftsManager.initialize()
    }

    override func tearDown() async throws {
        try await ftsManager.close()
        try await database.close()
        try FileManager.default.removeItem(at: testRoot)
    }

    // Each fixture passes through the actual SQLite capture/index APIs. All links
    // use returned database IDs; app metadata belongs to its own app segment.
    @discardableResult
    private func add(_ text: String, app: String = "com.apple.Safari",
                     title: String? = "GitHub", url: String? = nil,
                     offset: Double = 0) async throws -> FrameID {
        let timestamp = now.addingTimeInterval(offset)
        let video = try await database.insertVideoSegment(VideoSegment(
            id: VideoSegmentID(value: 0), startTime: timestamp, endTime: timestamp,
            frameCount: 1, fileSizeBytes: 1024, relativePath: "chunks/\(UUID())",
            width: 1920, height: 1080))
        try await database.markVideoFinalized(id: video, frameCount: 1, fileSize: 1024)
        let segment = try await database.insertSegment(bundleID: app, startDate: timestamp,
            endDate: timestamp, windowName: title, browserUrl: url, type: 0)
        let frame = FrameID(value: try await database.insertFrame(FrameReference(
            id: FrameID(value: 0), timestamp: timestamp,
            segmentID: AppSegmentID(value: segment), videoID: VideoSegmentID(value: video),
            frameIndexInSegment: 0, metadata: FrameMetadata(appBundleID: app, windowName: title, browserURL: url))))
        _ = try await database.commitFrameOCR(frameID: frame, text: ExtractedText(
            frameID: frame, timestamp: timestamp,
            regions: [TextRegion(frameID: frame, text: text, bounds: CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.1))]),
            frameWidth: 1920, frameHeight: 1080)
        return frame
    }

    private func seed() async throws -> [FrameID] {
        [try await add("Swift programming language documentation for macOS development", offset: -200),
         try await add("Retrace screen recording and search application source code", app: "com.apple.dt.Xcode", title: "Retrace Project", offset: -100),
         try await add("Terminal commands for git commit and push operations", app: "com.apple.Terminal", title: "bash", offset: -10)]
    }

    func testBasicSearch() async throws {
        let ids = try await seed()
        let results = try await ftsManager.search(query: "Swift", limit: 10, offset: 0)
        XCTAssertEqual(results.map(\.frameID), [ids[0]])
        XCTAssertEqual(results.first?.appName, "com.apple.Safari")
        XCTAssertTrue(results.first?.snippet.contains("<mark>Swift</mark>") == true)
    }

    func testSearchMultipleResults() async throws {
        let ids = try await seed()
        let results = try await ftsManager.search(query: "programming OR application", limit: 10, offset: 0)
        XCTAssertEqual(Set(results.map(\.frameID)), Set(ids.prefix(2)))
    }

    func testSearchNoResults() async throws {
        _ = try await seed()
        let results = try await ftsManager.search(query: "quantum", limit: 10, offset: 0)
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchCaseInsensitive() async throws {
        let ids = try await seed()
        for query in ["SWIFT", "swift"] {
            let results = try await ftsManager.search(query: query, limit: 10, offset: 0)
            XCTAssertEqual(results.map(\.frameID), [ids[0]])
        }
    }

    func testSearchSnippet() async throws {
        _ = try await seed()
        let results = try await ftsManager.search(query: "Retrace", limit: 10, offset: 0)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first?.snippet.contains("<mark>Retrace</mark>") == true)
    }

    func testPhraseSearch() async throws {
        let ids = try await seed()
        _ = try await add("screen and audio recording")
        let results = try await ftsManager.search(query: "\"screen recording\"", limit: 10, offset: 0)
        XCTAssertEqual(results.map(\.frameID), [ids[1]])
    }

    func testSearchWithTimeFilter() async throws {
        let ids = try await seed()
        let results = try await ftsManager.search(query: "git OR programming",
            filters: SearchFilters(startDate: now.addingTimeInterval(-50), endDate: now), limit: 10, offset: 0)
        XCTAssertEqual(results.map(\.frameID), [ids[2]])
    }

    func testSearchWithOldTimeFilter() async throws {
        _ = try await seed()
        let results = try await ftsManager.search(query: "Swift",
            filters: SearchFilters(startDate: now.addingTimeInterval(-86_400), endDate: now.addingTimeInterval(-43_200)), limit: 10, offset: 0)
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchWithAppFilter() async throws {
        let ids = try await seed()
        let results = try await ftsManager.search(query: "programming OR code",
            filters: SearchFilters(appBundleIDs: ["Safari"]), limit: 10, offset: 0)
        XCTAssertEqual(results.map(\.frameID), [ids[0]])
    }

    func testSearchWithAppBundleIDFilter() async throws {
        let chrome = try await add("shared searchable content", app: "com.google.Chrome", title: "Browser")
        _ = try await add("shared searchable content", app: "com.apple.Safari", title: "Browser")
        let results = try await ftsManager.search(query: "shared",
            filters: SearchFilters(appBundleIDs: ["com.google.Chrome"]), limit: 10, offset: 0)
        XCTAssertEqual(results.map(\.frameID), [chrome])
    }

    func testSearchWithAppFilterPartialMatch() async throws {
        let ids = try await seed()
        let results = try await ftsManager.search(query: "programming",
            filters: SearchFilters(appBundleIDs: ["Saf"]), limit: 10, offset: 0)
        XCTAssertEqual(results.map(\.frameID), [ids[0]])
    }

    func testSearchWithMultipleAppFilters() async throws {
        let ids = try await seed()
        let results = try await ftsManager.search(query: "programming OR code OR git",
            filters: SearchFilters(appBundleIDs: ["Safari", "Xcode"]), limit: 10, offset: 0)
        XCTAssertEqual(Set(results.map(\.frameID)), Set(ids.prefix(2)))
    }

    func testSearchWithExcludedAppFilter() async throws {
        let ids = try await seed()
        let filters = SearchFilters(excludedAppBundleIDs: ["Terminal"])
        let results = try await ftsManager.search(query: "git OR programming", filters: filters, limit: 10, offset: 0)
        let count = try await ftsManager.getMatchCount(query: "git OR programming", filters: filters)
        XCTAssertEqual(results.map(\.frameID), [ids[0]])
        XCTAssertEqual(count, 1)
    }

    func testExcludedAppDoesNotHideUntitledWindows() async throws {
        let wanted = try await add("visible evidence", title: nil)
        _ = try await add("visible evidence", app: "com.apple.Terminal", title: nil)
        let filters = SearchFilters(excludedAppBundleIDs: ["Terminal"])
        let results = try await ftsManager.search(query: "visible", filters: filters, limit: 10, offset: 0)
        let count = try await ftsManager.getMatchCount(query: "visible", filters: filters)
        XCTAssertEqual(results.map(\.frameID), [wanted])
        XCTAssertEqual(count, 1)
    }

    func testSearchWithWindowNameMetadataFilter() async throws {
        let github = try await add("debugging issue", title: "GitHub issue")
        _ = try await add("debugging issue", title: "Apple Docs")
        let results = try await ftsManager.search(query: "debugging",
            filters: SearchFilters(windowNameFilter: "GitHub"), limit: 10, offset: 0)
        XCTAssertEqual(results.map(\.frameID), [github])
        XCTAssertEqual(results.first?.windowName, "GitHub issue")
    }

    func testSearchWithBrowserUrlMetadataFilter() async throws {
        _ = try await add("debugging issue", url: "https://github.com/retrace")
        let apple = try await add("debugging issue", url: "https://developer.apple.com/documentation")
        let results = try await ftsManager.search(query: "debugging",
            filters: SearchFilters(browserUrlFilter: "developer.apple.com"), limit: 10, offset: 0)
        XCTAssertEqual(results.map(\.frameID), [apple])
    }

    func testGetMatchCount() async throws {
        _ = try await seed()
        let count = try await ftsManager.getMatchCount(query: "programming OR code", filters: .none)
        XCTAssertEqual(count, 2)
    }

    func testGetMatchCountWithFilters() async throws {
        _ = try await seed()
        let count = try await ftsManager.getMatchCount(query: "programming OR code",
            filters: SearchFilters(appBundleIDs: ["Safari"]))
        XCTAssertEqual(count, 1)
    }

    func testSearchPagination() async throws {
        var expected: Set<FrameID> = []
        for index in 0..<5 { expected.insert(try await add("database entry \(index)", offset: Double(index))) }
        var actual: [FrameID] = []
        for (offset, expectedCount) in [(0, 2), (2, 2), (4, 1)] {
            let page = try await ftsManager.search(query: "database", limit: 2, offset: offset)
            XCTAssertEqual(page.count, expectedCount)
            actual += page.map(\.frameID)
        }
        XCTAssertEqual(Set(actual), expected)
        XCTAssertEqual(actual.count, expected.count)
    }

    func testSearchRanking() async throws {
        let strongest = try await add("Python Python Python Python Python programming")
        _ = try await add("Python scripting language with many libraries and tools")
        _ = try await add("Learn several languages including Swift Rust Python Java Kotlin C Ruby Lua")
        let results = try await ftsManager.search(query: "Python", limit: 10, offset: 0)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.first?.frameID, strongest)
        XCTAssertEqual(results.map(\.rank), results.map(\.rank).sorted())
    }

    func testRebuildIndex() async throws {
        let ids = try await seed()
        try await ftsManager.rebuildIndex()
        let results = try await ftsManager.search(query: "Swift", limit: 10, offset: 0)
        XCTAssertEqual(results.map(\.frameID), [ids[0]])
    }

    func testOptimizeIndex() async throws {
        let ids = try await seed()
        try await ftsManager.optimizeIndex()
        let results = try await ftsManager.search(query: "Swift", limit: 10, offset: 0)
        XCTAssertEqual(results.map(\.frameID), [ids[0]])
    }

    func testBooleanAND() async throws {
        let ids = try await seed()
        let results = try await ftsManager.search(query: "Swift programming", limit: 10, offset: 0)
        XCTAssertEqual(results.map(\.frameID), [ids[0]])
    }

    func testBooleanOR() async throws {
        let ids = try await seed()
        let results = try await ftsManager.search(query: "Swift OR Terminal", limit: 10, offset: 0)
        XCTAssertEqual(Set(results.map(\.frameID)), Set([ids[0], ids[2]]))
    }

    func testBooleanNOT() async throws {
        let ids = try await seed()
        let results = try await ftsManager.search(query: "(programming OR git) NOT Terminal", limit: 10, offset: 0)
        XCTAssertEqual(results.map(\.frameID), [ids[0]])
    }

    func testInvalidFTSSyntaxThrowsInsteadOfReportingNoResults() async throws {
        _ = try await seed()
        do {
            _ = try await ftsManager.search(query: "\"unterminated", limit: 10, offset: 0)
            XCTFail("Malformed FTS input must report the SQLite error")
        } catch is DatabaseError { }
        do {
            _ = try await ftsManager.getMatchCount(query: "\"unterminated", filters: .none)
            XCTFail("Count must not hide a query error as zero results")
        } catch is DatabaseError { }
    }

    func testSearchIndexReplacesExistingDocumentForSameFrame() async throws {
        let frameID = try await add("oldcontext")
        let stored = try await database.getFrame(id: frameID)
        let frame = try XCTUnwrap(stored)
        let search = SearchManager(database: database, ftsEngine: ftsManager)
        try await search.initialize(config: .default)
        let replacement = ExtractedText(frameID: frameID, timestamp: frame.timestamp,
            regions: [TextRegion(frameID: frameID, text: "newcontext", bounds: CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.1))])
        _ = try await search.index(text: replacement, segmentId: frame.segmentID.value, frameId: frameID.value)
        let old = try await ftsManager.search(query: "oldcontext", limit: 10, offset: 0)
        let new = try await ftsManager.search(query: "newcontext", limit: 10, offset: 0)
        let stats = try await database.getStatistics()
        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(new.map(\.frameID), [frameID])
        XCTAssertEqual(stats.documentCount, 1)
    }
}
