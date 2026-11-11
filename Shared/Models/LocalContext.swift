import Foundation

/// Exact selected native evidence only. This request grants no tool/disclosure
/// permissions. Foundation Models is an independent explicit opt-in, default off.
public struct LocalContextRequest: Equatable, Sendable {
    public let screenReferences: [ScreenEvidenceRef]
    public let activityReferences: [ActivityEvidenceRef]
    public let externalSnapshot: LocalContextExternalSnapshot?
    public let foundationModelsEnabled: Bool
    public init(screenReferences: [ScreenEvidenceRef] = [], activityReferences: [ActivityEvidenceRef] = [],
                externalSnapshot: LocalContextExternalSnapshot? = nil, foundationModelsEnabled: Bool = false) {
        self.screenReferences = screenReferences; self.activityReferences = activityReferences
        self.externalSnapshot = externalSnapshot; self.foundationModelsEnabled = foundationModelsEnabled
    }
}

public struct LocalContextScreenSpan: Codable, Equatable, Sendable {
    public let fragmentID: ScreenEvidenceFragmentID
    public let utf16Range: EvidenceUTF16Range
    public init(fragmentID: ScreenEvidenceFragmentID, utf16Range: EvidenceUTF16Range) {
        self.fragmentID = fragmentID; self.utf16Range = utf16Range
    }
}

/// Provider provenance is intentionally not an EvidenceRef or a local fact.
public struct LocalContextExternalCitation: Codable, Equatable, Sendable {
    public let source: String
    public let sourceID: String?
    public let citation: String?
    public let capturedAt: Date?
    public let url: String?
    public init(source: String, sourceID: String? = nil, citation: String? = nil, capturedAt: Date? = nil, url: String? = nil) {
        self.source = source; self.sourceID = sourceID; self.citation = citation; self.capturedAt = capturedAt; self.url = url
    }
}
public struct LocalContextExternalItem: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let citations: [LocalContextExternalCitation]
    public init(id: String, title: String, detail: String, citations: [LocalContextExternalCitation]) {
        self.id = id; self.title = title; self.detail = detail; self.citations = citations
    }
}
public struct LocalContextExternalSnapshot: Codable, Equatable, Sendable {
    public let providerID: String
    public let revision: String
    public let generatedAt: Date
    public let expiresAt: Date
    public let items: [LocalContextExternalItem]
    public init(providerID: String, revision: String, generatedAt: Date, expiresAt: Date, items: [LocalContextExternalItem]) {
        self.providerID = providerID; self.revision = revision; self.generatedAt = generatedAt; self.expiresAt = expiresAt; self.items = items
    }
}
public struct LocalContextExternalReference: Codable, Equatable, Sendable {
    public let providerID: String
    public let snapshotRevision: String
    public let itemID: String
    public let citations: [LocalContextExternalCitation]
    public init(providerID: String, snapshotRevision: String, itemID: String, citations: [LocalContextExternalCitation]) {
        self.providerID = providerID; self.snapshotRevision = snapshotRevision; self.itemID = itemID; self.citations = citations
    }
}
public enum LocalContextSupport: Codable, Equatable, Sendable {
    case screen(LocalContextScreenSpan)
    case activity(ActivityEvidenceRef)
    case external(LocalContextExternalReference)
}
public enum LocalContextItemKind: String, Codable, Sendable {
    case activityObservation, screenExcerpt, topicInterpretation, externalSignal
}
public struct LocalContextItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: LocalContextItemKind
    public let title: String
    public let excerpt: String?
    public let observedAt: Date?
    public let supports: [LocalContextSupport]
    public var isInterpretation: Bool { kind == .topicInterpretation }
    public init(id: String, kind: LocalContextItemKind, title: String, excerpt: String? = nil,
                observedAt: Date? = nil, supports: [LocalContextSupport]) {
        self.id = id; self.kind = kind; self.title = title; self.excerpt = excerpt; self.observedAt = observedAt; self.supports = supports
    }
}
public enum LocalContextScope: String, Codable, Sendable {
    /// Bounded supplied references; never a claim of whole-history, job or audio coverage.
    case selectedNativeScreenAndActivity
}
public enum LocalContextModelStatus: String, Codable, Sendable {
    case disabled, noInput, unavailable, failed, rejected, used
}
public struct LocalContextSnapshot: Equatable, Sendable {
    public let revision: UUID
    public let generatedAt: Date
    public let expiresAt: Date
    /// Ephemeral process/boot-local deadline. Never persist or reuse after restart.
    public let expiresAtUptime: TimeInterval
    public let scope: LocalContextScope
    public let externalProviders: [String]
    public let screenTextTruncated: Bool
    public let modelStatus: LocalContextModelStatus
    public let items: [LocalContextItem]
    public init(revision: UUID, generatedAt: Date, expiresAt: Date, expiresAtUptime: TimeInterval, externalProviders: [String],
                screenTextTruncated: Bool, modelStatus: LocalContextModelStatus, items: [LocalContextItem]) {
        self.revision = revision; self.generatedAt = generatedAt; self.expiresAt = expiresAt; self.expiresAtUptime = expiresAtUptime
        self.scope = .selectedNativeScreenAndActivity; self.externalProviders = externalProviders
        self.screenTextTruncated = screenTextTruncated; self.modelStatus = modelStatus; self.items = items
    }
}

/// Model inputs are canonical, bounded candidate excerpts. IDs are request-local
/// selectors only and cannot resolve other evidence or authorize any operation.
public struct LocalContextModelCandidate: Codable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let excerpt: String
    public init(id: Int, title: String, excerpt: String) { self.id = id; self.title = title; self.excerpt = excerpt }
}
public struct LocalContextTopicProposal: Equatable, Sendable {
    public let label: String
    public let supportIDs: [Int]
    public init(label: String, supportIDs: [Int]) { self.label = label; self.supportIDs = supportIDs }
}
public enum LocalContextError: String, Error, Sendable { case invalidRequest, unavailableEvidence, changedEvidence, expired, stopped }

/// Closed categorical telemetry: no text, refs, app names, paths or provider IDs.
public struct LocalContextMetric: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable { case prepared, reused, failed, expired, stopped }
    public let operation: Operation
    public let modelStatus: LocalContextModelStatus
    public let itemCount: Int
    public init(operation: Operation, modelStatus: LocalContextModelStatus, itemCount: Int) {
        self.operation = operation; self.modelStatus = modelStatus; self.itemCount = max(0, min(6, itemCount))
    }
}

/// One canonical native read boundary. The database compares live capability and
/// durable epoch in the same transaction as both mutation revisions and store ID.
/// It is a short-lived equality fence, never an evidence/disclosure grant.
public struct LocalContextReadIdentity: Equatable, Sendable {
    public let policy: ScreenEvidencePolicyTransition
    public let storeID: UUID
    public let screenRevision: Int64
    public let nativeFeedSequence: Int64
    public let activityRevision: Int64
    public init(policy: ScreenEvidencePolicyTransition, storeID: UUID, screenRevision: Int64, nativeFeedSequence: Int64, activityRevision: Int64) {
        self.policy = policy; self.storeID = storeID; self.screenRevision = screenRevision
        self.nativeFeedSequence = nativeFeedSequence; self.activityRevision = activityRevision
    }
}
