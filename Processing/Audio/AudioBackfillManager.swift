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
    private var mediaStore: (any AudioChunkMediaStoreProtocol)?
    private let governor: (any BackgroundProcessingProtocol)?
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
        storageRoot: URL,
        governor: (any BackgroundProcessingProtocol)? = nil,
        mediaStore: (any AudioChunkMediaStoreProtocol)? = nil
    ) {
        self.transcriptionService = transcriptionService
        self.transcriptionQueries = transcriptionQueries
        self.audioWriter = audioWriter
        self.storageRoot = storageRoot
        self.governor = governor
        self.mediaStore = mediaStore
    }

    public func setChunkMediaStore(_ store: (any AudioChunkMediaStoreProtocol)?) { mediaStore = store }

    /// Process all saved batch audio files that haven't been transcribed
    /// Returns a summary of what was processed
    public func processAllPendingBatches(maxBatches: Int? = nil) async -> BackfillResult {
        guard !isRunning else {
            Log.warning("[AudioBackfill] Already running, skipping", category: .processing)
            return BackfillResult(processedCount: 0, silenceCount: 0, failedCount: 0, totalSentences: 0)
        }

        let batchLimit = maxBatches.map { max($0, 0) }
        if batchLimit == 0 {
            return BackfillResult(processedCount: 0, silenceCount: 0, failedCount: 0, totalSentences: 0)
        }

        isRunning = true
        defer { isRunning = false }

        var totalProcessed = 0
        var totalSilence = 0
        var totalFailed = 0
        var totalSentences = 0
        var attemptedBatches = 0
        var cursor: Int64 = 0

        // Process in pages of 10 to avoid loading too many at once
        let pageSize = 10

        while !Task.isCancelled {
            if let batchLimit, attemptedBatches >= batchLimit { break }
            let fetchLimit = batchLimit.map { min(pageSize, max($0 - attemptedBatches, 0)) } ?? pageSize
            guard fetchLimit > 0 else { break }

            let batches: [UntranscribedBatch]
            do {
                batches = try await transcriptionQueries.getUntranscribedBatches(limit: fetchLimit, afterID: cursor)
            } catch {
                Log.error("[AudioBackfill] Failed to query untranscribed batches: \(error)", category: .processing)
                break
            }

            guard !batches.isEmpty else { break }

            Log.info("[AudioBackfill] Processing \(batches.count) batch(es)...", category: .processing)

            for batch in batches {
                if let batchLimit, attemptedBatches >= batchLimit { break }
                guard !Task.isCancelled else { break }
                attemptedBatches += 1
                cursor = batch.id
                let result = await processGovernedBatch(batch)
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

    private enum BatchResult: Sendable {
        case transcribed(sentenceCount: Int)
        case silence
        case failed
    }

    private func processGovernedBatch(_ batch: UntranscribedBatch) async -> BatchResult {
        guard let governor else { return await processSingleBatch(batch) }
        do {
            let permit = try await governor.acquire(batch.probableSilenceHint ? .ambientSilence : .ambientSpeech)
            let result = await withTaskCancellationHandler {
                await BackgroundProcessingContext.$permit.withValue(permit) {
                    await self.processSingleBatch(batch)
                }
            } onCancel: { permit.cancellation.cancel() }
            await governor.release(permit)
            return result
        } catch { return .failed }
    }

    private func processSingleBatch(_ batch: UntranscribedBatch) async -> BatchResult {
        let originalSource: AudioOriginalSourceReceipt
        do {
            try BackgroundProcessingContext.checkCancellation()
            originalSource = try await transcriptionQueries.pendingFirstPassSource(rawBatchID: batch.id, path: batch.audioPath)
        } catch { return .failed }
        do {
            return try await AudioTranscriptionMedia.withInput(path: batch.audioPath,
                legacyStartTime: batch.startTime, storageRoot: storageRoot,
                queries: transcriptionQueries, mediaStore: mediaStore) { [self] input in
                    await processLoadedBatch(batch, originalSource: originalSource, input: input)
                }
        } catch is CancellationError {
            return .failed
        } catch {
            try? await transcriptionQueries.updateBatchOutcome(id: batch.id, text: "", transcriptStatus: "needs_repair",
                detectedLanguage: nil, audioVariant: "raw", qualityFlags: "media_input_unavailable", originalSource: originalSource)
            return .failed
        }
    }

    private func processLoadedBatch(_ batch: UntranscribedBatch, originalSource: AudioOriginalSourceReceipt,
        input: AudioTranscriptionInput) async -> BatchResult {
        // 3. Always transcribe; silence/junk is classified after the attempt.
        let decision: AudioTranscriptionDecision
        do {
            decision = try await AudioTranscriptionRetryPipeline.transcribeBest(
                audioData: input.data,
                sampleRate: input.sampleRate,
                channels: 1,
                transcriptionService: transcriptionService,
                wordLevel: true,
                initialPrompt: nil,
                profile: .liveFirstPass,
                requireWordTimings: input.window != nil
            )
        } catch {
            Log.error("[AudioBackfill] Transcription failed for \(batch.audioPath): \(error)", category: .processing)
            return .failed
        }
        do { try input.checkValidity() } catch { return .failed }
        let transcription = decision.transcription

        guard decision.shouldStoreText else {
            try? await transcriptionQueries.updateBatchOutcome(
                id: batch.id,
                text: "",
                transcriptStatus: decision.status.rawValue,
                detectedLanguage: transcription.language,
                audioVariant: decision.audioVariant.rawValue,
                qualityFlags: Self.qualityFlags(decision),
                originalSource: originalSource
            )
            return .silence
        }

        let owned: (words: [TranscriptionWord], text: String)
        do { owned = try input.ownedTranscript(transcription) }
        catch {
            try? await transcriptionQueries.updateBatchOutcome(id: batch.id, text: "", transcriptStatus: "needs_repair",
                detectedLanguage: transcription.language, audioVariant: "raw", qualityFlags: "exact_window_ownership_unavailable",
                originalSource: originalSource)
            return .failed
        }
        // 5. Segment only the current chunk's owned words.
        let sentences = SentenceSegmenter.segment(
            words: owned.words,
            fullText: owned.text,
            fallbackDuration: input.duration
        )

        guard !sentences.isEmpty else {
            try? await transcriptionQueries.updateBatchOutcome(
                id: batch.id,
                text: transcription.text,
                transcriptStatus: decision.status.rawValue,
                detectedLanguage: transcription.language,
                audioVariant: decision.audioVariant.rawValue,
                qualityFlags: Self.qualityFlags(decision, appending: ["empty_sentences"]),
                originalSource: originalSource
            )
            return .silence
        }

        // Keep sentence timing in SQLite while retaining one canonical batch file.
        let transcriptAudioPath = AudioStoragePolicy.canonicalTranscriptPath(
            batchAudioPath: batch.audioPath
        )

        // 7. Insert sentence records with audio paths
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
                startTime: input.startTime.addingTimeInterval(sentence.startTime),
                endTime: input.startTime.addingTimeInterval(sentence.endTime),
                source: batch.source,
                confidence: sentence.confidence,
                words: sentence.words,
                audioPath: transcriptAudioPath,
                transcriptionPass: 1,
                batchAudioPath: batch.audioPath,
                transcriptStatus: decision.status.rawValue,
                detectedLanguage: transcription.language,
                audioVariant: decision.audioVariant.rawValue,
                qualityFlags: Self.qualityFlags(decision)
            ))
        }

        guard !transcriptionsBatch.isEmpty else {
            try? await transcriptionQueries.updateBatchOutcome(
                id: batch.id,
                text: transcription.text,
                transcriptStatus: decision.status.rawValue,
                detectedLanguage: transcription.language,
                audioVariant: decision.audioVariant.rawValue,
                qualityFlags: Self.qualityFlags(decision, appending: ["empty_transcription_batch"]),
                originalSource: originalSource
            )
            return .silence
        }

        do {
            try await input.validateForPublication(queries: transcriptionQueries, path: batch.audioPath)
            try await transcriptionQueries.commitFirstPass(rawBatchID: batch.id, records: transcriptionsBatch, originalSource: originalSource)
        } catch {
            Log.error("[AudioBackfill] Failed to insert sentences for \(batch.audioPath): \(error)", category: .processing)
            return .failed
        }

        Log.debug("[AudioBackfill] Transcribed batch \(batch.id): \(sentences.count) sentences status=\(decision.status.rawValue) variant=\(decision.audioVariant.rawValue) language=\(transcription.language ?? "unknown") attempts=\(decision.attempts)", category: .processing)
        return .transcribed(sentenceCount: sentences.count)
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

        let knownExact: Set<String> = [
            "thank you", "thanks", "thank", "you", "bye",
            "uh", "um", "oh", "i'm", "so", "okay", "ok"
        ]
        if knownExact.contains(lower) { return true }

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
            if lower.contains(phrase) { return true }
        }

        let words = trimmed.split(separator: " ").map(String.init)
        if words.count <= 2 {
            return true
        }

        guard words.count >= 4 else { return false }

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
}
