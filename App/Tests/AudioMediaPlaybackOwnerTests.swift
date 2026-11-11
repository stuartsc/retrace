import Foundation
import Shared
import SQLCipher
import Storage
import XCTest
@testable import App
@testable import Database

final class AudioMediaPlaybackOwnerTests: XCTestCase {
    func testConcurrentCloseCallersJoinHeldNativeRevalidation() async throws {
        let fixture = try await PlaybackFixture.make()
        let entered = expectation(description: "Native revalidation held")
        let gate = PlaybackReadGate(reader: fixture.reader, entered: entered)
        let owner = AudioMediaPlaybackOwner(evidence: gate, media: fixture.media, configuration: { CaptureConfig() })
        let lease = try await owner.acquire(fixture.reference)
        await gate.arm()
        await fulfillment(of: [entered], timeout: 3)
        await lease.release()
        let completions = PlaybackCompletions()
        let first = Task { await owner.close(); await completions.completed() }
        let second = Task { await owner.close(); await completions.completed() }
        try await Task.sleep(for: .milliseconds(30))
        let before = await completions.count
        XCTAssertEqual(before, 0, "Both callers must join the held canonical read")
        await gate.open()
        await first.value; await second.value
        let after = await completions.count
        XCTAssertEqual(after, 2)
        await fixture.close()
    }
    func testSubmillisecondOriginUsesOnlyDeclaredSQLiteTimingTolerance() async throws {
        let fixture = try await PlaybackFixture.make(submillisecondOrigin: true)
        let owner = AudioMediaPlaybackOwner(evidence: fixture.reader, media: fixture.media,
            configuration: { CaptureConfig() })
        let lease = try await owner.acquire(fixture.reference)
        XCTAssertGreaterThan(lease.pcmData.count, 15_950)
        XCTAssertLessThanOrEqual(lease.pcmData.count, 16_000)
        await lease.release(); await owner.close(); await fixture.close()
    }
    func testExactAACRangeRevalidatesDeletionAndJoinsRelease() async throws {
        let fixture = try await PlaybackFixture.make()
        let observedMedia = PlaybackObservedMedia(fixture.media)
        let owner = AudioMediaPlaybackOwner(evidence: fixture.reader, media: observedMedia,
            configuration: { CaptureConfig() })
        let lease = try await owner.acquire(fixture.reference)
        XCTAssertEqual(lease.pcmData.count, 16_000) // 0.5 seconds of mono Int16.
        XCTAssertTrue(lease.validity.isValid)
        let nativePCM = await observedMedia.lastReadPCM
        XCTAssertEqual(lease.pcmData, try XCTUnwrap(nativePCM).subdata(in: 8_000..<24_000),
            "Selection must use exactly the admitted lease's samples; separate lossy decodes may differ numerically")
        _ = try await fixture.queries.deleteTranscription(id: fixture.row)
        await owner.revalidateActive()
        XCTAssertFalse(lease.validity.isValid)
        let close = Task { await owner.close() }
        await lease.release()
        await close.value
        do { _ = try await owner.acquire(fixture.reference); XCTFail("Terminal owner must reject") }
        catch { }
        await fixture.close()
    }

    func testPolicyChangeAndTamperedAACCannotBePresented() async throws {
        let fixture = try await PlaybackFixture.make()
        let policy = PlaybackPolicy()
        let owner = AudioMediaPlaybackOwner(evidence: fixture.reader, media: fixture.media,
            configuration: { await policy.value })
        let lease = try await owner.acquire(fixture.reference)
        await policy.change()
        await owner.revalidateActive()
        XCTAssertFalse(lease.validity.isValid)
        await lease.release()
        let path = fixture.root.appendingPathComponent(fixture.window.manifest.ranges[0].chunk.relativePath)
        var data = try Data(contentsOf: path)
        data[data.count / 2] ^= 0xff
        try data.write(to: path)
        do { _ = try await owner.acquire(fixture.reference); XCTFail("Tampered AAC must reject") }
        catch { }
        await owner.close(); await fixture.close()
    }
}

/// Observes the actual native lease without replacing decoding or persistence.
private actor PlaybackObservedMedia: AudioChunkMediaStoreProtocol {
    let base: AudioChunkMediaStore
    var lastReadPCM: Data?
    init(_ base: AudioChunkMediaStore) { self.base = base }
    func persistChunk(_ input: AudioChunkInput, previous: AudioChunkDescriptor?) async throws -> StoredAudioWindow {
        try await base.persistChunk(input, previous: previous)
    }
    func readWindow(_ window: StoredAudioWindow) async throws -> AudioWindowReadLease {
        let lease = try await base.readWindow(window)
        lastReadPCM = lease.pcmData
        return lease
    }
    func release(_ lease: AudioWindowReadLease) async { await base.release(lease) }
    func pendingWindows(limit: Int) async throws -> [StoredAudioWindow] { try await base.pendingWindows(limit: limit) }
    func acknowledgePublished(_ window: StoredAudioWindow) async throws { try await base.acknowledgePublished(window) }
    func deleteAuthorized(windows: [StoredAudioWindow], chunks: [AudioChunkDescriptor]) async throws {
        try await base.deleteAuthorized(windows: windows, chunks: chunks)
    }
    func close() async { await base.close() }
}

