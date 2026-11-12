import Foundation
import Shared

struct OriginalSpoolAccounting {
    var bytes: Int64 = 0
    var reservedBytes: Int64 = 0
    var files: [String: Int64] = [:]
    var frameCounts: [String: Int] = [:]
    var epoch: UInt64 = 0
}

/// Multiple readers/recovery owners can share one root. An owned mutation only
/// invalidates another owner's cache; the normal single writer updates in place.
private final class OriginalSpoolEpochs: @unchecked Sendable {
    static let shared = OriginalSpoolEpochs()
    private let lock = NSLock()
    private var epochs: [String: UInt64] = [:]
    func value(_ root: String) -> UInt64 { lock.withLock { epochs[root, default: 0] } }
    func advance(_ root: String) -> UInt64 {
        lock.withLock { epochs[root, default: 0] &+= 1; return epochs[root, default: 0] }
    }
    func advance(_ root: String, expecting expected: UInt64) -> UInt64? {
        lock.withLock {
            let unchanged = epochs[root, default: 0] == expected
            epochs[root, default: 0] &+= 1
            return unchanged ? epochs[root, default: 0] : nil
        }
    }
}

extension WALManager {
    private var accountingRoot: String { walRootURL.resolvingSymlinksInPath().standardizedFileURL.path }

    func cachedOriginalSpoolUsage() throws -> (bytes: Int64, reservedBytes: Int64) {
        let epoch = OriginalSpoolEpochs.shared.value(accountingRoot)
        if let accounting = originalAccounting, accounting.epoch == epoch {
            return (accounting.bytes, accounting.reservedBytes)
        }
        var accounting = OriginalSpoolAccounting(epoch: epoch)
        originalAccountingScanCount += 1
        if FileManager.default.fileExists(atPath: walRootURL.path) {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
            guard let files = FileManager.default.enumerator(at: walRootURL, includingPropertiesForKeys: Array(keys)) else {
                throw StorageError.fileReadFailed(path: walRootURL.path, underlying: "Cannot account for original spool")
            }
            for case let url as URL in files {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else {
                    throw StorageError.fileReadFailed(path: url.path, underlying: "Symbolic link in original spool")
                }
                guard values.isRegularFile == true, let size = values.fileSize else { continue }
                try updateFile(url, size: Int64(size), in: &accounting)
                if url.lastPathComponent == "metadata.json",
                   let metadata = try? originalSessionMetadata(url.deletingLastPathComponent()) {
                    try updateReserve(directory: url.deletingLastPathComponent(), frames: metadata.frameCount, in: &accounting)
                }
            }
        }
        originalAccounting = accounting
        return (accounting.bytes, accounting.reservedBytes)
    }

    func accountOriginalFile(_ url: URL, metadata: WALMetadata? = nil) throws {
        let current = OriginalSpoolEpochs.shared.value(accountingRoot)
        if var accounting = originalAccounting, accounting.epoch == current {
            do {
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                try updateFile(url, size: size, in: &accounting)
                if let metadata { try updateReserve(directory: url.deletingLastPathComponent(), frames: metadata.frameCount, in: &accounting) }
                guard let epoch = OriginalSpoolEpochs.shared.advance(accountingRoot, expecting: current) else {
                    originalAccounting = nil
                    return
                }
                accounting.epoch = epoch
                originalAccounting = accounting
            } catch {
                invalidateOriginalAccounting()
                throw error
            }
        } else {
            invalidateOriginalAccounting()
        }
    }

    func accountRemovedOriginalSession(_ directory: URL) {
        let current = OriginalSpoolEpochs.shared.value(accountingRoot)
        if var accounting = originalAccounting, accounting.epoch == current {
            let directoryKey = directory.resolvingSymlinksInPath().standardizedFileURL.path
            let prefix = directoryKey + "/"
            for path in accounting.files.keys.filter({ $0.hasPrefix(prefix) }) {
                accounting.bytes -= accounting.files.removeValue(forKey: path) ?? 0
            }
            if let count = accounting.frameCounts.removeValue(forKey: directoryKey) {
                accounting.reservedBytes -= Int64(count) * 1_024
            }
            guard let epoch = OriginalSpoolEpochs.shared.advance(accountingRoot, expecting: current) else {
                originalAccounting = nil
                return
            }
            accounting.epoch = epoch
            originalAccounting = accounting
        } else { invalidateOriginalAccounting() }
    }

    func invalidateOriginalAccounting() {
        originalAccounting = nil
        _ = OriginalSpoolEpochs.shared.advance(accountingRoot)
    }

    /// Periodic maintenance refreshes only one source's small receipt files.
    /// Recovery's journal can change independently of the capture writer.
    func refreshOriginalSessionAccounting(_ session: WALSession) throws {
        for name in ["frames.bin", "metadata.json", "frame_id_map.bin", "original-retention.json", "recovery-progress.json"] {
            let url = session.sessionDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try accountOriginalFile(url, metadata: name == "metadata.json" ? originalSessionMetadata(session.sessionDir) : nil)
            }
        }
    }

    private func updateFile(_ url: URL, size: Int64, in accounting: inout OriginalSpoolAccounting) throws {
        let key = url.resolvingSymlinksInPath().standardizedFileURL.path
        let previous = accounting.files[key, default: 0]
        let sum = accounting.bytes.addingReportingOverflow(size - previous)
        guard size >= 0, !sum.overflow, sum.partialValue >= 0 else {
            throw StorageError.fileReadFailed(path: url.path, underlying: "Original spool accounting overflow")
        }
        accounting.files[key] = size
        accounting.bytes = sum.partialValue
    }

    private func updateReserve(directory: URL, frames: Int, in accounting: inout OriginalSpoolAccounting) throws {
        guard frames >= 0 else {
            throw StorageError.fileReadFailed(path: directory.path, underlying: "Invalid original frame reserve")
        }
        let key = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let previous = accounting.frameCounts[key, default: 0]
        let delta = Int64(frames - previous).multipliedReportingOverflow(by: 1_024)
        let sum = accounting.reservedBytes.addingReportingOverflow(delta.partialValue)
        guard frames >= 0, !delta.overflow, !sum.overflow, sum.partialValue >= 0 else {
            throw StorageError.fileReadFailed(path: directory.path, underlying: "Original spool reserve overflow")
        }
        accounting.frameCounts[key] = frames
        accounting.reservedBytes = sum.partialValue
    }
}
