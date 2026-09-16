import Foundation
import CryptoKit
import SQLCipher
import Shared

extension DatabaseManager: ScreenEvidenceAdmissionStoreProtocol {
    private func requireAdmissionConnection() throws -> OpaquePointer {
        guard !screenEvidenceAdmissionClosing, isReady() else { throw ScreenEvidenceAdmissionError.inactive }
        return try requireRecallConnection()
    }

    public func beginScreenEvidenceWriterSession(policy: ScreenEvidenceAccessPolicy) async throws
        -> ScreenEvidencePolicyTransition {
        let connection = try requireAdmissionConnection()
        return try ScreenEvidenceAdmissionSQL.begin(connection, capability: &screenEvidenceAdmissionCapability, policy: policy)
    }

    public func prepareScreenEvidencePolicy(session: ScreenEvidenceWriterSession,
                                            policy: ScreenEvidenceAccessPolicy) async throws -> ScreenEvidencePolicyTransition {
        let connection = try requireAdmissionConnection()
        return try ScreenEvidenceAdmissionSQL.prepare(connection, capability: &screenEvidenceAdmissionCapability,
                                                      session: session, policy: policy)
    }

    public func activateScreenEvidencePolicy(_ transition: ScreenEvidencePolicyTransition) async throws {
        let connection = try requireAdmissionConnection()
        try ScreenEvidenceAdmissionSQL.activate(connection, capability: &screenEvidenceAdmissionCapability, transition: transition)
    }

    public func revokeScreenEvidencePolicy(_ transition: ScreenEvidencePolicyTransition) async throws {
        guard screenEvidenceAdmissionCapability.session == transition.session,
              screenEvidenceAdmissionCapability.prepared == transition || screenEvidenceAdmissionCapability.active == transition else { return }
        guard let connection = getConnection() else {
            screenEvidenceAdmissionCapability = ScreenEvidenceAdmissionCapability()
            return
        }
        try ScreenEvidenceAdmissionSQL.revoke(connection, capability: &screenEvidenceAdmissionCapability, transition: transition)
    }

    public func endScreenEvidenceWriterSession(_ session: ScreenEvidenceWriterSession) async throws {
        guard screenEvidenceAdmissionCapability.session == session else { return }
        guard let connection = getConnection() else {
            screenEvidenceAdmissionCapability = ScreenEvidenceAdmissionCapability()
            return
        }
        try ScreenEvidenceAdmissionSQL.end(connection, capability: &screenEvidenceAdmissionCapability, session: session)
    }

    public func claimScreenEvidenceDerivation(_ request: ScreenEvidenceDerivationRequest) async throws
        -> ScreenEvidenceDerivationClaim {
        let connection = try requireAdmissionConnection()
        return try ScreenEvidenceAdmissionSQL.claim(connection, capability: &screenEvidenceAdmissionCapability, request: request)
    }

    public func cancelScreenEvidenceDerivation(_ claim: ScreenEvidenceDerivationClaim) async throws {
        let connection = try requireAdmissionConnection()
        try ScreenEvidenceAdmissionSQL.cancel(connection, capability: &screenEvidenceAdmissionCapability, claim: claim)
    }

    public func stageScreenEvidenceArtifact(claim: ScreenEvidenceDerivationClaim, data: Data) async throws
        -> ScreenEvidenceArtifactReceipt {
        let connection = try requireAdmissionConnection()
        return try ScreenEvidenceAdmissionSQL.stage(connection, capability: &screenEvidenceAdmissionCapability, claim: claim, data: data)
    }

    public func readScreenEvidenceArtifact(_ receipt: ScreenEvidenceArtifactReceipt) async throws -> ScreenEvidenceStagedArtifact {
        let connection = try requireAdmissionConnection()
        return try ScreenEvidenceAdmissionSQL.read(connection, capability: &screenEvidenceAdmissionCapability, receipt: receipt)
    }

    public func compactScreenEvidenceArtifacts(limit: Int) async throws -> ScreenEvidenceArtifactCompaction {
        let connection = try requireAdmissionConnection()
        return try ScreenEvidenceAdmissionSQL.compact(connection, capability: &screenEvidenceAdmissionCapability, limit: limit)
    }
}

/// Owned only by the DatabaseManager actor (or a private synchronous SQLite test).
/// Persisted policy bytes alone cannot reconstruct this capability.
struct ScreenEvidenceAdmissionCapability {
    var session: ScreenEvidenceWriterSession?
    var prepared: ScreenEvidencePolicyTransition?
    var active: ScreenEvidencePolicyTransition?

    mutating func closeAdmission() { prepared = nil; active = nil }
}

/// Synchronous time input for real SQLite deadline regressions. Production uses
/// the platform clocks; tests may advance both clocks while a writer lock is held.
struct ScreenEvidenceAdmissionClock: Sendable {
    struct Instant: Sendable {
        let date: Date
        let uptime: TimeInterval
    }
    let sample: @Sendable () -> Instant
}

/// The real writer and raw private SQLite regressions share this synchronous
/// engine. No transaction suspends; injected clocks require no sleeping.
enum ScreenEvidenceAdmissionSQL {
    private static let maximumRecords = 256
    private static let maximumArtifactBytes = 262_144
    private static let maximumTotalBytes = 16_777_216
    private static let maximumJSONBytes = 65_536
    private static let maximumSnapshotBytes = 8_388_608
    private static let artifactRetention: TimeInterval = 24 * 60 * 60

    static func begin(_ db: OpaquePointer, capability: inout ScreenEvidenceAdmissionCapability,
                      policy: ScreenEvidenceAccessPolicy) throws -> ScreenEvidencePolicyTransition {
        capability = ScreenEvidenceAdmissionCapability()
        try Task.checkCancellation()
        let payload = try policyPayload(policy)
        let transition = try PipelineSQL.transaction(db) {
            let state = try readState(db)
            let session = ScreenEvidenceWriterSession(feedID: state.feed.feedID, storeID: state.feed.storeID, writerID: UUID())
            return try prepareRow(db, state: state, session: session, payload: payload)
        }
        capability.session = transition.session
        capability.prepared = transition
        return transition
    }

