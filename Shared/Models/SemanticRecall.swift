import Foundation

/// A semantic index is a local derivative of currently permitted native screen
/// evidence. It is neither an evidence admission grant nor a model download job.
public struct SemanticRecallTransformation: Codable, Equatable, Sendable {
    public let identifier: String
    public let fingerprintSHA256: String
    public let runtimeTransformSHA256: String
    public let modelRevision: String
    public let modelPackageSHA256: String
    public let tokenizerSHA256: String
    public let dimensions: Int

    public static let miniLMNativeV1 = SemanticRecallTransformation(
        identifier: "retrace.native-screen.minilm.float32.v1",
        fingerprintSHA256: "aa66ed4648ac1a84436726ec43c9278ccde3b78c1a91148e17037a1c6a99308e",
        runtimeTransformSHA256: "266a80a756948759e1818406797949566dda34fd16dd16987d36544bf10b42e5",
        modelRevision: "1110a243fdf4706b3f48f1d95db1a4f5529b4d41",
        modelPackageSHA256: "d3806da4c9148f87ef92f5054d4fbc74875589ce5ee81640d65c7813d7a17779",
        tokenizerSHA256: "be50c3628f2bf5bb5e3a7f17b1f74611b2561a3a27eeab05e5aa30f411572037",
        dimensions: 384)
}

public enum SemanticRecallError: String, Error, Codable, Sendable {
    case unsupportedTransformation, invalidLimits, invalidCursor, cursorExpired
    case attemptInProgress, invalidClaim, claimExpired, claimCancelled
    case sourceChanged, conflictingResult, invalidVector, invalidSpan, incompleteWindows
    case staleRead, capacityExceeded, integrityFailure
}

public struct SemanticRecallCursor: Codable, Equatable, Sendable {
    public let indexID: UUID
    public let feedID: UUID
    public let storeID: UUID
    public let leaseID: UUID
    public init(indexID: UUID, feedID: UUID, storeID: UUID, leaseID: UUID) {
        self.indexID = indexID; self.feedID = feedID; self.storeID = storeID; self.leaseID = leaseID
    }
}

public enum SemanticRecallLane: String, Codable, Sendable { case fresh, backfill }

public struct SemanticRecallClaim: Codable, Equatable, Sendable {
    public let attemptID: UUID
    public let cursor: SemanticRecallCursor
    public let transformation: SemanticRecallTransformation
    public let policy: ScreenEvidencePolicyTransition
    public let reference: ScreenEvidenceRef
    public let lane: SemanticRecallLane
    public let sourceSequence: Int64
    public let metadataEpoch: Int64
    public let inputSHA256: String
    public let expansion: ScreenEvidenceExpansionRequest
    public let nextExpansion: ScreenEvidenceExpansionCursor?
    public let pageOrdinal: Int
    public let issuedAt: Date
    public let deadline: Date
    public init(attemptID: UUID, cursor: SemanticRecallCursor, transformation: SemanticRecallTransformation,
                policy: ScreenEvidencePolicyTransition, reference: ScreenEvidenceRef, lane: SemanticRecallLane,
                sourceSequence: Int64, metadataEpoch: Int64, inputSHA256: String,
                expansion: ScreenEvidenceExpansionRequest, nextExpansion: ScreenEvidenceExpansionCursor?,
                pageOrdinal: Int, issuedAt: Date, deadline: Date) {
        self.attemptID = attemptID; self.cursor = cursor; self.transformation = transformation
        self.policy = policy; self.reference = reference; self.lane = lane; self.sourceSequence = sourceSequence
        self.metadataEpoch = metadataEpoch; self.inputSHA256 = inputSHA256; self.expansion = expansion
        self.nextExpansion = nextExpansion; self.pageOrdinal = pageOrdinal; self.issuedAt = issuedAt; self.deadline = deadline
    }
}

/// Channel coordinates refer to the immutable extraction, not a later OCR run.
public struct SemanticRecallSpan: Codable, Equatable, Sendable {
    public let fragmentID: ScreenEvidenceFragmentID
    public let sourceUTF16Range: EvidenceUTF16Range
    public let inputUTF16Range: EvidenceUTF16Range
    public init(fragmentID: ScreenEvidenceFragmentID, sourceUTF16Range: EvidenceUTF16Range,
                inputUTF16Range: EvidenceUTF16Range) {
        self.fragmentID = fragmentID; self.sourceUTF16Range = sourceUTF16Range; self.inputUTF16Range = inputUTF16Range
    }
}

public struct SemanticRecallInput: Sendable {
    public let claim: SemanticRecallClaim
    /// Canonical fragment order, separated by exactly one newline. This is the
    /// complete bounded page; the runtime must not silently truncate it.
    public let text: String
    public let fragments: [SemanticRecallSpan]
    public init(claim: SemanticRecallClaim, text: String, fragments: [SemanticRecallSpan]) {
        self.claim = claim; self.text = text; self.fragments = fragments
    }

