import App
import Shared
import SwiftUI

struct CompanionSpeakerView: View {
    @ObservedObject var model: CompanionWorkspaceModel
    let selected: CompanionSpeakerPresentation?
    let dismiss: () -> Void
    @State private var editingJob: String?
    @State private var editingSpeaker: String?
    @State private var name = ""

    private var presentations: [CompanionSpeakerPresentation] {
        guard let selected else { return model.presentations }
        guard let current = model.selectedPresentation, current.jobID == selected.jobID else { return [] }
        return [current]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Speaker labels").font(.title2.weight(.semibold)); Spacer(); Button("Done", action: dismiss) }
            Text("Anonymous labels belong to this recording only; Speaker 1 in another recording is a separate identity. Manual names are your corrections. Suggested identities remain unconfirmed.")
                .font(.callout).foregroundStyle(.secondary)
            Text(model.title).font(.caption).foregroundStyle(.secondary)
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(presentations, id: \.jobID) { presentation in
                        VStack(alignment: .leading, spacing: 9) {
                            let source = presentation.enhancement.sourceIdentity
                            Text("Recording around \(source.approximateOrigin.addingTimeInterval(Double(source.startSample) / Double(source.sampleRate)).formatted(date: .abbreviated, time: .standard))")
                                .font(.headline)
                            ForEach(Array(presentation.enhancement.turns.enumerated()), id: \.offset) { _, turn in
                                let correction = presentation.corrections.first { $0.speakerID == turn.speakerID }
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(correction?.displayName ?? turn.speakerLabel).font(.callout.weight(.semibold))
                                        Text(correction?.displayName == nil ?
                                            (turn.speakerStatus == .suggested ? "Suggested: \(turn.candidateName ?? "unconfirmed")" : turn.speakerStatus.rawValue.capitalized) : "Manual name")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("Name") { editingJob = presentation.jobID; editingSpeaker = turn.speakerID; name = correction?.displayName ?? "" }
                                            .disabled(model.isSaving)
                                        if correction?.displayName != nil {
                                            Button("Undo name") { model.correct(presentation, speakerID: turn.speakerID, name: nil) }.disabled(model.isSaving)
                                        }
                                    }
                                    Text(turn.text).textSelection(.enabled)
                                    if editingJob == presentation.jobID, editingSpeaker == turn.speakerID {
                                        HStack {
                                            TextField("Name for this recording", text: $name).textFieldStyle(.roundedBorder)
                                            Button("Save") { model.correct(presentation, speakerID: turn.speakerID, name: name) }
                                                .disabled(model.isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                            Button("Cancel") { editingJob = nil; editingSpeaker = nil }.disabled(model.isSaving)
                                        }
                                    }
                                }.padding(10).background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            }
                            DisclosureGroup("Retained first pass · full original recording") {
                                Text("The original batch may include an overlapping tail outside the enhanced interval.").font(.caption).foregroundStyle(.secondary)
                                Text(presentation.firstPassText).textSelection(.enabled)
                            }
                                .font(.callout)
                        }
                    }
                    if presentations.isEmpty { Text("No speaker enrichment is available in this interval.").foregroundStyle(.secondary) }
                }
            }
        }.padding(20).frame(width: 720, height: 620)
            .onChange(of: model.savedRevision) { _ in editingJob = nil; editingSpeaker = nil; name = "" }
    }
}