    static func prepare(_ db: OpaquePointer, capability: inout ScreenEvidenceAdmissionCapability,
                        session: ScreenEvidenceWriterSession, policy: ScreenEvidenceAccessPolicy) throws -> ScreenEvidencePolicyTransition {
        guard capability.session == session else { throw ScreenEvidenceAdmissionError.staleSession }
        capability.closeAdmission()
        try Task.checkCancellation()
        let payload = try policyPayload(policy)
        let transition = try PipelineSQL.transaction(db) {
            let state = try readState(db)
            guard state.session == session, state.phase != "inactive" else { throw ScreenEvidenceAdmissionError.staleSession }
            return try prepareRow(db, state: state, session: session, payload: payload)
        }
        capability.prepared = transition
        return transition
    }

    static func activate(_ db: OpaquePointer, capability: inout ScreenEvidenceAdmissionCapability,
                         transition: ScreenEvidencePolicyTransition) throws {
        guard capability.session == transition.session else { throw ScreenEvidenceAdmissionError.staleSession }
        guard capability.prepared == transition else { throw ScreenEvidenceAdmissionError.stalePolicy }
        // A failed COMMIT or cancellation cannot leave a locally reusable grant.
        capability.closeAdmission()
        try Task.checkCancellation()
        try PipelineSQL.transaction(db) {
            let state = try readState(db)
            try match(state, transition: transition)
            guard state.phase == "prepared" else { throw ScreenEvidenceAdmissionError.stalePolicy }
            try PipelineSQL.execute(db, "UPDATE screen_evidence_admission_state SET phase='active' WHERE id=1")
            try Task.checkCancellation()
        }
        capability.active = transition
    }

    static func revoke(_ db: OpaquePointer, capability: inout ScreenEvidenceAdmissionCapability,
                       transition: ScreenEvidencePolicyTransition) throws {
        // Delayed cleanup from an older operation must not even close a newer
        // local epoch. This path deliberately ignores caller cancellation.
        guard capability.session == transition.session,
              capability.prepared == transition || capability.active == transition else { return }
        capability.closeAdmission()
        try PipelineSQL.transaction(db) {
            try PipelineSQL.execute(db, """
                UPDATE screen_evidence_admission_state SET phase='revoked'
                WHERE id=1 AND feedID=? AND storeID=? AND writerID=? AND policyEpoch=? AND policySHA256=?
                """, tokenValues(transition))
        }
    }

    static func end(_ db: OpaquePointer, capability: inout ScreenEvidenceAdmissionCapability,
                    session: ScreenEvidenceWriterSession) throws {
        guard capability.session == session else { return }
        capability = ScreenEvidenceAdmissionCapability()
        try PipelineSQL.transaction(db) {
            try PipelineSQL.execute(db, """
                UPDATE screen_evidence_admission_state SET phase='revoked'
                WHERE id=1 AND feedID=? AND storeID=? AND writerID=?
                """, [.text(session.feedID.uuidString), .text(session.storeID.uuidString), .text(session.writerID.uuidString)])
        }
    }

    static func claim(_ db: OpaquePointer, capability: inout ScreenEvidenceAdmissionCapability,
                      request: ScreenEvidenceDerivationRequest, now: Date? = nil,
                      uptime: TimeInterval? = nil, clock: ScreenEvidenceAdmissionClock? = nil) throws -> ScreenEvidenceDerivationClaim {
        try Task.checkCancellation()
        try validateRequest(request)
        let clock = resolvedClock(now: now, uptime: uptime, override: clock)
        return try PipelineSQL.transaction(db) {
            let started = try checkedInstant(clock)
            let now = started.date, uptime = started.uptime
            let state = try requireActive(db, capability: capability)
            let consumerExpiry = try requireConsumer(db, request.cursor, feed: state.feed, now: now)
            let input = try loadInput(db, request: request, state: state)
            // Only a genuinely live attempt blocks a new one. Old policy/source
            // attempts remain as bounded receipts, with no transferable authority.
            let previous = try records(db, """
                WHERE consumerID=? AND storeID=? AND observationID=? AND channel=? AND status='claimed'
                """, [.text(request.cursor.consumerID.uuidString), .text(request.expansion.reference.storeID.uuidString),
                        .text(request.expansion.reference.observationID.uuidString), .text(request.channel.rawValue)])
            for row in previous {
                if live(row, state: state, cursor: request.cursor, input: input, now: now, uptime: uptime) {
                    throw ScreenEvidenceAdmissionError.attemptInProgress
                }
                try invalidate(db, row.claim.attemptID)
            }
            guard try totals(db).count < maximumRecords else { throw ScreenEvidenceAdmissionError.capacityExceeded }
            let deadline = min(now.addingTimeInterval(request.executionDuration), consumerExpiry)
            guard deadline > now, let transition = state.transition else { throw ScreenEvidenceAdmissionError.invalidConsumer }
            let claim = ScreenEvidenceDerivationClaim(attemptID: UUID(), request: request, policy: transition,
                sourceSequence: input.sequence, metadataEpoch: state.metadataEpoch, inputSHA256: input.hash,
                inputUTF8Bytes: input.bytes, fragmentCount: input.fragments, nextCursor: input.nextCursor,
                issuedAt: now, deadline: deadline)
            let payload = try boundedJSON(claim)
            let deadlineUptime = uptime + min(request.executionDuration, deadline.timeIntervalSince(now))
            _ = try validateExecution(claim, deadlineUptime: deadlineUptime, consumerExpiry: consumerExpiry, clock: clock)
            try PipelineSQL.execute(db, """
                INSERT INTO screen_evidence_derivation(attemptID,consumerID,storeID,observationID,channel,
                  writerID,policyEpoch,claimPayload,status,deadline,deadlineUptime)
                VALUES(?,?,?,?,?,?,?,?,'claimed',?,?)
                """, [.text(claim.attemptID.uuidString), .text(request.cursor.consumerID.uuidString),
                    .text(request.expansion.reference.storeID.uuidString), .text(request.expansion.reference.observationID.uuidString),
                    .text(request.channel.rawValue), .text(transition.session.writerID.uuidString), .integer(transition.policyEpoch),
                    .text(payload), .real(deadline.timeIntervalSince1970),
                    .real(deadlineUptime)])
            _ = try validateExecution(claim, deadlineUptime: deadlineUptime, consumerExpiry: consumerExpiry, clock: clock)
            try Task.checkCancellation()
            return claim
        }
    }

