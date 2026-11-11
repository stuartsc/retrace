import CryptoKit
import Foundation
import Shared
import SQLCipher
import Storage
import XCTest
@testable import Database

/// Real AAC receipts and private SQLite writer/reader transactions. These tests
/// prove registration and exact identity fences, not recognition accuracy.
final class AudioChunkMediaPersistenceTests: XCTestCase {
    private var directory: URL!
    private var databasePath: String!
    private var writer: OpaquePointer!
    private var queries: AudioTranscriptionQueries!
    private var reader: NativeAudioEvidenceStore!
    private var media: (any AudioChunkMediaStoreProtocol)!
    private var storeID: UUID!
    private let origin = Date(timeIntervalSince1970: 1_700_000_000.125)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-chunk-database-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databasePath = directory.appendingPathComponent("authored.sqlite").path
        XCTAssertEqual(sqlite3_open_v2(databasePath, &writer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        try sql("PRAGMA journal_mode=WAL")
        try await MigrationRunner(db: writer).runMigrations()
        queries = AudioTranscriptionQueries(db: writer)
        storeID = try await queries.audioMediaStoreID()
        reader = try NativeAudioEvidenceStore(connection: SQLiteConnection(readOnlyDatabasePath: databasePath))
        media = AudioChunkMediaStore(storageRoot: directory, storeID: storeID)
    }

    override func tearDown() async throws {
        await media?.close(); media = nil
        await reader?.close(); reader = nil; queries = nil
        if let writer { XCTAssertEqual(sqlite3_close_v2(writer), SQLITE_OK) }
        writer = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testTwoOverlappingWindowsShareEncodedChunkAndRecoverThroughPendingIndex() async throws {
        let (first, second) = try await windows()
        let firstID = try await queries.registerRawAudioWindow(first, sessionID: "Cedar 🦘's review")
        let secondID = try await queries.registerRawAudioWindow(second, probableSilenceHint: true)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_media_chunk"), 2)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_media_window"), 2)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_media_window_range"), 3)
        let pending = try await queries.getUntranscribedBatches(limit: 16)
        XCTAssertEqual(pending.map(\.id), [firstID, secondID])
        XCTAssertEqual(pending.map(\.probableSilenceHint), [false, true])
        expectEqual(try await queries.getUntranscribedBatchCount(), 2)
        expectEqual(try await queries.storedAudioWindow(forPath: second.relativePath), second)
        XCTAssertEqual(try text("SELECT session_id FROM audio_captures WHERE id=\(firstID)"), "Cedar 🦘's review")
    }

