import Foundation

public enum ContextExplanationOrigin: String, Codable, Sendable { case userAuthored, companionDerived, legacyUnverified }

public struct MarkerContextProvenance: Codable, Equatable, Sendable {
    public let jobID: String
    public let resultSHA256: String
    public let proposalRevision: UUID
    public let supportIDs: [String]
    public init(jobID: String, resultSHA256: String, proposalRevision: UUID, supportIDs: [String]) {
        self.jobID = jobID; self.resultSHA256 = resultSHA256; self.proposalRevision = proposalRevision; self.supportIDs = supportIDs
    }
}
public struct ContextProposalHead: Codable, Equatable, Sendable {
    public let revision: UUID
    public let jobID: String
    public let sequence: Int64
    public init(revision: UUID, jobID: String, sequence: Int64) { self.revision = revision; self.jobID = jobID; self.sequence = sequence }
}
public struct ContextProposalCommand: Codable, Equatable, Sendable {
    public let jobID: String
    public let proposalRevision: UUID
    public let expectedMarkerRevision: UUID
    public let expectedProposalHead: UUID?
    /// Original bounded immutable wire bytes, retained in the context sidecar for offline validation.
    public let requestPayload: Data
    public let resultPayload: Data
    public init(jobID: String, proposalRevision: UUID, expectedMarkerRevision: UUID, expectedProposalHead: UUID?, requestPayload: Data, resultPayload: Data) {
        self.jobID = jobID; self.proposalRevision = proposalRevision; self.expectedMarkerRevision = expectedMarkerRevision
        self.expectedProposalHead = expectedProposalHead; self.requestPayload = requestPayload; self.resultPayload = resultPayload
    }
}
public struct ContextProposalReceipt: Codable, Equatable, Sendable {
    public let markerID: UUID
    public let head: ContextProposalHead
    public init(markerID: UUID, head: ContextProposalHead) { self.markerID = markerID; self.head = head }
}
public struct RetainedContextProposal: Sendable {
    public let markerID: UUID
    public let markerRevision: UUID
    public let proposalRevision: UUID
    public let jobID: String
    public let resultSHA256: String
    public let requestPayload: Data
    public let resultPayload: Data
    public init(markerID: UUID, markerRevision: UUID, proposalRevision: UUID, jobID: String, resultSHA256: String, requestPayload: Data, resultPayload: Data) {
        self.markerID = markerID; self.markerRevision = markerRevision; self.proposalRevision = proposalRevision
        self.jobID = jobID; self.resultSHA256 = resultSHA256; self.requestPayload = requestPayload; self.resultPayload = resultPayload
    }
}
public struct ContextRangeRevision: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case active, superseded }
    public let sequence: Int64
    public let markerID: UUID
    public let range: MarkerContextRange
    public let state: State
    public let recordedAt: Date
    public init(sequence: Int64, markerID: UUID, range: MarkerContextRange, state: State, recordedAt: Date) {
        self.sequence = sequence; self.markerID = markerID; self.range = range; self.state = state; self.recordedAt = recordedAt
    }
}

public struct ContextRangePresentationReference: Codable, Equatable, Sendable {
    public let nativeStoreID: UUID
    public let markerID: UUID
    public let markerRevision: UUID
    public let rangeID: UUID
    public let rangeRevision: UUID
    public let provenance: MarkerContextProvenance?
    public init(nativeStoreID: UUID, markerID: UUID, markerRevision: UUID, rangeID: UUID, rangeRevision: UUID, provenance: MarkerContextProvenance?) {
        self.nativeStoreID = nativeStoreID; self.markerID = markerID; self.markerRevision = markerRevision
        self.rangeID = rangeID; self.rangeRevision = rangeRevision; self.provenance = provenance
    }
}
public struct ContextRangePresentation: Codable, Equatable, Identifiable, Sendable {
    public enum Availability: String, Codable, Sendable { case available, sourceUnavailable, legacyUnverified, evidenceGrantRequired }
    public var id: UUID { reference.rangeID }
    public let reference: ContextRangePresentationReference
    public let ownership: MarkerContextOwnership
    public let availability: Availability
    /// Nil when inherited source content cannot currently be disclosed.
    public let range: MarkerContextRange?
    /// Explicit user-authored text remains distinct from an inherited explanation.
    public let userNote: String?
    public init(reference: ContextRangePresentationReference, ownership: MarkerContextOwnership, availability: Availability, range: MarkerContextRange?, userNote: String?) {
        self.reference = reference; self.ownership = ownership; self.availability = availability; self.range = range; self.userNote = userNote
    }
}
public struct ContextRangePresentationPage: Codable, Sendable {
    public let markerID: UUID
    public let markerRevision: UUID
    public let items: [ContextRangePresentation]
    public let incomplete: Bool
    /// Process-local invalidation precision, never serialized as evidence or paths.
    public let sourceDependencies: NativeSourceDependencies
    private enum CodingKeys: String, CodingKey { case markerID, markerRevision, items, incomplete }
    public init(markerID: UUID, markerRevision: UUID, items: [ContextRangePresentation], incomplete: Bool,
                sourceDependencies: NativeSourceDependencies = .unknown) {
        self.markerID = markerID; self.markerRevision = markerRevision; self.items = items; self.incomplete = incomplete
        self.sourceDependencies = sourceDependencies
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        markerID = try values.decode(UUID.self, forKey: .markerID)
        markerRevision = try values.decode(UUID.self, forKey: .markerRevision)
        items = try values.decode([ContextRangePresentation].self, forKey: .items)
        incomplete = try values.decode(Bool.self, forKey: .incomplete)
        sourceDependencies = .unknown
    }
}