    static func cancel(_ db: OpaquePointer, capability: inout ScreenEvidenceAdmissionCapability,
                       claim: ScreenEvidenceDerivationClaim) throws {
        // Like policy cleanup, exact cancellation remains usable by a cancelled
        // caller. It can remove only this owner's authoritative attempt.
        guard capability.session == claim.policy.session else { throw ScreenEvidenceAdmissionError.staleSession }
        try PipelineSQL.transaction(db) {
            let row = try requireRecord(db, claim: claim)
            try PipelineSQL.execute(db, """
                UPDATE screen_evidence_derivation SET status='cancelled',artifact=NULL,artifactBytes=0,
                  receiptPayload=NULL,retainUntil=NULL WHERE attemptID=?
                """, [.text(row.claim.attemptID.uuidString)])
        }
    }

    static func stage(_ db: OpaquePointer, capability: inout ScreenEvidenceAdmissionCapability,
                      claim: ScreenEvidenceDerivationClaim, data: Data, now: Date? = nil,
                      uptime: TimeInterval? = nil,
                      clock: ScreenEvidenceAdmissionClock? = nil) throws -> ScreenEvidenceArtifactReceipt {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= maximumArtifactBytes else { throw ScreenEvidenceAdmissionError.invalidRequest }
        let clock = resolvedClock(now: now, uptime: uptime, override: clock)
        let digest = sha256(data)
        return try PipelineSQL.transaction(db) {
            // Sampling after BEGIN includes time spent waiting on another writer.
            let started = try checkedInstant(clock)
            let state = try requireActive(db, capability: capability, expected: claim.policy)
            let row = try requireRecord(db, claim: claim)
            let consumerExpiry = try validateCurrent(db, row: row, state: state, now: started.date)
            if row.status == "staged" {
                let receipt = try retainedReceipt(row, now: started.date)
                guard receipt.artifactSHA256 == digest, receipt.artifactBytes == data.count else {
                    throw ScreenEvidenceAdmissionError.conflictingResult
                }
                _ = try artifactData(db, claimID: row.claim.attemptID, receipt: receipt)
                // Completed retry retention is independent of execution expiry.
                let finished = try checkedInstant(clock)
                try validateConsumerExpiry(consumerExpiry, at: finished.date)
                _ = try retainedReceipt(row, now: finished.date)
                try Task.checkCancellation()
                return receipt
            }
            let current = try totals(db)
            guard current.bytes <= maximumTotalBytes - data.count else { throw ScreenEvidenceAdmissionError.capacityExceeded }
            let publication = try validateExecution(row.claim, deadlineUptime: row.deadlineUptime,
                                                     consumerExpiry: consumerExpiry, clock: clock)
            let receipt = ScreenEvidenceArtifactReceipt(receiptID: UUID(), claim: row.claim,
                artifactSHA256: digest, artifactBytes: data.count, stagedAt: publication.date)
            let encoded = try boundedJSON(receipt)
            let retainUntil = min(publication.date.addingTimeInterval(artifactRetention), consumerExpiry)
            try PipelineSQL.execute(db, """
                UPDATE screen_evidence_derivation SET status='staged',receiptPayload=?,artifact=?,artifactBytes=?,retainUntil=?
                WHERE attemptID=? AND status='claimed'
                """, [.text(encoded), .blob(data), .integer(Int64(data.count)), .real(retainUntil.timeIntervalSince1970),
                        .text(row.claim.attemptID.uuidString)])
            guard sqlite3_changes(db) == 1 else { throw ScreenEvidenceAdmissionError.integrityFailure }
            // Roll back if bounded serialization/storage crossed the deadline.
            // The check is logical admission, not a physical fsync-time promise.
            let finished = try validateExecution(row.claim, deadlineUptime: row.deadlineUptime,
                                                  consumerExpiry: consumerExpiry, clock: clock)
            guard finished.date >= receipt.stagedAt else { throw ScreenEvidenceAdmissionError.claimExpired }
            try Task.checkCancellation()
            return receipt
        }
    }

    static func read(_ db: OpaquePointer, capability: inout ScreenEvidenceAdmissionCapability,
                     receipt: ScreenEvidenceArtifactReceipt, now: Date? = nil,
                     clock: ScreenEvidenceAdmissionClock? = nil) throws -> ScreenEvidenceStagedArtifact {
        try Task.checkCancellation()
        let clock = resolvedClock(now: now, uptime: nil, override: clock)
        return try PipelineSQL.transaction(db) {
            let started = try checkedInstant(clock)
            let state = try requireActive(db, capability: capability, expected: receipt.claim.policy)
            let row = try requireRecord(db, claim: receipt.claim)
            let consumerExpiry = try validateCurrent(db, row: row, state: state, now: started.date)
            let retained = try retainedReceipt(row, now: started.date)
            guard try identical(retained, receipt) else { throw ScreenEvidenceAdmissionError.invalidClaim }
            let data = try artifactData(db, claimID: row.claim.attemptID, receipt: retained)
            let finished = try checkedInstant(clock)
            try validateConsumerExpiry(consumerExpiry, at: finished.date)
            _ = try retainedReceipt(row, now: finished.date)
            try Task.checkCancellation()
            return ScreenEvidenceStagedArtifact(receipt: retained, data: data)
        }
    }

    static func compact(_ db: OpaquePointer, capability: inout ScreenEvidenceAdmissionCapability,
                        limit: Int, now: Date? = nil, uptime: TimeInterval? = nil,
                        clock: ScreenEvidenceAdmissionClock? = nil) throws
        -> ScreenEvidenceArtifactCompaction {
        try Task.checkCancellation()
        guard (1...100).contains(limit) else { throw ScreenEvidenceAdmissionError.invalidRequest }
        let clock = resolvedClock(now: now, uptime: uptime, override: clock)
        return try PipelineSQL.transaction(db) {
            let started = try checkedInstant(clock)
            let now = started.date, uptime = started.uptime
            let state = try readState(db)
            // At most 256 identity receipts exist. No blob, OCR or historical
            // corpus scan is needed to find a bounded set of stale receipts.
            let candidates = try records(db, "ORDER BY deadline,attemptID", [])
            var removed = 0, artifacts = 0, bytes = 0
            for row in candidates where removed < limit {
                try Task.checkCancellation()
                var stale = row.status == "cancelled" || row.status == "invalidated"
                    || state.phase != "active" || state.transition != row.claim.policy
                    || row.claim.metadataEpoch != state.metadataEpoch
                if row.status == "claimed", !withinDeadline(row, now: now, uptime: uptime) { stale = true }
                if row.status == "staged", row.retainUntil.map({ $0 <= now }) ?? true { stale = true }
                if !stale { stale = try staleSourceOrConsumer(db, row: row, state: state, now: now) }
                if stale {
                    try PipelineSQL.execute(db, "DELETE FROM screen_evidence_derivation WHERE attemptID=?", [.text(row.claim.attemptID.uuidString)])
                    removed += 1
                    if row.artifactBytes > 0 { artifacts += 1; bytes += row.artifactBytes }
                }
            }
            try Task.checkCancellation()
            return ScreenEvidenceArtifactCompaction(removedClaims: removed, removedArtifacts: artifacts, removedArtifactBytes: bytes)
        }
    }

