import Darwin
import Foundation
import Security
import Shared

public struct RetraceClientSummary: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let capabilities: Set<RetraceCapability>
    public let expiresAt: Date?
}
public struct RetraceIssuedClient: Sendable {
    public let summary: RetraceClientSummary
    /// Returned exactly once. The owner persists only a SHA-256 digest.
    public let bearerToken: String
}
public struct RetraceCommandAccessState: Sendable {
    public let enabled: Bool
    public let listening: Bool
    public let clients: [RetraceClientSummary]
    public let lastError: String?
}

/// Lazy App-owned client provisioning and native listener lifecycle. Creating this service
/// does no I/O and grants no client access. A missing configuration defaults to disabled.
public actor RetraceCommandAccessService {
    private struct Configuration: Codable {
        var enabled = false
        var clients: [RetraceClientGrant] = []
        var names: [String: String] = [:]
    }
    private let storageRoot: URL
    private let makeHandlers: @Sendable () async throws -> [RetraceCommandHandler]
    private var configuration: Configuration?
    private var directory: URL?
    private var revision = UUID()
    private var transition: (id: UUID, task: Task<Void, Error>)?
    private var dispatcher: RetraceCommandDispatcher?
    private var bridge: RetraceNativeBridge?
    private var terminal = false
    private var lastError: String?

    public init(storageRoot: URL, handlers: @escaping @Sendable () async throws -> [RetraceCommandHandler]) {
        self.storageRoot = storageRoot; makeHandlers = handlers
    }
    public func state() async -> RetraceCommandAccessState {
        do { try load() } catch { lastError = "Private client configuration could not be opened safely." }
        let config = configuration ?? Configuration()
        return .init(enabled: config.enabled, listening: await bridge?.isListening() ?? false, clients: config.clients.map { summary($0, config: config) }, lastError: lastError)
    }
    /// Called by the App owner after initialization; restores only a previously enabled configuration.
    public func restore() async throws { try load(); try await reconcile() }

    public func createClient(name: String, capabilities: Set<RetraceCapability>, expiresAt: Date? = nil) async throws -> RetraceIssuedClient {
        guard !terminal else { throw RetraceCommandError.unavailable }
        try load()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 128, !name.contains("\0"), !capabilities.isEmpty,
              expiresAt.map({ $0.timeIntervalSince1970.isFinite && $0 > Date() }) ?? true,
              var config = configuration, config.clients.count < 64 else { throw RetraceCommandError.invalidArguments }
        var bytes = [UInt8](repeating: 0, count: 48)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw RetraceCommandError.unavailable }
        let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let id = UUID().uuidString
        let grant = RetraceClientGrant(clientID: id, tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: capabilities, expiresAt: expiresAt)
        config.clients.append(grant); config.names[id] = name
        try save(config)
        try? await reconcile()
        return .init(summary: summary(grant, config: config), bearerToken: token)
    }

    public func revokeClient(id: String) async throws {
        guard !terminal else { throw RetraceCommandError.unavailable }
        try load()
        guard var config = configuration, config.clients.contains(where: { $0.clientID == id }) else { throw RetraceCommandError.invalidArguments }
        config.clients.removeAll { $0.clientID == id }; config.names[id] = nil
        do { try save(config) }
        catch {
            // Stop live access if revocation cannot be made durable. Do not claim persisted success.
            configuration?.enabled = false; revision = UUID()
            transition?.task.cancel()
            if let transition { _ = await transition.task.result }
            await stopListener()
            lastError = "Revocation could not be saved. Live access stopped; retry before restarting Retrace."
            throw error
        }
        try await reconcile()
    }

    public func setEnabled(_ enabled: Bool) async throws {
        guard !terminal else { throw RetraceCommandError.unavailable }
        try load()
        guard var config = configuration else { throw RetraceCommandError.unavailable }
        guard !enabled || !config.clients.isEmpty else { throw RetraceCommandError.invalidArguments }
        config.enabled = enabled
        do { try save(config) }
        catch {
            if !enabled {
                configuration?.enabled = false; revision = UUID()
                transition?.task.cancel()
                if let transition { _ = await transition.task.result }
                await stopListener()
            }
            throw error
        }
        try await reconcile()
    }

    public func close() async {
        terminal = true
        transition?.task.cancel()
        if let transition { _ = await transition.task.result }
        transition = nil
        await stopListener()
    }

    private func reconcile() async throws {
        guard !terminal else { throw RetraceCommandError.unavailable }
        if let transition {
            try await transition.task.value
            if self.transition?.id == transition.id { self.transition = nil }
            // A changed configuration while the task was suspended needs a fresh reconciliation.
            try await reconcile()
            return
        }
        let id = UUID()
        let task = Task { [self] in
            while !terminal {
                let currentRevision = revision
                guard let config = configuration else { throw RetraceCommandError.unavailable }
                if !config.enabled || config.clients.isEmpty { await stopListener() }
                else if let dispatcher { try await dispatcher.replaceGrants(config.clients) }
                else {
                    let handlers = try await makeHandlers()
                    try Task.checkCancellation()
                    guard !terminal, currentRevision == revision, let directory else { continue }
                    let dispatcher = try RetraceCommandDispatcher(directory: directory, grants: config.clients, handlers: handlers)
                    let bridge = RetraceNativeBridge(dispatcher: dispatcher)
                    do {
                        try await bridge.start()
                        guard !terminal, currentRevision == revision else { await bridge.close(); await dispatcher.close(); continue }
                        self.dispatcher = dispatcher; self.bridge = bridge
                    } catch { await bridge.close(); await dispatcher.close(); throw error }
                }
                if currentRevision == revision { break }
            }
            try Task.checkCancellation()
        }
        transition = (id, task)
        do {
            try await task.value
            if transition?.id == id { transition = nil }
            lastError = nil
        } catch {
            if transition?.id == id { transition = nil }
            lastError = "Native MCP access is unavailable. Check the private listener and client configuration."
            throw error
        }
    }
    private func stopListener() async {
        if let bridge { await bridge.close(); self.bridge = nil }
        if let dispatcher { await dispatcher.close(); self.dispatcher = nil }
    }
    private func summary(_ grant: RetraceClientGrant, config: Configuration) -> RetraceClientSummary {
        .init(id: grant.clientID, name: config.names[grant.clientID] ?? grant.clientID,
              capabilities: grant.capabilities, expiresAt: grant.expiresAt)
    }
    private func load() throws {
        if configuration != nil { return }
        let context = storageRoot.appendingPathComponent("context", isDirectory: true)
        try Self.ensurePrivateDirectory(context)
        let directory = context.appendingPathComponent("native-access", isDirectory: true)
        try Self.ensurePrivateDirectory(directory)
        self.directory = directory
        let file = directory.appendingPathComponent("clients.json")
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
        if descriptor < 0 {
            guard errno == ENOENT else { throw RetraceCommandError.unavailable }
            configuration = Configuration()
            return
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size <= 65_536 else { throw RetraceCommandError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let bytes = try handle.readToEnd() ?? Data()
        guard bytes.count <= 65_536 else { throw RetraceCommandError.invalidArguments }
        let config = try RetraceWire.decoder().decode(Configuration.self, from: bytes)
        guard config.clients.count <= 64, config.names.count <= 64,
              Set(config.clients.map(\.clientID)).count == config.clients.count,
              Set(config.clients.map(\.tokenSHA256)).count == config.clients.count else { throw RetraceCommandError.invalidArguments }
        configuration = config
    }
    private func save(_ config: Configuration) throws {
        guard let directory else { throw RetraceCommandError.unavailable }
        let bytes = try RetraceWire.encoder().encode(config)
        guard bytes.count <= 65_536 else { throw RetraceCommandError.invalidArguments }
        let temporary = directory.appendingPathComponent(".clients-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw RetraceCommandError.unavailable }
        defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: bytes)
        guard fsync(descriptor) == 0, rename(temporary.path, directory.appendingPathComponent("clients.json").path) == 0 else { throw RetraceCommandError.unavailable }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw RetraceCommandError.unavailable }
        defer { Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw RetraceCommandError.unavailable }
        configuration = config; revision = UUID()
    }
    private static func ensurePrivateDirectory(_ directory: URL) throws {
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw RetraceCommandError.unavailable }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700, info.st_uid == getuid() else { throw RetraceCommandError.unavailable }
    }
}
