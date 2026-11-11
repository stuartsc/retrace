import Foundation

/// A stored sampling group is not a simultaneous screenshot. Every member keeps
/// its own sample time, and a similar member may point to an older exact sample.
public enum CaptureGroupRetentionState: String, Codable, Sendable {
    case pending, stored, similar, unavailable, dropped, cancelled, deleted, interrupted, excluded
}

public struct CaptureGroupMemberSnapshot: Sendable {
    public let target: CaptureSamplingTarget
    public let state: CaptureGroupRetentionState
    public let outcome: CaptureAttemptOutcome?
    /// Present only after current canonical source/privacy admission. A similar
    /// member's reference belongs to its earlier sample, never to this group time.
    public let reference: ScreenEvidenceRef?
    public let evidenceTimestamp: Date?
    public init(target: CaptureSamplingTarget, state: CaptureGroupRetentionState,
                outcome: CaptureAttemptOutcome?, reference: ScreenEvidenceRef?, evidenceTimestamp: Date?) {
        self.target = target; self.state = state; self.outcome = outcome
        self.reference = reference; self.evidenceTimestamp = evidenceTimestamp
    }
}

public struct CaptureGroupSnapshot: Sendable {
    public let stamp: CaptureGroupReadStamp
    public let group: CaptureSamplingGroup
    public let samplingEnd: CaptureSamplingEndReason?
    public let members: [CaptureGroupMemberSnapshot]
    public init(stamp: CaptureGroupReadStamp, group: CaptureSamplingGroup, samplingEnd: CaptureSamplingEndReason?,
                members: [CaptureGroupMemberSnapshot]) {
        self.stamp = stamp; self.group = group; self.samplingEnd = samplingEnd; self.members = members
    }
}

public struct CaptureGroupReadStamp: Equatable, Sendable {
    public let groupID: UUID
    public let journalRevision: Int64
    public let policy: ScreenEvidencePolicyTransition
    public let sourceSequence: Int64
    public let metadataEpoch: Int64
    public init(groupID: UUID, journalRevision: Int64, policy: ScreenEvidencePolicyTransition,
                sourceSequence: Int64, metadataEpoch: Int64) {
        self.groupID = groupID; self.journalRevision = journalRevision
        self.policy = policy; self.sourceSequence = sourceSequence; self.metadataEpoch = metadataEpoch
    }
}

public enum CaptureGroupStoreError: String, Error, Codable, Sendable {
    case invalidEvent, conflictingEvent, groupUnavailable, invalidTransition
    case conflictingFrame, stalePolicy, sourceUnavailable, integrityFailure
}
