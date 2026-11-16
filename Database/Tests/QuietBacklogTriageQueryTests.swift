import XCTest
import Shared
import SQLCipher
@testable import Database

/// Old quiet-at-capture recordings become no speech; everything else is untouched.
final class QuietBacklogTriageQueryTests: XCTestCase {
    private var database: DatabaseManager!
    private var queries: AudioTranscriptionQueries!
    private var connection: OpaquePointer!

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:quiet_backlog_\(UUID().uuidString)?mode=memory&cache=shared")
        try await database.initialize()
        connection = await database.getConnection()
        queries = AudioTranscriptionQueries(db: connection)
    }
    override func tearDown() async throws { try await database.close() }

    private func insert(ageHours: Double, quiet: Bool, now: Date, path: String? = nil) async throws -> Int64 {
        let start = now.addingTimeInterval(-ageHours * 3_600)
        return try await queries.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(15),
            source: .microphone, audioPath: path ?? "audio/batch_\(UUID().uuidString).m4a",
            audioSize: 1_000, deferForLowEnergy: quiet)
    }

    private func row(_ id: Int64) -> (status: String, flags: String?, path: String?) {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(connection, "SELECT transcript_status, quality_flags, audio_path FROM audio_captures WHERE id = ?", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        func text(_ column: Int32) -> String? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(statement, column))
        }
        return (text(0) ?? "", text(1), text(2))
    }

    func testMarksOnlyOldQuietPendingAndKeepsAudio() async throws {
        let now = Date()
        let oldQuiet = try await insert(ageHours: 72, quiet: true, now: now)
        let newQuiet = try await insert(ageHours: 24, quiet: true, now: now)
        let oldSpeech = try await insert(ageHours: 72, quiet: false, now: now)
        let oldQuietNonBatch = try await insert(ageHours: 72, quiet: true, now: now, path: "audio/word_1.m4a")
        let pathBefore = row(oldQuiet).path

        let marked = try await queries.markAgedLowEnergyPendingAsSilence(olderThan: now.addingTimeInterval(-48 * 3_600))

        XCTAssertEqual(marked, 1)
        let after = row(oldQuiet)
        XCTAssertEqual(after.status, "probable_silence")
        XCTAssertEqual(after.flags, "pending_low_energy_v1,backlog_quiet_v1")
        XCTAssertEqual(after.path, pathBefore)
        XCTAssertEqual(row(newQuiet).status, "pending")
        XCTAssertEqual(row(oldSpeech).status, "pending")
        XCTAssertEqual(row(oldQuietNonBatch).status, "pending")
        // Re-running finds nothing more to do.
        let again = try await queries.markAgedLowEnergyPendingAsSilence(olderThan: now.addingTimeInterval(-48 * 3_600))
        XCTAssertEqual(again, 0)
    }

    func testRespectsBatchLimit() async throws {
        let now = Date()
        for _ in 0..<5 { _ = try await insert(ageHours: 100, quiet: true, now: now) }
        let first = try await queries.markAgedLowEnergyPendingAsSilence(olderThan: now.addingTimeInterval(-48 * 3_600), limit: 3)
        let second = try await queries.markAgedLowEnergyPendingAsSilence(olderThan: now.addingTimeInterval(-48 * 3_600), limit: 3)
        XCTAssertEqual(first, 3)
        XCTAssertEqual(second, 2)
    }
}
