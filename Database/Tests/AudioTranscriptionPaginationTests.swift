import XCTest
import Database
import Shared

final class AudioTranscriptionPaginationTests: XCTestCase {
    private var database: DatabaseManager!

    override func setUp() async throws {
        let path = "file:audio_pagination_tests_\(UUID().uuidString)?mode=memory&cache=shared"
        database = DatabaseManager(databasePath: path)
        try await database.initialize()
    }

    override func tearDown() async throws {
        try await database.close()
        database = nil
    }

    func testTranscriptionsSupportPagingOffset() async throws {
        let queries = try await makeQueries()
        let baseDate = Date(timeIntervalSince1970: 7_000)

        for index in 0..<5 {
            _ = try await queries.insertTranscription(
                sessionID: "session_\(index)",
                text: "Audio \(index)",
                startTime: baseDate.addingTimeInterval(TimeInterval(index)),
                endTime: baseDate.addingTimeInterval(TimeInterval(index + 1)),
                source: .microphone,
                confidence: 0.9,
                words: []
            )
        }

        let firstPage = try await queries.getTranscriptions(
            from: baseDate.addingTimeInterval(-1),
            to: baseDate.addingTimeInterval(10),
            limit: 2,
            offset: 0
        )
        let secondPage = try await queries.getTranscriptions(
            from: baseDate.addingTimeInterval(-1),
            to: baseDate.addingTimeInterval(10),
            limit: 2,
            offset: 2
        )

        XCTAssertEqual(firstPage.map(\.text), ["Audio 4", "Audio 3"])
        XCTAssertEqual(secondPage.map(\.text), ["Audio 2", "Audio 1"])
    }

