import SwiftUI
import AppKit
import Shared

struct ExactEvidenceView: View {
    @ObservedObject var model: ActivityTimelineViewModel
    @State private var showAllText = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Recorded evidence").font(.title2.bold())
                    Spacer()
                    if model.evidenceReference != nil {
                        Button("Close") { model.closeEvidence(); Task { await model.track(.evidenceClosed) } }
                    }
                }
                if model.resolvingEvidence { ProgressView("Resolving this exact evidence…") }
                else if model.associationUnavailable {
                    Text("This activity-to-screen association is no longer available. The screen may still be retained independently.").foregroundStyle(.secondary)
                } else if let result = model.resolution {
                    resolved(result)
                } else {
                    Text("Expand an activity interval to inspect its observed metadata or linked recorded screens. Search results open their saved evidence here.")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.evidenceReference) { _ in showAllText = false }
    }

    @ViewBuilder private func resolved(_ resolution: EvidenceResolution) -> some View {
        switch resolution {
        case .activity(let event): activity(event)
        case .screen(let snapshot, let image): screen(snapshot, image: image)
        case .unavailable(let reason):
            Label(unavailable(reason), systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            if let retained = model.retainedSnapshot {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Retained evidence without a verified image").font(.headline)
                    Text("Captured \(retained.frame.timestamp.formatted(date: .abbreviated, time: .standard)) · Revision \(retained.ref.extractionRevision)")
                        .font(.caption).foregroundStyle(.secondary)
                    if retained.legacyContext { Text("Legacy metadata may describe the surrounding session.").font(.caption) }
                    if let text = retained.text?.fullText, !text.isEmpty {
                        Text(showAllText ? text : String(text.prefix(12_000))).textSelection(.enabled)
                        if text.count > 12_000 && !showAllText {
                            Button("Show all retained text") { showAllText = true; Task { await model.track(.textExpanded) } }
                        }
                    }
                    citationControls()
                }
            }
            if let reference = model.evidenceReference {
                Button("Retry this evidence") { Task { await model.openEvidence(reference) } }
            }
        }
    }

    private func activity(_ stored: PersistedActivityEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Observed activity metadata").font(.headline)
            if let context = stored.event.context {
                Text(context.windowTitle ?? context.appName).font(.title3).textSelection(.enabled)
                Text(context.appName)
                Text("A window title identifies observed context; it does not establish the document's contents.").font(.callout).foregroundStyle(.secondary)
                if let url = currentURL(context.safeURL) { currentDocumentButton(url) }
                if !context.uncertainty.isEmpty { Text(context.uncertainty.joined(separator: "; ")).font(.caption) }
            }
            Text("Observed \(stored.event.observedAt.formatted(date: .abbreviated, time: .standard))")
            Text("Persisted \(stored.persistedAt.formatted(date: .abbreviated, time: .standard))")
            Text("Coverage: \(stored.event.coverage.rawValue) · Method: \(stored.event.method)").font(.caption).foregroundStyle(.secondary)
            citationControls()
        }
    }

    private func screen(_ snapshot: ScreenEvidenceSnapshot, image: CGImage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(snapshot.frame.metadata.windowName ?? snapshot.frame.metadata.appName ?? "Recorded screen").font(.headline)
            Text("\(snapshot.ref.source.rawValue.capitalized) · Captured \(snapshot.frame.timestamp.formatted(date: .abbreviated, time: .standard))")
                .font(.subheadline)
            Text("Retained extraction revision \(snapshot.ref.extractionRevision)").font(.caption).foregroundStyle(.secondary)
            if snapshot.legacyContext {
                Text("Legacy attribution: the saved title or URL may describe the surrounding session. Precise text highlights are unavailable.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Image(decorative: image, scale: 1)
                .resizable().aspectRatio(contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    GeometryReader { geometry in
                        ForEach(highlights(snapshot)) { block in
                            Rectangle().stroke(Color.yellow, lineWidth: 2).background(Color.yellow.opacity(0.12))
                                .frame(width: block.bounds.width / CGFloat(snapshot.width) * geometry.size.width,
                                       height: block.bounds.height / CGFloat(snapshot.height) * geometry.size.height)
                                .offset(x: block.bounds.minX / CGFloat(snapshot.width) * geometry.size.width,
                                        y: block.bounds.minY / CGFloat(snapshot.height) * geometry.size.height)
                        }
                    }.allowsHitTesting(false)
                }
                .accessibilityLabel("Recorded screen at the cited capture time")
            if !snapshot.ref.blockIDs.isEmpty && !snapshot.highlightsVerified {
                Text("This extraction cannot verify the requested text region.").font(.caption).foregroundStyle(.secondary)
            }
            citationControls()
            if let url = currentURL(snapshot.frame.metadata.browserURL) { currentDocumentButton(url) }
            if let newer = model.newerRevision {
                Button("Open newer extraction (revision \(newer))") {
                    let ref = ScreenEvidenceRef(storeID: snapshot.ref.storeID, source: snapshot.ref.source,
                        observationID: snapshot.ref.observationID, frameID: snapshot.ref.frameID, extractionRevision: newer)
                    Task { await model.openEvidence(.screen(ref)) }
                }
                Text("The saved citation continues to identify revision \(snapshot.ref.extractionRevision).").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("Text extracted from this recorded screen").font(.headline)
            if let text = snapshot.text?.fullText, !text.isEmpty {
                Text(showAllText ? text : String(text.prefix(12_000))).textSelection(.enabled).font(.body)
                if text.count > 12_000 && !showAllText {
                    Button("Show all extracted text (\(text.count) characters)") { showAllText = true; Task { await model.track(.textExpanded) } }
                }
            } else { Text("Text is not available for this extraction revision.").foregroundStyle(.secondary) }
        }
    }

    private func citationControls() -> some View {
        Button {
            guard let url = model.evidenceReference?.deepLink else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
            Task { await model.track(.deepLinkCopied) }
        } label: { Label("Copy exact evidence link", systemImage: "link") }
        .disabled(model.evidenceReference == nil)
    }
    private func currentDocumentButton(_ url: URL) -> some View {
        Button {
            let success = NSWorkspace.shared.open(url)
            Task { await model.track(.currentDocumentOpened, outcome: success ? "success" : "failed") }
        } label: { Label("Open current document separately", systemImage: "arrow.up.right.square") }
        .help("Opens the current location. It may have changed since this recording.")
    }
    private func currentURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
    private struct Highlight: Identifiable { let id: Int; let bounds: CGRect }
    private func highlights(_ snapshot: ScreenEvidenceSnapshot) -> [Highlight] {
        guard snapshot.highlightsVerified, !snapshot.legacyContext, snapshot.width > 0, snapshot.height > 0,
              let text = snapshot.text else { return [] }
        let regions = text.regions + text.chromeRegions
        // IDs are immutable extraction block ordinals, exactly as carried by the citation.
        return snapshot.ref.blockIDs.compactMap { id in
            guard regions.indices.contains(id) else { return nil }
            return Highlight(id: id, bounds: regions[id].bounds)
        }
    }
    private func unavailable(_ reason: EvidenceUnavailableReason) -> String {
        switch reason {
        case .notPermitted: return "Current privacy settings do not permit opening this evidence."
        case .sourceDisconnected: return "The source library is disconnected. Reconnect that source to open this evidence."
        case .recordingMissing: return "The exact recording is unavailable. Retained metadata and text have not been deleted."
        case .frameFinalising: return "This frame is still being finalised. Try again shortly."
        case .evidenceDeleted: return "This evidence has been deleted."
        case .extractionUnavailable: return "The cited extraction revision or text block is unavailable."
        case .integrityFailure: return "The recording could not be verified against this exact evidence reference."
        case .unsupported: return "This evidence type is not supported in this viewer yet."
        }
    }
}
