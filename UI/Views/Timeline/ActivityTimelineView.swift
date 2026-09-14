import SwiftUI
import AppKit
import App
import Shared

struct ActivityTimelineView: View {
    @ObservedObject var model: ActivityTimelineViewModel
    @State private var expanded: Set<UUID> = []
    @State private var correction: CorrectionDraft?
    @State private var confirmDelete = false
    @State private var showCorrectionHistory = false
    @State private var useDates = false
    @State private var start = Date().addingTimeInterval(-86_400)
    @State private var end = Date()
    private struct CorrectionDraft: Identifiable { let id = UUID(); let action: ActivityCorrectionAction }

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding()
            Divider()
            HSplitView {
                activityList.frame(minWidth: 390, idealWidth: 510)
                ExactEvidenceView(model: model).frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $correction) { draft in
            ActivityCorrectionSheet(model: model, action: draft.action)
        }
        .alert("Delete selected activity?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) { Task { await model.track(.deletionCancelled) } }
            Button("Delete activity", role: .destructive) { Task { await model.deleteSelected() } }
        } message: {
            Text("This permanently removes \(model.selectedEventIDs.count) activity observations and their corrections and screen associations. Recorded screens remain subject to their separate retention and deletion controls.")
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Activity & Evidence").font(.title2.bold())
                Spacer()
                Toggle("Group related visits", isOn: Binding(get: { model.grouped }, set: { value in Task { await model.setGrouped(value) } }))
                    .toggleStyle(.checkbox)
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            HStack {
                Toggle("Collect activity context while recording", isOn: Binding(get: { model.contextEnabled ?? false },
                    set: { enabled in Task { await model.setContextCollection(enabled) } }))
                    .toggleStyle(.checkbox).disabled(model.contextEnabled == nil || model.changingContextCollection)
                Text("Applies to future observations. Master recording pause still applies.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Search app names, window titles and observed URLs", text: $model.queryText)
                    .textFieldStyle(.roundedBorder).onSubmit(search)
                Picker("App", selection: $model.appBundleID) {
                    Text("All apps").tag("")
                    ForEach(availableApps, id: \.id) { app in Text(app.name).tag(app.id) }
                }.frame(maxWidth: 190)
                Button("Search", action: search).disabled(model.isLoading)
            }
            HStack {
                Toggle("Date range", isOn: $useDates).toggleStyle(.checkbox)
                DatePicker("From", selection: $start).labelsHidden().disabled(!useDates)
                Text("to").foregroundStyle(.secondary)
                DatePicker("To", selection: $end).labelsHidden().disabled(!useDates)
                Spacer()
                Text("Metadata is available before text extraction.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private struct AppChoice: Identifiable { let id: String; let name: String }
    private var availableApps: [AppChoice] {
        var apps: [String: String] = [:]
        for event in model.events { if let context = event.event.context { apps[context.appBundleID] = context.appName } }
        if !model.appBundleID.isEmpty, apps[model.appBundleID] == nil { apps[model.appBundleID] = model.appBundleID }
        return apps.map { AppChoice(id: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }
    private func search() {
        model.from = useDates ? start : nil; model.to = useDates ? end : nil
        Task { await model.refresh() }
    }

    private var activityList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ActivityStageHealthView(model: model)
                visibilityControls
                if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                if !model.selectedEventIDs.isEmpty { correctionControls }
                if model.visibleEpisodes.isEmpty, !model.isLoading {
                    Text(model.hasMore ? "No visible activity in this page. Continue through history below." : "No activity matches these filters.")
                        .foregroundStyle(.secondary).padding(.vertical)
                }
                ForEach(model.visibleEpisodes) { episode in episodeRow(episode) }
                if model.isLoading { ProgressView("Loading activity…").frame(maxWidth: .infinity) }
                if model.hasMore { Button("Load more activity") { Task { await model.loadMore() } }.disabled(model.isLoading) }
                correctionHistory
            }.padding()
        }
    }

    private var visibilityControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Hide visits under 10 seconds (\(model.hiddenGlanceCount))", isOn: $model.hideGlances)
                .toggleStyle(.checkbox)
                .onChange(of: model.hideGlances) { hidden in
                    Task { await model.track(hidden ? .glancesHidden : .glancesRevealed, count: model.hiddenGlanceCount) }
                }
            if model.hiddenEpisodeCount > 0 {
                Toggle("Reveal \(model.hiddenEpisodeCount) hidden episodes", isOn: $model.revealHidden).toggleStyle(.checkbox)
                    .onChange(of: model.revealHidden) { revealed in
                        Task { await model.track(revealed ? .hiddenEpisodesRevealed : .hiddenEpisodesHidden, count: model.hiddenEpisodeCount) }
                    }
            }
            Text("Focus duration describes observed foreground time. A brief visit does not establish distraction.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var correctionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Selected observations: \(model.selectedEventIDs.count)").font(.subheadline.bold())
                Spacer(); Button("Clear") {
                    let count = model.selectedEventIDs.count; model.selectedEventIDs = []
                    Task { await model.track(.selectionCleared, count: count) }
                }
            }
            HStack {
                Menu("Correct selected…") {
                    Button("Rename…") { openCorrection(.rename) }
                    Button("Assign project…") { openCorrection(.assignProject) }
                    Button("Group selected…") { openCorrection(.group) }
                    Button("Keep separate…") { openCorrection(.separate) }
                    Button("Hide from timeline…") { openCorrection(.hide) }
                }
                Button("Exclude from future capture…") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                    Task { await model.track(.captureSettingChanged, outcome: "pending") }
                }
                Button("Delete…", role: .destructive) {
                    confirmDelete = true; Task { await model.track(.deletionOpened, count: model.selectedEventIDs.count) }
                }
            }.disabled(model.isMutating || model.selectedEventIDs.count > 500)
            if model.selectedEventIDs.count > 500 { Text("Select at most 500 observations per correction or deletion.").font(.caption) }
        }.padding(10).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func openCorrection(_ action: ActivityCorrectionAction) {
        correction = .init(action: action)
        Task { await model.track(.correctionOpened, outcome: action.rawValue, count: model.selectedEventIDs.count) }
    }

    private func episodeRow(_ episode: ActivityEpisode) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(episode.id) }, set: { value in
            if value { expanded.insert(episode.id); Task { await model.track(.expanded) } }
            else { expanded.remove(episode.id); Task { await model.track(.collapsed) } }
        })) {
            VStack(alignment: .leading, spacing: 12) {
                let visible = model.visibleIntervals(in: episode)
                if visible.count < episode.intervals.count {
                    Text("Short visits hidden: \(episode.intervals.count - visible.count). Turn off Hide visits to reveal them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(visible) { interval in intervalRow(interval) }
            }.padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title).font(.headline).lineLimit(2)
                Text("\(duration(episode.focusDuration)) observed focus · \(duration(episode.spanDuration)) span · \(episode.intervals.count) intervals")
                    .font(.caption).foregroundStyle(.secondary)
                Text(episode.classification).font(.caption).foregroundStyle(episode.pendingCorrectionIDs.isEmpty ? Color.secondary : .orange)
            }.padding(.vertical, 5)
        }.padding(10).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func intervalRow(_ interval: ActivityInterval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Toggle("Select interval", isOn: Binding(get: {
                    !interval.eventIDs.isEmpty && interval.eventIDs.allSatisfy(model.selectedEventIDs.contains)
                }, set: { value in
                    if value { model.selectedEventIDs.formUnion(interval.eventIDs) }
                    else { model.selectedEventIDs.subtract(interval.eventIDs) }
                    Task { await model.track(value ? .intervalSelected : .intervalDeselected, count: interval.eventIDs.count) }
                })).labelsHidden().toggleStyle(.checkbox).disabled(interval.eventIDs.isEmpty)
                VStack(alignment: .leading, spacing: 3) {
                    Text(interval.context?.windowTitle ?? interval.context?.appName ?? interval.coverage.rawValue.capitalized).font(.subheadline.bold())
                    Text("\(interval.startedAt.formatted(date: .abbreviated, time: .standard)) — \(interval.endedAt.formatted(date: .omitted, time: .standard))")
                    Text("\(interval.context?.appName ?? "Coverage") · \(interval.coverage.rawValue) · \(duration(interval.focusDuration)) observed focus")
                }.font(.caption)
            }
            if let uncertainty = interval.context?.uncertainty, !uncertainty.isEmpty {
                Text(uncertainty.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if let eventID = interval.eventIDs.first {
                    Button("Observed metadata") {
                        Task { await model.openEvidence(.activity(ActivityEvidenceRef(storeID: interval.storeID, eventID: eventID))) }
                    }
                }
                Button("Recorded screens") { Task { await model.loadLinks(for: interval) } }
                    .disabled(interval.eventIDs.isEmpty || model.loadingLinks.contains(interval.id))
                if model.loadingLinks.contains(interval.id) { ProgressView().controlSize(.small) }
            }
            if let links = model.linksByInterval[interval.id] {
                ForEach(links) { link in
                    Button {
                        Task { await model.openEvidence(.screen(link.screen), link: link) }
                    } label: {
                        Label("Captured \(link.capturedAt.formatted(date: .omitted, time: .standard))", systemImage: "photo")
                    }
                }
                if model.intervalsWithMoreLinks.contains(interval.id) {
                    Button("More recorded screens") { Task { await model.loadLinks(for: interval) } }
                } else if links.isEmpty { Text("No image with a verified association is available for this interval.").font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var correctionHistory: some View {
        DisclosureGroup("Corrections (\(model.corrections.count))", isExpanded: $showCorrectionHistory) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(model.corrections, id: \.command.id) { receipt in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(receipt.command.label ?? receipt.command.action.rawValue.capitalized)
                            Text("\(receipt.command.targetEventIDs.count) selected · \(receipt.command.scope.rawValue) · \(receipt.status.rawValue)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if receipt.command.action != .revoke && receipt.command.confirmed && [.pending, .applied].contains(receipt.status) {
                            Button("Undo") { Task { await model.revoke(receipt) } }.disabled(model.isMutating)
                        }
                    }
                }
            }.padding(.top, 8)
        }.onChange(of: showCorrectionHistory) { visible in
            Task { await model.track(visible ? .correctionHistoryExpanded : .correctionHistoryCollapsed) }
        }
    }
    private func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        return "\(Int(seconds / 60))m \(Int(seconds) % 60)s"
    }
}

