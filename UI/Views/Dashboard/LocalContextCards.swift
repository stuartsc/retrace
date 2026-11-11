import SwiftUI
import Shared

struct LocalContextCards: View {
    @ObservedObject var model: LocalContextPresentationModel
    let onOpen: (EvidenceRef) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Local context").font(.subheadline.bold())
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            if model.isRefreshing { ProgressView().controlSize(.small) }
            if let snapshot = model.snapshot {
                ForEach(snapshot.items) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.subheadline)
                        if let observed = item.observedAt {
                            Text(observed.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if item.isInterpretation { Text("Interpretation").font(.caption2).foregroundStyle(.secondary) }
                        if let excerpt = item.excerpt { Text(excerpt).font(.caption).textSelection(.enabled) }
                        ForEach(Array(item.supports.enumerated()), id: \.offset) { _, support in
                            if let reference = reference(support) {
                                Button("View supporting moment") { Task { await onOpen(reference) } }
                                    .font(.caption).buttonStyle(.link)
                            }
                        }
                    }
                }
                if snapshot.screenTextTruncated {
                    Text("A short excerpt of the selected evidence is shown.").font(.caption2).foregroundStyle(.secondary)
                }
                if snapshot.items.isEmpty { Text("No current text context for this selection.").font(.caption) }
            }
        }
    }

    private func reference(_ support: LocalContextSupport) -> EvidenceRef? {
        switch support {
        case .screen(let span): return .screen(span.fragmentID.reference)
        case .activity(let reference): return .activity(reference)
        case .external: return nil
        }
    }
}
