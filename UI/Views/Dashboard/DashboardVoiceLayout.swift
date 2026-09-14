import Foundation
import CoreGraphics
import Shared
import App

enum DashboardContentTab: String, CaseIterable, Identifiable {
    case dictation
    case appUsage = "app_usage"
    case live
    case screenshots

    static let defaultTab: DashboardContentTab = .dictation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .appUsage: return "App Usage"
        case .live: return "Live"
        case .screenshots: return "Screenshots"
        }
    }

    var icon: String {
        switch self {
        case .dictation: return "mic.fill"
        case .appUsage: return "chart.bar.fill"
        case .live: return "waveform.and.magnifyingglass"
        case .screenshots: return "rectangle.stack.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .dictation:
            return "Inserted speech sent into the active control"
        case .appUsage:
            return "App usage and activity"
        case .live:
            return "Live transcript, operating brief, and activity pulse"
        case .screenshots:
            return "Screen frames, OCR, and capture metadata"
        }
    }
}

enum DashboardVoiceContentMode: Equatable {
    case split
    case stacked
}

enum DashboardVoiceLayoutPolicy {
    static let defaultWindowWidth: CGFloat = 1_480
    static let defaultWindowHeight: CGFloat = 800
    static let minWindowWidth: CGFloat = 1_180
    static let minWindowHeight: CGFloat = 720
    static let horizontalContentPadding: CGFloat = 64
    static let defaultContentWidth: CGFloat = defaultWindowWidth - horizontalContentPadding
    static let splitThreshold: CGFloat = 820

    static func contentMode(forWidth width: CGFloat) -> DashboardVoiceContentMode {
        width >= splitThreshold ? .split : .stacked
    }
}

enum DashboardLiveContentMode: Equatable {
    case threeColumn
    case stacked
}

struct DashboardLiveColumnWidths: Equatable {
    let transcript: CGFloat
    let intelligence: CGFloat
    let context: CGFloat
}

enum DashboardLiveLayoutPolicy {
    static let minThreeColumnWidth: CGFloat = 1_080
    static let screenshotPageSize = 18
    static let activityInitialFrameFetchLimit = 72
    static let activityRefreshFrameFetchLimit = 24
    static let columnSpacing: CGFloat = 14

    static func contentMode(forWidth width: CGFloat) -> DashboardLiveContentMode {
        width >= minThreeColumnWidth ? .threeColumn : .stacked
    }

    static func columnWidths(forWidth width: CGFloat) -> DashboardLiveColumnWidths {
        let usableWidth = max(width - (columnSpacing * 2), 0)
        return DashboardLiveColumnWidths(
            transcript: usableWidth * 0.30,
            intelligence: usableWidth * 0.45,
            context: usableWidth * 0.25
        )
    }
}

enum DashboardTranscriptConfidencePolicy {
    static func displayLabel(transcriptionPass: Int, confidence: Double?) -> String {
        let passLabel = transcriptionPass > 1 ? "Pass \(transcriptionPass)" : "First pass"
        guard let confidence, confidence > 0 else { return passLabel }
        return "\(passLabel) · \(Int((confidence * 100).rounded()))%"
    }
}

struct DashboardScreenshotColumnWidths: Equatable {
    let screenshots: CGFloat
    let context: CGFloat
}

enum DashboardScreenshotLayoutPolicy {
    static let minSplitWidth: CGFloat = 900
    static let screenshotColumnRatio: CGFloat = 0.58
    static let minimumInteractiveListWidth: CGFloat = 500

    static func contentMode(forWidth width: CGFloat) -> DashboardVoiceContentMode {
        width >= minSplitWidth ? .split : .stacked
    }

    static func columnWidths(forWidth width: CGFloat) -> DashboardScreenshotColumnWidths {
        let usableWidth = max(width - DashboardLiveLayoutPolicy.columnSpacing, 0)
        let screenshotWidth = max(usableWidth * screenshotColumnRatio, minimumInteractiveListWidth)
        let boundedScreenshotWidth = min(screenshotWidth, usableWidth)

        return DashboardScreenshotColumnWidths(
            screenshots: boundedScreenshotWidth,
            context: max(usableWidth - boundedScreenshotWidth, 0)
        )
    }
}

enum DashboardScreenshotWorkspaceContentMode: Equatable {
    case threeColumn
    case stacked
}

struct DashboardScreenshotWorkspaceColumnWidths: Equatable {
    let momentRail: CGFloat
    let preview: CGFloat
    let inspector: CGFloat
}

enum DashboardScreenshotWorkspacePolicy {
    static let minThreeColumnWidth: CGFloat = 1_050
    static let momentRailWidth: CGFloat = 250
    static let inspectorWidth: CGFloat = 340

    static func contentMode(forWidth width: CGFloat) -> DashboardScreenshotWorkspaceContentMode {
        width >= minThreeColumnWidth ? .threeColumn : .stacked
    }

    static func columnWidths(forWidth width: CGFloat) -> DashboardScreenshotWorkspaceColumnWidths {
        let spacing = DashboardLiveLayoutPolicy.columnSpacing * 2
        let usableWidth = max(width - spacing, 0)
        let momentRail = min(momentRailWidth, usableWidth)
        let inspector = min(inspectorWidth, max(usableWidth - momentRail, 0))
        let preview = max(usableWidth - momentRail - inspector, 0)

        return DashboardScreenshotWorkspaceColumnWidths(
            momentRail: momentRail,
            preview: preview,
            inspector: inspector
        )
    }
}

enum DashboardScreenshotFilterPolicy {
    static func matches(
        query: String,
        appName: String?,
        windowName: String?,
        browserURL: String?,
        ocrText: String?
    ) -> Bool {
        let terms = query
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        guard !terms.isEmpty else { return true }

        let searchableText = [appName, windowName, browserURL, ocrText]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        return terms.allSatisfy(searchableText.contains)
    }
}

enum DashboardScreenshotNavigationDirection {
    case newer
    case older
}

/// Dashboard's shared row admission path. Keeping this outside the native view
/// lets authored SQLite source rows exercise the actual selection and merge.
enum DashboardScreenshotIdentityPolicy {
    static func selectedFrame<Item: DashboardScreenshotRepresentable>(in frames: [Item], selection: ScreenshotEvidenceSelection?) -> Item? {
        guard let selection else { return frames.first }
        return frames.first { $0.screenshotIdentity == selection }
    }

    static func appending<Item: DashboardScreenshotRepresentable>(_ incoming: [Item], to existing: [Item]) -> [Item] {
        var ids = Set(existing.map(\.screenshotIdentity))
        return existing + incoming.filter { ids.insert($0.screenshotIdentity).inserted }
    }

    static func mergedLatest<Item: DashboardScreenshotRepresentable>(_ latest: [Item], into existing: [Item], maxCount: Int?) -> [Item] {
        DashboardLiveMemoryPolicy.mergedLatest(latest, into: existing, id: { $0.screenshotIdentity }, maxCount: maxCount)
    }

    static func adjacentSelection<Item: DashboardScreenshotRepresentable>(from selection: ScreenshotEvidenceSelection?, direction: DashboardScreenshotNavigationDirection,
                                  frames: [Item]) -> ScreenshotEvidenceSelection? {
        guard let selection else { return frames.first?.screenshotIdentity }
        guard let index = frames.firstIndex(where: { $0.screenshotIdentity == selection }) else { return nil }
        let next = direction == .older ? index + 1 : index - 1
        return frames.indices.contains(next) ? frames[next].screenshotIdentity : nil
    }

