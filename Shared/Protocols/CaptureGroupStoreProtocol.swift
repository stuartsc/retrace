import Foundation

public protocol CaptureGroupStoreProtocol: Actor, CaptureGroupJournalProtocol {
    /// Requires an exact native selected reference and the current owning policy.
    /// Callers recheck their presentation admission after this awaited read and
    /// resolve each selected companion through the existing evidence service.
    func captureGroup(for reference: ScreenEvidenceRef) async throws -> CaptureGroupSnapshot?
    func revalidateCaptureGroupRead(_ stamp: CaptureGroupReadStamp) async throws
}
