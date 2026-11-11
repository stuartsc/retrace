import Database
import Foundation
import Shared
import Storage
import XCTest
@testable import Processing

/// Real PCM, native AAC writer/decoder and SQLite surround a controlled model
/// boundary. These are ownership/recovery tests, not speech accuracy tests.
final class AudioProcessingLifecycleTests: XCTestCase {
    func testCallerCancellationAndExplicitStopJoinHeldPostCommitDelivery() async throws {
        let entered = expectation(description: "durable callback entered")
        let cancelled = expectation(description: "callback cancellation requested")
        let gate = AudioLifecycleGate(entered: { entered.fulfill() }, cancelled: { cancelled.fulfill() })
        let sink = AudioLifecycleReceipts()
        let fixture = try await makeFixture(service: AudioLifecycleTranscriber(), gate: gate) { receipt, rows in
            await sink.append(receipt, rowCount: rows)
            await gate.hold()
        }
        let input = AsyncStream<CapturedAudio>.makeStream(bufferingPolicy: .bufferingOldest(8))
        let processingReturned = AudioLifecycleFlag()
        let processing = Task {
            await fixture.manager.startProcessing(audioStream: input.stream)
            await processingReturned.set()
        }
        input.continuation.yield(Self.sample(at: 1_000))
        await fulfillment(of: [entered], timeout: 5)
        let rowsBeforeStop = await sink.rowCounts
        XCTAssertGreaterThan(rowsBeforeStop.first ?? 0, 0, "The held receipt must follow actual SQLite insertion")
        processing.cancel()
        await fulfillment(of: [cancelled], timeout: 5)
        let stoppingReturned = AudioLifecycleFlag()
        let stopping = Task { await fixture.manager.stopProcessing(); await stoppingReturned.set() }
        let pendingProcessing = await fixture.manager.isCurrentlyProcessing
        let callerReturnedEarly = await processingReturned.value
        let stopReturnedEarly = await stoppingReturned.value
        XCTAssertTrue(pendingProcessing)
        XCTAssertFalse(callerReturnedEarly, "Caller cancellation cannot detach an entered callback")
        XCTAssertFalse(stopReturnedEarly)
        await gate.release()
        await stopping.value
        await processing.value
        let processingAfterStop = await fixture.manager.isCurrentlyProcessing
        let pendingRows = try await fixture.queries.getUntranscribedBatchCount()
        let receipts = await sink.values
        XCTAssertFalse(processingAfterStop)
        XCTAssertEqual(pendingRows, 0, "Committed batch cleanup is also joined before database close")
        XCTAssertEqual(receipts.count, 1)
        await fixture.manager.stopProcessing()
        let afterIdempotentStop = await sink.values.count
        XCTAssertEqual(afterIdempotentStop, 1)
    }

    func testExplicitStopWaitsForCallbackEvenAfterInputHasEnded() async throws {
        let entered = expectation(description: "natural drain callback entered")
        let cancelled = expectation(description: "stop reaches draining worker")
        let gate = AudioLifecycleGate(entered: { entered.fulfill() }, cancelled: { cancelled.fulfill() })
        let fixture = try await makeFixture(service: AudioLifecycleTranscriber(), gate: gate) { _, _ in await gate.hold() }
        let input = AsyncStream<CapturedAudio>.makeStream()
        input.continuation.yield(Self.sample(at: 2_000)); input.continuation.finish()
        let processing = Task { await fixture.manager.startProcessing(audioStream: input.stream) }
        await fulfillment(of: [entered], timeout: 5)
        let finished = AudioLifecycleFlag()
        let stop = Task { await fixture.manager.stopProcessing(); await finished.set() }
        await fulfillment(of: [cancelled], timeout: 5)
        let returnedEarly = await finished.value
        XCTAssertFalse(returnedEarly)
        await gate.release()
        await stop.value; await processing.value
        let running = await fixture.manager.isCurrentlyProcessing
        XCTAssertFalse(running)
    }

