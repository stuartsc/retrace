import Foundation
import XCTest
import Database
import Shared
import Storage
@testable import Processing

final class PersistedAudioBatchCallbackTests: XCTestCase {
    private var database: DatabaseManager!
    private var root: URL!

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:persisted_callback_\(UUID().uuidString)?mode=memory&cache=shared")
        try await database.initialize()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("persisted_callback_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testCallbackSeesCommittedRecordingAndStopJoinsItWithoutCancellation() async throws {
        let queries = try await makeQueries()
        let probe = PersistedCallbackProbe(hold: true)
        let manager = makeManager(queries)
        let installed = await manager.setPersistedBatchHandler { receipt in
            let committed = try await queries.getContextEntry(id: receipt.rawBatchID)
            await probe.receive(receipt, committedPath: committed?.audioPath)
        }
        XCTAssertTrue(installed)
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        let ingestion = Task { await manager.startProcessing(audioStream: stream) }
        let sample = Self.sample()
        continuation.yield(sample)
        let entered = await eventually { await probe.receipts.count == 1 }
        XCTAssertTrue(entered, "Native AAC and the raw row must commit before the callback")

        let replacedWhileActive = await manager.setPersistedBatchHandler(nil)
        XCTAssertFalse(replacedWhileActive, "An accepted recording retains its configured callback")
        let completion = PersistedStopCompletion()
        let stop = Task {
            await completion.started()
            await manager.stopProcessing()
            await completion.finished()
        }
        let stopStarted = await eventually { await completion.hasStarted }
        XCTAssertTrue(stopStarted)
        try? await Task.sleep(for: .milliseconds(100), clock: .continuous)
        let finishedEarly = await completion.hasFinished
        XCTAssertFalse(finishedEarly, "Stop must join the accepted post-commit registration")
        await probe.release()
        await stop.value
        continuation.finish()
        await ingestion.value

        let receipts = await probe.receipts
        let receipt = try XCTUnwrap(receipts.first)
        let committedPaths = await probe.committedPaths
        XCTAssertEqual(committedPaths, [receipt.relativePath])
        XCTAssertEqual(receipt.sourceRanges, [AudioBatchSourceRange(source: try XCTUnwrap(sample.sampleIdentity), batchStartSample: 0)])
        XCTAssertEqual(receipt.frameCount, 16_000)
        XCTAssertEqual(receipt.sampleRate, 16_000)
        XCTAssertEqual(receipt.channels, 1)
        XCTAssertEqual(receipt.source, .microphone)
        XCTAssertEqual(receipt.startTimestamp, sample.timestamp)
        XCTAssertEqual(receipt.endTimestamp, sample.timestamp.addingTimeInterval(1))
        XCTAssertEqual(receipt.fileURL, root.appendingPathComponent(receipt.relativePath))
        let attributes = try FileManager.default.attributesOfItem(atPath: receipt.fileURL.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.int64Value, receipt.fileSize)
        let decoded = try AudioFileDecoder.decodeToPCM(fileURL: receipt.fileURL)
        XCTAssertGreaterThan(decoded.data.count, 0, "Use the production native AAC writer and decoder")
        let callbackWasCancelled = await probe.observedCancellation
        XCTAssertFalse(callbackWasCancelled)
        let remaining = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(remaining, 1, "Registering context must not consume pending inference work")
        let callbackFailure = await manager.hasPersistedBatchCallbackFailure
        XCTAssertFalse(callbackFailure)
        let replacedAfterStop = await manager.setPersistedBatchHandler(nil)
        XCTAssertTrue(replacedAfterStop)
    }