    /// Native and imported queries are separate actor reads. Keep unavailable
    /// sources absent and compare both sides rather than relabeling old rows.
    static func sourceGenerations(_ read: @Sendable (FrameSource) async throws -> String) async throws -> [FrameSource: String] {
        var values: [FrameSource: String] = [:]
        for source in FrameSource.allCases {
            try Task.checkCancellation()
            values[source] = try? await read(source)
        }
        try Task.checkCancellation()
        return values
    }

    static func retainingCurrentRows(_ rows: [DashboardScreenshotRow], generations: [FrameSource: String]) -> [DashboardScreenshotRow] {
        rows.filter { generations[$0.frame.source] == $0.sourceGeneration }
    }

    static func validateContext(_ row: DashboardScreenshotRow, service: ProgressiveRecallService) async throws -> ScreenEvidenceRef {
        guard try await service.sourceGeneration(source: row.frame.source) == row.sourceGeneration else {
            throw EvidenceUnavailableReason.sourceDisconnected
        }
        let reference = try await service.reference(frameID: row.frame.id, source: row.frame.source)
        try await validateContext(row, reference: reference, service: service)
        return reference
    }

    private static func validateContext(_ row: DashboardScreenshotRow, reference: ScreenEvidenceRef,
                                        service: ProgressiveRecallService) async throws {
        try Task.checkCancellation()
        guard let retained = await service.retainedScreen(reference, for: .localUser), row.id.matches(retained.frame) else {
            throw EvidenceUnavailableReason.integrityFailure
        }
        guard try await service.sourceGeneration(source: row.frame.source) == row.sourceGeneration else {
            throw EvidenceUnavailableReason.sourceDisconnected
        }
        try Task.checkCancellation()
    }

    static func readContext(_ row: DashboardScreenshotRow, service: ProgressiveRecallService,
                            load: @Sendable () async throws -> [OCRNodeWithText]) async throws -> [OCRNodeWithText] {
        let reference = try await validateContext(row, service: service)
        let nodes = try await load()
        try await validateContext(row, reference: reference, service: service)
        return nodes
    }

    static func readRows(sourceGeneration: @Sendable (FrameSource) async throws -> String,
                         load: @Sendable () async throws -> [FrameWithVideoInfo]) async throws -> [DashboardScreenshotRow] {
        for _ in 0..<2 {
            let before = try await sourceGenerations(sourceGeneration)
            let frames = try await load()
            let after = try await sourceGenerations(sourceGeneration)
            guard before == after else { continue }
            return frames.compactMap { frame in
                before[frame.frame.source].map { DashboardScreenshotRow(value: frame, sourceGeneration: $0) }
            }
        }
        throw EvidenceUnavailableReason.sourceDisconnected
    }

    /// Evaluate the captured row/OCR snapshot off main. Cancellation belongs to
    /// this query, so typing again cannot leave earlier scans running indefinitely.
    @MainActor
    static func filterRows(_ rows: [DashboardScreenshotRow],
                           matches: @escaping @Sendable (DashboardScreenshotRow) -> Bool) async throws -> Set<ScreenshotEvidenceSelection> {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) {
            var result: Set<ScreenshotEvidenceSelection> = []
            for row in rows {
                try Task.checkCancellation()
                if matches(row) { result.insert(row.id) }
            }
            return result
        }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }

}

enum DashboardScreenshotNavigationPolicy {
    static func adjacentID(
        from selectedID: Int64?,
        direction: DashboardScreenshotNavigationDirection,
        orderedIDs: [Int64]
    ) -> Int64? {
        guard !orderedIDs.isEmpty else { return nil }
        guard let selectedID, let index = orderedIDs.firstIndex(of: selectedID) else {
            return orderedIDs.first
        }

        let targetIndex = direction == .older ? index + 1 : index - 1
        guard orderedIDs.indices.contains(targetIndex) else { return nil }
        return orderedIDs[targetIndex]
    }
}

enum DashboardScreenshotRetryPolicy {
    static let maximumAttempts = 3

    static func shouldRetry(attemptCount: Int) -> Bool {
        attemptCount < maximumAttempts
    }
}

struct DashboardScreenshotScrollGeometry: Equatable {
    let offsetY: CGFloat
    let contentHeight: CGFloat
    let containerHeight: CGFloat
}

enum DashboardScreenshotPaginationPolicy {
    static let minimumScrollOffset: CGFloat = 24
    static let minimumDownwardDelta: CGFloat = 1
    static let preloadDistance: CGFloat = 160

    static func shouldLoadOlder(previousOffsetY: CGFloat, currentOffsetY: CGFloat,
                                contentHeight: CGFloat, containerHeight: CGFloat,
                                boundary: ScreenshotEvidenceSelection?, lastRequestedBoundary: ScreenshotEvidenceSelection?,
                                canLoadMore: Bool, isLoading: Bool) -> Bool {
        shouldLoadOlder(previousOffsetY: previousOffsetY, currentOffsetY: currentOffsetY,
            contentHeight: contentHeight, containerHeight: containerHeight,
            boundaryID: boundary == nil ? nil : 1, lastRequestedBoundaryID: boundary == lastRequestedBoundary ? 1 : nil,
            canLoadMore: canLoadMore, isLoading: isLoading)
    }

    static func shouldLoadOlder(
        previousOffsetY: CGFloat,
        currentOffsetY: CGFloat,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        boundaryID: Int64?,
        lastRequestedBoundaryID: Int64?,
        canLoadMore: Bool,
        isLoading: Bool
    ) -> Bool {
        guard canLoadMore, !isLoading else { return false }
        guard let boundaryID, boundaryID != lastRequestedBoundaryID else { return false }
        guard contentHeight > containerHeight else { return false }
        guard currentOffsetY >= minimumScrollOffset else { return false }
        guard currentOffsetY > previousOffsetY + minimumDownwardDelta else { return false }

        let remainingDistance = contentHeight - (currentOffsetY + containerHeight)
        return remainingDistance <= preloadDistance
    }
}

struct DashboardOCRContextLine: Identifiable, Equatable {
    let id: Int
    let text: String
    let nodeCount: Int
}

enum DashboardOCRContextPolicy {
    static let rowYTolerance: CGFloat = 0.018

    static func readableLines(from nodes: [OCRNodeWithText]) -> [DashboardOCRContextLine] {
        let readableNodes = nodes
            .map { node -> OCRNodeWithText? in
                let text = normalizedText(node.text)
                guard !text.isEmpty else { return nil }
                return OCRNodeWithText(
                    id: node.id,
                    frameId: node.frameId,
                    x: node.x,
                    y: node.y,
                    width: node.width,
                    height: node.height,
                    text: text
                )
            }
            .compactMap { $0 }
            .sorted { lhs, rhs in
                if abs(lhs.y - rhs.y) > rowYTolerance {
                    return lhs.y < rhs.y
                }
                return lhs.x < rhs.x
            }

        var lines: [DashboardOCRContextLine] = []
        var currentRow: [OCRNodeWithText] = []
        var currentRowY: CGFloat?

        func flushCurrentRow() {
            guard !currentRow.isEmpty else { return }
            let row = currentRow.sorted { lhs, rhs in
                if abs(lhs.x - rhs.x) > 0.001 {
                    return lhs.x < rhs.x
                }
                return lhs.id < rhs.id
            }
            let text = row.map(\.text).joined(separator: " ")
            lines.append(DashboardOCRContextLine(
                id: row.map(\.id).min() ?? lines.count,
                text: text,
                nodeCount: row.count
            ))
            currentRow.removeAll(keepingCapacity: true)
            currentRowY = nil
        }

        for node in readableNodes {
            guard let rowY = currentRowY else {
                currentRow = [node]
                currentRowY = node.y
                continue
            }

            if abs(node.y - rowY) <= rowYTolerance {
                currentRow.append(node)
                currentRowY = (rowY + node.y) / 2
            } else {
                flushCurrentRow()
                currentRow = [node]
                currentRowY = node.y
            }
        }

        flushCurrentRow()
        return lines
    }

