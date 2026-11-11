import Database
import Foundation
import Processing
import Shared
import Storage
import XCTest
@testable import App

/// Real AAC/SQLite surrounds an explicitly held model boundary; no capture devices or models start.
final class ManualRefinementOwnershipTests: XCTestCase {
    func testManualRefinementStillRunsWhilePausedAfterPipelineStop() async throws {
        let fixture = try await makeFixture()
        try await fixture.coordinator.stopPipeline(persistState: false)
        let task = Task { await fixture.coordinator.triggerRefinementNow() }
        await fulfillment(of: [fixture.entered], timeout: 5)
        let during = await fixture.governor.snapshot()
        XCTAssertTrue(during.isRunning, "Explicit refinement must admit despite zero idle time")
        XCTAssertFalse(during.processNow, "Manual ownership does not modify the global override")
        await fixture.gate.release()
        let result = await task.value
        XCTAssertEqual(result.backfillProcessed, 1)
        let pending = try await fixture.queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 0)
        let decoded = try AudioFileDecoder.decodeToPCM(fileURL: fixture.audioURL)
        XCTAssertFalse(decoded.data.isEmpty)
    }

    func testCallerCancellationJoinsNativeWorkAndPreservesPendingRecording() async throws {
        let fixture = try await makeFixture()
        let returned = ManualRefinementFlag()
        let task = Task {
            let result = await fixture.coordinator.triggerRefinementNow()
            await returned.mark()
            return result
        }
        await fulfillment(of: [fixture.entered], timeout: 5)
        task.cancel()
        await fulfillment(of: [fixture.cancelled], timeout: 5)
        let returnedEarly = await returned.value
        XCTAssertFalse(returnedEarly, "Cancelling a caller must still join owned native inference")
        await fixture.gate.release()
        let result = await task.value
        XCTAssertEqual(result.backfillProcessed, 0)
        try await assertPending(fixture)
    }

    func testPipelineStopJoinsManualNativeWorkAndPreservesPendingRecording() async throws {
        let fixture = try await makeFixture()
        let manual = Task { await fixture.coordinator.triggerRefinementNow() }
        await fulfillment(of: [fixture.entered], timeout: 5)
        let stopped = ManualRefinementFlag()
        let stop = Task {
            try await fixture.coordinator.stopPipeline(persistState: false)
            await stopped.mark()
        }
        await fulfillment(of: [fixture.cancelled], timeout: 5)
        let stoppedEarly = await stopped.value
        XCTAssertFalse(stoppedEarly, "Pipeline pause must join manual inference even without active capture")
        await fixture.gate.release()
        try await stop.value
        let result = await manual.value
        XCTAssertEqual(result.backfillProcessed, 0)
        try await assertPending(fixture)
    }

    func testConcurrentManualRequestsJoinOneNativeInferenceAndShareResult() async throws {
        let fixture = try await makeFixture()
        let first = Task { await fixture.coordinator.triggerRefinementNow() }
        await fulfillment(of: [fixture.entered], timeout: 5)
        let duplicateReturned = expectation(description: "duplicate remains joined while native call is held")
        duplicateReturned.isInverted = true
        let second = Task {
            let result = await fixture.coordinator.triggerRefinementNow()
            duplicateReturned.fulfill()
            return result
        }
        await fulfillment(of: [duplicateReturned], timeout: 0.1)
        let heldCalls = await fixture.service.callCount
        XCTAssertEqual(heldCalls, 1)
        await fixture.gate.release()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult.backfillProcessed, 1)
        XCTAssertEqual(secondResult.backfillProcessed, 1, "Both callers join the same completed operation")
        let calls = await fixture.service.callCount
        XCTAssertEqual(calls, 1)
        let rows = try await fixture.queries.getTranscriptionCount()
        XCTAssertEqual(rows, 1)
    }

    private struct Fixture {
        let coordinator: AppCoordinator
        let governor: BackgroundProcessingGovernor
        let queries: AudioTranscriptionQueries
        let service: ManualRefinementTranscriber
        let gate: ManualRefinementGate
        let entered: XCTestExpectation
        let cancelled: XCTestExpectation
        let audioURL: URL
    }

    private func makeFixture() async throws -> Fixture {
        let services = ServiceContainer(inMemory: true)
        let database = await services.database
        try await database.initialize()
        let pointer = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(pointer))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("manual-refinement-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = AudioSegmentWriter(storageRoot: root)
        let samples = (0..<16_000).map { index in
            Int16(sin(2 * Double.pi * 220 * Double(index) / 16_000) * 1_000)
        }
        let pcm = samples.withUnsafeBytes { Data($0) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let (path, size) = try await writer.writeFullBatch(audioData: pcm, sampleRate: 16_000,
            channels: 1, timestamp: start, source: .system)
        _ = try await queries.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(1),
            source: .system, audioPath: path, audioSize: size)
        let entered = expectation(description: "native inference entered")
        // Only cancellation tests wait for this independently owned expectation.
        let cancelled = XCTestExpectation(description: "native inference cancellation requested")
        let gate = ManualRefinementGate(entered: { entered.fulfill() }, cancelled: { cancelled.fulfill() })
        let service = ManualRefinementTranscriber(gate: gate)
        let governor = await services.backgroundProcessing
        await governor.updateEnvironment(.init(idleSeconds: 0))
        let backfill = AudioBackfillManager(transcriptionService: service, transcriptionQueries: queries,
            audioWriter: writer, storageRoot: root, governor: governor)
        await services.installManualRefinementFixture(backfill)
        let coordinator = AppCoordinator(services: services)
        addTeardownBlock {
            await gate.release()
            try? await coordinator.stopPipeline(persistState: false)
            await governor.close()
            try await database.close()
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(coordinator: coordinator, governor: governor, queries: queries, service: service,
            gate: gate, entered: entered, cancelled: cancelled, audioURL: root.appendingPathComponent(path))
    }

    private func assertPending(_ fixture: Fixture) async throws {
        let pending = try await fixture.queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 1)
        let rows = try await fixture.queries.getTranscriptions(from: Date(timeIntervalSince1970: 1_699_999_999),
            to: Date(timeIntervalSince1970: 1_700_000_002))
        XCTAssertTrue(rows.isEmpty, "Cancelled inference cannot publish text")
        let decoded = try AudioFileDecoder.decodeToPCM(fileURL: fixture.audioURL)
        XCTAssertGreaterThan(decoded.duration, 0.9)
        XCTAssertFalse(decoded.data.isEmpty)
        let snapshot = await fixture.governor.snapshot()
        XCTAssertFalse(snapshot.isRunning)
    }
}

