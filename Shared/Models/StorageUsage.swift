import Foundation

/// File categories are presentation labels, not permissions to remove their contents.
public enum StorageUsageCategory: String, CaseIterable, Codable, Sendable {
    case screenVideo, audio, database, originals, indexes, models, caches, logs
    case backups, candidates, imported, other
}

public struct StorageUsageAmount: Equatable, Codable, Sendable {
    public var logicalBytes: UInt64
    /// Allocated file blocks, including shared APFS clone blocks. Not reclaimable bytes.
    public var allocatedBytes: UInt64
    public var fileCount: UInt64

    public init(logicalBytes: UInt64 = 0, allocatedBytes: UInt64 = 0, fileCount: UInt64 = 0) {
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
    }
}

public enum StorageUsageMissingBehavior: Sendable {
    /// A required/custom/offline library is unavailable when it cannot be found.
    case unavailable
    /// An absent optional leaf file or directory is empty only if its parent is accessible.
    case knownZero
}

public struct StorageUsageRoot: Sendable {
    /// A content-free stable identifier supplied by the owner, never a filesystem path.
    public let id: String
    public let url: URL
    public let defaultCategory: StorageUsageCategory
    public let classifyNativeLibrary: Bool
    public let missingBehavior: StorageUsageMissingBehavior

    public init(id: String, url: URL, defaultCategory: StorageUsageCategory = .other,
                classifyNativeLibrary: Bool = false,
                missingBehavior: StorageUsageMissingBehavior = .unavailable) {
        self.id = id
        self.url = url
        self.defaultCategory = defaultCategory
        self.classifyNativeLibrary = classifyNativeLibrary
        self.missingBehavior = missingBehavior
    }
}

public struct StorageUsageConfiguration: Sendable {
    public let refreshInterval: TimeInterval
    public let batchSize: Int
    public let maxDepth: Int
    public let maxHardLinkIdentities: Int
    public let maxIssues: Int

    public init(refreshInterval: TimeInterval = 15 * 60, batchSize: Int = 256,
                maxDepth: Int = 128, maxHardLinkIdentities: Int = 100_000, maxIssues: Int = 64) {
        self.refreshInterval = refreshInterval.isFinite && refreshInterval > 0
            ? min(max(refreshInterval, 0.05), 24 * 60 * 60) : 15 * 60
        self.batchSize = min(max(batchSize, 1), 4_096)
        self.maxDepth = min(max(maxDepth, 1), 256)
        self.maxHardLinkIdentities = min(max(maxHardLinkIdentities, 1), 1_000_000)
        self.maxIssues = min(max(maxIssues, 1), 256)
    }
}

public enum StorageUsageRootStatus: String, Codable, Sendable {
    case complete, absent, coveredByOtherRoot, partial, unavailable, cancelled
}

public enum StorageUsageIssueReason: String, Codable, Sendable {
    case invalidRoot, missingRoot, symbolicLinkRoot, unreadableRoot
    case enumerationFailed, metadataFailed, entryChangedDuringScan, resourceLimit
    case arithmeticOverflow, volumeUnavailable, cancelled
}

public struct StorageUsageIssue: Equatable, Codable, Sendable {
    public let rootID: String
    public let reason: StorageUsageIssueReason
    /// Categorical native error only; no filenames, paths or contents.
    public let systemError: Int32?

    public init(rootID: String, reason: StorageUsageIssueReason, systemError: Int32? = nil) {
        self.rootID = rootID
        self.reason = reason
        self.systemError = systemError
    }
}

public struct StorageUsageRootReport: Equatable, Codable, Sendable {
    public let rootID: String
    public let status: StorageUsageRootStatus
    public let amount: StorageUsageAmount
    public let coveredByRootID: String?
    public let skippedSymbolicLinks: UInt64

    public init(rootID: String, status: StorageUsageRootStatus, amount: StorageUsageAmount = .init(),
                coveredByRootID: String? = nil, skippedSymbolicLinks: UInt64 = 0) {
        self.rootID = rootID
        self.status = status
        self.amount = amount
        self.coveredByRootID = coveredByRootID
        self.skippedSymbolicLinks = skippedSymbolicLinks
    }
}

public struct StorageUsageVolume: Equatable, Codable, Sendable {
    public let deviceID: UInt64
    public let totalBytes: UInt64
    public let availableBytes: UInt64
    public let observedAt: Date

    public init(deviceID: UInt64, totalBytes: UInt64, availableBytes: UInt64, observedAt: Date) {
        self.deviceID = deviceID
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.observedAt = observedAt
    }
}

/// A metadata scan observes a changing filesystem over an interval, not an atomic disk snapshot.
public struct StorageUsageReport: Equatable, Codable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let categories: [StorageUsageCategory: StorageUsageAmount]
    public let roots: [StorageUsageRootReport]
    public let volumes: [StorageUsageVolume]
    public let issues: [StorageUsageIssue]
    public let totalIssueCount: UInt64
    public let isCancelled: Bool

    public var isComplete: Bool {
        !isCancelled && totalIssueCount == 0 && roots.allSatisfy {
            $0.status == .complete || $0.status == .absent || $0.status == .coveredByOtherRoot
        }
    }

    public var total: StorageUsageAmount {
        categories.values.reduce(into: StorageUsageAmount()) { sum, amount in
            // Scanner publication rejects overflow. Defensive decoding remains bounded.
            sum.logicalBytes = Self.saturatingAdd(sum.logicalBytes, amount.logicalBytes)
            sum.allocatedBytes = Self.saturatingAdd(sum.allocatedBytes, amount.allocatedBytes)
            sum.fileCount = Self.saturatingAdd(sum.fileCount, amount.fileCount)
        }
    }

    public init(id: UUID = UUID(), startedAt: Date, finishedAt: Date,
                categories: [StorageUsageCategory: StorageUsageAmount], roots: [StorageUsageRootReport],
                volumes: [StorageUsageVolume], issues: [StorageUsageIssue], totalIssueCount: UInt64,
                isCancelled: Bool = false) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.categories = categories
        self.roots = roots
        self.volumes = volumes
        self.issues = issues
        self.totalIssueCount = totalIssueCount
        self.isCancelled = isCancelled
    }

    private static func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let result = a.addingReportingOverflow(b)
        return result.overflow ? .max : result.partialValue
    }
}

public struct StorageUsageSnapshot: Equatable, Sendable {
    public let latestReport: StorageUsageReport?
    public let lastCompleteReport: StorageUsageReport?
    public let isScanning: Bool
    public let isClosed: Bool

    public init(latestReport: StorageUsageReport? = nil, lastCompleteReport: StorageUsageReport? = nil,
                isScanning: Bool = false, isClosed: Bool = false) {
        self.latestReport = latestReport
        self.lastCompleteReport = lastCompleteReport
        self.isScanning = isScanning
        self.isClosed = isClosed
    }
}
