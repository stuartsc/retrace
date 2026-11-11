import Foundation

/// Source-only provenance. This proves no app ownership, capture-time exclusion
/// policy, consent event, speech accuracy or verified media bytes.
public enum AudioEvidenceProvenance: String, Codable, Sendable { case declaredOriginalSource }
public enum AudioEvidenceMediaAvailability: String, Codable, Sendable { case notVerified }

public struct AudioEvidenceSnapshot: Codable, Sendable {
    /// segmentID is a canonical transcript-observation UUID; times are absolute
    /// Unix seconds copied from the original declared SQLite millisecond values.
    /// transcriptRevision is an immutable row revision, never a refinement pass.
    public let reference: AudioEvidenceRef
    public let recordingID: UUID
    public let recordingSource: AudioSource
    public let recordingStartedAt: Date
    public let recordingEndedAt: Date
    public let text: String
    public let transcriptStatus: String
    public let transcriptionPass: Int
    public let detectedLanguage: String?
    public let audioVariant: String
    public let confidence: Double?
    public let provenance: AudioEvidenceProvenance
    public let mediaAvailability: AudioEvidenceMediaAvailability
    public var startTime: Date { Date(timeIntervalSince1970: reference.startTime) }
    public var endTime: Date { Date(timeIntervalSince1970: reference.endTime) }

    public init(reference: AudioEvidenceRef, recordingID: UUID, recordingSource: AudioSource,
        recordingStartedAt: Date, recordingEndedAt: Date, text: String, transcriptStatus: String,
        transcriptionPass: Int, detectedLanguage: String?, audioVariant: String, confidence: Double?) {
        self.reference = reference; self.recordingID = recordingID; self.recordingSource = recordingSource
        self.recordingStartedAt = recordingStartedAt; self.recordingEndedAt = recordingEndedAt
        self.text = text; self.transcriptStatus = transcriptStatus; self.transcriptionPass = transcriptionPass
        self.detectedLanguage = detectedLanguage; self.audioVariant = audioVariant; self.confidence = confidence
        self.provenance = .declaredOriginalSource; self.mediaAvailability = .notVerified
    }
}

/// Ephemeral read identity, not a disclosure/permission capability. App owns the
/// independent local-read policy and source epoch before presenting any content.
public struct AudioEvidenceReadStamp: Hashable, Sendable {
    public let storeID: UUID
    public let readerID: UUID
    public let mutationRevision: Int64
    public init(storeID: UUID, readerID: UUID, mutationRevision: Int64) {
        self.storeID = storeID; self.readerID = readerID; self.mutationRevision = mutationRevision
    }
}

public enum AudioEvidenceUnavailableReason: String, Codable, Sendable {
    case notNative, sourceMismatch, evidenceMissing, evidenceDeleted, revisionUnavailable
    case lineageUnavailable, lineageConflicting, mediaUnregistered, unavailableQuality, invalidTiming, oversizedText
    case unsupportedApplicationScope, unsupportedWindowScope, unsupportedURLScope
    case unsupportedTagScope, unsupportedCommentScope, unsupportedHiddenScope, unsupportedDateScope
    case unattestedCapturePolicy, integrityFailure, budgetExceeded, sourceClosed
}

public enum AudioEvidenceError: String, Error, Sendable {
    case invalidRequest, dataChanged, readerClosed, connectionBusy, unsupportedConnection, integrityFailure
}

public enum AudioEvidenceReadResult: Sendable {
    case available(AudioEvidenceSnapshot, AudioEvidenceReadStamp)
    case unavailable(AudioEvidenceUnavailableReason)
}

/// Database authorization only. Storage must independently verify every byte
/// and acquire a reader lease before playback; App revalidates this stamp.
public enum AudioEvidenceMediaReadResult: Sendable {
    case available(StoredAudioWindow, AudioEvidenceSnapshot, AudioEvidenceReadStamp)
    case unavailable(AudioEvidenceUnavailableReason)
}

public struct AudioEvidenceBootstrapProgress: Equatable, Sendable {
    public let historicalBoundary: Int64
    public let throughRowID: Int64
    public let complete: Bool
    /// Rows inspected by this maintenance call, not total historic coverage.
    public let inspectedRows: Int
    public init(historicalBoundary: Int64, throughRowID: Int64, complete: Bool, inspectedRows: Int = 0) {
        self.historicalBoundary = historicalBoundary; self.throughRowID = throughRowID
        self.complete = complete; self.inspectedRows = inspectedRows
    }
}

