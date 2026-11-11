import App
import Combine
import Foundation
import Shared

/// Owns publication, cancellation and an independent monotonic expiry timer.
/// All canonical reads and optional model work belong to the App actor.
@MainActor
final class LocalContextPresentationModel: ObservableObject {
    @Published private(set) var snapshot: LocalContextSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var status = "Select a native recorded moment for context"
    private let load: @Sendable (LocalContextRequest) async throws -> LocalContextSnapshot
    private let clock: @MainActor () -> LocalContextInstant
    private var generation = UUID()
    private var work: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var pending: LocalContextRequest?

    init(load: @escaping @Sendable (LocalContextRequest) async throws -> LocalContextSnapshot,
         clock: @escaping @MainActor () -> LocalContextInstant = { .live }) {
        self.load = load; self.clock = clock
    }

    func clearPresentation() {
        expiry?.cancel(); expiry = nil; snapshot = nil
    }

    func clear() {
        generation = UUID(); work?.cancel(); expiry?.cancel(); expiry = nil
        pending = nil; snapshot = nil; isRefreshing = false
        status = "Select a native recorded moment for context"
        // Keep the task handle until a replacement joins it. Clear never makes
        // a cancellation-insensitive completion eligible for publication.
    }

    func refresh(_ request: LocalContextRequest) async {
        guard !Task.isCancelled else { return }
        let task = beginRefresh(request)
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    /// The shared workspace poll can request context without waiting for model work.
    func requestRefresh(_ request: LocalContextRequest) { _ = beginRefresh(request) }

    private func beginRefresh(_ request: LocalContextRequest) -> Task<Void, Never> {
        if pending == request, let work { return work }
        let previous = work
        clear()
        let token = generation
        isRefreshing = true; status = "Checking local context"; pending = request
        let task = Task { [weak self, load] in
            if let previous { await previous.value }
            guard let self, !Task.isCancelled, generation == token else { return }
            defer { if generation == token { work = nil; pending = nil; isRefreshing = false } }
            do {
                let value = try await load(request)
                guard !Task.isCancelled, generation == token else { return }
                let now = clock()
                let wallRemaining = value.expiresAt.timeIntervalSince(now.wall)
                let uptimeRemaining = value.expiresAtUptime - now.uptime
                let remaining = min(wallRemaining, uptimeRemaining)
                guard wallRemaining.isFinite, uptimeRemaining.isFinite,
                      remaining > 0, remaining <= 120 else {
                    status = "Context expired"; return
                }
                snapshot = value
                switch value.modelStatus {
                case .used: status = "Local topic interpretation · check its evidence"
                case .disabled, .noInput: status = "Selected moment · recorded evidence"
                case .unavailable: status = "Local model unavailable · recorded evidence"
                case .failed, .rejected: status = "Local topic unavailable · recorded evidence"
                }
                expiry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                    guard let self, generation == token else { return }
                    snapshot = nil; status = "Context expired"; expiry = nil
                }
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                snapshot = nil; status = "Context unavailable for this selection"
            }
        }
        work = task
        return task
    }

    deinit { work?.cancel(); expiry?.cancel() }
}

struct LocalContextPresentationKey: Hashable {
    let reference: EvidenceRef?
    let modelEnabled: Bool
    let visible: Bool
}
