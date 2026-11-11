import Database
import Foundation
import Shared
import SQLCipher
import Storage
import XCTest
@testable import Processing

/// Actual PCM -> AAC -> decoder -> production refinement/SQLite. Authored model
/// output is a controlled boundary; these tests do not measure ASR accuracy.
final class AudioRefinementSourceTests: XCTestCase {
    func testPassTwoKeepsSystemSourceAfterRawPlaceholderRetirement() async throws {
        let fixture = try await makeFixture(source: .system)
        try await fixture.queries.retireRawBatchAfterTranscription(id: fixture.rawID)
        let service = OriginalSourceTranscript()
        let manager = AudioRefinementManager(transcriptionService: service,
            transcriptionQueries: fixture.queries, audioWriter: fixture.writer, storageRoot: fixture.root)
        let result = await manager.processAllPendingRefinements(maxBatches: 1)
        XCTAssertEqual(result.refinedCount, 1)
        let rows = try await fixture.currentRows()
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.source == .system && $0.transcriptionPass == 2 })
        XCTAssertTrue(rows.allSatisfy { $0.batchAudioPath == fixture.path })
    }

    func testPassTwoKeepsMicrophoneSource() async throws {
        let fixture = try await makeFixture(source: .microphone)
        let manager = AudioRefinementManager(transcriptionService: OriginalSourceTranscript(),
            transcriptionQueries: fixture.queries, audioWriter: fixture.writer, storageRoot: fixture.root)
        let result = await manager.processAllPendingRefinements(maxBatches: 1)
        XCTAssertEqual(result.refinedCount, 1)
        let rows = try await fixture.currentRows()
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.source == .microphone && $0.transcriptionPass == 2 })
    }

    func testPassThreeUsesOriginalSystemSourceRatherThanMislabeledRefinedSource() async throws {
        let fixture = try await makeFixture(source: .system)
        try await fixture.queries.retireRawBatchAfterTranscription(id: fixture.rawID)
        _ = try await fixture.insert(pass: 2, source: .microphone)
        try await fixture.insertNeighbor()
        let manager = AudioContextualRefinementManager(transcriptionService: OriginalSourceTranscript(),
            transcriptionQueries: fixture.queries, audioWriter: fixture.writer, storageRoot: fixture.root)
        let result = await manager.processAllPendingRefinements(runMode: .manual, maxBatches: 1)
        XCTAssertEqual(result.refinedCount, 1)
        let rows = try await fixture.currentRows()
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.source == .system && $0.transcriptionPass == 3 })
    }

    func testConflictingOriginalCandidateDoesNotInvokeModelOrRewriteHistory() async throws {
        let fixture = try await makeFixture(source: .system)
        _ = try await fixture.insert(pass: 1, source: .microphone)
        let before = try await fixture.database.refinementSourceFixtureRows()
        let service = OriginalSourceTranscript()
        let manager = AudioRefinementManager(transcriptionService: service,
            transcriptionQueries: fixture.queries, audioWriter: fixture.writer, storageRoot: fixture.root)
        let result = await manager.processAllPendingRefinements(maxBatches: 1)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.refinedCount, 0)
        let calls = await service.calls
        let after = try await fixture.database.refinementSourceFixtureRows()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(after, before)
    }

    func testPassThreeWithoutOriginalReceiptDoesNotUseLatestLabel() async throws {
        let fixture = try await makeFixture(source: .system, insertRaw: false, insertPassOne: false)
        _ = try await fixture.insert(pass: 2, source: .microphone)
        try await fixture.insertNeighbor()
        let before = try await fixture.database.refinementSourceFixtureRows()
        let service = OriginalSourceTranscript()
        let manager = AudioContextualRefinementManager(transcriptionService: service,
            transcriptionQueries: fixture.queries, audioWriter: fixture.writer, storageRoot: fixture.root)
        let result = await manager.processAllPendingRefinements(runMode: .manual, maxBatches: 1)
        let calls = await service.calls
        let after = try await fixture.database.refinementSourceFixtureRows()
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.refinedCount, 0)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(after, before)
    }

    func testDeleteWhilePassTwoModelWorksCannotPublishNewRows() async throws {
        let fixture = try await makeFixture(source: .system)
        let service = OriginalSourceTranscript(onFirstRequest: {
            _ = try await fixture.queries.deleteTranscription(id: fixture.rawID)
        })
        let manager = AudioRefinementManager(transcriptionService: service,
            transcriptionQueries: fixture.queries, audioWriter: fixture.writer, storageRoot: fixture.root)
        let result = await manager.processAllPendingRefinements(maxBatches: 1)
        XCTAssertEqual(result.refinedCount, 0)
        XCTAssertEqual(result.failedCount, 1)
        let rows = try await fixture.currentRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.transcriptionPass, 1)
        XCTAssertEqual(rows.first?.transcriptStatus, "transcribed")
    }

    func testResetWhileContextualModelWorksRejectsSourceReceipt() async throws {
        let fixture = try await makeFixture(source: .system)
        _ = try await fixture.insert(pass: 2, source: .system, pipeline: CURRENT_PIPELINE_VERSION - 1)
        try await fixture.insertNeighbor()
        let service = OriginalSourceTranscript(onFirstRequest: {
            _ = try await fixture.queries.resetStalePipelineRecords()
        })
        let manager = AudioContextualRefinementManager(transcriptionService: service,
            transcriptionQueries: fixture.queries, audioWriter: fixture.writer, storageRoot: fixture.root)
        let result = await manager.processAllPendingRefinements(runMode: .manual, maxBatches: 1)
        XCTAssertEqual(result.refinedCount, 0)
        XCTAssertEqual(result.failedCount, 1)
        let rows = try await fixture.currentRows()
        XCTAssertTrue(rows.allSatisfy { $0.transcriptionPass == 1 })
        XCTAssertTrue(rows.allSatisfy { $0.transcriptStatus == "transcribed" })
    }

    func testCancelledModelDoesNotRetireOrRelabelOriginalHistory() async throws {
        let fixture = try await makeFixture(source: .system)
        let before = try await fixture.database.refinementSourceFixtureRows()
        let service = OriginalSourceTranscript(onFirstRequest: { throw CancellationError() })
        let manager = AudioRefinementManager(transcriptionService: service,
            transcriptionQueries: fixture.queries, audioWriter: fixture.writer, storageRoot: fixture.root)
        let result = await manager.processAllPendingRefinements(maxBatches: 1)
        let after = try await fixture.database.refinementSourceFixtureRows()
        XCTAssertEqual(result.refinedCount, 0)
        XCTAssertEqual(after, before)
    }

    func testPassTwoPagesPastUnavailableLegacyPrefixBeforeModelLimit() async throws {
        let fixture = try await makeFixture(source: .system, legacyCount: 12)
        let before = try await fixture.database.refinementSourceFixtureRows()
        let service = OriginalSourceTranscript()
        let manager = AudioRefinementManager(transcriptionService: service,
            transcriptionQueries: fixture.queries, audioWriter: fixture.writer, storageRoot: fixture.root)
        let result = await manager.processAllPendingRefinements(maxBatches: 1)
        let after = try await fixture.database.refinementSourceFixtureRows()
        let rows = try await fixture.currentRows()
        XCTAssertEqual(result.refinedCount, 1)
        XCTAssertEqual(result.failedCount, 12)
        XCTAssertEqual(Array(after.prefix(12)), Array(before.prefix(12)))
        XCTAssertEqual(rows.first?.source, .system)
        XCTAssertEqual(rows.first?.transcriptionPass, 2)
    }

    func testPassThreePagesPastUnavailableLegacyPrefixBeforeModelLimit() async throws {
        let fixture = try await makeFixture(source: .system, legacyCount: 12, legacyPass: 2)
        _ = try await fixture.insert(pass: 2, source: .microphone)
        let before = try await fixture.database.refinementSourceFixtureRows()
        let manager = AudioContextualRefinementManager(transcriptionService: OriginalSourceTranscript(),
            transcriptionQueries: fixture.queries, audioWriter: fixture.writer, storageRoot: fixture.root)
        let result = await manager.processAllPendingRefinements(runMode: .manual, maxBatches: 1)
        let after = try await fixture.database.refinementSourceFixtureRows()
        let rows = try await fixture.currentRows()
        XCTAssertEqual(result.refinedCount, 1)
        XCTAssertEqual(result.failedCount, 12)
        XCTAssertEqual(Array(after.prefix(12)), Array(before.prefix(12)))
        XCTAssertEqual(rows.first?.source, .system)
        XCTAssertEqual(rows.first?.transcriptionPass, 3)
    }

    func testPassTwoResumesBoundedInspectionAcrossAutomaticSizeCycles() async throws {
        let fixture = try await makeFixture(source: .system, legacyCount: 257)
        let service = OriginalSourceTranscript()
        let manager = AudioRefinementManager(transcriptionService: service,
            transcriptionQueries: fixture.queries, audioWriter: fixture.writer, storageRoot: fixture.root)
        let first = await manager.processAllPendingRefinements(maxBatches: 1)
        let firstCalls = await service.calls
        XCTAssertEqual(first.refinedCount, 0)
        XCTAssertEqual(first.failedCount, 256)
        XCTAssertEqual(firstCalls, 0)
        let second = await manager.processAllPendingRefinements(maxBatches: 1)
        XCTAssertEqual(second.failedCount, 1)
        XCTAssertEqual(second.refinedCount, 1)
    }

    func testPassThreeResumesBoundedInspectionAcrossAutomaticSizeCycles() async throws {
        let fixture = try await makeFixture(source: .system, legacyCount: 257, legacyPass: 2)
        _ = try await fixture.insert(pass: 2, source: .system)
        let service = OriginalSourceTranscript()
        let manager = AudioContextualRefinementManager(transcriptionService: service,
            transcriptionQueries: fixture.queries, audioWriter: fixture.writer, storageRoot: fixture.root)
        let first = await manager.processAllPendingRefinements(runMode: .manual, maxBatches: 1)
        let firstCalls = await service.calls
        XCTAssertEqual(first.refinedCount, 0)
        XCTAssertEqual(first.failedCount, 256)
        XCTAssertEqual(firstCalls, 0)
        let second = await manager.processAllPendingRefinements(runMode: .manual, maxBatches: 1)
        XCTAssertEqual(second.failedCount, 1)
        XCTAssertEqual(second.refinedCount, 1)
    }

    func testPassTwoCancellationReturningEmptyModelOutputDoesNotRetireHistory() async throws {
        let fixture = try await makeFixture(source: .system)
        let before = try await fixture.database.refinementSourceFixtureRows()
        let service = OriginalSourceTranscript(text: "", onFirstRequest: {
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let manager = AudioRefinementManager(transcriptionService: service,
            transcriptionQueries: fixture.queries, audioWriter: fixture.writer, storageRoot: fixture.root)
        let task = Task { await manager.processAllPendingRefinements(maxBatches: 1) }
        let result = await task.value
        let after = try await fixture.database.refinementSourceFixtureRows()
        XCTAssertEqual(result.silenceCount, 0)
        XCTAssertEqual(result.refinedCount, 0)
        XCTAssertEqual(after, before)
    }

    func testPassThreeCancellationReturningEmptyModelOutputDoesNotRetireHistory() async throws {
        let fixture = try await makeFixture(source: .system)
        _ = try await fixture.insert(pass: 2, source: .system)
        try await fixture.insertNeighbor()
        let before = try await fixture.database.refinementSourceFixtureRows()
        let service = OriginalSourceTranscript(text: "", onFirstRequest: {
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let manager = AudioContextualRefinementManager(transcriptionService: service,
            transcriptionQueries: fixture.queries, audioWriter: fixture.writer, storageRoot: fixture.root)
        let task = Task { await manager.processAllPendingRefinements(runMode: .manual, maxBatches: 1) }
        let result = await task.value
        let after = try await fixture.database.refinementSourceFixtureRows()
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.refinedCount, 0)
        XCTAssertEqual(after, before)
    }

    func testPassTwoDeduplicatesUnavailablePathsWithinBoundedInspection() async throws {
        let fixture = try await makeFixture(source: .system, legacyCount: 1, legacyCopies: 12)
        let manager = AudioRefinementManager(transcriptionService: OriginalSourceTranscript(),
            transcriptionQueries: fixture.queries, audioWriter: fixture.writer, storageRoot: fixture.root)
        let result = await manager.processAllPendingRefinements(maxBatches: 1)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.refinedCount, 1)
    }

    func testPassThreeDeduplicatesUnavailablePathsWithinBoundedInspection() async throws {
        let fixture = try await makeFixture(source: .system, legacyCount: 1, legacyPass: 2, legacyCopies: 12)
        _ = try await fixture.insert(pass: 2, source: .system)
        let manager = AudioContextualRefinementManager(transcriptionService: OriginalSourceTranscript(),
            transcriptionQueries: fixture.queries, audioWriter: fixture.writer, storageRoot: fixture.root)
        let result = await manager.processAllPendingRefinements(runMode: .manual, maxBatches: 1)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.refinedCount, 1)
    }

    private struct Fixture: Sendable {
        let database: DatabaseManager
        let queries: AudioTranscriptionQueries
        let writer: AudioSegmentWriter
        let root: URL
        let path: String
        let start: Date
        let rawID: Int64
        func currentRows() async throws -> [AudioTranscription] {
            try await queries.getTranscriptions(from: start, to: start.addingTimeInterval(3), limit: 20)
        }
        @discardableResult
        func insert(pass: Int, source: AudioSource, pipeline: Int = CURRENT_PIPELINE_VERSION) async throws -> Int64 {
            try await queries.insertTranscription(sessionID: nil,
                text: "Cedar proposal needs approval tomorrow", startTime: start,
                endTime: start.addingTimeInterval(2), source: source, confidence: 0.95, words: [],
                audioPath: path, transcriptionPass: pass, batchAudioPath: path, pipelineVersion: pipeline)
        }
        func insertNeighbor() async throws {
            _ = try await queries.insertTranscription(sessionID: nil,
                text: "Yesterday the Cedar team discussed the proposal", startTime: start.addingTimeInterval(-10),
                endTime: start.addingTimeInterval(-8), source: .system, confidence: 0.95, words: [],
                audioPath: "audio/neighbor.m4a", transcriptionPass: 3, batchAudioPath: "audio/neighbor.m4a")
        }
    }

    private func makeFixture(source: AudioSource, insertRaw: Bool = true, insertPassOne: Bool = true,
        legacyCount: Int = 0, legacyPass: Int = 1, legacyCopies: Int = 1) async throws -> Fixture {
        let database = DatabaseManager(databasePath: "file:refinement-source-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("refinement-source-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? await database.close(); try? FileManager.default.removeItem(at: root) }
        let pointer = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(pointer))
        let writer = AudioSegmentWriter(storageRoot: root)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<legacyCount {
            let legacyPath = "audio/legacy_\(index).m4a"
            let legacyStart = start.addingTimeInterval(Double(index - legacyCount) * 3)
            for _ in 0..<legacyCopies {
            _ = try await queries.insertTranscription(sessionID: nil,
                text: "Legacy Cedar discussion needs approval \(index)", startTime: legacyStart,
                endTime: legacyStart.addingTimeInterval(2), source: .system, confidence: 0.95, words: [],
                audioPath: legacyPath, transcriptionPass: legacyPass, batchAudioPath: legacyPath)
            }
        }
        let samples = (0..<32_000).map { i in Int16(8_000 * sin(Double(i) * 2 * .pi * 220 / 16_000)) }
        let pcm = samples.withUnsafeBytes { Data($0) }
        let saved = try await writer.writeFullBatch(audioData: pcm, sampleRate: 16_000, channels: 1,
            timestamp: start, source: source)
        let rawID: Int64
        if insertRaw {
            rawID = try await queries.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(2),
                source: source, audioPath: saved.filePath, audioSize: saved.fileSize)
        } else { rawID = 0 }
        let fixture = Fixture(database: database, queries: queries, writer: writer, root: root,
            path: saved.filePath, start: start, rawID: rawID)
        if insertPassOne { _ = try await fixture.insert(pass: 1, source: source) }
        return fixture
    }
}

