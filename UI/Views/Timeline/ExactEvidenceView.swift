import SwiftUI
import AppKit
import Shared

struct ExactEvidenceView: View {
    @ObservedObject var model: EvidenceViewModel
    var showsImage = true
    var showsClose = true
    var onClose: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Recorded evidence").font(.title2.bold())
                    Spacer()
                    if showsClose && model.isPresentingEvidence {
                        Button("Close") {
                            if let onClose { onClose() } else { model.closeEvidence() }
                            Task { await model.track(.evidenceClosed) }
                        }
                    }
                }
                if model.resolvingEvidence { ProgressView("Resolving this exact evidence…") }
                else if let result = model.resolution {
                    resolved(result)
                } else {
                    Text("Select a screenshot to see its recorded context and extracted text.")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
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
                    revisionControls(retained)
                    EvidenceTextView(reference: retained.ref, model: model)
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
            Text("Captured context").font(.headline)
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
            if let app = snapshot.frame.metadata.appName ?? snapshot.frame.metadata.appBundleID {
                Text(app).font(.callout).foregroundStyle(.secondary)
            }
            if let context = snapshot.frame.metadata.captureContext, !context.uncertainty.isEmpty {
                Text(context.uncertainty.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary)
            }
            if snapshot.legacyContext {
                Text("Legacy attribution: the saved title or URL may describe the surrounding session. Precise text highlights are unavailable.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if showsImage { ExactEvidenceImage(snapshot: snapshot, image: image) }
            if !snapshot.ref.blockIDs.isEmpty && !snapshot.highlightsVerified {
                Text("This extraction cannot verify the requested text region.").font(.caption).foregroundStyle(.secondary)
            }
            citationControls()
            if let url = currentURL(snapshot.frame.metadata.browserURL) { currentDocumentButton(url) }
            revisionControls(snapshot)
            Divider()
            Text("Text extracted from this recorded screen").font(.headline)
            EvidenceTextView(reference: snapshot.ref, model: model)
        }
    }

    @ViewBuilder private func revisionControls(_ snapshot: ScreenEvidenceSnapshot) -> some View {
        if !snapshot.ref.blockIDs.isEmpty {
            Button("Read all text from this screen") {
                let reference = ScreenEvidenceRef(storeID: snapshot.ref.storeID, source: snapshot.ref.source,
                    observationID: snapshot.ref.observationID, frameID: snapshot.ref.frameID,
                    extractionRevision: snapshot.ref.extractionRevision)
                Task { await model.openEvidence(.screen(reference)) }
            }
        }
        if let newer = model.newerRevision {
            Button("Open newer extraction (revision \(newer))") {
                let ref = ScreenEvidenceRef(storeID: snapshot.ref.storeID, source: snapshot.ref.source,
                    observationID: snapshot.ref.observationID, frameID: snapshot.ref.frameID, extractionRevision: newer)
                Task { await model.openEvidence(.screen(ref)) }
            }
            Text("The saved citation continues to identify revision \(snapshot.ref.extractionRevision).").font(.caption).foregroundStyle(.secondary)
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

/// Shared image rendering keeps timeline and Screenshots on the same verified pixels.
struct ExactEvidenceImage: View {
    let snapshot: ScreenEvidenceSnapshot
    let image: CGImage

    var body: some View {
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
    }
    private struct Highlight: Identifiable { let id: Int; let bounds: CGRect }
    private func highlights(_ snapshot: ScreenEvidenceSnapshot) -> [Highlight] {
        guard snapshot.highlightsVerified, !snapshot.legacyContext, snapshot.width > 0, snapshot.height > 0,
              let text = snapshot.text else { return [] }
        // IDs are immutable extraction block ordinals, exactly as carried by the citation.
        return snapshot.ref.blockIDs.compactMap { id in
            let region: TextRegion
            if text.regions.indices.contains(id) { region = text.regions[id] }
            else {
                let chromeID = id - text.regions.count
                guard text.chromeRegions.indices.contains(chromeID) else { return nil }
                region = text.chromeRegions[chromeID]
            }
            let bounds = region.bounds
            guard bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite,
                  bounds.minX >= 0, bounds.minY >= 0, bounds.width > 0, bounds.height > 0,
                  bounds.maxX <= CGFloat(snapshot.width), bounds.maxY <= CGFloat(snapshot.height) else { return nil }
            return Highlight(id: id, bounds: bounds)
        }
    }
}
