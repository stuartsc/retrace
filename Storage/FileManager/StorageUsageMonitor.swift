import Darwin
import Foundation
import Shared

/// Periodic metadata accounting has a separate owner from capture's storage writer.
/// The constructor and snapshot accessor do no filesystem work.
public actor StorageUsageMonitor: StorageUsageReportingProtocol {
    private let roots: [StorageUsageRoot]
    private let omittedRootCount: Int
    private let configuration: StorageUsageConfiguration
    private let shouldDefer: @Sendable () async -> Bool
    private var periodicTask: Task<Void, Never>?
    private var scan: (id: UUID, task: Task<StorageUsageReport, Never>)?
    private var latestReport: StorageUsageReport?
    private var lastCompleteReport: StorageUsageReport?
    private var isClosed = false

    /// `shouldDefer` must read a cheap cached value and return promptly. Pressure slows
    /// each bounded batch, rather than making a scan or close wait indefinitely for idle.
    public init(roots: [StorageUsageRoot], configuration: StorageUsageConfiguration = .init(),
                shouldDefer: @escaping @Sendable () async -> Bool = { false }) {
        self.roots = Array(roots.prefix(256))
        self.omittedRootCount = max(0, roots.count - 256)
        self.configuration = configuration
        self.shouldDefer = shouldDefer
    }

    public func start() async {
        guard !isClosed else { return }
        if periodicTask == nil {
            let interval = configuration.refreshInterval
            periodicTask = Task(priority: .background) { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(interval)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    guard let snapshot = await self?.refresh(), !snapshot.isClosed else { return }
                }
            }
        }
        await refresh()
    }

    public func snapshot() -> StorageUsageSnapshot {
        .init(latestReport: latestReport, lastCompleteReport: lastCompleteReport,
              isScanning: scan != nil, isClosed: isClosed)
    }

    @discardableResult
    public func refresh() async -> StorageUsageSnapshot {
        guard !isClosed else { return snapshot() }
        let current: (id: UUID, task: Task<StorageUsageReport, Never>)
        if let scan {
            current = scan
        } else {
            let roots = self.roots
            let configuration = self.configuration
            let shouldDefer = self.shouldDefer
            let omittedRootCount = self.omittedRootCount
            let id = UUID()
            let task = Task.detached(priority: .background) {
                let scanner = StorageUsageScanner(roots: roots, configuration: configuration,
                                                   omittedRootCount: omittedRootCount,
                                                   shouldDefer: shouldDefer)
                return await scanner.run(id: id)
            }
            current = (id, task)
            scan = current
        }
        let report = await current.task.value
        publish(report, scanID: current.id)
        return snapshot()
    }

    public func close() async {
        isClosed = true
        let periodic = periodicTask
        let pending = scan
        periodic?.cancel()
        pending?.task.cancel()
        if let pending {
            let report = await pending.task.value
            publish(report, scanID: pending.id)
        }
        await periodic?.value
        periodicTask = nil
    }

    private func publish(_ report: StorageUsageReport, scanID: UUID) {
        guard scan?.id == scanID else { return }
        latestReport = report
        if report.isComplete { lastCompleteReport = report }
        scan = nil
    }
}