    private struct State {
        let feed: ScreenEvidenceFeedStatus
        let session: ScreenEvidenceWriterSession?
        let policyEpoch: Int64
        let metadataEpoch: Int64
        let phase: String
        let policy: ScreenEvidenceAccessPolicy?
        let policyHash: String?
        var transition: ScreenEvidencePolicyTransition? {
            guard let session, let policyHash else { return nil }
            return .init(session: session, policyEpoch: policyEpoch, policySHA256: policyHash)
        }
    }

    private struct Record {
        let claim: ScreenEvidenceDerivationClaim
        let status: String
        let deadlineUptime: TimeInterval
        let receipt: ScreenEvidenceArtifactReceipt?
        let artifactBytes: Int
        let retainUntil: Date?
    }

    private struct Input {
        let sequence: Int64
        let hash: String
        let bytes: Int
        let fragments: Int
        let nextCursor: ScreenEvidenceExpansionCursor?
    }

    /// The explicit envelope avoids concatenation ambiguity and preserves actual
    /// Unicode code units, fragment ranges and the complete requested block scope.
    /// It is hashed in memory; retained attempt rows contain no copied OCR text.
    private struct InputManifest: Encodable {
        let formatVersion = 1
        let extractionSHA256: String
        let captureSHA256: String
        let request: ScreenEvidenceExpansionRequest
        let fragments: [FragmentManifest]
        let nextCursor: ScreenEvidenceExpansionCursor?
    }

    private struct FragmentManifest: Encodable {
        let identity: ScreenEvidenceFragmentID
        let text: String
        let range: EvidenceUTF16Range
        let bounds: [Double]?
        let isLastFragment: Bool
        let provenance: EvidenceExtractionProvenance
        init(_ fragment: ScreenEvidenceTextFragment) {
            identity = fragment.id; text = fragment.text; range = fragment.utf16Range
            bounds = fragment.blockBounds.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
            isLastFragment = fragment.isLastFragment; provenance = fragment.provenance
        }
    }

    private static func readState(_ db: OpaquePointer) throws -> State {
        let feed: ScreenEvidenceFeedStatus
        do { feed = try ScreenEvidenceFeedSQL.status(db) }
        catch is ScreenEvidenceFeedError { throw ScreenEvidenceAdmissionError.integrityFailure }
        let rows = try PipelineSQL.query(db, """
            SELECT feedID,storeID,writerID,policyEpoch,metadataEpoch,phase,policySHA256,policyPayload
            FROM screen_evidence_admission_state WHERE id=1
            """) { row -> State in
            guard UUID(uuidString: RecallSQL.string(row, 0)) == feed.feedID,
                  UUID(uuidString: RecallSQL.string(row, 1)) == feed.storeID else {
                throw ScreenEvidenceAdmissionError.integrityFailure
            }
            let epoch = sqlite3_column_int64(row, 3), metadata = sqlite3_column_int64(row, 4)
            let phase = RecallSQL.string(row, 5)
            guard epoch >= 0, metadata >= 0, ["inactive", "prepared", "active", "revoked"].contains(phase) else {
                throw ScreenEvidenceAdmissionError.integrityFailure
            }
            var session: ScreenEvidenceWriterSession?
            if sqlite3_column_type(row, 2) != SQLITE_NULL {
                guard let owner = UUID(uuidString: RecallSQL.string(row, 2)) else { throw ScreenEvidenceAdmissionError.integrityFailure }
                session = .init(feedID: feed.feedID, storeID: feed.storeID, writerID: owner)
            }
            var policy: ScreenEvidenceAccessPolicy?, hash: String?
            if sqlite3_column_type(row, 7) != SQLITE_NULL {
                let payload = RecallSQL.string(row, 7)
                hash = RecallSQL.string(row, 6)
                guard payload.utf8.count <= maximumJSONBytes, hash == sha256(Data(payload.utf8)),
                      let decoded = try? RecallSQL.decode(ScreenEvidenceAccessPolicy.self, payload), decoded.formatVersion == 1 else {
                    throw ScreenEvidenceAdmissionError.integrityFailure
                }
                policy = decoded
            }
            if phase == "prepared" || phase == "active" {
                guard session != nil, policy != nil, epoch > 0 else { throw ScreenEvidenceAdmissionError.integrityFailure }
            }
            return State(feed: feed, session: session, policyEpoch: epoch, metadataEpoch: metadata,
                         phase: phase, policy: policy, policyHash: hash)
        }
        guard rows.count == 1, let state = rows.first else { throw ScreenEvidenceAdmissionError.integrityFailure }
        return state
    }

    private static func prepareRow(_ db: OpaquePointer, state: State, session: ScreenEvidenceWriterSession,
                                   payload: String) throws -> ScreenEvidencePolicyTransition {
        guard state.policyEpoch < Int64.max else { throw ScreenEvidenceAdmissionError.integrityFailure }
        let epoch = state.policyEpoch + 1, hash = sha256(Data(payload.utf8))
        try PipelineSQL.execute(db, """
            UPDATE screen_evidence_admission_state SET writerID=?,policyEpoch=?,phase='prepared',policySHA256=?,policyPayload=? WHERE id=1
            """, [.text(session.writerID.uuidString), .integer(epoch), .text(hash), .text(payload)])
        guard sqlite3_changes(db) == 1 else { throw ScreenEvidenceAdmissionError.integrityFailure }
        try Task.checkCancellation()
        return .init(session: session, policyEpoch: epoch, policySHA256: hash)
    }

