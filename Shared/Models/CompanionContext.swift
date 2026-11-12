import Foundation

public enum CompanionError: Error, Equatable, Sendable {
    case invalidPayload, nativeStoreMismatch, staleEvidence, staleMarker, closed
    case unsafeStorage, capacityExceeded, conflictingPublication, unavailable, transportRejected
}

/// Typed references remain native and source-qualified. Wall intervals are descriptive;
/// exact microphone identity is carried only by `media`.
public struct CompanionEvidenceReference: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case screen, transcript, v23Transcript, media }
    public let sourceStoreID: UUID
    public let kind: Kind
    public let screen: ScreenEvidenceRef?
    public let transcript: AudioEvidenceRef?
    public let v23Transcript: V23TranscriptReference?
    public let media: SpokenMarkerAnchor?
    public init(screen: ScreenEvidenceRef) {
        sourceStoreID = screen.storeID; kind = .screen; self.screen = screen; transcript = nil; v23Transcript = nil; media = nil
    }
    public init(transcript: AudioEvidenceRef) {
        sourceStoreID = transcript.storeID; kind = .transcript; screen = nil; self.transcript = transcript; v23Transcript = nil; media = nil
    }
    public init(media: SpokenMarkerAnchor) {
        sourceStoreID = media.nativeStoreID; kind = .media; screen = nil; transcript = nil; v23Transcript = nil; self.media = media
    }
    public init(v23Transcript: V23TranscriptReference) {
        sourceStoreID = v23Transcript.nativeStoreID; kind = .v23Transcript
        screen = nil; transcript = nil; self.v23Transcript = v23Transcript; media = nil
    }
    public func validate(storeID: UUID) throws {
        guard sourceStoreID == storeID else { throw CompanionError.nativeStoreMismatch }
        switch kind {
        case .screen:
            guard let ref = screen, transcript == nil, v23Transcript == nil, media == nil, ref.storeID == storeID,
                  ref.source == .native, ref.frameID.value > 0, ref.extractionRevision > 0,
                  ref.blockIDs.count <= 256, Set(ref.blockIDs).count == ref.blockIDs.count,
                  ref.blockIDs.allSatisfy({ $0 >= 0 }) else { throw CompanionError.invalidPayload }
        case .transcript:
            guard let ref = transcript, screen == nil, v23Transcript == nil, media == nil, ref.storeID == storeID,
                  ref.source == .native, ref.transcriptRevision > 0, ref.startTime.isFinite,
                  ref.endTime.isFinite, ref.startTime >= 0, ref.endTime >= ref.startTime else { throw CompanionError.invalidPayload }
            try CompanionBounds.text(ref.segmentID, max: 128)
        case .v23Transcript:
            guard let ref = v23Transcript, screen == nil, transcript == nil, media == nil,
                  ref.nativeStoreID == storeID, ref.version == 1, ref.rowID > 0,
                  ref.source == .microphone || ref.source == .system else { throw CompanionError.invalidPayload }
            try CompanionBounds.digest(ref.snapshotSHA256)
        case .media:
            guard let ref = media, screen == nil, transcript == nil, v23Transcript == nil, ref.nativeStoreID == storeID,
                  ref.source == .microphone, ref.sampleRate == 16_000, ref.startSample >= 0,
                  ref.endSample > ref.startSample, ref.endSample - ref.startSample <= 960_000 else { throw CompanionError.invalidPayload }
            try CompanionBounds.date(ref.approximateOrigin)
        }
    }
}

public struct CompanionEvidenceItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let reference: CompanionEvidenceReference
    public let start: Date
    public let end: Date
    public let text: String
    public let appName: String?
    public let windowTitle: String?
    public init(id: String, reference: CompanionEvidenceReference, start: Date, end: Date, text: String,
                appName: String? = nil, windowTitle: String? = nil) {
        self.id = id; self.reference = reference; self.start = start; self.end = end; self.text = text
        self.appName = appName; self.windowTitle = windowTitle
    }
}

