import Foundation

/// Native writer-owned admission. All SQL checks and result writes occur in one
/// non-suspending transaction. Implementations also require their current
/// in-memory writer capability; persisted active state alone never grants access.
public protocol ScreenEvidenceAdmissionStoreProtocol: Actor {
    /// Mint a fresh owning incarnation and an inactive prepared policy epoch.
    func beginScreenEvidenceWriterSession(policy: ScreenEvidenceAccessPolicy) async throws
        -> ScreenEvidencePolicyTransition

    /// Close local admission before the durable write; failure leaves it closed.
    func prepareScreenEvidencePolicy(session: ScreenEvidenceWriterSession,
                                     policy: ScreenEvidenceAccessPolicy) async throws -> ScreenEvidencePolicyTransition
    func activateScreenEvidencePolicy(_ transition: ScreenEvidencePolicyTransition) async throws

    /// Cleanup is cancellation-insensitive and conditional on the exact token.
    /// It must not deactivate a newer owner/epoch. Revoked epochs cannot reactivate.
    func revokeScreenEvidencePolicy(_ transition: ScreenEvidencePolicyTransition) async throws
    func endScreenEvidenceWriterSession(_ session: ScreenEvidenceWriterSession) async throws

    /// At most 30 seconds per attempt; this is a validity deadline, not automatic
    /// scheduling permission. A monotonic deadline also applies within the owner.
    func claimScreenEvidenceDerivation(_ request: ScreenEvidenceDerivationRequest) async throws
        -> ScreenEvidenceDerivationClaim
    func cancelScreenEvidenceDerivation(_ claim: ScreenEvidenceDerivationClaim) async throws

    /// Bounded opaque bytes and their receipt commit together. V22 channel work
    /// remains unready. Identical retained retries are idempotent while valid.
    func stageScreenEvidenceArtifact(claim: ScreenEvidenceDerivationClaim, data: Data) async throws
        -> ScreenEvidenceArtifactReceipt
    func readScreenEvidenceArtifact(_ receipt: ScreenEvidenceArtifactReceipt) async throws
        -> ScreenEvidenceStagedArtifact
    func compactScreenEvidenceArtifacts(limit: Int) async throws -> ScreenEvidenceArtifactCompaction
}

/// Injected into Capture by App. Capture serializes all calls with configuration
/// application and joins exact-token cleanup before releasing that lifecycle slot.
public protocol CaptureConfigurationAdmissionProtocol: Actor {
    func beginSession(config: CaptureConfig) async throws -> ScreenEvidencePolicyTransition
    func prepareConfiguration(_ config: CaptureConfig) async throws -> ScreenEvidencePolicyTransition
    func activate(_ transition: ScreenEvidencePolicyTransition) async throws
    func revoke(_ transition: ScreenEvidencePolicyTransition) async throws
    func endSession() async throws
}
