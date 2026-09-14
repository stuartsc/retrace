import Foundation
import CoreGraphics
import Shared
import Database

public struct ProgressiveRecallStageHealth: Sendable {
    public let contextEnabled: Bool
    public let collecting: Bool
    public let degraded: Bool
    public let activity: ActivityStoreHealth?
    public let imageAdmittedAt: Date?
    public let imageRetainedAt: Date?
    public let deduplicatedImages: Int
    public let pendingText: Int?
    public let processingText: Int?
    public let failedText: Int?
    public let oldestPendingTextAt: Date?
    public let audioProcessedAt: Date?
    public let audioTranscriptions: Int
}

public enum ProgressiveRecallAction: String, Sendable {
    case opened, searched, expanded, grouped, ungrouped, glancesRevealed
    case glancesHidden, hiddenEpisodesRevealed, hiddenEpisodesHidden, textExpanded
    case intervalSelected, intervalDeselected, selectionCleared, collapsed, correctionOpened, correctionCancelled
    case correctionHistoryExpanded, correctionHistoryCollapsed, healthExpanded, healthCollapsed
    case evidenceClosed, deletionOpened, deletionCancelled, correctionDraftSaved, screenLinksRequested
    case evidenceRequested, evidenceResolved, evidenceUnavailable, deepLinkCopied, currentDocumentOpened
    case captureSettingChanged, correctionConfirmed, correctionRevoked, activityDeleted
}