    static func fullText(from nodes: [OCRNodeWithText]) -> String {
        readableLines(from: nodes)
            .map(\.text)
            .joined(separator: "\n")
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum DashboardLiveMemoryPolicy {
    static let passiveScreenshotRetentionLimit = DashboardLiveLayoutPolicy.screenshotPageSize * 6
    static let passiveTranscriptRetentionLimit = 120
    static let initialReadableTranscriptTarget = 12
    static let olderReadableTranscriptTarget = 8
    static let recentStatusRowLimit = 20
    static let thumbnailCacheLimit = DashboardLiveLayoutPolicy.screenshotPageSize * 3
    static let ocrCacheLimit = DashboardLiveLayoutPolicy.screenshotPageSize * 2
    static let thumbnailMaxPixelDimension = 320

    static func mergedLatest<Item, ID: Hashable>(
        _ latest: [Item],
        into existing: [Item],
        id: (Item) -> ID,
        maxCount: Int?
    ) -> [Item] {
        let latestIDs = Set(latest.map(id))
        var merged = latest + existing.filter { !latestIDs.contains(id($0)) }

        if let maxCount, merged.count > maxCount {
            merged.removeLast(merged.count - maxCount)
        }

        return merged
    }

    static func retainedCacheIDs<ID: Hashable>(
        preferredIDs: [ID],
        selectedID: ID?,
        maxCount: Int
    ) -> Set<ID> {
        guard maxCount > 0 else { return [] }

        var retained: [ID] = []
        var seen = Set<ID>()

        if let selectedID {
            retained.append(selectedID)
            seen.insert(selectedID)
        }

        for id in preferredIDs where retained.count < maxCount {
            guard !seen.contains(id) else { continue }
            retained.append(id)
            seen.insert(id)
        }

        return Set(retained)
    }
}

/// Reconciles the selected screenshot independently of the bounded latest-page refresh.
@MainActor
final class DashboardSelectedFrameRefresher {
    struct Snapshot: Sendable {
        let frame: FrameWithVideoInfo
        let nodes: [OCRNodeWithText]?
    }

    private var generation = 0
    private var pending: (selection: ScreenshotEvidenceSelection, generation: Int, task: Task<Snapshot?, Error>)?

    func cancel() {
        generation += 1
        pending?.task.cancel()
        pending = nil
    }

    func refresh(
        _ selected: FrameWithVideoInfo,
        loadedStatus: Int?,
        loadFrame: @escaping @Sendable (FrameID) async throws -> FrameWithVideoInfo?,
        loadNodes: @escaping @Sendable (FrameWithVideoInfo) async throws -> [OCRNodeWithText]
    ) async throws -> Snapshot? {
        guard selected.frame.source == .native, !Task.isCancelled else { return nil }
        let request: (selection: ScreenshotEvidenceSelection, generation: Int, task: Task<Snapshot?, Error>)
        if let pending, pending.selection == selected.frame.screenshotIdentity {
            request = pending
        } else {
            cancel()
            let task = Task {
                let clock = ContinuousClock()
                let start = clock.now
                defer {
                    let duration = start.duration(to: clock.now).components
                    Log.recordLatency("dashboard.selected_frame_refresh", valueMs: Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1_000_000_000_000_000, category: .ui, warningThresholdMs: 500)
                }
                try Task.checkCancellation()
                guard let frame = try await loadFrame(selected.frame.id),
                      frame.frame.id == selected.frame.id,
                      ScreenshotEvidenceSelection(selected.frame).matches(frame.frame) else { return nil as Snapshot? }
                try Task.checkCancellation()
                let nodes = frame.processingStatus == 2 && loadedStatus != 2 ? try await loadNodes(frame) : nil
                try Task.checkCancellation()
                return Snapshot(frame: frame, nodes: nodes)
            }
            request = (selected.frame.screenshotIdentity, generation, task)
            pending = request
        }
        defer {
            if pending?.generation == request.generation { pending = nil }
        }
        let result = try await request.task.value
        try Task.checkCancellation()
        guard generation == request.generation else { return nil }
        return result
    }

    static func apply(
        _ snapshot: Snapshot,
        selectedID: Int64?,
        frames: inout [FrameWithVideoInfo],
        nodes: inout [Int64: [OCRNodeWithText]],
        loadedStatuses: inout [Int64: Int]
    ) -> Bool {
        let id = snapshot.frame.frame.id.value
        guard selectedID == id,
              let index = frames.firstIndex(where: { $0.frame.id.value == id && $0.frame.source == snapshot.frame.frame.source }) else { return false }
        frames[index] = snapshot.frame
        if let refreshedNodes = snapshot.nodes {
            nodes[id] = refreshedNodes
            loadedStatuses[id] = snapshot.frame.processingStatus
        } else if loadedStatuses[id] != snapshot.frame.processingStatus {
            nodes.removeValue(forKey: id)
            loadedStatuses.removeValue(forKey: id)
        }
        return true
    }
    static func apply(_ snapshot: Snapshot, selected: ScreenshotEvidenceSelection?,
                      frames: inout [DashboardScreenshotRow],
                      nodes: inout [ScreenshotEvidenceSelection: [OCRNodeWithText]],
                      loadedStatuses: inout [ScreenshotEvidenceSelection: Int]) -> Bool {
        guard let selected, selected.matches(snapshot.frame.frame),
              let index = frames.firstIndex(where: { $0.id == selected }) else { return false }
        frames[index] = DashboardScreenshotRow(value: snapshot.frame, sourceGeneration: frames[index].sourceGeneration)
        if let refreshed = snapshot.nodes {
            nodes[selected] = refreshed
            loadedStatuses[selected] = snapshot.frame.processingStatus
        } else if loadedStatuses[selected] != snapshot.frame.processingStatus {
            nodes.removeValue(forKey: selected)
            loadedStatuses.removeValue(forKey: selected)
        }
        return true
    }

}

enum DashboardLiveAudioPaginationPolicy {
    static func nextTranscriptOffset(
        currentOffset: Int,
        fetchedTranscriptRows: Int,
        reset: Bool
    ) -> Int {
        if reset {
            return max(fetchedTranscriptRows, 0)
        }
        return max(currentOffset, 0) + max(fetchedTranscriptRows, 0)
    }
}

enum DashboardLiveAudioHistoryPolicy {
    static let maximumPagesPerLoad = 3

    static func shouldShowHistory(readableRowCount: Int, canLoadMoreOlderRows: Bool, isLoadingOlderRows: Bool) -> Bool {
        readableRowCount > 0 || canLoadMoreOlderRows || isLoadingOlderRows
    }

    static func shouldPrefetchMoreReadableRows(
        readableRowCount: Int,
        targetReadableRowCount: Int,
        fetchedTranscriptRows: Int,
        fetchedPageCount: Int = 0,
        pageSize: Int,
        canLoadMoreOlderRows: Bool
    ) -> Bool {
        guard readableRowCount < targetReadableRowCount else { return false }
        guard canLoadMoreOlderRows else { return false }
        guard fetchedPageCount < maximumPagesPerLoad else { return false }
        return fetchedTranscriptRows >= pageSize
    }

    static func shouldAutoLoadOlderRows(
        currentRowID: Int64,
        lastRowID: Int64?,
        lastRequestedBoundaryRowID: Int64?,
        canLoadMoreOlderRows: Bool,
        isLoadingOlderRows: Bool
    ) -> Bool {
        guard canLoadMoreOlderRows && !isLoadingOlderRows else { return false }
        return currentRowID == lastRowID && currentRowID != lastRequestedBoundaryRowID
    }

    static func shouldAutoContinueFromVisibleFooter(
        currentOffset: Int,
        lastRequestedOffset: Int?,
        canLoadMoreOlderRows: Bool,
        isLoadingOlderRows: Bool
    ) -> Bool {
        guard canLoadMoreOlderRows && !isLoadingOlderRows else { return false }
        return currentOffset != lastRequestedOffset
    }
}

enum DashboardRefreshLoopPolicy {
    static func shouldContinue(
        loopTab: DashboardContentTab,
        selectedTab: DashboardContentTab,
        isWindowVisible: Bool
    ) -> Bool {
        isWindowVisible && selectedTab == loopTab
    }
}

enum DashboardTabEntryLoadAction: Equatable {
    case initialLoad
    case refresh
}

enum DashboardTabEntryLoadPolicy {
    static func action(hasLoadedItems: Bool) -> DashboardTabEntryLoadAction {
        hasLoadedItems ? .refresh : .initialLoad
    }
}

enum DashboardStatsStripLayoutPolicy {
    static let tileWidth: CGFloat = 184
    static let tileHeight: CGFloat = 122
    static let graphHeight: CGFloat = 38
    static let spacing: CGFloat = 10

    static func canFitAllTiles(cardCount: Int, availableWidth: CGFloat) -> Bool {
        guard cardCount > 0 else { return true }
        let totalWidth = CGFloat(cardCount) * tileWidth + CGFloat(cardCount - 1) * spacing
        return totalWidth <= availableWidth
    }
}

enum DashboardTranscriptDisplayPolicy {
    static let collapsedLineLimit = 3

    static func lineLimit(isExpanded: Bool) -> Int? {
        isExpanded ? nil : collapsedLineLimit
    }

    static func copyText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DashboardLiveAudioRow: Identifiable, Equatable, Sendable {
    let id: Int64
    let text: String
    let startedAt: Date
    let endedAt: Date
    let source: AudioSource
    let confidence: Double?
    let transcriptStatus: String
    let detectedLanguage: String?
    let audioVariant: String
    let qualityFlags: String?
    let transcriptionPass: Int
    let batchAudioPath: String?
    let pendingBatchCount: Int
    let isPendingSummary: Bool
    let isLowConfidenceSummary: Bool
    let isStatusSummary: Bool

    init(
        id: Int64,
        text: String,
        startedAt: Date,
        endedAt: Date,
        source: AudioSource,
        confidence: Double?,
        transcriptStatus: String,
        detectedLanguage: String?,
        audioVariant: String,
        qualityFlags: String?,
        transcriptionPass: Int = 1,
        batchAudioPath: String? = nil,
        pendingBatchCount: Int = 0,
        isPendingSummary: Bool = false,
        isLowConfidenceSummary: Bool = false,
        isStatusSummary: Bool = false
    ) {
        self.id = id
        self.text = text
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.confidence = confidence
        self.transcriptStatus = transcriptStatus
        self.detectedLanguage = detectedLanguage
        self.audioVariant = audioVariant
        self.qualityFlags = qualityFlags
        self.transcriptionPass = transcriptionPass
        self.batchAudioPath = batchAudioPath
        self.pendingBatchCount = pendingBatchCount
        self.isPendingSummary = isPendingSummary
        self.isLowConfidenceSummary = isLowConfidenceSummary
        self.isStatusSummary = isStatusSummary
    }

    var hasTranscriptText: Bool {
        !DashboardTranscriptDisplayPolicy.copyText(text).isEmpty
    }

    var displayText: String {
        if isPendingSummary {
            let countText = pendingBatchCount == 1 ? "1 audio batch" : "\(pendingBatchCount) audio batches"
            return "\(countText) captured. Transcription is catching up; raw audio is preserved for repair."
        }
        if isLowConfidenceSummary {
            let countText = pendingBatchCount == 1 ? "1 audio batch" : "\(pendingBatchCount) audio batches"
            return "\(countText) grouped for repair. Likely background audio, uncertain speech, or decoder artifact; raw audio remains available."
        }
        if isStatusSummary {
            if let ambientLabel {
                let countText = pendingBatchCount == 1 ? "1 entry" : "\(pendingBatchCount) entries"
                return "Ambient audio: \(ambientLabel) (\(countText) collapsed)."
            }
            let countText = pendingBatchCount == 1 ? "1 matching audio status row" : "\(pendingBatchCount) matching audio status rows"
            return "\(countText) collapsed. \(Self.statusText(status: transcriptStatus, qualityFlags: qualityFlags))"
        }
        guard !hasTranscriptText else { return text }
        return Self.statusText(status: transcriptStatus, qualityFlags: qualityFlags)
    }

    var statusBadgeText: String {
        if isPendingSummary {
            return "Catching up"
        }
        if isLowConfidenceSummary {
            return "Low confidence"
        }
        if isStatusSummary {
            if ambientLabel != nil {
                return "Ambient"
            }
            return "Collapsed"
        }
        return transcriptStatus
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    var isPendingCapturePlaceholder: Bool {
        !isPendingSummary && !hasTranscriptText && transcriptStatus == "pending"
    }

    var isRepairStatus: Bool {
        switch transcriptStatus {
        case "probable_silence",
             "probable_junk",
             "needs_review",
             "language_uncertain",
             "refinement_failed",
             "refinement_skipped":
            return true
        default:
            return false
        }
    }

    var isLowConfidenceArtifact: Bool {
        if isPendingSummary || isLowConfidenceSummary || isStatusSummary {
            return false
        }
        if transcriptStatus == "probable_junk" {
            return true
        }
        if transcriptStatus == "language_uncertain" {
            return true
        }
        if let qualityFlags {
            let flags = qualityFlags.lowercased()
            if flags.contains("junk_pattern")
                || flags.contains("vocalization_artifact")
                || flags.contains("unsupported_script_artifact")
                || flags.contains("language_uncertain") {
                return true
            }
        }
        if Self.looksLikeNonSpeechCaptionArtifact(text) {
            return true
        }
        if Self.looksLikePunctuationOnlyArtifact(text) {
            return true
        }
        if Self.looksLikePhoneticNoiseArtifact(text) {
            return true
        }
        if Self.looksLikeUnsupportedScriptArtifact(text, detectedLanguage: detectedLanguage) {
            return true
        }
        if Self.looksLikeCorruptDecoderArtifact(text, detectedLanguage: detectedLanguage) {
            return true
        }
        return !hasTranscriptText && isRepairStatus
    }

    var isRepairingTranscript: Bool {
        hasTranscriptText && isRepairStatus && !isLowConfidenceArtifact
    }

    var isRepairedTranscript: Bool {
        hasTranscriptText && transcriptStatus == "transcribed" && transcriptionPass > 1
    }

    var repairedBadgeText: String {
        transcriptionPass >= 3 ? "Context repaired" : "Repaired"
    }

    var ambientLabel: String? {
        guard let qualityFlags else { return nil }
        let prefix = "ambient_caption_summary:"
        guard qualityFlags.hasPrefix(prefix) else { return nil }
        let label = String(qualityFlags.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    static func previewText(from text: String) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "No transcript text" : collapsed
    }

    private static func looksLikePunctuationOnlyArtifact(_ text: String) -> Bool {
        let ignoredScalars = CharacterSet.whitespacesAndNewlines
        let punctuationScalars = CharacterSet.punctuationCharacters
            .union(.symbols)
        let signalScalars = text.unicodeScalars.filter { !ignoredScalars.contains($0) }
        guard !signalScalars.isEmpty else { return false }
        return signalScalars.allSatisfy { punctuationScalars.contains($0) }
    }

    static func statusText(status: String, qualityFlags: String?) -> String {
        switch status {
        case "pending":
            return "Audio captured. Transcribing now; raw audio is safely stored."
        case "probable_silence":
            return "Listening. Audio captured, no speech decoded in this batch."
        case "needs_review":
            return "Audio captured. No words decoded yet; queued for repair."
        case "language_uncertain":
            return "Audio captured. Language uncertain; queued for another pass."
        case "decode_failed":
            return "Audio captured, but decoding failed. Raw audio is preserved."
        default:
            if let qualityFlags, qualityFlags.contains("empty_text") {
                return "Audio captured. No transcript text decoded yet."
            }
            return "Audio captured."
        }
    }

    private static func looksLikePhoneticNoiseArtifact(_ text: String) -> Bool {
        let ignoredScalars = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(CharacterSet(charactersIn: "\"'`"))
        let signalScalars = text.unicodeScalars.filter { !ignoredScalars.contains($0) }
        guard signalScalars.count >= 4 else { return false }
        guard !signalScalars.contains(where: isPrimarySpeechScriptScalar) else { return false }
        return signalScalars.allSatisfy(isPhoneticArtifactScalar)
    }

    private static func looksLikeUnsupportedScriptArtifact(_ text: String, detectedLanguage: String?) -> Bool {
        let normalizedLanguage = detectedLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let languageIsUntrusted = normalizedLanguage == nil
            || normalizedLanguage == ""
            || normalizedLanguage == "nn"
            || normalizedLanguage == "und"
            || normalizedLanguage == "unknown"
            || normalizedLanguage == "auto"
        guard languageIsUntrusted else { return false }

        let ignoredScalars = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
            .union(CharacterSet(charactersIn: "\"'`"))
        let signalScalars = text.unicodeScalars.filter { !ignoredScalars.contains($0) }
        guard signalScalars.count >= 4 else { return false }
        return !signalScalars.contains(where: isPrimarySpeechScriptScalar)
    }

    private static func looksLikeCorruptDecoderArtifact(_ text: String, detectedLanguage: String?) -> Bool {
        if text.contains("\u{FFFD}") { return true }

        let normalizedLanguage = detectedLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let languageIsUntrusted = normalizedLanguage == nil
            || normalizedLanguage == ""
            || normalizedLanguage == "nn"
            || normalizedLanguage == "und"
            || normalizedLanguage == "unknown"
            || normalizedLanguage == "auto"
        guard languageIsUntrusted else { return false }

        let ignoredScalars = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
            .union(CharacterSet(charactersIn: "\"'`"))
        let signalScalars = text.unicodeScalars.filter { !ignoredScalars.contains($0) }
        guard signalScalars.count >= 4 else { return false }
        return signalScalars.contains { !isPrimarySpeechScriptScalar($0) }
    }

    private static func looksLikeNonSpeechCaptionArtifact(_ text: String) -> Bool {
        let captionMarkers = CharacterSet(charactersIn: "*[]()")
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hasCaptionWrapper =
            (trimmed.hasPrefix("*") && trimmed.hasSuffix("*")) ||
            (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) ||
            (trimmed.hasPrefix("(") && trimmed.hasSuffix(")"))
        let hasTruncatedCaptionMarker =
            trimmed.hasPrefix("[") != trimmed.hasSuffix("]") ||
            trimmed.hasPrefix("*") != trimmed.hasSuffix("*")
        guard hasCaptionWrapper || hasTruncatedCaptionMarker else { return false }

        let inner = trimmed
            .trimmingCharacters(in: captionMarkers)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nonSpeechTerms = [
            "applause",
            "alarm",
            "background",
            "beep",
            "bell",
            "breathing",
            "chime",
            "click",
            "clicking",
            "clapping",
            "cough",
            "crackle",
            "crackling",
            "door",
            "doorbell",
            "fire",
            "footstep",
            "footsteps",
            "inaudible",
            "keyboard",
            "knock",
            "laugh",
            "laughter",
            "mouse",
            "music",
            "no audio",
            "no sound",
            "noise",
            "notification",
            "ring",
            "ringing",
            "silence",
            "sigh",
            "sound",
            "sounds",
            "static",
            "typing",
            "waves",
            "wind",
            "笑",
            "笑い"
        ]
        if nonSpeechTerms.contains(where: { inner.contains($0) }) {
            return true
        }

        let words = inner
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0) }
        if hasTruncatedCaptionMarker {
            return words.count <= 4
        }
        let speechPronouns: Set<String> = [
            "i",
            "im",
            "you",
            "we",
            "he",
            "she",
            "they"
        ]

        return words.count <= 4
            && !words.contains(where: speechPronouns.contains)
            && words.contains { $0.hasSuffix("ing") }
    }

    private static func isPrimarySpeechScriptScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0030...0x0039,
             0x0041...0x005A,
             0x0061...0x007A,
             0x0400...0x04FF,
             0x1800...0x18AF,
             0x3040...0x309F,
             0x30A0...0x30FF,
             0x4E00...0x9FFF:
            return true
        default:
            return false
        }
    }

    private static func isPhoneticArtifactScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0250...0x02AF,
             0x02B0...0x02FF,
             0x0300...0x036F:
            return true
        default:
            return false
        }
    }
}