private actor OriginalSourceTranscript: TranscriptionProtocol {
    private let onFirstRequest: (@Sendable () async throws -> Void)?
    private let text: String
    private(set) var calls = 0
    init(text: String = "Cedar proposal needs approval tomorrow", onFirstRequest: (@Sendable () async throws -> Void)? = nil) {
        self.text = text; self.onFirstRequest = onFirstRequest
    }
    func initialize() {}
    func cleanup() {}
    func transcribe(_ data: Data) -> TranscriptionResult { .init(text: text, language: "en", duration: 2) }
    func transcribeWithTimestamps(_ data: Data, wordLevel: Bool, initialPrompt: String?) async throws -> DetailedTranscriptionResult {
        calls += 1
        if calls == 1 { try await onFirstRequest?() }
        let words = text.split(separator: " ").enumerated().map { index, word in
            TranscriptionWord(word: String(word), start: Double(index) * 0.35,
                end: Double(index + 1) * 0.35, confidence: 0.95)
        }
        return .init(text: text, words: words, language: "en", duration: 2)
    }
}

private extension DatabaseManager {
    func refinementSourceFixtureRows() throws -> [String] {
        let pointer = try XCTUnwrap(getConnection())
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(pointer,
            "SELECT id||'|'||text||'|'||source||'|'||transcription_pass||'|'||pipeline_version||'|'||transcript_status||'|'||COALESCE(quality_flags,'') FROM audio_captures ORDER BY id",
            -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(String(cString: sqlite3_column_text(statement, 0))) }
        return rows
    }
}
