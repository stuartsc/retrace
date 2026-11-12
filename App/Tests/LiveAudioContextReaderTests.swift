import Database
import Foundation
import Shared
import SQLCipher
import XCTest
@testable import App

final class LiveAudioContextReaderTests: XCTestCase {
    private var containers: [ServiceContainer] = []
    private var readers: [LiveAudioContextReader] = []
    private var directories: [URL] = []
    private var pointers: [OpaquePointer] = []

    override func tearDown() async throws {
        for reader in readers { await reader.close() }
        for container in containers { try await container.shutdown() }
        for pointer in pointers { XCTAssertEqual(sqlite3_close_v2(pointer), SQLITE_OK) }
        for directory in directories { try FileManager.default.removeItem(at: directory) }
    }

    func testCoordinatorFactoryPreservesPaginationAcrossRepeatedAcquisition() async throws {
        let (services, coordinator, start) = try await makeCoordinator()
        let end = start.addingTimeInterval(10)
        let firstReader = try await coordinator.getLiveAudioContextReader()
        let first = try await firstReader.getContextPage(from: start, to: end, limit: 1)
        let secondReader = try await coordinator.getLiveAudioContextReader()
        XCTAssertTrue(firstReader === secondReader)
        let second = try await secondReader.getContextPage(from: start, to: end, limit: 1,
            before: XCTUnwrap(first.nextCursor))
        let thirdReader = try await coordinator.getLiveAudioContextReader()
        let third = try await thirdReader.getContextPage(from: start, to: end, limit: 1,
            before: XCTUnwrap(second.nextCursor))
        XCTAssertEqual((first.entries + second.entries + third.entries).map(\.text),
            ["Authored passage 2", "Authored passage 1", "Authored passage 0"])
        XCTAssertNil(third.nextCursor)
        // The actual service close must revoke a retained factory result before
        // the canonical SQLite writer closes, even if a view still retains it.
        await services.setBeforeDatabaseCloseForTesting {
            do {
                _ = try await firstReader.getContextPage(from: start, to: end)
                XCTFail("The reader must close before the recording database")
            } catch AudioContextReadError.closed { }
        }
        try await services.shutdown()
        do {
            _ = try await coordinator.getLiveAudioContextReader()
            XCTFail("A shut-down service container cannot mint another reader")
        } catch AudioContextReadError.closed { }
        do {
            _ = try await firstReader.getContextEntry(id: first.entries[0].id)
            XCTFail("A retained reader cannot access its released connection")
        } catch AudioContextReadError.closed { }

        let (_, reopened, _) = try await makeCoordinator()
        let replacement = try await reopened.getLiveAudioContextReader()
        do {
            _ = try await replacement.getContextPage(from: start, to: end,
                before: XCTUnwrap(first.nextCursor))
            XCTFail("A continuation must not cross recording-reader lifetimes")
        } catch AudioContextReadError.invalidContinuation { }
    }

    func testOwnedFileReaderObservesCommittedChangesWithoutBorrowingWriterTransaction() async throws {
        let (path, writer) = try makePrivateFile()
        let reader = LiveAudioContextReader(openConnection: { try SQLiteConnection(readOnlyDatabasePath: path) })
        readers.append(reader)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(10)
        let first = try await reader.getContextPage(from: start, to: end)
        XCTAssertEqual(first.entries.map(\.id), [1])
        try writer.execute(sql: "BEGIN IMMEDIATE")
        try writer.execute(sql: "INSERT INTO audio_captures(id,text,start_time,end_time,source) VALUES(2,'Authored pending commit',1700000002000,1700000003000,'microphone')")
        let duringWrite = try await reader.getContextPage(from: start, to: end)
        XCTAssertEqual(duringWrite.entries.map(\.id), [1])
        try writer.commit()
        let committed = try await reader.getContextPage(from: start, to: end)
        XCTAssertEqual(committed.entries.map(\.id), [2, 1])
    }

    func testConcurrentFirstReadsShareOneConnectionAndCursorIdentity() async throws {
        let (path, writer) = try makePrivateFile()
        try writer.execute(sql: "INSERT INTO audio_captures(id,text,start_time,end_time,source) VALUES(2,'Authored second passage',1700000002000,1700000003000,'microphone')")
        let opens = LiveAudioOpenCounter()
        let reader = LiveAudioContextReader(openConnection: {
            await opens.increment()
            await Task.yield()
            return try SQLiteConnection(readOnlyDatabasePath: path)
        })
        readers.append(reader)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        async let first = reader.getContextPage(from: start, to: start.addingTimeInterval(10), limit: 1)
        async let second = reader.getContextPage(from: start, to: start.addingTimeInterval(10), limit: 1)
        let pages = try await (first, second)
        XCTAssertEqual(pages.0.entries.map(\.id), pages.1.entries.map(\.id))
        let count = await opens.count
        XCTAssertEqual(count, 1)
        for cursor in [try XCTUnwrap(pages.0.nextCursor), try XCTUnwrap(pages.1.nextCursor)] {
            let continued = try await reader.getContextPage(from: start, to: start.addingTimeInterval(10),
                limit: 1, before: cursor)
            XCTAssertEqual(continued.entries.map(\.id), [1])
        }
    }