struct DashboardLiveAudioPresentation: Equatable, Sendable {
    let transcriptRows: [DashboardLiveAudioRow]
    let statusRows: [DashboardLiveAudioRow]
}

struct DashboardLiveTranscriptBlock: Identifiable, Equatable, Sendable {
    enum ID: Hashable, Sendable {
        case audioBatch(String)
        case capture(startMilliseconds: Int64, source: String)
    }

    let id: ID
    let rows: [DashboardLiveAudioRow]
    let text: String
    let startedAt: Date
    let endedAt: Date

    init(rows: [DashboardLiveAudioRow]) {
        precondition(!rows.isEmpty, "Live transcript blocks require at least one row")

        let chronologicalRows = rows.sorted {
            if $0.startedAt != $1.startedAt {
                return $0.startedAt < $1.startedAt
            }
            return $0.id < $1.id
        }
        let oldestRow = chronologicalRows[0]

        self.id = Self.stableIdentity(for: oldestRow)
        self.rows = chronologicalRows
        self.text = DashboardLiveTranscriptBlockPolicy.continuousText(from: chronologicalRows)
        self.startedAt = chronologicalRows.map(\.startedAt).min() ?? oldestRow.startedAt
        self.endedAt = chronologicalRows.map(\.endedAt).max() ?? oldestRow.endedAt
    }