/// A page comes from one current-policy native snapshot. The opaque cursor has no time-window meaning.
public struct CompanionEvidencePage: Sendable {
    public let snapshotID: UUID
    public let items: [CompanionEvidenceItem]
    public let nextCursor: String?
    public let developing: Bool
    public let incomplete: Bool
    public init(snapshotID: UUID, items: [CompanionEvidenceItem], nextCursor: String?, developing: Bool, incomplete: Bool) {
        self.snapshotID = snapshotID; self.items = items; self.nextCursor = nextCursor
        self.developing = developing; self.incomplete = incomplete
    }
}

public struct CompanionContextRequest: Codable, Equatable, Sendable {
    public let markerID: UUID
    public let markerRevision: UUID
    public let snapshotID: UUID
    public let query: String
    public let verbatimExplanation: String
    public let developing: Bool
    public let incomplete: Bool
    public let evidence: [CompanionEvidenceItem]
    public let expectedProposalHead: UUID?
    public init(markerID: UUID, markerRevision: UUID, snapshotID: UUID, query: String, verbatimExplanation: String,
                developing: Bool, incomplete: Bool, evidence: [CompanionEvidenceItem], expectedProposalHead: UUID? = nil) {
        self.markerID = markerID; self.markerRevision = markerRevision; self.snapshotID = snapshotID; self.query = query
        self.verbatimExplanation = verbatimExplanation; self.developing = developing; self.incomplete = incomplete; self.evidence = evidence
        self.expectedProposalHead = expectedProposalHead
    }
}

/// Exact slices of original verified AAC objects; no file paths cross the transport.
public struct CompanionMediaSlice: Codable, Equatable, Sendable {
    public let sha256: String
    public let byteCount: Int
    public let mediaID: String
    public let offsetSamples: Int64
    public let countSamples: Int64
    public let sourceStartSample: Int64
    public init(sha256: String, byteCount: Int, mediaID: String, offsetSamples: Int64, countSamples: Int64, sourceStartSample: Int64) {
        self.sha256 = sha256; self.byteCount = byteCount; self.mediaID = mediaID
        self.offsetSamples = offsetSamples; self.countSamples = countSamples; self.sourceStartSample = sourceStartSample
    }
}

public struct CompanionSpeakerRequest: Codable, Equatable, Sendable {
    public let sourceIdentity: LiveAudioSampleIdentity
    /// Original first-pass batch scope when overlapping leading PCM was already queued.
    /// Text remains verbatim and is not claimed to be aligned to the trimmed inference span.
    public let firstPassSourceIdentity: LiveAudioSampleIdentity?
    public let firstPassText: String
    /// Exact ordered original V23 rows. Later refinement may coexist; deletion or
    /// any edit to these rows revokes publication and presentation of this request.
    public let firstPassReferences: [V23TranscriptReference]
    public let media: [CompanionMediaSlice]
    public init(sourceIdentity: LiveAudioSampleIdentity, firstPassText: String, media: [CompanionMediaSlice],
                firstPassReferences: [V23TranscriptReference], firstPassSourceIdentity: LiveAudioSampleIdentity? = nil) {
        self.sourceIdentity = sourceIdentity; self.firstPassText = firstPassText; self.media = media
        self.firstPassReferences = firstPassReferences
        self.firstPassSourceIdentity = firstPassSourceIdentity
    }
}

