import AppKit

/// Owns asynchronous launch and the single confirmed-Quit drain without blocking AppKit.
@MainActor
final class ApplicationTerminationWorkflow {
    private var initializationTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var terminationRequested = false
    private(set) var didCompleteShutdown = false
    var isDraining: Bool { drainTask != nil }
    var isTerminating: Bool { terminationRequested }

    func startInitialization(_ operation: @escaping @MainActor () async -> Void) {
        guard initializationTask == nil, !terminationRequested else { return }
        initializationTask = Task {
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    @discardableResult
    func requestTermination(prepareShutdown: @escaping @MainActor () async -> Void = {},
                            flushMetrics: @escaping @MainActor () async -> Void,
                            shutdown: @escaping @MainActor () async throws -> Void,
                            reply: @escaping @MainActor (Bool) -> Void,
                            reportFailure: @escaping @MainActor (Error) -> Void) -> NSApplication.TerminateReply {
        if didCompleteShutdown { return .terminateNow }
        if drainTask != nil { return .terminateLater }

        // A failed shutdown can leave partially stopped services. Never restart the
        // launch sequence; a subsequent Quit owns a fresh drain of what remains.
        terminationRequested = true
        let pendingInitialization = initializationTask
        pendingInitialization?.cancel()
        drainTask = Task {
            // Fence all recording entry points and cancel their owned startup before
            // metrics or an initializer join can yield to another recording request.
            await prepareShutdown()
            await flushMetrics()
            // Cancellation is cooperative. Join late initialization before closing
            // any service it might still be opening, without blocking AppKit.
            await pendingInitialization?.value
            do {
                try await shutdown()
                didCompleteShutdown = true
                drainTask = nil
                reply(true)
            } catch {
                drainTask = nil
                reportFailure(error)
                reply(false)
            }
        }
        return .terminateLater
    }
}
