import Foundation

public enum AudioTranscriptStatus: String, Sendable, Equatable {
    case pending
    case transcribed
    case probableSilence = "probable_silence"
    case probableJunk = "probable_junk"
    case needsReview = "needs_review"
    case languageUncertain = "language_uncertain"
    case decodeFailed = "decode_failed"
    case refinementFailed = "refinement_failed"
    case refinementSkipped = "refinement_skipped"
}

public enum AudioTranscriptionLanguageHint: String, Sendable, CaseIterable {
    case auto
    case english = "en"
    case japanese = "ja"
    case mongolian = "mn"

    public static let retryOrder: [AudioTranscriptionLanguageHint] = [
        .auto,
        .english,
        .japanese,
        .mongolian
    ]
}

public struct AudioTranscriptQualityAssessment: Sendable {
    public let status: AudioTranscriptStatus
    public let flags: [String]
    public let shouldStoreText: Bool
    public let shouldRetryWithEnhancement: Bool
}

public enum AudioTranscriptQualityPolicy {
    public static func assess(
        text: String,
        language: String?,
        activity: AudioSpeechActivityPolicy.Evaluation
    ) -> AudioTranscriptQualityAssessment {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var flags: [String] = []

        if normalizedText.isEmpty {
            if activity.isProbablySilence {
                return AudioTranscriptQualityAssessment(
                    status: .probableSilence,
                    flags: ["empty_text", "low_energy"],
                    shouldStoreText: false,
                    shouldRetryWithEnhancement: true
                )
            }
            return AudioTranscriptQualityAssessment(
                status: .needsReview,
                flags: ["empty_text", "speech_energy"],
                shouldStoreText: false,
                shouldRetryWithEnhancement: true
            )
        }

        if isPunctuationOnlyArtifact(normalizedText) {
            flags.append("punctuation_artifact")
            return AudioTranscriptQualityAssessment(
                status: .probableJunk,
                flags: flags,
                shouldStoreText: true,
                shouldRetryWithEnhancement: true
            )
        }

        if isLikelyPhoneticVocalizationArtifact(normalizedText) {
            flags.append("vocalization_artifact")
            return AudioTranscriptQualityAssessment(
                status: .probableJunk,
                flags: flags,
                shouldStoreText: true,
                shouldRetryWithEnhancement: true
            )
        }

        if isLikelyWhisperJunk(normalizedText) {
            flags.append("junk_pattern")
            return AudioTranscriptQualityAssessment(
                status: .probableJunk,
                flags: flags,
                shouldStoreText: true,
                shouldRetryWithEnhancement: true
            )
        }

        if isLikelyUnsupportedScriptArtifact(normalizedText, language: language) {
            flags.append("unsupported_script_artifact")
            return AudioTranscriptQualityAssessment(
                status: .probableJunk,
                flags: flags,
                shouldStoreText: true,
                shouldRetryWithEnhancement: true
            )
        }

        let words = normalizedText.split(whereSeparator: \.isWhitespace)
        if words.count <= 2 {
            flags.append("short_text")
            return AudioTranscriptQualityAssessment(
                status: .needsReview,
                flags: flags,
                shouldStoreText: true,
                shouldRetryWithEnhancement: true
            )
        }

        if let language, shouldTreatLanguageAsUncertain(language) {
            flags.append("language_uncertain")
            return AudioTranscriptQualityAssessment(
                status: .languageUncertain,
                flags: flags,
                shouldStoreText: true,
                shouldRetryWithEnhancement: true
            )
        }

        return AudioTranscriptQualityAssessment(
            status: .transcribed,
            flags: flags,
            shouldStoreText: true,
            shouldRetryWithEnhancement: false
        )
    }

    private static func shouldTreatLanguageAsUncertain(_ language: String) -> Bool {
        let normalized = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return true }

        let primaryLanguages: Set<String> = ["en", "ja", "mn"]
        if primaryLanguages.contains(normalized) {
            return false
        }

