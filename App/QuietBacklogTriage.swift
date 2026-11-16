import Foundation

/// Files recordings that were silent when captured and have waited more than
/// 48 hours as "no speech", in short batches, only while the governor's idle
/// window is open. Audio files are kept for a later sound pass.
enum QuietBacklogTriage {
    static let minimumAge: TimeInterval = 48 * 60 * 60
    static let batchSize = 500
    static let maximumBatchesPerTurn = 40

    /// Returns how many rows were marked. Stops early when a batch comes back
    /// short (backlog drained) or the caller is cancelled.
    static func runTurn(now: Date,
                        mark: (Date, Int) async throws -> Int,
                        isCancelled: () -> Bool,
                        pause: () async -> Void) async throws -> Int {
        let cutoff = now.addingTimeInterval(-minimumAge)
        var total = 0
        for index in 0..<maximumBatchesPerTurn {
            if isCancelled() { break }
            let marked = try await mark(cutoff, batchSize)
            total += marked
            if marked < batchSize { break }
            if index + 1 < maximumBatchesPerTurn { await pause() }
        }
        return total
    }
}
