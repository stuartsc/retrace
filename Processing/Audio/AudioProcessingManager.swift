import Foundation
import Shared
import Database
import Storage

private struct PersistedAudioBatch: Sendable {
    let batch: AudioBatch
    let rawBatchID: Int64?
    let savedBatchPath: String?
    let savedBatchURL: URL?
    var probableSilenceHint: Bool = false

    var isSpooledToDisk: Bool {
        batch.audioData.isEmpty && savedBatchURL != nil
    }

    func spooledToDisk() -> PersistedAudioBatch {
        guard savedBatchPath != nil else { return self }
        return PersistedAudioBatch(
            batch: AudioBatch(
                audioData: Data(),
                source: batch.source,
                startTimestamp: batch.startTimestamp,
                endTimestamp: batch.endTimestamp,
                duration: batch.duration,
                sampleRate: batch.sampleRate,
                channels: batch.channels
            ),
            rawBatchID: rawBatchID,
            savedBatchPath: savedBatchPath,
            savedBatchURL: savedBatchURL
        )
    }
}

/// Cross-task cancellation handle for exactly one processing session. Lock
/// sections only copy handles; cancellation and task joining happen outside.
private final class AudioProcessingSession: @unchecked Sendable {
    let id = UUID()
    let chunkedAudio: Bool
    init(chunkedAudio: Bool = false) { self.chunkedAudio = chunkedAudio }
    private let lock = NSLock()
    private var cancelled = false
    private var inferenceStopped = false
    private var ingestion: Task<Void, Never>?
    private var worker: (id: UUID, task: Task<Void, Never>)?
    private var inputFinished = false
    private let wake = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    var wakeStream: AsyncStream<Void> { wake.stream }
    var isInputFinished: Bool { lock.withLock { inputFinished } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    var isInferenceStopped: Bool { lock.withLock { inferenceStopped } }
    var ingestionTask: Task<Void, Never>? { lock.withLock { ingestion } }

    func installIngestion(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock { ingestion = task; return cancelled }
        if shouldCancel { task.cancel() }
    }
    func installWorker(id: UUID, task: Task<Void, Never>) {
        let shouldCancel = lock.withLock { worker = (id, task); return cancelled || inferenceStopped }
        if shouldCancel { task.cancel() }
    }
    func retireWorker(id: UUID) {
        lock.withLock { if worker?.id == id { worker = nil } }
    }
    func signalWork() { wake.continuation.yield(()) }
    func finishInput() {
        lock.withLock { inputFinished = true }
        signalWork()
    }
    func stopInference() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            inferenceStopped = true
            return worker?.task
        }
        task?.cancel()
        signalWork()
    }
    func cancel() {
        let tasks = lock.withLock { () -> [Task<Void, Never>] in
            cancelled = true
            return [ingestion, worker?.task].compactMap { $0 }
        }
        for task in tasks { task.cancel() }
    }
    func finish() {
        lock.withLock { ingestion = nil; worker = nil }
        wake.continuation.finish()
    }
}

private struct AudioProcessingOwnership: Sendable {
    let session: AudioProcessingSession
    let ingestion: Task<Void, Never>
}

