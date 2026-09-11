import Foundation
import Shared
import Database
import Storage

/// Refines pass-1 transcriptions using a larger whisper model with beam search
/// Processes batch audio files that already have pass-1 sentence records,
/// replacing them with higher-quality pass-2 transcriptions
/// Owner: PROCESSING agent

struct AudioRefinementSchedulingDecision: Equatable, Sendable {
    let shouldYield: Bool
    let shouldExit: Bool
    let delaySeconds: TimeInterval
}

enum AudioRefinementSchedulingPolicy {
    static func decision(
        isPass1Active: Bool,
        busyWaitDuration: TimeInterval,
        isCancelled: Bool = false
    ) -> AudioRefinementSchedulingDecision {
        if isCancelled {
            return AudioRefinementSchedulingDecision(
                shouldYield: false,
                shouldExit: true,
                delaySeconds: 0
            )
        }

        return AudioRefinementSchedulingDecision(
            shouldYield: isPass1Active,
            shouldExit: false,
            delaySeconds: isPass1Active ? busyWaitDuration : 0
        )
    }
}

public actor AudioRefinementManager {

    private let transcriptionService: any TranscriptionProtocol
    private let transcriptionQueries: AudioTranscriptionQueries
    private let audioWriter: AudioSegmentWriter
    private let storageRoot: URL
    private var isRunning = false

    /// Check if pass-1 pipeline is active (set externally to yield GPU)
    private var isPass1Active: (@Sendable () async -> Bool)?

    /// Configure the pass-1 activity check callback
    public func setPass1ActiveCheck(_ check: @escaping @Sendable () async -> Bool) {
        self.isPass1Active = check
    }

    // Throttling
    private let batchesPerCycle = 5
    private let yieldDuration: TimeInterval = 10
    private let busyWaitDuration: TimeInterval = 30

    public struct RefinementResult: Sendable {
        public let refinedCount: Int
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

    /// Process all pass-1 transcriptions that can be refined
    public func processAllPendingRefinements(maxBatches: Int? = nil) async -> RefinementResult {
        guard !isRunning else {
            Log.warning("[AudioRefinement] Already running, skipping", category: .processing)
            return RefinementResult(refinedCount: 0, silenceCount: 0, failedCount: 0, totalSentences: 0)
        }

        let batchLimit = maxBatches.map { max($0, 0) }
        if batchLimit == 0 {
            return RefinementResult(refinedCount: 0, silenceCount: 0, failedCount: 0, totalSentences: 0)
        }

        isRunning = true
        defer { isRunning = false }

        var totalRefined = 0
        var totalSilence = 0
        var totalFailed = 0
        var totalSentences = 0
        var batchesInCycle = 0
        var attemptedBatchPaths = Set<String>()
        var attemptedBatches = 0

        while !Task.isCancelled {
            if let batchLimit, attemptedBatches >= batchLimit { break }
            if await yieldToPass1IfNeeded() {
                continue
            }
            if Task.isCancelled { break }

            let batchPaths: [String]
            do {
                let fetchLimit = batchLimit.map { min(10, max($0 - attemptedBatches, 0)) } ?? 10
                guard fetchLimit > 0 else { break }
                let candidates = try await transcriptionQueries.getDistinctBatchPathsForRefinement(limit: fetchLimit)
                batchPaths = candidates.filter { !attemptedBatchPaths.contains($0) }
            } catch {
                Log.error("[AudioRefinement] Failed to query refinement candidates: \(error)", category: .processing)
                break
            }

            guard !batchPaths.isEmpty else { break }

            for batchPath in batchPaths {
                if Task.isCancelled { break }
                if let batchLimit, attemptedBatches >= batchLimit { break }
                if await yieldToPass1IfNeeded() { break }
                if Task.isCancelled { break }
                attemptedBatchPaths.insert(batchPath)
                attemptedBatches += 1

                let result = await processSingleBatch(batchPath)
                switch result {
                case .refined(let sentenceCount):
                    totalRefined += 1
                    totalSentences += sentenceCount
                case .silence(let reason):
                    totalSilence += 1
                    await retireBatchCandidate(batchPath, status: .refinementSkipped, reason: reason)
                case .failed(let reason):
                    totalFailed += 1
                    await retireBatchCandidate(batchPath, status: .refinementFailed, reason: reason)
                }

                batchesInCycle += 1
                if batchesInCycle >= batchesPerCycle {
                    batchesInCycle = 0
                    Log.debug("[AudioRefinement] Yielding after \(batchesPerCycle) batches (\(totalRefined) refined so far)", category: .processing)
                    try? await Task.sleep(for: .milliseconds(Int64(yieldDuration * 1_000)), clock: .continuous)
                }
            }
        }

        Log.info("[AudioRefinement] Complete: \(totalRefined) refined, \(totalSilence) silence, \(totalFailed) failed, \(totalSentences) sentences", category: .processing)
        return RefinementResult(
            refinedCount: totalRefined,
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
        case refined(sentenceCount: Int)
        case silence(reason: String)
        case failed(reason: String)
    }

    private func processSingleBatch(_ batchPath: String) async -> BatchResult {
        // 1. Resolve batch audio path
        let fileURL = storageRoot.appendingPathComponent(batchPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            Log.warning("[AudioRefinement] Batch file missing; keeping pass-1 text for recall: \(batchPath)", category: .processing)
            return .failed(reason: "missing_file")
        }

        // 2. Decode M4A → PCM
        let decoded: AudioFileDecoder.DecodedAudio
        do {
            decoded = try AudioFileDecoder.decodeToPCM(fileURL: fileURL)
        } catch {
            Log.error("[AudioRefinement] Failed to decode \(batchPath): \(error)", category: .processing)
            return .failed(reason: "decode_failed")
        }

        // 3. Get previous batch text for initial_prompt (text context only — no audio prepend,
        // which caused jumbled output because whisper got confused by audio starting mid-sentence).
        let neighbor = try? await transcriptionQueries.getNeighborBatchText(forBatchPath: batchPath)
        let promptText = neighbor?.preceding

        // 4. Always attempt refinement. Do not delete pass-1 unless this pass succeeds.
        let decision: AudioTranscriptionDecision
        do {
            decision = try await AudioTranscriptionRetryPipeline.transcribeBest(
                audioData: decoded.data,
                sampleRate: decoded.sampleRate,
                channels: 1,
                transcriptionService: transcriptionService,
                wordLevel: true,
                initialPrompt: promptText
            )
        } catch {
            Log.error("[AudioRefinement] Transcription failed for \(batchPath): \(error)", category: .processing)
            return .failed(reason: "transcription_failed")
        }
        let transcription = decision.transcription

        let adjustedWords = transcription.words
        let adjustedText = transcription.text

        // 5. Check for empty result. Keep pass-1 for recoverability.
        guard decision.shouldStoreText else {
            return .silence(reason: "no_storable_text")
        }

        // 7. Segment into sentences (using adjusted words/text so overlap is trimmed)
        let sentences = SentenceSegmenter.segment(
            words: adjustedWords,
            fullText: adjustedText,
            fallbackDuration: decoded.duration
        )

        guard !sentences.isEmpty else {
            return .silence(reason: "empty_sentence_segments")
        }

        // 8. Parse batch start time from filename (batch_<timestamp>_...)
        let batchStartTime: Date
        if let ts = Self.parseTimestampFromBatchPath(batchPath) {
            batchStartTime = ts
        } else {
            Log.error("[AudioRefinement] Cannot parse timestamp from \(batchPath)", category: .processing)
            return .failed(reason: "bad_batch_filename")
        }

        // Refinement changes text, not source audio. Reuse the raw batch.
        let transcriptAudioPath = AudioStoragePolicy.canonicalTranscriptPath(
            batchAudioPath: batchPath
        )

        // 10. Build sentence records
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
                startTime: batchStartTime.addingTimeInterval(sentence.startTime),
                endTime: batchStartTime.addingTimeInterval(sentence.endTime),
                source: .microphone,
                confidence: sentence.confidence,
                words: sentence.words,
                audioPath: transcriptAudioPath,
                transcriptionPass: 2,
                batchAudioPath: batchPath,
                transcriptStatus: decision.status.rawValue,
                detectedLanguage: transcription.language,
                audioVariant: decision.audioVariant.rawValue,
                qualityFlags: Self.qualityFlags(decision)
            ))
        }

        guard !transcriptionsBatch.isEmpty else {
            return .silence(reason: "empty_replacement_batch")
        }

        // 11. Atomically insert pass-2 records and remove pass-1 replacements.
        do {
            try await transcriptionQueries.replacePass1RecordsForBatch(
                batchAudioPath: batchPath,
                with: transcriptionsBatch
            )
        } catch {
            Log.error("[AudioRefinement] Failed to replace records for \(batchPath): \(error)", category: .processing)
            return .failed(reason: "replace_failed")
        }

        Log.debug("[AudioRefinement] Refined \(batchPath): \(transcriptionsBatch.count) sentences status=\(decision.status.rawValue) variant=\(decision.audioVariant.rawValue) language=\(transcription.language ?? "unknown") attempts=\(decision.attempts)", category: .processing)
        return .refined(sentenceCount: transcriptionsBatch.count)
    }

    private func yieldToPass1IfNeeded() async -> Bool {
        guard let isPass1Active else { return false }
        let active = await isPass1Active()
        let decision = AudioRefinementSchedulingPolicy.decision(
            isPass1Active: active,
            busyWaitDuration: busyWaitDuration,
            isCancelled: Task.isCancelled
        )
        guard !decision.shouldExit else { return false }
        guard decision.shouldYield else { return false }

        Log.debug("[AudioRefinement] Pass-1 transcription active; yielding for \(Int(decision.delaySeconds))s", category: .processing)
        do {
            try await Task.sleep(for: .milliseconds(Int64(decision.delaySeconds * 1_000)), clock: .continuous)
        } catch {
            return false
        }
        return !Task.isCancelled
    }

    private func retireBatchCandidate(
        _ batchPath: String,
        status: AudioTranscriptStatus,
        reason: String
    ) async {
        do {
            _ = try await transcriptionQueries.markBatchRefinementAttempted(
                batchAudioPath: batchPath,
                transcriptionPass: 1,
                transcriptStatus: status.rawValue,
                qualityFlag: reason
            )
        } catch {
            Log.error("[AudioRefinement] Failed to retire candidate \(batchPath): \(error)", category: .processing)
        }
    }

    // MARK: - Helpers

    /// Parse millisecond timestamp from batch filename: batch_<timestamp>_<source>_<hash>.m4a
    private static func parseTimestampFromBatchPath(_ path: String) -> Date? {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        guard filename.hasPrefix("batch_") else { return nil }
        let parts = filename.split(separator: "_")
        guard parts.count >= 2, let ms = Int64(parts[1]) else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

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

    /// Detect whisper hallucinations
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
        if words.count <= 2 { return true }
        guard words.count >= 4 else { return false }

        for phraseLen in 2...min(4, words.count / 2) {
            var phraseCounts: [String: Int] = [:]
            for i in 0...(words.count - phraseLen) {
                let phrase = words[i..<(i + phraseLen)].joined(separator: " ").lowercased()
                phraseCounts[phrase, default: 0] += 1
            }
            if let maxCount = phraseCounts.values.max(), maxCount > 3 { return true }
        }

        var wordCounts: [String: Int] = [:]
        for w in words { wordCounts[w.lowercased(), default: 0] += 1 }
        if let (_, count) = wordCounts.max(by: { $0.value < $1.value }) {
            if Double(count) / Double(words.count) > 0.5 && words.count > 4 { return true }
        }

        return false
    }

    private static func qualityFlags(_ decision: AudioTranscriptionDecision) -> String? {
        let flags = decision.qualityFlags
            + ["variant:\(decision.audioVariant.rawValue)", "language_hint:\(decision.languageHint.rawValue)", "attempts:\(decision.attempts)"]
        return flags.isEmpty ? nil : flags.joined(separator: ",")
    }
}
