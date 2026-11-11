import Foundation
import SQLCipher
import XCTest
import Shared
import App
import Storage
@testable import Database
@testable import Retrace

/// An authored transcript in a private file-backed SQLite store; the separate
/// reader exercises actual committed snapshot/deletion behavior. No live history.
@MainActor
final class WorkspaceAudioEvidenceTests: XCTestCase {
    private var directory: URL!
    private var connection: OpaquePointer!
    private var queries: AudioTranscriptionQueries!
    private var reader: NativeAudioEvidenceStore!
    private let start = Date(timeIntervalSince1970: 1_700_000_000.125)
    private let batch = "audio/batch_1700000000125_system_workspace.m4a"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-audio-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("fixture.sqlite").path
        XCTAssertEqual(sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        try await MigrationRunner(db: connection).runMigrations()
        queries = AudioTranscriptionQueries(db: connection)
        reader = try NativeAudioEvidenceStore(connection: SQLiteConnection(readOnlyDatabasePath: path))
        _ = try await queries.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(5),
            source: .system, audioPath: batch, audioSize: 4096)
    }
    override func tearDown() async throws {
        await reader?.close()
        reader = nil; queries = nil
        if let connection { XCTAssertEqual(sqlite3_close_v2(connection), SQLITE_OK) }
        connection = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testTranscriptIsSelectableWithNoScreenAndKeepsItsExactTimeAndText() async throws {
        _ = try await sentence("Cedar pricing discussion before the revised proposal")
        let page = try await reader.searchAudioEvidence(.init(terms: ["pricing"]))
        let hit = try XCTUnwrap(page.hits.first)
        let model = makeModel()
        await model.selectEvidence(.audio(hit.snapshot.reference))
        XCTAssertEqual(model.presentedReference, .audio(hit.snapshot.reference))
        XCTAssertEqual(model.selectedTimestamp, start)
        XCTAssertNil(model.selection)
        let admission = try XCTUnwrap(model.selectionAdmission)
        await model.refresh()
        XCTAssertTrue(model.admits(admission))
        guard case .audio(let exact) = model.evidence.resolution else { return XCTFail("No standalone transcript") }
        XCTAssertEqual(exact.text, hit.snapshot.text)
        XCTAssertEqual(exact.reference, hit.snapshot.reference)
        await model.toggleBookmark()
        XCTAssertEqual(model.bookmarks.first?.reference, .audio(hit.snapshot.reference))
        model.close()
    }

    func testRefinedTranscriptCannotReplacePinnedImmutableReference() async throws {
        let id = try await sentence("Amount 47000 remains a draft")
        let page = try await reader.searchAudioEvidence(.init(terms: ["Amount"]))
        let hit = try XCTUnwrap(page.hits.first)
        let model = makeModel()
        await model.selectEvidence(.audio(hit.snapshot.reference))
        try await queries.updateTranscriptionText(id: id, text: "Amount 48000 is the revision")
        await model.refresh()
        XCTAssertNil(model.presentedReference)
        XCTAssertEqual(model.evidence.evidenceReference, .audio(hit.snapshot.reference))
        guard case .unavailable = model.evidence.resolution else { return XCTFail("Substituted a newer transcript") }
        model.close()
    }

    func testDeletedTranscriptCannotReappearFromBookmark() async throws {
        let id = try await sentence("Authored retained text")
        let page = try await reader.searchAudioEvidence(.init(terms: ["Authored"]))
        let hit = try XCTUnwrap(page.hits.first)
        let model = makeModel()
        await model.selectEvidence(.audio(hit.snapshot.reference))
        await model.toggleBookmark()
        let bookmark = try XCTUnwrap(model.bookmarks.first)
        _ = try await queries.deleteTranscription(id: id)
        await model.openBookmark(bookmark)
        XCTAssertNil(model.selectionAdmission)
        guard case .unavailable = model.evidence.resolution else { return XCTFail("Deleted bookmark restored text") }
        model.close()
    }

    func testOneSearchFieldFindsAndSelectsAnExactTranscriptWithoutAScreen() async throws {
        _ = try await sentence("Cedar pricing before the proposal changed")
        let model = try await makeHistoryModel()
        await model.submitSearch("pricing")
        XCTAssertTrue(model.hasSearched)
        XCTAssertEqual(model.historySearchResults.count, 1)
        XCTAssertTrue(model.searchResults.isEmpty, "Transcript hits must not manufacture tape frames")
        let hit = try XCTUnwrap(model.historySearchResults.first)
        guard case .audio(let audio) = hit else { return XCTFail("Expected a real transcript match") }
        XCTAssertEqual(audio.excerpt.text, "Cedar pricing before the proposal changed")
        await model.selectHistoryHit(hit)
        XCTAssertEqual(model.presentedReference, hit.reference)
        XCTAssertEqual(model.selectedTimestamp, start)
        XCTAssertNil(model.selection)
        await model.toggleBookmark()
        XCTAssertEqual(model.bookmarks.first?.reference, hit.reference)
        model.close()
    }

    func testRefreshRemovesDeletedTranscriptSearchTextAndCoverage() async throws {
        let id = try await sentence("Cedar pricing before the proposal changed")
        let model = try await makeHistoryModel()
        await model.submitSearch("pricing")
        XCTAssertEqual(model.historySearchResults.count, 1)
        XCTAssertNotNil(model.historySearchCoverage)
        _ = try await queries.deleteTranscription(id: id)
        await model.refresh()
        XCTAssertTrue(model.historySearchResults.isEmpty)
        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertNil(model.historySearchCoverage)
        XCTAssertTrue(model.searchNeedsRefresh)
        model.close()
    }

    func testClosedWorkspaceRejectsLateRealTranscriptSearchResults() async throws {
        _ = try await sentence("Cedar pricing before the proposal changed")
        let entered = expectation(description: "Real history search completed before held delivery")
        let gate = WorkspaceHistoryResultGate(entered: { entered.fulfill() })
        addTeardownBlock { await gate.release() }
        let model = try await makeHistoryModel(afterSearch: { await gate.wait() })
        let task = Task { await model.submitSearch("pricing") }
        addTeardownBlock { await gate.release(); await task.value }
        await fulfillment(of: [entered], timeout: 5)
        model.close()
        await gate.release()
        await task.value
        XCTAssertTrue(model.historySearchResults.isEmpty)
        XCTAssertNil(model.historySearchCoverage)
        XCTAssertFalse(model.hasSearched)
        XCTAssertFalse(model.isSearching)
    }

    private func makeHistoryModel(afterSearch: @escaping @Sendable () async -> Void = {}) async throws -> UnifiedWorkspaceModel {
        let database = DatabaseManager(databasePath: "file:workspace-history-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let pointer = await database.getConnection()
        let adapter = DataAdapter(retraceConnection: SQLiteConnection(db: try XCTUnwrap(pointer)),
            retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: directory.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: directory.path), database: database)
        try await adapter.initialize()
        addTeardownBlock { await adapter.shutdown(); try await database.close() }
        let reader = reader!
        let service = ProgressiveRecallService(database: database, adapter: adapter,
            configuration: { CaptureConfig() }, audioHistory: reader, imageReader: { _ in
                XCTFail("Transcript search and selection must not decode a screen")
                throw EvidenceUnavailableReason.unsupported
            })
        return UnifiedWorkspaceModel(evidence: EvidenceViewModel(client: .live(service: service)),
            latest: { [] }, search: { _ in [] }, historySearch: { text in
                let result = try await HistoryMomentSearch.search(query: .init(text: text, mode: .relevant),
                    adapter: adapter, evidence: service, screenSearch: { try await adapter.search(query: $0) },
                    audioHistory: reader)
                await afterSearch()
                return result
            }, revalidateHistorySearch: { result in
                try await HistoryMomentSearch.revalidate(result, adapter: adapter, evidence: service, audioHistory: reader)
            }, track: { _ in }, seek: { _ in
                XCTFail("Transcript selection must not substitute a nearby screen")
                return []
            })
    }

    private func sentence(_ text: String) async throws -> Int64 {
        try await queries.insertTranscription(sessionID: nil, text: text, startTime: start,
            endTime: start.addingTimeInterval(2), source: .system, confidence: 0.9, words: [],
            audioPath: batch, transcriptionPass: 1, batchAudioPath: batch)
    }
    private func makeModel() -> UnifiedWorkspaceModel {
        let reader = reader!
        let client = EvidenceClient(reference: { _ in throw EvidenceUnavailableReason.unsupported },
            frameReference: { _, _ in throw EvidenceUnavailableReason.unsupported }, resolve: { reference in
                guard case .audio(let audio) = reference else { return .unavailable(.unsupported) }
                do {
                    switch try await reader.readAudioEvidence(audio) {
                    case .available(let snapshot, let stamp):
                        try await reader.revalidateAudioEvidence(stamp, references: [audio])
                        return .audio(snapshot)
                    case .unavailable(let reason):
                        return .unavailable(reason == .evidenceDeleted ? .evidenceDeleted : .extractionUnavailable)
                    }
                } catch { return .unavailable(.integrityFailure) }
            }, currentRevision: { _ in nil }, track: { _, _, _ in })
        return UnifiedWorkspaceModel(evidence: EvidenceViewModel(client: client), latest: { [] },
            search: { _ in [] }, track: { _ in }, seek: { _ in
                XCTFail("Exact transcript selection cannot require a nearby screen")
                return []
            })
    }
}

private actor WorkspaceHistoryResultGate {
    private let entered: @Sendable () -> Void
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(entered: @escaping @Sendable () -> Void) { self.entered = entered }
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0; entered() }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
