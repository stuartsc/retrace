import Foundation
import Shared
import Database
import Storage
import Search

/// Manages data retention policy enforcement
/// Periodically cleans up old frames, video segments, and related data based on user settings
/// Owner: APP integration
public actor RetentionManager {

    // MARK: - Properties

    private let database: DatabaseManager
    private let storage: StorageManager
    private let search: SearchManager

    private var cleanupTask: Task<Void, Never>?
    private var inFlightCleanup: Task<RetentionCleanupResult, Never>?
    private var isRunning = false
    private var isStopping = false

    /// Interval between cleanup checks (default: 1 hour)
    private let cleanupInterval: TimeInterval = 3600

    /// Last cleanup timestamp for rate limiting
    private var lastCleanupTime: Date?

    /// Minimum interval between cleanups (10 minutes)
    private let minimumCleanupInterval: TimeInterval = 600

    // MARK: - Initialization

    public init(
        database: DatabaseManager,
        storage: StorageManager,
        search: SearchManager
    ) {
        self.database = database
        self.storage = storage
        self.search = search
    }

    // MARK: - Lifecycle

    /// Start the retention manager (runs cleanup periodically)
    public func start() async {
        guard !isRunning, !isStopping else {
            Log.warning("[RetentionManager] Already running", category: .app)
            return
        }

        isRunning = true
        Log.info("[RetentionManager] Started", category: .app)

        // Start periodic cleanup task (runs in background, doesn't block startup)
        cleanupTask = Task {
            // Run initial cleanup after a short delay to not block app startup
            try? await Task.sleep(for: .nanoseconds(Int64(5_000_000_000)), clock: .continuous) // 5 second delay

            if Task.isCancelled { return }
            await runCleanupIfNeeded()

            while !Task.isCancelled {
                // Wait for cleanup interval
                try? await Task.sleep(for: .seconds(cleanupInterval), clock: .continuous)

                if Task.isCancelled { break }

                await runCleanupIfNeeded()
            }
        }
    }

    /// Stop the retention manager
    public func stop() async {
        if isStopping {
            if let inFlightCleanup { _ = await inFlightCleanup.value }
            return
        }
        guard isRunning || inFlightCleanup != nil else { return }
        isStopping = true
        defer { isStopping = false }

        cleanupTask?.cancel()
        cleanupTask = nil
        isRunning = false
        let pending = inFlightCleanup
        pending?.cancel()
        if let pending { _ = await pending.value }

        Log.info("[RetentionManager] Stopped", category: .app)
    }

    // MARK: - Cleanup Logic

    /// Get the current retention policy from user settings
    /// Returns nil if retention is set to "Forever" (0 days)
    public nonisolated func getRetentionDays() -> Int? {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let days = defaults.integer(forKey: "retentionDays")
        return days == 0 ? nil : days
    }

    /// Calculate the cutoff date based on retention settings
    /// Returns nil if retention is set to "Forever"
    public nonisolated func getCutoffDate() -> Date? {
        guard let retentionDays = getRetentionDays() else {
            return nil // Forever - no cleanup
        }

        let cutoffDate = Date().addingTimeInterval(-TimeInterval(retentionDays) * 86400)
        return cutoffDate
    }

    /// Get apps excluded from retention cleanup (data from these apps won't be deleted)
    /// NOTE: Exclusions are disabled - everything older than retention window gets deleted
    public nonisolated func getExcludedApps() -> Set<String> {
        // Exclusions disabled - always return empty set
        return []
        // Original code (commented out):
        // let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        // guard let appsString = defaults.string(forKey: "retentionExcludedApps"), !appsString.isEmpty else {
        //     return []
        // }
        // return Set(appsString.split(separator: ",").map { String($0) })
    }

    /// Get tag IDs excluded from retention cleanup (data with these tags won't be deleted)
    /// NOTE: Exclusions are disabled - everything older than retention window gets deleted
    public nonisolated func getExcludedTagIds() -> Set<Int64> {
        // Exclusions disabled - always return empty set
        return []
        // Original code (commented out):
        // let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        // guard let tagsString = defaults.string(forKey: "retentionExcludedTagIds"), !tagsString.isEmpty else {
        //     return []
        // }
        // return Set(tagsString.split(separator: ",").compactMap { Int64($0) })
    }

    /// Check if hidden items should be excluded from retention cleanup
    /// NOTE: Exclusions are disabled - everything older than retention window gets deleted (including hidden)
    public nonisolated func shouldExcludeHidden() -> Bool {
        // Exclusions disabled - never exclude hidden items
        return false
        // Original code (commented out):
        // let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        // return defaults.bool(forKey: "retentionExcludeHidden")
    }

    /// Run cleanup if enough time has passed since the last cleanup
    public func runCleanupIfNeeded() async {
        // Check if we've cleaned up recently
        if let lastCleanup = lastCleanupTime {
            let timeSinceLastCleanup = Date().timeIntervalSince(lastCleanup)
            if timeSinceLastCleanup < minimumCleanupInterval {
                Log.debug("[RetentionManager] Skipping cleanup - last cleanup was \(Int(timeSinceLastCleanup))s ago", category: .app)
                return
            }
        }

        await runCleanup()
    }

    /// Coalesce periodic and manually requested cleanup into one background operation.
    @discardableResult
    public func runCleanup() async -> RetentionCleanupResult {
        if let inFlightCleanup { return await inFlightCleanup.value }
        guard !isStopping else {
            return RetentionCleanupResult(deletedFrames: 0, deletedVideoSegments: 0, deletedAppSegments: 0,
                reclaimedBytes: 0, cutoffDate: nil, success: false, error: "Retention cleanup is stopping")
        }
        let task = Task { await self.performCleanup() }
        inFlightCleanup = task
        defer { inFlightCleanup = nil }
        return await task.value
    }

    private func performCleanup() async -> RetentionCleanupResult {
        guard let cutoff = getCutoffDate() else {
            return RetentionCleanupResult(deletedFrames: 0, deletedVideoSegments: 0, deletedAppSegments: 0,
                                          reclaimedBytes: 0, cutoffDate: nil, success: true, error: nil)
        }
        lastCleanupTime = Date()
        var deletedFrames = 0
        var deletedSegments = 0
        var deletedVideos = 0
        var reclaimedBytes: Int64 = 0
        var failures: [String] = []
        var attemptedVideoIDs: Set<VideoSegmentID> = []
        let root = await storage.getStorageDirectory()
        do {
            // Keep each SQLite transaction short and cap work per scheduled run.
            for _ in 0..<20 {
                try Task.checkCancellation()
                let batch = try await database.performRetentionBatch(olderThan: cutoff,
                    excludingApps: getExcludedApps(), excludingTagIDs: getExcludedTagIds(),
                    excludeHidden: shouldExcludeHidden())
                deletedFrames += batch.deletedFrames
                deletedSegments += batch.deletedAppSegments
                for candidate in batch.videos where attemptedVideoIDs.insert(candidate.id).inserted {
                    try Task.checkCancellation()
                    do {
                        let targets = try Self.validatedVideoURLs(root: root, relativePath: candidate.relativePath)
                        let bytes = try await database.completeRetentionVideoDeletion(candidate: candidate) {
                            // Recheck both filenames under the database guard. At
                            // most two metadata lookups/unlinks are needed, no scan.
                            try Self.deleteValidatedVideoFiles(root: root, relativePath: candidate.relativePath,
                                                              expectedURLs: targets)
                        }
                        if let bytes {
                            deletedVideos += 1
                            reclaimedBytes += bytes
                        }
                    } catch {
                        failures.append("Video \(candidate.id.value): \(error.localizedDescription)")
                        Log.warning("[RetentionManager] Keeping video cleanup candidate \(candidate.id.value): \(error)", category: .app)
                    }
                }
                if batch.deletedFrames < 500 { break }
                await Task.yield()
            }
        } catch {
            failures.append(error.localizedDescription)
            Log.error("[RetentionManager] Cleanup stopped with committed work preserved: \(error)", category: .app)
        }
        if deletedVideos > 0 { await storage.invalidateAllCaches() }
        Log.info("[RetentionManager] Cleanup: \(deletedFrames) frames, \(deletedSegments) sessions, \(deletedVideos) videos, \(reclaimedBytes) file bytes reclaimed", category: .app)
        return RetentionCleanupResult(deletedFrames: deletedFrames, deletedVideoSegments: deletedVideos,
            deletedAppSegments: deletedSegments, reclaimedBytes: reclaimedBytes, cutoffDate: cutoff,
            success: failures.isEmpty, error: failures.isEmpty ? nil : failures.joined(separator: "; "))
    }

    nonisolated static func validatedVideoURL(root: URL, relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"), components.first == "chunks", components.count >= 2,
              !components.contains(".."), !components.contains("."), !components.contains("") else {
            throw RetentionError.unsafeStoragePath(relativePath)
        }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RetentionError.storageUnavailable
        }
        let proposed = resolvedRoot.appendingPathComponent(relativePath).standardizedFileURL
        let resolved = proposed.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(resolvedRoot.path + "/"), resolved == proposed else {
            throw RetentionError.unsafeStoragePath(relativePath)
        }
        if FileManager.default.fileExists(atPath: resolved.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw RetentionError.unsafeStoragePath(relativePath)
            }
        }
        return resolved
    }

    /// Matches ImageExtractor's bounded primary / appended-.mp4 reader fallback.
    /// Validate both before deleting either, including when the primary is missing.
    nonisolated static func validatedVideoURLs(root: URL, relativePath: String) throws -> [URL] {
        try [relativePath, relativePath + ".mp4"].map { try validatedVideoURL(root: root, relativePath: $0) }
    }

    nonisolated static func deleteValidatedVideoFiles(root: URL, relativePath: String, expectedURLs: [URL]) throws -> Int64 {
        let current = try validatedVideoURLs(root: root, relativePath: relativePath)
        guard current == expectedURLs else { throw RetentionError.unsafeStoragePath(relativePath) }
        var removedBytes: Int64 = 0
        for url in current {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw RetentionError.unsafeStoragePath(relativePath)
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            try FileManager.default.removeItem(at: url)
            removedBytes += size
        }
        return removedBytes
    }
}

// MARK: - Supporting Types

/// Result of a retention cleanup operation
public struct RetentionCleanupResult: Sendable {
    public let deletedFrames: Int
    public let deletedVideoSegments: Int
    public let deletedAppSegments: Int
    public let reclaimedBytes: Int64
    public let cutoffDate: Date?
    public let success: Bool
    public let error: String?
}

/// Retention manager errors
public enum RetentionError: Error {
    case databaseNotConnected
    case queryFailed(String)
    case unsafeStoragePath(String)
    case storageUnavailable
}
