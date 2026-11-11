import CryptoKit
import Foundation
import Shared
import SQLCipher

extension DatabaseManager: CaptureGroupStoreProtocol {
    public func appendCaptureGroupEvent(_ event: CaptureGroupEvent) async throws {
        guard !screenEvidenceAdmissionClosing else { throw CaptureGroupJournalError.inactive }
        let db = try requireRecallConnection()
        try PipelineSQL.transaction(db) {
            try CaptureGroupSQL.append(db, event: event, capability: screenEvidenceAdmissionCapability)
        }
    }

    public func captureGroup(for reference: ScreenEvidenceRef) async throws -> CaptureGroupSnapshot? {
        guard !screenEvidenceAdmissionClosing else { throw CaptureGroupJournalError.inactive }
        let db = try requireRecallConnection()
        return try PipelineSQL.transaction(db) {
            let state = try ScreenEvidenceAdmissionSQL.requireActive(db, capability: screenEvidenceAdmissionCapability)
            guard let policy = state.policy, let transition = state.transition,
                  reference.source == .native, reference.storeID == transition.session.storeID,
                  reference.blockIDs.isEmpty,
                  let selected = try CaptureGroupSQL.exact(db, reference: reference),
                  try CaptureGroupSQL.permitted(db, snapshot: selected, policy: policy) else {
                throw CaptureGroupStoreError.sourceUnavailable
            }
            guard let receipt = selected.frame.metadata.captureGroup else { return nil }
            let row = try CaptureGroupSQL.group(db, id: receipt.groupID)
            guard row.storeID == reference.storeID, row.descriptor.capturePolicySHA256 == transition.policySHA256 else {
                throw CaptureGroupStoreError.stalePolicy
            }
            let selectedMember = try CaptureGroupSQL.member(db, receipt: receipt, group: row.descriptor)
            guard selectedMember.frameID == reference.frameID.value, !selectedMember.deleted else {
                throw CaptureGroupStoreError.conflictingFrame
            }
            var members: [CaptureGroupMemberSnapshot] = []
            for target in row.descriptor.targets {
                let member = try CaptureGroupSQL.member(db, receipt: .init(group: row.descriptor, target: target),
                                                       group: row.descriptor)
                var retention: CaptureGroupRetentionState
                var resolved: ScreenEvidenceSnapshot?
                if member.deleted { retention = .deleted }
                else if let frameID = member.frameID {
                    resolved = try ScreenEvidenceSQL.current(db, frameID: .init(value: frameID), storeID: row.storeID)
                    retention = resolved == nil ? .unavailable : .stored
                } else if member.phase == CaptureAttemptDisposition.suppressedSimilar.rawValue,
                          let prior = member.outcome?.similarReference {
                    let earlierGroup = try CaptureGroupSQL.group(db, id: prior.member.groupID)
                    let earlier = try CaptureGroupSQL.member(db, receipt: prior.member, group: earlierGroup.descriptor)
                    guard earlierGroup.storeID == row.storeID,
                          earlier.outcome?.pixelReceipt == prior.pixelReceipt else { throw CaptureGroupStoreError.integrityFailure }
                    if earlier.deleted { retention = .deleted }
                    else if earlier.phase == "dropped" { retention = .dropped }
                    else if earlier.phase == "cancelled" { retention = .cancelled }
                    else if earlier.phase == "unavailable" { retention = .unavailable }
                    else if earlier.phase != "retainedCandidate" { throw CaptureGroupStoreError.integrityFailure }
                    else if let frameID = earlier.frameID {
                        resolved = try ScreenEvidenceSQL.current(db, frameID: .init(value: frameID), storeID: row.storeID)
                        retention = resolved == nil ? .unavailable : .similar
                    } else { retention = row.writerID == transition.session.writerID ? .pending : .interrupted }
                } else {
                    switch member.phase {
                    case "unavailable": retention = .unavailable
                    case "dropped": retention = .dropped
                    case "cancelled": retention = .cancelled
                    default: retention = row.writerID == transition.session.writerID ? .pending : .interrupted
                    }
                }
                if let snapshot = resolved, try !CaptureGroupSQL.permitted(db, snapshot: snapshot, policy: policy) {
                    resolved = nil; retention = .excluded
                }
                members.append(.init(target: target, state: retention, outcome: member.outcome,
                    reference: resolved?.ref, evidenceTimestamp: resolved?.frame.timestamp))
            }
            return .init(stamp: .init(groupID: row.descriptor.groupID,
                                      journalRevision: try CaptureGroupSQL.revision(db),
                                      policy: transition, sourceSequence: state.feed.latestSequence,
                                      metadataEpoch: state.metadataEpoch),
                         group: row.descriptor, samplingEnd: row.end, members: members)
        }
    }

