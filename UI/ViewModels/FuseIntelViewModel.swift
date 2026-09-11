import Combine
import Foundation
import Shared

struct FuseIntelEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    let data: Value
    let generatedAt: String
    let freshness: String?
    let degraded: Bool
    let warnings: [String]
    let correlationId: String
}

struct FuseIntelSourceRef: Decodable, Equatable, Sendable {
    let source: String
    let sourceId: String?
    let citation: String?
    let capturedAt: String?
    let url: String?

    init(
        source: String,
        sourceId: String? = nil,
        citation: String? = nil,
        capturedAt: String? = nil,
        url: String? = nil
    ) {
        self.source = source
        self.sourceId = sourceId
        self.citation = citation
        self.capturedAt = capturedAt
        self.url = url
    }
}

struct FuseIntelImpact: Decodable, Equatable, Sendable {
    let label: String
    let kind: String
    let valueLow: Double?
    let valueHigh: Double?

    init(
        label: String,
        kind: String,
        valueLow: Double? = nil,
        valueHigh: Double? = nil
    ) {
        self.label = label
        self.kind = kind
        self.valueLow = valueLow
        self.valueHigh = valueHigh
    }
}

struct FuseIntelActionItem: Decodable, Equatable, Sendable {
    let id: String
    let kind: String
    let title: String
    let context: String?
    let status: String?
    let dueAt: String?
    let priority: String
    let impact: FuseIntelImpact?
    let confidence: Double?
    let freshnessAt: String?
    let whyNow: String?
    let suggestedAction: String?
    let sourceRefs: [FuseIntelSourceRef]

    init(
        id: String,
        kind: String,
        title: String,
        context: String? = nil,
        status: String? = nil,
        dueAt: String? = nil,
        priority: String = "medium",
        impact: FuseIntelImpact? = nil,
        confidence: Double? = nil,
        freshnessAt: String? = nil,
        whyNow: String? = nil,
        suggestedAction: String? = nil,
        sourceRefs: [FuseIntelSourceRef] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.context = context
        self.status = status
        self.dueAt = dueAt
        self.priority = priority
        self.impact = impact
        self.confidence = confidence
        self.freshnessAt = freshnessAt
        self.whyNow = whyNow
        self.suggestedAction = suggestedAction
        self.sourceRefs = sourceRefs
    }
}

struct FuseIntelRadarItem: Decodable, Equatable, Sendable {
    let id: String
    let category: String
    let title: String
    let summary: String
    let whyItMatters: String
    let suggestedAction: String?
    let severity: String
    let confidence: Double
    let evidenceState: String
    let freshnessAt: String?
    let sourceRefs: [FuseIntelSourceRef]
}

struct FuseIntelFeedItem: Decodable, Equatable, Sendable {
    let id: String
    let category: String
    let title: String
    let detail: String
    let at: String?
    let labels: [String]
    let sourceRefs: [FuseIntelSourceRef]

    init(
        id: String,
        category: String,
        title: String,
        detail: String,
        at: String? = nil,
        labels: [String] = [],
        sourceRefs: [FuseIntelSourceRef] = []
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
        self.at = at
        self.labels = labels
        self.sourceRefs = sourceRefs
    }
}

struct FuseIntelUpcomingEvent: Decodable, Equatable, Sendable {
    let id: String
    let subject: String
    let start: String?
    let end: String?
    let location: String
    let isOnline: Bool
    let importance: String
    let organizerName: String
    let organizerEmail: String
    let attendeeCount: Int
    let participants: [String]
}

struct FuseIntelThread: Decodable, Equatable, Sendable {
    let threadId: String?
    let subject: String
    let messageCount: Int
    let source: String
    let lastAt: String?

    enum CodingKeys: String, CodingKey {
        case threadId
        case subject
        case messageCount = "msgs"
        case source
        case lastAt = "last"
    }

    init(
        threadId: String? = nil,
        subject: String,
        messageCount: Int,
        source: String,
        lastAt: String? = nil
    ) {
        self.threadId = threadId
        self.subject = subject
        self.messageCount = messageCount
        self.source = source
        self.lastAt = lastAt
    }
}

struct FuseIntelJudgementStatus: Decodable, Equatable, Sendable {
    let inboxDepth: Int
    let oldestAgeSeconds: Double?
    let oldestCreatedAt: String?
    let byKind: [String: Int]
    let items: [FuseIntelActionItem]

    init(
        inboxDepth: Int = 0,
        oldestAgeSeconds: Double? = nil,
        oldestCreatedAt: String? = nil,
        byKind: [String: Int] = [:],
        items: [FuseIntelActionItem] = []
    ) {
        self.inboxDepth = inboxDepth
        self.oldestAgeSeconds = oldestAgeSeconds
        self.oldestCreatedAt = oldestCreatedAt
        self.byKind = byKind
        self.items = items
    }
}

