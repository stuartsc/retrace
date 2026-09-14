import Foundation
import CryptoKit

/// Conservative capture policy, applied before metadata enters a cache, database or log.
/// No query/fragment field is presumed public. Opaque navigation identity is local metadata.
public enum CapturedURLPolicy {
    public static func sanitizeLabel(_ label: String?) -> String? {
        guard let label else { return nil }
        let bounded = String(label.prefix(4096))
        guard let regex = try? NSRegularExpression(pattern: "(?i)(?:https?|file)://[^\\s<>]+") else { return nil }
        var result = bounded
        for match in regex.matches(in: bounded, range: NSRange(bounded.startIndex..., in: bounded)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: sanitize(String(result[range])) ?? "[URL omitted]")
        }
        return result
    }

    public static func sanitize(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count <= 16_384 else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["http", "https", "file"].contains(scheme),
              scheme == "file" || components.host?.isEmpty == false else { return nil }
        components.user = nil; components.password = nil
        components.query = nil; components.fragment = nil
        var decodedPath = components.percentEncodedPath
        for _ in 0..<4 {
            guard let decoded = decodedPath.removingPercentEncoding, decoded != decodedPath else { break }
            decodedPath = decoded
        }
        let parts = decodedPath.lowercased().split(separator: "/").map(String.init)
        let secretNames = ["token", "credential", "signature", "password", "secret", "oauth", "sso", "magic-link", "invite", "reset", "auth", "session"]
        let hasSecretPath = parts.contains { part in secretNames.contains(where: { part.contains($0) }) }
        let hasOpaquePath = parts.contains { part in
            if UUID(uuidString: part) != nil { return true }
            let hasDigit = part.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
            let hasLetter = part.unicodeScalars.contains { CharacterSet.letters.contains($0) }
            return part.count >= 48 || (part.count >= 24 && hasDigit && hasLetter)
                || part.hasPrefix("eyj") || part.contains("%")
        }
        if hasSecretPath || hasOpaquePath { components.path = "/" }
        return components.string
    }

    public static func navigationIdentity(_ raw: String) -> String {
        "navigation:" + SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
