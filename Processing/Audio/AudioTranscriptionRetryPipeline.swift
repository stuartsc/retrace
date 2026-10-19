import Foundation
import Shared

public struct AudioTranscriptionDecision: Sendable {
    public let transcription: DetailedTranscriptionResult
    public let status: AudioTranscriptStatus
    public let audioVariant: AudioEnhancementVariant
    public let languageHint: AudioTranscriptionLanguageHint
    public let qualityFlags: [String]
    /// Total transcription attempts made for this batch, not just the selected attempt.
    public let attempts: Int

    public var shouldStoreText: Bool {
        !transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum AudioTranscriptionProfile: Sendable, Equatable {
    /// Fast, user-facing pass. Raw audio remains on disk for exhaustive repair.
    case liveFirstPass
    /// The previous bounded enhancement sequence, admitted independently after
    /// an uncertain first pass. Also preserves legacy immediate fallback behavior.
    case deferredFirstPassRepair
    /// Offline/backfill/refinement pass. Spend more compute to recover quiet or multilingual speech.
    case exhaustiveRepair
}

public enum AudioTranscriptionRetryPipeline {
    public static func transcribeBest(
        audioData: Data,
        sampleRate: Int,
        channels: Int,
        transcriptionService: any TranscriptionProtocol,
        wordLevel: Bool,
        initialPrompt: String?,
        profile: AudioTranscriptionProfile = .exhaustiveRepair,
        retainedFirstPass: DetailedTranscriptionResult? = nil
    ) async throws -> AudioTranscriptionDecision {
        try BackgroundProcessingContext.checkCancellation()
        let activity = AudioSpeechActivityPolicy.evaluate(
            audioData,
            sampleRate: sampleRate,
            channels: channels
        )

        let retained = profile == .liveFirstPass ? nil : retainedFirstPass
        var bestDecision = retained.map { transcription in
            let assessment = AudioTranscriptQualityPolicy.assess(
                text: transcription.text, language: transcription.language, activity: activity)
            return AudioTranscriptionDecision(transcription: transcription, status: assessment.status,
                audioVariant: .raw, languageHint: .english, qualityFlags: assessment.flags, attempts: 0)
        }
        var attempts = 0
        let attemptPlan = attemptPlan(for: profile, hasRetainedFirstPass: retained != nil)
        let requestedWordLevel = profile != .exhaustiveRepair ? false : wordLevel
        // Context helps offline repair, but it can make quiet live batches echo the
        // previous transcript and feed that hallucination into every later batch.
        let effectiveInitialPrompt = profile != .exhaustiveRepair ? nil : initialPrompt

        for variant in attemptPlan.variants {
            try BackgroundProcessingContext.checkCancellation()
            let shouldKeepSearching = bestDecision.map {
                shouldContinueForCompleteness(activity: activity, decision: $0, profile: profile)
            } ?? true
            // Explicit exhaustive repair still begins with its original auto
            // attempt, even when a saved candidate seeds ranking. Do not expand
            // the raw variant into four language calls merely because it exists.
            let hints: [AudioTranscriptionLanguageHint] = profile == .exhaustiveRepair && variant == .raw
                ? [.auto]
                : languageHints(for: bestDecision, continueAfterTranscribed: shouldKeepSearching, profile: profile)
            guard !hints.isEmpty else { break }

            let candidateAudio = AudioEnhancer.enhance(
                audioData,
                variant: variant,
                sampleRate: sampleRate,
                channels: channels
            )

            for languageHint in hints {
                try BackgroundProcessingContext.checkCancellation()
                attempts += 1
                let transcription = try await transcriptionService.transcribeWithTimestamps(
                    candidateAudio,
                    wordLevel: requestedWordLevel,
                    initialPrompt: effectiveInitialPrompt,
                    languageHint: languageHint.rawValue
                )
                try BackgroundProcessingContext.checkCancellation()
                let assessment = AudioTranscriptQualityPolicy.assess(
                    text: transcription.text,
                    language: transcription.language,
                    activity: activity
                )
                let decision = AudioTranscriptionDecision(
                    transcription: transcription,
                    status: assessment.status,
                    audioVariant: variant,
                    languageHint: languageHint,
                    qualityFlags: assessment.flags,
                    attempts: attempts
                )

                if isBetter(decision, than: bestDecision) {
                    bestDecision = decision
                }
                if profile != .exhaustiveRepair,
                   activity.isProbablySilence,
                   assessment.status == .probableSilence,
                   bestDecision?.shouldStoreText != true {
                    return selected(bestDecision ?? decision, attempts: attempts)
                }
                if profile != .exhaustiveRepair, isAcceptableLiveCandidate(decision) {
                    return selected(bestDecision ?? decision, attempts: attempts)
                }
                if assessment.status == .transcribed,
                   !shouldContinueForCompleteness(activity: activity, decision: decision, profile: profile) {
                    return selected(bestDecision ?? decision, attempts: attempts)
                }
            }
        }

        if let bestDecision {
            return selected(bestDecision, attempts: attempts)
        }

        return AudioTranscriptionDecision(
            transcription: DetailedTranscriptionResult(text: "", words: [], language: nil, duration: nil),
            status: activity.isProbablySilence ? .probableSilence : .needsReview,
            audioVariant: .raw,
            languageHint: .auto,
            qualityFlags: activity.isProbablySilence ? ["empty_audio", "low_energy"] : ["empty_audio"],
            attempts: attempts
        )
    }

    private struct AttemptPlan {
        let variants: [AudioEnhancementVariant]
    }

    private static func selected(_ decision: AudioTranscriptionDecision, attempts: Int) -> AudioTranscriptionDecision {
        AudioTranscriptionDecision(transcription: decision.transcription, status: decision.status,
            audioVariant: decision.audioVariant, languageHint: decision.languageHint,
            qualityFlags: decision.qualityFlags, attempts: attempts)
    }

    private static func attemptPlan(for profile: AudioTranscriptionProfile, hasRetainedFirstPass: Bool) -> AttemptPlan {
        switch profile {
        case .liveFirstPass:
            // One admitted first pass must not expand into repeated native
            // inference. Retain its text/status and original audio; enhancement
            // belongs to a separately admitted repair lane.
            return AttemptPlan(variants: [.raw])
        case .deferredFirstPassRepair:
            return AttemptPlan(variants: hasRetainedFirstPass
                ? [.normalized, .highPassBoosted] : [.raw, .normalized, .highPassBoosted])
        case .exhaustiveRepair:
            return AttemptPlan(variants: AudioEnhancementVariant.retryOrder)
        }
    }

    private static func languageHints(
        for bestDecision: AudioTranscriptionDecision?,
        continueAfterTranscribed: Bool,
        profile: AudioTranscriptionProfile
    ) -> [AudioTranscriptionLanguageHint] {
        if profile != .exhaustiveRepair {
            return bestDecision == nil || continueAfterTranscribed ? [.english] : []
        }
        guard let bestDecision else {
            return [.auto]
        }
        switch bestDecision.status {
        case .transcribed:
            return continueAfterTranscribed ? AudioTranscriptionLanguageHint.retryOrder : []
        case .probableSilence, .probableJunk, .needsReview, .languageUncertain, .pending, .decodeFailed,
             .refinementFailed, .refinementSkipped:
            return AudioTranscriptionLanguageHint.retryOrder
        }
    }

    private static func isBetter(
        _ candidate: AudioTranscriptionDecision,
        than existing: AudioTranscriptionDecision?
    ) -> Bool {
        guard let existing else { return true }

        // An empty result cannot erase earlier recoverable text, even when its
        // categorical status happens to score higher (for example empty review
        // versus a nonempty caption). Retain that text with its review status.
        if candidate.shouldStoreText != existing.shouldStoreText { return candidate.shouldStoreText }

        let candidateQuality = qualityRank(candidate)
        let existingQuality = qualityRank(existing)
        if candidateQuality != existingQuality { return candidateQuality > existingQuality }

        let candidateScore = score(candidate)
        let existingScore = score(existing)
        if candidateScore != existingScore {
            return candidateScore > existingScore
        }
        return candidate.transcription.text.count > existing.transcription.text.count
    }

    private static func qualityRank(_ decision: AudioTranscriptionDecision) -> Int {
        // Readable speech must beat a long caption or other artifact before
        // completeness/length scoring is considered.
        if isAcceptableLiveCandidate(decision) { return 3 }
        switch decision.status {
        case .transcribed, .needsReview, .languageUncertain: return 2
        case .probableJunk: return 1
        default: return 0
        }
    }

    private static func score(_ decision: AudioTranscriptionDecision) -> Int {
        let text = decision.transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let whitespaceWords = text.split(whereSeparator: \.isWhitespace).count
        let wordCount = max(whitespaceWords, decision.transcription.words.count)
        let characterCoverage = min(text.count / 4, 50)
        let completenessScore = min(wordCount * 4, 80) + characterCoverage
        let statusScore: Int
        switch decision.status {
        case .transcribed:
            statusScore = 80
        case .needsReview, .languageUncertain:
            statusScore = 70
        case .probableJunk:
            statusScore = 15
        case .probableSilence:
            statusScore = 0
        case .pending, .decodeFailed, .refinementFailed, .refinementSkipped:
            statusScore = 0
        }
        return statusScore + completenessScore
    }

    private static func shouldContinueForCompleteness(
        activity: AudioSpeechActivityPolicy.Evaluation?,
        decision: AudioTranscriptionDecision,
        profile: AudioTranscriptionProfile
    ) -> Bool {
        if profile != .exhaustiveRepair {
            return !isAcceptableLiveCandidate(decision)
        }

        let text = decision.transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }

        let whitespaceWords = text.split(whereSeparator: \.isWhitespace).count
        let wordCount = max(whitespaceWords, decision.transcription.words.count)
        if decision.status != .transcribed { return true }

        // Quiet/distant speech is where raw Whisper most often returns plausible but partial text.
        // Keep exploring enhanced and language-hinted variants unless the result is clearly dense.
        if let activity {
            let quietBatch = activity.fullBatchRMS < 0.012 || activity.activeWindowRMS < 0.018
            if quietBatch && (wordCount < 24 || text.count < 140) {
                return true
            }
        }

        return false
    }

    private static func isAcceptableLiveCandidate(_ decision: AudioTranscriptionDecision) -> Bool {
        let text = decision.transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        switch decision.status {
        case .transcribed:
            return true
        case .needsReview:
            return isReadableShortLiveText(text, language: decision.transcription.language)
        case .probableSilence, .probableJunk, .languageUncertain, .pending, .decodeFailed,
             .refinementFailed, .refinementSkipped:
            return false
        }
    }

    static func needsDeferredFirstPassRepair(_ decision: AudioTranscriptionDecision) -> Bool {
        if decision.status == .probableSilence && !decision.shouldStoreText { return false }
        return !isAcceptableLiveCandidate(decision)
    }

    private static func isReadableShortLiveText(_ text: String, language: String?) -> Bool {
        let normalizedLanguage = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedLanguage == "en" || normalizedLanguage == "ja" || normalizedLanguage == "mn" else {
            return false
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("\u{FFFD}") { return false }
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("*") { return false }
        if trimmed.hasPrefix("("), trimmed.hasSuffix(")") {
            let inner = trimmed
                .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if inner.count <= 8 { return false }
        }
        return true
    }
}