    func testRegistrationFailurePreservesRecordingAndReportsSeparateStickyFailure() async throws {
        let queries = try await makeQueries()
        let probe = PersistedCallbackProbe()
        let manager = makeManager(queries, handler: { receipt in
            let committed = try await queries.getContextEntry(id: receipt.rawBatchID)
            await probe.receive(receipt, committedPath: committed?.audioPath)
            throw CallbackFixtureError.registrationFailed
        })
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        continuation.yield(Self.sample())
        continuation.finish()
        await manager.startProcessing(audioStream: stream)

        let callbackFailure = await manager.hasPersistedBatchCallbackFailure
        let canonicalFailure = await manager.hasPersistenceFailure
        XCTAssertTrue(callbackFailure)
        XCTAssertFalse(canonicalFailure)
        let receipts = await probe.receipts
        let receipt = try XCTUnwrap(receipts.first)
        let row = try await queries.getContextEntry(id: receipt.rawBatchID)
        XCTAssertEqual(row?.audioPath, receipt.relativePath)
        XCTAssertEqual(row?.text, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.fileURL.path))
        XCTAssertGreaterThan(try AudioFileDecoder.decodeToPCM(fileURL: receipt.fileURL).data.count, 0)
        let count = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(count, 1)
        let (emptyStream, emptyContinuation) = AsyncStream<CapturedAudio>.makeStream()
        emptyContinuation.finish()
        await manager.startProcessing(audioStream: emptyStream)
        let stillFailed = await manager.hasPersistedBatchCallbackFailure
        XCTAssertTrue(stillFailed, "Restarting a stream cannot silently clear a lost context mapping")
    }

    func testLegacyRecordingIsSavedWithoutInventingCallbackLineage() async throws {
        let queries = try await makeQueries()
        let probe = PersistedCallbackProbe()
        let manager = makeManager(queries, handler: { receipt in
            await probe.receive(receipt, committedPath: nil)
        })
        let original = Self.sample()
        let legacy = CapturedAudio(timestamp: original.timestamp, audioData: original.audioData,
            duration: original.duration, source: original.source)
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        continuation.yield(legacy)
        continuation.finish()
        await manager.startProcessing(audioStream: stream)
        let receipts = await probe.receipts
        XCTAssertTrue(receipts.isEmpty)
        let count = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(count, 1)
    }

    func testMalformedIdentityPublishesExplicitIncompleteDispositionAfterSaving() async throws {
        let queries = try await makeQueries()
        let probe = PersistedCallbackProbe()
        let manager = makeManager(queries, handler: { receipt in
            await probe.receive(receipt, committedPath: nil)
        })
        let original = Self.sample()
        let invalid = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(),
            startSample: 0, sampleCount: 1, sampleRate: 16_000, approximateOrigin: original.timestamp)
        let sample = CapturedAudio(timestamp: original.timestamp, audioData: original.audioData,
            duration: original.duration, source: .microphone, sampleIdentity: invalid)
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        continuation.yield(sample); continuation.finish()
        await manager.startProcessing(audioStream: stream)
        let receipts = await probe.receipts
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertTrue(receipt.sourceRanges.isEmpty)
        XCTAssertTrue(receipt.sourceMappingIncomplete)
        let count = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(count, 1)
    }

    func testCommittedCallbackSeesVerbatimFirstPassAndStopJoinsPublication() async throws {
        let queries = try await makeQueries()
        let manager = AudioProcessingManager(transcriptionService: CommittedFixtureTranscriber(), transcriptionQueries: queries,
            audioWriter: AudioSegmentWriter(storageRoot: root), config: .init(maxBufferDuration: 1))
        let probe = CommittedCallbackProbe()
        let installed = await manager.setCommittedBatchHandler { receipt in
            let retained = try await queries.getContextBatchEntries(batchAudioPath: receipt.relativePath)
            XCTAssertEqual(retained.map(\.id), receipt.records.map(\.id))
            XCTAssertEqual(receipt.firstPassText, retained.map(\.text).joined(separator: "\n"))
            await probe.receive(receipt)
        }
        XCTAssertTrue(installed)
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        let ingestion = Task { await manager.startProcessing(audioStream: stream) }
        continuation.yield(Self.sample())
        let entered = await eventually { await probe.receipt != nil }
        XCTAssertTrue(entered)
        let completion = PersistedStopCompletion()
        let stop = Task { await manager.stopProcessing(); await completion.finished() }
        try? await Task.sleep(for: .milliseconds(50))
        let early = await completion.hasFinished
        XCTAssertFalse(early)
        await probe.release(); await stop.value; continuation.finish(); await ingestion.value
        let received = await probe.receipt
        let receipt = try XCTUnwrap(received)
        XCTAssertTrue(receipt.firstPassText.contains("Remember this useful context"))
        XCTAssertTrue(receipt.records.allSatisfy { $0.transcriptionPass == 1 && $0.batchAudioPath == receipt.relativePath })
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(receipt.relativePath).path))
        let failed = await manager.hasCommittedBatchCallbackFailure
        XCTAssertFalse(failed)
    }

    func testCommittedCallbackFailureCannotEraseCanonicalFirstPass() async throws {
        let queries = try await makeQueries()
        let manager = AudioProcessingManager(transcriptionService: CommittedFixtureTranscriber(), transcriptionQueries: queries,
            audioWriter: AudioSegmentWriter(storageRoot: root), config: .init(maxBufferDuration: 1))
        let installed = await manager.setCommittedBatchHandler { _ in throw CallbackFixtureError.registrationFailed }
        XCTAssertTrue(installed)
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        continuation.yield(Self.sample()); continuation.finish()
        await manager.startProcessing(audioStream: stream)
        let failed = await manager.hasCommittedBatchCallbackFailure
        XCTAssertTrue(failed)
        let rows = try await queries.getContextPage(from: Date(timeIntervalSince1970: 1_799_999_999),
                                                    to: Date(timeIntervalSince1970: 1_800_000_010))
        XCTAssertFalse(rows.entries.isEmpty)
        XCTAssertTrue(rows.entries.map(\.text).joined(separator: " ").contains("Remember this useful context"))
    }

    private func makeQueries() async throws -> AudioTranscriptionQueries {
        guard let connection = await database.getConnection() else {
            throw DatabaseError.connectionFailed(underlying: "Private test connection missing")
        }
        return AudioTranscriptionQueries(db: connection)
    }

    private func makeManager(_ queries: AudioTranscriptionQueries,
                             handler: AudioProcessingManager.PersistedBatchHandler? = nil) -> AudioProcessingManager {
        AudioProcessingManager(transcriptionService: MockTranscriptionService(), transcriptionQueries: queries,
            audioWriter: AudioSegmentWriter(storageRoot: root), governor: PersistedNoInferenceGovernor(),
            config: .init(maxBufferDuration: 1), onPersistedBatch: handler)
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10), clock: .continuous)
        }
        return await condition()
    }

    private static func sample() -> CapturedAudio {
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (0..<16_000).map { Int16(sin(Double($0) * 0.08) * 2_000) }
        let identity = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(),
            startSample: 0, sampleCount: 16_000, sampleRate: 16_000, approximateOrigin: origin)
        return CapturedAudio(timestamp: origin, audioData: samples.withUnsafeBytes { Data($0) },
            duration: 1, source: .microphone, sampleIdentity: identity)
    }
}

