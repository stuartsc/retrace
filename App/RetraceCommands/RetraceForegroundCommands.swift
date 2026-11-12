import Foundation
import Shared

/// Native identities are re-resolved for every explicit foreground effect. Text or
/// paths supplied by a client never become a playback request.
enum RetraceForegroundCommands {
    struct Services: Sendable {
        let reader: @Sendable () async throws -> LiveContextSearchService
        let recall: @Sendable () async throws -> ProgressiveRecallService
        let companion: @Sendable () async throws -> CompanionController
        let markers: TimelineMarkerService
        let router: RetraceForegroundRouter
    }
    static func handlers(coordinator: AppCoordinator, markers: TimelineMarkerService) -> [RetraceCommandHandler] {
        handlers(.init(reader: { try await coordinator.liveContextSearch() },
            recall: { try await coordinator.progressiveRecall() },
            companion: { try await coordinator.companion() }, markers: markers, router: .shared))
    }
    static func handlers(_ services: Services) -> [RetraceCommandHandler] {
        [.init(operation: .navigate) { try await navigate($0, services: services) },
         .init(operation: .playback) { try await playback($0, services: services) }]
    }

    private struct Navigation: Decodable {
        enum Kind: String, Decodable { case screen, marker, transcript, speakerTurn }
        let kind: Kind; let reference: RetraceJSON?; let id: UUID?; let expectedRevision: UUID?
    }
    private struct Playback: Decodable {
        enum Action: String, Decodable { case play, playTurn, stop }
        let action: Action; let reference: CompanionTurnReference?; let id: UUID?; let expectedRevision: UUID?
    }
    private static func navigate(_ context: RetraceCommandContext, services: Services) async throws -> RetraceJSON {
        let input: Navigation = try context.decode(keys: ["kind", "reference", "id", "expectedRevision"])
        let target: RetraceNavigationTarget
        switch input.kind {
        case .marker:
            guard input.reference == nil, let id = input.id, let revision = input.expectedRevision else { throw RetraceCommandError.invalidArguments }
            target = .marker(id: id, expectedRevision: revision)
        case .screen, .transcript, .speakerTurn:
            guard let reference = input.reference, input.id == nil, input.expectedRevision == nil else { throw RetraceCommandError.invalidArguments }
            switch input.kind {
            case .screen: target = .screen(try reference.decode(ScreenEvidenceRef.self))
            case .transcript: target = .transcript(try reference.decode(V23TranscriptReference.self))
            case .speakerTurn: target = .speakerTurn(try reference.decode(CompanionTurnReference.self))
            case .marker: throw RetraceCommandError.invalidArguments
            }
        }
        try await withSourceWatch(target, context: context, services: services) {
            try await services.router.open(target, commandFence: context.mutationFence) {
                try await validate(target, context: context, services: services)
            }
        }
        return .object(["opened": .bool(true), "exactSelection": .bool(true)])
    }
    private static func playback(_ context: RetraceCommandContext, services: Services) async throws -> RetraceJSON {
        let input: Playback = try context.decode(keys: ["action", "reference", "id", "expectedRevision"])
        let request: RetracePlaybackRequest
        let target: RetraceNavigationTarget?
        switch input.action {
        case .play:
            guard input.reference == nil, let id = input.id, let revision = input.expectedRevision else { throw RetraceCommandError.invalidArguments }
            request = .playMarker(id: id, expectedRevision: revision); target = .marker(id: id, expectedRevision: revision)
        case .playTurn:
            guard let reference = input.reference, input.id == nil, input.expectedRevision == nil else { throw RetraceCommandError.invalidArguments }
            try reference.validate(); request = .playTurn(reference); target = .speakerTurn(reference)
        case .stop:
            guard input.reference == nil, input.id == nil, input.expectedRevision == nil else { throw RetraceCommandError.invalidArguments }
            request = .stop; target = nil
        }
        let perform: @Sendable () async throws -> Void = {
            try await services.router.playback(request, commandFence: context.mutationFence) {
                try await context.authorize()
                if let target { try await validate(target, context: context, services: services) }
            }
        }
        if let target { try await withSourceWatch(target, context: context, services: services, body: perform) }
        else { try await perform() }
        return .object(["action": .string(input.action.rawValue), "coverage": .string(input.action == .stop
            ? "Stopped the shared marker and speaker-turn players."
            : "Verified original source samples; recognition/model boundaries retain their stated uncertainty. Legacy transcript rows alone do not establish an exact playable sample range.")])
    }
    private static func validate(_ target: RetraceNavigationTarget, context: RetraceCommandContext, services: Services) async throws {
        try await context.authorize(.foregroundControl)
        // Foreground access cannot be used to disclose recorded sources without their grant.
        try await context.authorize(.evidenceRead)
        switch target {
        case .screen(let reference): try await services.recall().validateGrantedScreenAction(reference, context: context)
        case .transcript(let reference): try await services.reader().validateGranted(.transcript(reference), context: context)
        case .speakerTurn(let reference):
            try reference.validate()
            try await services.reader().validateGranted(.speakerTurn(reference), context: context)
        case .marker(let id, let revision):
            try await context.authorize(.markersRead)
            guard let marker = try await services.markers.marker(id: id), marker.revision == revision else { throw RetraceCommandError.revisionConflict }
        }
        try await context.authorize(.foregroundControl)
    }
    private static func withSourceWatch(_ target: RetraceNavigationTarget, context: RetraceCommandContext,
                                       services: Services, body: @Sendable () async throws -> Void) async throws {
        try await context.authorize(.evidenceRead)
        let owner = try await services.companion()
        let fence = context.mutationFence
        // Register before resolving: a source mutation between the final read and the
        // synchronous effect revokes that effect, including a non-cooperative callback.
        let observer = try owner.addSpeakerChangeObserver(invalidate: { change in
            switch change {
            case .all, .source: fence.invalidate()
            case .correction(let jobID, _):
                if case .speakerTurn(let reference) = target, reference.jobID == jobID { fence.invalidate() }
            }
        })
        var markerObserver: UUID?
        do {
            if case .marker(let id, _) = target {
                markerObserver = try await services.markers.addChangeObserver(invalidate: { changed in
                    if changed == nil || changed == id { fence.invalidate() }
                })
            }
            try await body()
            if let markerObserver { await services.markers.removeChangeObserver(markerObserver) }
            owner.removeSpeakerChangeObserver(observer)
        } catch {
            if let markerObserver { await services.markers.removeChangeObserver(markerObserver) }
            owner.removeSpeakerChangeObserver(observer)
            throw error
        }
    }
}
