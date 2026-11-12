import Foundation
import Shared

/// Synchronous revocation fences actual URLSession task resume, before actor scheduling.
/// It cannot retract bytes already sent by an admitted task; that partial delivery is explicit.
public final class CompanionAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()
    private var allowed = false
    public init() {}
    @discardableResult public func replace(allowed: Bool) -> UUID {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); self.allowed = allowed; return generation
    }
    public func check(_ expected: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard allowed, generation == expected else { throw CompanionError.staleEvidence }
    }
    /// A settings transition reserves a generation before persistence or actor handoff.
    /// Checking a reservation never enables transport.
    public func checkReservation(_ expected: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard generation == expected else { throw CompanionError.staleEvidence }
    }
    public func activate(_ expected: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard generation == expected else { throw CompanionError.staleEvidence }
        allowed = true
    }
    public func admit(_ expected: UUID, resume: () -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard allowed, generation == expected else { throw CompanionError.staleEvidence }
        resume()
    }
}
