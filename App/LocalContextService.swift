import Foundation
import Shared
import Database

public struct LocalContextInstant: Sendable {
    public let wall: Date
    public let uptime: TimeInterval
    public init(wall: Date, uptime: TimeInterval) { self.wall = wall; self.uptime = uptime }
    public static var live: LocalContextInstant { .init(wall: Date(), uptime: ProcessInfo.processInfo.systemUptime) }
}

/// App-owned, local-only contextual presentation. One optional model request at a
/// time; meaningful identical text reuses a bounded topic, while every new support
/// is read and admitted canonically. No background timers or automatic model opt-in.
public actor LocalContextService {
    private struct Prepared: Sendable {
        let request: LocalContextRequest
        let admission: LocalContextAdmission
        let snapshot: LocalContextSnapshot
        let start: LocalContextInstant
        let lifetime: TimeInterval
    }
    private struct Work: Sendable {
        let id: UUID
        let request: LocalContextRequest
        let task: Task<Prepared, Error>
    }
    private struct TopicCache {
        let key: String
        let proposal: LocalContextTopicProposal?
        let status: LocalContextModelStatus
        let start: LocalContextInstant
    }
    private let governor: (any BackgroundProcessingProtocol)?
    private let reader: LocalContextEvidenceReader
    private let externalAllowed: Bool
    private let model: any LocalContextTopicModel
    private let clock: @Sendable () -> LocalContextInstant
    private let recordMetric: @Sendable (LocalContextMetric) async -> Void
    private var work: Work?
    private var generation = UUID()
    private var cached: Prepared?
    private var topicCache: TopicCache?
    private var closed = false
    private var stopTask: Task<Void, Never>?
    private var activeOperations = 0
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(database: DatabaseManager, evidence: ProgressiveRecallService,
                governor: (any BackgroundProcessingProtocol)? = nil,
                model: any LocalContextTopicModel = FoundationModelsLocalContextModel(),
                externalRevalidator: LocalContextExternalRevalidator? = nil,
                clock: @escaping @Sendable () -> LocalContextInstant = { .live },
                recordMetric: @escaping @Sendable (LocalContextMetric) async -> Void) {
        self.governor = governor
        self.reader = .init(database: database, evidence: evidence, externalRevalidator: externalRevalidator)
        self.externalAllowed = externalRevalidator != nil
        self.model = model; self.clock = clock; self.recordMetric = recordMetric
    }

    public func refresh(_ request: LocalContextRequest) async throws -> LocalContextSnapshot {
        guard !closed else { throw LocalContextError.stopped }
        // Unowned provider payloads are not part of this request at all. They
        // cannot suppress local cards, alter coalescing, or supply currentness.
        let request = externalAllowed ? request : LocalContextRequest(screenReferences: request.screenReferences,
            activityReferences: request.activityReferences, foundationModelsEnabled: request.foundationModelsEnabled)
        try LocalContextEvidenceReader.validate(request)
        try Task.checkCancellation()
        activeOperations += 1
        defer { finishOperation() }
        if let cached, cached.request == request, isFresh(cached, at: clock()) {
            let owner = generation
            await recordMetric(.init(operation: .reused, modelStatus: cached.snapshot.modelStatus, itemCount: cached.snapshot.items.count))
            return try await publish(cached, owner: owner)
        }
        let current: Work
        if let existing = work, existing.request == request {
            current = existing
        } else {
            let previous = work?.task
            previous?.cancel()
            let id = UUID()
            generation = id; cached = nil
            let task = Task { [weak self] () async throws -> Prepared in
                // Superseding work owns and joins the previous model/metrics.
                if let previous { _ = await previous.result }
                guard let self else { throw LocalContextError.stopped }
                return try await self.prepare(request, owner: id)
            }
            current = Work(id: id, request: request, task: task)
            work = current
        }
        do {
            let prepared = try await withTaskCancellationHandler {
                try await current.task.value
            } onCancel: { current.task.cancel() }
            let result = try await publish(prepared, owner: current.id)
            if work?.id == current.id { work = nil }
            return result
        } catch {
            if work?.id == current.id { work = nil }
            if generation == current.id { cached = nil }
            throw error
        }
    }

    /// Revalidates exact support, policy epoch, source identity and expiry. UI
    /// should clear its previous card when this returns nil or throws.
    public func current() async throws -> LocalContextSnapshot? {
        guard !closed else { throw LocalContextError.stopped }
        try Task.checkCancellation()
        activeOperations += 1
        defer { finishOperation() }
        guard let current = cached else { return nil }
        let owner = generation
        guard isFresh(current, at: clock()) else {
            cached = nil
            await recordMetric(.init(operation: .expired, modelStatus: current.snapshot.modelStatus, itemCount: 0))
            try checkOwner(owner)
            return nil
        }
        return try await publish(current, owner: owner)
    }

    /// Terminal and coalesced. Cancellation of a close caller does not detach the
    /// owning cleanup. Active model work, final metrics and public read operations
    /// all finish before the last stopped callback and return. No callbacks follow.
    public func stop() async {
        if let stopTask { await stopTask.value; return }
        guard !closed else { return }
        closed = true; generation = UUID(); cached = nil; topicCache = nil
        let previous = work?.task
        previous?.cancel()
        let task = Task { [self] in
            if let previous { _ = await previous.result }
            await joinOperations()
            await recordMetric(.init(operation: .stopped, modelStatus: .disabled, itemCount: 0))
            finishStop()
        }
        stopTask = task
        await task.value
    }

    private func prepareOptionalTopic(_ inputs: [LocalContextModelCandidate]) async throws -> LocalContextTopicProposal? {
        guard let governor else { return try await model.topic(for: inputs) }
        // Deterministic source cards must not wait five minutes for an optional model.
        guard let permit = try await governor.tryAcquire(.localSummary) else { return nil }
        do {
            let result = try await withTaskCancellationHandler {
                try await BackgroundProcessingContext.$permit.withValue(permit) {
                    try BackgroundProcessingContext.checkCancellation()
                    let result = try await model.topic(for: inputs)
                    try BackgroundProcessingContext.checkCancellation()
                    return result
                }
            } onCancel: { permit.cancellation.cancel() }
            await governor.release(permit)
            return result
        } catch {
            await governor.release(permit)
            // A revoked optional-model permit does not invalidate the source
            // cards. Caller cancellation still retires the owning request.
            if error is CancellationError, !Task.isCancelled, permit.cancellation.isCancelled { return nil }
            throw error
        }
    }

    private func prepare(_ request: LocalContextRequest, owner: UUID) async throws -> Prepared {
        try checkOwner(owner)
        let started = clock()
        guard Self.valid(started) else { throw LocalContextError.expired }
        var status = LocalContextModelStatus.disabled
        do {
            let admitted = try await reader.read(request, now: started.wall)
            try checkOwner(owner)
            var items = admitted.items
            let localItems = admitted.items.filter { $0.kind != .externalSignal }
            let inputs = localItems.enumerated().map {
                LocalContextModelCandidate(id: $0.offset, title: $0.element.title, excerpt: $0.element.excerpt ?? "")
            }
            var proposal: LocalContextTopicProposal?
            if request.foundationModelsEnabled {
                if inputs.isEmpty { status = .noInput }
                else {
                    let key = try LocalContextText.identity(inputs)
                    if let reuse = topicCache, reuse.key == key, Self.fresh(start: reuse.start, lifetime: 120, now: clock()) {
                        proposal = reuse.proposal; status = reuse.status
                    } else {
                        do {
                            let generated = try await prepareOptionalTopic(inputs)
                            if let generated {
                                if let validated = Self.validate(generated, inputCount: inputs.count) {
                                    proposal = validated; status = .used
                                } else { status = .rejected }
                            } else { status = .unavailable }
                        } catch {
                            try checkOwner(owner)
                            if error is CancellationError { throw error }
                            status = .failed
                        }
                        try checkOwner(owner)
                        topicCache = TopicCache(key: key, proposal: proposal, status: status, start: started)
                    }
                }
            }
            try checkOwner(owner)
            if let proposal {
                var supports: [LocalContextSupport] = []
                for id in proposal.supportIDs {
                    for support in localItems[id].supports where !supports.contains(support) { supports.append(support) }
                }
                let identity = try LocalContextText.identity(supports)
                items.insert(.init(id: "topic-" + identity, kind: .topicInterpretation, title: proposal.label,
                    supports: supports), at: 0)
            }
            let externalLimit = admitted.request.externalSnapshot.map { $0.expiresAt.timeIntervalSince(started.wall) } ?? 120
            let lifetime = min(120, externalLimit)
            guard Self.fresh(start: started, lifetime: lifetime, now: clock()) else { throw LocalContextError.expired }
            let snapshot = LocalContextSnapshot(revision: UUID(), generatedAt: started.wall,
                expiresAt: started.wall.addingTimeInterval(lifetime), expiresAtUptime: started.uptime + lifetime,
                externalProviders: admitted.externalProviders,
                screenTextTruncated: admitted.screenTextTruncated, modelStatus: status, items: Array(items.prefix(6)))
            await recordMetric(.init(operation: .prepared, modelStatus: status, itemCount: snapshot.items.count))
            try checkOwner(owner)
            // publish() revalidates after this awaited telemetry and model call.
            return Prepared(request: request, admission: admitted, snapshot: snapshot, start: started, lifetime: lifetime)
        } catch {
            await recordMetric(.init(operation: .failed, modelStatus: status, itemCount: 0))
            throw error
        }
    }

    private func publish(_ prepared: Prepared, owner: UUID) async throws -> LocalContextSnapshot {
        do {
            try checkOwner(owner)
            guard isFresh(prepared, at: clock()) else { throw LocalContextError.expired }
            try await reader.revalidate(prepared.admission, now: clock().wall)
            // This is also the public task-hop boundary: a completed child task
            // cannot make a superseded/cancelled response successful again.
            try checkOwner(owner)
            guard isFresh(prepared, at: clock()) else { throw LocalContextError.expired }
            cached = prepared
            return prepared.snapshot
        } catch {
            if generation == owner { cached = nil }
            throw error
        }
    }

    private func checkOwner(_ owner: UUID) throws {
        try Task.checkCancellation()
        guard !closed else { throw LocalContextError.stopped }
        guard generation == owner else { throw CancellationError() }
    }
    private func isFresh(_ item: Prepared, at now: LocalContextInstant) -> Bool {
        Self.fresh(start: item.start, lifetime: item.lifetime, now: now)
    }
    private static func valid(_ instant: LocalContextInstant) -> Bool {
        instant.wall.timeIntervalSince1970.isFinite && instant.uptime.isFinite && instant.uptime >= 0
    }
    private static func fresh(start: LocalContextInstant, lifetime: TimeInterval, now: LocalContextInstant) -> Bool {
        valid(start) && valid(now) && lifetime > 0 && lifetime <= 120 && now.wall >= start.wall && now.uptime >= start.uptime
            && now.wall < start.wall.addingTimeInterval(lifetime) && now.uptime - start.uptime < lifetime
    }
    private static func validate(_ proposal: LocalContextTopicProposal, inputCount: Int) -> LocalContextTopicProposal? {
        let label = proposal.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(label.utf8.count), label.split(whereSeparator: \.isWhitespace).count <= 5,
              !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !label.contains(where: { "[]<>`".contains($0) }), !label.contains("://"),
              (1...4).contains(proposal.supportIDs.count), Set(proposal.supportIDs).count == proposal.supportIDs.count,
              proposal.supportIDs.allSatisfy({ (0..<inputCount).contains($0) }) else { return nil }
        return .init(label: label, supportIDs: proposal.supportIDs)
    }
    private func finishOperation() {
        activeOperations -= 1
        if activeOperations == 0 { operationWaiters.forEach { $0.resume() }; operationWaiters.removeAll() }
    }
    private func joinOperations() async {
        if activeOperations > 0 { await withCheckedContinuation { operationWaiters.append($0) } }
    }
    private func finishStop() { work = nil; stopTask = nil }
}
