import Foundation

/// Reference loss is the only recoverable admission decision: retain the new
/// actual candidate instead. Other journal failures stop grouped sampling.
public enum CaptureGroupJournalError: Error, Sendable {
    case inactive, unavailable, capacityExceeded, invalidTransition, referenceUnavailable
}

/// App/Database own durable admission. Returning acknowledges a committed,
/// idempotent event. A begin event MUST commit all pending targets before any
/// pixel request. Outcome delivery is lossless and bounded by awaiting each call.
/// Implementations enforce per-member transition order and keep durable frame
/// admission/deletion separate; a sampling-ended event cannot close that drain.
/// Failures leave already-durable pending members visible for crash recovery.
public protocol CaptureGroupJournalProtocol: Sendable {
    func appendCaptureGroupEvent(_ event: CaptureGroupEvent) async throws
}
