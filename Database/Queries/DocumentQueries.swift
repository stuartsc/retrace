import Foundation
import SQLCipher
import Shared

/// Compatibility CRUD for IndexedDocument, backed by the canonical FTS5 tables.
/// Frame time and app/window metadata remain authoritative on frame/segment.
/// Native OCR uses commitFrameOCR; this API does not change processing status.
enum DocumentQueries {
    static func insert(db: OpaquePointer, document: IndexedDocument) throws -> Int64 {
        try PipelineSQL.transaction(db) {
            guard let frame = try FrameQueries.getByID(db: db, id: document.frameID),
                  try AppSegmentQueries.getByID(db: db, id: frame.segmentID.value) != nil else {
                throw PipelineSQL.failure("Cannot index a document without its frame and app segment")
            }
            guard try FTSQueries.getDocidForFrame(db: db, frameId: document.frameID.value) == nil else {
                throw PipelineSQL.failure("Frame already has a document; update it or use atomic OCR replacement")
            }
            return try FTSQueries.indexFrame(db: db, mainText: document.content, chromeText: nil,
                windowTitle: frame.metadata.windowName, segmentId: frame.segmentID.value,
                frameId: document.frameID.value)
        }
    }

    static func update(db: OpaquePointer, id: Int64, content: String) throws {
        try PipelineSQL.transaction(db) {
            // Legacy updates have no replacement bounding boxes. Old offsets/raw
            // node text must not remain attached to different indexed content.
            try PipelineSQL.execute(db, "DELETE FROM node WHERE frameId IN (SELECT frameId FROM doc_segment WHERE docid=?)", [.integer(id)])
            try PipelineSQL.execute(db, "UPDATE searchRanking SET text=?, otherText=NULL WHERE rowid=?", [.text(content), .integer(id)])
        }
    }

    static func delete(db: OpaquePointer, id: Int64) throws {
        try PipelineSQL.transaction(db) {
            try PipelineSQL.execute(db, "DELETE FROM node WHERE frameId IN (SELECT frameId FROM doc_segment WHERE docid=?)", [.integer(id)])
            try PipelineSQL.execute(db, "DELETE FROM doc_segment WHERE docid=?", [.integer(id)])
            try PipelineSQL.execute(db, "DELETE FROM searchRanking WHERE rowid=?", [.integer(id)])
        }
    }

    static func getByFrameID(db: OpaquePointer, frameID: FrameID) throws -> IndexedDocument? {
        guard let frame = try FrameQueries.getByID(db: db, id: frameID),
              let docid = try FTSQueries.getDocidForFrame(db: db, frameId: frameID.value),
              let content = try FTSQueries.getContent(db: db, docid: docid) else { return nil }
        return IndexedDocument(id: docid, frameID: frameID, timestamp: frame.timestamp,
            content: content.mainText, appName: frame.metadata.appName,
            windowName: frame.metadata.windowName, browserURL: frame.metadata.browserURL)
    }

    static func getCount(db: OpaquePointer) throws -> Int {
        Int(try PipelineSQL.integers(db, "SELECT COUNT(*) FROM searchRanking").first ?? 0)
    }
}