/// This instance and every directory descriptor belong to one detached scan task.
/// Memory grows with directory depth and a bounded set of multiply-linked inodes,
/// never with the number of ordinary media files.
private final class StorageUsageScanner {
    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
        init(_ info: stat) {
            device = UInt64(UInt32(bitPattern: info.st_dev))
            inode = UInt64(info.st_ino)
        }
    }

    private final class DirectoryCursor {
        let stream: UnsafeMutablePointer<DIR>
        let absolutePath: String
        let relativePath: String
        let identity: FileIdentity

        init?(descriptor: Int32, absolutePath: String, relativePath: String, identity: FileIdentity) {
            guard let stream = fdopendir(descriptor) else { return nil }
            self.stream = stream
            self.absolutePath = absolutePath
            self.relativePath = relativePath
            self.identity = identity
        }

        deinit { closedir(stream) }
    }

    private enum OpenRootResult {
        case opened(Int32)
        case absent(parent: Int32)
        case failed(StorageUsageIssueReason, Int32?)
    }

    private let roots: [StorageUsageRoot]
    private let configuration: StorageUsageConfiguration
    private let omittedRootCount: Int
    private let shouldDefer: @Sendable () async -> Bool
    private var categories = Dictionary(uniqueKeysWithValues: StorageUsageCategory.allCases.map { ($0, StorageUsageAmount()) })
    private var rootReports: [Int: StorageUsageRootReport] = [:]
    private var volumes: [UInt64: StorageUsageVolume] = [:]
    private var hardLinks: Set<FileIdentity> = []
    private var rootIdentities: [FileIdentity: String] = [:]
    private var issues: [StorageUsageIssue] = []
    private var issueCount: UInt64 = 0
    private var total = StorageUsageAmount()
    private var entriesSinceYield = 0
    private var cancelled = false

    init(roots: [StorageUsageRoot], configuration: StorageUsageConfiguration, omittedRootCount: Int,
         shouldDefer: @escaping @Sendable () async -> Bool) {
        self.roots = roots
        self.configuration = configuration
        self.omittedRootCount = omittedRootCount
        self.shouldDefer = shouldDefer
    }

    func run(id: UUID) async -> StorageUsageReport {
        let startedAt = Date()
        if omittedRootCount > 0 { issue("configuration", .resourceLimit) }
        var validRoots: [(index: Int, root: StorageUsageRoot, path: String)] = []
        var paths: [String: String] = [:]
        var identifiers: Set<String> = []
        for (index, root) in roots.enumerated() {
            // Foundation standardization rewrites /private/var back to the /var
            // symlink on macOS. Preserve components for the no-follow walk.
            let path = "/" + root.url.path.split(separator: "/").joined(separator: "/")
            guard valid(root: root, path: path), identifiers.insert(root.id).inserted else {
                issue(root.id, .invalidRoot)
                rootReports[index] = .init(rootID: root.id, status: .unavailable)
                continue
            }
            if let owner = paths[path] {
                rootReports[index] = .init(rootID: root.id, status: .coveredByOtherRoot, coveredByRootID: owner)
                continue
            }
            paths[path] = root.id
            validRoots.append((index, root, path))
        }
        // A named nested root owns its contents and category even if a parent is also selected.
        validRoots.sort { $0.path.count == $1.path.count ? $0.index < $1.index : $0.path.count > $1.path.count }
        let boundaries = Set(validRoots.map(\.path))
        for entry in validRoots {
            if Task.isCancelled {
                cancelled = true
                issue(entry.root.id, .cancelled)
                rootReports[entry.index] = .init(rootID: entry.root.id, status: .cancelled)
                continue
            }
            rootReports[entry.index] = await scanRoot(entry.root, path: entry.path, boundaries: boundaries)
        }
        cancelled = cancelled || Task.isCancelled
        return .init(id: id, startedAt: startedAt, finishedAt: Date(), categories: categories,
                     roots: roots.indices.compactMap { rootReports[$0] },
                     volumes: volumes.values.sorted { $0.deviceID < $1.deviceID },
                     issues: issues, totalIssueCount: issueCount, isCancelled: cancelled)
    }

    private func scanRoot(_ root: StorageUsageRoot, path: String, boundaries: Set<String>) async -> StorageUsageRootReport {
        let descriptor: Int32
        switch openRoot(path: path, missing: root.missingBehavior) {
        case .opened(let fd): descriptor = fd
        case .absent(let parent):
            defer { Darwin.close(parent) }
            let before = issueCount
            recordVolume(descriptor: parent, rootID: root.id)
            return .init(rootID: root.id, status: before == issueCount ? .absent : .partial)
        case .failed(let reason, let code):
            issue(root.id, reason, code)
            return .init(rootID: root.id, status: .unavailable)
        }
        var rootInfo = stat()
        guard fstat(descriptor, &rootInfo) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            issue(root.id, .metadataFailed, code)
            return .init(rootID: root.id, status: .unavailable)
        }
        let identity = FileIdentity(rootInfo)
        if let previous = rootIdentities[identity] {
            Darwin.close(descriptor)
            return .init(rootID: root.id, status: .coveredByOtherRoot, coveredByRootID: previous)
        }
        rootIdentities[identity] = root.id
        let initialIssueCount = issueCount
        recordVolume(descriptor: descriptor, rootID: root.id)
        if rootInfo.st_mode & S_IFMT == S_IFREG {
            defer { Darwin.close(descriptor) }
            var amount = StorageUsageAmount()
            _ = accountFile(rootInfo, category: root.defaultCategory, rootID: root.id, amount: &amount)
            return .init(rootID: root.id, status: issueCount == initialIssueCount ? .complete : .partial,
                         amount: amount)
        }
        guard let cursor = DirectoryCursor(descriptor: descriptor, absolutePath: path, relativePath: "", identity: identity) else {
            let code = errno
            Darwin.close(descriptor)
            issue(root.id, .enumerationFailed, code)
            return .init(rootID: root.id, status: .unavailable)
        }
        var stack = [cursor]
        var amount = StorageUsageAmount()
        var skippedLinks: UInt64 = 0
        while let current = stack.last {
            if Task.isCancelled { cancelled = true; issue(root.id, .cancelled); break }
            errno = 0
            guard let entry = readdir(current.stream) else {
                if errno != 0 { issue(root.id, .enumerationFailed, errno) }
                stack.removeLast()
                continue
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { issue(root.id, .metadataFailed); continue }
            if name == "." || name == ".." { continue }
            let childPath = current.absolutePath + "/" + name
            if boundaries.contains(childPath) { continue }
            var info = stat()
            if fstatat(dirfd(current.stream), name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                issue(root.id, .metadataFailed, errno)
            } else {
                let relative = current.relativePath.isEmpty ? name : current.relativePath + "/" + name
                switch info.st_mode & S_IFMT {
                case S_IFLNK: skippedLinks += 1
                case S_IFREG:
                    if !accountFile(info, category: classify(relative, root: root), rootID: root.id, amount: &amount) {
                        // On a memory or arithmetic bound, retain a partial count instead of
                        // double-counting the remaining hard links or silently wrapping bytes.
                        stack.removeAll()
                    }
                case S_IFDIR:
                    if stack.count >= configuration.maxDepth || childPath.utf8.count > 16_384 {
                        issue(root.id, .resourceLimit)
                    } else {
                        let childID = FileIdentity(info)
                        if stack.contains(where: { $0.identity == childID }) {
                            issue(root.id, .entryChangedDuringScan)
                        } else if let child = openChild(name, parent: current, expected: childID,
                                                        absolutePath: childPath, relativePath: relative, rootID: root.id) {
                            stack.append(child)
                        }
                    }
                default: break // Sockets/devices are not retained media or allocated regular files.
                }
            }
            entriesSinceYield += 1
            if entriesSinceYield >= configuration.batchSize {
                entriesSinceYield = 0
                await Task.yield()
                if Task.isCancelled { continue }
                let deferBatch = await shouldDefer()
                do { try await Task.sleep(for: .milliseconds(deferBatch ? 100 : 1)) }
                catch { cancelled = true }
            }
        }
        return .init(rootID: root.id,
                     status: Task.isCancelled ? .cancelled : (issueCount == initialIssueCount ? .complete : .partial),
                     amount: amount, skippedSymbolicLinks: skippedLinks)
    }

    private func openChild(_ name: String, parent: DirectoryCursor, expected: FileIdentity,
                           absolutePath: String, relativePath: String, rootID: String) -> DirectoryCursor? {
        let fd = openat(dirfd(parent.stream), name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { issue(rootID, .enumerationFailed, errno); return nil }
        var actual = stat()
        guard fstat(fd, &actual) == 0, FileIdentity(actual) == expected else {
            Darwin.close(fd)
            issue(rootID, .entryChangedDuringScan)
            return nil
        }
        recordVolume(descriptor: fd, rootID: rootID)
        guard let cursor = DirectoryCursor(descriptor: fd, absolutePath: absolutePath,
                                           relativePath: relativePath, identity: expected) else {
            let code = errno
            Darwin.close(fd)
            issue(rootID, .enumerationFailed, code)
            return nil
        }
        return cursor
    }

    private func accountFile(_ info: stat, category: StorageUsageCategory, rootID: String,
                             amount: inout StorageUsageAmount) -> Bool {
        if info.st_nlink > 1 {
            let identity = FileIdentity(info)
            if hardLinks.contains(identity) { return true }
            guard hardLinks.count < configuration.maxHardLinkIdentities else {
                issue(rootID, .resourceLimit)
                return false
            }
            hardLinks.insert(identity)
        }
        guard info.st_size >= 0, info.st_blocks >= 0 else { issue(rootID, .metadataFailed); return true }
        let allocation = UInt64(info.st_blocks).multipliedReportingOverflow(by: 512)
        guard !allocation.overflow else { issue(rootID, .arithmeticOverflow); return false }
        let addition = StorageUsageAmount(logicalBytes: UInt64(info.st_size), allocatedBytes: allocation.partialValue, fileCount: 1)
        guard let nextTotal = adding(total, addition), let nextRoot = adding(amount, addition),
              let nextCategory = adding(categories[category] ?? .init(), addition) else {
            issue(rootID, .arithmeticOverflow)
            return false
        }
        total = nextTotal
        amount = nextRoot
        categories[category] = nextCategory
        return true
    }

    private func adding(_ a: StorageUsageAmount, _ b: StorageUsageAmount) -> StorageUsageAmount? {
        let logical = a.logicalBytes.addingReportingOverflow(b.logicalBytes)
        let allocated = a.allocatedBytes.addingReportingOverflow(b.allocatedBytes)
        let count = a.fileCount.addingReportingOverflow(b.fileCount)
        guard !logical.overflow, !allocated.overflow, !count.overflow else { return nil }
        return .init(logicalBytes: logical.partialValue, allocatedBytes: allocated.partialValue, fileCount: count.partialValue)
    }

    private func recordVolume(descriptor: Int32, rootID: String) {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { issue(rootID, .volumeUnavailable, errno); return }
        let device = FileIdentity(metadata).device
        guard volumes[device] == nil else { return }
        guard volumes.count < 128 else { issue(rootID, .resourceLimit); return }
        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0 else { issue(rootID, .volumeUnavailable, errno); return }
        let total = UInt64(filesystem.f_blocks).multipliedReportingOverflow(by: UInt64(filesystem.f_bsize))
        let available = UInt64(filesystem.f_bavail).multipliedReportingOverflow(by: UInt64(filesystem.f_bsize))
        guard !total.overflow, !available.overflow else { issue(rootID, .arithmeticOverflow); return }
        volumes[device] = .init(deviceID: device, totalBytes: total.partialValue,
                               availableBytes: available.partialValue, observedAt: Date())
    }

    private func issue(_ rootID: String, _ reason: StorageUsageIssueReason, _ code: Int32? = nil) {
        issueCount += 1
        if issues.count < configuration.maxIssues {
            issues.append(.init(rootID: rootID, reason: reason, systemError: code))
        }
    }

    private func valid(root: StorageUsageRoot, path: String) -> Bool {
        root.url.isFileURL && path.hasPrefix("/") && path != "/" && !path.utf8.contains(0)
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
            && path.utf8.count <= 16_384 && !root.id.isEmpty && root.id.utf8.count <= 128
            && root.id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }
    }

    /// Open each root component relative to its already-open parent. A root rename or
    /// symlink substitution cannot redirect enumeration through a different directory.
    private func openRoot(path: String, missing: StorageUsageMissingBehavior) -> OpenRootResult {
        var parent = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { return .failed(.unreadableRoot, errno) }
        let components = path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            var before = stat()
            guard fstatat(parent, component, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
                let code = errno
                if code == ENOENT, index == components.count - 1, missing == .knownZero {
                    return .absent(parent: parent)
                }
                Darwin.close(parent)
                return .failed(code == ENOENT ? .missingRoot : .unreadableRoot, code)
            }
            if before.st_mode & S_IFMT == S_IFLNK {
                Darwin.close(parent)
                return .failed(.symbolicLinkRoot, nil)
            }
            let isFile = index == components.count - 1 && before.st_mode & S_IFMT == S_IFREG
            guard isFile || before.st_mode & S_IFMT == S_IFDIR else {
                Darwin.close(parent)
                return .failed(.invalidRoot, nil)
            }
            // Exact file roots are metadata-only. Never open a device/FIFO for
            // reading or enumerate the shared cache parent just to count a file.
            let flags = isFile ? O_EVTONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                : O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            let next = openat(parent, component, flags)
            guard next >= 0 else {
                let code = errno
                Darwin.close(parent)
                return .failed(.unreadableRoot, code)
            }
            var after = stat()
            guard fstat(next, &after) == 0, FileIdentity(before) == FileIdentity(after),
                  before.st_mode & S_IFMT == after.st_mode & S_IFMT else {
                Darwin.close(next)
                Darwin.close(parent)
                return .failed(.entryChangedDuringScan, nil)
            }
            Darwin.close(parent)
            parent = next
        }
        return .opened(parent)
    }

    private func classify(_ relativePath: String, root: StorageUsageRoot) -> StorageUsageCategory {
        guard root.classifyNativeLibrary else { return root.defaultCategory }
        let components = relativePath.split(separator: "/")
        guard let first = components.first else { return root.defaultCategory }
        if first == "audio", components.count > 2, components[1] == "chunk-media", components[2] == "pending" {
            return .originals
        }
        switch first {
        case "chunks", "segments": return .screenVideo
        case "audio": return .audio
        case "wal", "originals", ".originals": return .originals
        case "indexes", "index": return .indexes
        case "models", "model-cache": return .models
        case "cache", "caches", "temp", "favicon_cache", "app_names.json", "app_icon_colors.json": return .caches
        case "logs": return .logs
        default:
            if components.count == 1,
               first.hasSuffix(".db") || first.hasSuffix(".db-wal") || first.hasSuffix(".db-shm")
                || first.hasSuffix(".sqlite") || first.hasSuffix(".sqlite-wal") || first.hasSuffix(".sqlite-shm")
                || first.hasSuffix(".sqlite3") || first.hasSuffix(".sqlite3-wal") || first.hasSuffix(".sqlite3-shm") {
                return .database
            }
            return root.defaultCategory
        }
    }
}
