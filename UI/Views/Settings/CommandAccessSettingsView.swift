import App
import AppKit
import Shared
import SwiftUI

struct CommandAccessSettingsView: View {
    @StateObject private var model: CommandAccessViewModel
    @State private var name = ""
    @State private var capabilities: Set<RetraceCapability> = []
    @State private var expiryDays = 7
    @State private var revealToken = false
    @State private var tokenCopied = false

    init(coordinator: AppCoordinator) {
        _model = StateObject(wrappedValue: CommandAccessViewModel(service: { try await coordinator.commandAccess() }))
    }

    #if DEBUG
    /// Native fixture boundary: the production controls and polling remain intact.
    init(service: @escaping @Sendable () async throws -> RetraceCommandAccessService) {
        _model = StateObject(wrappedValue: CommandAccessViewModel(service: service))
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Local MCP access", systemImage: "key.horizontal").font(.headline)
            Text("Give each client its own token and only the permissions you select. Access starts disabled; creating a client does not enable the listener.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Enable local MCP access", isOn: Binding(get: { model.state?.enabled ?? false }, set: { model.setEnabled($0) }))
                .toggleStyle(.switch).disabled(model.isBusy || model.state == nil || (model.state?.clients.isEmpty == true && model.state?.enabled != true))
            if let state = model.state {
                Label(state.listening ? "Listening for authorized local clients" : state.enabled ? "Enabled · listener unavailable" : "Access disabled",
                    systemImage: state.listening ? "checkmark.circle" : "circle")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = state.lastError { Text(error).font(.caption).foregroundStyle(Color.retraceWarning) }
                ForEach(state.clients) { client in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(client.name).font(.callout.weight(.medium))
                            Text(client.capabilities.map { CommandAccessCapabilityPresentation.title($0) }.sorted().joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                            if let expiry = client.expiresAt {
                                Text("\(expiry <= Date() ? "Expired" : "Expires") \(expiry.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else { Text("No expiry").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                        Button("Revoke") { model.revoke(client) }.disabled(model.isBusy)
                    }.padding(10).background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Divider()
            Text("Add a client").font(.callout.weight(.medium))
            TextField("Client name", text: $name).textFieldStyle(.roundedBorder).disabled(model.isBusy)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 9) {
                ForEach(RetraceCapability.allCases, id: \.self) { capability in
                    Toggle(CommandAccessCapabilityPresentation.title(capability), isOn: Binding(
                        get: { capabilities.contains(capability) },
                        set: { if $0 { capabilities.insert(capability) } else { capabilities.remove(capability) } }))
                        .toggleStyle(.checkbox).font(.caption).disabled(model.isBusy)
                }
            }
            HStack {
                Picker("Expires after", selection: $expiryDays) {
                    Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30); Text("No expiry").tag(0)
                }.frame(maxWidth: 260).disabled(model.isBusy)
                Spacer()
                Button("Create client token") {
                    let expiry = expiryDays == 0 ? nil : Date().addingTimeInterval(Double(expiryDays) * 86_400)
                    model.createClient(name: name, capabilities: capabilities, expiresAt: expiry)
                }.disabled(model.isBusy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || capabilities.isEmpty)
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(18).background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .task {
            model.show()
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .onDisappear { model.hide(); revealToken = false; tokenCopied = false }
        .sheet(isPresented: Binding(get: { model.issuedClient != nil }, set: { if !$0 { dismissToken() } })) { tokenSheet }
    }

    private var tokenSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save this client token").font(.title2.weight(.semibold))
            if let issued = model.issuedClient {
                Text("\(issued.summary.name) · shown once").font(.callout)
                Text("Copy the token into the client you chose. Retrace keeps only its digest and cannot show it again after you close this window.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Client ID: \(issued.summary.id)").font(.caption.monospaced()).textSelection(.enabled)
                if revealToken {
                    Text(issued.bearerToken).font(.body.monospaced()).textSelection(.enabled)
                } else {
                    SecureField("Bearer token", text: Binding(get: { issued.bearerToken }, set: { _ in }))
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("Reveal token", isOn: $revealToken).toggleStyle(.checkbox)
                HStack {
                    Button(tokenCopied ? "Copied" : "Copy token") { tokenCopied = model.copyIssuedToken() }
                    Spacer()
                    Button("Done") { dismissToken() }.keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 520)
    }

    private func dismissToken() {
        model.dismissToken(); revealToken = false; tokenCopied = false; name = ""; capabilities = []
    }
}
