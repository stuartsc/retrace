import CryptoKit
import Foundation
import Shared

/// Explicit bounded local history search. Screen discovery keeps its current
/// parser/ranking route; V30 receives only bounded literal terms. No media,
/// model, bootstrap worker or agent disclosure is activated here.
public enum HistoryMomentSearch {
    private static let maximumResults = 100
    private static let maximumAudioResults = 50
    private static let maximumScreenTextUnits = 262_144
    private static let maximumExcerptUnits = 512
    private static let maximumAudioPageBytes = 262_144

    public static func search(query: SearchQuery, adapter: DataAdapter, evidence: ProgressiveRecallService,
                              screenSearch: @Sendable (SearchQuery) async throws -> SearchResults,
                              audioHistory: (any AudioEvidenceStoreProtocol)?) async throws -> HistorySearchResults {
        let started = ContinuousClock.now
        defer { Log.recordLatency("recall.historySearch", valueMs: milliseconds(since: started), category: .app) }
        try validateQuery(query)
        try Task.checkCancellation()
        do {
            let querySHA256 = try fingerprint(query)
            let sources = Set(await adapter.registeredSources)
            let presentation = try await evidence.presentationStamp(sources: sources).fingerprintSHA256()
            let screenPage = try await screenSearch(query)
            try Task.checkCancellation()
            guard try fingerprint(screenPage.query) == querySHA256,
                  screenPage.results.count <= query.limit else { throw SearchPaginationError.dataChanged }
            var screens: [HistoryScreenSearchHit] = []
            var unavailableScreenHits = 0
            for result in screenPage.results {
                try Task.checkCancellation()
                do { screens.append(try await makeScreen(result, evidence: evidence)) }
                catch let reason as EvidenceUnavailableReason {
                    switch reason {
                    case .notPermitted, .frameFinalising, .extractionUnavailable:
                        unavailableScreenHits += 1
                    default: throw reason
                    }
                }
            }
            guard Set(screens.map { $0.result.sourceQualifiedID }).count == screens.count else {
                throw SearchPaginationError.dataChanged
            }

            var audioPage: AudioEvidenceSearchPage?
            let audioState: HistoryAudioSearchState
            if let audioHistory {
                switch literalTerms(query.text) {
                case .unsupported: audioState = .unsupportedQuerySyntax
                case .tooLarge: audioState = .queryExceedsAudioLimits
                case .terms(let terms):
                    let page = try await audioHistory.searchAudioEvidence(.init(terms: terms, filters: query.filters,
                        limit: min(maximumAudioResults, query.limit), maximumInspectedRows: 512))
                    try Task.checkCancellation()
                    try validateAudioPage(page, limit: min(maximumAudioResults, query.limit))
                    audioPage = page
                    audioState = page.unavailableReason.map(HistoryAudioSearchState.unavailable) ?? .searched
                }
            } else { audioState = .notConfigured }

            let audios = audioPage?.hits ?? []
            let ordered = merged(screens: screens, audios: audios)
            let selected = Array(ordered.prefix(query.limit))
            let screenCount = selected.reduce(0) { count, hit in if case .screen = hit { return count + 1 }; return count }
            let audioCount = selected.count - screenCount
            let screenComplete = screenPage.momentCoverage.map {
                $0.lexicalScanComplete && ($0.semanticScanComplete ?? true)
            } ?? !screenPage.hasMore
            let coverage = HistorySearchCoverage(screen: screenPage.momentCoverage,
                screenCandidateScanComplete: screenComplete && unavailableScreenHits == 0,
                unavailableScreenHits: unavailableScreenHits, audio: audioPage?.coverage, audioState: audioState,
                screenHitsOmittedByLimit: screens.count - screenCount, audioHitsOmittedByLimit: audios.count - audioCount)
            let stamp = HistorySearchReadStamp(querySHA256: querySHA256,
                screenSources: sources.sorted { $0.rawValue < $1.rawValue },
                screenPresentationSHA256: presentation, audio: audioPage?.stamp)
            let page = HistorySearchResults(query: query, results: selected, coverage: coverage,
                readStamp: stamp, searchTimeMs: Int(milliseconds(since: started)))
            // This is an awaited attempt, not a delivery-success receipt. A
            // mutation while metrics suspend must still fail final admission.
            await evidence.track(.historySearched, outcome: "pending", count: selected.count)
            try await validateBatch(page, adapter: adapter, evidence: evidence, audioHistory: audioHistory)
            try Task.checkCancellation()
            return .init(query: page.query, results: page.results, coverage: page.coverage,
                         readStamp: page.readStamp, searchTimeMs: Int(milliseconds(since: started)))
        } catch {
            await evidence.track(.historySearched, outcome: error is CancellationError ? "cancelled" : "failed", count: 0)
            if error is CancellationError { throw CancellationError() }
            if error is AudioEvidenceError || error is EvidenceUnavailableReason { throw SearchPaginationError.dataChanged }
            throw error
        }
    }