        return normalized == "auto" ||
            normalized == "unknown" ||
            normalized == "und" ||
            normalized == "nn"
    }

    private static func isPunctuationOnlyArtifact(_ text: String) -> Bool {
        let ignoredScalars = CharacterSet.whitespacesAndNewlines
        let punctuationScalars = CharacterSet.punctuationCharacters
            .union(.symbols)
        let signalScalars = text.unicodeScalars.filter { !ignoredScalars.contains($0) }
        guard !signalScalars.isEmpty else { return false }
        return signalScalars.allSatisfy { punctuationScalars.contains($0) }
    }

    private static func isLikelyWhisperJunk(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
        let lower = trimmed.lowercased()

        let knownSubstrings = [
            "thanks for watching",
            "thank you for watching",
            "please subscribe",
            "like and subscribe",
            "hit the like",
            "hit the bell",
            "subtitles by",
            "translated by",
            "i hope you enjoyed",
            "see you in the next",
            "don't forget to subscribe",
            "leave a comment",
            "i'll see you in the next video",
            "so i'm going to go ahead and"
        ]
        if knownSubstrings.contains(where: { lower.contains($0) }) {
            return true
        }

        if isLikelyNonSpeechCaption(lower) {
            return true
        }

        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 4 else { return false }

        for phraseLength in 2...min(4, words.count / 2) {
            var phraseCounts: [String: Int] = [:]
            for index in 0...(words.count - phraseLength) {
                let phrase = words[index..<(index + phraseLength)].joined(separator: " ").lowercased()
                phraseCounts[phrase, default: 0] += 1
            }
            if let maxCount = phraseCounts.values.max(), maxCount > 3 {
                return true
            }
        }

        var wordCounts: [String: Int] = [:]
        for word in words {
            wordCounts[word.lowercased(), default: 0] += 1
        }
        if let maxCount = wordCounts.values.max(), Double(maxCount) / Double(words.count) > 0.5 {
            return true
        }

        return false
    }

    private static func isLikelyPhoneticVocalizationArtifact(_ text: String) -> Bool {
        let ignoredScalars = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(CharacterSet(charactersIn: "\"'`"))
        let signalScalars = text.unicodeScalars.filter { !ignoredScalars.contains($0) }
        guard signalScalars.count >= 4 else { return false }
        guard !signalScalars.contains(where: isPrimarySpeechScriptScalar) else { return false }
        return signalScalars.allSatisfy(isPhoneticArtifactScalar)
    }

    private static func isLikelyUnsupportedScriptArtifact(_ text: String, language: String?) -> Bool {
        guard shouldTreatLanguageAsUncertain(language ?? "unknown") else { return false }
        if text.contains("\u{FFFD}") { return true }

        let ignoredScalars = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
            .union(CharacterSet(charactersIn: "\"'`"))
        let signalScalars = text.unicodeScalars.filter { !ignoredScalars.contains($0) }
        guard signalScalars.count >= 4 else { return false }

        return signalScalars.contains { !isPrimarySpeechScriptScalar($0) }
    }

    private static func isPrimarySpeechScriptScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0030...0x0039, // ASCII digits
             0x0041...0x005A, // Basic Latin uppercase
             0x0061...0x007A, // Basic Latin lowercase
             0x0400...0x04FF, // Cyrillic, used by modern Mongolian
             0x1800...0x18AF, // Traditional Mongolian
             0x3040...0x309F, // Hiragana
             0x30A0...0x30FF, // Katakana
             0x4E00...0x9FFF: // CJK unified ideographs
            return true
        default:
            return false
        }
    }

    private static func isPhoneticArtifactScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0250...0x02AF, // IPA Extensions
             0x02B0...0x02FF, // Spacing Modifier Letters
             0x0300...0x036F: // Combining Diacritical Marks
            return true
        default:
            return false
        }
    }

    private static func isLikelyNonSpeechCaption(_ lower: String) -> Bool {
        let captionMarkers = CharacterSet(charactersIn: "*[]()")
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCaptionWrapper =
            (trimmed.hasPrefix("*") && trimmed.hasSuffix("*")) ||
            (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) ||
            (trimmed.hasPrefix("(") && trimmed.hasSuffix(")"))
        guard hasCaptionWrapper else { return false }

        let inner = trimmed
            .trimmingCharacters(in: captionMarkers)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nonSpeechTerms = [
            "applause",
            "alarm",
            "background",
            "beep",
            "bell",
            "breathing",
            "chime",
            "click",
            "clicking",
            "clapping",
            "cough",
            "crackle",
            "crackling",
            "door",
            "doorbell",
            "fire",
            "footstep",
            "footsteps",
            "inaudible",
            "keyboard",
            "knock",
            "laugh",
            "laughter",
            "mouse",
            "music",
            "no audio",
            "no sound",
            "noise",
            "notification",
            "ring",
            "ringing",
            "silence",
            "sigh",
            "sound",
            "sounds",
            "static",
            "typing",
            "waves",
            "wind",
            "笑",
            "笑い"
        ]
        if nonSpeechTerms.contains(where: { inner.contains($0) }) {
            return true
        }

        let words = inner
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0) }
        let speechPronouns: Set<String> = [
            "i",
            "im",
            "you",
            "we",
            "he",
            "she",
            "they"
        ]

        return words.count <= 4
            && !words.contains(where: speechPronouns.contains)
            && words.contains { $0.hasSuffix("ing") }
    }
}
