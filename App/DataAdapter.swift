import Foundation
import CoreGraphics
import CryptoKit
import Shared
import Database
import Storage
import SQLCipher

/// Unified data adapter that owns connections directly and runs SQL
/// Seamlessly blends data from Retrace (native) and Rewind (encrypted) databases
public actor DataAdapter {

    /// High-frequency function words that should not use prefix expansion.
    /// These still participate in MATCH, but as exact token matches.
    private static let exactMatchStopwords: Set<String> = [
        "a", "an", "and", "as", "at",
        "be", "but", "by",
        "for", "from",
        "if", "in", "into", "is", "it",
        "of", "on", "or",
        "the", "to",
        "with"
    ]

    // MARK: - Connections

    private let retraceConnection: DatabaseConnection
    private let retraceConfig: DatabaseConfig

    private var rewindConnection: DatabaseConnection?
    private var rewindConfig: DatabaseConfig?
    private var cutoffDate: Date?

    // MARK: - Image Extractors

    private let retraceImageExtractor: ImageExtractor
    private var rewindImageExtractor: ImageExtractor?

    // MARK: - Database Reference (for legacy APIs)

    private let database: DatabaseManager

    // MARK: - Cache

    private struct SegmentCacheKey: Hashable {
        let startDate: Date
        let endDate: Date
    }

    private struct SegmentCacheEntry {
        let segments: [Segment]
        let timestamp: Date
    }

    private var segmentCache: [SegmentCacheKey: SegmentCacheEntry] = [:]
    private let segmentCacheTTL: TimeInterval = 300

    // MARK: - State

    private var isInitialized = false
    private var cachedHiddenTagId: Int64?
    private let searchConnectionIdentity = UUID()
    private var rewindSearchGeneration = UUID()

    // MARK: - Initialization

    public init(
        retraceConnection: DatabaseConnection,
        retraceConfig: DatabaseConfig,
        retraceImageExtractor: ImageExtractor,
        database: DatabaseManager
    ) {
        self.retraceConnection = retraceConnection
        self.retraceConfig = retraceConfig
        self.retraceImageExtractor = retraceImageExtractor
        self.database = database
    }

    /// Configure Rewind data source (encrypted SQLCipher database)
    public func configureRewind(
        connection: DatabaseConnection,
        config: DatabaseConfig,
        imageExtractor: ImageExtractor,
        cutoffDate: Date
    ) {
        self.rewindConnection = connection
        self.rewindConfig = config
        self.rewindImageExtractor = imageExtractor
        self.cutoffDate = cutoffDate
        rewindSearchGeneration = UUID()
        Log.info("[DataAdapter] Rewind source configured with cutoff \(cutoffDate)", category: .app)
    }

    /// Disconnect Rewind data source (clears connection without deleting data)
    public func disconnectRewind() {
        guard rewindConnection != nil else {
            Log.info("[DataAdapter] No Rewind source to disconnect", category: .app)
            return
        }
        self.rewindConnection = nil
        self.rewindConfig = nil
        self.rewindImageExtractor = nil
        self.cutoffDate = nil
        rewindSearchGeneration = UUID()
        Log.info("[DataAdapter] Rewind source disconnected", category: .app)
    }

    /// Initialize the adapter
    public func initialize() async throws {
        isInitialized = true

        // Cache the hidden tag ID
        if let hiddenTag = try? await database.getTag(name: "hidden") {
            cachedHiddenTagId = hiddenTag.id.value
            Log.debug("[DataAdapter] Cached hidden tag ID: \(hiddenTag.id.value)", category: .app)
        } else {
            Log.warning("[DataAdapter] Hidden tag not found in database", category: .app)
        }

        Log.info("[DataAdapter] Initialized with \(rewindConnection != nil ? "2" : "1") connection(s)", category: .app)
    }

    /// Shutdown the adapter
    public func shutdown() async {
        isInitialized = false
        cachedHiddenTagId = nil
        Log.info("[DataAdapter] Shutdown complete", category: .app)
    }

    // MARK: - Connection Selection

    private func connectionForTimestamp(_ timestamp: Date) -> (DatabaseConnection, DatabaseConfig) {
        if let cutoff = cutoffDate, let rewind = rewindConnection, let config = rewindConfig, timestamp < cutoff {
            return (rewind, config)
        }
        return (retraceConnection, retraceConfig)
    }

    /// Filters that require Retrace-only semantics because Rewind lacks supporting tables/data.
    private func requiresRetraceOnly(_ filters: FilterCriteria) -> Bool {
        (filters.selectedTags != nil && !filters.selectedTags!.isEmpty) ||
        filters.hiddenFilter == .onlyHidden ||
        filters.commentFilter == .commentsOnly
    }

    /// Search filters that require Retrace-only semantics.
    private func requiresRetraceOnly(_ filters: SearchFilters) -> Bool {
        (filters.selectedTagIds != nil && !filters.selectedTagIds!.isEmpty) ||
        (filters.excludedTagIds != nil && !filters.excludedTagIds!.isEmpty) ||
        filters.hiddenFilter == .onlyHidden ||
        filters.commentFilter == .commentsOnly
    }

    private static func buildDateRangeUnionClause(
        ranges: [DateRangeCriterion],
        columnName: String
    ) -> (clause: String?, bindValues: [Date]) {
        guard !ranges.isEmpty else {
            return (nil, [])
        }

        var dateClauses: [String] = []
        var bindValues: [Date] = []

        for range in ranges where range.hasBounds {
            switch (range.start, range.end) {
            case let (.some(start), .some(end)):
                if end < start {
                    dateClauses.append("(\(columnName) >= ? AND \(columnName) <= ?)")
                    bindValues.append(end)
                    bindValues.append(start)
                    continue
                }
                dateClauses.append("(\(columnName) >= ? AND \(columnName) <= ?)")
                bindValues.append(start)
                bindValues.append(end)
            case let (.some(start), .none):
                dateClauses.append("(\(columnName) >= ?)")
                bindValues.append(start)
            case let (.none, .some(end)):
                dateClauses.append("(\(columnName) <= ?)")
                bindValues.append(end)
            case (.none, .none):
                continue
            }
        }

        guard !dateClauses.isEmpty else {
            return (nil, [])
        }

        return ("(" + dateClauses.joined(separator: " OR ") + ")", bindValues)
    }

    private func hasDateRangeIntersectingRewind(_ ranges: [DateRangeCriterion]) -> Bool {
        guard let cutoffDate else { return true }
        guard !ranges.isEmpty else { return true }

        return ranges.contains { range in
            let rangeStart = range.start ?? .distantPast
            return rangeStart < cutoffDate
        }
    }

    // MARK: - Frame Retrieval

    /// Get frames with video info in a time range (optimized - single query with JOINs)
    public func getFramesWithVideoInfo(from startDate: Date, to endDate: Date, limit: Int = 500, filters: FilterCriteria? = nil) async throws -> [FrameWithVideoInfo] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Use filtered query when filters are provided (always applies hidden filter by default)
        if let filters = filters {
            return try await getFramesInRangeWithFilters(from: startDate, to: endDate, limit: limit, filters: filters)
        }

        // Original unfiltered logic (fast subquery approach) - only used when filters is nil
        var allFrames: [FrameWithVideoInfo] = []

        // Query Rewind if timestamp is before cutoff
        if let cutoff = cutoffDate, let rewind = rewindConnection, let config = rewindConfig, startDate < cutoff {
            let effectiveEnd = min(endDate, cutoff)
            let frames = try queryFramesWithVideoInfo(from: startDate, to: effectiveEnd, limit: limit, connection: rewind, config: config, filters: nil)
            allFrames.append(contentsOf: frames)
        }

        // Query Retrace
        var retraceStart = startDate
        if let cutoff = cutoffDate {
            retraceStart = max(startDate, cutoff)
        }
        if retraceStart < endDate {
            let frames = try queryFramesWithVideoInfo(from: retraceStart, to: endDate, limit: limit, connection: retraceConnection, config: retraceConfig, filters: nil)
            allFrames.append(contentsOf: frames)
        }

        // Sort by timestamp ascending (oldest first)
        allFrames.sort { $0.frame.timestamp < $1.frame.timestamp }
        return Array(allFrames.prefix(limit))
    }

    /// Optimized filtered query for date range.
    /// If the range starts before cutoff, prefer Rewind first to avoid expensive empty Retrace probes.
    private func getFramesInRangeWithFilters(from startDate: Date, to endDate: Date, limit: Int, filters: FilterCriteria) async throws -> [FrameWithVideoInfo] {
        var allFrames: [FrameWithVideoInfo] = []
        var remaining = limit

        // Check if we should exclude sources based on source filter
        let excludeRetrace = filters.selectedSources?.contains(.rewind) == true &&
                            filters.selectedSources?.contains(.native) == false
        let excludeRewind = filters.selectedSources?.contains(.native) == true &&
                           filters.selectedSources?.contains(.rewind) == false
        // Rewind database doesn't have segment_tag table.
        // For tag-driven filters, only query Retrace so semantics remain correct.
        let hasRetraceOnlyFilters = requiresRetraceOnly(filters)

        let shouldPreferRewindFirst: Bool = {
            guard let cutoff = cutoffDate else { return false }
            return startDate < cutoff
        }()

        func queryRetraceIfNeeded() throws {
            guard remaining > 0, !excludeRetrace else { return }
            var retraceStart = startDate
            if let cutoff = cutoffDate {
                retraceStart = max(startDate, cutoff)
            }
            guard retraceStart < endDate else { return }

            let retraceFrames = try queryFramesInRangeWithFiltersOptimized(
                from: retraceStart,
                to: endDate,
                limit: remaining,
                connection: retraceConnection,
                config: retraceConfig,
                filters: filters,
                isRewindDatabase: false
            )
            allFrames.append(contentsOf: retraceFrames)
            remaining -= retraceFrames.count
        }

        func queryRewindIfNeeded() throws {
            guard remaining > 0,
                  !excludeRewind,
                  !hasRetraceOnlyFilters,
                  let cutoff = cutoffDate,
                  let rewind = rewindConnection,
                  let config = rewindConfig,
                  startDate < cutoff else {
                return
            }

            let effectiveEnd = min(endDate, cutoff)
            guard startDate < effectiveEnd else { return }

            let rewindFrames = try queryFramesInRangeWithFiltersOptimized(
                from: startDate,
                to: effectiveEnd,
                limit: remaining,
                connection: rewind,
                config: config,
                filters: filters,
                isRewindDatabase: true
            )
            allFrames.append(contentsOf: rewindFrames)
            remaining -= rewindFrames.count
        }

        if shouldPreferRewindFirst {
            try queryRewindIfNeeded()
            try queryRetraceIfNeeded()
        } else {
            try queryRetraceIfNeeded()
            try queryRewindIfNeeded()
        }

        // Sort by timestamp ascending (oldest first)
        allFrames.sort { $0.frame.timestamp < $1.frame.timestamp }
        return allFrames
    }

    /// Get frames in a time range
    public func getFrames(from startDate: Date, to endDate: Date, limit: Int = 500, filters: FilterCriteria? = nil) async throws -> [FrameReference] {
        let framesWithVideo = try await getFramesWithVideoInfo(from: startDate, to: endDate, limit: limit, filters: filters)
        return framesWithVideo.map { $0.frame }
    }

    /// Get most recent frames with video info
    public func getMostRecentFramesWithVideoInfo(limit: Int = 250, filters: FilterCriteria? = nil) async throws -> [FrameWithVideoInfo] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Use filtered query when filters are provided (always applies hidden filter by default)
        if let filters = filters {
            return try await getMostRecentFramesWithFilters(limit: limit, filters: filters)
        }

        // Original unfiltered logic (fast subquery approach) - only used when filters is nil
        var allFrames: [FrameWithVideoInfo] = []

        // Query Retrace
        let retraceFrames = try queryMostRecentFramesWithVideoInfo(limit: limit, connection: retraceConnection, config: retraceConfig, filters: nil)
        allFrames.append(contentsOf: retraceFrames)

        // Query Rewind
        if let rewind = rewindConnection, let config = rewindConfig {
            let rewindFrames = try queryMostRecentFramesWithVideoInfo(limit: limit, connection: rewind, config: config, filters: nil)
            allFrames.append(contentsOf: rewindFrames)
        }

        // Sort by timestamp descending (newest first) and take top N
        allFrames.sort { $0.frame.timestamp > $1.frame.timestamp }
        return Array(allFrames.prefix(limit))
    }

    /// Optimized filtered query - tries Retrace first, then Rewind to get full limit
    private func getMostRecentFramesWithFilters(limit: Int, filters: FilterCriteria) async throws -> [FrameWithVideoInfo] {
        var allFrames: [FrameWithVideoInfo] = []
        var remaining = limit

        // Check if we should exclude sources based on source filter
        let excludeRetrace = filters.selectedSources?.contains(.rewind) == true &&
                            filters.selectedSources?.contains(.native) == false
        let excludeRewind = filters.selectedSources?.contains(.native) == true &&
                           filters.selectedSources?.contains(.rewind) == false

        // Step 1: Try Retrace first (unless excluded)
        if !excludeRetrace {
            let retraceFrames = try queryMostRecentFramesWithFiltersOptimized(
                limit: limit,
                connection: retraceConnection,
                config: retraceConfig,
                filters: filters,
                isRewindDatabase: false
            )
            allFrames.append(contentsOf: retraceFrames)
            remaining = limit - retraceFrames.count
            Log.debug("[Filter] Got \(retraceFrames.count) frames from Retrace, need \(remaining) more", category: .database)
        }

        // Step 2: If we don't have enough frames, query Rewind (unless excluded)
        // Note: Skip Rewind if tag filters are active (Rewind doesn't have segment_tag table)
        // Also skip if effective date filters cannot match data before cutoff.
        let hasRetraceOnlyFilters = requiresRetraceOnly(filters)
        let effectiveDateRanges = filters.effectiveDateRanges
        let hasRewindDateOverlap = hasDateRangeIntersectingRewind(effectiveDateRanges)
        if remaining > 0, !excludeRewind, !hasRetraceOnlyFilters, hasRewindDateOverlap, let rewind = rewindConnection, let config = rewindConfig {
            let rewindFrames = try queryMostRecentFramesWithFiltersOptimized(
                limit: remaining,
                connection: rewind,
                config: config,
                filters: filters,
                isRewindDatabase: true
            )
            allFrames.append(contentsOf: rewindFrames)
            Log.debug("[Filter] Got \(rewindFrames.count) frames from Rewind", category: .database)
        } else if !hasRewindDateOverlap, let cutoffDate {
            Log.debug("[Filter] Skipping Rewind query - date ranges do not overlap pre-cutoff data (cutoff=\(cutoffDate), ranges=\(effectiveDateRanges))", category: .database)
        }

        // Sort by timestamp descending (newest first)
        allFrames.sort { $0.frame.timestamp > $1.frame.timestamp }
        return allFrames
    }

    /// Get most recent frames
    public func getMostRecentFrames(limit: Int = 250, filters: FilterCriteria? = nil) async throws -> [FrameReference] {
        let framesWithVideo = try await getMostRecentFramesWithVideoInfo(limit: limit, filters: filters)
        return framesWithVideo.map { $0.frame }
    }

    /// Get frames with video info before a timestamp
    public func getFramesWithVideoInfoBefore(timestamp: Date, limit: Int = 300, filters: FilterCriteria? = nil) async throws -> [FrameWithVideoInfo] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Use filtered query when filters are provided (always applies hidden filter by default)
        if let filters = filters {
            return try await getFramesBeforeWithFilters(timestamp: timestamp, limit: limit, filters: filters)
        }

        // Original unfiltered logic (fast subquery approach) - only used when filters is nil
        var allFrames: [FrameWithVideoInfo] = []

        // Query Rewind
        if let rewind = rewindConnection, let config = rewindConfig {
            let effectiveTimestamp = cutoffDate != nil ? min(timestamp, cutoffDate!) : timestamp
            let frames = try queryFramesWithVideoInfoBefore(timestamp: effectiveTimestamp, limit: limit, connection: rewind, config: config, filters: nil)
            allFrames.append(contentsOf: frames)
        }

        // Query Retrace
        let retraceFrames = try queryFramesWithVideoInfoBefore(timestamp: timestamp, limit: limit, connection: retraceConnection, config: retraceConfig, filters: nil)
        allFrames.append(contentsOf: retraceFrames)

        // Sort by timestamp descending (newest first) and take top N
        allFrames.sort { $0.frame.timestamp > $1.frame.timestamp }
        return Array(allFrames.prefix(limit))
    }

    /// Optimized filtered query for frames before timestamp.
    /// If timestamp is before cutoff, prefer Rewind first to avoid expensive empty Retrace probes.
    private func getFramesBeforeWithFilters(timestamp: Date, limit: Int, filters: FilterCriteria) async throws -> [FrameWithVideoInfo] {
        var allFrames: [FrameWithVideoInfo] = []
        var remaining = limit

        // Check if we should exclude sources based on source filter
        let excludeRetrace = filters.selectedSources?.contains(.rewind) == true &&
                            filters.selectedSources?.contains(.native) == false
        let excludeRewind = filters.selectedSources?.contains(.native) == true &&
                           filters.selectedSources?.contains(.rewind) == false

        // Note: Skip Rewind if tag filters are active (Rewind doesn't have segment_tag table)
        let hasRetraceOnlyFilters = requiresRetraceOnly(filters)
        let shouldPreferRewindFirst: Bool = {
            guard let cutoff = cutoffDate else { return false }
            return timestamp < cutoff
        }()

        func queryRetraceIfNeeded() throws {
            guard remaining > 0, !excludeRetrace else { return }
            let retraceFrames = try queryFramesBeforeWithFiltersOptimized(
                timestamp: timestamp,
                limit: remaining,
                connection: retraceConnection,
                config: retraceConfig,
                filters: filters,
                isRewindDatabase: false
            )
            allFrames.append(contentsOf: retraceFrames)
            remaining -= retraceFrames.count
        }

        func queryRewindIfNeeded() throws {
            guard remaining > 0,
                  !excludeRewind,
                  !hasRetraceOnlyFilters,
                  let rewind = rewindConnection,
                  let config = rewindConfig else {
                return
            }
            let effectiveTimestamp = cutoffDate != nil ? min(timestamp, cutoffDate!) : timestamp
            let rewindFrames = try queryFramesBeforeWithFiltersOptimized(
                timestamp: effectiveTimestamp,
                limit: remaining,
                connection: rewind,
                config: config,
                filters: filters,
                isRewindDatabase: true
            )
            allFrames.append(contentsOf: rewindFrames)
            remaining -= rewindFrames.count
        }

        if shouldPreferRewindFirst {
            try queryRewindIfNeeded()
            try queryRetraceIfNeeded()
        } else {
            try queryRetraceIfNeeded()
            try queryRewindIfNeeded()
        }

        // Sort by timestamp descending (newest first)
        allFrames.sort { $0.frame.timestamp > $1.frame.timestamp }
        return allFrames
    }

    /// Get frames before a timestamp
    public func getFramesBefore(timestamp: Date, limit: Int = 300, filters: FilterCriteria? = nil) async throws -> [FrameReference] {
        let framesWithVideo = try await getFramesWithVideoInfoBefore(timestamp: timestamp, limit: limit, filters: filters)
        return framesWithVideo.map { $0.frame }
    }

    /// Get frames with video info after a timestamp
    public func getFramesWithVideoInfoAfter(timestamp: Date, limit: Int = 300, filters: FilterCriteria? = nil) async throws -> [FrameWithVideoInfo] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Use filtered query when filters are provided (always applies hidden filter by default)
        if let filters = filters {
            return try await getFramesAfterWithFilters(timestamp: timestamp, limit: limit, filters: filters)
        }

        // Original unfiltered logic (fast subquery approach) - only used when filters is nil
        var allFrames: [FrameWithVideoInfo] = []

        // Query Rewind (respecting cutoff)
        if let cutoff = cutoffDate, let rewind = rewindConnection, let config = rewindConfig, timestamp < cutoff {
            let frames = try queryFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit, connection: rewind, config: config, filters: nil)
            allFrames.append(contentsOf: frames)
        }

        // Query Retrace
        let retraceFrames = try queryFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit, connection: retraceConnection, config: retraceConfig, filters: nil)
        allFrames.append(contentsOf: retraceFrames)

        // Sort by timestamp ascending (oldest first) and take top N
        allFrames.sort { $0.frame.timestamp < $1.frame.timestamp }
        return Array(allFrames.prefix(limit))
    }

    /// Optimized filtered query for frames after timestamp.
    /// If timestamp is before cutoff, prefer Rewind first to avoid expensive empty Retrace probes.
    private func getFramesAfterWithFilters(timestamp: Date, limit: Int, filters: FilterCriteria) async throws -> [FrameWithVideoInfo] {
        var allFrames: [FrameWithVideoInfo] = []
        var remaining = limit

        // Check if we should exclude sources based on source filter
        let excludeRetrace = filters.selectedSources?.contains(.rewind) == true &&
                            filters.selectedSources?.contains(.native) == false
        let excludeRewind = filters.selectedSources?.contains(.native) == true &&
                           filters.selectedSources?.contains(.rewind) == false

        // Note: Skip Rewind if tag filters are active (Rewind doesn't have segment_tag table)
        let hasRetraceOnlyFilters = requiresRetraceOnly(filters)
        let shouldPreferRewindFirst: Bool = {
            guard let cutoff = cutoffDate else { return false }
            return timestamp < cutoff
        }()

        func queryRetraceIfNeeded() throws {
            guard remaining > 0, !excludeRetrace else { return }
            let retraceFrames = try queryFramesAfterWithFiltersOptimized(
                timestamp: timestamp,
                limit: remaining,
                connection: retraceConnection,
                config: retraceConfig,
                filters: filters,
                isRewindDatabase: false
            )
            allFrames.append(contentsOf: retraceFrames)
            remaining -= retraceFrames.count
        }

        func queryRewindIfNeeded() throws {
            guard remaining > 0,
                  !excludeRewind,
                  !hasRetraceOnlyFilters,
                  let cutoff = cutoffDate,
                  let rewind = rewindConnection,
                  let config = rewindConfig,
                  timestamp < cutoff else {
                return
            }

            let rewindFrames = try queryFramesAfterWithFiltersOptimized(
                timestamp: timestamp,
                limit: remaining,
                connection: rewind,
                config: config,
                filters: filters,
                isRewindDatabase: true
            )
            allFrames.append(contentsOf: rewindFrames)
            remaining -= rewindFrames.count
        }

        if shouldPreferRewindFirst {
            try queryRewindIfNeeded()
            try queryRetraceIfNeeded()
        } else {
            try queryRetraceIfNeeded()
            try queryRewindIfNeeded()
        }

        // Sort by timestamp ascending (oldest first)
        allFrames.sort { $0.frame.timestamp < $1.frame.timestamp }
        return allFrames
    }

    /// Get frames after a timestamp
    public func getFramesAfter(timestamp: Date, limit: Int = 300, filters: FilterCriteria? = nil) async throws -> [FrameReference] {
        let framesWithVideo = try await getFramesWithVideoInfoAfter(timestamp: timestamp, limit: limit, filters: filters)
        return framesWithVideo.map { $0.frame }
    }

    /// Get a single frame by ID with video info
    public func getFrameWithVideoInfoByID(id: FrameID, source: FrameSource) async throws -> FrameWithVideoInfo? {
        guard isInitialized else { throw DataAdapterError.notInitialized }
        let (connection, config) = try evidenceConnection(for: source)
        return try queryFrameWithVideoInfoByID(id: id, connection: connection, config: config)
    }

    /// A source-qualified store identity. Imported databases are never written to.
    public func evidenceStoreID(source: FrameSource) async throws -> UUID {
        guard isInitialized else { throw DataAdapterError.notInitialized }
        if source == .native { return try await database.activityStoreID() }
        let (connection, _) = try evidenceConnection(for: source)
        let generation = selectionSourceGeneration(source)
        let identity = try Self.importedStoreIdentity(connection)
        let storeID = try await database.evidenceStoreID(source: source, identity: identity)
        guard isInitialized, generation == selectionSourceGeneration(source),
              identity == (try Self.importedStoreIdentity(connection)) else {
            throw SearchPaginationError.dataChanged
        }
        return storeID
    }

    /// Opaque configuration/store identity for bracketing local evidence reads; never contains paths or content.
    public func evidenceSourceGeneration(source: FrameSource) async throws -> String {
        try Task.checkCancellation()
        guard isInitialized else { throw DataAdapterError.notInitialized }
        let generation = selectionSourceGeneration(source)
        let (connection, _) = try evidenceConnection(for: source)
        guard connection.getConnection() != nil else { throw DataAdapterError.sourceNotAvailable(source) }
        let identity = source == .rewind ? try Self.importedStoreIdentity(connection) : nil
        let storeID = try await evidenceStoreID(source: source)
        try Task.checkCancellation()
        guard isInitialized, generation == selectionSourceGeneration(source),
              identity == (source == .rewind ? try Self.importedStoreIdentity(connection) : nil) else {
            throw SearchPaginationError.dataChanged
        }
        return "\(generation):\(storeID.uuidString)"
    }

    public func savedEvidenceText(frame: FrameReference) throws -> ExtractedText? {
        let (connection, _) = try evidenceConnection(for: frame.source)
        let sql = "SELECT sc.c0, sc.c1 FROM doc_segment ds JOIN searchRanking_content sc ON sc.id=ds.docid WHERE ds.frameId=? ORDER BY ds.docid DESC LIMIT 1"
        guard let statement = try connection.prepare(sql: sql) else { throw DataAdapterError.parseFailed }
        defer { connection.finalize(statement) }
        sqlite3_bind_int64(statement, 1, frame.id.value)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let main = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        let chrome = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
        return ExtractedText(frameID: frame.id, timestamp: frame.timestamp, regions: [], fullText: main,
                             chromeText: chrome, metadata: frame.metadata)
    }

    private func evidenceConnection(for source: FrameSource) throws -> (DatabaseConnection, DatabaseConfig) {
        switch source {
        case .native: return (retraceConnection, retraceConfig)
        case .rewind:
            guard let connection = rewindConnection, let config = rewindConfig else { throw DataAdapterError.sourceNotAvailable(source) }
            return (connection, config)
        default: throw DataAdapterError.sourceNotAvailable(source)
        }
    }

    public func resolveEvidenceVideoURL(_ item: FrameWithVideoInfo) throws -> URL {
        let (_, config) = try evidenceConnection(for: item.frame.source)
        guard let video = item.videoInfo, video.frameIndex == item.frame.frameIndexInSegment,
              video.frameIndex >= 0 else { throw EvidenceUnavailableReason.frameFinalising }
        let root = URL(fileURLWithPath: config.storageRoot, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let raw = video.videoPath.hasPrefix("/") ? URL(fileURLWithPath: video.videoPath) : root.appendingPathComponent(video.videoPath)
        let resolved = raw.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") else { throw EvidenceUnavailableReason.integrityFailure }
        return resolved
    }

    public func oldestPendingTextAt() throws -> Date? {
        guard let statement = try retraceConnection.prepare(sql: "SELECT MIN(enqueuedAt) FROM processing_queue") else {
            throw DataAdapterError.parseFailed
        }
        defer { retraceConnection.finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw DataAdapterError.parseFailed }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    public func getFrameWithVideoInfoByID(id: FrameID) async throws -> FrameWithVideoInfo? {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Try Retrace first (more likely for recent frames)
        if let frame = try queryFrameWithVideoInfoByID(id: id, connection: retraceConnection, config: retraceConfig) {
            return frame
        }

        // Try Rewind if available
        if let rewind = rewindConnection, let config = rewindConfig {
            return try queryFrameWithVideoInfoByID(id: id, connection: rewind, config: config)
        }

        return nil
    }

    /// Get the most recent frame timestamp
    public func getMostRecentFrameTimestamp() async throws -> Date? {
        let frames = try await getMostRecentFrames(limit: 1)
        return frames.first?.timestamp
    }

    // MARK: - Image Extraction

    /// Get image data for a specific frame
    public func getFrameImage(segmentID: VideoSegmentID, timestamp: Date, source frameSource: FrameSource) async throws -> Data {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let (connection, config) = try evidenceConnection(for: frameSource)

        // Get video info
        guard let videoInfo = try getFrameVideoInfo(segmentID: segmentID, timestamp: timestamp, connection: connection, config: config) else {
            throw DataAdapterError.frameNotFound
        }

        // Extract image based on source
        if frameSource == .rewind, let extractor = rewindImageExtractor {
            return try await extractor.extractFrame(videoPath: videoInfo.videoPath, frameIndex: videoInfo.frameIndex, frameRate: videoInfo.frameRate)
        }
        return try await retraceImageExtractor.extractFrame(videoPath: videoInfo.videoPath, frameIndex: videoInfo.frameIndex, frameRate: videoInfo.frameRate)
    }

    /// Get image data for a frame by timestamp (auto-detects source)
    public func getFrameImage(segmentID: VideoSegmentID, timestamp: Date) async throws -> Data {
        // Determine source based on cutoff
        let source: FrameSource = (cutoffDate != nil && timestamp < cutoffDate! && rewindConnection != nil) ? .rewind : .native
        return try await getFrameImage(segmentID: segmentID, timestamp: timestamp, source: source)
    }

    /// Get frame image by exact videoID and frameIndex
    public func getFrameImageByIndex(videoID: VideoSegmentID, frameIndex: Int, source frameSource: FrameSource) async throws -> Data {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let (connection, config) = try evidenceConnection(for: frameSource)

        // Query video info directly
        let sql = """
            SELECT v.path, v.frameRate
            FROM video v
            WHERE v.id = ?
            LIMIT 1;
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            throw DataAdapterError.frameNotFound
        }
        defer { connection.finalize(statement) }

        sqlite3_bind_int64(statement, 1, videoID.value)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DataAdapterError.frameNotFound
        }

        guard let pathPtr = sqlite3_column_text(statement, 0) else {
            throw DataAdapterError.frameNotFound
        }
        let videoPath = String(cString: pathPtr)
        let frameRate = sqlite3_column_double(statement, 1)

        let fullPath = "\(config.storageRoot)/\(videoPath)"

        // Extract image based on source
        if frameSource == .rewind, let extractor = rewindImageExtractor {
            return try await extractor.extractFrame(videoPath: fullPath, frameIndex: frameIndex, frameRate: frameRate)
        }
        return try await retraceImageExtractor.extractFrame(videoPath: fullPath, frameIndex: frameIndex, frameRate: frameRate)
    }

    /// Get frame image as CGImage without JPEG encode/decode round-trips.
    /// Expects a video path returned by search results (relative or absolute).
    public func getFrameCGImage(videoPath: String, frameIndex: Int, frameRate: Double?, source frameSource: FrameSource) async throws -> CGImage {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let (_, config) = try evidenceConnection(for: frameSource)
        let resolvedPath: String = {
            if videoPath.hasPrefix("/") {
                return videoPath
            }
            return "\(config.storageRoot)/\(videoPath)"
        }()

        if frameSource == .rewind, let extractor = rewindImageExtractor {
            return try await extractor.extractFrameCGImage(
                videoPath: resolvedPath,
                frameIndex: frameIndex,
                frameRate: frameRate
            )
        }

        return try await retraceImageExtractor.extractFrameCGImage(
            videoPath: resolvedPath,
            frameIndex: frameIndex,
            frameRate: frameRate
        )
    }

    /// Get video info for a frame
    public func getFrameVideoInfo(segmentID: VideoSegmentID, timestamp: Date, source frameSource: FrameSource) async throws -> FrameVideoInfo? {
        let (connection, config) = try evidenceConnection(for: frameSource)
        return try getFrameVideoInfo(segmentID: segmentID, timestamp: timestamp, connection: connection, config: config)
    }

    // MARK: - Segments

    /// Get segments in a time range
    public func getSegments(from startDate: Date, to endDate: Date) async throws -> [Segment] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let cacheKey = SegmentCacheKey(startDate: startDate, endDate: endDate)

        // Check cache
        if let cached = segmentCache[cacheKey] {
            if Date().timeIntervalSince(cached.timestamp) < segmentCacheTTL {
                return cached.segments
            }
            segmentCache.removeValue(forKey: cacheKey)
        }

        var allSegments: [Segment] = []

        // Query Rewind
        if let cutoff = cutoffDate, let rewind = rewindConnection, let config = rewindConfig, startDate < cutoff {
            let effectiveEnd = min(endDate, cutoff)
            let segments = try querySegments(from: startDate, to: effectiveEnd, connection: rewind, config: config)
            allSegments.append(contentsOf: segments)
        }

        // Query Retrace
        var retraceStart = startDate
        if let cutoff = cutoffDate {
            retraceStart = max(startDate, cutoff)
        }
        if retraceStart < endDate {
            let segments = try querySegments(from: retraceStart, to: endDate, connection: retraceConnection, config: retraceConfig)
            allSegments.append(contentsOf: segments)
        }

        // Sort by start time
        allSegments.sort { $0.startDate < $1.startDate }

        // Cache
        segmentCache[cacheKey] = SegmentCacheEntry(segments: allSegments, timestamp: Date())
        return allSegments
    }

    /// Invalidate the segment cache
    public func invalidateSessionCache() {
        segmentCache.removeAll()
    }

    // MARK: - OCR Nodes

    /// Get all OCR nodes for a frame by timestamp
    public func getAllOCRNodes(timestamp: Date, source frameSource: FrameSource) async throws -> [OCRNodeWithText] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let (connection, config) = try evidenceConnection(for: frameSource)

        return try getAllOCRNodes(timestamp: timestamp, connection: connection, config: config)
    }

    /// Get all OCR nodes for a frame by frameID
    public func getAllOCRNodes(frameID: FrameID, source frameSource: FrameSource) async throws -> [OCRNodeWithText] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let (connection, _) = try evidenceConnection(for: frameSource)
        return try getAllOCRNodes(frameID: frameID, connection: connection)
    }

    // MARK: - App Discovery

    /// Get all distinct apps from all data sources
    /// Get distinct app bundle IDs from the database
    /// Caller is responsible for resolving names (use AppNameResolver.shared.resolveAll)
    public func getDistinctAppBundleIDs() async throws -> [String] {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        var bundleIDs: [String] = []

        // Try Rewind first (more historical data)
        if let rewind = rewindConnection {
            let queryStart = CFAbsoluteTimeGetCurrent()
            bundleIDs = try queryDistinctApps(connection: rewind)
            Log.debug("[DataAdapter] Rewind query took \(Int((CFAbsoluteTimeGetCurrent() - queryStart) * 1000))ms, found \(bundleIDs.count) bundle IDs", category: .database)
        }

        // If empty, try Retrace
        if bundleIDs.isEmpty {
            let queryStart = CFAbsoluteTimeGetCurrent()
            bundleIDs = try queryDistinctApps(connection: retraceConnection)
            Log.debug("[DataAdapter] Retrace query took \(Int((CFAbsoluteTimeGetCurrent() - queryStart) * 1000))ms, found \(bundleIDs.count) bundle IDs", category: .database)
        }

        Log.debug("[DataAdapter] getDistinctAppBundleIDs total: \(Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))ms", category: .database)
        return bundleIDs
    }

    // MARK: - URL Bounding Box Detection

    /// Get bounding box for URL in a frame's OCR text
    public func getURLBoundingBox(timestamp: Date, source frameSource: FrameSource) async throws -> URLBoundingBox? {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let (connection, config) = try evidenceConnection(for: frameSource)

        return try getURLBoundingBox(timestamp: timestamp, connection: connection, config: config)
    }

    // MARK: - Full-Text Search

    /// Search sources in their pagination order, preserving each source's cursor.
    public func search(query: SearchQuery) async throws -> SearchResults {
        guard isInitialized else { throw DataAdapterError.notInitialized }
        try Task.checkCancellation()
        let startedAt = Date()
        let hiddenTagId = cachedHiddenTagId
        let nativeCursor = query.cursor?.native
        let rewindCursor = query.cursor?.rewind
        let hasRewind = !requiresRetraceOnly(query.filters) && rewindConnection != nil && rewindConfig != nil
        let oldestFirst = query.mode == .all && query.sortOrder == .oldestFirst
        let sourceIdentity = searchConnectionIdentity.uuidString + ":" + (hasRewind ? rewindSearchGeneration.uuidString : "native")
        let fingerprint = try Self.searchFingerprint(query)
        Log.info("[DataAdapter] Search started: mode=\(query.mode), limit=\(query.limit), hasFilters=\(query.filters.hasFilters), hasCursor=\(query.cursor != nil)", category: .app)

        struct SourceRequest: Sendable {
            let source: FrameSource
            let connection: DatabaseConnection
            let config: DatabaseConfig
            let cursor: SearchSourceCursor?
        }
        let nativeRequest = SourceRequest(source: .native, connection: retraceConnection,
            config: retraceConfig, cursor: nativeCursor)
        var requests = [nativeRequest]
        if hasRewind, let rewindConnection, let rewindConfig {
            let rewindRequest = SourceRequest(source: .rewind, connection: rewindConnection,
                config: rewindConfig, cursor: rewindCursor)
            requests = oldestFirst ? [rewindRequest, nativeRequest] : [nativeRequest, rewindRequest]
        }

        let allRequests = requests
        let readStamp: @Sendable () throws -> SearchIndexStamp = {
            var stamp = SearchIndexStamp()
            for request in allRequests {
                try Task.checkCancellation()
                if request.source == .native {
                    stamp.nativeRevision = try Self.searchInteger(request.connection,
                        sql: "SELECT revision FROM recall_search_revision WHERE id=1")
                } else {
                    _ = try Self.validatedImportedDatabasePath(request.connection)
                    stamp.rewindDataVersion = try Self.searchInteger(request.connection, sql: "PRAGMA data_version")
                    stamp.rewindTotalChanges = sqlite3_total_changes64(request.connection.getConnection())
                }
            }
            return stamp
        }
        let stampTask = Task.detached(priority: .userInitiated) { try readStamp() }
        let stamp = try await withTaskCancellationHandler {
            try await stampTask.value
        } onCancel: { stampTask.cancel() }
        if let cursor = query.cursor {
            guard cursor.sourceIdentity == sourceIdentity, cursor.queryFingerprint == fingerprint,
                  cursor.nativeSearchRevision == stamp.nativeRevision,
                  cursor.rewindDataVersion == stamp.rewindDataVersion,
                  cursor.rewindTotalChanges == stamp.rewindTotalChanges else {
                throw SearchPaginationError.dataChanged
            }
        }
        // A cleared preferred-source cursor means this pagination flow has
        // exhausted that source. Revision stamps still cover both stores.
        if hasRewind, query.cursor != nil, requests.first?.cursor == nil {
            requests.removeFirst()
        }

        // Only the source being consumed owns an active read. This keeps failed
        // and cancelled pages from leaving speculative SQLite readers behind.
        for (index, request) in requests.enumerated() {
            try Task.checkCancellation()
            let task = Task.detached(priority: .userInitiated) {
                try Self.searchConnection(query: query, connection: request.connection,
                    config: request.config, source: request.source, sourceCursor: request.cursor,
                    hiddenTagId: hiddenTagId)
            }
            let page: SearchResults
            do {
                page = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                try Task.checkCancellation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.warning("[DataAdapter] Search source failed: source=\(request.source), errorType=\(type(of: error))", category: .app)
                throw error
            }
            // Both SQL statements in searchConnection have finalized before this
            // fence, allowing a new read to observe writes committed during the page.
            let finalStampTask = Task.detached(priority: .userInitiated) { try readStamp() }
            let finalStamp = try await withTaskCancellationHandler {
                try await finalStampTask.value
            } onCancel: { finalStampTask.cancel() }
            try Task.checkCancellation()
            let currentIdentity = searchConnectionIdentity.uuidString + ":" +
                (hasRewind ? rewindSearchGeneration.uuidString : "native")
            guard stamp == finalStamp, currentIdentity == sourceIdentity,
                  !hasRewind || (rewindConnection != nil && rewindConfig != nil) else {
                throw SearchPaginationError.dataChanged
            }
            guard !page.results.isEmpty else { continue }

            let moreSources = index + 1 < requests.count
            let nextCursor: SearchPageCursor?
            if request.source == .native {
                if let nextNative = page.nextCursor?.native {
                    nextCursor = SearchPageCursor(native: nextNative, rewind: moreSources ? rewindCursor : nil)
                } else if moreSources {
                    nextCursor = SearchPageCursor(native: nil, rewind: rewindCursor)
                } else {
                    nextCursor = nil
                }
            } else {
                if let nextRewind = page.nextCursor?.rewind {
                    nextCursor = SearchPageCursor(native: moreSources ? nativeCursor : nil, rewind: nextRewind)
                } else if moreSources {
                    nextCursor = SearchPageCursor(native: nativeCursor, rewind: nil)
                } else {
                    nextCursor = nil
                }
            }
            let stampedCursor = nextCursor.map {
                SearchPageCursor(native: $0.native, rewind: $0.rewind,
                    nativeSearchRevision: stamp.nativeRevision,
                    rewindDataVersion: stamp.rewindDataVersion, rewindTotalChanges: stamp.rewindTotalChanges,
                    sourceIdentity: sourceIdentity, queryFingerprint: fingerprint)
            }
            let selectedResults = try page.results.map {
                try Self.bindSearchSelection($0, config: request.config, stamp: stamp,
                                             generation: selectionSourceGeneration(request.source))
            }
            return SearchResults(query: query, results: selectedResults, totalCount: page.totalCount,
                searchTimeMs: Int(Date().timeIntervalSince(startedAt) * 1000), nextCursor: stampedCursor)
        }
        return SearchResults(query: query, results: [], totalCount: 0,
            searchTimeMs: Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    private struct SearchIndexStamp: Sendable, Equatable {
        var nativeRevision: Int64?
        var rewindDataVersion: Int64?
        var rewindTotalChanges: Int64?
    }

    struct SearchSelectionMaterial: Sendable {
        let storeID: UUID
        let item: FrameWithVideoInfo
        let text: ExtractedText?
        let token: SearchSelectionToken
    }

    /// Freeze the selected source's frame and text before crossing the persistence boundary.
    func prepareSearchSelection(_ result: SearchResult) async throws -> SearchSelectionMaterial {
        _ = try await validateSearchSelection(result)
        let storeID = try await evidenceStoreID(source: result.source)
        let current = try await validateSearchSelection(result)
        guard let token = result.selectionToken else { throw EvidenceUnavailableReason.integrityFailure }
        return SearchSelectionMaterial(storeID: storeID, item: current.item, text: current.text, token: token)
    }

    /// Materialization preserves the search corpus revision. The selected source,
    /// frame/media identity and indexed text must agree before and after persistence.
    @discardableResult
    func validateSearchSelection(_ result: SearchResult,
                                 materialized: SearchSelectionMaterial? = nil) async throws -> (item: FrameWithVideoInfo, text: ExtractedText?) {
        guard isInitialized else { throw DataAdapterError.notInitialized }
        try Task.checkCancellation()
        guard let token = result.selectionToken, token.source == result.source,
              token.captureIdentityDigest.utf8.count == 64 else {
            throw EvidenceUnavailableReason.integrityFailure
        }
        let generation = selectionSourceGeneration(result.source)
        guard token.sourceGeneration == generation else { throw SearchPaginationError.dataChanged }
        let (connection, config) = try evidenceConnection(for: result.source)
        guard token.captureIdentityDigest == (try Self.selectionDigest(result, config: config)) else {
            throw EvidenceUnavailableReason.integrityFailure
        }
        let readStamp: @Sendable () throws -> SearchIndexStamp = {
            if result.source == .native {
                return SearchIndexStamp(nativeRevision: try Self.searchInteger(connection,
                    sql: "SELECT revision FROM recall_search_revision WHERE id=1"))
            }
            _ = try Self.validatedImportedDatabasePath(connection)
            return SearchIndexStamp(rewindDataVersion: try Self.searchInteger(connection, sql: "PRAGMA data_version"),
                                    rewindTotalChanges: sqlite3_total_changes64(connection.getConnection()))
        }
        let before = try await Self.readSelectionStamp(readStamp)
        guard before.nativeRevision == token.nativeSearchRevision,
              before.rewindDataVersion == token.rewindDataVersion,
              before.rewindTotalChanges == token.rewindTotalChanges else {
            throw SearchPaginationError.dataChanged
        }
        // Use the captured connection/config throughout, even if configureRewind
        // runs at an await. Never route a later read using only the integer ID.
        guard let item = try queryFrameWithVideoInfoByID(id: result.id, connection: connection, config: config),
              token.captureIdentityDigest == (try Self.selectionDigest(item)) else {
            throw SearchPaginationError.dataChanged
        }
        let text = try Self.selectionText(frame: item.frame, connection: connection)
        if let materialized {
            guard materialized.token == token,
                  text?.fullText == materialized.text?.fullText,
                  text?.chromeText == materialized.text?.chromeText,
                  item.videoInfo == materialized.item.videoInfo else {
                throw SearchPaginationError.dataChanged
            }
        }
        let after = try await Self.readSelectionStamp(readStamp)
        guard before == after, isInitialized, generation == selectionSourceGeneration(result.source) else {
            throw SearchPaginationError.dataChanged
        }
        try Task.checkCancellation()
        return (item, text)
    }

    private func selectionSourceGeneration(_ source: FrameSource) -> String {
        source == .rewind
            ? "\(searchConnectionIdentity.uuidString):\(rewindSearchGeneration.uuidString)"
            : searchConnectionIdentity.uuidString
    }

    /// An open SQLite reader can outlive the file at its pathname. Its version
    /// counter then remains unchanged, so ask the VFS whether that exact opened
    /// file moved before using any pathname-derived registry identity.
    private static func validatedImportedDatabasePath(_ connection: DatabaseConnection,
                                                       requireFile: Bool = false) throws -> String? {
        guard let db = connection.getConnection(), let filename = sqlite3_db_filename(db, "main") else {
            throw EvidenceUnavailableReason.integrityFailure
        }
        let path = String(cString: filename)
        if path.isEmpty {
            // In-memory query fixtures have no replaceable pathname. They cannot
            // create durable imported evidence without a file identity.
            guard !requireFile else { throw EvidenceUnavailableReason.integrityFailure }
            return nil
        }
        var moved: Int32 = 0
        guard sqlite3_file_control(db, "main", SQLITE_FCNTL_HAS_MOVED, &moved) == SQLITE_OK else {
            throw EvidenceUnavailableReason.integrityFailure
        }
        guard moved == 0 else { throw SearchPaginationError.dataChanged }
        return path
    }

    private static func importedStoreIdentity(_ connection: DatabaseConnection) throws -> String {
        guard let path = try validatedImportedDatabasePath(connection, requireFile: true) else {
            throw EvidenceUnavailableReason.integrityFailure
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileID = attributes[.systemFileNumber].map(String.init(describing:)),
              let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970 else {
            throw EvidenceUnavailableReason.integrityFailure
        }
        _ = try validatedImportedDatabasePath(connection, requireFile: true)
        return "\(url.path)|\(fileID)|\(created)"
    }

    private static func readSelectionStamp(_ read: @escaping @Sendable () throws -> SearchIndexStamp) async throws -> SearchIndexStamp {
        let task = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try read() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func bindSearchSelection(_ result: SearchResult, config: DatabaseConfig,
                                           stamp: SearchIndexStamp, generation: String) throws -> SearchResult {
        let token = SearchSelectionToken(source: result.source, sourceGeneration: generation,
            nativeSearchRevision: result.source == .native ? stamp.nativeRevision : nil,
            rewindDataVersion: result.source == .rewind ? stamp.rewindDataVersion : nil,
            rewindTotalChanges: result.source == .rewind ? stamp.rewindTotalChanges : nil,
            captureIdentityDigest: try selectionDigest(result, config: config))
        return SearchResult(id: result.id, timestamp: result.timestamp, snippet: result.snippet,
            matchedText: result.matchedText, relevanceScore: result.relevanceScore, metadata: result.metadata,
            segmentID: result.segmentID, videoID: result.videoID, frameIndex: result.frameIndex,
            videoPath: result.videoPath, videoFrameRate: result.videoFrameRate, source: result.source,
            highlightNode: result.highlightNode, evidenceRef: result.evidenceRef, selectionToken: token)
    }

    private struct SelectionIdentity: Encodable {
        let source: FrameSource
        let frameID: FrameID
        let timestamp: Date
        let segmentID: AppSegmentID
        let videoID: VideoSegmentID
        let frameIndex: Int
        let path: String?
        let rate: Double?
        let bundleID: String?
        let title: String?
        let url: String?
        let redaction: String?
    }

    private static func selectionDigest(_ result: SearchResult, config: DatabaseConfig) throws -> String {
        try selectionDigest(SelectionIdentity(source: result.source, frameID: result.id, timestamp: result.timestamp,
            segmentID: result.segmentID, videoID: result.videoID, frameIndex: result.frameIndex,
            path: result.videoPath.map { "\(config.storageRoot)/\($0)" }, rate: result.videoFrameRate,
            bundleID: result.metadata.appBundleID?.isEmpty == true ? nil : result.metadata.appBundleID,
            title: result.metadata.windowName, url: result.metadata.browserURL, redaction: result.metadata.redactionReason))
    }

    private static func selectionDigest(_ item: FrameWithVideoInfo) throws -> String {
        let frame = item.frame
        return try selectionDigest(SelectionIdentity(source: frame.source, frameID: frame.id, timestamp: frame.timestamp,
            segmentID: frame.segmentID, videoID: frame.videoID, frameIndex: frame.frameIndexInSegment,
            path: item.videoInfo?.videoPath, rate: item.videoInfo?.frameRate,
            bundleID: frame.metadata.appBundleID?.isEmpty == true ? nil : frame.metadata.appBundleID,
            title: frame.metadata.windowName, url: frame.metadata.browserURL, redaction: frame.metadata.redactionReason))
    }

    private static func selectionDigest(_ identity: SelectionIdentity) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
    }

    private static func selectionText(frame: FrameReference, connection: DatabaseConnection) throws -> ExtractedText? {
        // A legacy frame may link several documents without an extraction ID.
        // Identical copies are harmless; conflicting text cannot establish which
        // document supplied the selected match, so never substitute the newest one.
        let sql = "SELECT DISTINCT COALESCE(sc.c0,''),COALESCE(sc.c1,'') FROM doc_segment ds JOIN searchRanking_content sc ON sc.id=ds.docid WHERE ds.frameId=? LIMIT 2"
        guard let statement = try connection.prepare(sql: sql) else { throw DataAdapterError.parseFailed }
        defer { connection.finalize(statement) }
        sqlite3_bind_int64(statement, 1, frame.id.value)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw DataAdapterError.parseFailed }
        let text = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        let chrome = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
        let remaining = sqlite3_step(statement)
        guard remaining != SQLITE_ROW else { throw EvidenceUnavailableReason.integrityFailure }
        guard remaining == SQLITE_DONE else { throw DataAdapterError.parseFailed }
        return ExtractedText(frameID: frame.id, timestamp: frame.timestamp, regions: [], fullText: text,
                             chromeText: chrome, metadata: frame.metadata)
    }

    private static func searchFingerprint(_ query: SearchQuery) throws -> String {
        struct Content: Encodable {
            let text: String
            let filters: SearchFilters
            let mode: SearchMode
            let sortOrder: SearchSortOrder
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(Content(text: query.text, filters: query.filters,
                                                  mode: query.mode, sortOrder: query.sortOrder))
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    private static func searchInteger(_ connection: DatabaseConnection, sql: String) throws -> Int64 {
        guard let statement = try connection.prepare(sql: sql) else { throw DatabaseConnectionError.notConnected }
        defer { connection.finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseConnectionError.executionFailed(sql: sql, error: "Search revision is unavailable")
        }
        return sqlite3_column_int64(statement, 0)
    }

    // MARK: - Deletion

    /// Delete a frame
    public func deleteFrame(frameID: FrameID, source frameSource: FrameSource) async throws {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        try requireWritableSource(frameSource)
        try await database.deleteFrame(id: frameID)
    }

    /// Delete multiple frames
    public func deleteFrames(_ frames: [(frameID: FrameID, source: FrameSource)]) async throws {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        // Validate the entire selection before the canonical writer mutates anything.
        for source in Set(frames.map(\.source)) { try requireWritableSource(source) }
        try await database.deleteFrames(ids: frames.map(\.frameID))
    }

    /// Delete frame by timestamp
    public func deleteFrameByTimestamp(_ timestamp: Date, source frameSource: FrameSource) async throws {
        guard isInitialized else {
            throw DataAdapterError.notInitialized
        }

        let (connection, config) = try evidenceConnection(for: frameSource)
        try requireWritableSource(frameSource)

        // Find frame by timestamp
        let sql = "SELECT id FROM frame WHERE createdAt = ? LIMIT 1;"
        guard let statement = try? connection.prepare(sql: sql) else {
            throw DataAdapterError.frameNotFound
        }
        defer { connection.finalize(statement) }

        config.bindDate(timestamp, to: statement, at: 1)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DataAdapterError.frameNotFound
        }

        let frameID = FrameID(value: sqlite3_column_int64(statement, 0))
        try await database.deleteFrame(id: frameID)
    }

    private func requireWritableSource(_ source: FrameSource) throws {
        _ = try evidenceConnection(for: source)
        guard source == .native else { throw DataAdapterError.readOnlySource(source) }
    }

    // MARK: - Source Information

    /// Get registered sources
    /// Public accessor for Rewind cutoff date (used to determine if data is from Rewind)
    public var rewindCutoffDate: Date? {
        cutoffDate
    }

    public var registeredSources: [FrameSource] {
        var sources: [FrameSource] = [.native]
        if rewindConnection != nil {
            sources.append(.rewind)
        }
        return sources
    }

    /// Check if source is available
    public func isSourceAvailable(_ source: FrameSource) -> Bool {
        if source == .native { return true }
        if source == .rewind { return rewindConnection != nil }
        return false
    }

    // MARK: - Private SQL Query Methods

    private func queryFramesWithVideoInfo(
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria? = nil
    ) throws -> [FrameWithVideoInfo] {
        let effectiveEndDate = config.applyCutoff(to: endDate)
        guard startDate < effectiveEndDate else { return [] }

        // Build WHERE clause based on filters
        var whereClauses = ["f.createdAt >= ?", "f.createdAt <= ?"]
        var bindIndex = 3 // 1 and 2 are for timestamps

        // App filter (include or exclude mode)
        if let apps = filters?.selectedApps, !apps.isEmpty {
            let filterMode = filters?.appFilterMode ?? .include
            whereClauses.append(buildAppFilterClause(apps: apps, mode: filterMode))
        }

        // Tag filter - need to join with segment_tag
        let needsTagJoin = filters?.selectedTags != nil && !(filters?.selectedTags!.isEmpty ?? true)
        let tagJoin = needsTagJoin ? """
            INNER JOIN segment_tag st ON f.segmentId = st.segmentId
            """ : ""

        if let tags = filters?.selectedTags, !tags.isEmpty {
            let placeholders = tags.map { _ in "?" }.joined(separator: ", ")
            whereClauses.append("st.tagId IN (\(placeholders))")
        }

        let whereClause = whereClauses.joined(separator: " AND ")

        // Rewind database doesn't have processingStatus column
        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"
        let redactionReasonColumn = config.source == .rewind ? "NULL as redactionReason" : "f.redactionReason"

        let sql = """
            SELECT
                f.id,
                f.createdAt,
                f.segmentId,
                f.videoId,
                f.videoFrameIndex,
                f.encodingStatus,
                \(processingStatusColumn),
                \(redactionReasonColumn),
                s.bundleID,
                s.windowName,
                s.browserUrl,
                v.path,
                v.frameRate,
                v.width,
                v.height
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            \(tagJoin)
            LEFT JOIN video v ON f.videoId = v.id
            WHERE \(whereClause)
            ORDER BY f.createdAt ASC
            LIMIT ?;
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        config.bindDate(startDate, to: statement, at: 1)
        config.bindDate(effectiveEndDate, to: statement, at: 2)

        // Bind app bundle IDs
        if let apps = filters?.selectedApps, !apps.isEmpty {
            for (index, app) in apps.enumerated() {
                sqlite3_bind_text(statement, Int32(bindIndex + index), (app as NSString).utf8String, -1, nil)
            }
            bindIndex += apps.count
        }

        // Bind tag IDs
        if let tags = filters?.selectedTags, !tags.isEmpty {
            for (index, tagId) in tags.enumerated() {
                sqlite3_bind_int64(statement, Int32(bindIndex + index), tagId)
            }
            bindIndex += tags.count
        }

        sqlite3_bind_int(statement, Int32(bindIndex), Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    /// Fast unfiltered query - uses subquery to limit before join
    private func queryMostRecentFramesWithVideoInfo(
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria? = nil
    ) throws -> [FrameWithVideoInfo] {
        // Rewind database doesn't have processingStatus column
        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"
        let redactionReasonColumn = config.source == .rewind ? "NULL as redactionReason" : "f.redactionReason"
        let subqueryProcessingStatus = config.source == .rewind ? "-1 as processingStatus" : "processingStatus"
        let subqueryRedactionReason = config.source == .rewind ? "NULL as redactionReason" : "redactionReason"

        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, \(processingStatusColumn), \(redactionReasonColumn),
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height, \(videoProcessingStateColumn(for: config))
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, encodingStatus, \(subqueryProcessingStatus), \(subqueryRedactionReason)
                FROM frame
                ORDER BY createdAt DESC
                LIMIT ?
            ) f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            ORDER BY f.createdAt DESC
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    /// Optimized filtered query - joins first to use bundleID index, then filters
    private func queryMostRecentFramesWithFiltersOptimized(
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria,
        isRewindDatabase: Bool = false
    ) throws -> [FrameWithVideoInfo] {
        var whereClauses: [String] = []
        var bindIndex = 1

        // Build tag filter including hidden filter logic
        // Note: Rewind database doesn't have segment_tag table, so skip tag filters for Rewind
        var tagsToFilter = Set<Int64>()
        let shouldApplyTagFilters = !isRewindDatabase

        if shouldApplyTagFilters {
            tagsToFilter = filters.selectedTags ?? Set<Int64>()

            // Apply hidden filter logic
            if let hiddenTagId = cachedHiddenTagId {
                switch filters.hiddenFilter {
                case .hide:
                    // Exclude hidden: We'll use NOT EXISTS clause below
                    break
                case .onlyHidden:
                    // Only show hidden: Set tags to only hidden tag
                    tagsToFilter = [hiddenTagId]
                case .showAll:
                    // Show all: Don't modify tag filter
                    break
                }
            }
        }

        // Window/browser metadata filters support encoded include/exclude term sets.
        let windowNameFilter = Self.decodeMetadataStringFilter(filters.windowNameFilter)
        let browserUrlFilter = Self.decodeMetadataStringFilter(filters.browserUrlFilter)
        let hasWindowNameFilter = windowNameFilter.hasActiveFilters
        let hasSelectedTagFilters = filters.selectedTags != nil && !filters.selectedTags!.isEmpty
        let hasBrowserUrlFilter = browserUrlFilter.hasActiveFilters
        let hasSegmentMetadataFilter = hasBrowserUrlFilter || hasWindowNameFilter
        var metadataBindValues: [Any] = []

        // Sparse metadata filters are often selective; use a segment-first query shape so SQLite doesn't
        // scan the full frame table just to satisfy ORDER BY createdAt LIMIT N.
        if hasSegmentMetadataFilter && !hasSelectedTagFilters && filters.hiddenFilter != .onlyHidden {
            return try queryMostRecentFramesWithSegmentMetadataFilterSegmentFirst(
                limit: limit,
                connection: connection,
                config: config,
                filters: filters,
                isRewindDatabase: isRewindDatabase
            )
        }

        // Build CTE for tag filtering (filter tags first in subquery, then join to frames)
        let tagCTE: String
        let tagJoin: String
        let hasTagFilter = !tagsToFilter.isEmpty
        let tagFilterMode = filters.tagFilterMode

        if hasTagFilter {
            let tagPlaceholders = tagsToFilter.map { _ in "?" }.joined(separator: ", ")
            if tagFilterMode == .include {
                // Include mode: Show only segments WITH selected tags
                tagCTE = """
                    tagged_segments AS (
                        SELECT DISTINCT segmentId
                        FROM segment_tag
                        WHERE tagId IN (\(tagPlaceholders))
                    )
                    """
                tagJoin = "INNER JOIN tagged_segments ts ON f.segmentId = ts.segmentId"
            } else {
                // Exclude mode: Show segments WITHOUT selected tags (via NOT EXISTS in WHERE)
                tagCTE = ""
                tagJoin = ""
            }
        } else {
            tagCTE = ""
            tagJoin = ""
        }

        // Combine CTEs (only tag CTE now, window name uses direct WHERE clause)
        let combinedCTE = tagCTE.isEmpty ? "" : "WITH " + tagCTE

        // App filter - uses index on segment.bundleID (include or exclude mode)
        if let apps = filters.selectedApps, !apps.isEmpty {
            whereClauses.append(buildAppFilterClause(apps: apps, mode: filters.appFilterMode))
        }

        Self.appendMetadataStringFilter(
            columnName: "s.browserUrl",
            parsedFilter: browserUrlFilter,
            whereConditions: &whereClauses,
            bindValues: &metadataBindValues
        )
        Self.appendMetadataStringFilter(
            columnName: "s.windowName",
            parsedFilter: windowNameFilter,
            whereConditions: &whereClauses,
            bindValues: &metadataBindValues
        )

        let dateRangeFilter = Self.buildDateRangeUnionClause(
            ranges: filters.effectiveDateRanges,
            columnName: "f.createdAt"
        )
        if let dateRangeClause = dateRangeFilter.clause {
            whereClauses.append(dateRangeClause)
        }

        // Tag exclude filter: Exclude segments that have any of the selected tags
        if hasTagFilter && tagFilterMode == .exclude {
            let tagPlaceholders = tagsToFilter.map { _ in "?" }.joined(separator: ", ")
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_exclude
                    WHERE st_exclude.segmentId = f.segmentId
                    AND st_exclude.tagId IN (\(tagPlaceholders))
                )
                """)
        }

        // Hidden filter: Exclude segments with hidden tag (when .hide mode)
        // Only apply for Retrace database (Rewind doesn't have segment_tag)
        if shouldApplyTagFilters && filters.hiddenFilter == .hide, cachedHiddenTagId != nil {
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_hidden
                    WHERE st_hidden.segmentId = f.segmentId
                    AND st_hidden.tagId = ?
                )
                """)
        }

        if let commentClause = Self.buildCommentFilterClause(
            filters.commentFilter,
            isRewindDatabase: isRewindDatabase,
            segmentIDExpression: "f.segmentId"
        ) {
            whereClauses.append(commentClause)
        }

        // Always exclude p=4 frames (not yet readable) - only for Retrace, Rewind doesn't have this column
        if config.source != .rewind {
            whereClauses.append("f.processingStatus != 4")
        }

        let whereClause = whereClauses.isEmpty ? "" : "WHERE " + whereClauses.joined(separator: " AND ")

        // Rewind database doesn't have processingStatus column
        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"
        let redactionReasonColumn = config.source == .rewind ? "NULL as redactionReason" : "f.redactionReason"

        // CTE filters tags first (small set), then joins with frames using segmentId index
        let sql = """
            \(combinedCTE)
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, \(processingStatusColumn), \(redactionReasonColumn),
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height, \(videoProcessingStateColumn(for: config))
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            \(tagJoin)
            LEFT JOIN video v ON f.videoId = v.id
            \(whereClause)
            ORDER BY f.createdAt DESC
            LIMIT ?
            """

        Log.debug("[Filter] ====== QUERY DEBUG START ======", category: .database)
        Log.debug("[Filter] Query SQL:\n\(sql)", category: .database)
        Log.debug("[Filter] Apps filter: \(filters.selectedApps ?? []), mode: \(filters.appFilterMode.rawValue)", category: .database)
        Log.debug("[Filter] Tags to filter: \(tagsToFilter), mode: \(tagFilterMode.rawValue)", category: .database)
        Log.debug("[Filter] Hidden filter: \(filters.hiddenFilter.rawValue), cachedHiddenTagId: \(String(describing: cachedHiddenTagId))", category: .database)
        Log.debug("[Filter] Window name filter: \(filters.windowNameFilter ?? "nil")", category: .database)
        Log.debug("[Filter] Browser URL filter: \(filters.browserUrlFilter ?? "nil")", category: .database)
        Log.debug("[Filter] Date ranges: \(filters.effectiveDateRanges)", category: .database)

        let statement: OpaquePointer?
        do {
            statement = try connection.prepare(sql: sql)
        } catch {
            Log.error("[Filter] Failed to prepare SQL statement: \(error)", category: .database)
            if let db = connection.getConnection(), let errMsg = sqlite3_errmsg(db) {
                Log.error("[Filter] SQLite error: \(String(cString: errMsg))", category: .database)
            }
            return []
        }
        guard let stmt = statement else {
            Log.error("[Filter] Statement is nil after prepare!", category: .database)
            return []
        }
        defer { connection.finalize(stmt) }

        // Bind tag IDs (they appear in the CTE) - ONLY for include mode
        if hasTagFilter && tagFilterMode == .include {
            for (index, tagId) in tagsToFilter.enumerated() {
                Log.debug("[Filter] Binding tagId \(tagId) at index \(bindIndex + index)", category: .database)
                sqlite3_bind_int64(stmt, Int32(bindIndex + index), tagId)
            }
            bindIndex += tagsToFilter.count
        }

        // Bind app bundle IDs
        if let apps = filters.selectedApps, !apps.isEmpty {
            for (index, app) in apps.enumerated() {
                Log.debug("[Filter] Binding app '\(app)' at index \(bindIndex + index)", category: .database)
                sqlite3_bind_text(stmt, Int32(bindIndex + index), (app as NSString).utf8String, -1, nil)
            }
            bindIndex += apps.count
        }

        for metadataValue in metadataBindValues {
            if let stringValue = metadataValue as? String {
                Log.debug("[Filter] Binding metadata pattern '\(stringValue)' at index \(bindIndex)", category: .database)
                sqlite3_bind_text(stmt, Int32(bindIndex), (stringValue as NSString).utf8String, -1, nil)
                bindIndex += 1
            }
        }

        // Bind date range union
        for date in dateRangeFilter.bindValues {
            Log.debug("[Filter] Binding date bound at index \(bindIndex)", category: .database)
            config.bindDate(date, to: stmt, at: Int32(bindIndex))
            bindIndex += 1
        }

        // Bind tag IDs for exclude mode (NOT EXISTS in WHERE clause)
        if hasTagFilter && tagFilterMode == .exclude {
            for (index, tagId) in tagsToFilter.enumerated() {
                Log.debug("[Filter] Binding exclude tagId \(tagId) at index \(bindIndex + index)", category: .database)
                sqlite3_bind_int64(stmt, Int32(bindIndex + index), tagId)
            }
            bindIndex += tagsToFilter.count
        }

        // Bind hidden tag ID for NOT EXISTS clause (if applicable)
        // Only bind for Retrace database (Rewind doesn't have segment_tag)
        if shouldApplyTagFilters && filters.hiddenFilter == .hide, let hiddenTagId = cachedHiddenTagId {
            Log.debug("[Filter] Binding hiddenTagId \(hiddenTagId) at index \(bindIndex)", category: .database)
            sqlite3_bind_int64(stmt, Int32(bindIndex), hiddenTagId)
            bindIndex += 1
        }

        // Bind limit
        Log.debug("[Filter] Binding limit \(limit) at index \(bindIndex)", category: .database)
        sqlite3_bind_int(stmt, Int32(bindIndex), Int32(limit))
        Log.debug("[Filter] ====== QUERY DEBUG END ======", category: .database)

        var frames: [FrameWithVideoInfo] = []
        var stepCount = 0
        var stepResult = sqlite3_step(stmt)

        while stepResult == SQLITE_ROW {
            stepCount += 1
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: stmt, config: config) {
                frames.append(frameWithVideo)
            }
            stepResult = sqlite3_step(stmt)
        }

        if stepResult != SQLITE_DONE {
            Log.error("[Filter] sqlite3_step error code: \(stepResult)", category: .database)
        }

        Log.debug("[Filter] Query returned \(frames.count) frames (stepped \(stepCount) times)", category: .database)

        return frames
    }

    /// Specialized most-recent query for window name/browser URL filters.
    /// Uses a segment-first subquery to avoid scanning frame.createdAt across the full table.
    private func queryMostRecentFramesWithSegmentMetadataFilterSegmentFirst(
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria,
        isRewindDatabase: Bool
    ) throws -> [FrameWithVideoInfo] {
        let windowNameFilter = Self.decodeMetadataStringFilter(filters.windowNameFilter)
        let browserUrlFilter = Self.decodeMetadataStringFilter(filters.browserUrlFilter)
        let hasBrowserUrlFilter = browserUrlFilter.hasActiveFilters
        let hasWindowNameFilter = windowNameFilter.hasActiveFilters
        guard hasBrowserUrlFilter || hasWindowNameFilter else {
            return []
        }

        var segmentWhereClauses: [String] = []
        var whereClauses: [String] = []
        var segmentMetadataBindValues: [Any] = []

        if let apps = filters.selectedApps, !apps.isEmpty {
            segmentWhereClauses.append(buildAppFilterClause(apps: apps, mode: filters.appFilterMode, tableAlias: "s2"))
        }

        Self.appendMetadataStringFilter(
            columnName: "s2.browserUrl",
            parsedFilter: browserUrlFilter,
            whereConditions: &segmentWhereClauses,
            bindValues: &segmentMetadataBindValues
        )
        Self.appendMetadataStringFilter(
            columnName: "s2.windowName",
            parsedFilter: windowNameFilter,
            whereConditions: &segmentWhereClauses,
            bindValues: &segmentMetadataBindValues
        )

        let segmentWhereClause = segmentWhereClauses.joined(separator: " AND ")
        whereClauses.append("""
            f.segmentId IN (
                SELECT s2.id
                FROM segment s2
                WHERE \(segmentWhereClause)
            )
            """)

        let dateRangeFilter = Self.buildDateRangeUnionClause(
            ranges: filters.effectiveDateRanges,
            columnName: "f.createdAt"
        )
        if let dateRangeClause = dateRangeFilter.clause {
            whereClauses.append(dateRangeClause)
        }

        // Rewind database doesn't have segment_tag; hidden filter only applies on Retrace.
        if !isRewindDatabase, filters.hiddenFilter == .hide, cachedHiddenTagId != nil {
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_hidden
                    WHERE st_hidden.segmentId = f.segmentId
                    AND st_hidden.tagId = ?
                )
                """)
        }

        if let commentClause = Self.buildCommentFilterClause(
            filters.commentFilter,
            isRewindDatabase: isRewindDatabase,
            segmentIDExpression: "f.segmentId"
        ) {
            whereClauses.append(commentClause)
        }

        if config.source != .rewind {
            whereClauses.append("f.processingStatus != 4")
        }

        let whereClause = whereClauses.joined(separator: " AND ")

        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"
        let redactionReasonColumn = config.source == .rewind ? "NULL as redactionReason" : "f.redactionReason"

        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, \(processingStatusColumn), \(redactionReasonColumn),
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height, \(videoProcessingStateColumn(for: config))
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            WHERE \(whereClause)
            ORDER BY f.createdAt DESC
            LIMIT ?
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        var bindIndex = 1

        if let apps = filters.selectedApps, !apps.isEmpty {
            for (index, app) in apps.enumerated() {
                sqlite3_bind_text(statement, Int32(bindIndex + index), (app as NSString).utf8String, -1, nil)
            }
            bindIndex += apps.count
        }

        for metadataValue in segmentMetadataBindValues {
            if let stringValue = metadataValue as? String {
                sqlite3_bind_text(statement, Int32(bindIndex), (stringValue as NSString).utf8String, -1, nil)
                bindIndex += 1
            }
        }

        for date in dateRangeFilter.bindValues {
            config.bindDate(date, to: statement, at: Int32(bindIndex))
            bindIndex += 1
        }

        if !isRewindDatabase, filters.hiddenFilter == .hide, let hiddenTagId = cachedHiddenTagId {
            sqlite3_bind_int64(statement, Int32(bindIndex), hiddenTagId)
            bindIndex += 1
        }

        sqlite3_bind_int(statement, Int32(bindIndex), Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    /// Optimized filtered query for frames before timestamp - joins first to use bundleID index
    private func queryFramesBeforeWithFiltersOptimized(
        timestamp: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria,
        isRewindDatabase: Bool = false
    ) throws -> [FrameWithVideoInfo] {
        let effectiveTimestamp = config.applyCutoff(to: timestamp)

        var whereClauses = ["f.createdAt < ?"]
        var bindIndex = 1

        // Build tag filter including hidden filter logic
        // Note: Rewind database doesn't have segment_tag table, so skip tag filters for Rewind
        var tagsToFilter = Set<Int64>()
        let shouldApplyTagFilters = !isRewindDatabase

        if shouldApplyTagFilters {
            tagsToFilter = filters.selectedTags ?? Set<Int64>()

            // Apply hidden filter logic
            if let hiddenTagId = cachedHiddenTagId {
                switch filters.hiddenFilter {
                case .hide:
                    // Exclude hidden: We'll use NOT EXISTS clause below
                    break
                case .onlyHidden:
                    // Only show hidden: Set tags to only hidden tag
                    tagsToFilter = [hiddenTagId]
                case .showAll:
                    // Show all: Don't modify tag filter
                    break
                }
            }
        }

        let windowNameFilter = Self.decodeMetadataStringFilter(filters.windowNameFilter)
        let browserUrlFilter = Self.decodeMetadataStringFilter(filters.browserUrlFilter)
        var metadataBindValues: [Any] = []

        // Build CTE for tag filtering (filter tags first in subquery, then join to frames)
        let tagCTE: String
        let tagJoin: String
        let hasTagFilter = !tagsToFilter.isEmpty
        let tagFilterMode = filters.tagFilterMode

        if hasTagFilter {
            let tagPlaceholders = tagsToFilter.map { _ in "?" }.joined(separator: ", ")
            if tagFilterMode == .include {
                // Include mode: Show only segments WITH selected tags
                tagCTE = """
                    tagged_segments AS (
                        SELECT DISTINCT segmentId
                        FROM segment_tag
                        WHERE tagId IN (\(tagPlaceholders))
                    )
                    """
                tagJoin = "INNER JOIN tagged_segments ts ON f.segmentId = ts.segmentId"
                // Update bindIndex to account for tag parameters in CTE
                bindIndex += tagsToFilter.count
            } else {
                // Exclude mode: Show segments WITHOUT selected tags (via NOT EXISTS in WHERE)
                tagCTE = ""
                tagJoin = ""
            }
        } else {
            tagCTE = ""
            tagJoin = ""
        }

        // Combine CTEs (only tag CTE now, window name uses direct WHERE clause)
        let combinedCTE = tagCTE.isEmpty ? "" : "WITH " + tagCTE

        // Now bind timestamp (after tag IDs in CTE, if any)
        bindIndex += 1

        // App filter - uses index on segment.bundleID (include or exclude mode)
        if let apps = filters.selectedApps, !apps.isEmpty {
            whereClauses.append(buildAppFilterClause(apps: apps, mode: filters.appFilterMode))
        }

        Self.appendMetadataStringFilter(
            columnName: "s.browserUrl",
            parsedFilter: browserUrlFilter,
            whereConditions: &whereClauses,
            bindValues: &metadataBindValues
        )
        Self.appendMetadataStringFilter(
            columnName: "s.windowName",
            parsedFilter: windowNameFilter,
            whereConditions: &whereClauses,
            bindValues: &metadataBindValues
        )

        let dateRangeFilter = Self.buildDateRangeUnionClause(
            ranges: filters.effectiveDateRanges,
            columnName: "f.createdAt"
        )
        if let dateRangeClause = dateRangeFilter.clause {
            whereClauses.append(dateRangeClause)
        }

        // Tag exclude filter: Exclude segments that have any of the selected tags
        if hasTagFilter && tagFilterMode == .exclude {
            let tagPlaceholders = tagsToFilter.map { _ in "?" }.joined(separator: ", ")
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_exclude
                    WHERE st_exclude.segmentId = f.segmentId
                    AND st_exclude.tagId IN (\(tagPlaceholders))
                )
                """)
        }

        // Hidden filter: Exclude segments with hidden tag (when .hide mode)
        // Only apply for Retrace database (Rewind doesn't have segment_tag)
        if shouldApplyTagFilters && filters.hiddenFilter == .hide, cachedHiddenTagId != nil {
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_hidden
                    WHERE st_hidden.segmentId = f.segmentId
                    AND st_hidden.tagId = ?
                )
                """)
        }

        if let commentClause = Self.buildCommentFilterClause(
            filters.commentFilter,
            isRewindDatabase: isRewindDatabase,
            segmentIDExpression: "f.segmentId"
        ) {
            whereClauses.append(commentClause)
        }

        // Always exclude p=4 frames (not yet readable) - only for Retrace, Rewind doesn't have this column
        if config.source != .rewind {
            whereClauses.append("f.processingStatus != 4")
        }

        let whereClause = whereClauses.joined(separator: " AND ")

        // Rewind database doesn't have processingStatus column
        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"
        let redactionReasonColumn = config.source == .rewind ? "NULL as redactionReason" : "f.redactionReason"

        // CTE filters tags first (small set), then joins with frames using segmentId index
        let sql = """
            \(combinedCTE)
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, \(processingStatusColumn), \(redactionReasonColumn),
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height, \(videoProcessingStateColumn(for: config))
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            \(tagJoin)
            LEFT JOIN video v ON f.videoId = v.id
            WHERE \(whereClause)
            ORDER BY f.createdAt DESC
            LIMIT ?
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        var currentBindIndex = 1

        // Bind tag IDs (they appear in the CTE) - ONLY for include mode
        if hasTagFilter && tagFilterMode == .include {
            for (index, tagId) in tagsToFilter.enumerated() {
                sqlite3_bind_int64(statement, Int32(currentBindIndex + index), tagId)
            }
            currentBindIndex += tagsToFilter.count
        }

        // Bind timestamp
        config.bindDate(effectiveTimestamp, to: statement, at: Int32(currentBindIndex))
        currentBindIndex += 1

        // Bind app bundle IDs
        if let apps = filters.selectedApps, !apps.isEmpty {
            for (index, app) in apps.enumerated() {
                sqlite3_bind_text(statement, Int32(currentBindIndex + index), (app as NSString).utf8String, -1, nil)
            }
            currentBindIndex += apps.count
        }

        for metadataValue in metadataBindValues {
            if let stringValue = metadataValue as? String {
                sqlite3_bind_text(statement, Int32(currentBindIndex), (stringValue as NSString).utf8String, -1, nil)
                currentBindIndex += 1
            }
        }

        // Bind date range union
        for date in dateRangeFilter.bindValues {
            config.bindDate(date, to: statement, at: Int32(currentBindIndex))
            currentBindIndex += 1
        }

        // Bind tag IDs for exclude mode (NOT EXISTS in WHERE clause)
        if hasTagFilter && tagFilterMode == .exclude {
            for (index, tagId) in tagsToFilter.enumerated() {
                sqlite3_bind_int64(statement, Int32(currentBindIndex + index), tagId)
            }
            currentBindIndex += tagsToFilter.count
        }

        // Bind hidden tag ID for NOT EXISTS clause (if applicable)
        // Only bind for Retrace database (Rewind doesn't have segment_tag)
        if shouldApplyTagFilters && filters.hiddenFilter == .hide, let hiddenTagId = cachedHiddenTagId {
            sqlite3_bind_int64(statement, Int32(currentBindIndex), hiddenTagId)
            currentBindIndex += 1
        }

        // Bind limit
        sqlite3_bind_int(statement, Int32(currentBindIndex), Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    /// Optimized filtered query for frames after timestamp - joins first to use bundleID index
    private func queryFramesAfterWithFiltersOptimized(
        timestamp: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria,
        isRewindDatabase: Bool = false
    ) throws -> [FrameWithVideoInfo] {
        var whereClauses = ["f.createdAt > ?"]
        var bindIndex = 1

        // Build tag filter including hidden filter logic
        // Note: Rewind database doesn't have segment_tag table, so skip tag filters for Rewind
        var tagsToFilter = Set<Int64>()
        let shouldApplyTagFilters = !isRewindDatabase

        if shouldApplyTagFilters {
            tagsToFilter = filters.selectedTags ?? Set<Int64>()

            // Apply hidden filter logic
            if let hiddenTagId = cachedHiddenTagId {
                switch filters.hiddenFilter {
                case .hide:
                    break
                case .onlyHidden:
                    tagsToFilter = [hiddenTagId]
                case .showAll:
                    break
                }
            }
        }

        let windowNameFilter = Self.decodeMetadataStringFilter(filters.windowNameFilter)
        let browserUrlFilter = Self.decodeMetadataStringFilter(filters.browserUrlFilter)
        var metadataBindValues: [Any] = []

        // Build CTE for tag filtering (filter tags first in subquery, then join to frames)
        let tagCTE: String
        let tagJoin: String
        let hasTagFilter = !tagsToFilter.isEmpty
        let tagFilterMode = filters.tagFilterMode

        if hasTagFilter {
            let tagPlaceholders = tagsToFilter.map { _ in "?" }.joined(separator: ", ")
            if tagFilterMode == .include {
                // Include mode: Show only segments WITH selected tags
                tagCTE = """
                    tagged_segments AS (
                        SELECT DISTINCT segmentId
                        FROM segment_tag
                        WHERE tagId IN (\(tagPlaceholders))
                    )
                    """
                tagJoin = "INNER JOIN tagged_segments ts ON f.segmentId = ts.segmentId"
                bindIndex += tagsToFilter.count
            } else {
                // Exclude mode: Show segments WITHOUT selected tags (via NOT EXISTS in WHERE)
                tagCTE = ""
                tagJoin = ""
            }
        } else {
            tagCTE = ""
            tagJoin = ""
        }

        // Combine CTEs (only tag CTE now, window name uses direct WHERE clause)
        let combinedCTE = tagCTE.isEmpty ? "" : "WITH " + tagCTE

        // Now bind timestamp (after tag IDs in CTE, if any)
        bindIndex += 1

        // App filter - uses index on segment.bundleID (include or exclude mode)
        if let apps = filters.selectedApps, !apps.isEmpty {
            whereClauses.append(buildAppFilterClause(apps: apps, mode: filters.appFilterMode))
        }

        Self.appendMetadataStringFilter(
            columnName: "s.browserUrl",
            parsedFilter: browserUrlFilter,
            whereConditions: &whereClauses,
            bindValues: &metadataBindValues
        )
        Self.appendMetadataStringFilter(
            columnName: "s.windowName",
            parsedFilter: windowNameFilter,
            whereConditions: &whereClauses,
            bindValues: &metadataBindValues
        )

        let dateRangeFilter = Self.buildDateRangeUnionClause(
            ranges: filters.effectiveDateRanges,
            columnName: "f.createdAt"
        )
        if let dateRangeClause = dateRangeFilter.clause {
            whereClauses.append(dateRangeClause)
        }

        // Tag exclude filter: Exclude segments that have any of the selected tags
        if hasTagFilter && tagFilterMode == .exclude {
            let tagPlaceholders = tagsToFilter.map { _ in "?" }.joined(separator: ", ")
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_exclude
                    WHERE st_exclude.segmentId = f.segmentId
                    AND st_exclude.tagId IN (\(tagPlaceholders))
                )
                """)
        }

        // Hidden filter: Exclude segments with hidden tag (when .hide mode)
        // Only apply for Retrace database (Rewind doesn't have segment_tag)
        if shouldApplyTagFilters && filters.hiddenFilter == .hide, cachedHiddenTagId != nil {
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_hidden
                    WHERE st_hidden.segmentId = f.segmentId
                    AND st_hidden.tagId = ?
                )
                """)
        }

        if let commentClause = Self.buildCommentFilterClause(
            filters.commentFilter,
            isRewindDatabase: isRewindDatabase,
            segmentIDExpression: "f.segmentId"
        ) {
            whereClauses.append(commentClause)
        }

        // Always exclude p=4 frames (not yet readable) - only for Retrace, Rewind doesn't have this column
        if config.source != .rewind {
            whereClauses.append("f.processingStatus != 4")
        }

        let whereClause = whereClauses.joined(separator: " AND ")

        // Rewind database doesn't have processingStatus column
        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"
        let redactionReasonColumn = config.source == .rewind ? "NULL as redactionReason" : "f.redactionReason"

        // CTE filters tags first (small set), then joins with frames using segmentId index
        let sql = """
            \(combinedCTE)
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, \(processingStatusColumn), \(redactionReasonColumn),
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height, \(videoProcessingStateColumn(for: config))
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            \(tagJoin)
            LEFT JOIN video v ON f.videoId = v.id
            WHERE \(whereClause)
            ORDER BY f.createdAt ASC
            LIMIT ?
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        var currentBindIndex = 1

        // Bind tag IDs (they appear in the CTE) - ONLY for include mode
        if hasTagFilter && tagFilterMode == .include {
            for (index, tagId) in tagsToFilter.enumerated() {
                sqlite3_bind_int64(statement, Int32(currentBindIndex + index), tagId)
            }
            currentBindIndex += tagsToFilter.count
        }

        // Bind timestamp
        config.bindDate(timestamp, to: statement, at: Int32(currentBindIndex))
        currentBindIndex += 1

        // Bind app bundle IDs
        if let apps = filters.selectedApps, !apps.isEmpty {
            for (index, app) in apps.enumerated() {
                sqlite3_bind_text(statement, Int32(currentBindIndex + index), (app as NSString).utf8String, -1, nil)
            }
            currentBindIndex += apps.count
        }

        for metadataValue in metadataBindValues {
            if let stringValue = metadataValue as? String {
                sqlite3_bind_text(statement, Int32(currentBindIndex), (stringValue as NSString).utf8String, -1, nil)
                currentBindIndex += 1
            }
        }

        // Bind date range union
        for date in dateRangeFilter.bindValues {
            config.bindDate(date, to: statement, at: Int32(currentBindIndex))
            currentBindIndex += 1
        }

        // Bind tag IDs for exclude mode (NOT EXISTS in WHERE clause)
        if hasTagFilter && tagFilterMode == .exclude {
            for (index, tagId) in tagsToFilter.enumerated() {
                sqlite3_bind_int64(statement, Int32(currentBindIndex + index), tagId)
            }
            currentBindIndex += tagsToFilter.count
        }

        // Bind hidden tag ID for NOT EXISTS clause (if applicable)
        // Only bind for Retrace database (Rewind doesn't have segment_tag)
        if shouldApplyTagFilters && filters.hiddenFilter == .hide, let hiddenTagId = cachedHiddenTagId {
            sqlite3_bind_int64(statement, Int32(currentBindIndex), hiddenTagId)
            currentBindIndex += 1
        }

        // Bind limit
        sqlite3_bind_int(statement, Int32(currentBindIndex), Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    /// Optimized filtered query for date range - joins first to use bundleID index
    private func queryFramesInRangeWithFiltersOptimized(
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria,
        isRewindDatabase: Bool = false
    ) throws -> [FrameWithVideoInfo] {
        let effectiveEndDate = config.applyCutoff(to: endDate)
        guard startDate < effectiveEndDate else { return [] }

        var whereClauses = ["f.createdAt >= ?", "f.createdAt <= ?"]
        var bindIndex = 1

        // Build tag filter including hidden filter logic
        var tagsToFilter = Set<Int64>()
        let shouldApplyTagFilters = !isRewindDatabase
        if shouldApplyTagFilters {
            tagsToFilter = filters.selectedTags ?? Set<Int64>()

            // Apply hidden filter logic
            if let hiddenTagId = cachedHiddenTagId {
                switch filters.hiddenFilter {
                case .hide:
                    break
                case .onlyHidden:
                    tagsToFilter = [hiddenTagId]
                case .showAll:
                    break
                }
            }
        }

        let windowNameFilter = Self.decodeMetadataStringFilter(filters.windowNameFilter)
        let browserUrlFilter = Self.decodeMetadataStringFilter(filters.browserUrlFilter)
        var metadataBindValues: [Any] = []

        // Build CTE for tag filtering (filter tags first in subquery, then join to frames)
        let tagCTE: String
        let tagJoin: String
        let hasTagFilter = !tagsToFilter.isEmpty
        let tagFilterMode = filters.tagFilterMode

        if hasTagFilter {
            let tagPlaceholders = tagsToFilter.map { _ in "?" }.joined(separator: ", ")
            if tagFilterMode == .include {
                // Include mode: Show only segments WITH selected tags
                tagCTE = """
                    tagged_segments AS (
                        SELECT DISTINCT segmentId
                        FROM segment_tag
                        WHERE tagId IN (\(tagPlaceholders))
                    )
                    """
                tagJoin = "INNER JOIN tagged_segments ts ON f.segmentId = ts.segmentId"
                bindIndex += tagsToFilter.count
            } else {
                // Exclude mode: Show segments WITHOUT selected tags (via NOT EXISTS in WHERE)
                tagCTE = ""
                tagJoin = ""
            }
        } else {
            tagCTE = ""
            tagJoin = ""
        }

        // Combine CTEs (only tag CTE now, window name uses direct WHERE clause)
        let combinedCTE = tagCTE.isEmpty ? "" : "WITH " + tagCTE

        // Now bind timestamps (after tag IDs in CTE, if any)
        bindIndex += 2  // For startDate and endDate

        // App filter - uses index on segment.bundleID (include or exclude mode)
        if let apps = filters.selectedApps, !apps.isEmpty {
            whereClauses.append(buildAppFilterClause(apps: apps, mode: filters.appFilterMode))
        }

        Self.appendMetadataStringFilter(
            columnName: "s.browserUrl",
            parsedFilter: browserUrlFilter,
            whereConditions: &whereClauses,
            bindValues: &metadataBindValues
        )
        Self.appendMetadataStringFilter(
            columnName: "s.windowName",
            parsedFilter: windowNameFilter,
            whereConditions: &whereClauses,
            bindValues: &metadataBindValues
        )

        let dateRangeFilter = Self.buildDateRangeUnionClause(
            ranges: filters.effectiveDateRanges,
            columnName: "f.createdAt"
        )
        if let dateRangeClause = dateRangeFilter.clause {
            whereClauses.append(dateRangeClause)
        }

        // Tag exclude filter: Exclude segments that have any of the selected tags
        if hasTagFilter && tagFilterMode == .exclude {
            let tagPlaceholders = tagsToFilter.map { _ in "?" }.joined(separator: ", ")
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_exclude
                    WHERE st_exclude.segmentId = f.segmentId
                    AND st_exclude.tagId IN (\(tagPlaceholders))
                )
                """)
        }

        // Hidden filter: Exclude segments with hidden tag (when .hide mode)
        // Skip for Rewind database - it doesn't have segment_tag table
        if shouldApplyTagFilters && filters.hiddenFilter == .hide, cachedHiddenTagId != nil {
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_hidden
                    WHERE st_hidden.segmentId = f.segmentId
                    AND st_hidden.tagId = ?
                )
                """)
        }

        if let commentClause = Self.buildCommentFilterClause(
            filters.commentFilter,
            isRewindDatabase: isRewindDatabase,
            segmentIDExpression: "f.segmentId"
        ) {
            whereClauses.append(commentClause)
        }

        // Always exclude p=4 frames (not yet readable) - only for Retrace, Rewind doesn't have this column
        if config.source != .rewind {
            whereClauses.append("f.processingStatus != 4")
        }

        let whereClause = whereClauses.joined(separator: " AND ")

        // Rewind database doesn't have processingStatus column
        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"
        let redactionReasonColumn = config.source == .rewind ? "NULL as redactionReason" : "f.redactionReason"

        // CTE filters tags first (small set), then joins with frames using segmentId index
        let sql = """
            \(combinedCTE)
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, \(processingStatusColumn), \(redactionReasonColumn),
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height, \(videoProcessingStateColumn(for: config))
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            \(tagJoin)
            LEFT JOIN video v ON f.videoId = v.id
            WHERE \(whereClause)
            ORDER BY f.createdAt ASC
            LIMIT ?
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { connection.finalize(statement) }

        var currentBindIndex = 1

        // Bind tag IDs (they appear in the CTE) - ONLY for include mode
        if hasTagFilter && tagFilterMode == .include {
            for (index, tagId) in tagsToFilter.enumerated() {
                sqlite3_bind_int64(statement, Int32(currentBindIndex + index), tagId)
            }
            currentBindIndex += tagsToFilter.count
        }

        // Bind timestamps
        config.bindDate(startDate, to: statement, at: Int32(currentBindIndex))
        currentBindIndex += 1
        config.bindDate(effectiveEndDate, to: statement, at: Int32(currentBindIndex))
        currentBindIndex += 1

        // Bind app bundle IDs
        if let apps = filters.selectedApps, !apps.isEmpty {
            for (index, app) in apps.enumerated() {
                sqlite3_bind_text(statement, Int32(currentBindIndex + index), (app as NSString).utf8String, -1, nil)
            }
            currentBindIndex += apps.count
        }

        for metadataValue in metadataBindValues {
            if let stringValue = metadataValue as? String {
                sqlite3_bind_text(statement, Int32(currentBindIndex), (stringValue as NSString).utf8String, -1, nil)
                currentBindIndex += 1
            }
        }

        for date in dateRangeFilter.bindValues {
            config.bindDate(date, to: statement, at: Int32(currentBindIndex))
            currentBindIndex += 1
        }

        // Bind tag IDs for exclude mode (NOT EXISTS in WHERE clause)
        if hasTagFilter && tagFilterMode == .exclude {
            for (index, tagId) in tagsToFilter.enumerated() {
                sqlite3_bind_int64(statement, Int32(currentBindIndex + index), tagId)
            }
            currentBindIndex += tagsToFilter.count
        }

        // Bind hidden tag ID for NOT EXISTS clause (if applicable)
        // Skip for Rewind database - it doesn't have segment_tag table
        if shouldApplyTagFilters && filters.hiddenFilter == .hide, let hiddenTagId = cachedHiddenTagId {
            sqlite3_bind_int64(statement, Int32(currentBindIndex), hiddenTagId)
            currentBindIndex += 1
        }

        // Bind limit
        sqlite3_bind_int(statement, Int32(currentBindIndex), Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    private func queryFramesWithVideoInfoBefore(
        timestamp: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria? = nil
    ) throws -> [FrameWithVideoInfo] {
        let effectiveTimestamp = config.applyCutoff(to: timestamp)

        // Build WHERE clause based on filters
        var whereClauses = ["createdAt < ?"]
        var bindIndex = 2 // 1 is for timestamp

        // App filter (include or exclude mode)
        if let apps = filters?.selectedApps, !apps.isEmpty {
            let filterMode = filters?.appFilterMode ?? .include
            whereClauses.append(buildAppFilterClause(apps: apps, mode: filterMode))
        }

        // Tag filter - need to join with segment_tag
        let needsTagJoin = filters?.selectedTags != nil && !(filters?.selectedTags!.isEmpty ?? true)
        let tagJoin = needsTagJoin ? """
            INNER JOIN segment_tag st ON f.segmentId = st.segmentId
            """ : ""

        if let tags = filters?.selectedTags, !tags.isEmpty {
            let placeholders = tags.map { _ in "?" }.joined(separator: ", ")
            whereClauses.append("st.tagId IN (\(placeholders))")
        }

        let whereClause = whereClauses.joined(separator: " AND ")

        // Rewind database doesn't have processingStatus column
        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"
        let redactionReasonColumn = config.source == .rewind ? "NULL as redactionReason" : "f.redactionReason"
        let subqueryProcessingStatus = config.source == .rewind ? "-1 as processingStatus" : "processingStatus"
        let subqueryRedactionReason = config.source == .rewind ? "NULL as redactionReason" : "redactionReason"

        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, \(processingStatusColumn), \(redactionReasonColumn),
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height, \(videoProcessingStateColumn(for: config))
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, encodingStatus, \(subqueryProcessingStatus), \(subqueryRedactionReason)
                FROM frame
                WHERE \(whereClause)
                ORDER BY createdAt DESC
                LIMIT ?
            ) f
            LEFT JOIN segment s ON f.segmentId = s.id
            \(tagJoin)
            LEFT JOIN video v ON f.videoId = v.id
            ORDER BY f.createdAt DESC
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        // Bind timestamp
        config.bindDate(effectiveTimestamp, to: statement, at: 1)

        // Bind app bundle IDs
        if let apps = filters?.selectedApps, !apps.isEmpty {
            for (index, app) in apps.enumerated() {
                sqlite3_bind_text(statement, Int32(bindIndex + index), (app as NSString).utf8String, -1, nil)
            }
            bindIndex += apps.count
        }

        // Bind tag IDs
        if let tags = filters?.selectedTags, !tags.isEmpty {
            for (index, tagId) in tags.enumerated() {
                sqlite3_bind_int64(statement, Int32(bindIndex + index), tagId)
            }
            bindIndex += tags.count
        }

        // Bind limit
        sqlite3_bind_int(statement, Int32(bindIndex), Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    private func queryFramesWithVideoInfoAfter(
        timestamp: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        filters: FilterCriteria? = nil
    ) throws -> [FrameWithVideoInfo] {
        // Build WHERE clause based on filters
        var whereClauses = ["createdAt > ?"]
        var bindIndex = 2 // 1 is for timestamp

        // App filter (include or exclude mode)
        if let apps = filters?.selectedApps, !apps.isEmpty {
            let filterMode = filters?.appFilterMode ?? .include
            whereClauses.append(buildAppFilterClause(apps: apps, mode: filterMode))
        }

        // Tag filter - need to join with segment_tag
        let needsTagJoin = filters?.selectedTags != nil && !(filters?.selectedTags!.isEmpty ?? true)
        let tagJoin = needsTagJoin ? """
            INNER JOIN segment_tag st ON f.segmentId = st.segmentId
            """ : ""

        if let tags = filters?.selectedTags, !tags.isEmpty {
            let placeholders = tags.map { _ in "?" }.joined(separator: ", ")
            whereClauses.append("st.tagId IN (\(placeholders))")
        }

        let whereClause = whereClauses.joined(separator: " AND ")

        // Rewind database doesn't have processingStatus column
        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"
        let redactionReasonColumn = config.source == .rewind ? "NULL as redactionReason" : "f.redactionReason"
        let subqueryProcessingStatus = config.source == .rewind ? "-1 as processingStatus" : "processingStatus"
        let subqueryRedactionReason = config.source == .rewind ? "NULL as redactionReason" : "redactionReason"

        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, \(processingStatusColumn), \(redactionReasonColumn),
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height, \(videoProcessingStateColumn(for: config))
            FROM (
                SELECT id, createdAt, segmentId, videoId, videoFrameIndex, encodingStatus, \(subqueryProcessingStatus), \(subqueryRedactionReason)
                FROM frame
                WHERE \(whereClause)
                ORDER BY createdAt ASC
                LIMIT ?
            ) f
            LEFT JOIN segment s ON f.segmentId = s.id
            \(tagJoin)
            LEFT JOIN video v ON f.videoId = v.id
            ORDER BY f.createdAt ASC
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        // Bind timestamp
        config.bindDate(timestamp, to: statement, at: 1)

        // Bind app bundle IDs
        if let apps = filters?.selectedApps, !apps.isEmpty {
            for (index, app) in apps.enumerated() {
                sqlite3_bind_text(statement, Int32(bindIndex + index), (app as NSString).utf8String, -1, nil)
            }
            bindIndex += apps.count
        }

        // Bind tag IDs
        if let tags = filters?.selectedTags, !tags.isEmpty {
            for (index, tagId) in tags.enumerated() {
                sqlite3_bind_int64(statement, Int32(bindIndex + index), tagId)
            }
            bindIndex += tags.count
        }

        // Bind limit
        sqlite3_bind_int(statement, Int32(bindIndex), Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = try? parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    private func queryFrameWithVideoInfoByID(
        id: FrameID,
        connection: DatabaseConnection,
        config: DatabaseConfig
    ) throws -> FrameWithVideoInfo? {
        // Rewind database doesn't have processingStatus column
        let processingStatusColumn = config.source == .rewind ? "-1 as processingStatus" : "f.processingStatus"
        let redactionReasonColumn = config.source == .rewind ? "NULL as redactionReason" : "f.redactionReason"

        let sql = """
            SELECT f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex, f.encodingStatus, \(processingStatusColumn), \(redactionReasonColumn),
                   s.bundleID, s.windowName, s.browserUrl,
                   v.path, v.frameRate, v.width, v.height, \(videoProcessingStateColumn(for: config))
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            WHERE f.id = ?
            """

        guard let statement = try connection.prepare(sql: sql) else { throw DataAdapterError.parseFailed }
        defer { connection.finalize(statement) }

        sqlite3_bind_int64(statement, 1, id.value)

        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw DataAdapterError.parseFailed }

        return try parseFrameWithVideoInfo(statement: statement, config: config)
    }

    private func getFrameVideoInfo(
        segmentID: VideoSegmentID,
        timestamp: Date,
        connection: DatabaseConnection,
        config: DatabaseConfig
    ) throws -> FrameVideoInfo? {
        let sql = """
            SELECT v.id, v.path, v.width, v.height, v.frameRate, f.videoFrameIndex,
                   \(videoProcessingStateColumn(for: config))
            FROM frame f
            LEFT JOIN video v ON f.videoId = v.id
            WHERE f.createdAt = ?
            LIMIT 1;
            """

        guard let statement = try? connection.prepare(sql: sql) else { return nil }
        defer { connection.finalize(statement) }

        config.bindDate(timestamp, to: statement, at: 1)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        guard let relativePath = getTextOrNil(statement, 1) else { return nil }

        let width = Int(sqlite3_column_int(statement, 2))
        let height = Int(sqlite3_column_int(statement, 3))
        let frameRate = sqlite3_column_double(statement, 4)
        let frameIndex = Int(sqlite3_column_int(statement, 5))
        let videoProcessingState = Int(sqlite3_column_int(statement, 6))

        let fullPath = "\(config.storageRoot)/\(relativePath)"

        return FrameVideoInfo(
            videoPath: fullPath,
            frameIndex: frameIndex,
            frameRate: frameRate,
            width: width,
            height: height,
            isVideoFinalized: videoProcessingState == 0
        )
    }

    private func querySegments(
        from startDate: Date,
        to endDate: Date,
        connection: DatabaseConnection,
        config: DatabaseConfig
    ) throws -> [Segment] {
        let sql = """
            SELECT id, bundleID, startDate, endDate, windowName, browserUrl, type
            FROM segment
            WHERE startDate >= ? AND startDate <= ?
            ORDER BY startDate ASC;
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        config.bindDate(startDate, to: statement, at: 1)
        config.bindDate(endDate, to: statement, at: 2)

        var segments: [Segment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let segment = try? parseSegment(statement: statement, config: config) {
                segments.append(segment)
            }
        }

        return segments
    }

    private func getAllOCRNodes(timestamp: Date, connection: DatabaseConnection, config: DatabaseConfig) throws -> [OCRNodeWithText] {
        // First find the frame ID
        let frameSql = "SELECT id FROM frame WHERE createdAt = ? LIMIT 1;"
        guard let frameStatement = try? connection.prepare(sql: frameSql) else { return [] }
        defer { connection.finalize(frameStatement) }

        config.bindDate(timestamp, to: frameStatement, at: 1)

        guard sqlite3_step(frameStatement) == SQLITE_ROW else { return [] }

        let frameID = FrameID(value: sqlite3_column_int64(frameStatement, 0))
        return try getAllOCRNodes(frameID: frameID, connection: connection)
    }

    private func getAllOCRNodes(frameID: FrameID, connection: DatabaseConnection) throws -> [OCRNodeWithText] {
        let sql = """
            SELECT
                n.id,
                n.nodeOrder,
                n.textOffset,
                n.textLength,
                n.leftX,
                n.topY,
                n.width,
                n.height,
                n.text,
                (COALESCE(sc.c0, '') || COALESCE(sc.c1, '')) as fullText,
                n.frameId
            FROM node n
            JOIN doc_segment ds ON n.frameId = ds.frameId
            JOIN searchRanking_content sc ON ds.docid = sc.id
            WHERE n.frameId = ?
            ORDER BY n.nodeOrder ASC;
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        sqlite3_bind_int64(statement, 1, frameID.value)

        var nodes: [OCRNodeWithText] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let node = parseOCRNodeFromRow(statement: statement) {
                nodes.append(node)
            }
        }

        return nodes
    }

    private func queryDistinctApps(connection: DatabaseConnection) throws -> [String] {
        let sql = """
            SELECT DISTINCT bundleID
            FROM segment
            WHERE bundleID IS NOT NULL AND bundleID != ''
            LIMIT 100;
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        var bundleIDs: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bundleIDPtr = sqlite3_column_text(statement, 0) else { continue }
            bundleIDs.append(String(cString: bundleIDPtr))
        }

        return bundleIDs
    }

    private func getURLBoundingBox(timestamp: Date, connection: DatabaseConnection, config: DatabaseConfig) throws -> URLBoundingBox? {
        // Get frameId and browserUrl
        let frameSQL = """
            SELECT f.id, s.browserUrl
            FROM frame f
            LEFT JOIN segment s ON f.segmentId = s.id
            WHERE f.createdAt = ?
            LIMIT 1;
            """

        guard let frameStmt = try? connection.prepare(sql: frameSQL) else { return nil }
        defer { connection.finalize(frameStmt) }

        config.bindDate(timestamp, to: frameStmt, at: 1)

        guard sqlite3_step(frameStmt) == SQLITE_ROW else { return nil }

        let frameId = sqlite3_column_int64(frameStmt, 0)
        guard let browserUrlPtr = sqlite3_column_text(frameStmt, 1) else { return nil }
        let browserUrl = String(cString: browserUrlPtr)
        guard !browserUrl.isEmpty else { return nil }
        let matchTerms = urlBoundingBoxMatchTerms(for: browserUrl)
        guard !matchTerms.isEmpty else { return nil }

        // Get FTS content
        let ftsSQL = """
            SELECT src.c0, src.c1
            FROM doc_segment ds
            JOIN searchRanking_content src ON ds.docid = src.id
            WHERE ds.frameId = ?
            LIMIT 1;
            """

        guard let ftsStmt = try? connection.prepare(sql: ftsSQL) else { return nil }
        defer { connection.finalize(ftsStmt) }

        sqlite3_bind_int64(ftsStmt, 1, frameId)

        guard sqlite3_step(ftsStmt) == SQLITE_ROW else { return nil }

        let c0Text = sqlite3_column_text(ftsStmt, 0).map { String(cString: $0) } ?? ""
        let c1Text = sqlite3_column_text(ftsStmt, 1).map { String(cString: $0) } ?? ""
        let ocrText = c0Text + c1Text
        let c0Length = c0Text.count

        // Get nodes
        let nodesSQL = """
            SELECT nodeOrder, textOffset, textLength, leftX, topY, width, height
            FROM node
            WHERE frameId = ?
            ORDER BY nodeOrder ASC;
            """

        guard let nodesStmt = try? connection.prepare(sql: nodesSQL) else { return nil }
        defer { connection.finalize(nodesStmt) }

        sqlite3_bind_int64(nodesStmt, 1, frameId)

        var bestMatch: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, score: Int)?
        var bestPathFallback: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, score: Int)?

        while sqlite3_step(nodesStmt) == SQLITE_ROW {
            let textOffset = Int(sqlite3_column_int(nodesStmt, 1))
            let textLength = Int(sqlite3_column_int(nodesStmt, 2))
            let leftX = CGFloat(sqlite3_column_double(nodesStmt, 3))
            let topY = CGFloat(sqlite3_column_double(nodesStmt, 4))
            let width = CGFloat(sqlite3_column_double(nodesStmt, 5))
            let height = CGFloat(sqlite3_column_double(nodesStmt, 6))
            let isOtherTextNode = textOffset >= c0Length

            let startIndex = ocrText.index(ocrText.startIndex, offsetBy: min(textOffset, ocrText.count), limitedBy: ocrText.endIndex) ?? ocrText.endIndex
            let endIndex = ocrText.index(startIndex, offsetBy: min(textLength, ocrText.count - textOffset), limitedBy: ocrText.endIndex) ?? ocrText.endIndex

            guard startIndex < endIndex else { continue }

            let nodeText = String(ocrText[startIndex..<endIndex])
            let normalizedNodeText = nodeText.lowercased()
            let hasPathLikeText = nodeText.contains("/") || nodeText.contains("?") || nodeText.contains("&") || nodeText.contains("=")
            if hasPathLikeText {
                // Fallback path for OCR cases where host text is missing but the address bar path is present.
                // Keep this conservative: top-of-frame, non-trivial width, and URL-like text.
                var fallbackScore = 0
                if topY <= 0.06 { fallbackScore += 95 }
                else if topY <= 0.11 { fallbackScore += 80 }
                else if topY <= 0.15 { fallbackScore += 55 }
                else if topY <= 0.20 { fallbackScore += 20 }

                let topBiasBonus = max(0, Int((0.22 - Double(topY)) * 200.0))
                fallbackScore += topBiasBonus
                if !nodeText.contains(" ") { fallbackScore += 60 }
                if width >= 0.05 { fallbackScore += 20 }
                if width >= 0.12 { fallbackScore += 20 }
                if isOtherTextNode { fallbackScore += 65 }

                if let current = bestPathFallback {
                    if fallbackScore > current.score || (fallbackScore == current.score && topY < current.y) {
                        bestPathFallback = (x: leftX, y: topY, width: width, height: height, score: fallbackScore)
                    }
                } else {
                    bestPathFallback = (x: leftX, y: topY, width: width, height: height, score: fallbackScore)
                }
            }

            let matchingTerm = matchTerms
                .filter { normalizedNodeText.contains($0) }
                .max(by: { $0.count < $1.count })
            guard let matchingTerm else { continue }

            var score = 0
            let matchRatio = Double(matchingTerm.count) / Double(max(nodeText.count, 1))
            if matchRatio > 0.6 { score += 40 }
            else if matchRatio > 0.3 { score += 28 }
            else { score += 14 }

            // Prefer higher text candidates; URL bars are consistently near the top.
            if topY <= 0.06 { score += 95 }
            else if topY <= 0.11 { score += 80 }
            else if topY <= 0.15 { score += 55 }
            else if topY <= 0.20 { score += 25 }

            let topBiasBonus = max(0, Int((0.22 - Double(topY)) * 260.0))
            score += topBiasBonus

            // Strongly prefer path/query-like URL text over bare hostnames.
            if hasPathLikeText && !nodeText.contains(" ") {
                score += 95
            } else if hasPathLikeText {
                score += 45
            }
            if isOtherTextNode {
                // `c1` / `otherText` is short chrome-like text; prioritize it for URL bar targeting.
                score += 85
            }

            if let current = bestMatch {
                if score > current.score || (score == current.score && topY < current.y) {
                    bestMatch = (x: leftX, y: topY, width: width, height: height, score: score)
                }
            } else {
                bestMatch = (x: leftX, y: topY, width: width, height: height, score: score)
            }
        }

        guard let bounds = bestMatch ?? bestPathFallback else { return nil }

        return URLBoundingBox(
            x: bounds.x,
            y: bounds.y,
            width: bounds.width,
            height: bounds.height,
            url: browserUrl
        )
    }

    private func urlBoundingBoxMatchTerms(for browserURL: String) -> [String] {
        var terms: [String] = []
        var seen = Set<String>()

        func appendHostVariants(_ rawHost: String?) {
            guard let rawHost else { return }
            let host = rawHost.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { return }
            if seen.insert(host).inserted { terms.append(host) }

            if host.hasPrefix("www.") {
                let withoutWWW = String(host.dropFirst(4))
                if !withoutWWW.isEmpty, seen.insert(withoutWWW).inserted {
                    terms.append(withoutWWW)
                }
            }
        }

        if let url = URL(string: browserURL) {
            appendHostVariants(url.host)

            // Handle redirect wrappers like google.com/url?q=https://target...
            let redirectQueryKeys: Set<String> = ["q", "url", "u", "target", "dest", "destination", "to"]
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                for item in components.queryItems ?? [] {
                    guard redirectQueryKeys.contains(item.name.lowercased()),
                          let value = item.value,
                          !value.isEmpty else {
                        continue
                    }
                    let decoded = value.removingPercentEncoding ?? value
                    appendHostVariants(URL(string: decoded)?.host)
                }
            }
        } else {
            appendHostVariants(browserURL)
        }

        return terms
    }

    /// Search every eligible observation before applying the final page boundary.
    /// Relevance and chronology share this constraint path so source-specific
    /// optimizations cannot silently truncate a sparse eligible result set.
    private static func searchConnection(
        query: SearchQuery,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        source: FrameSource,
        sourceCursor: SearchSourceCursor?,
        hiddenTagId: Int64?
    ) throws -> SearchResults {
        let startedAt = Date()
        let components = parseFTSQueryComponents(query.text)
        guard query.limit > 0, !components.includeParts.isEmpty else {
            return SearchResults(query: query, results: [], totalCount: 0, searchTimeMs: 0)
        }
        try Task.checkCancellation()

        let ftsQuery = scopeToSearchableTextColumns(components)
        let isRewind = source == .rewind
        var conditions = ["searchRanking MATCH ?"]
        var values: [Any] = [ftsQuery]

        if let cutoffDate = config.cutoffDate {
            conditions.append("f.createdAt < ?")
            values.append(config.formatDate(cutoffDate))
        }
        let dateFilter = buildDateRangeUnionClause(
            ranges: query.filters.effectiveDateRanges,
            columnName: "f.createdAt"
        )
        if let clause = dateFilter.clause {
            conditions.append(clause)
            values.append(contentsOf: dateFilter.bindValues.map(config.formatDate))
        }
        if let apps = query.filters.appBundleIDs, !apps.isEmpty {
            let placeholders = apps.map { _ in "?" }.joined(separator: ", ")
            conditions.append("s.bundleID IN (\(placeholders))")
            values.append(contentsOf: apps)
        }
        if let apps = query.filters.excludedAppBundleIDs, !apps.isEmpty {
            let placeholders = apps.map { _ in "?" }.joined(separator: ", ")
            conditions.append("s.bundleID NOT IN (\(placeholders))")
            values.append(contentsOf: apps)
        }
        appendMetadataStringFilter(
            columnName: "s.windowName",
            parsedFilter: decodeMetadataStringFilter(query.filters.windowNameFilter),
            whereConditions: &conditions,
            bindValues: &values
        )
        appendMetadataStringFilter(
            columnName: "s.browserUrl",
            parsedFilter: decodeMetadataStringFilter(query.filters.browserUrlFilter),
            whereConditions: &conditions,
            bindValues: &values
        )

        // EXISTS preserves one observation when several selected tags match it.
        // Imported stores have no native tag/comment tables.
        if !isRewind {
            if let tags = query.filters.selectedTagIds, !tags.isEmpty {
                let placeholders = tags.map { _ in "?" }.joined(separator: ", ")
                conditions.append("""
                    EXISTS (SELECT 1 FROM segment_tag st
                        WHERE st.segmentId = f.segmentId AND st.tagId IN (\(placeholders)))
                    """)
                values.append(contentsOf: tags)
            }
            if let tags = query.filters.excludedTagIds, !tags.isEmpty {
                let placeholders = tags.map { _ in "?" }.joined(separator: ", ")
                conditions.append("""
                    NOT EXISTS (SELECT 1 FROM segment_tag st
                        WHERE st.segmentId = f.segmentId AND st.tagId IN (\(placeholders)))
                    """)
                values.append(contentsOf: tags)
            }
            switch query.filters.hiddenFilter {
            case .hide:
                if let hiddenTagId {
                    conditions.append("""
                        NOT EXISTS (SELECT 1 FROM segment_tag st
                            WHERE st.segmentId = f.segmentId AND st.tagId = ?)
                        """)
                    values.append(hiddenTagId)
                }
            case .onlyHidden:
                if let hiddenTagId {
                    conditions.append("""
                        EXISTS (SELECT 1 FROM segment_tag st
                            WHERE st.segmentId = f.segmentId AND st.tagId = ?)
                        """)
                    values.append(hiddenTagId)
                } else {
                    conditions.append("0")
                }
            case .showAll:
                break
            }
        }
        if let commentClause = buildCommentFilterClause(
            query.filters.commentFilter,
            isRewindDatabase: isRewind,
            segmentIDExpression: "f.segmentId"
        ) {
            conditions.append(commentClause)
        }

        let sourceJoins = """
            FROM searchRanking
            JOIN doc_segment ds ON ds.docid = searchRanking.rowid
            JOIN frame f ON f.id = ds.frameId
            JOIN segment s ON s.id = f.segmentId
            """
        let filteredConditions = conditions.joined(separator: " AND ")
        let filteredValues = values
        let isRelevant = query.mode == .relevant
        let rankCursor = isRelevant ? decodeRelevantCursor(sourceCursor) : nil
        let hasCursor = isRelevant ? rankCursor != nil : sourceCursor != nil
        let order = query.sortOrder == .newestFirst ? "DESC" : "ASC"
        let sortClause = isRelevant ? "result_rank ASC, f.id ASC" : "f.createdAt \(order), f.id \(order)"

        if let rankCursor {
            values.append(contentsOf: [rankCursor.rank, rankCursor.rank, rankCursor.frameId] as [Any])
        } else if !isRelevant, let sourceCursor {
            let comparison = query.sortOrder == .newestFirst ? "<" : ">"
            conditions.append("(f.createdAt \(comparison) ? OR (f.createdAt = ? AND f.id \(comparison) ?))")
            let timestamp = config.formatDate(sourceCursor.timestamp)
            values.append(contentsOf: [timestamp, timestamp, sourceCursor.frameID])
        }

        // A one-row lookahead proves exhaustion without consuming the next page's
        // first observation. The cursor addresses the last consumed source row.
        let fetchLimit = query.limit == Int.max ? Int.max : query.limit + 1
        values.append(Int64(fetchLimit))
        let offsetClause: String
        if hasCursor {
            offsetClause = ""
        } else {
            offsetClause = "OFFSET ?"
            values.append(Int64(max(0, query.offset)))
        }
        let redactionColumn = isRewind ? "NULL" : "f.redactionReason"
        let rankColumn = isRelevant ? "matched_frames.result_rank" : "0.0"
        // A frame may have several legacy document links. Aggregate only its
        // matching document scores, preserving every distinct frame observation.
        // Materialize the narrow ID/rank pair because FTS5 ranking functions must
        // run inside their MATCH cursor, before the relational MIN aggregation.
        let rankingCTE = isRelevant ? """
            WITH matched_documents AS MATERIALIZED (
                SELECT f.id AS frame_id, bm25(searchRanking) AS document_rank
                \(sourceJoins)
                WHERE \(filteredConditions)
            ), matched_frames AS (
                SELECT frame_id, MIN(document_rank) AS result_rank
                FROM matched_documents GROUP BY frame_id
            )
            """ : ""
        let resultJoins = isRelevant ? """
            FROM matched_frames
            JOIN frame f ON f.id=matched_frames.frame_id
            JOIN segment s ON s.id=f.segmentId
            """ : sourceJoins
        let resultConditions = isRelevant
            ? (rankCursor == nil ? "1" : "(matched_frames.result_rank > ? OR (matched_frames.result_rank = ? AND f.id > ?))")
            : conditions.joined(separator: " AND ")
        // Legacy text writers can persist a flat extraction before the media
        // dimensions are known. Keep its source-bound selection token until
        // materialization can prove those dimensions from the selected media.
        let evidenceColumns = isRewind ? "NULL, NULL, NULL" : """
            evidence_store.storeID,
            CASE WHEN observation.width > 0 AND observation.height > 0 THEN observation.observationID ELSE NULL END,
            observation.preferredRevision
            """
        let evidenceJoins = isRewind ? "" : """
            LEFT JOIN screen_observation observation
                ON observation.nativeFrameID=f.id AND observation.source='native'
            LEFT JOIN evidence_store
                ON evidence_store.storeID=observation.storeID
                AND evidence_store.source='native' AND evidence_store.identity='native'
            """
        let sql = """
            \(rankingCTE)
            SELECT DISTINCT
                f.id, f.createdAt, f.segmentId, f.videoId, f.videoFrameIndex,
                v.path, v.frameRate, \(redactionColumn),
                s.bundleID, s.windowName, s.browserUrl,
                \(rankColumn) AS result_rank,
                \(evidenceColumns)
            \(resultJoins)
            LEFT JOIN video v ON v.id = f.videoId
            \(evidenceJoins)
            WHERE \(resultConditions)
            ORDER BY \(sortClause)
            LIMIT ? \(offsetClause)
            """
        guard let statement = try connection.prepare(sql: sql) else {
            throw DatabaseConnectionError.notConnected
        }
        defer { connection.finalize(statement) }
        bindSearchValues(values, to: statement)

        var results: [SearchResult] = []
        var lastRank: Double?
        var hasMore = false
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            if results.count == query.limit {
                hasMore = true
                break
            }
            let frameID = sqlite3_column_int64(statement, 0)
            let timestamp = config.parseDate(from: statement, column: 1) ?? Date()
            let bundleID = sqlite3_column_text(statement, 8).map { String(cString: $0) }
            let rank = sqlite3_column_double(statement, 11)
            let evidenceRef: ScreenEvidenceRef?
            if sqlite3_column_type(statement, 13) != SQLITE_NULL {
                guard let storeText = sqlite3_column_text(statement, 12),
                      let storeID = UUID(uuidString: String(cString: storeText)),
                      let observationText = sqlite3_column_text(statement, 13),
                      let observationID = UUID(uuidString: String(cString: observationText)),
                      sqlite3_column_type(statement, 14) == SQLITE_INTEGER,
                      sqlite3_column_int64(statement, 14) >= 0 else {
                    throw DatabaseConnectionError.executionFailed(sql: "screen observation reference",
                        error: "Indexed extraction identity is invalid")
                }
                evidenceRef = ScreenEvidenceRef(storeID: storeID, source: source,
                    observationID: observationID, frameID: FrameID(value: frameID),
                    extractionRevision: sqlite3_column_int64(statement, 14))
            } else {
                evidenceRef = nil
            }
            let result = SearchResult(
                id: FrameID(value: frameID),
                timestamp: timestamp,
                snippet: isRelevant ? "" : query.text,
                matchedText: query.text,
                relevanceScore: isRelevant ? abs(rank) / (1.0 + abs(rank)) : 0.5,
                metadata: FrameMetadata(
                    appBundleID: bundleID,
                    appName: bundleID?.components(separatedBy: ".").last,
                    windowName: sqlite3_column_text(statement, 9).map { String(cString: $0) },
                    browserURL: sqlite3_column_text(statement, 10).map { String(cString: $0) },
                    redactionReason: sqlite3_column_text(statement, 7).map { String(cString: $0) },
                    displayID: 0
                ),
                segmentID: AppSegmentID(value: sqlite3_column_int64(statement, 2)),
                videoID: VideoSegmentID(value: sqlite3_column_int64(statement, 3)),
                frameIndex: Int(sqlite3_column_int(statement, 4)),
                videoPath: sqlite3_column_text(statement, 5).map { String(cString: $0) },
                videoFrameRate: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 6),
                source: source,
                // Legacy textOffset/textLength values have no immutable extraction
                // revision tying merged text to these boxes. Exact evidence may
                // supply verified blocks after resolver validation.
                highlightNode: nil,
                evidenceRef: evidenceRef
            )
            results.append(result)
            lastRank = rank
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE || hasMore else {
            throw DatabaseConnectionError.executionFailed(sql: sql,
                error: String(cString: sqlite3_errmsg(connection.getConnection())))
        }

        let nextCursor: SearchPageCursor?
        if hasMore, let last = results.last {
            let next = SearchSourceCursor(
                timestamp: last.timestamp,
                frameID: last.id.value,
                relevanceRank: isRelevant ? lastRank : nil
            )
            nextCursor = isRewind ? SearchPageCursor(rewind: next) : SearchPageCursor(native: next)
        } else {
            nextCursor = nil
        }

        // Count the same eligible source observations, never an unconstrained
        // global FTS shortlist. Distinct IDs exclude accidental link duplication.
        let countSQL = """
            SELECT COUNT(DISTINCT f.id)
            \(sourceJoins)
            WHERE \(filteredConditions)
            """
        guard let countStatement = try connection.prepare(sql: countSQL) else {
            throw DatabaseConnectionError.notConnected
        }
        defer { connection.finalize(countStatement) }
        bindSearchValues(filteredValues, to: countStatement)
        guard sqlite3_step(countStatement) == SQLITE_ROW else {
            throw DatabaseConnectionError.executionFailed(sql: countSQL,
                error: String(cString: sqlite3_errmsg(connection.getConnection())))
        }
        let totalCount = Int(sqlite3_column_int64(countStatement, 0))
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        Log.info("[DataAdapter] Search page: source=\(source), mode=\(query.mode), rows=\(results.count), hasMore=\(hasMore), elapsedMs=\(elapsed)", category: .app)
        return SearchResults(query: query, results: results, totalCount: totalCount, searchTimeMs: elapsed, nextCursor: nextCursor)
    }

    private static func bindSearchValues(_ values: [Any], to statement: OpaquePointer?) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            if let string = value as? String {
                sqlite3_bind_text(statement, position, string, -1, transient)
            } else if let integer = value as? Int64 {
                sqlite3_bind_int64(statement, position, integer)
            } else if let double = value as? Double {
                sqlite3_bind_double(statement, position, double)
            }
        }
    }

    private struct FTSQueryComponents {
        let includeParts: [String]
        let excludeTerms: [String]
    }

    private static func parseFTSQueryComponents(_ text: String) -> FTSQueryComponents {
        let tokens = tokenizeSearchQuery(text)
        var includeParts: [String] = []
        var excludeTerms: [String] = []

        for token in tokens {
            if token == "-" {
                continue
            }

            if token.hasPrefix("-") && token.count > 1 {
                let rawExcluded = String(token.dropFirst())
                if rawExcluded.hasPrefix("\""), rawExcluded.hasSuffix("\""), rawExcluded.count > 1 {
                    let phrase = sanitizeFTSTerm(String(rawExcluded.dropFirst().dropLast()))
                    if !phrase.isEmpty {
                        excludeTerms.append("\"\(phrase)\"")
                    }
                } else {
                    let term = sanitizeFTSTerm(rawExcluded)
                    if !term.isEmpty {
                        excludeTerms.append("\"\(term)\"")
                    }
                }
                continue
            }

            if token.hasPrefix("\""), token.hasSuffix("\""), token.count > 1 {
                let phrase = sanitizeFTSTerm(String(token.dropFirst().dropLast()))
                if !phrase.isEmpty {
                    includeParts.append("\"\(phrase)\"")
                }
            } else {
                let term = sanitizeFTSTerm(token)
                if !term.isEmpty {
                    includeParts.append(formatUnquotedTerm(term))
                }
            }
        }

        return FTSQueryComponents(includeParts: includeParts, excludeTerms: excludeTerms)
    }

    /// Tokenize query while preserving quoted phrases and handling `-"phrase"` as one token.
    private static func tokenizeSearchQuery(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for char in query {
            if char == "\"" {
                if inQuotes {
                    current.append(char)
                    tokens.append(current)
                    current = ""
                    inQuotes = false
                } else {
                    if current == "-" {
                        current.append(char)
                        inQuotes = true
                        continue
                    }
                    if !current.isEmpty {
                        tokens.append(current)
                        current = ""
                    }
                    current.append(char)
                    inQuotes = true
                }
            } else if char.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    /// Restrict FTS MATCH to content columns only (exclude window title metadata).
    private static func scopeToSearchableTextColumns(_ components: FTSQueryComponents) -> String {
        guard !components.includeParts.isEmpty else {
            return "\"__retrace_no_match__\""
        }

        let includeClause = components.includeParts.joined(separator: " ")
        var parts = ["((text:(\(includeClause))) OR (otherText:(\(includeClause))))"]
        for excludedTerm in components.excludeTerms {
            parts.append("NOT text:(\(excludedTerm))")
            parts.append("NOT otherText:(\(excludedTerm))")
        }
        return parts.joined(separator: " ")
    }

    private static let encodedMetadataFilterPrefix = "__retrace_meta_filter_v1__"

    private struct EncodedMetadataFilterPayload: Codable {
        let includeTerms: [String]?
        let excludeTerms: [String]?
        // Legacy fields for backward compatibility.
        let mode: AppFilterMode?
        let terms: [String]?
    }

    private struct ParsedMetadataStringFilter {
        let includeTerms: [String]
        let excludeTerms: [String]

        var hasActiveFilters: Bool {
            !includeTerms.isEmpty || !excludeTerms.isEmpty
        }
    }

    private static func decodeMetadataStringFilter(_ rawValue: String?) -> ParsedMetadataStringFilter {
        guard let rawValue else {
            return ParsedMetadataStringFilter(includeTerms: [], excludeTerms: [])
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedMetadataStringFilter(includeTerms: [], excludeTerms: [])
        }

        guard trimmed.hasPrefix(encodedMetadataFilterPrefix) else {
            let normalized = normalizedMetadataStringFilterTerms([trimmed])
            return ParsedMetadataStringFilter(includeTerms: normalized, excludeTerms: [])
        }

        let encodedPayload = String(trimmed.dropFirst(encodedMetadataFilterPrefix.count))
        guard let data = Data(base64Encoded: encodedPayload),
              let payload = try? JSONDecoder().decode(EncodedMetadataFilterPayload.self, from: data) else {
            return ParsedMetadataStringFilter(includeTerms: [], excludeTerms: [])
        }

        let normalizedIncludeTerms = normalizedMetadataStringFilterTerms(payload.includeTerms ?? [])
        var normalizedExcludeTerms = normalizedMetadataStringFilterTerms(payload.excludeTerms ?? [])
        if !normalizedIncludeTerms.isEmpty || !normalizedExcludeTerms.isEmpty {
            let includeKeys = Set(normalizedIncludeTerms.map { $0.lowercased() })
            normalizedExcludeTerms.removeAll { includeKeys.contains($0.lowercased()) }
            return ParsedMetadataStringFilter(
                includeTerms: normalizedIncludeTerms,
                excludeTerms: normalizedExcludeTerms
            )
        }

        let normalizedLegacyTerms = normalizedMetadataStringFilterTerms(payload.terms ?? [])
        if payload.mode == .exclude {
            return ParsedMetadataStringFilter(includeTerms: [], excludeTerms: normalizedLegacyTerms)
        }
        return ParsedMetadataStringFilter(includeTerms: normalizedLegacyTerms, excludeTerms: [])
    }

    private static func appendMetadataStringFilter(
        columnName: String,
        parsedFilter: ParsedMetadataStringFilter,
        whereConditions: inout [String],
        bindValues: inout [Any]
    ) {
        for term in parsedFilter.includeTerms {
            guard let predicate = metadataStringFilterPredicate(columnName: columnName, term: term, negate: false) else {
                continue
            }
            whereConditions.append("(\(predicate.clause))")
            bindValues.append(contentsOf: predicate.bindValues)
        }

        for term in parsedFilter.excludeTerms {
            guard let predicate = metadataStringFilterPredicate(columnName: columnName, term: term, negate: true) else {
                continue
            }
            whereConditions.append("(\(predicate.clause))")
            bindValues.append(contentsOf: predicate.bindValues)
        }
    }

    private static func metadataStringFilterPredicate(
        columnName: String,
        term: String,
        negate: Bool
    ) -> (clause: String, bindValues: [String])? {
        guard let parsed = parsedMetadataStringFilterTerm(term) else { return nil }

        let op = negate ? "NOT LIKE" : "LIKE"
        switch parsed {
        case .exactPhrase(let phrase):
            return (
                clause: "COALESCE(\(columnName), '') \(op) ?",
                bindValues: ["%\(phrase)%"]
            )
        case .tokens(let tokens):
            let tokenJoiner = negate ? " OR " : " OR "
            let clause = tokens.map { _ in
                "COALESCE(\(columnName), '') \(op) ?"
            }.joined(separator: tokenJoiner)
            let bindValues = tokens.map { "%\($0)%" }
            return (clause: clause, bindValues: bindValues)
        }
    }

    private enum ParsedMetadataStringFilterTerm {
        case exactPhrase(String)
        case tokens([String])
    }

    private static func parsedMetadataStringFilterTerm(_ term: String) -> ParsedMetadataStringFilterTerm? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            let phrase = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty else { return nil }
            return .exactPhrase(phrase)
        }

        let tokens = trimmed
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return .tokens(tokens)
    }

    private static func normalizedMetadataStringFilterTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var normalizedTerms: [String] = []

        for term in terms {
            guard let normalized = normalizedMetadataStringFilterTerm(term) else { continue }
            let key = normalized.lowercased()
            if seen.insert(key).inserted {
                normalizedTerms.append(normalized)
            }
        }

        return normalizedTerms
    }

    private static func normalizedMetadataStringFilterTerm(_ term: String) -> String? {
        let collapsed = term
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Remove characters that have special meaning in FTS query syntax.
    private static func sanitizeFTSTerm(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: ":", with: "")
    }

    /// For unquoted terms, avoid prefix expansion on stopwords and very short tokens.
    /// This keeps terms like "a" as exact-token matches instead of broad "a*" prefix matches.
    private static func formatUnquotedTerm(_ term: String) -> String {
        if shouldUseExactMatch(term) {
            return "\"\(term)\""
        }
        return "\"\(term)\"*"
    }

    private static func shouldUseExactMatch(_ term: String) -> Bool {
        if term.count <= 2 {
            return true
        }
        return Self.exactMatchStopwords.contains(term.lowercased())
    }

    /// Decode relevant cursor from shared SearchSourceCursor.
    /// New cursors preserve the exact Double rank and actual capture timestamp.
    /// Accept legacy rank-as-Unix-time cursors, but not chronology-only cursors.
    private static func decodeRelevantCursor(_ sourceCursor: SearchSourceCursor?) -> (rank: Double, frameId: Int64)? {
        guard let sourceCursor else { return nil }
        if let rank = sourceCursor.relevanceRank, rank.isFinite {
            return (rank: rank, frameId: sourceCursor.frameID)
        }
        let legacyRank = sourceCursor.timestamp.timeIntervalSince1970
        guard legacyRank.isFinite, abs(legacyRank) < 1_000_000 else { return nil }
        return (rank: legacyRank, frameId: sourceCursor.frameID)
    }

    /// Build SQL clause for app filtering (IN or NOT IN based on filter mode)
    /// Returns the SQL clause like "s.bundleID IN (?, ?, ?)" or "s.bundleID NOT IN (?, ?, ?)"
    private func buildAppFilterClause(apps: Set<String>, mode: AppFilterMode, tableAlias: String = "s") -> String {
        let placeholders = apps.map { _ in "?" }.joined(separator: ", ")
        let operator_ = mode == .include ? "IN" : "NOT IN"
        return "\(tableAlias).bundleID \(operator_) (\(placeholders))"
    }

    /// Build SQL clause for comment-presence filtering.
    /// Returns nil when no filtering is required.
    private static func buildCommentFilterClause(
        _ filter: CommentFilter,
        isRewindDatabase: Bool,
        segmentIDExpression: String
    ) -> String? {
        switch filter {
        case .allFrames:
            return nil
        case .commentsOnly:
            if isRewindDatabase {
                // Rewind does not have comment-link data.
                return "1 = 0"
            }
            return """
                EXISTS (
                    SELECT 1 FROM segment_comment_link scl
                    WHERE scl.segmentId = \(segmentIDExpression)
                )
                """
        case .noComments:
            if isRewindDatabase {
                // Rewind has no comments, so all rows are "no comments".
                return nil
            }
            return """
                NOT EXISTS (
                    SELECT 1 FROM segment_comment_link scl
                    WHERE scl.segmentId = \(segmentIDExpression)
                )
                """
        }
    }

    // MARK: - Row Parsing

    private func videoProcessingStateColumn(for config: DatabaseConfig) -> String {
        config.source == .rewind
            ? "0 AS videoProcessingState"
            : "v.processingState AS videoProcessingState"
    }

    private func parseFrameWithVideoInfo(statement: OpaquePointer, config: DatabaseConfig) throws -> FrameWithVideoInfo {
        let id = FrameID(value: sqlite3_column_int64(statement, 0))

        guard let timestamp = config.parseDate(from: statement, column: 1) else {
            throw DataAdapterError.parseFailed
        }

        let segmentID = AppSegmentID(value: sqlite3_column_int64(statement, 2))
        let videoID = VideoSegmentID(value: sqlite3_column_int64(statement, 3))
        let videoFrameIndex = Int(sqlite3_column_int(statement, 4))

        let encodingStatusText = sqlite3_column_text(statement, 5)
        let encodingStatusString = encodingStatusText != nil ? String(cString: encodingStatusText!) : "pending"
        let encodingStatus = EncodingStatus(rawValue: encodingStatusString) ?? .pending
        let processingStatus = Int(sqlite3_column_int(statement, 6))

        let redactionReason = getTextOrNil(statement, 7)
        let bundleID = getTextOrNil(statement, 8) ?? ""
        let windowName = getTextOrNil(statement, 9)
        let browserUrl = getTextOrNil(statement, 10)

        let videoPath = getTextOrNil(statement, 11)
        let frameRate = sqlite3_column_type(statement, 12) != SQLITE_NULL ? sqlite3_column_double(statement, 12) : nil
        let width = sqlite3_column_type(statement, 13) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 13)) : nil
        let height = sqlite3_column_type(statement, 14) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 14)) : nil
        let videoProcessingState = sqlite3_column_count(statement) > 15
            ? Int(sqlite3_column_int(statement, 15))
            : 0

        let metadata = FrameMetadata(
            appBundleID: bundleID.isEmpty ? nil : bundleID,
            appName: bundleID.components(separatedBy: ".").last,
            windowName: windowName,
            browserURL: browserUrl,
            redactionReason: redactionReason,
            displayID: 0
        )

        let frame = FrameReference(
            id: id,
            timestamp: timestamp,
            segmentID: segmentID,
            videoID: videoID,
            frameIndexInSegment: videoFrameIndex,
            encodingStatus: encodingStatus,
            metadata: metadata,
            source: config.source
        )

        let videoInfo: FrameVideoInfo?
        if let relativePath = videoPath, let rate = frameRate, let w = width, let h = height {
            let fullPath = "\(config.storageRoot)/\(relativePath)"
            videoInfo = FrameVideoInfo(
                videoPath: fullPath,
                frameIndex: videoFrameIndex,
                frameRate: rate,
                width: w,
                height: h,
                isVideoFinalized: videoProcessingState == 0
            )
        } else {
            videoInfo = nil
        }

        return FrameWithVideoInfo(frame: frame, videoInfo: videoInfo, processingStatus: processingStatus)
    }

    private func parseSegment(statement: OpaquePointer, config: DatabaseConfig) throws -> Segment {
        let id = SegmentID(value: sqlite3_column_int64(statement, 0))
        let bundleID = getTextOrNil(statement, 1) ?? ""

        guard let startDate = config.parseDate(from: statement, column: 2),
              let endDate = config.parseDate(from: statement, column: 3) else {
            throw DataAdapterError.parseFailed
        }

        let windowName = getTextOrNil(statement, 4)
        let browserUrl = getTextOrNil(statement, 5)
        let type = Int(sqlite3_column_int(statement, 6))

        return Segment(
            id: id,
            bundleID: bundleID,
            startDate: startDate,
            endDate: endDate,
            windowName: windowName,
            browserUrl: browserUrl,
            type: type
        )
    }

    private func parseOCRNodeFromRow(statement: OpaquePointer) -> OCRNodeWithText? {
        let id = Int(sqlite3_column_int64(statement, 0))
        let textOffset = Int(sqlite3_column_int(statement, 2))
        let textLength = Int(sqlite3_column_int(statement, 3))
        let leftX = sqlite3_column_double(statement, 4)
        let topY = sqlite3_column_double(statement, 5)
        let width = sqlite3_column_double(statement, 6)
        let height = sqlite3_column_double(statement, 7)

        let text: String
        if let storedTextCStr = sqlite3_column_text(statement, 8) {
            let storedText = String(cString: storedTextCStr)
            text = storedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.legacyNodeText(statement: statement, column: 9, textOffset: textOffset, textLength: textLength)
                : storedText
        } else {
            text = Self.legacyNodeText(statement: statement, column: 9, textOffset: textOffset, textLength: textLength)
        }

        // Column 10: frameId for debugging
        let frameId = sqlite3_column_int64(statement, 10)

        return OCRNodeWithText(
            id: id,
            frameId: frameId,
            x: leftX,
            y: topY,
            width: width,
            height: height,
            text: text
        )
    }

    private static func legacyNodeText(
        statement: OpaquePointer,
        column: Int32,
        textOffset: Int,
        textLength: Int
    ) -> String {
        guard let fullTextCStr = sqlite3_column_text(statement, column) else { return "" }
        let fullText = String(cString: fullTextCStr)

        let startIndex = fullText.index(
            fullText.startIndex,
            offsetBy: textOffset,
            limitedBy: fullText.endIndex
        ) ?? fullText.endIndex

        let remainingLength = max(fullText.distance(from: startIndex, to: fullText.endIndex), 0)
        let safeLength = min(textLength, remainingLength)
        let endIndex = fullText.index(
            startIndex,
            offsetBy: safeLength,
            limitedBy: fullText.endIndex
        ) ?? fullText.endIndex

        return String(fullText[startIndex..<endIndex])
    }

    private func getTextOrNil(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }

    // MARK: - Combined Statistics (Retrace + Rewind)

    /// Get distinct dates that have frames from both Retrace and Rewind sources
    /// Returns dates sorted in descending order (newest first)
    public func getDistinctDates() throws -> [Date] {
        var allDates = Set<Date>()
        let calendar = Calendar.current

        // Get dates from Retrace
        let retraceDates = try queryDistinctDates(connection: retraceConnection)
        for date in retraceDates {
            allDates.insert(calendar.startOfDay(for: date))
        }

        // Get dates from Rewind if connected
        if let rewind = rewindConnection {
            let rewindDates = try queryDistinctDates(connection: rewind)
            for date in rewindDates {
                allDates.insert(calendar.startOfDay(for: date))
            }
        }

        return Array(allDates).sorted { $0 > $1 }
    }

    /// Query distinct dates from a specific connection
    private func queryDistinctDates(connection: DatabaseConnection) throws -> [Date] {
        let sql = """
            SELECT MIN(createdAt) as dayTimestamp
            FROM frame
            GROUP BY date(createdAt / 1000, 'unixepoch', 'localtime')
            ORDER BY dayTimestamp DESC
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var dates: [Date] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = sqlite3_column_int64(statement, 0)
            let date = Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
            dates.append(date)
        }

        return dates
    }

    /// Check if Rewind source is connected
    public var isRewindConnected: Bool {
        rewindConnection != nil
    }

    /// Get distinct dates from Rewind only (for parallel loading)
    public func getRewindDistinctDates() throws -> [Date] {
        guard let rewind = rewindConnection else { return [] }
        return try queryDistinctDates(connection: rewind)
    }

    /// Get Rewind storage root path for storage calculations (returns nil if Rewind not connected)
    public var rewindStorageRootPath: String? {
        guard rewindConnection != nil else { return nil }
        return AppPaths.expandedRewindStorageRoot
    }

    // MARK: - Calendar Hours Query

    /// Get distinct hours for a specific date that have frames
    /// Queries both databases and merges results to show all available hours
    public func getDistinctHoursForDate(_ date: Date) throws -> [Date] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        var allHours = Set<Date>()

        // Query Retrace database
        let retraceHours = try queryDistinctHoursRetrace(
            connection: retraceConnection,
            startOfDay: startOfDay,
            endOfDay: endOfDay
        )
        allHours.formUnion(retraceHours)

        // Query Rewind database if connected
        if let rewind = rewindConnection, let config = rewindConfig {
            let rewindHours = try queryDistinctHoursRewind(
                connection: rewind,
                config: config,
                startOfDay: startOfDay,
                endOfDay: endOfDay
            )
            allHours.formUnion(rewindHours)
        }

        // Return sorted by time (earliest first)
        return Array(allHours).sorted()
    }

    /// Query distinct hours from Retrace database (INTEGER timestamps in milliseconds)
    /// Returns the actual first frame timestamp for each hour (not normalized to :00:00)
    /// so that navigation can find frames around that time
    private func queryDistinctHoursRetrace(
        connection: DatabaseConnection,
        startOfDay: Date,
        endOfDay: Date
    ) throws -> [Date] {
        let startMs = Int64(startOfDay.timeIntervalSince1970 * 1000)
        let endMs = Int64(endOfDay.timeIntervalSince1970 * 1000)

        let sql = """
            SELECT MIN(createdAt) as hourTimestamp
            FROM frame
            WHERE createdAt >= ? AND createdAt < ?
            GROUP BY strftime('%H', createdAt / 1000, 'unixepoch', 'localtime')
            ORDER BY hourTimestamp ASC
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { connection.finalize(statement) }

        sqlite3_bind_int64(statement, 1, startMs)
        sqlite3_bind_int64(statement, 2, endMs)

        var hours: [Date] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestampMs = sqlite3_column_int64(statement, 0)
            // Return actual timestamp (not normalized) so navigation can find frames
            let timestamp = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)
            hours.append(timestamp)
        }

        return hours
    }

    /// Query distinct hours from Rewind database (TEXT ISO8601 timestamps)
    /// Returns the actual first frame timestamp for each hour (not normalized to :00:00)
    /// so that navigation can find frames around that time
    private func queryDistinctHoursRewind(
        connection: DatabaseConnection,
        config: DatabaseConfig,
        startOfDay: Date,
        endOfDay: Date
    ) throws -> [Date] {
        guard let formatter = config.dateFormatter else {
            return []
        }

        let startISO = formatter.string(from: startOfDay)
        let endISO = formatter.string(from: endOfDay)

        // Rewind stores TEXT timestamps like '2025-12-18T22:00:02.655'
        // Extract hour using substr (faster than strftime on TEXT)
        let sql = """
            SELECT MIN(createdAt) as hourTimestamp
            FROM frame
            WHERE createdAt >= ? AND createdAt < ?
            GROUP BY substr(createdAt, 12, 2)
            ORDER BY hourTimestamp ASC
            """

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { connection.finalize(statement) }

        sqlite3_bind_text(statement, 1, (startISO as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (endISO as NSString).utf8String, -1, nil)

        var hours: [Date] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else { continue }
            let isoString = String(cString: cString)
            // Return actual timestamp (not normalized) so navigation can find frames
            guard let timestamp = formatter.date(from: isoString) else { continue }
            hours.append(timestamp)
        }

        return hours
    }
}

// MARK: - Errors

public enum DataAdapterError: Error, LocalizedError {
    case notInitialized
    case sourceNotAvailable(FrameSource)
    case readOnlySource(FrameSource)
    case noSourceForTimestamp(Date)
    case frameNotFound
    case parseFailed

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "DataAdapter not initialized"
        case .sourceNotAvailable(let source):
            return "Data source not available: \(source.displayName)"
        case .readOnlySource(let source):
            return "\(source.displayName) is read-only. Delete its recordings in the source application."
        case .noSourceForTimestamp(let date):
            return "No data source available for timestamp: \(date)"
        case .frameNotFound:
            return "Frame not found"
        case .parseFailed:
            return "Failed to parse database row"
        }
    }
}