    /// Refresh the complete cached batch against its current local source and
    /// policy identities and exact canonical text. Changed batches are rejected
    /// together; no nearby frame, new transcript revision or old snippet is used.
    public static func revalidate(_ results: HistorySearchResults, adapter: DataAdapter,
                                  evidence: ProgressiveRecallService,
                                  audioHistory: (any AudioEvidenceStoreProtocol)?) async throws {
        let started = ContinuousClock.now
        defer { Log.recordLatency("recall.historyRevalidate", valueMs: milliseconds(since: started), category: .app) }
        try Task.checkCancellation()
        do {
            await evidence.track(.historyRevalidated, outcome: "pending", count: min(maximumResults, results.results.count))
            try await validateBatch(results, adapter: adapter, evidence: evidence, audioHistory: audioHistory)
            try Task.checkCancellation()
        } catch {
            await evidence.track(.historyRevalidated, outcome: error is CancellationError ? "cancelled" : "failed", count: 0)
            if error is CancellationError { throw CancellationError() }
            throw SearchPaginationError.dataChanged
        }
    }

    private static func validateBatch(_ page: HistorySearchResults, adapter: DataAdapter,
                                      evidence: ProgressiveRecallService,
                                      audioHistory: (any AudioEvidenceStoreProtocol)?) async throws {
        try validateQuery(page.query)
        try Task.checkCancellation()
        guard try fingerprint(page.query) == page.readStamp.querySHA256,
              page.results.count <= page.query.limit,
              Set(page.results.map(\.id)).count == page.results.count,
              Set(page.readStamp.screenSources).count == page.readStamp.screenSources.count,
              page.readStamp.screenSources == page.readStamp.screenSources.sorted(by: { $0.rawValue < $1.rawValue }),
              page.coverage.unavailableScreenHits >= 0, page.coverage.screenHitsOmittedByLimit >= 0,
              page.coverage.audioHitsOmittedByLimit >= 0 else { throw SearchPaginationError.dataChanged }
        try await validatePresentation(page.readStamp, adapter: adapter, evidence: evidence)
        var audioReferences: [AudioEvidenceRef] = []
        var audioBytes = 0
        for hit in page.results {
            try Task.checkCancellation()
            switch hit {
            case .screen(let screen):
                guard page.readStamp.screenSources.contains(screen.reference.source),
                      screen.result.evidenceRef == screen.reference else { throw SearchPaginationError.dataChanged }
                let snapshot = try await readScreen(screen.result, evidence: evidence)
                try validateScreen(screen, snapshot: snapshot)
            case .audio(let audio):
                guard let audioHistory, let stamp = page.readStamp.audio,
                      page.coverage.audioState == .searched,
                      audio.snapshot.reference.storeID == stamp.storeID,
                      audioReferences.count < maximumAudioResults else { throw SearchPaginationError.dataChanged }
                guard case .available(let canonical, let current) = try await audioHistory.readAudioEvidence(audio.snapshot.reference),
                      current == stamp, sameAudio(audio.snapshot, canonical) else { throw SearchPaginationError.dataChanged }
                try validateAudioHit(audio)
                audioBytes += canonical.text.utf8.count
                guard audioBytes <= maximumAudioPageBytes else { throw SearchPaginationError.dataChanged }
                audioReferences.append(canonical.reference)
            }
        }
        if case .searched = page.coverage.audioState, page.readStamp.audio == nil { throw SearchPaginationError.dataChanged }
        // Separate screen/import and transcript stores have no joint SQLite
        // transaction. These repeated, monotonic read identities provide an
        // optimistic batch fence; the receipt is not a continuing privacy lease.
        // No callbacks/metrics follow the last fences, only cancellation checks.
        try await validatePresentation(page.readStamp, adapter: adapter, evidence: evidence)
        if let stamp = page.readStamp.audio {
            guard let audioHistory else { throw SearchPaginationError.dataChanged }
            try await audioHistory.revalidateAudioEvidence(stamp, references: audioReferences)
        }
        try await validatePresentation(page.readStamp, adapter: adapter, evidence: evidence)
        try Task.checkCancellation()
    }

