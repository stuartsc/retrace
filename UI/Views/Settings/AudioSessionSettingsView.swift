import App
import Shared
import SwiftUI

/// Reads and updates the same owned configuration used by native MCP commands.
/// Opening Settings does not start capture or request a system-audio permission.
struct AudioSessionSettingsView: View {
    private let session: @Sendable () async throws -> AudioSessionOwner
    @State private var snapshot: AudioSessionSnapshot?
    @State private var busy = false
    @State private var message: String?

    init(coordinator: AppCoordinator) {
        session = { try await coordinator.audioSession() }
    }

    #if DEBUG
    /// Native fixture boundary: no AppCoordinator or capture owner is constructed.
    init(session: @escaping @Sendable () async throws -> AudioSessionOwner) {
        self.session = session
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Audio sources", systemImage: "mic").font(.headline)
            Toggle("Record microphone", isOn: Binding(
                get: { snapshot?.configured?.microphoneEnabled ?? false },
                set: { update(microphone: $0, systemAudio: snapshot?.configured?.systemAudioEnabled ?? false) }))
                .disabled(busy || snapshot?.configured == nil)
            Text("Microphone recording supplies transcripts, dictation and spoken markers while recording is active.")
                .font(.caption).foregroundStyle(.secondary)
            if let snapshot {
                Text("Microphone: \(label(snapshot.runtime.microphone.state)) · Session: \(label(snapshot.phase))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("System audio")
                Spacer()
                Text("Unavailable").foregroundStyle(.secondary)
            }
            Text("System audio recording is unavailable until application exclusions can be honoured by its capture source.")
                .font(.caption).foregroundStyle(.secondary)
            if snapshot?.configured?.systemAudioEnabled == true {
                Button("Turn off saved system audio setting") {
                    update(microphone: snapshot?.configured?.microphoneEnabled ?? false, systemAudio: false)
                }.disabled(busy)
            }
            if busy { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if snapshot == nil { Button("Retry") { Task { await refresh() } }.disabled(busy) }
        }
        .padding(18).background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .task {
            repeat {
                await refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            } while !Task.isCancelled
        }
    }

    @MainActor private func refresh() async {
        do {
            let value = try await session().snapshot()
            guard !Task.isCancelled else { return }
            snapshot = value
        } catch {
            if !Task.isCancelled { message = "Audio settings could not be read." }
        }
    }

    @MainActor private func update(microphone: Bool, systemAudio: Bool) {
        guard !busy, let configured = snapshot?.configured else { return }
        busy = true; message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await session().update(.init(expectedRevision: configured.revision,
                    microphoneEnabled: microphone, systemAudioEnabled: systemAudio))
                await refresh()
                message = snapshot?.phase == .degraded
                    ? "Setting saved. Audio is currently degraded; check the source status."
                    : "Audio setting saved."
            } catch {
                await refresh()
                message = "Audio settings changed or could not be saved. Review the current values and try again."
            }
        }
    }

    private func label(_ state: AudioSourceRuntimeState) -> String {
        switch state {
        case .disabled: "Off"
        case .paused: "Paused"
        case .running: "Recording"
        case .mutedForMeeting: "Muted during meeting"
        case .permissionDenied: "Permission required"
        case .unavailable: "Input unavailable"
        case .failed: "Capture failed"
        case .blockedByPolicy: "Unavailable"
        }
    }
    private func label(_ phase: AudioSessionPhase) -> String {
        switch phase {
        case .paused: "Paused"
        case .starting: "Starting"
        case .running: "Active"
        case .reconfiguring: "Updating"
        case .degraded: "Degraded"
        case .stopping: "Stopping"
        case .closed: "Closed"
        }
    }
}
