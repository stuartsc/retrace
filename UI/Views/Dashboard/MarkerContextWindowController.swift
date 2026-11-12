import App
import AppKit
import Shared
import SwiftUI

@MainActor
final class MarkerContextWindowController: NSObject, NSWindowDelegate {
    static let shared = MarkerContextWindowController()
    private(set) var window: NSWindow?
    private var model: MarkerContextViewModel?
    private var coordinator: AppCoordinator?
    private var generation = UUID()
    private var retiringPlayback: Task<Void, Never>?
    private var commandFence: NativeMutationFence?
    private let makeModel: @MainActor (AppCoordinator) -> MarkerContextViewModel
    private let playbackOwner: @MainActor (AppCoordinator) async throws -> MarkerAudioPlayback
    private let presentWindow: @MainActor (NSWindow) -> Void

    override init() {
        makeModel = { coordinator in MarkerContextViewModel(service: { try await coordinator.timelineMarkers() },
            presentations: { try await coordinator.contextRanges() }) }
        playbackOwner = { try await $0.markerPlayback() }
        presentWindow = { NSApp.activate(ignoringOtherApps: true); $0.makeKeyAndOrderFront(nil) }
        super.init()
    }
#if DEBUG
    init(makeModel: @escaping @MainActor (AppCoordinator) -> MarkerContextViewModel,
         playbackOwner: @escaping @MainActor (AppCoordinator) async throws -> MarkerAudioPlayback,
         presentWindow: @escaping @MainActor (NSWindow) -> Void) {
        self.makeModel = makeModel; self.playbackOwner = playbackOwner; self.presentWindow = presentWindow
        super.init()
    }
    var test_markerID: UUID? { model?.marker?.id }
#endif

    func open(markerID: UUID, expectedRevision: UUID, coordinator: AppCoordinator,
              authorization: RetraceForegroundAuthorization? = nil) async throws {
        let token = UUID()
        let begin = {
            if self.commandFence !== authorization?.fence { self.commandFence?.invalidate() }
            self.commandFence = authorization?.fence; self.generation = token
        }
        if let authorization { try authorization.effect(begin) } else { begin() }
        await retiringPlayback?.value
        guard generation == token else { throw CancellationError() }
        let model = makeModel(coordinator)
        defer { if self.model !== model { model.hide() } }
        try await model.load(id: markerID, expectedRevision: expectedRevision)
        try Task.checkCancellation()
        try await authorization?.validate()
        guard generation == token else { throw CancellationError() }
        if self.model != nil {
            if let authorization {
                let playback = try await playbackOwner(coordinator)
                try await authorization.validate()
                guard generation == token else { throw CancellationError() }
                try await playback.stop(commandFence: authorization.fence)
            } else { await (try? playbackOwner(coordinator))?.stop() }
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
        }
        try await authorization?.validate()
        let present = {
            guard self.generation == token else { throw CancellationError() }
            self.model?.hide()
            self.model = model; self.coordinator = coordinator
            let window = self.window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Marked moment"
            window.minSize = NSSize(width: 800, height: 600)
            window.delegate = self
            window.contentView = NSHostingView(rootView: MarkerContextDetailView(model: model, coordinator: coordinator))
            if self.window == nil { window.center() }
            self.window = window
            self.presentWindow(window)
        }
        if let authorization { try authorization.effect(present) } else { try present() }
    }

    func windowWillClose(_ notification: Notification) {
        commandFence?.invalidate(); commandFence = nil
        generation = UUID(); model?.hide(); model = nil
        window?.contentView = nil
        if let coordinator {
            let prior = retiringPlayback, playbackOwner = self.playbackOwner
            retiringPlayback = Task { await prior?.value; await (try? playbackOwner(coordinator))?.stop() }
        }
    }

}

private struct MarkerContextDetailView: View {
    @ObservedObject var model: MarkerContextViewModel
    let coordinator: AppCoordinator
    @State private var editing: ContextRangePresentationReference?
    @State private var editingUserAuthored = true
    @State private var selectedRangeID: UUID?
    @State private var start = Date()
    @State private var end = Date()
    @State private var explanation = ""
    @State private var pinned = false
    @State private var isPlaying = false
    @State private var audioMessage: String?
    @State private var playbackTask: Task<Void, Never>?
    @State private var editorExpanded = false
    @State private var editTask: Task<Void, Never>?