    func testLiveActivityQueryCanIncludeEmptyPendingBatches() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 8_000)
        _ = try await queries.insertRawBatch(
            startTime: start,
            endTime: start.addingTimeInterval(15),
            source: .microphone,
            audioPath: "audio/batch_8000_microphone_test.m4a",
            audioSize: 4096
        )

        let transcriptOnlyRows = try await queries.getTranscriptions(
            from: start.addingTimeInterval(-1),
            to: start.addingTimeInterval(20)
        )
        let activityRows = try await queries.getTranscriptions(
            from: start.addingTimeInterval(-1),
            to: start.addingTimeInterval(20),
            includeActivityRows: true
        )

        XCTAssertTrue(transcriptOnlyRows.isEmpty)
        XCTAssertEqual(activityRows.count, 1)
        XCTAssertEqual(activityRows.first?.transcriptStatus, "pending")
        XCTAssertEqual(activityRows.first?.text, "")
    }

    func testTranscriptionReadsReturnOnlyLatestPassPerBatch() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 9_000)
        let batchPath = "audio/batch_9000_microphone_test.m4a"

        _ = try await queries.insertTranscription(
            sessionID: nil,
            text: "first pass draft",
            startTime: start,
            endTime: start.addingTimeInterval(1),
            source: .microphone,
            confidence: 0.5,
            words: [],
            transcriptionPass: 1,
            batchAudioPath: batchPath
        )
        _ = try await queries.insertTranscription(
            sessionID: nil,
            text: "second pass repair",
            startTime: start.addingTimeInterval(1),
            endTime: start.addingTimeInterval(2),
            source: .microphone,
            confidence: 0.7,
            words: [],
            transcriptionPass: 2,
            batchAudioPath: batchPath
        )
        _ = try await queries.insertTranscription(
            sessionID: nil,
            text: "third pass final",
            startTime: start.addingTimeInterval(2),
            endTime: start.addingTimeInterval(3),
            source: .microphone,
            confidence: 0.9,
            words: [],
            transcriptionPass: 3,
            batchAudioPath: batchPath
        )

        let rows = try await queries.getTranscriptions(
            from: start.addingTimeInterval(-1),
            to: start.addingTimeInterval(4),
            limit: 10
        )

        XCTAssertEqual(rows.map(\.text), ["third pass final"])
        XCTAssertEqual(rows.first?.transcriptionPass, 3)
        XCTAssertEqual(rows.first?.batchAudioPath, batchPath)
    }

    func testSearchReturnsOnlyLatestPassPerBatch() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 9_100)
        let batchPath = "audio/batch_9100_microphone_test.m4a"

        _ = try await queries.insertTranscription(
            sessionID: nil,
            text: "oldpassonly draft",
            startTime: start,
            endTime: start.addingTimeInterval(1),
            source: .microphone,
            confidence: 0.5,
            words: [],
            transcriptionPass: 1,
            batchAudioPath: batchPath
        )
        _ = try await queries.insertTranscription(
            sessionID: nil,
            text: "latestpassonly final",
            startTime: start.addingTimeInterval(1),
            endTime: start.addingTimeInterval(2),
            source: .microphone,
            confidence: 0.9,
            words: [],
            transcriptionPass: 3,
            batchAudioPath: batchPath
        )

        let oldMatches = try await queries.searchTranscriptions(query: "oldpassonly")
        let latestMatches = try await queries.searchTranscriptions(query: "latestpassonly")

        XCTAssertTrue(oldMatches.isEmpty)
        XCTAssertEqual(latestMatches.map(\.text), ["latestpassonly final"])
        XCTAssertEqual(latestMatches.first?.transcriptionPass, 3)
    }

    private func makeQueries() async throws -> AudioTranscriptionQueries {
        guard let db = await database.getConnection() else {
            XCTFail("database connection missing")
            throw DatabaseError.connectionFailed(underlying: "database connection missing")
        }
        return AudioTranscriptionQueries(db: db)
    }

    func testContextPageIncludesCrossBoundaryAudioAndPendingRows() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 10_000)
        let crossing = try await queries.insertRawBatch(startTime: start.addingTimeInterval(-10),
            endTime: start.addingTimeInterval(10), source: .microphone,
            audioPath: "audio/crossing.m4a", audioSize: 128)
        _ = try await queries.insertRawBatch(startTime: start.addingTimeInterval(-20),
            endTime: start, source: .microphone, audioPath: "audio/before.m4a", audioSize: 128)
        _ = try await queries.insertRawBatch(startTime: start.addingTimeInterval(20),
            endTime: start.addingTimeInterval(30), source: .microphone,
            audioPath: "audio/after.m4a", audioSize: 128)
        let page = try await queries.getContextPage(from: start, to: start.addingTimeInterval(20))
        XCTAssertEqual(page.entries.map(\.id), [crossing])
        XCTAssertEqual(page.entries.first?.startTime, start.addingTimeInterval(-10))
        XCTAssertEqual(page.entries.first?.transcriptStatus, "pending")
        XCTAssertNil(page.nextCursor)
    }

    func testContextKeysetTiesDoNotSkipRowsWhenNewAudioArrives() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 11_000)
        var ids: [Int64] = []
        for i in 0..<5 {
            ids.append(try await queries.insertRawBatch(startTime: start,
                endTime: start.addingTimeInterval(10), source: .microphone,
                audioPath: "audio/tie-\(i).m4a", audioSize: 128))
        }
        let end = start.addingTimeInterval(100)
        let first = try await queries.getContextPage(from: start, to: end, limit: 2)
        _ = try await queries.insertRawBatch(startTime: start.addingTimeInterval(50),
            endTime: start.addingTimeInterval(60), source: .microphone,
            audioPath: "audio/new.m4a", audioSize: 128)
        let second = try await queries.getContextPage(from: start, to: end, limit: 2,
            before: try XCTUnwrap(first.nextCursor))
        let third = try await queries.getContextPage(from: start, to: end, limit: 2,
            before: try XCTUnwrap(second.nextCursor))
        XCTAssertEqual((first.entries + second.entries + third.entries).map(\.id), ids.reversed())
        XCTAssertNil(third.nextCursor)
    }

    func testContextSearchFiltersFullRangeBeforePagingAndUsesLatestPass() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 12_000)
        _ = try await queries.insertTranscription(sessionID: nil, text: "purple banana old",
            startTime: start, endTime: start.addingTimeInterval(1), source: .microphone,
            confidence: nil, words: [], transcriptionPass: 1, batchAudioPath: "audio/refined.m4a")
        let wanted = try await queries.insertTranscription(sessionID: nil, text: "purple banana corrected",
            startTime: start, endTime: start.addingTimeInterval(1), source: .microphone,
            confidence: nil, words: [], transcriptionPass: 2, batchAudioPath: "audio/refined.m4a")
        for i in 1...10 {
            _ = try await queries.insertTranscription(sessionID: nil, text: "Unrelated conversation",
                startTime: start.addingTimeInterval(Double(i)), endTime: start.addingTimeInterval(Double(i + 1)),
                source: .microphone, confidence: nil, words: [])
        }
        let page = try await queries.getContextPage(from: start, to: start.addingTimeInterval(100),
            limit: 1, query: "purple banana")
        XCTAssertEqual(page.entries.map(\.id), [wanted])
        XCTAssertNil(page.nextCursor)
        let old = try await queries.getContextPage(from: start, to: start.addingTimeInterval(100),
            query: "old")
        XCTAssertTrue(old.entries.isEmpty)
        let literal = try await queries.getContextPage(from: start, to: start.addingTimeInterval(100),
            query: "banana OR conversation")
        XCTAssertTrue(literal.entries.isEmpty, "User text must not become FTS operators")
    }

    func testContextCursorRejectsChangedScopeAndInvalidBounds() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 13_000)
        for i in 0..<3 {
            _ = try await queries.insertRawBatch(startTime: start.addingTimeInterval(Double(i)),
                endTime: start.addingTimeInterval(Double(i + 1)), source: .microphone,
                audioPath: "audio/scope-\(i).m4a", audioSize: 128)
        }
        let page = try await queries.getContextPage(from: start, to: start.addingTimeInterval(100), limit: 1)
        let cursor = try XCTUnwrap(page.nextCursor)
        do {
            _ = try await queries.getContextPage(from: start, to: start.addingTimeInterval(99), before: cursor)
            XCTFail("A continuation from another interval must be rejected")
        } catch { }
        do {
            _ = try await queries.getContextPage(from: start, to: start, limit: 0)
            XCTFail("Invalid interval/limit must be rejected")
        } catch { }
        do {
            _ = try await queries.getContextPage(from: Date(timeIntervalSince1970: .infinity), to: start)
            XCTFail("Non-finite timestamps must not reach the integer conversion")
        } catch { }
    }

    func testContextCursorRejectsOtherReaderSourceAndPhrase() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 14_000)
        for i in 0..<3 {
            _ = try await queries.insertTranscription(sessionID: nil, text: "Remember this",
                startTime: start.addingTimeInterval(Double(i)), endTime: start.addingTimeInterval(Double(i + 1)),
                source: .system, confidence: nil, words: [])
        }
        let end = start.addingTimeInterval(10)
        let page = try await queries.getContextPage(from: start, to: end, source: .system, limit: 1)
        XCTAssertEqual(page.entries.first?.source, .system)
        let cursor = try XCTUnwrap(page.nextCursor)
        let other = try await makeQueries()
        do {
            _ = try await other.getContextPage(from: start, to: end, source: .system, before: cursor)
            XCTFail("Continuations may not cross reader lifetimes")
        } catch AudioContextReadError.invalidContinuation { }
        do {
            _ = try await queries.getContextPage(from: start, to: end, source: .microphone, before: cursor)
            XCTFail("Continuations may not cross sources")
        } catch AudioContextReadError.invalidContinuation { }
        do {
            _ = try await queries.getContextPage(from: start, to: end, source: .system, before: cursor, query: "Remember")
            XCTFail("Continuations may not change their phrase")
        } catch AudioContextReadError.invalidContinuation { }
        let quoted = try await queries.getContextPage(from: start, to: end, query: "\"Remember this\"")
        XCTAssertEqual(quoted.entries.count, 3, "Quotes are safely escaped as literal phrase input")
    }

    func testContextActionReadRejectsDeletedAndSupersededRows() async throws {
        let queries = try await makeQueries()
        let start = Date(timeIntervalSince1970: 15_000)
        let path = "audio/context-revalidation.m4a"
        let first = try await queries.insertTranscription(sessionID: nil, text: "First wording",
            startTime: start, endTime: start.addingTimeInterval(5), source: .microphone,
            confidence: nil, words: [], transcriptionPass: 1, batchAudioPath: path)
        let current = try await queries.getContextEntry(id: first)
        XCTAssertEqual(current?.id, first)
        let later = try await queries.insertTranscription(sessionID: nil, text: "Corrected wording",
            startTime: start, endTime: start.addingTimeInterval(5), source: .microphone,
            confidence: nil, words: [], transcriptionPass: 2, batchAudioPath: path)
        let superseded = try await queries.getContextEntry(id: first)
        XCTAssertNil(superseded)
        try await queries.deleteTranscription(id: later)
        let deleted = try await queries.getContextEntry(id: later)
        XCTAssertNil(deleted)
    }
}
