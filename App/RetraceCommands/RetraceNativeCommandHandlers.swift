import Foundation
import Shared
import ImageIO
import UniformTypeIdentifiers

/// Registers only connected App services. Foreground navigation/playback and asynchronous jobs
/// are added by their owning adapters, not simulated by the HTTP server.
public enum RetraceNativeCommandHandlers {
    public static func make(coordinator: AppCoordinator, markers: TimelineMarkerService,
                            rulesChanged: @escaping @Sendable () async -> Void = {}) async -> [RetraceCommandHandler] {
        let sharedContext = RetraceContextCommands(reader: { try await coordinator.liveContextSearch() })
        let transcripts = RetraceTranscriptCommands(coordinator: coordinator, sharedContext: sharedContext)
        let timeline = RetraceTimelineCommands(coordinator: coordinator)
        let speakers = RetraceSpeakerCommands(owner: { try await coordinator.companion() })
        var handlers: [RetraceCommandHandler] = [
            .init(operation: .timeline) { try await timeline.read($0) },
            .init(operation: .speakers) { try await speakers.read($0) },
            .init(operation: .speakerCorrect) { try await speakers.correct($0) },
            .init(operation: .transcript) { try await transcripts.read($0) },
            .init(operation: .copyContext) { try await sharedContext.copy($0) },
            .init(operation: .search) { try await sharedContext.search($0) },
            .init(operation: .recordingRead) { context in
                try context.requireKeys([])
                return try .encode(await coordinator.recordingCommandState())
            },
            .init(operation: .recordingSet) { context in
                let input: RecordingSet = try context.decode(keys: ["active", "expectedRevision"])
                try await coordinator.setRecordingFromCommand(active: input.active, expectedRevision: input.expectedRevision)
                return try .encode(await coordinator.recordingCommandState())
            },
            .init(operation: .settingsRead) { context in
                try context.requireKeys([])
                let state = try await coordinator.captureCommandState()
                return try .encode(CaptureSettings(config: state.config, revision: state.revision))
            },
            .init(operation: .settingsUpdate) { context in
                let input: CaptureUpdate = try context.decode(keys: ["captureIntervalSeconds", "adaptiveCaptureEnabled", "deduplicationThreshold", "captureOnWindowChange", "excludedAppBundleIDs", "redactWindowTitlePatterns", "redactBrowserURLPatterns", "expectedRevision"])
                let state = try await coordinator.captureCommandState()
                let config = state.config
                guard input.expectedRevision == state.revision else { throw RetraceCommandError.revisionConflict }
                let replacement = CaptureConfig(captureIntervalSeconds: input.captureIntervalSeconds ?? config.captureIntervalSeconds,
                    adaptiveCaptureEnabled: input.adaptiveCaptureEnabled ?? config.adaptiveCaptureEnabled,
                    deduplicationThreshold: input.deduplicationThreshold ?? config.deduplicationThreshold,
                    maxResolution: config.maxResolution,
                    excludedAppBundleIDs: (input.excludedAppBundleIDs.map(Set.init) ?? config.excludedAppBundleIDs).union(["com.apple.loginwindow"]),
                    excludePrivateWindows: config.excludePrivateWindows, customPrivateWindowPatterns: config.customPrivateWindowPatterns,
                    showCursor: config.showCursor, redactWindowTitlePatterns: input.redactWindowTitlePatterns ?? config.redactWindowTitlePatterns,
                    redactBrowserURLPatterns: input.redactBrowserURLPatterns ?? config.redactBrowserURLPatterns,
                    idleThresholdSeconds: config.idleThresholdSeconds,
                    captureOnWindowChange: input.captureOnWindowChange ?? config.captureOnWindowChange)
                try await context.authorize()
                try await coordinator.updateCaptureConfig(replacement, expectedRevision: input.expectedRevision, commandFence: context.mutationFence)
                return .object(["revision": .string(try await coordinator.captureCommandState().revision.uuidString)])
            },
            .init(operation: .maintenance, runsAsJob: true) { context in
                try context.requireKeys([])
                try await context.authorize()
                try await coordinator.runDatabaseMaintenance()
                return .null
            },
            .init(operation: .indexRequest, runsAsJob: true) { context in
                try context.requireKeys([])
                try await context.authorize()
                try await coordinator.rebuildSearchIndex()
                return .null
            },
            .init(operation: .processingRepair, runsAsJob: true) { context in
                let input: Repair = try context.decode(keys: ["kind", "reference"])
                switch input.kind {
                case .ocr:
                    guard let reference = input.reference else { throw RetraceCommandError.invalidArguments }
                    try await context.authorize()
                    let result = try await coordinator.exactOCRRepair().repair(reference: reference,
                        requestID: context.requestID, clientID: context.clientID, commandFence: context.mutationFence,
                        progress: { await context.reportProgress($0) })
                    return try .encode(result)
                case .pendingTranscription:
                    guard input.reference == nil else { throw RetraceCommandError.invalidArguments }
                    try await context.authorize()
                    guard await coordinator.transcribePendingAudioNow() != nil else { throw RetraceCommandError.unavailable }
                }
                return .null
            },
            .init(operation: .processingOverride) { context in
                let input: Enabled = try context.decode(keys: ["enabled"])
                try await coordinator.setBackgroundProcessNowFromCommand(input.enabled)
                return .object(["requested": .bool(input.enabled)])
            },
            .init(operation: .markerList) { context in
                let input: MarkerList = try context.decode(keys: ["from", "to", "before", "limit", "query"])
                if let query = input.query { guard query.utf8.count <= 512 else { throw RetraceCommandError.invalidArguments } }
                let page = try await markers.listMarkers(.init(from: input.from, to: input.to, before: input.before, limit: input.limit ?? 50))
                let filtered = page.markers.filter { marker in
                    guard let query = input.query, !query.isEmpty else { return true }
                    return [marker.title, marker.note ?? "", marker.spokenObservation?.matchedPhrase ?? ""]
                        .contains { $0.localizedCaseInsensitiveContains(query) }
                }
                return .object(["markers": try .encode(filtered), "nextCursor": try page.nextCursor.map(RetraceJSON.encode) ?? .null,
                    "searchedThisPage": .number(Double(page.markers.count))])
            },
            .init(operation: .markerRead) { context in
                let input: Identifier = try context.decode(keys: ["id"])
                guard let marker = try await markers.marker(id: input.id) else { throw RetraceCommandError.unavailable }
                return try .encode(marker)
            },
            .init(operation: .markerCreate) { context in
                let input: MarkerCreate = try context.decode(keys: ["anchoredAt", "title", "note"])
                let marker = try await markers.createManualMarker(.init(clientID: context.clientID, requestID: context.requestID,
                    anchoredAt: input.anchoredAt, title: input.title ?? "Marked moment", note: input.note))
                return receipt(id: marker.id, revision: marker.revision)
            },
            .init(operation: .markerUpdate) { context in
                guard case .object(let fields) = context.arguments, fields["note"] != nil else { throw RetraceCommandError.invalidArguments }
                let input: MarkerUpdate = try context.decode(keys: ["id", "expectedRevision", "title", "note"])
                let marker = try await markers.updateMarker(.init(clientID: context.clientID, requestID: context.requestID,
                    id: input.id, expectedRevision: input.expectedRevision, title: input.title, note: input.note))
                return receipt(id: marker.id, revision: marker.revision)
            },
            .init(operation: .markerRemove, preview: { context in
                let input: RevisionIdentifier = try context.decode(keys: ["id", "expectedRevision"])
                guard let marker = try await markers.marker(id: input.id), marker.revision == input.expectedRevision else { throw RetraceCommandError.revisionConflict }
                return .init(summary: "Remove one marker (\(marker.id.uuidString))", revision: marker.revision.uuidString, affectedCount: 1)
            }) { context in
                let input: RevisionIdentifier = try context.decode(keys: ["id", "expectedRevision"])
                let marker = try await markers.setMarkerDeleted(id: input.id, expectedRevision: input.expectedRevision, deleted: true)
                return receipt(id: marker.id, revision: marker.revision)
            },
            .init(operation: .markerRestore) { context in
                let input: RevisionIdentifier = try context.decode(keys: ["id", "expectedRevision"])
                let marker = try await markers.setMarkerDeleted(id: input.id, expectedRevision: input.expectedRevision, deleted: false)
                return receipt(id: marker.id, revision: marker.revision)
            },
            .init(operation: .ruleList) { context in
                let input: RuleList = try context.decode(keys: ["afterID", "limit"])
                return try .encode(await markers.listKeywordRules(afterID: input.afterID, limit: input.limit ?? 100))
            },
            .init(operation: .ruleSave) { context in
                let input: RuleSave = try context.decode(keys: ["rule", "expectedRevision"])
                let saved = try await markers.saveKeywordRule(input.rule, expectedRevision: input.expectedRevision)
                await rulesChanged()
                return receipt(id: saved.id, revision: saved.revision)
            },
            .init(operation: .contextRead) { context in
                let owner = try await coordinator.contextRanges()
                return try await RetraceContextRangeCommands.read(context, owner: owner)
            },
            .init(operation: .contextRevise) { context in
                let input: RangeSave = try context.decode(keys: ["markerID", "range", "expectedRevision"])
                guard input.range.ownership != .proposed else { throw RetraceCommandError.invalidArguments }
                let saved = try await markers.saveContextRange(markerID: input.markerID, range: input.range, expectedRevision: input.expectedRevision)
                return receipt(id: saved.id, revision: saved.revision)
            }
        ]
        handlers.append(contentsOf: RetraceForegroundCommands.handlers(coordinator: coordinator, markers: markers))
        handlers.append(contentsOf: evidenceHandlers(coordinator: coordinator))
        handlers.append(contentsOf: RetraceAnnotationCommands.handlers(owner: { try await coordinator.annotations() }))
        handlers.append(contentsOf: RetraceSourceCommands.handlers(owner: { try await coordinator.sourceConfiguration() }))
        handlers.append(contentsOf: RetraceAudioSettingsCommands.handlers(owner: { try await coordinator.audioSession() }))
        handlers.append(contentsOf: RetraceRetentionCommands.handlers(owner: { try await coordinator.retentionCommands() }))
        handlers.append(contentsOf: RetraceOperationsService.handlers(coordinator: coordinator))
        return handlers
    }

