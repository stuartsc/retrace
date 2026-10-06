import CryptoKit
import XCTest
import Database
import Shared
import Storage
@testable import Processing

/// Real private SQLite rows and native decoding; inference/admission are controlled
/// protocol boundaries so the schedule can be verified without running a local model.
final class AudioProcessingFreshnessTests: XCTestCase {
    private var database: DatabaseManager!
    private var queries: AudioTranscriptionQueries!
    private var root: URL!
    private var fixture: Data!
    private var fixtureDuration: TimeInterval = 0
    private var fixtureExtension = "wav"

    override func setUp() async throws {
        let fixtureURL: URL
        let expectedDigest: String
        if let path = ProcessInfo.processInfo.environment["RETRACE_AUDIO_FRESHNESS_FIXTURE_AAC"] {
            // Native AAC acceptance is explicit. An enabled decode failure remains a failure.
            fixtureURL = URL(fileURLWithPath: path)
            fixtureExtension = "m4a"
            expectedDigest = "12d984dc71bad6e5bacab2f8fceb4423911a46e7ae5a23c9c1c41c349f8830dd"
        } else {
            fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "authored", withExtension: "wav",
                subdirectory: "WhisperTimedWords"))
            expectedDigest = "271a49fc227c083978627f4ea436d4f5c155514542d9089390a6885182c3cd00"
        }
        fixture = try Data(contentsOf: fixtureURL)
        let digest = SHA256.hash(data: fixture).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedDigest else {
            throw FreshnessFixtureError.wrongFixture
        }
        let decoded = try AudioFileDecoder.decodeToPCM(fileURL: fixtureURL)
        XCTAssertFalse(decoded.data.isEmpty)
        fixtureDuration = decoded.duration
        database = DatabaseManager(databasePath: "file:audio_freshness_\(UUID().uuidString)?mode=memory&cache=shared")
        try await database.initialize()
        let connection = await database.getConnection()
        queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("audio_freshness_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try await database?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testThreeNewestFirstPassAttemptsThenOldestAlternatesBothBacklogs() async throws {
        let now = Date()
        let repair = try await seed(at: now.addingTimeInterval(-72 * 3_600), status: "needs_repair")
        let oldestPending = try await seed(at: now.addingTimeInterval(-48 * 3_600))
        var recent: [Int64] = []
        for minute in 1...8 { recent.append(try await seed(at: now.addingTimeInterval(Double(-minute * 60)))) }
        let service = FreshnessTestTranscriber()
        let governor = FreshnessTestGovernor()
        let run = start(service: service, governor: governor)
        var remaining = Set(recent + [repair, oldestPending])
        for expected in [recent[0], recent[1], recent[2], repair, recent[3], recent[4], recent[5], oldestPending] {
            let before = remaining
            await governor.grantOne()
            let completed = await eventually { await governor.releaseCount >= 1 }
            XCTAssertTrue(completed)
            remaining = Set(try await queries.getUntranscribedBatches(limit: 100).map(\.id))
            XCTAssertEqual(before.subtracting(remaining), [expected], "Current recordings need three turns, then retained oldest work gets one")
            await governor.resetReleaseCount()
        }
        await stop(run)
        let calls = await service.callCount
        XCTAssertEqual(calls, 8)
        let threads = await service.observedThreads
        XCTAssertEqual(threads, Array(repeating: 2, count: 8), "Selection must preserve the admitted CPU limit")
        let peak = await governor.peakActivePermits
        XCTAssertEqual(peak, 1)
        let storedFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(storedFiles.count, 10, "Scheduling never deletes saved recordings")
    }

    func testNoRecentPendingFallsBackToOldestRepairAndPending() async throws {
        let now = Date()
        let oldest = try await seed(at: now.addingTimeInterval(-72 * 3_600), status: "needs_repair")
        let later = try await seed(at: now.addingTimeInterval(-48 * 3_600))
        let governor = FreshnessTestGovernor()
        let run = start(service: FreshnessTestTranscriber(), governor: governor)
        await governor.grantOne()
        let completed = await eventually { await governor.releaseCount == 1 }
        XCTAssertTrue(completed)
        await stop(run)
        let pending = try await queries.getUntranscribedBatches(limit: 100)
        XCTAssertEqual(pending.map(\.id), [later])
        let completedRows = try await queries.getTranscriptions(from: now.addingTimeInterval(-80 * 3_600), to: now)
        XCTAssertEqual(completedRows.count, 1)
        XCTAssertNotEqual(completedRows.first?.id, oldest)
    }

    func testRecentSelectionStillWaitsForAdmission() async throws {
        let saved = try await seed(at: Date().addingTimeInterval(-60))
        let service = FreshnessTestTranscriber()
        let governor = FreshnessTestGovernor()
        let run = start(service: service, governor: governor)
        let requested = await eventually { await governor.requestCount == 1 }
        XCTAssertTrue(requested)
        let calls = await service.callCount
        let initializations = await service.initializationCount
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(initializations, 0)
        await stop(run)
        let remaining = try await queries.getUntranscribedBatches(limit: 100)
        XCTAssertEqual(remaining.map(\.id), [saved])
    }

    func testCancellationRetainsNewestAndRestartCompletesItExactlyOnce() async throws {
        let now = Date()
        let old = try await seed(at: now.addingTimeInterval(-48 * 3_600))
        let recent = try await seed(at: now.addingTimeInterval(-60))
        let blocked = FreshnessTestTranscriber(hold: true)
        let firstGovernor = FreshnessTestGovernor()
        let first = start(service: blocked, governor: firstGovernor)
        await firstGovernor.grantOne()
        let started = await eventually { await blocked.callCount == 1 }
        XCTAssertTrue(started)
        await firstGovernor.cancelCurrent()
        let released = await eventually { await firstGovernor.releaseCount == 1 }
        XCTAssertTrue(released)
        await stop(first)
        let retained = try await queries.getUntranscribedBatches(limit: 100)
        XCTAssertEqual(Set(retained.map(\.id)), [old, recent], "Revocation leaves both canonical raw rows durable")

        let service = FreshnessTestTranscriber()
        let governor = FreshnessTestGovernor()
        let restarted = start(service: service, governor: governor)
        await governor.grantOne()
        let completed = await eventually { await governor.releaseCount == 1 }
        XCTAssertTrue(completed)
        await stop(restarted)
        let remaining = try await queries.getUntranscribedBatches(limit: 100)
        XCTAssertEqual(remaining.map(\.id), [old])
        let transcripts = try await queries.getTranscriptions(from: now.addingTimeInterval(-120), to: now)
        XCTAssertEqual(transcripts.count, 1)
        let calls = await service.callCount
        XCTAssertEqual(calls, 1)
    }

    func testFailedOldestAttemptBacksOffThenRecentWorkContinues() async throws {
        let now = Date()
        let old = try await seed(at: now.addingTimeInterval(-48 * 3_600))
        var recent: [Int64] = []
        for minute in 1...4 { recent.append(try await seed(at: now.addingTimeInterval(Double(-minute * 60)))) }
        let service = FreshnessTestTranscriber(failCalls: [4])
        let governor = FreshnessTestGovernor()
        let run = start(service: service, governor: governor)
        for turn in 1...4 {
            await governor.grantOne()
            let completed = await eventually { await governor.releaseCount == turn }
            XCTAssertTrue(completed)
        }
        await governor.grantOne()
        try await Task.sleep(for: .milliseconds(150), clock: .continuous)
        let earlyCalls = await service.callCount
        XCTAssertEqual(earlyCalls, 4, "Existing five-second error backoff must remain in force")
        let resumed = await eventually(timeout: .seconds(7)) { await governor.releaseCount == 5 }
        XCTAssertTrue(resumed, "A failed old attempt must not repeatedly consume every recent turn")
        await stop(run)
        let remaining = try await queries.getUntranscribedBatches(limit: 100)
        XCTAssertEqual(remaining.map(\.id), [old])
        let calls = await service.callCount
        XCTAssertEqual(calls, 5)
    }

    func testDeletionDuringSelectedInferenceCannotRestoreRecentAudio() async throws {
        let now = Date()
        let old = try await seed(at: now.addingTimeInterval(-48 * 3_600))
        let recent = try await seed(at: now.addingTimeInterval(-60))
        let service = FreshnessTestTranscriber(hold: true)
        let governor = FreshnessTestGovernor()
        let run = start(service: service, governor: governor)
        await governor.grantOne()
        let started = await eventually { await service.callCount == 1 }
        XCTAssertTrue(started)
        try await queries.deleteTranscription(id: recent)
        await service.allowCompletion()
        let released = await eventually { await governor.releaseCount == 1 }
        XCTAssertTrue(released)
        await stop(run)
        let remaining = try await queries.getUntranscribedBatches(limit: 100)
        XCTAssertEqual(remaining.map(\.id), [old])
        let recentRows = try await queries.getTranscriptions(from: now.addingTimeInterval(-120), to: now, includeActivityRows: true)
        XCTAssertTrue(recentRows.isEmpty)
    }

    func testCancelledOldestAttemptConsumesItsTurnWithinSameManager() async throws {
        let now = Date()
        let old = try await seed(at: now.addingTimeInterval(-48 * 3_600))
        for minute in 1...4 { _ = try await seed(at: now.addingTimeInterval(Double(-minute * 60))) }
        let service = FreshnessTestTranscriber()
        let governor = FreshnessTestGovernor()
        let run = start(service: service, governor: governor)
        for turn in 1...3 {
            await governor.grantOne()
            let released = await eventually { await governor.releaseCount == turn }
            XCTAssertTrue(released)
        }
        await service.holdCompletion()
        await governor.grantOne()
        let enteredOldest = await eventually { await service.callCount == 4 }
        XCTAssertTrue(enteredOldest)
        await governor.cancelCurrent()
        let cancelled = await eventually { await governor.releaseCount == 4 }
        XCTAssertTrue(cancelled)
        await service.allowCompletion()
        await governor.grantOne()
        let resumedRecent = await eventually { await governor.releaseCount == 5 }
        XCTAssertTrue(resumedRecent)
        await stop(run)
        let remaining = try await queries.getUntranscribedBatches(limit: 100)
        XCTAssertEqual(remaining.map(\.id), [old], "Cancellation retains the oldest row but does not monopolize later turns")
    }

    func testEmptyQueueReleasesPermitWithoutInitializingModel() async throws {
        let service = FreshnessTestTranscriber()
        let governor = FreshnessTestGovernor()
        let run = start(service: service, governor: governor)
        await governor.grantOne()
        let released = await eventually { await governor.releaseCount == 1 }
        XCTAssertTrue(released)
        await stop(run)
        let calls = await service.callCount
        let initializations = await service.initializationCount
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(initializations, 0)
    }

    func testReverseRecentWindowsAndOldLaneHopPreserveWordsTimesAndEmptyPrompt() async throws {
        let newestStart = Date().addingTimeInterval(-60)
        let old = try await seed(at: newestStart.addingTimeInterval(-48 * 3_600))
        // These windows overlap by the production five seconds, but will be selected
        // backwards. Repeated leading/trailing words would be wrongly removed if the
        // worker reused its previous window without checking forward adjacency.
        let stride = fixtureDuration - 5
        var recent: [Int64] = []
        for offset in 0..<4 {
            recent.append(try await seed(at: newestStart.addingTimeInterval(-Double(offset) * stride)))
        }
        let originals = try await queries.getUntranscribedBatches(limit: 10)
        var words: [TranscriptionWord] = []
        for (group, start) in [0.0, stride].enumerated() {
            for (index, value) in ["Keep", "every", "captured", group == 0 ? "word" : "word."].enumerated() {
                let time = start + Double(index) * 0.45
                words.append(.init(word: value, start: time, end: time + 0.4, confidence: 0.9))
            }
        }
        let service = FreshnessTestTranscriber(words: words)
        let governor = FreshnessTestGovernor()
        let run = start(service: service, governor: governor)
        var previousPending = Set(originals.map(\.id))
        let order = [recent[0], recent[1], recent[2], old, recent[3]]
        for (turn, expected) in order.enumerated() {
            await governor.grantOne()
            let completed = await eventually { await governor.releaseCount == turn + 1 }
            XCTAssertTrue(completed)
            let pending = Set(try await queries.getUntranscribedBatches(limit: 10).map(\.id))
            XCTAssertEqual(previousPending.subtracting(pending), [expected])
            previousPending = pending
        }
        await stop(run)
        let rows = try await queries.getTranscriptions(from: newestStart.addingTimeInterval(-49 * 3_600),
            to: newestStart.addingTimeInterval(fixtureDuration + 1), limit: 100)
        XCTAssertEqual(rows.count, 10)
        for original in originals {
            let sentences = rows.filter { $0.batchAudioPath == original.audioPath }.sorted { $0.startTime < $1.startTime }
            XCTAssertEqual(sentences.map(\.text), ["Keep every captured word", "Keep every captured word."])
            guard sentences.count == 2 else { continue }
            for (index, expectedStart) in [0.0, stride].enumerated() {
                XCTAssertEqual(sentences[index].startTime.timeIntervalSince(original.startTime), expectedStart, accuracy: 0.002)
                XCTAssertEqual(sentences[index].endTime.timeIntervalSince(original.startTime), expectedStart + 1.75, accuracy: 0.002)
                XCTAssertEqual(sentences[index].audioPath, original.audioPath)
                XCTAssertEqual(sentences[index].source, original.source)
            }
        }
        let calls = await service.callCount
        let promptedCalls = await service.nonNilPromptCount
        XCTAssertEqual(calls, 5)
        XCTAssertEqual(promptedCalls, 0, "An old-lane hop must not feed old transcript text to the next live pass")
    }

    func testStopDuringAdmittedInferenceJoinsCancellationAndKeepsRawPending() async throws {
        let now = Date()
        let old = try await seed(at: now.addingTimeInterval(-48 * 3_600))
        let recent = try await seed(at: now.addingTimeInterval(-60))
        let service = FreshnessTestTranscriber(hold: true, holdCancellationCleanup: true)
        let governor = FreshnessTestGovernor()
        let run = start(service: service, governor: governor)
        await governor.grantOne()
        let entered = await eventually { await service.callCount == 1 }
        XCTAssertTrue(entered)
        let returnedBeforeCleanup = expectation(description: "Stop cannot return before the inference cleanup tail")
        returnedBeforeCleanup.isInverted = true
        let stopped = FreshnessStopReceipt()
        let stopTask = Task {
            await run.manager.stopProcessing()
            await stopped.finish()
            if !(await service.cancellationCleanupReleased) { returnedBeforeCleanup.fulfill() }
        }
        let cleaningUp = await eventually { await service.cancellationCleanupEntered }
        XCTAssertTrue(cleaningUp, "Stopping must cancel admitted inference")
        await fulfillment(of: [returnedBeforeCleanup], timeout: 0.1)
        let stoppedWhileHeld = await stopped.isFinished
        let releasedWhileHeld = await governor.releaseCount
        XCTAssertFalse(stoppedWhileHeld, "stopProcessing must own the inference drain")
        XCTAssertEqual(releasedWhileHeld, 0)
        await service.releaseCancellationCleanup()
        // Keep a broken owner drainable after the join assertions have been made.
        await service.allowCompletion()
        await stopTask.value
        // Inspect the stop contract before the test itself joins the outer stream task.
        let released = await governor.releaseCount
        let cancellationSet = await governor.lastReleasedCancellation
        XCTAssertEqual(released, 1)
        XCTAssertTrue(cancellationSet, "Task shutdown must revoke the native permit as well as stop admission")
        let pending = try await queries.getUntranscribedBatches(limit: 10)
        XCTAssertEqual(Set(pending.map(\.id)), [old, recent])
        let visible = try await queries.getTranscriptions(from: now.addingTimeInterval(-49 * 3_600), to: now)
        XCTAssertTrue(visible.isEmpty)
        run.continuation.finish()
        await run.task.value
    }

    private func seed(at date: Date, status: String = "pending") async throws -> Int64 {
        let path = "batch_\(UUID().uuidString)_microphone.\(fixtureExtension)"
        try fixture.write(to: root.appendingPathComponent(path))
        let id = try await queries.insertRawBatch(startTime: date, endTime: date.addingTimeInterval(fixtureDuration),
            source: .microphone, audioPath: path, audioSize: Int64(fixture.count))
        if status != "pending" {
            try await queries.updateBatchOutcome(id: id, text: "", transcriptStatus: status,
                detectedLanguage: nil, audioVariant: "raw", qualityFlags: nil)
        }
        return id
    }

    private func start(service: FreshnessTestTranscriber, governor: FreshnessTestGovernor) -> FreshnessTestRun {
        let manager = AudioProcessingManager(transcriptionService: service, transcriptionQueries: queries,
            audioWriter: AudioSegmentWriter(storageRoot: root), governor: governor,
            config: .init(minimumConfidence: 0, maxQueuedLiveTranscriptionBatches: 1))
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        let task = Task { await manager.startProcessing(audioStream: stream) }
        return FreshnessTestRun(manager: manager, task: task, continuation: continuation)
    }

    private func stop(_ run: FreshnessTestRun) async {
        await run.manager.stopProcessing()
        run.continuation.finish()
        await run.task.value
    }

    private func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5), clock: .continuous)
        }
        return await condition()
    }
}

