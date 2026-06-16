import XCTest
import Database
import Shared
import Storage
@testable import Processing

final class AudioProcessingBackpressureTests: XCTestCase {
    private var database: DatabaseManager!
    private var tempDirectory: URL!

    override func setUp() async throws {
        let path = "file:audio_processing_backpressure_tests_\(UUID().uuidString)?mode=memory&cache=shared"
        database = DatabaseManager(databasePath: path)
        try await database.initialize()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace_audio_backpressure_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try await database.close()
        database = nil

        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testLiveIngestionPersistsCompletedBatchesWhileFirstTranscriptionIsBlocked() async throws {
        let queries = try await makeQueries()
        let transcriptionService = BlockingTranscriptionService()
        try await transcriptionService.initialize()

        let manager = AudioProcessingManager(
            transcriptionService: transcriptionService,
            transcriptionQueries: queries,
            audioWriter: AudioSegmentWriter(storageRoot: tempDirectory),
            config: AudioProcessingConfig(
                enableWordLevelTimestamps: true,
                minimumConfidence: 0.0,
                maxBufferDuration: 0.25
            )
        )

        var continuation: AsyncStream<CapturedAudio>.Continuation!
        let stream = AsyncStream<CapturedAudio>(bufferingPolicy: .bufferingNewest(1)) { streamContinuation in
            continuation = streamContinuation
        }

        let processingTask = Task {
            await manager.startProcessing(audioStream: stream)
        }

        continuation.yield(Self.audioSample(at: 1_000, textMarker: 1))
        await transcriptionService.waitForFirstTranscription()

        continuation.yield(Self.audioSample(at: 1_001, textMarker: 2))

        let persistedCount = try await waitForPendingBatchCount(
            queries: queries,
            expectedCount: 2,
            timeoutSeconds: 1.0
        )

        await transcriptionService.releaseFirstTranscription()
        continuation.finish()
        _ = await processingTask.result

        XCTAssertEqual(
            persistedCount,
            2,
            "Live ingestion must keep accepting and persisting completed raw batches while transcription is blocked."
        )
    }

    func testSaturatedLiveQueueStillDrainsAllBatchesThroughLiveWorker() async throws {
        let queries = try await makeQueries()
        let transcriptionService = BlockingTranscriptionService()
        try await transcriptionService.initialize()

        let manager = AudioProcessingManager(
            transcriptionService: transcriptionService,
            transcriptionQueries: queries,
            audioWriter: AudioSegmentWriter(storageRoot: tempDirectory),
            config: AudioProcessingConfig(
                enableWordLevelTimestamps: true,
                minimumConfidence: 0.0,
                maxBufferDuration: 0.25,
                maxQueuedLiveTranscriptionBatches: 1
            )
        )

        var continuation: AsyncStream<CapturedAudio>.Continuation!
        let stream = AsyncStream<CapturedAudio>(bufferingPolicy: .bufferingNewest(1)) { streamContinuation in
            continuation = streamContinuation
        }

        let processingTask = Task {
            await manager.startProcessing(audioStream: stream)
        }

        continuation.yield(Self.audioSample(at: 2_000, textMarker: 1))
        await transcriptionService.waitForFirstTranscription()

        continuation.yield(Self.audioSample(at: 2_001, textMarker: 2))
        continuation.yield(Self.audioSample(at: 2_002, textMarker: 3))

        let persistedCount = try await waitForPendingBatchCount(
            queries: queries,
            expectedCount: 3,
            timeoutSeconds: 1.0
        )

        await transcriptionService.releaseFirstTranscription()
        continuation.finish()
        _ = await processingTask.result

        let remainingPending = try await queries.getUntranscribedBatchCount()

        XCTAssertEqual(persistedCount, 3)
        XCTAssertEqual(
            remainingPending,
            0,
            "Live queue saturation must not permanently skip a batch; disk-backed queue entries should still drain."
        )
    }

    func testOCRMemoryBackoffIgnoresHighSharedResidentMemoryWhenOwnedHeapIsLow() {
        let shouldBackOff = FrameProcessingMemoryBackoffPolicy.shouldBackOff(
            snapshot: FrameProcessingMemorySnapshot(
                residentBytes: 3_000_000_000,
                ownedHeapBytes: 400_000_000
            ),
            residentLimitBytes: 2_000_000_000,
            ownedHeapLimitBytes: 2_000_000_000
        )

        XCTAssertFalse(
            shouldBackOff,
            "Shared screen/capture memory alone must not starve durable OCR backlog processing."
        )
    }

    func testOCRMemoryBackoffPausesWhenResidentAndOwnedHeapAreBothHigh() {
        let shouldBackOff = FrameProcessingMemoryBackoffPolicy.shouldBackOff(
            snapshot: FrameProcessingMemorySnapshot(
                residentBytes: 3_000_000_000,
                ownedHeapBytes: 2_500_000_000
            ),
            residentLimitBytes: 2_000_000_000,
            ownedHeapLimitBytes: 2_000_000_000
        )

        XCTAssertTrue(shouldBackOff)
    }

    func testOCRMemoryBackoffFallsBackToConservativePauseWhenOwnedHeapIsUnknown() {
        let shouldBackOff = FrameProcessingMemoryBackoffPolicy.shouldBackOff(
            snapshot: FrameProcessingMemorySnapshot(
                residentBytes: 3_000_000_000,
                ownedHeapBytes: nil
            ),
            residentLimitBytes: 2_000_000_000,
            ownedHeapLimitBytes: 2_000_000_000
        )

        XCTAssertTrue(shouldBackOff)
    }

    private func makeQueries() async throws -> AudioTranscriptionQueries {
        guard let db = await database.getConnection() else {
            XCTFail("database connection missing")
            throw DatabaseError.connectionFailed(underlying: "database connection missing")
        }
        return AudioTranscriptionQueries(db: db)
    }

    private func waitForPendingBatchCount(
        queries: AudioTranscriptionQueries,
        expectedCount: Int,
        timeoutSeconds: TimeInterval
    ) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastCount = 0

        while Date() < deadline {
            lastCount = try await queries.getUntranscribedBatchCount()
            if lastCount >= expectedCount {
                return lastCount
            }
            try? await Task.sleep(for: .milliseconds(20), clock: .continuous)
        }

        return lastCount
    }

