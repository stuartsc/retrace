import Foundation

public struct VoiceMarkerPlaybackAdmission: Sendable, Equatable {
    public let revision: UInt64
    public let suppressed: Bool
    public init(revision: UInt64, suppressed: Bool) { self.revision = revision; self.suppressed = suppressed }
}

/// App-local acoustic playback suppression. Acquire before starting an audible
/// player and release on every stop/failure/deinit path. The short release tail
/// covers already queued output; it never mutates the recording stream.
public final class RetracePlaybackGate: @unchecked Sendable {
    public static let shared = RetracePlaybackGate()
    private let lock = NSLock()
    private var leases = Set<UUID>()
    private var revision: UInt64 = 0
    private var releaseTail = ContinuousClock.now
    public init() {}
    public func acquire() -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID(); leases.insert(id); revision &+= 1; return id
    }
    public func release(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if leases.remove(id) != nil { revision &+= 1; releaseTail = .now.advanced(by: .milliseconds(750)) }
    }
    public var admission: VoiceMarkerPlaybackAdmission {
        lock.lock(); defer { lock.unlock() }
        return .init(revision: revision, suppressed: !leases.isEmpty || ContinuousClock.now < releaseTail)
    }
    public var isSuppressed: Bool {
        lock.lock(); defer { lock.unlock() }
        return !leases.isEmpty || ContinuousClock.now < releaseTail
    }
}
