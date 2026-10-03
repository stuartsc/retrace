import Combine
import Database
import Foundation
import Shared
import SwiftUI

struct DashboardSavedRecording: Identifiable, Equatable, Sendable {
    let request: TranscriptAudioRequest
    let transcriptStatus: String
    let hasTranscriptText: Bool

    var id: Int64 { request.id }
    var textStatusLabel: String {
        switch transcriptStatus {
        case "pending": return "Text not ready"
        case "needs_repair": return "Text needs another pass"
        case "transcribed" where hasTranscriptText: return "Text available"
        default: return "Audio saved"
        }
    }

    init(_ transcription: AudioTranscription) {
        request = TranscriptAudioRequest(transcription: transcription)
        transcriptStatus = transcription.transcriptStatus
        hasTranscriptText = !transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct DashboardSavedRecordingsPage: Sendable {
    let rows: [DashboardSavedRecording]
    let hasMore: Bool
}

enum DashboardSavedRecordingsQuery {
    static let maximumRows = 12

    static func load(queries: AudioTranscriptionQueries, through timestamp: Date) async throws -> DashboardSavedRecordingsPage {
        try Task.checkCancellation()
        let rows = try await queries.getTranscriptions(from: Date(timeIntervalSince1970: 0), to: timestamp,
            limit: maximumRows + 1, includeActivityRows: true)
        try Task.checkCancellation()
        let recordings = rows.prefix(maximumRows).map(DashboardSavedRecording.init).filter { $0.request.hasAudioPath }
        return DashboardSavedRecordingsPage(rows: recordings, hasMore: rows.count > maximumRows)
    }
}

@MainActor
final class DashboardSavedRecordingsModel: ObservableObject {
    @Published private(set) var rows: [DashboardSavedRecording] = []
    @Published private(set) var hasMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    let playback: TranscriptAudioPlayback
    private let load: @Sendable () async throws -> DashboardSavedRecordingsPage
    private var isActive = false
    private var refreshTask: Task<Void, Never>?
    private var refreshTaskID: UUID?
    private var refreshGeneration: UInt64?
    private var generation: UInt64 = 0

    init(playback: TranscriptAudioPlayback,
         load: @escaping @Sendable () async throws -> DashboardSavedRecordingsPage) {
        self.playback = playback
        self.load = load
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        generation &+= 1
        if !active {
            refreshTask?.cancel()
            rows = []
            hasMore = false
            errorMessage = nil
            isLoading = false
            playback.stop(reason: .closed)
        } else {
            isLoading = refreshTask != nil
        }
    }

    func refresh() async {
        guard isActive, !Task.isCancelled else { return }
        let generation = generation
        isLoading = true
        defer {
            if self.generation == generation, refreshTask == nil { isLoading = false }
        }
        while let refreshTask {
            let joinedGeneration = refreshGeneration
            await refreshTask.value
            guard isActive, self.generation == generation, !Task.isCancelled else { return }
            // Same-generation callers share their owner's result. A reopened view must
            // wait for the cancelled old read to drain before requesting fresh rows.
            if joinedGeneration == generation { return }
        }
        let taskID = UUID()
        let task = Task { [weak self, load] in
            defer {
                if self?.refreshTaskID == taskID {
                    self?.refreshTask = nil
                    self?.refreshTaskID = nil
                    self?.refreshGeneration = nil
                    if self?.generation == generation || self?.isActive == false {
                        self?.isLoading = false
                    }
                }
            }
            let started = ContinuousClock.now
            do {
                try Task.checkCancellation()
                let page = try await load()
                guard !Task.isCancelled, let self, self.isActive, self.generation == generation else { return }
                self.playback.retainSelection(in: page.rows.map(\.request))
                self.rows = page.rows
                self.hasMore = page.hasMore
                self.errorMessage = nil
            } catch {
                guard !Task.isCancelled, let self, self.isActive, self.generation == generation else { return }
                self.playback.stop(reason: .selectionChanged)
                self.rows = []
                self.hasMore = false
                self.errorMessage = "Unable to load saved recordings"
            }
            let elapsed = started.duration(to: .now).components
            Log.recordLatency("dashboard.live.saved_audio_read",
                valueMs: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15, category: .ui)
        }
        refreshTask = task
        refreshTaskID = taskID
        refreshGeneration = generation
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// Deliberate playback only. This small current page never traverses old transcript history.
struct DashboardSavedRecordingsView: View {
    @ObservedObject var model: DashboardSavedRecordingsModel
    @ObservedObject private var playback: TranscriptAudioPlayback
    let isActive: Bool
    let sourceRevision: UInt64

    init(model: DashboardSavedRecordingsModel, isActive: Bool, sourceRevision: UInt64) {
        self.model = model
        self.playback = model.playback
        self.isActive = isActive
        self.sourceRevision = sourceRevision
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Recent saved recordings").font(.retraceCaptionMedium)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.mini) }
            }
            Text("Audio is saved while text waits for background processing. Play a recording without starting transcription.")
                .font(.retraceCaption2)
                .foregroundColor(.retraceSecondary)
            if let message = model.errorMessage {
                Text(message).font(.retraceCaption2).foregroundColor(.retraceWarning)
            } else if model.rows.isEmpty && !model.isLoading {
                Text("No saved recordings in the newest audio entries.")
                    .font(.retraceCaption2).foregroundColor(.retraceSecondary)
            }
            ForEach(model.rows) { recording in
                recordingRow(recording)
            }
            if model.hasMore {
                Text("Showing \(model.rows.count) saved recordings among the newest \(DashboardSavedRecordingsQuery.maximumRows) audio entries. Open Audio Recordings on the timeline to browse other times.")
                    .font(.retraceCaption2).foregroundColor(.retraceSecondary)
            }
        }
        .padding(10)
        .background(Color.retraceAccent.opacity(0.04))
        .cornerRadius(10)
        .task(id: "\(isActive):\(sourceRevision)") {
            model.setActive(isActive)
            guard isActive else { return }
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
            }
        }
        .onChange(of: isActive) { model.setActive($0) }
        .onDisappear { model.setActive(false) }
    }

    private func recordingRow(_ recording: DashboardSavedRecording) -> some View {
        let selected = playback.state.request == recording.request
        let playing = selected && playback.state.phase == .playing
        let loading = selected && playback.state.phase == .loading
        let paused = selected && playback.state.phase == .paused
        let action = loading ? "Cancel audio loading" : (playing ? "Pause recording" : (paused ? "Resume recording" : "Play recording"))
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.request.start.formatted(date: .abbreviated, time: .shortened))
                    .font(.retraceCaption2Medium)
                Text("\(recording.request.source.displayName) · \(recording.textStatusLabel)")
                    .font(.retraceCaption2).foregroundColor(.retraceSecondary)
                if selected, let message = playback.state.message {
                    Text(message).font(.retraceCaption2).foregroundColor(.retraceWarning)
                }
            }
            Spacer(minLength: 0)
            Button { playback.toggle(recording.request) } label: {
                if loading { ProgressView().controlSize(.mini) }
                else { Image(systemName: playing ? "pause.fill" : "play.fill") }
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .disabled(!isActive)
            .help(action)
            .accessibilityLabel("\(action) from \(recording.request.start.formatted(date: .abbreviated, time: .shortened))")
        }
    }
}
