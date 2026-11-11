import Foundation

/// Canonical native-only persistence. Caller payloads cannot restore writer
/// capability, select a different store or make observed content executable.
/// Implementations bound unfinished runs, return exact idempotent ACKs, and keep
/// deletion tombstones. No method executes a command or opens an external source.
public protocol JobEventStoreProtocol: Sendable {
    func openJobWriter(admission: JobAdmission) async throws -> JobWriterSession
    func appendJobStart(_ event: JobObservation, session: JobWriterSession) async throws -> JobBeginReceipt
    func appendJobEnd(_ event: JobObservation, session: JobWriterSession) async throws -> JobEventSnapshot
    /// Cancellation-insensitive cleanup. The matching local writer closes before
    /// SQL can fail; remaining previously admitted runs become explicit gaps.
    func closeJobWriter(_ session: JobWriterSession, reason: JobGapReason) async throws
    /// Local historical reads use validated retained policy identity, including
    /// paused/revoked state, without minting a writer capability. App must also
    /// fence current user privacy/configuration around presentation awaits.
    func resolveJobEvidence(_ reference: JobEvidenceRef) async throws -> JobEvidenceResolution
    func jobChronology(_ query: JobChronologyQuery, after cursor: JobEventCursor?) async throws -> JobEventPage
    func validateJobRead(_ stamp: JobReadStamp) async throws -> Bool
    func deleteJobRun(_ runID: UUID, storeID: UUID) async throws
    func recordJobDiagnostic(_ diagnostic: JobDiagnostic) async throws
}
