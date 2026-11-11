import CryptoKit
import Darwin
import Foundation

/// Owns the exact bytes used by Core ML. Hashing a caller's mutable path and
/// subsequently loading that path would not bind the loaded model to its pin.
final class VerifiedMiniLMArtifacts {
    let directory: URL
    let modelPackageURL: URL
    let compiledModelURL: URL
    private var removed = false

    private init(directory: URL) {
        self.directory = directory
        modelPackageURL = directory.appendingPathComponent("model.mlpackage", isDirectory: true)
        compiledModelURL = directory.appendingPathComponent("model.mlmodelc", isDirectory: true)
    }

    static func tokenizerData(at url: URL) throws -> Data {
        var bytes = Data()
        try copyPinnedFile(url, pin: MiniLMModelPin.tokenizer) { bytes.append($0) }
        return bytes
    }

    static func create(configuration: MiniLMEmbeddingConfiguration, tokenizerData: Data) throws -> VerifiedMiniLMArtifacts {
        try Task.checkCancellation()
        guard tokenizerData.count == MiniLMModelPin.tokenizer.byteCount,
              SHA256.hash(data: tokenizerData).map({ String(format: "%02x", $0) }).joined() == MiniLMModelPin.tokenizer.sha256 else {
            throw MiniLMRuntimeError.artifactInvalid
        }
        guard configuration.modelPackageURL.isFileURL, configuration.privateCacheParentURL.isFileURL else {
            throw MiniLMRuntimeError.artifactInvalid
        }
        let parent = configuration.privateCacheParentURL.resolvingSymlinksInPath()
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0,
              parentInfo.st_mode & S_IFMT == S_IFDIR,
              parentInfo.st_uid == getuid(), parentInfo.st_mode & 0o022 == 0 else {
            throw MiniLMRuntimeError.artifactInvalid
        }
        try verifyInventory(configuration.modelPackageURL)
        let directory = parent.appendingPathComponent("minilm-\(UUID().uuidString)", isDirectory: true)
        // Claim ownership only after an exclusive directory creation succeeds.
        // FileManager.createDirectory may accept an already-existing directory.
        guard mkdir(directory.path, 0o700) == 0 else { throw MiniLMRuntimeError.artifactUnavailable }
        let result = VerifiedMiniLMArtifacts(directory: directory)
        do {
            try tokenizerData.write(to: directory.appendingPathComponent("tokenizer.json"), options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o400],
                ofItemAtPath: directory.appendingPathComponent("tokenizer.json").path)
            for artifact in MiniLMModelPin.modelArtifacts {
                try Task.checkCancellation()
                let destination = result.modelPackageURL.appendingPathComponent(artifact.relativePath)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw MiniLMRuntimeError.artifactUnavailable }
                let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                do {
                    try copyPinnedFile(configuration.modelPackageURL.appendingPathComponent(artifact.relativePath), pin: artifact) {
                        try output.write(contentsOf: $0)
                    }
                    try output.close()
                } catch {
                    try? output.close()
                    throw error
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
            }
            try Task.checkCancellation()
            return result
        } catch {
            try? result.remove()
            if error is CancellationError { throw error }
            throw (error as? MiniLMRuntimeError) ?? .artifactUnavailable
        }
    }

    private static func verifyInventory(_ suppliedRoot: URL) throws {
        var rootInfo = stat()
        guard lstat(suppliedRoot.path, &rootInfo) == 0 else { throw MiniLMRuntimeError.artifactUnavailable }
        guard rootInfo.st_mode & S_IFMT == S_IFDIR else { throw MiniLMRuntimeError.artifactInvalid }
        // Foundation's enumerator canonicalizes ancestor aliases such as /tmp
        // to /private/tmp. Check the supplied root itself before canonicalizing
        // so an actual model-root symlink is still rejected.
        // NSURL deliberately preserves some public aliases when resolving
        // symlinks; realpath matches the enumerator's physical namespace.
        guard let physicalPath = realpath(suppliedRoot.path, nil) else {
            throw MiniLMRuntimeError.artifactUnavailable
        }
        defer { free(physicalPath) }
        let root = URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
        let files = Set(MiniLMModelPin.modelArtifacts.map(\.relativePath))
        let directories: Set<String> = ["Data", "Data/com.apple.CoreML", "Data/com.apple.CoreML/weights"]
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw MiniLMRuntimeError.artifactUnavailable
        }
        var found = Set<String>()
        var count = 0
        for case let item as URL in entries {
            try Task.checkCancellation()
            count += 1
            guard count <= files.count + directories.count,
                  item.path.hasPrefix(root.path + "/") else { throw MiniLMRuntimeError.artifactInvalid }
            let relative = String(item.path.dropFirst(root.path.count + 1))
            var info = stat()
            guard lstat(item.path, &info) == 0 else { throw MiniLMRuntimeError.artifactInvalid }
            if directories.contains(relative) {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw MiniLMRuntimeError.artifactInvalid }
            } else {
                guard files.contains(relative), info.st_mode & S_IFMT == S_IFREG else {
                    throw MiniLMRuntimeError.artifactInvalid
                }
                found.insert(relative)
            }
        }
        guard found == files else { throw MiniLMRuntimeError.artifactInvalid }
    }

    /// The hash is computed from the same bounded bytes written into the private
    /// copy. A changing source can only pass if those copied bytes match the pin.
    private static func copyPinnedFile(_ url: URL, pin: MiniLMModelPin.Artifact,
                                       consume: (Data) throws -> Void) throws {
        try Task.checkCancellation()
        guard url.isFileURL else { throw MiniLMRuntimeError.artifactInvalid }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            throw errno == ELOOP ? MiniLMRuntimeError.artifactInvalid : .artifactUnavailable
        }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == pin.byteCount else { throw MiniLMRuntimeError.artifactInvalid }
        var digest = SHA256()
        var received = 0
        while received < pin.byteCount {
            try Task.checkCancellation()
            let bytes = try input.read(upToCount: min(1_048_576, pin.byteCount - received)) ?? Data()
            guard !bytes.isEmpty else { throw MiniLMRuntimeError.artifactInvalid }
            received += bytes.count
            digest.update(data: bytes)
            try consume(bytes)
        }
        guard (try input.read(upToCount: 1) ?? Data()).isEmpty,
              digest.finalize().map({ String(format: "%02x", $0) }).joined() == pin.sha256 else {
            throw MiniLMRuntimeError.artifactInvalid
        }
        try Task.checkCancellation()
    }

    func remove() throws {
        if removed { return }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        removed = true
    }

    deinit {
        // Explicit close is the joined lifecycle boundary. If an owning caller
        // is abandoned, avoid a blocking filesystem walk on its deinit thread.
        if !removed {
            let abandonedDirectory = directory
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: abandonedDirectory)
            }
        }
    }
}
