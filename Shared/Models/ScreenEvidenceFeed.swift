import Foundation

/// This registry does not enumerate unmaterialized legacy frames or imported history.
public enum ScreenEvidenceFeedCoverage: String, Codable, Sendable {
    case materializedNativeObservations
}

/// Publication order is independent of extraction revision: media and redaction can
/// change without producing new OCR. An event is identified by (feedID, sequence).
public enum ScreenEvidenceFeedChangeKind: String, Codable, Sendable {
    case extractionPublished = "extraction_published"
    case deleted
    case mediaUnavailable = "media_unavailable"
    case mediaRestored = "media_restored"
    case mediaLinkChanged = "media_link_changed"
    case redactionChanged = "redaction_changed"
}

public struct ScreenEvidenceFeedStatus: Codable, Sendable {
    public let feedID: UUID
    public let storeID: UUID
    public let latestSequence: Int64
    /// Events through this sequence have been compacted. Older cursors must reset.
    public let retainedThrough: Int64
    public let coverage: ScreenEvidenceFeedCoverage

    public init(feedID: UUID, storeID: UUID, latestSequence: Int64, retainedThrough: Int64) {
        self.feedID = feedID
        self.storeID = storeID
        self.latestSequence = latestSequence
        self.retainedThrough = retainedThrough
        self.coverage = .materializedNativeObservations
    }
}

/// The database owns all positions. Supplying a cursor cannot acknowledge a
/// caller-selected sequence or import unverified event contents.
public struct ScreenEvidenceConsumerCursor: Hashable, Codable, Sendable {
    public let feedID: UUID
    public let storeID: UUID
    public let consumerID: UUID
    public let leaseID: UUID

    public init(feedID: UUID, storeID: UUID, consumerID: UUID, leaseID: UUID) {
        self.feedID = feedID
        self.storeID = storeID
        self.consumerID = consumerID
        self.leaseID = leaseID
    }
}

public enum ScreenEvidenceConsumerPhase: String, Codable, Sendable {
    case bootstrap
    case replay
    case expired
}

public struct ScreenEvidenceConsumerStatus: Codable, Sendable {
    public let cursor: ScreenEvidenceConsumerCursor
    public let coverage: ScreenEvidenceFeedCoverage
    public let phase: ScreenEvidenceConsumerPhase
    public let boundarySequence: Int64
    public let maximumFrameID: Int64
    public let lastFrameID: Int64
    public let checkpointSequence: Int64
    public let expiresAt: Date

    public init(cursor: ScreenEvidenceConsumerCursor, phase: ScreenEvidenceConsumerPhase,
                boundarySequence: Int64, maximumFrameID: Int64, lastFrameID: Int64,
                checkpointSequence: Int64, expiresAt: Date) {
        self.cursor = cursor
        self.coverage = .materializedNativeObservations
        self.phase = phase
        self.boundarySequence = boundarySequence
        self.maximumFrameID = maximumFrameID
        self.lastFrameID = lastFrameID
        self.checkpointSequence = checkpointSequence
        self.expiresAt = expiresAt
    }
}

/// Publication and consumption confer no disclosure permission or index readiness.
/// A future worker requires a durable policy/source fence before accepting results.
public enum ScreenEvidenceWorkState: String, Codable, Sendable {
    case blocked
    case invalidated
    case deleted
}

/// Opaque bookkeeping only. No text, URL, title, geometry or embedding is staged.
public struct ScreenEvidenceWork: Codable, Sendable {
    public let reference: ScreenEvidenceRef
    public let sourceSequence: Int64
    public let lexicalState: ScreenEvidenceWorkState
    public let vectorState: ScreenEvidenceWorkState
    public let lexicalReadyRevision: Int64?
    public let vectorReadyRevision: Int64?

    public init(reference: ScreenEvidenceRef, sourceSequence: Int64,
                lexicalState: ScreenEvidenceWorkState, vectorState: ScreenEvidenceWorkState) {
        self.reference = reference
        self.sourceSequence = sourceSequence
        self.lexicalState = lexicalState
        self.vectorState = vectorState
        self.lexicalReadyRevision = nil
        self.vectorReadyRevision = nil
    }
}

public struct ScreenEvidenceConsumerPage: Codable, Sendable {
    public let status: ScreenEvidenceConsumerStatus
    public let inspectedCount: Int
    public let appliedCount: Int
    public let work: [ScreenEvidenceWork]

    public init(status: ScreenEvidenceConsumerStatus, inspectedCount: Int,
                appliedCount: Int, work: [ScreenEvidenceWork]) {
        self.status = status
        self.inspectedCount = inspectedCount
        self.appliedCount = appliedCount
        self.work = work
    }
}

public struct ScreenEvidenceFeedCompaction: Codable, Sendable {
    public let feed: ScreenEvidenceFeedStatus
    public let deletedEventCount: Int
    public let expiredConsumerCount: Int

    public init(feed: ScreenEvidenceFeedStatus, deletedEventCount: Int, expiredConsumerCount: Int) {
        self.feed = feed
        self.deletedEventCount = deletedEventCount
        self.expiredConsumerCount = expiredConsumerCount
    }
}

public enum ScreenEvidenceFeedError: String, Error, Codable, Sendable {
    case invalidLimits
    case invalidLease
    case consumerLimitReached
    case invalidCursor
    case cursorExpired
    case feedGap
    case integrityFailure
}
