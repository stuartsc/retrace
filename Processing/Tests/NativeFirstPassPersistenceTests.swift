import Foundation
import CryptoKit
import XCTest
import Database
import Shared
@testable import Storage
@testable import Processing

/// Controlled recognizer output, real AAC encoder/decoder and private SQLite.
/// These validate publication/durability, not Apple model quality or speed.
final class NativeFirstPassPersistenceTests: XCTestCase {
    private var database: DatabaseManager!
    private var queries: AudioTranscriptionQueries!
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("native_first_pass_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = DatabaseManager(databasePath: root.appendingPathComponent("private.db").path)
        try await database.initialize()
        let connection = await database.getConnection()
        queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
    }
    override func tearDown() async throws {
        try await database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testNativeCoveredAACIsSearchableWithoutCPUAndCorrectionRemainsDurableAcrossReopen() async throws {
        let cpu = NativeReuseCPU(), governor = NativeReuseGovernor(), probe = NativeReuseProbe()
        let run = await start(cpu: cpu, governor: governor, provider: { batch in
            await probe.receive(batch)
            return .init(batch: batch, text: "Stuart confirmed twelve dollars.")
        })
        run.continuation.yield(sample())
        try await grantAfterPersisted(governor)
        try await wait { await governor.releases == 1 }
        let capturedProof = await probe.batch
        let proof = try XCTUnwrap(capturedProof)
        let savedValue = try await queries.getContextEntry(id: proof.rawBatchID)
        let saved = try XCTUnwrap(savedValue)
        XCTAssertEqual(saved.text, "Stuart confirmed twelve dollars.")
        XCTAssertEqual(saved.transcriptStatus, "needs_repair")
        XCTAssertTrue(saved.qualityFlags?.contains(AudioPreparationMetadata.firstPassRepairPending) == true)
        let calls = await cpu.calls, initialized = await cpu.initializations
        XCTAssertEqual(calls, 0); XCTAssertEqual(initialized, 0)
        let decoded = try AudioFileDecoder.decodeToPCM(fileURL: root.appendingPathComponent(proof.relativePath))
        XCTAssertEqual(decoded.data.count, Int(proof.frameCount) * 2)
        let results = try await queries.searchTranscriptions(query: "Stuart")
        XCTAssertTrue(results.contains { $0.id == proof.rawBatchID })
        await stop(run)
        try await database.close()
        database = DatabaseManager(databasePath: root.appendingPathComponent("private.db").path)
        try await database.initialize()
        let connection = await database.getConnection()
        queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let pending = try await queries.getOldestRepairBatch()
        XCTAssertEqual(pending?.retainedFirstPass?.text, saved.text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(proof.relativePath).path))
        // No in-memory proof survives restart. The retained text is corrected
        // by the existing historical lane, never reclassified as a fresh job.
        let secondGovernor = NativeReuseGovernor()
        let resumed = await start(cpu: cpu, governor: secondGovernor, provider: nil)
        await secondGovernor.grantOne()
        try await wait { await secondGovernor.releases == 1 }
        let resumedCalls = await cpu.calls, kinds = await secondGovernor.kinds
        XCTAssertGreaterThan(resumedCalls, 0)
        XCTAssertEqual(kinds.first, .ambientSpeech)
        await stop(resumed)
    }

    func testNativeProofBindsCompactedAACBeforeSearchablePublication() async throws {
        let cpu = NativeReuseCPU(), governor = NativeReuseGovernor(), probe = NativeReuseProbe()
        let run = await start(cpu: cpu, governor: governor, compactContainerPadding: true, provider: { batch in
            await probe.receive(batch)
            return .init(batch: batch, text: "Compacted audio retained its native text.")
        })
        run.continuation.yield(sample())
        try await grantAfterPersisted(governor)
        try await wait { await governor.releases == 1 }
        let captured = await probe.batch
        let proof = try XCTUnwrap(captured)
        let url = root.appendingPathComponent(proof.relativePath)
        let bytes = try Data(contentsOf: url)
        XCTAssertNil(AACContainerCompactor.compact(bytes), "The saved file was compacted before proof registration")
        XCTAssertEqual(proof.encodedSHA256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try AudioFileDecoder.decodeToPCM(fileURL: url).data.count, Int(proof.frameCount) * 2)
        let pending = try await queries.getOldestRepairBatch()
        XCTAssertEqual(pending?.id, proof.rawBatchID)
        XCTAssertEqual(pending?.audioSize, Int64(bytes.count), "The durable row records the final file size")
        let matches = try await queries.searchTranscriptions(query: "Compacted")
        XCTAssertTrue(matches.contains { $0.id == proof.rawBatchID })
        let calls = await cpu.calls
        XCTAssertEqual(calls, 0)
        await stop(run)
    }

