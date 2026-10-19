import Foundation
import Shared
import Storage

/// Owns periodic accounting independently of capture writers and UI lifetime.
/// Construction performs no scan; startup never awaits directory enumeration.
public actor StorageUsageService: StorageUsageReportingProtocol {
    private let roots: [StorageUsageRoot]
    private let resources: any ResourceUsageProviding
    private var monitor: StorageUsageMonitor?
    private var startup: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var previous = StorageUsageSnapshot()
    private var lifecycleGeneration: UInt64 = 0

    public init(roots: [StorageUsageRoot], resources: any ResourceUsageProviding) {
        self.roots = roots
        self.resources = resources
    }

    public static func roots(native: URL, includeRelatedLibraries: Bool) -> [StorageUsageRoot] {
        var roots = [StorageUsageRoot(id: "native", url: native, classifyNativeLibrary: true)]
        guard includeRelatedLibraries else { return roots }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support")
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Caches")
        roots += [
            .init(id: "backups", url: support.appendingPathComponent("Retrace Backups"),
                  defaultCategory: .backups, missingBehavior: .knownZero),
            .init(id: "candidates", url: support.appendingPathComponent("Retrace Candidates"),
                  defaultCategory: .candidates, missingBehavior: .knownZero),
            .init(id: "imported", url: URL(fileURLWithPath: AppPaths.expandedRewindStorageRoot),
                  defaultCategory: .imported, missingBehavior: .knownZero),
            .init(id: "nativeLogs", url: home.appendingPathComponent("Library/Logs/Retrace"),
                  defaultCategory: .logs, missingBehavior: .knownZero),
            .init(id: "nativeCaches", url: cache.appendingPathComponent("io.retrace.app"),
                  defaultCategory: .caches, missingBehavior: .knownZero),
            .init(id: "searchThumbnails", url: cache.appendingPathComponent("search_thumbnails_v1"),
                  defaultCategory: .caches, missingBehavior: .knownZero),
            .init(id: "searchResults", url: cache.appendingPathComponent("search_results_cache.json"),
                  defaultCategory: .caches, missingBehavior: .knownZero),
            .init(id: "otherApps", url: cache.appendingPathComponent("other_apps_cache.json"),
                  defaultCategory: .caches, missingBehavior: .knownZero)
        ]
        return roots
    }

    public func start() async {
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        if let closing {
            await closing.value
            guard generation == lifecycleGeneration else { return }
            self.closing = nil
        }
        guard monitor == nil else { return }
        let monitor = StorageUsageMonitor(roots: roots, shouldDefer: { [resources] in
            let sample = await resources.snapshot()
            return sample.systemFiveSecondCPUPercent.map { $0 > 80 } ?? false
        })
        self.monitor = monitor
        startup = Task { await monitor.start() }
    }

    public func snapshot() async -> StorageUsageSnapshot {
        if let monitor { return await monitor.snapshot() }
        return previous
    }

    public func refresh() async -> StorageUsageSnapshot {
        guard let monitor else { return previous }
        return await monitor.refresh()
    }

    public func close() async {
        lifecycleGeneration &+= 1
        if let closing { await closing.value; return }
        let monitor = self.monitor, startup = self.startup
        self.monitor = nil
        self.startup = nil
        let task = Task {
            await monitor?.close()
            await startup?.value
        }
        closing = task
        await task.value
        previous = await monitor?.snapshot() ?? .init(isClosed: true)
    }
}
