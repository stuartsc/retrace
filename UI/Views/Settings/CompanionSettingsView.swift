import App
import SwiftUI

struct CompanionSettingsView: View {
    @StateObject private var model: CompanionSettingsViewModel
    @State private var endpoint = ""
    @State private var token = ""
    init(coordinator: AppCoordinator) {
        _model = StateObject(wrappedValue: CompanionSettingsViewModel(service: { try await coordinator.companionSettings() }))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Private companion", systemImage: "network").font(.headline)
            Text("Connect your private companion to enhance speaker labels and suggest marker context. Connecting permits recorded audio and supporting text to be sent to that endpoint; first-pass recordings remain available locally.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("https://your-private-host.ts.net/retrace-companion", text: $endpoint).textFieldStyle(.roundedBorder)
            SecureField(model.configured ? "New token (leave empty to keep the same endpoint's token)" : "Companion access token", text: $token)
                .textFieldStyle(.roundedBorder)
            Text("Tokens are stored in macOS Keychain and are never shown again. Only a private HTTPS .ts.net endpoint or local loopback endpoint is accepted.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(model.configured ? "Configured" : "Not configured").font(.caption).foregroundStyle(.secondary)
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                if model.configured { Button("Disconnect") { token = ""; model.configure(endpoint: nil, token: nil) }.disabled(model.busy) }
                Button(model.configured ? "Save connection" : "Connect") {
                    let supplied = token; token = ""
                    model.configure(endpoint: endpoint, token: supplied.isEmpty ? nil : supplied)
                }.disabled(model.busy || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.padding(18).background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            .task { await model.refresh(); endpoint = model.endpoint }
            .onChange(of: model.endpoint) { endpoint = $0 }
            .onDisappear { token = ""; model.hide() }
    }
}
