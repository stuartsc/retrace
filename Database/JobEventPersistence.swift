import CryptoKit
import Foundation
import Shared
import SQLCipher

extension DatabaseManager: JobEventStoreProtocol {
    public func openJobWriter(admission: JobAdmission) async throws -> JobWriterSession {
        try Task.checkCancellation()
        let db = try requireJobConnection()
        let proposed = JobWriterSession(id: UUID(), admission: admission)
        let result = try PipelineSQL.transaction(db) {
            try JobSQL.requireActive(db, capability: screenEvidenceAdmissionCapability, admission: admission)
            if let existing = jobEventWriter {
                guard existing.admission == admission else { throw JobEventError.inactive }
                return existing
            }
            // A previous incarnation's pending starts cannot become successes.
            // At most eight are possible through the admitted writer. A recovery
            // gap is observed now by this new session, with no invented exit time.
            try JobSQL.interruptPending(db, owner: nil, observer: proposed.id, reason: .producerRestarted)
            try Task.checkCancellation()
            return proposed
        }
        jobEventWriter = result
        return result
    }

    public func appendJobStart(_ event: JobObservation, session: JobWriterSession) async throws -> JobBeginReceipt {
        try Task.checkCancellation()
        guard jobEventWriter == session else { throw JobEventError.inactive }
        let db = try requireJobConnection()
        return try PipelineSQL.transaction(db) {
            try JobSQL.requireActive(db, capability: screenEvidenceAdmissionCapability, admission: session.admission)
            try JobSQL.validateIncoming(event)
            guard event.phase == .started else { throw JobEventError.invalidRequest }
            try JobSQL.requireNotDeleted(db, event: event)
            if let run = try JobSQL.run(db, event.runID) {
                guard run.ownerID == session.id, run.admission == session.admission, run.startEventID == event.id,
                      let existing = try JobSQL.event(db, event.id), existing.observation == event else { throw JobEventError.conflict }
                return .init(event: existing, inserted: false)
            }
            guard try JobSQL.event(db, event.id) == nil else { throw JobEventError.conflict }
            let pending = try PipelineSQL.integers(db, "SELECT 1 FROM job_run WHERE terminalEventID IS NULL LIMIT 8")
            guard pending.count < JobProducer.maximumOutstanding else { throw JobEventError.capacityExceeded }
            let admission = try JobSQL.encode(session.admission)
            try PipelineSQL.execute(db, """
                INSERT INTO job_run(runID,storeID,producerID,ownerID,admissionPayload,policySHA256,kind,startEventID)
                VALUES(?,?,?,?,?,?,?,?)
                """, [.text(event.runID.uuidString), .text(session.admission.policy.session.storeID.uuidString),
                        .text(session.producerID.uuidString), .text(session.id.uuidString), .text(admission),
                        .text(session.admission.policy.policySHA256), .text(event.kind.rawValue), .text(event.id.uuidString)])
            let result = try JobSQL.insert(db, event: event, observer: session.id, policyHash: session.admission.policy.policySHA256)
            try Task.checkCancellation()
            return .init(event: result, inserted: true)
        }
    }

    public func appendJobEnd(_ event: JobObservation, session: JobWriterSession) async throws -> JobEventSnapshot {
        // Gaps are cleanup receipts and may drain after policy revocation or
        // caller cancellation, but only for this exact live job writer/run.
        if event.phase != .gap { try Task.checkCancellation() }
        guard jobEventWriter == session else { throw JobEventError.inactive }
        let db = try requireJobConnection()
        return try PipelineSQL.transaction(db) {
            try JobSQL.validateIncoming(event)
            guard event.phase == .terminal || event.phase == .gap else { throw JobEventError.invalidRequest }
            if event.phase == .terminal {
                try JobSQL.requireActive(db, capability: screenEvidenceAdmissionCapability, admission: session.admission)
            }
            try JobSQL.requireNotDeleted(db, event: event)
            guard let run = try JobSQL.run(db, event.runID), run.ownerID == session.id,
                  run.admission == session.admission, run.kind == event.kind,
                  let start = try JobSQL.event(db, run.startEventID), start.observerSessionID == session.id,
                  event.observedUptime >= start.observation.observedUptime else { throw JobEventError.conflict }
            if let terminalID = run.terminalEventID {
                guard terminalID == event.id, let existing = try JobSQL.event(db, terminalID),
                      existing.observation == event else { throw JobEventError.conflict }
                return existing
            }
            let result = try JobSQL.finish(db, run: run, event: event, observer: session.id)
            if event.phase != .gap { try Task.checkCancellation() }
            return result
        }
    }

