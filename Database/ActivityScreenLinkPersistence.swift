import Foundation
import SQLCipher
import Shared

extension DatabaseManager {
    public func linkActivityScreen(eventID: UUID, screen: ScreenEvidenceRef, capturedAt: Date,
                                   method: String) async throws -> ActivityScreenLink {
        guard screen.source == .native, screen.frameID.value > 0, screen.extractionRevision >= 0,
              screen.blockIDs.isEmpty, capturedAt.timeIntervalSince1970.isFinite,
              !method.isEmpty, method.utf8.count <= 128 else { throw RecallSQL.failure("Invalid activity screen link") }
        let db = try requireRecallConnection()
        return try PipelineSQL.transaction(db) {
            guard screen.storeID == (try RecallSQL.nativeStore(db)), let activity = try RecallSQL.activity(db, eventID),
                  let context = activity.event.context, [.observed, .uncertain].contains(activity.event.coverage) else {
                throw RecallSQL.failure("Link target activity is unavailable or unobserved")
            }
            let snapshot = try PipelineSQL.query(db, """
                SELECT e.payload FROM screen_extraction e
                  JOIN screen_observation o ON o.observationID=e.observationID
                  JOIN frame f ON f.id=o.nativeFrameID
                WHERE o.storeID=? AND o.source='native' AND o.frameID=? AND o.observationID=? AND e.revision=?
                """, [.text(screen.storeID.uuidString), .integer(screen.frameID.value),
                         .text(screen.observationID.uuidString), .integer(screen.extractionRevision)]) {
                try RecallSQL.decode(ScreenEvidenceSnapshot.self, RecallSQL.string($0, 0))
            }.first
            guard let snapshot, snapshot.ref == screen, !snapshot.legacyContext,
                  let proof = snapshot.frame.metadata.activityIdentity,
                  let capturedContext = snapshot.frame.metadata.captureContext,
                  let capturedMonotonic = snapshot.frame.metadata.captureMonotonicTime,
                  let windowID = context.windowID, windowID > 0,
                  let windowGeneration = context.windowGeneration, !windowGeneration.isEmpty,
                  context.processID > 0, !context.processGeneration.isEmpty,
                  let displayID = context.displayID, displayID > 0,
                  proof.activityEventID == eventID, proof.sessionID == activity.event.sessionID,
                  proof.processID == context.processID, proof.processGeneration == context.processGeneration,
                  proof.windowID == windowID, proof.windowGeneration == windowGeneration,
                  proof.documentID == context.documentID, proof.paneID == context.paneID,
                  capturedMonotonic.isFinite, proof.captureMonotonicTime == capturedMonotonic,
                  capturedMonotonic >= activity.event.monotonicTime,
                  ActivityLinkSQL.sameSurface(context, capturedContext),
                  snapshot.frame.metadata.appBundleID == context.appBundleID,
                  snapshot.frame.metadata.windowName == context.windowTitle,
                  snapshot.frame.metadata.displayID == displayID,
                  Schema.dateToTimestamp(snapshot.frame.timestamp) == Schema.dateToTimestamp(capturedAt),
                  snapshot.frame.timestamp >= activity.event.observedAt,
                  abs(snapshot.frame.timestamp.timeIntervalSince(activity.event.observedAt)
                      - (capturedMonotonic - activity.event.monotonicTime)) <= 2 else {
                throw RecallSQL.failure("Captured surface identity or timing does not prove this activity link")
            }

            // Use the session/monotonic index, never scan an entire library. Excess
            // history is an explicit inability to prove continuity, not an implied match.
            let intervening = try PipelineSQL.query(db, """
                SELECT payload FROM activity_event
                WHERE sessionID=? AND monotonicTime>=? AND monotonicTime<=? AND sessionSequence>?
                ORDER BY monotonicTime,sessionSequence LIMIT 129
                """, [.text(activity.event.sessionID.uuidString), .real(activity.event.monotonicTime),
                         .real(capturedMonotonic), .integer(activity.event.sequence)]) {
                try RecallSQL.decode(ActivityEvent.self, RecallSQL.string($0, 0))
            }
            guard intervening.count <= 128, intervening.allSatisfy({ event in
                guard [.observed, .uncertain].contains(event.coverage), let interveningContext = event.context else { return false }
                return ActivityLinkSQL.sameSurface(context, interveningContext)
            }) else { throw RecallSQL.failure("Intervening activity or unknown coverage prevents the link") }

            if let existing = try PipelineSQL.query(db, "SELECT payload FROM activity_screen_link WHERE eventID=? AND observationID=? AND revision=?", [
                .text(eventID.uuidString), .text(screen.observationID.uuidString), .integer(screen.extractionRevision)
            ], map: { try RecallSQL.decode(ActivityScreenLink.self, RecallSQL.string($0, 0)) }).first {
                guard existing.screen == screen, existing.capturedAt == snapshot.frame.timestamp,
                      existing.method == method else { throw RecallSQL.failure("Activity screen link retry conflicts") }
                return existing
            }
            let id = UUID()
            let sequence = try RecallSQL.feed(db, kind: "activity_screen_link", id: id, payload: "{}")
            let link = ActivityScreenLink(id: id, commitSequence: sequence, eventID: eventID, screen: screen,
                                           capturedAt: snapshot.frame.timestamp, method: method)
            let payload = try RecallSQL.encode(link)
            try PipelineSQL.execute(db, "INSERT INTO activity_screen_link(linkID,commitSequence,eventID,observationID,revision,payload,sessionID,activitySequence,captureMonotonicTime) VALUES(?,?,?,?,?,?,?,?,?)", [
                .text(id.uuidString), .integer(sequence), .text(eventID.uuidString),
                .text(screen.observationID.uuidString), .integer(screen.extractionRevision), .text(payload),
                .text(activity.event.sessionID.uuidString), .integer(activity.event.sequence), .real(capturedMonotonic)
            ])
            try PipelineSQL.execute(db, "UPDATE activity_feed SET payload=? WHERE sequence=?", [.text(payload), .integer(sequence)])
            try DailyMetricsQueries.recordEvent(db: db, metricType: .activityScreenLinked, metadata: "{\"outcome\":\"linked\"}")
            return link
        }
    }

