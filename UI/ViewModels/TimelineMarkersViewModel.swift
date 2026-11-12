import App
import Combine
import Foundation
import Shared

/// Presentation of the App-owned sidecar. Recording data is never written here.
@MainActor
final class TimelineMarkersViewModel: ObservableObject {
    @Published private(set) var markers: [TimelineMarker] = []
    @Published private(set) var hasMore = false
    @Published private(set) var canGoNewer = false
    @Published private(set) var loadedCount = 0
    @Published private(set) var query = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var message: String?
    @Published private(set) var undoMarker: TimelineMarker?
    private let service: @Sendable () async throws -> TimelineMarkerService
    private var readTask: Task<Void, Never>?
    private var readID: UUID?
    private var readingGeneration: UInt64?
    private var readGeneration: UInt64 = 0
    private var writeTask: Task<Void, Never>?
    private var pendingCommand: ManualTimelineMarkerCommand?
    private var pendingEdit: TimelineMarkerEditCommand?
    private var pageMarkers: [TimelineMarker] = []
    private var pageCursor: TimelineMarkerCursor?
    private var nextCursor: TimelineMarkerCursor?
    private var previousCursors: [TimelineMarkerCursor?] = []

    init(service: @escaping @Sendable () async throws -> TimelineMarkerService) { self.service = service }