    private static func match(_ state: State, transition: ScreenEvidencePolicyTransition) throws {
        guard state.session == transition.session else { throw ScreenEvidenceAdmissionError.staleSession }
        guard state.transition == transition else { throw ScreenEvidenceAdmissionError.stalePolicy }
    }

    private static func requireActive(_ db: OpaquePointer, capability: ScreenEvidenceAdmissionCapability,
                                      expected: ScreenEvidencePolicyTransition? = nil) throws -> State {
        guard let active = capability.active, capability.session == active.session else { throw ScreenEvidenceAdmissionError.inactive }
        if let expected {
            guard expected.session == active.session else { throw ScreenEvidenceAdmissionError.staleSession }
            guard expected == active else { throw ScreenEvidenceAdmissionError.stalePolicy }
        }
        let state = try readState(db)
        try match(state, transition: active)
        guard state.phase == "active", state.policy != nil else { throw ScreenEvidenceAdmissionError.inactive }
        return state
    }

    private static func requireConsumer(_ db: OpaquePointer, _ cursor: ScreenEvidenceConsumerCursor,
                                        feed: ScreenEvidenceFeedStatus, now: Date) throws -> Date {
        guard cursor.feedID == feed.feedID, cursor.storeID == feed.storeID else { throw ScreenEvidenceAdmissionError.invalidConsumer }
        let rows = try PipelineSQL.query(db, """
            SELECT feedID,storeID,leaseID,phase,expiresAt,bootstrapBoundary,checkpoint,maxFrameID,lastFrameID
            FROM screen_evidence_consumer WHERE consumerID=?
            """, [.text(cursor.consumerID.uuidString)]) { row -> Date in
            let phase = RecallSQL.string(row, 3), expiry = Date(timeIntervalSince1970: sqlite3_column_double(row, 4))
            let boundary = sqlite3_column_int64(row, 5), checkpoint = sqlite3_column_int64(row, 6)
            let maximum = sqlite3_column_int64(row, 7), last = sqlite3_column_int64(row, 8)
            guard UUID(uuidString: RecallSQL.string(row, 0)) == cursor.feedID,
                  UUID(uuidString: RecallSQL.string(row, 1)) == cursor.storeID,
                  UUID(uuidString: RecallSQL.string(row, 2)) == cursor.leaseID,
                  phase == "bootstrap" || phase == "replay", expiry.timeIntervalSince1970.isFinite, expiry > now,
                  boundary >= 0, checkpoint >= boundary, checkpoint <= feed.latestSequence,
                  maximum >= 0, last >= 0, last <= maximum,
                  phase != "bootstrap" || checkpoint == boundary,
                  (phase == "bootstrap" ? boundary : checkpoint) >= feed.retainedThrough else {
                throw ScreenEvidenceAdmissionError.invalidConsumer
            }
            return expiry
        }
        guard rows.count == 1, let result = rows.first else { throw ScreenEvidenceAdmissionError.invalidConsumer }
        return result
    }