private struct ActivityCorrectionSheet: View {
    @ObservedObject var model: ActivityTimelineViewModel
    let action: ActivityCorrectionAction
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var scope: ActivityCorrectionScope = .selection
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm \(action.rawValue) correction").font(.title2.bold())
            Text("Selected observations: \(model.selectedEventIDs.count). Recorded metadata is preserved.")
            if [.rename, .assignProject].contains(action) { TextField("Label", text: $label).textFieldStyle(.roundedBorder) }
            Picker("Scope", selection: $scope) {
                Text("Selected observations only").tag(ActivityCorrectionScope.selection)
                if [.rename, .assignProject].contains(action) { Text("This known document").tag(ActivityCorrectionScope.document) }
            }
            Text("Confirmed corrections are previewed locally and remain pending until the activity service acknowledges them. You can undo a correction.")
                .font(.callout).foregroundStyle(.secondary)
            if action == .hide { Text("Hide changes timeline presentation. Excluding future capture and deleting stored activity are separate controls.").font(.callout) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss(); Task { await model.track(.correctionCancelled) } }
                Spacer()
                Button("Save draft") { submit(confirmed: false) }.disabled(labelRequired)
                Button("Confirm correction") { submit(confirmed: true) }.keyboardShortcut(.defaultAction).disabled(labelRequired)
            }.disabled(model.isMutating)
        }.padding(24).frame(width: 480)
    }
    private var labelRequired: Bool {
        [.rename, .assignProject].contains(action) && label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func submit(confirmed: Bool) {
        Task { await model.submitCorrection(action: action, label: label.isEmpty ? nil : label, scope: scope, confirmed: confirmed); dismiss() }
    }
}

