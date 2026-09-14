import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database

final class RecallSearchRevisionTests: XCTestCase {
    private var database: DatabaseManager!
    private var db: OpaquePointer!

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:revision_\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        db = try requireValue(await database.getConnection())
    }
    override func tearDown() async throws { try await database.close() }

    func testFTSUpdatesInvalidatePagesButRollbackRestoresRevision() throws {
        let initial = try revision()
        try PipelineSQL.execute(db, "INSERT INTO searchRanking(rowid,text,title) VALUES(1,'before','title')")
        let inserted = try revision()
        expectGreaterThan(inserted, initial)
        try PipelineSQL.execute(db, "BEGIN IMMEDIATE")
        try PipelineSQL.execute(db, "UPDATE searchRanking SET text='after' WHERE rowid=1")
        expectGreaterThan(try revision(), inserted)
        try PipelineSQL.execute(db, "ROLLBACK")
        expectEqual(try revision(), inserted)
        try PipelineSQL.execute(db, "DELETE FROM searchRanking WHERE rowid=1")
        expectGreaterThan(try revision(), inserted)
    }

    func testSearchWritesInvalidateButMaterializationMetricsAndActivityDoNot() async throws {
        var previous = try revision()
        let changes = [
            "INSERT INTO segment(id,bundleID,startDate,endDate,type) VALUES(1,'app',0,1,0)",
            "INSERT INTO frame(id,createdAt,imageFileName,segmentId) VALUES(1,0,'',1)",
            "INSERT INTO searchRanking(rowid,text,title) VALUES(1,'original text','title')",
            "INSERT INTO doc_segment(docid,segmentId,frameId) VALUES(1,1,1)",
            "INSERT INTO tag(id,name) VALUES(999,'project')",
            "INSERT INTO segment_tag(segmentId,tagId) VALUES(1,999)",
            "UPDATE tag SET name='hidden-project' WHERE id=999",
            "UPDATE frame SET videoFrameIndex=2 WHERE id=1",
            "UPDATE segment SET windowName='changed' WHERE id=1"
        ]
        for sql in changes {
            try PipelineSQL.execute(db, sql)
            let next = try revision()
            XCTAssertGreaterThan(next, previous, sql)
            previous = next
        }
        try PipelineSQL.execute(db, "INSERT INTO segment_comment(id,body,author) VALUES(1,'comment','user')")
        expectEqual(try revision(), previous)
        try PipelineSQL.execute(db, "INSERT INTO segment_comment_link(commentId,segmentId) VALUES(1,1)")
        expectGreaterThan(try revision(), previous)
        previous = try revision()
        try PipelineSQL.execute(db, "UPDATE frame SET processingStatus=3 WHERE id=1")
        try DailyMetricsQueries.recordEvent(db: db, metricType: .progressiveRecallAction, metadata: "{\"action\":\"open\",\"outcome\":\"success\",\"count\":1}")
        _ = try await database.appendActivity(ActivityEvent(sessionID: UUID(), sequence: 1, monotonicTime: 1,
            kind: .startup, coverage: .unknown, method: "test"))
        expectEqual(try revision(), previous)
        let storeID = try await database.activityStoreID()
        let frame = try requireValue(try await database.getFrame(id: FrameID(value: 1)))
        _ = try await database.materializeScreenEvidence(frame: frame, storeID: storeID, width: 100, height: 100, text: nil)
        expectEqual(try revision(), previous)
        let importedStore = try await database.evidenceStoreID(source: .rewind, identity: "isolated-revision-fixture")
        let imported = FrameReference(id: .init(value: 42), timestamp: frame.timestamp, segmentID: frame.segmentID,
            frameIndexInSegment: 0, metadata: frame.metadata, source: .rewind)
        _ = try await database.materializeScreenEvidence(frame: imported, storeID: importedStore,
            width: 100, height: 100, text: ExtractedText(frameID: imported.id, timestamp: frame.timestamp,
                regions: [], fullText: "imported original"))
        _ = try await database.materializeScreenEvidence(frame: imported, storeID: importedStore,
            width: 100, height: 100, text: ExtractedText(frameID: imported.id, timestamp: frame.timestamp,
                regions: [], fullText: "imported changed externally"))
        expectEqual(try revision(), previous)
        _ = try await database.commitFrameOCR(frameID: frame.id,
            text: ExtractedText(frameID: frame.id, timestamp: frame.timestamp, regions: [], fullText: "updated indexed text"),
            frameWidth: 100, frameHeight: 100)
        expectGreaterThan(try revision(), previous)
        previous = try revision()
        try PipelineSQL.execute(db, "UPDATE evidence_store SET identity='renamed-native' WHERE storeID=?", [.text(storeID.uuidString)])
        expectGreaterThan(try revision(), previous)
        previous = try revision()
        try PipelineSQL.execute(db, "DELETE FROM frame WHERE id=1")
        expectGreaterThan(try revision(), previous)
    }

    private func revision() throws -> Int64 {
        try requireValue(PipelineSQL.integers(db, "SELECT revision FROM recall_search_revision WHERE id=1").first)
    }
}
