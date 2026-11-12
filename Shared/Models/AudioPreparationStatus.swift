import Foundation

/// Bounded status-row inventory. Counts are lower bounds when truncated; they
/// are not speech counts or a promise that retained media is decodable.
/// A missing snapshot means unavailable, never an empty queue.
public struct AudioPreparationStatus: Codable, Sendable, Equatable {
    public let observedAt: Date
    public let pendingCountLowerBound: Int
    public let hasMorePending: Bool
    public let oldestPendingAt: Date?
    public let repairCountLowerBound: Int
    public let hasMoreRepair: Bool
    public let oldestRepairAt: Date?

    public init(observedAt: Date, pendingCountLowerBound: Int, hasMorePending: Bool,
                oldestPendingAt: Date?, repairCountLowerBound: Int, hasMoreRepair: Bool,
                oldestRepairAt: Date?) {
        self.observedAt = observedAt
        self.pendingCountLowerBound = pendingCountLowerBound
        self.hasMorePending = hasMorePending
        self.oldestPendingAt = oldestPendingAt
        self.repairCountLowerBound = repairCountLowerBound
        self.hasMoreRepair = hasMoreRepair
        self.oldestRepairAt = oldestRepairAt
    }
}