    private static func validatePresentation(_ stamp: HistorySearchReadStamp, adapter: DataAdapter,
                                             evidence: ProgressiveRecallService) async throws {
        let sources = Set(stamp.screenSources)
        guard Set(await adapter.registeredSources) == sources else { throw SearchPaginationError.dataChanged }
        let current = try await evidence.presentationStamp(sources: sources).fingerprintSHA256()
        guard current == stamp.screenPresentationSHA256 else { throw SearchPaginationError.dataChanged }
        try Task.checkCancellation()
    }

    private static func makeScreen(_ result: SearchResult, evidence: ProgressiveRecallService) async throws -> HistoryScreenSearchHit {
        let snapshot = try await readScreen(result, evidence: evidence)
        let main = snapshot.text?.fullText ?? "", chrome = snapshot.text?.chromeText ?? ""
        let channel: EvidenceTextChannel
        let range: EvidenceUTF16Range
        let text: String
        let candidates = [result.snippet, result.matchedText].filter { !$0.isEmpty && $0.utf16.count <= maximumExcerptUnits }
        var preferred: (EvidenceTextChannel, NSRange)?
        for candidate in candidates {
            for (candidateChannel, source) in [(EvidenceTextChannel.main, main), (.chrome, chrome)] {
                let found = (source as NSString).range(of: candidate, options: .literal)
                if found.location != NSNotFound { preferred = (candidateChannel, found); break }
            }
            if preferred != nil { break }
        }
        channel = preferred?.0 ?? (main.isEmpty ? .chrome : .main)
        let source = channel == .main ? main : chrome
        let excerpt = try boundedExcerpt(source, around: preferred?.1)
        range = excerpt.range; text = excerpt.text
        let ref = snapshot.ref
        let copied = SearchResult(id: result.id, timestamp: snapshot.frame.timestamp, snippet: text, matchedText: text,
            relevanceScore: result.relevanceScore, metadata: snapshot.frame.metadata, segmentID: result.segmentID,
            videoID: result.videoID, frameIndex: result.frameIndex, videoPath: result.videoPath,
            videoFrameRate: result.videoFrameRate, source: result.source,
            highlightNode: snapshot.highlightsVerified ? result.highlightNode : nil,
            evidenceRef: ref, selectionToken: result.selectionToken, matchExplanation: result.matchExplanation)
        let hit = HistoryScreenSearchHit(result: copied, excerpt: .init(reference: ref, channel: channel,
            utf16Range: range, text: text, provenance: snapshot.observation.provenance))
        try validateScreen(hit, snapshot: snapshot)
        return hit
    }

    private static func readScreen(_ result: SearchResult, evidence: ProgressiveRecallService) async throws -> ScreenEvidenceSnapshot {
        let ref = try await evidence.reference(searchResult: result)
        guard let snapshot = await evidence.retainedScreen(ref, for: .localUser),
              try await evidence.currentRevision(ref) == ref.extractionRevision else { throw SearchPaginationError.dataChanged }
        guard (snapshot.text?.fullText.utf16.prefix(maximumScreenTextUnits + 1).count ?? 0) <= maximumScreenTextUnits,
              (snapshot.text?.chromeText.utf16.prefix(maximumScreenTextUnits + 1).count ?? 0) <= maximumScreenTextUnits else {
            throw EvidenceUnavailableReason.extractionUnavailable
        }
        try Task.checkCancellation()
        return snapshot
    }

