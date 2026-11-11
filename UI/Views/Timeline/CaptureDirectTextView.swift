import SwiftUI
import Shared

/// The parent owns current evidence admission. Validation and canonical JSON
/// work stay outside the render/main path; cancellation prevents a changed
/// selection from publishing the preceding frame's direct text.
struct CaptureDirectTextView: View {
    let snapshot: ScreenEvidenceSnapshot
    @State private var admitted: (reference: ScreenEvidenceRef, text: CaptureTextObservation)?

    var body: some View {
        Group {
            if let admitted, admitted.reference == snapshot.ref, !admitted.text.runs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(admitted.text.availability == .partial ? "Visible app text (partial)" : "Visible app text")
                        .font(.headline)
                    Text("Read directly from the visible window around this capture. Compare with the screenshot when exact appearance matters.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(admitted.text.runs) { run in
                        Text(run.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                }
            }
        }
        .task(id: snapshot.ref) {
            admitted = nil
            let source = snapshot
            let validation = Task.detached(priority: .userInitiated) { () -> CaptureTextObservation? in
                guard !Task.isCancelled else { return nil }
                return source.validatedCaptureText
            }
            let text = await withTaskCancellationHandler {
                await validation.value
            } onCancel: { validation.cancel() }
            guard !Task.isCancelled, let text else { return }
            admitted = (source.ref, text)
        }
    }
}