    public func closeJobWriter(_ session: JobWriterSession, reason: JobGapReason) async throws {
        guard jobEventWriter == session else { return }
        // Retire capability even if SQLite is unavailable or COMMIT fails. A new
        // owner will recover the still-durable pending rows as interrupted.
        jobEventWriter = nil
        let db = try requireJobConnection()
        try PipelineSQL.transaction(db) {
            try JobSQL.interruptPending(db, owner: session.id, observer: session.id, reason: reason)
        }
    }

    public func resolveJobEvidence(_ reference: JobEvidenceRef) async throws -> JobEvidenceResolution {
        try Task.checkCancellation()
        let db = try requireJobConnection()
        return try PipelineSQL.transaction(db) {
            let stamp: JobReadStamp
            do { stamp = try JobSQL.readStamp(db) }
            catch JobEventError.inactive { return .unavailable(.notPermitted) }
            catch { return .unavailable(.integrityFailure) }
            guard reference.storeID == stamp.storeID, reference.producerID == JobProducer.ownedCommand,
                  reference.revision == 1 else { return .unavailable(.unsupportedReference) }
            if try JobSQL.deletedEvent(db, reference.eventID) { return .unavailable(.deleted) }
            do {
                guard let event = try JobSQL.event(db, reference.eventID) else { return .unavailable(.missing) }
                guard event.reference == reference else { return .unavailable(.integrityFailure) }
                guard event.policySHA256 == stamp.policy.policySHA256 else { return .unavailable(.notPermitted) }
                return .available(event, stamp)
            } catch { return .unavailable(.integrityFailure) }
        }
    }

    public func jobChronology(_ query: JobChronologyQuery, after cursor: JobEventCursor?) async throws -> JobEventPage {
        try Task.checkCancellation()
        try JobSQL.validateQuery(query)
        let db = try requireJobConnection()
        return try PipelineSQL.transaction(db) {
            let stamp = try JobSQL.readStamp(db)
            if let cursor {
                guard cursor.query == query, cursor.lastSequence > 0,
                      cursor.lastObservedAt.timeIntervalSince1970.isFinite else { throw JobEventError.invalidRequest }
                guard cursor.stamp == stamp else { throw JobEventError.staleRead }
                // Cursors are not disclosure authority; prove the exact key is
                // still a retained member of this query before continuing.
                guard let anchor = try JobSQL.eventAtSequence(db, cursor.lastSequence),
                      anchor.observation.observedAt.timeIntervalSince1970 == cursor.lastObservedAt.timeIntervalSince1970,
                      anchor.policySHA256 == stamp.policy.policySHA256, JobSQL.matches(anchor, query) else { throw JobEventError.invalidRequest }
            }
            var sql = JobSQL.select + " WHERE e.policySHA256=?"
            var values: [PipelineSQL.Value] = [.text(stamp.policy.policySHA256)]
            if let from = query.from { sql += " AND e.observedAt>=?"; values.append(.real(from.timeIntervalSince1970)) }
            if let through = query.through { sql += " AND e.observedAt<=?"; values.append(.real(through.timeIntervalSince1970)) }
            if let kind = query.kind { sql += " AND e.kind=?"; values.append(.text(kind.rawValue)) }
            if let outcome = query.outcome { sql += " AND e.outcome=?"; values.append(.text(outcome.rawValue)) }
            if let cursor {
                sql += " AND (e.observedAt<? OR (e.observedAt=? AND e.sequence<?))"
                values += [.real(cursor.lastObservedAt.timeIntervalSince1970), .real(cursor.lastObservedAt.timeIntervalSince1970), .integer(cursor.lastSequence)]
            }
            sql += " ORDER BY e.observedAt DESC,e.sequence DESC LIMIT ?"
            values.append(.integer(Int64(query.limit + 1)))
            let rows = try PipelineSQL.query(db, sql, values, map: JobSQL.row)
            let page = Array(rows.prefix(query.limit))
            let next = rows.count > query.limit ? page.last.map {
                JobEventCursor(stamp: stamp, query: query, lastObservedAt: $0.observation.observedAt, lastSequence: $0.sequence)
            } : nil
            try Task.checkCancellation()
            return .init(events: page, stamp: stamp, next: next)
        }
    }