    var rowCount: Int { rows.count }
    var oldestRowID: Int64 { rows.first?.id ?? 0 }
    var newestRowID: Int64 { rows.last?.id ?? 0 }

    var sourceLabel: String {
        let sourceNames = rows.reduce(into: [String]()) { names, row in
            let name = row.source.rawValue.capitalized
            if !names.contains(name) {
                names.append(name)
            }
        }
        return sourceNames.count == 1 ? (sourceNames.first ?? "Audio") : "Mixed audio"
    }

    var spansMultipleDisplayMinutes: Bool {
        Int(startedAt.timeIntervalSince1970 / 60) != Int(endedAt.timeIntervalSince1970 / 60)
    }

    var isUpdating: Bool {
        rows.contains(where: \.isRepairingTranscript)
    }

    var refinementBadgeText: String? {
        if isUpdating {
            return "Updating"
        }

        let passes = rows.map(\.transcriptionPass)
        guard let minimumPass = passes.min(), let maximumPass = passes.max(), maximumPass > 1 else {
            return nil
        }
        if minimumPass >= 3 {
            return "Context repaired"
        }
        if minimumPass >= 2 {
            return "Repaired"
        }
        return "Partially repaired"
    }

    private static func stableIdentity(for row: DashboardLiveAudioRow) -> ID {
        if let batchAudioPath = row.batchAudioPath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !batchAudioPath.isEmpty {
            return .audioBatch(batchAudioPath)
        }

        return .capture(
            startMilliseconds: Int64((row.startedAt.timeIntervalSince1970 * 1_000).rounded()),
            source: row.source.rawValue
        )
    }
}

