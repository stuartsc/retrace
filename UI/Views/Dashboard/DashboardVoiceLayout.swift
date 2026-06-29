import Foundation
import CoreGraphics
import Shared

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
            return "Live transcript, intelligence feed, and conversation context"
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
    static let columnSpacing: CGFloat = 14

    static func contentMode(forWidth width: CGFloat) -> DashboardLiveContentMode {
        width >= minThreeColumnWidth ? .threeColumn : .stacked
    }

    static func columnWidths(forWidth width: CGFloat) -> DashboardLiveColumnWidths {
        let usableWidth = max(width - (columnSpacing * 2), 0)
        return DashboardLiveColumnWidths(
            transcript: usableWidth * 0.31,
            intelligence: usableWidth * 0.46,
            context: usableWidth * 0.23
        )
    }
}

struct DashboardLiveIntelligenceCard: Identifiable, Equatable {
    let id: String
    let title: String
    let badge: String?
    let detail: String
    let bullets: [String]
    let iconName: String
    let accentName: String

    init(
        id: String,
        title: String,
        badge: String? = nil,
        detail: String,
        bullets: [String] = [],
        iconName: String,
        accentName: String
    ) {
        self.id = id
        self.title = title
        self.badge = badge
        self.detail = detail
        self.bullets = bullets
        self.iconName = iconName
        self.accentName = accentName
    }
}

enum DashboardLiveIntelligencePolicy {
    static let defaultCards: [DashboardLiveIntelligenceCard] = [
        DashboardLiveIntelligenceCard(
            id: "people",
            title: "Key people mentioned",
            badge: "NEW",
            detail: "Names, roles, and teams detected from live speech will appear here.",
            iconName: "person.2.fill",
            accentName: "violet"
        ),
        DashboardLiveIntelligenceCard(
            id: "company",
            title: "Company context",
            detail: "FuseIntel can attach CRM, email, notes, and prior meeting context.",
            iconName: "building.2.fill",
            accentName: "blue"
        ),
        DashboardLiveIntelligenceCard(
            id: "talking-points",
            title: "Suggested talking points",
            detail: "Keep the conversation moving with timely prompts.",
            bullets: [
                "Clarify scope, decision owner, and timing.",
                "Confirm the pain point in the user's own words.",
                "Ask what success must look like after rollout."
            ],
            iconName: "lightbulb.fill",
            accentName: "pink"
        ),
        DashboardLiveIntelligenceCard(
            id: "risks",
            title: "Risks & objections",
            detail: "Budget, implementation effort, unclear ownership, and integration risk.",
            iconName: "exclamationmark.triangle.fill",
            accentName: "red"
        ),
        DashboardLiveIntelligenceCard(
            id: "background",
            title: "Relevant background",
            detail: "Prior decisions, related documents, and searchable memory will be surfaced here.",
            iconName: "book.closed.fill",
            accentName: "indigo"
        ),
        DashboardLiveIntelligenceCard(
            id: "actions",
            title: "Action items forming",
            detail: "Commitments and next steps are tracked as they emerge.",
            bullets: [
                "Capture owner, due date, and dependency.",
                "Separate confirmed actions from possible follow-ups."
            ],
            iconName: "checkmark.circle.fill",
            accentName: "teal"
        ),
        DashboardLiveIntelligenceCard(
            id: "questions",
            title: "Questions to ask now",
            detail: "Useful questions based on what was just said.",
            bullets: [
                "What needs to be true before this moves forward?",
                "Who else needs to be involved in the decision?"
            ],
            iconName: "questionmark.circle.fill",
            accentName: "amber"
        )
    ]
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

    static func retainedCacheIDs(
        preferredIDs: [Int64],
        selectedID: Int64?,
        maxCount: Int
    ) -> Set<Int64> {
        guard maxCount > 0 else { return [] }

        var retained: [Int64] = []
        var seen = Set<Int64>()

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
    static func shouldShowHistory(readableRowCount: Int, canLoadMoreOlderRows: Bool, isLoadingOlderRows: Bool) -> Bool {
        readableRowCount > 0 || canLoadMoreOlderRows || isLoadingOlderRows
    }

    static func shouldPrefetchMoreReadableRows(
        readableRowCount: Int,
        targetReadableRowCount: Int,
        fetchedTranscriptRows: Int,
        pageSize: Int,
        canLoadMoreOlderRows: Bool
    ) -> Bool {
        guard readableRowCount < targetReadableRowCount else { return false }
        guard canLoadMoreOlderRows else { return false }
        return fetchedTranscriptRows >= pageSize
    }

    static func shouldAutoLoadOlderRows(
        currentRowID: Int64,
        lastRowID: Int64?,
        canLoadMoreOlderRows: Bool,
        isLoadingOlderRows: Bool
    ) -> Bool {
        guard canLoadMoreOlderRows && !isLoadingOlderRows else { return false }
        return currentRowID == lastRowID
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

struct DashboardLiveAudioRow: Identifiable, Equatable {
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
        guard hasCaptionWrapper else { return false }

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

struct DashboardLiveAudioPresentation: Equatable {
    let transcriptRows: [DashboardLiveAudioRow]
    let statusRows: [DashboardLiveAudioRow]
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