/// Local presentation service. A broker is not an implicit grant to disclose captured evidence.
public actor ProgressiveRecallService: EvidenceResolverProtocol {
    private let database: DatabaseManager
    private let adapter: DataAdapter
    private let configuration: @Sendable () async -> CaptureConfig
    private let imageReader: @Sendable (FrameWithVideoInfo) async throws -> CGImage

    public init(database: DatabaseManager, adapter: DataAdapter,
                configuration: @escaping @Sendable () async -> CaptureConfig,
                imageReader: @escaping @Sendable (FrameWithVideoInfo) async throws -> CGImage) {
        self.database = database; self.adapter = adapter
        self.configuration = configuration; self.imageReader = imageReader
    }

    public func activity(_ query: ActivityQuery) async throws -> ActivityPage {
        let page = try await database.searchActivity(query)
        let config = await configuration()
        let visible = page.events.filter { stored in
            guard let context = stored.event.context else { return true }
            return Self.permits(FrameMetadata(appBundleID: context.appBundleID, appName: context.appName,
                windowName: context.windowTitle, browserURL: context.safeURL), config: config)
        }
        // Cursor advances over examined records, including newly excluded historical activity.
        return ActivityPage(events: visible, nextSequence: page.nextSequence)
    }
    public func activityHealth() async throws -> ActivityStoreHealth { try await database.activityHealth() }
    public func corrections() async throws -> [ActivityCorrectionReceipt] {
        let receipts = try await database.activityCorrections()
        var visible: [ActivityCorrectionReceipt] = []
        for receipt in receipts {
            var permitted = true
            for id in receipt.command.targetEventIDs {
                guard let event = try await database.activityEvent(id: id) else { permitted = false; break }
                if let context = event.event.context, !(await permits(context)) { permitted = false; break }
            }
            if permitted { visible.append(receipt) }
        }
        return visible
    }
    public func correct(_ command: ActivityCorrection) async throws -> ActivityCorrectionReceipt {
        for id in command.targetEventIDs {
            guard let event = try await database.activityEvent(id: id) else { throw EvidenceUnavailableReason.evidenceDeleted }
            if let context = event.event.context, !(await permits(context)) { throw EvidenceUnavailableReason.notPermitted }
        }
        return try await database.submitActivityCorrection(command)
    }
    public func deleteActivity(eventIDs: [UUID]) async throws { try await database.deleteActivity(eventIDs: eventIDs) }
    public func screenLinks(eventID: UUID, afterSequence: Int64 = 0, limit: Int = 20) async throws -> [ActivityScreenLink] {
        guard let event = try await database.activityEvent(id: eventID) else { return [] }
        if let context = event.event.context, !(await permits(context)) { return [] }
        return try await database.activityScreenLinks(eventID: eventID, afterSequence: afterSequence, limit: min(500, max(1, limit)))
    }

    /// Resolve exactly the selected immutable extraction, or materialize legacy
    /// evidence only while its captured source, frame, media and index still agree.
    public func reference(searchResult: SearchResult) async throws -> ScreenEvidenceRef {
        do {
            try Task.checkCancellation()
            if let ref = searchResult.evidenceRef {
                guard ref.source == searchResult.source, ref.frameID == searchResult.id else {
                    throw EvidenceUnavailableReason.integrityFailure
                }
                guard try await adapter.evidenceStoreID(source: ref.source) == ref.storeID else {
                    throw EvidenceUnavailableReason.sourceDisconnected
                }
                guard let snapshot = try await database.screenEvidence(ref) else {
                    throw EvidenceUnavailableReason.extractionUnavailable
                }
                guard abs(snapshot.frame.timestamp.timeIntervalSince(searchResult.timestamp)) < 0.001 else {
                    throw EvidenceUnavailableReason.integrityFailure
                }
                guard snapshot.width > 0, snapshot.height > 0 else {
                    throw EvidenceUnavailableReason.frameFinalising
                }
                guard await permits(snapshot.frame.metadata) else { throw EvidenceUnavailableReason.notPermitted }
                guard try await adapter.evidenceStoreID(source: ref.source) == ref.storeID else {
                    throw EvidenceUnavailableReason.sourceDisconnected
                }
                guard try await database.screenEvidence(ref) != nil else { throw EvidenceUnavailableReason.evidenceDeleted }
                try Task.checkCancellation()
                // A newer preferred extraction must never replace this selected revision.
                return ref
            }

            let frozen = try await adapter.prepareSearchSelection(searchResult)
            guard await permits(frozen.item.frame.metadata) else { throw EvidenceUnavailableReason.notPermitted }
            try await adapter.validateSearchSelection(searchResult)
            guard let width = frozen.item.videoInfo?.width, let height = frozen.item.videoInfo?.height,
                  width > 0, height > 0 else {
                throw EvidenceUnavailableReason.frameFinalising
            }
            let saved = try await database.materializeScreenEvidence(frame: frozen.item.frame,
                storeID: frozen.storeID, width: width, height: height, text: frozen.text)
            guard saved.ref.storeID == frozen.storeID, saved.ref.source == searchResult.source,
                  saved.ref.frameID == searchResult.id,
                  abs(saved.frame.timestamp.timeIntervalSince(searchResult.timestamp)) < 0.001,
                  saved.width == width, saved.height == height,
                  saved.text?.fullText == frozen.text?.fullText,
                  saved.text?.chromeText == frozen.text?.chromeText else {
                throw EvidenceUnavailableReason.integrityFailure
            }
            try await adapter.validateSearchSelection(searchResult, materialized: frozen)
            guard await permits(saved.frame.metadata) else { throw EvidenceUnavailableReason.notPermitted }
            guard try await database.screenEvidence(saved.ref) != nil else { throw EvidenceUnavailableReason.evidenceDeleted }
            try await adapter.validateSearchSelection(searchResult, materialized: frozen)
            try Task.checkCancellation()
            return saved.ref
        } catch let error as EvidenceUnavailableReason { throw error }
        catch let error as SearchPaginationError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch DataAdapterError.sourceNotAvailable { throw EvidenceUnavailableReason.sourceDisconnected }
        catch { throw EvidenceUnavailableReason.integrityFailure }
    }

    public func reference(frameID: FrameID, source: FrameSource) async throws -> ScreenEvidenceRef {
        do {
            let storeID = try await adapter.evidenceStoreID(source: source)
            guard let item = try await adapter.getFrameWithVideoInfoByID(id: frameID, source: source) else {
                throw EvidenceUnavailableReason.evidenceDeleted
            }
            if let saved = try await database.currentScreenEvidence(frameID: frameID, storeID: storeID) {
                guard await permits(saved.frame.metadata) else { throw EvidenceUnavailableReason.notPermitted }
                if saved.width > 0, saved.height > 0 { return saved.ref }
            }
            guard await permits(item.frame.metadata) else { throw EvidenceUnavailableReason.notPermitted }
            guard let width = item.videoInfo?.width, let height = item.videoInfo?.height, width > 0, height > 0 else {
                throw EvidenceUnavailableReason.frameFinalising
            }
            let text = try await adapter.savedEvidenceText(frame: item.frame)
            let saved = try await database.materializeScreenEvidence(frame: item.frame, storeID: storeID,
                                                                      width: width, height: height, text: text)
            return saved.ref
        } catch let error as EvidenceUnavailableReason { throw error }
        catch DataAdapterError.sourceNotAvailable { throw EvidenceUnavailableReason.sourceDisconnected }
        catch { throw EvidenceUnavailableReason.integrityFailure }
    }

    public func resolve(_ reference: EvidenceRef, for audience: EvidenceAudience) async -> EvidenceResolution {
        if case .agent = audience { return .unavailable(.notPermitted) }
        do {
            try Task.checkCancellation()
            switch reference {
            case .activity(let ref):
                guard ref.source == .native else { return .unavailable(.sourceDisconnected) }
                guard try await database.activityStoreID() == ref.storeID else { return .unavailable(.sourceDisconnected) }
                guard let event = try await database.activityEvent(id: ref.eventID) else { return .unavailable(.evidenceDeleted) }
                if let context = event.event.context, !(await permits(context)) { return .unavailable(.notPermitted) }
                guard let current = try await database.activityEvent(id: ref.eventID) else { return .unavailable(.evidenceDeleted) }
                if let context = current.event.context, !(await permits(context)) { return .unavailable(.notPermitted) }
                try Task.checkCancellation()
                return .activity(current)
            case .screen(let ref):
                guard try await adapter.evidenceStoreID(source: ref.source) == ref.storeID else {
                    return .unavailable(.sourceDisconnected)
                }
                guard let item = try await adapter.getFrameWithVideoInfoByID(id: ref.frameID, source: ref.source) else {
                    return .unavailable(.evidenceDeleted)
                }
                guard let snapshot = try await database.screenEvidence(ref) else { return .unavailable(.extractionUnavailable) }
                guard await permits(snapshot.frame.metadata) else { return .unavailable(.notPermitted) }
                guard item.frame.source == ref.source,
                      abs(item.frame.timestamp.timeIntervalSince(snapshot.frame.timestamp)) < 0.001 else {
                    return .unavailable(.integrityFailure)
                }
                // The immutable snapshot supplies attribution; the current row supplies finalised media mapping.
                let attributedFrame = FrameReference(id: item.frame.id, timestamp: item.frame.timestamp,
                    segmentID: item.frame.segmentID, videoID: item.frame.videoID,
                    frameIndexInSegment: item.frame.frameIndexInSegment, encodingStatus: item.frame.encodingStatus,
                    metadata: snapshot.frame.metadata, source: ref.source)
                let image = try await imageReader(FrameWithVideoInfo(frame: attributedFrame, videoInfo: item.videoInfo,
                                                                    processingStatus: item.processingStatus))
                try Task.checkCancellation()
                guard image.width == snapshot.width, image.height == snapshot.height else { return .unavailable(.integrityFailure) }
                guard try await adapter.evidenceStoreID(source: ref.source) == ref.storeID else { return .unavailable(.sourceDisconnected) }
                guard let current = try await adapter.getFrameWithVideoInfoByID(id: ref.frameID, source: ref.source),
                      try await database.screenEvidence(ref) != nil else { return .unavailable(.evidenceDeleted) }
                guard current.frame.videoID == item.frame.videoID,
                      abs(current.frame.timestamp.timeIntervalSince(item.frame.timestamp)) < 0.001,
                      current.frame.frameIndexInSegment == item.frame.frameIndexInSegment,
                      current.videoInfo == item.videoInfo else { return .unavailable(.frameFinalising) }
                guard await permits(snapshot.frame.metadata) else { return .unavailable(.notPermitted) }
                try Task.checkCancellation()
                let selected = ScreenEvidenceSnapshot(ref: ref, frame: snapshot.frame, width: snapshot.width,
                    height: snapshot.height, text: snapshot.text, legacyContext: snapshot.legacyContext,
                    highlightsVerified: snapshot.highlightsVerified)
                return .screen(selected, image: image)
            case .audio: return .unavailable(.unsupported)
            }
        } catch let reason as EvidenceUnavailableReason { return .unavailable(reason) }
        catch DataAdapterError.sourceNotAvailable { return .unavailable(.sourceDisconnected) }
        catch { return .unavailable(.integrityFailure) }
    }

    public func currentRevision(_ ref: ScreenEvidenceRef) async throws -> Int64? {
        guard try await adapter.evidenceStoreID(source: ref.source) == ref.storeID else { return nil }
        guard let current = try await database.currentScreenEvidence(frameID: ref.frameID, storeID: ref.storeID),
              await permits(current.frame.metadata) else { return nil }
        return current.ref.extractionRevision
    }

    /// Retained text remains readable when media is unavailable; it is not proof of a resolved image.
    public func retainedScreen(_ ref: ScreenEvidenceRef, for audience: EvidenceAudience) async -> ScreenEvidenceSnapshot? {
        if case .agent = audience { return nil }
        do {
            guard try await adapter.evidenceStoreID(source: ref.source) == ref.storeID,
                  let frame = try await adapter.getFrameWithVideoInfoByID(id: ref.frameID, source: ref.source),
                  let snapshot = try await database.screenEvidence(ref),
                  abs(frame.frame.timestamp.timeIntervalSince(snapshot.frame.timestamp)) < 0.001,
                  await permits(snapshot.frame.metadata), !Task.isCancelled else { return nil }
            guard try await adapter.evidenceStoreID(source: ref.source) == ref.storeID,
                  try await database.screenEvidence(ref) != nil, !Task.isCancelled else { return nil }
            return ScreenEvidenceSnapshot(ref: ref, frame: snapshot.frame, width: snapshot.width,
                height: snapshot.height, text: snapshot.text, legacyContext: snapshot.legacyContext,
                highlightsVerified: snapshot.highlightsVerified)
        } catch { return nil }
    }

    private func permits(_ context: ActivityContext) async -> Bool {
        await permits(FrameMetadata(appBundleID: context.appBundleID, appName: context.appName,
                                    windowName: context.windowTitle, browserURL: context.safeURL))
    }

    private func permits(_ metadata: FrameMetadata) async -> Bool {
        let config = await configuration()
        return Self.permits(metadata, config: config)
    }

    private static func permits(_ metadata: FrameMetadata, config: CaptureConfig) -> Bool {
        guard metadata.redactionReason == nil,
              metadata.appBundleID.map({ !config.excludedAppBundleIDs.contains($0) }) ?? true else { return false }
        let title = metadata.windowName ?? ""
        guard !config.redactWindowTitlePatterns.contains(where: { !$0.isEmpty && title.localizedCaseInsensitiveContains($0) }) else { return false }
        if config.excludePrivateWindows {
            let patterns = ["incognito", "inprivate", "private browsing", "(private)"] + config.customPrivateWindowPatterns
            if patterns.contains(where: { !$0.isEmpty && title.localizedCaseInsensitiveContains($0) }) { return false }
        }
        // A retained scrubbed URL cannot prove that an old credential/query never matched a new rule.
        if !config.redactBrowserURLPatterns.isEmpty { return false }
        return true
    }

    public func track(_ action: ProgressiveRecallAction, outcome: String = "success", count: Int = 1) async {
        let safeOutcomes: Set<String> = ["success", "failed", "no_results", "pending", "conflict", "cancelled"]
        let metadata: [String: Any] = ["action": action.rawValue, "outcome": safeOutcomes.contains(outcome) ? outcome : "failed", "count": max(0, count)]
        if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            try? await database.recordMetricEvent(metricType: .progressiveRecallAction, metadata: json)
        }
    }
}
