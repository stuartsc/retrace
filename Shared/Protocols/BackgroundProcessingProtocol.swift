import Foundation

/// Automatic work only. Recording, playback, explicit searches and dictation do not acquire a permit.
public enum BackgroundProcessingKind: String, Sendable {
    case freshTranscription, overdueTranscription, ambientSpeech, ambientSilence, freshOCR, historicalOCR, refinement, indexing, localSummary

    /// Fresh capture preparation has a latency budget, not an inactivity requirement.
    public var isFresh: Bool { self == .freshOCR || self == .freshTranscription }
    public var isFirstPass: Bool { self == .freshTranscription || self == .overdueTranscription }
}

/// Synchronous, lock-protected cancellation for native inference callbacks.
public final class BackgroundProcessingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() { lock.withLock { cancelled = true } }
}

public struct BackgroundProcessingPermit: Sendable {
    public let id: UUID
    public let threadCount: Int
    public let cancellation: BackgroundProcessingCancellation
    public init(id: UUID = UUID(), threadCount: Int, cancellation: BackgroundProcessingCancellation = .init()) {
        self.id = id
        self.threadCount = threadCount
        self.cancellation = cancellation
    }
}

public protocol BackgroundProcessingProtocol: Sendable {
    /// The caller must release the permit after native work has actually returned, even on cancellation.
    func acquire(_ kind: BackgroundProcessingKind) async throws -> BackgroundProcessingPermit
    /// Optional work may skip model enrichment without delaying an explicit UI request.
    func tryAcquire(_ kind: BackgroundProcessingKind) async throws -> BackgroundProcessingPermit?
    func release(_ permit: BackgroundProcessingPermit) async
}

public extension BackgroundProcessingProtocol {
    func tryAcquire(_ kind: BackgroundProcessingKind) async throws -> BackgroundProcessingPermit? { nil }
}
