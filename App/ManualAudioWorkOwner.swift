import Foundation
import Shared

enum ManualAudioWorkError: Error { case busy, closeIncomplete }

/// Owns an explicit repair through its final database write, not just native inference.
/// A second UI route cannot start another repair concurrently.
actor ManualAudioWorkOwner {
    private struct Work {
        let id: UUID
        let cancel: @Sendable () -> Void
        let joined: Task<Void, Never>
    }
    private var current: Work?
    private var closed = false
    private var closingCount = 0

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard current == nil else { throw ManualAudioWorkError.busy }
        let id = UUID()
        let task = Task<T, Error> {
            try await BackgroundProcessingContext.$explicitRequest.withValue(true) {
                try Task.checkCancellation()
                let result = try await operation()
                try Task.checkCancellation()
                return result
            }
        }
        let joined = Task { _ = try? await task.value }
        current = Work(id: id, cancel: { task.cancel() }, joined: joined)
        defer { if current?.id == id { current = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    func close() async {
        closed = true
        closingCount += 1
        defer { closingCount -= 1 }
        let ending = current
        ending?.cancel()
        await ending?.joined.value
        if current?.id == ending?.id { current = nil }
    }

    func reopen() throws {
        guard closingCount == 0, current == nil else { throw ManualAudioWorkError.closeIncomplete }
        closed = false
    }
}