    /// Derives supporting ranges; publication repeats this calculation from the
    /// canonical input instead of trusting a worker's range assignments.
    public func spans(for range: EvidenceUTF16Range) throws -> [SemanticRecallSpan] {
        try Self.spans(in: text, fragments: fragments, for: range)
    }

    public static func spans(in text: String, fragments: [SemanticRecallSpan],
                             for range: EvidenceUTF16Range) throws -> [SemanticRecallSpan] {
        let units = Array(text.utf16)
        guard range.location >= 0, range.length > 0, range.location <= units.count,
              range.length <= units.count - range.location else { throw SemanticRecallError.invalidSpan }
        let end = range.location + range.length
        func boundary(_ offset: Int) -> Bool {
            offset == 0 || offset == units.count || !(0xDC00...0xDFFF).contains(units[offset])
        }
        guard boundary(range.location), boundary(end) else { throw SemanticRecallError.invalidSpan }
        var spans: [SemanticRecallSpan] = []
        for fragment in fragments {
            guard fragment.inputUTF16Range.location >= 0, fragment.inputUTF16Range.length >= 0,
                  fragment.inputUTF16Range.location <= units.count,
                  fragment.inputUTF16Range.length <= units.count - fragment.inputUTF16Range.location,
                  fragment.sourceUTF16Range.location >= 0,
                  fragment.sourceUTF16Range.length == fragment.inputUTF16Range.length,
                  fragment.sourceUTF16Range.length <= Int.max - fragment.sourceUTF16Range.location else {
                throw SemanticRecallError.invalidSpan
            }
            let start = max(range.location, fragment.inputUTF16Range.location)
            let stop = min(end, fragment.inputUTF16Range.location + fragment.inputUTF16Range.length)
            if start < stop {
                spans.append(.init(fragmentID: fragment.fragmentID,
                    sourceUTF16Range: .init(location: fragment.sourceUTF16Range.location + start - fragment.inputUTF16Range.location,
                                            length: stop - start),
                    inputUTF16Range: .init(location: start, length: stop - start)))
            }
        }
        guard !spans.isEmpty else { throw SemanticRecallError.invalidSpan }
        return spans
    }
}

public struct SemanticRecallVectorWindow: Codable, Equatable, Sendable {
    public let tokenStart: Int
    public let tokenEnd: Int
    public let inputUTF16Range: EvidenceUTF16Range
    public let spans: [SemanticRecallSpan]
    public let vector: [Float]
    public init(tokenStart: Int, tokenEnd: Int, inputUTF16Range: EvidenceUTF16Range,
                spans: [SemanticRecallSpan], vector: [Float]) {
        self.tokenStart = tokenStart; self.tokenEnd = tokenEnd; self.inputUTF16Range = inputUTF16Range
        self.spans = spans; self.vector = vector
    }
}

public struct SemanticRecallPublication: Codable, Equatable, Sendable {
    public let reference: ScreenEvidenceRef
    public let pageOrdinal: Int
    public let windowCount: Int
    public let observationComplete: Bool
    public init(reference: ScreenEvidenceRef, pageOrdinal: Int, windowCount: Int, observationComplete: Bool) {
        self.reference = reference; self.pageOrdinal = pageOrdinal; self.windowCount = windowCount
        self.observationComplete = observationComplete
    }
}

/// Counts describe the visited native, materialized observations only. They do
/// not claim imported, audio, legacy-unmaterialized or future direct-text coverage.
public struct SemanticRecallCoverage: Sendable {
    public let cursor: SemanticRecallCursor
    public let transformation: SemanticRecallTransformation
    public let boundarySequence: Int64
    public let freshSequence: Int64
    public let latestSequence: Int64
    public let maximumBackfillFrameID: Int64
    public let lastBackfillFrameID: Int64
    public let backfillComplete: Bool
    public let completedObservations: Int
    public let emptyObservations: Int
    public let pendingObservations: Int
    public let skippedObservations: Int
    public let publishedWindows: Int
    /// Queue caught up is distinct from complete searchable coverage.
    public var caughtUp: Bool { backfillComplete && freshSequence == latestSequence && pendingObservations == 0 }
    public var fullyIndexed: Bool { caughtUp && skippedObservations == 0 }
    public init(cursor: SemanticRecallCursor, transformation: SemanticRecallTransformation,
                boundarySequence: Int64, freshSequence: Int64, latestSequence: Int64,
                maximumBackfillFrameID: Int64, lastBackfillFrameID: Int64, backfillComplete: Bool,
                completedObservations: Int, emptyObservations: Int, pendingObservations: Int,
                skippedObservations: Int, publishedWindows: Int) {
        self.cursor = cursor; self.transformation = transformation; self.boundarySequence = boundarySequence
        self.freshSequence = freshSequence; self.latestSequence = latestSequence
        self.maximumBackfillFrameID = maximumBackfillFrameID; self.lastBackfillFrameID = lastBackfillFrameID
        self.backfillComplete = backfillComplete; self.completedObservations = completedObservations
        self.emptyObservations = emptyObservations; self.pendingObservations = pendingObservations
        self.skippedObservations = skippedObservations; self.publishedWindows = publishedWindows
    }
}

