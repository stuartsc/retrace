import Foundation

enum RecordingLifecycleError: Error, Equatable { case shuttingDown }

/// An owned attempt retains both errors for every caller that joined it.
struct RecordingStartupFailure: Error {
    let startup: any Error
    let rollback: any Error
}

struct RecordingShutdownFailure: Error {
    let request: any Error
    let cleanup: any Error
}

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
               rollback: @escaping @Sendable () async throws -> Void) async throws {
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
                let startupError = error
                do {
                    try await rollback()
                } catch {
                    // A failed rollback cannot transfer resource ownership to a
                    // replacement start. Explicit stop may still retry cleanup.
                    shutdownRequested = true
                    failedStart(id)
                    throw RecordingStartupFailure(startup: startupError, rollback: error)
                }
                failedStart(id)
                throw startupError
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

    func stop(onRequest: @escaping @Sendable () async throws -> Void,
              operation: @escaping @Sendable () async throws -> Void) async throws {
        if let stopping = stopTask {
            // Every stop request owns its content/privacy fence even when device
            // teardown is already owned by an earlier (possibly unexpected) stop.
            var requestError: (any Error)?
            do { try await Task { try await onRequest() }.value }
            catch { requestError = error }
            do { try await stopping.value }
            catch {
                if let requestError { throw RecordingShutdownFailure(request: requestError, cleanup: error) }
                throw error
            }
            if let requestError { throw requestError }
            return
        }
        let starting = startTask
        let startingID = startID
        starting?.cancel()
        let id = UUID()
        let task = Task {
            var requestError: (any Error)?
            do { try await onRequest() }
            catch { requestError = error }
            if let starting { _ = try? await starting.value }
            do {
                try await operation()
            } catch {
                finishedStop(id, startingID: startingID)
                if let requestError { throw RecordingShutdownFailure(request: requestError, cleanup: error) }
                throw error
            }
            finishedStop(id, startingID: startingID)
            if let requestError { throw requestError }
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
