import Foundation
import Shared

/// Content-free capture availability. A gap is distinct from deduplicating
/// successfully observed, unchanged pixels. Consumers can persist transitions.
public struct CaptureCoverageEvent: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case gap(CaptureCoverageGapReason)
        case recovered
        /// The source stopped or was replaced; this does not assert recovery.
        case ended
    }

    public let backend: CaptureBackend
    public let displayID: UInt32?
    public let observedAt: Date
    public let state: State

    public init(backend: CaptureBackend, displayID: UInt32?, observedAt: Date = Date(), state: State) {
        self.backend = backend; self.displayID = displayID
        self.observedAt = observedAt; self.state = state
    }
}

public enum CaptureCoverageGapReason: String, Sendable, Codable {
    case busy
    case displayUnavailable
    case unstableContext
    case captureFailed
    case consumerBackpressure
    case configurationChanged
    case groupJournalUnavailable
}

/// Source and forwarding run on different actors. Their callbacks remain
/// synchronous and ordered without spawning an unbounded task per transition.
/// Recovery of one queue cannot conceal a still-open gap in the other queue.
final class CaptureCoverageDelivery: @unchecked Sendable {
    enum Stage { case source, forwarding }
    private let lock = NSRecursiveLock()
    private var sourceGaps: [UInt32: CaptureBackend] = [:]
    private var forwardingGaps: Set<UInt32> = []
    private var overflowed = false
    private var handler: (@Sendable (CaptureCoverageEvent) -> Void)?

    func setHandler(_ handler: (@Sendable (CaptureCoverageEvent) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    func receive(_ event: CaptureCoverageEvent, stage: Stage) {
        lock.withLock {
            let key = event.displayID ?? 0
            if case .gap = event.state,
               sourceGaps[key] == nil, !forwardingGaps.contains(key),
               Set(sourceGaps.keys).union(forwardingGaps).count >= 128 {
                if !overflowed {
                    overflowed = true
                    handler?(CaptureCoverageEvent(backend: event.backend, displayID: nil,
                        observedAt: event.observedAt, state: .gap(.consumerBackpressure)))
                }
                return
            }
            switch (stage, event.state) {
            case (.source, .gap): sourceGaps[key] = event.backend
            case (.forwarding, .gap): forwardingGaps.insert(key)
            case (.source, .recovered), (.source, .ended): sourceGaps.removeValue(forKey: key)
            case (.forwarding, .recovered), (.forwarding, .ended): forwardingGaps.remove(key)
            }
            if event.state == .recovered || event.state == .ended,
               sourceGaps[key] != nil || forwardingGaps.contains(key) || (key == 0 && overflowed) { return }
            // Serialize callback order with state transitions. The public
            // handler contract requires enqueue-only work; recursive locking
            // also permits synchronous handler replacement without deadlock.
            handler?(event)
        }
    }

    /// Called after the old native source has stopped and before its replacement
    /// starts. End only old source availability; forwarding still owns any
    /// pending configuration/backpressure gap until real pixels are admitted.
    func endSource() {
        lock.withLock {
            let ended = sourceGaps
            sourceGaps.removeAll()
            for key in ended.keys.sorted() {
                guard !forwardingGaps.contains(key), !(key == 0 && overflowed), let backend = ended[key] else { continue }
                handler?(.init(backend: backend, displayID: key == 0 ? nil : key, state: .ended))
            }
        }
    }

    func reset() { lock.withLock { sourceGaps.removeAll(); forwardingGaps.removeAll(); overflowed = false } }
}