    public func revalidateCaptureGroupRead(_ stamp: CaptureGroupReadStamp) async throws {
        guard !screenEvidenceAdmissionClosing else { throw CaptureGroupJournalError.inactive }
        let db = try requireRecallConnection()
        try PipelineSQL.transaction(db) {
            let state = try ScreenEvidenceAdmissionSQL.requireActive(db, capability: screenEvidenceAdmissionCapability,
                                                                     expected: stamp.policy)
            let group = try CaptureGroupSQL.group(db, id: stamp.groupID)
            guard group.storeID == stamp.policy.session.storeID,
                  try CaptureGroupSQL.revision(db) == stamp.journalRevision,
                  state.feed.latestSequence == stamp.sourceSequence, state.metadataEpoch == stamp.metadataEpoch else {
                throw CaptureGroupStoreError.sourceUnavailable
            }
        }
    }
}

enum CaptureGroupSQL {
    struct GroupRow {
        let storeID: UUID
        let writerID: UUID
        let policyEpoch: Int64
        let descriptor: CaptureSamplingGroup
        let end: CaptureSamplingEndReason?
    }
    struct MemberRow {
        let phase: String
        let outcome: CaptureAttemptOutcome?
        let latestUptime: Double
        let frameID: Int64?
        let deleted: Bool
    }

