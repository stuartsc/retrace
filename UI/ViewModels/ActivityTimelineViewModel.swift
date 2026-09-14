import Foundation
import Combine
import CoreGraphics
import App
import Shared

/// Async boundaries are explicit so presentation can be exercised with real stores
/// and delayed protocol responses without opening windows or reading live capture.
struct ActivityTimelineClient: Sendable {
    var activity: @Sendable (ActivityQuery) async throws -> ActivityPage
    var corrections: @Sendable () async throws -> [ActivityCorrectionReceipt]
    var activityHealth: @Sendable () async throws -> ActivityStoreHealth
    var stageHealth: @Sendable () async -> ProgressiveRecallStageHealth?
    var correct: @Sendable (ActivityCorrection) async throws -> ActivityCorrectionReceipt
    var delete: @Sendable ([UUID]) async throws -> Void
    var links: @Sendable (UUID, Int64, Int) async throws -> [ActivityScreenLink]
    var reference: @Sendable (SearchResult) async throws -> ScreenEvidenceRef
    var resolve: @Sendable (EvidenceRef) async -> EvidenceResolution
    var currentRevision: @Sendable (ScreenEvidenceRef) async throws -> Int64?
    var track: @Sendable (ProgressiveRecallAction, String, Int) async -> Void
    var retainedScreen: @Sendable (ScreenEvidenceRef) async -> ScreenEvidenceSnapshot? = { _ in nil }
    var contextEnabled: @Sendable () async -> Bool = { false }
    var setContextEnabled: @Sendable (Bool) async -> Void = { _ in }
    var project: @Sendable ([PersistedActivityEvent], [ActivityCorrectionReceipt], Bool) async -> [ActivityEpisode] = { rows, commands, grouping in
        await Task.detached(priority: .userInitiated) {
            ActivityTimelineProjection.build(events: rows, corrections: commands, grouped: grouping)
        }.value
    }

    static func live(service: ProgressiveRecallService, coordinator: AppCoordinator) -> Self {
        Self(activity: { try await service.activity($0) }, corrections: { try await service.corrections() },
            activityHealth: { try await service.activityHealth() }, stageHealth: { await coordinator.progressiveRecallHealth() },
            correct: { try await service.correct($0) }, delete: { try await service.deleteActivity(eventIDs: $0) },
            links: { try await service.screenLinks(eventID: $0, afterSequence: $1, limit: $2) },
            reference: { try await service.reference(searchResult: $0) },
            resolve: { await service.resolve($0, for: .localUser) },
            currentRevision: { try await service.currentRevision($0) },
            track: { await service.track($0, outcome: $1, count: $2) },
            retainedScreen: { await service.retainedScreen($0, for: .localUser) },
            contextEnabled: { await coordinator.isActivityContextEnabled() },
            setContextEnabled: { await coordinator.setActivityContextEnabled($0) })
    }
}

@MainActor
final class ActivityTimelineViewModel: ObservableObject {
    @Published var queryText = ""
    @Published var appBundleID = ""
    @Published var from: Date?
    @Published var to: Date?
    @Published var hideGlances = false
    @Published var revealHidden = false
    @Published var selectedEventIDs: Set<UUID> = []
    @Published private(set) var events: [PersistedActivityEvent] = []
    @Published private(set) var episodes: [ActivityEpisode] = []
    @Published private(set) var corrections: [ActivityCorrectionReceipt] = []
    @Published private(set) var grouped = true
    @Published private(set) var hasMore = false
    @Published private(set) var isLoading = false
    @Published private(set) var isMutating = false
    @Published private(set) var message: String?
    @Published private(set) var stageHealth: ProgressiveRecallStageHealth?
    @Published private(set) var storeHealth: ActivityStoreHealth?
    @Published private(set) var linksByInterval: [UUID: [ActivityScreenLink]] = [:]
    @Published private(set) var loadingLinks: Set<UUID> = []
    @Published private(set) var intervalsWithMoreLinks: Set<UUID> = []
    @Published private(set) var evidenceReference: EvidenceRef?
    @Published private(set) var resolution: EvidenceResolution?
    @Published private(set) var resolvingEvidence = false
    @Published private(set) var associationUnavailable = false
    @Published private(set) var newerRevision: Int64?
    @Published private(set) var retainedSnapshot: ScreenEvidenceSnapshot?
    @Published private(set) var contextEnabled: Bool?
    @Published private(set) var changingContextCollection = false