private enum FreshnessFixtureError: Error { case wrongFixture }
private actor FreshnessStopReceipt {
    private(set) var isFinished = false
    func finish() { isFinished = true }
}
private struct FreshnessTestRun {
    let manager: AudioProcessingManager
    let task: Task<Void, Never>
    let continuation: AsyncStream<CapturedAudio>.Continuation
}

private actor FreshnessTestGovernor: BackgroundProcessingProtocol {
    private var grants = 0
    private var current: BackgroundProcessingPermit?
    private(set) var releaseCount = 0
    private(set) var requestCount = 0
    private(set) var peakActivePermits = 0
    private(set) var lastReleasedCancellation = false

    func acquire(_ kind: BackgroundProcessingKind) async throws -> BackgroundProcessingPermit {
        requestCount += 1
        while grants == 0 || current != nil {
            try await Task.sleep(for: .milliseconds(5), clock: .continuous)
        }
        try Task.checkCancellation()
        grants -= 1
        let permit = BackgroundProcessingPermit(threadCount: 2)
        current = permit
        peakActivePermits = max(peakActivePermits, 1)
        return permit
    }
    func release(_ permit: BackgroundProcessingPermit) {
        if current?.id == permit.id {
            lastReleasedCancellation = permit.cancellation.isCancelled
            current = nil
            releaseCount += 1
        }
    }
    func grantOne() { grants += 1 }
    func resetReleaseCount() { releaseCount = 0 }
    func cancelCurrent() { current?.cancellation.cancel() }
}

