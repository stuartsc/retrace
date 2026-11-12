import Foundation
import Shared
import XCTest
@testable import Database

final class LiveContextQueryTests: XCTestCase {
    // This millisecond residue previously rounded a +0.001 upper bound back to
    // the original timestamp and incorrectly invalidated retained exact rows.
    private let time = Date(timeIntervalSince1970: 1_800_000_000.001)

    func testFiniteButUnrepresentableDateFailsBeforeIntegerConversion() async throws {
        let db = DatabaseManager(databasePath: ":memory:")
        try await db.initialize()
        do {
            _ = try await db.contextMetadataPage(from: time, to: Date(timeIntervalSince1970: 1e30), query: "", limit: 1)
            XCTFail("Out-of-range milliseconds must throw without converting to Int64")
        } catch { }
        do {
            _ = try await db.contextNotePage(from: Date(timeIntervalSince1970: -1e30), to: time, query: "", limit: 1)
            XCTFail("Out-of-range milliseconds must throw without converting to Int64")
        } catch { }
        try await db.close()
    }

    func testEqualTimestampMetadataPagesAreStableAndHiddenRowsInvalidate() async throws {
        let db = DatabaseManager(databasePath: ":memory:")
        try await db.initialize()
        let segment = try await db.insertSegment(bundleID: "com.authored.fixture", startDate: time,
            endDate: time.addingTimeInterval(5), windowName: "Budget 50%_ready", browserUrl: nil, type: 0)
        var ids: [FrameID] = []
        for index in 0..<3 {
            ids.append(FrameID(value: try await db.insertFrame(.init(id: .init(value: 0), timestamp: time,
                segmentID: .init(value: segment), frameIndexInSegment: index,
                metadata: .init(appBundleID: "com.authored.fixture", windowName: "Budget 50%_ready")))))
        }
        let first = try await db.contextMetadataPage(from: time, to: time.addingTimeInterval(1), query: "50%_", limit: 2)
        XCTAssertEqual(first.entries.map(\.frameID), Array(ids.reversed().prefix(2)))
        let second = try await db.contextMetadataPage(from: time, to: time.addingTimeInterval(1), query: "50%_", before: first.nextCursor, limit: 2)
        XCTAssertEqual(second.entries.map(\.frameID), [ids[0]])
        XCTAssertNil(second.nextCursor)
        let excludedEnd = try await db.contextMetadataPage(from: time.addingTimeInterval(-1), to: time, query: "", limit: 2)
        XCTAssertTrue(excludedEnd.entries.isEmpty)
        do {
            _ = try await db.contextMetadataPage(from: time, to: time.addingTimeInterval(2), query: "50%_", before: first.nextCursor, limit: 2)
            XCTFail("Cursor must remain bound to the exact interval")
        } catch { }
        let expected = try XCTUnwrap(first.entries.first)
        let initiallyValid = try await db.validateContextMetadata(expected)
        XCTAssertTrue(initiallyValid)
        let tagValue = try await db.getTag(name: "hidden")
        let tag = try XCTUnwrap(tagValue)
        try await db.addTagToSegment(segmentId: .init(value: segment), tagId: tag.id)
        let validAfterHide = try await db.validateContextMetadata(expected)
        XCTAssertFalse(validAfterHide)
        try await db.close()
    }

    func testNotesAreDeduplicatedAndEditsRevokeTheirOriginalSnapshot() async throws {
        let db = DatabaseManager(databasePath: ":memory:")
        try await db.initialize()
        let firstSegment = try await db.insertSegment(bundleID: "com.authored.fixture", startDate: time,
            endDate: time.addingTimeInterval(10), windowName: "First", browserUrl: nil, type: 0)
        let secondSegment = try await db.insertSegment(bundleID: "com.authored.fixture", startDate: time.addingTimeInterval(2),
            endDate: time.addingTimeInterval(10), windowName: "Second", browserUrl: nil, type: 0)
        let note = try await db.createSegmentComment(body: "Budget note 50%_ready", author: "Fixture author")
        try await db.addCommentToSegment(segmentId: .init(value: firstSegment), commentId: note.id)
        try await db.addCommentToSegment(segmentId: .init(value: secondSegment), commentId: note.id)
        let page = try await db.contextNotePage(from: time, to: time.addingTimeInterval(20), query: "50%_", limit: 2)
        XCTAssertEqual(page.entries.count, 1)
        let expected = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(expected.segmentID.value, firstSegment)
        XCTAssertNil(expected.comment.frameID, "A segment note must not invent a representative screenshot")
        let valid = try await db.validateContextNote(expected)
        XCTAssertTrue(valid)
        try await db.updateSegmentComment(commentId: note.id, body: "Changed", author: note.author, attachments: [])
        let validAfterEdit = try await db.validateContextNote(expected)
        XCTAssertFalse(validAfterEdit)
        try await db.close()
    }
}
