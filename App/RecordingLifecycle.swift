import Foundation

enum RecordingLifecycleError: Error, Equatable { case shuttingDown }

/// Serializes device startup and teardown without blocking a thread. A replacement
/// start cannot acquire devices until cancelled startup has finished its rollback.
actor RecordingLifecycle {
    nonisolated static func cancelAndJoin(_ tasks: [Task<Void, Never>]) async {
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    private var startTask: Task<Void, Error>?
    private var startID: UUID?
    private var stopTask: Task<Void, Error>?
    private var stopID: UUID?
    private var shutdownRequested = false

    /// Close admission immediately. Device rollback is joined by stop(), allowing
    /// termination to establish its fence before other asynchronous shutdown work.
    func beginShutdown() {
        shutdownRequested = true
        startTask?.cancel()
    }

    func start(operation: @escaping @Sendable () async throws -> Void,
               rollback: @escaping @Sendable () async -> Void) async throws {
        guard !shutdownRequested else { throw RecordingLifecycleError.shuttingDown }
        while let stopping = stopTask {
            try await stopping.value
            guard !shutdownRequested else { throw RecordingLifecycleError.shuttingDown }
        }
        try Task.checkCancellation()
        if let task = startTask {
            // A duplicate caller only joins; its cancellation cannot release
            // devices owned by the original startup request.
            try await task.value
            try Task.checkCancellation()
            guard !shutdownRequested else { throw RecordingLifecycleError.shuttingDown }
            return
        }
        let id = UUID()
        let task = Task {
            do {
                try Task.checkCancellation()
                try await operation()
                try Task.checkCancellation()
            } catch {
                await rollback()
                failedStart(id)
                throw error
            }
        }
        startID = id; startTask = task
        // Task creation is unstructured, so parent cancellation must explicitly
        // reach the owned startup. Awaiting its value also joins late API cleanup.
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        guard !shutdownRequested else { throw RecordingLifecycleError.shuttingDown }
    }

    func stop(onRequest: @escaping @Sendable () async -> Void,
              operation: @escaping @Sendable () async throws -> Void) async throws {
        if let stopping = stopTask {
            // Every stop request owns its content/privacy fence even when device
            // teardown is already owned by an earlier (possibly unexpected) stop.
            await onRequest()
            return try await stopping.value
        }
        let starting = startTask
        let startingID = startID
        starting?.cancel()
        let id = UUID()
        let task = Task {
            await onRequest()
            if let starting { _ = try? await starting.value }
            do {
                try await operation()
                finishedStop(id, startingID: startingID)
            } catch {
                finishedStop(id, startingID: startingID)
                throw error
            }
        }
        stopID = id; stopTask = task
        try await task.value
    }

    private func failedStart(_ id: UUID) {
        if startID == id { startID = nil; startTask = nil }
    }

    private func finishedStop(_ id: UUID, startingID: UUID?) {
        if startID == startingID { startID = nil; startTask = nil }
        if stopID == id { stopID = nil; stopTask = nil }
    }
}
