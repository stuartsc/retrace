import App
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Native file selection is UI-only; hashing, copying and Core ML preparation
/// belong to the App owner. The setting acknowledges only a verified runtime.
@MainActor
struct LocalRecallSettingsContent: View {
    let coordinator: AppCoordinator
    @State private var snapshot: LocalRecallSnapshot?
    @State private var isChanging = false
    @State private var errorMessage: String?
    @State private var changeTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find recorded screen text by meaning using a model on this Mac.")
                .font(.callout)
            Text("Meaning search covers native screen text. Imported history uses text matching; audio is not included yet.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if isChanging {
                    ProgressView().controlSize(.small)
                    Text("Preparing local search…").font(.caption)
                } else {
                    Text(snapshot?.summary ?? "Checking local search…").font(.caption)
                }
                Spacer()
                Button(snapshot?.modelPackageURL == nil ? "Choose local model…" : "Change model…") { chooseModel() }
                    .disabled(isChanging).accessibilityIdentifier("settings.localRecall.choose")
                if snapshot?.modelPackageURL != nil {
                    Button("Turn off") { change(nil) }
                        .disabled(isChanging).accessibilityIdentifier("settings.localRecall.disable")
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.localRecall.error")
            }
        }
        .task {
            let current = await coordinator.localRecallSnapshot()
            guard !Task.isCancelled else { return }
            snapshot = current
        }
        .onDisappear { changeTask?.cancel() }
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.title = "Choose the verified local meaning model"
        panel.message = "Choose the Retrace MiniLM model package. It is verified on this Mac before use."
        panel.allowedContentTypes = [UTType(filenameExtension: "mlpackage") ?? .package]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        Task {
            try? await coordinator.recordMetricEvent(metricType: .progressiveRecallAction,
                metadata: "{\"action\":\"localRecallModelPickerOpened\",\"outcome\":\"opened\"}")
        }
        panel.begin { response in
            if response == .OK, let selected = panel.url { change(selected) }
            else {
                Task {
                    try? await coordinator.recordMetricEvent(metricType: .progressiveRecallAction,
                        metadata: "{\"action\":\"localRecallModelPickerOpened\",\"outcome\":\"cancelled\"}")
                }
            }
        }
    }

    private func change(_ selected: URL?) {
        guard !isChanging else { return }
        isChanging = true; errorMessage = nil
        changeTask = Task {
            defer { isChanging = false; changeTask = nil }
            do { try await coordinator.configureLocalRecall(modelPackageURL: selected) }
            catch is CancellationError { return }
            catch { errorMessage = "The local model could not be enabled. Choose the verified Retrace model package and try again." }
            let current = await coordinator.localRecallSnapshot()
            guard !Task.isCancelled else { return }
            snapshot = current
        }
    }
}
