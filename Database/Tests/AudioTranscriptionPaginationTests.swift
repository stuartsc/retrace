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
}
