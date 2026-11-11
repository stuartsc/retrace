import XCTest
import Database
import Shared
import Storage
import SQLCipher
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

    func testPermitRevokedByPostCommitCallbackDoesNotRepeatAlreadyPublishedInference() async throws {
        let queries = try await makeQueries()
        let service = BlockingTranscriptionService()
        try await service.initialize()
        let governor = HeldAudioGovernor()
        await governor.allow()
        let committed = expectation(description: "committed callback revokes permit")
        let manager = AudioProcessingManager(transcriptionService: service, transcriptionQueries: queries,
            audioWriter: AudioSegmentWriter(storageRoot: tempDirectory),
            config: AudioProcessingConfig(maxBufferDuration: 0.25, committedTranscriptionCallback: { _ in
                await governor.pauseAndCancel()
                committed.fulfill()
            }), governor: governor)
        let task = Task {
            await manager.startProcessing(audioStream: AsyncStream { continuation in
                continuation.yield(Self.audioSample(at: 425, textMarker: 1)); continuation.finish()
            })
        }
        await service.waitForFirstTranscription()
        await service.releaseFirstTranscription()
        await fulfillment(of: [committed], timeout: 5)
        await governor.waitForAdmissionRequest()
        await governor.allow()
        await task.value
        let calls = await service.numberOfCalls
        XCTAssertEqual(calls, 1, "A retired pending row must be rejected before repeated decoding or inference")
        let rows = try await queries.getTranscriptionCount()
        XCTAssertEqual(rows, 1)
        let pending = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 0)
    }

    func testGovernedMissingDatabaseSuspendsWithoutPCMQueueAndRecoversAfterInitialization() async throws {
        let queries = try await makeQueries()
        let service = BlockingTranscriptionService()
        try await service.initialize()
        let governor = HeldAudioGovernor()
        let writer = AudioSegmentWriter(storageRoot: tempDirectory)
        let manager = AudioProcessingManager(transcriptionService: service, audioWriter: writer,
            config: AudioProcessingConfig(maxBufferDuration: 0.25), governor: governor)
        let failure = AudioFailureReceipt()
        await manager.setPersistenceFailureCallback { await failure.record() }
        await manager.startProcessing(audioStream: AsyncStream { continuation in
            for index in 0..<3 { continuation.yield(Self.audioSample(at: 450 + Double(index), textMarker: index)) }
            continuation.finish()
        })
        let failed = await manager.hasPersistenceFailure
        XCTAssertTrue(failed)
        let failures = await failure.count
        XCTAssertEqual(failures, 1)
        let calls = await service.numberOfCalls
        XCTAssertEqual(calls, 0)
        let before = try await queries.getTranscriptionCount()
        XCTAssertEqual(before, 0)
        try await manager.initialize(transcriptionQueries: queries)
        await governor.allow()
        let restart = Task { await manager.startProcessing(audioStream: AsyncStream { $0.finish() }) }
        await service.waitForFirstTranscription()
        await service.releaseFirstTranscription()
        await restart.value
        let stillFailed = await manager.hasPersistenceFailure
        XCTAssertFalse(stillFailed)
        let rows = try await queries.getTranscriptions(from: Date(timeIntervalSince1970: 449), to: Date(timeIntervalSince1970: 454))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.startTime, Date(timeIntervalSince1970: 450))
    }

    func testBoundedRecoveryPagePrioritizesSpeechHintsAndStillAdmitsSilence() async throws {
        let queries = try await makeQueries()
        let writer = AudioSegmentWriter(storageRoot: tempDirectory)
        for index in 0..<6 {
            let input = Self.audioSample(at: 500 + Double(index), textMarker: index)
            let pcm = index == 0 ? Data(repeating: 0, count: input.audioData.count) : input.audioData
            let (path, size) = try await writer.writeFullBatch(audioData: pcm, sampleRate: input.sampleRate,
                channels: input.channels, timestamp: input.timestamp, source: input.source)
            _ = try await queries.insertRawBatch(startTime: input.timestamp,
                endTime: input.timestamp.addingTimeInterval(input.duration), source: input.source,
                audioPath: path, audioSize: size, probableSilenceHint: index == 0)
        }
        let service = BlockingTranscriptionService()
        try await service.initialize()
        let governor = HeldAudioGovernor()
        await governor.allow()
        let manager = AudioProcessingManager(transcriptionService: service, transcriptionQueries: queries,
            audioWriter: writer, governor: governor)
        let task = Task { await manager.startProcessing(audioStream: AsyncStream { $0.finish() }) }
        await service.waitForFirstTranscription()
        await service.releaseFirstTranscription()
        await task.value
        let kinds = await governor.kinds
        XCTAssertEqual(kinds.map(\.rawValue), ["ambientSpeech", "ambientSpeech", "ambientSpeech", "ambientSilence", "ambientSpeech", "ambientSpeech"])
        let pending = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 0)
    }

    func testFailedInferenceRetriesDurablePendingWithoutNewCapture() async throws {
        let queries = try await makeQueries()
        let service = BlockingTranscriptionService(firstCallFails: true)
        try await service.initialize()
        let manager = AudioProcessingManager(transcriptionService: service, transcriptionQueries: queries,
            audioWriter: AudioSegmentWriter(storageRoot: tempDirectory),
            config: AudioProcessingConfig(maxBufferDuration: 0.25), pendingRetryInterval: .milliseconds(30))
        let stream = AsyncStream<CapturedAudio>.makeStream()
        let task = Task { await manager.startProcessing(audioStream: stream.stream) }
        stream.continuation.yield(Self.audioSample(at: 550, textMarker: 1))
        await service.waitForFirstTranscription()
        await service.releaseFirstTranscription()
        let deadline = Date().addingTimeInterval(3)
        while await service.numberOfCalls < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20), clock: .continuous)
        }
        stream.continuation.finish()
        await task.value
        let calls = await service.numberOfCalls
        XCTAssertEqual(calls, 2)
        let pending = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 0)
    }

    func testSQLitePersistenceFailureSuspendsAndRetainsBatchForNextStart() async throws {
        let queries = try await makeQueries()
        let pointer = await database.getConnection()
        let db = try XCTUnwrap(pointer)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_raw BEFORE INSERT ON audio_captures WHEN NEW.batch_audio_path IS NULL BEGIN SELECT RAISE(ABORT,'fixture'); END", nil, nil, nil), SQLITE_OK)
        let service = BlockingTranscriptionService()
        try await service.initialize()
        let manager = AudioProcessingManager(transcriptionService: service, transcriptionQueries: queries,
            audioWriter: AudioSegmentWriter(storageRoot: tempDirectory), config: AudioProcessingConfig(maxBufferDuration: 0.25))
        let failure = AudioFailureReceipt()
        await manager.setPersistenceFailureCallback { await failure.record() }
        await manager.startProcessing(audioStream: AsyncStream { continuation in
            continuation.yield(Self.audioSample(at: 600, textMarker: 1)); continuation.finish()
        })
        let failed = await manager.hasPersistenceFailure
        XCTAssertTrue(failed)
        let failures = await failure.count
        XCTAssertEqual(failures, 1)
        let calls = await service.numberOfCalls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER fail_raw", nil, nil, nil), SQLITE_OK)
        let restart = Task { await manager.startProcessing(audioStream: AsyncStream { $0.finish() }) }
        await service.waitForFirstTranscription()
        await service.releaseFirstTranscription()
        await restart.value
        let stillFailed = await manager.hasPersistenceFailure
        XCTAssertFalse(stillFailed)
        let pending = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 0)
        let count = try await queries.getTranscriptionCount()
        XCTAssertEqual(count, 1)
    }

    func testRenewedInteractionLeavesAACPendingAndRetriesWithoutDuplicateText() async throws {
        let queries = try await makeQueries()
        let service = BlockingTranscriptionService()
        try await service.initialize()
        let governor = HeldAudioGovernor()
        await governor.allow()
        let manager = AudioProcessingManager(transcriptionService: service, transcriptionQueries: queries,
            audioWriter: AudioSegmentWriter(storageRoot: tempDirectory),
            config: AudioProcessingConfig(maxBufferDuration: 0.25), governor: governor)
        let stream = AsyncStream<CapturedAudio>.makeStream()
        let task = Task { await manager.startProcessing(audioStream: stream.stream) }
        stream.continuation.yield(Self.audioSample(at: 700, textMarker: 1))
        await service.waitForFirstTranscription()
        await governor.pauseAndCancel()
        await service.releaseFirstTranscription()
        await governor.waitForAdmissionRequest()
        let pending = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 1)
        let before = try await queries.getTranscriptionCount()
        XCTAssertEqual(before, 1, "Only the retained raw placeholder may exist before renewed admission")
        await governor.allow()
        stream.continuation.finish()
        await task.value
        let remaining = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(remaining, 0)
        let after = try await queries.getTranscriptionCount()
        XCTAssertEqual(after, 1)
    }

    func testGovernorDefersModelWhileRecordingPersistsThenDrains() async throws {
        let queries = try await makeQueries()
        let service = BlockingTranscriptionService()
        try await service.initialize()
        let governor = HeldAudioGovernor()
        let manager = AudioProcessingManager(transcriptionService: service, transcriptionQueries: queries,
            audioWriter: AudioSegmentWriter(storageRoot: tempDirectory),
            config: AudioProcessingConfig(maxBufferDuration: 0.25), governor: governor)
        let stream = AsyncStream<CapturedAudio>.makeStream()
        let task = Task { await manager.startProcessing(audioStream: stream.stream) }
        stream.continuation.yield(Self.audioSample(at: 800, textMarker: 1))
        await governor.waitForAdmissionRequest()
        stream.continuation.yield(Self.audioSample(at: 801, textMarker: 2))
        let pending = try await waitForPendingBatchCount(queries: queries, expectedCount: 2, timeoutSeconds: 2)
        XCTAssertEqual(pending, 2)
        let callsBeforeAdmission = await service.numberOfCalls
        XCTAssertEqual(callsBeforeAdmission, 0)
        await governor.allow()
        await service.waitForFirstTranscription()
        await service.releaseFirstTranscription()
        stream.continuation.finish()
        await task.value
        let remaining = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(remaining, 0)
        let releases = await governor.releaseCount
        XCTAssertEqual(releases, 2)
    }

    func testEmptyStreamRecoversDurablePendingAACWithoutRefinement() async throws {
        let queries = try await makeQueries()
        let writer = AudioSegmentWriter(storageRoot: tempDirectory)
        let input = Self.audioSample(at: 900, textMarker: 1)
        let (path, size) = try await writer.writeFullBatch(audioData: input.audioData, sampleRate: input.sampleRate,
            channels: input.channels, timestamp: input.timestamp, source: input.source)
        _ = try await queries.insertRawBatch(startTime: input.timestamp,
            endTime: input.timestamp.addingTimeInterval(input.duration), source: input.source,
            audioPath: path, audioSize: size)
        let service = BlockingTranscriptionService()
        try await service.initialize()
        let manager = AudioProcessingManager(transcriptionService: service, transcriptionQueries: queries, audioWriter: writer)
        let task = Task { await manager.startProcessing(audioStream: AsyncStream { $0.finish() }) }
        await service.waitForFirstTranscription()
        await service.releaseFirstTranscription()
        await task.value
        let pending = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent(path).path))
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
    private let firstCallFails: Bool
    init(firstCallFails: Bool = false) { self.firstCallFails = firstCallFails }
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
            if firstCallFails { throw TranscriptionError.notInitialized }
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

    var numberOfCalls: Int { callCount }

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

private actor HeldAudioGovernor: BackgroundProcessingProtocol {
    private var allowed = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var requested: CheckedContinuation<Void, Never>?
    private var hasRequest = false
    private var current: BackgroundProcessingPermit?
    private(set) var releaseCount = 0
    private(set) var kinds: [BackgroundProcessingKind] = []
    func acquire(_ kind: BackgroundProcessingKind) async throws -> BackgroundProcessingPermit {
        kinds.append(kind)
        hasRequest = true
        requested?.resume(); requested = nil
        if !allowed { await withCheckedContinuation { waiting = $0 } }
        try Task.checkCancellation()
        let permit = BackgroundProcessingPermit(threadCount: 2)
        current = permit
        return permit
    }
    func release(_ permit: BackgroundProcessingPermit) { releaseCount += 1 }
    func waitForAdmissionRequest() async {
        if !hasRequest { await withCheckedContinuation { requested = $0 } }
    }
    func pauseAndCancel() { allowed = false; hasRequest = false; current?.cancellation.cancel() }
    func allow() { allowed = true; waiting?.resume(); waiting = nil }
}

private actor AudioFailureReceipt {
    private(set) var count = 0
    func record() { count += 1 }
}