    private static func loadInput(_ db: OpaquePointer, request: ScreenEvidenceDerivationRequest,
                                  state: State, retainedClaim: ScreenEvidenceDerivationClaim? = nil) throws -> Input {
        let ref = request.expansion.reference
        let referenceError: ScreenEvidenceAdmissionError = retainedClaim == nil ? .invalidReference : .sourceChanged
        guard ref.source == .native, ref.storeID == state.feed.storeID, ref.frameID.value > 0, ref.extractionRevision >= 0,
              ref.blockIDs.count <= 500, Set(ref.blockIDs).count == ref.blockIDs.count else { throw referenceError }
        if let retainedClaim, retainedClaim.metadataEpoch != state.metadataEpoch { throw ScreenEvidenceAdmissionError.sourceChanged }
        let rows = try PipelineSQL.query(db, """
            SELECT o.frameID,o.nativeFrameID,o.source,o.preferredRevision,
              CASE WHEN length(CAST(o.framePayload AS BLOB))<=? THEN o.framePayload END,
              CASE WHEN length(CAST(e.payload AS BLOB))<=? THEN e.payload END,
              f.id,f.createdAt,f.segmentId,g.id,g.bundleID,g.windowName,g.browserUrl,f.redactionReason,m.reason,
              s.frameID,s.latestSequence,s.extractionRevision,s.deleted,s.redacted,s.mediaUnavailableReason,
              EXISTS(SELECT 1 FROM screen_deleted d WHERE d.storeID=o.storeID AND d.observationID=o.observationID)
            FROM screen_observation o
            LEFT JOIN screen_extraction e ON e.observationID=o.observationID AND e.revision=o.preferredRevision
            LEFT JOIN frame f ON f.id=o.nativeFrameID
            LEFT JOIN segment g ON g.id=f.segmentId
            LEFT JOIN frame_media_unavailable m ON m.frameID=f.id
            LEFT JOIN screen_evidence_source_state s ON s.storeID=o.storeID AND s.observationID=o.observationID
            WHERE o.storeID=? AND o.observationID=?
            """, [.integer(Int64(maximumSnapshotBytes)), .integer(Int64(maximumSnapshotBytes)),
                    .text(ref.storeID.uuidString), .text(ref.observationID.uuidString)]) { row -> Input in
            guard sqlite3_column_int64(row, 0) == ref.frameID.value,
                  sqlite3_column_type(row, 1) != SQLITE_NULL, sqlite3_column_int64(row, 1) == ref.frameID.value,
                  RecallSQL.string(row, 2) == "native", sqlite3_column_int64(row, 3) == ref.extractionRevision,
                  sqlite3_column_type(row, 6) != SQLITE_NULL, sqlite3_column_int64(row, 6) == ref.frameID.value,
                  sqlite3_column_int(row, 21) == 0 else { throw referenceError }
            guard sqlite3_column_type(row, 4) != SQLITE_NULL, sqlite3_column_type(row, 5) != SQLITE_NULL,
                  sqlite3_column_type(row, 8) == SQLITE_NULL || sqlite3_column_type(row, 9) != SQLITE_NULL else {
                throw ScreenEvidenceAdmissionError.integrityFailure
            }
            let capturePayload = RecallSQL.string(row, 4), extractionPayload = RecallSQL.string(row, 5)
            let original = try RecallSQL.decode(FrameReference.self, capturePayload)
            let snapshot = try ScreenEvidenceSQL.decodeSnapshot(extractionPayload)
            let base = ScreenEvidenceRef(storeID: ref.storeID, source: ref.source, observationID: ref.observationID,
                                         frameID: ref.frameID, extractionRevision: ref.extractionRevision)
            guard snapshot.ref == base, original == snapshot.frame, snapshot.frame.id == ref.frameID,
                  snapshot.frame.source == .native,
                  Schema.dateToTimestamp(snapshot.frame.timestamp) == sqlite3_column_int64(row, 7) else { throw referenceError }
            let redacted = sqlite3_column_type(row, 13) != SQLITE_NULL
            let reason = optionalString(row, 14)
            var sequence: Int64 = 0
            if sqlite3_column_type(row, 15) != SQLITE_NULL {
                sequence = sqlite3_column_int64(row, 16)
                guard sqlite3_column_int64(row, 15) == ref.frameID.value, sequence > 0, sequence <= state.feed.latestSequence,
                      sqlite3_column_int64(row, 17) == ref.extractionRevision, sqlite3_column_int(row, 18) == 0,
                      (sqlite3_column_int(row, 19) != 0) == redacted, optionalString(row, 20) == reason else {
                    throw ScreenEvidenceAdmissionError.sourceChanged
                }
            }
            if let retainedClaim, retainedClaim.sourceSequence != sequence { throw ScreenEvidenceAdmissionError.sourceChanged }
            guard let policy = state.policy else { throw ScreenEvidenceAdmissionError.inactive }
            let current = FrameMetadata(appBundleID: optionalString(row, 10), windowName: optionalString(row, 11),
                                        browserURL: optionalString(row, 12), redactionReason: optionalString(row, 13))
            guard policy.permits(original.metadata), policy.permits(snapshot.frame.metadata), policy.permits(current) else {
                throw ScreenEvidenceAdmissionError.notPermitted
            }
            guard reason == nil else { throw ScreenEvidenceAdmissionError.sourceChanged }
            try requireWork(db, request: request, sequence: sequence)
            if !ref.blockIDs.isEmpty {
                let count = (snapshot.text?.regions.count ?? 0) + (snapshot.text?.chromeRegions.count ?? 0)
                guard snapshot.highlightsVerified, ref.blockIDs.allSatisfy({ $0 >= 0 && $0 < count }) else { throw referenceError }
            }
            let page: ScreenEvidenceExpansionPage
            do { page = try snapshot.expansionPage(for: request.expansion) }
            catch is ScreenEvidenceExpansionError { throw ScreenEvidenceAdmissionError.invalidRequest }
            guard page.textUTF8Bytes > 0, !page.fragments.isEmpty else { throw ScreenEvidenceAdmissionError.invalidRequest }
            let manifest = InputManifest(extractionSHA256: sha256(Data(extractionPayload.utf8)),
                captureSHA256: sha256(Data(capturePayload.utf8)), request: request.expansion,
                fragments: page.fragments.map(FragmentManifest.init), nextCursor: page.nextCursor)
            let inputHash = sha256(Data(try RecallSQL.encode(manifest).utf8))
            return Input(sequence: sequence, hash: inputHash, bytes: page.textUTF8Bytes,
                         fragments: page.fragments.count, nextCursor: page.nextCursor)
        }
        guard rows.count == 1, let result = rows.first else { throw referenceError }
        return result
    }

    private static func requireWork(_ db: OpaquePointer, request: ScreenEvidenceDerivationRequest, sequence: Int64) throws {
        let ref = request.expansion.reference
        let rows = try PipelineSQL.query(db, """
            SELECT frameID,leaseID,extractionRevision,sourceSequence,state FROM screen_evidence_work
            WHERE consumerID=? AND storeID=? AND observationID=? AND channel=?
            """, [.text(request.cursor.consumerID.uuidString), .text(ref.storeID.uuidString),
                    .text(ref.observationID.uuidString), .text(request.channel.rawValue)]) { row -> Bool in
            guard UUID(uuidString: RecallSQL.string(row, 1)) == request.cursor.leaseID else {
                throw ScreenEvidenceAdmissionError.invalidConsumer
            }
            return sqlite3_column_int64(row, 0) == ref.frameID.value && sqlite3_column_int64(row, 2) == ref.extractionRevision
                && sqlite3_column_int64(row, 3) == sequence && RecallSQL.string(row, 4) == "blocked"
        }
        guard rows.count == 1 else { throw ScreenEvidenceAdmissionError.invalidConsumer }
        guard rows.first == true else { throw ScreenEvidenceAdmissionError.sourceChanged }
    }

    private static let recordColumns = """
        attemptID,consumerID,storeID,observationID,channel,writerID,policyEpoch,claimPayload,
        status,deadline,deadlineUptime,receiptPayload,artifactBytes,retainUntil
        """