struct DashboardLiveAudioPreparedSnapshot: Equatable, Sendable {
    let transcriptRows: [DashboardLiveAudioRow]
    let statusRows: [DashboardLiveAudioRow]
    let transcriptBlocks: [DashboardLiveTranscriptBlock]

    init(rawRows: [DashboardLiveAudioRow], statusRowLimit: Int) {
        let presentation = DashboardLiveAudioPresentationPolicy.presentation(
            for: rawRows,
            statusRowLimit: statusRowLimit
        )
        self.transcriptRows = presentation.transcriptRows
        self.statusRows = presentation.statusRows
        self.transcriptBlocks = DashboardLiveTranscriptBlockPolicy.blocks(
            from: presentation.transcriptRows
        )
    }
}

enum DashboardLiveTranscriptBlockPolicy {
    static let maximumInterSegmentStartGap: TimeInterval = 20
    static let maximumBlockDuration: TimeInterval = 90
    static let maximumBlockCharacterCount = 1_200

    private static let minimumOverlapWordCount = 3
    private static let maximumOverlapWordCount = 32

    static func blocks(from rows: [DashboardLiveAudioRow]) -> [DashboardLiveTranscriptBlock] {
        let chronologicalRows = latestPassRows(from: rows)
            .filter { $0.hasTranscriptText }
            .sorted {
                if $0.startedAt != $1.startedAt {
                    return $0.startedAt < $1.startedAt
                }
                return $0.id < $1.id
            }

        var groupedRows: [[DashboardLiveAudioRow]] = []
        for row in chronologicalRows {
            if let currentRows = groupedRows.last,
               canAppend(row, to: currentRows) {
                groupedRows[groupedRows.count - 1].append(row)
            } else {
                groupedRows.append([row])
            }
        }

        return groupedRows.reversed().map(DashboardLiveTranscriptBlock.init(rows:))
    }

