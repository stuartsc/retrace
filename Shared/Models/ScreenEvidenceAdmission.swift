import Foundation

/// Historical evidence visibility, not permission to start capture or model work.
/// Keep the five privacy inputs versioned together. Arrays retain their original
/// substring semantics; bundle IDs are sorted only for stable serialization.
public struct ScreenEvidenceAccessPolicy: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let excludedAppBundleIDs: [String]
    public let excludePrivateWindows: Bool
    public let customPrivateWindowPatterns: [String]
    public let redactWindowTitlePatterns: [String]
    public let redactBrowserURLPatterns: [String]

    public init(config: CaptureConfig) {
        formatVersion = 1
        excludedAppBundleIDs = config.excludedAppBundleIDs.sorted()
        excludePrivateWindows = config.excludePrivateWindows
        customPrivateWindowPatterns = config.customPrivateWindowPatterns
        redactWindowTitlePatterns = config.redactWindowTitlePatterns
        redactBrowserURLPatterns = config.redactBrowserURLPatterns
    }

    /// Same retained-evidence predicate used by exact local presentation. A
    /// scrubbed URL cannot establish that a historical raw URL passes a new rule.
    public func permits(_ metadata: FrameMetadata) -> Bool {
        guard formatVersion == 1, metadata.redactionReason == nil,
              metadata.appBundleID.map({ !excludedAppBundleIDs.contains($0) }) ?? true else { return false }
        let title = metadata.windowName ?? ""
        guard !redactWindowTitlePatterns.contains(where: {
            !$0.isEmpty && title.localizedCaseInsensitiveContains($0)
        }) else { return false }
        if excludePrivateWindows {
            let patterns = ["incognito", "inprivate", "private browsing", "(private)"] + customPrivateWindowPatterns
            if patterns.contains(where: { !$0.isEmpty && title.localizedCaseInsensitiveContains($0) }) { return false }
        }
        return redactBrowserURLPatterns.isEmpty
    }
}

/// Issued by a capable native writer, not recovered as authority from disk.
public struct ScreenEvidenceWriterSession: Codable, Equatable, Sendable {
    public let feedID: UUID
    public let storeID: UUID
    public let writerID: UUID

    public init(feedID: UUID, storeID: UUID, writerID: UUID) {
        self.feedID = feedID; self.storeID = storeID; self.writerID = writerID
    }
}

/// A prepared epoch can be activated once. Revocation cannot reactivate an old
/// epoch, even if the user later restores identical configuration values.
public struct ScreenEvidencePolicyTransition: Codable, Equatable, Sendable {
    public let session: ScreenEvidenceWriterSession
    public let policyEpoch: Int64
    public let policySHA256: String

    public init(session: ScreenEvidenceWriterSession, policyEpoch: Int64, policySHA256: String) {
        self.session = session; self.policyEpoch = policyEpoch; self.policySHA256 = policySHA256
    }
}

public enum ScreenEvidenceDerivationChannel: String, Codable, Sendable {
    case lexical, vector
}

/// Opaque declared transform identity. This gate does not validate model quality
/// or publish this format to a searchable index.
public struct ScreenEvidenceTransformation: Codable, Equatable, Sendable {
    public let identifier: String
    public let fingerprintSHA256: String
    public let artifactFormat: String

    public init(identifier: String, fingerprintSHA256: String, artifactFormat: String) {
        self.identifier = identifier; self.fingerprintSHA256 = fingerprintSHA256
        self.artifactFormat = artifactFormat
    }
}

/// The database projects the requested exact text page and hashes its actual
/// identity, fragment boundaries and UTF-8 bytes. Callers cannot supply input text.
public struct ScreenEvidenceDerivationRequest: Codable, Equatable, Sendable {
    public let cursor: ScreenEvidenceConsumerCursor
    public let expansion: ScreenEvidenceExpansionRequest
    public let channel: ScreenEvidenceDerivationChannel
    public let transformation: ScreenEvidenceTransformation
    public let executionDuration: TimeInterval