struct FuseIntelSystemSummary: Decodable, Equatable, Sendable {
    let state: String
    let ready: Bool
    let signalCount: Int
    let freshnessAt: String?
    let lastSyncAt: String?
    let alerts: [String]

    init(
        state: String = "unknown",
        ready: Bool = false,
        signalCount: Int = 0,
        freshnessAt: String? = nil,
        lastSyncAt: String? = nil,
        alerts: [String] = []
    ) {
        self.state = state
        self.ready = ready
        self.signalCount = signalCount
        self.freshnessAt = freshnessAt
        self.lastSyncAt = lastSyncAt
        self.alerts = alerts
    }
}

struct FuseIntelCommandResponse: Decodable, Equatable, Sendable {
    let nextMoves: [FuseIntelActionItem]
    let radar: [FuseIntelRadarItem]
    let recentIntel: [FuseIntelFeedItem]
    let waiting: [FuseIntelActionItem]
    let upcoming: [FuseIntelUpcomingEvent]
    let commercialPriorities: [FuseIntelActionItem]
    let businessForesight: [FuseIntelActionItem]
    let delegated: [FuseIntelActionItem]
    let threads: [FuseIntelThread]
    let judgements: FuseIntelJudgementStatus
    let unwiredPanels: [String]
    let system: FuseIntelSystemSummary

    init(
        nextMoves: [FuseIntelActionItem] = [],
        radar: [FuseIntelRadarItem] = [],
        recentIntel: [FuseIntelFeedItem] = [],
        waiting: [FuseIntelActionItem] = [],
        upcoming: [FuseIntelUpcomingEvent] = [],
        commercialPriorities: [FuseIntelActionItem] = [],
        businessForesight: [FuseIntelActionItem] = [],
        delegated: [FuseIntelActionItem] = [],
        threads: [FuseIntelThread] = [],
        judgements: FuseIntelJudgementStatus = FuseIntelJudgementStatus(),
        unwiredPanels: [String] = [],
        system: FuseIntelSystemSummary = FuseIntelSystemSummary()
    ) {
        self.nextMoves = nextMoves
        self.radar = radar
        self.recentIntel = recentIntel
        self.waiting = waiting
        self.upcoming = upcoming
        self.commercialPriorities = commercialPriorities
        self.businessForesight = businessForesight
        self.delegated = delegated
        self.threads = threads
        self.judgements = judgements
        self.unwiredPanels = unwiredPanels
        self.system = system
    }

    enum CodingKeys: String, CodingKey {
        case nextMoves
        case radar
        case recentIntel
        case waiting
        case upcoming
        case commercialPriorities
        case businessForesight
        case delegated
        case threads
        case judgements
        case unwiredPanels
        case system
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nextMoves = try container.decodeIfPresent([FuseIntelActionItem].self, forKey: .nextMoves) ?? []
        radar = try container.decodeIfPresent([FuseIntelRadarItem].self, forKey: .radar) ?? []
        recentIntel = try container.decodeIfPresent([FuseIntelFeedItem].self, forKey: .recentIntel) ?? []
        waiting = try container.decodeIfPresent([FuseIntelActionItem].self, forKey: .waiting) ?? []
        upcoming = try container.decodeIfPresent([FuseIntelUpcomingEvent].self, forKey: .upcoming) ?? []
        commercialPriorities = try container.decodeIfPresent(
            [FuseIntelActionItem].self,
            forKey: .commercialPriorities
        ) ?? []
        businessForesight = try container.decodeIfPresent(
            [FuseIntelActionItem].self,
            forKey: .businessForesight
        ) ?? []
        delegated = try container.decodeIfPresent([FuseIntelActionItem].self, forKey: .delegated) ?? []
        threads = try container.decodeIfPresent([FuseIntelThread].self, forKey: .threads) ?? []
        judgements = try container.decodeIfPresent(
            FuseIntelJudgementStatus.self,
            forKey: .judgements
        ) ?? FuseIntelJudgementStatus()
        unwiredPanels = try container.decodeIfPresent([String].self, forKey: .unwiredPanels) ?? []
        system = try container.decodeIfPresent(
            FuseIntelSystemSummary.self,
            forKey: .system
        ) ?? FuseIntelSystemSummary()
    }
}

struct FuseIntelSnapshot: Sendable {
    let commandEnvelope: FuseIntelEnvelope<FuseIntelCommandResponse>
    let feedEnvelope: FuseIntelEnvelope<[FuseIntelFeedItem]>
}

enum FuseIntelClientError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "FuseIntel returned an invalid response."
        case .httpStatus(let status):
            return "FuseIntel returned HTTP \(status)."
        }
    }
}

