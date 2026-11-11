import Foundation
import Shared

/// Explicit workspace moments only. Existing paged/chronological callers keep
/// DataAdapter.search. This stateless service never enables a stopped model.
enum HybridMomentSearch {
    private static let maximumCandidates = 128
    private static let lexicalPageSize = 64
    private static let maximumLexicalPages = 4
    private static let maximumIdentifiers = 4
    private static let maximumSupportingSpans = 64

    static func search(query: SearchQuery, adapter: DataAdapter, evidence: ProgressiveRecallService,
                       semantic: @Sendable (SemanticRecallQuestion) async throws -> SemanticRecallResponse?,
                       revalidate: @Sendable (SemanticRecallReadStamp) async throws -> Void) async throws -> SearchResults {
        let began = ContinuousClock.now
        defer { Log.recordLatency("recall.hybridMomentSearch", valueMs: milliseconds(since: began), category: .app) }
        try Task.checkCancellation()
        await evidence.track(.searched, outcome: "pending", count: 0)
        guard supportsSemantic(query) else {
            // Unsupported constraints retain their existing parser, SQL filters,
            // pagination and source-error behavior. No constraint is ignored.
            return try await adapter.search(query: query)
        }
        let sources = Set(await adapter.registeredSources)
        let before = try await evidence.presentationStamp(sources: sources)
        do {
            let identifiers = exactIdentifierTerms(query.text)
            var candidates: [String: Candidate] = [:]
            var lexicalComplete = true, nextRank = 0
            var unavailable: Set<String> = []
            // Reserve actual identifiers before broader lexical prefix matches
            // can fill the candidate budget; probes still require literal proof.
            let probes = identifiers.map { "\"\($0)\"" } + [query.text]
            for (probeIndex, text) in probes.enumerated() {
                var cursor: SearchPageCursor?
                var pages = 0
                repeat {
                    try Task.checkCancellation()
                    let page = try await adapter.search(query: .init(text: text, filters: query.filters,
                        limit: lexicalPageSize, cursor: cursor, mode: .relevant, sortOrder: query.sortOrder))
                    pages += 1; cursor = page.nextCursor
                    for hit in page.results {
                        try Task.checkCancellation()
                        if candidates.count >= maximumCandidates { lexicalComplete = false; break }
                        let selected: Candidate
                        do {
                            selected = try await lexicalCandidate(hit, identifiers: identifiers,
                                rank: nextRank + 1, adapter: adapter, evidence: evidence)
                        } catch let reason as EvidenceUnavailableReason {
                            switch reason {
                            case .notPermitted, .frameFinalising, .extractionUnavailable:
                                unavailable.insert(hit.sourceQualifiedID); lexicalComplete = false; continue
                            default: throw reason
                            }
                        }
                        if probeIndex < identifiers.count, selected.exactIdentifiers.isEmpty { continue }
                        nextRank += 1
                        let key = selected.result.sourceQualifiedID
                        if let existing = candidates[key] {
                            // Identifier probes are additional lexical discovery,
                            // not independent votes that inflate a repeated hit.
                            if !selected.exactIdentifiers.isEmpty { candidates[key] = existing.withIdentifiers(selected.exactIdentifiers) }
                        } else { candidates[key] = selected }
                    }
                    if candidates.count >= maximumCandidates { lexicalComplete = false; break }
                } while cursor != nil && pages < (probeIndex == identifiers.count ? maximumLexicalPages : 1)
                if cursor != nil { lexicalComplete = false }
                if candidates.count >= maximumCandidates { break }
            }
            // Materialize legacy lexical selections first. New immutable native
            // revisions may invalidate semantic rows; obtain its stamp afterward.
            let range = query.filters.effectiveDateRanges.first
            let filter = SemanticRecallFilter(from: range?.start, through: range?.end,
                appBundleIDs: Array(Set(query.filters.appBundleIDs ?? [])).sorted(),
                excludedAppBundleIDs: Array(Set(query.filters.excludedAppBundleIDs ?? [])).sorted(),
                hiddenFilter: query.filters.hiddenFilter)
            let semanticPage = try await semantic(.init(text: query.text, filter: filter,
                                                        limit: min(100, max(query.limit, 20))))
            try Task.checkCancellation()
            if let semanticPage {
                guard semanticPage.matches.count <= 100 else { throw EvidenceUnavailableReason.integrityFailure }
                for (rank, match) in semanticPage.matches.enumerated() {
                    try Task.checkCancellation()
                    let selected = try await semanticCandidate(match, identifiers: identifiers, rank: rank + 1,
                                                               adapter: adapter, evidence: evidence)
                    let key = selected.result.sourceQualifiedID
                    if let existing = candidates[key] { candidates[key] = existing.merging(selected) }
                    else { candidates[key] = selected }
                }
            }
            let ordered = candidates.values.sorted {
                if $0.exactIdentifiers.isEmpty != $1.exactIdentifiers.isEmpty { return !$0.exactIdentifiers.isEmpty }
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.result.timestamp != $1.result.timestamp { return $0.result.timestamp > $1.result.timestamp }
                return $0.result.sourceQualifiedID < $1.result.sourceQualifiedID
            }
            let selected = ordered.prefix(min(100, query.limit)).map { $0.presented() }
            let coverage = MomentSearchCoverage(nativeSemanticUsed: semanticPage != nil,
                lexicalScanComplete: lexicalComplete, semanticScanComplete: semanticPage?.scanComplete,
                nativeIndexCaughtUp: semanticPage?.coverage.caughtUp,
                indexedObservations: semanticPage?.coverage.completedObservations ?? 0,
                pendingObservations: semanticPage?.coverage.pendingObservations ?? 0,
                skippedObservations: semanticPage?.coverage.skippedObservations ?? 0,
                unavailableLexicalObservations: unavailable.count)
            // Telemetry precedes the final disclosure fences. A metric writer
            // or source swap cannot create a late awaited disclosure gap.
            await evidence.track(.searched, outcome: selected.isEmpty ? "no_results" : "success", count: selected.count)
            guard try await evidence.presentationStamp(sources: sources) == before,
                  Set(await adapter.registeredSources) == sources else { throw SearchPaginationError.dataChanged }
            if let semanticPage { try await revalidate(semanticPage.stamp) }
            guard try await evidence.presentationStamp(sources: sources) == before else { throw SearchPaginationError.dataChanged }
            try Task.checkCancellation()
            // This is a bounded, non-paginated list of moments. Coverage carries
            // incompleteness; totalCount is not an invented corpus-wide count.
            return .init(query: query, results: selected, totalCount: selected.count,
                         searchTimeMs: Int(milliseconds(since: began)), momentCoverage: coverage)
        } catch {
            await evidence.track(.searched, outcome: error is CancellationError ? "cancelled" : "failed", count: 0)
            throw error
        }
    }

