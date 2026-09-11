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
        profile: AudioTranscriptionProfile = .exhaustiveRepair
    ) async throws -> AudioTranscriptionDecision {
        let activity = AudioSpeechActivityPolicy.evaluate(
            audioData,
            sampleRate: sampleRate,
            channels: channels
        )

        var bestDecision: AudioTranscriptionDecision?
        var attempts = 0
        let attemptPlan = attemptPlan(for: profile)
        let requestedWordLevel = profile == .liveFirstPass ? false : wordLevel
        // Context helps offline repair, but it can make quiet live batches echo the
        // previous transcript and feed that hallucination into every later batch.
        let effectiveInitialPrompt = profile == .liveFirstPass ? nil : initialPrompt

        for variant in attemptPlan.variants {
            let shouldKeepSearching = bestDecision.map {
                shouldContinueForCompleteness(activity: activity, decision: $0, profile: profile)
            } ?? true
            let hints = languageHints(
                for: bestDecision,
                continueAfterTranscribed: shouldKeepSearching,
                profile: profile
            )
            guard !hints.isEmpty else { break }

            let candidateAudio = AudioEnhancer.enhance(
                audioData,
                variant: variant,
                sampleRate: sampleRate,
                channels: channels
            )

            for languageHint in hints {
                attempts += 1
                let transcription = try await transcriptionService.transcribeWithTimestamps(
                    candidateAudio,
                    wordLevel: requestedWordLevel,
                    initialPrompt: effectiveInitialPrompt,
                    languageHint: languageHint.rawValue
                )
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
                if profile == .liveFirstPass,
                   activity.isProbablySilence,
                   assessment.status == .probableSilence,
                   transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return AudioTranscriptionDecision(
                        transcription: transcription,
                        status: assessment.status,
                        audioVariant: variant,
                        languageHint: languageHint,
                        qualityFlags: assessment.flags,
                        attempts: attempts
                    )
                }
                if profile == .liveFirstPass, isAcceptableLiveCandidate(decision) {
                    return AudioTranscriptionDecision(
                        transcription: transcription,
                        status: assessment.status,
                        audioVariant: variant,
                        languageHint: languageHint,
                        qualityFlags: assessment.flags,
                        attempts: attempts
                    )
                }
                if assessment.status == .transcribed,
                   !shouldContinueForCompleteness(activity: activity, decision: decision, profile: profile) {
                    return AudioTranscriptionDecision(
                        transcription: transcription,
                        status: assessment.status,
                        audioVariant: variant,
                        languageHint: languageHint,
                        qualityFlags: assessment.flags,
                        attempts: attempts
                    )
                }
            }
        }

        if let bestDecision {
            return AudioTranscriptionDecision(
                transcription: bestDecision.transcription,
                status: bestDecision.status,
                audioVariant: bestDecision.audioVariant,
                languageHint: bestDecision.languageHint,
                qualityFlags: bestDecision.qualityFlags,
                attempts: attempts
            )
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

    private static func attemptPlan(for profile: AudioTranscriptionProfile) -> AttemptPlan {
        switch profile {
        case .liveFirstPass:
            return AttemptPlan(variants: [.raw, .normalized, .highPassBoosted])
        case .exhaustiveRepair:
            return AttemptPlan(variants: AudioEnhancementVariant.retryOrder)
        }
    }

    private static func languageHints(
        for bestDecision: AudioTranscriptionDecision?,
        continueAfterTranscribed: Bool,
        profile: AudioTranscriptionProfile
    ) -> [AudioTranscriptionLanguageHint] {
        if profile == .liveFirstPass {
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

        let candidateScore = score(candidate)
        let existingScore = score(existing)
        if candidateScore != existingScore {
            return candidateScore > existingScore
        }
        return candidate.transcription.text.count > existing.transcription.text.count
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
        if profile == .liveFirstPass {
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
