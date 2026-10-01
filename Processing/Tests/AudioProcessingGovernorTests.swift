import XCTest
import Database
import Shared
import Storage
@testable import Processing

final class AudioProcessingGovernorTests: XCTestCase {
    private var database: DatabaseManager!
    private var root: URL!

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:audio_governor_\(UUID().uuidString)?mode=memory&cache=shared")
        try await database.initialize()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("audio_governor_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testDeferredAudioPersistsWithoutInvokingModelAndResumesOnceAdmitted() async throws {
        let queries = try await makeQueries()
        let service = GovernorTestTranscriber()
        let governor = AudioTestGovernor()
        let manager = makeManager(queries, service, governor)
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        let task = Task { await manager.startProcessing(audioStream: stream) }
        continuation.yield(Self.sample(at: 1_000, duration: 0.25))
        let didPersist = await eventually { (try? await queries.getUntranscribedBatchCount()) == 1 }
        XCTAssertTrue(didPersist, "Original AAC and pending row must be durable before admission")
        let before = await service.callCount
        XCTAssertEqual(before, 0, "Active-use deferral must not start Whisper")
        let pending = try await queries.getUntranscribedBatches(limit: 1)
        if let row = pending.first {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(row.audioPath).path))
        }
        await governor.setAllowed(true)
        let didDrain = await eventually { (try? await queries.getUntranscribedBatchCount()) == 0 }
        XCTAssertTrue(didDrain)
        continuation.finish()
        await task.value
        let calls = await service.callCount
        XCTAssertEqual(calls, 1)
        let threads = await service.observedThreads
        XCTAssertEqual(threads, [2], "The permit must reach the native transcription boundary")
    }

    func testCancellationKeepsRawBatchPendingAndRestartProcessesItExactlyOnce() async throws {
        let queries = try await makeQueries()
        let firstService = GovernorTestTranscriber(holdUntilCancelled: true)
        let governor = AudioTestGovernor(allowed: true)
        let manager = makeManager(queries, firstService, governor)
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        let task = Task { await manager.startProcessing(audioStream: stream) }
        continuation.yield(Self.sample(at: 2_000, duration: 0.25))
        let didStart = await eventually { await firstService.callCount == 1 }
        XCTAssertTrue(didStart)
        await governor.cancelCurrentAndDefer()
        let didCancel = await eventually { await firstService.cancellationCount == 1 }
        XCTAssertTrue(didCancel)
        await manager.stopProcessing()
        task.cancel()
        continuation.finish()
        await task.value
        let pendingCount = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(pendingCount, 1, "Cancellation must retain pending, not mark silence/failure")

        let recoveredService = GovernorTestTranscriber()
        let recoveredGovernor = AudioTestGovernor(allowed: true)
        let recovered = makeManager(queries, recoveredService, recoveredGovernor)
        let (recoveredStream, recoveredContinuation) = AsyncStream<CapturedAudio>.makeStream()
        let recoveredTask = Task { await recovered.startProcessing(audioStream: recoveredStream) }
        let recoveredOnce = await eventually { (try? await queries.getUntranscribedBatchCount()) == 0 }
        XCTAssertTrue(recoveredOnce, "Restart must discover pending rows without another captured sample")
        recoveredContinuation.finish()
        await recoveredTask.value
        let calls = await recoveredService.callCount
        XCTAssertEqual(calls, 1)
        let records = try await queries.getTranscriptions(from: Date(timeIntervalSince1970: 1_999), to: Date(timeIntervalSince1970: 2_002))
        XCTAssertEqual(records.count, 1)
    }

    func testStopFlushesPartialCapturedAudioWhileAdmissionIsDeferred() async throws {
        let queries = try await makeQueries()
        let service = GovernorTestTranscriber()
        let governor = AudioTestGovernor()
        let manager = makeManager(queries, service, governor, duration: 1)
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        let task = Task { await manager.startProcessing(audioStream: stream) }
        continuation.yield(Self.sample(at: 3_000, duration: 0.25))
        // The explicit receipt avoids assuming a stream yield already reached the owner.
        let accepted = await eventually { await manager.acceptedAudioSampleCountForTesting == 1 }
        XCTAssertTrue(accepted)
        await manager.stopProcessing()
        let pending = try await queries.getUntranscribedBatches(limit: 4)
        XCTAssertEqual(pending.count, 1, "Joined stop must persist the accepted partial tail")
        if let row = pending.first {
            let decoded = try AudioFileDecoder.decodeToPCM(fileURL: root.appendingPathComponent(row.audioPath))
            XCTAssertGreaterThan(decoded.data.count, 0)
        }
        let calls = await service.callCount
        XCTAssertEqual(calls, 0)
        task.cancel()
        continuation.finish()
        await task.value
    }

    func testRevokedPermitRejectsSuccessfulStaleModelResult() async throws {
        let queries = try await makeQueries()
        let service = GovernorTestTranscriber(cancelPermitBeforeReturning: true)
        let governor = AudioTestGovernor(allowed: true)
        let manager = makeManager(queries, service, governor)
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        let task = Task { await manager.startProcessing(audioStream: stream) }
        continuation.yield(Self.sample(at: 4_000, duration: 0.25))
        let started = await eventually { await service.callCount > 0 }
        XCTAssertTrue(started)
        await governor.setAllowed(false)
        await manager.stopProcessing()
        task.cancel()
        continuation.finish()
        await task.value
        let pending = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 1, "A native API can finish after cancellation; stale text cannot commit")
    }

    func testCancelledPassTwoRemainsEligibleWithoutRetiringCandidate() async throws {
        let queries = try await makeQueries()
        let service = GovernorTestTranscriber(throwCancellationImmediately: true)
        let path = try await makeRefinementCandidate(queries, pass: 1, at: 5_000)
        let manager = AudioRefinementManager(transcriptionService: service, transcriptionQueries: queries,
            audioWriter: AudioSegmentWriter(storageRoot: root), storageRoot: root)
        let result = await manager.processAllPendingRefinements(maxBatches: 1)
        let pending = try await queries.getDistinctBatchPathsForRefinement(limit: 10)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.refinedCount, 0)
        XCTAssertEqual(pending, [path], "Interrupted repair must remain eligible for a quiet period")
    }

    func testCancelledPassThreeRemainsEligibleWithoutRetiringCandidate() async throws {
        let queries = try await makeQueries()
        let service = GovernorTestTranscriber(throwCancellationImmediately: true)
        let path = try await makeRefinementCandidate(queries, pass: 2, at: 6_000)
        _ = try await queries.insertTranscription(sessionID: nil, text: "Previous invoice context.",
            startTime: Date(timeIntervalSince1970: 5_999), endTime: Date(timeIntervalSince1970: 6_000),
            source: .microphone, confidence: 0.9, words: [], transcriptionPass: 3,
            batchAudioPath: "audio/batch_5999000_microphone_previous.m4a")
        let manager = AudioContextualRefinementManager(transcriptionService: service, transcriptionQueries: queries,
            audioWriter: AudioSegmentWriter(storageRoot: root), storageRoot: root)
        let result = await manager.processAllPendingRefinements(runMode: .manual, maxBatches: 1)
        let pending = try await queries.getDistinctBatchPathsForContextualRefinement(limit: 10)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.refinedCount, 0)
        XCTAssertEqual(pending, [path])
        let calls = await service.callCount
        XCTAssertEqual(calls, 1, "The real AAC candidate must reach the cancelled transcription boundary")
    }

    func testCancelledBackfillLeavesPendingWithoutCountingFailure() async throws {
        let queries = try await makeQueries()
        let service = GovernorTestTranscriber(throwCancellationImmediately: true)
        let sample = Self.sample(at: 7_000, duration: 0.25)
        let writer = AudioSegmentWriter(storageRoot: root)
        let (path, size) = try await writer.writeFullBatch(audioData: sample.audioData, sampleRate: 16_000,
            channels: 1, timestamp: sample.timestamp, source: .microphone)
        _ = try await queries.insertRawBatch(startTime: sample.timestamp, endTime: sample.timestamp.addingTimeInterval(0.25),
            source: .microphone, audioPath: path, audioSize: size)
        let manager = AudioBackfillManager(transcriptionService: service, transcriptionQueries: queries,
            audioWriter: writer, storageRoot: root)
        let result = await manager.processAllPendingBatches(maxBatches: 1)
        let pending = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.processedCount, 0)
        XCTAssertEqual(pending, 1)
    }

    private func makeRefinementCandidate(_ queries: AudioTranscriptionQueries, pass: Int, at time: Double) async throws -> String {
        let sample = Self.sample(at: time, duration: 0.25)
        let writer = AudioSegmentWriter(storageRoot: root)
        let (path, _) = try await writer.writeFullBatch(audioData: sample.audioData, sampleRate: 16_000,
            channels: 1, timestamp: sample.timestamp, source: .microphone)
        _ = try await queries.insertTranscription(sessionID: nil, text: "The invoice total is twelve dollars.",
            startTime: sample.timestamp, endTime: sample.timestamp.addingTimeInterval(0.25),
            source: .microphone, confidence: 0.9, words: [], audioPath: path, transcriptionPass: pass,
            batchAudioPath: path)
        return path
    }

    func testGovernedInitializationDoesNotLoadModelBeforeAdmission() async throws {
        let queries = try await makeQueries()
        let service = GovernorTestTranscriber()
        let governor = AudioTestGovernor()
        let manager = makeManager(queries, service, governor)
        try await manager.initialize()
        let calls = await service.initializationCount
        XCTAssertEqual(calls, 0, "Startup bookkeeping must not load a native model during active use")
    }

    func testMissingModelKeepsPendingUntilRealServiceArrivesWithoutAnotherCapture() async throws {
        let queries = try await makeQueries()
        let governor = AudioTestGovernor(allowed: true)
        let manager = AudioProcessingManager(transcriptionService: MockTranscriptionService(),
            transcriptionQueries: queries, audioWriter: AudioSegmentWriter(storageRoot: root),
            governor: governor, config: .init(maxBufferDuration: 0.25))
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        let task = Task { await manager.startProcessing(audioStream: stream) }
        continuation.yield(Self.sample(at: 8_000, duration: 0.25))
        let captured = await eventually { (try? await queries.getUntranscribedBatchCount()) == 1 }
        XCTAssertTrue(captured)
        try await Task.sleep(for: .milliseconds(100), clock: .continuous)
        let pending = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 1, "The missing-model mock must not classify real retained audio as silence")
        let service = GovernorTestTranscriber()
        await manager.updateTranscriptionService(service)
        let drained = await eventually { (try? await queries.getUntranscribedBatchCount()) == 0 }
        XCTAssertTrue(drained)
        let calls = await service.callCount
        XCTAssertEqual(calls, 1)
        await manager.stopProcessing()
        continuation.finish()
        await task.value
    }

    func testModelRemovedWhileAwaitingPermitCannotClassifyRetainedAudio() async throws {
        let queries = try await makeQueries()
        let governor = AudioTestGovernor()
        let manager = makeManager(queries, GovernorTestTranscriber(), governor)
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        let task = Task { await manager.startProcessing(audioStream: stream) }
        continuation.yield(Self.sample(at: 9_000, duration: 0.25))
        let waiting = await eventually { await governor.requestCount > 0 }
        XCTAssertTrue(waiting)
        let captured = await eventually { (try? await queries.getUntranscribedBatchCount()) == 1 }
        XCTAssertTrue(captured)
        await manager.updateTranscriptionService(MockTranscriptionService())
        await governor.setAllowed(true)
        try await Task.sleep(for: .milliseconds(150), clock: .continuous)
        await manager.stopProcessing()
        continuation.finish()
        await task.value
        let pending = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 1, "Model availability must be checked after long admission waits too")
    }

    func testRepeatedModelFailureBacksOffAndStopJoinsTheDelay() async throws {
        let queries = try await makeQueries()
        let service = GovernorTestTranscriber(throwNativeFailure: true)
        let manager = makeManager(queries, service, AudioTestGovernor(allowed: true))
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        let task = Task { await manager.startProcessing(audioStream: stream) }
        continuation.yield(Self.sample(at: 10_000, duration: 0.25))
        let started = await eventually { await service.callCount > 0 }
        XCTAssertTrue(started)
        try await Task.sleep(for: .milliseconds(200), clock: .continuous)
        let count = await service.callCount
        XCTAssertEqual(count, 1, "An always-admitting override must not spin on a failing pending row")
        await manager.stopProcessing()
        continuation.finish()
        await task.value
        let pending = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 1)
    }

    private func makeQueries() async throws -> AudioTranscriptionQueries {
        guard let connection = await database.getConnection() else {
            throw DatabaseError.connectionFailed(underlying: "test connection missing")
        }
        return AudioTranscriptionQueries(db: connection)
    }

    private func makeManager(_ queries: AudioTranscriptionQueries, _ service: GovernorTestTranscriber,
                             _ governor: AudioTestGovernor, duration: Double = 0.25) -> AudioProcessingManager {
        AudioProcessingManager(transcriptionService: service, transcriptionQueries: queries,
                               audioWriter: AudioSegmentWriter(storageRoot: root), governor: governor,
                               config: .init(minimumConfidence: 0, maxBufferDuration: duration,
                                             maxQueuedLiveTranscriptionBatches: 1))
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10), clock: .continuous)
        }
        return await condition()
    }

    private static func sample(at time: TimeInterval, duration: Double) -> CapturedAudio {
        let samples = (0..<Int(16_000 * duration)).map { Int16(sin(Double($0) * 0.08) * 1_000) }
        let data = samples.withUnsafeBytes { Data($0) }
        return CapturedAudio(timestamp: Date(timeIntervalSince1970: time), audioData: data,
                             duration: duration, source: .microphone, sampleRate: 16_000, channels: 1)
    }
}