    private struct Candidate {
        let result: SearchResult
        let lexicalRank: Int?
        let semanticRank: Int?
        let exactIdentifiers: [String]
        let spans: [SemanticRecallSpan]
        let cosine: Double?
        var score: Double {
            let lexical: Double = lexicalRank.map { 1.0 / (60.0 + Double($0)) } ?? 0.0
            let semantic: Double = semanticRank.map { 1.0 / (60.0 + Double($0)) } ?? 0.0
            return lexical + semantic
        }
        func withIdentifiers(_ extra: [String]) -> Candidate {
            .init(result: result, lexicalRank: lexicalRank, semanticRank: semanticRank,
                  exactIdentifiers: Array(Set(exactIdentifiers + extra)).sorted(), spans: spans, cosine: cosine)
        }
        func merging(_ semantic: Candidate) -> Candidate {
            .init(result: semantic.result, lexicalRank: lexicalRank, semanticRank: semantic.semanticRank,
                  exactIdentifiers: Array(Set(exactIdentifiers + semantic.exactIdentifiers)).sorted(),
                  spans: semantic.spans, cosine: semantic.cosine)
        }
        func presented() -> SearchResult {
            var bases: [SearchMatchExplanation.Basis] = []
            if !exactIdentifiers.isEmpty { bases.append(.exactIdentifier) }
            if lexicalRank != nil { bases.append(.textMatch) }
            if semanticRank != nil { bases.append(.semanticSimilarity) }
            return HybridMomentSearch.copy(result, score: score, explanation: .init(bases: bases,
                exactIdentifiers: exactIdentifiers, supportingSpans: spans, semanticCosine: cosine))
        }
    }