public struct CompanionJobRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case context, speaker }
    public let version: Int
    public let kind: Kind
    public let sourceStoreID: UUID
    public let observedAt: Date
    public let context: CompanionContextRequest?
    public let speaker: CompanionSpeakerRequest?
    public init(sourceStoreID: UUID, observedAt: Date, context: CompanionContextRequest) {
        version = 1; kind = .context; self.sourceStoreID = sourceStoreID; self.observedAt = observedAt; self.context = context; speaker = nil
    }
    public init(sourceStoreID: UUID, observedAt: Date, speaker: CompanionSpeakerRequest) {
        version = 1; kind = .speaker; self.sourceStoreID = sourceStoreID; self.observedAt = observedAt; context = nil; self.speaker = speaker
    }
    public func validate() throws {
        guard version == 1 else { throw CompanionError.invalidPayload }
        try CompanionBounds.date(observedAt)
        switch kind {
        case .context:
            guard let context, speaker == nil, context.evidence.count <= 256,
                  Set(context.evidence.map(\.id)).count == context.evidence.count else { throw CompanionError.invalidPayload }
            try CompanionBounds.text(context.query, max: 8192)
            try CompanionBounds.text(context.verbatimExplanation, max: 16384, empty: true)
            var total = 0
            for item in context.evidence {
                try CompanionBounds.text(item.id, max: 160)
                try CompanionBounds.text(item.text, max: 8192)
                try CompanionBounds.date(item.start); try CompanionBounds.date(item.end)
                guard item.start <= item.end else { throw CompanionError.invalidPayload }
                try item.reference.validate(storeID: sourceStoreID)
                if let name = item.appName { try CompanionBounds.text(name, max: 512, empty: true) }
                if let title = item.windowTitle { try CompanionBounds.text(title, max: 512, empty: true) }
                total += item.text.utf8.count
            }
            guard total <= 512 * 1024 else { throw CompanionError.invalidPayload }
        case .speaker:
            guard let speaker, context == nil, speaker.sourceIdentity.isValid,
                  (1...32).contains(speaker.media.count) else { throw CompanionError.invalidPayload }
            try CompanionBounds.date(speaker.sourceIdentity.approximateOrigin)
            if let original = speaker.firstPassSourceIdentity {
                let exact = speaker.sourceIdentity
                guard original.isValid, original.recordingGeneration == exact.recordingGeneration,
                      original.continuityID == exact.continuityID, original.approximateOrigin == exact.approximateOrigin,
                      original.startSample <= exact.startSample,
                      original.startSample + original.sampleCount >= exact.startSample + exact.sampleCount else { throw CompanionError.invalidPayload }
            }
            try CompanionBounds.text(speaker.firstPassText, max: 128 * 1024, empty: true)
            guard (1...1024).contains(speaker.firstPassReferences.count),
                  Set(speaker.firstPassReferences.map(\.rowID)).count == speaker.firstPassReferences.count else { throw CompanionError.invalidPayload }
            for reference in speaker.firstPassReferences {
                guard reference.nativeStoreID == sourceStoreID, reference.version == 1,
                      reference.source == .microphone, reference.rowID > 0,
                      reference.recordingGeneration == nil else { throw CompanionError.invalidPayload }
                try CompanionBounds.digest(reference.snapshotSHA256)
            }
            var cursor = speaker.sourceIdentity.startSample
            for item in speaker.media {
                try CompanionBounds.digest(item.sha256); try CompanionBounds.digest(item.mediaID)
                guard (1...16 * 1024 * 1024).contains(item.byteCount), item.sourceStartSample == cursor,
                      item.offsetSamples >= 0, item.offsetSamples < 1_920_000, item.countSamples > 0,
                      item.countSamples <= 1_920_000 - item.offsetSamples,
                      cursor <= Int64.max - item.countSamples else { throw CompanionError.invalidPayload }
                cursor += item.countSamples
            }
            guard cursor == speaker.sourceIdentity.startSample + speaker.sourceIdentity.sampleCount else { throw CompanionError.invalidPayload }
        }
    }
}