    func testMissingCoverageAndSystemSourceUseCPUFallback() async throws {
        for source in [AudioSource.microphone, .system] {
            let cpu = NativeReuseCPU(), governor = NativeReuseGovernor(), probe = NativeReuseProbe()
            let run = await start(cpu: cpu, governor: governor, provider: { batch in
                await probe.receive(batch)
                return nil
            })
            run.continuation.yield(sample(source: source))
            try await grantAfterPersisted(governor)
            try await wait { await governor.releases == 1 }
            let calls = await cpu.calls, observed = await probe.batch
            XCTAssertGreaterThan(calls, 0)
            if source == .system { XCTAssertNil(observed, "Never manufacture system-audio sample identity") }
            else { XCTAssertNotNil(observed) }
            await stop(run)
        }
    }

    func testCancellationDuringNativeWaitKeepsRecordingPendingAndJoined() async throws {
        let cpu = NativeReuseCPU(), governor = NativeReuseGovernor(), probe = NativeReuseProbe()
        let run = await start(cpu: cpu, governor: governor, provider: { batch in
            await probe.receive(batch)
            while true { try BackgroundProcessingContext.checkCancellation(); try await Task.sleep(for: .milliseconds(10)) }
        })
        run.continuation.yield(sample())
        try await grantAfterPersisted(governor)
        try await wait { await probe.batch != nil }
        await stop(run)
        let capturedProof = await probe.batch
        let proof = try XCTUnwrap(capturedProof)
        let rowValue = try await queries.getContextEntry(id: proof.rawBatchID)
        let row = try XCTUnwrap(rowValue)
        XCTAssertTrue(row.text.isEmpty)
        XCTAssertEqual(row.transcriptStatus, "pending")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(proof.relativePath).path))
        let calls = await cpu.calls
        XCTAssertEqual(calls, 0)
    }

    func testDifferentProofCannotPublishNativeText() async throws {
        let cpu = NativeReuseCPU(), governor = NativeReuseGovernor()
        let run = await start(cpu: cpu, governor: governor, provider: { batch in
            let different = NativeFirstPassBatch(rawBatchID: batch.rawBatchID + 1, relativePath: batch.relativePath,
                encodedSHA256: batch.encodedSHA256, frameCount: batch.frameCount, source: .microphone,
                sampleRate: 16_000, channels: 1, ranges: [batch.range], mappingIncomplete: false)!
            return .init(batch: different, text: "Wrong source text")
        })
        run.continuation.yield(sample())
        try await grantAfterPersisted(governor)
        try await wait { await governor.releases == 1 }
        let calls = await cpu.calls
        XCTAssertGreaterThan(calls, 0)
        let wrong = try await queries.searchTranscriptions(query: "Wrong")
        XCTAssertTrue(wrong.isEmpty)
        await stop(run)
    }

    func testDeletedPendingRowCannotBeRecreatedByLateNativeText() async throws {
        let cpu = NativeReuseCPU(), governor = NativeReuseGovernor(), probe = NativeReuseProbe()
        let queries = try XCTUnwrap(self.queries)
        let run = await start(cpu: cpu, governor: governor, provider: { batch in
            await probe.receive(batch)
            let deleted = try await queries.deleteTranscription(id: batch.rawBatchID)
            XCTAssertTrue(deleted)
            return .init(batch: batch, text: "Late deleted transcript")
        })
        run.continuation.yield(sample())
        try await grantAfterPersisted(governor)
        try await wait { await governor.releases == 1 }
        let captured = await probe.batch
        let proof = try XCTUnwrap(captured)
        let row = try await queries.getContextEntry(id: proof.rawBatchID)
        XCTAssertNil(row)
        let results = try await queries.searchTranscriptions(query: "Late")
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(proof.relativePath).path))
        await stop(run)
    }

    func testChangedAACWhileWaitingCannotAcceptNativeText() async throws {
        let cpu = NativeReuseCPU(), governor = NativeReuseGovernor()
        let root = try XCTUnwrap(self.root)
        let run = await start(cpu: cpu, governor: governor, provider: { batch in
            let path = root.appendingPathComponent(batch.relativePath)
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
            return .init(batch: batch, text: "Untrusted native text")
        })
        run.continuation.yield(sample())
        try await grantAfterPersisted(governor)
        try await wait { await governor.releases == 1 }
        let calls = await cpu.calls
        XCTAssertGreaterThan(calls, 0, "A changed media digest invalidates native reuse")
        let results = try await queries.searchTranscriptions(query: "Untrusted")
        XCTAssertTrue(results.isEmpty)
        await stop(run)
    }

    func testNativeRetainedTextStillGetsRawCPUComparisonAndSurvivesEmptyCorrection() async throws {
        let cpu = NativeReuseCPU(text: "")
        let pcm = sample().audioData
        let retained = DetailedTranscriptionResult(text: "Stuart confirmed twelve dollars.", words: [], language: "en", duration: 1)
        let decision = try await AudioTranscriptionRetryPipeline.transcribeBest(audioData: pcm,
            sampleRate: 16_000, channels: 1, transcriptionService: cpu, wordLevel: false,
            initialPrompt: nil, profile: .deferredFirstPassRepair, retainedFirstPass: retained,
            retainedFirstPassRequiresRawInference: true)
        let calls = await cpu.calls
        XCTAssertGreaterThan(calls, 0, "Readable native text still requires the promised raw CPU comparison")
        XCTAssertEqual(decision.transcription.text, retained.text, "Empty correction cannot erase retained native text")
    }

    private func start(cpu: NativeReuseCPU, governor: NativeReuseGovernor,
                       compactContainerPadding: Bool = false,
                       provider: AudioProcessingManager.NativeFirstPassProvider?) async -> NativeReuseRun {
        let manager = AudioProcessingManager(transcriptionService: cpu, transcriptionQueries: queries,
            audioWriter: AudioSegmentWriter(storageRoot: root, compactContainerPadding: compactContainerPadding), governor: governor,
            config: .init(minimumConfidence: 0, maxBufferDuration: 1))
        let installed = await manager.setNativeFirstPassProvider(provider)
        XCTAssertTrue(installed)
        let pair = AsyncStream<CapturedAudio>.makeStream()
        let task = Task { await manager.startProcessing(audioStream: pair.stream) }
        return .init(manager: manager, continuation: pair.continuation, task: task)
    }
    private func sample(source: AudioSource = .microphone) -> CapturedAudio {
        let origin = Date()
        let pcm = (0..<16_000).map { Int16(sin(Double($0) * 0.08) * 4_000) }
        let identity = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(),
            startSample: 0, sampleCount: 16_000, sampleRate: 16_000, approximateOrigin: origin)
        return .init(timestamp: origin, audioData: pcm.withUnsafeBytes { Data($0) }, duration: 1,
            source: source, sampleIdentity: source == .microphone ? identity : nil)
    }
    private func stop(_ run: NativeReuseRun) async {
        await run.manager.stopProcessing(); run.continuation.finish(); await run.task.value
    }
    private func grantAfterPersisted(_ governor: NativeReuseGovernor) async throws {
        try await wait { ((try? await self.queries.getUntranscribedBatchCount()) ?? 0) > 0 }
        await governor.grantOne()
    }
    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Private native publication fixture did not settle")
    }
}

