import Foundation
import Shared
import Database
import Storage

private enum PendingAudioCompletionError: Error { case staleRow, modelUnavailable }

/// A committed recording plus its original PCM lineage. This receipt does not
/// itself prove an AAC seek mapping; the context owner verifies the retained file.
public struct PersistedAudioBatchReceipt: Sendable {
    public let rawBatchID: Int64
    public let relativePath: String
    public let fileURL: URL
    public let fileSize: Int64
    public let frameCount: Int64
    public let sampleRate: Int
    public let channels: Int
    public let source: AudioSource
    public let startTimestamp: Date
    public let endTimestamp: Date
    public let sourceRanges: [AudioBatchSourceRange]
    public let sourceMappingIncomplete: Bool

    public init(rawBatchID: Int64, relativePath: String, fileURL: URL, fileSize: Int64,
                frameCount: Int64, sampleRate: Int, channels: Int, source: AudioSource,
                startTimestamp: Date, endTimestamp: Date, sourceRanges: [AudioBatchSourceRange], sourceMappingIncomplete: Bool = false) {
        self.rawBatchID = rawBatchID; self.relativePath = relativePath; self.fileURL = fileURL
        self.fileSize = fileSize; self.frameCount = frameCount; self.sampleRate = sampleRate
        self.channels = channels; self.source = source
        self.startTimestamp = startTimestamp; self.endTimestamp = endTimestamp; self.sourceRanges = sourceRanges
        self.sourceMappingIncomplete = sourceMappingIncomplete
    }
}

/// Canonical first-pass rows after a successful commit. Text remains verbatim; optional enrichment
/// cannot replace these rows or delay the next capture write with a network request.
public struct CommittedAudioBatchReceipt: Sendable {
    public let relativePath: String
    public let source: AudioSource
    public let records: [AudioTranscription]
    public var firstPassText: String { records.map(\.text).joined(separator: "\n") }
    public init(relativePath: String, source: AudioSource, records: [AudioTranscription]) {
        self.relativePath = relativePath; self.source = source; self.records = records
    }
}

private struct PersistedAudioBatch: Sendable {
    let batch: AudioBatch
    let rawBatchID: Int64?
    let savedBatchPath: String?
    let savedBatchURL: URL?
    let pendingRecord: UntranscribedBatch?

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
            savedBatchURL: savedBatchURL,
            pendingRecord: pendingRecord
        )
    }
}

