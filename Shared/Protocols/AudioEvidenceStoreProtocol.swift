import Foundation

/// Exact native transcript reads only. No model scheduling, agent disclosure,
/// capture permission or verified audio-file access is granted by this contract.
/// App revalidates its current local-history policy/source epoch after these calls.
public protocol AudioEvidenceStoreProtocol: Sendable {
    func searchAudioEvidence(_ request: AudioEvidenceSearchRequest) async throws -> AudioEvidenceSearchPage
    func readAudioEvidence(_ reference: AudioEvidenceRef) async throws -> AudioEvidenceReadResult
    func readAudioMedia(_ reference: AudioEvidenceRef) async throws -> AudioEvidenceMediaReadResult
    func revalidateAudioEvidence(_ stamp: AudioEvidenceReadStamp, references: [AudioEvidenceRef]) async throws
    func audioEvidenceCoverage() async throws -> AudioEvidenceCoverage
    /// Terminal and joined; later calls fail. The owning database stays open
    /// until this reader and any App policy/metrics work have drained.
    func close() async
}

public extension AudioEvidenceStoreProtocol {
    func readAudioMedia(_ reference: AudioEvidenceRef) async throws -> AudioEvidenceMediaReadResult {
        .unavailable(.lineageUnavailable)
    }
}