    private static func records(_ db: OpaquePointer, _ suffix: String, _ values: [PipelineSQL.Value]) throws -> [Record] {
        let result = try PipelineSQL.query(db, "SELECT \(recordColumns) FROM screen_evidence_derivation \(suffix) LIMIT 257", values) { row -> Record in
            let encoded = RecallSQL.string(row, 7)
            guard encoded.utf8.count <= maximumJSONBytes,
                  let claim = try? RecallSQL.decode(ScreenEvidenceDerivationClaim.self, encoded),
                  UUID(uuidString: RecallSQL.string(row, 0)) == claim.attemptID,
                  UUID(uuidString: RecallSQL.string(row, 1)) == claim.request.cursor.consumerID,
                  UUID(uuidString: RecallSQL.string(row, 2)) == claim.request.expansion.reference.storeID,
                  UUID(uuidString: RecallSQL.string(row, 3)) == claim.request.expansion.reference.observationID,
                  RecallSQL.string(row, 4) == claim.request.channel.rawValue,
                  UUID(uuidString: RecallSQL.string(row, 5)) == claim.policy.session.writerID,
                  sqlite3_column_int64(row, 6) == claim.policy.policyEpoch,
                  sqlite3_column_double(row, 9) == claim.deadline.timeIntervalSince1970 else {
                throw ScreenEvidenceAdmissionError.integrityFailure
            }
            let status = RecallSQL.string(row, 8), deadline = sqlite3_column_double(row, 10)
            let size = Int(sqlite3_column_int64(row, 12))
            guard ["claimed", "staged", "cancelled", "invalidated"].contains(status), deadline.isFinite, deadline >= 0,
                  (0...maximumArtifactBytes).contains(size) else { throw ScreenEvidenceAdmissionError.integrityFailure }
            var receipt: ScreenEvidenceArtifactReceipt?, retainUntil: Date?
            if sqlite3_column_type(row, 11) != SQLITE_NULL {
                let payload = RecallSQL.string(row, 11)
                guard payload.utf8.count <= maximumJSONBytes,
                      let decoded = try? RecallSQL.decode(ScreenEvidenceArtifactReceipt.self, payload),
                      try identical(decoded.claim, claim), decoded.artifactBytes == size,
                      validSHA(decoded.artifactSHA256), decoded.status == .stagedUnpublished else {
                    throw ScreenEvidenceAdmissionError.integrityFailure
                }
                receipt = decoded
                let expiry = Date(timeIntervalSince1970: sqlite3_column_double(row, 13))
                guard sqlite3_column_type(row, 13) != SQLITE_NULL, expiry.timeIntervalSince1970.isFinite,
                      expiry <= decoded.stagedAt.addingTimeInterval(artifactRetention), status == "staged" else {
                    throw ScreenEvidenceAdmissionError.integrityFailure
                }
                retainUntil = expiry
            } else if status == "staged" || size != 0 { throw ScreenEvidenceAdmissionError.integrityFailure }
            return Record(claim: claim, status: status, deadlineUptime: deadline, receipt: receipt,
                          artifactBytes: size, retainUntil: retainUntil)
        }
        guard result.count <= maximumRecords else { throw ScreenEvidenceAdmissionError.integrityFailure }
        return result
    }

    private static func requireRecord(_ db: OpaquePointer, claim: ScreenEvidenceDerivationClaim) throws -> Record {
        let rows = try records(db, "WHERE attemptID=?", [.text(claim.attemptID.uuidString)])
        guard let row = rows.first, rows.count == 1, try identical(row.claim, claim) else {
            throw ScreenEvidenceAdmissionError.invalidClaim
        }
        return row
    }

    private static func validateCurrent(_ db: OpaquePointer, row: Record, state: State, now: Date) throws -> Date {
        if row.status == "cancelled" { throw ScreenEvidenceAdmissionError.claimCancelled }
        if row.status == "invalidated" { throw ScreenEvidenceAdmissionError.sourceChanged }
        let expiry = try requireConsumer(db, row.claim.request.cursor, feed: state.feed, now: now)
        let input = try loadInput(db, request: row.claim.request, state: state, retainedClaim: row.claim)
        guard input.hash == row.claim.inputSHA256, input.bytes == row.claim.inputUTF8Bytes,
              input.fragments == row.claim.fragmentCount, input.nextCursor == row.claim.nextCursor else {
            throw ScreenEvidenceAdmissionError.sourceChanged
        }
        return expiry
    }

    private static func retainedReceipt(_ row: Record, now: Date) throws -> ScreenEvidenceArtifactReceipt {
        guard row.status == "staged", let receipt = row.receipt, let expiry = row.retainUntil,
              receipt.stagedAt <= now, expiry > now else { throw ScreenEvidenceAdmissionError.artifactUnavailable }
        return receipt
    }

    private static func artifactData(_ db: OpaquePointer, claimID: UUID, receipt: ScreenEvidenceArtifactReceipt) throws -> Data {
        let blobs = try PipelineSQL.query(db, """
            SELECT artifact FROM screen_evidence_derivation WHERE attemptID=? AND artifactBytes BETWEEN 1 AND ?
            """, [.text(claimID.uuidString), .integer(Int64(maximumArtifactBytes))]) { statement -> Data in
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count == receipt.artifactBytes, count <= maximumArtifactBytes,
                  let bytes = sqlite3_column_blob(statement, 0) else { throw ScreenEvidenceAdmissionError.integrityFailure }
            return Data(bytes: bytes, count: count)
        }
        guard let data = blobs.first, blobs.count == 1, sha256(data) == receipt.artifactSHA256 else {
            throw ScreenEvidenceAdmissionError.integrityFailure
        }
        return data
    }

    private static func live(_ row: Record, state: State, cursor: ScreenEvidenceConsumerCursor,
                             input: Input, now: Date, uptime: TimeInterval) -> Bool {
        row.status == "claimed" && row.claim.policy == state.transition && row.claim.request.cursor == cursor
            && row.claim.metadataEpoch == state.metadataEpoch && row.claim.sourceSequence == input.sequence
            && withinDeadline(row, now: now, uptime: uptime)
    }

    private static func withinDeadline(_ row: Record, now: Date, uptime: TimeInterval) -> Bool {
        withinDeadline(row.claim, deadlineUptime: row.deadlineUptime, now: now, uptime: uptime)
    }

    private static func withinDeadline(_ claim: ScreenEvidenceDerivationClaim, deadlineUptime: TimeInterval,
                                       now: Date, uptime: TimeInterval) -> Bool {
        let duration = claim.deadline.timeIntervalSince(claim.issuedAt)
        return now >= claim.issuedAt && now < claim.deadline && uptime < deadlineUptime
            && uptime >= deadlineUptime - duration && duration > 0 && duration <= 30
    }

    private static func validateExecution(_ claim: ScreenEvidenceDerivationClaim, deadlineUptime: TimeInterval,
                                          consumerExpiry: Date, clock: ScreenEvidenceAdmissionClock) throws
        -> ScreenEvidenceAdmissionClock.Instant {
        let current = try checkedInstant(clock)
        try validateConsumerExpiry(consumerExpiry, at: current.date)
        guard withinDeadline(claim, deadlineUptime: deadlineUptime, now: current.date, uptime: current.uptime) else {
            throw ScreenEvidenceAdmissionError.claimExpired
        }
        return current
    }

    private static func validateConsumerExpiry(_ expiry: Date, at date: Date) throws {
        guard expiry > date else { throw ScreenEvidenceAdmissionError.invalidConsumer }
    }