private actor AudioTestGovernor: BackgroundProcessingProtocol {
    private(set) var requestCount = 0
    private var allowed: Bool
    private var current: BackgroundProcessingPermit?
    init(allowed: Bool = false) { self.allowed = allowed }
    func acquire(_ kind: BackgroundProcessingKind) async throws -> BackgroundProcessingPermit {
        requestCount += 1
        while !allowed || current != nil {
            try await Task.sleep(for: .milliseconds(5), clock: .continuous)
        }
        try Task.checkCancellation()
        let permit = BackgroundProcessingPermit(threadCount: 2)
        current = permit
        return permit
    }
    func release(_ permit: BackgroundProcessingPermit) {
        if current?.id == permit.id { current = nil }
    }
    func setAllowed(_ value: Bool) { allowed = value }
    func cancelCurrentAndDefer() { allowed = false; current?.cancellation.cancel() }
}

private actor GovernorTestTranscriber: TranscriptionProtocol {
    private(set) var initializationCount = 0
    private(set) var callCount = 0
    private(set) var cancellationCount = 0
    private(set) var observedThreads: [Int] = []
    private let throwNativeFailure: Bool
    private let throwCancellationImmediately: Bool
    private let holdUntilCancelled: Bool
    private let cancelPermitBeforeReturning: Bool
    init(holdUntilCancelled: Bool = false, cancelPermitBeforeReturning: Bool = false, throwCancellationImmediately: Bool = false, throwNativeFailure: Bool = false) {
        self.throwNativeFailure = throwNativeFailure
        self.throwCancellationImmediately = throwCancellationImmediately
        self.holdUntilCancelled = holdUntilCancelled
        self.cancelPermitBeforeReturning = cancelPermitBeforeReturning
    }
    func initialize() { initializationCount += 1 }
    func transcribe(_ audioData: Data) async throws -> TranscriptionResult {
        .init(text: "The invoice total is twelve dollars.", confidence: 0.9, language: "en", duration: 0.25)
    }
    func transcribeWithTimestamps(_ audioData: Data, wordLevel: Bool, initialPrompt: String?) async throws -> DetailedTranscriptionResult {
        callCount += 1
        if throwCancellationImmediately { throw CancellationError() }
        if throwNativeFailure { throw TranscriptionError.transcriptionFailed }
        observedThreads.append(BackgroundProcessingContext.permit?.threadCount ?? 0)
        if holdUntilCancelled {
            do {
                while true {
                    try BackgroundProcessingContext.checkCancellation()
                    try await Task.sleep(for: .milliseconds(5), clock: .continuous)
                }
            } catch {
                cancellationCount += 1
                throw error
            }
        }
        if cancelPermitBeforeReturning { BackgroundProcessingContext.permit?.cancellation.cancel() }
        return .init(text: "The invoice total is twelve dollars.", words: [], language: "en", duration: 0.25)
    }
    func cleanup() {}
}
