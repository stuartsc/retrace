import Foundation

/// Canonical native-store bookkeeping. Implementations choose, validate and apply
/// each page inside one writer transaction. No API marks lexical/vector work ready.
public protocol ScreenEvidenceFeedStoreProtocol: Actor {
    func screenEvidenceFeedStatus() async throws -> ScreenEvidenceFeedStatus

    /// Resumes an unexpired generation or starts a fresh bootstrap after expiry
    /// or a feed gap. Starting a new generation invalidates its earlier work.
    /// Lease duration must be finite, positive and no longer than seven days.
    /// At most 32 consumer IDs may be registered; reuse an existing ID after expiry.
    func beginScreenEvidenceBootstrap(consumerID: UUID, leaseDuration: TimeInterval) async throws
        -> ScreenEvidenceConsumerStatus

    /// Applies at most 200 canonical observations/events, atomically with its
    /// durable work and checkpoint. Retrying resumes from the persisted position.
    func advanceScreenEvidenceConsumer(cursor: ScreenEvidenceConsumerCursor, limit: Int) async throws
        -> ScreenEvidenceConsumerPage

    func screenEvidenceConsumerStatus(cursor: ScreenEvidenceConsumerCursor) async throws
        -> ScreenEvidenceConsumerStatus

    /// Removes at most 1,000 unneeded events, retaining all unexpired cursor history.
    func compactScreenEvidenceFeed(limit: Int) async throws -> ScreenEvidenceFeedCompaction
}