public struct CompanionProposedRange: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let start: Date
    public let end: Date
    public let explanation: String
    public let supportIDs: [String]
    public let score: Double
    public init(id: UUID, start: Date, end: Date, explanation: String, supportIDs: [String], score: Double) {
        self.id = id; self.start = start; self.end = end; self.explanation = explanation; self.supportIDs = supportIDs; self.score = score
    }
}
public extension CompanionProposedRange {
    /// Current ranking copies one exact support. A future generated explanation must
    /// declare all of its dependencies instead of claiming this single-support contract.
    static func supportedExplanation(_ support: CompanionEvidenceItem) -> String {
        support.text.utf8.count <= 4096 ? support.text :
            "Local semantic ranking selected exact supporting evidence " + support.id +
            ". The complete excerpt is retained with the proposal."
    }
}
public struct CompanionContextProposal: Codable, Equatable, Sendable {
    public let markerID: UUID
    public let markerRevision: UUID
    public let snapshotID: UUID
    public let verbatimExplanation: String
    public let developing: Bool
    public let incomplete: Bool
    public let ranges: [CompanionProposedRange]
    public let method: String
    public init(markerID: UUID, markerRevision: UUID, snapshotID: UUID, verbatimExplanation: String,
                developing: Bool, incomplete: Bool, ranges: [CompanionProposedRange], method: String) {
        self.markerID = markerID; self.markerRevision = markerRevision; self.snapshotID = snapshotID
        self.verbatimExplanation = verbatimExplanation; self.developing = developing; self.incomplete = incomplete
        self.ranges = ranges; self.method = method
    }
}
public struct CompanionSpeakerTurn: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case unknown, suggested, overlap }
    public let start: Double
    public let end: Double
    public let text: String
    public let speakerID: String
    public let speakerLabel: String
    public let speakerStatus: Status
    public let candidateName: String?
    public let personID: String?
    public let similarity: Double?
    public init(start: Double, end: Double, text: String, speakerID: String, speakerLabel: String,
                speakerStatus: Status, candidateName: String? = nil, personID: String? = nil, similarity: Double? = nil) {
        self.start = start; self.end = end; self.text = text; self.speakerID = speakerID
        self.speakerLabel = speakerLabel; self.speakerStatus = speakerStatus; self.candidateName = candidateName
        self.personID = personID; self.similarity = similarity
    }
}
public struct CompanionSpeakerEnrichment: Codable, Equatable, Sendable {
    public let sourceIdentity: LiveAudioSampleIdentity
    public let firstPassSHA256: String
    public let enhancedText: String
    public let turns: [CompanionSpeakerTurn]
    /// Always false until a separately reviewed held-out >=98% precision receipt exists.
    public let automaticNamesCalibrated: Bool
    public let modelFingerprint: String
    public init(sourceIdentity: LiveAudioSampleIdentity, firstPassSHA256: String, enhancedText: String,
                turns: [CompanionSpeakerTurn], automaticNamesCalibrated: Bool, modelFingerprint: String) {
        self.sourceIdentity = sourceIdentity; self.firstPassSHA256 = firstPassSHA256; self.enhancedText = enhancedText
        self.turns = turns; self.automaticNamesCalibrated = automaticNamesCalibrated; self.modelFingerprint = modelFingerprint
    }
}
public struct CompanionResult: Codable, Equatable, Sendable {
    public let version: Int
    public let jobID: String
    public let kind: CompanionJobRequest.Kind
    public let sourceStoreID: UUID
    public let contextProposal: CompanionContextProposal?
    public let speakerEnrichment: CompanionSpeakerEnrichment?
    public init(jobID: String, sourceStoreID: UUID, contextProposal: CompanionContextProposal) {
        version = 1; self.jobID = jobID; kind = .context; self.sourceStoreID = sourceStoreID
        self.contextProposal = contextProposal; speakerEnrichment = nil
    }
}

public enum CompanionBounds {
    public static func text(_ value: String, max: Int, empty: Bool = false) throws {
        guard value.utf8.count <= max, !value.contains("\0"), empty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CompanionError.invalidPayload }
    }
    public static func date(_ value: Date) throws {
        guard value.timeIntervalSince1970.isFinite, value.timeIntervalSince1970 > 0,
              value.timeIntervalSince1970 < 253_402_300_000 else { throw CompanionError.invalidPayload }
    }
    public static func digest(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CompanionError.invalidPayload }
    }
}

