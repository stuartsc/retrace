import Foundation

public enum DictationTextFormatter {
    public static func formatted(_ text: String) -> String? {
        var result = removeKnownNonSpeechCaptions(from: text)
        result = removeStandaloneDecoderBrackets(from: result)
        result = collapseWhitespace(in: result)
        result = normalizePunctuation(in: result)
        result = collapseWhitespace(in: result)

        guard containsSpeechSignal(result) else { return nil }

        result = capitalizeSentenceStarts(in: result)

        if let last = result.last, !".!?".contains(last) {
            result.append(".")
        }

        return result
    }

    private static func removeKnownNonSpeechCaptions(from text: String) -> String {
        let captionPatterns = [
            #"(?i)[\[(]\s*(?:blank_audio|blank audio|no audio|silence|breathing|sigh|click|typing|keyboard typing|laughter|laughs|music|applause|sound of [^\]\)]+)\s*[\])]"#,
            #"(?i)\*\s*(?:blank_audio|blank audio|no audio|silence|breathing|sigh|click|typing|keyboard typing|laughter|laughs|music|applause|sound of [^\*]+)\s*\*"#
        ]

        return captionPatterns.reduce(text) { partial, pattern in
            partial.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
    }

    private static func removeStandaloneDecoderBrackets(from text: String) -> String {
        text.replacingOccurrences(
            of: #"(?<!\S)[\[\]\{\}\(\)](?!\S)"#,
            with: " ",
            options: .regularExpression
        )
    }

    private static func collapseWhitespace(in text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func normalizePunctuation(in text: String) -> String {
        var result = text

        let replacements: [(String, String)] = [
            (#"\s+([,.!?;:])"#, "$1"),
            (#"([,;])(?=\S)"#, "$1 "),
            (#"(?<=[A-Za-z0-9])([.!?])(?=[A-Za-z])"#, "$1 "),
            (#"\.{2,}"#, "."),
            (#"!{2,}"#, "!"),
            (#"\?{2,}"#, "?")
        ]

        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }

        return result
    }

    private static func containsSpeechSignal(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic || scalar.properties.numericType != nil
        }
    }

    private static func capitalizeSentenceStarts(in text: String) -> String {
        var result = ""
        var shouldCapitalizeNextLetter = true

        for character in text {
            if shouldCapitalizeNextLetter, character.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) {
                result.append(String(character).uppercased())
                shouldCapitalizeNextLetter = false
                continue
            }

            result.append(character)

            if ".!?".contains(character) {
                shouldCapitalizeNextLetter = true
            } else if !character.isWhitespace {
                shouldCapitalizeNextLetter = false
            }
        }

        return result
    }
}