    private static func evidenceHandlers(coordinator: AppCoordinator) -> [RetraceCommandHandler] {
        [
            .init(operation: .evidence) { context in
                let input: ScreenRead = try context.decode(keys: ["reference"])
                let service = try await coordinator.progressiveRecall()
                return try .encode(await service.grantedScreen(input.reference, context: context))
            },
            .init(operation: .screenshot) { context in
                let service = try await coordinator.progressiveRecall()
                return try await RetraceScreenshotCommands.read(context, service: service)
            }
        ]
    }
    private static func receipt(id: UUID, revision: UUID) -> RetraceJSON { .object(["id": .string(id.uuidString), "revision": .string(revision.uuidString), "historicalOutcome": .bool(true)]) }
    private static func validateDates(_ from: Date?, _ to: Date?) throws {
        for date in [from, to].compactMap({ $0 }) { guard date.timeIntervalSince1970.isFinite, (-62_135_596_800...253_402_300_799).contains(date.timeIntervalSince1970) else { throw RetraceCommandError.invalidArguments } }
        if let from, let to, from >= to { throw RetraceCommandError.invalidArguments }
    }
    private struct RecordingSet: Decodable { let active: Bool; let expectedRevision: UUID }
    private struct CaptureUpdate: Decodable {
        let captureIntervalSeconds: Double?; let adaptiveCaptureEnabled: Bool?; let deduplicationThreshold: Double?
        let captureOnWindowChange: Bool?; let excludedAppBundleIDs: [String]?
        let redactWindowTitlePatterns: [String]?; let redactBrowserURLPatterns: [String]?; let expectedRevision: UUID
    }
    private struct CaptureSettings: Encodable {
        let revision: UUID
        let captureIntervalSeconds: Double; let adaptiveCaptureEnabled: Bool; let deduplicationThreshold: Double
        let captureOnWindowChange: Bool; let excludedAppBundleIDs: [String]
        let redactWindowTitlePatterns: [String]; let redactBrowserURLPatterns: [String]
        init(config: CaptureConfig, revision: UUID) {
            self.revision = revision; captureIntervalSeconds = config.captureIntervalSeconds
            adaptiveCaptureEnabled = config.adaptiveCaptureEnabled; deduplicationThreshold = config.deduplicationThreshold
            captureOnWindowChange = config.captureOnWindowChange; excludedAppBundleIDs = config.excludedAppBundleIDs.sorted()
            redactWindowTitlePatterns = config.redactWindowTitlePatterns; redactBrowserURLPatterns = config.redactBrowserURLPatterns
        }
    }
    private struct Repair: Decodable {
        enum Kind: String, Decodable { case pendingTranscription, ocr }
        let kind: Kind
        let reference: ScreenEvidenceRef?
    }
    private struct Enabled: Decodable { let enabled: Bool }
    private struct Identifier: Decodable { let id: UUID }
    private struct RevisionIdentifier: Decodable { let id: UUID; let expectedRevision: UUID }
    private struct MarkerCreate: Decodable { let anchoredAt: Date; let title: String?; let note: String? }
    private struct MarkerUpdate: Decodable { let id: UUID; let expectedRevision: UUID; let title: String; let note: String? }
    private struct MarkerList: Decodable { let from: Date?; let to: Date?; let before: TimelineMarkerCursor?; let limit: Int?; let query: String? }
    private struct RuleList: Decodable { let afterID: UUID?; let limit: Int? }
    private struct RuleSave: Decodable { let rule: KeywordRule; let expectedRevision: UUID? }
    private struct RangeSave: Decodable { let markerID: UUID; let range: MarkerContextRange; let expectedRevision: UUID? }
    private struct ScreenRead: Decodable { let reference: ScreenEvidenceRef }
}

extension RetraceCommandContext {
    func requireKeys(_ allowed: Set<String>) throws {
        guard case .object(let values) = arguments, Set(values.keys).isSubset(of: allowed) else { throw RetraceCommandError.invalidArguments }
    }
    func decode<T: Decodable>(keys: Set<String>) throws -> T {
        try requireKeys(keys)
        return try arguments.decode(T.self)
    }
}