    func testStopPreservesDiskBacklogAndRestartCannotOverlapOrLoseWorkerOwnership() async throws {
        let entered = expectation(description: "first model call held")
        let cancelled = expectation(description: "old model cancellation requested")
        let gate = AudioLifecycleGate(entered: { entered.fulfill() }, cancelled: { cancelled.fulfill() })
        let service = AudioLifecycleTranscriber(firstGate: gate)
        let sink = AudioLifecycleReceipts()
        let fixture = try await makeFixture(service: service, gate: gate, maximumQueued: 1) { receipt, rows in
            await sink.append(receipt, rowCount: rows)
        }
        let input = AsyncStream<CapturedAudio>.makeStream(bufferingPolicy: .bufferingOldest(8))
        let old = Task { await fixture.manager.startProcessing(audioStream: input.stream) }
        input.continuation.yield(Self.sample(at: 3_000))
        await fulfillment(of: [entered], timeout: 5)
        input.continuation.yield(Self.sample(at: 3_010))
        input.continuation.yield(Self.sample(at: 3_020))
        let persisted = try await waitForPending(fixture.queries, count: 3)
        XCTAssertEqual(persisted, 3)
        let stop = Task { await fixture.manager.stopProcessing() }
        await fulfillment(of: [cancelled], timeout: 5)
        let nextInput = AsyncStream<CapturedAudio>.makeStream()
        nextInput.continuation.yield(Self.sample(at: 4_000)); nextInput.continuation.finish()
        let next = Task { await fixture.manager.startProcessing(audioStream: nextInput.stream) }
        let beforeRelease = await service.callCount
        XCTAssertEqual(beforeRelease, 1)
        let beforeReceipts = await sink.values
        XCTAssertTrue(beforeReceipts.isEmpty, "The cancelled model call has not published any transcript")
        let retained = try await fixture.queries.getUntranscribedBatches(limit: 10)
        XCTAssertEqual(retained.map(\.startTime), [3_000, 3_010, 3_020].map { Date(timeIntervalSince1970: $0) })
        for batch in retained {
            let url = fixture.root.appendingPathComponent(batch.audioPath)
            let decoded = try await Task.detached { try AudioFileDecoder.decodeToPCM(fileURL: url) }.value
            XCTAssertFalse(decoded.data.isEmpty, "Cancellation preserves canonical AAC before a successor is admitted")
            XCTAssertGreaterThan(decoded.duration, 0.9)
        }
        await gate.release()
        await stop.value; await old.value; await next.value
        let maximum = await service.maximumActiveCalls
        let allCalls = await service.callCount
        let receipts = await sink.values
        let expectedTimes = [3_000, 3_010, 3_020, 4_000].map { Date(timeIntervalSince1970: $0) }
        XCTAssertEqual(maximum, 1, "New work cannot run beside a retiring cancelled worker")
        XCTAssertEqual(allCalls, 5, "The cancelled first attempt is retried, three retained batches recover, and fresh capture is processed")
        XCTAssertEqual(receipts.map(\.startedAt), expectedTimes,
                       "Only the successor commits each retained recording and the fresh batch, exactly once")
        XCTAssertEqual(Set(receipts.map(\.startedAt)).count, 4)
        let pending = try await fixture.queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 0, "Restart independently recovers the durable first-pass backlog")
        let rows = try await fixture.queries.getTranscriptions(from: Date(timeIntervalSince1970: 2_999),
            to: Date(timeIntervalSince1970: 4_002), limit: 20)
        XCTAssertEqual(rows.map(\.startTime).sorted(), expectedTimes)
        let paths = Set(rows.compactMap(\.audioPath))
        XCTAssertEqual(paths.count, 4)
        XCTAssertTrue(Set(retained.map(\.audioPath)).isSubset(of: paths), "Recovered transcripts keep their original canonical media")
        for path in paths {
            let url = fixture.root.appendingPathComponent(path)
            let decoded = try await Task.detached { try AudioFileDecoder.decodeToPCM(fileURL: url) }.value
            XCTAssertFalse(decoded.data.isEmpty, "Publication retires only the placeholder, never the recording")
            XCTAssertGreaterThan(decoded.duration, 0.9)
        }
        let running = await fixture.manager.isCurrentlyProcessing
        XCTAssertFalse(running)
    }

    func testDuplicateStartJoinsExistingStreamUntilItsWorkerCompletes() async throws {
        let entered = expectation(description: "original worker held")
        let gate = AudioLifecycleGate(entered: { entered.fulfill() })
        let service = AudioLifecycleTranscriber(firstGate: gate)
        let sink = AudioLifecycleReceipts()
        let fixture = try await makeFixture(service: service, gate: gate) { receipt, rows in
            await sink.append(receipt, rowCount: rows)
        }
        let firstInput = AsyncStream<CapturedAudio>.makeStream()
        firstInput.continuation.yield(Self.sample(at: 5_000)); firstInput.continuation.finish()
        let first = Task { await fixture.manager.startProcessing(audioStream: firstInput.stream) }
        await fulfillment(of: [entered], timeout: 5)
        let unused = AsyncStream<CapturedAudio>.makeStream()
        unused.continuation.yield(Self.sample(at: 9_000)); unused.continuation.finish()
        let duplicateReturned = expectation(description: "duplicate must await original ownership")
        duplicateReturned.isInverted = true
        let duplicate = Task {
            await fixture.manager.startProcessing(audioStream: unused.stream)
            duplicateReturned.fulfill()
        }
        await fulfillment(of: [duplicateReturned], timeout: 0.1)
        await gate.release()
        await first.value; await duplicate.value
        let calls = await service.callCount
        let receipts = await sink.values
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(receipts.map(\.startedAt), [Date(timeIntervalSince1970: 5_000)])
    }

    func testStopQueuedRestartThenSecondStopLeavesNoSuccessorRunning() async throws {
        let entered = expectation(description: "old model held")
        let cancelled = expectation(description: "first stop entered")
        let gate = AudioLifecycleGate(entered: { entered.fulfill() }, cancelled: { cancelled.fulfill() })
        let fixture = try await makeFixture(service: AudioLifecycleTranscriber(firstGate: gate), gate: gate) { _, _ in }
        let originalInput = AsyncStream<CapturedAudio>.makeStream()
        originalInput.continuation.yield(Self.sample(at: 5_500))
        let originalReturned = expectation(description: "old stream retired")
        let original = Task {
            await fixture.manager.startProcessing(audioStream: originalInput.stream)
            originalReturned.fulfill()
        }
        await fulfillment(of: [entered], timeout: 5)
        let firstStop = Task { await fixture.manager.stopProcessing() }
        await fulfillment(of: [cancelled], timeout: 5)
        let firstStopID = await fixture.manager.lifecycleRegistrationID
        let newInput = AsyncStream<CapturedAudio>.makeStream()
        let restartedInputCancelled = expectation(description: "second stop cancels the successor input")
        newInput.continuation.onTermination = { _ in restartedInputCancelled.fulfill() }
        let restartReturned = expectation(description: "successor fully retired")
        let restart = Task {
            await fixture.manager.startProcessing(audioStream: newInput.stream)
            restartReturned.fulfill()
        }
        let restartID = await waitForRegistration(fixture.manager, after: firstStopID)
        XCTAssertNotEqual(restartID, firstStopID)
        let lastStopReturned = expectation(description: "last ordered stop returned")
        let lastStop = Task { await fixture.manager.stopProcessing(); lastStopReturned.fulfill() }
        let lastStopID = await waitForRegistration(fixture.manager, after: restartID)
        XCTAssertNotEqual(lastStopID, restartID)
        await gate.release()
        await fulfillment(of: [originalReturned, restartReturned, lastStopReturned, restartedInputCancelled], timeout: 5)
        let stillRunning = await fixture.manager.isCurrentlyProcessing
        XCTAssertFalse(stillRunning, "A stop registered after restart must retire the successor, not just the old session")
        // Failure cleanup is bounded by ordinary AsyncStream cancellation; never
        // leave a successor iterator hanging after an ordering assertion fails.
        restart.cancel()
        await fixture.manager.stopProcessing()
        await firstStop.value; await original.value; await restart.value; await lastStop.value
        let pending = try await fixture.queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 1, "The cancelled old model batch stays recoverable on disk")
    }

    func testStopClearsPartialPCMAndOverlapBeforeRestart() async throws {
        let pulledAgain = expectation(description: "partial sample accumulated before next input pull")
        let feed = PartialAudioLifecycleFeed(sample: Self.sample(at: 6_000, duration: 0.4),
                                             waiting: { pulledAgain.fulfill() })
        let service = AudioLifecycleTranscriber()
        let sink = AudioLifecycleReceipts()
        let fixture = try await makeFixture(service: service) { receipt, rows in await sink.append(receipt, rowCount: rows) }
        let stream = AsyncStream<CapturedAudio>(unfolding: { await feed.next() })
        let first = Task { await fixture.manager.startProcessing(audioStream: stream) }
        await fulfillment(of: [pulledAgain], timeout: 5)
        await fixture.manager.stopProcessing(); await first.value
        let cancelledPending = try await fixture.queries.getUntranscribedBatchCount()
        XCTAssertEqual(cancelledPending, 0, "An incomplete cancelled buffer is cleared without inventing a batch")
        let next = AsyncStream<CapturedAudio>.makeStream()
        next.continuation.yield(Self.sample(at: 7_000, duration: 0.7)); next.continuation.finish()
        await fixture.manager.startProcessing(audioStream: next.stream)
        let receipts = await sink.values
        let bytes = await service.byteCounts
        XCTAssertEqual(receipts.count, 1)
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipt.startedAt, Date(timeIntervalSince1970: 7_000))
        XCTAssertEqual(receipt.endedAt.timeIntervalSince(receipt.startedAt), 0.7, accuracy: 0.001)
        XCTAssertEqual(bytes, [Int(0.7 * 16_000) * MemoryLayout<Int16>.size], "No prior-session PCM reaches the new decoder")
    }

    private struct Fixture {
        let root: URL
        let queries: AudioTranscriptionQueries
        let manager: AudioProcessingManager
    }

    private func makeFixture(service: AudioLifecycleTranscriber, gate: AudioLifecycleGate? = nil,
                             maximumQueued: Int = 2,
                             callback: @escaping @Sendable (AudioTranscriptCommitReceipt, Int) async -> Void) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-audio-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = DatabaseManager(databasePath: root.appendingPathComponent("history.sqlite").path)
        do { try await database.initialize() } catch {
            try? FileManager.default.removeItem(at: root); throw error
        }
        let queries = try await database.audioLifecycleQueries()
        let manager = AudioProcessingManager(transcriptionService: service, transcriptionQueries: queries,
            audioWriter: AudioSegmentWriter(storageRoot: root),
            config: .init(maxBufferDuration: 1, maxQueuedLiveTranscriptionBatches: maximumQueued,
                committedTranscriptionCallback: { receipt in
                    let rows = (try? await queries.getTranscriptions(from: receipt.startedAt,
                        to: receipt.endedAt, limit: 100)) ?? []
                    await callback(receipt, rows.count)
                }))
        addTeardownBlock {
            await gate?.release()
            await manager.stopProcessing()
            try await database.close()
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(root: root, queries: queries, manager: manager)
    }

    private func waitForRegistration(_ manager: AudioProcessingManager, after previous: UUID) async -> UUID {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var current = await manager.lifecycleRegistrationID
        while current == previous, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10), clock: .continuous)
            current = await manager.lifecycleRegistrationID
        }
        return current
    }

    private func waitForPending(_ queries: AudioTranscriptionQueries, count: Int) async throws -> Int {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var found = 0
        while ContinuousClock.now < deadline {
            found = try await queries.getUntranscribedBatchCount()
            if found >= count { break }
            try await Task.sleep(for: .milliseconds(20), clock: .continuous)
        }
        return found
    }

    private static func sample(at timestamp: TimeInterval, duration: TimeInterval = 1) -> CapturedAudio {
        let samples = (0..<Int(duration * 16_000)).map { i in
            Int16(8_000 * sin(Double(i) * 2 * .pi * 220 / 16_000))
        }
        return CapturedAudio(timestamp: Date(timeIntervalSince1970: timestamp),
            audioData: samples.withUnsafeBytes { Data($0) }, duration: duration, source: .microphone)
    }
}

