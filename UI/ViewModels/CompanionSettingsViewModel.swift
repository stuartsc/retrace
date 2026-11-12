import App
import Combine
import Foundation

@MainActor
final class CompanionSettingsViewModel: ObservableObject {
    @Published private(set) var endpoint = ""
    @Published private(set) var configured = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private let service: @Sendable () async throws -> CompanionSettingsService
    private var generation = UUID()
    private var write: Task<Void, Never>?

    init(service: @escaping @Sendable () async throws -> CompanionSettingsService) { self.service = service }
    func refresh() async {
        let token = generation
        do {
            let state = try await service().state()
            guard !Task.isCancelled, generation == token else { return }
            endpoint = state.endpoint ?? ""; configured = state.configured; message = state.lastError
        } catch { if generation == token, !Task.isCancelled { message = "Companion settings could not be read." } }
    }
    func configure(endpoint: String?, token: String?) {
        guard write == nil else { return }
        let url: URL?
        if let endpoint {
            guard let parsed = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), parsed.scheme != nil else {
                message = "Enter the private companion's full endpoint URL."; return
            }
            url = parsed
        } else { url = nil }
        let generation = generation
        busy = true; message = nil
        write = Task { [weak self, service] in
            defer { self?.busy = false; self?.write = nil }
            do {
                try await service().configure(endpoint: url, bearerToken: token)
                guard let self, self.generation == generation else { return }
                await self.refresh()
                if self.message == nil { self.message = url == nil ? "Companion disconnected. Saved local recordings remain available." : "Companion configuration saved." }
            } catch {
                guard let self, self.generation == generation else { return }
                await self.refresh()
                if self.message == nil { self.message = "Could not connect. Check the private endpoint and token, then try again." }
            }
        }
    }
    func hide() { generation = UUID(); message = nil }
    func finishPendingWrite() async { await write?.value }
}