    static func append(_ db: OpaquePointer, event: CaptureGroupEvent,
                       capability: ScreenEvidenceAdmissionCapability) throws {
        let id: UUID
        let descriptor: CaptureSamplingGroup
        switch event.payload {
        case .began(let value): id = value.groupID; descriptor = value
        case .attemptOutcome(let value): id = value.member.groupID; descriptor = try group(db, id: id).descriptor
        case .samplingEnded(let value): id = value.groupID; descriptor = try group(db, id: id).descriptor
        }
        let bytes: Data
        do { bytes = try event.validatedEncoding(group: descriptor) }
        catch { throw CaptureGroupStoreError.invalidEvent }
        let hash = digest(bytes)
        var beginAuthority: ScreenEvidencePolicyTransition?
        if case .began = event.payload {
            let state = try ScreenEvidenceAdmissionSQL.requireActive(db, capability: capability)
            guard let active = state.transition, descriptor.capturePolicySHA256 == active.policySHA256 else {
                throw CaptureGroupStoreError.stalePolicy
            }
            beginAuthority = active
        }
        let previous = try PipelineSQL.query(db, "SELECT eventSHA256 FROM capture_group_event WHERE eventID=?",
            [.text(event.eventID.uuidString)]) { RecallSQL.string($0, 0) }.first
        if let previous {
            guard previous == hash else { throw CaptureGroupStoreError.conflictingEvent }
            if let active = beginAuthority {
                let original = try group(db, id: id)
                guard original.storeID == active.session.storeID, original.writerID == active.session.writerID,
                      original.policyEpoch == active.policyEpoch else { throw CaptureGroupStoreError.stalePolicy }
            }
            return
        }
        switch event.payload {
        case .began(let descriptor):
            guard let transition = beginAuthority else {
                throw CaptureGroupStoreError.stalePolicy
            }
            let existing = try PipelineSQL.integers(db, "SELECT 1 FROM capture_group WHERE groupID=?", [.text(id.uuidString)])
            guard existing.isEmpty else { throw CaptureGroupStoreError.conflictingEvent }
            let last = try PipelineSQL.query(db, """
                SELECT enumerationEnd,configurationGeneration FROM capture_group
                WHERE sessionID=? ORDER BY enumerationEnd DESC LIMIT 1
                """, [.text(descriptor.sessionID.uuidString)]) {
                    (sqlite3_column_double($0, 0), sqlite3_column_int64($0, 1))
                }.first
            if let last {
                guard descriptor.enumeration.startedUptime >= last.0,
                      descriptor.configurationGeneration >= UInt64(last.1) else { throw CaptureGroupStoreError.invalidTransition }
            }
            let json = try RecallSQL.encode(descriptor)
            guard json.utf8.count <= CaptureGroupEvent.maximumJSONBytes else { throw CaptureGroupStoreError.invalidEvent }
            for target in descriptor.targets {
                let payload = try RecallSQL.encode(target.attachment)
                let attachmentHash = digest(Data(payload.utf8))
                let existing = try PipelineSQL.query(db,
                    "SELECT sessionID,descriptorSHA256 FROM capture_display_attachment WHERE attachmentID=?",
                    [.text(target.attachment.attachmentID.uuidString)]) { (RecallSQL.string($0, 0), RecallSQL.string($0, 1)) }.first
                if let existing {
                    guard existing.0 == descriptor.sessionID.uuidString, existing.1 == attachmentHash else {
                        throw CaptureGroupStoreError.conflictingEvent
                    }
                } else {
                    try PipelineSQL.execute(db,
                        "INSERT INTO capture_display_attachment(attachmentID,sessionID,descriptorSHA256,descriptor) VALUES(?,?,?,?)",
                        [.text(target.attachment.attachmentID.uuidString), .text(descriptor.sessionID.uuidString),
                         .text(attachmentHash), .text(payload)])
                }
            }
            try PipelineSQL.execute(db, """
                INSERT INTO capture_group(groupID,storeID,sessionID,writerID,policyEpoch,configurationGeneration,
                                          enumerationStart,enumerationEnd,descriptor) VALUES(?,?,?,?,?,?,?,?,?)
                """, [.text(id.uuidString), .text(transition.session.storeID.uuidString), .text(descriptor.sessionID.uuidString),
                         .text(transition.session.writerID.uuidString), .integer(transition.policyEpoch),
                         .integer(Int64(descriptor.configurationGeneration)), .real(descriptor.enumeration.startedUptime),
                         .real(descriptor.enumeration.endedUptime), .text(json)])
            for (ordinal, target) in descriptor.targets.enumerated() {
                try PipelineSQL.execute(db, """
                    INSERT INTO capture_group_member(attemptID,groupID,ordinal,attachmentID,displayID,latestUptime)
                    VALUES(?,?,?,?,?,?)
                    """, [.text(target.attemptID.uuidString), .text(id.uuidString), .integer(Int64(ordinal)),
                             .text(target.attachment.attachmentID.uuidString), .integer(Int64(target.attachment.displayID)),
                             .real(descriptor.enumeration.endedUptime)])
            }
        case .attemptOutcome(let outcome):
            let current = try member(db, receipt: outcome.member, group: descriptor)
            guard !current.deleted, current.frameID == nil,
                  event.monotonicTime >= current.latestUptime else { throw CaptureGroupStoreError.invalidTransition }
            if current.phase == "pending" {
                guard [.retainedCandidate, .unavailable, .cancelled].contains(outcome.disposition) else {
                    throw CaptureGroupStoreError.invalidTransition
                }
            } else if current.phase == CaptureAttemptDisposition.retainedCandidate.rawValue {
                guard outcome.disposition != .unavailable, outcome.pixelReceipt == current.outcome?.pixelReceipt else {
                    throw CaptureGroupStoreError.invalidTransition
                }
            } else {
                guard current.outcome == outcome else { throw CaptureGroupStoreError.invalidTransition }
            }
            if outcome.disposition == .suppressedSimilar {
                guard let previous = outcome.similarReference else { throw CaptureGroupJournalError.referenceUnavailable }
                let priorGroup = try group(db, id: previous.member.groupID)
                let ownGroup = try group(db, id: id)
                let prior = try member(db, receipt: previous.member, group: priorGroup.descriptor)
                guard priorGroup.storeID == ownGroup.storeID,
                      priorGroup.descriptor.capturePolicySHA256 == descriptor.capturePolicySHA256,
                      !prior.deleted, prior.phase == CaptureAttemptDisposition.retainedCandidate.rawValue,
                      prior.outcome?.pixelReceipt == previous.pixelReceipt else {
                    throw CaptureGroupJournalError.referenceUnavailable
                }
            }
            let payload = try RecallSQL.encode(outcome)
            guard payload.utf8.count <= 16_384 else { throw CaptureGroupStoreError.invalidEvent }
            try PipelineSQL.execute(db, "UPDATE capture_group_member SET phase=?,outcome=?,latestUptime=? WHERE attemptID=?",
                [.text(outcome.disposition.rawValue), .text(payload), .real(event.monotonicTime), .text(outcome.member.attemptID.uuidString)])
        case .samplingEnded(let end):
            let current = try group(db, id: id)
            guard current.end == nil || current.end == end.reason else { throw CaptureGroupStoreError.invalidTransition }
            try PipelineSQL.execute(db, "UPDATE capture_group SET samplingEnd=?,samplingEndUptime=MAX(COALESCE(samplingEndUptime,0),?) WHERE groupID=?",
                [.text(end.reason.rawValue), .real(event.monotonicTime), .text(id.uuidString)])
        }
        try PipelineSQL.execute(db, "INSERT INTO capture_group_event(eventID,eventSHA256,groupID) VALUES(?,?,?)",
            [.text(event.eventID.uuidString), .text(hash), .text(id.uuidString)])
        let category: String
        switch event.payload {
        case .began(let group): category = "{\"kind\":\"began\",\"targets\":\(group.targets.count)}"
        case .attemptOutcome(let outcome):
            let comparison = outcome.comparison.map { ",\"comparison\":\"\($0.method.rawValue)\"" } ?? ""
            category = "{\"kind\":\"member\",\"outcome\":\"\(outcome.disposition.rawValue)\"\(comparison)}"
        case .samplingEnded(let end): category = "{\"kind\":\"ended\",\"outcome\":\"\(end.reason.rawValue)\"}"
        }
        try DailyMetricsQueries.recordEvent(db: db, metricType: .captureGroup, metadata: category)
    }

