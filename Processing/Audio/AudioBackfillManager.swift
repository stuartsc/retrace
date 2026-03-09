import Foundation
import Shared
import Database
import Storage

/// Retroactively transcribes saved batch audio files using whisper.cpp
/// Processes batch_*.m4a files that were saved before the whisper model was available
/// Owner: PROCESSING agent
public actor AudioBackfillManager {

    private let transcriptionService: any TranscriptionProtocol
    private let transcriptionQueries: AudioTranscriptionQueries
    private let audioWriter: AudioSegmentWriter
    private let storageRoot: URL
    private var isRunning = false

    public struct BackfillResult: Sendable {
        public let processedCount: Int
        public let silenceCount: Int
        public let failedCount: Int
        public let totalSentences: Int
    }

    public init(
        transcriptionService: any TranscriptionProtocol,
        transcriptionQueries: AudioTranscriptionQueries,
        audioWriter: AudioSegmentWriter,
        storageRoot: URL
    ) {
        self.transcriptionService = transcriptionService
        self.transcriptionQueries = transcriptionQueries
        self.audioWriter = audioWriter
        self.storageRoot = storageRoot
    }

    /// Process all saved batch audio files that haven't been transcribed
    /// Returns a summary of what was processed
    public func processAllPendingBatches() async -> BackfillResult {
        guard !isRunning else {
            Log.warning("[AudioBackfill] Already running, skipping", category: .processing)
            return BackfillResult(processedCount: 0, silenceCount: 0, failedCount: 0, totalSentences: 0)
        }

        isRunning = true
        defer { isRunning = false }

        var totalProcessed = 0
        var totalSilence = 0
        var totalFailed = 0
        var totalSentences = 0

        // Process in pages of 10 to avoid loading too many at once
        let pageSize = 10

        while true {
            let batches: [UntranscribedBatch]
            do {
                batches = try await transcriptionQueries.getUntranscribedBatches(limit: pageSize)
            } catch {
                Log.error("[AudioBackfill] Failed to query untranscribed batches: \(error)", category: .processing)
                break
            }

            guard !batches.isEmpty else { break }

            Log.info("[AudioBackfill] Processing \(batches.count) batch(es)...", category: .processing)

            for batch in batches {
                let result = await processSingleBatch(batch)
                switch result {
                case .transcribed(let sentenceCount):
                    totalProcessed += 1
                    totalSentences += sentenceCount
                case .silence:
                    totalSilence += 1
                case .failed:
                    totalFailed += 1
                }
            }

            Log.info("[AudioBackfill] Progress: \(totalProcessed) transcribed, \(totalSilence) silence, \(totalFailed) failed, \(totalSentences) sentences", category: .processing)
        }

        Log.info("[AudioBackfill] Complete: \(totalProcessed) transcribed, \(totalSilence) silence, \(totalFailed) failed, \(totalSentences) total sentences", category: .processing)

        return BackfillResult(
            processedCount: totalProcessed,
            silenceCount: totalSilence,
            failedCount: totalFailed,
            totalSentences: totalSentences
        )
    }

    public var isCurrentlyRunning: Bool {
        return isRunning
    }

    // MARK: - Private

    private enum BatchResult {
        case transcribed(sentenceCount: Int)
        case silence
        case failed
    }

    private func processSingleBatch(_ batch: UntranscribedBatch) async -> BatchResult {
        // 1. Resolve audio path to full URL
        let fileURL = storageRoot.appendingPathComponent(batch.audioPath)

        // 2. Decode M4A → PCM
        let decoded: AudioFileDecoder.DecodedAudio
        do {
            decoded = try AudioFileDecoder.decodeToPCM(fileURL: fileURL)
        } catch {
            Log.error("[AudioBackfill] Failed to decode \(batch.audioPath): \(error)", category: .processing)
            // Mark as silence to avoid retrying a bad file
            try? await transcriptionQueries.updateTranscriptionText(id: batch.id, text: "[decode_error]")
            return .failed
        }

        // 3. Transcribe
        let transcription: DetailedTranscriptionResult
        do {
            transcription = try await transcriptionService.transcribeWithTimestamps(decoded.data, wordLevel: true)
        } catch {
            Log.error("[AudioBackfill] Transcription failed for \(batch.audioPath): \(error)", category: .processing)
            return .failed
        }

        // 4. Check for silence/empty
        guard !transcription.text.isEmpty else {
            try? await transcriptionQueries.updateTranscriptionText(id: batch.id, text: "[silence]")
            Log.debug("[AudioBackfill] Silence detected: \(batch.audioPath)", category: .processing)
            return .silence
        }

        // 5. Segment into sentences
        let sentences = SentenceSegmenter.segment(
            words: transcription.words,
            fullText: transcription.text
        )

        guard !sentences.isEmpty else {
            try? await transcriptionQueries.updateTranscriptionText(id: batch.id, text: "[silence]")
            return .silence
        }

        // 6. Insert sentence records
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
                startTime: batch.startTime.addingTimeInterval(sentence.startTime),
                endTime: batch.startTime.addingTimeInterval(sentence.endTime),
                source: batch.source,
                confidence: sentence.confidence,
                words: sentence.words
            ))
        }

        do {
            try await transcriptionQueries.insertTranscriptionsBatch(transcriptionsBatch)
        } catch {
            Log.error("[AudioBackfill] Failed to insert sentences for \(batch.audioPath): \(error)", category: .processing)
            return .failed
        }

        // 7. Write sentence-level M4A files
        for sentence in sentences {
            do {
                let (filePath, _) = try await audioWriter.writeAudioSegment(
                    audioData: decoded.data,
                    startTime: sentence.startTime,
                    endTime: sentence.endTime,
                    sampleRate: decoded.sampleRate,
                    channels: 1,
                    timestamp: batch.startTime.addingTimeInterval(sentence.startTime),
                    source: batch.source
                )
                Log.debug("[AudioBackfill] Wrote sentence segment: \(filePath)", category: .processing)
            } catch {
                Log.error("[AudioBackfill] Failed to write sentence audio: \(error)", category: .processing)
            }
        }

        // 8. Delete the raw batch DB record (M4A file stays on disk)
        do {
            try await transcriptionQueries.deleteTranscription(id: batch.id)
        } catch {
            Log.error("[AudioBackfill] Failed to delete batch record \(batch.id): \(error)", category: .processing)
        }

        Log.debug("[AudioBackfill] Transcribed batch \(batch.id): \(sentences.count) sentences", category: .processing)
        return .transcribed(sentenceCount: sentences.count)
    }
}