public struct AudioEvidenceCoverage: Sendable {
    public enum Scope: String, Sendable { case provenNativeTranscripts }
    public let scope: Scope
    public let bootstrap: AudioEvidenceBootstrapProgress
    /// These counts describe only this bounded read, never all retained history.
    public let inspectedRows: Int
    public let availableRows: Int
    public let unprovenLineageRows: Int
    public let unavailableQualityRows: Int
    public let unmaterializedRows: Int
    public let scanComplete: Bool
    public init(bootstrap: AudioEvidenceBootstrapProgress, inspectedRows: Int = 0,
        availableRows: Int = 0, unprovenLineageRows: Int = 0, unavailableQualityRows: Int = 0,
        unmaterializedRows: Int = 0, scanComplete: Bool = false) {
        self.scope = .provenNativeTranscripts; self.bootstrap = bootstrap
        self.inspectedRows = inspectedRows; self.availableRows = availableRows
        self.unprovenLineageRows = unprovenLineageRows; self.unavailableQualityRows = unavailableQualityRows
        self.unmaterializedRows = unmaterializedRows; self.scanComplete = scanComplete
    }
}

/// A bounded excerpt in exact UTF16 coordinates of this immutable transcript.
/// Its sentence interval is seekable only after independent media verification;
/// text ranges do not manufacture word-level audio timing.
public struct AudioEvidenceTextSpan: Sendable {
    public let reference: AudioEvidenceRef
    public let utf16Range: EvidenceUTF16Range
    public let text: String
    public init(reference: AudioEvidenceRef, utf16Range: EvidenceUTF16Range, text: String) {
        self.reference = reference; self.utf16Range = utf16Range; self.text = text
    }
}

public struct AudioEvidenceSearchHit: Sendable {
    public let snapshot: AudioEvidenceSnapshot
    public let excerpt: AudioEvidenceTextSpan
    public init(snapshot: AudioEvidenceSnapshot, excerpt: AudioEvidenceTextSpan) {
        self.snapshot = snapshot; self.excerpt = excerpt
    }
}

/// Cursor for one reader lifetime, exact query/filter fingerprint and mutation
/// revision. It is not persisted across process restart and grants no access.
public struct AudioEvidenceSearchCursor: Equatable, Sendable {
    public let stamp: AudioEvidenceReadStamp
    public let querySHA256: String
    public let beforeRowID: Int64
    public init(stamp: AudioEvidenceReadStamp, querySHA256: String, beforeRowID: Int64) {
        self.stamp = stamp; self.querySHA256 = querySHA256; self.beforeRowID = beforeRowID
    }
}

public struct AudioEvidenceSearchRequest: Sendable {
    /// Literal FTS terms/phrases, joined with AND; never raw SQL/FTS operators.
    /// Empty terms permits a bounded browse. Raw query parsing remains in App.
    public let terms: [String]
    public let filters: SearchFilters
    /// Empty means every supported, proven declared original recording source.
    public let recordingSources: [AudioSource]
    public let limit: Int
    public let maximumInspectedRows: Int
    public let cursor: AudioEvidenceSearchCursor?
    public let requiresCapturePolicyAttestation: Bool
    public init(terms: [String], filters: SearchFilters = .none, recordingSources: [AudioSource] = [],
        limit: Int = 20, maximumInspectedRows: Int = 512, cursor: AudioEvidenceSearchCursor? = nil,
        requiresCapturePolicyAttestation: Bool = false) {
        self.terms = terms; self.filters = filters; self.recordingSources = recordingSources
        self.limit = limit; self.maximumInspectedRows = maximumInspectedRows; self.cursor = cursor
        self.requiresCapturePolicyAttestation = requiresCapturePolicyAttestation
    }
}

public struct AudioEvidenceSearchPage: Sendable {
    public let hits: [AudioEvidenceSearchHit]
    public let stamp: AudioEvidenceReadStamp?
    public let nextCursor: AudioEvidenceSearchCursor?
    public let coverage: AudioEvidenceCoverage
    public let unavailableReason: AudioEvidenceUnavailableReason?
    public init(hits: [AudioEvidenceSearchHit], stamp: AudioEvidenceReadStamp?,
        nextCursor: AudioEvidenceSearchCursor?, coverage: AudioEvidenceCoverage,
        unavailableReason: AudioEvidenceUnavailableReason? = nil) {
        self.hits = hits; self.stamp = stamp; self.nextCursor = nextCursor
        self.coverage = coverage; self.unavailableReason = unavailableReason
    }
}