    private static func lexicalCandidate(_ hit: SearchResult, identifiers: [String], rank: Int,
                                         adapter: DataAdapter, evidence: ProgressiveRecallService) async throws -> Candidate {
        let reference = try await evidence.reference(searchResult: hit)
        guard let snapshot = await evidence.retainedScreen(reference, for: .localUser),
              try await evidence.currentRevision(reference) == reference.extractionRevision else {
            throw SearchPaginationError.dataChanged
        }
        let main = snapshot.text?.fullText ?? "", chrome = snapshot.text?.chromeText ?? ""
        let exact = identifiers.filter { exactRange($0, in: main) != nil || exactRange($0, in: chrome) != nil }
        let preferred = exact.first
        let mainRange = preferred.flatMap { exactRange($0, in: main) }
        let chromeRange = preferred.flatMap { exactRange($0, in: chrome) }
        let snippet = chromeRange != nil && mainRange == nil ? excerpt(chrome, around: chromeRange)
            : excerpt(main.isEmpty ? chrome : main, around: mainRange)
        let result = SearchResult(id: hit.id, timestamp: snapshot.frame.timestamp, snippet: snippet, matchedText: snippet,
            relevanceScore: hit.relevanceScore, metadata: snapshot.frame.metadata, segmentID: hit.segmentID,
            videoID: hit.videoID, frameIndex: hit.frameIndex, videoPath: hit.videoPath, videoFrameRate: hit.videoFrameRate,
            source: hit.source, highlightNode: hit.highlightNode, evidenceRef: reference, selectionToken: hit.selectionToken)
        return .init(result: result, lexicalRank: rank, semanticRank: nil, exactIdentifiers: exact, spans: [], cosine: nil)
    }

    private static func semanticCandidate(_ match: SemanticRecallMatch, identifiers: [String], rank: Int,
                                          adapter: DataAdapter, evidence: ProgressiveRecallService) async throws -> Candidate {
        guard match.reference.source == .native, match.reference.blockIDs.isEmpty,
              match.cosine.isFinite, (-1...1).contains(match.cosine),
              !match.spans.isEmpty, match.spans.count <= maximumSupportingSpans,
              match.pageOrdinal >= 0, match.pageOrdinal < 4096, (0..<32).contains(match.windowOrdinal),
              let snapshot = await evidence.retainedScreen(match.reference, for: .localUser),
              try await evidence.currentRevision(match.reference) == match.reference.extractionRevision,
              let current = try await adapter.getFrameWithVideoInfoByID(id: match.reference.frameID, source: .native),
              abs(snapshot.frame.timestamp.timeIntervalSince(match.captureTimestamp)) < 0.001,
              abs(current.frame.timestamp.timeIntervalSince(match.captureTimestamp)) < 0.001 else {
            throw EvidenceUnavailableReason.integrityFailure
        }
        let observation = snapshot.observation
        var excerpts: [String] = []
        var seenFragments: Set<ScreenEvidenceFragmentID> = []
        var retainedUnits = 0
        for span in match.spans {
            guard span.fragmentID.reference == match.reference,
                  seenFragments.insert(span.fragmentID).inserted,
                  span.inputUTF16Range.location >= 0, span.inputUTF16Range.length > 0,
                  span.inputUTF16Range.length == span.sourceUTF16Range.length,
                  span.inputUTF16Range.location <= 4159,
                  span.inputUTF16Range.length <= 4159 - span.inputUTF16Range.location,
                  span.sourceUTF16Range.length <= 4096 - retainedUnits else {
                throw EvidenceUnavailableReason.integrityFailure
            }
            retainedUnits += span.sourceUTF16Range.length
            let channel = span.fragmentID.channel
            let text = channel == .main ? snapshot.text?.fullText ?? "" : snapshot.text?.chromeText ?? ""
            let baseText: String
            let baseStart: Int
            if let blockID = span.fragmentID.blockID {
                guard let block = observation.blocks.first(where: { $0.id == blockID && $0.channel == channel }) else {
                    throw EvidenceUnavailableReason.integrityFailure
                }
                baseText = block.text; baseStart = block.utf16Range.location
                guard span.sourceUTF16Range.location >= baseStart,
                      span.sourceUTF16Range.location - baseStart <= block.utf16Range.length,
                      span.sourceUTF16Range.length <= block.utf16Range.length - (span.sourceUTF16Range.location - baseStart) else {
                    throw EvidenceUnavailableReason.integrityFailure
                }
            } else {
                guard observation.unstructuredText.contains(where: { $0.channel == channel }) else {
                    throw EvidenceUnavailableReason.integrityFailure
                }
                baseText = text; baseStart = 0
            }
            let offset = span.fragmentID.blockUTF8Offset
            guard offset >= 0, offset <= baseText.utf8.count,
                  let boundary = baseText.utf8.index(baseText.utf8.startIndex, offsetBy: offset, limitedBy: baseText.utf8.endIndex),
                  boundary == baseText.utf8.endIndex || baseText.utf8[boundary] & 0xC0 != 0x80 else {
                throw EvidenceUnavailableReason.integrityFailure
            }
            let prefix = String(decoding: baseText.utf8[..<boundary], as: UTF8.self).utf16.count
            guard prefix <= Int.max - baseStart, span.sourceUTF16Range.location >= baseStart + prefix else {
                throw EvidenceUnavailableReason.integrityFailure
            }
            excerpts.append(try slice(text, range: span.sourceUTF16Range))
        }
        let main = snapshot.text?.fullText ?? "", chrome = snapshot.text?.chromeText ?? ""
        let exact = identifiers.filter { exactRange($0, in: main) != nil || exactRange($0, in: chrome) != nil }
        let snippet = excerpt(excerpts[0])
        let frame = current.frame
        let result = SearchResult(id: match.reference.frameID, timestamp: match.captureTimestamp, snippet: snippet,
            matchedText: snippet, relevanceScore: 0, metadata: snapshot.frame.metadata, segmentID: frame.segmentID,
            videoID: frame.videoID, frameIndex: frame.frameIndexInSegment, videoPath: current.videoInfo?.videoPath,
            videoFrameRate: current.videoInfo?.frameRate, source: .native, evidenceRef: match.reference)
        return .init(result: result, lexicalRank: nil, semanticRank: rank, exactIdentifiers: exact,
                     spans: match.spans, cosine: match.cosine)
    }

