import App
import Database
import Foundation
import Shared
import SQLCipher
import XCTest
@testable import Retrace

/// The transcript panel must read on a read-only connection, never the writer's.
final class TranscriptReadConnectionTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_800_000_000)

    func testLoaderWorksOnAReadOnlyConnectionThatIsNotTheWriter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-read-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let database = DatabaseManager(databasePath: directory.appendingPathComponent("retrace.db").path)
        try await database.initialize()
        let writerConnection = await database.getConnection()
        let writerPointer = try XCTUnwrap(writerConnection)
        let writer = AudioTranscriptionQueries(db: writerPointer)
        _ = try await writer.insertTranscription(sessionID: nil, text: "Read-only panel row",
            startTime: time, endTime: time.addingTimeInterval(1), source: .microphone, confidence: nil, words: [])

        let reader = try await database.makeRecallReadConnection()
        let readerPointer = try XCTUnwrap(reader.getConnection())
        XCTAssertNotEqual(readerPointer, writerPointer)
        XCTAssertEqual(sqlite3_db_readonly(readerPointer, "main"), 1)

        let page = try await TranscriptRecordingLoader.load(queries: AudioTranscriptionQueries(db: readerPointer), at: time)
        XCTAssertEqual(page.transcriptions.map(\.text), ["Read-only panel row"])
        XCTAssertFalse(page.isTruncated)
        try await database.close()
    }

    func testLoaderReadsThroughTheCoordinatorsSharedReader() async throws {
        let services = ServiceContainer(inMemory: true)
        try await services.database.initialize()
        let coordinator = AppCoordinator(services: services)
        let writerValue = await coordinator.getAudioTranscriptionQueries()
        let writer = try XCTUnwrap(writerValue)
        _ = try await writer.insertTranscription(sessionID: nil, text: "Shared reader row",
            startTime: time, endTime: time.addingTimeInterval(1), source: .microphone, confidence: nil, words: [])

        let reader = try await coordinator.getLiveAudioContextReader()
        let first = try await TranscriptRecordingLoader.load(reader: reader, at: time)
        let second = try await TranscriptRecordingLoader.load(reader: reader, at: time)
        XCTAssertEqual(first.transcriptions.map(\.text), ["Shared reader row"])
        XCTAssertEqual(second.transcriptions.map(\.id), first.transcriptions.map(\.id))
        let sameReader = try await coordinator.getLiveAudioContextReader()
        XCTAssertTrue(sameReader === reader, "Refreshes must reuse one reader, not open one per refresh")
        await reader.close()
        try await services.database.close()
    }
}