public struct SemanticRecallWorkPage: Sendable {
    public let input: SemanticRecallInput?
    public let inspectedCount: Int
    public let coverage: SemanticRecallCoverage
    public init(input: SemanticRecallInput?, inspectedCount: Int, coverage: SemanticRecallCoverage) {
        self.input = input; self.inspectedCount = inspectedCount; self.coverage = coverage
    }
}

public struct SemanticRecallFilter: Codable, Equatable, Sendable {
    public let from: Date?
    public let through: Date?
    public let appBundleIDs: [String]
    public let excludedAppBundleIDs: [String]
    public let hiddenFilter: HiddenFilter
    public init(from: Date? = nil, through: Date? = nil, appBundleIDs: [String] = [],
                excludedAppBundleIDs: [String] = [], hiddenFilter: HiddenFilter = .hide) {
        self.from = from; self.through = through; self.appBundleIDs = appBundleIDs.sorted()
        self.excludedAppBundleIDs = excludedAppBundleIDs.sorted(); self.hiddenFilter = hiddenFilter
    }
}

/// Exact current owner + policy + generation. Revalidate after awaited ranking
/// and again before exposing evidence; a vector is not an access capability.
public struct SemanticRecallReadStamp: Codable, Equatable, Sendable {
    public let indexID: UUID
    public let policy: ScreenEvidencePolicyTransition
    public let generation: Int64
    public let metadataEpoch: Int64
    public init(indexID: UUID, policy: ScreenEvidencePolicyTransition, generation: Int64, metadataEpoch: Int64) {
        self.indexID = indexID; self.policy = policy; self.generation = generation; self.metadataEpoch = metadataEpoch
    }
}

public struct SemanticRecallVectorCursor: Codable, Equatable, Sendable {
    public let stamp: SemanticRecallReadStamp
    public let filter: SemanticRecallFilter
    public let afterRowID: Int64
    public init(stamp: SemanticRecallReadStamp, filter: SemanticRecallFilter, afterRowID: Int64) {
        self.stamp = stamp; self.filter = filter; self.afterRowID = afterRowID
    }
}

public struct SemanticRecallVectorReadRequest: Sendable {
    public let transformation: SemanticRecallTransformation
    public let filter: SemanticRecallFilter
    public let cursor: SemanticRecallVectorCursor?
    public let maximumWindows: Int
    public let maximumInspected: Int
    public init(transformation: SemanticRecallTransformation = .miniLMNativeV1,
                filter: SemanticRecallFilter = .init(), cursor: SemanticRecallVectorCursor? = nil,
                maximumWindows: Int = 128, maximumInspected: Int = 256) {
        self.transformation = transformation; self.filter = filter; self.cursor = cursor
        self.maximumWindows = maximumWindows; self.maximumInspected = maximumInspected
    }
}

public struct SemanticRecallVectorCandidate: Sendable {
    public let rowID: Int64
    public let reference: ScreenEvidenceRef
    public let captureTimestamp: Date
    public let pageOrdinal: Int
    public let windowOrdinal: Int
    public let window: SemanticRecallVectorWindow
    public init(rowID: Int64, reference: ScreenEvidenceRef, captureTimestamp: Date,
                pageOrdinal: Int, windowOrdinal: Int, window: SemanticRecallVectorWindow) {
        self.rowID = rowID; self.reference = reference; self.captureTimestamp = captureTimestamp
        self.pageOrdinal = pageOrdinal; self.windowOrdinal = windowOrdinal; self.window = window
    }
}

public struct SemanticRecallVectorPage: Sendable {
    public let stamp: SemanticRecallReadStamp
    public let candidates: [SemanticRecallVectorCandidate]
    public let inspectedCount: Int
    public let nextCursor: SemanticRecallVectorCursor?
    public init(stamp: SemanticRecallReadStamp, candidates: [SemanticRecallVectorCandidate],
                inspectedCount: Int, nextCursor: SemanticRecallVectorCursor?) {
        self.stamp = stamp; self.candidates = candidates; self.inspectedCount = inspectedCount; self.nextCursor = nextCursor
    }
}
