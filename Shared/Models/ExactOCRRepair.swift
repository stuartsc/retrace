import Foundation

/// Process-local authority for one admitted native mutation. Invalidating waits only for
/// a short synchronous commit, never for file reads, decoding or recognition.
public final class NativeMutationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private let expiresAt: Date?
    private let clock: @Sendable () -> Date
    public init(expiresAt: Date? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.expiresAt = expiresAt; self.clock = clock
    }
    public func invalidate() { lock.lock(); valid = false; lock.unlock() }
    /// Checks only the immutable deadline, not mutation authority. Safe to repeat while
    /// admission is already held; it must not recursively acquire the admission lock.
    public func checkDeadline() throws {
        if let expiresAt, expiresAt <= clock() { throw CancellationError() }
    }
    public func withAdmission<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard valid else { throw CancellationError() }
        try checkDeadline()
        try Task.checkCancellation()
        return try operation()
    }
}

public enum ExactOCRRepairPhase: String, Codable, Sendable {
    case waitingForCapacity, readingPixels, recognizing, committing
}

public enum ExactOCRRepairError: Error, Sendable {
    case busy, closed, staleTarget, invalidTarget, invalidPixels
}

/// An internal native proof; it is never accepted from an MCP caller or persisted as text.
public struct ExactOCRRepairTarget: Sendable {
    public let snapshot: ScreenEvidenceSnapshot
    public let currentFrame: FrameReference
    public let sourceSequence: Int64
    public let metadataEpoch: Int64
    public init(snapshot: ScreenEvidenceSnapshot, currentFrame: FrameReference,
                sourceSequence: Int64, metadataEpoch: Int64) {
        self.snapshot = snapshot; self.currentFrame = currentFrame
        self.sourceSequence = sourceSequence; self.metadataEpoch = metadataEpoch
    }
}

public struct ExactOCRRepairOutcome: Codable, Equatable, Sendable {
    public let reference: ScreenEvidenceRef
    public init(reference: ScreenEvidenceRef) { self.reference = reference }
}
