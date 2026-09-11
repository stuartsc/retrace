import XCTest
import SQLCipher
import Shared
@testable import Database

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                        QUERY BUILDER TESTS                                   ║
// ║                                                                              ║
// ║  • Verify FrameQueries builds correct SQL statements                         ║
// ║  • Verify SegmentQueries builds correct SQL statements                       ║
// ║  • Verify DocumentQueries builds correct SQL statements                      ║
// ║  • Verify query result parsing works correctly                               ║
// ║  • Verify parameter binding prevents SQL injection                           ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class QueryBuilderTests: XCTestCase {

    var db: OpaquePointer?
    private static var hasPrintedSeparator = false

    override func setUp() async throws {
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil), SQLITE_OK)

        let runner = MigrationRunner(db: db!)
        try await runner.runMigrations()

        if !Self.hasPrintedSeparator {
            printTestSeparator()
            Self.hasPrintedSeparator = true
        }
    }

    override func tearDown() {
        sqlite3_close(db)
        db = nil
    }

    // MARK: - Helper to create VideoSegment with required fields

    private func makeSegment(
        id: VideoSegmentID = VideoSegmentID(value: 0),
        startTime: Date = Date(),
        endTime: Date? = nil,
        frameCount: Int = 100,
        fileSizeBytes: Int64 = 1024,
        relativePath: String = "test.mp4"
    ) -> VideoSegment {
        VideoSegment(
            id: id,
            startTime: startTime,
            endTime: endTime ?? startTime.addingTimeInterval(300),
            frameCount: frameCount,
            fileSizeBytes: fileSizeBytes,
            relativePath: relativePath,
            width: 1920,
            height: 1080
        )
    }

    private func makeFrame(
        id: FrameID = FrameID(value: 0),
        timestamp: Date = Date(),
        segmentID: AppSegmentID,
        videoID: VideoSegmentID = VideoSegmentID(value: 0),
        frameIndex: Int = 0,
        metadata: FrameMetadata = .empty
    ) -> FrameReference {
        FrameReference(
            id: id,
            timestamp: timestamp,
            segmentID: segmentID,
            videoID: videoID,
            frameIndexInSegment: frameIndex,
            metadata: metadata
        )
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                      SEGMENT QUERIES TESTS                              ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    func testSegmentQueries_Insert_StoresAllFields() throws {
        let segment = makeSegment(
            startTime: Date(timeIntervalSince1970: 1702406400),
            endTime: Date(timeIntervalSince1970: 1702406700),
            frameCount: 73,
            fileSizeBytes: 52428800,
            relativePath: "segments/2024/01/test.mp4"
        )

        let insertedID = try SegmentQueries.insert(db: db!, segment: segment)

        let sql = "SELECT height, width, path, fileSize, frameCount, processingState FROM video WHERE id = ?"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        sqlite3_bind_int64(statement, 1, insertedID)

        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)

        let height = sqlite3_column_int(statement, 0)
        let width = sqlite3_column_int(statement, 1)
        let path = String(cString: sqlite3_column_text(statement, 2))
        let fileSize = sqlite3_column_int64(statement, 3)

        XCTAssertEqual(height, 1080)
        XCTAssertEqual(width, 1920)
        XCTAssertEqual(path, "segments/2024/01/test.mp4")
        XCTAssertEqual(fileSize, 52428800)
        XCTAssertEqual(sqlite3_column_int(statement, 4), 73)
        XCTAssertEqual(sqlite3_column_int(statement, 5), 1, "New video rows remain in progress until finalized")
    }

    func testSegmentQueries_GetByID_ReturnsCorrectSegment() throws {
        let segment = makeSegment(frameCount: 100, fileSizeBytes: 1024000)
        let videoID = VideoSegmentID(value: try SegmentQueries.insert(db: db!, segment: segment))

        let retrieved = try SegmentQueries.getByID(db: db!, id: videoID)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, videoID)
        XCTAssertEqual(retrieved?.frameCount, 100)
        XCTAssertEqual(retrieved?.fileSizeBytes, 1024000)
        XCTAssertEqual(retrieved?.width, 1920)
        XCTAssertEqual(retrieved?.height, 1080)
    }

    func testSegmentQueries_GetByID_ReturnsNilForMissingID() throws {
        let result = try SegmentQueries.getByID(db: db!, id: VideoSegmentID(value: 99999))
        XCTAssertNil(result)
    }

    func testSegmentQueries_GetByTimestamp_FindsVideoForExactFrameTimestamp() throws {
        let startTime = Date(timeIntervalSince1970: 1702406400)
        let segment = makeSegment(startTime: startTime, endTime: startTime.addingTimeInterval(300))
        let videoID = VideoSegmentID(value: try SegmentQueries.insert(db: db!, segment: segment))
        let appSegmentID = try createTestSegment()

        let midpoint = startTime.addingTimeInterval(150)
        _ = try FrameQueries.insert(db: db!, frame: makeFrame(timestamp: midpoint, segmentID: appSegmentID, videoID: videoID))
        let result = try SegmentQueries.getByTimestamp(db: db!, timestamp: midpoint)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.id, videoID)
        XCTAssertEqual(result?.frameCount, 100)
        XCTAssertNil(try SegmentQueries.getByTimestamp(db: db!, timestamp: midpoint.addingTimeInterval(0.001)),
                     "A video lookup needs a frame at the exact millisecond")
    }

    func testSegmentQueries_GetByTimestamp_ReturnsNilOutsideRange() throws {
        let startTime = Date(timeIntervalSince1970: 1702406400)
        let segment = makeSegment(startTime: startTime, endTime: startTime.addingTimeInterval(300))
        let videoID = VideoSegmentID(value: try SegmentQueries.insert(db: db!, segment: segment))
        let appSegmentID = try createTestSegment()
        _ = try FrameQueries.insert(db: db!, frame: makeFrame(timestamp: startTime, segmentID: appSegmentID, videoID: videoID))
        XCTAssertEqual(try SegmentQueries.getByTimestamp(db: db!, timestamp: startTime)?.id, videoID)

        // Query outside segment
        let beforeStart = startTime.addingTimeInterval(-100)
        let result = try SegmentQueries.getByTimestamp(db: db!, timestamp: beforeStart)

        XCTAssertNil(result)
    }

    func testSegmentQueries_GetByTimeRange_ReturnsDistinctVideosWithFramesInRange() throws {
        let seg1 = makeSegment(
            startTime: Date(timeIntervalSince1970: 1000),
            endTime: Date(timeIntervalSince1970: 1300),
            relativePath: "seg1.mp4"
        )
        let seg2 = makeSegment(
            startTime: Date(timeIntervalSince1970: 1500),
            endTime: Date(timeIntervalSince1970: 1800),
            relativePath: "seg2.mp4"
        )
        let seg3 = makeSegment(
            startTime: Date(timeIntervalSince1970: 5000),
            endTime: Date(timeIntervalSince1970: 5300),
            relativePath: "seg3.mp4"
        )

        let videoIDs = try [seg1, seg2, seg3].map {
            VideoSegmentID(value: try SegmentQueries.insert(db: db!, segment: $0))
        }
        let appSegmentID = try createTestSegment()
        for (index, entry) in [(videoIDs[0], 1200.0), (videoIDs[0], 1300.0),
                               (videoIDs[1], 1600.0), (videoIDs[2], 5000.0)].enumerated() {
            _ = try FrameQueries.insert(db: db!, frame: makeFrame(
                timestamp: Date(timeIntervalSince1970: entry.1), segmentID: appSegmentID,
                videoID: entry.0, frameIndex: index))
        }

        // Both endpoints are inclusive; two matching frames do not duplicate a video.
        let results = try SegmentQueries.getByTimeRange(
            db: db!,
            from: Date(timeIntervalSince1970: 1200),
            to: Date(timeIntervalSince1970: 1600)
        )

        XCTAssertEqual(results.map(\.id), Array(videoIDs.prefix(2)))
        XCTAssertEqual(results.map(\.frameCount), [100, 100])
    }

    func testSegmentQueries_Delete_RemovesSegment() throws {
        let segment = makeSegment(relativePath: "to-delete.mp4")
        let videoID = VideoSegmentID(value: try SegmentQueries.insert(db: db!, segment: segment))
        let survivorID = VideoSegmentID(value: try SegmentQueries.insert(db: db!, segment: makeSegment(relativePath: "keep.mp4")))

        XCTAssertNotNil(try SegmentQueries.getByID(db: db!, id: videoID))
        try SegmentQueries.delete(db: db!, id: videoID)
        XCTAssertNil(try SegmentQueries.getByID(db: db!, id: videoID))
        XCTAssertEqual(try SegmentQueries.getByID(db: db!, id: survivorID)?.relativePath, "keep.mp4")
    }

    func testSegmentQueries_GetCount_ReturnsCorrectCount() throws {
        for i in 0..<5 {
            let segment = makeSegment(
                startTime: Date().addingTimeInterval(Double(i * 300)),
                endTime: Date().addingTimeInterval(Double(i * 300 + 299)),
                relativePath: "seg-\(i).mp4"
            )
            try SegmentQueries.insert(db: db!, segment: segment)
        }

        let count = try SegmentQueries.getCount(db: db!)
        XCTAssertEqual(count, 5)
    }

    func testSegmentQueries_GetTotalStorageBytes_SumsCorrectly() throws {
        let sizes: [Int64] = [1000, 2000, 3000, 4000, 5000]

        for (i, size) in sizes.enumerated() {
            let segment = makeSegment(
                startTime: Date().addingTimeInterval(Double(i * 300)),
                endTime: Date().addingTimeInterval(Double(i * 300 + 299)),
                fileSizeBytes: size,
                relativePath: "seg-\(i).mp4"
            )
            try SegmentQueries.insert(db: db!, segment: segment)
        }

        let total = try SegmentQueries.getTotalStorageBytes(db: db!)
        XCTAssertEqual(total, 15000)
    }

    func testSegmentQueries_UpdateAndFinalize_ReturnPersistedFrameCounts() throws {
        let videoID = VideoSegmentID(value: try SegmentQueries.insert(db: db!, segment: makeSegment(frameCount: 0)))
        XCTAssertEqual(try SegmentQueries.getByID(db: db!, id: videoID)?.frameCount, 0)
        XCTAssertEqual(try SegmentQueries.getUnfinalisedByResolution(db: db!, width: 1920, height: 1080)?.frameCount, 0)

        try SegmentQueries.update(db: db!, id: videoID.value, width: 1920, height: 1080, fileSize: 2048, frameCount: 17)
        XCTAssertEqual(try SegmentQueries.getByID(db: db!, id: videoID)?.frameCount, 17)
        try SegmentQueries.update(db: db!, id: videoID.value, width: 1920, height: 1080, fileSize: 3072)
        XCTAssertEqual(try SegmentQueries.getByID(db: db!, id: videoID)?.frameCount, 17, "An omitted count preserves the last persisted count")

        try SegmentQueries.markFinalized(db: db!, id: videoID.value, frameCount: 23, fileSize: 4096)
        let finalized = try SegmentQueries.getByID(db: db!, id: videoID)
        XCTAssertEqual(finalized?.frameCount, 23)
        XCTAssertEqual(finalized?.fileSizeBytes, 4096)
        XCTAssertTrue(try SegmentQueries.getAllUnfinalised(db: db!).isEmpty)
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                       FRAME QUERIES TESTS                               ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    private func createTestSegment(
        bundleID: String = "com.test.app",
        windowName: String? = nil,
        browserURL: String? = nil
    ) throws -> AppSegmentID {
        let appSegmentID = try AppSegmentQueries.insert(
            db: db!,
            bundleID: bundleID,
            startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 4102444800),
            windowName: windowName,
            browserUrl: browserURL,
            type: 0
        )
        return AppSegmentID(value: appSegmentID)
    }

    func testFrameQueries_Insert_StoresAllFields() throws {
        let segmentID = try createTestSegment(bundleID: "com.apple.Safari", windowName: "GitHub - retrace", browserURL: "https://github.com/retrace")
        // Video file identity is independent of the app session identity.
        _ = try SegmentQueries.insert(db: db!, segment: makeSegment(relativePath: "unrelated.mp4"))
        let videoID = VideoSegmentID(value: try SegmentQueries.insert(db: db!, segment: makeSegment()))
        XCTAssertNotEqual(segmentID.value, videoID.value)
        let timestamp = Date(timeIntervalSince1970: 1702406400.123)

        let frame = makeFrame(
            timestamp: timestamp,
            segmentID: segmentID,
            videoID: videoID,
            frameIndex: 42,
            metadata: FrameMetadata(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                windowName: "GitHub - retrace",
                browserURL: "https://github.com/retrace"
            )
        )

        let frameID = FrameID(value: try FrameQueries.insert(db: db!, frame: frame))

        let retrieved = try FrameQueries.getByID(db: db!, id: frameID)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, frameID)
        XCTAssertEqual(retrieved?.segmentID, segmentID)
        XCTAssertEqual(retrieved?.videoID, videoID)
        XCTAssertEqual(try XCTUnwrap(retrieved).timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(retrieved?.frameIndexInSegment, 42)
        XCTAssertEqual(retrieved?.metadata.appBundleID, "com.apple.Safari")
        XCTAssertNil(retrieved?.metadata.appName, "App display names are not persisted in the session schema")
        XCTAssertEqual(retrieved?.metadata.windowName, "GitHub - retrace")
        XCTAssertEqual(retrieved?.metadata.browserURL, "https://github.com/retrace")
    }

    func testFrameQueries_Insert_WithNullMetadata_StoresCorrectly() throws {
        let segmentID = try createTestSegment()
        let frame = makeFrame(segmentID: segmentID, metadata: FrameMetadata())

        let frameID = FrameID(value: try FrameQueries.insert(db: db!, frame: frame))

        let retrieved = try FrameQueries.getByID(db: db!, id: frameID)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.metadata.appBundleID, "com.test.app", "Frame context comes from its linked app session")
        XCTAssertNil(retrieved?.metadata.appName)
        XCTAssertNil(retrieved?.metadata.windowName)
        XCTAssertNil(retrieved?.metadata.browserURL)
    }

    func testFrameQueries_GetByTimeRange_ReturnsOrderedByTimestampAsc() throws {
        let segmentID = try createTestSegment()
        let timestamps = [100.0, 300.0, 200.0, 500.0, 400.0]

        for (i, offset) in timestamps.enumerated() {
            let frame = makeFrame(
                timestamp: Date(timeIntervalSince1970: offset),
                segmentID: segmentID,
                frameIndex: i
            )
            try FrameQueries.insert(db: db!, frame: frame)
        }

        let results = try FrameQueries.getByTimeRange(
            db: db!,
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 1000),
            limit: 10
        )

        XCTAssertEqual(results.count, 5)

        XCTAssertEqual(results.map { $0.timestamp.timeIntervalSince1970 }, timestamps.sorted())
    }

    func testFrameQueries_GetByTimeRange_RespectsLimit() throws {
        let segmentID = try createTestSegment()

        for i in 0..<10 {
            let frame = makeFrame(
                timestamp: Date().addingTimeInterval(Double(i)),
                segmentID: segmentID,
                frameIndex: i
            )
            try FrameQueries.insert(db: db!, frame: frame)
        }

        let results = try FrameQueries.getByTimeRange(
            db: db!,
            from: Date().addingTimeInterval(-100),
            to: Date().addingTimeInterval(100),
            limit: 3
        )

        XCTAssertEqual(results.count, 3)
    }

    func testFrameQueries_GetByApp_FiltersCorrectly() throws {
        let apps = ["com.apple.Safari", "com.apple.Xcode", "com.apple.Safari", "com.apple.Terminal"]
        var expectedSafariIDs: [FrameID] = []

        for (i, app) in apps.enumerated() {
            let segmentID = try createTestSegment(bundleID: app)
            let frame = makeFrame(
                timestamp: Date().addingTimeInterval(Double(i)),
                segmentID: segmentID,
                frameIndex: i,
                metadata: FrameMetadata(appBundleID: app)
            )
            let frameID = FrameID(value: try FrameQueries.insert(db: db!, frame: frame))
            if app == "com.apple.Safari" { expectedSafariIDs.append(frameID) }
        }

        let safariFrames = try FrameQueries.getByApp(
            db: db!,
            appBundleID: "com.apple.Safari",
            limit: 10,
            offset: 0
        )

        XCTAssertEqual(safariFrames.count, 2)
        XCTAssertEqual(Set(safariFrames.map(\.id)), Set(expectedSafariIDs))
        for frame in safariFrames {
            XCTAssertEqual(frame.metadata.appBundleID, "com.apple.Safari")
        }
    }

    func testFrameQueries_DeleteOlderThan_ReturnsDeletedCount() throws {
        let segmentID = try createTestSegment()
        let now = Date()

        // 5 old frames
        for i in 0..<5 {
            let frame = makeFrame(
                timestamp: now.addingTimeInterval(-86400 * Double(100 + i)),
                segmentID: segmentID,
                frameIndex: i
            )
            try FrameQueries.insert(db: db!, frame: frame)
        }

        // 3 recent frames
        for i in 0..<3 {
            let frame = makeFrame(
                timestamp: now.addingTimeInterval(-Double(i)),
                segmentID: segmentID,
                frameIndex: 5 + i
            )
            try FrameQueries.insert(db: db!, frame: frame)
        }

        let cutoff = now.addingTimeInterval(-86400 * 30)
        let deleted = try FrameQueries.deleteOlderThan(db: db!, date: cutoff)

        XCTAssertEqual(deleted, 5)
        XCTAssertEqual(try FrameQueries.getCount(db: db!), 3)
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                      DOCUMENT QUERIES TESTS                             ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    private func createTestFrame(
        timestamp: Date = Date(),
        windowName: String? = nil,
        browserURL: String? = nil
    ) throws -> FrameID {
        let segmentID = try createTestSegment(windowName: windowName, browserURL: browserURL)
        let frame = makeFrame(timestamp: timestamp, segmentID: segmentID)
        return FrameID(value: try FrameQueries.insert(db: db!, frame: frame))
    }

    func testDocumentQueries_Insert_ReturnsAutoIncrementID() throws {
        let frameID = try createTestFrame()

        let document = IndexedDocument(
            id: 0,
            frameID: frameID,
            timestamp: Date(),
            content: "Test content"
        )

        let id1 = try DocumentQueries.insert(db: db!, document: document)
        XCTAssertGreaterThan(id1, 0)

        let frameID2 = try createTestFrame()
        let document2 = IndexedDocument(id: 0, frameID: frameID2, timestamp: Date(), content: "More content")

        let id2 = try DocumentQueries.insert(db: db!, document: document2)
        XCTAssertGreaterThan(id2, id1)
        XCTAssertEqual(try DocumentQueries.getByFrameID(db: db!, frameID: frameID)?.id, id1)
        XCTAssertEqual(try DocumentQueries.getByFrameID(db: db!, frameID: frameID2)?.id, id2)
    }

    func testDocumentQueries_Insert_StoresAllFields() throws {
        let timestamp = Date(timeIntervalSince1970: 1702406400.123)
        let frameID = try createTestFrame(timestamp: timestamp, windowName: "GitHub Page", browserURL: "https://github.com")

        let document = IndexedDocument(
            id: 0,
            frameID: frameID,
            timestamp: timestamp,
            content: "Full document content here",
            appName: "Safari",
            windowName: "GitHub Page",
            browserURL: "https://github.com"
        )

        let docID = try DocumentQueries.insert(db: db!, document: document)

        let retrieved = try DocumentQueries.getByFrameID(db: db!, frameID: frameID)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, docID)
        XCTAssertEqual(retrieved?.frameID, frameID)
        XCTAssertEqual(try XCTUnwrap(retrieved).timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(retrieved?.content, "Full document content here")
        XCTAssertNil(retrieved?.appName, "Document context is read from the source frame and session")
        XCTAssertEqual(retrieved?.windowName, "GitHub Page")
        XCTAssertEqual(retrieved?.browserURL, "https://github.com")
    }

    func testDocumentQueries_Update_ChangesContent() throws {
        let frameID = try createTestFrame()

        let document = IndexedDocument(id: 0, frameID: frameID, timestamp: Date(), content: "Original")
        let docID = try DocumentQueries.insert(db: db!, document: document)

        try DocumentQueries.update(db: db!, id: docID, content: "Updated content")

        let retrieved = try DocumentQueries.getByFrameID(db: db!, frameID: frameID)
        XCTAssertEqual(retrieved?.content, "Updated content")
        XCTAssertEqual(retrieved?.id, docID)
        XCTAssertEqual(try DocumentQueries.getCount(db: db!), 1)
    }

    func testDocumentQueries_Delete_RemovesDocument() throws {
        let frameID = try createTestFrame()

        let document = IndexedDocument(id: 0, frameID: frameID, timestamp: Date(), content: "To delete")
        let docID = try DocumentQueries.insert(db: db!, document: document)

        XCTAssertNotNil(try DocumentQueries.getByFrameID(db: db!, frameID: frameID))
        try DocumentQueries.delete(db: db!, id: docID)
        XCTAssertNil(try DocumentQueries.getByFrameID(db: db!, frameID: frameID))
        XCTAssertNotNil(try FrameQueries.getByID(db: db!, id: frameID), "Deleting indexed text preserves its source frame")
    }

    func testDocumentQueries_GetCount_ReturnsCorrectCount() throws {
        for _ in 0..<7 {
            let frameID = try createTestFrame()
            let document = IndexedDocument(id: 0, frameID: frameID, timestamp: Date(), content: "Content")
            _ = try DocumentQueries.insert(db: db!, document: document)
        }

        let count = try DocumentQueries.getCount(db: db!)
        XCTAssertEqual(count, 7)
    }
}
