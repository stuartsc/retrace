import Foundation
import Shared
import Database
import Storage

/// Coordinates audio capture → batch buffering → transcription → database storage pipeline
/// Accumulates PCM into 30-second batches per source before calling whisper.cpp
public actor AudioProcessingManager {

    private let transcriptionService: any TranscriptionProtocol
    private var transcriptionQueries: AudioTranscriptionQueries?
    private var audioWriter: AudioSegmentWriter?
    private var isProcessing = false

    // Batch buffering
    private let bufferManager: AudioBufferManager

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

    // MARK: - Processing Pipeline

    /// Start processing audio stream with batch accumulation
    public func startProcessing(audioStream: AsyncStream<CapturedAudio>) async {
        guard !isProcessing else { return }
        isProcessing = true

        for await audio in audioStream {
            // Accumulate samples into batches
            if let batch = await bufferManager.addSample(audio) {
                await processBatch(batch)
            }
        }

        // Stream ended — flush remaining buffers
        let remainingBatches = await bufferManager.flush()
        for batch in remainingBatches {
            await processBatch(batch)
        }

        isProcessing = false
    }

    /// Process a single batch of accumulated audio (~30s)
    private func processBatch(_ batch: AudioBatch) async {
        let startTime = Date()

        // Step 0: Save raw batch audio to disk immediately (never lose audio)
        if let writer = audioWriter {
            do {
                let (batchPath, batchSize) = try await writer.writeFullBatch(
                    audioData: batch.audioData,
                    sampleRate: batch.sampleRate,
                    channels: batch.channels,
                    timestamp: batch.startTimestamp,
                    source: batch.source
                )
                Log.debug("[AudioProcessingManager] Saved raw batch: \(batchPath) (\(batchSize) bytes)", category: .processing)

                // Insert DB record for the raw batch
                if let queries = transcriptionQueries {
                    do {
                        try await queries.insertRawBatch(
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

        do {
            // Step 1: Transcribe the full batch with word-level timestamps
            let transcription = try await transcriptionService.transcribeWithTimestamps(
                batch.audioData,
                wordLevel: config.enableWordLevelTimestamps
            )

            guard !transcription.text.isEmpty else { return }

            // Step 2: Segment transcription into sentences
            let sentences = SentenceSegmenter.segment(
                words: transcription.words,
                fullText: transcription.text
            )

            guard !sentences.isEmpty else { return }

            // Step 3: Save to database
            guard let queries = transcriptionQueries else {
                Log.warning("[AudioProcessingManager] Audio storage not configured, skipping save", category: .processing)
                return
            }

            // Build transcription batch data
            var transcriptionsBatch: [(
                sessionID: String?,
                text: String,
                startTime: Date,
                endTime: Date,
                source: AudioSource,
                confidence: Double?,
                words: [TranscriptionWord]
            )] = []

            for sentence in sentences {
                transcriptionsBatch.append((
                    sessionID: nil,
                    text: sentence.text,
                    startTime: batch.startTimestamp.addingTimeInterval(sentence.startTime),
                    endTime: batch.startTimestamp.addingTimeInterval(sentence.endTime),
                    source: batch.source,
                    confidence: sentence.confidence,
                    words: sentence.words
                ))
            }

            // Step 4: Batch insert all sentences in single transaction
            try await queries.insertTranscriptionsBatch(transcriptionsBatch)

            // Step 5: Write audio segments to disk if writer is available
            if let writer = audioWriter {
                for sentence in sentences {
                    do {
                        let (filePath, _) = try await writer.writeAudioSegment(
                            audioData: batch.audioData,
                            startTime: sentence.startTime,
                            endTime: sentence.endTime,
                            sampleRate: batch.sampleRate,
                            channels: batch.channels,
                            timestamp: batch.startTimestamp.addingTimeInterval(sentence.startTime),
                            source: batch.source
                        )
                        Log.debug("[AudioProcessingManager] Wrote audio segment: \(filePath)", category: .processing)
                    } catch {
                        Log.error("[AudioProcessingManager] Failed to write audio segment: \(error)", category: .processing)
                    }
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

            Log.info("[AudioProcessingManager] Batch transcribed: \(sentences.count) sentences, \(transcription.words.count) words from \(batch.source.rawValue) (\(String(format: "%.1f", batch.duration))s)", category: .processing)

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

    /// Maximum audio buffer size before forcing transcription (seconds)
    public let maxBufferDuration: Double

    /// Callback invoked after each transcription
    public let transcriptionCallback: (@Sendable (CapturedAudio, DetailedTranscriptionResult) async -> Void)?

    public init(
        enableWordLevelTimestamps: Bool = true,
        minimumConfidence: Double = 0.5,
        maxBufferDuration: Double = 30.0,
        transcriptionCallback: (@Sendable (CapturedAudio, DetailedTranscriptionResult) async -> Void)? = nil
    ) {
        self.enableWordLevelTimestamps = enableWordLevelTimestamps
        self.minimumConfidence = minimumConfidence
        self.maxBufferDuration = maxBufferDuration
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