private actor AudioLifecycleFlag {
    private(set) var value = false
    func set() { value = true }
}

private actor AudioLifecycleReceipts {
    private(set) var values: [AudioTranscriptCommitReceipt] = []
    private(set) var rowCounts: [Int] = []
    func append(_ receipt: AudioTranscriptCommitReceipt, rowCount: Int) { values.append(receipt); rowCounts.append(rowCount) }
}

private actor AudioLifecycleGate {
    private let entered: @Sendable () -> Void
    private let cancelled: @Sendable () -> Void
    private let releaseSignal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var released = false
    init(entered: @escaping @Sendable () -> Void, cancelled: @escaping @Sendable () -> Void = {}) {
        self.entered = entered; self.cancelled = cancelled
    }
    func hold() async {
        guard !released else { return }
        entered()
        let stream = releaseSignal.stream, cancellation = cancelled
        await withTaskCancellationHandler {
            await Task.detached { var iterator = stream.makeAsyncIterator(); _ = await iterator.next() }.value
        } onCancel: { cancellation() }
    }
    func release() { released = true; releaseSignal.continuation.yield(()); releaseSignal.continuation.finish() }
}

private actor PartialAudioLifecycleFeed {
    private var sample: CapturedAudio?
    private let waiting: @Sendable () -> Void
    init(sample: CapturedAudio, waiting: @escaping @Sendable () -> Void) { self.sample = sample; self.waiting = waiting }
    func next() async -> CapturedAudio? {
        if let sample { self.sample = nil; return sample }
        waiting()
        try? await Task.sleep(for: .seconds(30), clock: .continuous)
        return nil
    }
}

