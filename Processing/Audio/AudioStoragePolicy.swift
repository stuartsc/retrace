import Foundation

/// Keeps transcript records anchored to the canonical raw batch instead of
/// materializing duplicate sentence-level audio files.
public enum AudioStoragePolicy {
    public static func canonicalTranscriptPath(batchAudioPath: String?) -> String? {
        guard let batchAudioPath else { return nil }
        let trimmed = batchAudioPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : batchAudioPath
    }
}
