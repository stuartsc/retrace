import Foundation
import Shared

/// The synchronous half only rotates a memory fence and invokes cheap observers.
/// Native output drains run separately, outside SQL hooks and correction-store transactions.
final class CompanionSpeakerChanges: @unchecked Sendable {
    typealias Drain = @Sendable () async -> Void
    private struct Observer { let invalidate: @Sendable (CompanionSpeakerChange) -> Void; let drain: Drain }
    private let lock = NSLock()
    private var observers: [UUID: Observer] = [:]
    private var revision = UUID()
    private var closed = false
    func add(invalidate: @escaping @Sendable (CompanionSpeakerChange) -> Void, drain: @escaping Drain) throws -> UUID {
        try lock.withLock {
            guard !closed else { throw CompanionError.closed }
            guard observers.count < 32 else { throw CompanionError.capacityExceeded }
            let id = UUID(); observers[id] = .init(invalidate: invalidate, drain: drain); return id
        }
    }
    func remove(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }
    func snapshot() -> UUID { lock.withLock { revision } }
    func check(_ expected: UUID) throws {
        try lock.withLock { guard !closed, revision == expected else { throw CompanionError.staleEvidence } }
    }
    func invalidate(_ change: CompanionSpeakerChange, close: Bool = false) {
        let callbacks = lock.withLock {
            revision = UUID(); closed = closed || close; return observers.values.map(\.invalidate)
        }
        callbacks.forEach { $0(change) }
    }
    func drain() async {
        let callbacks = lock.withLock { observers.values.map(\.drain) }
        for callback in callbacks { await callback() }
    }
}