/// Coordinates audio capture → batch buffering → transcription → database storage pipeline
/// Accumulates PCM into 30-second batches per source before calling whisper.cpp
public actor AudioProcessingManager {

    private var transcriptionService: any TranscriptionProtocol
    private var transcriptionQueries: AudioTranscriptionQueries?
    private var audioWriter: AudioSegmentWriter?
    private var mediaStore: (any AudioChunkMediaStoreProtocol)?
    private var chunkBuffer = AudioChunkBuffer()
    private var previousChunks: [AudioSource: AudioChunkDescriptor] = [:]
    private var retainedChunkInputs: [AudioChunkInput] = []
    private var processingSession: AudioProcessingSession?
    private var lifecycleTail: Task<Void, Never>?
    private var lifecycleID = UUID()
    private var nextSessionDrainsCapturedInput = false

    /// Trailing words from the last batch (in the overlap zone) — used to deduplicate
    private var previousBatchTrailingWords: [TranscriptionWord] = []

    /// Duration of the last batch — needed to compute absolute timestamps for trailing words
    private var previousBatchEnd: Date?
    private var previousBatchSource: AudioSource?
    private var previousBatchDuration: TimeInterval = 0

    // Batch buffering
    private var bufferManager: AudioBufferManager

    // Live transcription queue. Ingestion must keep draining capture even when Whisper is slow.
    private var liveTranscriptionQueue: [PersistedAudioBatch] = []
    private var liveTranscriptionWorker: (sessionID: UUID, id: UUID, task: Task<Void, Never>)?

    // Configuration
    private let governor: (any BackgroundProcessingProtocol)?
    private let pendingRetryInterval: Duration
    private var pendingCursor: Int64 = 0
    private var pendingPage: [UntranscribedBatch] = []
    private var speechAdmissions = 0
    private var sweepExhausted = false
    private var retainedPersistenceFailure: PersistedAudioBatch?
    public private(set) var hasPersistenceFailure = false
    private var persistenceFailureCallback: (@Sendable () async -> Void)?

    /// The callback may stop capture; it must not join this manager's own session.
    public func setPersistenceFailureCallback(_ callback: (@Sendable () async -> Void)?) {
        persistenceFailureCallback = callback
    }
    private var config: AudioProcessingConfig

    // Statistics
    private var statistics = AudioProcessingStatistics(
        totalAudioSamplesProcessed: 0,
        totalTranscriptionsGenerated: 0,
        totalWordsTranscribed: 0,
        totalProcessingTime: 0,
        averageConfidence: 0,
        lastProcessedAt: nil
    )

    public init(
        transcriptionService: any TranscriptionProtocol,
        transcriptionQueries: AudioTranscriptionQueries? = nil,
        audioWriter: AudioSegmentWriter? = nil,
        config: AudioProcessingConfig = .default,
        governor: (any BackgroundProcessingProtocol)? = nil,
        pendingRetryInterval: Duration = .seconds(30),
        mediaStore: (any AudioChunkMediaStoreProtocol)? = nil
    ) {
        self.transcriptionService = transcriptionService
        self.transcriptionQueries = transcriptionQueries
        self.audioWriter = audioWriter
        self.mediaStore = mediaStore
        self.config = config
        self.governor = governor
        self.pendingRetryInterval = max(pendingRetryInterval, .milliseconds(20))
        self.bufferManager = AudioBufferManager(maxBufferDuration: config.maxBufferDuration)
    }

    public func setChunkMediaStore(_ store: (any AudioChunkMediaStoreProtocol)?) { mediaStore = store }

    // MARK: - Initialization

    /// Initialize the audio processing manager and transcription service
    public func initialize(
        transcriptionQueries: AudioTranscriptionQueries? = nil,
        audioWriter: AudioSegmentWriter? = nil
    ) async throws {
        if let queries = transcriptionQueries {
            self.transcriptionQueries = queries
        }
        if let writer = audioWriter {
            self.audioWriter = writer
        }
        do {
            try await transcriptionService.initialize()
        } catch {
            Log.warning("[AudioProcessingManager] Transcription service init failed (model may not be downloaded yet): \(error)", category: .processing)
        }
    }

    /// Hot-swap the transcription service (e.g., after downloading whisper model)
    public func updateTranscriptionService(_ service: any TranscriptionProtocol) {
        self.transcriptionService = service
        Log.info("[AudioProcessingManager] Transcription service updated to \(type(of: service))", category: .processing)
    }

    // MARK: - Processing Pipeline

    /// Joins one owned ingestion/worker session. Duplicate starts join the
    /// active stream; a start during stop waits for complete retirement first.
    /// Cancelling a joined caller requests cancellation of that same session.
    public func startProcessing(audioStream: AsyncStream<CapturedAudio>) async {
        guard !Task.isCancelled else { return }
        let ownership = await serializeLifecycle { manager in
            await manager.startOwned(audioStream: audioStream)
        }
        guard let ownership else { return }
        // The long-lived stream join stays outside the lifecycle request queue,
        // so explicit stop can enter that queue and join this exact session.
        await join(ownership.session, task: ownership.ingestion)
    }

    /// App calls this before creating a new producer/consumer pair. A previous
    /// stop that preceded consumer registration cannot suppress a later session.
    public func prepareCapturedInput() async {
        await serializeLifecycle { manager in await manager.prepareCapturedInputOwned() }
    }

    private func prepareCapturedInputOwned() { nextSessionDrainsCapturedInput = false }

    /// The caller must first stop/join the producer and finish its input stream.
    /// Cancel inference immediately, then drain queued captured PCM and final
    /// partials to durable storage. An early request is consumed by the next
    /// registered session; App's prepare call separates successive producers.
    public func finishCapturedInput() async {
        await serializeLifecycle { manager in await manager.finishCapturedInputOwned() }
    }

    private func finishCapturedInputOwned() async {
        guard let session = processingSession, let task = session.ingestionTask else {
            nextSessionDrainsCapturedInput = true
            return
        }
        session.stopInference()
        await task.value
    }

    /// Cancels and joins ingestion, native/model work and entered callbacks.
    /// Callbacks must enqueue a lifecycle request outside their own delivery;
    /// awaiting this stop from inside a callback would join the callback itself.
    public func stopProcessing() async {
        await serializeLifecycle { manager in await manager.stopOwned() }
    }

    private func startOwned(audioStream: AsyncStream<CapturedAudio>) async -> AudioProcessingOwnership? {
        guard !Task.isCancelled else { return nil }
        while let existing = processingSession {
            guard let task = existing.ingestionTask else { return nil }
            if existing.isCancelled {
                await task.value
                guard !Task.isCancelled else { return nil }
                continue
            }
            return AudioProcessingOwnership(session: existing, ingestion: task)
        }
        guard !Task.isCancelled else { return nil }
        if let retained = retainedPersistenceFailure {
            let retried = await persistRawBatch(retained.batch, recovering: retained)
            guard retried.rawBatchID != nil else {
                retainedPersistenceFailure = retried
                await persistenceFailureCallback?()
                return nil
            }
            retainedPersistenceFailure = nil
            hasPersistenceFailure = false
        }
        guard !Task.isCancelled else { return nil }
        if !retainedChunkInputs.isEmpty {
            let retained = retainedChunkInputs
            retainedChunkInputs.removeAll()
            await persistAcceptedChunkInputs(retained)
            guard retainedChunkInputs.isEmpty else { return nil }
        }
        if mediaStore != nil {
            guard await recoverChunkRegistrations() else { return nil }
        }
        guard !Task.isCancelled else { return nil }
        hasPersistenceFailure = false
        previousChunks.removeAll()
        chunkBuffer = AudioChunkBuffer()
        let session = AudioProcessingSession(chunkedAudio: config.chunkedAudioEnabled)
        if nextSessionDrainsCapturedInput { session.stopInference() }
        nextSessionDrainsCapturedInput = false
        processingSession = session
        bufferManager = AudioBufferManager(maxBufferDuration: config.maxBufferDuration)
        let task = Task { await self.ingest(audioStream, session: session) }
        session.installIngestion(task)
        pendingCursor = 0
        pendingPage.removeAll()
        sweepExhausted = false
        startLiveTranscriptionWorkerIfNeeded(session: session)
        session.signalWork()
        return AudioProcessingOwnership(session: session, ingestion: task)
    }

    private func stopOwned() async {
        guard let session = processingSession, let task = session.ingestionTask else { return }
        session.cancel()
        await task.value
    }

    /// Opaque, content-free synchronization receipt for controlled concurrency
    /// regressions. It grants no session ownership or mutation capability.
    var lifecycleRegistrationID: UUID { lifecycleID }

    private func serializeLifecycle<Value: Sendable>(
        _ operation: @escaping @Sendable (AudioProcessingManager) async -> Value
    ) async -> Value {
        let predecessor = lifecycleTail
        let id = UUID()
        let operationTask = Task { [self] in
            await predecessor?.value
            return await operation(self)
        }
        lifecycleID = id
        lifecycleTail = Task { _ = await operationTask.value }
        let value = await withTaskCancellationHandler { await operationTask.value } onCancel: { operationTask.cancel() }
        if lifecycleID == id { lifecycleTail = nil }
        return value
    }

    private func join(_ session: AudioProcessingSession, task: Task<Void, Never>) async {
        await withTaskCancellationHandler { await task.value } onCancel: { session.cancel() }
    }

    private func acceptsWork(_ session: AudioProcessingSession) -> Bool {
        processingSession?.id == session.id && !session.isCancelled && !Task.isCancelled
    }

    private func ingest(_ audioStream: AsyncStream<CapturedAudio>, session: AudioProcessingSession) async {
        for await audio in audioStream {
            guard acceptsWork(session) else { break }
            if session.chunkedAudio {
                do {
                    let chunks = try await chunkBuffer.append(audio)
                    // Sample ownership was accepted above. Stop cancels inference,
                    // but durable capture writes remain joined and uncancelled.
                    await persistAcceptedChunksJoined(chunks)
                    session.signalWork()
                } catch {
                    hasPersistenceFailure = true
                    Log.error("[AudioProcessingManager] Captured PCM rejected by exact chunk contract", category: .processing)
                    await persistenceFailureCallback?()
                }
            } else {
                let batch = await bufferManager.addSample(audio)
                guard acceptsWork(session) else { break }
                if let batch { await acceptBatch(batch, session: session) }
            }
            if hasPersistenceFailure { break }
        }

        if session.chunkedAudio {
            // A stop or natural end persists every accepted partial exactly once.
            // The joined task does not inherit cancellation from inference/stop.
            let remaining = await chunkBuffer.finish()
            await persistAcceptedChunksJoined(remaining)
            session.signalWork()
        } else if acceptsWork(session) && !hasPersistenceFailure {
            let remaining = await bufferManager.flush()
            for batch in remaining {
                guard acceptsWork(session) else { break }
                await acceptBatch(batch, session: session)
                if hasPersistenceFailure { break }
            }
        }
        if !acceptsWork(session) {
            session.cancel()
            // Completed raw batches remain in SQLite/on disk for recovery.
            // Drop only in-memory scheduling references and partial PCM below.
            liveTranscriptionQueue.removeAll()
        }
        session.finishInput()
        await waitForLiveTranscriptionQueueToDrain(session: session)

        // No successor starts until this session's ingestion and worker retire.
        // The identity guard also prevents an old task clearing a newer slot.
        if processingSession?.id == session.id {
            liveTranscriptionQueue.removeAll()
            if liveTranscriptionWorker?.sessionID == session.id { liveTranscriptionWorker = nil }
            bufferManager = AudioBufferManager(maxBufferDuration: config.maxBufferDuration)
            previousBatchTrailingWords.removeAll()
            previousBatchDuration = 0
            processingSession = nil
        }
        session.finish()
    }

    private func persistAcceptedChunksJoined(_ inputs: [AudioChunkInput]) async {
        guard !inputs.isEmpty else { return }
        let task = Task.detached(priority: .utility) { [self] in
            await persistAcceptedChunkInputs(inputs)
        }
        await task.value
    }

    /// At most one bounded capture callback plus final per-source partials can
    /// wait here: ingestion stops immediately after a durable-write failure.
    private func persistAcceptedChunkInputs(_ inputs: [AudioChunkInput]) async {
        if !retainedChunkInputs.isEmpty {
            retainedChunkInputs.append(contentsOf: inputs)
            return
        }
        for (index, input) in inputs.enumerated() {
            do {
                guard let mediaStore, let queries = transcriptionQueries else {
                    throw AudioTranscriptionMediaError.unavailable
                }
                let prior = previousChunks[input.source]
                let continuous = prior?.streamID == input.streamID ? prior : nil
                let window = try await mediaStore.persistChunk(input, previous: continuous)
                _ = try await queries.registerRawAudioWindow(window, probableSilenceHint:
                    AudioSpeechActivityPolicy.evaluate(input.pcmData, sampleRate: 16_000, channels: 1).isProbablySilence)
                previousChunks[input.source] = window.manifest.ranges.last?.chunk
                do { try await mediaStore.acknowledgePublished(window) }
                catch { Log.warning("[AudioProcessingManager] Published audio journal acknowledgement deferred", category: .processing) }
            } catch {
                retainedChunkInputs.append(contentsOf: inputs[index...])
                hasPersistenceFailure = true
                Log.error("[AudioProcessingManager] Exact audio chunk persistence interrupted", category: .processing)
                await persistenceFailureCallback?()
                return
            }
        }
    }

    /// One bounded page per startup/tick. The owned session ticker resumes any
    /// remainder while capture proceeds; no task is detached for backlog repair.
    private func recoverChunkRegistrations() async -> Bool {
        guard let mediaStore, let queries = transcriptionQueries else { return false }
        do {
            let pending = try await mediaStore.pendingWindows(limit: 16)
            for window in pending {
                try Task.checkCancellation()
                do {
                    _ = try await queries.registerRawAudioWindow(window)
                } catch {
                    // A matching canonical tombstone proves this exact journal
                    // was deleted after publication. Acknowledge staging only;
                    // never recreate history or authorize media removal here.
                    guard try await queries.isAudioWindowCanonicallyDeleted(window) else { throw error }
                }
                try await mediaStore.acknowledgePublished(window)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            hasPersistenceFailure = true
            Log.error("[AudioProcessingManager] Durable audio registration recovery interrupted", category: .processing)
            await persistenceFailureCallback?()
            return false
        }
    }

    /// Persist completed raw audio before model work. A cancellation arriving
    /// during persistence leaves its durable pending batch available for repair.
    private func acceptBatch(_ batch: AudioBatch, session: AudioProcessingSession) async {
        guard acceptsWork(session) else { return }
        let persistedBatch = await persistRawBatch(batch)
        // Governed production must never fall back to an unbounded volatile queue
        // when initialization could not acquire either durable dependency.
        let requiresDurability = governor != nil || (audioWriter != nil && transcriptionQueries != nil)
        if requiresDurability && persistedBatch.rawBatchID == nil {
            retainedPersistenceFailure = persistedBatch
            hasPersistenceFailure = true
            await persistenceFailureCallback?()
            return
        }
        guard acceptsWork(session) else { return }
        enqueueLiveTranscription(persistedBatch, session: session)
    }

    private func persistRawBatch(_ batch: AudioBatch, recovering: PersistedAudioBatch? = nil) async -> PersistedAudioBatch {
        var rawBatchID: Int64?
        var savedBatchPath: String?
        var savedBatchURL: URL?
        if let writer = audioWriter {
            do {
                let batchPath: String
                let batchSize: Int64
                if let path = recovering?.savedBatchPath, let url = recovering?.savedBatchURL {
                    batchPath = path
                    batchSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                } else {
                    (batchPath, batchSize) = try await writer.writeFullBatch(
                    audioData: batch.audioData,
                    sampleRate: batch.sampleRate,
                    channels: batch.channels,
                    timestamp: batch.startTimestamp,
                    source: batch.source
                    )
                }
                savedBatchPath = batchPath
                savedBatchURL = writer.storageRoot.appendingPathComponent(batchPath)
                Log.debug("[AudioProcessingManager] Saved raw batch: \(batchPath) (\(batchSize) bytes)", category: .processing)

                // Insert DB record for the raw batch
                if let queries = transcriptionQueries {
                    do {
                        rawBatchID = try await queries.insertRawBatch(
                            startTime: batch.startTimestamp,
                            endTime: batch.endTimestamp,
                            source: batch.source,
                            audioPath: batchPath,
                            audioSize: batchSize,
                            probableSilenceHint: AudioSpeechActivityPolicy.evaluate(batch.audioData, sampleRate: batch.sampleRate, channels: batch.channels).isProbablySilence
                        )
                    } catch {
                        Log.error("[AudioProcessingManager] Failed to insert raw batch DB record: \(error)", category: .processing)
                    }
                }
            } catch {
                Log.error("[AudioProcessingManager] Failed to save raw batch audio: \(error)", category: .processing)
            }
        }

        return PersistedAudioBatch(
            batch: batch,
            rawBatchID: rawBatchID,
            savedBatchPath: savedBatchPath,
            savedBatchURL: savedBatchURL
        )
    }

    private func enqueueLiveTranscription(_ persistedBatch: PersistedAudioBatch, session: AudioProcessingSession) {
        // Durable rows are the queue. Only nonpersisted fallback work retains PCM references.
        if persistedBatch.rawBatchID == nil { liveTranscriptionQueue.append(persistedBatch) }
        startLiveTranscriptionWorkerIfNeeded(session: session)
        session.signalWork()
    }

    private func startLiveTranscriptionWorkerIfNeeded(session: AudioProcessingSession) {
        guard acceptsWork(session), !session.isInferenceStopped, liveTranscriptionWorker == nil else { return }
        let workerID = UUID()
        let task = Task { await self.processLiveTranscriptionQueue(session: session) }
        liveTranscriptionWorker = (session.id, workerID, task)
        session.installWorker(id: workerID, task: task)
    }

    private func processLiveTranscriptionQueue(session: AudioProcessingSession) async {
        // Keep one task for the whole session, including idle periods, so its
        // handle remains owned until ingestion has actually joined task.value.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: self.pendingRetryInterval, clock: .continuous) } catch { return }
                    await self.retryPendingSweep(session: session)
                }
            }
            defer { group.cancelAll() }
        for await _ in session.wakeStream {
            while acceptsWork(session) {
                let persistedBatch: PersistedAudioBatch
                if !liveTranscriptionQueue.isEmpty {
                    persistedBatch = liveTranscriptionQueue.removeFirst()
                } else if let queries = transcriptionQueries, let writer = audioWriter {
                    do {
                        if pendingPage.isEmpty {
                            pendingPage = try await queries.getUntranscribedBatches(limit: 16, afterID: pendingCursor)
                            guard let last = pendingPage.last else { sweepExhausted = true; break }
                            pendingCursor = last.id
                        }
                        let wantsSilence = speechAdmissions >= 3
                        let selected = pendingPage.firstIndex { $0.probableSilenceHint == wantsSilence } ?? 0
                        let row = pendingPage.remove(at: selected)
                        speechAdmissions = row.probableSilenceHint ? 0 : speechAdmissions + 1
                        persistedBatch = PersistedAudioBatch(batch: AudioBatch(audioData: Data(), source: row.source,
                            startTimestamp: row.startTime, endTimestamp: row.endTime,
                            duration: row.endTime.timeIntervalSince(row.startTime), sampleRate: 16_000, channels: 1),
                            rawBatchID: row.id, savedBatchPath: row.audioPath,
                            savedBatchURL: writer.storageRoot.appendingPathComponent(row.audioPath), probableSilenceHint: row.probableSilenceHint)
                    } catch { sweepExhausted = true; break }
                } else { break }
                await processGovernedBatch(persistedBatch)
            }
            if !acceptsWork(session) || (session.isInputFinished && liveTranscriptionQueue.isEmpty) { return }
        }
        }
    }

    private func retryPendingSweep(session: AudioProcessingSession) async {
        guard acceptsWork(session) else { return }
        if mediaStore != nil { _ = await recoverChunkRegistrations() }
        guard acceptsWork(session), sweepExhausted else { return }
        pendingCursor = 0
        sweepExhausted = false
        session.signalWork()
    }

    private func waitForLiveTranscriptionQueueToDrain(session: AudioProcessingSession) async {
        guard let worker = liveTranscriptionWorker, worker.sessionID == session.id else { return }
        await worker.task.value
        if liveTranscriptionWorker?.sessionID == session.id, liveTranscriptionWorker?.id == worker.id {
            liveTranscriptionWorker = nil
        }
        session.retireWorker(id: worker.id)
    }

    private func processGovernedBatch(_ batch: PersistedAudioBatch) async {
        guard let governor else { await processPersistedBatch(batch); return }
        while !Task.isCancelled {
            do {
                let permit = try await governor.acquire(batch.probableSilenceHint ? .ambientSilence : .ambientSpeech)
                await withTaskCancellationHandler {
                    await BackgroundProcessingContext.$permit.withValue(permit) {
                        await self.processPersistedBatch(batch)
                    }
                } onCancel: { permit.cancellation.cancel() }
                await governor.release(permit)
                if !permit.cancellation.isCancelled { return }
                // Renewed input cancels inference, not the durable work or session.
            } catch { return }
        }
    }

    /// Process a single persisted batch of accumulated audio (~30s)
    private func processPersistedBatch(_ persistedBatch: PersistedAudioBatch) async {
        guard !Task.isCancelled else { return }
        let startTime = Date()
        let originalSource: AudioOriginalSourceReceipt?
        do {
            try BackgroundProcessingContext.checkCancellation()
            if let path = persistedBatch.savedBatchPath, let queries = transcriptionQueries, let rawID = persistedBatch.rawBatchID {
                originalSource = try await queries.pendingFirstPassSource(rawBatchID: rawID, path: path)
            } else { originalSource = nil }
        } catch { return }
        if let path = persistedBatch.savedBatchPath, let queries = transcriptionQueries,
           let writer = audioWriter {
            do {
                try await AudioTranscriptionMedia.withInput(path: path,
                    legacyStartTime: persistedBatch.batch.startTimestamp, storageRoot: writer.storageRoot,
                    queries: queries, mediaStore: mediaStore) { [self] input in
                        await processLoadedBatch(persistedBatch, originalSource: originalSource,
                            input: input, processingStarted: startTime)
                    }
            } catch is CancellationError {
                // Pending work remains durable and can reacquire a permit.
            } catch {
                Log.error("[AudioProcessingManager] Saved audio input unavailable", category: .processing)
                if let raw = persistedBatch.rawBatchID {
                    try? await queries.updateBatchOutcome(id: raw, text: "", transcriptStatus: "needs_repair",
                        detectedLanguage: nil, audioVariant: "raw", qualityFlags: "media_input_unavailable",
                        originalSource: originalSource)
                }
            }
            return
        }
        // Compatibility for callers without durable storage; production capture
        // never reaches this branch after a required persistence failure.
        let batch = persistedBatch.batch
        let input = AudioTranscriptionInput(data: batch.audioData, sampleRate: batch.sampleRate,
            duration: batch.duration, startTime: batch.startTimestamp, window: nil, lease: nil)
        await processLoadedBatch(persistedBatch, originalSource: originalSource,
            input: input, processingStarted: startTime)
    }

    private func processLoadedBatch(_ persistedBatch: PersistedAudioBatch,
        originalSource: AudioOriginalSourceReceipt?, input: AudioTranscriptionInput,
        processingStarted startTime: Date) async {
        let batch = AudioBatch(audioData: input.data, source: persistedBatch.batch.source,
            startTimestamp: input.startTime, endTimestamp: input.endTime, duration: input.duration,
            sampleRate: input.sampleRate, channels: 1)
        let rawBatchID = persistedBatch.rawBatchID
        let savedBatchPath = persistedBatch.savedBatchPath

        do {
            try BackgroundProcessingContext.checkCancellation()
            // Step 1: Always attempt transcription. Silence/junk detection is metadata,
            // never a pre-transcription gate, because missed speech is worse than junk.
            let decision = try await AudioTranscriptionRetryPipeline.transcribeBest(
                audioData: batch.audioData,
                sampleRate: batch.sampleRate,
                channels: batch.channels,
                transcriptionService: transcriptionService,
                wordLevel: input.window != nil || config.enableWordLevelTimestamps,
                initialPrompt: nil,
                profile: .liveFirstPass,
                requireWordTimings: input.window != nil
            )
            try BackgroundProcessingContext.checkCancellation()
            let transcription = decision.transcription
            try input.checkValidity()

            guard decision.shouldStoreText else {
                if let batchID = rawBatchID, let queries = transcriptionQueries {
                    try? await queries.updateBatchOutcome(
                        id: batchID,
                        text: "",
                        transcriptStatus: decision.status.rawValue,
                        detectedLanguage: transcription.language,
                        audioVariant: decision.audioVariant.rawValue,
                        qualityFlags: Self.qualityFlags(decision),
                    originalSource: originalSource
                )
                }
                return
            }

            // Step 2: Merge overlapping words from consecutive batches.
            // The overlap zone (first 5s of this batch = last 5s of previous batch) may
            // contain words that were cut by the previous batch. We deduplicate by checking
            // if a word in the overlap zone already appeared in the previous batch's trailing words.
            let overlapSeconds = 5.0
            let owned = try input.ownedTranscript(transcription)
            var mergedWords = Self.wordsOrTextFallback(
                words: owned.words,
                text: owned.text,
                duration: batch.duration
            )

            if input.window == nil, previousBatchSource == batch.source, let previousBatchEnd,
               abs(previousBatchEnd.timeIntervalSince(batch.startTimestamp) - 5) < 0.05,
               !previousBatchTrailingWords.isEmpty && !mergedWords.isEmpty {
                // Find words in this batch's overlap zone (first 5 seconds)
                let overlapEndIdx = mergedWords.firstIndex(where: { $0.start >= overlapSeconds }) ?? mergedWords.count

                if overlapEndIdx > 0 {
                    // Check each overlap word against previous batch's trailing words
                    var deduplicatedOverlap: [TranscriptionWord] = []
                    for word in mergedWords[0..<overlapEndIdx] {
                        // Convert this batch's relative timestamp to the previous batch's reference frame
                        // This batch's second 0 = previous batch's second (duration - overlap)
                        let prevBatchEquivalentTime = (previousBatchDuration - overlapSeconds) + word.start

                        // Check if this word already exists in the previous batch's trailing words
                        let isDuplicate = previousBatchTrailingWords.contains { prevWord in
                            abs(prevWord.start - prevBatchEquivalentTime) < 0.3 &&
                            prevWord.word.lowercased() == word.word.lowercased()
                        }

                        if !isDuplicate {
                            // This word was NOT captured by the previous batch — keep it
                            deduplicatedOverlap.append(word)
                        }
                    }

                    // Replace overlap zone with deduplicated version
                    mergedWords = deduplicatedOverlap + Array(mergedWords[overlapEndIdx...])
                }
            }

            let mergedText = Self.text(from: mergedWords, fallback: owned.text)
            guard !mergedText.trimmingCharacters(in: .whitespaces).isEmpty else {
                if let batchID = rawBatchID, let queries = transcriptionQueries {
                    try? await queries.updateBatchOutcome(
                        id: batchID,
                        text: transcription.text,
                        transcriptStatus: decision.status.rawValue,
                        detectedLanguage: transcription.language,
                        audioVariant: decision.audioVariant.rawValue,
                        qualityFlags: Self.qualityFlags(decision, appending: ["empty_merged_words"]),
                    originalSource: originalSource
                )
                }
                return
            }

            // Segment merged transcription into sentences
            let sentences = SentenceSegmenter.segment(
                words: mergedWords,
                fullText: mergedText,
                fallbackDuration: batch.duration
            )

            guard !sentences.isEmpty else {
                if let batchID = rawBatchID, let queries = transcriptionQueries {
                    try? await queries.updateBatchOutcome(
                        id: batchID,
                        text: mergedText,
                        transcriptStatus: decision.status.rawValue,
                        detectedLanguage: transcription.language,
                        audioVariant: decision.audioVariant.rawValue,
                        qualityFlags: Self.qualityFlags(decision, appending: ["empty_sentences"]),
                    originalSource: originalSource
                )
                }
                return
            }

            // Step 3: Save to database
            guard let queries = transcriptionQueries else {
                Log.warning("[AudioProcessingManager] Audio storage not configured, skipping save", category: .processing)
                return
            }

            // Sentence clips duplicate the raw batch. Store sentence timing in SQLite
            // and resolve playback against the canonical batch file instead.
            let transcriptAudioPath = AudioStoragePolicy.canonicalTranscriptPath(
                batchAudioPath: savedBatchPath
            )

            // Step 5: Build and batch insert all sentences with audio paths
            var transcriptionsBatch: [(
                sessionID: String?,
                text: String,
                startTime: Date,
                endTime: Date,
                source: AudioSource,
                confidence: Double?,
                words: [TranscriptionWord],
                audioPath: String?,
                transcriptionPass: Int,
                batchAudioPath: String?,
                transcriptStatus: String,
                detectedLanguage: String?,
                audioVariant: String,
                qualityFlags: String?
            )] = []

            for sentence in sentences {
                transcriptionsBatch.append((
                    sessionID: nil,
                    text: sentence.text,
                    startTime: batch.startTimestamp.addingTimeInterval(sentence.startTime),
                    endTime: batch.startTimestamp.addingTimeInterval(sentence.endTime),
                    source: batch.source,
                    confidence: sentence.confidence,
                    words: sentence.words,
                    audioPath: transcriptAudioPath,
                    transcriptionPass: 1,
                    batchAudioPath: savedBatchPath,
                    transcriptStatus: decision.status.rawValue,
                    detectedLanguage: transcription.language,
                    audioVariant: decision.audioVariant.rawValue,
                    qualityFlags: Self.qualityFlags(decision)
                ))
            }

            guard !transcriptionsBatch.isEmpty else {
                if let batchID = rawBatchID {
                    try? await queries.updateBatchOutcome(
                        id: batchID,
                        text: mergedText,
                        transcriptStatus: decision.status.rawValue,
                        detectedLanguage: transcription.language,
                        audioVariant: decision.audioVariant.rawValue,
                        qualityFlags: Self.qualityFlags(decision, appending: ["empty_transcription_batch"]),
                    originalSource: originalSource
                )
                }
                return
            }

            if let path = savedBatchPath { try await input.validateForPublication(queries: queries, path: path) }
            try BackgroundProcessingContext.checkCancellation()
            if let rawBatchID, let originalSource {
                _ = try await queries.commitFirstPass(rawBatchID: rawBatchID, records: transcriptionsBatch, originalSource: originalSource)
            } else {
                _ = try await queries.insertTranscriptionsBatch(transcriptionsBatch)
            }

            // This receipt is emitted only after the real transaction succeeds.
            // It carries the original audio occurrence, never the callback time.
            if let committed = config.committedTranscriptionCallback {
                await committed(AudioTranscriptCommitReceipt(startedAt: input.ownedStartTime,
                    endedAt: input.endTime, source: batch.source,
                    acceptedTranscription: decision.status == .transcribed))
            }

            // Step 6: Update statistics
            let processingTime = Date().timeIntervalSince(startTime)
            updateStatistics(
                transcription: transcription,
                processingTime: processingTime
            )

            // Step 7: Invoke callback if configured
            if let callback = config.transcriptionCallback {
                let syntheticAudio = CapturedAudio(
                    timestamp: batch.startTimestamp,
                    audioData: batch.audioData,
                    duration: batch.duration,
                    source: batch.source,
                    sampleRate: batch.sampleRate,
                    channels: batch.channels
                )
                await callback(syntheticAudio, transcription)
            }

            // Keep timing evidence for overlap deduplication. Live decoding deliberately
            // remains context-free; contextual prompts are reserved for repair passes.
            if input.window == nil {
                previousBatchEnd = batch.endTimestamp
                previousBatchSource = batch.source
                previousBatchDuration = batch.duration
                previousBatchTrailingWords = transcription.words.filter {
                    $0.start >= (batch.duration - 10.0)
                }
            }

            Log.info("[AudioProcessingManager] Batch transcribed: \(sentences.count) sentences, \(transcription.words.count) words from \(batch.source.rawValue) status=\(decision.status.rawValue) variant=\(decision.audioVariant.rawValue) language=\(transcription.language ?? "unknown") attempts=\(decision.attempts) (\(String(format: "%.1f", batch.duration))s)", category: .processing)

        } catch is CancellationError {
            // The raw batch remains pending; caller/stop joins this worker.
        } catch let error as AudioTranscriptionMediaError {
            if let rawBatchID, let queries = transcriptionQueries {
                try? await queries.updateBatchOutcome(id: rawBatchID, text: "", transcriptStatus: "needs_repair",
                    detectedLanguage: nil, audioVariant: "raw", qualityFlags: "exact_window_ownership_unavailable",
                    originalSource: originalSource)
            }
            Log.warning("[AudioProcessingManager] Exact window publication deferred: \(error)", category: .processing)
        } catch {
            Log.error("[AudioProcessingManager] Batch transcription error: \(error)", category: .processing)
        }
    }

    private func updateStatistics(transcription: DetailedTranscriptionResult, processingTime: TimeInterval) {
        let wordCount = transcription.words.count
        let totalConfidence = transcription.words.reduce(0.0) { $0 + ($1.confidence ?? 0) }
        let avgConfidence = wordCount > 0 ? totalConfidence / Double(wordCount) : 0

        let prevTotalSamples = Double(statistics.totalAudioSamplesProcessed)
        let prevAvgConfidence = statistics.averageConfidence

        statistics = AudioProcessingStatistics(
            totalAudioSamplesProcessed: statistics.totalAudioSamplesProcessed + 1,
            totalTranscriptionsGenerated: statistics.totalTranscriptionsGenerated + 1,
            totalWordsTranscribed: statistics.totalWordsTranscribed + wordCount,
            totalProcessingTime: statistics.totalProcessingTime + processingTime,
            averageConfidence: (prevAvgConfidence * prevTotalSamples + avgConfidence) / (prevTotalSamples + 1),
            lastProcessedAt: Date()
        )
    }

    // MARK: - Audio Analysis

    /// Calculate RMS energy of PCM Int16 audio data
    private static func calculateRMS(_ audioData: Data) -> Double {
        let int16Count = audioData.count / 2
        guard int16Count > 0 else { return 0 }

        var sumSquares: Double = 0
        audioData.withUnsafeBytes { buffer in
            let samples = buffer.bindMemory(to: Int16.self)
            for i in 0..<int16Count {
                let normalized = Double(samples[i]) / 32768.0
                sumSquares += normalized * normalized
            }
        }
        return (sumSquares / Double(int16Count)).squareRoot()
    }

    /// Detect whisper hallucinations: repetitive phrases, common filler, and generic whisper noise
    private static func isHallucination(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
        let lower = trimmed.lowercased()

        // Common single-word/short whisper hallucinations (exact match)
        let knownExact: Set<String> = [
            "thank you", "thanks", "thank", "you", "bye",
            "uh", "um", "oh", "i'm", "so", "okay", "ok"
        ]
        if knownExact.contains(lower) {
            return true
        }

        // Phrases that indicate whisper hallucination (substring match)
        let knownSubstrings = [
            "thanks for watching", "thank you for watching",
            "please subscribe", "like and subscribe",
            "hit the like", "hit the bell",
            "subtitles by", "translated by",
            "i hope you enjoyed", "see you in the next",
            "don't forget to subscribe", "leave a comment",
            "i'll see you in the next video",
            "so i'm going to go ahead and"
        ]
        for phrase in knownSubstrings {
            if lower.contains(phrase) {
                return true
            }
        }

        // Very short text (< 4 real words) is likely not meaningful speech
        let words = trimmed.split(separator: " ").map(String.init)
        if words.count <= 2 {
            return true
        }

        guard words.count >= 4 else { return false }

        // Check if any 2-4 word phrase repeats more than 3 times
        for phraseLen in 2...min(4, words.count / 2) {
            var phraseCounts: [String: Int] = [:]
            for i in 0...(words.count - phraseLen) {
                let phrase = words[i..<(i + phraseLen)].joined(separator: " ").lowercased()
                phraseCounts[phrase, default: 0] += 1
            }
            if let maxCount = phraseCounts.values.max(), maxCount > 3 {
                return true
            }
        }

        // Check if text is mostly a single repeated word
        var wordCounts: [String: Int] = [:]
        for w in words {
            wordCounts[w.lowercased(), default: 0] += 1
        }
        if let (_, count) = wordCounts.max(by: { $0.value < $1.value }) {
            if Double(count) / Double(words.count) > 0.5 && words.count > 4 {
                return true
            }
        }

        return false
    }

    private static func qualityFlags(
        _ decision: AudioTranscriptionDecision,
        appending extraFlags: [String] = []
    ) -> String? {
        let flags = decision.qualityFlags
            + ["variant:\(decision.audioVariant.rawValue)", "language_hint:\(decision.languageHint.rawValue)", "attempts:\(decision.attempts)"]
            + extraFlags
        return flags.isEmpty ? nil : flags.joined(separator: ",")
    }

    private static func wordsOrTextFallback(
        words: [TranscriptionWord],
        text: String,
        duration: TimeInterval
    ) -> [TranscriptionWord] {
        guard words.isEmpty else { return words }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [
            TranscriptionWord(
                word: trimmed,
                start: 0,
                end: max(duration, 0.01),
                confidence: nil
            )
        ]
    }

    private static func text(from words: [TranscriptionWord], fallback: String) -> String {
        let fallbackText = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.count == 1, words[0].word == fallbackText {
            return fallbackText
        }
        return words.map(\.word).joined(separator: " ")
    }

    // MARK: - Configuration

    public func updateConfig(_ config: AudioProcessingConfig) {
        self.config = config
    }

    public func getConfig() -> AudioProcessingConfig {
        return config
    }

    // MARK: - Statistics

    public func getStatistics() -> AudioProcessingStatistics {
        return statistics
    }

    public func resetStatistics() {
        statistics = AudioProcessingStatistics(
            totalAudioSamplesProcessed: 0,
            totalTranscriptionsGenerated: 0,
            totalWordsTranscribed: 0,
            totalProcessingTime: 0,
            averageConfidence: 0,
            lastProcessedAt: nil
        )
    }

    // MARK: - State

    public var isCurrentlyProcessing: Bool {
        return processingSession != nil
    }
}

