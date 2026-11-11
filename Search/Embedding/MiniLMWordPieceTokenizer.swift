import CryptoKit
import Foundation

struct MiniLMToken: Equatable, Sendable {
    let id: Int32
    let utf16Location: Int
    let utf16Length: Int
}

struct MiniLMTokenWindow: Sendable {
    let tokenStart: Int
    let tokenEnd: Int
    let utf16Location: Int
    let utf16Length: Int
    let content: [MiniLMToken]

    var inputIDs: [Int32] {
        [101] + content.map(\.id) + [102] + [Int32](repeating: 0, count: 254 - content.count)
    }
    var attentionMask: [Int32] {
        [Int32](repeating: 1, count: content.count + 2) + [Int32](repeating: 0, count: 254 - content.count)
    }
}

/// The checked tokenizer is the exact pinned BertNormalizer/BertPreTokenizer/
/// WordPiece vocabulary, not a tokenizer inferred from arbitrary model metadata.
/// Original UTF-16 offsets survive normalization and complete overlapping windows.
struct MiniLMWordPieceTokenizer: Sendable {
    static let tokenizerSHA256 = "be50c3628f2bf5bb5e3a7f17b1f74611b2561a3a27eeab05e5aa30f411572037"
    static let maximumInputUTF16 = 32_768
    enum Failure: Error { case invalidTokenizer, inputTooLarge }
    private let vocabulary: [String: Int32]
    private let special: [([Unicode.Scalar], Int32)]

    init(data: Data) throws {
        guard data.count == 466_247,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == Self.tokenizerSHA256 else {
            throw Failure.invalidTokenizer
        }
        struct Configuration: Decodable {
            struct Model: Decodable { let vocab: [String: Int32] }
            let model: Model
        }
        vocabulary = try JSONDecoder().decode(Configuration.self, from: data).model.vocab
        guard vocabulary.count == 30_522 else { throw Failure.invalidTokenizer }
        special = [("[PAD]", 0), ("[UNK]", 100), ("[CLS]", 101), ("[SEP]", 102), ("[MASK]", 103)]
            .map { (Array($0.0.unicodeScalars), Int32($0.1)) }
    }

    func windows(_ text: String) throws -> [MiniLMTokenWindow] {
        let tokens = try tokenize(text)
        let source = Array(text.utf16)
        var result: [MiniLMTokenWindow] = []
        var start = 0
        while start < tokens.count {
            try Task.checkCancellation()
            var end = min(start + 224, tokens.count)
            if end < tokens.count {
                let lower = max(start + 33, end - 48)
                for candidate in stride(from: end, through: lower, by: -1) {
                    let previous = tokens[candidate - 1]
                    let next = tokens[candidate]
                    let previousEnd = previous.utf16Location + previous.utf16Length
                    let hasNewline = previousEnd <= next.utf16Location &&
                        source[previousEnd..<next.utf16Location].contains(10)
                    let punctuation: Set<UInt16> = [46, 33, 63, 59]
                    let endsSentence = previousEnd > previous.utf16Location &&
                        punctuation.contains(source[previousEnd - 1])
                    if hasNewline || endsSentence { end = candidate; break }
                }
            }
            let first = start == 0 ? 0 : tokens[start].utf16Location
            let last = end == tokens.count ? source.count : tokens[end].utf16Location
            result.append(.init(tokenStart: start, tokenEnd: end,
                                utf16Location: first, utf16Length: last - first,
                                content: Array(tokens[start..<end])))
            if end == tokens.count { break }
            start = end - 32
        }
        return result
    }

    private struct Scalar {
        let value: Unicode.Scalar
        let start: Int
        let end: Int
    }

    func tokenize(_ text: String) throws -> [MiniLMToken] {
        guard text.utf16.prefix(Self.maximumInputUTF16 + 1).count <= Self.maximumInputUTF16 else {
            throw Failure.inputTooLarge
        }
        try Task.checkCancellation()
        let source = Array(text.unicodeScalars)
        var position = 0
        let offsets = source.map { scalar -> Int in
            defer { position += scalar.value > 0xffff ? 2 : 1 }
            return position
        } + [position]
        var result: [MiniLMToken] = []
        var ordinary: [Scalar] = []
        var index = 0
        func flush() { appendBasic(ordinary, to: &result); ordinary.removeAll(keepingCapacity: true) }
        while index < source.count {
            if index % 256 == 0 { try Task.checkCancellation() }
            if let match = special.first(where: { token, _ in
                index + token.count <= source.count && source[index..<(index + token.count)].elementsEqual(token)
            }) {
                flush()
                let end = index + match.0.count
                result.append(.init(id: match.1, utf16Location: offsets[index], utf16Length: offsets[end] - offsets[index]))
                index = end
            } else {
                ordinary.append(.init(value: source[index], start: offsets[index], end: offsets[index + 1]))
                index += 1
            }
        }
        flush()
        return result
    }

    private func appendBasic(_ source: [Scalar], to output: inout [MiniLMToken]) {
        var word: [Scalar] = []
        func flush() { appendPieces(word, to: &output); word.removeAll(keepingCapacity: true) }
        for sourceScalar in source {
            let scalar = sourceScalar.value
            if scalar.value == 0 || scalar.value == 0xfffd || Self.isControl(scalar) { continue }
            if Self.isWhitespace(scalar) { flush(); continue }
            if Self.isChinese(scalar) {
                flush(); appendPieces([sourceScalar], to: &output); continue
            }
            // BertNormalizer lowercases then applies canonical decomposition and
            // removes Mn only. Each normalized scalar retains its original span.
            for value in String(scalar).lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
                if value.properties.generalCategory == .nonspacingMark { continue }
                let normalized = Scalar(value: value, start: sourceScalar.start, end: sourceScalar.end)
                if Self.isPunctuation(value) {
                    flush(); appendPieces([normalized], to: &output)
                } else {
                    word.append(normalized)
                }
            }
        }
        flush()
    }

    private func appendPieces(_ word: [Scalar], to output: inout [MiniLMToken]) {
        guard let first = word.first, let last = word.last else { return }
        func unknown() { output.append(.init(id: 100, utf16Location: first.start, utf16Length: last.end - first.start)) }
        guard word.count <= 100 else { unknown(); return }
        var start = 0
        var pieces: [MiniLMToken] = []
        while start < word.count {
            var end = word.count
            var found: MiniLMToken?
            while start < end {
                let value = String(String.UnicodeScalarView(word[start..<end].map(\.value)))
                if let id = vocabulary[(start == 0 ? "" : "##") + value] {
                    found = .init(id: id, utf16Location: word[start].start,
                                  utf16Length: word[end - 1].end - word[start].start)
                    break
                }
                end -= 1
            }
            guard let found else { unknown(); return }
            pieces.append(found); start = end
        }
        output.append(contentsOf: pieces)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        if [9, 10, 13].contains(scalar.value) { return false }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse: return true
        default: return false
        }
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let code = scalar.value
        if (33...47).contains(code) || (58...64).contains(code) || (91...96).contains(code) || (123...126).contains(code) { return true }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }

    private static func isChinese(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x4e00...0x9fff).contains(value) || (0x3400...0x4dbf).contains(value) ||
            (0x20000...0x2a6df).contains(value) || (0x2a700...0x2b73f).contains(value) ||
            (0x2b740...0x2b81f).contains(value) || (0x2b920...0x2ceaf).contains(value) ||
            (0xf900...0xfaff).contains(value) || (0x2f800...0x2fa1f).contains(value)
    }
}
