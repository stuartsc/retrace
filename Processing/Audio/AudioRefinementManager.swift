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
    private var mediaStore: (any AudioChunkMediaStoreProtocol)?
    private var isRunning = false
    // Carry inspection progress across the App's bounded automatic/manual cycles.
    // Restart begins another safe sweep; no legacy transcript is rewritten.
    private var refinementCandidateCursor: Int64 = 0
    private let candidateInspectionLimit = 256

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
        storageRoot: URL,
        mediaStore: (any AudioChunkMediaStoreProtocol)? = nil
    ) {
        self.transcriptionService = transcriptionService
        self.transcriptionQueries = transcriptionQueries
        self.audioWriter = audioWriter
        self.storageRoot = storageRoot
        self.mediaStore = mediaStore
    }

    public func setChunkMediaStore(_ store: (any AudioChunkMediaStoreProtocol)?) { mediaStore = store }

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
        var inspectedCandidates = 0
        var attemptedBatchPaths = Set<String>()
        var attemptedBatches = 0

        while !Task.isCancelled && inspectedCandidates < candidateInspectionLimit {
            if let batchLimit, attemptedBatches >= batchLimit { break }
            if await yieldToPass1IfNeeded() {
                continue
            }
            if Task.isCancelled { break }

            let candidates: [AudioRefinementInspection]
            do {
                candidates = try await transcriptionQueries.originalSourceRefinementPage(
                    transcriptionPass: 1, afterRowID: refinementCandidateCursor,
                    limit: min(10, candidateInspectionLimit - inspectedCandidates))
            } catch {
                Log.error("[AudioRefinement] Failed to query refinement candidates: \(error)", category: .processing)
                break
            }

            guard !candidates.isEmpty else {
                refinementCandidateCursor = 0
                break
            }

            for candidate in candidates {
                if Task.isCancelled { break }
                if let batchLimit, attemptedBatches >= batchLimit { break }
                if await yieldToPass1IfNeeded() { break }
                if Task.isCancelled { break }
                refinementCandidateCursor = candidate.rowID
                inspectedCandidates += 1
                guard let batchPath = candidate.batchAudioPath,
                      attemptedBatchPaths.insert(batchPath).inserted else { continue }

                let result = await processSingleBatch(batchPath)
                if Task.isCancelled { break }
                switch result {
                case .refined(let sentenceCount):
                    totalRefined += 1
                    totalSentences += sentenceCount
                case .silence(let reason):
                    totalSilence += 1
                    await retireBatchCandidate(batchPath, status: .refinementSkipped, reason: reason)
                case .sourceUnavailable(let modelAttempted):
                    totalFailed += 1
                    // Inspect legacy gaps without consuming the model-work limit
                    // or throttle. The persisted actor cursor prevents starvation.
                    if !modelAttempted { continue }
                case .failed(let reason):
                    totalFailed += 1
                    await retireBatchCandidate(batchPath, status: .refinementFailed, reason: reason)
                }

                attemptedBatches += 1
                batchesInCycle += 1
                if batchesInCycle >= batchesPerCycle,
                   batchLimit.map({ attemptedBatches < $0 }) ?? true {
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

    private enum BatchResult: Sendable {
        case refined(sentenceCount: Int)
        case silence(reason: String)
        case failed(reason: String)
        case sourceUnavailable(modelAttempted: Bool)
    }

    private func recordSourceFailure(_ failure: AudioOriginalSourceError) async {
        do { try await transcriptionQueries.recordOriginalSourceFailure(failure, pass: 2) }
        catch { Log.warning("[AudioRefinement] Original source outcome metric unavailable", category: .processing) }
    }

    private func processSingleBatch(_ batchPath: String) async -> BatchResult {
        let originalSource: AudioOriginalSourceReceipt
        do {
            originalSource = try await transcriptionQueries.originalSourceReceipt(forBatchPath: batchPath)
        } catch {
            let failure = (error as? AudioOriginalSourceError) ?? .unavailable
            await recordSourceFailure(failure)
            let reason = failure.rawValue
            Log.warning("[AudioRefinement] Original recording source unavailable: \(reason)", category: .processing)
            return .sourceUnavailable(modelAttempted: false)
        }

        do {
            return try await AudioTranscriptionMedia.withInput(path: batchPath,
                legacyStartTime: Self.parseTimestampFromBatchPath(batchPath), storageRoot: storageRoot,
                queries: transcriptionQueries, mediaStore: mediaStore) { [self] input in
                    await processLoadedBatch(batchPath, originalSource: originalSource, input: input)
                }
        } catch is CancellationError {
            return .sourceUnavailable(modelAttempted: false)
        } catch {
            return .sourceUnavailable(modelAttempted: false)
        }
    }

    private func processLoadedBatch(_ batchPath: String, originalSource: AudioOriginalSourceReceipt,
        input: AudioTranscriptionInput) async -> BatchResult {
        // 3. Get previous batch text for initial_prompt (text context only — no audio prepend,
        // which caused jumbled output because whisper got confused by audio starting mid-sentence).
        let neighbor = try? await transcriptionQueries.getNeighborBatchText(forBatchPath: batchPath)
        let promptText = neighbor?.preceding

        // 4. Always attempt refinement. Do not delete pass-1 unless this pass succeeds.
        let decision: AudioTranscriptionDecision
        do {
            try input.checkValidity()
            decision = try await AudioTranscriptionRetryPipeline.transcribeBest(
                audioData: input.data,
                sampleRate: input.sampleRate,
                channels: 1,
                transcriptionService: transcriptionService,
                wordLevel: true,
                initialPrompt: promptText
            )
            // A backend may return normally after cancellation, including an
            // empty result. Never retire retained text on that cancelled result.
            try input.checkValidity()
        } catch is CancellationError {
            await recordSourceFailure(.cancelled)
            return .sourceUnavailable(modelAttempted: true)
        } catch is AudioTranscriptionMediaError {
            return .sourceUnavailable(modelAttempted: true)
        } catch {
            Log.error("[AudioRefinement] Transcription failed for \(batchPath): \(error)", category: .processing)
            return .failed(reason: "transcription_failed")
        }
        let transcription = decision.transcription

        // 5. Check for empty result. Keep pass-1 for recoverability.
        guard decision.shouldStoreText else {
            return .silence(reason: "no_storable_text")
        }

        let owned: (words: [TranscriptionWord], text: String)
        do { owned = try input.ownedTranscript(transcription) }
        catch { return .sourceUnavailable(modelAttempted: true) }

        // Segment only words owned by this exact logical window.
        let sentences = SentenceSegmenter.segment(
            words: owned.words,
            fullText: owned.text,
            fallbackDuration: input.duration
        )

        guard !sentences.isEmpty else {
            return .silence(reason: "empty_sentence_segments")
        }

        let batchStartTime = input.startTime

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
                source: originalSource.source,
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

        // 11. Revalidate the original recording source and atomically append pass-2; earlier passes remain retained.
        do {
            try await input.validateForPublication(queries: transcriptionQueries, path: batchPath)
            try await transcriptionQueries.replacePass1RecordsForBatch(
                batchAudioPath: batchPath,
                with: transcriptionsBatch,
                originalSource: originalSource
            )
        } catch is CancellationError {
            await recordSourceFailure(.cancelled)
            return .sourceUnavailable(modelAttempted: true)
        } catch let error as AudioOriginalSourceError {
            await recordSourceFailure(error)
            Log.warning("[AudioRefinement] Original recording source changed: \(error.rawValue)", category: .processing)
            return .sourceUnavailable(modelAttempted: true)
        } catch is AudioTranscriptionMediaError {
            return .sourceUnavailable(modelAttempted: true)
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
