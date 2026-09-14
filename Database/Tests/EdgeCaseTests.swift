import XCTest
import Foundation
import SQLCipher
import Shared
@testable import Database

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                            EDGE CASE TESTS                                   ║
// ║                                                                              ║
// ║  • Verify empty database queries return nil/empty (don't crash)              ║
// ║  • Verify null/optional field handling                                       ║
// ║  • Verify large data sets don't cause performance issues                     ║
// ║  • Verify special characters and Unicode in text content                     ║
// ║  • Verify boundary conditions (zero values, max values)                      ║
// ║  • Verify duplicate handling and constraint violations                       ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class EdgeCaseTests: XCTestCase {

    var database: DatabaseManager!
    private static var hasPrintedSeparator = false

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:edge_cases_\(UUID().uuidString)?mode=memory&cache=private")
        try await database.initialize()

        if !Self.hasPrintedSeparator {
            printTestSeparator()
            Self.hasPrintedSeparator = true
        }
    }

    override func tearDown() async throws {
        try await database.close()
        database = nil
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                         EMPTY DATABASE TESTS                            ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ Queries on empty database should return empty/nil, not crash            │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testGetFrame_EmptyDatabase_ReturnsNil() async throws {
        let result = try await database.getFrame(id: FrameID(value: 999))
        XCTAssertNil(result, "Should return nil for non-existent frame")
    }

    func testGetSegment_EmptyDatabase_ReturnsNil() async throws {
        let result = try await database.getSegment(id: 999)
        XCTAssertNil(result, "Should return nil for non-existent app segment")
    }

    func testGetSegmentContainingTimestamp_EmptyDatabase_ReturnsNil() async throws {
        let result = try await database.getVideoSegment(containingTimestamp: Date())
        XCTAssertNil(result, "Should return nil when no segments exist")
    }

    func testGetFrames_EmptyDatabase_ReturnsEmptyArray() async throws {
        let result = try await database.getFrames(
            from: Date().addingTimeInterval(-3600),
            to: Date(),
            limit: 100
        )
        XCTAssertEqual(result.count, 0, "Should return empty array")
    }

    func testGetFramesByApp_EmptyDatabase_ReturnsEmptyArray() async throws {
        let result = try await database.getFrames(
            appBundleID: "com.example.app",
            limit: 100,
            offset: 0
        )
        XCTAssertEqual(result.count, 0, "Should return empty array")
    }

    func testGetFrameCount_EmptyDatabase_ReturnsZero() async throws {
        let count = try await database.getFrameCount()
        XCTAssertEqual(count, 0, "Should return 0")
    }

    func testGetTotalStorageBytes_EmptyDatabase_ReturnsZero() async throws {
        let bytes = try await database.getTotalStorageBytes()
        XCTAssertEqual(bytes, 0, "Should return 0")
    }

    func testDeleteFramesOlderThan_EmptyDatabase_ReturnsZero() async throws {
        let deleted = try await database.deleteFrames(olderThan: Date())
        XCTAssertEqual(deleted, 0, "Should return 0 when nothing to delete")
    }

    func testGetStatistics_EmptyDatabase_ReturnsZeroCounts() async throws {
        let stats = try await database.getStatistics()

        XCTAssertEqual(stats.frameCount, 0)
        XCTAssertEqual(stats.segmentCount, 0)
        XCTAssertEqual(stats.documentCount, 0)
        XCTAssertNil(stats.oldestFrameDate)
        XCTAssertNil(stats.newestFrameDate)
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                         NULL/OPTIONAL HANDLING                          ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ Nullable fields should be stored and retrieved correctly                │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testFrame_WithNullMetadata_StoresAndRetrievesCorrectly() async throws {
        // Create segment first
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        // Create frame with all null optional fields
        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoID,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(
                appBundleID: nil,
                appName: nil,
                windowName: nil,
                browserURL: nil
            ),
            source: .native
        )
        let frameID = FrameID(value: try await database.insertFrame(frame))

        // Retrieve and verify nulls are preserved
        let retrieved = try await database.getFrame(id: frameID)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.metadata.appBundleID, "com.test.app", "The linked session supplies its required bundle ID")
        XCTAssertNil(retrieved?.metadata.appName)
        XCTAssertNil(retrieved?.metadata.windowName)
        XCTAssertNil(retrieved?.metadata.browserURL)
    }

    func testFrame_WithPartialMetadata_StoresAndRetrievesCorrectly() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.example.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        // Only app name, no other metadata
        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoID,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(
                appBundleID: "com.example.app",
                appName: "Example",
                windowName: nil,  // Intentionally nil
                browserURL: nil    // Intentionally nil
            ),
            source: .native
        )
        let frameID = FrameID(value: try await database.insertFrame(frame))

        let retrieved = try await database.getFrame(id: frameID)
        XCTAssertEqual(retrieved?.metadata.appBundleID, "com.example.app")
        XCTAssertNil(retrieved?.metadata.appName, "Display names are transient; the schema persists the bundle ID")
        XCTAssertNil(retrieved?.metadata.windowName)
        XCTAssertNil(retrieved?.metadata.browserURL)
    }

    func testDocument_WithNullOptionalFields_StoresCorrectly() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoID,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )
        let frameID = FrameID(value: try await database.insertFrame(frame))

        let document = IndexedDocument(
            id: 0,
            frameID: frameID,
            timestamp: Date(),
            content: "Test content",
            appName: nil,       // Intentionally nil
            windowName: nil,   // Intentionally nil
            browserURL: nil     // Intentionally nil
        )

        let docID = try await database.insertDocument(document)
        XCTAssertGreaterThan(docID, 0)

        let retrieved = try await database.getDocument(frameID: frameID)
        XCTAssertEqual(retrieved?.content, "Test content")
        XCTAssertNil(retrieved?.appName)
        XCTAssertNil(retrieved?.windowName)
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                         BOUNDARY CONDITIONS                             ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ Tests for extreme values, limits, and edge timestamps                   │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testSegment_WithZeroFrameCount_StoresCorrectly() async throws {
        // Edge case: segment with no frames yet
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 0,
            fileSizeBytes: 0,
            relativePath: "empty.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))

        let retrieved = try await database.getVideoSegment(id: videoID)
        XCTAssertEqual(retrieved?.frameCount, 0)
        XCTAssertEqual(retrieved?.fileSizeBytes, 0)
    }

    func testSegment_WithLargeFileSize_StoresCorrectly() async throws {
        // Edge case: very large file (100GB)
        let largeSize: Int64 = 100 * 1024 * 1024 * 1024

        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 10000,
            fileSizeBytes: largeSize,
            relativePath: "large.mp4",
            width: 3840,
            height: 2160,
            source: .native
        )
        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))

        let retrieved = try await database.getVideoSegment(id: videoID)
        XCTAssertEqual(retrieved?.fileSizeBytes, largeSize)
    }

    func testFrame_WithVeryOldTimestamp_StoresCorrectly() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(timeIntervalSince1970: 0),  // 1970
            endTime: Date(timeIntervalSince1970: 1000),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "old.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))

        let oldDate = Date(timeIntervalSince1970: 500)  // 1970
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: oldDate,
            endDate: oldDate.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: oldDate,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoID,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )
        let frameID = FrameID(value: try await database.insertFrame(frame))

        let retrieved = try await database.getFrame(id: frameID)
        guard let retrieved = retrieved else {
            XCTFail("Failed to retrieve frame")
            return
        }
        XCTAssertEqual(
            retrieved.timestamp.timeIntervalSince1970,
            oldDate.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testFrame_WithFutureTimestamp_StoresCorrectly() async throws {
        let futureDate = Date().addingTimeInterval(86400 * 365 * 10)  // 10 years from now

        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: futureDate,
            endTime: futureDate.addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "future.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))

        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: futureDate,
            endDate: futureDate.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: futureDate,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoID,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )
        let frameID = FrameID(value: try await database.insertFrame(frame))

        let retrieved = try await database.getFrame(id: frameID)
        guard let retrieved = retrieved else {
            XCTFail("Failed to retrieve frame")
            return
        }
        XCTAssertEqual(
            retrieved.timestamp.timeIntervalSince1970,
            futureDate.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testGetFrames_WithZeroLimit_ReturnsEmptyArray() async throws {
        // Set up data
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoID,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )
        let frameID = FrameID(value: try await database.insertFrame(frame))

        // Query with limit 0
        let available = try await database.getFrames(from: timestamp.addingTimeInterval(-1), to: timestamp.addingTimeInterval(1), limit: 1)
        XCTAssertEqual(available.map(\.id), [frameID])
        let results = try await database.getFrames(
            from: Date().addingTimeInterval(-3600),
            to: Date().addingTimeInterval(3600),
            limit: 0
        )

        XCTAssertEqual(results.count, 0, "Limit 0 should return empty array")
    }

    func testGetFramesByApp_WithLargeOffset_ReturnsEmptyArray() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoID,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(appBundleID: "com.test.app"),
            source: .native
        )
        let frameID = FrameID(value: try await database.insertFrame(frame))

        try await database.markFrameReadable(frameID: frameID.value)
        let firstPage = try await database.getFrames(appBundleID: "com.test.app", limit: 1, offset: 0)
        XCTAssertEqual(firstPage.map(\.id), [frameID])

        // Query with huge offset
        let results = try await database.getFrames(
            appBundleID: "com.test.app",
            limit: 100,
            offset: 1000000
        )

        XCTAssertEqual(results.count, 0, "Large offset past data should return empty")
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                         SPECIAL CHARACTERS                              ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ Unicode, emoji, SQL injection attempts, special chars                   │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testFrame_WithUnicodeMetadata_StoresCorrectly() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "unicode.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.example.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: "日本語アプリ — Émojis: 😀🎉🚀 and más",
            browserUrl: "https://example.com/путь",
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoID,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(
                appBundleID: "com.example.app",
                appName: "日本語アプリ",  // Japanese
                windowName: "日本語アプリ — Émojis: 😀🎉🚀 and más",  // Mixed
                browserURL: "https://example.com/путь"  // Russian
            ),
            source: .native
        )
        let frameID = FrameID(value: try await database.insertFrame(frame))

        let retrieved = try await database.getFrame(id: frameID)
        XCTAssertNil(retrieved?.metadata.appName, "Unicode is preserved in the session window title; app display names are not persisted")
        XCTAssertEqual(retrieved?.metadata.windowName, "日本語アプリ — Émojis: 😀🎉🚀 and más")
        // Capture metadata uses the canonical, scrubbed URL representation. Its
        // percent encoding must preserve the original Unicode path through SQLite.
        let retainedString = try XCTUnwrap(retrieved?.metadata.browserURL)
        let retainedURL = try XCTUnwrap(URL(string: retainedString))
        XCTAssertEqual(retainedString, "https://example.com/%D0%BF%D1%83%D1%82%D1%8C")
        XCTAssertEqual(retainedURL.path, "/путь")
    }

    func testDocument_WithSQLInjectionAttempt_SafelyStored() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "injection.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoID,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )
        let frameID = FrameID(value: try await database.insertFrame(frame))

        // Attempt SQL injection in content
        let maliciousContent = "'; DROP TABLE frame; --"
        let document = IndexedDocument(
            id: 0,
            frameID: frameID,
            timestamp: Date(),
            content: maliciousContent,
            appName: "Robert'); DROP TABLE Students;--"  // Bobby Tables
        )

        let docID = try await database.insertDocument(document)
        XCTAssertGreaterThan(docID, 0, "Insert should succeed despite SQL injection attempt")

        // Verify table still exists and content is stored literally
        let retrieved = try await database.getDocument(frameID: frameID)
        XCTAssertEqual(retrieved?.content, maliciousContent, "Content should be stored literally, not executed")
        let sourceFrame = try await database.getFrame(id: frameID)
        XCTAssertEqual(sourceFrame?.id, frameID, "The source table and row must remain intact")
    }

    func testFrame_WithQuotesInMetadata_StoresCorrectly() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "quotes.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.example.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: "App with 'single' quotes / Window with \"double\" quotes",
            browserUrl: nil,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoID,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: FrameMetadata(
                appBundleID: "com.example.app",
                appName: "App with 'single' quotes",
                windowName: "App with 'single' quotes / Window with \"double\" quotes",
                browserURL: nil
            ),
            source: .native
        )
        let frameID = FrameID(value: try await database.insertFrame(frame))

        let retrieved = try await database.getFrame(id: frameID)
        XCTAssertNil(retrieved?.metadata.appName, "Only the linked session metadata is persisted")
        XCTAssertEqual(retrieved?.metadata.windowName, "App with 'single' quotes / Window with \"double\" quotes")
    }

    func testDocument_WithVeryLongContent_StoresCorrectly() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "long.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoID,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )
        let frameID = FrameID(value: try await database.insertFrame(frame))

        // Create very long content (100KB of text)
        let longContent = String(repeating: "Lorem ipsum dolor sit amet. ", count: 4000)

        let document = IndexedDocument(
            id: 0,
            frameID: frameID,
            timestamp: Date(),
            content: longContent
        )

        let docID = try await database.insertDocument(document)
        XCTAssertGreaterThan(docID, 0)

        let retrieved = try await database.getDocument(frameID: frameID)
        XCTAssertEqual(retrieved?.content, longContent)
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                         TIME RANGE EDGE CASES                           ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    func testGetSegment_ExactlyAtBoundary_Found() async throws {
        let startTime = Date(timeIntervalSince1970: 1_702_406_400)
        let endTime = startTime.addingTimeInterval(300)

        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: startTime,
            endTime: endTime,
            frameCount: 10,
            fileSizeBytes: 1024,
            relativePath: "boundary.mp4"
        ,
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))
        let appSegmentID = try await database.insertSegment(bundleID: "com.test.boundaries",
            startDate: startTime, endDate: endTime, windowName: nil, browserUrl: nil, type: 0)
        for (index, date) in [startTime, endTime].enumerated() {
            let id = try await database.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: date,
                segmentID: AppSegmentID(value: appSegmentID), videoID: videoID,
                frameIndexInSegment: index, metadata: .empty))
            try await database.markFrameReadable(frameID: id)
        }

        // Query at exact start time
        let atStart = try await database.getVideoSegment(containingTimestamp: startTime)
        XCTAssertEqual(atStart?.id, videoID, "The start boundary frame identifies its video")

        // Query at exact end time
        let atEnd = try await database.getVideoSegment(containingTimestamp: endTime)
        XCTAssertEqual(atEnd?.id, videoID, "The end boundary frame identifies its video")
    }

    func testGetSegment_JustOutsideBoundary_NotFound() async throws {
        let startTime = Date(timeIntervalSince1970: 1_702_406_400)
        let endTime = startTime.addingTimeInterval(300)

        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: startTime,
            endTime: endTime,
            frameCount: 10,
            fileSizeBytes: 1024,
            relativePath: "boundary.mp4"
        ,
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))
        let appSegmentID = try await database.insertSegment(bundleID: "com.test.boundaries",
            startDate: startTime, endDate: endTime, windowName: nil, browserUrl: nil, type: 0)
        for (index, date) in [startTime, endTime].enumerated() {
            let id = try await database.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: date,
                segmentID: AppSegmentID(value: appSegmentID), videoID: videoID,
                frameIndexInSegment: index, metadata: .empty))
            try await database.markFrameReadable(frameID: id)
        }

        // Query 1ms before start
        let beforeStart = try await database.getVideoSegment(
            containingTimestamp: startTime.addingTimeInterval(-0.001)
        )
        XCTAssertNil(beforeStart, "Should not find segment before start time")

        // Query 1ms after end
        let afterEnd = try await database.getVideoSegment(
            containingTimestamp: endTime.addingTimeInterval(0.001)
        )
        XCTAssertNil(afterEnd, "Should not find segment after end time")
    }

    func testGetFrames_InvertedTimeRange_ReturnsEmpty() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoID,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )
        let frameID = FrameID(value: try await database.insertFrame(frame))

        // Query with end before start (inverted range)
        let available = try await database.getFrames(from: timestamp.addingTimeInterval(-1), to: timestamp.addingTimeInterval(1), limit: 1)
        XCTAssertEqual(available.map(\.id), [frameID])
        let now = Date()
        let results = try await database.getFrames(
            from: now.addingTimeInterval(3600),  // Future
            to: now.addingTimeInterval(-3600),   // Past (inverted!)
            limit: 100
        )

        XCTAssertEqual(results.count, 0, "Inverted time range should return empty")
    }

    // ╔═════════════════════════════════════════════════════════════════════════╗
    // ║                         DUPLICATE HANDLING                              ║
    // ╚═════════════════════════════════════════════════════════════════════════╝

    func testInsertSegment_SuppliedExistingID_AllocatesDistinctRows() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 10,
            fileSizeBytes: 1024,
            relativePath: "original.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )

        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))

        // Try to insert same ID again
        let duplicate = VideoSegment(
            id: videoID,  // Insertion must still allocate a new database ID
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 20,
            fileSizeBytes: 2048,
            relativePath: "duplicate.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )

        let secondID = VideoSegmentID(value: try await database.insertVideoSegment(duplicate))
        XCTAssertNotEqual(secondID, videoID)
        let originalRow = try await database.getVideoSegment(id: videoID)
        let secondRow = try await database.getVideoSegment(id: secondID)
        XCTAssertEqual(originalRow?.relativePath, "original.mp4")
        XCTAssertEqual(originalRow?.fileSizeBytes, 1024)
        XCTAssertEqual(secondRow?.relativePath, "duplicate.mp4")
        XCTAssertEqual(secondRow?.fileSizeBytes, 2048)
    }

    func testInsertFrame_SuppliedExistingID_AllocatesDistinctRows() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoID,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )
        let frameID = FrameID(value: try await database.insertFrame(frame))

        // Try to insert same ID again
        let duplicate = FrameReference(
            id: frameID,  // Insertion must still allocate a new database ID
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoID,
            frameIndexInSegment: 1,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )

        let secondID = FrameID(value: try await database.insertFrame(duplicate))
        XCTAssertNotEqual(secondID, frameID)
        let originalRow = try await database.getFrame(id: frameID)
        let secondRow = try await database.getFrame(id: secondID)
        XCTAssertEqual(originalRow?.frameIndexInSegment, 0)
        XCTAssertEqual(secondRow?.frameIndexInSegment, 1)
        XCTAssertEqual(originalRow?.videoID, videoID)
        XCTAssertEqual(secondRow?.videoID, videoID)
        let count = try await database.getFrameCount()
        XCTAssertEqual(count, 2)
    }

    func testInsertDocument_DuplicateFrameID_ThrowsError() async throws {
        let segment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: Date(),
            endTime: Date().addingTimeInterval(300),
            frameCount: 1,
            fileSizeBytes: 1024,
            relativePath: "test.mp4",
            width: 1920,
            height: 1080,
            source: .native
        )
        let videoID = VideoSegmentID(value: try await database.insertVideoSegment(segment))

        let timestamp = Date()
        let appSegmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(300),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        let frame = FrameReference(
            id: FrameID(value: 0),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: appSegmentID),
            videoID: videoID,
            frameIndexInSegment: 0,
            encodingStatus: .success,
            metadata: .empty,
            source: .native
        )
        let frameID = FrameID(value: try await database.insertFrame(frame))

        let document1 = IndexedDocument(
            id: 0,
            frameID: frameID,
            timestamp: Date(),
            content: "First document"
        )
        let documentID = try await database.insertDocument(document1)

        // Try to insert another document for same frame
        let document2 = IndexedDocument(
            id: 0,
            frameID: frameID,  // Same frame ID!
            timestamp: Date(),
            content: "Second document"
        )

        do {
            _ = try await database.insertDocument(document2)
            XCTFail("The insert API must reject a second document for an already indexed frame")
        } catch {
            // The compatibility insert API rejects replacing existing frame text.
        }
        let retained = try await database.getDocument(frameID: frameID)
        XCTAssertEqual(retained?.content, "First document")
        XCTAssertEqual(retained?.id, documentID)
        let statistics = try await database.getStatistics()
        XCTAssertEqual(statistics.documentCount, 1)
        let linkCount = try await database.edgeCaseDocumentLinkCount(frameID: frameID)
        XCTAssertEqual(linkCount, 1)
    }
}

private extension DatabaseManager {
    /// Run the assertion query on the database actor, preserving connection ownership.
    func edgeCaseDocumentLinkCount(frameID: FrameID) throws -> Int {
        let db = try XCTUnwrap(getConnection())
        let sql = "SELECT COUNT(*) FROM doc_segment WHERE frameId = ?"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(statement, 1, frameID.value)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
