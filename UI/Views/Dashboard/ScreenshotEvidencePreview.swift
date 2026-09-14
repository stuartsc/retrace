import SwiftUI
import Shared
import App

/// Capture identity deliberately excludes mutable metadata and processing status.
/// A background OCR refresh must not silently replace a selected extraction.
struct ScreenshotEvidenceSelection: Hashable, Sendable {
    let source: FrameSource
    let frameID: FrameID
    let capturedAt: Date
    let sourceGeneration: String?

    init(_ frame: FrameReference, sourceGeneration: String? = nil) {
        source = frame.source
        frameID = frame.id
        capturedAt = frame.timestamp
        self.sourceGeneration = sourceGeneration
    }

    func matches(_ frame: FrameReference) -> Bool {
        source == frame.source && frameID == frame.id && abs(capturedAt.timeIntervalSince(frame.timestamp)) < 0.001
    }

    var previewKey: String { "\(source.rawValue):\(frameID.value):\(capturedAt.timeIntervalSince1970.bitPattern):\(sourceGeneration ?? "")" }
}

extension FrameReference {
    var screenshotIdentity: ScreenshotEvidenceSelection { ScreenshotEvidenceSelection(self) }
}

protocol DashboardScreenshotRepresentable {
    var frame: FrameReference { get }
    var screenshotIdentity: ScreenshotEvidenceSelection { get }
}

extension FrameWithVideoInfo: DashboardScreenshotRepresentable {
    var screenshotIdentity: ScreenshotEvidenceSelection { frame.screenshotIdentity }
}

/// The token is captured with the query result and never inferred from a later
/// global source mapping when this row is selected or displayed.
struct DashboardScreenshotRow: Sendable, Identifiable, DashboardScreenshotRepresentable {
    let value: FrameWithVideoInfo
    let sourceGeneration: String
    var frame: FrameReference { value.frame }
    var videoInfo: FrameVideoInfo? { value.videoInfo }
    var processingStatus: Int { value.processingStatus }
    var screenshotIdentity: ScreenshotEvidenceSelection { ScreenshotEvidenceSelection(frame, sourceGeneration: sourceGeneration) }
    var id: ScreenshotEvidenceSelection { screenshotIdentity }
}

struct DashboardScreenshotEvidenceRequest: Equatable {
    let selection: ScreenshotEvidenceSelection?
    let available: Bool
    let epoch: UInt64
}

struct DashboardScreenshotFilterRequest: Equatable {
    let query: String
    let contentRevision: UInt64
    let epoch: UInt64
}

/// Shared by selection, explicit retry and bounded polling. A successfully
/// cited revision stays selected when background OCR publishes a newer one.
@MainActor
final class DashboardScreenshotEvidencePresenter {
    private var selection: ScreenshotEvidenceSelection?

    func show(_ row: DashboardScreenshotRow, model: EvidenceViewModel) async {
        guard !Task.isCancelled else { return }
        if selection == row.id, model.evidenceReference != nil {
            await model.refreshCurrentRevision()
            return
        }
        selection = row.id
        await model.openFrame(row.frame, expectedSourceGeneration: row.sourceGeneration)
    }

    func close(model: EvidenceViewModel) {
        selection = nil
        model.closeEvidence()
    }
}

struct ScreenshotEvidencePreview: View {
    @ObservedObject var model: EvidenceViewModel
    let selection: ScreenshotEvidenceSelection?
    let selectionAvailable: Bool
    let completedSelection: ScreenshotEvidenceSelection?
    let retrySelection: () -> Void
    let openTimeline: (EvidenceRef) -> Void

    private var snapshot: ScreenEvidenceSnapshot? {
        let snapshot: ScreenEvidenceSnapshot?
        if case .screen(let saved, _) = model.resolution { snapshot = saved }
        else { snapshot = model.retainedSnapshot }
        guard selectionAvailable, completedSelection == selection, let snapshot, selection?.matches(snapshot.frame) == true else { return nil }
        return snapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Recorded screenshot", systemImage: "viewfinder").font(.headline)
                Spacer()
                if let snapshot {
                    Button("Open moment") { openTimeline(.screen(snapshot.ref)) }
                        .help("Open this exact recording and extraction in the timeline")
                }
            }
            if let selection {
                Text(selection.capturedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(Color.black.opacity(0.24))
                if let snapshot, case .screen(_, let image) = model.resolution {
                    ExactEvidenceImage(snapshot: snapshot, image: image).padding(8)
                } else if selection == nil {
                    Text("Select a screenshot to inspect it.").foregroundStyle(.secondary)
                } else if !selectionAvailable {
                    Text("The selected screenshot is no longer available.").foregroundStyle(.secondary)
                } else if completedSelection != selection || model.resolvingEvidence || !model.isPresentingEvidence {
                    ProgressView("Opening recorded evidence…")
                } else {
                    Label("The exact image is unavailable. See the evidence details.", systemImage: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if selectionAvailable, selection != nil, model.evidenceReference == nil,
               model.isPresentingEvidence, !model.resolvingEvidence {
                Button("Retry screenshot", action: retrySelection)
            }
            if let snapshot {
                Text(snapshot.frame.metadata.windowName ?? snapshot.frame.metadata.appName ?? "Recorded screen")
                    .font(.callout).textSelection(.enabled)
                Text("\(snapshot.ref.source.displayName) · Extraction \(snapshot.ref.extractionRevision)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Each visible appearance reacquires current evidence permission. The shared
/// loader bounds decoding; pixels live only in this row's presentation owner.
struct DashboardScreenshotThumbnail: View {
    let row: DashboardScreenshotRow
    let isVisible: Bool
    let epoch: UInt64
    let loader: SearchEvidenceThumbnailLoader
    let service: () async throws -> ProgressiveRecallService
    @StateObject private var preview = SearchEvidenceThumbnailPreview()

    private struct Request: Equatable {
        let key: String
        let value: FrameWithVideoInfo
        let isVisible: Bool
    }
    private var key: String { "\(row.id.previewKey):\(epoch)" }
    private var request: Request { Request(key: key, value: row.value, isVisible: isVisible) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.035))
            if isVisible, let image = preview.image(for: key) {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: preview.isUnavailable(for: key) ? "photo.badge.exclamationmark" : "photo")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 82, height: 50).clipShape(RoundedRectangle(cornerRadius: 7))
        .task(id: request) {
            guard isVisible else { preview.hide(); return }
            await preview.show(row.frame, expectedSourceGeneration: row.sourceGeneration, key: key,
                loader: loader, size: CGSize(width: 164, height: 100), service: service)
        }
        .onDisappear { preview.hide() }
    }
}