    static func copyText(from blocks: [DashboardLiveTranscriptBlock]) -> String {
        blocks.reversed()
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    static func normalizedSegmentText(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func continuousText(from rows: [DashboardLiveAudioRow]) -> String {
        let chronologicalRows = rows.sorted {
            if $0.startedAt != $1.startedAt {
                return $0.startedAt < $1.startedAt
            }
            return $0.id < $1.id
        }

        var result = ""
        var previousSegment = ""
        var previousSignature: String?

        for row in chronologicalRows {
            let segment = normalizedSegmentText(row.text)
            guard !segment.isEmpty else { continue }

            let signature = comparisonSignature(segment)
            if !signature.isEmpty, signature == previousSignature {
                previousSegment = segment
                continue
            }

            if result.isEmpty {
                result = segment
            } else {
                let overlapCount = leadingOverlapWordCount(
                    previousSegment: previousSegment,
                    nextSegment: segment
                )
                let remainder = segmentDroppingLeadingWords(segment, count: overlapCount)
                if !remainder.isEmpty {
                    result += " " + remainder
                }
            }

            previousSegment = segment
            previousSignature = signature
        }

        return result
    }

    private static func canAppend(
        _ row: DashboardLiveAudioRow,
        to currentRows: [DashboardLiveAudioRow]
    ) -> Bool {
        guard let previousRow = currentRows.last,
              let firstRow = currentRows.first else {
            return false
        }

        let startGap = row.startedAt.timeIntervalSince(previousRow.startedAt)
        guard startGap <= maximumInterSegmentStartGap else { return false }

        let blockEnd = max(
            row.endedAt,
            currentRows.map(\.endedAt).max() ?? previousRow.endedAt
        )
        guard blockEnd.timeIntervalSince(firstRow.startedAt) <= maximumBlockDuration else {
            return false
        }

        return continuousText(from: currentRows + [row]).count <= maximumBlockCharacterCount
    }

    private static func latestPassRows(
        from rows: [DashboardLiveAudioRow]
    ) -> [DashboardLiveAudioRow] {
        var latestPassByBatchPath: [String: Int] = [:]
        for row in rows {
            guard let batchPath = normalizedBatchPath(row.batchAudioPath) else { continue }
            latestPassByBatchPath[batchPath] = max(
                latestPassByBatchPath[batchPath] ?? row.transcriptionPass,
                row.transcriptionPass
            )
        }

        return rows.filter { row in
            guard let batchPath = normalizedBatchPath(row.batchAudioPath),
                  let latestPass = latestPassByBatchPath[batchPath] else {
                return true
            }
            return row.transcriptionPass == latestPass
        }
    }

    private static func normalizedBatchPath(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return path
    }

    private static func leadingOverlapWordCount(
        previousSegment: String,
        nextSegment: String
    ) -> Int {
        let previousWords = canonicalWords(previousSegment)
        let nextWords = canonicalWords(nextSegment)
        let maximumCount = min(
            maximumOverlapWordCount,
            previousWords.count,
            nextWords.count
        )
        guard maximumCount >= minimumOverlapWordCount else { return 0 }

        for count in stride(from: maximumCount, through: minimumOverlapWordCount, by: -1) {
            if previousWords.suffix(count).elementsEqual(nextWords.prefix(count)) {
                return count
            }
        }
        return 0
    }

    private static func segmentDroppingLeadingWords(_ segment: String, count: Int) -> String {
        guard count > 0 else { return segment }

        let rawWords = segment.split(whereSeparator: \Character.isWhitespace).map(String.init)
        var meaningfulWordCount = 0
        var finalDroppedIndex: Int?

        for (index, rawWord) in rawWords.enumerated() where !canonicalWord(rawWord).isEmpty {
            meaningfulWordCount += 1
            if meaningfulWordCount == count {
                finalDroppedIndex = index
                break
            }
        }

        guard let finalDroppedIndex else { return segment }
        return rawWords.dropFirst(finalDroppedIndex + 1).joined(separator: " ")
    }

    private static func comparisonSignature(_ text: String) -> String {
        canonicalWords(text).joined(separator: " ")
    }

    private static func canonicalWords(_ text: String) -> [String] {
        text.split(whereSeparator: \Character.isWhitespace)
            .map { canonicalWord(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func canonicalWord(_ word: String) -> String {
        String(word.unicodeScalars.filter(CharacterSet.alphanumerics.contains))
            .lowercased()
    }
}

enum DashboardLiveAudioPresentationPolicy {
    static func mergedRowsReplacingOlderPasses(
        existing: [DashboardLiveAudioRow],
        latest: [DashboardLiveAudioRow]
    ) -> [DashboardLiveAudioRow] {
        let latestIDs = Set(latest.map(\.id))
        let latestBatchPaths = Set(latest.compactMap { normalizedBatchPath($0.batchAudioPath) })
        let retainedExisting = existing.filter { row in
            if latestIDs.contains(row.id) {
                return false
            }
            if let batchPath = normalizedBatchPath(row.batchAudioPath),
               latestBatchPaths.contains(batchPath) {
                return false
            }
            return true
        }

        return normalizedRows(latest + retainedExisting)
    }

    static func normalizedRows(_ rows: [DashboardLiveAudioRow]) -> [DashboardLiveAudioRow] {
        Dictionary(grouping: rows, by: \.id)
            .compactMap { _, rows in rows.max(by: rowSortIsAscending) }
            .sorted(by: rowSortIsDescending)
    }

    static func presentation(
        for rows: [DashboardLiveAudioRow],
        statusRowLimit: Int? = nil
    ) -> DashboardLiveAudioPresentation {
        var transcriptRows: [DashboardLiveAudioRow] = []
        var statusRows: [DashboardLiveAudioRow] = []

        for row in rows {
            if belongsInStatusPanel(row) {
                statusRows.append(row)
            } else {
                transcriptRows.append(row)
            }
        }

        let repeatedDecoderPartition = partitionRepeatedFirstPassDecoderLoops(transcriptRows)
        transcriptRows = repeatedDecoderPartition.readableRows
        statusRows.append(contentsOf: repeatedDecoderPartition.summaryRows)
        statusRows.sort(by: rowSortIsDescending)

        if let statusRowLimit {
            statusRows = Array(statusRows.prefix(max(statusRowLimit, 0)))
        }

        return DashboardLiveAudioPresentation(
            transcriptRows: coalescedRepeatedTranscriptRows(transcriptRows),
            statusRows: coalescedRepeatedStatusRows(statusRows)
        )
    }

    static func rowsForDisplay(_ rows: [DashboardLiveAudioRow]) -> [DashboardLiveAudioRow] {
        presentation(for: rows).transcriptRows
    }

    private static func belongsInStatusPanel(_ row: DashboardLiveAudioRow) -> Bool {
        ambientCaption(for: row) != nil
            || row.isPendingSummary
            || row.isLowConfidenceSummary
            || row.isStatusSummary
            || row.isPendingCapturePlaceholder
            || row.isLowConfidenceArtifact
            || !row.hasTranscriptText
    }

    private static func coalescedRepeatedTranscriptRows(_ rows: [DashboardLiveAudioRow]) -> [DashboardLiveAudioRow] {
        var coalesced: [DashboardLiveAudioRow] = []
        var previousSignature: String?

        for row in rows {
            let signature = transcriptSignature(for: row)
            guard !signature.isEmpty else {
                previousSignature = nil
                coalesced.append(row)
                continue
            }

            if signature == previousSignature {
                continue
            }

            previousSignature = signature
            coalesced.append(row)
        }

        return coalesced
    }

    private static func partitionRepeatedFirstPassDecoderLoops(
        _ rows: [DashboardLiveAudioRow]
    ) -> (readableRows: [DashboardLiveAudioRow], summaryRows: [DashboardLiveAudioRow]) {
        let minimumRepeatedRowCount = 3
        let minimumSignatureCharacterCount = 18
        let minimumSignatureWordCount = 5
        let maximumOccurrenceGap: TimeInterval = 5 * 60

        var readableRows: [DashboardLiveAudioRow] = []
        var summaryRows: [DashboardLiveAudioRow] = []
        var index = 0

        while index < rows.count {
            let signature = transcriptSignature(for: rows[index])
            var endIndex = index + 1

            while endIndex < rows.count,
                  transcriptSignature(for: rows[endIndex]) == signature,
                  abs(rows[endIndex].startedAt.timeIntervalSince(rows[endIndex - 1].startedAt))
                    <= maximumOccurrenceGap {
                endIndex += 1
            }

            let repeatedRows = Array(rows[index..<endIndex])
            let signatureWordCount = signature.split(whereSeparator: \Character.isWhitespace).count
            let shouldQuarantine = !signature.isEmpty
                && repeatedRows.count >= minimumRepeatedRowCount
                && repeatedRows.allSatisfy { $0.transcriptionPass == 1 }
                && signature.count >= minimumSignatureCharacterCount
                && signatureWordCount >= minimumSignatureWordCount

            if shouldQuarantine, let summary = lowConfidenceSummary(for: repeatedRows) {
                summaryRows.append(summary)
            } else {
                readableRows.append(contentsOf: repeatedRows)
            }

            index = endIndex
        }

        return (readableRows, summaryRows)
    }

    private static func lowConfidenceSummary(
        for rows: [DashboardLiveAudioRow]
    ) -> DashboardLiveAudioRow? {
        guard let firstRow = rows.first else { return nil }
        var summary = normalizedStatusRow(firstRow, signature: "low_confidence")
        for row in rows.dropFirst() {
            summary = mergedStatusRow(summary, with: row, signature: "low_confidence")
        }
        return summary
    }

    private static func transcriptSignature(for row: DashboardLiveAudioRow) -> String {
        let edgeNoise = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return DashboardTranscriptDisplayPolicy.copyText(row.text)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: edgeNoise)
            .lowercased()
    }

    private static func coalescedRepeatedStatusRows(_ rows: [DashboardLiveAudioRow]) -> [DashboardLiveAudioRow] {
        var coalesced: [DashboardLiveAudioRow] = []
        var statusIndexBySignature: [String: Int] = [:]

        for row in rows {
            guard let signature = repeatedStatusSignature(for: row) else {
                coalesced.append(row)
                statusIndexBySignature.removeAll()
                continue
            }

            if let existingIndex = statusIndexBySignature[signature] {
                coalesced[existingIndex] = mergedStatusRow(
                    coalesced[existingIndex],
                    with: row,
                    signature: signature
                )
            } else {
                statusIndexBySignature[signature] = coalesced.count
                coalesced.append(normalizedStatusRow(row, signature: signature))
            }
        }

        return coalesced
    }

    private static func repeatedStatusSignature(for row: DashboardLiveAudioRow) -> String? {
        if let caption = ambientCaption(for: row),
           shouldUseAmbientCaptionSummary(for: row) {
            return caption.signature
        }
        if row.isLowConfidenceSummary || row.isLowConfidenceArtifact {
            return "low_confidence"
        }
        if let caption = ambientCaption(for: row) {
            return caption.signature
        }
        if row.isPendingSummary || row.isPendingCapturePlaceholder {
            return "pending"
        }
        if row.isStatusSummary || !row.hasTranscriptText {
            return "status:\(row.transcriptStatus):\(statusSummaryMessage(for: row))"
        }
        return nil
    }

    private static func statusSummaryMessage(for row: DashboardLiveAudioRow) -> String {
        DashboardLiveAudioRow.statusText(status: row.transcriptStatus, qualityFlags: row.qualityFlags)
    }

    private static func normalizedStatusRow(
        _ row: DashboardLiveAudioRow,
        signature: String
    ) -> DashboardLiveAudioRow {
        switch signature {
        case let ambient where ambient.hasPrefix("ambient:"):
            guard !row.isStatusSummary else { return row }
            let label = String(ambient.dropFirst("ambient:".count))
            return DashboardLiveAudioRow(
                id: syntheticAmbientSummaryID(for: row),
                text: label,
                startedAt: row.startedAt,
                endedAt: row.endedAt,
                source: row.source,
                confidence: nil,
                transcriptStatus: "ambient_caption",
                detectedLanguage: row.detectedLanguage,
                audioVariant: row.audioVariant,
                qualityFlags: "ambient_caption_summary:\(label)",
                batchAudioPath: row.batchAudioPath,
                pendingBatchCount: 1,
                isStatusSummary: true
            )
        case "low_confidence":
            guard !row.isLowConfidenceSummary else { return row }
            return DashboardLiveAudioRow(
                id: syntheticLowConfidenceSummaryID(for: row),
                text: "",
                startedAt: row.startedAt,
                endedAt: row.endedAt,
                source: row.source,
                confidence: nil,
                transcriptStatus: "probable_junk",
                detectedLanguage: row.detectedLanguage,
                audioVariant: row.audioVariant,
                qualityFlags: "low_confidence_summary",
                batchAudioPath: row.batchAudioPath,
                pendingBatchCount: 1,
                isLowConfidenceSummary: true
            )
        case "pending":
            guard !row.isPendingCapturePlaceholder else {
                return DashboardLiveAudioRow(
                    id: syntheticPendingSummaryID(for: row),
                    text: "",
                    startedAt: row.startedAt,
                    endedAt: row.endedAt,
                    source: row.source,
                    confidence: nil,
                    transcriptStatus: "pending",
                    detectedLanguage: nil,
                    audioVariant: row.audioVariant,
                    qualityFlags: "pending_summary",
                    batchAudioPath: row.batchAudioPath,
                    pendingBatchCount: 1,
                    isPendingSummary: true
                )
            }
            return row
        default:
            guard !row.isStatusSummary else { return row }
            return DashboardLiveAudioRow(
                id: syntheticStatusSummaryID(for: row),
                text: "",
                startedAt: row.startedAt,
                endedAt: row.endedAt,
                source: row.source,
                confidence: nil,
                transcriptStatus: row.transcriptStatus,
                detectedLanguage: row.detectedLanguage,
                audioVariant: row.audioVariant,
                qualityFlags: row.qualityFlags,
                batchAudioPath: row.batchAudioPath,
                pendingBatchCount: 1,
                isStatusSummary: true
            )
        }
    }

    private static func mergedStatusRow(
        _ existing: DashboardLiveAudioRow,
        with next: DashboardLiveAudioRow,
        signature: String
    ) -> DashboardLiveAudioRow {
        let nextNormalized = normalizedStatusRow(next, signature: signature)
        let mergedCount = max(existing.pendingBatchCount, 1) + max(nextNormalized.pendingBatchCount, 1)

        switch signature {
        case let ambient where ambient.hasPrefix("ambient:"):
            let label = String(ambient.dropFirst("ambient:".count))
            return DashboardLiveAudioRow(
                id: existing.id,
                text: label,
                startedAt: existing.startedAt,
                endedAt: nextNormalized.endedAt,
                source: existing.source,
                confidence: nil,
                transcriptStatus: "ambient_caption",
                detectedLanguage: existing.detectedLanguage ?? nextNormalized.detectedLanguage,
                audioVariant: existing.audioVariant,
                qualityFlags: "ambient_caption_summary:\(label)",
                batchAudioPath: existing.batchAudioPath ?? nextNormalized.batchAudioPath,
                pendingBatchCount: mergedCount,
                isStatusSummary: true
            )
        case "low_confidence":
            return DashboardLiveAudioRow(
                id: existing.id,
                text: "",
                startedAt: existing.startedAt,
                endedAt: nextNormalized.endedAt,
                source: existing.source,
                confidence: nil,
                transcriptStatus: "probable_junk",
                detectedLanguage: existing.detectedLanguage ?? nextNormalized.detectedLanguage,
                audioVariant: existing.audioVariant,
                qualityFlags: "low_confidence_summary",
                batchAudioPath: existing.batchAudioPath ?? nextNormalized.batchAudioPath,
                pendingBatchCount: mergedCount,
                isLowConfidenceSummary: true
            )
        case "pending":
            return DashboardLiveAudioRow(
                id: existing.id,
                text: "",
                startedAt: existing.startedAt,
                endedAt: nextNormalized.endedAt,
                source: existing.source,
                confidence: nil,
                transcriptStatus: "pending",
                detectedLanguage: nil,
                audioVariant: existing.audioVariant,
                qualityFlags: "pending_summary",
                batchAudioPath: existing.batchAudioPath ?? nextNormalized.batchAudioPath,
                pendingBatchCount: mergedCount,
                isPendingSummary: true
            )
        default:
            return DashboardLiveAudioRow(
                id: existing.id,
                text: "",
                startedAt: existing.startedAt,
                endedAt: nextNormalized.endedAt,
                source: existing.source,
                confidence: nil,
                transcriptStatus: existing.transcriptStatus,
                detectedLanguage: existing.detectedLanguage ?? nextNormalized.detectedLanguage,
                audioVariant: existing.audioVariant,
                qualityFlags: existing.qualityFlags ?? nextNormalized.qualityFlags,
                batchAudioPath: existing.batchAudioPath ?? nextNormalized.batchAudioPath,
                pendingBatchCount: mergedCount,
                isStatusSummary: true
            )
        }
    }

    private static func syntheticPendingSummaryID(for row: DashboardLiveAudioRow) -> Int64 {
        row.id > 0 ? -row.id : row.id
    }

    private static func syntheticLowConfidenceSummaryID(for row: DashboardLiveAudioRow) -> Int64 {
        row.id > 0 ? -(row.id + 1_000_000_000) : row.id - 1_000_000_000
    }

    private static func syntheticStatusSummaryID(for row: DashboardLiveAudioRow) -> Int64 {
        row.id > 0 ? -(row.id + 2_000_000_000) : row.id - 2_000_000_000
    }

    private static func syntheticAmbientSummaryID(for row: DashboardLiveAudioRow) -> Int64 {
        row.id > 0 ? -(row.id + 3_000_000_000) : row.id - 3_000_000_000
    }

    private static func ambientCaption(for row: DashboardLiveAudioRow) -> (signature: String, label: String)? {
        TranscriptPresentationPolicy.ambientCaptionSignature(
            for: row.text,
            transcriptStatus: row.transcriptStatus
        )
    }

    private static func shouldUseAmbientCaptionSummary(for row: DashboardLiveAudioRow) -> Bool {
        row.transcriptStatus == "transcribed" && (row.confidence ?? 1.0) >= 0.5
    }

    private static func normalizedBatchPath(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return path
    }

    private static func rowSortIsAscending(_ lhs: DashboardLiveAudioRow, _ rhs: DashboardLiveAudioRow) -> Bool {
        if lhs.transcriptionPass != rhs.transcriptionPass {
            return lhs.transcriptionPass < rhs.transcriptionPass
        }
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt < rhs.startedAt
        }
        return lhs.id < rhs.id
    }

    private static func rowSortIsDescending(_ lhs: DashboardLiveAudioRow, _ rhs: DashboardLiveAudioRow) -> Bool {
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt > rhs.startedAt
        }
        return lhs.id > rhs.id
    }
}
