import App
import Shared
import SwiftUI

struct VoiceMarkerRulesView: View {
    @StateObject private var model: VoiceMarkerRulesViewModel
    @StateObject private var voice: VoiceMarkerStatusModel
    @AppStorage("voiceMarkersAcknowledgementSoundEnabled") private var acknowledgementSound = false
    @State private var phrase = ""
    @State private var name = ""
    @State private var meaning = ""
    @State private var aliases = ""
    @State private var editingRule: KeywordRule?
    @State private var preparingSpeech = false
    @State private var preparationMessage: String?
    private let prepareSpeech: @Sendable () async throws -> Void

    init(coordinator: AppCoordinator) {
        prepareSpeech = { try await coordinator.voiceMarkers().prepareAssets() }
        _model = StateObject(wrappedValue: VoiceMarkerRulesViewModel(service: { try await coordinator.timelineMarkers() }))
        _voice = StateObject(wrappedValue: VoiceMarkerStatusModel(coordinator: coordinator))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Voice marker rules", systemImage: "bookmark").font(.headline)
            Text("Choose phrases you want to mark on your timeline. New rules are disabled until you enable them.")
                .font(.callout).foregroundStyle(.secondary)
            Label(voice.title, systemImage: "waveform")
                .font(.caption).foregroundStyle(.secondary)
            Text(voice.detail)
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Prepare speech recognition") { preparingSpeech = true }
                    .disabled(preparingSpeech)
                if preparingSpeech { ProgressView().controlSize(.small) }
                if let preparationMessage { Text(preparationMessage).font(.caption).foregroundStyle(.secondary) }
            }
            Text("Downloads Apple's on-device speech assets when needed. Recognition starts only while recording with an enabled rule.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Play a sound after a voice marker is saved", isOn: $acknowledgementSound)
                .toggleStyle(.switch).controlSize(.small).font(.callout)
            ForEach(model.rules) { rule in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.name).font(.callout.weight(.medium))
                        Text("“\(rule.phrase)”").font(.callout).textSelection(.enabled)
                        if !rule.meaning.isEmpty { Text(rule.meaning).font(.caption).foregroundStyle(.secondary) }
                        if !rule.aliases.isEmpty {
                            Text("Aliases: \(rule.aliases.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        editingRule = rule; phrase = rule.phrase; name = rule.name
                        meaning = rule.meaning; aliases = rule.aliases.joined(separator: ", ")
                    } label: { Image(systemName: "pencil") }.buttonStyle(.plain).help("Edit voice rule")
                        .disabled(model.isBusy)
                    Toggle("Enabled", isOn: Binding(get: { rule.enabled }, set: { model.setEnabled(rule, enabled: $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(model.isBusy || editingRule != nil)
                        .accessibilityLabel("Enable \(rule.name)")
                }.padding(10).background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow { Text("Phrase"); TextField("For example: mark this moment", text: $phrase) }
                GridRow { Text("Marker name"); TextField("A short name", text: $name) }
                GridRow { Text("Meaning"); TextField("What this phrase means to you", text: $meaning) }
                GridRow { Text("Aliases"); TextField("Optional alternatives, separated by commas", text: $aliases) }
            }.textFieldStyle(.roundedBorder).font(.callout).disabled(model.isBusy)
            HStack {
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if editingRule != nil { Button("Cancel edit") { clearEditor() }.disabled(model.isBusy) }
                Button(editingRule == nil ? "Add disabled rule" : "Save rule") {
                    model.save(phrase: phrase, name: name, meaning: meaning, aliases: aliases, editing: editingRule)
                }
                    .disabled(model.isBusy || phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .task { await model.refresh() }
        .task(id: preparingSpeech) {
            guard preparingSpeech else { return }
            preparationMessage = nil
            do {
                try await prepareSpeech()
                try Task.checkCancellation()
                preparationMessage = "Speech assets are ready."
                await voice.refresh()
            } catch is CancellationError { }
            catch { if !Task.isCancelled { preparationMessage = "Speech assets could not be prepared. Check your connection and try again." } }
            preparingSpeech = false
        }
        .task {
            while !Task.isCancelled {
                await voice.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onChange(of: model.editorSaveRevision) { _ in clearEditor() }
    }

    private func clearEditor() { editingRule = nil; phrase = ""; name = ""; meaning = ""; aliases = "" }
}
