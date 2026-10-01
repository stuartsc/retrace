import Foundation

/// CPU percentages use 100% for one logical core; system CPU uses 100% for the
/// whole machine. A missing measurement is unknown, never an idle sample.
public struct ResourceUsageWindow: Sendable, Codable, Equatable {
    public var cpuPercent: Double?
    public var peakCPUPercent: Double?
    public var sampledSeconds: Double
    public var elapsedSeconds: Double
    public init(cpuPercent: Double? = nil, peakCPUPercent: Double? = nil,
                sampledSeconds: Double = 0, elapsedSeconds: Double = 0) {
        self.cpuPercent = cpuPercent
        self.peakCPUPercent = peakCPUPercent
        self.sampledSeconds = sampledSeconds
        self.elapsedSeconds = elapsedSeconds
    }
    public var coverage: Double {
        elapsedSeconds > 0 ? min(1, max(0, sampledSeconds / elapsedSeconds)) : 0
    }
}

public struct ResourceUsageSnapshot: Sendable, Codable, Equatable {
    public var observedAt: Date?
    public var sampleUptime: Double?
    public var cpuPercent: Double?
    public var systemCPUPercent: Double?
    public var systemFiveSecondCPUPercent: Double?
    public var physicalFootprintBytes: UInt64?
    public var logicalCoreCount: Int
    public var oneMinute: ResourceUsageWindow
    public var fifteenMinutes: ResourceUsageWindow
    public var isCurrent: Bool
    public init(observedAt: Date? = nil, sampleUptime: Double? = nil,
                cpuPercent: Double? = nil, systemCPUPercent: Double? = nil,
                systemFiveSecondCPUPercent: Double? = nil, physicalFootprintBytes: UInt64? = nil,
                logicalCoreCount: Int = 1, oneMinute: ResourceUsageWindow = .init(),
                fifteenMinutes: ResourceUsageWindow = .init(), isCurrent: Bool = false) {
        self.observedAt = observedAt
        self.sampleUptime = sampleUptime
        self.cpuPercent = cpuPercent
        self.systemCPUPercent = systemCPUPercent
        self.systemFiveSecondCPUPercent = systemFiveSecondCPUPercent
        self.physicalFootprintBytes = physicalFootprintBytes
        self.logicalCoreCount = max(1, logicalCoreCount)
        self.oneMinute = oneMinute
        self.fifteenMinutes = fifteenMinutes
        self.isCurrent = isCurrent
    }
    public static let unavailable = ResourceUsageSnapshot()
}

/// Fixed-size, content-free minute aggregates. Unobserved seconds remain visible.
public struct ResourceUsageMinute: Sendable, Codable, Equatable {
    public let timestamp: Date
    public let cpu: ResourceUsageWindow
    public let systemCPUPercent: Double?
    public let physicalFootprintBytes: UInt64?
    public let droppedMinutes: Int
    public init(timestamp: Date, cpu: ResourceUsageWindow, systemCPUPercent: Double?,
                physicalFootprintBytes: UInt64?, droppedMinutes: Int = 0) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.systemCPUPercent = systemCPUPercent
        self.physicalFootprintBytes = physicalFootprintBytes
        self.droppedMinutes = droppedMinutes
    }
}
