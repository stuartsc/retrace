import App
import Shared
import SwiftUI

/// Manual bounded retention, with the same exact review and execution owner as MCP.
struct RetentionReviewView: View {
    @StateObject private var model: RetentionReviewModel
    init(coordinator: AppCoordinator) {
        _model = StateObject(wrappedValue: RetentionReviewModel(service: { try await coordinator.retentionCommands() }))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Review older screen history", systemImage: "calendar.badge.minus").font(.headline)
            Text("Review one bounded page before deleting native screenshots and eligible sessions. Audio, protected sessions and existing video files remain retained. This operation reports no reclaimed disk space.")
                .font(.callout).foregroundStyle(.secondary)
            DatePicker("Before", selection: Binding(get: { model.cutoff }, set: { model.changeCutoff($0) }),
                       in: ...Date(), displayedComponents: [.date, .hourAndMinute]).disabled(model.busy)
            HStack {
                Button(model.preview == nil ? "Preview deletion" : "Refresh preview") { model.loadPreview() }.disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small) }
                if let phase = model.phase { Text(phase.label).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if model.busy { Button("Cancel") { model.cancel() } }
            }
            if let preview = model.preview {
                Text("This page: \(preview.frames) screenshots, \(preview.sessions) sessions and \(preview.videoCandidates) video records.")
                Text("Scanned \(preview.scannedFrames) screen rows and \(preview.scannedVideos) video rows; skipped \(preview.skippedFrames) screen rows and \(preview.skippedVideos) video rows. \(preview.deferredVideoFiles) existing video files are deferred.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Review expires \(preview.expiresAt.formatted(date: .omitted, time: .standard)).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Confirm deletion of this page", role: .destructive) { model.confirm() }
                    .disabled(model.busy || preview.expiresAt <= Date())
                    .accessibilityIdentifier("retention.confirm")
            }
            if let outcome = model.outcome {
                Text("Deleted \(outcome.deletedFrames) screenshots, \(outcome.deletedSessions) sessions and \(outcome.deletedVideoRows) video records. \(outcome.pendingVideoFiles) video files remain pending. Audio is retained.")
                if outcome.partial { Text("This result covers part of the eligible history. Review another page to continue.").font(.caption).foregroundStyle(.secondary) }
            }
            if model.nextContinuationID != nil {
                Button("Preview next page") { model.loadNextPage() }.disabled(model.busy)
                Text("Moving to another page replaces an unconfirmed preview. Each page needs its own confirmation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(18).background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .onDisappear { model.cancel() }
    }
}

@MainActor
final class RetentionReviewModel: ObservableObject {
    struct Client: Sendable {
        let preview: @Sendable (Date, UUID?) async throws -> RetentionCommandPreview
        let execute: @Sendable (RetentionCommandPreview, NativeMutationFence, @escaping @Sendable (RetentionCommandPhase) async -> Void) async throws -> RetentionCommandOutcome
    }
    @Published private(set) var cutoff: Date
    @Published private(set) var preview: RetentionCommandPreview?
    @Published private(set) var outcome: RetentionCommandOutcome?
    @Published private(set) var nextContinuationID: UUID?
    @Published private(set) var busy = false
    @Published private(set) var phase: RetentionCommandPhase?
    @Published private(set) var message: String?
    private let client: Client
    private var task: Task<Void, Never>?
    private var fence: NativeMutationFence?

    convenience init(service: @escaping @Sendable () async throws -> RetentionCommandService) {
        let clientID = "local-retention-\(UUID().uuidString)"
        self.init(client: .init(preview: { cutoff, continuation in
            try await service().preview(clientID: clientID, cutoff: cutoff, continuationID: continuation)
        }, execute: { preview, fence, progress in
            try await service().execute(preview: preview, clientID: clientID, commandFence: fence, progress: progress)
        }))
    }
    init(client: Client, cutoff: Date = Date().addingTimeInterval(-30 * 86_400)) {
        self.client = client; self.cutoff = cutoff
    }
    func changeCutoff(_ date: Date) {
        guard !busy else { return }
        cutoff = date; preview = nil; outcome = nil; nextContinuationID = nil; message = nil; phase = nil
    }
    func loadPreview() { load(continuation: nil) }
    func loadNextPage() {
        guard let token = nextContinuationID else { return }
        load(continuation: token)
    }
    private func load(continuation: UUID?) {
        guard !busy else { return }
        let cutoff = cutoff
        busy = true; preview = nil; outcome = nil; nextContinuationID = nil; message = nil; phase = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                let value = try await client.preview(cutoff, continuation)
                try Task.checkCancellation()
                preview = value; nextContinuationID = value.nextContinuationID
            } catch { message = Self.message(for: error) }
        }
    }
    func confirm() {
        guard !busy, let selected = preview, selected.expiresAt > Date() else { return }
        let admission = NativeMutationFence(expiresAt: selected.expiresAt)
        fence = admission; busy = true; message = nil; outcome = nil; phase = .validating
        preview = nil
        task = Task {
            defer { busy = false; task = nil; fence = nil }
            do {
                outcome = try await client.execute(selected, admission) { [weak self] value in
                    await MainActor.run { self?.phase = value }
                }
                // A cancelled caller still receives counts from an already committed deletion.
                phase = .completed
            } catch { message = Self.message(for: error); phase = nil }
        }
    }
    func cancel() { fence?.invalidate(); task?.cancel() }
    private static func message(for error: Error) -> String {
        if error is CancellationError { return "Cancelled before completion. Review current history before trying again." }
        switch error as? RetentionCommandError {
        case .stalePreview: return "The reviewed history or policy changed. Create a new preview."
        case .busy: return "Another retention review is active. Try again shortly."
        case .invalidArguments: return "Choose a valid cutoff in the past."
        default: return "Retention is unavailable. No further deletion was requested."
        }
    }
}

private extension RetentionCommandPhase {
    var label: String {
        switch self {
        case .validating: return "Checking reviewed history"
        case .deletingScreens: return "Deleting reviewed screenshots"
        case .drainingOutput: return "Closing affected playback"
        case .checkingVideos: return "Checking video records"
        case .completed: return "Completed"
        }
    }
}
