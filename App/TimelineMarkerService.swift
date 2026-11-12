import Darwin
import Foundation
import Database
import Shared

public enum TimelineMarkerServiceError: Error, Equatable, LocalizedError {
    case inactiveMarker, screenReferenceUnsupported, unsafeStorage

    public var errorDescription: String? {
        switch self {
        case .inactiveMarker: return "This marker is no longer active."
        case .screenReferenceUnsupported: return "Screen attachment is not available for manual markers yet."
        case .unsafeStorage: return "The private marker storage folder could not be opened safely."
        }
    }
}

public enum TimelineMarkerAction: String, Sendable {
    case create, edit, read, list, delete, undo, saveRule, listRules, saveRange, listRanges
    case spokenObservation, readSpokenObservation, spokenHistory, registerMedia, listMedia
    case applyProposal, readProposal, rangeHistory
    case companionEnrollment, companionCandidate
}

public enum TimelineMarkerOutcome: String, Sendable { case submitted, succeeded, failed, cancelled }

struct TimelineMarkerInitializationFailure: Error {
    let initialization: any Error
    let cleanup: any Error
}

/// One lazy owner for UI and future explicit clients. It does not start recognition, inspect audio,
/// or grant access to a captured screen. Every operation and metric tail is joined before close.
public actor TimelineMarkerService {
    public typealias Metrics = @Sendable (TimelineMarkerAction, TimelineMarkerOutcome) async -> Void
    typealias Store = any ContextStoreProtocol
    private let factory: @Sendable () async throws -> Store
    private let closeStore: @Sendable (Store) async throws -> Void
    private let metrics: Metrics
    private var rulesChanged: @Sendable () -> Void = {}
    private struct ChangeObserver: Sendable {
        let invalidate: @Sendable (UUID?) -> Void
        let drain: @Sendable (UUID?) async -> Void
    }
    private var changeObservers: [UUID: ChangeObserver] = [:]
    private var candidate: Store?
    private var readyStore: Store?
    private var initialization: (id: UUID, task: Task<Store, Error>)?
    private var closing: (id: UUID, task: Task<Void, Error>)?
    private var terminal = false

    private struct Operation: Sendable {
        let cancel: @Sendable () -> Void
        let join: @Sendable () async -> Void
    }
    private var operations: [UUID: Operation] = [:]

    /// Constructing the owner performs no I/O. Store identity and the private directory are acquired on first use.
    public init(storageRoot: URL, nativeStoreID: @escaping @Sendable () async throws -> UUID,
                metrics: @escaping Metrics = { _, _ in }) {
        factory = {
            let nativeID = try await nativeStoreID()
            try Task.checkCancellation()
            let path = try Self.preparePrivateDatabasePath(storageRoot: storageRoot)
            return ContextDatabase(databasePath: path, nativeStoreID: nativeID)
        }
        closeStore = { try await $0.close() }
        self.metrics = metrics
    }

    /// Test seams hold real store acquisition/cleanup; production always uses the private-path initializer.
    init(factory: @escaping @Sendable () async throws -> Store,
         closeStore: @escaping @Sendable (Store) async throws -> Void = { try await $0.close() },
         metrics: @escaping Metrics = { _, _ in }) {
        self.factory = factory; self.closeStore = closeStore; self.metrics = metrics
    }

    public func createManualMarker(_ command: ManualTimelineMarkerCommand) async throws -> TimelineMarker {
        // Exact screen admission requires a current policy bracket. This initial owner only accepts timestamp anchors.
        guard command.screenReference == nil else { throw TimelineMarkerServiceError.screenReferenceUnsupported }
        return try await perform(.create) { store in
            let receipt = try await store.createManualMarker(command)
            await self.notifyChange(receipt.id)
            try Task.checkCancellation()
            guard let current = try await store.marker(id: receipt.id, includeDeleted: false) else {
                throw TimelineMarkerServiceError.inactiveMarker
            }
            return current
        }
    }

    public func marker(id: UUID, includeDeleted: Bool = false) async throws -> TimelineMarker? {
        try await perform(.read) { try await $0.marker(id: id, includeDeleted: includeDeleted) }
    }

    /// Only ServiceContainer acquires this sibling capability. It closes the
    /// audio session owner before closing this context-store owner.
    func audioSessionSettingsStore() async throws -> any AudioSessionSettingsStoreProtocol {
        let store = try await acquireStore()
        guard let audioStore = store as? any AudioSessionSettingsStoreProtocol else {
            throw AudioSessionError.settingsUnavailable
        }
        return audioStore
    }

    public func updateMarker(_ command: TimelineMarkerEditCommand) async throws -> TimelineMarker {
        try await perform(.edit) { store in
            let receipt = try await store.updateMarker(command)
            await self.notifyChange(receipt.id)
            try Task.checkCancellation()
            guard let current = try await store.marker(id: receipt.id, includeDeleted: false) else {
                throw TimelineMarkerServiceError.inactiveMarker
            }
            return current
        }
    }

    public func listMarkers(_ query: TimelineMarkerQuery = .init()) async throws -> TimelineMarkerPage {
        try await perform(.list) { try await $0.listMarkers(query) }
    }

    public func setMarkerDeleted(id: UUID, expectedRevision: UUID, deleted: Bool) async throws -> TimelineMarker {
        try await perform(deleted ? .delete : .undo) {
            let result = try await $0.setMarkerDeleted(id: id, expectedRevision: expectedRevision, deleted: deleted)
            await self.notifyChange(id)
            return result
        }
    }

    /// Invalidate synchronously, then join admitted side effects before acknowledging
    /// a durable change. Callbacks must only invalidate/drain their own work; they
    /// must not wait for a new marker write. nil invalidates every marker on close.
    public func addChangeObserver(invalidate: @escaping @Sendable (UUID?) -> Void,
                                  drain: @escaping @Sendable (UUID?) async -> Void = { _ in }) throws -> UUID {
        guard !terminal else { throw ContextStoreError.closed }
        guard changeObservers.count < 8 else { throw ContextStoreError.capacityExceeded }
        let id = UUID()
        changeObservers[id] = ChangeObserver(invalidate: invalidate, drain: drain)
        return id
    }

    public func removeChangeObserver(_ id: UUID) { changeObservers[id] = nil }

    private func notifyChange(_ markerID: UUID?) async {
        let observers = Array(changeObservers.values)
        for observer in observers { observer.invalidate(markerID) }
        for observer in observers { await observer.drain(markerID) }
    }

    public func saveKeywordRule(_ rule: KeywordRule, expectedRevision: UUID?) async throws -> KeywordRule {
        let signal = rulesChanged
        return try await perform(.saveRule) {
            let saved = try await $0.saveKeywordRule(rule, expectedRevision: expectedRevision)
            signal()
            return saved
        }
    }

    /// The handler only signals an owned command channel. It must not synchronously wait for service reads.
    public func setRulesChangedHandler(_ handler: @escaping @Sendable () -> Void) {
        guard !terminal else { return }
        rulesChanged = handler
    }

    public func listKeywordRules(afterID: UUID? = nil, limit: Int = 100) async throws -> [KeywordRule] {
        try await perform(.listRules) { try await $0.listKeywordRules(afterID: afterID, limit: limit) }
    }

    public func saveContextRange(markerID: UUID, range: MarkerContextRange, expectedRevision: UUID?, expectedMarkerRevision: UUID? = nil) async throws -> MarkerContextRange {
        try await perform(.saveRange) {
            let result = try await $0.saveContextRange(markerID: markerID, range: range, expectedRevision: expectedRevision, expectedMarkerRevision: expectedMarkerRevision)
            await self.notifyChange(markerID)
            return result
        }
    }

    public func listContextRanges(markerID: UUID, limit: Int = 64) async throws -> [MarkerContextRange] {
        try await perform(.listRanges) { try await $0.listContextRanges(markerID: markerID, limit: limit) }
    }

    public func contextProposalHead(markerID: UUID) async throws -> ContextProposalHead? {
        try await perform(.readProposal) { try await $0.contextProposalHead(markerID: markerID) }
    }

    public func applyContextProposal(_ command: ContextProposalCommand) async throws -> ContextProposalReceipt {
        try await perform(.applyProposal) {
            let receipt = try await $0.applyContextProposal(command)
            await self.notifyChange(receipt.markerID)
            return receipt
        }
    }

    /// Retained payloads are validation inputs, not permission to disclose copied source text.
    func contextProposal(jobID: String) async throws -> RetainedContextProposal? {
        try await perform(.readProposal) { try await $0.contextProposal(jobID: jobID) }
    }

    func contextRangeHistory(markerID: UUID, afterSequence: Int64 = 0, limit: Int = 100) async throws -> [ContextRangeRevision] {
        try await perform(.rangeHistory) { try await $0.contextRangeHistory(markerID: markerID, afterSequence: afterSequence, limit: limit) }
    }

    /// The durable store retains the original receipt; presentation receives the latest committed state,
    /// including permanent automatic suppression after a user Undo/delete.
    public func applySpokenObservation(_ command: SpokenObservationCommand) async throws -> SpokenMarkerReceipt {
        try await perform(.spokenObservation) { store in
            let receipt = try await store.applySpokenObservation(command)
            await self.notifyChange(receipt.marker.id)
            guard let current = try await store.spokenMarkerState(occurrenceID: command.occurrenceID) else {
                throw TimelineMarkerServiceError.inactiveMarker
            }
            return current
        }
    }

    public func spokenMarkerState(occurrenceID: UUID) async throws -> SpokenMarkerReceipt? {
        try await perform(.readSpokenObservation) { try await $0.spokenMarkerState(occurrenceID: occurrenceID) }
    }

    public func spokenObservation(occurrenceID: UUID) async throws -> SpokenMarkerObservation? {
        try await perform(.readSpokenObservation) { try await $0.spokenObservation(occurrenceID: occurrenceID) }
    }

    public func spokenObservations(occurrenceID: UUID, afterSequence: Int64 = 0, limit: Int = 100) async throws -> [SpokenMarkerObservation] {
        try await perform(.spokenHistory) { try await $0.spokenObservations(occurrenceID: occurrenceID, afterSequence: afterSequence, limit: limit) }
    }

    public func registerAudioManifest(_ manifest: AudioMediaManifest) async throws -> AudioMediaManifest {
        try await perform(.registerMedia) { try await $0.registerAudioManifest(manifest) }
    }

    public func audioManifests(intersecting anchor: SpokenMarkerAnchor, limit: Int = 100) async throws -> [AudioMediaManifest] {
        try await perform(.listMedia) { try await $0.audioManifests(intersecting: anchor, limit: limit) }
    }
    public func audioManifests(intersecting range: NativeAudioSampleRange, limit: Int = 100) async throws -> [AudioMediaManifest] {
        try await perform(.listMedia) { try await $0.audioManifests(intersecting: range, limit: limit) }
    }

    public func audioManifest(relativePath: String) async throws -> AudioMediaManifest? {
        try await perform(.listMedia) { try await $0.audioManifest(relativePath: relativePath) }
    }

    public func setCompanionEnrollment(enabled: Bool) async throws -> CompanionEnrollment? {
        try await perform(.companionEnrollment) { try await $0.setCompanionEnrollment(enabled: enabled) }
    }

    public func companionEnrollment() async throws -> CompanionEnrollment? {
        try await perform(.companionEnrollment, recordMetrics: false) { try await $0.companionEnrollment() }
    }

    public func companionBatchCandidate(manifestID: UUID) async throws -> CompanionBatchCandidate? {
        try await perform(.companionCandidate, recordMetrics: false) { try await $0.companionBatchCandidate(manifestID: manifestID) }
    }

    public func companionBatchCandidates(now: Date, limit: Int) async throws -> [CompanionBatchCandidate] {
        try await perform(.companionCandidate, recordMetrics: false) { try await $0.companionBatchCandidates(now: now, limit: limit) }
    }

    public func finishCompanionBatch(_ candidate: CompanionBatchCandidate, disposition: CompanionBatchDisposition,
                                     groupID: String?, retryAfter: Date?) async throws {
        try await perform(.companionCandidate) {
            try await $0.finishCompanionBatch(candidate, disposition: disposition, groupID: groupID, retryAfter: retryAfter)
        }
    }

    /// Immediately fences new work; close() subsequently joins all admitted work and releases the store.
    public func beginClose() {
        terminal = true
        for observer in changeObservers.values { observer.invalidate(nil) }
        initialization?.task.cancel()
        for operation in operations.values { operation.cancel() }
    }

    /// Terminal even when cleanup fails. A retry closes the same retained capability; it cannot reopen admission.
    public func close() async throws {
        beginClose()
        if let closing { try await closing.task.value; return }
        let id = UUID()
        let task = Task { try await drainAndClose() }
        closing = (id, task)
        do {
            try await task.value
            if closing?.id == id { closing = nil }
        } catch {
            if closing?.id == id { closing = nil }
            throw error
        }
    }

    private func drainAndClose() async throws {
        let admitted = Array(operations.values)
        for operation in admitted { await operation.join() }
        await notifyChange(nil)
        changeObservers.removeAll()
        if let initialization { _ = await initialization.task.result }
        if let candidate { try await closeStore(candidate) }
        candidate = nil
        readyStore = nil
        initialization = nil
        operations.removeAll()
    }

    private func acquireStore() async throws -> Store {
        guard !terminal else { throw ContextStoreError.closed }
        try Task.checkCancellation()
        if let readyStore { return readyStore }
        let attempt: (id: UUID, task: Task<Store, Error>)
        if let initialization { attempt = initialization }
        else {
            let id = UUID()
            let task = Task<Store, Error> { [self] in
                let store = try await factory()
                candidate = store
                do {
                    try Task.checkCancellation()
                    try await store.initialize()
                    try Task.checkCancellation()
                    return store
                } catch {
                    let initializationError = error
                    do {
                        try await closeStore(store)
                        candidate = nil
                    } catch {
                        terminal = true
                        throw TimelineMarkerInitializationFailure(initialization: initializationError, cleanup: error)
                    }
                    throw initializationError
                }
            }
            attempt = (id, task)
            initialization = attempt
        }
        do {
            let store = try await attempt.task.value
            if initialization?.id == attempt.id { initialization = nil; readyStore = store }
            guard !terminal else { throw ContextStoreError.closed }
            try Task.checkCancellation()
            return store
        } catch {
            if initialization?.id == attempt.id { initialization = nil }
            throw error
        }
    }

    private func perform<T: Sendable>(_ action: TimelineMarkerAction, recordMetrics: Bool = true,
                                      operation: @escaping @Sendable (Store) async throws -> T) async throws -> T {
        guard !terminal else { throw ContextStoreError.closed }
        try Task.checkCancellation()
        let id = UUID()
        let task = Task<T, Error> { [self] in
            var outcomeDelivered = false
            if recordMetrics { await metrics(action, .submitted) }
            do {
                try Task.checkCancellation()
                let store = try await acquireStore()
                try Task.checkCancellation()
                let result = try await operation(store)
                try Task.checkCancellation()
                outcomeDelivered = true
                if recordMetrics { await metrics(action, .succeeded) }
                try Task.checkCancellation()
                return result
            } catch {
                if recordMetrics && !outcomeDelivered { await metrics(action, error is CancellationError ? .cancelled : .failed) }
                throw error
            }
        }
        operations[id] = Operation(cancel: { task.cancel() }, join: { _ = await task.result })
        defer { operations[id] = nil }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !terminal else { throw ContextStoreError.closed }
        try Task.checkCancellation()
        return result
    }

    /// Only the context directory and its database are created. Existing symlinks, hard links or
    /// permissive paths are rejected; no chmod is applied to the recording tree or existing files.
    private nonisolated static func preparePrivateDatabasePath(storageRoot: URL) throws -> String {
        let directory = storageRoot.appendingPathComponent("context", isDirectory: true)
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw TimelineMarkerServiceError.unsafeStorage }
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_mode & 0o777 == 0o700 else { throw TimelineMarkerServiceError.unsafeStorage }

        let path = directory.appendingPathComponent("context.db").path
        var descriptor = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if descriptor < 0 && errno == EEXIST { descriptor = open(path, O_RDWR | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw TimelineMarkerServiceError.unsafeStorage }
        defer { Darwin.close(descriptor) }
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0,
              fileInfo.st_mode & S_IFMT == S_IFREG,
              fileInfo.st_mode & 0o777 == 0o600,
              fileInfo.st_nlink == 1 else { throw TimelineMarkerServiceError.unsafeStorage }
        return path
    }
}