    private let client: ActivityTimelineClient
    private let pageSize: Int
    private var nextSequence: Int64?
    private var generation = 0
    private var evidenceGeneration = 0
    private var projectionGeneration = 0
    private var correctionGeneration = 0
    private var contextGeneration = 0
    private var loadTask: Task<Void, Never>?
    private var evidenceTask: Task<Void, Never>?
    private var loadKey: LoadKey?
    private var linkCursors: [UUID: (eventIndex: Int, after: Int64)] = [:]
    private struct LoadKey: Equatable { let query: String; let app: String; let from: Date?; let to: Date? }

    init(client: ActivityTimelineClient, pageSize: Int = 100) {
        self.client = client; self.pageSize = min(500, max(1, pageSize))
    }

    var visibleEpisodes: [ActivityEpisode] {
        episodes.filter { (revealHidden || !$0.hidden) && !visibleIntervals(in: $0).isEmpty }
    }
    var hiddenGlanceCount: Int {
        episodes.filter { revealHidden || !$0.hidden }.flatMap(\.intervals).filter(Self.isGlance).count
    }
    var hiddenEpisodeCount: Int { episodes.filter(\.hidden).count }
    func visibleIntervals(in episode: ActivityEpisode) -> [ActivityInterval] {
        hideGlances ? episode.intervals.filter { !Self.isGlance($0) } : episode.intervals
    }
    private static func isGlance(_ interval: ActivityInterval) -> Bool {
        interval.focusDuration > 0 && interval.focusDuration < 10 && interval.context != nil
    }

    func refresh() async {
        let key = LoadKey(query: queryText, app: appBundleID, from: from, to: to)
        if let loadTask, key == loadKey { await loadTask.value; return }
        generation += 1; projectionGeneration += 1; let token = generation
        loadTask?.cancel(); loadKey = key
        events = []; episodes = []; nextSequence = nil; hasMore = false
        selectedEventIDs = []; linksByInterval = [:]; linkCursors = [:]; intervalsWithMoreLinks = []; loadingLinks = []
        loadTask = Task { [weak self] in await self?.loadPage(key: key, after: 0, token: token) }
        await loadTask?.value
    }

    func loadMore() async {
        if let loadTask { await loadTask.value; return }
        guard let nextSequence, let key = loadKey else { return }
        let token = generation
        loadTask = Task { [weak self] in await self?.loadPage(key: key, after: nextSequence, token: token) }
        await loadTask?.value
    }

    private func loadPage(key: LoadKey, after: Int64, token: Int) async {
        isLoading = true; message = nil
        let correctionToken = correctionGeneration
        let contextToken = contextGeneration
        let began = CFAbsoluteTimeGetCurrent()
        defer { if generation == token { isLoading = false; loadTask = nil } }
        do {
            async let page = client.activity(ActivityQuery(text: key.query, from: key.from, to: key.to,
                appBundleIDs: key.app.isEmpty ? nil : [key.app], afterSequence: after, limit: pageSize))
            async let receipts = client.corrections()
            async let health = client.activityHealth()
            async let stages = client.stageHealth()
            async let enabled = client.contextEnabled()
            let result = try await (page, receipts, health, stages, enabled)
            guard generation == token, !Task.isCancelled else { return }
            let known = Set(events.map(\.id))
            events += result.0.events.filter { !known.contains($0.id) }
            nextSequence = result.0.nextSequence; hasMore = nextSequence != nil
            if correctionToken == correctionGeneration { corrections = result.1; storeHealth = result.2 }
            if contextToken == contextGeneration {
                stageHealth = result.3; contextEnabled = result.4
            }
            await reproject()
            guard generation == token else { return }
            await track(.searched, outcome: events.isEmpty && !hasMore ? "no_results" : "success", count: result.0.events.count)
        } catch {
            if generation == token, !Task.isCancelled { message = "Activity could not be loaded. Try Refresh."; await track(.searched, outcome: "failed") }
        }
        Log.recordLatency("progressive_recall.activity", valueMs: (CFAbsoluteTimeGetCurrent() - began) * 1_000, category: .ui)
    }

    func setGrouped(_ value: Bool) async {
        grouped = value; await reproject(); await track(value ? .grouped : .ungrouped)
    }

    func setContextCollection(_ enabled: Bool) async {
        guard !changingContextCollection else { return }
        changingContextCollection = true
        contextGeneration += 1
        defer { changingContextCollection = false }
        let token = contextGeneration
        await client.setContextEnabled(enabled)
        let persisted = await client.contextEnabled()
        let stages = await client.stageHealth()
        guard token == contextGeneration else { return }
        // Also fence pages that began while the setting acknowledgement was pending.
        contextGeneration += 1
        contextEnabled = persisted; stageHealth = stages
    }

