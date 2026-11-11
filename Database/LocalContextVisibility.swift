import Foundation
import Shared
import SQLCipher

extension DatabaseManager {
    /// Requires the live native writer capability as well as the exact durable
    /// active epoch. Disk state alone cannot authorize background derivation.
    public func localContextPolicyIdentity() async throws -> ScreenEvidencePolicyTransition {
        try readLocalContextIdentity().policy
    }

    public func localContextReadIdentity() async throws -> LocalContextReadIdentity {
        try readLocalContextIdentity()
    }

    private func readLocalContextIdentity() throws -> LocalContextReadIdentity {
        guard !screenEvidenceAdmissionClosing else { throw ScreenEvidenceAdmissionError.inactive }
        let db = try requireRecallConnection()
        return try PipelineSQL.transaction(db) {
            let state = try ScreenEvidenceAdmissionSQL.requireActive(db, capability: screenEvidenceAdmissionCapability)
            let storeID = try RecallSQL.nativeStore(db)
            guard let policy = state.transition, policy.session.storeID == storeID,
                  let screenRevision = try PipelineSQL.integers(db, "SELECT revision FROM recall_search_revision WHERE id=1").first,
                  screenRevision >= 0 else { throw EvidenceUnavailableReason.integrityFailure }
            let activityRevision = try PipelineSQL.integers(db, "SELECT COALESCE(MAX(sequence),0) FROM activity_feed").first ?? 0
            return .init(policy: policy, storeID: storeID, screenRevision: screenRevision,
                         nativeFeedSequence: state.feed.latestSequence, activityRevision: activityRevision)
        }
    }

    /// Missing/deleted events are hidden. Pending confirmed selection hides take
    /// effect immediately; document reuse requires acknowledged applied status.
    public func isActivityHiddenForLocalContext(eventID: UUID) async throws -> Bool {
        let db = try requireRecallConnection()
        guard let event = try RecallSQL.activity(db, eventID) else { return true }
        let hidden = try PipelineSQL.integers(db, LocalContextVisibilitySQL.hiddenActivity,
            [.text(eventID.uuidString), .text(event.event.context?.stableDocumentKey ?? "")]).first
        return hidden != 0
    }

    /// The authoritative current named tag is resolved in the same query; a
    /// cached numeric tag ID cannot survive deletion and recreation of "hidden".
    public func isScreenHiddenForLocalContext(frameID: FrameID) async throws -> Bool {
        let db = try requireRecallConnection()
        return try PipelineSQL.integers(db, """
            SELECT NOT EXISTS(SELECT 1 FROM frame WHERE id=?) OR EXISTS(
              SELECT 1 FROM frame f JOIN segment_tag st ON st.segmentId=f.segmentId
              JOIN tag t ON t.id=st.tagId WHERE f.id=? AND t.name='hidden')
            """, [.integer(frameID.value), .integer(frameID.value)]).first != 0
    }

    /// The activity feed includes acknowledgements and deletions as well as new
    /// observations. The old health revision does not fence all visibility changes.
    public func localContextActivityRevision() async throws -> Int64 {
        try PipelineSQL.integers(requireRecallConnection(), "SELECT COALESCE(MAX(sequence),0) FROM activity_feed").first ?? 0
    }
}

enum LocalContextVisibilitySQL {
    static let hiddenActivity = """
        SELECT EXISTS(
          SELECT 1 FROM activity_correction_target t
          JOIN activity_correction c ON c.commandID=t.commandID
          WHERE t.eventID=? AND c.status IN ('pending','applied')
            AND json_extract(c.payload,'$.confirmed')=1 AND json_extract(c.payload,'$.action')='hide'
            AND NOT EXISTS(
              SELECT 1 FROM activity_correction r
              WHERE r.status IN ('pending','applied') AND json_extract(r.payload,'$.confirmed')=1
                AND json_extract(r.payload,'$.action')='revoke'
                AND CAST(json_extract(r.payload,'$.revokesCommandID') AS TEXT)=c.commandID)
          UNION ALL
          SELECT 1 FROM activity_correction c
          WHERE c.status='applied' AND json_extract(c.payload,'$.confirmed')=1
            AND json_extract(c.payload,'$.action')='hide' AND json_extract(c.payload,'$.scope')='document'
            AND json_extract(c.payload,'$.documentKey')=?
            AND NOT EXISTS(
              SELECT 1 FROM activity_correction r
              WHERE r.status IN ('pending','applied') AND json_extract(r.payload,'$.confirmed')=1
                AND json_extract(r.payload,'$.action')='revoke'
                AND CAST(json_extract(r.payload,'$.revokesCommandID') AS TEXT)=c.commandID)
        )
        """
}
