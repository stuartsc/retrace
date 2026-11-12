import Foundation
import Shared

/// Expected queue pressure preserves the dirty work and still lets delivery free capacity.
enum CompanionRefreshPass {
    static func run(all: Bool, ids: Set<UUID>, recent: @Sendable () async throws -> [UUID],
                    refresh: @Sendable (UUID, Bool) async throws -> Void,
                    retry: @Sendable (UUID, Bool) -> Void, retryAll: @Sendable () -> Void,
                    drain: @Sendable () async throws -> Void) async throws {
        guard ids.count <= 256 else { throw CompanionError.capacityExceeded }
        var selected = ids, firstFailure: (any Error)?
        if all {
            do { let fresh = try await recent(); guard fresh.count <= 32 else { throw CompanionError.capacityExceeded }; selected.formUnion(fresh) }
            catch is CancellationError { retryAll(); for id in ids { retry(id, true) }; throw CancellationError() }
            catch { retryAll(); firstFailure = error }
        }
        // Explicit older marker IDs take retry capacity before the rediscoverable recent page.
        let ordered = ids.sorted { $0.uuidString < $1.uuidString } + selected.subtracting(ids).sorted { $0.uuidString < $1.uuidString }
        for (offset, id) in ordered.enumerated() {
            do { try Task.checkCancellation(); try await refresh(id, all) }
            catch is CancellationError {
                for pending in ordered[offset...] { retry(pending, all) }; throw CancellationError()
            } catch { retry(id, all); if firstFailure == nil { firstFailure = error } }
        }
        // Drain even when one/all refreshes could not publish. Delivery and source
        // collection remain separate retryable operations.
        do { try await drain() }
        catch is CancellationError { throw CancellationError() }
        catch { if firstFailure == nil { firstFailure = error } }
        if let firstFailure { throw firstFailure }
    }
}