/// V23 has mutable transcript rows, not V30 immutable transcript revisions.
/// A current full-row digest and canonical store/source identity must match on every use.
/// Legacy rows have no proven recording generation, including after restart.
public struct V23TranscriptReference: Codable, Equatable, Sendable {
    public let version: Int
    public let nativeStoreID: UUID
    public let source: AudioSource
    public let rowID: Int64
    public let snapshotSHA256: String
    public let recordingGeneration: UUID?
    public init(nativeStoreID: UUID, source: AudioSource, rowID: Int64, snapshotSHA256: String, recordingGeneration: UUID? = nil) {
        version = 1; self.nativeStoreID = nativeStoreID; self.source = source; self.rowID = rowID
        self.snapshotSHA256 = snapshotSHA256; self.recordingGeneration = recordingGeneration
    }
}

public struct CompanionSpeakerCorrectionCommand: Codable, Equatable, Sendable {
    public let clientID: String
    public let requestID: UUID
    public let jobID: String
    public let speakerID: String
    public let displayName: String?
    public let personID: String?
    public let expectedRevision: UUID?
    public init(clientID: String = "native-ui", requestID: UUID = UUID(), jobID: String, speakerID: String,
                displayName: String?, personID: String? = nil, expectedRevision: UUID?) {
        self.clientID = clientID; self.requestID = requestID; self.jobID = jobID; self.speakerID = speakerID
        self.displayName = displayName; self.personID = personID; self.expectedRevision = expectedRevision
    }
}
public struct CompanionSpeakerCorrection: Codable, Equatable, Sendable {
    public let nativeStoreID: UUID
    public let speakerID: String
    public let sourceIdentity: LiveAudioSampleIdentity
    public let revision: UUID
    public let displayName: String?
    public let personID: String?
    public let updatedAt: Date
    public init(nativeStoreID: UUID, speakerID: String, sourceIdentity: LiveAudioSampleIdentity, revision: UUID,
                displayName: String?, personID: String?, updatedAt: Date) {
        self.nativeStoreID = nativeStoreID; self.speakerID = speakerID; self.sourceIdentity = sourceIdentity
        self.revision = revision; self.displayName = displayName; self.personID = personID; self.updatedAt = updatedAt
    }
}
public struct CompanionSpeakerPresentation: Sendable {
    public let jobID: String
    public let nativeStoreID: UUID
    public let firstPassText: String
    public let firstPassSourceIdentity: LiveAudioSampleIdentity
    public let enhancement: CompanionSpeakerEnrichment
    public let corrections: [CompanionSpeakerCorrection]
    public let sourceDependencies: NativeSourceDependencies
    public let firstPassReferences: [V23TranscriptReference]
    /// Matches enhancement.turns by index. A caller still resolves each reference before an action.
    public let turnReferences: [CompanionTurnReference]
    public init(jobID: String, nativeStoreID: UUID, firstPassText: String, enhancement: CompanionSpeakerEnrichment,
                corrections: [CompanionSpeakerCorrection], firstPassSourceIdentity: LiveAudioSampleIdentity? = nil,
                sourceDependencies: NativeSourceDependencies = .unknown,
                firstPassReferences: [V23TranscriptReference] = [], turnReferences: [CompanionTurnReference] = []) {
        self.jobID = jobID; self.nativeStoreID = nativeStoreID; self.firstPassText = firstPassText
        self.enhancement = enhancement; self.corrections = corrections
        self.firstPassSourceIdentity = firstPassSourceIdentity ?? enhancement.sourceIdentity
        self.sourceDependencies = sourceDependencies
        self.firstPassReferences = firstPassReferences; self.turnReferences = turnReferences
    }
}
public struct CompanionSpeakerPage: Sendable {
    public let items: [CompanionSpeakerPresentation]
    public let nextCursor: String?
    public let incomplete: Bool
    public init(items: [CompanionSpeakerPresentation], nextCursor: String?, incomplete: Bool) {
        self.items = items; self.nextCursor = nextCursor; self.incomplete = incomplete
    }
}
