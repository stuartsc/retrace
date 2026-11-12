import Darwin
import Foundation
import Shared

/// Private immutable files plus append-only stage receipts. The actor owner serializes access.
struct CompanionSpool: Sendable {
    let root: URL
    let nativeStoreID: UUID
#if DEBUG
    /// Holds the real filesystem boundary in concurrent startup regressions.
    var publicationObserver: (@Sendable (URL) -> Void)? = nil
#endif
    func acquire() throws -> Int32 {
        try directory(root)
        let descriptor = Darwin.open(root.appendingPathComponent("owner.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CompanionError.unsafeStorage }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor); throw CompanionError.unavailable
        }
        return descriptor
    }
    func initialize() throws {
        try directory(root)
        for name in ["", "requests", "objects", "results", "receipts"] {
            let folder = root.appendingPathComponent(name)
            try directory(folder)
            let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            // A crash after link() may leave a temporary second link alongside an
            // otherwise full 4096-object directory. Bound cleanup discovery separately
            // from the ordinary-file quota, then remove only validated publisher temps.
            guard entries.count <= 8192 else { throw CompanionError.capacityExceeded }
            let temporary = entries.filter { $0.lastPathComponent.hasPrefix(".publish-") }
            guard temporary.count <= 4096 else { throw CompanionError.capacityExceeded }
            for entry in temporary {
                guard UUID(uuidString: String(entry.lastPathComponent.dropFirst(9))) != nil else { throw CompanionError.unsafeStorage }
                var info = stat()
                guard lstat(entry.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
                      (1...2).contains(info.st_nlink) else { throw CompanionError.unsafeStorage }
            }
            for entry in temporary {
                guard Darwin.unlink(entry.path) == 0 else { throw CompanionError.unsafeStorage }
            }
            if !temporary.isEmpty {
                let descriptor = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard descriptor >= 0 else { throw CompanionError.unsafeStorage }
                let synced = fsync(descriptor); Darwin.close(descriptor)
                guard synced == 0 else { throw CompanionError.unsafeStorage }
            }
            guard entries.count - temporary.count <= 4096 else { throw CompanionError.capacityExceeded }
        }
        let binding = root.appendingPathComponent("native-store")
        let data = Data(nativeStoreID.uuidString.utf8)
        if FileManager.default.fileExists(atPath: binding.path) {
            guard try read(binding, limit: 64) == data else { throw CompanionError.nativeStoreMismatch }
        } else { try publish(data, to: binding) }
    }
    func directory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw CompanionError.unsafeStorage }
            let parentURL = url.deletingLastPathComponent()
            // Foundation may apply attributes after creating a visible directory.
            // mkdir applies the private mode in the same kernel publication step.
            // Only missing ancestors are created; existing shared parents such as
            // the system temporary directory retain their original permissions.
            var parentInfo = stat()
            if lstat(parentURL.path, &parentInfo) != 0 {
                guard errno == ENOENT, parentURL.path != url.path else { throw CompanionError.unsafeStorage }
                try directory(parentURL)
            }
            let created = Darwin.mkdir(url.path, 0o700) == 0
            guard created || errno == EEXIST else { throw CompanionError.unsafeStorage }
            guard lstat(url.path, &info) == 0 else { throw CompanionError.unsafeStorage }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw CompanionError.unsafeStorage }
#if DEBUG
            if created { publicationObserver?(url) }
#endif
            let parent = Darwin.open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard parent >= 0 else { throw CompanionError.unsafeStorage }
            defer { Darwin.close(parent) }
            guard fsync(parent) == 0 else { throw CompanionError.unsafeStorage }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw CompanionError.unsafeStorage }
    }
    func path(_ folder: String, _ id: String, suffix: String = ".json") throws -> URL {
        try CompanionBounds.digest(id)
        return root.appendingPathComponent(folder).appendingPathComponent(id + suffix)
    }
    func read(_ path: URL, limit: Int) throws -> Data {
        let descriptor = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CompanionError.unsafeStorage }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= limit else { throw CompanionError.unsafeStorage }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CompanionError.unsafeStorage }
                offset += count
            }
        }
        return data
    }
    func publish(_ data: Data, to destination: URL) throws {
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".publish-" + UUID().uuidString)
        let descriptor = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CompanionError.unsafeStorage }
        defer { Darwin.close(descriptor); Darwin.unlink(temp.path) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CompanionError.unsafeStorage }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw CompanionError.unsafeStorage }
        // An exclusive rename publishes the complete, private, single-link file
        // atomically. link()+unlink() exposes an otherwise valid destination with
        // two links to independent offline readers between those system calls.
        let published = Darwin.renamex_np(temp.path, destination.path, UInt32(RENAME_EXCL)) == 0
        if !published {
            guard errno == EEXIST, try read(destination, limit: data.count) == data else { throw CompanionError.conflictingPublication }
            guard Darwin.unlink(temp.path) == 0 else { throw CompanionError.unsafeStorage }
        }
#if DEBUG
        if published { publicationObserver?(destination) }
#endif
        let parent = Darwin.open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw CompanionError.unsafeStorage }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw CompanionError.unsafeStorage }
    }
    func publishObject(_ object: CompanionMediaObject) throws {
        let target = try path("objects", object.sha256, suffix: ".m4a")
        if !exists(target) {
            var space = statfs()
            guard statfs(root.path, &space) == 0,
                  UInt64(space.f_bavail) * UInt64(space.f_bsize) >= UInt64(object.data.count) + 256 * 1024 * 1024 else { throw CompanionError.capacityExceeded }
        }
        try publish(object.data, to: target)
    }
    /// Removes only a catalog-claimed staged copy, never the original recording AAC.
    func removeObject(_ object: CompanionObjectReservation) throws {
        let target = try path("objects", object.sha256, suffix: ".m4a")
        var info = stat()
        if lstat(target.path, &info) != 0 { guard errno == ENOENT else { throw CompanionError.unsafeStorage }; return }
        let bytes = try read(target, limit: 16 * 1024 * 1024)
        guard bytes.count == object.byteCount, CompanionWire.digest(bytes) == object.sha256,
              Darwin.unlink(target.path) == 0 else { throw CompanionError.unsafeStorage }
        let parent = Darwin.open(target.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw CompanionError.unsafeStorage }; defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw CompanionError.unsafeStorage }
    }
    func entries(_ folder: String) throws -> [URL] {
        let result = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".publish-") }
        guard result.count <= 4096 else { throw CompanionError.capacityExceeded }
        return result
    }
    func exists(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 }
}
