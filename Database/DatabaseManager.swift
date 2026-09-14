import Foundation
import SQLCipher
import Shared
import CryptoKit

/// Main database manager implementing DatabaseProtocol
/// Owner: DATABASE agent
///
/// Thread Safety: Actor provides automatic serialization of all database operations
public actor DatabaseManager: DatabaseProtocol {

    // MARK: - Properties

    private var db: OpaquePointer?
    private let databasePath: String
    private var isInitialized = false
    private var consecutivePriorityClaims = 0

    /// Public accessor for the database connection (needed for query classes)
    public func getConnection() -> OpaquePointer? {
        db
    }

    /// Check if the database has been fully initialized
    public func isReady() -> Bool {
        isInitialized && db != nil
    }

    // MARK: - Initialization

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    /// Convenience initializer for in-memory database (testing)
    public init() {
        self.databasePath = ":memory:"
    }

    // MARK: - Lifecycle

    public func initialize() async throws {
        guard !isInitialized else { return }
        Log.debug("[DatabaseManager] initialize() started", category: .database)

        // Expand tilde in path if present
        let expandedPath = NSString(string: databasePath).expandingTildeInPath
        Log.debug("[DatabaseManager] Expanded path: \(expandedPath)", category: .database)

        // Create parent directory if needed (unless in-memory)
        // Check for both ":memory:" and URI-based in-memory databases (file:xxx?mode=memory)
        let isInMemory = databasePath == ":memory:" || databasePath.contains("mode=memory")
        if !isInMemory {
            let directory = (expandedPath as NSString).deletingLastPathComponent
            do {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                Log.critical("[DatabaseManager] Failed to create database directory: \(directory)", category: .database, error: error)
                throw DatabaseError.connectionFailed(underlying: "Directory creation failed: \(error.localizedDescription)")
            }
        }

        // Open database
        // Use sqlite3_open_v2 with SQLITE_OPEN_URI to support URI filenames like:
        // file:memdb_xxx?mode=memory&cache=private for unique in-memory databases
        // SQLITE_OPEN_FULLMUTEX enables thread-safe serialized access mode
        Log.debug("[DatabaseManager] Opening database...", category: .database)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(expandedPath, &db, flags, nil) == SQLITE_OK else {
            let errorMsg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            Log.critical("[DatabaseManager] Failed to open database at: \(expandedPath) - \(errorMsg)", category: .database)
            throw DatabaseError.connectionFailed(underlying: errorMsg)
        }
        Log.debug("[DatabaseManager] Database opened successfully", category: .database)

        // Set encryption key (SQLCipher) if encryption is enabled and not in-memory
        if !isInMemory {
            try await setEncryptionKey()
        }

        // Enable foreign keys and WAL mode
        Log.debug("[DatabaseManager] Executing pragmas...", category: .database)
        try executePragmas()
        Log.debug("[DatabaseManager] Pragmas executed", category: .database)

        // Run migrations
        Log.debug("[DatabaseManager] Running migrations...", category: .database)
        let migrationRunner = MigrationRunner(db: db!)
        try await migrationRunner.runMigrations()
        Log.debug("[DatabaseManager] Migrations complete", category: .database)

        // Offset AUTOINCREMENT to avoid collision with Rewind's frozen data
        Log.debug("[DatabaseManager] Setting AUTOINCREMENT offset...", category: .database)
        try await offsetAutoincrementFromRewind()
        Log.debug("[DatabaseManager] AUTOINCREMENT offset complete", category: .database)

        isInitialized = true
        Log.info("[DatabaseManager] Database initialized at: \(expandedPath)", category: .database)
    }

    public func close() async throws {
        guard let db = db else { return }

        // Checkpoint WAL before closing (if not in-memory)
        let isInMemory = databasePath == ":memory:" || databasePath.contains("mode=memory")
        if !isInMemory {
            try await checkpoint()
        }

        // Close connection.
        //
        // IMPORTANT: Do not manually finalize all outstanding statements here.
        // FTS5 maintains internal cached statements; finalizing them directly can corrupt
        // the virtual table state and crash during close (seen as SIGSEGV in sqlite3_finalize).
        // `sqlite3_close_v2` safely performs a deferred close if anything is still in use.
        let rc = sqlite3_close_v2(db)
        guard rc == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.connectionFailed(underlying: "Failed to close database (\(rc)): \(errorMsg)")
        }

        self.db = nil
        isInitialized = false
        Log.info("[DatabaseManager] Database closed", category: .database)
    }

    /// Owns a separate read transaction domain while preserving this database's encryption policy.
    public func makeRecallReadConnection() throws -> SQLiteConnection {
        guard isInitialized, let db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        if databasePath == ":memory:" || databasePath.contains("mode=memory") {
            return SQLiteConnection(db: db)
        }
        let reader = try SQLiteConnection(readOnlyDatabasePath: NSString(string: databasePath).expandingTildeInPath)
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        if defaults.object(forKey: "encryptionEnabled") as? Bool == true {
            // A reader never generates/replaces the writer's key. Keep key-bearing SQL out of errors/logs.
            let key = try loadKeyFromKeychain(service: AppPaths.keychainService, account: AppPaths.keychainAccount)
            guard key.count == 32, let pointer = reader.getConnection() else {
                throw DatabaseError.connectionFailed(underlying: "Encrypted reader unavailable")
            }
            let hex = key.map { String(format: "%02hhx", $0) }.joined()
            guard sqlite3_exec(pointer, "PRAGMA key = \"x'\(hex)'\";", nil, nil, nil) == SQLITE_OK else {
                throw DatabaseError.connectionFailed(underlying: "Encrypted reader unavailable")
            }
        }
        return reader
    }

    // MARK: - Audio Transcription Operations
    // ⚠️ RELEASE 2 ONLY - Audio transcription methods commented out for Release 1

    /*
    /// Insert audio transcription with word-level timestamps
    public func insertAudioTranscription(
        sessionID: String?,
        text: String,
        startTime: Date,
        endTime: Date,
        source: AudioSource,
        confidence: Double?,
        words: [TranscriptionWord]
    ) async throws -> Int64 {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        let queries = AudioTranscriptionQueries(db: db)
        return try await queries.insertTranscription(
            sessionID: sessionID,
            text: text,
            startTime: startTime,
            endTime: endTime,
            source: source,
            confidence: confidence,
            words: words
        )
    }

    /// Get audio transcriptions within a time range
    public func getAudioTranscriptions(
        from startDate: Date,
        to endDate: Date,
        source: AudioSource? = nil,
        limit: Int = 100
    ) async throws -> [AudioTranscription] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        let queries = AudioTranscriptionQueries(db: db)
        return try await queries.getTranscriptions(from: startDate, to: endDate, source: source, limit: limit)
    }

    /// Search audio transcriptions by text
    public func searchAudioTranscriptions(
        query: String,
        from startDate: Date? = nil,
        to endDate: Date? = nil,
        limit: Int = 50
    ) async throws -> [AudioTranscription] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        let queries = AudioTranscriptionQueries(db: db)
        return try await queries.searchTranscriptions(query: query, from: startDate, to: endDate, limit: limit)
    }

    /// Get transcriptions for a specific session
    public func getAudioTranscriptions(forSession sessionID: String) async throws -> [AudioTranscription] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        let queries = AudioTranscriptionQueries(db: db)
        return try await queries.getTranscriptions(forSession: sessionID)
    }

    /// Delete old audio transcriptions
    public func deleteAudioTranscriptions(olderThan date: Date) async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        let queries = AudioTranscriptionQueries(db: db)
        return try await queries.deleteTranscriptions(olderThan: date)
    }

    /// Get total audio transcription count
    public func getAudioTranscriptionCount() async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        let queries = AudioTranscriptionQueries(db: db)
        return try await queries.getTranscriptionCount()
    }
    */

    // MARK: - Frame Operations

    public func insertFrame(_ frame: FrameReference) async throws -> Int64 {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try PipelineSQL.transaction(db) {
            let id = try FrameQueries.insert(db: db, frame: frame)
            try ScreenEvidenceSQL.capture(db, frameID: id, descriptor: frame)
            return id
        }
    }

    public func getFrame(id: FrameID) async throws -> FrameReference? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getByID(db: db, id: id)
    }

    public func getFrames(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameReference] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getByTimeRange(db: db, from: startDate, to: endDate, limit: limit)
    }

    public func getFramesBefore(timestamp: Date, limit: Int) async throws -> [FrameReference] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getFramesBefore(db: db, timestamp: timestamp, limit: limit)
    }

    public func getFramesAfter(timestamp: Date, limit: Int) async throws -> [FrameReference] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getFramesAfter(db: db, timestamp: timestamp, limit: limit)
    }

    public func getMostRecentFrames(limit: Int) async throws -> [FrameReference] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getMostRecent(db: db, limit: limit)
    }

    // MARK: - Optimized Frame Queries with Video Info (Rewind-inspired)

    public func getFramesWithVideoInfo(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getByTimeRangeWithVideoInfo(db: db, from: startDate, to: endDate, limit: limit)
    }

    public func getMostRecentFramesWithVideoInfo(limit: Int) async throws -> [FrameWithVideoInfo] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getMostRecentWithVideoInfo(db: db, limit: limit)
    }

    public func getFramesWithVideoInfoBefore(timestamp: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getBeforeWithVideoInfo(db: db, timestamp: timestamp, limit: limit)
    }

    public func getFramesWithVideoInfoAfter(timestamp: Date, limit: Int) async throws -> [FrameWithVideoInfo] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getAfterWithVideoInfo(db: db, timestamp: timestamp, limit: limit)
    }

    public func getFrameWithVideoInfoByID(id: FrameID) async throws -> FrameWithVideoInfo? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getByIDWithVideoInfo(db: db, id: id)
    }

    public func getFrames(appBundleID: String, limit: Int, offset: Int) async throws -> [FrameReference] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getByApp(db: db, appBundleID: appBundleID, limit: limit, offset: offset)
    }

    public func deleteFrames(olderThan date: Date) async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.deleteOlderThan(db: db, date: date)
    }

    /// Delete frames newer than the specified date (for quick delete feature)
    public func deleteFrames(newerThan date: Date) async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.deleteNewerThan(db: db, date: date)
    }

    public func deleteFrame(id: FrameID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try FrameQueries.delete(db: db, id: id)
    }

    /// A selected native batch shares one writer transaction, including all derived evidence cleanup.
    public func deleteFrames(ids: [FrameID]) throws {
        guard let db else { throw DatabaseError.connectionFailed(underlying: "Database not initialized") }
        guard !ids.isEmpty else { return }
        try PipelineSQL.transaction(db) {
            for id in Set(ids) { try FrameQueries.delete(db: db, id: id) }
        }
    }

    public func getFrameCount() async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getCount(db: db)
    }

    /// Get all distinct dates that have frames (for calendar display)
    public func getDistinctDates() async throws -> [Date] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getDistinctDates(db: db)
    }

    /// Get distinct hours for a specific date that have frames
    public func getDistinctHoursForDate(_ date: Date) async throws -> [Date] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getDistinctHoursForDate(db: db, date: date)
    }

    public func frameExistsAtTimestamp(_ timestamp: Date) async throws -> Bool {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.existsAtTimestamp(db: db, timestamp: timestamp)
    }

    public func getFrameIDAtTimestamp(_ timestamp: Date) async throws -> Int64? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FrameQueries.getFrameIDAtTimestamp(db: db, timestamp: timestamp)
    }

    public func updateFrameVideoLink(frameID: FrameID, videoID: VideoSegmentID, frameIndex: Int) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try FrameQueries.updateVideoLink(db: db, frameId: frameID.value, videoId: videoID.value, videoFrameIndex: frameIndex)
    }

    // MARK: - OCR Node Operations

    /// Get all OCR nodes with their text for a specific frame
    /// Returns nodes with normalized coordinates (0.0-1.0) and extracted text
    public func getOCRNodesWithText(frameID: FrameID) async throws -> [OCRNodeWithText] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        // Query nodes with text directly - keep coordinates normalized (0-1)
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
                (COALESCE(sc.c0, '') || COALESCE(sc.c1, '')) AS fullText,
                n.frameId
            FROM node n
            JOIN doc_segment ds ON n.frameId = ds.frameId
            JOIN searchRanking_content sc ON ds.docid = sc.id
            WHERE n.frameId = ?
            ORDER BY n.nodeOrder ASC
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, frameID.value)

        var results: [OCRNodeWithText] = []
        while sqlite3_step(statement) == SQLITE_ROW {
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
                    ? Self.legacyNodeText(statement: statement!, column: 9, textOffset: textOffset, textLength: textLength)
                    : storedText
            } else {
                text = Self.legacyNodeText(statement: statement!, column: 9, textOffset: textOffset, textLength: textLength)
            }

            // Column 10: frameId for debugging
            let nodeFrameId = sqlite3_column_int64(statement, 10)

            results.append(OCRNodeWithText(
                id: id,
                frameId: nodeFrameId,
                x: leftX,
                y: topY,
                width: width,
                height: height,
                text: text
            ))
        }

        return results
    }

    // MARK: - Video Segment Operations (Video Files)

    public func insertVideoSegment(_ segment: VideoSegment) async throws -> Int64 {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.insert(db: db, segment: segment)
    }

    public func updateVideoSegment(id: Int64, width: Int, height: Int, fileSize: Int64) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try SegmentQueries.update(db: db, id: id, width: width, height: height, fileSize: fileSize)
    }

    public func getVideoSegment(id: VideoSegmentID) async throws -> VideoSegment? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.getByID(db: db, id: id)
    }

    public func getVideoSegment(containingTimestamp date: Date) async throws -> VideoSegment? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.getByTimestamp(db: db, timestamp: date)
    }

    public func getVideoSegments(from startDate: Date, to endDate: Date) async throws -> [VideoSegment] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.getByTimeRange(db: db, from: startDate, to: endDate)
    }

    public func deleteVideoSegment(id: VideoSegmentID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try PipelineSQL.transaction(db) {
            try FrameQueries.deleteForVideo(db: db, id: id)
            try SegmentQueries.delete(db: db, id: id)
        }
    }

    public func getTotalStorageBytes() async throws -> Int64 {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.getTotalStorageBytes(db: db)
    }

    // MARK: - Unfinalised Video Operations (Multi-Resolution Support)

    public func getUnfinalisedVideoByResolution(width: Int, height: Int) async throws -> UnfinalisedVideo? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.getUnfinalisedByResolution(db: db, width: width, height: height)
    }

    public func getAllUnfinalisedVideos() async throws -> [UnfinalisedVideo] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.getAllUnfinalised(db: db)
    }

    public func markVideoFinalized(id: Int64, frameCount: Int, fileSize: Int64) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try SegmentQueries.markFinalized(db: db, id: id, frameCount: frameCount, fileSize: fileSize)
    }

    public func finalizeOrphanedVideos(activeVideoIDs: Set<Int64>) async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try SegmentQueries.finalizeOrphanedVideos(db: db, activeVideoIDs: activeVideoIDs)
    }

    public func updateVideoSegment(id: Int64, width: Int, height: Int, fileSize: Int64, frameCount: Int) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try SegmentQueries.update(db: db, id: id, width: width, height: height, fileSize: fileSize, frameCount: frameCount)
    }

    // MARK: - Document Operations

    public func insertDocument(_ document: IndexedDocument) async throws -> Int64 {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try DocumentQueries.insert(db: db, document: document)
    }

    public func updateDocument(id: Int64, content: String) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try DocumentQueries.update(db: db, id: id, content: content)
    }

    public func deleteDocument(id: Int64) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try DocumentQueries.delete(db: db, id: id)
    }

    public func getDocument(frameID: FrameID) async throws -> IndexedDocument? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try DocumentQueries.getByFrameID(db: db, frameID: frameID)
    }

    // MARK: - Segment Operations (App Focus Sessions - Rewind Compatible)

    public func insertSegment(
        bundleID: String,
        startDate: Date,
        endDate: Date,
        windowName: String?,
        browserUrl: String?,
        type: Int
    ) async throws -> Int64 {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.insert(
            db: db,
            bundleID: bundleID,
            startDate: startDate,
            endDate: endDate,
            windowName: windowName,
            browserUrl: browserUrl,
            type: type
        )
    }

    public func updateSegmentEndDate(id: Int64, endDate: Date) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try AppSegmentQueries.updateEndDate(db: db, id: id, endDate: endDate)
    }

    /// Update segment browserURL.
    /// - Parameter onlyIfNull: When true, updates only if browserUrl is currently NULL.
    ///   When false, allows correcting a previously-written URL.
    public func updateSegmentBrowserURL(
        id: Int64,
        browserURL: String,
        onlyIfNull: Bool = true
    ) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try AppSegmentQueries.updateBrowserURL(
            db: db,
            id: id,
            browserURL: browserURL,
            onlyIfNull: onlyIfNull
        )
    }

    public func getSegment(id: Int64) async throws -> Segment? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getByID(db: db, id: id)
    }

    public func getSegments(from startDate: Date, to endDate: Date) async throws -> [Segment] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getByTimeRange(db: db, from: startDate, to: endDate)
    }

    public func getMostRecentSegment() async throws -> Segment? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getMostRecent(db: db)
    }

    public func getSegments(bundleID: String, limit: Int) async throws -> [Segment] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getByBundleID(db: db, bundleID: bundleID, limit: limit)
    }

    public func getSegments(
        bundleID: String,
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        offset: Int
    ) async throws -> [Segment] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getByBundleIDAndTimeRange(
            db: db,
            bundleID: bundleID,
            from: startDate,
            to: endDate,
            limit: limit,
            offset: offset
        )
    }

    /// Get segments filtered by bundle ID, time range, and window name or domain
    /// For browsers, filters by domain extracted from browserUrl; for other apps, filters by windowName
    public func getSegments(
        bundleID: String,
        windowNameOrDomain: String,
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        offset: Int
    ) async throws -> [Segment] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getByBundleIDAndWindowName(
            db: db,
            bundleID: bundleID,
            windowNameOrDomain: windowNameOrDomain,
            from: startDate,
            to: endDate,
            limit: limit,
            offset: offset
        )
    }

    public func getAppUsageStats(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(bundleID: String, duration: TimeInterval, uniqueItemCount: Int)] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getAppUsageStats(db: db, from: startDate, to: endDate)
    }

    public func getWindowUsageForApp(
        bundleID: String,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(windowName: String?, isWebsite: Bool, duration: TimeInterval, tabCount: Int?)] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getWindowUsageForApp(db: db, bundleID: bundleID, from: startDate, to: endDate)
    }

    public func getBrowserTabUsage(
        bundleID: String,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(windowName: String?, browserUrl: String?, duration: TimeInterval)] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getBrowserTabUsage(db: db, bundleID: bundleID, from: startDate, to: endDate)
    }

    public func getBrowserTabUsageForDomain(
        bundleID: String,
        domain: String,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(windowName: String?, browserUrl: String?, duration: TimeInterval)] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getBrowserTabUsageForDomain(db: db, bundleID: bundleID, domain: domain, from: startDate, to: endDate)
    }

    public func deleteSegment(id: Int64) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        // Capture linked comments before deleting the segment.
        // The FK on segment_comment_link cascades link deletion; we then clean orphan comments.
        let linkedCommentIDs = try getCommentIDsForSegment(db: db, segmentId: id)
        try AppSegmentQueries.delete(db: db, id: id)

        // Best-effort orphan cleanup after this segment's links are removed.
        for commentID in linkedCommentIDs {
            try cleanupOrphanedCommentIfNeeded(db: db, commentId: commentID)
        }
    }

    /// Get total captured duration across all segments in seconds
    public func getTotalCapturedDuration() async throws -> TimeInterval {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getTotalCapturedDuration(db: db)
    }

    /// Get captured duration for segments starting after a given date
    public func getCapturedDurationAfter(date: Date) async throws -> TimeInterval {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getCapturedDurationAfter(db: db, date: date)
    }

    // MARK: - Tag Operations

    /// Get all tags
    public func getAllTags() async throws -> [Tag] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT id, name FROM tag ORDER BY name ASC;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        var tags: [Tag] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            guard let namePtr = sqlite3_column_text(statement, 1) else { continue }
            let name = String(cString: namePtr)
            tags.append(Tag(id: TagID(value: id), name: name))
        }

        return tags
    }

    /// Create a new tag
    public func createTag(name: String) async throws -> Tag {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "INSERT INTO tag (name) VALUES (?);"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        let id = sqlite3_last_insert_rowid(db)
        return Tag(id: TagID(value: id), name: name)
    }

    /// Get a tag by name
    public func getTag(name: String) async throws -> Tag? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT id, name FROM tag WHERE name = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let id = sqlite3_column_int64(statement, 0)
        guard let namePtr = sqlite3_column_text(statement, 1) else { return nil }
        let tagName = String(cString: namePtr)
        return Tag(id: TagID(value: id), name: tagName)
    }

    /// Add a tag to a segment
    public func addTagToSegment(segmentId: SegmentID, tagId: TagID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "INSERT OR IGNORE INTO segment_tag (segmentId, tagId) VALUES (?, ?);"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, segmentId.value)
        sqlite3_bind_int64(statement, 2, tagId.value)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        let changes = sqlite3_changes(db)
        Log.debug("[DB] addTagToSegment: segmentId=\(segmentId.value), tagId=\(tagId.value), rows affected=\(changes)", category: .database)
    }

    /// Remove a tag from a segment
    public func removeTagFromSegment(segmentId: SegmentID, tagId: TagID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "DELETE FROM segment_tag WHERE segmentId = ? AND tagId = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, segmentId.value)
        sqlite3_bind_int64(statement, 2, tagId.value)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    /// Delete a tag entirely (CASCADE will remove all segment associations)
    public func deleteTag(tagId: TagID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "DELETE FROM tag WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, tagId.value)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    /// Get the count of segments that have a specific tag
    public func getSegmentCountForTag(tagId: TagID) async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT COUNT(*) FROM segment_tag WHERE tagId = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, tagId.value)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Get all tags for a segment
    public func getTagsForSegment(segmentId: SegmentID) async throws -> [Tag] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT t.id, t.name
            FROM tag t
            JOIN segment_tag st ON t.id = st.tagId
            WHERE st.segmentId = ?
            ORDER BY t.name ASC;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, segmentId.value)

        var tags: [Tag] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            guard let namePtr = sqlite3_column_text(statement, 1) else { continue }
            let name = String(cString: namePtr)
            tags.append(Tag(id: TagID(value: id), name: name))
        }

        return tags
    }

    /// Get all segment IDs that have the "hidden" tag
    public func getHiddenSegmentIds() async throws -> Set<SegmentID> {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT st.segmentId
            FROM segment_tag st
            JOIN tag t ON st.tagId = t.id
            WHERE t.name = 'hidden';
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        var segmentIds: Set<SegmentID> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            segmentIds.insert(SegmentID(value: id))
        }

        return segmentIds
    }

    /// Get a map of segment IDs to their tag IDs for efficient filtering
    public func getSegmentTagsMap() async throws -> [Int64: Set<Int64>] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT segmentId, tagId FROM segment_tag;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        var map: [Int64: Set<Int64>] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let segmentId = sqlite3_column_int64(statement, 0)
            let tagId = sqlite3_column_int64(statement, 1)

            if map[segmentId] == nil {
                map[segmentId] = []
            }
            map[segmentId]!.insert(tagId)
        }

        return map
    }

    /// Get a map of segment IDs to linked comment counts for tape-level comment indicators.
    public func getSegmentCommentCountsMap() async throws -> [Int64: Int] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT segmentId, COUNT(*)
            FROM segment_comment_link
            GROUP BY segmentId;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        var map: [Int64: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let segmentId = sqlite3_column_int64(statement, 0)
            let count = Int(sqlite3_column_int64(statement, 1))
            map[segmentId] = count
        }

        return map
    }

    // MARK: - Segment Comment Operations

    /// Create a new long-form comment
    public func createSegmentComment(
        body: String,
        author: String,
        attachments: [SegmentCommentAttachment] = [],
        frameID: FrameID? = nil
    ) async throws -> SegmentComment {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let timestamp = Schema.currentTimestamp()
        let attachmentsJSON = try encodeCommentAttachments(attachments)
        let sql = """
            INSERT INTO segment_comment (body, author, attachmentsJson, frameId, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_text(statement, 1, body, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, author, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, attachmentsJSON, -1, SQLITE_TRANSIENT)
        if let frameID {
            sqlite3_bind_int64(statement, 4, frameID.value)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_bind_int64(statement, 5, timestamp)
        sqlite3_bind_int64(statement, 6, timestamp)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        let id = sqlite3_last_insert_rowid(db)
        guard let comment = try getSegmentCommentByID(db: db, commentID: id) else {
            throw DatabaseError.recordNotFound(table: "segment_comment", id: String(id))
        }
        return comment
    }

    /// Update an existing comment body, author, and attachments
    public func updateSegmentComment(
        commentId: SegmentCommentID,
        body: String,
        author: String,
        attachments: [SegmentCommentAttachment]
    ) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let attachmentsJSON = try encodeCommentAttachments(attachments)
        let updatedAt = Schema.currentTimestamp()
        let sql = """
            UPDATE segment_comment
            SET body = ?, author = ?, attachmentsJson = ?, updatedAt = ?
            WHERE id = ?;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_text(statement, 1, body, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, author, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, attachmentsJSON, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 4, updatedAt)
        sqlite3_bind_int64(statement, 5, commentId.value)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    /// Delete a comment and all links, then best-effort cleanup attachment files
    public func deleteSegmentComment(commentId: SegmentCommentID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let attachments = try getCommentAttachments(db: db, commentId: commentId.value)
        try deleteCommentRow(db: db, commentId: commentId.value)
        cleanupAttachmentFiles(attachments)
    }

    /// Link an existing comment to a segment
    public func addCommentToSegment(segmentId: SegmentID, commentId: SegmentCommentID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "INSERT OR IGNORE INTO segment_comment_link (commentId, segmentId) VALUES (?, ?);"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, commentId.value)
        sqlite3_bind_int64(statement, 2, segmentId.value)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    /// Remove a segment-comment link and auto-delete orphaned comments
    public func removeCommentFromSegment(segmentId: SegmentID, commentId: SegmentCommentID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "DELETE FROM segment_comment_link WHERE segmentId = ? AND commentId = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, segmentId.value)
        sqlite3_bind_int64(statement, 2, commentId.value)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        // If this was the last link, delete the now-orphaned comment and clean attachments.
        try cleanupOrphanedCommentIfNeeded(db: db, commentId: commentId.value)
    }

    /// Get all comments linked to a segment
    public func getCommentsForSegment(segmentId: SegmentID) async throws -> [SegmentComment] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT c.id, c.body, c.author, c.attachmentsJson, c.frameId, c.createdAt, c.updatedAt
            FROM segment_comment c
            JOIN segment_comment_link scl ON c.id = scl.commentId
            WHERE scl.segmentId = ?
            ORDER BY c.createdAt ASC, c.id ASC;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, segmentId.value)

        var comments: [SegmentComment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            comments.append(parseSegmentComment(statement: statement!))
        }

        return comments
    }

    /// Get all linked comments with a representative segment context per comment.
    /// This powers the "All Comments" timeline without frame-first fan-out queries.
    public func getAllCommentTimelineEntries() async throws -> [(
        comment: SegmentComment,
        segmentID: SegmentID,
        appBundleID: String?,
        appName: String?,
        browserURL: String?,
        referenceTimestamp: Date
    )] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            WITH chosen_segment AS (
                SELECT scl.commentId, MIN(scl.segmentId) AS segmentId
                FROM segment_comment_link scl
                GROUP BY scl.commentId
            )
            SELECT
                c.id, c.body, c.author, c.attachmentsJson, c.frameId, c.createdAt, c.updatedAt,
                cs.segmentId, s.bundleID, s.browserUrl, s.startDate
            FROM segment_comment c
            JOIN chosen_segment cs ON cs.commentId = c.id
            LEFT JOIN segment s ON s.id = cs.segmentId
            ORDER BY c.createdAt ASC, c.id ASC;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        var entries: [(
            comment: SegmentComment,
            segmentID: SegmentID,
            appBundleID: String?,
            appName: String?,
            browserURL: String?,
            referenceTimestamp: Date
        )] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let comment = parseSegmentComment(statement: statement!)
            let segmentIDValue = sqlite3_column_int64(statement, 7)
            let appBundleID = sqlite3_column_text(statement, 8).map { String(cString: $0) }
            let browserURL = sqlite3_column_text(statement, 9).map { String(cString: $0) }
            let referenceTimestamp: Date
            if sqlite3_column_type(statement, 10) == SQLITE_NULL {
                referenceTimestamp = comment.createdAt
            } else {
                referenceTimestamp = Schema.timestampToDate(sqlite3_column_int64(statement, 10))
            }

            entries.append((
                comment: comment,
                segmentID: SegmentID(value: segmentIDValue),
                appBundleID: appBundleID,
                appName: nil,
                browserURL: browserURL,
                referenceTimestamp: referenceTimestamp
            ))
        }

        return entries
    }

    /// Full-text search comments by body text.
    /// Uses FTS5 index and always enforces capped pagination inputs.
    public func searchSegmentComments(query: String, limit: Int = 10, offset: Int = 0) async throws -> [SegmentComment] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let cappedLimit = min(max(limit, 1), 200)
        let cappedOffset = max(offset, 0)
        let ftsQuery = buildSegmentCommentFTSQuery(from: trimmed)
        guard !ftsQuery.isEmpty else { return [] }

        let sql = """
            SELECT c.id, c.body, c.author, c.attachmentsJson, c.frameId, c.createdAt, c.updatedAt
            FROM segment_comment_fts fts
            JOIN segment_comment c ON c.id = fts.rowid
            WHERE segment_comment_fts MATCH ?
            ORDER BY bm25(segment_comment_fts), c.createdAt DESC, c.id DESC
            LIMIT ? OFFSET ?;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_text(statement, 1, ftsQuery, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Int64(cappedLimit))
        sqlite3_bind_int64(statement, 3, Int64(cappedOffset))

        var comments: [SegmentComment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            comments.append(parseSegmentComment(statement: statement!))
        }

        return comments
    }

    /// Full-text search comments with representative segment context for each comment.
    /// This is used by the All Comments search UI to avoid follow-up context queries.
    public func searchCommentTimelineEntries(
        query: String,
        limit: Int = 10,
        offset: Int = 0
    ) async throws -> [(
        comment: SegmentComment,
        segmentID: SegmentID,
        appBundleID: String?,
        appName: String?,
        browserURL: String?,
        referenceTimestamp: Date
    )] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let cappedLimit = min(max(limit, 1), 200)
        let cappedOffset = max(offset, 0)
        let ftsQuery = buildSegmentCommentFTSQuery(from: trimmed)
        guard !ftsQuery.isEmpty else { return [] }

        let sql = """
            WITH matched_comments AS (
                SELECT
                    rowid AS commentId,
                    bm25(segment_comment_fts) AS rank
                FROM segment_comment_fts
                WHERE segment_comment_fts MATCH ?
                ORDER BY bm25(segment_comment_fts), rowid DESC
                LIMIT ? OFFSET ?
            ),
            chosen_segment AS (
                SELECT scl.commentId, MIN(scl.segmentId) AS segmentId
                FROM segment_comment_link scl
                JOIN matched_comments mc ON mc.commentId = scl.commentId
                GROUP BY scl.commentId
            )
            SELECT
                c.id, c.body, c.author, c.attachmentsJson, c.frameId, c.createdAt, c.updatedAt,
                cs.segmentId, s.bundleID, s.browserUrl, s.startDate
            FROM matched_comments mc
            JOIN segment_comment c ON c.id = mc.commentId
            JOIN chosen_segment cs ON cs.commentId = c.id
            LEFT JOIN segment s ON s.id = cs.segmentId
            ORDER BY mc.rank, c.createdAt DESC, c.id DESC;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_text(statement, 1, ftsQuery, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Int64(cappedLimit))
        sqlite3_bind_int64(statement, 3, Int64(cappedOffset))

        var entries: [(
            comment: SegmentComment,
            segmentID: SegmentID,
            appBundleID: String?,
            appName: String?,
            browserURL: String?,
            referenceTimestamp: Date
        )] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let comment = parseSegmentComment(statement: statement!)
            let segmentIDValue = sqlite3_column_int64(statement, 7)
            let appBundleID = sqlite3_column_text(statement, 8).map { String(cString: $0) }
            let browserURL = sqlite3_column_text(statement, 9).map { String(cString: $0) }
            let referenceTimestamp: Date
            if sqlite3_column_type(statement, 10) == SQLITE_NULL {
                referenceTimestamp = comment.createdAt
            } else {
                referenceTimestamp = Schema.timestampToDate(sqlite3_column_int64(statement, 10))
            }

            entries.append((
                comment: comment,
                segmentID: SegmentID(value: segmentIDValue),
                appBundleID: appBundleID,
                appName: nil,
                browserURL: browserURL,
                referenceTimestamp: referenceTimestamp
            ))
        }

        return entries
    }

    /// Get how many segments a comment is currently linked to
    public func getSegmentCountForComment(commentId: SegmentCommentID) async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try getSegmentCountForComment(db: db, commentId: commentId.value)
    }

    /// Get the first linked segment for a comment (deterministic by link creation).
    public func getFirstLinkedSegmentForComment(commentId: SegmentCommentID) async throws -> SegmentID? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT segmentId
            FROM segment_comment_link
            WHERE commentId = ?
            ORDER BY createdAt ASC, segmentId ASC
            LIMIT 1;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, commentId.value)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return SegmentID(value: sqlite3_column_int64(statement, 0))
    }

    /// Get the first frame in a segment (oldest by timestamp).
    public func getFirstFrameForSegment(segmentId: SegmentID) async throws -> FrameID? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT id
            FROM frame
            WHERE segmentId = ?
            ORDER BY createdAt ASC, id ASC
            LIMIT 1;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, segmentId.value)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return FrameID(value: sqlite3_column_int64(statement, 0))
    }

    // MARK: - Segment Comment Helpers

    private func getSegmentCommentByID(db: OpaquePointer, commentID: Int64) throws -> SegmentComment? {
        let sql = """
            SELECT id, body, author, attachmentsJson, frameId, createdAt, updatedAt
            FROM segment_comment
            WHERE id = ?;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, commentID)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return parseSegmentComment(statement: statement!)
    }

    private func parseSegmentComment(statement: OpaquePointer) -> SegmentComment {
        let id = sqlite3_column_int64(statement, 0)
        let body = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
        let author = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
        let attachmentsJSON = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "[]"
        let frameID: FrameID?
        if sqlite3_column_type(statement, 4) == SQLITE_NULL {
            frameID = nil
        } else {
            frameID = FrameID(value: sqlite3_column_int64(statement, 4))
        }
        let createdAt = Schema.timestampToDate(sqlite3_column_int64(statement, 5))
        let updatedAt = Schema.timestampToDate(sqlite3_column_int64(statement, 6))

        return SegmentComment(
            id: SegmentCommentID(value: id),
            body: body,
            author: author,
            attachments: decodeCommentAttachments(attachmentsJSON),
            frameID: frameID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func encodeCommentAttachments(_ attachments: [SegmentCommentAttachment]) throws -> String {
        do {
            let data = try JSONEncoder().encode(attachments)
            guard let json = String(data: data, encoding: .utf8) else {
                throw DatabaseError.queryExecutionFailed("Failed to convert encoded attachments to UTF-8 string")
            }
            return json
        } catch let error as DatabaseError {
            throw error
        } catch {
            throw DatabaseError.queryExecutionFailed("Failed to encode comment attachments: \(error.localizedDescription)")
        }
    }

    private func decodeCommentAttachments(_ attachmentsJSON: String) -> [SegmentCommentAttachment] {
        guard let data = attachmentsJSON.data(using: .utf8) else {
            return []
        }
        do {
            return try JSONDecoder().decode([SegmentCommentAttachment].self, from: data)
        } catch {
            Log.warning("[DB] Failed to decode comment attachments JSON: \(error.localizedDescription)", category: .database)
            return []
        }
    }

    private func getCommentAttachments(db: OpaquePointer, commentId: Int64) throws -> [SegmentCommentAttachment] {
        let sql = "SELECT attachmentsJson FROM segment_comment WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, commentId)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return []
        }

        let attachmentsJSON = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "[]"
        return decodeCommentAttachments(attachmentsJSON)
    }

    private func deleteCommentRow(db: OpaquePointer, commentId: Int64) throws {
        let sql = "DELETE FROM segment_comment WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, commentId)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func getCommentIDsForSegment(db: OpaquePointer, segmentId: Int64) throws -> [Int64] {
        let sql = "SELECT commentId FROM segment_comment_link WHERE segmentId = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, segmentId)

        var commentIDs: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            commentIDs.append(sqlite3_column_int64(statement, 0))
        }

        return commentIDs
    }

    private func getSegmentCountForComment(db: OpaquePointer, commentId: Int64) throws -> Int {
        let sql = "SELECT COUNT(*) FROM segment_comment_link WHERE commentId = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, commentId)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        return Int(sqlite3_column_int64(statement, 0))
    }

    private func buildSegmentCommentFTSQuery(from rawQuery: String) -> String {
        rawQuery
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .map { token in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " ")
    }

    private func cleanupOrphanedCommentIfNeeded(db: OpaquePointer, commentId: Int64) throws {
        guard try getSegmentCountForComment(db: db, commentId: commentId) == 0 else {
            return
        }

        let attachments = try getCommentAttachments(db: db, commentId: commentId)
        try deleteCommentRow(db: db, commentId: commentId)
        cleanupAttachmentFiles(attachments)
    }

    private func cleanupAttachmentFiles(_ attachments: [SegmentCommentAttachment]) {
        guard !attachments.isEmpty else { return }

        for attachment in attachments {
            let rawPath = attachment.filePath
            let resolvedPath: String
            if rawPath.hasPrefix("/") || rawPath.hasPrefix("~") {
                resolvedPath = NSString(string: rawPath).expandingTildeInPath
            } else {
                resolvedPath = (AppPaths.expandedStorageRoot as NSString).appendingPathComponent(rawPath)
            }

            guard FileManager.default.fileExists(atPath: resolvedPath) else {
                continue
            }

            do {
                try FileManager.default.removeItem(atPath: resolvedPath)
            } catch {
                Log.warning("[DB] Failed to remove attachment file at \(resolvedPath): \(error.localizedDescription)", category: .database)
            }
        }
    }

    // MARK: - OCR Node Operations (Rewind-compatible)

    public func insertNodes(
        frameID: FrameID,
        nodes: [(textOffset: Int, textLength: Int, text: String?, bounds: CGRect, windowIndex: Int?)],
        frameWidth: Int,
        frameHeight: Int
    ) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try NodeQueries.insertBatch(
            db: db,
            frameID: frameID,
            nodes: nodes,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )
    }

    private nonisolated static func legacyNodeText(
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

    public func getNodes(frameID: FrameID, frameWidth: Int, frameHeight: Int) async throws -> [OCRNode] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try NodeQueries.getByFrameID(
            db: db,
            frameID: frameID,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )
    }

    public func getNodesWithText(frameID: FrameID, frameWidth: Int, frameHeight: Int) async throws -> [(node: OCRNode, text: String)] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try NodeQueries.getNodesWithText(
            db: db,
            frameID: frameID,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )
    }

    public func deleteNodes(frameID: FrameID) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try NodeQueries.deleteByFrameID(db: db, frameID: frameID)
    }

    // MARK: - FTS Content Operations (Rewind-compatible)

    public func indexFrameText(
        mainText: String,
        chromeText: String?,
        windowTitle: String?,
        segmentId: Int64,
        frameId: Int64
    ) async throws -> Int64 {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        func executeTransactionSQL(_ sql: String) throws {
            var error: UnsafeMutablePointer<Int8>?
            guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
                sqlite3_free(error)
                throw DatabaseError.queryFailed(query: sql, underlying: message)
            }
        }

        try executeTransactionSQL("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let captured = try ScreenEvidenceSQL.commitLegacyText(db, frameID: FrameID(value: frameId),
                                                                  mainText: mainText, chromeText: chromeText)
            guard captured.segmentID.value == segmentId else { throw PipelineSQL.failure("Indexed segment differs from retained frame") }
            if let previousID = try FTSQueries.getDocidForFrame(db: db, frameId: frameId),
               let previous = try FTSQueries.getContent(db: db, docid: previousID),
               previous.mainText != mainText || (previous.chromeText ?? "") != (chromeText ?? "") {
                try NodeQueries.deleteByFrameID(db: db, frameID: FrameID(value: frameId))
            }
            try FTSQueries.deleteForFrame(db: db, frameId: frameId)
            let docid = try FTSQueries.indexFrame(
                db: db,
                mainText: mainText,
                chromeText: chromeText,
                windowTitle: captured.metadata.windowName,
                segmentId: segmentId,
                frameId: frameId
            )
            try executeTransactionSQL("COMMIT;")
            return docid
        } catch {
            try? executeTransactionSQL("ROLLBACK;")
            throw error
        }
    }

    public func getDocidForFrame(frameId: Int64) async throws -> Int64? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FTSQueries.getDocidForFrame(db: db, frameId: frameId)
    }

    public func getFTSContent(docid: Int64) async throws -> (mainText: String, chromeText: String?, windowTitle: String?)? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try FTSQueries.getContent(db: db, docid: docid)
    }

    public func deleteFTSContent(frameId: Int64) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try FTSQueries.deleteForFrame(db: db, frameId: frameId)
    }

    // MARK: - Daily Metrics Operations

    /// Record a single metric event (timeline open, search, text copy)
    public func recordMetricEvent(
        metricType: DailyMetricsQueries.MetricType,
        timestamp: Date = Date(),
        metadata: String? = nil
    ) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try DailyMetricsQueries.recordEvent(
            db: db,
            metricType: metricType,
            timestamp: timestamp,
            metadata: metadata
        )
    }

    /// Get daily counts for a metric type (for graphs)
    /// Returns array of (date, count) tuples sorted by date ascending
    public func getDailyMetrics(
        metricType: DailyMetricsQueries.MetricType,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(date: Date, value: Int64)] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try DailyMetricsQueries.getDailyCounts(
            db: db,
            metricType: metricType,
            from: startDate,
            to: endDate
        )
    }

    /// Get total count of a metric over a date range
    public func getDailyMetricCount(
        metricType: DailyMetricsQueries.MetricType,
        from startDate: Date,
        to endDate: Date
    ) async throws -> Int64 {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try DailyMetricsQueries.getTotalCount(
            db: db,
            metricType: metricType,
            from: startDate,
            to: endDate
        )
    }

    /// Get daily screen time totals (for graphs)
    /// Returns array of (date, totalSeconds) tuples sorted by date ascending
    public func getDailyScreenTime(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [(date: Date, value: Int64)] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getDailyScreenTime(
            db: db,
            from: startDate,
            to: endDate
        )
    }

    // MARK: - Statistics

    public func getStatistics() async throws -> DatabaseStatistics {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let frameCount = try FrameQueries.getCount(db: db)
        let segmentCount = try SegmentQueries.getCount(db: db) // Video segments
        let documentCount = try DocumentQueries.getCount(db: db)

        // Get database file size (doesn't work for in-memory)
        var databaseSizeBytes: Int64 = 0
        let isInMemory = databasePath == ":memory:" || databasePath.contains("mode=memory")
        if !isInMemory {
            let expandedPath = NSString(string: databasePath).expandingTildeInPath
            if let attributes = try? FileManager.default.attributesOfItem(atPath: expandedPath) {
                databaseSizeBytes = attributes[.size] as? Int64 ?? 0
            }
        }

        // Get oldest and newest frame dates
        let (oldestDate, newestDate) = try getFrameDateRange(db: db)

        return DatabaseStatistics(
            frameCount: frameCount,
            segmentCount: segmentCount,
            documentCount: documentCount,
            databaseSizeBytes: databaseSizeBytes,
            oldestFrameDate: oldestDate,
            newestFrameDate: newestDate
        )
    }

    /// Get app session count (from segment table, not video table)
    public func getAppSessionCount() async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        return try AppSegmentQueries.getCount(db: db)
    }

    /// Quick statistics query - single combined query for feedback diagnostics
    /// Only returns frameCount and sessionCount (what's actually displayed)
    public func getStatisticsQuick() async throws -> (frameCount: Int, sessionCount: Int) {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT
                (SELECT COUNT(*) FROM frame) as frameCount,
                (SELECT COUNT(*) FROM segment) as sessionCount
            """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(query: sql, underlying: "No result row")
        }

        let frameCount = Int(sqlite3_column_int64(statement, 0))
        let sessionCount = Int(sqlite3_column_int64(statement, 1))

        return (frameCount: frameCount, sessionCount: sessionCount)
    }

    // MARK: - Maintenance Operations

    /// Checkpoint the WAL file (merge WAL into main database and truncate)
    /// Call periodically to prevent WAL file from growing too large.
    /// Includes retry logic for external drives that may have slow I/O.
    public func checkpoint(maxRetries: Int = 3) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "PRAGMA wal_checkpoint(TRUNCATE);"
        var lastError: String?

        for attempt in 1...maxRetries {
            let checkpointStart = CFAbsoluteTimeGetCurrent()

            var errorMessage: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
            let message = errorMessage.map { String(cString: $0) }
            sqlite3_free(errorMessage)

            if result == SQLITE_OK {
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - checkpointStart) * 1000

                if elapsedMs > 1000 {
                    Log.warning("[DatabaseManager] Slow WAL checkpoint: \(String(format: "%.0f", elapsedMs))ms (external drive may be slow)", category: .database)
                }

                Log.info("[DatabaseManager] WAL checkpoint completed in \(String(format: "%.0f", elapsedMs))ms", category: .database)
                return
            }

            lastError = message ?? "Unknown error"
            Log.error("[DatabaseManager] WAL checkpoint failed (attempt \(attempt)/\(maxRetries)): \(lastError!)", category: .database)

            // Exponential backoff before retry
            if attempt < maxRetries {
                try await Task.sleep(for: .nanoseconds(Int64(UInt64(attempt) * 500_000_000)), clock: .continuous) // 500ms, 1s, 1.5s
            }
        }

        // All retries exhausted
        Log.critical("[DatabaseManager] WAL checkpoint failed after \(maxRetries) retries", category: .database)
        throw StorageError.walCheckpointFailed(retries: maxRetries)
    }

    /// Rebuild database file to reclaim space from deleted records
    /// WARNING: Can be slow on large databases. Run during idle time.
    public func vacuum() async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "VACUUM;"
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            sqlite3_free(errorMessage)
        }

        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            throw DatabaseError.queryFailed(query: sql, underlying: message)
        }

        Log.info("[DatabaseManager] Database vacuumed successfully", category: .database)
    }

    /// Update query planner statistics for better performance
    /// Run weekly or after significant data changes
    public func analyze() async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "ANALYZE;"
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            sqlite3_free(errorMessage)
        }

        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            throw DatabaseError.queryFailed(query: sql, underlying: message)
        }

        Log.info("[DatabaseManager] Database statistics analyzed successfully", category: .database)
    }

    // MARK: - Private Helpers

    /// Offset Retrace's AUTOINCREMENT to avoid ID collisions with Rewind's frozen data
    /// Queries Rewind's database for max IDs and sets Retrace's sequences to start after them
    private func offsetAutoincrementFromRewind() async throws {
        // Check if offset has already been applied (check sqlite_sequence table)
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        // Check if we've already set the offset (look for our marker)
        let checkSQL = "SELECT COUNT(*) FROM sqlite_sequence WHERE name = 'frame';"
        var checkStmt: OpaquePointer?
        defer { sqlite3_finalize(checkStmt) }

        guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else { return }

        // If we already have entries in sqlite_sequence, we've already inserted data - don't offset
        if sqlite3_step(checkStmt) == SQLITE_ROW {
            let count = sqlite3_column_int(checkStmt, 0)
            if count > 0 {
                Log.debug("[DatabaseManager] AUTOINCREMENT already initialized, skipping offset", category: .database)
                return
            }
        }

        // Query Rewind's database for max IDs
        let expandedRewindPath = NSString(string: AppPaths.rewindUnencryptedDBPath).expandingTildeInPath

        // Check if Rewind database exists
        guard FileManager.default.fileExists(atPath: expandedRewindPath) else {
            Log.debug("[DatabaseManager] Rewind database not found, skipping AUTOINCREMENT offset", category: .database)
            return
        }

        var rewindDB: OpaquePointer?
        defer {
            if let rewindDB = rewindDB {
                sqlite3_close(rewindDB)
            }
        }

        // Open Rewind database (read-only)
        guard sqlite3_open_v2(expandedRewindPath, &rewindDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            Log.debug("[DatabaseManager] Failed to open Rewind database, skipping AUTOINCREMENT offset", category: .database)
            return
        }

        // Get max frame ID from Rewind
        let maxFrameSQL = "SELECT COALESCE(MAX(id), 0) FROM frame;"
        var maxFrameStmt: OpaquePointer?
        defer { sqlite3_finalize(maxFrameStmt) }

        var maxFrameID: Int64 = 0
        if sqlite3_prepare_v2(rewindDB, maxFrameSQL, -1, &maxFrameStmt, nil) == SQLITE_OK,
           sqlite3_step(maxFrameStmt) == SQLITE_ROW {
            maxFrameID = sqlite3_column_int64(maxFrameStmt, 0)
        }

        // Get max video ID from Rewind
        let maxVideoSQL = "SELECT COALESCE(MAX(id), 0) FROM video;"
        var maxVideoStmt: OpaquePointer?
        defer { sqlite3_finalize(maxVideoStmt) }

        var maxVideoID: Int64 = 0
        if sqlite3_prepare_v2(rewindDB, maxVideoSQL, -1, &maxVideoStmt, nil) == SQLITE_OK,
           sqlite3_step(maxVideoStmt) == SQLITE_ROW {
            maxVideoID = sqlite3_column_int64(maxVideoStmt, 0)
        }

        Log.debug("[DatabaseManager] Rewind max IDs - frame: \(maxFrameID), video: \(maxVideoID)", category: .database)

        // Set Retrace's AUTOINCREMENT to start after Rewind's max IDs
        // We do this by inserting/updating the sqlite_sequence table

        if maxFrameID > 0 {
            let updateFrameSeq = """
                INSERT OR REPLACE INTO sqlite_sequence (name, seq) VALUES ('frame', ?);
                """
            var updateFrameStmt: OpaquePointer?
            defer { sqlite3_finalize(updateFrameStmt) }

            if sqlite3_prepare_v2(db, updateFrameSeq, -1, &updateFrameStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(updateFrameStmt, 1, maxFrameID)
                if sqlite3_step(updateFrameStmt) == SQLITE_DONE {
                    Log.debug("[DatabaseManager] Set frame AUTOINCREMENT to start at \(maxFrameID + 1)", category: .database)
                }
            }
        }

        if maxVideoID > 0 {
            let updateVideoSeq = """
                INSERT OR REPLACE INTO sqlite_sequence (name, seq) VALUES ('video', ?);
                """
            var updateVideoStmt: OpaquePointer?
            defer { sqlite3_finalize(updateVideoStmt) }

            if sqlite3_prepare_v2(db, updateVideoSeq, -1, &updateVideoStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(updateVideoStmt, 1, maxVideoID)
                if sqlite3_step(updateVideoStmt) == SQLITE_DONE {
                    Log.debug("[DatabaseManager] Set video AUTOINCREMENT to start at \(maxVideoID + 1)", category: .database)
                }
            }
        }
    }

    private func executePragmas() throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        for pragma in Schema.initializationPragmas {
            var errorMessage: UnsafeMutablePointer<CChar>?
            defer {
                sqlite3_free(errorMessage)
            }

            guard sqlite3_exec(db, pragma, nil, nil, &errorMessage) == SQLITE_OK else {
                let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
                Log.error("[DatabaseManager] PRAGMA execution failed: \(pragma) - \(message)", category: .database)
                throw DatabaseError.queryFailed(query: pragma, underlying: message)
            }
        }
    }

    private func getFrameDateRange(db: OpaquePointer) throws -> (oldest: Date?, newest: Date?) {
        let sql = """
            SELECT MIN(createdAt), MAX(createdAt)
            FROM frame;
            """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return (nil, nil)
        }

        var oldest: Date?
        var newest: Date?

        // Check if MIN is not NULL
        if sqlite3_column_type(statement, 0) != SQLITE_NULL {
            let oldestMs = sqlite3_column_int64(statement, 0)
            oldest = Schema.timestampToDate(oldestMs)
        }

        // Check if MAX is not NULL
        if sqlite3_column_type(statement, 1) != SQLITE_NULL {
            let newestMs = sqlite3_column_int64(statement, 1)
            newest = Schema.timestampToDate(newestMs)
        }

        return (oldest, newest)
    }

    /// Set encryption key for database using SQLCipher PRAGMA key
    /// NOTE: This requires SQLCipher to be compiled into the SQLite3 library
    private func setEncryptionKey() async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        // Check if encryption is enabled in UserDefaults
        // Default to false (disabled) - user must explicitly enable it during onboarding
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let encryptionEnabled = defaults.object(forKey: "encryptionEnabled") as? Bool ?? false

        // For unencrypted databases, simply don't set any PRAGMA key.
        // SQLCipher will operate as regular SQLite when no key is provided on a new/plaintext database.
        if !encryptionEnabled {
            Log.debug("[DatabaseManager] Database encryption disabled - no key set", category: .database)
            return
        }

        // Get or generate encryption key from Keychain
        let keychainService = AppPaths.keychainService
        let keychainAccount = AppPaths.keychainAccount

        var keyData: Data
        do {
            keyData = try loadKeyFromKeychain(service: keychainService, account: keychainAccount)
            Log.debug("[DatabaseManager] Loaded existing database encryption key from Keychain", category: .database)
        } catch {
            // Generate new key
            let key = SymmetricKey(size: .bits256)
            keyData = key.withUnsafeBytes { Data($0) }
            try saveKeyToKeychain(keyData, service: keychainService, account: keychainAccount)
            Log.debug("[DatabaseManager] Generated and saved new database encryption key to Keychain", category: .database)
        }

        // Set key using PRAGMA key (SQLCipher)
        // Convert key data to hex string for PRAGMA
        let keyHex = keyData.map { String(format: "%02hhx", $0) }.joined()
        let pragma = "PRAGMA key = \"x'\(keyHex)'\";"

        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            sqlite3_free(errorMessage)
        }

        guard sqlite3_exec(db, pragma, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            Log.error("[DatabaseManager] Failed to set database encryption key: \(message)", category: .database)
            Log.warning("[DatabaseManager] SQLCipher may not be available - falling back to unencrypted database", category: .database)
            // Don't throw - fall back to unencrypted database
            return
        }

        Log.debug("[DatabaseManager] Database encryption key set successfully", category: .database)
    }

    /// Save encryption key to Keychain
    private func saveKeyToKeychain(_ key: Data, service: String, account: String) throws {
        // Use kSecAttrAccessibleAfterFirstUnlock with kSecAttrSynchronizable = false
        // This prevents the keychain password prompt on every app launch
        // kSecAttrSynchronizable = false ensures it stays local and doesn't prompt for iCloud Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false  // Don't sync to iCloud, stay local
        ]

        // Delete existing item first
        SecItemDelete(query as CFDictionary)

        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DatabaseError.connectionFailed(underlying: "Failed to save encryption key to Keychain (status: \(status))")
        }
    }

    /// Load encryption key from Keychain
    private func loadKeyFromKeychain(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw DatabaseError.connectionFailed(underlying: "Failed to load encryption key from Keychain")
        }
        return data
    }

    // MARK: - Static Keychain Setup (for onboarding)

    /// Setup encryption key in Keychain during onboarding
    /// Call this when user selects "Yes" for encryption and clicks Continue
    public static func setupEncryptionKeychain() throws {
        let keychainService = AppPaths.keychainService
        let keychainAccount = AppPaths.keychainAccount

        // Check if key already exists (without retrieving data to avoid prompts)
        let checkQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let checkStatus = SecItemCopyMatching(checkQuery as CFDictionary, &result)

        if checkStatus == errSecSuccess {
            // Key already exists, no need to create again
            Log.debug("[DatabaseManager] Encryption key already exists in Keychain, skipping setup", category: .database)
            return
        }

        // Generate new key
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        // Use kSecAttrAccessibleAfterFirstUnlock directly (without SecAccessControlCreateWithFlags)
        // This allows access without prompting after the device is unlocked
        // kSecAttrSynchronizable = false ensures it stays local and doesn't prompt for iCloud Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false  // Don't sync to iCloud, stay local
        ]

        // Delete existing item first (in case of partial state)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "com.retrace.keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to save encryption key to Keychain (status: \(status))"])
        }

        Log.debug("[DatabaseManager] Generated and saved new database encryption key to Keychain during onboarding", category: .database)
    }

    /// Verify we can read the encryption key from Keychain
    /// This triggers the keychain access prompt if needed, so it's best called immediately after setup
    public static func verifyEncryptionKeychain() throws -> Bool {
        let keychainService = AppPaths.keychainService
        let keychainAccount = AppPaths.keychainAccount

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let _ = result as? Data else {
            throw NSError(domain: "com.retrace.keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to verify encryption key in Keychain (status: \(status))"])
        }

        return true
    }

    /// Delete the encryption key from Keychain (useful for resetting)
    public static func deleteEncryptionKeychain() {
        let keychainService = AppPaths.keychainService
        let keychainAccount = AppPaths.keychainAccount

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]

        let status = SecItemDelete(deleteQuery as CFDictionary)
        if status == errSecSuccess {
            Log.debug("[DatabaseManager] Deleted encryption key from Keychain", category: .database)
        } else if status == errSecItemNotFound {
            Log.debug("[DatabaseManager] No encryption key found in Keychain to delete", category: .database)
        } else {
            Log.error("[DatabaseManager] Failed to delete encryption key from Keychain (status: \(status))", category: .database)
        }
    }

    // MARK: - Processing Queue Operations

    /// Enqueue a frame for OCR processing
    /// Only enqueues frames with processingStatus = 0 (pending)
    @discardableResult
    public func enqueueFrameForProcessing(frameID: Int64, priority: Int = 0) async throws -> Bool {
        guard let db else { throw DatabaseError.connectionFailed(underlying: "Database not initialized") }
        return try PipelineSQL.transaction(db) {
            try PipelineSQL.enqueue(db, frameID: frameID, priority: priority)
        }
    }

    /// Claim atomically: manual work first, then three current captures per historical turn.
    /// Automatic priorities expire after 60 seconds; all historical work shares FIFO order.
    public func dequeueFrameForProcessing() async throws -> (queueID: Int64, frameID: Int64, retryCount: Int)? {
        guard let db else { throw DatabaseError.connectionFailed(underlying: "Database not initialized") }
        enum Lane { case manual, current, historical }
        let currentCutoff = Schema.dateToTimestamp(Date().addingTimeInterval(-60))
        let selected = try PipelineSQL.transaction(db) { () -> (Int64, Int64, Int, Lane)? in
            func candidate(_ lane: Lane) throws -> (Int64, Int64, Int, Lane)? {
                let condition: String
                let index: String
                let order: String
                let values: [PipelineSQL.Value]
                switch lane {
                case .manual:
                    condition = "pq.priority > 10"
                    index = "idx_processing_queue_priority"
                    order = "pq.priority DESC,pq.enqueuedAt ASC,pq.id ASC"
                    values = []
                case .current:
                    condition = "pq.priority BETWEEN 1 AND 10 AND f.createdAt >= ?"
                    index = "idx_processing_queue_priority"
                    order = "pq.priority DESC,pq.enqueuedAt ASC,pq.id ASC"
                    values = [.integer(currentCutoff)]
                case .historical:
                    condition = """
                        (pq.priority IS NULL OR pq.priority <= 0 OR (pq.priority BETWEEN 1 AND 10 AND f.createdAt < ?))
                        AND NOT EXISTS (
                            SELECT 1 FROM processing_queue preferred INDEXED BY idx_processing_queue_frame_id
                            WHERE preferred.frameId=pq.frameId AND
                                (preferred.priority > 10 OR (preferred.priority BETWEEN 1 AND 10 AND f.createdAt >= ?))
                        )
                        """
                    index = "idx_processing_queue_enqueued"
                    order = "pq.enqueuedAt ASC,pq.id ASC"
                    values = [.integer(currentCutoff), .integer(currentCutoff)]
                }
                return try PipelineSQL.query(db, """
                    SELECT pq.id,pq.frameId,pq.retryCount,pq.priority
                    FROM processing_queue pq INDEXED BY \(index)
                    CROSS JOIN frame f ON f.id=pq.frameId
                    WHERE f.processingStatus=0 AND \(condition)
                    ORDER BY \(order) LIMIT 1
                    """, values) { (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1), Int(sqlite3_column_int($0, 2)), lane) }.first
            }
            // Manual requests retain precedence without consuming the current/history budget.
            var item = try candidate(.manual)
            if item == nil && consecutivePriorityClaims >= 3 { item = try candidate(.historical) }
            if item == nil { item = try candidate(.current) }
            if item == nil && consecutivePriorityClaims < 3 { item = try candidate(.historical) }
            guard let item else { return nil }
            try PipelineSQL.execute(db, "UPDATE frame SET processingStatus=1 WHERE id=? AND processingStatus=0", [.integer(item.1)])
            guard sqlite3_changes(db) == 1 else { throw PipelineSQL.failure("Frame was claimed concurrently") }
            try PipelineSQL.execute(db, "DELETE FROM processing_queue WHERE frameId=?", [.integer(item.1)])
            return item
        }
        guard let selected else { return nil }
        switch selected.3 {
        case .manual: break
        case .current: consecutivePriorityClaims = min(3, consecutivePriorityClaims + 1)
        case .historical: consecutivePriorityClaims = 0
        }
        return (selected.0, selected.1, selected.2)
    }

    /// Get the current processing queue depth
    public func getProcessingQueueDepth() async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT COUNT(DISTINCT pq.frameId) FROM processing_queue pq JOIN frame f ON f.id=pq.frameId WHERE f.processingStatus=0;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Get count of frames that are pending or currently processing (status 0 or 1)
    public func getPendingFrameCount() async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT COUNT(*) FROM frame WHERE processingStatus IN (0, 1);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Get separate counts for pending (status 0) and processing (status 1) frames
    public func getFrameStatusCounts() async throws -> (pending: Int, processing: Int) {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT processingStatus, COUNT(*) FROM frame WHERE processingStatus IN (0, 1) GROUP BY processingStatus;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        var pending = 0
        var processing = 0

        while sqlite3_step(stmt) == SQLITE_ROW {
            let status = Int(sqlite3_column_int(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            if status == 0 {
                pending = count
            } else if status == 1 {
                processing = count
            }
        }

        return (pending: pending, processing: processing)
    }

    /// Clear the entire processing queue (used when changing database location)
    /// WARNING: This removes all pending OCR work! Only call when intentionally switching databases.
    public func clearProcessingQueue() async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "DELETE FROM processing_queue;"
        var error: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let errorMsg = error.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(error)
            throw DatabaseError.queryFailed(query: sql, underlying: errorMsg)
        }

        Log.warning("[Database] Cleared processing queue (database location changed)", category: .database)
    }

    /// Get frame IDs that were in "processing" status (crashed during OCR)
    public func getCrashedProcessingFrameIDs() async throws -> [Int64] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        // processingStatus = 1 means "processing" (crashed)
        let sql = "SELECT id FROM frame WHERE processingStatus = 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        var frameIDs: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            frameIDs.append(sqlite3_column_int64(stmt, 0))
        }

        return frameIDs
    }

    /// Get count of frames processed per minute for the last N minutes
    /// Returns dictionary of [minuteOffset: count] where offset 0 = current minute
    public func getFramesProcessedPerMinute(lastMinutes: Int) async throws -> [Int: Int] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        // Query frames by processedAt (when OCR completed) in the last N minutes
        // processedAt is stored as INTEGER Unix timestamp in milliseconds
        // Use clean minute boundaries (floor to start of minute) for consistent bucketing
        // e.g., 17:05:23 becomes minute key for 17:05:00
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let currentMinuteMs = (nowMs / 60000) * 60000  // Floor to start of current minute
        let cutoffMs = currentMinuteMs - Int64(lastMinutes * 60 * 1000)

        // Group by which minute bucket the frame was processed in
        // minuteOffset 0 = current minute (e.g., 17:05:00 to 17:05:59)
        // minuteOffset 1 = previous minute (e.g., 17:04:00 to 17:04:59)
        let sql = """
            SELECT
                CAST((\(currentMinuteMs) - (processedAt / 60000) * 60000) / 60000 AS INTEGER) as minuteOffset,
                COUNT(*) as count
            FROM frame
            WHERE processedAt IS NOT NULL
              AND processedAt >= \(cutoffMs)
            GROUP BY minuteOffset
            ORDER BY minuteOffset ASC;
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        var result: [Int: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let minuteOffset = Int(sqlite3_column_int(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            if minuteOffset >= 0 && minuteOffset < lastMinutes {
                result[minuteOffset] = count
            }
        }

        Log.debug("[DatabaseManager] getFramesProcessedPerMinute returned \(result.count) minute buckets, total: \(result.values.reduce(0, +)) frames", category: .database)

        return result
    }

    /// Retry a frame by re-adding it to the processing queue with incremented retry count
    public func retryFrameProcessing(frameID: Int64, retryCount: Int, errorMessage: String) async throws {
        guard let db else { throw DatabaseError.connectionFailed(underlying: "Database not initialized") }
        _ = try PipelineSQL.transaction(db) {
            try PipelineSQL.enqueue(db, frameID: frameID, priority: 0, retryCount: retryCount, error: errorMessage)
        }
    }

    /// Update frame processing status
    /// When status is 2 (completed), also sets processedAt timestamp
    public func updateFrameProcessingStatus(frameID: Int64, status: Int) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        // If status is 2 (completed), also set processedAt timestamp
        let sql: String
        if status == 2 {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            sql = "UPDATE frame SET processingStatus = ?, processedAt = \(nowMs) WHERE id = ?;"
        } else {
            sql = "UPDATE frame SET processingStatus = ? WHERE id = ?;"
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int(stmt, 1, Int32(status))
        sqlite3_bind_int64(stmt, 2, frameID)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Get the processing status for a specific frame
    /// Returns nil if the frame doesn't exist
    public func getFrameProcessingStatus(frameID: Int64) async throws -> Int? {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT processingStatus FROM frame WHERE id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(stmt, 1, frameID)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil // Frame not found
        }

        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Mark frame as readable from video file (processingStatus 4 -> 0)
    /// Called when frame is confirmed to be written to video file
    public func markFrameReadable(frameID: Int64) async throws {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        // Only update if status is 4 (not yet readable)
        let sql = "UPDATE frame SET processingStatus = 0 WHERE id = ? AND processingStatus = 4;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(stmt, 1, frameID)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Get processing status for multiple frames in a single query
    /// Returns dictionary of frameID -> processingStatus (0=pending, 1=processing, 2=completed, 3=failed, 4=not yet readable)
    public func getFrameProcessingStatuses(frameIDs: [Int64]) async throws -> [Int64: Int] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        guard !frameIDs.isEmpty else {
            return [:]
        }

        // Build parameterized query for batch lookup
        let placeholders = frameIDs.map { _ in "?" }.joined(separator: ", ")
        let sql = "SELECT id, processingStatus FROM frame WHERE id IN (\(placeholders));"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        // Bind all frame IDs
        for (index, frameID) in frameIDs.enumerated() {
            sqlite3_bind_int64(stmt, Int32(index + 1), frameID)
        }

        var results: [Int64: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let frameID = sqlite3_column_int64(stmt, 0)
            let status = Int(sqlite3_column_int(stmt, 1))
            results[frameID] = status
        }

        return results
    }

    /// Check if a frame is currently in the processing queue
    public func isFrameInProcessingQueue(frameID: Int64) async throws -> Bool {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = "SELECT 1 FROM processing_queue WHERE frameId = ? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(stmt, 1, frameID)

        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Estimate the frame's 1-based position using the current manual/current/history schedule.
    /// New arrivals and capture aging may change it; claimed/completed frames have no position.
    public func getFrameQueuePosition(frameID: Int64) async throws -> Int? {
        guard let db else { throw DatabaseError.connectionFailed(underlying: "Database not initialized") }
        let cutoff = Schema.dateToTimestamp(Date().addingTimeInterval(-60))
        // A legacy duplicate may occupy several lanes. The frame belongs to its best lane.
        let target = try PipelineSQL.query(db, """
            SELECT pq.id,pq.priority,pq.enqueuedAt,
                CASE WHEN pq.priority > 10 THEN 0
                     WHEN pq.priority BETWEEN 1 AND 10 AND f.createdAt >= ? THEN 1 ELSE 2 END AS lane
            FROM processing_queue pq INDEXED BY idx_processing_queue_frame_id
            CROSS JOIN frame f ON f.id=pq.frameId
            WHERE pq.frameId=? AND f.processingStatus=0
            ORDER BY lane ASC,
                CASE WHEN pq.priority > 10 OR (pq.priority BETWEEN 1 AND 10 AND f.createdAt >= ?) THEN pq.priority ELSE 0 END DESC,
                pq.enqueuedAt ASC,pq.id ASC LIMIT 1
            """, [.integer(cutoff), .integer(frameID), .integer(cutoff)]) {
                (id: sqlite3_column_int64($0, 0), priority: Int(sqlite3_column_int($0, 1)),
                 enqueuedAt: sqlite3_column_double($0, 2), lane: Int(sqlite3_column_int($0, 3)))
            }.first
        guard let target else { return nil }

        func count(lane: Int, ahead: Bool = false, limit: Int? = nil) throws -> Int {
            if limit == 0 { return 0 }
            let index = lane == 2 ? "idx_processing_queue_enqueued" : "idx_processing_queue_priority"
            var values: [PipelineSQL.Value] = []
            var condition: String
            switch lane {
            case 0:
                condition = "pq.priority > 10"
            case 1:
                condition = """
                    pq.priority BETWEEN 1 AND 10 AND f.createdAt >= ?
                    AND NOT EXISTS (SELECT 1 FROM processing_queue preferred INDEXED BY idx_processing_queue_frame_id
                        WHERE preferred.frameId=pq.frameId AND preferred.priority > 10)
                    """
                values = [.integer(cutoff)]
            default:
                condition = """
                    (pq.priority IS NULL OR pq.priority <= 0 OR (pq.priority BETWEEN 1 AND 10 AND f.createdAt < ?))
                    AND NOT EXISTS (SELECT 1 FROM processing_queue preferred INDEXED BY idx_processing_queue_frame_id
                        WHERE preferred.frameId=pq.frameId AND
                            (preferred.priority > 10 OR (preferred.priority BETWEEN 1 AND 10 AND f.createdAt >= ?)))
                    """
                values = [.integer(cutoff), .integer(cutoff)]
            }
            if ahead {
                let fifo = "(pq.enqueuedAt < ? OR (pq.enqueuedAt = ? AND pq.id < ?))"
                if lane == 2 {
                    condition += " AND \(fifo)"
                } else {
                    condition += " AND (pq.priority > ? OR (pq.priority = ? AND \(fifo)))"
                    values += [.integer(Int64(target.priority)), .integer(Int64(target.priority))]
                }
                values += [.real(target.enqueuedAt), .real(target.enqueuedAt), .integer(target.id)]
            }
            let bounded = limit == nil ? "" : "LIMIT ?"
            if let limit { values.append(.integer(Int64(limit))) }
            // DISTINCT consolidates legacy rows; LIMIT avoids counting irrelevant distant turns.
            return Int(try PipelineSQL.integers(db, """
                SELECT COUNT(*) FROM (
                    SELECT DISTINCT pq.frameId FROM processing_queue pq INDEXED BY \(index)
                    CROSS JOIN frame f ON f.id=pq.frameId
                    WHERE f.processingStatus=0 AND \(condition) \(bounded)
                )
                """, values).first ?? 0)
        }

        let rank = try count(lane: target.lane, ahead: true) + 1
        if target.lane == 0 { return rank }
        let manual = try count(lane: 0)
        if target.lane == 1 {
            let historicalTurns = (consecutivePriorityClaims + rank - 1) / 3
            return manual + rank + (try count(lane: 2, limit: historicalTurns))
        }
        let currentTurns = (3 - consecutivePriorityClaims) + 3 * (rank - 1)
        return manual + rank + (try count(lane: 1, limit: currentTurns))
    }

    /// Get all frame IDs with pending status (processingStatus=0) that are NOT in the processing queue
    /// Used to find frames that need to be re-enqueued for OCR processing
    public func getPendingFrameIDsNotInQueue(limit: Int = 1000) async throws -> [Int64] {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT f.id FROM frame f
            LEFT JOIN processing_queue pq ON f.id = pq.frameId
            WHERE f.processingStatus = 0 AND pq.frameId IS NULL
            ORDER BY f.id DESC
            LIMIT ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var frameIDs: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            frameIDs.append(sqlite3_column_int64(stmt, 0))
        }

        return frameIDs
    }

    /// Queue one frame for OCR rebuild without deleting its current OCR/search rows.
    /// The worker replaces those rows only after it has a fresh OCR result.
    public func enqueueFrameForOCRRebuild(frameID: Int64, priority: Int = 75) async throws -> Bool {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        func executeTransactionSQL(_ sql: String) throws {
            var error: UnsafeMutablePointer<Int8>?
            guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
                sqlite3_free(error)
                throw DatabaseError.queryFailed(query: sql, underlying: message)
            }
        }

        try executeTransactionSQL("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let updateSQL = "UPDATE frame SET processingStatus = 0 WHERE id = ? AND processingStatus IN (2, 3);"
            var updateStmt: OpaquePointer?
            defer { sqlite3_finalize(updateStmt) }

            guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else {
                throw DatabaseError.queryFailed(query: updateSQL, underlying: String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_bind_int64(updateStmt, 1, frameID)

            guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                throw DatabaseError.queryFailed(query: updateSQL, underlying: String(cString: sqlite3_errmsg(db)))
            }

            let insertSQL = """
                INSERT INTO processing_queue (frameId, enqueuedAt, priority, retryCount, lastError)
                SELECT ?, ?, ?, 0, NULL
                WHERE EXISTS (
                    SELECT 1 FROM frame WHERE id = ? AND processingStatus = 0
                )
                AND NOT EXISTS (
                    SELECT 1 FROM processing_queue WHERE frameId = ?
                );
            """
            var insertStmt: OpaquePointer?
            defer { sqlite3_finalize(insertStmt) }

            guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
                throw DatabaseError.queryFailed(query: insertSQL, underlying: String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_bind_int64(insertStmt, 1, frameID)
            sqlite3_bind_double(insertStmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_int(insertStmt, 3, Int32(priority))
            sqlite3_bind_int64(insertStmt, 4, frameID)
            sqlite3_bind_int64(insertStmt, 5, frameID)

            guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                throw DatabaseError.queryFailed(query: insertSQL, underlying: String(cString: sqlite3_errmsg(db)))
            }
            let inserted = sqlite3_changes(db) > 0

            try executeTransactionSQL("COMMIT;")
            return inserted
        } catch {
            try? executeTransactionSQL("ROLLBACK;")
            throw error
        }
    }

    /// Count frames with pending status (processingStatus=0) that are NOT in the processing queue
    public func countPendingFramesNotInQueue() async throws -> Int {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        let sql = """
            SELECT COUNT(*) FROM frame f
            LEFT JOIN processing_queue pq ON f.id = pq.frameId
            WHERE f.processingStatus = 0 AND pq.frameId IS NULL;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Schema Inspection

    /// Returns a human-readable description of the database schema
    public func getSchemaDescription() async throws -> String {
        guard let db = db else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }

        var result = "DATABASE SCHEMA\n"
        result += "===============\n\n"

        // Get all tables
        let tablesSql = "SELECT name, sql FROM sqlite_master WHERE type='table' ORDER BY name;"
        var tablesStmt: OpaquePointer?
        defer { sqlite3_finalize(tablesStmt) }

        guard sqlite3_prepare_v2(db, tablesSql, -1, &tablesStmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: tablesSql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        while sqlite3_step(tablesStmt) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(tablesStmt, 0) else { continue }
            let tableName = String(cString: namePtr)

            // Skip internal SQLite tables
            if tableName.hasPrefix("sqlite_") { continue }

            result += "TABLE: \(tableName)\n"
            result += String(repeating: "-", count: tableName.count + 7) + "\n"

            // Get column info
            let pragmaSql = "PRAGMA table_info(\(tableName));"
            var pragmaStmt: OpaquePointer?

            if sqlite3_prepare_v2(db, pragmaSql, -1, &pragmaStmt, nil) == SQLITE_OK {
                while sqlite3_step(pragmaStmt) == SQLITE_ROW {
                    let colName = sqlite3_column_text(pragmaStmt, 1).map { String(cString: $0) } ?? "?"
                    let colType = sqlite3_column_text(pragmaStmt, 2).map { String(cString: $0) } ?? "?"
                    let notNull = sqlite3_column_int(pragmaStmt, 3) != 0
                    let isPK = sqlite3_column_int(pragmaStmt, 5) != 0

                    var colDesc = "  \(colName) \(colType)"
                    if isPK { colDesc += " PRIMARY KEY" }
                    if notNull { colDesc += " NOT NULL" }
                    result += colDesc + "\n"
                }
                sqlite3_finalize(pragmaStmt)
            }

            result += "\n"
        }

        // Get indexes
        result += "INDEXES\n"
        result += "-------\n"

        let indexSql = "SELECT name, tbl_name, sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL ORDER BY tbl_name, name;"
        var indexStmt: OpaquePointer?
        defer { sqlite3_finalize(indexStmt) }

        guard sqlite3_prepare_v2(db, indexSql, -1, &indexStmt, nil) == SQLITE_OK else {
            return result + "Error loading indexes\n"
        }

        while sqlite3_step(indexStmt) == SQLITE_ROW {
            let name = sqlite3_column_text(indexStmt, 0).map { String(cString: $0) } ?? "?"
            let table = sqlite3_column_text(indexStmt, 1).map { String(cString: $0) } ?? "?"
            result += "  \(name) ON \(table)\n"
        }

        return result
    }
}