    private static func validateScreen(_ hit: HistoryScreenSearchHit, snapshot: ScreenEvidenceSnapshot) throws {
        guard hit.reference == snapshot.ref, hit.result.evidenceRef == snapshot.ref,
              hit.result.id == snapshot.ref.frameID, hit.result.source == snapshot.ref.source,
              hit.result.timestamp == snapshot.frame.timestamp, hit.result.metadata == snapshot.frame.metadata,
              hit.excerpt.provenance == snapshot.observation.provenance,
              hit.result.snippet.utf16.elementsEqual(hit.excerpt.text.utf16),
              hit.result.matchedText.utf16.elementsEqual(hit.excerpt.text.utf16) else { throw SearchPaginationError.dataChanged }
        let main = snapshot.text?.fullText ?? "", chrome = snapshot.text?.chromeText ?? ""
        try validateSlice(hit.excerpt.text, range: hit.excerpt.utf16Range, source: hit.excerpt.channel == .main ? main : chrome)
        if let explanation = hit.result.matchExplanation, explanation.bases.contains(.exactIdentifier) {
            guard !explanation.exactIdentifiers.isEmpty, explanation.exactIdentifiers.count <= 4,
                  explanation.exactIdentifiers.allSatisfy({ exactIdentifier($0, occursIn: main) || exactIdentifier($0, occursIn: chrome) }) else {
                throw SearchPaginationError.dataChanged
            }
        }
    }

    private static func validateAudioPage(_ page: AudioEvidenceSearchPage, limit: Int) throws {
        guard page.hits.count <= limit, page.hits.count <= maximumAudioResults,
              page.unavailableReason == nil || page.hits.isEmpty,
              page.stamp != nil || page.hits.isEmpty,
              Set(page.hits.map { $0.snapshot.reference }).count == page.hits.count else { throw SearchPaginationError.dataChanged }
        var total = 0
        for hit in page.hits {
            guard hit.snapshot.reference.storeID == page.stamp?.storeID else { throw SearchPaginationError.dataChanged }
            try validateAudioHit(hit)
            total += hit.snapshot.text.utf8.count
            guard total <= maximumAudioPageBytes else { throw SearchPaginationError.dataChanged }
        }
    }

    private static func validateAudioHit(_ hit: AudioEvidenceSearchHit) throws {
        let ref = hit.snapshot.reference
        guard ref.source == .native, ref.transcriptRevision > 0, UUID(uuidString: ref.segmentID) != nil,
              ref.startTime.isFinite, ref.endTime.isFinite, ref.endTime > ref.startTime,
              hit.excerpt.reference == ref, hit.snapshot.text.utf8.count <= 65_536,
              hit.snapshot.mediaAvailability == .notVerified, hit.snapshot.provenance == .declaredOriginalSource else {
            throw SearchPaginationError.dataChanged
        }
        try validateSlice(hit.excerpt.text, range: hit.excerpt.utf16Range, source: hit.snapshot.text)
    }

    private static func sameAudio(_ lhs: AudioEvidenceSnapshot, _ rhs: AudioEvidenceSnapshot) -> Bool {
        lhs.reference == rhs.reference && lhs.recordingID == rhs.recordingID && lhs.recordingSource == rhs.recordingSource
            && lhs.recordingStartedAt == rhs.recordingStartedAt && lhs.recordingEndedAt == rhs.recordingEndedAt
            && lhs.text.utf8.elementsEqual(rhs.text.utf8) && lhs.transcriptStatus == rhs.transcriptStatus
            && lhs.transcriptionPass == rhs.transcriptionPass && lhs.detectedLanguage == rhs.detectedLanguage
            && lhs.audioVariant == rhs.audioVariant && lhs.confidence == rhs.confidence
            && lhs.provenance == rhs.provenance && lhs.mediaAvailability == rhs.mediaAvailability
    }