    func refresh() async {
        guard !Task.isCancelled else { return }
        let generation = readGeneration
        while let readTask {
            let joinedGeneration = readingGeneration
            await readTask.value
            guard !Task.isCancelled, generation == readGeneration else { return }
            if joinedGeneration == generation { return }
        }
        let id = UUID()
        let cursor = pageCursor
        isLoading = true
        let task = Task { [weak self, service] in
            defer {
                if self?.readID == id {
                    self?.readTask = nil; self?.readID = nil; self?.readingGeneration = nil; self?.isLoading = false
                }
            }
            do {
                let page = try await service().listMarkers(TimelineMarkerQuery(before: cursor, limit: 50))
                guard !Task.isCancelled, let self, self.readGeneration == generation else { return }
                self.pageMarkers = page.markers
                self.loadedCount = page.markers.count
                self.applyQuery()
                self.nextCursor = page.nextCursor
                self.hasMore = page.nextCursor != nil
            } catch {
                guard !Task.isCancelled, let self, self.readGeneration == generation else { return }
                self.message = "Markers could not be read."
            }
        }
        readTask = task; readID = id; readingGeneration = generation
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func setQuery(_ value: String) {
        query = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        applyQuery()
    }

    private func applyQuery() {
        markers = pageMarkers.filter { marker in
            query.isEmpty || [marker.title, marker.note ?? "", marker.spokenObservation?.matchedPhrase ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    func olderPage() async {
        guard !isLoading, let nextCursor else { return }
        previousCursors.append(pageCursor)
        if previousCursors.count > 100 { previousCursors.removeFirst() }
        pageCursor = nextCursor
        canGoNewer = true
        readGeneration &+= 1
        await refresh()
    }

    func newerPage() async {
        guard !isLoading, !previousCursors.isEmpty else { return }
        pageCursor = previousCursors.removeLast()
        canGoNewer = !previousCursors.isEmpty
        readGeneration &+= 1
        await refresh()
    }

    func newestPage() async {
        pageCursor = nil; previousCursors.removeAll(); canGoNewer = false
        readGeneration &+= 1; readTask?.cancel()
        await refresh()
    }

    func edit(_ marker: TimelineMarker, title: String, note: String?) {
        guard writeTask == nil else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { message = "Enter a marker title."; return }
        let command: TimelineMarkerEditCommand
        if let pendingEdit, pendingEdit.id == marker.id, pendingEdit.expectedRevision == marker.revision,
           pendingEdit.title == title, pendingEdit.note == note { command = pendingEdit }
        else { command = .init(id: marker.id, expectedRevision: marker.revision, title: title, note: note) }
        pendingEdit = command; isSaving = true; message = nil
        writeTask = Task { [weak self, service] in
            defer { self?.writeTask = nil; self?.isSaving = false }
            do {
                let saved = try await service().updateMarker(command)
                guard let self else { return }
                self.pendingEdit = nil
                if self.undoMarker?.id == saved.id { self.undoMarker = saved }
                self.message = "Marker saved"
                self.readGeneration &+= 1; self.readTask?.cancel()
                await self.refresh()
            } catch {
                self?.message = "This marker could not be saved. Refresh to check its latest revision."
            }
        }
    }

    func markNow(at date: Date = Date()) {
        guard writeTask == nil else { return }
        let command = pendingCommand ?? ManualTimelineMarkerCommand(anchoredAt: date)
        pendingCommand = command
        isSaving = true
        message = nil
        writeTask = Task { [weak self, service] in
            defer { self?.writeTask = nil; self?.isSaving = false }
            do {
                let saved = try await service().createManualMarker(command)
                guard let self else { return }
                self.pendingCommand = nil
                self.undoMarker = saved
                self.message = "Marked at \(saved.anchoredAt.formatted(date: .omitted, time: .standard))"
                await self.newestPage()
            } catch { self?.message = "The moment could not be marked. Try again." }
        }
    }

    func delete(_ marker: TimelineMarker) { setDeleted(marker, deleted: true) }
    func undo() {
        guard let marker = undoMarker else { return }
        setDeleted(marker, deleted: marker.deletedAt == nil)
    }

    private func setDeleted(_ marker: TimelineMarker, deleted: Bool) {
        guard writeTask == nil else { return }
        isSaving = true
        writeTask = Task { [weak self, service] in
            defer { self?.writeTask = nil; self?.isSaving = false }
            do {
                let saved = try await service().setMarkerDeleted(id: marker.id, expectedRevision: marker.revision, deleted: deleted)
                guard let self else { return }
                self.undoMarker = deleted ? saved : nil
                self.message = deleted ? "Marker removed" : "Marker restored"
                self.readGeneration &+= 1
                self.readTask?.cancel()
                await self.refresh()
            } catch {
                self?.undoMarker = nil
                self?.message = "This marker changed. Refresh the list before trying again."
            }
        }
    }

    func hide() {
        readGeneration &+= 1
        readTask?.cancel()
        markers = []
        pageMarkers = []; loadedCount = 0; nextCursor = nil
        pageCursor = nil; previousCursors.removeAll(); canGoNewer = false
        hasMore = false
    }

    func finishPendingWrite() async { await writeTask?.value }
}

@MainActor
final class VoiceMarkerRulesViewModel: ObservableObject {
    @Published private(set) var rules: [KeywordRule] = []
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var editorSaveRevision: UInt64 = 0
    private let service: @Sendable () async throws -> TimelineMarkerService
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(service: @escaping @Sendable () async throws -> TimelineMarkerService) { self.service = service }

    func refresh() async {
        guard !isBusy, !Task.isCancelled else { return }
        let generation = generation
        do {
            let rows = try await service().listKeywordRules(afterID: nil, limit: 100)
            guard !Task.isCancelled, generation == self.generation else { return }
            rules = rows
        } catch { if !Task.isCancelled, generation == self.generation { message = "Voice rules could not be read." } }
    }

    func save(phrase: String, name: String, meaning: String, aliases: String, editing: KeywordRule? = nil) {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, !name.isEmpty else { message = "Enter a phrase and a marker name."; return }
        let rule = KeywordRule(id: editing?.id ?? UUID(), revision: editing?.revision ?? UUID(), phrase: phrase,
            aliases: aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            name: name, meaning: meaning.trimmingCharacters(in: .whitespacesAndNewlines), enabled: editing?.enabled ?? false)
        save(rule, expectedRevision: editing?.revision, fromEditor: true)
    }

    func setEnabled(_ rule: KeywordRule, enabled: Bool) {
        let updated = KeywordRule(id: rule.id, revision: rule.revision, phrase: rule.phrase, aliases: rule.aliases,
            name: rule.name, meaning: rule.meaning, enabled: enabled, action: rule.action)
        save(updated, expectedRevision: rule.revision)
    }

    private func save(_ rule: KeywordRule, expectedRevision: UUID?, fromEditor: Bool = false) {
        guard task == nil else { return }
        generation &+= 1
        isBusy = true; message = nil
        task = Task { [weak self, service] in
            defer { self?.task = nil; self?.isBusy = false }
            do {
                let owner = try await service()
                _ = try await owner.saveKeywordRule(rule, expectedRevision: expectedRevision)
                let rows = try await owner.listKeywordRules(afterID: nil, limit: 100)
                self?.rules = rows
                self?.message = "Rule saved locally."
                if fromEditor { self?.editorSaveRevision &+= 1 }
            } catch { self?.message = "The rule could not be saved. Refresh and try again." }
        }
    }

    func finishPendingWrite() async { await task?.value }
}