    public func activityScreenLinks(eventID: UUID, afterSequence: Int64, limit: Int) async throws -> [ActivityScreenLink] {
        guard afterSequence >= 0, (1...500).contains(limit) else { throw RecallSQL.failure("Invalid activity screen link page") }
        return try PipelineSQL.query(requireRecallConnection(), "SELECT payload FROM activity_screen_link WHERE eventID=? AND commitSequence>? ORDER BY commitSequence LIMIT ?", [
            .text(eventID.uuidString), .integer(afterSequence), .integer(Int64(limit))
        ]) { try RecallSQL.decode(ActivityScreenLink.self, RecallSQL.string($0, 0)) }
    }
}

enum ActivityLinkSQL {
    /// Capture and activity have independent queues. A boundary committed after a
    /// screen link can still predate those pixels. Invalidate that association and
    /// publish its tombstone in the event transaction; retain the recorded screen.
    static func invalidateLateLinks(_ db: OpaquePointer, event: ActivityEvent) throws {
        let keys = ["appBundleID", "processID", "processGeneration", "windowID", "windowGeneration",
                    "displayID", "documentID", "paneID", "windowTitle", "safeURL"]
        let comparison = keys.map { "json_extract(origin.payload,'$.context.\($0)') IS json_extract(?,'$.\($0)')" }.joined(separator: " AND ")
        let context = try event.context.map(RecallSQL.encode) ?? "null"
        let observed = event.context != nil && [.observed, .uncertain].contains(event.coverage)
        let values: [PipelineSQL.Value] = [.text(event.sessionID.uuidString), .real(event.monotonicTime),
            .integer(event.sequence), .integer(observed ? 1 : 0)] + keys.map { _ in .text(context) }
        try PipelineSQL.execute(db, """
            DELETE FROM activity_screen_link
            WHERE sessionID=? AND captureMonotonicTime>=? AND activitySequence<?
              AND (?=0 OR NOT EXISTS(SELECT 1 FROM activity_event origin
                WHERE origin.eventID=activity_screen_link.eventID AND \(comparison)))
            """, values)
    }

    static func sameSurface(_ first: ActivityContext, _ second: ActivityContext) -> Bool {
        first.appBundleID == second.appBundleID && first.processID == second.processID
            && first.processGeneration == second.processGeneration && first.windowID == second.windowID
            && first.windowGeneration == second.windowGeneration && first.displayID == second.displayID
            && first.documentID == second.documentID && first.paneID == second.paneID
            && first.windowTitle == second.windowTitle && first.safeURL == second.safeURL
    }
}
