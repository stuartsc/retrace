import Foundation

/// Exact copied source characters. A channel range does not invent OCR geometry
/// or ownership; legacy provenance remains legacyUnknown.
public struct HistoryScreenTextSpan: Sendable {
    public let reference: ScreenEvidenceRef
    public let channel: EvidenceTextChannel
    public let utf16Range: EvidenceUTF16Range
    public let text: String
    public let provenance: EvidenceExtractionProvenance
    public init(reference: ScreenEvidenceRef, channel: EvidenceTextChannel,
                utf16Range: EvidenceUTF16Range, text: String, provenance: EvidenceExtractionProvenance) {
        self.reference = reference; self.channel = channel; self.utf16Range = utf16Range
        self.text = text; self.provenance = provenance
    }
}

public struct HistoryScreenSearchHit: Sendable {
    public let result: SearchResult
    public let excerpt: HistoryScreenTextSpan
    public var reference: ScreenEvidenceRef { excerpt.reference }
    public init(result: SearchResult, excerpt: HistoryScreenTextSpan) {
        self.result = result; self.excerpt = excerpt
    }
}

/// Each channel retains its own ordering; no comparable cross-source score or
/// semantic-audio match is implied. Transcript row order is publication order,
/// not necessarily capture chronology. Screen match bases remain on SearchResult.
public enum HistorySearchRankBasis: String, Sendable {
    case existingScreenOrder, transcriptTextAndRowOrder
}

public enum HistorySearchHit: Identifiable, Sendable {
    case screen(HistoryScreenSearchHit)
    case audio(AudioEvidenceSearchHit)

    public var reference: EvidenceRef {
        switch self {
        case .screen(let hit): return .screen(hit.reference)
        case .audio(let hit): return .audio(hit.snapshot.reference)
        }
    }
    public var id: String {
        switch self {
        case .screen(let hit): return "screen:\(hit.result.sourceQualifiedID)"
        case .audio(let hit):
            let ref = hit.snapshot.reference
            return "audio:\(ref.source.rawValue):\(ref.storeID.uuidString):\(ref.segmentID)"
        }
    }
    public var timestamp: Date {
        switch self {
        case .screen(let hit): return hit.result.timestamp
        case .audio(let hit): return hit.snapshot.startTime
        }
    }
    public var rankBasis: HistorySearchRankBasis {
        switch self {
        case .screen: return .existingScreenOrder
        case .audio: return .transcriptTextAndRowOrder
        }
    }
}

public enum HistoryAudioSearchState: Equatable, Sendable {
    case searched
    case notConfigured
    case unsupportedQuerySyntax
    case queryExceedsAudioLimits
    case unavailable(AudioEvidenceUnavailableReason)
}

/// Coverage is channel-specific. Activity/jobs, semantic audio, imported audio
/// and verified media are not searched by this slice. A finished candidate scan
/// is never an assertion that all retained history was admitted or indexed.
public struct HistorySearchCoverage: Sendable {
    public let screen: MomentSearchCoverage?
    public let screenCandidateScanComplete: Bool
    public let unavailableScreenHits: Int
    public let audio: AudioEvidenceCoverage?
    public let audioState: HistoryAudioSearchState
    public let screenHitsOmittedByLimit: Int
    public let audioHitsOmittedByLimit: Int
    public init(screen: MomentSearchCoverage?, screenCandidateScanComplete: Bool,
                unavailableScreenHits: Int, audio: AudioEvidenceCoverage?, audioState: HistoryAudioSearchState,
                screenHitsOmittedByLimit: Int, audioHitsOmittedByLimit: Int) {
        self.screen = screen; self.screenCandidateScanComplete = screenCandidateScanComplete
        self.unavailableScreenHits = unavailableScreenHits; self.audio = audio; self.audioState = audioState
        self.screenHitsOmittedByLimit = screenHitsOmittedByLimit; self.audioHitsOmittedByLimit = audioHitsOmittedByLimit
    }
}

/// Ephemeral equality receipt for this exact query and read. The digest binds
/// current App policy and screen source/mutation identities without exposing
/// policy-rule strings. Audio retains its separate native reader/store stamp.
/// Neither this value nor captured content grants source, agent or media access.
public struct HistorySearchReadStamp: Equatable, Sendable {
    public let querySHA256: String
    public let screenSources: [FrameSource]
    public let screenPresentationSHA256: String
    public let audio: AudioEvidenceReadStamp?
    public init(querySHA256: String, screenSources: [FrameSource], screenPresentationSHA256: String,
                audio: AudioEvidenceReadStamp?) {
        self.querySHA256 = querySHA256; self.screenSources = screenSources
        self.screenPresentationSHA256 = screenPresentationSHA256; self.audio = audio
    }
}

/// One bounded, explicit search. Exact screen identifiers keep precedence;
/// remaining screen and transcript results interleave while retaining each
/// channel's order. No merged pagination token or corpus-wide total is invented.
public struct HistorySearchResults: Sendable {
    public let query: SearchQuery
    public let results: [HistorySearchHit]
    public let coverage: HistorySearchCoverage
    public let readStamp: HistorySearchReadStamp
    public let searchTimeMs: Int
    public var isEmpty: Bool { results.isEmpty }
    public init(query: SearchQuery, results: [HistorySearchHit], coverage: HistorySearchCoverage,
                readStamp: HistorySearchReadStamp, searchTimeMs: Int) {
        self.query = query; self.results = results; self.coverage = coverage
        self.readStamp = readStamp; self.searchTimeMs = searchTimeMs
    }
}
