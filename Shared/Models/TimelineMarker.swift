import Foundation

/// An explicit manual marker command. It invents no audio identity.
public struct ManualTimelineMarkerCommand: Codable, Equatable, Sendable {
    public let clientID: String
    public let requestID: UUID
    public let anchoredAt: Date
    public let title: String
    public let note: String?
    public let screenReference: ScreenEvidenceRef?

    public init(clientID: String = "native-ui", requestID: UUID = UUID(), anchoredAt: Date,
                title: String = "Marked moment", note: String? = nil, screenReference: ScreenEvidenceRef? = nil) {
        self.clientID = clientID; self.requestID = requestID; self.anchoredAt = anchoredAt
        self.title = title; self.note = note; self.screenReference = screenReference
    }
}

/// Edits presentation fields only. The original phrase/media anchor and verbatim
/// recognition history cannot be supplied or replaced by an editing client.
public struct TimelineMarkerEditCommand: Codable, Equatable, Sendable {
    public let clientID: String
    public let requestID: UUID
    public let id: UUID
    public let expectedRevision: UUID
    public let title: String
    public let note: String?

    public init(clientID: String = "native-ui", requestID: UUID = UUID(), id: UUID,
                expectedRevision: UUID, title: String, note: String?) {
        self.clientID = clientID; self.requestID = requestID; self.id = id
        self.expectedRevision = expectedRevision; self.title = title; self.note = note
    }
}

public struct TimelineMarker: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let revision: UUID
    public let nativeStoreID: UUID
    public let anchoredAt: Date
    public let title: String
    public let note: String?
    /// An exact reference supplied by the policy owner; persistence does not assert current visibility.
    public let screenReference: ScreenEvidenceRef?
    public let createdAt: Date
    public let deletedAt: Date?
    /// Optional for compatibility with manual markers and existing version-1 payloads.
    public let spokenObservation: SpokenMarkerObservation?
    /// Optional for old records. Later recognition revisions preserve these user edits.
    public let userEditedAt: Date?

    public init(id: UUID, revision: UUID, nativeStoreID: UUID, anchoredAt: Date, title: String,
                note: String?, screenReference: ScreenEvidenceRef?, createdAt: Date, deletedAt: Date? = nil,
                spokenObservation: SpokenMarkerObservation? = nil, userEditedAt: Date? = nil) {
        self.id = id; self.revision = revision; self.nativeStoreID = nativeStoreID; self.anchoredAt = anchoredAt
        self.title = title; self.note = note; self.screenReference = screenReference
        self.createdAt = createdAt; self.deletedAt = deletedAt
        self.spokenObservation = spokenObservation
        self.userEditedAt = userEditedAt
    }
}

public enum MarkerContextOwnership: String, Codable, Sendable {
    case proposed, manual, pinned
}

/// Each range has its own revision. Saving a range never changes the marker's revision.
public struct MarkerContextRange: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let revision: UUID
    public let start: Date
    public let end: Date
    public let explanation: String
    public let ownership: MarkerContextOwnership
    public let explanationOrigin: ContextExplanationOrigin?
    public let provenance: MarkerContextProvenance?
    public let userNote: String?
    public var effectiveExplanationOrigin: ContextExplanationOrigin { explanationOrigin ?? .legacyUnverified }

    public init(id: UUID = UUID(), revision: UUID = UUID(), start: Date, end: Date,
                explanation: String, ownership: MarkerContextOwnership, explanationOrigin: ContextExplanationOrigin? = nil,
                provenance: MarkerContextProvenance? = nil, userNote: String? = nil) {
        self.id = id; self.revision = revision; self.start = start; self.end = end
        self.explanation = explanation; self.ownership = ownership
        self.explanationOrigin = explanationOrigin ?? (ownership == .proposed ? .legacyUnverified : .userAuthored)
        self.provenance = provenance; self.userNote = userNote
    }
}

public enum KeywordRuleAction: String, Codable, Sendable {
    case markOnTimeline
}

/// Stored configuration only: an enabled rule does not start recognition or grant microphone access.
public struct KeywordRule: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let revision: UUID
    public let phrase: String
    public let aliases: [String]
    public let name: String
    public let meaning: String
    public let enabled: Bool
    public let action: KeywordRuleAction

    public init(id: UUID = UUID(), revision: UUID = UUID(), phrase: String, aliases: [String] = [],
                name: String, meaning: String, enabled: Bool = false, action: KeywordRuleAction = .markOnTimeline) {
        self.id = id; self.revision = revision; self.phrase = phrase; self.aliases = aliases
        self.name = name; self.meaning = meaning; self.enabled = enabled; self.action = action
    }
}

public struct TimelineMarkerCursor: Codable, Equatable, Sendable {
    public let anchoredAt: Date
    public let id: UUID
    public init(anchoredAt: Date, id: UUID) { self.anchoredAt = anchoredAt; self.id = id }
}

public struct TimelineMarkerQuery: Sendable {
    public let from: Date?
    public let to: Date?
    public let before: TimelineMarkerCursor?
    public let limit: Int
    public let includeDeleted: Bool

    /// Inclusive time bounds, newest first, at most 200 rows per page.
    public init(from: Date? = nil, to: Date? = nil, before: TimelineMarkerCursor? = nil,
                limit: Int = 50, includeDeleted: Bool = false) {
        self.from = from; self.to = to; self.before = before; self.limit = limit; self.includeDeleted = includeDeleted
    }
}

public struct TimelineMarkerPage: Sendable {
    public let markers: [TimelineMarker]
    public let nextCursor: TimelineMarkerCursor?
    public init(markers: [TimelineMarker], nextCursor: TimelineMarkerCursor?) {
        self.markers = markers; self.nextCursor = nextCursor
    }
}

public enum ContextStoreError: Error, Equatable, Sendable {
    case notInitialized, closed, incompatibleDatabase, nativeStoreMismatch
    case invalidInput, requestConflict, revisionConflict, markerNotFound, protectedContextRange, capacityExceeded
    case confirmedAnchorConflict, ruleUnavailable, mediaMappingConflict
}
