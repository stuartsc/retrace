import Foundation
import Database
import Shared

/// Credentials are supplied by the App's private settings owner and are never serialized here.
public struct CompanionConfiguration: Sendable {
    public let endpoint: URL
    public let bearerToken: String
    public init(endpoint: URL, bearerToken: String) { self.endpoint = endpoint; self.bearerToken = bearerToken }
}
public struct CompanionControllerStatus: Sendable {
    public enum State: String, Sendable { case unconfigured, ready, offline, suspended, closed }
    public let state: State
    public let pendingCount: Int
    /// Cancellation cannot retract an object already admitted to the transport.
    public let partialDeliveryPossible: Bool
}

/// One App-owned companion lifetime. Views and MCP share this owner; no view creates a worker.
public actor CompanionController {
    public typealias Metric = @Sendable (_ action: String, _ outcome: String) async -> Void
    private struct Session: Sendable {
        let generation: UUID
        let service: CompanionEnrichmentService
        let reader: CompanionEvidenceReader
    }
    private struct Operation: Sendable {
        let cancel: @Sendable () -> Void
        let join: @Sendable () async -> Void
    }
    private let root: URL
    private let nativeStoreID: UUID
    private let databasePath: String
    private let adapter: DataAdapter
    private let recall: ProgressiveRecallService
    private let markers: TimelineMarkerService
    private let verifiedBytes: @Sendable (AudioMediaManifest) async throws -> Data
    private let policy: @Sendable () async throws -> Void
    private let metric: Metric
    private let corrections: CompanionSpeakerCorrectionStore
    private nonisolated let gate = CompanionAdmissionGate()
    private nonisolated let evidenceAdmission = CompanionEvidenceAdmission()
    private nonisolated let signal = CompanionControllerSignal()
    private nonisolated let presentationHolder = CompanionPresentationHolder()
    private nonisolated let speakerChanges = CompanionSpeakerChanges()
    private var contextInitialization: Task<ContextRangePresentationService, Error>?
    private var contextObserver: UUID?
    private var catalog: CompanionSpeakerCatalog?
    private var session: Session?
    private var loop: Task<Void, Never>?
    private var transition: Task<Void, Error>?
    private var closing: Task<Void, Error>?
    private var stopping: Task<Void, Error>?
    private var retiringSession: Session?
    private var retiringLoop: Task<Void, Never>?
    private var operations: [UUID: Operation] = [:]
    private var terminal = false
    private var observer: UUID?
    private var observedRevisions: [UUID: UUID] = [:]
    private var cached = CompanionControllerStatus(state: .unconfigured, pendingCount: 0, partialDeliveryPossible: false)

    public init(storageRoot: URL, nativeStoreID: UUID, databasePath: String, adapter: DataAdapter,
                recall: ProgressiveRecallService, markers: TimelineMarkerService,
                verifiedBytes: @escaping @Sendable (AudioMediaManifest) async throws -> Data,
                policy: @escaping @Sendable () async throws -> Void,
                metric: @escaping Metric = { _, _ in }) {
        root = storageRoot; self.nativeStoreID = nativeStoreID; self.databasePath = databasePath
        self.adapter = adapter; self.recall = recall; self.markers = markers
        self.verifiedBytes = verifiedBytes; self.policy = policy; self.metric = metric
        corrections = .init(root: storageRoot.appendingPathComponent("speaker-corrections"), nativeStoreID: nativeStoreID)
    }
    /// Invoke synchronously before any policy/configuration change, then await configure or close.
    public nonisolated func invalidate() {
        speakerChanges.invalidate(.all)
        gate.replace(allowed: false); evidenceAdmission.invalidate(); presentationHolder.invalidate(); signal.cancel()
    }
    /// Reserve before persisting settings. A queued older transition cannot reactivate
    /// after a newer disconnect or configuration has synchronously revoked it.
    public nonisolated func reserveConfiguration() -> UUID {
        speakerChanges.invalidate(.all)
        let reservation = gate.replace(allowed: false)
        evidenceAdmission.invalidate(); presentationHolder.invalidate(); signal.cancel()
        return reservation
    }
    public nonisolated func textCommitted() { signal.refreshAll() }
    /// Call synchronously for source deletion/hiding, before acknowledging that mutation.
    /// Unlike a policy/configuration revocation, this keeps unrelated work available.
    public nonisolated func sourceChanged(refreshContext: Bool = true) {
        speakerChanges.invalidate(.all)
        evidenceAdmission.invalidate(); presentationHolder.invalidate()
        if refreshContext { signal.refreshAll() }
    }
    /// Native writer callback: every write revokes in-flight work; cached local
    /// presentations can retain results whose source targets are disjoint.
    public nonisolated func sourceChanged(_ mutation: NativeSourceMutation) {
        speakerChanges.invalidate(.source(mutation))
        evidenceAdmission.invalidate(); presentationHolder.invalidate(mutation)
    }
    public nonisolated func markerChanged(_ id: UUID?) {
        evidenceAdmission.invalidate(); presentationHolder.invalidate()
        if let id { signal.mark(id) } else { invalidate() }
    }
    public func status() -> CompanionControllerStatus {
        if signal.invalidated && !terminal {
            return .init(state: .suspended, pendingCount: cached.pendingCount, partialDeliveryPossible: session != nil)
        }
        return cached
    }

    public nonisolated func checkConfigurationReservation(_ reservation: UUID) throws {
        try gate.checkReservation(reservation)
    }
    /// Settings invokes this before publishing newly enabled credentials from a disabled
    /// state. The durable reset must precede that external persistence boundary so a
    /// restart cannot mistake a stale active epoch for the newly authorized interval.
    public func prepareEnrollmentReset(reservation: UUID) async throws {
        guard !terminal else { throw CompanionError.closed }; try Task.checkCancellation()
        try gate.checkReservation(reservation)
        // Preparation participates in the same joined chain as activation and close.
        // A later reservation may supersede this one while its marker metric is held,
        // but it cannot activate until this mutation has finished or been cancelled.
        let previous = transition
        let task = Task {
            if let previous { _ = await previous.result }
            try Task.checkCancellation(); try self.gate.checkReservation(reservation)
            _ = try await self.markers.setCompanionEnrollment(enabled: false)
            try Task.checkCancellation(); try self.gate.checkReservation(reservation)
        }
        transition = task
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    public func configure(_ configuration: CompanionConfiguration?, restartEnrollment: Bool = false) async throws {
        try Task.checkCancellation()
        try await configure(configuration, reservation: reserveConfiguration(), restartEnrollment: restartEnrollment)
    }
    public func configure(_ configuration: CompanionConfiguration?, reservation: UUID, restartEnrollment: Bool = false) async throws {
        try Task.checkCancellation()
        guard !terminal else { throw CompanionError.closed }
        try gate.checkReservation(reservation)
        let previous = transition
        let task = Task {
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            try await self.replaceSession(configuration, generation: reservation, restartEnrollment: restartEnrollment)
        }
        transition = task
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private func replaceSession(_ configuration: CompanionConfiguration?, generation: UUID, restartEnrollment: Bool) async throws {
        try gate.checkReservation(generation)
        try await stopSession()
        guard !terminal else { throw CompanionError.closed }; try Task.checkCancellation()
        try gate.checkReservation(generation)
        guard let configuration else {
            _ = try await markers.setCompanionEnrollment(enabled: false)
            try gate.checkReservation(generation)
            signal.reset(); cached = .init(state: .unconfigured, pendingCount: 0, partialDeliveryPossible: false); return
        }
        try await policy(); try Task.checkCancellation()
        guard !terminal, try await adapter.evidenceStoreID(source: .native) == nativeStoreID else { throw CompanionError.nativeStoreMismatch }
        try gate.checkReservation(generation)
        if restartEnrollment {
            _ = try await markers.setCompanionEnrollment(enabled: false)
            try Task.checkCancellation(); try gate.checkReservation(generation)
        }
        _ = try await markers.setCompanionEnrollment(enabled: true)
        try Task.checkCancellation(); try gate.activate(generation)
        let gate = self.gate, policy = self.policy
        let markers = self.markers, native = nativeStoreID, verified = verifiedBytes
        let admission: @Sendable () async throws -> Void = {
            do {
                try gate.check(generation); try await policy(); try Task.checkCancellation(); try gate.check(generation)
            } catch is CancellationError { throw CancellationError() }
            catch { throw CompanionAdmissionUnavailable.revoked }
        }
        let reader = CompanionEvidenceReader(databasePath: databasePath, nativeStoreID: native,
            adapter: adapter, recall: recall, admission: admission, validateSpeaker: { request, records in
                try await Self.validateSpeaker(request, records: records, nativeStoreID: native, markers: markers, verifiedBytes: verified)
            })
        let transport: CompanionHTTPTransport
        do { transport = try CompanionHTTPTransport(baseURL: configuration.endpoint, bearerToken: configuration.bearerToken,
            admission: { resume in try gate.admit(generation, resume: resume) }) }
        catch { gate.replace(allowed: false); await reader.close(); throw error }
        let importer = CompanionContextImporter(markers: markers)
        let service = CompanionEnrichmentService(root: root.appendingPathComponent("delivery"), nativeStoreID: native,
            transport: transport, revalidate: { request in
                try await admission()
                if let context = request.context {
                    guard let marker = try await markers.marker(id: context.markerID), marker.revision == context.markerRevision,
                          marker.spokenObservation?.status != .withdrawn else { throw CompanionError.staleMarker }
                }
                do { try await reader.revalidate(request) }
                catch where Self.isTerminalSourceFailure(error) { throw CompanionSourceInvalidated.unavailable }
                try await admission()
                if let context = request.context {
                    guard let marker = try await markers.marker(id: context.markerID), marker.revision == context.markerRevision else { throw CompanionError.staleMarker }
                }
            }, importResult: { request, result, requestData, resultData in
                try await admission()
                if result.contextProposal != nil {
                    try await Self.importContext(request: request, result: result, requestData: requestData,
                        resultData: resultData, importer: importer, markers: markers)
                }
                try await admission()
            }, transmissionAdmission: { [evidenceAdmission] in evidenceAdmission.permit() })
        session = .init(generation: generation, service: service, reader: reader)
        if observer == nil {
            observer = try await markers.addChangeObserver(invalidate: { [weak self] id in self?.markerChanged(id) })
        }
        try Task.checkCancellation(); try gate.check(generation)
        signal.reset(); signal.refreshAll()
        cached = .init(state: .ready, pendingCount: 0, partialDeliveryPossible: false)
        loop = Task { await self.run(generation: generation) }
        signal.install(loop)
        await metric("configured", "ready")
    }
    private func stopSession() async throws {
        if let stopping { return try await stopping.value }
        // Retain the retiring capability until every waiter has joined cleanup. If close
        // fails, a later retry still owns the service/reader that need to be drained.
        if let session { retiringSession = session; self.session = nil }
        if let loop { retiringLoop = loop; self.loop = nil }
        let old = retiringSession, oldLoop = retiringLoop
        oldLoop?.cancel()
        let active = Array(operations.values); active.forEach { $0.cancel() }
        let task = Task {
            if let old { await old.service.beginClose() }
            if let oldLoop { await oldLoop.value }
            for operation in active { await operation.join() }
            if let old { try await old.service.close(); await old.reader.close() }
        }
        stopping = task
        do {
            try await task.value
            retiringSession = nil; retiringLoop = nil; stopping = nil
        } catch { stopping = nil; throw error }
    }
    private func run(generation: UUID) async {
        while !Task.isCancelled {
            guard let session, session.generation == generation else { return }
            do {
                try gate.check(generation)
                var refreshFailure: (any Error)?
                do { try await refreshSuperseded(session: session) }
                catch is CancellationError { throw CancellationError() }
                catch { refreshFailure = error }
                do { try await reconcileBatches(session: session) }
                catch is CancellationError { throw CancellationError() }
                catch { if refreshFailure == nil { refreshFailure = error } }
                let dirty = signal.take()
                do {
                    try await CompanionRefreshPass.run(all: dirty.all, ids: dirty.ids,
                        recent: { try await self.markers.listMarkers(.init(limit: 32)).markers.map(\.id) },
                        refresh: { id, force in try await self.refreshOwned(id, force: force, session: session) },
                        retry: { id, force in self.signal.mark(id); if force { self.signal.refreshAll() } },
                        retryAll: { self.signal.refreshAll() },
                        drain: { _ = try await session.service.synchronize(limit: 8) })
                } catch is CancellationError { throw CancellationError() }
                catch { if refreshFailure == nil { refreshFailure = error } }
                if let refreshFailure { throw refreshFailure }
                let count = try await session.service.pendingCount()
                cached = .init(state: .ready, pendingCount: count, partialDeliveryPossible: false)
            } catch is CancellationError { return }
            catch {
                if Task.isCancelled { return }
                cached = .init(state: .offline, pendingCount: cached.pendingCount, partialDeliveryPossible: true)
            }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }
    public func refreshMarker(markerID: UUID) async throws {
        try await perform { session in try await self.refreshOwned(markerID, force: true, session: session) }
    }
    private func refreshOwned(_ id: UUID, force: Bool, session: Session) async throws {
        try gate.check(session.generation)
        guard let marker = try await markers.marker(id: id), marker.spokenObservation?.status != .withdrawn else {
            observedRevisions[id] = nil; return
        }
        if !force, observedRevisions[id] == marker.revision { return }
        let explanation = marker.note ?? ""
        // The recognition explanation is a rolling excerpt, not the full first-pass transcript.
        let query = [marker.title, marker.spokenObservation?.ruleSnapshot.meaning ?? "", marker.spokenObservation?.explanation ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
        let head = try await markers.contextProposalHead(markerID: id)
        let request = try await session.reader.contextRequest(marker: marker, query: query, verbatimExplanation: explanation, expectedProposalHead: head?.revision)
        let existing = try await session.service.contextCandidates(currentHeadJobID: head?.jobID)
        let duplicate = existing.contains { Self.suppressesContextRefresh($0, request: request, currentHead: head) }
        if !duplicate { _ = try await session.service.publish(request) }
        observedRevisions[id] = marker.revision
        if observedRevisions.count > 256 { observedRevisions = [id: marker.revision] }
    }

    private func refreshSuperseded(session: Session) async throws {
        let pending = try await session.service.pendingContextRefreshes(limit: 8)
        var firstFailure: (any Error)?
        for item in pending {
            try Task.checkCancellation(); try gate.check(session.generation)
            do {
                // Deleted/withdrawn markers return without a new request; admission failures
                // retain this receipt for the next bounded pass.
                try await refreshOwned(item.markerID, force: true, session: session)
                try await session.service.completeContextRefresh(jobID: item.jobID)
            } catch is CancellationError { throw CancellationError() }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        if let firstFailure { throw firstFailure }
    }
    nonisolated static func suppressesContextRefresh(_ candidate: CompanionContextCandidate,
        request: CompanionJobRequest, currentHead: ContextProposalHead?) -> Bool {
        guard candidate.state != .invalidated, let a = candidate.request.context, let b = request.context,
              a.markerID == b.markerID, a.markerRevision == b.markerRevision, a.query == b.query,
              a.verbatimExplanation == b.verbatimExplanation, sameWire(a.evidence, b.evidence),
              a.developing == b.developing, a.incomplete == b.incomplete else { return false }
        // Current accepted inputs suppress import-triggered feedback even though the
        // request preceded its own head. Historical accepted inputs cannot suppress a
        // later return to those inputs after a different proposal has become current.
        if candidate.jobID == currentHead?.jobID { return true }
        guard candidate.state != .imported, candidate.state != .acknowledged else { return false }
        return a.expectedProposalHead == b.expectedProposalHead
    }
    nonisolated static func importContext(request: CompanionJobRequest, result: CompanionResult,
        requestData: Data, resultData: Data, importer: CompanionContextImporter, markers: TimelineMarkerService) async throws {
        do {
            try await importer.apply(request: request, result: result, requestData: requestData, resultData: resultData)
        } catch ContextStoreError.revisionConflict {
            guard let source = request.context, try await markers.contextProposal(jobID: result.jobID) == nil else {
                throw ContextStoreError.revisionConflict
            }
            guard let marker = try await markers.marker(id: source.markerID), marker.revision == source.markerRevision else {
                throw CompanionError.staleMarker
            }
            guard try await markers.contextProposalHead(markerID: source.markerID)?.revision != source.expectedProposalHead else {
                throw ContextStoreError.revisionConflict
            }
            throw CompanionProposalSuperseded.marker(source.markerID)
        }
    }

    /// Reconciles only manifest registrations admitted during an explicit enable epoch.
    /// A callback loss, pending first pass, or full outbox leaves the durable candidate due.
    private func reconcileBatches(session: Session) async throws {
        try await CompanionBatchReconciler.run(markers: markers, readFirstPass: { manifest in
            try await session.reader.firstPassRecords(manifest: manifest)
        }, publish: { candidate, rows in
            try await self.recordedBatchOwned(candidate: candidate, records: rows, session: session)
        }, checkAdmission: { try self.gate.check(session.generation) }, terminalSourceFailure: Self.isTerminalSourceFailure)
    }
    /// Full-fragment durable publication. It never acknowledges just the first uncovered
    /// interval, and it never enrolls a pre-enable or disabled-period recording.
    @discardableResult public func recordedBatch(manifest: AudioMediaManifest, records: [AudioTranscription]) async throws -> CompanionBatchPublicationReceipt {
        try await perform { session in
            guard let candidate = try await self.markers.companionBatchCandidate(manifestID: manifest.id),
                  candidate.manifest == manifest else { throw CompanionError.staleEvidence }
            return try await self.recordedBatchOwned(candidate: candidate, records: records, session: session)
        }
    }
    private func recordedBatchOwned(candidate: CompanionBatchCandidate, records: [AudioTranscription], session: Session) async throws -> CompanionBatchPublicationReceipt {
        let manifest = candidate.manifest
        let batch = try CompanionBatchPlan(manifest: manifest, records: records, nativeStoreID: nativeStoreID, enrollmentID: candidate.enrollmentID)
        let data = try await verifiedBytes(manifest)
        try gate.check(session.generation)
        if let previous = try await session.service.latestBatchGroup(batchKey: batch.key) {
            var valid = true
            for id in Set(previous.jobIDs + previous.coverageJobIDs) {
                guard let request = try await session.service.request(jobID: id) else { valid = false; break }
                do { try await session.reader.revalidate(request) }
                catch where Self.isTerminalSourceFailure(error) { valid = false; break }
            }
            if valid {
                // Even an all-covered receipt must revalidate this batch's own original rows.
                try await session.reader.revalidate(batch.request(window: batch.identity, byteCount: data.count))
                try gate.check(session.generation); return previous
            }
        }
        let existing = try await session.service.speakerCoverage(intersecting: batch.identity)
        var covered: [LiveAudioSampleIdentity] = [], dependencyIDs: [String] = []
        for (id, request) in existing {
            do {
                try await session.reader.revalidate(request)
                if let source = request.speaker?.sourceIdentity { covered.append(source); dependencyIDs.append(id) }
            } catch where Self.isTerminalSourceFailure(error) { continue }
        }
        let windows = try CompanionSpeakerWindow.uncovered(batch.identity, covered: covered, limit: 32)
        let requests = windows.map { batch.request(window: $0, byteCount: data.count) }
        // The plan key changes when a revoked coverage dependency is removed. Original
        // batch identity and every old request/result/plan remain immutable.
        let semantic = try batch.planPayload(dependencyIDs: dependencyIDs)
        try await session.reader.revalidate(batch.request(window: batch.identity, byteCount: data.count))
        try gate.check(session.generation)
        return try await session.service.publishGroup(semanticPayload: semantic, requests: requests,
            objects: requests.isEmpty ? [] : [.init(sha256: manifest.sha256, data: data)],
            batchKey: batch.key, coverageJobIDs: dependencyIDs.sorted())
    }
    public func contextRanges() async throws -> ContextRangePresentationService {
        guard !terminal else { throw CompanionError.closed }
        if let contextInitialization { return try await contextInitialization.value }
        if let owner = presentationHolder.get() { return owner }
        let task = Task { [self] in
            let owner = ContextRangePresentationService(markers: markers, validateEvidence: { [weak self] request in
                guard let self else { throw CompanionError.closed }
                try await self.validateRetainedContext(request)
            }, currentEpoch: { [weak self] in
                guard let self else { throw CompanionError.closed }
                return try await self.presentationEpoch()
            }, sourceDependencies: { [weak self] request in
                guard let self else { throw CompanionError.closed }
                return try await self.sourceDependencies(request)
            })
            presentationHolder.set(owner)
            let observer = try await markers.addChangeObserver(invalidate: { [weak self] id in self?.markerChanged(id) })
            guard !terminal, !Task.isCancelled else {
                await markers.removeChangeObserver(observer); await owner.close()
                throw CompanionError.closed
            }
            contextObserver = observer
            return owner
        }
        contextInitialization = task
        do { let value = try await task.value; contextInitialization = nil; return value }
        catch { contextInitialization = nil; presentationHolder.set(nil); throw error }
    }
    private func validateRetainedContext(_ request: CompanionJobRequest) async throws {
        try await performLocal { catalog in try await catalog.reader.revalidate(request) }
    }
    private func sourceDependencies(_ request: CompanionJobRequest) async throws -> NativeSourceDependencies {
        var frames = Set<Int64>(), audio = Set<Int64>(), targets = Set<NativeSourceTarget>()
        for item in request.context?.evidence ?? [] {
            if let screen = item.reference.screen {
                frames.insert(screen.frameID.value); targets.insert(.observation(screen.observationID))
            }
            if let row = item.reference.v23Transcript { audio.insert(row.rowID) }
        }
        for row in request.speaker?.firstPassReferences ?? [] { audio.insert(row.rowID) }
        return try await adapter.nativeSourceDependencies(frameIDs: frames, audioRowIDs: audio).merging(.init(targets: targets))
    }
    private func presentationEpoch() async throws -> String {
        guard !terminal else { throw CompanionError.closed }
        let epoch = evidenceAdmission.snapshot()
        try await policy()
        let source = try await recall.sourceGeneration(source: .native)
        guard !terminal, evidenceAdmission.snapshot() == epoch else { throw CompanionError.staleEvidence }
        return epoch.uuidString + ":" + source
    }
    public func speakerPresentation(jobID: String) async throws -> CompanionSpeakerPresentation? {
        let epoch = speakerChanges.snapshot()
        let result: CompanionSpeakerPresentation? = try await performLocal { catalog in try await self.presentation(jobID, catalog: catalog) }
        try speakerChanges.check(epoch); return result
    }
    public func resolveTurn(_ reference: CompanionTurnReference) async throws -> CompanionTurnPresentation {
        try reference.validate()
        guard reference.nativeStoreID == nativeStoreID else { throw CompanionError.nativeStoreMismatch }
        guard let batch = try await speakerPresentation(jobID: reference.jobID) else { throw CompanionError.staleEvidence }
        return try CompanionTurnResolver.resolve(batch, reference: reference)
    }
    public nonisolated func addSpeakerChangeObserver(invalidate: @escaping @Sendable (CompanionSpeakerChange) -> Void,
                                                     drain: @escaping @Sendable () async -> Void = {}) throws -> UUID {
        try speakerChanges.add(invalidate: invalidate, drain: drain)
    }
    public nonisolated func removeSpeakerChangeObserver(_ id: UUID) { speakerChanges.remove(id) }
    /// App mutation owners may join output teardown after SQLite callbacks have returned.
    public func drainSpeakerOutput() async { await speakerChanges.drain() }
    private func presentation(_ id: String, catalog: CompanionSpeakerCatalog) async throws -> CompanionSpeakerPresentation? {
        guard let (request, result, digest) = try await catalog.retained(id), let speaker = request.speaker,
              let enhancement = result.speakerEnrichment else { return nil }
        let corrections = try await corrections.list(speakerIDs: Set(enhancement.turns.map(\.speakerID)), sourceIdentity: speaker.sourceIdentity)
        let dependencies = try await sourceDependencies(request)
        // Corrections and source rows are separate stores; re-read after gathering both.
        guard let final = try await catalog.retained(id), final.resultSHA256 == digest else { throw CompanionError.staleEvidence }
        let references = enhancement.turns.enumerated().map { index, turn in
            CompanionTurnReference(nativeStoreID: nativeStoreID, jobID: id, resultSHA256: digest, turnIndex: index,
                correctionRevision: corrections.first { $0.speakerID == turn.speakerID }?.revision)
        }
        return .init(jobID: id, nativeStoreID: nativeStoreID, firstPassText: speaker.firstPassText, enhancement: enhancement,
            corrections: corrections, firstPassSourceIdentity: speaker.firstPassSourceIdentity, sourceDependencies: dependencies,
            firstPassReferences: speaker.firstPassReferences, turnReferences: references)
    }
    private struct PageCursor: Codable { let snapshot: String; let offset: Int }
    public func speakerPresentations(from: Date, to: Date, before: String? = nil, limit: Int = 32) async throws -> CompanionSpeakerPage {
        try CompanionBounds.date(from); try CompanionBounds.date(to)
        guard from <= to, (1...64).contains(limit) else { throw CompanionError.invalidPayload }
        let epoch = speakerChanges.snapshot()
        let result: CompanionSpeakerPage = try await performLocal { catalog in
            if var page = try await catalog.indexedPage(from: from, to: to, before: before, limit: limit) {
                var items: [CompanionSpeakerPresentation] = [], scanned = 0
                while true {
                    for id in page.jobIDs {
                        scanned += 1
                        do {
                            if let item = try await self.presentation(id, catalog: catalog) { items.append(item) }
                        } catch where Self.isUnavailableCatalogEntry(error) { continue }
                    }
                    guard items.count < limit, scanned < 64, let next = page.nextCursor else {
                        return .init(items: items, nextCursor: page.nextCursor, incomplete: true)
                    }
                    guard let following = try await catalog.indexedPage(from: from, to: to, before: next,
                        limit: min(limit - items.count, 64 - scanned)) else { throw CompanionError.staleEvidence }
                    page = following
                }
            }
            let requests = try catalog.requests().filter { _, request in
                guard let source = request.speaker?.sourceIdentity else { return false }
                let start = source.approximateOrigin.addingTimeInterval(Double(source.startSample) / 16000)
                let end = start.addingTimeInterval(Double(source.sampleCount) / 16000)
                return start <= to && end >= from
            }
            let snapshot = CompanionWire.digest(try CompanionWire.encode(requests.map(\.0) + [String(from.timeIntervalSince1970), String(to.timeIntervalSince1970)]))
            var offset = 0
            if let before {
                guard before.utf8.count <= 2048, let data = Data(base64Encoded: before) else { throw CompanionError.invalidPayload }
                let cursor = try CompanionWire.decode(PageCursor.self, data: data, limit: 1024)
                guard cursor.snapshot == snapshot, (0...requests.count).contains(cursor.offset) else { throw CompanionError.staleEvidence }
                offset = cursor.offset
            }
            var items: [CompanionSpeakerPresentation] = [], scanned = 0
            while offset < requests.count && items.count < limit && scanned < 64 {
                let id = requests[offset].0; offset += 1; scanned += 1
                do {
                    if let item = try await self.presentation(id, catalog: catalog) { items.append(item) }
                } catch where Self.isUnavailableCatalogEntry(error) {
                    // A terminally stale individual recording cannot starve later retained
                    // jobs. The outer owner still checks cancellation, policy and epoch.
                    continue
                }
            }
            let cursor = offset < requests.count ? try CompanionWire.encode(PageCursor(snapshot: snapshot, offset: offset)).base64EncodedString() : nil
            return .init(items: items, nextCursor: cursor, incomplete: true)
        }
        try speakerChanges.check(epoch); return result
    }
    public func correctSpeaker(_ command: CompanionSpeakerCorrectionCommand) async throws -> CompanionSpeakerCorrection {
        let permit = evidenceAdmission.permit()
        return try await performLocal { catalog in
            guard let current = try await self.presentation(command.jobID, catalog: catalog),
                  current.enhancement.turns.contains(where: { $0.speakerID == command.speakerID }) else { throw CompanionError.staleEvidence }
            let saved = try await self.corrections.apply(command, sourceIdentity: current.enhancement.sourceIdentity,
                admission: { try Task.checkCancellation(); try permit {} })
            self.speakerChanges.invalidate(.correction(jobID: command.jobID, speakerID: command.speakerID))
            self.presentationHolder.invalidate()
            await self.speakerChanges.drain()
            guard try await self.presentation(command.jobID, catalog: catalog) != nil else { throw CompanionError.staleEvidence }
            await self.metric("speaker_correction", "saved")
            return saved
        }
    }
    public func close() async throws {
        if let closing { return try await closing.value }
        terminal = true; speakerChanges.invalidate(.all, close: true)
        invalidate(); transition?.cancel(); contextInitialization?.cancel()
        let transition = self.transition
        let task = Task {
            if let transition { _ = await transition.result }
            try await self.finishClose()
        }
        closing = task
        do { try await task.value }
        catch { closing = nil; throw error }
    }
    private func finishClose() async throws {
        await speakerChanges.drain()
        try await stopSession()
        if let observer { await markers.removeChangeObserver(observer); self.observer = nil }
        if let contextInitialization { _ = await contextInitialization.result }
        if let presentation = presentationHolder.get() { await presentation.close(); presentationHolder.set(nil) }
        if let contextObserver { await markers.removeChangeObserver(contextObserver); self.contextObserver = nil }
        if let catalog { await catalog.reader.close(); self.catalog = nil }
        await corrections.close()
        cached = .init(state: .closed, pendingCount: cached.pendingCount, partialDeliveryPossible: cached.partialDeliveryPossible)
    }
    private nonisolated static func isUnavailableCatalogEntry(_ error: any Error) -> Bool {
        switch error {
        case CompanionError.staleEvidence,
             EvidenceUnavailableReason.evidenceDeleted, EvidenceUnavailableReason.recordingMissing,
             EvidenceUnavailableReason.integrityFailure, MarkerAudioMediaError.invalidMedia,
             MarkerAudioMediaError.staleMarker:
            return true
        default: return false
        }
    }
    private nonisolated static func isTerminalSourceFailure(_ error: any Error) -> Bool {
        switch error {
        case CompanionError.staleEvidence, CompanionError.nativeStoreMismatch,
             EvidenceUnavailableReason.notPermitted, EvidenceUnavailableReason.evidenceDeleted,
             EvidenceUnavailableReason.recordingMissing, EvidenceUnavailableReason.integrityFailure,
             MarkerAudioMediaError.invalidMedia, MarkerAudioMediaError.staleMarker:
            return true
        default: return false
        }
    }
    private func perform<T: Sendable>(_ body: @escaping @Sendable (Session) async throws -> T) async throws -> T {
        guard !terminal else { throw CompanionError.closed }
        guard let session else { throw CompanionError.unavailable }
        try gate.check(session.generation); try Task.checkCancellation()
        let evidencePermit = evidenceAdmission.permit()
        let id = UUID(), task = Task {
            let result = try await body(session)
            try Task.checkCancellation(); try self.gate.check(session.generation); try evidencePermit {}
            await self.metric("operation", "succeeded")
            try Task.checkCancellation(); try self.gate.check(session.generation); try evidencePermit {}
            return result
        }
        operations[id] = .init(cancel: { task.cancel() }, join: { _ = await task.result })
        defer { operations[id] = nil }
        return try await withTaskCancellationHandler(operation: {
            let result = try await task.value
            try Task.checkCancellation(); try self.gate.check(session.generation); try evidencePermit {}; return result
        }, onCancel: { task.cancel() })
    }
    /// Local retained reads remain usable while delivery is unconfigured or offline.
    /// They share current source/policy invalidation and joined shutdown with the owner.
    private func localCatalog() throws -> CompanionSpeakerCatalog {
        guard !terminal else { throw CompanionError.closed }
        if let catalog { return catalog }
        let native = nativeStoreID, markers = self.markers, verified = verifiedBytes
        let reader = CompanionEvidenceReader(databasePath: databasePath, nativeStoreID: native,
            adapter: adapter, recall: recall, admission: policy, validateSpeaker: { request, records in
                try await Self.validateSpeaker(request, records: records, nativeStoreID: native, markers: markers, verifiedBytes: verified)
            })
        let value = CompanionSpeakerCatalog(spool: .init(root: root.appendingPathComponent("delivery"), nativeStoreID: native), reader: reader)
        catalog = value
        return value
    }
    private func performLocal<T: Sendable>(_ body: @escaping @Sendable (CompanionSpeakerCatalog) async throws -> T) async throws -> T {
        guard operations.count < 32 else { throw CompanionError.capacityExceeded }
        let catalog = try localCatalog(), permit = evidenceAdmission.permit()
        try Task.checkCancellation()
        let generation = try await recall.sourceGeneration(source: .native)
        guard !terminal else { throw CompanionError.closed }
        try permit {}
        let id = UUID(), task = Task {
            try await self.policy(); try permit {}; try Task.checkCancellation()
            let result = try await body(catalog)
            try await self.policy(); try permit {}; try Task.checkCancellation()
            guard try await self.recall.sourceGeneration(source: .native) == generation else { throw CompanionError.staleEvidence }
            await self.metric("operation", "succeeded")
            try Task.checkCancellation(); try permit {}; return result
        }
        operations[id] = .init(cancel: { task.cancel() }, join: { _ = await task.result })
        defer { operations[id] = nil }
        return try await withTaskCancellationHandler(operation: {
            let result = try await task.value
            guard !terminal else { throw CompanionError.closed }
            try Task.checkCancellation(); try permit {}; return result
        }, onCancel: { task.cancel() })
    }
    nonisolated static func sameWire<T: Encodable>(_ a: T, _ b: T) -> Bool {
        guard let left = try? CompanionWire.encode(a), let right = try? CompanionWire.encode(b) else { return false }
        return left == right
    }
    nonisolated static func mediaID(_ manifest: AudioMediaManifest) -> String {
        CompanionWire.digest(Data(manifest.id.uuidString.lowercased().utf8))
    }
    private nonisolated static func validateSpeaker(_ request: CompanionSpeakerRequest, records: [AudioTranscription], nativeStoreID: UUID,
        markers: TimelineMarkerService, verifiedBytes: @Sendable (AudioMediaManifest) async throws -> Data) async throws {
        let source = request.sourceIdentity
        let manifests = try await markers.audioManifests(intersecting: NativeAudioSampleRange(nativeStoreID: nativeStoreID, identity: source), limit: 100)
        var verified = Set<UUID>()
        for slice in request.media {
            guard let manifest = manifests.first(where: { mediaID($0) == slice.mediaID && $0.sha256 == slice.sha256 }),
                  manifest.source == .microphone,
                  !records.isEmpty, records.allSatisfy({ $0.batchAudioPath == manifest.relativePath && $0.source == .microphone }),
                  manifest.sourceRanges.contains(where: { range in
                      range.source.recordingGeneration == source.recordingGeneration && range.source.continuityID == source.continuityID &&
                      CompanionWire.sameWireDate(range.source.approximateOrigin, source.approximateOrigin) && range.source.startSample <= slice.sourceStartSample &&
                      range.source.startSample + range.source.sampleCount >= slice.sourceStartSample + slice.countSamples &&
                      range.batchStartSample + slice.sourceStartSample - range.source.startSample == slice.offsetSamples
                  }) else { throw CompanionError.staleEvidence }
            if verified.insert(manifest.id).inserted {
                let bytes = try await verifiedBytes(manifest)
                guard bytes.count == slice.byteCount else { throw CompanionError.staleEvidence }
            }
        }
    }
}

/// A mutation revokes prepared transmissions synchronously without cancelling the
/// context importer that may itself be committing a proposed range. Resume and mutation
/// share this lock, so deletion acknowledgement cannot race a previously prepared upload.
final class CompanionEvidenceAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = UUID()
    func invalidate() { lock.lock(); revision = UUID(); lock.unlock() }
    func snapshot() -> UUID { lock.lock(); defer { lock.unlock() }; return revision }
    func permit() -> CompanionHTTPTransport.Admission {
        lock.lock(); let expected = revision; lock.unlock()
        return { [self] resume in
            lock.lock(); defer { lock.unlock() }
            guard revision == expected else { throw CompanionTransmissionRevoked.changed }
            resume()
        }
    }
}

private final class CompanionControllerSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var ids = Set<UUID>()
    private var all = false
    private var revoked = false
    var invalidated: Bool { lock.lock(); defer { lock.unlock() }; return revoked }
    func cancel() { lock.lock(); revoked = true; let task = task; lock.unlock(); task?.cancel() }
    func reset() { lock.lock(); defer { lock.unlock() }; revoked = false; task = nil }
    func install(_ task: Task<Void, Never>?) { lock.lock(); self.task = task; let cancel = revoked; lock.unlock(); if cancel { task?.cancel() } }
    func mark(_ id: UUID) { lock.lock(); defer { lock.unlock() }; if ids.count < 256 { ids.insert(id) } else { all = true } }
    func refreshAll() { lock.lock(); defer { lock.unlock() }; all = true }
    func take() -> (all: Bool, ids: Set<UUID>) { lock.lock(); defer { lock.unlock() }; let result = (all, ids); all = false; ids = []; return result }
}

private final class CompanionPresentationHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: ContextRangePresentationService?
    func get() -> ContextRangePresentationService? { lock.withLock { owner } }
    func set(_ value: ContextRangePresentationService?) { lock.withLock { owner = value } }
    func invalidate(_ mutation: NativeSourceMutation = .all) { get()?.invalidate(mutation) }
}