enum FuseIntelRefreshPolicy {
    static let requestTimeout: TimeInterval = 30
    static let resourceTimeout: TimeInterval = 45
    static let successRefreshInterval: TimeInterval = 300
    static let failureRetryInterval: TimeInterval = 60
    static let extendedFailureRetryInterval: TimeInterval = 300
    static let maximumFailureRetryInterval: TimeInterval = 900

    static func retryInterval(consecutiveFailures: Int) -> TimeInterval {
        switch consecutiveFailures {
        case ...1:
            return failureRetryInterval
        case 2:
            return extendedFailureRetryInterval
        default:
            return maximumFailureRetryInterval
        }
    }

    static func shouldRefresh(
        force: Bool,
        isLoading: Bool,
        lastAttemptAt: Date?,
        lastSuccessAt: Date?,
        consecutiveFailures: Int = 0,
        now: Date
    ) -> Bool {
        guard !isLoading else { return false }
        if force { return true }
        if let lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < successRefreshInterval {
            return false
        }
        if let lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < retryInterval(consecutiveFailures: consecutiveFailures) {
            return false
        }
        return true
    }
}

actor FuseIntelClient {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:9010")!

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = defaultBaseURL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = FuseIntelRefreshPolicy.requestTimeout
            configuration.timeoutIntervalForResource = FuseIntelRefreshPolicy.resourceTimeout
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func fetchSnapshot() async throws -> FuseIntelSnapshot {
        let command: FuseIntelEnvelope<FuseIntelCommandResponse> = try await fetch(
            path: "/api/command",
            queryItems: [URLQueryItem(name: "recent_hours", value: "24")]
        )

        // The command view already includes recentIntel. Avoid polling the wider
        // feed query because it can monopolize the local single-worker BFF.
        let feed = FuseIntelEnvelope<[FuseIntelFeedItem]>(
            data: [],
            generatedAt: command.generatedAt,
            freshness: command.freshness,
            degraded: command.degraded,
            warnings: [],
            correlationId: "\(command.correlationId):command-only"
        )
        return FuseIntelSnapshot(commandEnvelope: command, feedEnvelope: feed)
    }

    private func fetch<Value: Decodable & Sendable>(
        path: String,
        queryItems: [URLQueryItem]
    ) async throws -> FuseIntelEnvelope<Value> {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw FuseIntelClientError.invalidResponse
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw FuseIntelClientError.invalidResponse
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FuseIntelClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw FuseIntelClientError.httpStatus(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(FuseIntelEnvelope<Value>.self, from: data)
    }
}

@MainActor
final class FuseIntelViewModel: ObservableObject {
    @Published private(set) var snapshot: FuseIntelSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdatedAt: Date?

    let baseURL: URL
    private let client: FuseIntelClient
    private var lastAttemptAt: Date?
    private var consecutiveFailures = 0

    init(
        baseURL: URL = FuseIntelClient.defaultBaseURL,
        client: FuseIntelClient? = nil
    ) {
        self.baseURL = baseURL
        self.client = client ?? FuseIntelClient(baseURL: baseURL)
    }

    var command: FuseIntelCommandResponse? { snapshot?.commandEnvelope.data }
    var feed: [FuseIntelFeedItem] { snapshot?.feedEnvelope.data ?? [] }
    var warnings: [String] {
        (snapshot?.commandEnvelope.warnings ?? []) + (snapshot?.feedEnvelope.warnings ?? [])
    }

    /// A last-good snapshot remains useful when a refresh fails; the UI labels it stale.
    var isConnected: Bool { snapshot != nil }

    var freshnessDate: Date? {
        FuseIntelDateParser.date(
            from: snapshot?.commandEnvelope.freshness
                ?? snapshot?.commandEnvelope.data.system.freshnessAt
        )
    }

    func refresh(force: Bool = false) async {
        let now = Date()
        guard FuseIntelRefreshPolicy.shouldRefresh(
            force: force,
            isLoading: isLoading,
            lastAttemptAt: lastAttemptAt,
            lastSuccessAt: lastUpdatedAt,
            consecutiveFailures: consecutiveFailures,
            now: now
        ) else { return }
        lastAttemptAt = now
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await client.fetchSnapshot()
            guard !Task.isCancelled else { return }
            snapshot = result
            errorMessage = nil
            lastUpdatedAt = Date()
            consecutiveFailures = 0
        } catch is CancellationError {
            return
        } catch {
            consecutiveFailures += 1
            errorMessage = error.localizedDescription
            Log.warning("[FuseIntel] Dashboard BFF unavailable: \(error.localizedDescription)", category: .ui)
        }
    }
}

