import App
import AppKit
import Shared
import SwiftUI

/// An exact audio-only destination. No screen is fabricated for a speaker turn.
@MainActor
final class CompanionTurnWindowController: NSObject, NSWindowDelegate {
    static let shared = CompanionTurnWindowController()
    private var window: NSWindow?
    private var observed: (owner: CompanionController, id: UUID)?
    private var selected: (reference: CompanionTurnReference, coordinator: AppCoordinator)?
    private var generation = UUID()

    func open(_ reference: CompanionTurnReference, coordinator: AppCoordinator,
              authorization: RetraceForegroundAuthorization) async throws {
        let token = UUID()
        try authorization.effect { clear(); generation = token }
        let owner = try await coordinator.companion()
        let admission = NativeMutationFence()
        let dependencies = TurnWindowDependencies()
        let id = try owner.addSpeakerChangeObserver(invalidate: { [weak self] change in
            let affected: Bool
            switch change {
            case .all: affected = true
            case .source(let mutation): affected = dependencies.affected(by: mutation)
            case .correction(let jobID, _): affected = jobID == reference.jobID
            }
            guard affected else { return }
            admission.invalidate()
            Task { @MainActor [weak self] in
                guard self?.generation == token else { return }
                self?.clear()
            }
        })
        do {
            let turn = try await owner.resolveTurn(reference)
            dependencies.bind(turn.sourceDependencies)
            try await authorization.validate()
            try authorization.effect {
                try admission.withAdmission {
                    guard generation == token else { throw CancellationError() }
                    if let observed { observed.owner.removeSpeakerChangeObserver(observed.id) }
                    observed = (owner, id)
                    selected = (reference, coordinator)
                    let panel = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 640),
                        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
                    panel.isReleasedWhenClosed = false; panel.delegate = self; panel.title = "Selected speaker turn"
                    panel.minSize = NSSize(width: 460, height: 400)
                    panel.contentView = NSHostingView(rootView: CompanionTurnDetailView(turn: turn, coordinator: coordinator))
                    if window == nil { panel.center() }
                    window = panel
                    NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
                }
            }
        } catch { owner.removeSpeakerChangeObserver(id); throw error }
    }
    private func clear() {
        generation = UUID()
        if let observed { observed.owner.removeSpeakerChangeObserver(observed.id) }
        observed = nil; window?.contentView = nil; window?.orderOut(nil)
        if let selected {
            Task {
                await (try? selected.coordinator.companionTurnPlayback())?.stop(ifCurrent: selected.reference)
            }
        }
        selected = nil
    }
    func windowWillClose(_ notification: Notification) { clear() }
}

private final class TurnWindowDependencies: @unchecked Sendable {
    private let lock = NSLock()
    private var value = NativeSourceDependencies.unknown
    func bind(_ value: NativeSourceDependencies) { lock.withLock { self.value = value } }
    func affected(by mutation: NativeSourceMutation) -> Bool { lock.withLock { mutation.affects(value) } }
}

private struct CompanionTurnDetailView: View {
    let turn: CompanionTurnPresentation
    let coordinator: AppCoordinator
    @State private var playbackTask: Task<Void, Never>?
    @State private var message: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(turn.displayLabel).font(.title2.bold())
                Text(turn.speakerStatus == .manualName ? "Manually named in this recording" : turn.speakerStatus == .suggestion ? "Suggested identity — unconfirmed" : "Speaker identity is scoped to this recording")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(turn.approximateStart.formatted()) – \(turn.approximateEnd.formatted(date: .omitted, time: .standard))")
                Text("Approximate wall interval and model-estimated speech boundaries. Playback uses the verified original source samples.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(turn.turn.text).textSelection(.enabled)
                HStack {
                    Button("Play selected turn") {
                        playbackTask?.cancel()
                        playbackTask = Task {
                            do { try await coordinator.companionTurnPlayback().play(turn.reference) }
                            catch { if !Task.isCancelled { message = "This turn is no longer available. Reopen its current reference." } }
                        }
                    }
                    Button("Stop") { playbackTask?.cancel(); Task { await (try? coordinator.companionTurnPlayback())?.stop() } }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Divider()
                Text("Retained first pass — full original recording").font(.headline)
                Text("Preserved separately from turn alignment; may include overlapping speech outside this turn.").font(.caption).foregroundStyle(.secondary)
                Text(turn.firstPassText).textSelection(.enabled)
                Divider()
                Text("Source \(turn.reference.nativeStoreID)\nJob \(turn.reference.jobID)\nResult \(turn.reference.resultSHA256) · turn \(turn.reference.turnIndex)\nSamples \(turn.sourceIdentity.startSample)..<\(turn.sourceIdentity.startSample + turn.sourceIdentity.sampleCount) at \(turn.sourceIdentity.sampleRate) Hz")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text("This selection is audio evidence. Screen coverage is not implied.").font(.caption).foregroundStyle(.secondary)
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }.onDisappear { playbackTask?.cancel() }
    }
}
