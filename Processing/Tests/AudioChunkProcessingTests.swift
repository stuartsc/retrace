import Database
import CryptoKit
import Foundation
import Shared
import SQLCipher
import Storage
import XCTest
@testable import Processing

/// Actual native AAC, durable manifests and private SQLite surround an authored
/// timed-word model boundary. These prove ownership, not recognition quality.
final class AudioChunkProcessingTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_010_000.125)

    func testLiveCaptureStoresThreeChunksAndBuildsOverlapOnlyForInference() async throws {
        let fixture = try await makeFixture()
        let model = ChunkTranscriptModel()
        let manager = fixture.manager(model: model, enabled: true)
        let input = AsyncStream<CapturedAudio>.makeStream()
        input.continuation.yield(capture(frames: 480_000, source: .zoom))
        input.continuation.finish()
        await manager.startProcessing(audioStream: input.stream)

        let rows = try await fixture.rows()
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.source == .zoom && $0.text == "Cedar amount seven approved today." })
        let paths = Set(rows.compactMap(\.batchAudioPath))
        XCTAssertEqual(paths.count, 3)
        var windows: [StoredAudioWindow] = []
        for path in paths {
            let stored = try await fixture.queries.storedAudioWindow(forPath: path)
            windows.append(try XCTUnwrap(stored))
        }
        windows.sort { $0.manifest.startFrame < $1.manifest.startFrame }
        XCTAssertEqual(windows.map { $0.manifest.frameCount }, [160_000, 240_000, 240_000])
        XCTAssertEqual(windows.map { $0.manifest.ownedStartFrame }, [0, 80_000, 80_000])
        XCTAssertEqual(windows.map { $0.manifest.ranges.map(\.offsetFrames) }, [[0], [80_000, 0], [80_000, 0]])
        XCTAssertEqual(windows.map { $0.manifest.ranges.map(\.frameCount) }, [[160_000], [80_000, 160_000], [80_000, 160_000]])
        XCTAssertEqual(windows.map { $0.manifest.ranges.map { $0.chunk.startFrame } }, [[0], [0, 160_000], [160_000, 320_000]])
        XCTAssertEqual(windows.compactMap { $0.manifest.ranges.last?.chunk.frameCount }.reduce(0, +), 480_000)
        let chunkPaths = Set(windows.flatMap { $0.manifest.ranges.map { $0.chunk.relativePath } })
        XCTAssertEqual(chunkPaths.count, 3, "Context must reference prior media rather than encode it again")
        let callSizes = await model.inputSizes
        XCTAssertEqual(callSizes.sorted(), [320_000, 480_000, 480_000])
        let timingRequests = await model.wordTimingRequests
        XCTAssertEqual(timingRequests, [true, true, true], "Exact ownership requires native word timestamps during first pass")
        for row in rows {
            let window = try XCTUnwrap(windows.first { $0.relativePath == row.batchAudioPath })
            XCTAssertGreaterThanOrEqual(row.startTime, window.manifest.ownedStartTime)
            XCTAssertLessThanOrEqual(row.endTime, window.manifest.endTime)
            XCTAssertEqual(row.audioPath, window.relativePath)
        }
        let leased = await fixture.media.activeLeaseCount
        XCTAssertEqual(leased, 0)
    }

    func testRestartAndSpeechReorderingUseDurableOwnershipWithoutPreviousWords() async throws {
        let fixture = try await makeFixture()
        let windows = try await seedWindows(fixture, count: 3)
        let model = ChunkTranscriptModel()
        let freshManager = fixture.manager(model: model, enabled: false)
        let empty = AsyncStream<CapturedAudio>.makeStream()
        empty.continuation.finish()
        await freshManager.startProcessing(audioStream: empty.stream)
        let observed = await model.inputs
        let timingRequests = await model.wordTimingRequests
        XCTAssertEqual(timingRequests, [true, true, true], "Existing exact media still requires timestamps when new capture is disabled")
        let leasedInputs = await fixture.media.readObservations
        XCTAssertEqual(leasedInputs.map(\.windowID), [windows[1].manifest.id, windows[2].manifest.id, windows[0].manifest.id],
            "Speech hints change admission order while each read retains its exact window identity")
        XCTAssertEqual(observed, leasedInputs.map(\.pcmData),
            "The first raw inference attempt receives exactly the bytes from its own native read lease")
        let rows = try await fixture.rows()
        XCTAssertEqual(rows.count, 3)
        for window in windows {
            let row = try XCTUnwrap(rows.first { $0.batchAudioPath == window.relativePath })
            XCTAssertEqual(row.text, "Cedar amount seven approved today.")
            XCTAssertGreaterThanOrEqual(row.startTime, window.manifest.ownedStartTime)
        }
        let pending = try await fixture.queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 0)
    }

    func testTextWithoutWordTimingCannotRepublishPrecedingContext() async throws {
        let fixture = try await makeFixture()
        let windows = try await seedWindows(fixture, count: 2)
        let model = ChunkTranscriptModel(textOnly: true)
        let backfill = AudioBackfillManager(transcriptionService: model, transcriptionQueries: fixture.queries,
            audioWriter: fixture.writer, storageRoot: fixture.root, mediaStore: fixture.media)
        _ = await backfill.processAllPendingBatches(maxBatches: 2)
        let rows = try await fixture.rows()
        XCTAssertFalse(rows.contains { $0.batchAudioPath == windows[1].relativePath })
        let pending = try await fixture.queries.getUntranscribedBatches()
        XCTAssertEqual(pending.map(\.audioPath), [windows[1].relativePath])
        let leased = await fixture.media.activeLeaseCount
        XCTAssertEqual(leased, 0, "A rejected timing result still releases its native media reader")
    }

    func testBackfillRequestsTimedWordsBeforePublishingOwnedContext() async throws {
        let fixture = try await makeFixture()
        let windows = try await seedWindows(fixture, count: 2)
        let model = ChunkTranscriptModel()
        let backfill = AudioBackfillManager(transcriptionService: model, transcriptionQueries: fixture.queries,
            audioWriter: fixture.writer, storageRoot: fixture.root, mediaStore: fixture.media)
        _ = await backfill.processAllPendingBatches(maxBatches: 2)
        let timingRequests = await model.wordTimingRequests
        XCTAssertEqual(timingRequests, [true, true])
        let rows = try await fixture.rows()
        XCTAssertEqual(rows.count, 2)
        for window in windows {
            let row = try XCTUnwrap(rows.first { $0.batchAudioPath == window.relativePath })
            XCTAssertEqual(row.text, "Cedar amount seven approved today.")
            XCTAssertGreaterThanOrEqual(row.startTime, window.manifest.ownedStartTime)
        }
        let pending = try await fixture.queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 0)
    }

    func testOwnedWordBoundariesAreHalfOpenAndInvalidTimingFailsClosed() async throws {
        let fixture = try await makeFixture()
        let windows = try await seedWindows(fixture, count: 2)
        let window = windows[1]
        try await AudioTranscriptionMedia.withInput(path: window.relativePath, legacyStartTime: nil,
            storageRoot: fixture.root, queries: fixture.queries, mediaStore: fixture.media) { input in
                let result = DetailedTranscriptionResult(text: "context Cedar end excluded", words: [
                    .init(word: "context", start: 4.999, end: 5.1),
                    .init(word: "Cedar", start: 5, end: 5.2),
                    .init(word: "end", start: 14.999, end: 15.2),
                    .init(word: "excluded", start: 15, end: 15.1)
                ])
                let owned = try input.ownedTranscript(result)
                XCTAssertEqual(owned.text, "Cedar end")
                XCTAssertEqual(owned.words.map(\.start), [5, 14.999])
                XCTAssertEqual(owned.words.last?.end, 15)
                for words in [
                    [TranscriptionWord(word: "Cedar", start: .nan, end: 7)],
                    [TranscriptionWord(word: "Cedar", start: 6, end: 5)],
                    [TranscriptionWord(word: "Cedar", start: 7, end: 8), TranscriptionWord(word: "amount", start: 6, end: 7)]
                ] {
                    XCTAssertThrowsError(try input.ownedTranscript(.init(text: "Cedar amount", words: words)))
                }
            }
        let leased = await fixture.media.activeLeaseCount
        XCTAssertEqual(leased, 0)
    }

    func testDeletionDuringInferenceRejectsPublicationAndJoinsLease() async throws {
        let fixture = try await makeFixture()
        let windows = try await seedWindows(fixture, count: 1)
        let pending = try await fixture.queries.getUntranscribedBatches()
        let raw = try XCTUnwrap(pending.first)
        let sawLease = ChunkTestFlag()
        let model = ChunkTranscriptModel(onCall: {
            await sawLease.set(await fixture.media.activeLeaseCount == 1)
            _ = try? await fixture.queries.deleteTranscription(id: raw.id)
        })
        let backfill = AudioBackfillManager(transcriptionService: model, transcriptionQueries: fixture.queries,
            audioWriter: fixture.writer, storageRoot: fixture.root, mediaStore: fixture.media)
        _ = await backfill.processAllPendingBatches(maxBatches: 1)
        let rows = try await fixture.rows()
        XCTAssertFalse(rows.contains { $0.batchAudioPath == windows[0].relativePath })
        let wasHeld = await sawLease.value
        let leased = await fixture.media.activeLeaseCount
        XCTAssertTrue(wasHeld)
        XCTAssertEqual(leased, 0)
    }

    func testStopPersistsAcceptedPartialPCMBeforeTheSessionRetires() async throws {
        let fixture = try await makeFixture()
        let accepted = expectation(description: "capture consumed before next input request")
        let feed = ChunkPartialFeed(capture: capture(frames: 8_000), accepted: { accepted.fulfill() })
        let manager = fixture.manager(model: ChunkTranscriptModel(), enabled: true)
        let stream = AsyncStream<CapturedAudio>(unfolding: { await feed.next() })
        let processing = Task { await manager.startProcessing(audioStream: stream) }
        await fulfillment(of: [accepted], timeout: 5)
        await manager.stopProcessing()
        await processing.value
        let pending = try await fixture.queries.getUntranscribedBatches()
        XCTAssertEqual(pending.count, 1)
        let row = try XCTUnwrap(pending.first)
        let value = try await fixture.queries.storedAudioWindow(forPath: row.audioPath)
        let window = try XCTUnwrap(value)
        XCTAssertEqual(window.manifest.frameCount, 8_000)
        let lease = try await fixture.media.readWindow(window)
        XCTAssertEqual(lease.pcmData.count, 16_000)
        await fixture.media.release(lease)
    }

    func testRefinementPassesReuseExactWindowAndOwnership() async throws {
        let fixture = try await makeFixture()
        let windows = try await seedWindows(fixture, count: 2)
        let model = ChunkTranscriptModel()
        let backfill = AudioBackfillManager(transcriptionService: model, transcriptionQueries: fixture.queries,
            audioWriter: fixture.writer, storageRoot: fixture.root, mediaStore: fixture.media)
        _ = await backfill.processAllPendingBatches(maxBatches: 2)
        let passTwo = AudioRefinementManager(transcriptionService: model, transcriptionQueries: fixture.queries,
            audioWriter: fixture.writer, storageRoot: fixture.root, mediaStore: fixture.media)
        let second = await passTwo.processAllPendingRefinements(maxBatches: 2)
        XCTAssertEqual(second.refinedCount, 2)
        XCTAssertEqual(second.failedCount, 0)
        let passTwoRows = try await fixture.rows()
        let preserved = try XCTUnwrap(passTwoRows.first { $0.batchAudioPath == windows[0].relativePath })
        let firstNeighbors = try await fixture.queries.getNeighborBatchText(forBatchPath: windows[0].relativePath)
        let secondNeighbors = try await fixture.queries.getNeighborBatchText(forBatchPath: windows[1].relativePath)
        // The existing following-context query requires more than thirty seconds
        // of separation. This ten-second successor supplies no context to the
        // first window; the second still has the first as preceding context.
        XCTAssertNil(firstNeighbors.preceding)
        XCTAssertNil(firstNeighbors.following)
        XCTAssertEqual(secondNeighbors.preceding, "Cedar amount seven approved today.")
        let passThree = AudioContextualRefinementManager(transcriptionService: model, transcriptionQueries: fixture.queries,
            audioWriter: fixture.writer, storageRoot: fixture.root, mediaStore: fixture.media)
        let third = await passThree.processAllPendingRefinements(runMode: .manual, maxBatches: 2)
        XCTAssertEqual(third.refinedCount, 1)
        XCTAssertEqual(third.skippedCount, 1)
        XCTAssertEqual(third.failedCount, 0)
        let rows = try await fixture.rows()
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.text == "Cedar amount seven approved today." })
        let first = try XCTUnwrap(rows.first { $0.batchAudioPath == windows[0].relativePath })
        XCTAssertEqual(first.id, preserved.id)
        XCTAssertEqual(first.transcriptionPass, 2)
        XCTAssertEqual(first.transcriptStatus, AudioTranscriptStatus.refinementSkipped.rawValue)
        XCTAssertTrue(first.qualityFlags?.split(separator: ",").contains("no_context") == true)
        XCTAssertEqual(first.text, preserved.text)
        XCTAssertEqual(first.startTime, preserved.startTime)
        XCTAssertEqual(first.endTime, preserved.endTime)
        XCTAssertEqual(first.audioPath, preserved.audioPath)
        let refined = try XCTUnwrap(rows.first { $0.batchAudioPath == windows[1].relativePath })
        XCTAssertEqual(refined.transcriptionPass, 3)
        XCTAssertEqual(refined.transcriptStatus, AudioTranscriptStatus.transcribed.rawValue)
        for row in rows {
            let window = try XCTUnwrap(windows.first { $0.relativePath == row.batchAudioPath })
            XCTAssertGreaterThanOrEqual(row.startTime, window.manifest.ownedStartTime)
            XCTAssertLessThanOrEqual(row.endTime, window.manifest.endTime)
        }
        let leased = await fixture.media.activeLeaseCount
        XCTAssertEqual(leased, 0)
    }

    func testWriteFailureRetainsBoundedAcceptedChunksForRetry() async throws {
        let fixture = try await makeFixture()
        await fixture.media.failNextPersistence()
        let model = ChunkTranscriptModel()
        let manager = fixture.manager(model: model, enabled: true)
        let stream = AsyncStream<CapturedAudio>.makeStream()
        stream.continuation.yield(capture(frames: 320_000))
        stream.continuation.finish()
        await manager.startProcessing(audioStream: stream.stream)
        let failed = await manager.hasPersistenceFailure
        let before = await model.inputSizes
        XCTAssertTrue(failed)
        XCTAssertTrue(before.isEmpty)

        let retry = AsyncStream<CapturedAudio>.makeStream()
        retry.continuation.finish()
        await manager.startProcessing(audioStream: retry.stream)
        let rows = try await fixture.rows()
        let after = await manager.hasPersistenceFailure
        let attempts = await fixture.media.persistenceAttempts
        XCTAssertFalse(after)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(attempts.count, 3)
        let firstAttempt = try XCTUnwrap(attempts.first)
        let retryAttempt = try XCTUnwrap(attempts.dropFirst().first)
        let nextAttempt = try XCTUnwrap(attempts.dropFirst(2).first)
        XCTAssertEqual(firstAttempt, retryAttempt, "Retry preserves the same accepted chunk identity")
        XCTAssertNotEqual(retryAttempt, nextAttempt)
    }

    func testGracefulFinishedSourceDrainsQueuedThirtyAndAHalfSecondsBehindNativeWrite() async throws {
        let fixture = try await makeFixture()
        let entered = expectation(description: "first actual AAC write held before registration")
        let gate = ChunkRecoveryGate(entered: { entered.fulfill() })
        await fixture.media.holdNextPersistence(gate)
        let model = ChunkTranscriptModel()
        let manager = fixture.manager(model: model, enabled: true)
        await manager.prepareCapturedInput()
        let input = AsyncStream<CapturedAudio>.makeStream(bufferingPolicy: .bufferingOldest(8))
        let processing = Task { await manager.startProcessing(audioStream: input.stream) }
        let counts = [160_000, 160_000, 160_000, 8_000]
        let pcm = counts.enumerated().map { Self.tone(frames: $0.element, frequency: 220 + Double($0.offset) * 40) }
        input.continuation.yield(CapturedAudio(timestamp: origin, audioData: pcm[0], duration: 10, source: .microphone))
        await fulfillment(of: [entered], timeout: 5)
        for index in 1..<counts.count {
            input.continuation.yield(CapturedAudio(timestamp: origin.addingTimeInterval(Double(index) * 10),
                audioData: pcm[index], duration: Double(counts[index]) / 16_000, source: .microphone))
        }
        input.continuation.finish()
        let premature = expectation(description: "graceful stop must join held capture persistence")
        premature.isInverted = true
        let drain = Task { await manager.finishCapturedInput(); premature.fulfill() }
        await fulfillment(of: [premature], timeout: 0.1)
        await gate.release()
        await drain.value
        await processing.value
        let pending = try await fixture.queries.getUntranscribedBatches()
        XCTAssertEqual(pending.count, 4)
        var owned: [AudioChunkDescriptor] = []
        for row in pending {
            let stored = try await fixture.queries.storedAudioWindow(forPath: row.audioPath)
            let window = try XCTUnwrap(stored)
            owned.append(try XCTUnwrap(window.manifest.ranges.last?.chunk))
        }
        owned.sort { $0.startFrame < $1.startFrame }
        XCTAssertEqual(owned.map(\.frameCount), counts.map(Int64.init))
        XCTAssertEqual(owned.reduce(Int64(0)) { $0 + $1.frameCount }, 488_000)
        XCTAssertEqual(owned.map(\.originalPCMSHA256), pcm.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() })
        let inference = await model.inputSizes
        XCTAssertTrue(inference.isEmpty, "Stop cancels quiet-time inference while already captured input reaches durable media")
    }

    func testGracefulStopRegisteredBeforeConsumerStartIsConsumedOnlyOnce() async throws {
        let fixture = try await makeFixture()
        let model = ChunkTranscriptModel()
        let manager = fixture.manager(model: model, enabled: true)
        await manager.prepareCapturedInput()
        let input = AsyncStream<CapturedAudio>.makeStream()
        input.continuation.yield(capture(frames: 8_000))
        input.continuation.finish()
        await manager.finishCapturedInput()
        await manager.startProcessing(audioStream: input.stream)
        let pending = try await fixture.queries.getUntranscribedBatchCount()
        let duringStop = await model.inputSizes
        XCTAssertEqual(pending, 1)
        XCTAssertTrue(duringStop.isEmpty)

        await manager.prepareCapturedInput()
        let restart = AsyncStream<CapturedAudio>.makeStream()
        restart.continuation.finish()
        await manager.startProcessing(audioStream: restart.stream)
        let rows = try await fixture.rows()
        let recovered = await model.inputSizes
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(recovered.count, 1, "A later prepared capture session resumes pending transcription normally")
    }

    func testFreshManagerRegistersMediaJournalAfterSQLiteFailureWithoutReencoding() async throws {
        let fixture = try await makeFixture()
        try await fixture.database.chunkProcessingFixtureSQL("CREATE TRIGGER deny_chunk BEFORE INSERT ON audio_captures WHEN NEW.text='' BEGIN SELECT RAISE(ABORT,'fixture registration denial'); END")
        let first = fixture.manager(model: ChunkTranscriptModel(), enabled: true)
        let stream = AsyncStream<CapturedAudio>.makeStream()
        stream.continuation.yield(capture(frames: 160_000))
        stream.continuation.finish()
        await first.startProcessing(audioStream: stream.stream)
        let interrupted = await first.hasPersistenceFailure
        let journal = try await fixture.media.pendingWindows(limit: 16)
        XCTAssertTrue(interrupted)
        XCTAssertEqual(journal.count, 1)
        let before = await fixture.media.persistenceAttempts.count
        try await fixture.database.chunkProcessingFixtureSQL("DROP TRIGGER deny_chunk")

        let replacement = fixture.manager(model: ChunkTranscriptModel(), enabled: false)
        let empty = AsyncStream<CapturedAudio>.makeStream()
        empty.continuation.finish()
        await replacement.startProcessing(audioStream: empty.stream)
        let rows = try await fixture.rows()
        let after = await fixture.media.persistenceAttempts.count
        let pendingJournal = try await fixture.media.pendingWindows(limit: 16)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.batchAudioPath, journal.first?.relativePath)
        XCTAssertEqual(before, after, "Restart reuses the actual AAC and manifest written before the SQLite denial")
        XCTAssertTrue(pendingJournal.isEmpty)
    }

    func testDeletedPublishedJournalIsAcknowledgedWithoutResurrectingHistoryOrDeletingMedia() async throws {
        let fixture = try await makeFixture()
        let input = AudioChunkInput(streamID: UUID(), source: .system, origin: origin,
            startFrame: 0, pcmData: Self.tone(frames: 1_600))
        let window = try await fixture.media.persistChunk(input, previous: nil)
        let rawID = try await fixture.queries.registerRawAudioWindow(window)
        _ = try await fixture.queries.deleteTranscription(id: rawID)
        let empty = AsyncStream<CapturedAudio>.makeStream()
        empty.continuation.finish()
        let manager = fixture.manager(model: ChunkTranscriptModel(), enabled: false)
        await manager.startProcessing(audioStream: empty.stream)
        let failed = await manager.hasPersistenceFailure
        let journal = try await fixture.media.journalSnapshot()
        let rows = try await fixture.rows()
        XCTAssertFalse(failed)
        XCTAssertTrue(journal.isEmpty)
        XCTAssertTrue(rows.isEmpty)
        for range in window.manifest.ranges {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(range.chunk.relativePath).path))
        }
    }

    func testSeventeenthJournalWaitsForOwnedPeriodicRecoveryWhileCaptureContinues() async throws {
        let fixture = try await makeFixture()
        for index in 0..<17 {
            _ = try await fixture.media.persistChunk(AudioChunkInput(streamID: UUID(), source: .system,
                origin: origin.addingTimeInterval(Double(index)), startFrame: 0,
                pcmData: Self.tone(frames: 1_600, frequency: 220 + Double(index))), previous: nil)
        }
        let periodicEntered = expectation(description: "owned periodic page waits at media boundary")
        let gate = ChunkRecoveryGate(entered: { periodicEntered.fulfill() })
        await fixture.media.holdRecoveryAfterFirstPage(gate)
        let accepted = expectation(description: "capture starts after bounded initial recovery")
        let feed = ChunkPartialFeed(capture: capture(frames: 8_000), accepted: { accepted.fulfill() })
        let manager = AudioProcessingManager(transcriptionService: ChunkTranscriptModel(),
            transcriptionQueries: fixture.queries, audioWriter: fixture.writer,
            config: .init(chunkedAudioEnabled: true), pendingRetryInterval: .milliseconds(30), mediaStore: fixture.media)
        let processing = Task {
            await manager.startProcessing(audioStream: AsyncStream<CapturedAudio>(unfolding: { await feed.next() }))
        }
        await fulfillment(of: [accepted, periodicEntered], timeout: 5)
        let remainder = try await fixture.media.journalSnapshot()
        let running = await manager.isCurrentlyProcessing
        XCTAssertEqual(remainder.count, 1, "Startup registers at most sixteen journal entries")
        XCTAssertTrue(running)
        await gate.release()
        var completed = false
        for _ in 0..<500 {
            if try await fixture.media.journalSnapshot().isEmpty { completed = true; break }
            try await Task.sleep(for: .milliseconds(10), clock: .continuous)
        }
        XCTAssertTrue(completed, "The owned periodic task must resume registration without another capture or restart")
        await manager.stopProcessing()
        await processing.value
        let leases = await fixture.media.activeLeaseCount
        XCTAssertEqual(leases, 0)
    }

    private func makeFixture() async throws -> ChunkFixture {
        let database = DatabaseManager(databasePath: "file:audio-chunk-processing-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let pointer = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(pointer))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-chunk-processing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeID = try await database.evidenceStoreID(source: .native, identity: "native")
        let media = ObservedChunkMediaStore(base: AudioChunkMediaStore(storageRoot: root, storeID: storeID))
        let fixture = ChunkFixture(database: database, queries: queries, root: root,
            writer: AudioSegmentWriter(storageRoot: root), media: media)
        addTeardownBlock {
            await media.close()
            try? await database.close()
            try? FileManager.default.removeItem(at: root)
        }
        return fixture
    }

    private func seedWindows(_ fixture: ChunkFixture, count: Int) async throws -> [StoredAudioWindow] {
        let stream = UUID()
        var previous: AudioChunkDescriptor?
        var windows: [StoredAudioWindow] = []
        for index in 0..<count {
            let input = AudioChunkInput(streamID: stream, source: .system, origin: origin,
                startFrame: Int64(index * 160_000), pcmData: Self.tone(frames: 160_000, frequency: 220 + Double(index) * 40))
            let window = try await fixture.media.persistChunk(input, previous: previous)
            _ = try await fixture.queries.registerRawAudioWindow(window, probableSilenceHint: index == 0)
            try await fixture.media.acknowledgePublished(window)
            previous = window.manifest.ranges.last?.chunk
            windows.append(window)
        }
        return windows
    }

    private func capture(frames: Int, source: AudioSource = .microphone) -> CapturedAudio {
        CapturedAudio(timestamp: origin, audioData: Self.tone(frames: frames), duration: Double(frames) / 16_000, source: source)
    }

    private static func tone(frames: Int, frequency: Double = 220) -> Data {
        let samples = (0..<frames).map { Int16(8_000 * sin(Double($0) * 2 * .pi * frequency / 16_000)) }
        return samples.withUnsafeBytes { Data($0) }
    }

}