struct RetraceActivityMoment: Equatable, Sendable {
    let timestamp: Date
    let appName: String
    let windowTitle: String?
    let browserURL: String?
    let isSelfCapture: Bool

    init(
        timestamp: Date,
        appName: String,
        windowTitle: String?,
        browserURL: String?,
        isSelfCapture: Bool = false
    ) {
        self.timestamp = timestamp
        self.appName = appName
        self.windowTitle = windowTitle
        self.browserURL = browserURL
        self.isSelfCapture = isSelfCapture
    }
}

struct RetraceSpeechMoment: Equatable, Sendable {
    let startedAt: Date
    let endedAt: Date
    let text: String
}

struct RetraceActivityBrief: Equatable, Sendable {
    let headline: String
    let summary: String
    let currentApp: String?
    let primaryApp: String?
    let appTrail: [String]
    let focusTerms: [String]
    let contextText: String
    let capturedMomentCount: Int
    let speechSegmentCount: Int
    let appSwitchCount: Int
    let startedAt: Date?
    let endedAt: Date?

    var duration: TimeInterval {
        guard let startedAt, let endedAt else { return 0 }
        return max(endedAt.timeIntervalSince(startedAt), 0)
    }
}

enum RetraceActivityBriefPolicy {
    static let maximumMoments = 24
    static let maximumSpeechSegments = 8
    static let maximumContextCharacters = 6_000

    private static let stopWords: Set<String> = [
        "about", "actually", "after", "again", "alright", "also", "anything", "backintime",
        "because", "been", "before", "being", "between", "bond", "codex", "could",
        "current", "dashboard", "from", "good", "going", "have", "here", "into", "just",
        "know", "like", "live", "maybe", "microsoft", "more", "need", "okay", "only",
        "other", "outlook", "really", "retrace", "right", "should", "some", "stuart",
        "swift", "than", "thank", "thanks", "that", "their", "them", "then", "there",
        "these", "they", "thing", "things", "this", "those", "transcript", "very", "want",
        "well", "what", "when", "where", "which", "while", "window", "with", "working",
        "would", "yeah", "your"
    ]