private enum CallbackFixtureError: Error { case registrationFailed }

private actor PersistedCallbackProbe {
    private let hold: Bool
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var receipts: [PersistedAudioBatchReceipt] = []
    private(set) var committedPaths: [String?] = []
    private(set) var observedCancellation = false

    init(hold: Bool = false) { self.hold = hold }

    func receive(_ receipt: PersistedAudioBatchReceipt, committedPath: String?) async {
        receipts.append(receipt)
        committedPaths.append(committedPath)
        if hold && !released { await withCheckedContinuation { waiting = $0 } }
        observedCancellation = observedCancellation || Task.isCancelled
    }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }
}

private actor PersistedStopCompletion {
    private(set) var hasStarted = false
    private(set) var hasFinished = false
    func started() { hasStarted = true }
    func finished() { hasFinished = true }
}

private struct PersistedNoInferenceGovernor: BackgroundProcessingProtocol {
    func acquire(_ kind: BackgroundProcessingKind) async throws -> BackgroundProcessingPermit {
        XCTFail("The missing-model path must not request native inference")
        throw CancellationError()
    }
    func release(_ permit: BackgroundProcessingPermit) async {}
}

private actor CommittedCallbackProbe {
    private(set) var receipt: CommittedAudioBatchReceipt?
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false
    func receive(_ value: CommittedAudioBatchReceipt) async {
        receipt = value
        if !released { await withCheckedContinuation { waiting = $0 } }
    }
    func release() { released = true; waiting?.resume(); waiting = nil }
}

private actor CommittedFixtureTranscriber: TranscriptionProtocol {
    func initialize() {}
    func cleanup() {}
    func transcribe(_ audioData: Data) -> TranscriptionResult { .init(text: "Remember this useful context.", confidence: 0.98, language: "en", duration: 1) }
    func transcribeWithTimestamps(_ audioData: Data, wordLevel: Bool, initialPrompt: String?) -> DetailedTranscriptionResult {
        let words = ["Remember", "this", "useful", "context."].enumerated().map {
            TranscriptionWord(word: $0.element, start: Double($0.offset) * 0.2, end: Double($0.offset + 1) * 0.2, confidence: 0.98)
        }
        return .init(text: "Remember this useful context.", words: words, language: "en", duration: 1)
    }
}