    func testCloseJoinsOpeningBeforeReleasingOwnedConnection() async throws {
        let (path, _) = try makePrivateFile()
        let entered = expectation(description: "owned connection open is held")
        let gate = LiveAudioOpenGate(entered: entered)
        let reader = LiveAudioContextReader(openConnection: {
            // Own an actual independent connection while the factory is held.
            let connection = try SQLiteConnection(readOnlyDatabasePath: path)
            await gate.hold()
            return connection
        })
        readers.append(reader)
        let closeEntered = expectation(description: "close has revoked read admission")
        await reader.setCloseRequestForTesting { closeEntered.fulfill() }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let read = Task { try await reader.getContextPage(from: start, to: start.addingTimeInterval(10)) }
        await fulfillment(of: [entered], timeout: 3)
        let closeCompletions = LiveAudioOpenCounter()
        let close = Task { await reader.close(); await closeCompletions.increment() }
        await fulfillment(of: [closeEntered], timeout: 3)
        try? await Task.sleep(for: .milliseconds(50))
        let prematureCompletions = await closeCompletions.count
        XCTAssertEqual(prematureCompletions, 0, "Close must remain joined to the held connection open")
        // Even though close is waiting, no competing request may reopen it.
        do {
            _ = try await reader.getContextEntry(id: 1)
            XCTFail("Closing readers must reject new work immediately")
        } catch AudioContextReadError.closed { }
        catch {
            await gate.release()
            _ = try? await read.value
            await close.value
            throw error
        }
        await gate.release()
        let readResult = await read.result
        await close.value
        do {
            _ = try readResult.get()
            XCTFail("An open finishing after close cannot publish a reader")
        } catch AudioContextReadError.closed { }
        let finalCompletions = await closeCompletions.count
        XCTAssertEqual(finalCompletions, 1)
    }

    private func makeCoordinator() async throws -> (ServiceContainer, AppCoordinator, Date) {
        let services = ServiceContainer(inMemory: true)
        containers.append(services)
        try await services.database.initialize()
        let coordinator = AppCoordinator(services: services)
        let value = await coordinator.getAudioTranscriptionQueries()
        let writer = try XCTUnwrap(value)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<3 {
            _ = try await writer.insertTranscription(sessionID: nil, text: "Authored passage \(index)",
                startTime: start.addingTimeInterval(Double(index)), endTime: start.addingTimeInterval(Double(index + 1)),
                source: .microphone, confidence: nil, words: [])
        }
        return (services, coordinator, start)
    }

    private func makePrivateFile() throws -> (String, SQLiteConnection) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-audio-reader-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        directories.append(directory)
        let path = directory.appendingPathComponent("authored.sqlite").path
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &raw, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        let pointer = try XCTUnwrap(raw)
        pointers.append(pointer)
        let writer = SQLiteConnection(db: pointer)
        try writer.execute(sql: "PRAGMA journal_mode=WAL")
        try writer.execute(sql: """
            CREATE TABLE audio_captures (
                id INTEGER PRIMARY KEY, session_id TEXT, text TEXT NOT NULL,
                start_time INTEGER NOT NULL, end_time INTEGER NOT NULL, source TEXT NOT NULL,
                confidence REAL, created_at INTEGER DEFAULT 0, audio_path TEXT,
                transcript_status TEXT DEFAULT 'transcribed', detected_language TEXT,
                audio_variant TEXT DEFAULT 'original', quality_flags TEXT,
                transcription_pass INTEGER DEFAULT 1, batch_audio_path TEXT)
            """)
        try writer.execute(sql: "INSERT INTO audio_captures(id,text,start_time,end_time,source) VALUES(1,'Authored committed passage',1700000000000,1700000001000,'microphone')")
        return (path, writer)
    }
}

private actor LiveAudioOpenCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor LiveAudioOpenGate {
    let entered: XCTestExpectation
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation) { self.entered = entered }
    func hold() async {
        entered.fulfill()
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