private struct ActivityStageHealthView: View {
    @ObservedObject var model: ActivityTimelineViewModel
    @State private var expanded = false
    var body: some View {
        DisclosureGroup("Collection and evidence availability", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 5) {
                if let health = model.stageHealth {
                    Text(health.collecting ? (health.degraded ? "Activity collecting with gaps" : "Activity collecting") : "Activity collection stopped")
                    row("Image admitted", health.imageAdmittedAt)
                    row("Image retained", health.imageRetainedAt)
                    Text("Images skipped as duplicates: \(health.deduplicatedImages)")
                    Text("Text: \(count(health.pendingText)) queued · \(count(health.processingText)) processing · \(count(health.failedText)) failed")
                    row("Oldest queued text", health.oldestPendingTextAt)
                    row("Audio text processed", health.audioProcessedAt)
                    Text("Audio transcripts: \(health.audioTranscriptions)")
                } else { Text("Collection status unavailable") }
                row("Activity observed", model.storeHealth?.lastObservedAt)
                row("Activity persisted", model.storeHealth?.lastPersistedAt)
                Text("Recorded coverage gaps: \(count(model.storeHealth?.gapCount))")
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
        }.onChange(of: expanded) { visible in
            Task { await model.track(visible ? .healthExpanded : .healthCollapsed) }
        }
    }
    private func count(_ number: Int?) -> String { number.map(String.init) ?? "unknown" }
    private func row(_ title: String, _ date: Date?) -> some View {
        Text("\(title): \(date?.formatted(date: .abbreviated, time: .standard) ?? "unavailable")")
    }
}