    private func reproject() async {
        projectionGeneration += 1; let token = projectionGeneration
        let loadGeneration = generation
        let rows = events, commands = corrections, grouping = grouped
        let projected = await client.project(rows, commands, grouping)
        guard token == projectionGeneration, loadGeneration == generation, !Task.isCancelled else { return }
        episodes = projected
    }

    func loadLinks(for interval: ActivityInterval) async {
        guard !loadingLinks.contains(interval.id) else { return }
        let token = generation
        loadingLinks.insert(interval.id)
        defer { if token == generation { loadingLinks.remove(interval.id) } }
        var cursor = linkCursors[interval.id] ?? (eventIndex: 0, after: 0)
        var found: [ActivityScreenLink] = []
        do {
            while cursor.eventIndex < interval.eventIDs.count && found.count < 20 {
                let limit = 20 - found.count
                let rows = try await client.links(interval.eventIDs[cursor.eventIndex], cursor.after, limit)
                guard generation == token, !Task.isCancelled else { return }
                found += rows
                if rows.count == limit, let last = rows.last { cursor.after = last.commitSequence }
                else { cursor.eventIndex += 1; cursor.after = 0 }
            }
            let known = Set((linksByInterval[interval.id] ?? []).map(\.id))
            linksByInterval[interval.id, default: []] += found.filter { !known.contains($0.id) }
            linkCursors[interval.id] = cursor
            if cursor.eventIndex < interval.eventIDs.count { intervalsWithMoreLinks.insert(interval.id) }
            else { intervalsWithMoreLinks.remove(interval.id) }
            await track(.screenLinksRequested, outcome: found.isEmpty ? "no_results" : "success", count: found.count)
        } catch {
            if generation == token { message = "Recorded screen links could not be loaded." }
            await track(.screenLinksRequested, outcome: "failed")
        }
    }

    func submitCorrection(action: ActivityCorrectionAction, label: String? = nil,
                          scope: ActivityCorrectionScope = .selection, confirmed: Bool) async {
        guard !isMutating, !selectedEventIDs.isEmpty, selectedEventIDs.count <= 500 else { return }
        // Freeze the reviewed scope before any suspension. A later selection is a
        // different user action and must not silently change this command's targets.
        let selected = events.filter { selectedEventIDs.contains($0.id) }
        let metric: ProgressiveRecallAction = confirmed ? .correctionConfirmed : .correctionDraftSaved
        isMutating = true; defer { isMutating = false }
        do {
            let health = try await client.activityHealth()
            let keys = Set(selected.compactMap { $0.event.context?.stableDocumentKey })
            if scope == .document && (keys.count != 1 || selected.contains(where: { $0.event.context?.stableDocumentKey == nil })) {
                message = "A document rule needs the same known document identity for every selected observation."
                await track(metric, outcome: "invalid_scope"); return
            }
            let command = ActivityCorrection(targetEventIDs: selected.map(\.id), expectedRevision: health.correctionRevision,
                action: action, scope: scope, label: label, documentKey: scope == .document ? keys.first : nil, confirmed: confirmed)
            let receipt = try await client.correct(command)
            if await presentCommittedCorrection(receipt) {
                message = receipt.status == .pending ? "Confirmed locally. Application is pending; Undo remains available." : "Correction: \(receipt.status.rawValue)."
            } else {
                message = "Correction saved locally (\(receipt.status.rawValue)); the latest status refresh is unavailable."
            }
            await track(metric, outcome: receipt.status.rawValue)
        } catch { message = "Correction could not be saved. Refresh and try again."; await track(metric, outcome: "failed") }
    }

    func revoke(_ receipt: ActivityCorrectionReceipt) async {
        guard !isMutating else { return }
        isMutating = true; defer { isMutating = false }
        do {
            let health = try await client.activityHealth()
            let command = ActivityCorrection(targetEventIDs: receipt.command.targetEventIDs,
                expectedRevision: health.correctionRevision, action: .revoke, confirmed: true, revokesCommandID: receipt.command.id)
            let result = try await client.correct(command)
            if await presentCommittedCorrection(result) {
                message = "Undo confirmed locally; application is \(result.status.rawValue)."
            } else {
                message = "Undo saved locally (\(result.status.rawValue)); the latest status refresh is unavailable."
            }
            await track(.correctionRevoked, outcome: result.status.rawValue)
        } catch { message = "Undo could not be saved. Refresh and try again."; await track(.correctionRevoked, outcome: "failed") }
    }

    private func refreshCorrections() async throws {
        let latest = try await client.corrections()
        let health = try await client.activityHealth()
        corrections = latest; storeHealth = health; await reproject()
    }