private struct NativeReuseRun {
    let manager: AudioProcessingManager
    let continuation: AsyncStream<CapturedAudio>.Continuation
    let task: Task<Void, Never>
}
private actor NativeReuseProbe {
    var batch: NativeFirstPassBatch?
    func receive(_ batch: NativeFirstPassBatch) { self.batch = batch }
}
private actor NativeReuseGovernor: BackgroundProcessingProtocol {
    private var grants = 0
    var releases = 0
    var kinds: [BackgroundProcessingKind] = []
    func grantOne() { grants += 1 }
    func acquire(_ kind: BackgroundProcessingKind) async throws -> BackgroundProcessingPermit {
        kinds.append(kind)
        while grants == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation(); grants -= 1
        return .init(threadCount: 2)
    }
    func release(_ permit: BackgroundProcessingPermit) { releases += 1 }
}
private actor NativeReuseCPU: TranscriptionProtocol {
    private let text: String
    var calls = 0
    var initializations = 0
    init(text: String = "Stuart confirmed twelve dollars.") { self.text = text }
    func initialize() { initializations += 1 }
    func cleanup() {}
    func transcribe(_ audioData: Data) async throws -> TranscriptionResult { .init(text: "CPU fallback") }
    func transcribeWithTimestamps(_ audioData: Data, wordLevel: Bool, initialPrompt: String?) async throws -> DetailedTranscriptionResult {
        calls += 1
        XCTAssertFalse(audioData.isEmpty)
        return .init(text: text, words: text.isEmpty ? [] : [
            .init(word: text, start: 0, end: 1, confidence: 0.99)
        ], language: "en", duration: 1)
    }
}