    /// Called inside the original frame/alias transaction. Recovery can finish
    /// an interrupted exact candidate, but cannot revive a deleted/dropped one.
    static func admit(_ db: OpaquePointer, frameID: Int64, frame: FrameReference,
                      width: Int, height: Int,
                      freshCapability: ScreenEvidenceAdmissionCapability? = nil) throws {
        guard let receipt = frame.metadata.captureGroup else { return }
        let row = try group(db, id: receipt.groupID)
        if let freshCapability {
            let active = try ScreenEvidenceAdmissionSQL.requireActive(db, capability: freshCapability)
            guard let transition = active.transition, row.storeID == transition.session.storeID,
                  row.writerID == transition.session.writerID, row.policyEpoch == transition.policyEpoch,
                  row.descriptor.capturePolicySHA256 == transition.policySHA256 else {
                throw CaptureGroupStoreError.stalePolicy
            }
        }
        let current = try member(db, receipt: receipt, group: row.descriptor)
        guard row.storeID == (try RecallSQL.nativeStore(db)), frame.source == .native,
              !current.deleted, current.phase == CaptureAttemptDisposition.retainedCandidate.rawValue,
              current.frameID == nil || current.frameID == frameID,
              let target = row.descriptor.targets.first(where: { $0.attemptID == receipt.attemptID }),
              target.attachment.pixelWidth == width, target.attachment.pixelHeight == height,
              frame.metadata.capturePolicySHA256 == row.descriptor.capturePolicySHA256,
              frame.metadata.displayID == receipt.displayID,
              frame.metadata.pixelReceipt == current.outcome?.pixelReceipt,
              frame.metadata.pixelReceipt?.attemptID == receipt.attemptID else { throw CaptureGroupStoreError.conflictingFrame }
        try frame.metadata.validatedCaptureText(frameWidth: width, frameHeight: height, timestamp: frame.timestamp)
        try PipelineSQL.execute(db, "UPDATE capture_group_member SET frameID=? WHERE attemptID=?",
            [.integer(frameID), .text(receipt.attemptID.uuidString)])
    }

    static func group(_ db: OpaquePointer, id: UUID) throws -> GroupRow {
        let value = try PipelineSQL.query(db, "SELECT storeID,writerID,descriptor,samplingEnd,policyEpoch FROM capture_group WHERE groupID=?",
            [.text(id.uuidString)]) { row -> GroupRow in
                let descriptor = try boundedDecode(CaptureSamplingGroup.self, row, column: 2, maximum: 65_536)
                guard descriptor.groupID == id, let store = UUID(uuidString: RecallSQL.string(row, 0)),
                      let writer = UUID(uuidString: RecallSQL.string(row, 1)), sqlite3_column_int64(row, 4) > 0 else {
                    throw CaptureGroupStoreError.integrityFailure
                }
                _ = try CaptureGroupEvent(occurredAt: descriptor.enumeration.endedAt,
                    monotonicTime: descriptor.enumeration.endedUptime, payload: .began(descriptor)).validatedEncoding()
                var end: CaptureSamplingEndReason?
                if sqlite3_column_type(row, 3) != SQLITE_NULL {
                    guard let parsed = CaptureSamplingEndReason(rawValue: RecallSQL.string(row, 3)) else {
                        throw CaptureGroupStoreError.integrityFailure
                    }
                    end = parsed
                }
                return .init(storeID: store, writerID: writer, policyEpoch: sqlite3_column_int64(row, 4), descriptor: descriptor, end: end)
            }.first
        guard let value else { throw CaptureGroupStoreError.groupUnavailable }
        return value
    }

