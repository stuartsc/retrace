import Foundation

public enum SpokenTimingPrecision: String, Codable, Sendable { case phraseAligned, enclosingTimedSpan }
public enum SpokenRecognitionStatus: String, Codable, Sendable { case provisional, confirmed, withdrawn }

/// Exact offsets within microphone PCM continuity. The civil-clock origin remains approximate.
public struct SpokenMarkerAnchor: Codable, Equatable, Sendable {
    public let nativeStoreID: UUID
    public let source: AudioSource
    public let recordingGeneration: UUID
    public let continuityID: UUID
    public let sampleRate: Int
    public let startSample: Int64
    public let endSample: Int64
    public let approximateOrigin: Date
    public let timingPrecision: SpokenTimingPrecision

    public init(nativeStoreID: UUID, source: AudioSource = .microphone, recordingGeneration: UUID, continuityID: UUID,
                sampleRate: Int = 16_000, startSample: Int64, endSample: Int64, approximateOrigin: Date,
                timingPrecision: SpokenTimingPrecision) {
        self.nativeStoreID = nativeStoreID; self.source = source; self.recordingGeneration = recordingGeneration
        self.continuityID = continuityID; self.sampleRate = sampleRate; self.startSample = startSample
        self.endSample = endSample; self.approximateOrigin = approximateOrigin; self.timingPrecision = timingPrecision
    }

    /// Display placement only; it does not upgrade the wall clock to sample-accurate time.
    public var approximateStart: Date { approximateOrigin.addingTimeInterval(Double(startSample) / Double(sampleRate)) }
}

public struct SpokenObservationCommand: Codable, Equatable, Sendable {
    public let clientID: String
    public let requestID: UUID
    public let occurrenceID: UUID
    public let expectedRevision: UUID?
    public let status: SpokenRecognitionStatus
    public let anchor: SpokenMarkerAnchor
    public let ruleSnapshot: KeywordRule
    public let matchedPhrase: String
    public let explanation: String

    public init(clientID: String = "native-voice", requestID: UUID = UUID(), occurrenceID: UUID,
                expectedRevision: UUID? = nil, status: SpokenRecognitionStatus, anchor: SpokenMarkerAnchor,
                ruleSnapshot: KeywordRule, matchedPhrase: String, explanation: String) {
        self.clientID = clientID; self.requestID = requestID; self.occurrenceID = occurrenceID
        self.expectedRevision = expectedRevision; self.status = status; self.anchor = anchor
        self.ruleSnapshot = ruleSnapshot; self.matchedPhrase = matchedPhrase; self.explanation = explanation
    }
}

/// An immutable recognition revision. Confirmation says nothing about retained media availability.
public struct SpokenMarkerObservation: Codable, Equatable, Sendable {
    public let occurrenceID: UUID
    public let revision: UUID
    public let sequence: Int64
    public let status: SpokenRecognitionStatus
    public let anchor: SpokenMarkerAnchor
    public let ruleSnapshot: KeywordRule
    public let matchedPhrase: String
    public let explanation: String
    public let recordedAt: Date

    public init(occurrenceID: UUID, revision: UUID, sequence: Int64, status: SpokenRecognitionStatus,
                anchor: SpokenMarkerAnchor, ruleSnapshot: KeywordRule, matchedPhrase: String, explanation: String, recordedAt: Date) {
        self.occurrenceID = occurrenceID; self.revision = revision; self.sequence = sequence; self.status = status
        self.anchor = anchor; self.ruleSnapshot = ruleSnapshot; self.matchedPhrase = matchedPhrase
        self.explanation = explanation; self.recordedAt = recordedAt
    }
}

public struct SpokenMarkerReceipt: Codable, Equatable, Sendable {
    public let observation: SpokenMarkerObservation
    public let marker: TimelineMarker
    /// A user deletion permanently fences automatic projection changes for this occurrence.
    public let suppressed: Bool
    public init(observation: SpokenMarkerObservation, marker: TimelineMarker, suppressed: Bool) {
        self.observation = observation; self.marker = marker; self.suppressed = suppressed
    }
}

/// An immutable registration of an original AAC file and its exact source PCM slices.
/// Registration is metadata only; a reader must verify the file hash and decoded frames before playback.
public struct AudioMediaManifest: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let nativeStoreID: UUID
    public let source: AudioSource
    public let relativePath: String
    public let sha256: String
    public let frameCount: Int64
    public let sampleRate: Int
    public let sourceRanges: [AudioBatchSourceRange]

    public init(id: UUID = UUID(), nativeStoreID: UUID, source: AudioSource = .microphone,
                relativePath: String, sha256: String, frameCount: Int64, sampleRate: Int = 16_000,
                sourceRanges: [AudioBatchSourceRange]) {
        self.id = id; self.nativeStoreID = nativeStoreID; self.source = source; self.relativePath = relativePath
        self.sha256 = sha256; self.frameCount = frameCount; self.sampleRate = sampleRate; self.sourceRanges = sourceRanges
    }
}
