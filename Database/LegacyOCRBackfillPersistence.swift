import Foundation
import SQLCipher
import Shared

extension DatabaseManager {
    /// Preview only the next bounded node page. An empty result does not establish
    /// that the entire library is complete, and this read does not advance maintenance.
    public func getLegacyOCRNodeTextBackfillFrameIDs(limit: Int = 250) async throws -> [Int64] {
        guard let db = getConnection() else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try Task.checkCancellation()
        let frameLimit = min(max(limit, 0), 100)
        guard frameLimit > 0 else { return [] }
        let sweep = try legacyNodeSweep(db)
        let upperBound = try sweep.upperBound ?? newestLegacyNodeID(db)
        let page = try legacyNodePage(db, after: sweep.cursor, through: upperBound, limit: 1_000)
        var visited = Set<Int64>()
        var candidates: [Int64] = []
        for row in page {
            try Task.checkCancellation()
            guard row.missingText, visited.insert(row.frameID).inserted,
                  try isLegacyBackfillCandidate(db, frameID: row.frameID) else { continue }
            candidates.append(row.frameID)
            if candidates.count == frameLimit { break }
        }
        return candidates
    }

    /// Inspect at most 1,000 nodes and enqueue at most 100 frames in one transaction.
    /// Cursor and queue changes commit together, while readable OCR/search rows stay
    /// untouched until the worker atomically publishes replacement text. Empty means
    /// this tick enqueued nothing, including when the capture queue is busy.
    public func enqueueLegacyOCRNodeTextBackfill(
        limit: Int = 250,
        priority: Int = 75,
        maxQueueDepth: Int = 250,
        nodePageSize: Int = 1_000
    ) async throws -> [Int64] {
        guard let db = getConnection() else {
            throw DatabaseError.connectionFailed(underlying: "Database not initialized")
        }
        try Task.checkCancellation()
        let frameLimit = min(max(limit, 0), 100)
        let pageSize = min(max(nodePageSize, 0), 1_000)
        let capacity = min(max(maxQueueDepth, 0), 1_000)
        guard frameLimit > 0, pageSize > 0, capacity > 0 else { return [] }

        return try PipelineSQL.transaction(db) {
            try Task.checkCancellation()
            // LIMIT is applied to indexed pending/claimed frame rows before counting.
            // Stale/duplicate queue entries cannot turn this into an unbounded scan.
            let depth = Int(try PipelineSQL.integers(db, """
                SELECT COUNT(*) FROM (
                    SELECT id FROM frame INDEXED BY idx_frame_processing_status
                    WHERE processingStatus IN (0,1) LIMIT ?
                )
                """, [.integer(Int64(capacity))]).first ?? 0)
            guard depth < capacity else { return [] }
            let enqueueLimit = min(frameLimit, capacity - depth)
            let sweep = try legacyNodeSweep(db)
            // Freeze this pass's endpoint. Captures can append nodes faster than
            // maintenance scans; a growing tail must not prevent older revisits.
            let upperBound = try sweep.upperBound ?? newestLegacyNodeID(db)
            let page = try legacyNodePage(db, after: sweep.cursor, through: upperBound, limit: pageSize)
            var nextCursor = sweep.cursor
            var visited = Set<Int64>()
            var enqueued: [Int64] = []

            for row in page {
                try Task.checkCancellation()
                nextCursor = row.id
                guard row.missingText, visited.insert(row.frameID).inserted,
                      try isLegacyBackfillCandidate(db, frameID: row.frameID) else { continue }
                try PipelineSQL.execute(db, "UPDATE frame SET processingStatus=0 WHERE id=? AND processingStatus=2", [.integer(row.frameID)])
                try PipelineSQL.execute(db, """
                    INSERT INTO processing_queue(frameId,enqueuedAt,priority,retryCount,lastError)
                    VALUES(?,?,?,0,NULL)
                    """, [.integer(row.frameID), .real(Date().timeIntervalSince1970), .integer(Int64(priority))])
                enqueued.append(row.frameID)
                // Do not advance over the uninspected remainder of a full page.
                if enqueued.count == enqueueLimit { break }
            }

            try Task.checkCancellation()
            // Revisit earlier rows on a later tick, including frames that were busy
            // when first encountered. Never loop over a second page in this call.
            if page.isEmpty {
                try PipelineSQL.execute(db, "UPDATE ocr_backfill_state SET nodeCursor=0,nodeUpperBound=NULL WHERE id=1")
            } else {
                try PipelineSQL.execute(db, "UPDATE ocr_backfill_state SET nodeCursor=?,nodeUpperBound=? WHERE id=1", [.integer(nextCursor), .integer(upperBound)])
            }
            try Task.checkCancellation()
            return enqueued
        }
    }

    private func legacyNodeSweep(_ db: OpaquePointer) throws -> (cursor: Int64, upperBound: Int64?) {
        try PipelineSQL.query(db, "SELECT nodeCursor,nodeUpperBound FROM ocr_backfill_state WHERE id=1") {
            (sqlite3_column_int64($0, 0), sqlite3_column_type($0, 1) == SQLITE_NULL ? nil : sqlite3_column_int64($0, 1))
        }.first ?? (0, nil)
    }

    private func newestLegacyNodeID(_ db: OpaquePointer) throws -> Int64 {
        // A primary-key endpoint lookup, not a count or traversal of node text.
        try PipelineSQL.integers(db, "SELECT id FROM node ORDER BY id DESC LIMIT 1").first ?? 0
    }

    private func legacyNodePage(_ db: OpaquePointer, after cursor: Int64, through upperBound: Int64, limit: Int) throws -> [LegacyNodeRow] {
        // The only predicates before LIMIT are primary-key bounds. Filtering for
        // missing text in WHERE would still scan the entire library on sparse pages.
        try PipelineSQL.query(db, """
            SELECT id,frameId,(text IS NULL OR length(trim(text))=0)
            FROM node WHERE id>? AND id<=? ORDER BY id LIMIT ?
            """, [.integer(cursor), .integer(upperBound), .integer(Int64(limit))]) {
            LegacyNodeRow(id: sqlite3_column_int64($0, 0), frameID: sqlite3_column_int64($0, 1), missingText: sqlite3_column_int($0, 2) != 0)
        }
    }

    private func isLegacyBackfillCandidate(_ db: OpaquePointer, frameID: Int64) throws -> Bool {
        try !PipelineSQL.integers(db, """
            SELECT id FROM frame WHERE id=? AND processingStatus=2
            AND NOT EXISTS (
                SELECT 1 FROM processing_queue INDEXED BY idx_processing_queue_frame_id WHERE frameId=?
            )
            """, [.integer(frameID), .integer(frameID)]).isEmpty
    }
}

private struct LegacyNodeRow {
    let id: Int64
    let frameID: Int64
    let missingText: Bool
}