/// Coordinates audio capture → batch buffering → transcription → database storage pipeline
/// Accumulates PCM into bounded batches per source before calling whisper.cpp.
public actor AudioProcessingManager {
    public typealias PersistedBatchHandler = @Sendable (PersistedAudioBatchReceipt) async throws -> Void
    public typealias CommittedBatchHandler = @Sendable (CommittedAudioBatchReceipt) async throws -> Void

    private var transcriptionService: any TranscriptionProtocol
    private var transcriptionQueries: AudioTranscriptionQueries?
    private var audioWriter: AudioSegmentWriter?
    private var isProcessing = false
    private let governor: (any BackgroundProcessingProtocol)?
    private var ingestionTask: Task<Void, Never>?
    private var admissionTask: Task<BackgroundProcessingPermit, Error>?
    private var admissionKind: BackgroundProcessingKind?
    private var pendingGeneration: UInt64 = 0
    /// Attempt budget survives quiet-time revocation for this manager's lifetime. Durable
    /// rows remain the queue; a new process starts by giving current recordings a turn.
    private var consecutiveRecentAutomaticAttempts = 0
    public private(set) var isTranscribing = false
    public private(set) var hasPersistenceFailure = false
    /// Sticky disclosure: canonical recordings survive a failed optional context registration.
    public private(set) var hasPersistedBatchCallbackFailure = false
    private var onPersistedBatch: PersistedBatchHandler?
    private var onCommittedBatch: CommittedBatchHandler?
    public private(set) var hasCommittedBatchCallbackFailure = false
    #if DEBUG
    private(set) var acceptedAudioSampleCountForTesting = 0
    #endif

    /// Trailing words from the last batch (in the overlap zone) — used to deduplicate
    private var previousBatchTrailingWords: [TranscriptionWord] = []

    /// Duration of the last batch — needed to compute absolute timestamps for trailing words
    private var previousBatchDuration: TimeInterval = 0
    private var previousBatchStart: Date?
    private var previousBatchSource: AudioSource?

    // Batch buffering
    private var bufferManager: AudioBufferManager

    // Live transcription queue. Ingestion must keep draining capture even when Whisper is slow.
    private var liveTranscriptionQueue: [PersistedAudioBatch] = []
    private var liveTranscriptionWorker: Task<Void, Never>?

    // Configuration
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
        governor: (any BackgroundProcessingProtocol)? = nil,
        config: AudioProcessingConfig = .default,
        onPersistedBatch: PersistedBatchHandler? = nil
    ) {
        self.transcriptionService = transcriptionService
        self.transcriptionQueries = transcriptionQueries
        self.audioWriter = audioWriter
        self.config = config
        self.governor = governor
        self.onPersistedBatch = onPersistedBatch
        self.bufferManager = AudioBufferManager(maxBufferDuration: config.maxBufferDuration)
    }

    /// Configure before recording starts. Active accepted writes retain their
    /// observer until its joined callback completes.
    @discardableResult
    public func setPersistedBatchHandler(_ handler: PersistedBatchHandler?) -> Bool {
        guard !isProcessing else { return false }
        onPersistedBatch = handler
        return true
    }

    @discardableResult
    public func setCommittedBatchHandler(_ handler: CommittedBatchHandler?) -> Bool {
        guard !isProcessing else { return false }
        onCommittedBatch = handler
        return true
    }

    /// Join accepted capture writes, pending admission and the native inference callback.
    public func stopProcessing() async {
        guard let task = ingestionTask else { return }
        task.cancel()
        await task.value
    }

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
        guard governor == nil else { return }
        do {
            try await transcriptionService.initialize()
        } catch {
            Log.warning("[AudioProcessingManager] Transcription service init failed (model may not be downloaded yet): \(error)", category: .processing)
        }
    }

    /// Hot-swap the transcription service (e.g., after downloading whisper model)
    public func updateTranscriptionService(_ service: any TranscriptionProtocol) {
        self.transcriptionService = service
        if isProcessing { startLiveTranscriptionWorkerIfNeeded() }
        Log.info("[AudioProcessingManager] Transcription service updated to \(type(of: service))", category: .processing)
    }

    // MARK: - Processing Pipeline

    /// Start processing audio stream with batch accumulation
    public func startProcessing(audioStream: AsyncStream<CapturedAudio>) async {
        guard !isProcessing, !Task.isCancelled else { return }
        isProcessing = true
        bufferManager = AudioBufferManager(maxBufferDuration: config.maxBufferDuration)
        previousBatchTrailingWords.removeAll()
        previousBatchDuration = 0
        let task = Task { await self.ingest(audioStream) }
        ingestionTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
    }

    private func ingest(_ audioStream: AsyncStream<CapturedAudio>) async {
        defer { isProcessing = false; ingestionTask = nil }
        if governor != nil { startLiveTranscriptionWorkerIfNeeded() }
        for await audio in audioStream {
            guard !Task.isCancelled else { break }
            let batch = await bufferManager.addSample(audio)
            #if DEBUG
            acceptedAudioSampleCountForTesting += 1
            #endif
            // Once accepted into the buffer, a completed batch belongs to the durable writer,
            // even when stop arrives during the buffer actor hop.
            if let batch { await persistAcceptedBatchJoined(batch) }
        }
        let remaining = await bufferManager.flush()
        for batch in remaining { await persistAcceptedBatchJoined(batch) }
        if governor != nil || Task.isCancelled {
            await cancelLiveTranscriptionQueue()
        } else {
            await waitForLiveTranscriptionQueueToDrain()
        }
    }

    private func persistAcceptedBatchJoined(_ batch: AudioBatch) async {
        // Unstructured solely to keep accepted capture writes uncancelled; always joined.
        let write = Task { await self.acceptBatch(batch) }
        await write.value
    }

    /// Persist a completed raw batch before any model work. This keeps recall lossless
    /// even when live transcription is delayed or skipped under backpressure.
    private func acceptBatch(_ batch: AudioBatch) async {
        let persistedBatch = await persistRawBatch(batch)
        enqueueLiveTranscription(persistedBatch)
    }

    private func persistRawBatch(_ batch: AudioBatch) async -> PersistedAudioBatch {
        var rawBatchID: Int64?
        var savedBatchPath: String?
        var savedBatchURL: URL?
        var savedBatchSize: Int64?
        var pendingRecord: UntranscribedBatch?
        if let writer = audioWriter {
            do {
                let (batchPath, batchSize) = try await writer.writeFullBatch(
                    audioData: batch.audioData,
                    sampleRate: batch.sampleRate,
                    channels: batch.channels,
                    timestamp: batch.startTimestamp,
                    source: batch.source
                )
                savedBatchPath = batchPath
                savedBatchURL = writer.storageRoot.appendingPathComponent(batchPath)
                savedBatchSize = batchSize
                Log.debug("[AudioProcessingManager] Saved raw batch: \(batchPath) (\(batchSize) bytes)", category: .processing)

                // Insert DB record for the raw batch
                if let queries = transcriptionQueries {
                    do {
                        // Prioritization only. Quiet speech can be misclassified, so
                        // every original remains pending and eligible for catch-up.
                        let activity = AudioSpeechActivityPolicy.evaluate(batch.audioData,
                            sampleRate: batch.sampleRate, channels: batch.channels)
                        rawBatchID = try await queries.insertRawBatch(
                            startTime: batch.startTimestamp,
                            endTime: batch.endTimestamp,
                            source: batch.source,
                            audioPath: batchPath,
                            audioSize: batchSize,
                            deferForLowEnergy: activity.isProbablySilence
                        )
                        if let rawBatchID {
                            pendingRecord = UntranscribedBatch(id: rawBatchID,
                                startTime: batch.startTimestamp, endTime: batch.endTimestamp,
                                source: batch.source, audioPath: batchPath, audioSize: batchSize)
                        }
                    } catch {
                        Log.error("[AudioProcessingManager] Failed to insert raw batch DB record: \(error)", category: .processing)
                    }
                }
            } catch {
                Log.error("[AudioProcessingManager] Failed to save raw batch audio: \(error)", category: .processing)
            }
        }

        if let rawBatchID, let path = savedBatchPath, let fileURL = savedBatchURL,
           let fileSize = savedBatchSize, !batch.sourceRanges.isEmpty || batch.sourceMappingIncomplete, let onPersistedBatch {
            let receipt = PersistedAudioBatchReceipt(rawBatchID: rawBatchID, relativePath: path,
                fileURL: fileURL, fileSize: fileSize, frameCount: Int64(batch.audioData.count / (max(batch.channels, 1) * 2)),
                sampleRate: batch.sampleRate, channels: batch.channels, source: batch.source,
                startTimestamp: batch.startTimestamp, endTimestamp: batch.endTimestamp, sourceRanges: batch.sourceRanges,
                sourceMappingIncomplete: batch.sourceMappingIncomplete)
            do { try await onPersistedBatch(receipt) }
            catch {
                hasPersistedBatchCallbackFailure = true
                Log.warning("[AudioProcessingManager] Saved audio context registration failed; recording remains available", category: .processing)
            }
        }

        return PersistedAudioBatch(
            batch: batch,
            rawBatchID: rawBatchID,
            savedBatchPath: savedBatchPath,
            savedBatchURL: savedBatchURL,
            pendingRecord: pendingRecord
        )
    }

    private func enqueueLiveTranscription(_ persistedBatch: PersistedAudioBatch) {
        pendingGeneration &+= 1
        if governor != nil, persistedBatch.pendingRecord != nil {
            // The legacy SQLite pending row is the queue. No deferred PCM or metadata array.
            if admissionKind == .ambientSpeech { admissionTask?.cancel() }
            startLiveTranscriptionWorkerIfNeeded()
            return
        }
        if governor != nil {
            // Keep the previous immediate fallback when a raw write fails. It must not
            // sit behind a five-minute idle gate accumulating captured PCM in memory.
            hasPersistenceFailure = true
            admissionTask?.cancel()
            Log.error("[AudioProcessingManager] Raw audio persistence failed; using immediate legacy fallback", category: .processing)
        }
        let shouldSpool = persistedBatch.rawBatchID != nil &&
            config.maxQueuedLiveTranscriptionBatches > 0 &&
            liveTranscriptionQueue.count >= config.maxQueuedLiveTranscriptionBatches
        liveTranscriptionQueue.append(shouldSpool ? persistedBatch.spooledToDisk() : persistedBatch)
        startLiveTranscriptionWorkerIfNeeded()
    }

    private func startLiveTranscriptionWorkerIfNeeded() {
        guard liveTranscriptionWorker == nil else { return }
        if governor != nil, liveTranscriptionQueue.isEmpty,
           transcriptionService is MockTranscriptionService { return }
        liveTranscriptionWorker = Task(priority: .utility) { await self.processLiveTranscriptionQueue() }
    }

    private func processLiveTranscriptionQueue() async {
        defer { liveTranscriptionWorker = nil }
        while !Task.isCancelled {
            if !liveTranscriptionQueue.isEmpty {
                let persisted = liveTranscriptionQueue.removeFirst()
                do { try await processPersistedBatch(persisted) }
                catch is CancellationError { break }
                catch { Log.error("[AudioProcessingManager] Immediate batch transcription failed: \(error)", category: .processing) }
                continue
            }
            guard let governor, let queries = transcriptionQueries, let writer = audioWriter,
                  !(transcriptionService is MockTranscriptionService) else { return }
            let generation = pendingGeneration
            let fresh: UntranscribedBatch?
            do { fresh = try await queries.getFreshPendingBatch() }
            catch {
                if Task.isCancelled { break }
                Log.warning("[AudioProcessingManager] Fresh queue read failed; retaining pending work", category: .processing)
                try? await Task.sleep(for: .seconds(5))
                continue
            }
            let kind: BackgroundProcessingKind = fresh == nil ? .ambientSpeech : .freshTranscription
            let request = Task { try await governor.acquire(kind) }
            admissionKind = kind
            admissionTask = request
            let permit: BackgroundProcessingPermit
            do {
                permit = try await withTaskCancellationHandler {
                    try await request.value
                } onCancel: { request.cancel() }
            } catch {
                admissionTask = nil
                admissionKind = nil
                if Task.isCancelled { break }
                if !liveTranscriptionQueue.isEmpty { continue }
                // New durable audio deliberately interrupts a historical wait.
                // Re-evaluate its lane immediately; this is not a model failure.
                if error is CancellationError, generation != pendingGeneration { continue }
                try? await Task.sleep(for: .seconds(5), clock: .continuous)
                continue
            }
            admissionTask = nil
            admissionKind = nil
            if Task.isCancelled || !liveTranscriptionQueue.isEmpty {
                await governor.release(permit)
                continue
            }
            var retryDelay: Duration?
            var wasEmpty = false
            do {
                wasEmpty = try await withTaskCancellationHandler {
                    try await BackgroundProcessingContext.$permit.withValue(permit) {
                        try BackgroundProcessingContext.checkCancellation()
                        let recent: UntranscribedBatch?
                        if kind == .freshTranscription {
                            recent = try await queries.getFreshPendingBatch()
                            // It may have aged out or been completed while waiting for
                            // admission. Never use a fresh permit for old/repair work.
                            guard recent != nil else { return false }
                        } else if consecutiveRecentAutomaticAttempts < 3 {
                            recent = try await queries.getRecentPendingBatch()
                        } else {
                            recent = nil
                        }
                        let row: UntranscribedBatch
                        if let recent {
                            row = recent
                        } else if let oldest = try await queries.getOldestUntranscribedBatch() {
                            row = oldest
                        } else { return true }
                        try BackgroundProcessingContext.checkCancellation()
                        // Count selected attempts, not successes: a cancelled or broken oldest
                        // recording must not repeatedly take every subsequent admitted turn.
                        consecutiveRecentAutomaticAttempts = recent == nil ? 0 : consecutiveRecentAutomaticAttempts + 1
                        let pending = PersistedAudioBatch(
                            batch: AudioBatch(audioData: Data(), source: row.source,
                                startTimestamp: row.startTime, endTimestamp: row.endTime,
                                duration: max(0, row.endTime.timeIntervalSince(row.startTime)),
                                sampleRate: 16_000, channels: 1),
                            rawBatchID: row.id, savedBatchPath: row.audioPath,
                            savedBatchURL: writer.storageRoot.appendingPathComponent(row.audioPath),
                            pendingRecord: row)
                        try await processPersistedBatch(pending)
                        return false
                    }
                } onCancel: { permit.cancellation.cancel() }
            } catch is CancellationError {
                retryDelay = .milliseconds(100)
            } catch {
                retryDelay = .seconds(5)
                Log.error("[AudioProcessingManager] Pending transcription retained for retry: \(error)", category: .processing)
            }
            await governor.release(permit)
            if wasEmpty && generation == pendingGeneration { return }
            if let retryDelay { try? await Task.sleep(for: retryDelay, clock: .continuous) }
        }
    }

    private func waitForLiveTranscriptionQueueToDrain() async {
        while let worker = liveTranscriptionWorker {
            await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        }
    }

    private func cancelLiveTranscriptionQueue() async {
        let worker = liveTranscriptionWorker
        worker?.cancel()
        admissionTask?.cancel()
        await worker?.value
        liveTranscriptionQueue.removeAll()
    }

    /// Process a single persisted batch of accumulated audio (~30s)
    private func processPersistedBatch(_ persistedBatch: PersistedAudioBatch) async throws {
        try BackgroundProcessingContext.checkCancellation()
        let service = transcriptionService
        guard governor == nil || !(service is MockTranscriptionService) else {
            throw PendingAudioCompletionError.modelUnavailable
        }
        isTranscribing = true
        defer { isTranscribing = false }
        if governor != nil {
            try await service.initialize()
            try BackgroundProcessingContext.checkCancellation()
        }
        let startTime = Date()
        let batch: AudioBatch
        do {
            batch = try loadBatchForTranscription(persistedBatch)
        } catch {
            Log.error("[AudioProcessingManager] Failed to load queued batch audio: \(error)", category: .processing)
            if persistedBatch.pendingRecord != nil {
                try await updatePendingOutcome(persistedBatch,
                    text: persistedBatch.pendingRecord?.retainedFirstPass?.text ?? "",
                    transcriptStatus: AudioTranscriptStatus.decodeFailed.rawValue,
                    detectedLanguage: persistedBatch.pendingRecord?.retainedFirstPass?.language,
                    audioVariant: AudioEnhancementVariant.raw.rawValue,
                    qualityFlags: "decode_error"
                )
            }
            return
        }
        let savedBatchPath = persistedBatch.savedBatchPath
        let canDeferRepair = governor != nil && persistedBatch.pendingRecord != nil
        let profile: AudioTranscriptionProfile = canDeferRepair && persistedBatch.pendingRecord?.needsFirstPassRepair != true
            ? .liveFirstPass : .deferredFirstPassRepair

        do {
            // Step 1: Always attempt transcription. Silence/junk detection is metadata,
            // never a pre-transcription gate, because missed speech is worse than junk.
            let decision = try await AudioTranscriptionRetryPipeline.transcribeBest(
                audioData: batch.audioData,
                sampleRate: batch.sampleRate,
                channels: batch.channels,
                transcriptionService: service,
                wordLevel: config.enableWordLevelTimestamps,
                initialPrompt: nil,
                profile: profile,
                retainedFirstPass: persistedBatch.pendingRecord?.retainedFirstPass
            )
            try BackgroundProcessingContext.checkCancellation()
            let transcription = decision.transcription

            if profile == .liveFirstPass, AudioTranscriptionRetryPipeline.needsDeferredFirstPassRepair(decision) {
                // Preserve the raw identity and provisional result in the durable
                // queue. A later historical permit owns enhancement; it cannot
                // consume this fresh turn or loop back into the live lane.
                try await updatePendingOutcome(persistedBatch, text: transcription.text,
                    transcriptStatus: "needs_repair", detectedLanguage: transcription.language,
                    audioVariant: decision.audioVariant.rawValue,
                    qualityFlags: Self.qualityFlags(decision,
                        appending: [AudioPreparationMetadata.firstPassRepairPending]))
                return
            }

            guard decision.shouldStoreText else {
                if persistedBatch.pendingRecord != nil {
                    try await updatePendingOutcome(persistedBatch,
                        text: "",
                        transcriptStatus: decision.status.rawValue,
                        detectedLanguage: transcription.language,
                        audioVariant: decision.audioVariant.rawValue,
                        qualityFlags: Self.qualityFlags(decision)
                    )
                }
                return
            }

            // Step 2: Merge overlapping words from consecutive batches.
            // The overlap zone (first 5s of this batch = last 5s of previous batch) may
            // contain words that were cut by the previous batch. We deduplicate by checking
            // if a word in the overlap zone already appeared in the previous batch's trailing words.
            let overlapSeconds = 5.0
            var mergedWords = Self.wordsOrTextFallback(
                words: transcription.words,
                text: transcription.text,
                duration: batch.duration
            )

            let consecutiveWindow = previousBatchSource == batch.source && previousBatchStart.map {
                abs(batch.startTimestamp.timeIntervalSince($0) - (previousBatchDuration - overlapSeconds)) < 0.1
            } == true
            if consecutiveWindow && !previousBatchTrailingWords.isEmpty && !mergedWords.isEmpty {
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

            let mergedText = Self.text(from: mergedWords, fallback: transcription.text)
            guard !mergedText.trimmingCharacters(in: .whitespaces).isEmpty else {
                if persistedBatch.pendingRecord != nil {
                    try await updatePendingOutcome(persistedBatch,
                        text: transcription.text,
                        transcriptStatus: decision.status.rawValue,
                        detectedLanguage: transcription.language,
                        audioVariant: decision.audioVariant.rawValue,
                        qualityFlags: Self.qualityFlags(decision, appending: ["empty_merged_words"])
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
                if persistedBatch.pendingRecord != nil {
                    try await updatePendingOutcome(persistedBatch,
                        text: mergedText,
                        transcriptStatus: decision.status.rawValue,
                        detectedLanguage: transcription.language,
                        audioVariant: decision.audioVariant.rawValue,
                        qualityFlags: Self.qualityFlags(decision, appending: ["empty_sentences"])
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
                if persistedBatch.pendingRecord != nil {
                    try await updatePendingOutcome(persistedBatch,
                        text: mergedText,
                        transcriptStatus: decision.status.rawValue,
                        detectedLanguage: transcription.language,
                        audioVariant: decision.audioVariant.rawValue,
                        qualityFlags: Self.qualityFlags(decision, appending: ["empty_transcription_batch"])
                    )
                }
                return
            }

            try BackgroundProcessingContext.checkCancellation()
            if let pending = persistedBatch.pendingRecord {
                guard try await queries.completePendingRawBatch(pending, with: transcriptionsBatch,
                    cancellation: BackgroundProcessingContext.permit?.cancellation) else {
                    throw PendingAudioCompletionError.staleRow
                }
            } else {
                _ = try await queries.insertTranscriptionsBatch(transcriptionsBatch)
            }

            await publishCommittedBatch(persistedBatch)

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
            previousBatchDuration = batch.duration
            previousBatchStart = batch.startTimestamp
            previousBatchSource = batch.source
            // Keep words from the last 10 seconds for overlap deduplication
            previousBatchTrailingWords = transcription.words.filter {
                $0.start >= (batch.duration - 10.0)
            }

            Log.info("[AudioProcessingManager] Batch transcribed: \(sentences.count) sentences, \(transcription.words.count) words from \(batch.source.rawValue) status=\(decision.status.rawValue) variant=\(decision.audioVariant.rawValue) language=\(transcription.language ?? "unknown") attempts=\(decision.attempts) (\(String(format: "%.1f", batch.duration))s)", category: .processing)

        } catch {
            throw error
        }
    }

    private func updatePendingOutcome(_ persisted: PersistedAudioBatch, text: String,
        transcriptStatus: String, detectedLanguage: String?, audioVariant: String, qualityFlags: String?) async throws {
        try BackgroundProcessingContext.checkCancellation()
        guard let pending = persisted.pendingRecord, let queries = transcriptionQueries else { return }
        guard try await queries.updatePendingRawBatchOutcome(pending, text: text,
            transcriptStatus: transcriptStatus, detectedLanguage: detectedLanguage,
            audioVariant: audioVariant, qualityFlags: qualityFlags,
            cancellation: BackgroundProcessingContext.permit?.cancellation) else {
            throw PendingAudioCompletionError.staleRow
        }
        // An uncertain but retained first pass is still evidence. Later repair may improve it.
        if !text.isEmpty { await publishCommittedBatch(persisted) }
    }

    private func publishCommittedBatch(_ persisted: PersistedAudioBatch) async {
        guard let callback = onCommittedBatch, let path = persisted.savedBatchPath,
              let queries = transcriptionQueries else { return }
        do {
            let rows = try await queries.getContextBatchEntries(batchAudioPath: path)
            guard !rows.isEmpty else { return }
            try await callback(.init(relativePath: path, source: persisted.batch.source, records: rows))
        } catch {
            hasCommittedBatchCallbackFailure = true
            Log.warning("Optional companion publication failed; committed audio and text are retained", category: .processing)
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

    private func loadBatchForTranscription(_ persistedBatch: PersistedAudioBatch) throws -> AudioBatch {
        guard persistedBatch.isSpooledToDisk else {
            return persistedBatch.batch
        }
        guard let savedBatchURL = persistedBatch.savedBatchURL else {
            return persistedBatch.batch
        }

        let decoded = try AudioFileDecoder.decodeToPCM(
            fileURL: savedBatchURL
        )
        return AudioBatch(
            audioData: decoded.data,
            source: persistedBatch.batch.source,
            startTimestamp: persistedBatch.batch.startTimestamp,
            endTimestamp: persistedBatch.batch.endTimestamp,
            duration: decoded.duration,
            sampleRate: decoded.sampleRate,
            channels: 1
        )
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
        return isProcessing
    }
}

// MARK: - Configuration

public struct AudioProcessingConfig: Sendable {
    /// Enable word-level timestamps (more expensive but more accurate)
    public let enableWordLevelTimestamps: Bool

    /// Minimum confidence threshold (0-1) to store transcription
    public let minimumConfidence: Double

    /// Maximum audio buffer size before forcing transcription (seconds).
    /// Shorter live batches reduce silence dilution and dashboard latency.
    public let maxBufferDuration: Double

    /// Maximum number of persisted batches to hold in memory for immediate live transcription.
    /// When this saturates, the raw batch remains pending on disk/DB for backfill.
    public let maxQueuedLiveTranscriptionBatches: Int

    /// Callback invoked after each transcription
    public let transcriptionCallback: (@Sendable (CapturedAudio, DetailedTranscriptionResult) async -> Void)?

    public init(
        enableWordLevelTimestamps: Bool = true,
        minimumConfidence: Double = 0.5,
        maxBufferDuration: Double = 15.0,
        maxQueuedLiveTranscriptionBatches: Int = 12,
        transcriptionCallback: (@Sendable (CapturedAudio, DetailedTranscriptionResult) async -> Void)? = nil
    ) {
        self.enableWordLevelTimestamps = enableWordLevelTimestamps
        self.minimumConfidence = minimumConfidence
        self.maxBufferDuration = maxBufferDuration
        self.maxQueuedLiveTranscriptionBatches = max(0, maxQueuedLiveTranscriptionBatches)
        self.transcriptionCallback = transcriptionCallback
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
