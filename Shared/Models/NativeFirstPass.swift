import Foundation

/// Ephemeral proof created only after the canonical AAC file and pending row
/// commit. Restart loses this optimisation, never the pending recording.
public struct NativeFirstPassBatch: Sendable, Equatable {
    public let rawBatchID: Int64
    public let relativePath: String
    public let encodedSHA256: String
    public let frameCount: Int64
    public let range: AudioBatchSourceRange
    public init?(rawBatchID: Int64, relativePath: String, encodedSHA256: String,
                 frameCount: Int64, source: AudioSource, sampleRate: Int, channels: Int,
                 ranges: [AudioBatchSourceRange], mappingIncomplete: Bool) {
        guard rawBatchID > 0, !relativePath.isEmpty, source == .microphone,
              sampleRate == 16_000, channels == 1, !mappingIncomplete,
              frameCount > 0, frameCount <= 16_000 * 60,
              ranges.count == 1, let range = ranges.first,
              range.batchStartSample == 0, range.source.isValid,
              range.source.sampleCount == frameCount,
              encodedSHA256.utf8.count == 64,
              encodedSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.rawBatchID = rawBatchID; self.relativePath = relativePath
        self.encodedSHA256 = encodedSHA256; self.frameCount = frameCount; self.range = range
    }
}

/// Native finalization is sufficient for an unrefined first pass, not a claim
/// that recognition is accurate. CPU correction remains independently pending.
public struct NativeFirstPassText: Sendable {
    public let batch: NativeFirstPassBatch
    public let text: String
    public init(batch: NativeFirstPassBatch, text: String) { self.batch = batch; self.text = text }
}