    func testIdenticalRegistrationReplaySurvivesFirstPassRetirementWithoutNewRows() async throws {
        let window = try await windows().0
        let raw = try await queries.registerRawAudioWindow(window)
        expectEqual(try await queries.registerRawAudioWindow(window), raw)
        let receipt = try await queries.pendingFirstPassSource(rawBatchID: raw, path: window.relativePath)
        let ids = try await queries.commitFirstPass(rawBatchID: raw,
            records: [record(window, text: "Cedar invoice 402")], originalSource: receipt)
        XCTAssertEqual(ids.count, 1)
        expectEqual(try await queries.registerRawAudioWindow(window), raw)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_captures WHERE batch_audio_path IS NULL"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_media_window"), 1)
        expectEqual(try await queries.storedAudioWindow(forPath: window.relativePath), window)
    }

    func testRegistrationFailureRollsBackRawSourceChunksAndRangesTogether() async throws {
        let window = try await windows().1
        try sql("""
            CREATE TRIGGER authored_window_failure BEFORE INSERT ON audio_media_window_range
            WHEN NEW.ordinal=1 BEGIN SELECT RAISE(ABORT,'authored final range failure'); END
            """)
        await assertFails { _ = try await self.queries.registerRawAudioWindow(window) }
        for table in ["audio_captures", "audio_original_source", "audio_media_chunk", "audio_media_window", "audio_media_window_range"] {
            XCTAssertEqual(try scalar("SELECT COUNT(*) FROM \(table)"), 0, table)
        }
        try sql("DROP TRIGGER authored_window_failure")
        _ = try await queries.registerRawAudioWindow(window)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_media_window_range"), 2)
    }

    func testConflictingManifestAndStoreIdentityCannotReplaceRegisteredWindow() async throws {
        let window = try await windows().0
        _ = try await queries.registerRawAudioWindow(window)
        let changed = StoredAudioWindow(manifest: window.manifest, relativePath: window.relativePath,
            manifestSHA256: String(repeating: "a", count: 64), manifestBytes: window.manifestBytes)
        await assertFails { _ = try await self.queries.registerRawAudioWindow(changed) }
        let foreign = AudioChunkMediaStore(storageRoot: directory.appendingPathComponent("foreign"), storeID: UUID())
        let other = try await foreign.persistChunk(input(startFrame: 0), previous: nil)
        await assertFails { _ = try await self.queries.registerRawAudioWindow(other) }
        await foreign.close()
        expectEqual(try await queries.storedAudioWindow(forPath: window.relativePath), window)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_media_window"), 1)
    }

    func testMissingNewManifestFailsClosedWhileLegacyMediaRemainsReadable() async throws {
        let window = try await windows().0
        await assertFails { _ = try await self.queries.storedAudioWindow(forPath: window.relativePath) }
        let legacy = "audio/batch_1700000000125_system_legacy.m4a"
        _ = try await queries.insertRawBatch(startTime: origin, endTime: origin.addingTimeInterval(10),
            source: .system, audioPath: legacy, audioSize: 4096)
        expectNil(try await queries.storedAudioWindow(forPath: legacy))
        expectEqual(try await queries.getUntranscribedBatchCount(), 1)
    }

    func testExactMediaReadUsesV30ReferenceAndRejectsRevisionSubstitution() async throws {
        let window = try await windows().1
        let raw = try await queries.registerRawAudioWindow(window)
        let receipt = try await queries.pendingFirstPassSource(rawBatchID: raw, path: window.relativePath)
        let row = try unwrap(try await queries.commitFirstPass(rawBatchID: raw,
            records: [record(window, text: "Cedar invoice 402")], originalSource: receipt).first)
        let selected = try await queries.getTranscriptions(from: origin.addingTimeInterval(-1), to: origin.addingTimeInterval(40))
        let reference = try XCTUnwrap(selected.first?.evidenceReference)
        let initial = try await reader.readAudioMedia(reference)
        guard case .available(let media, let snapshot, let stamp) = initial else { return XCTFail("Registered exact media must resolve") }
        XCTAssertEqual(media, window)
        XCTAssertEqual(snapshot.reference, reference)
        try await reader.revalidateAudioEvidence(stamp, references: [reference])
        try await queries.updateTranscriptionText(id: row, text: "Birch invoice 402")
        guard case .unavailable(.revisionUnavailable) = try await reader.readAudioMedia(reference) else {
            return XCTFail("An old transcript reference must not select a changed row")
        }
    }

    func testContextOnlyTranscriptAndUnregisteredMediaPathCannotBePublished() async throws {
        let window = try await windows().1
        let raw = try await queries.registerRawAudioWindow(window)
        let receipt = try await queries.pendingFirstPassSource(rawBatchID: raw, path: window.relativePath)
        var context = record(window, text: "Already owned by the previous chunk")
        context.startTime = window.manifest.startTime
        context.endTime = context.startTime.addingTimeInterval(1)
        let capturedContext = context
        await assertFails { _ = try await self.queries.commitFirstPass(rawBatchID: raw,
            records: [capturedContext], originalSource: receipt) }
        var wrongMedia = record(window, text: "Cedar wrong file")
        wrongMedia.audioPath = "audio/batch_1700000000125_unrelated.m4a"
        let capturedWrongMedia = wrongMedia
        await assertFails { _ = try await self.queries.commitFirstPass(rawBatchID: raw,
            records: [capturedWrongMedia], originalSource: receipt) }
        expectEqual(try await queries.getUntranscribedBatchCount(), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_evidence_snapshot"), 0)
        _ = try await queries.commitFirstPass(rawBatchID: raw,
            records: [record(window, text: "Cedar current ownership")], originalSource: receipt)
    }

    func testMediaReadRejectsDeletionWhileAwaitingMetricDelivery() async throws {
        let window = try await windows().0
        let row = try await publish(window, text: "Cedar held media read")
        let page = try await reader.searchAudioEvidence(.init(terms: ["Cedar"]))
        let reference = try XCTUnwrap(page.hits.first?.snapshot.reference)
        let gate = AudioChunkReadGate()
        let held = try NativeAudioEvidenceStore(connection: SQLiteConnection(readOnlyDatabasePath: databasePath), metric: { operation, _ in
            if operation == "media" { await gate.hold() }
        })
        let reading = Task { try await held.readAudioMedia(reference) }
        await gate.waitUntilHeld()
        _ = try await queries.deleteTranscription(id: row)
        await gate.release()
        do { _ = try await reading.value; XCTFail("Deleted media must not escape an awaiting read") }
        catch AudioEvidenceError.dataChanged { }
        await held.close()
    }

    func testRegisteredMetadataCannotBeMutatedOrRemovedInPlace() async throws {
        let window = try await windows().1
        _ = try await queries.registerRawAudioWindow(window)
        for statement in [
            "UPDATE audio_media_chunk SET descriptorJSON='{}'",
            "UPDATE audio_media_window SET manifestSHA256='" + String(repeating: "a", count: 64) + "'",
            "UPDATE audio_media_window_range SET offsetFrames=0 WHERE ordinal=0",
            "DELETE FROM audio_media_chunk", "DELETE FROM audio_media_window_range", "DELETE FROM audio_media_window"
        ] {
            XCTAssertNotEqual(sqlite3_exec(writer, statement, nil, nil, nil), SQLITE_OK, statement)
        }
        expectEqual(try await queries.storedAudioWindow(forPath: window.relativePath), window)
    }

    func testDifferentChunkIdentitiesCannotDuplicateAnAlreadyRegisteredSampleRange() async throws {
        let originalInput = input(startFrame: 0)
        let first = try await media.persistChunk(originalInput, previous: nil)
        _ = try await queries.registerRawAudioWindow(first)
        let duplicate = try await media.persistChunk(input(startFrame: 0, streamID: originalInput.streamID), previous: nil)
        await assertFails { _ = try await self.queries.registerRawAudioWindow(duplicate) }
        // Submit a false overlapping chronological claim for the actual second
        // AAC receipt. Storage correctly refuses to create this stream shape;
        // the database must independently refuse its registration as well.
        let encoded = try XCTUnwrap(duplicate.manifest.ranges.first?.chunk)
        let shifted = AudioChunkDescriptor(storeID: encoded.storeID, id: encoded.id,
            streamID: encoded.streamID, source: encoded.source, origin: encoded.origin,
            startFrame: 80_000, frameCount: encoded.frameCount, relativePath: encoded.relativePath,
            encodedBytes: encoded.encodedBytes, encodedSHA256: encoded.encodedSHA256,
            originalPCMSHA256: encoded.originalPCMSHA256, decodedPCMSHA256: encoded.decodedPCMSHA256,
            validFrames: encoded.validFrames, primingFrames: encoded.primingFrames,
            remainderFrames: encoded.remainderFrames, packetCount: encoded.packetCount,
            framesPerPacket: encoded.framesPerPacket, trackStartSeconds: encoded.trackStartSeconds)
        let claimed = AudioWindowManifest(storeID: encoded.storeID, id: encoded.id, streamID: encoded.streamID,
            source: encoded.source, origin: encoded.origin, startFrame: 80_000, frameCount: encoded.frameCount,
            ownedStartFrame: 0, ranges: [.init(chunk: shifted, offsetFrames: 0, frameCount: encoded.frameCount)])
        let bytes = try AudioChunkMediaValidation.encodedManifestData(claimed)
        let overlap = StoredAudioWindow(manifest: claimed, relativePath: duplicate.relativePath,
            manifestSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), manifestBytes: Int64(bytes.count))
        await assertFails { _ = try await self.queries.registerRawAudioWindow(overlap) }
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_media_chunk"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_media_window"), 1)
    }

    func testRegistrationPreservesNonBinarySubMillisecondOriginInManifestHash() async throws {
        let preciseOrigin = Date(timeIntervalSinceReferenceDate: 812_345_678.1234567)
        let window = try await media.persistChunk(input(startFrame: 0, origin: preciseOrigin), previous: nil)
        _ = try await queries.registerRawAudioWindow(window)
        let recovered = try unwrap(try await queries.storedAudioWindow(forPath: window.relativePath))
        XCTAssertEqual(recovered.manifest.origin, preciseOrigin)
        XCTAssertEqual(recovered, window)
        XCTAssertEqual(try AudioChunkMediaValidation.encodedManifestData(recovered.manifest),
            try AudioChunkMediaValidation.encodedManifestData(window.manifest))
    }

    func testCommittedDeletionBeforeJournalAcknowledgementDoesNotResurrectOrBlockRecovery() async throws {
        let window = try await media.persistChunk(input(startFrame: 0), previous: nil)
        let raw = try await queries.registerRawAudioWindow(window)
        expectEqual(try await media.pendingWindows(limit: 16), [window])
        expectEqual(try await queries.isAudioWindowCanonicallyDeleted(window), false)
        _ = try await queries.deleteTranscription(id: raw)
        await assertFails { _ = try await self.queries.registerRawAudioWindow(window) }
        expectEqual(try await queries.isAudioWindowCanonicallyDeleted(window), true)

        // The proof permits acknowledging only the pending publication journal.
        // Original AAC and manifest bytes remain readable for shared references.
        try await media.acknowledgePublished(window)
        expectEqual(try await media.pendingWindows(limit: 16), [])
        let retained = try await media.readWindow(window)
        XCTAssertEqual(retained.pcmData.count, Int(window.manifest.frameCount) * 2)
        await media.release(retained)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_media_chunk"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_media_window"), 1)

        let unknown = try await media.persistChunk(input(startFrame: 0), previous: nil)
        expectEqual(try await queries.isAudioWindowCanonicallyDeleted(unknown), false)
        let changed = StoredAudioWindow(manifest: window.manifest, relativePath: window.relativePath,
            manifestSHA256: String(repeating: "a", count: 64), manifestBytes: window.manifestBytes)
        await assertFails { _ = try await self.queries.isAudioWindowCanonicallyDeleted(changed) }
    }

    func testDeletingOneWindowInvalidatesItsExactMediaButKeepsSharedSuccessor() async throws {
        let (first, second) = try await windows()
        let firstRow = try await publish(first, text: "Cedar first recording")
        _ = try await publish(second, text: "Cedar successor recording")
        let before = try await reader.searchAudioEvidence(.init(terms: ["Cedar"]))
        XCTAssertEqual(before.hits.count, 2)
        let firstReference = try XCTUnwrap(before.hits.first { $0.snapshot.text == "Cedar first recording" }?.snapshot.reference)
        let secondReference = try XCTUnwrap(before.hits.first { $0.snapshot.text == "Cedar successor recording" }?.snapshot.reference)
        _ = try await queries.deleteTranscription(id: firstRow)
        await assertFails { _ = try await self.queries.registerRawAudioWindow(first) }
        await assertFails { _ = try await self.queries.storedAudioWindow(forPath: first.relativePath) }
        guard case .unavailable(.evidenceDeleted) = try await reader.readAudioMedia(firstReference) else {
            return XCTFail("Deleted window must be unavailable")
        }
        guard case .available(let kept, _, _) = try await reader.readAudioMedia(secondReference) else {
            return XCTFail("Shared chunk does not make the successor evidence deleted")
        }
        XCTAssertEqual(kept, second)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_media_chunk"), 2)
        let lease = try await media.readWindow(second)
        XCTAssertEqual(lease.pcmData.count, Int(second.manifest.frameCount) * MemoryLayout<Int16>.size)
        await media.release(lease)
    }

    func testDirectSQLTombstoneBlocksPendingCommitAndWindowReplay() async throws {
        let window = try await windows().0
        let raw = try await queries.registerRawAudioWindow(window)
        let receipt = try await queries.pendingFirstPassSource(rawBatchID: raw, path: window.relativePath)
        try sql("INSERT INTO audio_original_source_tombstone(batchAudioPath) VALUES('\(window.relativePath)')")
        await assertFails { _ = try await self.queries.commitFirstPass(rawBatchID: raw,
            records: [self.record(window, text: "Must never publish")], originalSource: receipt) }
        await assertFails { _ = try await self.queries.registerRawAudioWindow(window) }
        await assertFails { _ = try await self.queries.storedAudioWindow(forPath: window.relativePath) }
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_evidence_snapshot"), 0)
    }

    func testRestartReopensSameRegistrationAndExactPendingSource() async throws {
        let window = try await windows().1
        let raw = try await queries.registerRawAudioWindow(window)
        let original = try await queries.pendingFirstPassSource(rawBatchID: raw, path: window.relativePath)
        await reader.close(); reader = nil; queries = nil
        XCTAssertEqual(sqlite3_close_v2(writer), SQLITE_OK); writer = nil
        XCTAssertEqual(sqlite3_open_v2(databasePath, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        queries = AudioTranscriptionQueries(db: writer)
        reader = try NativeAudioEvidenceStore(connection: SQLiteConnection(readOnlyDatabasePath: databasePath))
        expectEqual(try await queries.registerRawAudioWindow(window), raw)
        expectEqual(try await queries.pendingFirstPassSource(rawBatchID: raw, path: window.relativePath), original)
        expectEqual(try await queries.storedAudioWindow(forPath: window.relativePath), window)
    }

    func testRegistrationRefusesBorrowedTransactionAndCancelledPermit() async throws {
        let window = try await windows().0
        try sql("BEGIN IMMEDIATE")
        await assertFails { _ = try await self.queries.registerRawAudioWindow(window) }
        XCTAssertEqual(sqlite3_get_autocommit(writer), 0)
        try sql("ROLLBACK")
        let permit = BackgroundProcessingPermit(threadCount: 2)
        permit.cancellation.cancel()
        do {
            _ = try await BackgroundProcessingContext.$permit.withValue(permit) {
                try await self.queries.registerRawAudioWindow(window)
            }
            XCTFail("Cancellation must not admit a partially registered recording")
        } catch is CancellationError { }
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM audio_media_window"), 0)
    }

    private func windows() async throws -> (StoredAudioWindow, StoredAudioWindow) {
        let firstInput = input(startFrame: 0)
        let first = try await media.persistChunk(firstInput, previous: nil)
        let secondInput = input(startFrame: 160_000, streamID: firstInput.streamID)
        let second = try await media.persistChunk(secondInput, previous: first.manifest.ranges.last?.chunk)
        return (first, second)
    }

    private func input(startFrame: Int64, streamID: UUID = UUID(), origin: Date? = nil) -> AudioChunkInput {
        var samples = (0..<160_000).map { index in
            Int16((sin(Double(index) * 2 * .pi * 440 / 16_000) * 8_000).rounded())
        }
        let bytes = samples.withUnsafeMutableBytes { Data($0) }
        return .init(streamID: streamID, source: .system, origin: origin ?? self.origin, startFrame: startFrame, pcmData: bytes)
    }

    private func publish(_ window: StoredAudioWindow, text: String) async throws -> Int64 {
        let raw = try await queries.registerRawAudioWindow(window)
        let receipt = try await queries.pendingFirstPassSource(rawBatchID: raw, path: window.relativePath)
        return try unwrap(try await queries.commitFirstPass(rawBatchID: raw,
            records: [record(window, text: text)], originalSource: receipt).first)
    }

    private func record(_ window: StoredAudioWindow, text: String) -> AudioTranscriptionQueries.TranscriptionBatchRecord {
        (nil, text, window.manifest.ownedStartTime, window.manifest.ownedStartTime.addingTimeInterval(2),
         .system, 0.9, [], window.relativePath, 1, window.relativePath, "transcribed", "en", "raw", nil)
    }

    private func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs, rhs, file: file, line: line)
    }

    private func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(value, file: file, line: line)
    }

    private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    private func assertFails(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Operation should fail closed", file: file, line: line) }
        catch { }
    }

    private func sql(_ query: String) throws {
        let result = sqlite3_exec(writer, query, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw NSError(domain: "AuthoredAudioChunkSQL", code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(writer))])
        }
    }

    private func scalar(_ query: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(writer, query, -1, &statement, nil) == SQLITE_OK else { throw AudioEvidenceError.integrityFailure }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw AudioEvidenceError.integrityFailure }
        return sqlite3_column_int64(statement, 0)
    }

    private func text(_ query: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(writer, query, -1, &statement, nil) == SQLITE_OK else { throw AudioEvidenceError.integrityFailure }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw AudioEvidenceError.integrityFailure }
        return String(cString: value)
    }
}

private actor AudioChunkReadGate {
    private var held = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        held = true
        let waiting = observers; observers.removeAll()
        for observer in waiting { observer.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }
    func waitUntilHeld() async {
        if !held { await withCheckedContinuation { observers.append($0) } }
    }
    func release() {
        releaseContinuation?.resume(); releaseContinuation = nil
    }
}