private struct ChunkFixture: Sendable {
    let database: DatabaseManager
    let queries: AudioTranscriptionQueries
    let root: URL
    let writer: AudioSegmentWriter
    let media: ObservedChunkMediaStore
    func manager(model: any TranscriptionProtocol, enabled: Bool) -> AudioProcessingManager {
        AudioProcessingManager(transcriptionService: model, transcriptionQueries: queries, audioWriter: writer,
            config: .init(chunkedAudioEnabled: enabled), mediaStore: media)
    }
    func rows() async throws -> [AudioTranscription] {
        try await queries.getTranscriptions(from: Date(timeIntervalSince1970: 1_800_009_000),
            to: Date(timeIntervalSince1970: 1_800_020_000), limit: 100)
    }
}

private actor ChunkTranscriptModel: TranscriptionProtocol {
    let textOnly: Bool
    let onCall: (@Sendable () async -> Void)?
    var inputs: [Data] = []
    var wordTimingRequests: [Bool] = []
    var inputSizes: [Int] { inputs.map(\.count) }
    init(textOnly: Bool = false, onCall: (@Sendable () async -> Void)? = nil) {
        self.textOnly = textOnly; self.onCall = onCall
    }
    func initialize() {}
    func cleanup() {}
    func transcribe(_ data: Data) -> TranscriptionResult { .init(text: "Cedar amount seven approved today.") }
    func transcribeWithTimestamps(_ data: Data, wordLevel: Bool, initialPrompt: String?) async throws -> DetailedTranscriptionResult {
        inputs.append(data)
        wordTimingRequests.append(wordLevel)
        await onCall?()
        let duration = Double(data.count / 2) / 16_000
        let lower = duration > 10 ? 5.0 : 0.0
        let words = "Cedar amount seven approved today.".split(separator: " ").enumerated().map { index, word in
            TranscriptionWord(word: String(word), start: lower + min(0.25, duration / 20) + Double(index) * min(0.15, duration / 8),
                end: lower + min(0.35, duration / 12) + Double(index) * min(0.15, duration / 8), confidence: 0.99)
        }
        let preceding = lower > 0 ? [TranscriptionWord(word: "PREVIOUS-CONTEXT", start: 1, end: 1.2, confidence: 0.99)] : []
        let all = preceding + words
        // Match native Whisper: disabling token timing returns text only.
        return .init(text: all.map(\.word).joined(separator: " "), words: textOnly || !wordLevel ? [] : all,
            language: "en", duration: duration)
    }
}