    public func validateJobRead(_ stamp: JobReadStamp) async throws -> Bool {
        try Task.checkCancellation()
        let db = try requireJobConnection()
        return try PipelineSQL.transaction(db) {
            do { return try JobSQL.readStamp(db) == stamp }
            catch JobEventError.inactive { return false }
        }
    }

    public func deleteJobRun(_ runID: UUID, storeID: UUID) async throws {
        try Task.checkCancellation()
        let db = try requireJobConnection()
        try PipelineSQL.transaction(db) {
            guard try RecallSQL.nativeStore(db) == storeID else { throw JobEventError.invalidRequest }
            try PipelineSQL.execute(db, "DELETE FROM job_run WHERE runID=? AND storeID=?", [.text(runID.uuidString), .text(storeID.uuidString)])
            if sqlite3_changes(db) > 0 { try JobSQL.metric(db, ["operation": "deleted"]) }
        }
    }

    public func recordJobDiagnostic(_ diagnostic: JobDiagnostic) async throws {
        let db = try requireJobConnection()
        try JobSQL.metric(db, ["operation": diagnostic.rawValue])
    }

    private func requireJobConnection() throws -> OpaquePointer {
        guard !screenEvidenceAdmissionClosing, isReady(), let db = getConnection() else { throw JobEventError.unavailable }
        return db
    }
}