private extension ServiceContainer {
    func installManualRefinementFixture(_ backfill: AudioBackfillManager) { audioBackfill = backfill }
}

private actor ManualRefinementFlag {
    private(set) var value = false
    func mark() { value = true }
}

private actor ManualRefinementGate {
    private let entered: @Sendable () -> Void
    private let cancelled: @Sendable () -> Void
    private let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var released = false
    init(entered: @escaping @Sendable () -> Void, cancelled: @escaping @Sendable () -> Void) {
        self.entered = entered; self.cancelled = cancelled
    }
    func hold() async {
        guard !released else { return }
        entered()
        let stream = signal.stream, onCancel = cancelled
        await withTaskCancellationHandler {
            await Task.detached { var iterator = stream.makeAsyncIterator(); _ = await iterator.next() }.value
        } onCancel: { onCancel() }
    }
    func release() { released = true; signal.continuation.yield(()); signal.continuation.finish() }
}

private actor ManualRefinementTranscriber: TranscriptionProtocol {
    let gate: ManualRefinementGate
    private(set) var callCount = 0
    init(gate: ManualRefinementGate) { self.gate = gate }
    func initialize() {}
    func cleanup() {}
    func transcribe(_ data: Data) async throws -> TranscriptionResult {
        let result = try await transcribeWithTimestamps(data, wordLevel: true, initialPrompt: nil)
        return TranscriptionResult(text: result.text, language: result.language, duration: result.duration)
    }
    func transcribeWithTimestamps(_ data: Data, wordLevel: Bool, initialPrompt: String?) async throws -> DetailedTranscriptionResult {
        callCount += 1
        await gate.hold()
        let duration = Double(data.count) / 32_000
        let words = ["Cedar", "meeting", "requires", "approval", "tomorrow."]
        return DetailedTranscriptionResult(text: words.joined(separator: " "), words: words.enumerated().map { index, word in
            TranscriptionWord(word: word, start: Double(index) * duration / Double(words.count),
                end: Double(index + 1) * duration / Double(words.count), confidence: 0.98)
        }, language: "en", duration: duration)
    }
}
