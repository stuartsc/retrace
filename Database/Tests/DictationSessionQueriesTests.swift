import XCTest
import Database
import Shared

final class DictationSessionQueriesTests: XCTestCase {
    private var database: DatabaseManager!

    override func setUp() async throws {
        let path = "file:dictation_tests_\(UUID().uuidString)?mode=memory&cache=shared"
        database = DatabaseManager(databasePath: path)
        try await database.initialize()
    }

    override func tearDown() async throws {
        try await database.close()
        database = nil
    }

    func testInsertAndFetchRecentDictationSession() async throws {
        let queries = try await makeQueries()
        let startedAt = Date(timeIntervalSince1970: 4_000)
        let session = DictationSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(2),
            insertedAt: startedAt.addingTimeInterval(3),
            text: "Hello from Retrace.",
            status: .inserted,
            targetContext: DictationTargetContext(
                bundleID: "com.apple.TextEdit",
                appName: "TextEdit",
                windowTitle: "Untitled"
            ),
            insertionMethod: .clipboardPaste,
            errorMessage: nil
        )

        try await queries.upsertSession(session)
        let sessions = try await queries.getRecentSessions(limit: 5)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, session.id)
        XCTAssertEqual(sessions[0].text, "Hello from Retrace.")
        XCTAssertEqual(sessions[0].status, .inserted)
        XCTAssertEqual(sessions[0].targetContext?.bundleID, "com.apple.TextEdit")
    }

    func testUpsertUpdatesExistingDictationSessionStatus() async throws {
        let queries = try await makeQueries()
        let startedAt = Date(timeIntervalSince1970: 5_000)
        let id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        try await queries.upsertSession(DictationSession(
            id: id,
            startedAt: startedAt,
            endedAt: nil,
            insertedAt: nil,
            text: "",
            status: .capturing,
            targetContext: nil,
            insertionMethod: .clipboardPaste,
            errorMessage: nil
        ))

        try await queries.upsertSession(DictationSession(
            id: id,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1),
            insertedAt: nil,
            text: "",
            status: .empty,
            targetContext: nil,
            insertionMethod: .clipboardPaste,
            errorMessage: "No microphone audio captured"
        ))

        let sessions = try await queries.getRecentSessions(limit: 5)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].status, .empty)
        XCTAssertEqual(sessions[0].errorMessage, "No microphone audio captured")
    }

    func testFetchRecentDictationSessionsSupportsPagingOffset() async throws {
        let queries = try await makeQueries()
        let baseDate = Date(timeIntervalSince1970: 6_000)

        for index in 0..<5 {
            try await queries.upsertSession(DictationSession(
                id: UUID(),
                startedAt: baseDate.addingTimeInterval(TimeInterval(index)),
                endedAt: baseDate.addingTimeInterval(TimeInterval(index + 1)),
                insertedAt: baseDate.addingTimeInterval(TimeInterval(index + 2)),
                text: "Session \(index)",
                status: .inserted,
                targetContext: nil,
                insertionMethod: .clipboardPaste,
                errorMessage: nil
            ))
        }

        let firstPage = try await queries.getRecentSessions(limit: 2, offset: 0)
        let secondPage = try await queries.getRecentSessions(limit: 2, offset: 2)

        XCTAssertEqual(firstPage.map(\.text), ["Session 4", "Session 3"])
        XCTAssertEqual(secondPage.map(\.text), ["Session 2", "Session 1"])
    }

    private func makeQueries() async throws -> DictationSessionQueries {
        guard let db = await database.getConnection() else {
            XCTFail("database connection missing")
            throw DatabaseError.connectionFailed(underlying: "database connection missing")
        }
        return DictationSessionQueries(db: db)
    }
}
