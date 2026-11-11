import Foundation

/// Content-free receipt emitted after sentence rows commit. It is a transcription
/// quality decision, not physical speech proof or an exact audio evidence reference.
public struct AudioTranscriptCommitReceipt: Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let source: AudioSource
    public let acceptedTranscription: Bool
    public init(startedAt: Date, endedAt: Date, source: AudioSource, acceptedTranscription: Bool) {
        self.startedAt = startedAt; self.endedAt = endedAt; self.source = source
        self.acceptedTranscription = acceptedTranscription
    }
}