private actor PlaybackCompletions {
    var count = 0
    func completed() { count += 1 }
}

private actor PlaybackReadGate: AudioEvidenceStoreProtocol {
    let reader: NativeAudioEvidenceStore
    let entered: XCTestExpectation
    var armed = false
    var continuation: CheckedContinuation<Void, Never>?
    init(reader: NativeAudioEvidenceStore, entered: XCTestExpectation) { self.reader = reader; self.entered = entered }
    func arm() { armed = true }
    func open() { armed = false; continuation?.resume(); continuation = nil }
    func readAudioMedia(_ reference: AudioEvidenceRef) async throws -> AudioEvidenceMediaReadResult {
        let value = try await reader.readAudioMedia(reference)
        if armed {
            entered.fulfill()
            await withCheckedContinuation { continuation = $0 }
        }
        return value
    }
    func searchAudioEvidence(_ request: AudioEvidenceSearchRequest) async throws -> AudioEvidenceSearchPage {
        try await reader.searchAudioEvidence(request)
    }
    func readAudioEvidence(_ reference: AudioEvidenceRef) async throws -> AudioEvidenceReadResult { try await reader.readAudioEvidence(reference) }
    func revalidateAudioEvidence(_ stamp: AudioEvidenceReadStamp, references: [AudioEvidenceRef]) async throws {
        try await reader.revalidateAudioEvidence(stamp, references: references)
    }
    func audioEvidenceCoverage() async throws -> AudioEvidenceCoverage { try await reader.audioEvidenceCoverage() }
    func close() async { open(); await reader.close() }
}

private actor PlaybackPolicy {
    var value = CaptureConfig()
    func change() { value = CaptureConfig(excludedAppBundleIDs: ["authored.policy.change"]) }
}

private struct PlaybackFixture {
    let root: URL
    let db: OpaquePointer
    let queries: AudioTranscriptionQueries
    let reader: NativeAudioEvidenceStore
    let media: AudioChunkMediaStore
    let window: StoredAudioWindow
    let row: Int64
    let reference: AudioEvidenceRef

    static func make(submillisecondOrigin: Bool = false) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-playback-owner-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("fixture.sqlite").path
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = pointer else { throw AudioEvidenceError.integrityFailure }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        try await MigrationRunner(db: db).runMigrations()
        let queries = AudioTranscriptionQueries(db: db)
        let media = AudioChunkMediaStore(storageRoot: root, storeID: try await queries.audioMediaStoreID())
        let start = Date(timeIntervalSince1970: 1_700_000_000 + (submillisecondOrigin ? 0.000_375 : 0))
        let samples = (0..<16_000).map { Int16(sin(Double($0) * 0.06) * 12_000) }
        let pcm = samples.withUnsafeBytes { Data($0) }
        let window = try await media.persistChunk(.init(streamID: UUID(), source: .system,
            origin: start, startFrame: 0, pcmData: pcm), previous: nil)
        let raw = try await queries.registerRawAudioWindow(window)
        let original = try await queries.pendingFirstPassSource(rawBatchID: raw, path: window.relativePath)
        let rows = try await queries.commitFirstPass(rawBatchID: raw, records: [
            (nil, "Cedar exact range", start.addingTimeInterval(submillisecondOrigin ? 0 : 0.25),
             start.addingTimeInterval(submillisecondOrigin ? 0.5 : 0.75),
             .system, 0.9, [], window.relativePath, 1, window.relativePath, "transcribed", "en", "raw", nil)
        ], originalSource: original)
        let reader = try NativeAudioEvidenceStore(connection: SQLiteConnection(readOnlyDatabasePath: path))
        let hits = try await reader.searchAudioEvidence(.init(terms: ["Cedar"]))
        return Self(root: root, db: db, queries: queries, reader: reader, media: media, window: window,
            row: try XCTUnwrap(rows.first), reference: try XCTUnwrap(hits.hits.first?.snapshot.reference))
    }
    func close() async {
        await reader.close(); await media.close()
        sqlite3_close_v2(db)
        try? FileManager.default.removeItem(at: root)
    }
}