    static func make(
        moments: [RetraceActivityMoment],
        speech: [RetraceSpeechMoment]
    ) -> RetraceActivityBrief {
        let orderedMoments = Array(
            moments
                .filter { !$0.isSelfCapture }
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(maximumMoments)
        )
        let orderedSpeech = Array(speech.sorted { $0.endedAt > $1.endedAt }.prefix(maximumSpeechSegments))
        let currentMoment = orderedMoments.first
        let currentApp = nonEmpty(currentMoment?.appName)
        let currentWindow = nonEmpty(currentMoment?.windowTitle)
        let appTrail = uniqueApps(from: orderedMoments)
        let primaryApp = dominantApp(in: orderedMoments)
        let timestamps = orderedMoments.map(\.timestamp)
            + orderedSpeech.flatMap { [$0.startedAt, $0.endedAt] }
        let startedAt = timestamps.min()
        let endedAt = timestamps.max()
        let appSwitchCount = switchCount(in: orderedMoments)

        var contextParts: [String] = []
        for moment in orderedMoments {
            if let appName = nonEmpty(moment.appName) { contextParts.append(appName) }
            if let windowTitle = nonEmpty(moment.windowTitle) { contextParts.append(windowTitle) }
            if let browserURL = nonEmpty(moment.browserURL) { contextParts.append(browserURL) }
        }
        for speechMoment in orderedSpeech {
            let text = speechMoment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { contextParts.append(String(text.prefix(600))) }
        }
        let contextText = String(contextParts.joined(separator: " ").prefix(maximumContextCharacters))
        let focusText = orderedMoments.flatMap { moment in
            [nonEmpty(moment.windowTitle), nonEmpty(moment.browserURL)].compactMap { $0 }
        } + orderedSpeech.map(\.text)
        let excludedFocusTerms = Set(appTrail.flatMap(tokenize))
        let focusTerms = rankedTerms(
            in: focusText.joined(separator: " "),
            excluding: excludedFocusTerms
        )

        let headline = currentWindow ?? currentApp.map { "Working in \($0)" }
            ?? (orderedSpeech.isEmpty ? "Waiting for recent activity" : "Recent spoken context")
        let summary = summary(
            currentApp: currentApp,
            primaryApp: primaryApp,
            appTrail: appTrail,
            focusTerms: focusTerms,
            duration: duration(from: startedAt, to: endedAt),
            hasSpeech: !orderedSpeech.isEmpty
        )

        return RetraceActivityBrief(
            headline: headline,
            summary: summary,
            currentApp: currentApp,
            primaryApp: primaryApp,
            appTrail: appTrail,
            focusTerms: focusTerms,
            contextText: contextText,
            capturedMomentCount: orderedMoments.count,
            speechSegmentCount: orderedSpeech.count,
            appSwitchCount: appSwitchCount,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    private static func summary(
        currentApp: String?,
        primaryApp: String?,
        appTrail: [String],
        focusTerms: [String],
        duration: TimeInterval,
        hasSpeech: Bool
    ) -> String {
        guard currentApp != nil || hasSpeech else {
            return "Retrace is ready to describe the next captured work sequence."
        }

        var parts: [String] = []
        if let primaryApp {
            let span = durationLabel(duration)
            if let span {
                parts.append("\(primaryApp) has been the main workspace across \(span)")
            } else {
                parts.append("\(primaryApp) has been the main workspace")
            }
        } else if hasSpeech {
            parts.append("Recent audio is available even though no readable screen moment is loaded")
        }

        let supportingApps = appTrail.filter { $0 != primaryApp }.prefix(2)
        if !supportingApps.isEmpty {
            parts.append("Recent movement also includes \(supportingApps.joined(separator: " and "))")
        }

        let usefulTerms = focusTerms.prefix(3)
        if !usefulTerms.isEmpty {
            parts.append("The captured context is centred on \(usefulTerms.joined(separator: ", "))")
        }
        return parts.joined(separator: ". ") + "."
    }

    private static func uniqueApps(from moments: [RetraceActivityMoment]) -> [String] {
        var seen = Set<String>()
        return moments.compactMap { moment in
            guard let app = nonEmpty(moment.appName), seen.insert(app.lowercased()).inserted else {
                return nil
            }
            return app
        }
    }

    private static func dominantApp(in moments: [RetraceActivityMoment]) -> String? {
        var counts: [String: (name: String, count: Int, latest: Date)] = [:]
        for moment in moments {
            guard let name = nonEmpty(moment.appName) else { continue }
            let key = name.lowercased()
            let existing = counts[key]
            counts[key] = (
                name: name,
                count: (existing?.count ?? 0) + 1,
                latest: max(existing?.latest ?? .distantPast, moment.timestamp)
            )
        }
        return counts.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.latest > $1.latest
        }.first?.name
    }

    private static func switchCount(in moments: [RetraceActivityMoment]) -> Int {
        let chronologicalApps = moments.sorted { $0.timestamp < $1.timestamp }
            .compactMap { nonEmpty($0.appName)?.lowercased() }
        guard chronologicalApps.count > 1 else { return 0 }
        return zip(chronologicalApps, chronologicalApps.dropFirst())
            .filter { pair in pair.0 != pair.1 }
            .count
    }

    private static func rankedTerms(in text: String, excluding excludedTerms: Set<String>) -> [String] {
        var counts: [String: Int] = [:]
        for term in tokenize(text)
            .filter({ $0.count >= 4 && !stopWords.contains($0) && !excludedTerms.contains($0) }) {
            counts[term, default: 0] += 1
        }
        return counts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            if $0.key.count != $1.key.count { return $0.key.count > $1.key.count }
            return $0.key < $1.key
        }
        .prefix(8)
        .map(\.key)
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static func duration(from start: Date?, to end: Date?) -> TimeInterval {
        guard let start, let end else { return 0 }
        return max(end.timeIntervalSince(start), 0)
    }

    private static func durationLabel(_ duration: TimeInterval) -> String? {
        guard duration >= 60 else { return nil }
        if duration < 3_600 {
            return "\(max(Int(duration / 60), 1)) min"
        }
        let hours = Int(duration / 3_600)
        let minutes = Int(duration.truncatingRemainder(dividingBy: 3_600) / 60)
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

enum FuseIntelSection: String, CaseIterable, Identifiable {
    case now
    case signals
    case upcoming

    var id: String { rawValue }

    var title: String {
        switch self {
        case .now: return "Brief"
        case .signals: return "Signals"
        case .upcoming: return "Ahead"
        }
    }
}

enum FuseIntelRelevance: Equatable, Sendable {
    case contextMatch
    case acrossWork
}

enum FuseIntelDisplayKind: String, Sendable {
    case move
    case commercial
    case foresight
    case radar
    case signal
    case upcoming
    case waiting
    case delegated
    case judgement
    case thread
}

struct FuseIntelDisplayItem: Identifiable, Equatable, Sendable {
    let id: String
    let kind: FuseIntelDisplayKind
    let title: String
    let detail: String
    let eyebrow: String
    let priority: String
    let timestamp: Date?
    let confidence: Double?
    let evidenceState: String?
    let sourceRefs: [FuseIntelSourceRef]
    let relevance: FuseIntelRelevance
    let matchedTerms: [String]
    let matchScore: Int
    let suggestedAction: String?
    let impactLabel: String?
}

enum FuseIntelPresentationPolicy {
    private static let stopWords: Set<String> = [
        "about", "after", "again", "also", "because", "been", "before", "being",
        "between", "bond", "codex", "could", "dashboard", "from", "have", "into", "just",
        "live", "microsoft", "more", "need", "only", "other", "outlook", "retrace", "should",
        "some", "stuart", "than", "that", "their", "them", "then", "there", "these", "they",
        "this", "those", "transcript", "very", "want", "what", "when", "where", "which",
        "while", "window", "with", "working", "would", "your"
    ]

    static func items(
        command: FuseIntelCommandResponse?,
        feed: [FuseIntelFeedItem],
        section: FuseIntelSection,
        contextText: String
    ) -> [FuseIntelDisplayItem] {
        let contextTerms = keywords(in: contextText)
        var baseItems: [FuseIntelDisplayItem] = []

        switch section {
        case .now:
            baseItems.append(contentsOf: (command?.nextMoves ?? []).map { action in
                makeAction(action, kind: .move, eyebrow: "Next move", contextTerms: contextTerms)
            })
            baseItems.append(contentsOf: (command?.commercialPriorities ?? []).map { action in
                makeAction(action, kind: .commercial, eyebrow: "Commercial priority", contextTerms: contextTerms)
            })
            baseItems.append(contentsOf: (command?.businessForesight ?? []).map { action in
                makeAction(action, kind: .foresight, eyebrow: "Business foresight", contextTerms: contextTerms)
            })
            baseItems.append(contentsOf: (command?.radar ?? []).map { radar in
                makeRadar(radar, contextTerms: contextTerms)
            })
            baseItems.append(contentsOf: (command?.threads ?? []).map { thread in
                makeThread(thread, contextTerms: contextTerms)
            })
        case .signals:
            var seen = Set<String>()
            let combined = (command?.recentIntel ?? []) + feed
            baseItems.append(contentsOf: combined.compactMap { item in
                guard seen.insert(item.id).inserted else { return nil }
                return makeSignal(item, contextTerms: contextTerms)
            })
            baseItems.append(contentsOf: (command?.radar ?? []).map { radar in
                makeRadar(radar, contextTerms: contextTerms)
            })
            baseItems.append(contentsOf: (command?.businessForesight ?? []).map { action in
                makeAction(action, kind: .foresight, eyebrow: "Business foresight", contextTerms: contextTerms)
            })
        case .upcoming:
            baseItems.append(contentsOf: (command?.upcoming ?? []).map { event in
                makeUpcoming(event, contextTerms: contextTerms)
            })
            baseItems.append(contentsOf: (command?.waiting ?? []).map { action in
                makeAction(action, kind: .waiting, eyebrow: "Waiting on you", contextTerms: contextTerms)
            })
            baseItems.append(contentsOf: (command?.delegated ?? []).map { action in
                makeAction(action, kind: .delegated, eyebrow: "Delegated", contextTerms: contextTerms)
            })
            baseItems.append(contentsOf: (command?.judgements.items ?? []).map { action in
                makeAction(action, kind: .judgement, eyebrow: "Decision needed", contextTerms: contextTerms)
            })
        }

        return deduplicated(baseItems).sorted { lhs, rhs in
            let lhsContext = lhs.relevance == .contextMatch ? 1 : 0
            let rhsContext = rhs.relevance == .contextMatch ? 1 : 0
            if lhsContext != rhsContext { return lhsContext > rhsContext }

            if lhs.matchScore != rhs.matchScore { return lhs.matchScore > rhs.matchScore }

            let lhsPriority = priorityWeight(lhs.priority)
            let rhsPriority = priorityWeight(rhs.priority)
            if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }

            return (lhs.timestamp ?? .distantPast) > (rhs.timestamp ?? .distantPast)
        }
    }

    private static func makeAction(
        _ action: FuseIntelActionItem,
        kind: FuseIntelDisplayKind,
        eyebrow: String,
        contextTerms: Set<String>
    ) -> FuseIntelDisplayItem {
        let detail = action.whyNow
            ?? action.suggestedAction
            ?? action.context
            ?? "Source-backed action from FuseIntel."
        return displayItem(
            id: "\(kind.rawValue):\(action.id)",
            kind: kind,
            title: action.title,
            detail: detail,
            eyebrow: eyebrow,
            priority: action.priority,
            timestamp: FuseIntelDateParser.date(from: action.dueAt ?? action.freshnessAt),
            confidence: action.confidence,
            evidenceState: nil,
            sourceRefs: action.sourceRefs,
            matchText: [action.title, action.context, action.whyNow, action.suggestedAction]
                .compactMap { $0 }
                .joined(separator: " "),
            suggestedAction: action.suggestedAction,
            impactLabel: action.impact?.label,
            contextTerms: contextTerms
        )
    }

    private static func makeRadar(
        _ radar: FuseIntelRadarItem,
        contextTerms: Set<String>
    ) -> FuseIntelDisplayItem {
        displayItem(
            id: "radar:\(radar.id)",
            kind: .radar,
            title: radar.title,
            detail: [radar.summary, radar.whyItMatters]
                .filter { !$0.isEmpty }
                .joined(separator: " · "),
            eyebrow: radar.category.replacingOccurrences(of: "_", with: " ").capitalized,
            priority: radar.severity,
            timestamp: FuseIntelDateParser.date(from: radar.freshnessAt),
            confidence: radar.confidence,
            evidenceState: radar.evidenceState,
            sourceRefs: radar.sourceRefs,
            matchText: [radar.title, radar.summary, radar.whyItMatters, radar.suggestedAction]
                .compactMap { $0 }
                .joined(separator: " "),
            suggestedAction: radar.suggestedAction,
            impactLabel: nil,
            contextTerms: contextTerms
        )
    }

    private static func makeSignal(
        _ signal: FuseIntelFeedItem,
        contextTerms: Set<String>
    ) -> FuseIntelDisplayItem {
        displayItem(
            id: "signal:\(signal.id)",
            kind: .signal,
            title: signal.title,
            detail: signal.detail,
            eyebrow: signal.category.replacingOccurrences(of: "_", with: " ").capitalized,
            priority: "medium",
            timestamp: FuseIntelDateParser.date(from: signal.at),
            confidence: nil,
            evidenceState: nil,
            sourceRefs: signal.sourceRefs,
            matchText: signal.title + " " + signal.detail + " " + signal.labels.joined(separator: " "),
            suggestedAction: nil,
            impactLabel: nil,
            contextTerms: contextTerms
        )
    }

    private static func makeUpcoming(
        _ event: FuseIntelUpcomingEvent,
        contextTerms: Set<String>
    ) -> FuseIntelDisplayItem {
        let detailParts = [
            event.organizerName.isEmpty ? nil : event.organizerName,
            event.location.isEmpty ? nil : event.location,
            event.attendeeCount > 0 ? "\(event.attendeeCount) attendees" : nil
        ].compactMap { $0 }
        return displayItem(
            id: "upcoming:\(event.id)",
            kind: .upcoming,
            title: event.subject,
            detail: detailParts.isEmpty ? "Upcoming calendar event" : detailParts.joined(separator: " · "),
            eyebrow: event.isOnline ? "Online meeting" : "Calendar",
            priority: event.importance == "high" ? "high" : "medium",
            timestamp: FuseIntelDateParser.date(from: event.start),
            confidence: nil,
            evidenceState: "verified",
            sourceRefs: [FuseIntelSourceRef(source: "outlook_calendar", citation: event.id)],
            matchText: [event.subject, event.organizerName, event.organizerEmail]
                .filter { !$0.isEmpty }
                .joined(separator: " ") + " " + event.participants.joined(separator: " "),
            suggestedAction: nil,
            impactLabel: nil,
            contextTerms: contextTerms
        )
    }

    private static func makeThread(
        _ thread: FuseIntelThread,
        contextTerms: Set<String>
    ) -> FuseIntelDisplayItem {
        let messageLabel = thread.messageCount == 1 ? "1 message" : "\(thread.messageCount) messages"
        return displayItem(
            id: "thread:\(thread.threadId ?? thread.subject)",
            kind: .thread,
            title: thread.subject,
            detail: "\(messageLabel) in this active pursuit thread.",
            eyebrow: "Pursuit thread",
            priority: "medium",
            timestamp: FuseIntelDateParser.date(from: thread.lastAt),
            confidence: nil,
            evidenceState: "verified",
            sourceRefs: [FuseIntelSourceRef(
                source: thread.source,
                citation: thread.threadId ?? thread.subject,
                capturedAt: thread.lastAt
            )],
            matchText: thread.subject,
            suggestedAction: nil,
            impactLabel: nil,
            contextTerms: contextTerms
        )
    }

    private static func displayItem(
        id: String,
        kind: FuseIntelDisplayKind,
        title: String,
        detail: String,
        eyebrow: String,
        priority: String,
        timestamp: Date?,
        confidence: Double?,
        evidenceState: String?,
        sourceRefs: [FuseIntelSourceRef],
        matchText: String,
        suggestedAction: String?,
        impactLabel: String?,
        contextTerms: Set<String>
    ) -> FuseIntelDisplayItem {
        let itemTerms = keywords(in: matchText)
        let matches = contextTerms.intersection(itemTerms).sorted()
        let titleMatches = contextTerms.intersection(keywords(in: title)).count
        let matchScore = (titleMatches * 4) + matches.count
        return FuseIntelDisplayItem(
            id: id,
            kind: kind,
            title: title,
            detail: detail,
            eyebrow: eyebrow,
            priority: priority,
            timestamp: timestamp,
            confidence: confidence,
            evidenceState: evidenceState,
            sourceRefs: sourceRefs,
            relevance: matches.isEmpty ? .acrossWork : .contextMatch,
            matchedTerms: matches,
            matchScore: matchScore,
            suggestedAction: suggestedAction,
            impactLabel: impactLabel
        )
    }

    private static func deduplicated(_ items: [FuseIntelDisplayItem]) -> [FuseIntelDisplayItem] {
        var seen = Set<String>()
        return items.filter { item in
            let signature = keywords(in: item.title).sorted().joined(separator: "|")
            return seen.insert(signature.isEmpty ? item.id : signature).inserted
        }
    }

    private static func keywords(in text: String) -> Set<String> {
        Set(text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 && !stopWords.contains($0) })
    }

    private static func priorityWeight(_ priority: String) -> Int {
        switch priority.lowercased() {
        case "critical": return 4
        case "high": return 3
        case "medium": return 2
        case "low": return 1
        default: return 0
        }
    }
}

struct FuseIntelPresentationSnapshot: Equatable, Sendable {
    static let empty = FuseIntelPresentationSnapshot(
        nowItems: [],
        signalItems: [],
        upcomingItems: [],
        contextItems: []
    )

