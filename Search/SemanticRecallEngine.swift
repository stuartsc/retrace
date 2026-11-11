import Foundation
import Shared

/// Optional local semantic work and retrieval. Production dependencies are only
/// Shared protocols. This actor never chooses a model path, downloads artifacts,
/// opens a database, or broadens the canonical evidence owner's permissions.
public actor SemanticRecallEngine {
    private let governor: (any BackgroundProcessingProtocol)?
    private let store: any SemanticRecallStoreProtocol
    private let makeRuntime: @Sendable () -> any LocalEmbeddingRuntimeProtocol
    private let recordMetric: @Sendable (SemanticRecallMetric) -> Void
    private let configuration: SemanticRecallEngineConfiguration
    private var runtime: (any LocalEmbeddingRuntimeProtocol)?
    private var cursor: SemanticRecallCursor?
    private var phase: SemanticRecallEngineStatus.Phase = .stopped
    private var queryStage: SemanticRecallEngineStatus.QueryStage = .idle
    private var coverage: SemanticRecallCoverage?
    private var lastFailure: String?
    private var lifecycleID = UUID()
    private var starting: (id: UUID, task: Task<Void, Error>)?
    private var stopping: (id: UUID, task: Task<Void, Error>)?
    private var background: (id: UUID, task: Task<Void, Never>)?
    private var query: (id: UUID, task: Task<SemanticRecallResponse, Error>)?
    private var foregroundRequests: Set<UUID> = []
    private var latestQuestion: UUID?
    private var refreshPending = false
    private var outstandingClaim: SemanticRecallClaim?
    private var claimCleanup: (id: UUID, task: Task<Void, Error>)?

    #if DEBUG
    private var publicResponseCheckpoint: (@Sendable () async -> Void)?
    func setPublicResponseCheckpointForTesting(_ checkpoint: (@Sendable () async -> Void)?) {
        publicResponseCheckpoint = checkpoint
    }
    #endif

    public init(store: any SemanticRecallStoreProtocol,
                makeRuntime: @escaping @Sendable () -> any LocalEmbeddingRuntimeProtocol,
                recordMetric: @escaping @Sendable (SemanticRecallMetric) -> Void,
                configuration: SemanticRecallEngineConfiguration = .init(),
                governor: (any BackgroundProcessingProtocol)? = nil) {
        self.governor = governor
        self.store = store; self.makeRuntime = makeRuntime; self.recordMetric = recordMetric; self.configuration = configuration
    }

    /// Explicit enable/start is required. A question or captured text cannot
    /// reactivate a stopped engine. Repeated starts join one owning operation.
    public func start() async throws {
        try Task.checkCancellation()
        try validateConfiguration()
        if let stopping { try await stopping.task.value }
        if phase == .ready { return }
        if phase == .failed, runtime != nil { try await stop() }
        let operation: (id: UUID, task: Task<Void, Error>)
        if let current = starting { operation = current }
        else {
            let id = UUID(); lifecycleID = id; phase = .starting; lastFailure = nil
            operation = (id, Task(priority: .utility) { try await self.openRuntime(owner: id) })
            starting = operation
        }
        defer { if starting?.id == operation.id { starting = nil } }
        // A cancelled waiter does not cancel the shared owner. stop() does.
        try await operation.task.value
        try Task.checkCancellation()
    }

    /// Coalesced notification after meaningful evidence/policy changes. No idle
    /// polling, frame-by-frame model call or unbounded pending-task queue.
    public func refresh() {
        guard phase == .ready else { return }
        refreshPending = true
        launchBackgroundIfPossible()
    }

    public func status() -> SemanticRecallEngineStatus {
        .init(phase: phase, queryStage: queryStage, indexing: background != nil,
              coverage: coverage, lastFailure: lastFailure)
    }

    public func search(_ request: SemanticRecallQuestion) async throws -> SemanticRecallResponse {
        guard phase == .ready || phase == .starting else { throw SemanticRecallEngineError.stopped }
        try validateQuestion(request)
        try Task.checkCancellation()
        let id = UUID(); foregroundRequests.insert(id); latestQuestion = id
        defer {
            foregroundRequests.remove(id)
            if query?.id == id { query = nil; queryStage = .idle }
            if latestQuestion == id { latestQuestion = nil }
            if phase == .ready { refreshPending = true; launchBackgroundIfPossible() }
        }
        if let previous = query { previous.task.cancel(); _ = await previous.task.result }
        if let active = background { active.task.cancel(); await active.task.value }
        try await drainOutstandingClaim()
        try checkQuestion(id)
        if let starting { try await starting.task.value }
        try checkQuestion(id)
        guard phase == .ready, let runtime else { throw SemanticRecallEngineError.stopped }
        let owner = lifecycleID
        let task = Task(priority: .userInitiated) { try await self.performQuery(request, id: id, owner: owner, runtime: runtime) }
        query = (id, task)
        let response = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        #if DEBUG
        if let publicResponseCheckpoint { await publicResponseCheckpoint() }
        #endif
        // The owned task may already be successful when cancellation, stop or
        // a newer question wins the actor hop back to this public method.
        try checkQuestion(id); try checkOwner(owner)
        return response
    }

    /// Cancellation-independent joined teardown. App must call this before
    /// closing the canonical database or draining its metric inbox.
    public func stop() async throws {
        if let current = stopping { try await current.task.value; return }
        if phase == .stopped, runtime == nil { return }
        phase = .stopping; lifecycleID = UUID(); latestQuestion = nil; refreshPending = false
        let startTask = starting?.task, backgroundTask = background?.task, queryTask = query?.task
        startTask?.cancel(); backgroundTask?.cancel(); queryTask?.cancel()
        let id = UUID()
        let operation = Task { try await self.finishStopping(startTask: startTask, backgroundTask: backgroundTask, queryTask: queryTask) }
        stopping = (id, operation)
        defer { if stopping?.id == id { stopping = nil } }
        try await operation.value
    }

    private func openRuntime(owner: UUID) async throws {
        let began = ContinuousClock.now
        try Task.checkCancellation()
        guard phase == .starting, lifecycleID == owner else { throw CancellationError() }
        let candidate = makeRuntime(); runtime = candidate
        do {
            let descriptor = try await candidate.prepare()
            guard descriptor == .miniLM else { throw SemanticRecallEngineError.incompatibleRuntime }
            try checkOwner(owner)
            let created = try await store.beginSemanticRecall(transformation: .miniLMNativeV1, leaseDuration: configuration.leaseDuration)
            try checkOwner(owner)
            let initial = try await store.semanticRecallCoverage(cursor: created)
            try checkOwner(owner)
            cursor = created; coverage = initial; phase = .ready; lastFailure = nil
            emit(.startup, .completed, since: began)
            refreshPending = true; launchBackgroundIfPossible()
        } catch {
            // Retain ownership after failed cleanup so stop() can retry.
            do { try await candidate.close(); runtime = nil }
            catch { lastFailure = "cleanupFailed" }
            if phase != .stopping { phase = .failed; lastFailure = failureCode(error) }
            emit(.startup, outcome(error), since: began)
            throw error
        }
    }

    private func finishStopping(startTask: Task<Void, Error>?, backgroundTask: Task<Void, Never>?,
                                queryTask: Task<SemanticRecallResponse, Error>?) async throws {
        let began = ContinuousClock.now
        if let startTask { _ = await startTask.result }
        if let backgroundTask { await backgroundTask.value }
        if let queryTask { _ = await queryTask.result }
        do {
            try await drainOutstandingClaim()
            try await runtime?.close()
            runtime = nil; cursor = nil; starting = nil; background = nil; query = nil
            queryStage = .idle; phase = .stopped; lastFailure = nil
            emit(.shutdown, .completed, since: began)
        } catch {
            phase = .failed; lastFailure = "cleanupFailed"
            emit(.shutdown, .failed, since: began)
            throw SemanticRecallEngineError.cleanupFailed
        }
    }

    private func launchBackgroundIfPossible() {
        guard phase == .ready, foregroundRequests.isEmpty, background == nil, refreshPending else { return }
        refreshPending = false
        let id = UUID(), owner = lifecycleID
        background = (id, Task(priority: .utility) { await self.runBackground(id: id, owner: owner) })
    }

    private func runBackground(id: UUID, owner: UUID) async {
        defer {
            if background?.id == id { background = nil }
            launchBackgroundIfPossible()
        }
        var pages = 0
        do {
            while true {
                try checkOwner(owner)
                guard foregroundRequests.isEmpty, let runtime else { throw CancellationError() }
                let more: Bool
                do {
                    more = try await BackgroundProcessingContext.run(governor: governor, kind: .indexing) {
                        try await self.performWork(owner: owner, runtime: runtime)
                    }
                } catch is CancellationError {
                    try checkOwner(owner)
                    // Activity revoked the permit; retain durable work and wait for another quiet interval.
                    continue
                }
                if !more { return }
                pages += 1
                if pages % configuration.backgroundPagesPerYield == 0, configuration.backgroundYieldMilliseconds > 0 {
                    try await Task.sleep(for: .milliseconds(configuration.backgroundYieldMilliseconds))
                } else { await Task.yield() }
            }
        } catch {
            if !(error is CancellationError), phase == .ready { lastFailure = failureCode(error) }
        }
    }

    private func performWork(owner: UUID, runtime: any LocalEmbeddingRuntimeProtocol) async throws -> Bool {
        let began = ContinuousClock.now
        var inspected = 0
        do {
            try await drainOutstandingClaim()
            try checkOwner(owner)
            let current = try await renewCursor(owner: owner)
            let page = try await store.claimSemanticRecallWork(cursor: current,
                maximumInspected: configuration.maximumInspectedPerWorkPage, executionDuration: 30)
            inspected = page.inspectedCount; coverage = page.coverage; outstandingClaim = page.input?.claim
            try checkOwner(owner)
            guard let input = page.input else {
                emit(.work, .completed, inspected: inspected, partial: !page.coverage.fullyIndexed, since: began)
                return !page.coverage.caughtUp && page.inspectedCount > 0
            }
            let windows: [SemanticRecallVectorWindow]
            do {
                let embedded = try await runtime.embed(input.text)
                try checkOwner(owner)
                try validateBatch(embedded, text: input.text)
                windows = try embedded.windows.map {
                    .init(tokenStart: $0.tokenStart, tokenEnd: $0.tokenEnd, inputUTF16Range: $0.inputUTF16Range,
                          spans: try input.spans(for: $0.inputUTF16Range), vector: $0.vector)
                }
            } catch LocalEmbeddingError.emptyInput {
                // The database independently permits this only when the actual
                // canonical page has no substantive text after normalization.
                windows = []
            }
            try checkOwner(owner)
            _ = try await store.publishSemanticRecall(claim: input.claim, windows: windows)
            outstandingClaim = nil
            try checkOwner(owner)
            coverage = try await store.semanticRecallCoverage(cursor: current)
            try checkOwner(owner)
            lastFailure = nil
            emit(.work, .completed, windows: windows.count, inspected: inspected,
                 partial: !(coverage?.fullyIndexed ?? false), since: began)
            return !(coverage?.caughtUp ?? false)
        } catch {
            do { try await drainOutstandingClaim() }
            catch {
                lastFailure = "cleanupFailed"
                emit(.work, .failed, inspected: inspected, since: began)
                throw SemanticRecallEngineError.cleanupFailed
            }
            emit(.work, outcome(error), inspected: inspected, since: began)
            if phase == .ready, lifecycleID == owner, isSourceRace(error) {
                // Retained cursor/work is independently revalidated next time.
                // The next page observes deletion/revision/policy state anew.
                return true
            }
            throw error
        }
    }

    private func performQuery(_ request: SemanticRecallQuestion, id: UUID, owner: UUID,
                              runtime: any LocalEmbeddingRuntimeProtocol) async throws -> SemanticRecallResponse {
        let began = ContinuousClock.now
        var inspected = 0, scanned = 0
        do {
            try checkQuestion(id); try checkOwner(owner)
            let current = try await renewCursor(owner: owner)
            queryStage = .embeddingQuestion
            let queryVectors = try await runtime.embed(request.text)
            try checkQuestion(id); try checkOwner(owner)
            try validateBatch(queryVectors, text: request.text)
            queryStage = .findingMoments
            var next: SemanticRecallVectorCursor?
            var stamp: SemanticRecallReadStamp?
            var best: [ScreenEvidenceRef: SemanticRecallMatch] = [:]
            var pageNumber = 0
            repeat {
                try checkQuestion(id); try checkOwner(owner)
                let page = try await store.readSemanticRecallVectors(request: .init(filter: request.filter, cursor: next))
                try checkQuestion(id); try checkOwner(owner)
                if let stamp, stamp != page.stamp { throw SemanticRecallEngineError.staleEvidence }
                stamp = page.stamp; next = page.nextCursor; pageNumber += 1
                inspected += page.inspectedCount; scanned += page.candidates.count
                for candidate in page.candidates {
                    try Task.checkCancellation()
                    try validateVector(candidate.window.vector)
                    var score = -Double.infinity
                    var matchedRange = queryVectors.windows[0].inputUTF16Range
                    for window in queryVectors.windows {
                        let cosine = zip(window.vector, candidate.window.vector).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
                        if cosine > score { score = cosine; matchedRange = window.inputUTF16Range }
                    }
                    let match = SemanticRecallMatch(reference: candidate.reference, captureTimestamp: candidate.captureTimestamp,
                        cosine: max(-1, min(1, score)), spans: candidate.window.spans, queryUTF16Range: matchedRange,
                        pageOrdinal: candidate.pageOrdinal, windowOrdinal: candidate.windowOrdinal)
                    if let old = best[candidate.reference], !precedes(match, old) { continue }
                    best[candidate.reference] = match
                    if best.count > request.limit, let worst = best.values.max(by: precedes) { best.removeValue(forKey: worst.reference) }
                }
                await Task.yield()
            } while next != nil && pageNumber < request.maximumPages &&
                began.duration(to: .now) < .seconds(request.maximumDuration)
            try checkQuestion(id); try checkOwner(owner)
            guard let stamp else { throw SemanticRecallEngineError.staleEvidence }
            let currentCoverage = try await store.semanticRecallCoverage(cursor: current)
            try checkQuestion(id); try checkOwner(owner)
            coverage = currentCoverage
            let matches = best.values.sorted(by: precedes)
            queryStage = .checkingEvidence
            try await store.revalidateSemanticRecallRead(stamp: stamp)
            try checkQuestion(id); try checkOwner(owner)
            let elapsed = milliseconds(since: began)
            emit(.query, .completed, windows: scanned, inspected: inspected,
                 partial: next != nil || !currentCoverage.fullyIndexed, since: began)
            return .init(matches: matches, stamp: stamp, coverage: currentCoverage, scanComplete: next == nil,
                          inspectedCount: inspected, scannedWindowCount: scanned, elapsedMilliseconds: elapsed)
        } catch {
            emit(.query, outcome(error), windows: scanned, inspected: inspected, since: began)
            if isSourceRace(error) { throw SemanticRecallEngineError.staleEvidence }
            throw error
        }
    }

    /// Own the exact canonical claim until cancellation succeeds. The owning
    /// task is independent of a cancelled foreground/background waiter and is
    /// coalesced when stop/preemption reaches the same cleanup concurrently.
    private func drainOutstandingClaim() async throws {
        guard let retained = outstandingClaim else { return }
        let operation: (id: UUID, task: Task<Void, Error>)
        if let current = claimCleanup { operation = current }
        else {
            let id = UUID(), store = store
            operation = (id, Task { try await store.cancelSemanticRecall(claim: retained) })
            claimCleanup = operation
        }
        defer { if claimCleanup?.id == operation.id { claimCleanup = nil } }
        do { try await operation.task.value }
        catch { lastFailure = "cleanupFailed"; throw SemanticRecallEngineError.cleanupFailed }
        if outstandingClaim?.attemptID == retained.attemptID { outstandingClaim = nil }
    }

    private func renewCursor(owner: UUID) async throws -> SemanticRecallCursor {
        let current = try await store.beginSemanticRecall(transformation: .miniLMNativeV1, leaseDuration: configuration.leaseDuration)
        try checkOwner(owner)
        cursor = current
        return current
    }
    private func checkOwner(_ id: UUID) throws {
        try BackgroundProcessingContext.checkCancellation()
        try Task.checkCancellation()
        guard lifecycleID == id, phase == .ready || phase == .starting else { throw CancellationError() }
    }
    private func checkQuestion(_ id: UUID) throws {
        try Task.checkCancellation()
        guard latestQuestion == id, phase == .ready || phase == .starting else { throw CancellationError() }
    }
    private func validateConfiguration() throws {
        guard (1...64).contains(configuration.backgroundPagesPerYield), (0...1000).contains(configuration.backgroundYieldMilliseconds),
              (1...200).contains(configuration.maximumInspectedPerWorkPage), configuration.leaseDuration.isFinite,
              configuration.leaseDuration > 0, configuration.leaseDuration <= 7 * 24 * 60 * 60 else {
            throw SemanticRecallEngineError.invalidConfiguration
        }
    }
    private func validateQuestion(_ request: SemanticRecallQuestion) throws {
        guard request.text.utf16.prefix(32_769).count <= 32_768,
              !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1...100).contains(request.limit),
              (1...128).contains(request.maximumPages), request.maximumDuration.isFinite,
              request.maximumDuration > 0, request.maximumDuration <= 30,
              request.filter.appBundleIDs.count <= 64,
              Set(request.filter.appBundleIDs).count == request.filter.appBundleIDs.count,
              request.filter.appBundleIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }),
              request.filter.excludedAppBundleIDs.count <= 64,
              Set(request.filter.excludedAppBundleIDs).count == request.filter.excludedAppBundleIDs.count,
              request.filter.excludedAppBundleIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }),
              [request.filter.from, request.filter.through].compactMap({ $0 }).allSatisfy({
                  let milliseconds = $0.timeIntervalSince1970 * 1000
                  return milliseconds.isFinite && milliseconds > Double(Int64.min) && milliseconds < Double(Int64.max)
              }) else { throw SemanticRecallEngineError.invalidQuestion }
        if let from = request.filter.from, let through = request.filter.through, from > through {
            throw SemanticRecallEngineError.invalidQuestion
        }
    }
    private func validateBatch(_ batch: LocalEmbeddingBatch, text: String) throws {
        guard batch.descriptor == .miniLM, !batch.windows.isEmpty, batch.windows.count <= 32,
              batch.windows.first?.tokenStart == 0,
              batch.windows.first?.inputUTF16Range.location == 0 else { throw SemanticRecallEngineError.incompatibleRuntime }
        let count = text.utf16.count
        var previous: LocalEmbeddingWindow?
        for (index, window) in batch.windows.enumerated() {
            guard window.tokenStart >= 0, window.tokenEnd > window.tokenStart, window.tokenEnd - window.tokenStart <= 224,
                  index == batch.windows.count - 1 || window.tokenEnd - window.tokenStart >= 176,
                  window.inputUTF16Range.location >= 0, window.inputUTF16Range.length > 0,
                  window.inputUTF16Range.location <= count, window.inputUTF16Range.length <= count - window.inputUTF16Range.location else {
                throw LocalEmbeddingError.invalidOutput
            }
            if let previous {
                let end = previous.inputUTF16Range.location + previous.inputUTF16Range.length
                guard window.tokenStart == previous.tokenEnd - 32, window.tokenEnd > previous.tokenEnd,
                      window.inputUTF16Range.location >= previous.inputUTF16Range.location,
                      window.inputUTF16Range.location <= end,
                      window.inputUTF16Range.location + window.inputUTF16Range.length > end else {
                    throw LocalEmbeddingError.invalidOutput
                }
            }
            try validateVector(window.vector)
            previous = window
        }
        guard let final = previous, final.inputUTF16Range.location + final.inputUTF16Range.length == count else {
            throw LocalEmbeddingError.invalidOutput
        }
    }
    private func validateVector(_ vector: [Float]) throws {
        guard vector.count == 384, vector.allSatisfy(\.isFinite) else { throw LocalEmbeddingError.invalidOutput }
        let norm = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard abs(norm - 1) <= 0.0002 else { throw LocalEmbeddingError.invalidOutput }
    }
    private func precedes(_ lhs: SemanticRecallMatch, _ rhs: SemanticRecallMatch) -> Bool {
        if lhs.cosine != rhs.cosine { return lhs.cosine > rhs.cosine }
        if lhs.captureTimestamp != rhs.captureTimestamp { return lhs.captureTimestamp > rhs.captureTimestamp }
        if lhs.reference != rhs.reference { return lhs.reference.observationID.uuidString < rhs.reference.observationID.uuidString }
        if lhs.pageOrdinal != rhs.pageOrdinal { return lhs.pageOrdinal < rhs.pageOrdinal }
        return lhs.windowOrdinal < rhs.windowOrdinal
    }
    private func isSourceRace(_ error: Error) -> Bool {
        if let error = error as? SemanticRecallError { return [.sourceChanged, .invalidClaim, .staleRead].contains(error) }
        if let error = error as? ScreenEvidenceAdmissionError { return [.sourceChanged, .stalePolicy, .invalidReference, .notPermitted].contains(error) }
        return false
    }
    private func failureCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? LocalEmbeddingError { return error.rawValue }
        if let error = error as? SemanticRecallError { return error.rawValue }
        if let error = error as? ScreenEvidenceAdmissionError { return error.rawValue }
        if let error = error as? SemanticRecallEngineError { return error.rawValue }
        return "unavailable"
    }
    private func outcome(_ error: Error) -> SemanticRecallMetric.Outcome {
        if error is CancellationError { return .cancelled }
        return .failed
    }
    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return max(0, Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000)
    }
    private func emit(_ operation: SemanticRecallMetric.Operation, _ outcome: SemanticRecallMetric.Outcome,
                      windows: Int = 0, inspected: Int = 0, partial: Bool = false, since began: ContinuousClock.Instant) {
        recordMetric(.init(operation: operation, outcome: outcome, windowCount: windows,
                           inspectedCount: inspected, partial: partial, elapsedMilliseconds: milliseconds(since: began)))
    }
}