    public init(cursor: ScreenEvidenceConsumerCursor, expansion: ScreenEvidenceExpansionRequest,
                channel: ScreenEvidenceDerivationChannel, transformation: ScreenEvidenceTransformation,
                executionDuration: TimeInterval = 10) {
        self.cursor = cursor; self.expansion = expansion; self.channel = channel
        self.transformation = transformation; self.executionDuration = executionDuration
    }
}

/// Separate from the consumer's bootstrap lease. An attempt grants no external
/// disclosure, model scheduling permission or whole-observation index readiness.
public struct ScreenEvidenceDerivationClaim: Codable, Equatable, Sendable {
    public let attemptID: UUID
    public let request: ScreenEvidenceDerivationRequest
    public let policy: ScreenEvidencePolicyTransition
    public let sourceSequence: Int64
    public let metadataEpoch: Int64
    public let inputSHA256: String
    public let inputUTF8Bytes: Int
    public let fragmentCount: Int
    public let nextCursor: ScreenEvidenceExpansionCursor?
    public let issuedAt: Date
    public let deadline: Date

    public init(attemptID: UUID, request: ScreenEvidenceDerivationRequest,
                policy: ScreenEvidencePolicyTransition, sourceSequence: Int64, metadataEpoch: Int64,
                inputSHA256: String, inputUTF8Bytes: Int, fragmentCount: Int,
                nextCursor: ScreenEvidenceExpansionCursor?, issuedAt: Date, deadline: Date) {
        self.attemptID = attemptID; self.request = request; self.policy = policy
        self.sourceSequence = sourceSequence; self.metadataEpoch = metadataEpoch
        self.inputSHA256 = inputSHA256; self.inputUTF8Bytes = inputUTF8Bytes
        self.fragmentCount = fragmentCount; self.nextCursor = nextCursor
        self.issuedAt = issuedAt; self.deadline = deadline
    }
}

public enum ScreenEvidenceArtifactStatus: String, Codable, Sendable {
    case stagedUnpublished
}

/// Confirms atomic storage under the stated fences, not semantic correctness.
/// Reads revalidate current policy/source state; this is not a permanent grant.
public struct ScreenEvidenceArtifactReceipt: Codable, Equatable, Sendable {
    public let receiptID: UUID
    public let claim: ScreenEvidenceDerivationClaim
    public let artifactSHA256: String
    public let artifactBytes: Int
    public let stagedAt: Date
    public let status: ScreenEvidenceArtifactStatus

    public init(receiptID: UUID, claim: ScreenEvidenceDerivationClaim, artifactSHA256: String,
                artifactBytes: Int, stagedAt: Date) {
        self.receiptID = receiptID; self.claim = claim; self.artifactSHA256 = artifactSHA256
        self.artifactBytes = artifactBytes; self.stagedAt = stagedAt; self.status = .stagedUnpublished
    }
}

public struct ScreenEvidenceStagedArtifact: Sendable {
    public let receipt: ScreenEvidenceArtifactReceipt
    public let data: Data

    public init(receipt: ScreenEvidenceArtifactReceipt, data: Data) {
        self.receipt = receipt; self.data = data
    }
}

public struct ScreenEvidenceArtifactCompaction: Sendable {
    public let removedClaims: Int
    public let removedArtifacts: Int
    public let removedArtifactBytes: Int

    public init(removedClaims: Int, removedArtifacts: Int, removedArtifactBytes: Int) {
        self.removedClaims = removedClaims; self.removedArtifacts = removedArtifacts
        self.removedArtifactBytes = removedArtifactBytes
    }
}

public enum ScreenEvidenceAdmissionError: String, Error, Codable, Sendable {
    case inactive, staleSession, stalePolicy, invalidRequest, notPermitted
    case invalidReference, sourceChanged, invalidConsumer, invalidClaim
    case claimExpired, claimCancelled, attemptInProgress, conflictingResult
    case capacityExceeded, artifactUnavailable, integrityFailure, unsupported
}