    /// A failed status read cannot undo or misreport a successful canonical write.
    private func presentCommittedCorrection(_ receipt: ActivityCorrectionReceipt) async -> Bool {
        correctionGeneration += 1
        corrections.removeAll { $0.command.id == receipt.command.id }
        corrections.append(receipt)
        corrections.sort { $0.revision < $1.revision }
        do { try await refreshCorrections(); return true }
        catch { await reproject(); return false }
    }

    func deleteSelected() async {
        guard !isMutating, !selectedEventIDs.isEmpty, selectedEventIDs.count <= 500 else { return }
        isMutating = true; defer { isMutating = false }
        do {
            let count = selectedEventIDs.count
            try await client.delete(Array(selectedEventIDs)); closeEvidence(); await refresh()
            await track(.activityDeleted, count: count)
        } catch { message = "The selected activity could not be deleted."; await track(.activityDeleted, outcome: "failed") }
    }

    func openEvidence(_ ref: EvidenceRef, link: ActivityScreenLink? = nil) async {
        await requestEvidence(link: link) { ref }
    }

    func openSearchResult(_ result: SearchResult) async {
        let source = client
        await requestEvidence(link: nil) {
            if let ref = result.evidenceRef { return .screen(ref) }
            return .screen(try await source.reference(result))
        }
    }

    private func requestEvidence(link: ActivityScreenLink?, reference: @escaping @Sendable () async throws -> EvidenceRef) async {
        evidenceGeneration += 1; let token = evidenceGeneration
        evidenceTask?.cancel(); resolution = nil; evidenceReference = nil; newerRevision = nil; retainedSnapshot = nil
        associationUnavailable = false; resolvingEvidence = true
        evidenceTask = Task { [weak self] in
            guard let self else { return }
            let began = CFAbsoluteTimeGetCurrent()
            defer { if token == evidenceGeneration { resolvingEvidence = false; evidenceTask = nil } }
            await track(.evidenceRequested)
            do {
                if let link, try await !validLink(link) {
                    if token == evidenceGeneration { associationUnavailable = true }
                    await track(.evidenceUnavailable, outcome: "association_unavailable"); return
                }
                let ref = try await reference()
                guard token == evidenceGeneration, !Task.isCancelled else { return }
                evidenceReference = ref
                let result = await client.resolve(ref)
                guard token == evidenceGeneration, !Task.isCancelled else { return }
                if let link, try await !validLink(link) {
                    if token == evidenceGeneration { associationUnavailable = true; evidenceReference = nil }
                    await track(.evidenceUnavailable, outcome: "association_unavailable"); return
                }
                guard token == evidenceGeneration, !Task.isCancelled else { return }
                resolution = result
                if case .unavailable = result, case .screen(let screen) = ref {
                    let retained = await client.retainedScreen(screen)
                    guard token == evidenceGeneration, !Task.isCancelled else { return }
                    if let link, try await !validLink(link) {
                        if token == evidenceGeneration {
                            associationUnavailable = true; evidenceReference = nil; resolution = nil; retainedSnapshot = nil
                        }
                        await track(.evidenceUnavailable, outcome: "association_unavailable")
                        return
                    }
                    if token == evidenceGeneration, !Task.isCancelled { retainedSnapshot = retained }
                }
                if case .screen(let screen, _) = result {
                    let preferred = try? await client.currentRevision(screen.ref)
                    if token == evidenceGeneration, let preferred, preferred > screen.ref.extractionRevision { newerRevision = preferred }
                }
                if case .unavailable = result { await track(.evidenceUnavailable) }
                else { await track(.evidenceResolved) }
            } catch {
                if token == evidenceGeneration, !Task.isCancelled { resolution = .unavailable((error as? EvidenceUnavailableReason) ?? .integrityFailure); await track(.evidenceUnavailable) }
            }
            Log.recordLatency("progressive_recall.evidence", valueMs: (CFAbsoluteTimeGetCurrent() - began) * 1_000, category: .ui)
        }
        await evidenceTask?.value
    }

    private func validLink(_ link: ActivityScreenLink) async throws -> Bool {
        let current = try await client.links(link.eventID, max(0, link.commitSequence - 1), 1)
        return current.first?.id == link.id && current.first?.screen == link.screen
    }

    func closeEvidence() {
        evidenceGeneration += 1; evidenceTask?.cancel(); evidenceTask = nil
        evidenceReference = nil; resolution = nil; resolvingEvidence = false; associationUnavailable = false; newerRevision = nil; retainedSnapshot = nil
    }
    func cancel() {
        generation += 1; projectionGeneration += 1; loadTask?.cancel(); loadTask = nil; isLoading = false; closeEvidence()
    }
    func track(_ action: ProgressiveRecallAction, outcome: String = "success", count: Int = 1) async {
        await client.track(action, outcome, count)
    }
}
