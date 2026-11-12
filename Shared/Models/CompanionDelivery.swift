import Foundation

/// The private SQLite file exists but no catalog metadata transaction is visible yet.
public enum CompanionDeliveryDatabaseError: Error, Equatable, Sendable { case unpublished }

public enum CompanionDeliveryStage: String, Codable, Sendable { case queued, published, received, imported, acknowledged, invalidated }
public struct CompanionDeliveryRecord: Sendable {
    public let sequence: Int64
    public let jobID: String
    public let requestPayload: Data
    public let resultPayload: Data?
    public let stage: CompanionDeliveryStage
    public let observedAt: Date
    public init(sequence: Int64, jobID: String, requestPayload: Data, resultPayload: Data?, stage: CompanionDeliveryStage, observedAt: Date) {
        self.sequence = sequence; self.jobID = jobID; self.requestPayload = requestPayload; self.resultPayload = resultPayload; self.stage = stage; self.observedAt = observedAt
    }
}
public struct CompanionDeliveryCursor: Codable, Equatable, Sendable {
    public let catalogID: UUID
    public let nativeStoreID: UUID
    public let from: Date
    public let to: Date
    public let maximumSequence: Int64
    public let beforeSourceStart: Double
    public let beforeID: String
    public init(catalogID: UUID, nativeStoreID: UUID, from: Date, to: Date, maximumSequence: Int64, beforeSourceStart: Double, beforeID: String) {
        self.catalogID = catalogID; self.nativeStoreID = nativeStoreID; self.from = from; self.to = to
        self.maximumSequence = maximumSequence; self.beforeSourceStart = beforeSourceStart; self.beforeID = beforeID
    }
}
public struct CompanionDeliveryPage: Sendable {
    public let records: [CompanionDeliveryRecord]
    public let nextCursor: CompanionDeliveryCursor?
    public init(records: [CompanionDeliveryRecord], nextCursor: CompanionDeliveryCursor?) { self.records = records; self.nextCursor = nextCursor }
}
public struct CompanionBatchPublicationReceipt: Codable, Equatable, Sendable {
    public let groupID: String
    public let jobIDs: [String]
    public let alreadyCovered: Bool
    public let coverageJobIDs: [String]
    public init(groupID: String, jobIDs: [String], alreadyCovered: Bool, coverageJobIDs: [String] = []) {
        self.groupID = groupID; self.jobIDs = jobIDs; self.alreadyCovered = alreadyCovered; self.coverageJobIDs = coverageJobIDs
    }
}
public struct CompanionObjectReservation: Codable, Equatable, Sendable {
    public let sha256: String
    public let byteCount: Int
    public init(sha256: String, byteCount: Int) { self.sha256 = sha256; self.byteCount = byteCount }
}
public struct CompanionRefreshCandidate: Sendable {
    public let sequence: Int64
    public let jobID: String
    public let markerID: UUID
    public init(sequence: Int64, jobID: String, markerID: UUID) { self.sequence = sequence; self.jobID = jobID; self.markerID = markerID }
}
public struct CompanionEnrollment: Codable, Equatable, Sendable {
    public let id: UUID
    public let active: Bool
    public let startedAt: Date
    public init(id: UUID, active: Bool, startedAt: Date) { self.id = id; self.active = active; self.startedAt = startedAt }
}
public struct CompanionBatchCandidate: Codable, Sendable {
    public let sequence: Int64
    public let enrollmentID: UUID
    public let manifest: AudioMediaManifest
    public let revision: UUID
    public init(sequence: Int64, enrollmentID: UUID, manifest: AudioMediaManifest, revision: UUID) {
        self.sequence = sequence; self.enrollmentID = enrollmentID; self.manifest = manifest; self.revision = revision
    }
}
public enum CompanionBatchDisposition: String, Codable, Sendable { case waiting, published, sourceUnavailable }
public protocol CompanionSourceStoreProtocol: Actor {
    /// Enabling reuses an active epoch; a disabled epoch is never reopened. Existing manifests are never enrolled.
    func setCompanionEnrollment(enabled: Bool) async throws -> CompanionEnrollment?
    func companionEnrollment() async throws -> CompanionEnrollment?
    func companionBatchCandidate(manifestID: UUID) async throws -> CompanionBatchCandidate?
    func companionBatchCandidates(now: Date, limit: Int) async throws -> [CompanionBatchCandidate]
    func finishCompanionBatch(_ candidate: CompanionBatchCandidate, disposition: CompanionBatchDisposition, groupID: String?, retryAfter: Date?) async throws
}
