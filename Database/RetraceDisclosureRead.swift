import Foundation
import SQLCipher
import Shared

extension DatabaseManager {
    /// A single bounded native read binds retained extraction, current metadata and hidden
    /// state to the same SQLite snapshot. The revision is an optimistic read fence, never
    /// a lasting disclosure grant. Callers must also bracket the current App policy.
    public func validateNativeDisclosure(_ ref: ScreenEvidenceRef,
                                         policy: ScreenEvidenceAccessPolicy,
                                         expectedReadRevision: Int64? = nil) throws -> Int64 {
        try Task.checkCancellation()
        guard ref.source == .native, ref.frameID.value > 0, ref.extractionRevision >= 0,
              ref.blockIDs.count <= 500, Set(ref.blockIDs).count == ref.blockIDs.count else {
            throw EvidenceUnavailableReason.notPermitted
        }
        let db = try requireRecallConnection()
        let rows = try PipelineSQL.query(db, """
            SELECT e.payload,r.revision,f.createdAt,f.redactionReason,s.bundleID,s.windowName,s.browserUrl
            FROM screen_observation o
            JOIN evidence_store es ON es.storeID=o.storeID AND es.source='native'
            JOIN screen_extraction e ON e.observationID=o.observationID AND e.revision=?
            JOIN frame f ON f.id=o.nativeFrameID AND f.id=o.frameID
            LEFT JOIN segment s ON s.id=f.segmentId
            JOIN recall_search_revision r ON r.id=1
            WHERE o.storeID=? AND o.source='native' AND o.observationID=? AND o.frameID=?
              AND NOT EXISTS(SELECT 1 FROM segment_tag st JOIN tag t ON t.id=st.tagId
                             WHERE st.segmentId=f.segmentId AND t.name='hidden')
            LIMIT 1
            """, [.integer(ref.extractionRevision), .text(ref.storeID.uuidString),
                   .text(ref.observationID.uuidString), .integer(ref.frameID.value)]) { row -> Int64 in
            let snapshot = try ScreenEvidenceSQL.decodeSnapshot(RecallSQL.string(row, 0))
            let revision = sqlite3_column_int64(row, 1)
            func optional(_ column: Int32) -> String? {
                sqlite3_column_type(row, column) == SQLITE_NULL ? nil : RecallSQL.string(row, column)
            }
            let current = FrameMetadata(appBundleID: optional(4), windowName: optional(5),
                browserURL: optional(6), redactionReason: optional(3))
            guard snapshot.ref.storeID == ref.storeID, snapshot.ref.source == .native,
                  snapshot.ref.observationID == ref.observationID, snapshot.ref.frameID == ref.frameID,
                  snapshot.ref.extractionRevision == ref.extractionRevision,
                  Schema.dateToTimestamp(snapshot.frame.timestamp) == sqlite3_column_int64(row, 2),
                  policy.permitsLocalPresentation(snapshot.frame.metadata), policy.permitsLocalPresentation(current) else {
                throw EvidenceUnavailableReason.notPermitted
            }
            if !ref.blockIDs.isEmpty {
                let count = (snapshot.text?.regions.count ?? 0) + (snapshot.text?.chromeRegions.count ?? 0)
                guard snapshot.highlightsVerified, ref.blockIDs.allSatisfy({ $0 >= 0 && $0 < count }) else {
                    throw EvidenceUnavailableReason.integrityFailure
                }
            }
            if let expectedReadRevision, expectedReadRevision != revision {
                throw EvidenceUnavailableReason.evidenceDeleted
            }
            return revision
        }
        guard let revision = rows.first else { throw EvidenceUnavailableReason.notPermitted }
        try Task.checkCancellation()
        return revision
    }
}
