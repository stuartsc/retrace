import Database
import Foundation
import Shared
import SQLCipher
import Storage
import XCTest
@testable import Processing

/// Real PCM -> audio writer -> production quality gate -> SQLite commit.
/// The transcription service supplies authored words; this is not ASR accuracy proof.
final class AudioTranscriptionCommitTests: XCTestCase {
    func testReceiptUsesOriginalAudioDatesAndFollowsDurableAcceptedRows() async throws {
        let run = try await runFixture(text: "Cedar proposal needs approval tomorrow", failInsert: false)
        XCTAssertEqual(run.receipts.count, 1)
        let receipt = try XCTUnwrap(run.receipts.first)
        XCTAssertTrue(receipt.acceptedTranscription)
        XCTAssertEqual(receipt.startedAt, run.startedAt)
        XCTAssertEqual(receipt.endedAt.timeIntervalSince(run.startedAt), 1, accuracy: 0.001)
        XCTAssertEqual(receipt.source, .microphone)
        XCTAssertGreaterThan(run.rowCounts.first ?? 0, 0, "Callback must follow the SQLite transaction")
    }

    func testUnreliableStoredTextCannotBecomeAcceptedSpeech() async throws {
        let run = try await runFixture(text: "Thank you for watching", failInsert: false)
        XCTAssertTrue(run.receipts.allSatisfy { !$0.acceptedTranscription })
    }

    func testSQLiteInsertionFailureCannotEmitACommitReceipt() async throws {
        let run = try await runFixture(text: "Cedar proposal needs approval tomorrow", failInsert: true)
        XCTAssertTrue(run.receipts.isEmpty)
        XCTAssertTrue(run.rowCounts.isEmpty)
    }

    private struct Run {
        let startedAt: Date
        let receipts: [AudioTranscriptCommitReceipt]
        let rowCounts: [Int]
    }

    private func runFixture(text: String, failInsert: Bool) async throws -> Run {
        let database = DatabaseManager(databasePath: "file:audio-commit-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-commit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? await database.close(); try? FileManager.default.removeItem(at: root) }
        let queries = try await database.commitFixtureQueries(failInsert: failInsert)
        let sink = CommitReceiptSink()
        let writer = AudioSegmentWriter(storageRoot: root)
        let manager = AudioProcessingManager(transcriptionService: CommitTranscriptFixture(text: text),
            transcriptionQueries: queries, audioWriter: writer,
            config: .init(maxBufferDuration: 1, committedTranscriptionCallback: { receipt in
                let rows = (try? await queries.getTranscriptions(from: receipt.startedAt,
                    to: receipt.endedAt, limit: 20)) ?? []
                await sink.append(receipt, rowCount: rows.count)
            }))
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = (0..<16_000).map { i in Int16(8_000 * sin(Double(i) * 2 * .pi * 220 / 16_000)) }
        let pcm = samples.withUnsafeBytes { Data($0) }
        let pair = AsyncStream<CapturedAudio>.makeStream()
        pair.continuation.yield(.init(timestamp: started, audioData: pcm, duration: 1, source: .microphone))
        pair.continuation.finish()
        await manager.startProcessing(audioStream: pair.stream)
        let values = await sink.values()
        return Run(startedAt: started, receipts: values.0, rowCounts: values.1)
    }
}

private actor CommitReceiptSink {
    var receipts: [AudioTranscriptCommitReceipt] = []
    var counts: [Int] = []
    func append(_ receipt: AudioTranscriptCommitReceipt, rowCount: Int) { receipts.append(receipt); counts.append(rowCount) }
    func values() -> ([AudioTranscriptCommitReceipt], [Int]) { (receipts, counts) }
}

private actor CommitTranscriptFixture: TranscriptionProtocol {
    let text: String
    init(text: String) { self.text = text }
    func initialize() {}
    func cleanup() {}
    func transcribe(_ data: Data) -> TranscriptionResult { .init(text: text, language: "en", duration: 1) }
    func transcribeWithTimestamps(_ data: Data, wordLevel: Bool, initialPrompt: String?) -> DetailedTranscriptionResult {
        let words = text.split(separator: " ").enumerated().map { offset, word in
            TranscriptionWord(word: String(word), start: Double(offset) * 0.15,
                end: Double(offset + 1) * 0.15, confidence: 0.95)
        }
        return .init(text: text, words: words, language: "en", duration: 1)
    }
}

private extension DatabaseManager {
    func commitFixtureQueries(failInsert: Bool) throws -> AudioTranscriptionQueries {
        let db = try XCTUnwrap(getConnection())
        if failInsert {
            let sql = "CREATE TRIGGER fail_transcript BEFORE INSERT ON audio_captures WHEN NEW.transcription_pass=1 BEGIN SELECT RAISE(ABORT,'fixture commit denial'); END;"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        return AudioTranscriptionQueries(db: db)
    }
}