// MARK: - Configuration

public struct AudioProcessingConfig: Sendable {
    /// Independently switchable new-media candidate. Existing history stays readable.
    public var chunkedAudioEnabled: Bool

    /// Enable word-level timestamps (more expensive but more accurate)
    public let enableWordLevelTimestamps: Bool

    /// Minimum confidence threshold (0-1) to store transcription
    public let minimumConfidence: Double

    /// Maximum audio buffer size before forcing transcription (seconds).
    /// Shorter live batches reduce silence dilution and dashboard latency.
    public let maxBufferDuration: Double

    /// Legacy configuration retained for compatibility. Production work uses a
    /// bounded 16-row durable pending page and one retained persistence failure.
    public let maxQueuedLiveTranscriptionBatches: Int

    /// Content-free acknowledgement after durable sentence insertion.
    public let committedTranscriptionCallback: (@Sendable (AudioTranscriptCommitReceipt) async -> Void)?

    /// Callback invoked after each transcription
    public let transcriptionCallback: (@Sendable (CapturedAudio, DetailedTranscriptionResult) async -> Void)?

    public init(
        enableWordLevelTimestamps: Bool = true,
        minimumConfidence: Double = 0.5,
        maxBufferDuration: Double = 15.0,
        maxQueuedLiveTranscriptionBatches: Int = 12,
        chunkedAudioEnabled: Bool = false,
        transcriptionCallback: (@Sendable (CapturedAudio, DetailedTranscriptionResult) async -> Void)? = nil,
        committedTranscriptionCallback: (@Sendable (AudioTranscriptCommitReceipt) async -> Void)? = nil
    ) {
        self.enableWordLevelTimestamps = enableWordLevelTimestamps
        self.chunkedAudioEnabled = chunkedAudioEnabled
        self.minimumConfidence = minimumConfidence
        self.maxBufferDuration = maxBufferDuration
        self.maxQueuedLiveTranscriptionBatches = max(0, maxQueuedLiveTranscriptionBatches)
        self.transcriptionCallback = transcriptionCallback
        self.committedTranscriptionCallback = committedTranscriptionCallback
    }

    public static let `default` = AudioProcessingConfig()
}

// MARK: - Statistics

public struct AudioProcessingStatistics: Sendable {
    public let totalAudioSamplesProcessed: Int
    public let totalTranscriptionsGenerated: Int
    public let totalWordsTranscribed: Int
    public let totalProcessingTime: TimeInterval
    public let averageConfidence: Double
    public let lastProcessedAt: Date?

    public var averageProcessingTimePerSample: TimeInterval {
        guard totalAudioSamplesProcessed > 0 else { return 0 }
        return totalProcessingTime / Double(totalAudioSamplesProcessed)
    }

    public var averageWordsPerTranscription: Double {
        guard totalTranscriptionsGenerated > 0 else { return 0 }
        return Double(totalWordsTranscribed) / Double(totalTranscriptionsGenerated)
    }
}
