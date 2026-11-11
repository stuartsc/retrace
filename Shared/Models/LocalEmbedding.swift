import Foundation

public struct LocalEmbeddingConfiguration: Sendable {
    public let modelPackageURL: URL
    public let tokenizerURL: URL
    public let privateCacheParentURL: URL
    public init(modelPackageURL: URL, tokenizerURL: URL, privateCacheParentURL: URL) {
        self.modelPackageURL = modelPackageURL; self.tokenizerURL = tokenizerURL
        self.privateCacheParentURL = privateCacheParentURL
    }
}

public struct LocalEmbeddingDescriptor: Codable, Equatable, Sendable {
    public let modelID: String
    public let modelRevision: String
    public let modelPackageSHA256: String
    public let tokenizerSHA256: String
    public let transformSHA256: String
    public let dimensions: Int
    public static let miniLM = LocalEmbeddingDescriptor(modelID: "sentence-transformers/all-MiniLM-L6-v2",
        modelRevision: "1110a243fdf4706b3f48f1d95db1a4f5529b4d41",
        modelPackageSHA256: "d3806da4c9148f87ef92f5054d4fbc74875589ce5ee81640d65c7813d7a17779",
        tokenizerSHA256: "be50c3628f2bf5bb5e3a7f17b1f74611b2561a3a27eeab05e5aa30f411572037",
        transformSHA256: "266a80a756948759e1818406797949566dda34fd16dd16987d36544bf10b42e5", dimensions: 384)
}

public struct LocalEmbeddingWindow: Sendable {
    public let tokenStart: Int
    public let tokenEnd: Int
    public let inputUTF16Range: EvidenceUTF16Range
    public let vector: [Float]
    public init(tokenStart: Int, tokenEnd: Int, inputUTF16Range: EvidenceUTF16Range, vector: [Float]) {
        self.tokenStart = tokenStart; self.tokenEnd = tokenEnd; self.inputUTF16Range = inputUTF16Range; self.vector = vector
    }
}

public struct LocalEmbeddingBatch: Sendable {
    public let descriptor: LocalEmbeddingDescriptor
    public let windows: [LocalEmbeddingWindow]
    public init(descriptor: LocalEmbeddingDescriptor, windows: [LocalEmbeddingWindow]) {
        self.descriptor = descriptor; self.windows = windows
    }
}

public enum LocalEmbeddingError: String, Error, Sendable {
    case artifactUnavailable, artifactInvalid, modelInvalid, predictionFailed, invalidOutput
    case inputTooLarge, emptyInput, busy, closed, cleanupFailed
}

public struct LocalEmbeddingStatus: Sendable {
    public let isPrepared: Bool
    public let isEmbedding: Bool
    public let completedWindowCount: Int
    public let totalWindowCount: Int
    public init(isPrepared: Bool, isEmbedding: Bool, completedWindowCount: Int, totalWindowCount: Int) {
        self.isPrepared = isPrepared; self.isEmbedding = isEmbedding
        self.completedWindowCount = completedWindowCount; self.totalWindowCount = totalWindowCount
    }
}

