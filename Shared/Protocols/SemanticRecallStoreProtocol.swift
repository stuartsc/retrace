import Foundation

/// V25 typed native local derivations. The owning Database actor must have a
/// current active V23 writer capability. Persisted active rows are insufficient.
/// Input, publication and every read use one non-suspending SQLite transaction.
public protocol SemanticRecallStoreProtocol: Actor {
    /// One durable index per supported transformation. A new writer/expired
    /// lease receives a new cursor lease while preserving content/checkpoints.
    func beginSemanticRecall(transformation: SemanticRecallTransformation,
                             leaseDuration: TimeInterval) async throws -> SemanticRecallCursor
    /// At most 200 source identities inspected and one <=4096-byte canonical
    /// text page returned. Fresh changes precede resumable historical work.
    func claimSemanticRecallWork(cursor: SemanticRecallCursor, maximumInspected: Int,
                                 executionDuration: TimeInterval) async throws -> SemanticRecallWorkPage
    /// The trusted pinned producer supplies complete tokenizer/model output.
    /// Persistence independently validates declared contiguous window coverage,
    /// exact source spans and 384 finite unit vectors, not numerical inference.
    /// Empty windows only complete an actually empty normalized text page.
    func publishSemanticRecall(claim: SemanticRecallClaim,
                               windows: [SemanticRecallVectorWindow]) async throws -> SemanticRecallPublication
    /// Cancellation-independent cleanup. Success proves the exact claim is
    /// cancelled, already retired or absent in canonical storage. Failures must
    /// retain caller ownership for retry; no generic error proves absence.
    func cancelSemanticRecall(claim: SemanticRecallClaim) async throws
    func semanticRecallCoverage(cursor: SemanticRecallCursor) async throws -> SemanticRecallCoverage
    /// Filters and canonical privacy precede the output limit. Bounded scans can
    /// return zero candidates with a continuation; that is not search completion.
    func readSemanticRecallVectors(request: SemanticRecallVectorReadRequest) async throws -> SemanticRecallVectorPage
    func revalidateSemanticRecallRead(stamp: SemanticRecallReadStamp) async throws
}