    let nowItems: [FuseIntelDisplayItem]
    let signalItems: [FuseIntelDisplayItem]
    let upcomingItems: [FuseIntelDisplayItem]
    let contextItems: [FuseIntelDisplayItem]

    var contextMatchCount: Int { contextItems.count }

    func items(for section: FuseIntelSection) -> [FuseIntelDisplayItem] {
        switch section {
        case .now: return nowItems
        case .signals: return signalItems
        case .upcoming: return upcomingItems
        }
    }
}

enum FuseIntelPresentationSnapshotPolicy {
    static func make(
        command: FuseIntelCommandResponse?,
        feed: [FuseIntelFeedItem],
        contextText: String
    ) -> FuseIntelPresentationSnapshot {
        let nowItems = FuseIntelPresentationPolicy.items(
            command: command,
            feed: feed,
            section: .now,
            contextText: contextText
        )
        let signalItems = FuseIntelPresentationPolicy.items(
            command: command,
            feed: feed,
            section: .signals,
            contextText: contextText
        )
        let upcomingItems = FuseIntelPresentationPolicy.items(
            command: command,
            feed: feed,
            section: .upcoming,
            contextText: contextText
        )

        var seenContextIDs = Set<String>()
        let contextItems = (nowItems + signalItems + upcomingItems)
            .filter { $0.relevance == .contextMatch }
            .filter { seenContextIDs.insert($0.id).inserted }

        return FuseIntelPresentationSnapshot(
            nowItems: nowItems,
            signalItems: signalItems,
            upcomingItems: upcomingItems,
            contextItems: contextItems
        )
    }
}

struct FuseIntelOperatingBrief: Equatable, Sendable {
    let recommendation: FuseIntelDisplayItem?
    let connectedContext: [FuseIntelDisplayItem]
    let broaderPriorities: [FuseIntelDisplayItem]