public struct LocalEmbeddingMetric: Sendable {
    public enum Operation: String, Sendable { case preparation, embedding, cleanup }
    public enum Outcome: String, Sendable { case completed, rejected, cancelled, failed }
    public let operation: Operation
    public let outcome: Outcome
    public let windowCount: Int
    public let elapsedMilliseconds: Double
    public init(operation: Operation, outcome: Outcome, windowCount: Int, elapsedMilliseconds: Double) {
        self.operation = operation; self.outcome = outcome; self.windowCount = windowCount
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public struct SemanticRecallEngineConfiguration: Sendable {
    public let backgroundPagesPerYield: Int
    public let backgroundYieldMilliseconds: Int
    public let maximumInspectedPerWorkPage: Int
    public let leaseDuration: TimeInterval
    public init(backgroundPagesPerYield: Int = 4, backgroundYieldMilliseconds: Int = 100,
                maximumInspectedPerWorkPage: Int = 64, leaseDuration: TimeInterval = 3600) {
        self.backgroundPagesPerYield = backgroundPagesPerYield
        self.backgroundYieldMilliseconds = backgroundYieldMilliseconds
        self.maximumInspectedPerWorkPage = maximumInspectedPerWorkPage; self.leaseDuration = leaseDuration
    }
}

public struct SemanticRecallQuestion: Sendable {
    public let text: String
    public let filter: SemanticRecallFilter
    public let limit: Int
    public let maximumPages: Int
    public let maximumDuration: TimeInterval
    public init(text: String, filter: SemanticRecallFilter = .init(), limit: Int = 20,
                maximumPages: Int = 32, maximumDuration: TimeInterval = 2) {
        self.text = text; self.filter = filter; self.limit = limit
        self.maximumPages = maximumPages; self.maximumDuration = maximumDuration
    }
}

public struct SemanticRecallMatch: Sendable {
    public let reference: ScreenEvidenceRef
    public let captureTimestamp: Date
    public let cosine: Double
    public let spans: [SemanticRecallSpan]
    public let queryUTF16Range: EvidenceUTF16Range
    public let pageOrdinal: Int
    public let windowOrdinal: Int
    public init(reference: ScreenEvidenceRef, captureTimestamp: Date, cosine: Double, spans: [SemanticRecallSpan],
                queryUTF16Range: EvidenceUTF16Range, pageOrdinal: Int, windowOrdinal: Int) {
        self.reference = reference; self.captureTimestamp = captureTimestamp; self.cosine = cosine; self.spans = spans
        self.queryUTF16Range = queryUTF16Range; self.pageOrdinal = pageOrdinal; self.windowOrdinal = windowOrdinal
    }
}

public struct SemanticRecallResponse: Sendable {
    public let matches: [SemanticRecallMatch]
    public let stamp: SemanticRecallReadStamp
    public let coverage: SemanticRecallCoverage
    /// False means a bounded scan stopped with more eligible rows to inspect.
    /// Complete scans can still have incomplete historical indexing coverage.
    public let scanComplete: Bool
    public let inspectedCount: Int
    public let scannedWindowCount: Int
    public let elapsedMilliseconds: Double
    public init(matches: [SemanticRecallMatch], stamp: SemanticRecallReadStamp, coverage: SemanticRecallCoverage,
                scanComplete: Bool, inspectedCount: Int, scannedWindowCount: Int, elapsedMilliseconds: Double) {
        self.matches = matches; self.stamp = stamp; self.coverage = coverage; self.scanComplete = scanComplete
        self.inspectedCount = inspectedCount; self.scannedWindowCount = scannedWindowCount
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public enum SemanticRecallEngineError: String, Error, Sendable {
    case stopped, invalidConfiguration, invalidQuestion, incompatibleRuntime, staleEvidence, cleanupFailed
}

public struct SemanticRecallEngineStatus: Sendable {
    public enum Phase: String, Sendable { case stopped, starting, ready, stopping, failed }
    public enum QueryStage: String, Sendable { case idle, embeddingQuestion, findingMoments, checkingEvidence }
    public let phase: Phase
    public let queryStage: QueryStage
    public let indexing: Bool
    public let coverage: SemanticRecallCoverage?
    public let lastFailure: String?
    public init(phase: Phase, queryStage: QueryStage, indexing: Bool,
                coverage: SemanticRecallCoverage?, lastFailure: String?) {
        self.phase = phase; self.queryStage = queryStage; self.indexing = indexing
        self.coverage = coverage; self.lastFailure = lastFailure
    }
}

/// A synchronous enqueue event, never captured text, source IDs, app names or paths.
public struct SemanticRecallMetric: Sendable {
    public enum Operation: String, Sendable { case startup, work, query, shutdown }
    public enum Outcome: String, Sendable { case completed, cancelled, failed, rejected }
    public let operation: Operation
    public let outcome: Outcome
    public let windowCount: Int
    public let inspectedCount: Int
    public let partial: Bool
    public let elapsedMilliseconds: Double
    public init(operation: Operation, outcome: Outcome, windowCount: Int = 0, inspectedCount: Int = 0,
                partial: Bool = false, elapsedMilliseconds: Double) {
        self.operation = operation; self.outcome = outcome; self.windowCount = windowCount
        self.inspectedCount = inspectedCount; self.partial = partial; self.elapsedMilliseconds = elapsedMilliseconds
    }
}
