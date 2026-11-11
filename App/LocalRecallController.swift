import Database
import Darwin
import Foundation
import Search
import Shared

public struct LocalRecallSnapshot: Sendable {
    public let modelPackageURL: URL?
    public let engine: SemanticRecallEngineStatus?
    public let failure: String?
    public let lastSearchWasPartial: Bool?

    public var summary: String {
        guard modelPackageURL != nil else {
            return failure == nil ? "Meaning search off" : "Meaning search unavailable"
        }
        guard let engine else { return "Preparing meaning search" }
        guard engine.phase == .ready else { return "Meaning search \(engine.phase.rawValue)" }
        guard let coverage = engine.coverage else { return "Screen indexing pending" }
        let progress = coverage.caughtUp ? "caught up" : "indexing"
        let skipped = coverage.skippedObservations == 0 ? "" : " · \(coverage.skippedObservations) unavailable"
        return "Screen meaning index: \(coverage.completedObservations) · \(progress)\(skipped)"
    }
}

public enum LocalRecallControllerError: String, Error, Sendable { case shuttingDown, invalidModelLocation }

public enum LocalRecallSettings {
    public static let modelPackagePathKey = "localRecallModelPackagePathV1"
}

/// Owns one optional local runtime and its joined metric delivery. Neither a
/// question nor captured content can enable a disabled owner or choose a model.
public actor LocalRecallController {
    typealias RuntimeFactory = @Sendable (LocalEmbeddingConfiguration,
        @escaping @Sendable (LocalEmbeddingMetric) -> Void) -> any LocalEmbeddingRuntimeProtocol
    private let governor: (any BackgroundProcessingProtocol)?
    private let database: DatabaseManager
    private let cacheRoot: URL
    private let makeRuntime: RuntimeFactory
    private let acknowledgeConfiguration: @Sendable (URL?) -> Void
    private var engine: SemanticRecallEngine?
    private var inbox: LocalRecallMetricsInbox?
    private var metrics: Task<Void, Never>?
    private var modelPackageURL: URL?
    private var failure: String?
    private var lastSearchWasPartial: Bool?
    private var mutation: (id: UUID, task: Task<Void, Error>)?
    private var shutdownTask: Task<Void, Error>?
    private var closing = false
    private var configurationGeneration = UUID()
    private var queryID = UUID()

    #if DEBUG
    private var runtimeFactoryForTesting: RuntimeFactory?
    private var configurationWaitCheckpointForTesting: (@Sendable () async -> Void)?
    func setRuntimeFactoryForTesting(_ factory: @escaping RuntimeFactory) throws {
        guard !closing, engine == nil, mutation == nil else { throw LocalRecallControllerError.shuttingDown }
        runtimeFactoryForTesting = factory
    }
    func isClosingForTesting() -> Bool { closing }
    func setConfigurationWaitCheckpointForTesting(_ checkpoint: (@Sendable () async -> Void)?) {
        precondition(mutation == nil)
        configurationWaitCheckpointForTesting = checkpoint
    }
    #endif

    public init(database: DatabaseManager, cacheRoot: URL, governor: (any BackgroundProcessingProtocol)? = nil,
                acknowledgeConfiguration: @escaping @Sendable (URL?) -> Void = { _ in }) {
        self.governor = governor
        self.database = database; self.cacheRoot = cacheRoot
        self.makeRuntime = { LocalEmbeddingRuntime(configuration: $0, recordMetric: $1) }
        self.acknowledgeConfiguration = acknowledgeConfiguration
    }

    init(database: DatabaseManager, cacheRoot: URL, makeRuntime: @escaping RuntimeFactory) {
        self.governor = nil
        self.database = database; self.cacheRoot = cacheRoot; self.makeRuntime = makeRuntime
        self.acknowledgeConfiguration = { _ in }
    }

    /// Nil disables the candidate. Settings persist only the acknowledged state.
    public func configure(modelPackageURL selected: URL?) async throws {
        guard !closing else { throw LocalRecallControllerError.shuttingDown }
        let generation = configurationGeneration
        if let selected {
            guard selected.isFileURL, selected.path.hasPrefix("/"), selected.path.utf8.count <= 8_192 else {
                throw LocalRecallControllerError.invalidModelLocation
            }
        }
        while let active = mutation {
            #if DEBUG
            await configurationWaitCheckpointForTesting?()
            #endif
            _ = await active.task.result
            if mutation?.id == active.id { mutation = nil }
            guard !closing, configurationGeneration == generation else { throw LocalRecallControllerError.shuttingDown }
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        let id = UUID()
        let task = Task { try await self.replaceRuntime(selected) }
        mutation = (id, task)
        defer { if mutation?.id == id { mutation = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard !closing, configurationGeneration == generation else { throw LocalRecallControllerError.shuttingDown }
    }

    public func snapshot() async -> LocalRecallSnapshot {
        for _ in 0..<2 {
            let selected = modelPackageURL
            let current = engine
            let state = await current?.status()
            // A later configuration cannot be labelled with the earlier status.
            if selected == modelPackageURL, current === engine {
                return .init(modelPackageURL: selected, engine: state, failure: failure,
                             lastSearchWasPartial: lastSearchWasPartial)
            }
        }
        // Frequent reconfiguration must not create an unbounded recursive read.
        return .init(modelPackageURL: modelPackageURL, engine: nil, failure: failure,
                     lastSearchWasPartial: nil)
    }

    public func search(_ question: SemanticRecallQuestion) async throws -> SemanticRecallResponse? {
        guard !closing, modelPackageURL != nil, let current = engine else { return nil }
        let id = UUID(); queryID = id
        let response = try await current.search(question)
        try Task.checkCancellation()
        guard !closing, queryID == id, current === engine, modelPackageURL != nil else { throw CancellationError() }
        try await database.revalidateSemanticRecallRead(stamp: response.stamp)
        try Task.checkCancellation()
        guard !closing, queryID == id, current === engine else { throw CancellationError() }
        lastSearchWasPartial = !response.scanComplete || !response.coverage.fullyIndexed
        return response
    }

    public func refresh() async { if !closing { await engine?.refresh() } }

    /// Terminal fence first; then cancel/join startup, model work and all metrics
    /// before ServiceContainer may close the canonical SQLite writer.
    public func shutdown() async throws {
        if let shutdownTask { try await shutdownTask.value; return }
        closing = true; queryID = UUID(); configurationGeneration = UUID(); mutation?.task.cancel()
        let pending = mutation?.task
        let task = Task {
            if let pending { _ = await pending.result }
            try await self.closeRuntime()
        }
        shutdownTask = task
        do { try await task.value }
        catch { shutdownTask = nil; throw error }
    }

    /// Only ServiceContainer's serialized, nonterminal initialization retry uses
    /// this. A successful join releases the fence but never selects a model.
    func reopenAfterJoinedClose() async throws {
        try Task.checkCancellation()
        guard closing else { return }
        guard let shutdownTask else { throw LocalRecallControllerError.shuttingDown }
        try await shutdownTask.value
        // Shutdown already joined the task; its configure caller may still be
        // resuming to clear this token. Retire only that completed generation.
        if let pending = mutation {
            _ = await pending.task.result
            if mutation?.id == pending.id { mutation = nil }
        }
        try Task.checkCancellation()
        guard closing, engine == nil, inbox == nil, metrics == nil,
              modelPackageURL == nil, mutation == nil else { throw LocalRecallControllerError.shuttingDown }
        self.shutdownTask = nil
        queryID = UUID()
        failure = nil; lastSearchWasPartial = nil
        closing = false
    }

    private func replaceRuntime(_ selected: URL?) async throws {
        queryID = UUID()
        try await closeRuntime()
        acknowledgeConfiguration(nil)
        failure = nil; lastSearchWasPartial = nil
        guard let selected else { return }
        try Task.checkCancellation()
        guard !closing else { throw LocalRecallControllerError.shuttingDown }
        let configuration = LocalEmbeddingConfiguration(modelPackageURL: selected,
            tokenizerURL: try LocalEmbeddingResources.tokenizerURL(), privateCacheParentURL: cacheRoot)
        let delivery = LocalRecallMetricsInbox()
        inbox = delivery
        let database = self.database
        metrics = Task {
            await delivery.deliver { metadata in
                try await database.recordMetricEvent(metricType: .semanticRecall, metadata: metadata)
            }
        }
        #if DEBUG
        let factory = runtimeFactoryForTesting ?? makeRuntime
        #else
        let factory = makeRuntime
        #endif
        let candidate = SemanticRecallEngine(store: database,
            makeRuntime: { factory(configuration, { delivery.send($0) }) },
            recordMetric: { delivery.send($0) }, governor: governor)
        engine = candidate
        do {
            try prepareCacheParent()
            try await candidate.start()
            try Task.checkCancellation()
            guard !closing else { throw LocalRecallControllerError.shuttingDown }
            modelPackageURL = selected
            acknowledgeConfiguration(selected)
        } catch {
            failure = error is CancellationError ? "cancelled" : "modelUnavailable"
            // A failed cleanup retains its owning engine/inbox for shutdown retry.
            do { try await closeRuntime() }
            catch { failure = "cleanupFailed"; throw error }
            throw error
        }
    }

    private func closeRuntime() async throws {
        modelPackageURL = nil; queryID = UUID()
        try await engine?.stop()
        engine = nil
        let delivery = inbox, task = metrics
        delivery?.finish()
        await task?.value
        inbox = nil; metrics = nil
    }

    /// Lazy and actor-owned: disabled search never touches the filesystem. Do not
    /// chmod an existing user path or accept a symlink as this cache directory.
    private func prepareCacheParent() throws {
        guard cacheRoot.isFileURL else { throw LocalEmbeddingError.artifactInvalid }
        var info = stat()
        if lstat(cacheRoot.path, &info) != 0 {
            guard errno == ENOENT else { throw LocalEmbeddingError.artifactUnavailable }
            try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        guard lstat(cacheRoot.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw LocalEmbeddingError.artifactInvalid
        }
    }
}