    private static func audioSample(at timestamp: TimeInterval, textMarker: Int) -> CapturedAudio {
        CapturedAudio(
            timestamp: Date(timeIntervalSince1970: timestamp),
            audioData: pcmSine(duration: 0.25, sampleRate: 16_000, amplitude: 0.02 + Double(textMarker) * 0.001),
            duration: 0.25,
            source: .microphone,
            sampleRate: 16_000,
            channels: 1
        )
    }

    private static func pcmSine(duration: TimeInterval, sampleRate: Int, amplitude: Double) -> Data {
        let totalSamples = Int(duration * Double(sampleRate))
        var samples: [Int16] = []
        samples.reserveCapacity(totalSamples)

        for index in 0..<totalSamples {
            let wave = sin(2.0 * Double.pi * 220.0 * Double(index) / Double(sampleRate))
            samples.append(Int16(max(-1.0, min(1.0, wave * amplitude)) * 32767.0))
        }

        return Data(bytes: samples, count: samples.count * MemoryLayout<Int16>.size)
    }
}

private actor BlockingTranscriptionService: TranscriptionProtocol {
    private var isInitialized = false
    private var callCount = 0
    private var firstStartedContinuation: CheckedContinuation<Void, Never>?
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?

    func initialize() async throws {
        isInitialized = true
    }

    func cleanup() {
        isInitialized = false
    }

    func transcribe(_ audioData: Data) async throws -> TranscriptionResult {
        let detailed = try await transcribeWithTimestamps(audioData, wordLevel: false, initialPrompt: nil)
        return TranscriptionResult(
            text: detailed.text,
            confidence: 0.9,
            language: detailed.language,
            duration: detailed.duration
        )
    }

    func transcribeWithTimestamps(
        _ audioData: Data,
        wordLevel: Bool,
        initialPrompt: String?
    ) async throws -> DetailedTranscriptionResult {
        try await transcribeWithTimestamps(
            audioData,
            wordLevel: wordLevel,
            initialPrompt: initialPrompt,
            languageHint: nil
        )
    }

    func transcribeWithTimestamps(
        _ audioData: Data,
        wordLevel: Bool,
        initialPrompt: String?,
        languageHint: String?
    ) async throws -> DetailedTranscriptionResult {
        guard isInitialized else {
            throw TranscriptionError.notInitialized
        }

        callCount += 1
        let currentCall = callCount

        if currentCall == 1 {
            firstStartedContinuation?.resume()
            firstStartedContinuation = nil
            await withCheckedContinuation { continuation in
                firstReleaseContinuation = continuation
            }
        }

        let marker = "batch \(currentCall)"
        return DetailedTranscriptionResult(
            text: "captured speech \(marker) safely",
            words: [
                TranscriptionWord(word: "captured", start: 0.00, end: 0.05, confidence: 0.9),
                TranscriptionWord(word: "speech", start: 0.06, end: 0.10, confidence: 0.9),
                TranscriptionWord(word: "batch", start: 0.11, end: 0.15, confidence: 0.9),
                TranscriptionWord(word: "\(currentCall)", start: 0.16, end: 0.20, confidence: 0.9),
                TranscriptionWord(word: "safely", start: 0.21, end: 0.24, confidence: 0.9)
            ],
            language: "en",
            duration: 0.25
        )
    }

    func waitForFirstTranscription() async {
        if callCount > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            firstStartedContinuation = continuation
        }
    }

    func releaseFirstTranscription() {
        firstReleaseContinuation?.resume()
        firstReleaseContinuation = nil
    }
}
