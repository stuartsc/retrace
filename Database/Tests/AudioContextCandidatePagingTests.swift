import Database
import Foundation
import Shared
import SQLCipher
import XCTest

final class AudioContextCandidatePagingTests: XCTestCase {
    private var database: DatabaseManager!
    private var queries: AudioTranscriptionQueries!
    private var pointer: OpaquePointer!

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:audio_candidate_\(UUID())?mode=memory&cache=shared")
        try await database.initialize()
        let connection = await database.getConnection()
        pointer = try XCTUnwrap(connection)
        queries = AudioTranscriptionQueries(db: pointer)
    }

    override func tearDown() async throws {
        try await database.close()
        queries = nil
        database = nil
        pointer = nil
    }

    func testPartialFinalPageRetainsMatchesAndFindsEarlierLongOverlapWithoutDrainingHistory() async throws {
        let start = Date(timeIntervalSince1970: 20_000)
        let end = start.addingTimeInterval(10)
        let longOverlap = try await insert("Long overlap", at: start.addingTimeInterval(-10_000), end: end)
        // These expired rows sit between the recent matches and the much earlier
        // overlap. Their exclusion must advance an explicit raw continuation.
        for index in 1...1_100 {
            let time = start.addingTimeInterval(-Double(index))
            _ = try await insert("Expired authored recording", at: time, end: time.addingTimeInterval(0.5))
        }
        var recent: [Int64] = []
        for _ in 0..<178 {
            recent.append(try await insert("Recent authored recording", at: start, end: end))
        }
        let first = try await queries.getContextPage(from: start, to: end, limit: 100)
        XCTAssertEqual(first.entries.count, 100)
        XCTAssertTrue(first.hasMoreMatches)
        XCTAssertFalse(first.scanIncomplete)
        XCTAssertEqual(first.scannedCandidates, 101)
        let second = try await queries.getContextPage(from: start, to: end, limit: 100,
            before: XCTUnwrap(first.nextCursor))
        XCTAssertEqual(second.entries.count, 78, "Keep useful matches instead of discarding a partial final page")
        XCTAssertTrue(second.scanIncomplete)
        XCTAssertFalse(second.hasMoreMatches, "Unchecked history does not prove another match")
        XCTAssertEqual(second.scannedCandidates, AudioTranscriptionQueries.contextCandidateLimit)
        let third = try await queries.getContextPage(from: start, to: end, limit: 100,
            before: XCTUnwrap(second.nextCursor))
        XCTAssertTrue(third.entries.isEmpty)
        XCTAssertTrue(third.scanIncomplete)
        XCTAssertNotEqual(third.nextCursor, second.nextCursor, "An empty accepted page still advances inspected history")
        let fourth = try await queries.getContextPage(from: start, to: end, limit: 100,
            before: XCTUnwrap(third.nextCursor))
        XCTAssertEqual(fourth.entries.map(\.id), [longOverlap])
        XCTAssertNil(fourth.nextCursor)
        XCTAssertFalse(fourth.scanIncomplete)
        let all = [first, second, third, fourth].flatMap { $0.entries.map(\.id) }
        XCTAssertEqual(all, Array(recent.reversed()) + [longOverlap])
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertTrue([first, second, third, fourth].allSatisfy { $0.scannedCandidates <= 512 })
    }

    func testSparsePhrasePagesPreserveSourceLatestPassAndCursorScope() async throws {
        let start = Date(timeIntervalSince1970: 30_000)
        let end = start.addingTimeInterval(2_000)
        _ = try await insert("purple banana stale", at: start, end: start.addingTimeInterval(3),
            source: .microphone, pass: 1, batch: "authored/refined.m4a")
        let wanted = try await insert("purple banana corrected", at: start, end: start.addingTimeInterval(3),
            source: .system, pass: 2, batch: "authored/refined.m4a")
        _ = try await insert("purple banana excluded source", at: start.addingTimeInterval(1),
            end: start.addingTimeInterval(3), source: .microphone)
        for index in 1...520 {
            let time = start.addingTimeInterval(Double(index + 10))
            _ = try await insert("Unrelated authored conversation", at: time, end: time.addingTimeInterval(1), source: .system)
        }
        let first = try await queries.getContextPage(from: start, to: end, source: .system, limit: 1, query: "purple banana")
        XCTAssertTrue(first.entries.isEmpty)
        XCTAssertTrue(first.scanIncomplete)
        XCTAssertEqual(first.scannedCandidates, 512)
        let cursor = try XCTUnwrap(first.nextCursor)
        let other = AudioTranscriptionQueries(db: pointer)
        let invalidOperations: [() async throws -> AudioContextPage] = [
            { try await self.queries.getContextPage(from: start, to: end, source: .microphone, before: cursor, query: "purple banana") },
            { try await self.queries.getContextPage(from: start, to: end.addingTimeInterval(1), source: .system, before: cursor, query: "purple banana") },
            { try await self.queries.getContextPage(from: start, to: end, source: .system, before: cursor, query: "purple") },
            { try await other.getContextPage(from: start, to: end, source: .system, before: cursor, query: "purple banana") }
        ]
        for operation in invalidOperations {
            do { _ = try await operation(); XCTFail("A partial continuation cannot change reader or scope") }
            catch AudioContextReadError.invalidContinuation { }
        }
        let second = try await queries.getContextPage(from: start, to: end, source: .system,
            limit: 1, before: cursor, query: "purple banana")
        XCTAssertEqual(second.entries.map(\.id), [wanted])
        XCTAssertNil(second.nextCursor)
        XCTAssertFalse(second.scanIncomplete)
    }

    func testEqualStartRowsUseExistingIndexEndThenIDOrderWithoutSkippingMatchingSentinel() async throws {
        let start = Date(timeIntervalSince1970: 40_000)
        var expected: [(end: Int, id: Int64)] = []
        for duration in [1, 3, 2, 3, 1, 2, 3] {
            expected.append((duration, try await insert("Authored tie", at: start,
                end: start.addingTimeInterval(Double(duration)))))
        }
        expected.sort { $0.end == $1.end ? $0.id > $1.id : $0.end > $1.end }
        var cursor: AudioContextCursor?
        var received: [Int64] = []
        var requests = 0
        repeat {
            requests += 1
            let page = try await queries.getContextPage(from: start, to: start.addingTimeInterval(10),
                limit: 2, before: cursor)
            received += page.entries.map(\.id)
            XCTAssertFalse(page.scanIncomplete)
            XCTAssertLessThanOrEqual(page.scannedCandidates, 3)
            cursor = page.nextCursor
        } while cursor != nil && requests < 8
        XCTAssertEqual(received, expected.map { $0.id })
        XCTAssertNil(cursor)
    }

    private func insert(_ text: String, at start: Date, end: Date,
                        source: AudioSource = .microphone, pass: Int = 1, batch: String? = nil) async throws -> Int64 {
        try await queries.insertTranscription(sessionID: nil, text: text, startTime: start, endTime: end,
            source: source, confidence: nil, words: [], transcriptionPass: pass, batchAudioPath: batch)
    }
}
