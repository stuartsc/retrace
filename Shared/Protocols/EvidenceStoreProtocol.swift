import Foundation

public protocol EvidenceStoreProtocol: Actor {
    func evidenceStoreID(source: FrameSource, identity: String) async throws -> UUID
    func materializeScreenEvidence(frame: FrameReference, storeID: UUID, width: Int, height: Int,
                                   text: ExtractedText?) async throws -> ScreenEvidenceSnapshot
    func screenEvidence(_ ref: ScreenEvidenceRef) async throws -> ScreenEvidenceSnapshot?
    func currentScreenEvidence(frameID: FrameID, storeID: UUID) async throws -> ScreenEvidenceSnapshot?
}
