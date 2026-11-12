import Foundation
import SQLCipher
import Shared

extension DatabaseManager {
    /// Current exact target, including revision zero (captured pixels, no OCR yet).
    /// No status changes or queue insertion occur during recognition.
    public func exactOCRRepairTarget(_ reference: ScreenEvidenceRef,
                                     policy: ScreenEvidenceAccessPolicy) throws -> ExactOCRRepairTarget {
        try Task.checkCancellation()
        return try ExactOCRRepairSQL.target(requireRecallConnection(), reference, policy: policy)
    }

    /// The short native publication is linearized with App policy, grant and cancellation
    /// revocation. All media reads and OCR happen before this method. Existing OCR survives
    /// every rejected/failed attempt; the immutable old extraction remains after success.
    public func commitExactOCRRepair(_ target: ExactOCRRepairTarget, text: ExtractedText,
                                    width: Int, height: Int, policy: ScreenEvidenceAccessPolicy,
                                    fences: [NativeMutationFence]) throws -> ExactOCRRepairOutcome {
        guard (1...3).contains(fences.count), Set(fences.map(ObjectIdentifier.init)).count == fences.count,
              (1...16_384).contains(width), (1...16_384).contains(height),
              width * height <= 33_554_432, text.regions.count + text.chromeRegions.count <= 4096,
              text.fullText.utf8.count + text.chromeText.utf8.count <= 1_048_576 else {
            throw ExactOCRRepairError.invalidPixels
        }
        let db = try requireRecallConnection()
        // Wait for SQLite before taking the App admission locks.
        try PipelineSQL.execute(db, "BEGIN IMMEDIATE TRANSACTION")
        do {
            func admitted<T>(_ index: Int, _ operation: () throws -> T) throws -> T {
                if index == fences.count { return try operation() }
                return try fences[index].withAdmission { try admitted(index + 1, operation) }
            }
            return try admitted(0) {
                let current = try ExactOCRRepairSQL.target(db, target.snapshot.ref, policy: policy)
                guard current.currentFrame == target.currentFrame,
                      current.sourceSequence == target.sourceSequence,
                      current.metadataEpoch == target.metadataEpoch else { throw ExactOCRRepairError.staleTarget }
                _ = try PipelineSQL.publishOCR(db, frameID: target.snapshot.ref.frameID, text: text,
                    frameWidth: width, frameHeight: height)
                guard let replacement = try ScreenEvidenceSQL.current(db, frameID: target.snapshot.ref.frameID,
                    storeID: target.snapshot.ref.storeID) else { throw ExactOCRRepairError.staleTarget }
                try Task.checkCancellation()
                // Recognition and even the bounded SQL publication can cross a grant's
                // deadline. Every admission lock is still held here; recheck its immutable
                // clock bound without taking those locks recursively.
                for fence in fences { try fence.checkDeadline() }
                try PipelineSQL.execute(db, "COMMIT")
                return .init(reference: replacement.ref)
            }
        } catch { try? PipelineSQL.execute(db, "ROLLBACK"); throw error }
    }
}

private enum ExactOCRRepairSQL {
    static func target(_ db: OpaquePointer, _ ref: ScreenEvidenceRef,
                       policy: ScreenEvidenceAccessPolicy) throws -> ExactOCRRepairTarget {
        guard ref.source == .native, ref.frameID.value > 0, ref.extractionRevision >= 0,
              ref.blockIDs.isEmpty else { throw ExactOCRRepairError.invalidTarget }
        let rows = try PipelineSQL.query(db, """
            SELECT CASE WHEN length(CAST(e.payload AS BLOB))<=8388608 THEN e.payload END,
                   COALESCE(s.latestSequence,0),a.metadataEpoch
            FROM screen_observation o
            JOIN evidence_store es ON es.storeID=o.storeID AND es.source='native' AND es.identity='native'
            JOIN screen_extraction e ON e.observationID=o.observationID AND e.revision=o.preferredRevision
            JOIN frame f ON f.id=o.nativeFrameID AND f.id=o.frameID
            LEFT JOIN screen_evidence_source_state s ON s.storeID=o.storeID AND s.observationID=o.observationID
            JOIN screen_evidence_admission_state a ON a.id=1 AND a.storeID=o.storeID
            WHERE o.storeID=? AND o.source='native' AND o.observationID=? AND o.frameID=?
              AND o.preferredRevision=? AND COALESCE(s.deleted,0)=0 AND COALESCE(s.redacted,0)=0
              AND f.processingStatus IN (0,2,3) AND f.redactionReason IS NULL
              AND NOT EXISTS(SELECT 1 FROM processing_queue q WHERE q.frameId=f.id)
              AND NOT EXISTS(SELECT 1 FROM segment_tag st JOIN tag t ON t.id=st.tagId
                             WHERE st.segmentId=f.segmentId AND t.name='hidden')
            LIMIT 1
            """, [.text(ref.storeID.uuidString), .text(ref.observationID.uuidString),
                   .integer(ref.frameID.value), .integer(ref.extractionRevision)]) { row -> ExactOCRRepairTarget in
            guard sqlite3_column_type(row, 0) != SQLITE_NULL else { throw ExactOCRRepairError.invalidTarget }
            let snapshot = try ScreenEvidenceSQL.decodeSnapshot(RecallSQL.string(row, 0))
            guard snapshot.ref == ref, snapshot.frame.source == .native,
                  let frame = try FrameQueries.getByID(db: db, id: ref.frameID),
                  Schema.dateToTimestamp(frame.timestamp) == Schema.dateToTimestamp(snapshot.frame.timestamp),
                  policy.permitsLocalPresentation(frame.metadata),
                  policy.permitsLocalPresentation(snapshot.frame.metadata) else { throw ExactOCRRepairError.invalidTarget }
            return .init(snapshot: snapshot, currentFrame: frame,
                         sourceSequence: sqlite3_column_int64(row, 1), metadataEpoch: sqlite3_column_int64(row, 2))
        }
        guard let target = rows.first else { throw ExactOCRRepairError.staleTarget }
        try Task.checkCancellation()
        return target
    }
}