    private static func supportsSemantic(_ query: SearchQuery) -> Bool {
        guard query.limit > 0, query.offset == 0, query.cursor == nil,
              query.text.utf16.prefix(32_769).count <= 32_768,
              !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.filters.effectiveDateRanges.count <= 1,
              (query.filters.appBundleIDs?.count ?? 0) <= 64,
              (query.filters.excludedAppBundleIDs?.count ?? 0) <= 64,
              query.filters.selectedTagIds?.isEmpty != false, query.filters.excludedTagIds?.isEmpty != false,
              query.filters.commentFilter == .allFrames,
              query.filters.windowNameFilter?.isEmpty != false, query.filters.browserUrlFilter?.isEmpty != false,
              !query.text.contains(where: { "\"“”*:(){}[]".contains($0) }) else { return false }
        return !query.text.split(whereSeparator: \.isWhitespace).contains {
            $0.hasPrefix("-") || ["AND", "OR", "NOT", "NEAR"].contains(String($0))
        }
    }

    private static func exactIdentifierTerms(_ text: String) -> [String] {
        let trim = CharacterSet(charactersIn: ".,!?;()[]{}\"'")
        var values: [String] = []
        for piece in text.split(whereSeparator: \.isWhitespace) {
            let value = String(piece).trimmingCharacters(in: trim)
            guard (2...128).contains(value.utf16.count), value.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains),
                  value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-./@".unicodeScalars.contains($0) }),
                  !values.contains(value) else { continue }
            values.append(value)
            if values.count == maximumIdentifiers { break }
        }
        return values
    }

    private static func exactRange(_ identifier: String, in text: String) -> NSRange? {
        // Punctuation inside an identifier is part of its boundary. A prefix
        // probe such as JOB-123 must not claim JOB-1234 or JOB-123-extra is exact.
        let pattern = "(?<![\\p{L}\\p{N}\\p{M}_./:@-])" + NSRegularExpression.escapedPattern(for: identifier)
            + "(?![\\p{L}\\p{N}\\p{M}_./:@-])"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return expression.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count))?.range
    }

    private static func slice(_ text: String, range: EvidenceUTF16Range) throws -> String {
        let source = text as NSString
        guard range.location >= 0, range.length > 0, range.location <= source.length,
              range.length <= source.length - range.location,
              scalarBoundary(source, range.location), scalarBoundary(source, range.location + range.length) else {
            throw EvidenceUnavailableReason.integrityFailure
        }
        return source.substring(with: NSRange(location: range.location, length: range.length))
    }
    private static func scalarBoundary(_ text: NSString, _ offset: Int) -> Bool {
        offset == 0 || offset == text.length || !(0xDC00...0xDFFF).contains(text.character(at: offset))
    }
    private static func excerpt(_ text: String, around range: NSRange? = nil) -> String {
        let source = text as NSString
        var start = max(0, (range?.location ?? 0) - 48)
        if !scalarBoundary(source, start) { start -= 1 }
        var end = min(source.length, start + 320)
        if !scalarBoundary(source, end) { end -= 1 }
        return source.substring(with: NSRange(location: start, length: max(0, end - start)))
    }
    private static func copy(_ result: SearchResult, score: Double, explanation: SearchMatchExplanation) -> SearchResult {
        .init(id: result.id, timestamp: result.timestamp, snippet: result.snippet, matchedText: result.matchedText,
            relevanceScore: score, metadata: result.metadata, segmentID: result.segmentID, videoID: result.videoID,
            frameIndex: result.frameIndex, videoPath: result.videoPath, videoFrameRate: result.videoFrameRate,
            source: result.source, highlightNode: result.highlightNode, evidenceRef: result.evidenceRef,
            selectionToken: result.selectionToken, matchExplanation: explanation)
    }
    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
}