private actor AudioLifecycleTranscriber: TranscriptionProtocol {
    let firstGate: AudioLifecycleGate?
    private(set) var callCount = 0
    private(set) var maximumActiveCalls = 0
    private(set) var byteCounts: [Int] = []
    private var activeCalls = 0
    init(firstGate: AudioLifecycleGate? = nil) { self.firstGate = firstGate }
    func initialize() {}
    func cleanup() {}
    func transcribe(_ data: Data) async throws -> TranscriptionResult {
        let result = try await transcribeWithTimestamps(data, wordLevel: true, initialPrompt: nil)
        return TranscriptionResult(text: result.text, language: result.language, duration: result.duration)
    }
    func transcribeWithTimestamps(_ data: Data, wordLevel: Bool, initialPrompt: String?) async throws -> DetailedTranscriptionResult {
        callCount += 1; activeCalls += 1; maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        byteCounts.append(data.count)
        defer { activeCalls -= 1 }
        if callCount == 1 { await firstGate?.hold() }
        let duration = Double(data.count) / (16_000 * 2)
        let text = "Captured Cedar discussion requires approval tomorrow."
        let parts = text.split(separator: " ")
        let words = parts.enumerated().map { index, word in
            TranscriptionWord(word: String(word), start: Double(index) * duration / Double(parts.count),
                end: Double(index + 1) * duration / Double(parts.count), confidence: 0.98)
        }
        return DetailedTranscriptionResult(text: text, words: words, language: "en", duration: duration)
    }
}

private extension DatabaseManager {
    func audioLifecycleQueries() throws -> AudioTranscriptionQueries {
        AudioTranscriptionQueries(db: try XCTUnwrap(getConnection()))
    }
}
