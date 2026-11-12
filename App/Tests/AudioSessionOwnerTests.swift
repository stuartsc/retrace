import Foundation
import Database
import Processing
import Shared
import Storage
import XCTest
@testable import App

final class AudioSessionOwnerTests: XCTestCase {
    private var directory: URL!
    private var store: ContextDatabase!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-owner-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ContextDatabase(databasePath: directory.appendingPathComponent("context.db").path, nativeStoreID: UUID())
        try await store.initialize()
    }
    override func tearDown() async throws {
        try await store.close(); try FileManager.default.removeItem(at: directory)
    }

    func testMCPAudioSettingsShareDurableOwnerWithoutStartingHardwareAndRejectUnsupportedFields() async throws {
        let native = SessionNativeBoundary(), owner = makeOwner(native)
        try await owner.initialize()
        let token = "audio-settings-test-token-at-least-32-characters"
        let commands = directory.appendingPathComponent("commands")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let dispatcher = try RetraceCommandDispatcher(directory: commands,
            grants: [.init(clientID: "audio-client", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token),
                           capabilities: [.settingsRead, .settingsWrite])],
            handlers: RetraceAudioSettingsCommands.handlers(owner: { owner }))
        let read = await dispatcher.execute(.init(requestID: UUID(), operation: .audioSettingsRead), bearerToken: token)
        let snapshot = try XCTUnwrap(read.data).decode(AudioSessionSnapshot.self)
        let original = try XCTUnwrap(snapshot.configured)
        let arguments = RetraceJSON.object(["expectedRevision": .string(original.revision.uuidString),
            "microphoneEnabled": .bool(false), "systemAudioEnabled": .bool(false)])
        let request = RetraceCommandRequest(requestID: UUID(), operation: .audioSettingsUpdate, arguments: arguments)
        let written = await dispatcher.execute(request, bearerToken: token)
        XCTAssertEqual(written.status, .succeeded)
        let receipt = try XCTUnwrap(written.data).decode(AudioSessionSettingsReceipt.self)
        let saved = try await store.audioSessionSettings()
        XCTAssertEqual(saved, receipt.settings)
        XCTAssertFalse(saved.microphoneEnabled)
        let retry = await dispatcher.execute(request, bearerToken: token)
        XCTAssertTrue(retry.replayed); XCTAssertEqual(retry.data, written.data)
        let stale = await dispatcher.execute(.init(requestID: UUID(), operation: .audioSettingsUpdate, arguments: arguments), bearerToken: token)
        XCTAssertEqual(stale.status, .conflict)
        let forbidden = await dispatcher.execute(.init(requestID: UUID(), operation: .audioSettingsUpdate,
            arguments: .object(["expectedRevision": .string(saved.revision.uuidString), "microphoneEnabled": .bool(true),
                "systemAudioEnabled": .bool(false), "hasConsentedToMeetingRecording": .bool(true)])), bearerToken: token)
        XCTAssertEqual(forbidden.status, .failed)
        let starts = await native.starts
        XCTAssertEqual(starts, 0, "Reading and configuring a paused audio owner must not open capture")
        await dispatcher.close(); try await owner.close()
    }

    func testSettingsCommitWaitsForOldDrainAndRetryDoesNotRepeatNativeStart() async throws {
        let native = SessionNativeBoundary()
        let owner = makeOwner(native)
        try await owner.initialize()
        let initial = await owner.snapshot()
        XCTAssertEqual(initial.phase, .paused)
        let idleStarts = await native.starts
        XCTAssertEqual(idleStarts, 0, "Reads never open hardware")
        try await owner.setRecordingRequested(true)
        let configured = await owner.snapshot().configured
        let settings = try XCTUnwrap(configured)
        let entered = expectation(description: "Old audio generation drains")
        let hold = AudioOwnerHold()
        await native.holdNextDrain { entered.fulfill(); await hold.wait() }
        let command = AudioSessionSettingsCommand(expectedRevision: settings.revision, microphoneEnabled: false, systemAudioEnabled: false)
        let update = Task { try await owner.update(command) }
        await fulfillment(of: [entered], timeout: 3)
        let durable = try await store.audioSessionSettings()
        XCTAssertFalse(durable.microphoneEnabled, "Commit is durable before device reconciliation")
        let during = await owner.snapshot()
        XCTAssertEqual(during.phase, .reconfiguring)
        let beforeDrain = await native.starts
        XCTAssertEqual(beforeDrain, 1, "A second source cannot start before accepted old audio drains")
        update.cancel() // A disconnect after commit must still finish the disable.
        await hold.release()
        let receipt = try await update.value
        let after = await owner.snapshot()
        XCTAssertFalse(after.configured!.microphoneEnabled)
        XCTAssertEqual(after.runtime.microphone.state, .disabled)
        _ = try await owner.update(command)
        let afterRetry = await native.starts
        XCTAssertEqual(afterRetry, 2, "A durable retry does not restart the stream")
        XCTAssertEqual(receipt.settings, durable)
        try await owner.close()
    }

    func testPauseDuringHeldNativeStartJoinsCleanupAndNeverReopens() async throws {
        let native = SessionNativeBoundary(), entered = expectation(description: "Native start held")
        let hold = AudioOwnerHold()
        await native.holdNextStart { entered.fulfill(); await hold.wait() }
        let owner = makeOwner(native)
        let start = Task { try await owner.setRecordingRequested(true) }
        await fulfillment(of: [entered], timeout: 3)
        let pause = Task { try await owner.setRecordingRequested(false) }
        await waitUntil { !(await owner.snapshot()).recordingRequested }
        await hold.release()
        try await start.value; try await pause.value
        let state = await owner.snapshot(), starts = await native.starts
        XCTAssertEqual(state.phase, .paused)
        XCTAssertFalse(state.runtime.microphone.isActive)
        XCTAssertEqual(starts, 1)
        try await owner.close()
    }

    func testSystemPolicyDenialAndRevokedCommandCannotChangeSettingsOrRestart() async throws {
        let native = SessionNativeBoundary(), owner = makeOwner(native)
        try await owner.initialize()
        let configured = await owner.snapshot().configured
        let original = try XCTUnwrap(configured)
        do { _ = try await owner.update(.init(expectedRevision: original.revision, microphoneEnabled: true, systemAudioEnabled: true))
            XCTFail("System audio cannot silently bypass exclusions") }
        catch AudioSessionError.systemAudioPolicyUnavailable { }
        let fence = NativeMutationFence(); fence.invalidate()
        do { _ = try await owner.update(.init(expectedRevision: original.revision, microphoneEnabled: false, systemAudioEnabled: false), fence: fence)
            XCTFail("Revoked client cannot write settings") }
        catch is CancellationError { }
        let current = try await store.audioSessionSettings(), starts = await native.starts
        XCTAssertEqual(current, original); XCTAssertEqual(starts, 0)
        try await owner.close()
    }

    func testCloseFailureRetainsTerminalOwnerUntilJoinedCleanupRetry() async throws {
        let native = SessionNativeBoundary(), owner = makeOwner(native)
        try await owner.setRecordingRequested(true)
        await native.failNextDrain()
        do { try await owner.close(); XCTFail("Failed cleanup cannot authorize database shutdown") }
        catch AudioSessionError.cleanupFailed { }
        do { try await owner.setRecordingRequested(true); XCTFail("Terminal owner cannot reopen after failed close") }
        catch AudioSessionError.closed { }
        try await owner.close()
        let state = await owner.snapshot()
        XCTAssertEqual(state.phase, .closed)
    }

    func testReconfigurationFlushesRealPCMToAACAndJoinsPersistedCallbackBeforeNewStream() async throws {
        let database = DatabaseManager(databasePath: "file:audio_owner_\(UUID())?mode=memory&cache=shared")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let writer = AudioSegmentWriter(storageRoot: directory)
        let hold = AudioOwnerHold(), entered = expectation(description: "AAC and native row committed before callback")
        let probe = SessionBatchProbe()
        let processor = AudioProcessingManager(transcriptionService: MockTranscriptionService(), transcriptionQueries: queries,
            audioWriter: writer, governor: SessionNoInferenceGovernor(), config: .init(maxBufferDuration: 30),
            onPersistedBatch: { receipt in
                await probe.record(receipt)
                entered.fulfill()
                await hold.wait()
            })
        let boundary = SessionPCMStreamBoundary(processor: processor)
        let owner = AudioSessionOwner(store: store, baseConfig: .default, pipeline: .init(
            start: { await boundary.start($0) }, stopAndDrain: { await boundary.drain() }, runtime: { await boundary.runtime() },
            revokeMarkers: {}, setMicrophoneAllowed: { _ in }))
        try await owner.setRecordingRequested(true)
        let settingsValue = await owner.snapshot().configured
        let settings = try XCTUnwrap(settingsValue)
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (0..<16_000).map { Int16(sin(Double($0) * 0.08) * 2_000) }
        let identity = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(),
            startSample: 0, sampleCount: 16_000, sampleRate: 16_000, approximateOrigin: origin)
        await boundary.offer(CapturedAudio(timestamp: origin, audioData: samples.withUnsafeBytes { Data($0) },
            duration: 1, source: .microphone, sampleIdentity: identity))
        let update = Task { try await owner.update(.init(expectedRevision: settings.revision,
            microphoneEnabled: false, systemAudioEnabled: false)) }
        await fulfillment(of: [entered], timeout: 10)
        let startsWhileHeld = await boundary.starts
        XCTAssertEqual(startsWhileHeld, 1)
        let pending = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 1)
        await hold.release()
        _ = try await update.value
        let receipts = await probe.receipts
        XCTAssertEqual(receipts.count, 1, "The accepted tail is saved once across reconfiguration")
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipt.sourceRanges, [AudioBatchSourceRange(source: identity, batchStartSample: 0)])
        XCTAssertGreaterThan(try AudioFileDecoder.decodeToPCM(fileURL: receipt.fileURL).data.count, 0)
        let starts = await boundary.starts
        XCTAssertEqual(starts, 2)
        try await owner.close()
        try await database.close()
    }

    private func makeOwner(_ boundary: SessionNativeBoundary) -> AudioSessionOwner {
        AudioSessionOwner(store: store, baseConfig: .init(microphoneEnabled: true, systemAudioEnabled: false), pipeline: .init(
            start: { try await boundary.start($0) }, stopAndDrain: { try await boundary.drain() },
            runtime: { await boundary.runtime() }, revokeMarkers: { await boundary.revoke() },
            setMicrophoneAllowed: { await boundary.allowMicrophone($0) }))
    }
    private func waitUntil(_ condition: () async -> Bool) async {
        let limit = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < limit { await Task.yield() }
        let completed = await condition()
        XCTAssertTrue(completed)
    }
}

