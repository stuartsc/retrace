import SwiftUI
import Shared

struct EvidenceTextView: View {
    let reference: ScreenEvidenceRef
    @StateObject private var text: EvidenceTextViewModel

    init(reference: ScreenEvidenceRef, model: EvidenceViewModel) {
        self.reference = reference
        _text = StateObject(wrappedValue: EvidenceTextViewModel(report: { outcome, count in
            await model.track(.textExpanded, outcome: outcome, count: count)
        }) {
            try await model.expandText($0)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if text.isLoading || text.reference != reference {
                ProgressView("Loading captured text…")
            } else if let error = text.error {
                Text(message(error)).foregroundStyle(.secondary)
                Button("Retry text") { Task { await text.open(reference) } }
            } else if let page = text.page {
                Text(page.provenance.origin == .ocr ? "OCR from this recording" : "Retained text; extraction method was not recorded")
                    .font(.caption).foregroundStyle(.secondary)
                if page.fragments.isEmpty {
                    Text("Text is not available for this extraction revision.").foregroundStyle(.secondary)
                }
                ForEach(page.fragments) { fragment in
                    VStack(alignment: .leading, spacing: 3) {
                        if fragment.channel == .chrome {
                            Text("Screen edge text").font(.caption).foregroundStyle(.secondary)
                        }
                        if fragment.blockUTF8Offset > 0 {
                            Text("Continued from the previous page").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(fragment.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if !fragment.isLastFragment {
                            Text("Continues on the next page").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if text.canGoBack || page.nextCursor != nil {
                    HStack {
                        Button("Previous text") { Task { await text.previous() } }.disabled(!text.canGoBack)
                        Text("Page \(text.pageNumber)").font(.caption).foregroundStyle(.secondary)
                        Button("More text") { Task { await text.next() } }.disabled(page.nextCursor == nil)
                    }
                }
            }
        }
        .task(id: reference) { await text.open(reference) }
        .onDisappear { text.cancel() }
    }

    private func message(_ reason: EvidenceUnavailableReason) -> String {
        switch reason {
        case .notPermitted: return "Current privacy settings do not permit showing this text."
        case .evidenceDeleted: return "This evidence has been deleted."
        case .sourceDisconnected: return "Reconnect this source library to read its text."
        default: return "This exact text could not be opened."
        }
    }
}