private actor FreshnessTestTranscriber: TranscriptionProtocol {
    private var hold: Bool
    private let failCalls: Set<Int>
    private let words: [TranscriptionWord]
    private let holdCancellationCleanup: Bool
    private var cancellationCleanupContinuation: CheckedContinuation<Void, Never>?
    private(set) var cancellationCleanupEntered = false
    private(set) var cancellationCleanupReleased = false
    private(set) var callCount = 0
    private(set) var initializationCount = 0
    private(set) var observedThreads: [Int] = []
    private(set) var nonNilPromptCount = 0

    init(hold: Bool = false, failCalls: Set<Int> = [], words: [TranscriptionWord] = [], holdCancellationCleanup: Bool = false) {
        self.hold = hold
        self.failCalls = failCalls
        self.words = words
        self.holdCancellationCleanup = holdCancellationCleanup
    }
    func initialize() { initializationCount += 1 }
    func transcribe(_ audioData: Data) async throws -> TranscriptionResult {
        .init(text: "The invoice total is twelve dollars.", confidence: 0.9, language: "en", duration: 1)
    }
    func transcribeWithTimestamps(_ audioData: Data, wordLevel: Bool, initialPrompt: String?) async throws -> DetailedTranscriptionResult {
        callCount += 1
        if initialPrompt != nil { nonNilPromptCount += 1 }
        observedThreads.append(BackgroundProcessingContext.permit?.threadCount ?? 0)
        XCTAssertFalse(audioData.isEmpty, "The admitted job must decode actual retained authored audio")
        if failCalls.contains(callCount) { throw TranscriptionError.transcriptionFailed }
        do {
            while hold {
                try BackgroundProcessingContext.checkCancellation()
                try await Task.sleep(for: .milliseconds(5), clock: .continuous)
            }
            try BackgroundProcessingContext.checkCancellation()
        } catch {
            if holdCancellationCleanup {
                cancellationCleanupEntered = true
                if !cancellationCleanupReleased {
                    await withCheckedContinuation { cancellationCleanupContinuation = $0 }
                }
            }
            throw error
        }
        let text = words.isEmpty ? "The invoice total is twelve dollars." : words.map(\.word).joined(separator: " ")
        return .init(text: text, words: words, language: "en", duration: 1)
    }
    func allowCompletion() { hold = false }
    func holdCompletion() { hold = true }
    func releaseCancellationCleanup() {
        cancellationCleanupReleased = true
        cancellationCleanupContinuation?.resume()
        cancellationCleanupContinuation = nil
    }
    func cleanup() {}
}
