import App
import AppKit
import Combine
import Foundation
import Shared

@MainActor
final class CommandAccessViewModel: ObservableObject {
    @Published private(set) var state: RetraceCommandAccessState?
    @Published private(set) var issuedClient: RetraceIssuedClient?
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    private let service: @Sendable () async throws -> RetraceCommandAccessService
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var visible = true

    init(service: @escaping @Sendable () async throws -> RetraceCommandAccessService) { self.service = service }

    func refresh() async {
        guard !isBusy, !Task.isCancelled else { return }
        let generation = generation
        do {
            let owner = try await service()
            let result = await owner.state()
            guard !Task.isCancelled, generation == self.generation else { return }
            state = result
        } catch {
            if !Task.isCancelled, generation == self.generation { message = "Local MCP access could not be read." }
        }
    }

    func createClient(name: String, capabilities: Set<RetraceCapability>, expiresAt: Date?) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !capabilities.isEmpty else { return }
        mutate(success: "Client created. Keep its token in the client you chose.") {
            try await $0.createClient(name: name, capabilities: capabilities, expiresAt: expiresAt)
        }
    }

    func setEnabled(_ enabled: Bool) {
        mutate(success: enabled ? "Local MCP access enabled." : "Local MCP access disabled.") {
            try await $0.setEnabled(enabled); return nil
        }
    }

    func revoke(_ client: RetraceClientSummary) {
        mutate(success: "Client access revoked.") { try await $0.revokeClient(id: client.id); return nil }
    }

    private func mutate(success: String,
                        operation: @escaping @Sendable (RetraceCommandAccessService) async throws -> RetraceIssuedClient?) {
        guard task == nil else { return }
        generation &+= 1; isBusy = true; message = nil
        let issuanceGeneration = generation
        task = Task { [weak self, service] in
            defer { self?.task = nil; self?.isBusy = false }
            do {
                let owner = try await service()
                let issued = try await operation(owner)
                let state = await owner.state()
                guard let self else { return }
                self.state = state
                self.message = success
                if let issued {
                    if self.visible, self.generation == issuanceGeneration { self.issuedClient = issued }
                    else { self.message = "Client created after Settings closed. Revoke it and create another if you need its token." }
                }
            } catch {
                if let owner = try? await service() { self?.state = await owner.state() }
                self?.message = "The MCP access change could not be completed. Review the current status and try again."
            }
        }
    }

    @discardableResult
    func copyIssuedToken(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let token = issuedClient?.bearerToken else { return false }
        let item = NSPasteboardItem()
        item.setString(token, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    func dismissToken() { issuedClient = nil }
    func show() { visible = true }
    func hide() { visible = false; generation &+= 1; dismissToken() }
    func finishPendingWrite() async { await task?.value }
}

enum CommandAccessCapabilityPresentation {
    static func title(_ capability: RetraceCapability) -> String {
        switch capability {
        case .manifest: return "Discover supported commands"
        case .operationsRead: return "Read operation status"
        case .evidenceRead: return "Read recorded evidence"
        case .markersRead: return "Read timeline markers"
        case .markersWrite: return "Create and change markers"
        case .rulesRead: return "Read voice rules"
        case .rulesWrite: return "Change voice rules"
        case .annotationsRead: return "Read context annotations"
        case .annotationsWrite: return "Change context annotations"
        case .foregroundControl: return "Open views and control playback"
        case .settingsRead: return "Read supported settings"
        case .settingsWrite: return "Change settings and start or stop recording"
        case .processing: return "Request supported processing"
        case .maintenance: return "Request supported maintenance"
        }
    }
}