    var evidenceItemCount: Int {
        (recommendation == nil ? 0 : 1) + connectedContext.count + broaderPriorities.count
    }
}

enum FuseIntelOperatingBriefPolicy {
    static let maximumConnectedItems = 2
    static let maximumBroaderPriorities = 3

    static func make(from items: [FuseIntelDisplayItem]) -> FuseIntelOperatingBrief {
        let evidenceBacked = items.filter { !$0.sourceRefs.isEmpty }
        let recommendation = evidenceBacked.first(where: { $0.relevance == .contextMatch })
            ?? evidenceBacked.first
        let remaining = evidenceBacked.filter { $0.id != recommendation?.id }
        let connected = Array(
            remaining
                .filter { $0.relevance == .contextMatch }
                .prefix(maximumConnectedItems)
        )
        let connectedIDs = Set(connected.map(\.id))
        let broader = Array(
            remaining
                .filter { !connectedIDs.contains($0.id) }
                .prefix(maximumBroaderPriorities)
        )
        return FuseIntelOperatingBrief(
            recommendation: recommendation,
            connectedContext: connected,
            broaderPriorities: broader
        )
    }
}

enum FuseIntelDateParser {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let standardFormatter = ISO8601DateFormatter()

    static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return fractionalFormatter.date(from: value) ?? standardFormatter.date(from: value)
    }
}