enum JobSQL {
    struct Run {
        let id: UUID
        let ownerID: UUID
        let admission: JobAdmission
        let kind: JobKind
        let startEventID: UUID
        let terminalEventID: UUID?
    }
    static let select = """
        SELECT e.sequence,e.eventID,e.runID,e.observerID,e.phase,e.kind,e.outcome,e.observedAt,e.observedUptime,
               e.receivedAt,e.payload,e.payloadSHA256,r.storeID,r.producerID,r.policySHA256,r.startEventID,
               r.terminalEventID,r.admissionPayload,e.policySHA256
        FROM job_event e JOIN job_run r ON r.runID=e.runID
        """
    static func requireActive(_ db: OpaquePointer, capability: ScreenEvidenceAdmissionCapability, admission: JobAdmission) throws {
        do {
            _ = try ScreenEvidenceAdmissionSQL.requireActive(db, capability: capability, expected: admission.policy)
            guard try RecallSQL.nativeStore(db) == admission.policy.session.storeID else { throw JobEventError.inactive }
        } catch { throw JobEventError.inactive }
    }
    static func readStamp(_ db: OpaquePointer) throws -> JobReadStamp {
        let state: ScreenEvidenceAdmissionSQL.State
        do { state = try ScreenEvidenceAdmissionSQL.retainedStateForLocalRead(db) }
        catch ScreenEvidenceAdmissionError.inactive { throw JobEventError.inactive }
        catch { throw JobEventError.integrityFailure }
        let store = try RecallSQL.nativeStore(db)
        guard let policy = state.transition, policy.session.storeID == store,
              let phase = JobRetainedPolicyPhase(rawValue: state.phase),
              let revision = try PipelineSQL.integers(db, "SELECT revision FROM job_state WHERE id=1").first,
              revision >= 0, revision < Int64.max else { throw JobEventError.integrityFailure }
        return .init(storeID: store, policy: policy, policyPhase: phase, revision: revision)
    }
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let value = try RecallSQL.encode(value)
        guard value.utf8.count <= 8192 else { throw JobEventError.invalidRequest }
        return value
    }
    static func hash(_ payload: String) -> String { SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func validateIncoming(_ event: JobObservation) throws {
        try event.validate(receivedAt: Date(), maximumUptime: ProcessInfo.processInfo.systemUptime)
        _ = try encode(event)
    }
    static func requireNotDeleted(_ db: OpaquePointer, event: JobObservation) throws {
        let found = try PipelineSQL.integers(db,
            "SELECT 1 FROM job_deleted WHERE runID=? OR startEventID=? OR terminalEventID=? LIMIT 1",
            [.text(event.runID.uuidString), .text(event.id.uuidString), .text(event.id.uuidString)])
        guard found.isEmpty else { throw JobEventError.deleted }
    }
    static func deletedEvent(_ db: OpaquePointer, _ id: UUID) throws -> Bool {
        try !PipelineSQL.integers(db, "SELECT 1 FROM job_deleted WHERE startEventID=? OR terminalEventID=? LIMIT 1",
            [.text(id.uuidString), .text(id.uuidString)]).isEmpty
    }
    static func run(_ db: OpaquePointer, _ id: UUID) throws -> Run? {
        try PipelineSQL.query(db, "SELECT ownerID,admissionPayload,kind,startEventID,terminalEventID FROM job_run WHERE runID=?", [.text(id.uuidString)]) { row in
            guard let owner = UUID(uuidString: RecallSQL.string(row, 0)), let kind = JobKind(rawValue: RecallSQL.string(row, 2)),
                  let start = UUID(uuidString: RecallSQL.string(row, 3)) else { throw JobEventError.integrityFailure }
            let payload = RecallSQL.string(row, 1)
            guard payload.utf8.count <= 8192 else { throw JobEventError.integrityFailure }
            let admission = try RecallSQL.decode(JobAdmission.self, payload)
            let terminalString = RecallSQL.string(row, 4), terminal = UUID(uuidString: terminalString)
            guard terminalString.isEmpty || terminal != nil else { throw JobEventError.integrityFailure }
            return Run(id: id, ownerID: owner, admission: admission, kind: kind, startEventID: start, terminalEventID: terminal)
        }.first
    }
    static func event(_ db: OpaquePointer, _ id: UUID) throws -> JobEventSnapshot? {
        try PipelineSQL.query(db, select + " WHERE e.eventID=?", [.text(id.uuidString)], map: row).first
    }
    static func eventAtSequence(_ db: OpaquePointer, _ sequence: Int64) throws -> JobEventSnapshot? {
        try PipelineSQL.query(db, select + " WHERE e.sequence=?", [.integer(sequence)], map: row).first
    }
    static func row(_ row: OpaquePointer) throws -> JobEventSnapshot {
        let payload = RecallSQL.string(row, 10), policy = RecallSQL.string(row, 14), admissionPayload = RecallSQL.string(row, 17)
        guard payload.utf8.count <= 8192, admissionPayload.utf8.count <= 8192,
              hash(payload) == RecallSQL.string(row, 11),
              let id = UUID(uuidString: RecallSQL.string(row, 1)), let runID = UUID(uuidString: RecallSQL.string(row, 2)),
              let observer = UUID(uuidString: RecallSQL.string(row, 3)), let store = UUID(uuidString: RecallSQL.string(row, 12)),
              UUID(uuidString: RecallSQL.string(row, 13)) == JobProducer.ownedCommand,
              policy.count == 64, policy.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              policy == RecallSQL.string(row, 18), sqlite3_column_int64(row, 0) > 0 else { throw JobEventError.integrityFailure }
        let event = try RecallSQL.decode(JobObservation.self, payload)
        let admission = try RecallSQL.decode(JobAdmission.self, admissionPayload)
        let received = Date(timeIntervalSince1970: sqlite3_column_double(row, 9))
        try event.validate(receivedAt: received)
        guard event.id == id, event.runID == runID, event.phase.rawValue == RecallSQL.string(row, 4),
              event.kind.rawValue == RecallSQL.string(row, 5), (event.outcome?.rawValue ?? "") == RecallSQL.string(row, 6),
              event.observedAt.timeIntervalSince1970 == sqlite3_column_double(row, 7),
              event.observedUptime == sqlite3_column_double(row, 8), admission.policy.policySHA256 == policy,
              admission.policy.session.storeID == store,
              id.uuidString == RecallSQL.string(row, event.phase == .started ? 15 : 16) else { throw JobEventError.integrityFailure }
        return .init(reference: .init(storeID: store, producerID: JobProducer.ownedCommand, eventID: id),
            observation: event, observerSessionID: observer, receivedAt: received, sequence: sqlite3_column_int64(row, 0), policySHA256: policy)
    }
    static func insert(_ db: OpaquePointer, event: JobObservation, observer: UUID, policyHash: String) throws -> JobEventSnapshot {
        let payload = try encode(event), received = Date()
        try event.validate(receivedAt: received)
        try PipelineSQL.execute(db, """
            INSERT INTO job_event(eventID,runID,observerID,phase,kind,outcome,observedAt,observedUptime,receivedAt,policySHA256,payload,payloadSHA256)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(event.id.uuidString), .text(event.runID.uuidString), .text(observer.uuidString), .text(event.phase.rawValue),
                    .text(event.kind.rawValue), .text(event.outcome?.rawValue ?? ""), .real(event.observedAt.timeIntervalSince1970),
                    .real(event.observedUptime), .real(received.timeIntervalSince1970), .text(policyHash), .text(payload), .text(hash(payload))])
        try metric(db, ["operation": event.phase.rawValue, "kind": event.kind.rawValue, "outcome": event.outcome?.rawValue ?? "none"])
        guard let snapshot = try self.event(db, event.id) else { throw JobEventError.integrityFailure }
        return snapshot
    }
    static func finish(_ db: OpaquePointer, run: Run, event: JobObservation, observer: UUID) throws -> JobEventSnapshot {
        guard run.terminalEventID == nil, run.kind == event.kind, event.runID == run.id,
              try self.event(db, event.id) == nil else { throw JobEventError.conflict }
        try requireNotDeleted(db, event: event)
        try PipelineSQL.execute(db, "UPDATE job_run SET terminalEventID=? WHERE runID=? AND terminalEventID IS NULL",
            [.text(event.id.uuidString), .text(run.id.uuidString)])
        guard sqlite3_changes(db) == 1 else { throw JobEventError.conflict }
        return try insert(db, event: event, observer: observer, policyHash: run.admission.policy.policySHA256)
    }
    static func interruptPending(_ db: OpaquePointer, owner: UUID?, observer: UUID, reason: JobGapReason) throws {
        var sql = "SELECT runID FROM job_run WHERE terminalEventID IS NULL", values: [PipelineSQL.Value] = []
        if let owner { sql += " AND ownerID=?"; values.append(.text(owner.uuidString)) }
        let ids = try PipelineSQL.query(db, sql + " LIMIT 9", values) { RecallSQL.string($0, 0) }
        guard ids.count <= JobProducer.maximumOutstanding else { throw JobEventError.integrityFailure }
        for string in ids {
            guard let id = UUID(uuidString: string), let run = try run(db, id),
                  try event(db, run.startEventID) != nil else { throw JobEventError.integrityFailure }
            let gap = JobObservation(runID: id, kind: run.kind, phase: .gap, outcome: .interrupted, gapReason: reason)
            _ = try finish(db, run: run, event: gap, observer: observer)
        }
    }
    static func validateQuery(_ query: JobChronologyQuery) throws {
        guard (1...200).contains(query.limit) else { throw JobEventError.invalidRequest }
        for date in [query.from, query.through].compactMap({ $0 }) {
            guard date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0 else { throw JobEventError.invalidRequest }
        }
        if let from = query.from, let through = query.through, from > through { throw JobEventError.invalidRequest }
    }
    static func matches(_ event: JobEventSnapshot, _ query: JobChronologyQuery) -> Bool {
        (query.from == nil || event.observation.observedAt >= query.from!) &&
        (query.through == nil || event.observation.observedAt <= query.through!) &&
        (query.kind == nil || event.observation.kind == query.kind) &&
        (query.outcome == nil || event.observation.outcome == query.outcome)
    }
    static func metric(_ db: OpaquePointer, _ metadata: [String: String]) throws {
        try DailyMetricsQueries.recordEvent(db: db, metricType: .jobEvent, metadata: try encode(metadata))
    }
}
