import App
import SwiftUI

/// Independent comparison switch. This never grants system audio recording consent.
@MainActor
struct MeetingComparisonSettings: View {
    let coordinator: AppCoordinator
    @StateObject private var status = MeetingStatusModel()
    @State private var task: Task<Void, Never>?
    @State private var changing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Compare call controls and app audio activity", isOn: Binding(
                get: { status.snapshot?.comparisonEnabled ?? false }, set: change))
                .disabled(status.snapshot == nil || changing)
            Text("Uses visible call controls and the same app's audio input activity. An open meeting app alone means only a possible call. Audio recording continues to follow your existing settings.")
                .font(.caption).foregroundStyle(.secondary)
            Text(status.summary).font(.caption).foregroundStyle(.secondary)
            if changing { ProgressView().controlSize(.small) }
        }
        .task {
            let current = await coordinator.meetingHealth()
            guard !Task.isCancelled else { return }
            status.update(current)
        }
        .onDisappear { task?.cancel(); status.close() }
    }

    private func change(_ enabled: Bool) {
        guard !changing else { return }
        changing = true
        task = Task {
            await coordinator.setMeetingComparisonEnabled(enabled)
            let current = await coordinator.meetingHealth()
            if !Task.isCancelled { status.update(current) }
            changing = false; task = nil
        }
    }
}