    private var selectedRange: MarkerContextRange? {
        model.presentations.first { $0.id == selectedRangeID && $0.availability == .available }?.range
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let marker = model.marker {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(marker.title).font(.title2.weight(.semibold))
                        Text("\(marker.spokenObservation == nil ? "Marked" : "Phrase around") \(marker.anchoredAt.formatted(date: .abbreviated, time: .standard))")
                            .font(.callout).foregroundStyle(.secondary)
                        if let observation = marker.spokenObservation {
                            Text(observation.status == .provisional ? "Provisional recognition" : observation.status == .withdrawn ? "Recognition withdrawn" : "Confirmed phrase")
                                .font(.caption).foregroundStyle(.secondary)
                            if observation.anchor.timingPrecision == .enclosingTimedSpan {
                                Text("Phrase boundaries are approximate; playback includes the enclosing speech span.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    if marker.spokenObservation != nil {
                        Button(isPlaying ? "Stop recording playback" : (marker.spokenObservation?.anchor.timingPrecision == .enclosingTimedSpan ? "Play enclosing speech" : "Play phrase")) {
                            playbackTask?.cancel()
                            playbackTask = Task {
                                do {
                                    let playback = try await coordinator.markerPlayback()
                                    try Task.checkCancellation()
                                    if isPlaying { await playback.stop() }
                                    else { try await playback.play(markerID: marker.id, expectedRevision: marker.revision) }
                                    audioMessage = nil
                                } catch { audioMessage = "Exact retained audio is unavailable for this marker." }
                            }
                        }
                    }
                }
                if let note = marker.note { Text(note).textSelection(.enabled) }
                if let audioMessage { Text(audioMessage).font(.caption).foregroundStyle(Color.retraceWarning) }
                if marker.screenReference == nil {
                    Text("This marker has no attached screenshot. Context ranges and audio can be reviewed independently.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(model.presentations) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.ownership.rawValue.capitalized).font(.caption.weight(.semibold))
                                if item.availability == .available, let range = item.range {
                                    Text("\(range.start.formatted(date: .omitted, time: .shortened)) – \(range.end.formatted(date: .omitted, time: .shortened))").font(.caption)
                                    Text(range.explanation).font(.caption).lineLimit(2)
                                    HStack {
                                        Button("Review") { review(item.reference) }.disabled(range.start >= range.end)
                                        Button("Edit / pin") { edit(item.reference) }
                                    }.controlSize(.small)
                                } else {
                                    Text(item.availability == .legacyUnverified ? "Earlier context has no verifiable source link." : "Supporting evidence is unavailable.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let note = item.userNote, !note.isEmpty {
                                    Text("Your note: \(note)").font(.caption).lineLimit(2)
                                }
                            }.padding(10).frame(width: 240, alignment: .leading)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }.frame(maxHeight: model.presentations.isEmpty ? 0 : 155)
                DisclosureGroup(editing == nil ? "Add a context range" : "Edit context range", isExpanded: $editorExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            DatePicker("From", selection: $start, displayedComponents: [.date, .hourAndMinute])
                            DatePicker("To", selection: $end, displayedComponents: [.date, .hourAndMinute])
                        }
                        TextField(editingUserAuthored ? "Why this interval belongs with the marker" : "Your note about this context (optional)", text: $explanation).textFieldStyle(.roundedBorder)
                        if !editingUserAuthored {
                            Text("Your note is separate from the source explanation. Pinning or editing does not change its source requirements.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Toggle("Pin this range", isOn: $pinned).toggleStyle(.checkbox)
                            Spacer()
                            if editing != nil { Button("Cancel edit") { clearEditor() } }
                            Button("Save range") { model.save(start: start, end: end, explanation: explanation, editing: editing, pinned: pinned) }
                                .disabled(start >= end || (editingUserAuthored && explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        }
                    }.padding(.top, 8).disabled(model.isSaving)
                }
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let range = selectedRange {
                    LiveContextWorkspaceView(coordinator: coordinator, isActive: true,
                        isRecording: coordinator.statusHolder.status.isRunning,
                        initialInterval: DateInterval(start: range.start, end: range.end)).id(range.id.uuidString + range.revision.uuidString)
                } else {
                    Text(model.presentations.isEmpty ? "Choose a range to review recorded context. No automatic before/after interval has been assumed." : "Select Review on an available context range to open its saved transcript and screen evidence.")
                        .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text(model.message ?? "Refreshing this marked moment…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(18).background(Color.retraceBackground)
        .onAppear { if let marker = model.marker { start = marker.anchoredAt; end = marker.anchoredAt } }
        .onChange(of: model.saveRevision) { _ in
            clearEditor()
        }
        .onDisappear { playbackTask?.cancel(); editTask?.cancel() }
        .task {
            while !Task.isCancelled {
                if let playback = try? await coordinator.markerPlayback() {
                    let state = await playback.snapshot()
                    isPlaying = state.isPlaying && state.markerID == model.marker?.id
                }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }
    private func review(_ reference: ContextRangePresentationReference) {
        editTask?.cancel()
        editTask = Task {
            do {
                _ = try await model.resolveForAction(reference)
                try Task.checkCancellation()
                selectedRangeID = reference.rangeID
            } catch { if !Task.isCancelled { audioMessage = "The context source changed. Refresh the marker before reviewing it." } }
        }
    }
    private func edit(_ reference: ContextRangePresentationReference) {
        editTask?.cancel()
        editTask = Task {
            do {
                let range = try await model.resolveForAction(reference)
                try Task.checkCancellation()
                editing = reference; start = range.start; end = range.end
                editingUserAuthored = range.effectiveExplanationOrigin == .userAuthored
                explanation = editingUserAuthored ? range.explanation : range.userNote ?? ""
                pinned = range.ownership == .pinned; editorExpanded = true
            } catch { if !Task.isCancelled { audioMessage = "The context source changed. Refresh the marker before editing." } }
        }
    }
    private func clearEditor() { editing = nil; editingUserAuthored = true; explanation = ""; pinned = false }
}
