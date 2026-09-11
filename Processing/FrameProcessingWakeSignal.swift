import Foundation

/// Generation checks cover enqueues between a worker's empty dequeue and its wait.
/// The timeout still discovers work queued directly through the database.
actor FrameProcessingWakeSignal {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Never>
        let timeout: Task<Void, Never>
    }

    private var generation: UInt64 = 0
    private var waiters: [UUID: Waiter] = [:]

    var pendingWaiterCount: Int { waiters.count }

    func snapshot() -> UInt64 { generation }

    func notify() {
        generation &+= 1
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.timeout.cancel()
            waiter.continuation.resume()
        }
    }

    func wait(after observedGeneration: UInt64, timeout: Duration) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, generation == observedGeneration else {
                    continuation.resume()
                    return
                }
                let timer = Task {
                    do {
                        try await Task.sleep(for: timeout, clock: .continuous)
                        self.finish(id)
                    } catch { /* Notification/cancellation owns the continuation. */ }
                }
                waiters[id] = Waiter(continuation: continuation, timeout: timer)
            }
        } onCancel: {
            Task { await self.finish(id) }
        }
    }

    private func finish(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume()
    }
}