private struct ChunkReadObservation: Sendable {
    let windowID: UUID
    let pcmData: Data
}

private actor ObservedChunkMediaStore: AudioChunkMediaStoreProtocol {
    let base: AudioChunkMediaStore
    private var leases: Set<UUID> = []
    var activeLeaseCount: Int { leases.count }
    private var writesToFail = 0
    private var recoveryGate: ChunkRecoveryGate?
    private var persistenceGate: ChunkRecoveryGate?
    private var recoveryPages = 0
    var persistenceAttempts: [UUID] = []
    var readObservations: [ChunkReadObservation] = []
    init(base: AudioChunkMediaStore) { self.base = base }
    func failNextPersistence() { writesToFail = 1 }
    func holdRecoveryAfterFirstPage(_ gate: ChunkRecoveryGate) { recoveryGate = gate; recoveryPages = 0 }
    func holdNextPersistence(_ gate: ChunkRecoveryGate) { persistenceGate = gate }
    func persistChunk(_ input: AudioChunkInput, previous: AudioChunkDescriptor?) async throws -> StoredAudioWindow {
        persistenceAttempts.append(input.id)
        if writesToFail > 0 {
            writesToFail -= 1
            throw StorageError.fileWriteFailed(path: "authored chunk", underlying: "fixture failure before native write")
        }
        let result = try await base.persistChunk(input, previous: previous)
        if let gate = persistenceGate { persistenceGate = nil; await gate.hold() }
        return result
    }
    func readWindow(_ window: StoredAudioWindow) async throws -> AudioWindowReadLease {
        let lease = try await base.readWindow(window)
        leases.insert(lease.id)
        // Record the actual immutable bytes returned by this same native read;
        // comparing a separate decode would conflate routing with AAC variation.
        readObservations.append(.init(windowID: lease.window.manifest.id, pcmData: lease.pcmData))
        return lease
    }
    func release(_ lease: AudioWindowReadLease) async { await base.release(lease); leases.remove(lease.id) }
    func pendingWindows(limit: Int) async throws -> [StoredAudioWindow] {
        recoveryPages += 1
        if recoveryPages > 1 { await recoveryGate?.hold() }
        return try await base.pendingWindows(limit: limit)
    }
    func journalSnapshot() async throws -> [StoredAudioWindow] { try await base.pendingWindows(limit: 64) }
    func acknowledgePublished(_ window: StoredAudioWindow) async throws { try await base.acknowledgePublished(window) }
    func deleteAuthorized(windows: [StoredAudioWindow], chunks: [AudioChunkDescriptor]) async throws {
        try await base.deleteAuthorized(windows: windows, chunks: chunks)
    }
    func close() async { await base.close() }
}

private extension DatabaseManager {
    func chunkProcessingFixtureSQL(_ sql: String) throws {
        let db = try XCTUnwrap(getConnection())
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
}

private actor ChunkTestFlag {
    var value = false
    func set(_ value: Bool) { self.value = value }
}

private actor ChunkRecoveryGate {
    let entered: @Sendable () -> Void
    private var didEnter = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(entered: @escaping @Sendable () -> Void) { self.entered = entered }
    func hold() async {
        guard !released else { return }
        if !didEnter { didEnter = true; entered() }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private actor ChunkPartialFeed {
    let capture: CapturedAudio
    let accepted: @Sendable () -> Void
    var first = true
    init(capture: CapturedAudio, accepted: @escaping @Sendable () -> Void) { self.capture = capture; self.accepted = accepted }
    func next() async -> CapturedAudio? {
        if first { first = false; return capture }
        accepted()
        do { try await Task.sleep(for: .seconds(60), clock: .continuous) } catch {}
        return nil
    }
}
