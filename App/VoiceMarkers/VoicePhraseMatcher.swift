import Foundation
import Shared

struct VoicePhraseChange: Equatable, Sendable {
    let occurrenceID: UUID
    let rule: KeywordRule
    let source: LiveAudioSampleIdentity
    let startSample: Int64
    let endSample: Int64
    let precision: SpokenTimingPrecision
    let matchedPhrase: String
    let explanation: String
    let status: SpokenRecognitionStatus
}

/// Literal phrase recognition over bounded native timed text. This is not a
/// semantic trigger. Provisional revisions reconcile one-to-one with occurrences;
/// coincident coarse spans still preserve two separate textual utterances.
struct VoicePhraseMatcher {
    private let rules: [KeywordRule]
    private var spans: [VoiceRecognitionUpdate] = []
    private var occurrences: [VoicePhraseChange] = []
    private var generation: UUID?
    private var continuity: UUID?
    private var highWater: Int64 = 0
    private var finalizedThrough: Int64 = 0
    private static let horizon: Int64 = 16_000 * 360

    init(rules: [KeywordRule]) { self.rules = Array(rules.filter(\.enabled).prefix(128)) }

    var retainedOccurrenceIDs: Set<UUID> { Set(occurrences.map(\.occurrenceID)) }

    static func words(_ text: String) -> [String] {
        text.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    private struct Token {
        let word: String
        let timing: VoiceTimedToken
        let final: Bool
    }
    private struct Candidate {
        let rule: KeywordRule
        let start: Int64
        let end: Int64
        let precision: SpokenTimingPrecision
        let phrase: String
        let final: Bool
    }

    mutating func receive(_ update: VoiceRecognitionUpdate) throws -> [VoicePhraseChange] {
        guard update.source.isValid, update.startSample >= 0, update.endSample > update.startSample,
              update.endSample - update.startSample <= Self.horizon,
              update.text.utf8.count <= 65_536, update.tokens.count <= 2_048,
              update.tokens.allSatisfy({ $0.startSample >= update.startSample && $0.endSample <= update.endSample &&
                  $0.endSample > $0.startSample && $0.text.utf8.count <= 4_096 }) else {
            throw VoiceRecognitionError.invalidInput
        }
        if generation != update.source.recordingGeneration || continuity != update.source.continuityID {
            spans = []; occurrences = []; highWater = 0; finalizedThrough = 0
            generation = update.source.recordingGeneration; continuity = update.source.continuityID
        }
        highWater = max(highWater, update.endSample)
        let floor = max(0, highWater - Self.horizon)
        // Late results beyond retained reconciliation state cannot become new markers.
        guard update.startSample >= floor else { return [] }
        spans.removeAll { $0.endSample <= floor || ($0.startSample < update.endSample && $0.endSample > update.startSample) }
        spans.append(update)
        spans.sort { $0.startSample < $1.startSample }
        guard spans.count <= 512 else { throw VoiceRecognitionError.droppedInput }
        occurrences.removeAll { $0.endSample <= floor }
        let candidates = allCandidates()
        var used = Set<UUID>()
        var changed: [VoicePhraseChange] = []
        for candidate in candidates {
            let previous = occurrences.filter { old in
                old.rule.id == candidate.rule.id && !used.contains(old.occurrenceID) &&
                old.startSample < candidate.end && old.endSample > candidate.start
            }.min { abs($0.startSample - candidate.start) < abs($1.startSample - candidate.start) }
            let id = previous?.occurrenceID ?? UUID()
            used.insert(id)
            // A confirmed native anchor is immutable, including a later decoder revision.
            let confirmed = previous?.status == .confirmed
            let start = confirmed ? previous!.startSample : candidate.start
            let end = confirmed ? previous!.endSample : candidate.end
            let explanation = spans.filter { $0.endSample > end }.map(\.text).joined(separator: " ")
            let item = VoicePhraseChange(occurrenceID: id, rule: previous?.rule ?? candidate.rule,
                source: previous?.source ?? update.source, startSample: start, endSample: end,
                precision: confirmed ? previous!.precision : candidate.precision,
                matchedPhrase: confirmed ? previous!.matchedPhrase : candidate.phrase,
                explanation: Self.explanationExcerpt(explanation),
                status: confirmed || candidate.final || end <= finalizedThrough ? .confirmed : .provisional)
            if item != previous {
                occurrences.removeAll { $0.occurrenceID == id }; occurrences.append(item); changed.append(item)
            }
        }
        for old in occurrences where old.status == .provisional && !used.contains(old.occurrenceID) &&
            old.startSample < update.endSample && old.endSample > update.startSample {
            let withdrawn = VoicePhraseChange(occurrenceID: old.occurrenceID, rule: old.rule, source: old.source,
                startSample: old.startSample, endSample: old.endSample, precision: old.precision,
                matchedPhrase: old.matchedPhrase, explanation: old.explanation, status: .withdrawn)
            if let index = occurrences.firstIndex(where: { $0.occurrenceID == old.occurrenceID }) { occurrences[index] = withdrawn }
            changed.append(withdrawn)
        }
        guard occurrences.count <= 512 else { throw VoiceRecognitionError.droppedInput }
        return changed
    }

    mutating func finalize(recordingGeneration: UUID, continuityID: UUID, throughSample: Int64) -> [VoicePhraseChange] {
        guard generation == recordingGeneration, continuity == continuityID else { return [] }
        finalizedThrough = max(finalizedThrough, throughSample)
        var changes: [VoicePhraseChange] = []
        for index in occurrences.indices {
            let old = occurrences[index]
            guard old.status == .provisional, old.endSample <= finalizedThrough else { continue }
            let confirmed = VoicePhraseChange(occurrenceID: old.occurrenceID, rule: old.rule, source: old.source,
                startSample: old.startSample, endSample: old.endSample, precision: old.precision,
                matchedPhrase: old.matchedPhrase, explanation: old.explanation, status: .confirmed)
            occurrences[index] = confirmed; changes.append(confirmed)
        }
        return changes
    }

    private func allCandidates() -> [Candidate] {
        let tokens = spans.flatMap { span in span.tokens.flatMap { timed in
            let words = Self.words(timed.text)
            return words.enumerated().map { index, word in Token(word: word,
                timing: .init(text: word, startSample: timed.startSample, endSample: timed.endSample,
                    hasStartBoundary: timed.hasStartBoundary && index == 0,
                    hasEndBoundary: timed.hasEndBoundary && index == words.count - 1), final: span.isFinal) }
        } }
        var candidates: [Candidate] = []
        for rule in rules {
            let alternatives = ([rule.phrase] + rule.aliases).map { ($0, Self.words($0)) }
                .filter { !$0.1.isEmpty }.sorted { $0.1.count > $1.1.count }
            var index = 0
            while index < tokens.count {
                var matchedCount = 0
                for (phrase, words) in alternatives where index + words.count <= tokens.count {
                    let slice = Array(tokens[index..<(index + words.count)])
                    guard slice.map(\.word) == words, let first = slice.first, let last = slice.last,
                          last.timing.endSample >= first.timing.startSample else { continue }
                    // Prevent unrelated distant turns from completing one configured phrase.
                    guard zip(slice, slice.dropFirst()).allSatisfy({ $1.timing.startSample - $0.timing.endSample <= 160_000 }) else { continue }
                    candidates.append(.init(rule: rule, start: first.timing.startSample, end: last.timing.endSample,
                        precision: first.timing.hasStartBoundary && last.timing.hasEndBoundary ? .phraseAligned : .enclosingTimedSpan,
                        phrase: phrase, final: slice.allSatisfy(\.final)))
                    matchedCount = words.count; break
                }
                index += max(1, matchedCount)
            }
        }
        return candidates
    }

    /// The full source remains in recording/transcript storage. This rolling
    /// verbatim excerpt obeys the durable store's UTF-8 budget, including emoji.
    private static func explanationExcerpt(_ text: String) -> String {
        var bytes = Array(text.utf8.prefix(4_096))
        while !bytes.isEmpty {
            if let value = String(bytes: bytes, encoding: .utf8) { return value }
            bytes.removeLast()
        }
        return ""
    }

    #if DEBUG
    func matchesForTesting(_ text: String) -> [String] {
        let words = Self.words(text)
        return rules.filter { rule in ([rule.phrase] + rule.aliases).contains { Self.words($0) == words } }.map(\.name)
    }
    #endif
}