    static func member(_ db: OpaquePointer, receipt: CaptureGroupFrameReceipt,
                       group: CaptureSamplingGroup) throws -> MemberRow {
        guard receipt.groupID == group.groupID, receipt.sessionID == group.sessionID,
              receipt.configurationGeneration == group.configurationGeneration,
              let target = group.targets.first(where: { $0.attemptID == receipt.attemptID }),
              target.attachment.attachmentID == receipt.attachmentID, target.attachment.displayID == receipt.displayID else {
            throw CaptureGroupStoreError.conflictingFrame
        }
        let result = try PipelineSQL.query(db, """
            SELECT phase,outcome,latestUptime,frameID,deleted,attachmentID,displayID FROM capture_group_member
            WHERE attemptID=? AND groupID=?
            """, [.text(receipt.attemptID.uuidString), .text(group.groupID.uuidString)]) { row -> MemberRow in
                guard RecallSQL.string(row, 5) == receipt.attachmentID.uuidString,
                      sqlite3_column_int64(row, 6) == Int64(receipt.displayID) else { throw CaptureGroupStoreError.integrityFailure }
                let outcome: CaptureAttemptOutcome? = sqlite3_column_type(row, 1) == SQLITE_NULL ? nil :
                    try boundedDecode(CaptureAttemptOutcome.self, row, column: 1, maximum: 16_384)
                if let outcome { guard outcome.member == receipt else { throw CaptureGroupStoreError.integrityFailure } }
                return .init(phase: RecallSQL.string(row, 0), outcome: outcome, latestUptime: sqlite3_column_double(row, 2),
                    frameID: sqlite3_column_type(row, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(row, 3),
                    deleted: sqlite3_column_int(row, 4) != 0)
            }.first
        guard let result else { throw CaptureGroupStoreError.groupUnavailable }
        return result
    }

    static func exact(_ db: OpaquePointer, reference: ScreenEvidenceRef) throws -> ScreenEvidenceSnapshot? {
        try PipelineSQL.query(db, """
            SELECT e.payload FROM screen_extraction e JOIN screen_observation o ON o.observationID=e.observationID
            JOIN frame f ON f.id=o.nativeFrameID WHERE o.storeID=? AND o.observationID=? AND o.frameID=?
            AND o.source='native' AND e.revision=?
            """, [.text(reference.storeID.uuidString), .text(reference.observationID.uuidString),
                     .integer(reference.frameID.value), .integer(reference.extractionRevision)]) { row -> ScreenEvidenceSnapshot in
                let snapshot = try boundedDecode(ScreenEvidenceSnapshot.self, row, column: 0, maximum: 8_388_608)
                guard snapshot.ref == reference else { throw CaptureGroupStoreError.integrityFailure }
                return snapshot
            }.first
    }

    static func permitted(_ db: OpaquePointer, snapshot: ScreenEvidenceSnapshot,
                          policy: ScreenEvidenceAccessPolicy) throws -> Bool {
        guard snapshot.ref.source == .native, !snapshot.legacyContext,
              snapshot.ref.storeID == (try RecallSQL.nativeStore(db)),
              let frame = try FrameQueries.getByID(db: db, id: snapshot.frame.id),
              policy.permits(snapshot.frame.metadata), policy.permits(frame.metadata),
              Schema.dateToTimestamp(frame.timestamp) == Schema.dateToTimestamp(snapshot.frame.timestamp),
              frame.metadata.appBundleID == snapshot.frame.metadata.appBundleID else { return false }
        return try PipelineSQL.integers(db, "SELECT 1 FROM screen_deleted WHERE storeID=? AND frameID=? LIMIT 1",
            [.text(snapshot.ref.storeID.uuidString), .integer(snapshot.frame.id.value)]).isEmpty
    }

    private static func boundedDecode<Value: Decodable>(_ type: Value.Type, _ row: OpaquePointer,
                                                       column: Int32, maximum: Int) throws -> Value {
        guard sqlite3_column_bytes(row, column) <= maximum else { throw CaptureGroupStoreError.integrityFailure }
        return try RecallSQL.decode(type, RecallSQL.string(row, column))
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func revision(_ db: OpaquePointer) throws -> Int64 {
        guard let revision = try PipelineSQL.integers(db, "SELECT revision FROM capture_group_state WHERE id=1").first,
              revision >= 0 else { throw CaptureGroupStoreError.integrityFailure }
        return revision
    }
}
