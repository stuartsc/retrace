import App
import Combine
import Foundation
import Shared

@MainActor
final class CompanionWorkspaceModel: ObservableObject {
    @Published private(set) var title = "Companion unavailable"
    @Published private(set) var presentations: [CompanionSpeakerPresentation] = []
    @Published private(set) var message: String?
    @Published private(set) var isSaving = false
    @Published private(set) var savedRevision = UUID()
    @Published private(set) var selectedPresentation: CompanionSpeakerPresentation?
    @Published private(set) var playingTurn: CompanionTurnReference?
    @Published private(set) var loadingTurn: CompanionTurnReference?
    @Published private(set) var playbackMessage: String?
    private var selectedJobID: String?
    private let service: @Sendable () async throws -> CompanionController
    private let playbackService: (@Sendable () async throws -> CompanionTurnPlayback)?
    private var playbackOwner: CompanionTurnPlayback?
    private var playbackTask: Task<Void, Never>?
    private var playbackRevision = UUID()
    private var generation = UUID()
    private var write: Task<Void, Never>?
    private var interval: DateInterval?

    init(service: @escaping @Sendable () async throws -> CompanionController,
         playbackService: (@Sendable () async throws -> CompanionTurnPlayback)? = nil) {
        self.service = service; self.playbackService = playbackService
    }

    /// Live owns the chronological evidence page; this model owns explicit name
    /// editing and playback. It need not fetch a duplicate page on every poll.
    func adopt(_ values: [CompanionSpeakerPresentation], interval: DateInterval?) {
        presentations = values; self.interval = interval
        if let selectedJobID, let current = values.first(where: { $0.jobID == selectedJobID }) { selectedPresentation = current }
    }

    func refreshStatus() async {
        do {
            let status = try await service().status()
            switch status.state {
            case .unconfigured: title = "Companion not configured"
            case .offline: title = "Companion offline · \(status.pendingCount) pending"
            case .ready: title = status.pendingCount == 0 ? "Companion connected" : "Companion · \(status.pendingCount) pending"
            case .suspended: title = "Companion suspended"
            case .closed: title = "Companion closed"
            }
        } catch { title = "Companion unavailable" }
    }

    func playTurn(_ reference: CompanionTurnReference) {
        let prior = playbackTask, token = UUID()
        prior?.cancel(); playbackRevision = token
        loadingTurn = reference; playingTurn = nil; playbackMessage = nil
        playbackTask = Task { [weak self, playbackService] in
            await prior?.value
            do {
                try Task.checkCancellation()
                guard let playbackService else { throw CompanionError.unavailable }
                let owner = try await playbackService()
                guard let self, self.playbackRevision == token, !Task.isCancelled else { return }
                self.playbackOwner = owner
                try await owner.play(reference)
                guard self.playbackRevision == token, !Task.isCancelled else { return }
                self.loadingTurn = nil; self.playingTurn = reference; self.playbackTask = nil
            } catch {
                guard let self, self.playbackRevision == token else { return }
                self.loadingTurn = nil; self.playingTurn = nil; self.playbackTask = nil
                if !Task.isCancelled { self.playbackMessage = "This turn's original audio is unavailable or its saved evidence changed." }
            }
        }
    }

    func refreshPlayback() async {
        guard let owner = playbackOwner else { return }
        let token = playbackRevision, state = await owner.snapshot()
        guard playbackRevision == token else { return }
        playingTurn = state.isPlaying ? state.reference : nil
        if state.errorCode != nil { playbackMessage = "Turn playback is unavailable." }
    }

    func stopPlayback() {
        playbackRevision = UUID()
        let prior = playbackTask, owner = playbackOwner
        prior?.cancel(); playingTurn = nil; loadingTurn = nil; playbackMessage = nil
        playbackTask = Task { await prior?.value; await owner?.stop() }
    }

    func refresh(interval: DateInterval?) async {
        let token = generation
        self.interval = interval
        do {
            let owner = try await service()
            let status = await owner.status()
            try Task.checkCancellation()
            guard generation == token else { return }
            switch status.state {
            case .unconfigured: title = "Companion not configured"
            case .offline: title = "Companion offline · \(status.pendingCount) pending"
            case .ready: title = status.pendingCount == 0 ? "Companion connected" : "Companion · \(status.pendingCount) pending"
            case .suspended: title = "Companion suspended"
            case .closed: title = "Companion closed"
            }
            // Delivery configuration does not determine whether locally retained
            // speaker evidence is readable. The App-owned catalog applies current
            // source/policy checks without activating a companion connection.
            guard let interval, status.state != .closed else { presentations = []; selectedPresentation = nil; return }
            let page = try await owner.speakerPresentations(from: interval.start, to: interval.end, limit: 32)
            try Task.checkCancellation()
            guard generation == token else { return }
            presentations = page.items
            if let selectedJobID {
                let selected = try await owner.speakerPresentation(jobID: selectedJobID)
                try Task.checkCancellation()
                guard generation == token, self.selectedJobID == selectedJobID else { return }
                selectedPresentation = selected
            }
            message = page.nextCursor != nil ? "Showing the first 32 enriched recordings. Use interval search to continue through available labels." : nil
        } catch {
            if generation == token, !Task.isCancelled { presentations = []; selectedPresentation = nil; message = "Available speaker labels could not be refreshed." }
        }
    }

    func select(jobID: String) async throws {
        let token = generation
        let current = try await service().speakerPresentation(jobID: jobID)
        try Task.checkCancellation()
        guard generation == token, let current else { throw CompanionError.staleEvidence }
        selectedJobID = jobID; selectedPresentation = current
    }

    func correct(_ presentation: CompanionSpeakerPresentation, speakerID: String, name: String?) {
        guard write == nil else { return }
        let token = generation
        let current = presentation.corrections.first { $0.speakerID == speakerID }
        let command = CompanionSpeakerCorrectionCommand(jobID: presentation.jobID, speakerID: speakerID,
            displayName: name?.trimmingCharacters(in: .whitespacesAndNewlines), expectedRevision: current?.revision)
        isSaving = true; message = nil
        write = Task { [weak self, service] in
            defer { self?.write = nil; self?.isSaving = false }
            do {
                let owner = try await service()
                _ = try await owner.correctSpeaker(command)
                guard let self, self.generation == token else { return }
                await self.refresh(interval: self.interval)
                self.savedRevision = UUID()
                self.message = name == nil ? "Manual speaker label removed." : "Speaker label saved for this recording."
            } catch {
                if let self, self.generation == token { self.message = "The speaker evidence or label changed. Refresh before saving again." }
            }
        }
    }

    func hide() { generation = UUID(); presentations = []; selectedPresentation = nil; selectedJobID = nil; stopPlayback() }
    func finishPendingWrite() async { await write?.value }
}
