import Foundation
import Shared
import Database
import Storage
import CoreGraphics

/// Pass-3 contextual refinement: re-transcribes pass-2 batches using neighboring transcript text
/// as initial_prompt to improve coherence and reduce hallucinations.
/// Runs only when idle (AC power + no user activity for 5 minutes).
/// Owner: PROCESSING agent
public actor AudioContextualRefinementManager {

    private let transcriptionService: WhisperCppTranscriptionService
    private let transcriptionQueries: AudioTranscriptionQueries
    private let audioWriter: AudioSegmentWriter
    private let storageRoot: URL
    private var isRunning = false

    // Throttling — more conservative than pass-2 since this is idle-only
    private let batchesPerCycle = 3
    private let yieldDuration: TimeInterval = 15
    private let idleCheckInterval: TimeInterval = 60
    private let requiredIdleSeconds: Double = 300  // 5 minutes

    public struct RefinementResult: Sendable {
        public let refinedCount: Int
        public let skippedCount: Int
        public let failedCount: Int
        public let totalSentences: Int
    }

    public enum RunMode: Sendable {
        case automatic
        case manual
    }

    public init(
        transcriptionService: WhisperCppTranscriptionService,
        transcriptionQueries: AudioTranscriptionQueries,
        audioWriter: AudioSegmentWriter,
        storageRoot: URL
    ) {
        self.transcriptionService = transcriptionService
        self.transcriptionQueries = transcriptionQueries
        self.audioWriter = audioWriter
        self.storageRoot = storageRoot
    }

    /// Process all pass-2 transcriptions that can be contextually refined
    public func processAllPendingRefinements(
        runMode: RunMode = .automatic,
        maxBatches: Int? = nil
    ) async -> RefinementResult {
        guard !isRunning else {
            Log.warning("[ContextualRefinement] Already running, skipping", category: .processing)
            return RefinementResult(refinedCount: 0, skippedCount: 0, failedCount: 0, totalSentences: 0)
        }

        let batchLimit = maxBatches.map { max($0, 0) }
        if batchLimit == 0 {
            return RefinementResult(refinedCount: 0, skippedCount: 0, failedCount: 0, totalSentences: 0)
        }

        isRunning = true
        defer { isRunning = false }

        var totalRefined = 0
        var totalSkipped = 0
        var totalFailed = 0
        var totalSentences = 0
        var batchesInCycle = 0
        var attemptedBatchPaths = Set<String>()
        var attemptedBatches = 0

        while true {
            if let batchLimit, attemptedBatches >= batchLimit { break }
            // Wait for idle conditions
            while runMode == .automatic && !isIdle() {
                Log.debug("[ContextualRefinement] Not idle, waiting \(Int(idleCheckInterval))s", category: .processing)
                try? await Task.sleep(for: .milliseconds(Int64(idleCheckInterval * 1_000)), clock: .continuous)
                if Task.isCancelled { break }
            }
            if Task.isCancelled { break }

            let batchPaths: [String]
            do {
                let fetchLimit = batchLimit.map { min(10, max($0 - attemptedBatches, 0)) } ?? 10
                guard fetchLimit > 0 else { break }
                let candidates = try await transcriptionQueries.getDistinctBatchPathsForContextualRefinement(limit: fetchLimit)
                batchPaths = candidates.filter { !attemptedBatchPaths.contains($0) }
            } catch {
                Log.error("[ContextualRefinement] Failed to query candidates: \(error)", category: .processing)
                break
            }

            guard !batchPaths.isEmpty else {
                Log.info("[ContextualRefinement] No more pass-2 batches to refine", category: .processing)
                break
            }

            for batchPath in batchPaths {
                if Task.isCancelled { break }
                if let batchLimit, attemptedBatches >= batchLimit { break }
                attemptedBatchPaths.insert(batchPath)
                attemptedBatches += 1

                // Re-check idle before each batch
                if runMode == .automatic && !isIdle() { break }

                let result = await processSingleBatch(batchPath)
                switch result {
                case .refined(let sentenceCount):
                    totalRefined += 1
                    totalSentences += sentenceCount
                case .skipped(let reason):
                    totalSkipped += 1
                    await retireBatchCandidate(batchPath, status: .refinementSkipped, reason: reason)
                case .failed(let reason):
                    totalFailed += 1
                    await retireBatchCandidate(batchPath, status: .refinementFailed, reason: reason)
                }

                batchesInCycle += 1
                if batchesInCycle >= batchesPerCycle {
                    batchesInCycle = 0
                    try? await Task.sleep(for: .milliseconds(Int64(yieldDuration * 1_000)), clock: .continuous)
                }
            }
        }

        Log.info("[ContextualRefinement] Complete: \(totalRefined) refined, \(totalSkipped) skipped, \(totalFailed) failed, \(totalSentences) sentences", category: .processing)
        return RefinementResult(
            refinedCount: totalRefined,
            skippedCount: totalSkipped,
            failedCount: totalFailed,
            totalSentences: totalSentences
        )
    }

    public var isCurrentlyRunning: Bool { isRunning }

    // MARK: - Idle Detection

    /// Check if machine is idle enough for background refinement
    private nonisolated func isIdle() -> Bool {
        // Must be on AC power
        guard PowerStateMonitor.shared.isOnACPower else { return false }

        // Must not be in low power mode
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }

        // Check user idle time (keyboard/mouse inactivity)
        let idleTime = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
        let keyIdleTime = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        let minIdle = min(idleTime, keyIdleTime)

        return minIdle >= requiredIdleSeconds
    }

    // MARK: - Private

    private enum BatchResult {
        case refined(sentenceCount: Int)
        case skipped(reason: String)
        case failed(reason: String)
    }

    private func processSingleBatch(_ batchPath: String) async -> BatchResult {
        // 1. Get neighboring batch text for context
        let neighbors: (preceding: String?, following: String?)
        do {
            neighbors = try await transcriptionQueries.getNeighborBatchText(forBatchPath: batchPath)
        } catch {
            Log.error("[ContextualRefinement] Failed to get neighbors for \(batchPath): \(error)", category: .processing)
            return .failed(reason: "neighbor_query_failed")
        }

        // Skip if no neighbors have text — context won't help
        guard neighbors.preceding != nil || neighbors.following != nil else {
            return .skipped(reason: "no_context")
        }

        // 2. Build contextual prompt
        var promptParts: [String] = []
        if let preceding = neighbors.preceding { promptParts.append(preceding) }
        if let following = neighbors.following { promptParts.append(following) }
        let prompt = promptParts.joined(separator: " ")

        // 3. Resolve and decode batch audio
        let fileURL = storageRoot.appendingPathComponent(batchPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            Log.warning("[ContextualRefinement] Batch file missing; keeping pass-2 text for recall: \(batchPath)", category: .processing)
            return .failed(reason: "missing_file")
        }

        let decoded: AudioFileDecoder.DecodedAudio
        do {
            decoded = try AudioFileDecoder.decodeToPCM(fileURL: fileURL)
        } catch {
            Log.error("[ContextualRefinement] Failed to decode \(batchPath): \(error)", category: .processing)
            return .failed(reason: "decode_failed")
        }

        // 4. Transcribe with text prompt only. Do not delete pass-2 unless this pass succeeds.
        let decision: AudioTranscriptionDecision
        do {
            decision = try await AudioTranscriptionRetryPipeline.transcribeBest(
                audioData: decoded.data,
                sampleRate: decoded.sampleRate,
                channels: 1,
                transcriptionService: transcriptionService,
                wordLevel: true,
                initialPrompt: prompt
            )
        } catch {
            Log.error("[ContextualRefinement] Transcription failed for \(batchPath): \(error)", category: .processing)
            return .failed(reason: "transcription_failed")
        }
        let transcription = decision.transcription

        let adjustedWords = transcription.words
        let adjustedText = transcription.text

        guard decision.shouldStoreText else {
            return .skipped(reason: "no_storable_text")
        }

        // 7. Segment into sentences
        let sentences = SentenceSegmenter.segment(
            words: adjustedWords,
            fullText: adjustedText,
            fallbackDuration: decoded.duration
        )
        guard !sentences.isEmpty else {
            return .skipped(reason: "empty_sentence_segments")
        }

        // 8. Parse batch start time
        guard let batchStartTime = Self.parseTimestampFromBatchPath(batchPath) else {
            Log.error("[ContextualRefinement] Cannot parse timestamp from \(batchPath)", category: .processing)
            return .failed(reason: "bad_batch_filename")
        }

        // Contextual refinement shares the immutable raw batch with earlier passes.
        let transcriptAudioPath = AudioStoragePolicy.canonicalTranscriptPath(
            batchAudioPath: batchPath
        )

        // 10. Build pass-3 records
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
                transcriptionPass: 3,
                batchAudioPath: batchPath,
                transcriptStatus: decision.status.rawValue,
                detectedLanguage: transcription.language,
                audioVariant: decision.audioVariant.rawValue,
                qualityFlags: Self.qualityFlags(decision)
            ))
        }

        guard !transcriptionsBatch.isEmpty else {
            return .skipped(reason: "empty_replacement_batch")
        }

        // 11. Atomically insert pass-3 records and remove pass-2 replacements.
        do {
            try await transcriptionQueries.replacePass2RecordsForBatch(
                batchAudioPath: batchPath,
                with: transcriptionsBatch
            )
        } catch {
            Log.error("[ContextualRefinement] Failed to replace records for \(batchPath): \(error)", category: .processing)
            return .failed(reason: "replace_failed")
        }

        Log.debug("[ContextualRefinement] Refined \(batchPath): \(transcriptionsBatch.count) sentences with context status=\(decision.status.rawValue) variant=\(decision.audioVariant.rawValue) language=\(transcription.language ?? "unknown") attempts=\(decision.attempts)", category: .processing)
        return .refined(sentenceCount: transcriptionsBatch.count)
    }

    private func retireBatchCandidate(
        _ batchPath: String,
        status: AudioTranscriptStatus,
        reason: String
    ) async {
        do {
            _ = try await transcriptionQueries.markBatchRefinementAttempted(
                batchAudioPath: batchPath,
                transcriptionPass: 2,
                transcriptStatus: status.rawValue,
                qualityFlag: reason
            )
        } catch {
            Log.error("[ContextualRefinement] Failed to retire candidate \(batchPath): \(error)", category: .processing)
        }
    }

    // MARK: - Helpers

    private static func parseTimestampFromBatchPath(_ path: String) -> Date? {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        guard filename.hasPrefix("batch_") else { return nil }
        let parts = filename.split(separator: "_")
        guard parts.count >= 2, let ms = Int64(parts[1]) else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

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