private actor AudioOwnerHold {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor SessionNativeBoundary {
    private(set) var starts = 0
    private var config: AudioCaptureConfig?
    private var onStart: (@Sendable () async -> Void)?
    private var onDrain: (@Sendable () async -> Void)?
    private var failDrain = false
    private var microphoneAllowed = false
    func holdNextStart(_ callback: @escaping @Sendable () async -> Void) { onStart = callback }
    func holdNextDrain(_ callback: @escaping @Sendable () async -> Void) { onDrain = callback }
    func failNextDrain() { failDrain = true }
    func start(_ config: AudioCaptureConfig) async throws {
        starts += 1
        let callback = onStart; onStart = nil
        await callback?(); self.config = config
    }
    func drain() async throws {
        let callback = onDrain; onDrain = nil
        await callback?()
        if failDrain { failDrain = false; throw AudioSessionError.cleanupFailed }
        config = nil
    }
    func revoke() { }
    func allowMicrophone(_ allowed: Bool) { microphoneAllowed = allowed }
    func runtime() -> AudioCaptureRuntime {
        guard let config else { return .init(microphone: .init(.paused), systemAudio: .init(.paused)) }
        return .init(microphone: .init(config.microphoneEnabled && microphoneAllowed ? .running : .disabled),
            systemAudio: .init(config.systemAudioEnabled ? .running : .disabled))
    }
}

private actor SessionBatchProbe {
    private(set) var receipts: [PersistedAudioBatchReceipt] = []
    func record(_ receipt: PersistedAudioBatchReceipt) { receipts.append(receipt) }
}
private actor SessionNoInferenceGovernor: BackgroundProcessingProtocol {
    func acquire(_ kind: BackgroundProcessingKind) throws -> BackgroundProcessingPermit { throw CancellationError() }
    func release(_ permit: BackgroundProcessingPermit) { }
}
private actor SessionPCMStreamBoundary {
    private let processor: AudioProcessingManager
    private var continuation: AsyncStream<CapturedAudio>.Continuation?
    private var consumer: Task<Void, Never>?
    private var config: AudioCaptureConfig?
    private(set) var starts = 0
    init(processor: AudioProcessingManager) { self.processor = processor }
    func start(_ config: AudioCaptureConfig) {
        starts += 1; self.config = config
        let pair = AsyncStream<CapturedAudio>.makeStream()
        continuation = pair.continuation
        consumer = Task { await processor.startProcessing(audioStream: pair.stream) }
    }
    func offer(_ sample: CapturedAudio) { continuation?.yield(sample) }
    func drain() async {
        continuation?.finish(); continuation = nil
        let current = consumer
        await current?.value // Natural completion flushes accepted PCM; no cancellation.
        consumer = nil; config = nil
    }
    func runtime() -> AudioCaptureRuntime {
        .init(microphone: .init(config?.microphoneEnabled == true ? .running : .disabled), systemAudio: .init(.disabled))
    }
}
