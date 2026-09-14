import AppKit
import SwiftUI
import App
import Shared

@MainActor
private final class ActivityTimelineHostState: ObservableObject {
    @Published var model: ActivityTimelineViewModel?
    @Published var failed = false
}

@MainActor
final class ActivityTimelineController: NSObject, NSWindowDelegate {
    static let shared = ActivityTimelineController()
    private var window: NSWindow?
    private let state = ActivityTimelineHostState()
    private var startup: Task<ActivityTimelineViewModel, Error>?
    private var presentation: Task<Void, Never>?
    private var generation = 0

    func show(coordinator: AppCoordinator, evidence: EvidenceRef? = nil) {
        present(coordinator: coordinator) { model in
            if let evidence { await model.openEvidence(evidence) }
        }
    }

    func openSearchResult(_ result: SearchResult, coordinator: AppCoordinator) {
        present(coordinator: coordinator) { await $0.openSearchResult(result) }
    }

    private func present(coordinator: AppCoordinator, selection: @escaping @MainActor (ActivityTimelineViewModel) async -> Void) {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.title = "Activity & Evidence"
            panel.minSize = NSSize(width: 900, height: 580)
            panel.isReleasedWhenClosed = false; panel.delegate = self
            panel.contentView = NSHostingView(rootView: ActivityTimelineHost(state: state))
            panel.center(); window = panel
        }
        // The legacy fullscreen timeline sits at screen-saver level. Dismiss its
        // presentation so this normal window and separately opened documents remain usable.
        if TimelineWindowController.shared.isVisible { TimelineWindowController.shared.hide() }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        generation += 1; let token = generation
        presentation?.cancel(); state.failed = false
        presentation = Task { [weak self] in
            guard let self else { return }
            do {
                let model = try await readyModel(coordinator: coordinator)
                guard token == generation, !Task.isCancelled else { return }
                state.model = model
                await model.track(.opened)
                await model.refresh()
                guard token == generation, !Task.isCancelled else { return }
                await selection(model)
            } catch { if token == generation { state.failed = true } }
        }
    }

    private func readyModel(coordinator: AppCoordinator) async throws -> ActivityTimelineViewModel {
        if let model = state.model { return model }
        if let startup { return try await startup.value }
        let task = Task {
            let service = try await coordinator.progressiveRecall()
            return ActivityTimelineViewModel(client: .live(service: service, coordinator: coordinator))
        }
        startup = task
        defer { startup = nil }
        return try await task.value
    }

    func windowWillClose(_ notification: Notification) {
        generation += 1; presentation?.cancel(); presentation = nil
        state.model?.cancel()
    }
}

private struct ActivityTimelineHost: View {
    @ObservedObject var state: ActivityTimelineHostState
    var body: some View {
        Group {
            if let model = state.model { ActivityTimelineView(model: model) }
            else if state.failed { Text("Activity could not be opened. Close this window and try again.").padding() }
            else { ProgressView("Opening activity and evidence…").padding() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