    private static func resolvedClock(now: Date?, uptime: TimeInterval?, override: ScreenEvidenceAdmissionClock?)
        -> ScreenEvidenceAdmissionClock {
        // Explicit values are for deterministic private SQLite tests. Production
        // leaves them nil and reads both platform clocks at each check.
        override ?? ScreenEvidenceAdmissionClock {
            .init(date: now ?? Date(), uptime: uptime ?? ProcessInfo.processInfo.systemUptime)
        }
    }

    private static func checkedInstant(_ clock: ScreenEvidenceAdmissionClock) throws -> ScreenEvidenceAdmissionClock.Instant {
        let current = clock.sample()
        try validateClock(current.date, uptime: current.uptime)
        return current
    }

    private static func invalidate(_ db: OpaquePointer, _ attemptID: UUID) throws {
        try PipelineSQL.execute(db, """
            UPDATE screen_evidence_derivation SET status='invalidated',artifact=NULL,artifactBytes=0,
              receiptPayload=NULL,retainUntil=NULL WHERE attemptID=?
            """, [.text(attemptID.uuidString)])
    }

    private static func staleSourceOrConsumer(_ db: OpaquePointer, row: Record, state: State, now: Date) throws -> Bool {
        do { _ = try requireConsumer(db, row.claim.request.cursor, feed: state.feed, now: now) }
        catch ScreenEvidenceAdmissionError.invalidConsumer { return true }
        let ref = row.claim.request.expansion.reference
        let rows = try PipelineSQL.query(db, """
            SELECT o.frameID,o.preferredRevision,COALESCE(s.latestSequence,0),COALESCE(s.deleted,0),f.id,
              f.redactionReason,m.frameID,w.leaseID,w.state,w.extractionRevision,w.sourceSequence
            FROM screen_observation o LEFT JOIN frame f ON f.id=o.nativeFrameID
            LEFT JOIN screen_evidence_source_state s ON s.storeID=o.storeID AND s.observationID=o.observationID
            LEFT JOIN frame_media_unavailable m ON m.frameID=f.id
            LEFT JOIN screen_evidence_work w ON w.storeID=o.storeID AND w.observationID=o.observationID AND w.consumerID=? AND w.channel=?
            WHERE o.storeID=? AND o.observationID=? AND o.source='native'
            """, [.text(row.claim.request.cursor.consumerID.uuidString), .text(row.claim.request.channel.rawValue),
                    .text(ref.storeID.uuidString), .text(ref.observationID.uuidString)]) { pointer -> Bool in
            sqlite3_column_int64(pointer, 0) == ref.frameID.value && sqlite3_column_int64(pointer, 1) == ref.extractionRevision
                && sqlite3_column_int64(pointer, 2) == row.claim.sourceSequence && sqlite3_column_int(pointer, 3) == 0
                && sqlite3_column_type(pointer, 4) != SQLITE_NULL && sqlite3_column_type(pointer, 5) == SQLITE_NULL
                && sqlite3_column_type(pointer, 6) == SQLITE_NULL
                && UUID(uuidString: RecallSQL.string(pointer, 7)) == row.claim.request.cursor.leaseID
                && RecallSQL.string(pointer, 8) == "blocked" && sqlite3_column_int64(pointer, 9) == ref.extractionRevision
                && sqlite3_column_int64(pointer, 10) == row.claim.sourceSequence
        }
        return rows.count != 1 || rows.first != true
    }

    private static func totals(_ db: OpaquePointer) throws -> (count: Int, bytes: Int) {
        let rows = try PipelineSQL.query(db, "SELECT COUNT(*),COALESCE(SUM(artifactBytes),0) FROM screen_evidence_derivation") {
            (Int(sqlite3_column_int64($0, 0)), Int(sqlite3_column_int64($0, 1)))
        }
        guard let value = rows.first, rows.count == 1, (0...maximumRecords).contains(value.0),
              (0...maximumTotalBytes).contains(value.1) else { throw ScreenEvidenceAdmissionError.integrityFailure }
        return value
    }

    private static func policyPayload(_ policy: ScreenEvidenceAccessPolicy) throws -> String {
        guard policy.formatVersion == 1, policy.excludedAppBundleIDs == policy.excludedAppBundleIDs.sorted(),
              Set(policy.excludedAppBundleIDs).count == policy.excludedAppBundleIDs.count else {
            throw ScreenEvidenceAdmissionError.invalidRequest
        }
        return try boundedJSON(policy)
    }

    private static func validateRequest(_ request: ScreenEvidenceDerivationRequest) throws {
        guard request.executionDuration.isFinite, request.executionDuration > 0, request.executionDuration <= 30,
              !request.transformation.identifier.isEmpty, request.transformation.identifier.utf8.count <= 256,
              !request.transformation.artifactFormat.isEmpty, request.transformation.artifactFormat.utf8.count <= 128,
              validSHA(request.transformation.fingerprintSHA256) else { throw ScreenEvidenceAdmissionError.invalidRequest }
        do { try request.expansion.validate() }
        catch { throw ScreenEvidenceAdmissionError.invalidRequest }
        _ = try boundedJSON(request)
    }

    private static func validateClock(_ date: Date, uptime: TimeInterval? = nil) throws {
        guard date.timeIntervalSince1970.isFinite,
              uptime.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw ScreenEvidenceAdmissionError.invalidRequest }
    }

    private static func boundedJSON<T: Encodable>(_ value: T) throws -> String {
        let payload = try RecallSQL.encode(value)
        guard payload.utf8.count <= maximumJSONBytes else { throw ScreenEvidenceAdmissionError.invalidRequest }
        return payload
    }

    private static func identical<T: Encodable>(_ lhs: T, _ rhs: T) throws -> Bool {
        try boundedJSON(lhs).utf8.elementsEqual(boundedJSON(rhs).utf8)
    }

    private static func validSHA(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func optionalString(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(row, column) == SQLITE_NULL ? nil : RecallSQL.string(row, column)
    }

    private static func tokenValues(_ token: ScreenEvidencePolicyTransition) -> [PipelineSQL.Value] {
        [.text(token.session.feedID.uuidString), .text(token.session.storeID.uuidString), .text(token.session.writerID.uuidString),
         .integer(token.policyEpoch), .text(token.policySHA256)]
    }
}
