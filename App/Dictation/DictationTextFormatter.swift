import Foundation

public enum DictationTextFormatter {
    public static func formatted(_ text: String) -> String? {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !collapsed.isEmpty else { return nil }

        var result = collapsed
        if let first = result.first {
            result.replaceSubrange(result.startIndex...result.startIndex, with: String(first).uppercased())
        }

        if let last = result.last, !".!?".contains(last) {
            result.append(".")
        }

        return result
    }
}