    private static func validateSlice(_ text: String, range: EvidenceUTF16Range, source: String) throws {
        let string = source as NSString
        guard range.location >= 0, (1...maximumExcerptUnits).contains(range.length),
              range.location <= string.length, range.length <= string.length - range.location,
              scalarBoundary(string, range.location), scalarBoundary(string, range.location + range.length),
              string.substring(with: NSRange(location: range.location, length: range.length)).utf16.elementsEqual(text.utf16) else {
            throw SearchPaginationError.dataChanged
        }
    }

    private static func boundedExcerpt(_ text: String, around range: NSRange?) throws -> (range: EvidenceUTF16Range, text: String) {
        let string = text as NSString
        guard string.length > 0 else { throw EvidenceUnavailableReason.extractionUnavailable }
        var start = max(0, (range?.location ?? 0) - 48)
        start = string.rangeOfComposedCharacterSequence(at: start).location
        var end = min(string.length, start + maximumExcerptUnits)
        if end < string.length {
            let cluster = string.rangeOfComposedCharacterSequence(at: end)
            if cluster.location < end { end = cluster.location }
        }
        guard end > start else { throw EvidenceUnavailableReason.extractionUnavailable }
        let result = EvidenceUTF16Range(location: start, length: end - start)
        return (result, string.substring(with: NSRange(location: result.location, length: result.length)))
    }

    private static func scalarBoundary(_ string: NSString, _ offset: Int) -> Bool {
        offset == 0 || offset == string.length || !(0xDC00...0xDFFF).contains(string.character(at: offset))
    }

    private static func exactIdentifier(_ identifier: String, occursIn text: String) -> Bool {
        guard (2...128).contains(identifier.utf16.count) else { return false }
        let boundary = "[\\p{L}\\p{N}\\p{M}_./:@-]"
        let pattern = "(?<!" + boundary + ")" + NSRegularExpression.escapedPattern(for: identifier) + "(?!" + boundary + ")"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
    }

    private static func merged(screens: [HistoryScreenSearchHit], audios: [AudioEvidenceSearchHit]) -> [HistorySearchHit] {
        let exact = screens.filter { $0.result.matchExplanation?.bases.contains(.exactIdentifier) == true }
        let other = screens.filter { $0.result.matchExplanation?.bases.contains(.exactIdentifier) != true }
        var result = exact.map(HistorySearchHit.screen)
        var screenIndex = 0, audioIndex = 0
        var audioTurn = !exact.isEmpty
        while screenIndex < other.count || audioIndex < audios.count {
            if audioTurn && audioIndex < audios.count || screenIndex == other.count {
                result.append(.audio(audios[audioIndex])); audioIndex += 1
            } else if screenIndex < other.count {
                result.append(.screen(other[screenIndex])); screenIndex += 1
            }
            audioTurn.toggle()
        }
        return result
    }

    private enum LiteralInput { case terms([String]), unsupported, tooLarge }
    private static func literalTerms(_ text: String) -> LiteralInput {
        // Recognition only: no FTS operators or another query language parser.
        // The unchanged screen route handles all existing advanced syntax.
        guard !text.contains(where: { "\"“”*:(){}[]".contains($0) }) else { return .unsupported }
        let pieces = text.split(whereSeparator: \.isWhitespace)
        guard !pieces.contains(where: { $0.hasPrefix("-") || ["AND", "OR", "NOT", "NEAR"].contains(String($0)) }) else {
            return .unsupported
        }
        guard pieces.count <= 16, pieces.allSatisfy({ $0.utf8.count <= 256 }) else { return .tooLarge }
        return .terms(pieces.map(String.init))
    }

    private static func validateQuery(_ query: SearchQuery) throws {
        guard query.mode == .relevant, query.offset == 0, query.cursor == nil,
              (1...maximumResults).contains(query.limit), !query.text.contains("\0"),
              !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.text.utf16.prefix(32_769).count <= 32_768 else {
            throw SearchError.invalidQuery(reason: "History moments require a bounded relevance query without a page cursor")
        }
    }
    private static func fingerprint(_ query: SearchQuery) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(query)).map { String(format: "%02x", $0) }.joined()
    }
    private static func milliseconds(since started: ContinuousClock.Instant) -> Double {
        let value = started.duration(to: .now).components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
}
