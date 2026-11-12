import Foundation

/// Provenance of converted microphone PCM. Offsets are exact within one native
/// continuity interval. The first wall date is callback-anchored and approximate;
/// it must not be presented as a sample-accurate civil-clock measurement.
public struct LiveAudioSampleIdentity: Codable, Equatable, Sendable {
    public let recordingGeneration: UUID
    public let continuityID: UUID
    public let startSample: Int64
    public let sampleCount: Int64
    public let sampleRate: Int
    public let approximateOrigin: Date

    public init(recordingGeneration: UUID, continuityID: UUID, startSample: Int64,
                sampleCount: Int64, sampleRate: Int, approximateOrigin: Date) {
        self.recordingGeneration = recordingGeneration
        self.continuityID = continuityID
        self.startSample = startSample
        self.sampleCount = sampleCount
        self.sampleRate = sampleRate
        self.approximateOrigin = approximateOrigin
    }

    public var isValid: Bool {
        startSample >= 0 && sampleCount > 0 && sampleCount <= 16_000 * 60 &&
        startSample <= Int64.max - sampleCount && sampleRate == 16_000 &&
        approximateOrigin.timeIntervalSince1970.isFinite
    }
}

/// A slice of source PCM in a persisted batch. Several entries may refer to
/// different continuity intervals; adjacency in the file never proves continuity.
public struct AudioBatchSourceRange: Codable, Equatable, Sendable {
    public let source: LiveAudioSampleIdentity
    public let batchStartSample: Int64

    public init(source: LiveAudioSampleIdentity, batchStartSample: Int64) {
        self.source = source
        self.batchStartSample = batchStartSample
    }
}
