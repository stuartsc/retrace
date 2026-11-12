import Shared
import SwiftUI

struct TimelineMarkersPanel: View {
    @ObservedObject var model: TimelineMarkersViewModel
    let openMarker: @MainActor (TimelineMarker) async throws -> Void
    @State private var openTask: Task<Void, Never>?
    @State private var openError: String?
    @State private var query = ""
    @State private var editing: TimelineMarker?
    @State private var editedTitle = ""
    @State private var editedNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Marked moments", systemImage: "bookmark").font(.headline)
                Spacer()
                Button { Task { await model.newestPage() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Return to newest marked moments")
            }
            Text("Manual markers preserve the time you chose. They do not imply a transcript or screenshot exists at that exact instant.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search marker titles, notes and phrases", text: $query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: query) { model.setQuery($0) }
            if model.isLoading && model.markers.isEmpty { ProgressView().frame(maxWidth: .infinity) }
            else if model.markers.isEmpty {
                Text(model.query.isEmpty ? "No marked moments on this page. Use Mark now while recording or reviewing your work." :
                    "No matches on this page. Continue through older or newer markers.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 18)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.markers) { marker in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "bookmark.fill").foregroundStyle(Color.retraceAccent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(marker.title).font(.callout.weight(.medium))
                                    Text(marker.anchoredAt.formatted(date: .abbreviated, time: .standard))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let observation = marker.spokenObservation {
                                        Text(observation.status == .provisional ? "Provisional phrase · approximate time" :
                                            observation.status == .withdrawn ? "Recognition withdrawn" : "Confirmed phrase · approximate time")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let note = marker.note { Text(note).font(.caption).textSelection(.enabled) }
                                }
                                Spacer(minLength: 0)
                                Button("Open") {
                                    openTask?.cancel()
                                    openTask = Task {
                                        do { try await openMarker(marker); openError = nil }
                                        catch { if !Task.isCancelled { openError = "This marker changed or is unavailable. Refresh the list." } }
                                    }
                                }.controlSize(.small)
                                Button {
                                    editedTitle = marker.title; editedNote = marker.note ?? ""; editing = marker
                                } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.plain).disabled(model.isSaving).help("Edit marker title and note")
                                Button { model.delete(marker) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).disabled(model.isSaving)
                                    .help("Remove marker; Undo remains available")
                            }.padding(10).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
            }
            HStack {
                Text(model.query.isEmpty ? "\(model.loadedCount) markers on this page" :
                    "\(model.markers.count) matches in \(model.loadedCount) markers")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Newer") { Task { await model.newerPage() } }.disabled(!model.canGoNewer || model.isLoading)
                Button("Older") { Task { await model.olderPage() } }.disabled(!model.hasMore || model.isLoading)
            }
            if let openError { Text(openError).font(.caption).foregroundStyle(Color.retraceWarning) }
            if let message = model.message {
                HStack {
                    Text(message).font(.caption)
                    Spacer()
                    if model.undoMarker != nil { Button("Undo") { model.undo() }.disabled(model.isSaving) }
                }
            }
        }
        .padding(18).frame(width: 480, height: 500)
        .task { await model.refresh() }
        .onDisappear { model.hide(); openTask?.cancel() }
        .sheet(item: $editing) { marker in
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit marker").font(.headline)
                TextField("Title", text: $editedTitle).textFieldStyle(.roundedBorder)
                Text("Your note").font(.caption)
                TextEditor(text: $editedNote).frame(height: 100).border(Color.secondary.opacity(0.3))
                Text("The original phrase, recording time and verbatim speech stay attached to this marker.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = model.message { Text(message).font(.caption) }
                HStack {
                    Button("Cancel") { editing = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") {
                        model.edit(marker, title: editedTitle, note: editedNote.isEmpty ? nil : editedNote)
                        Task {
                            await model.finishPendingWrite()
                            if model.message == "Marker saved" { editing = nil }
                        }
                    }.keyboardShortcut(.defaultAction).disabled(model.isSaving || editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20).frame(width: 420)
        }
    }
}
