import Foundation

/// Exact native microphone samples. Civil-clock origin is callback-anchored and approximate.
/// This is a media coordinate, never a marker or a permission to read a recording.
public struct NativeAudioSampleRange: Equatable, Sendable {
    public let nativeStoreID: UUID
    public let source: AudioSource
    public let identity: LiveAudioSampleIdentity
    public init(nativeStoreID: UUID, source: AudioSource = .microphone, identity: LiveAudioSampleIdentity) {
        self.nativeStoreID = nativeStoreID; self.source = source; self.identity = identity
    }
}

/// A selected immutable inference turn and the exact manual-name revision shown to the user.
/// Anonymous cluster identities are scoped to their retained job; labels are not person IDs.
public struct CompanionTurnReference: Codable, Hashable, Sendable {
    public let version: Int
    public let nativeStoreID: UUID
    public let jobID: String
    public let resultSHA256: String
    public let turnIndex: Int
    public let correctionRevision: UUID?
    public init(nativeStoreID: UUID, jobID: String, resultSHA256: String, turnIndex: Int, correctionRevision: UUID?) {
        version = 1; self.nativeStoreID = nativeStoreID; self.jobID = jobID
        self.resultSHA256 = resultSHA256; self.turnIndex = turnIndex; self.correctionRevision = correctionRevision
    }
    public func validate() throws {
        guard version == 1, (0..<4096).contains(turnIndex) else { throw CompanionError.invalidPayload }
        try CompanionBounds.digest(jobID); try CompanionBounds.digest(resultSHA256)
    }
}

public enum CompanionTurnSpeakerStatus: String, Sendable { case anonymous, manualName, suggestion, overlap, unknown }

public struct CompanionTurnPresentation: Sendable {
    public let reference: CompanionTurnReference
    public let turn: CompanionSpeakerTurn
    /// Enclosing source samples derived from model-estimated offsets, not measured word alignment.
    public let sourceIdentity: LiveAudioSampleIdentity
    public let displayLabel: String
    public let speakerStatus: CompanionTurnSpeakerStatus
    public let firstPassText: String
    public let firstPassSourceIdentity: LiveAudioSampleIdentity
    public let firstPassReferences: [V23TranscriptReference]
    public let sourceDependencies: NativeSourceDependencies
    public var expectedCorrectionRevision: UUID? { reference.correctionRevision }
    public var approximateStart: Date { sourceIdentity.approximateOrigin.addingTimeInterval(Double(sourceIdentity.startSample) / 16_000) }
    public var approximateEnd: Date { approximateStart.addingTimeInterval(Double(sourceIdentity.sampleCount) / 16_000) }
    public init(reference: CompanionTurnReference, turn: CompanionSpeakerTurn, sourceIdentity: LiveAudioSampleIdentity,
                displayLabel: String, speakerStatus: CompanionTurnSpeakerStatus, firstPassText: String,
                firstPassSourceIdentity: LiveAudioSampleIdentity, firstPassReferences: [V23TranscriptReference],
                sourceDependencies: NativeSourceDependencies = .unknown) {
        self.reference = reference; self.turn = turn; self.sourceIdentity = sourceIdentity
        self.displayLabel = displayLabel; self.speakerStatus = speakerStatus; self.firstPassText = firstPassText
        self.firstPassSourceIdentity = firstPassSourceIdentity; self.firstPassReferences = firstPassReferences
        self.sourceDependencies = sourceDependencies
    }
}

/// Cheap process-local invalidation. Source callbacks must never wait for native playback or SQLite.
public enum CompanionSpeakerChange: Sendable {
    case all
    case source(NativeSourceMutation)
    case correction(jobID: String, speakerID: String)
}
