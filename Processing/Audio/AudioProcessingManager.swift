import Foundation
import Shared
import Database
import Storage

private struct PersistedAudioBatch: Sendable {
    let batch: AudioBatch
    let rawBatchID: Int64?
    let savedBatchPath: String?
    let savedBatchURL: URL?

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

/// Coordinates audio capture → batch buffering → transcription → database storage pipeline
/// Accumulates PCM into 30-second batches per source before calling whisper.cpp
public actor AudioProcessingManager {

    private var transcriptionService: any TranscriptionProtocol
    private var transcriptionQueries: AudioTranscriptionQueries?
    private var audioWriter: AudioSegmentWriter?
    private var isProcessing = false

    /// Trailing words from the last batch (in the overlap zone) — used to deduplicate
    private var previousBatchTrailingWords: [TranscriptionWord] = []

    /// Duration of the last batch — needed to compute absolute timestamps for trailing words
    private var previousBatchDuration: TimeInterval = 0

    // Batch buffering
    private let bufferManager: AudioBufferManager

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
        config: AudioProcessingConfig = .default
    ) {
        self.transcriptionService = transcriptionService
        self.transcriptionQueries = transcriptionQueries
        self.audioWriter = audioWriter
        self.config = config
        self.bufferManager = AudioBufferManager(maxBufferDuration: config.maxBufferDuration)
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

    /// Start processing audio stream with batch accumulation
    public func startProcessing(audioStream: AsyncStream<CapturedAudio>) async {
        guard !isProcessing else { return }
        isProcessing = true
        var wasCancelled = false
        defer {
            isProcessing = false
        }

        for await audio in audioStream {
            if Task.isCancelled {
                wasCancelled = true
                break
            }

            // Accumulate samples into batches
            if let batch = await bufferManager.addSample(audio) {
                await acceptBatch(batch)
            }
        }

        if wasCancelled || Task.isCancelled {
            cancelLiveTranscriptionQueue()
            return
        }

        // Stream ended — flush remaining buffers
        let remainingBatches = await bufferManager.flush()
        for batch in remainingBatches {
            await acceptBatch(batch)
        }

        await waitForLiveTranscriptionQueueToDrain()
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
                Log.debug("[AudioProcessingManager] Saved raw batch: \(batchPath) (\(batchSize) bytes)", category: .processing)

                // Insert DB record for the raw batch
                if let queries = transcriptionQueries {
                    do {
                        rawBatchID = try await queries.insertRawBatch(
                            startTime: batch.startTimestamp,
                            endTime: batch.endTimestamp,
                            source: batch.source,
                            audioPath: batchPath,
                            audioSize: batchSize
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

    private func enqueueLiveTranscription(_ persistedBatch: PersistedAudioBatch) {
        let canRecoverFromRawBatch = persistedBatch.rawBatchID != nil
        let shouldSpool = canRecoverFromRawBatch &&
            config.maxQueuedLiveTranscriptionBatches > 0 &&
            liveTranscriptionQueue.count >= config.maxQueuedLiveTranscriptionBatches
        let queuedBatch = shouldSpool ? persistedBatch.spooledToDisk() : persistedBatch
        if shouldSpool {
            Log.warning("[AudioProcessingManager] Live transcription queue saturated; queued disk-backed batch path=\(persistedBatch.savedBatchPath ?? "unknown")", category: .processing)
        }

        liveTranscriptionQueue.append(queuedBatch)
        startLiveTranscriptionWorkerIfNeeded()
    }

    private func startLiveTranscriptionWorkerIfNeeded() {
        guard liveTranscriptionWorker == nil else { return }

        liveTranscriptionWorker = Task {
            await self.processLiveTranscriptionQueue()
        }
    }

    private func processLiveTranscriptionQueue() async {
        while !Task.isCancelled {
            guard !liveTranscriptionQueue.isEmpty else {
                liveTranscriptionWorker = nil
                return
            }

            let persistedBatch = liveTranscriptionQueue.removeFirst()
            await processPersistedBatch(persistedBatch)
        }

        liveTranscriptionWorker = nil
    }

    private func waitForLiveTranscriptionQueueToDrain() async {
        while let worker = liveTranscriptionWorker {
            await worker.value
        }
    }

    private func cancelLiveTranscriptionQueue() {
        liveTranscriptionWorker?.cancel()
        liveTranscriptionWorker = nil
        liveTranscriptionQueue.removeAll()
    }

    /// Process a single persisted batch of accumulated audio (~30s)
    private func processPersistedBatch(_ persistedBatch: PersistedAudioBatch) async {
        let startTime = Date()
        let batch: AudioBatch
        do {
            batch = try loadBatchForTranscription(persistedBatch)
        } catch {
            Log.error("[AudioProcessingManager] Failed to load queued batch audio: \(error)", category: .processing)
            if let batchID = persistedBatch.rawBatchID, let queries = transcriptionQueries {
                try? await queries.updateBatchOutcome(
                    id: batchID,
                    text: "",
                    transcriptStatus: AudioTranscriptStatus.decodeFailed.rawValue,
                    detectedLanguage: nil,
                    audioVariant: AudioEnhancementVariant.raw.rawValue,
                    qualityFlags: "decode_error"
                )
            }
            return
        }
        let rawBatchID = persistedBatch.rawBatchID
        let savedBatchPath = persistedBatch.savedBatchPath

        do {
            // Step 1: Always attempt transcription. Silence/junk detection is metadata,
            // never a pre-transcription gate, because missed speech is worse than junk.
            let decision = try await AudioTranscriptionRetryPipeline.transcribeBest(
                audioData: batch.audioData,
                sampleRate: batch.sampleRate,
                channels: batch.channels,
                transcriptionService: transcriptionService,
                wordLevel: config.enableWordLevelTimestamps,
                initialPrompt: nil,
                profile: .liveFirstPass
            )
            let transcription = decision.transcription

            guard decision.shouldStoreText else {
                if let batchID = rawBatchID, let queries = transcriptionQueries {
                    try? await queries.updateBatchOutcome(
                        id: batchID,
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

            if !previousBatchTrailingWords.isEmpty && !mergedWords.isEmpty {
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
                if let batchID = rawBatchID, let queries = transcriptionQueries {
                    try? await queries.updateBatchOutcome(
                        id: batchID,
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
                if let batchID = rawBatchID, let queries = transcriptionQueries {
                    try? await queries.updateBatchOutcome(
                        id: batchID,
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
                if let batchID = rawBatchID {
                    try? await queries.updateBatchOutcome(
                        id: batchID,
                        text: mergedText,
                        transcriptStatus: decision.status.rawValue,
                        detectedLanguage: transcription.language,
                        audioVariant: decision.audioVariant.rawValue,
                        qualityFlags: Self.qualityFlags(decision, appending: ["empty_transcription_batch"])
                    )
                }
                return
            }

            _ = try await queries.insertTranscriptionsBatch(transcriptionsBatch)

            // Step 5b: Delete the raw batch record now that sentences are inserted
            // This prevents the backfill manager from re-transcribing the same batch
            if let batchID = rawBatchID {
                do {
                    try await queries.deleteTranscription(id: batchID)
                } catch {
                    Log.error("[AudioProcessingManager] Failed to delete raw batch record \(batchID): \(error)", category: .processing)
                }
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
            previousBatchDuration = batch.duration
            // Keep words from the last 10 seconds for overlap deduplication
            previousBatchTrailingWords = transcription.words.filter {
                $0.start >= (batch.duration - 10.0)
            }

            Log.info("[AudioProcessingManager] Batch transcribed: \(sentences.count) sentences, \(transcription.words.count) words from \(batch.source.rawValue) status=\(decision.status.rawValue) variant=\(decision.audioVariant.rawValue) language=\(transcription.language ?? "unknown") attempts=\(decision.attempts) (\(String(format: "%.1f", batch.duration))s)", category: .processing)

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
