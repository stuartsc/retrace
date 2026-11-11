import Foundation
import Shared
import SQLCipher
import XCTest
@testable import Database

/// Private real SQLite, canonical live V23 admission and immutable job receipts.
/// No native process, user database, model, or application preferences are read.
final class JobEventPersistenceTests: XCTestCase {
    private var database: DatabaseManager!
    private var admission: JobAdmission!
    private var writer: JobWriterSession!

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:job-events-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let policy = try await database.beginScreenEvidenceWriterSession(policy: .init(config: CaptureConfig()))
        try await database.activateScreenEvidencePolicy(policy)
        admission = .init(masterGeneration: UUID(), policy: policy)
        writer = try await database.openJobWriter(admission: admission)
    }

    override func tearDown() async throws {
        if let writer { try? await database.closeJobWriter(writer, reason: .serviceStopped) }
        if let database { try await database.close() }
    }

    func testCanonicalStartTerminalResolutionAndFilteredChronology() async throws {
        let start = observation(kind: .build)
        let first = try await database.appendJobStart(start, session: writer)
        let terminal = end(start, outcome: .failed, status: 2)
        let finished = try await database.appendJobEnd(terminal, session: writer)
        XCTAssertTrue(first.inserted)
        XCTAssertEqual(finished.observation.terminationStatus, 2)
        XCTAssertGreaterThan(finished.sequence, first.event.sequence)
        let resolved = try await database.resolveJobEvidence(finished.reference)
        guard case .available(let exact, let stamp) = resolved else { return XCTFail("Exact committed terminal unavailable") }
        XCTAssertEqual(exact, finished)
        let valid = try await database.validateJobRead(stamp)
        XCTAssertTrue(valid)
        let page = try await database.jobChronology(.init(kind: .build, outcome: .failed), after: nil)
        XCTAssertEqual(page.events.map(\.reference), [finished.reference])
        let noMatch = try await database.jobChronology(.init(kind: .test), after: nil)
        XCTAssertTrue(noMatch.events.isEmpty)
    }

    func testIdenticalReplayIsIdempotentAndConflictingUUIDIsRejected() async throws {
        let start = observation()
        let a = try await database.appendJobStart(start, session: writer)
        let b = try await database.appendJobStart(start, session: writer)
        XCTAssertFalse(b.inserted)
        XCTAssertEqual(a.event, b.event)
        let terminal = end(start, outcome: .succeeded, status: 0)
        let first = try await database.appendJobEnd(terminal, session: writer)
        let retry = try await database.appendJobEnd(terminal, session: writer)
        XCTAssertEqual(first, retry)
        let conflict = JobObservation(id: terminal.id, runID: start.runID, kind: .command, phase: .terminal,
            outcome: .failed, terminationStatus: 1, observedAt: terminal.observedAt, observedUptime: terminal.observedUptime)
        await fails(.conflict) { try await self.database.appendJobEnd(conflict, session: self.writer) }
        let raw = await database.getConnection()
        let metricCount = try PipelineSQL.integers(XCTUnwrap(raw), "SELECT count(*) FROM daily_metrics WHERE metricType='job_event'").first
        XCTAssertEqual(metricCount, 2, "ACK retry must not duplicate action metrics")
    }

    func testDeletionTombstonesAllExactReferencesAndDeniesReplay() async throws {
        let start = observation()
        let first = try await database.appendJobStart(start, session: writer)
        let terminal = end(start, outcome: .succeeded, status: 0)
        let last = try await database.appendJobEnd(terminal, session: writer)
        let before = try await database.jobChronology(.init(), after: nil)
        try await database.deleteJobRun(start.runID, storeID: first.event.reference.storeID)
        for ref in [first.event.reference, last.reference] {
            let result = try await database.resolveJobEvidence(ref)
            XCTAssertEqual(result, .unavailable(.deleted))
        }
        let stillValid = try await database.validateJobRead(before.stamp)
        XCTAssertFalse(stillValid)
        await fails(.deleted) { try await self.database.appendJobStart(start, session: self.writer) }
        await fails(.deleted) { try await self.database.appendJobEnd(terminal, session: self.writer) }
        let raw = await database.getConnection()
        XCTAssertEqual(try PipelineSQL.integers(XCTUnwrap(raw), "SELECT count(*) FROM job_event").first, 0)
    }

    func testPolicyRevocationDeniesSuccessButAllowsExactContentFreeInterruption() async throws {
        let start = observation()
        _ = try await database.appendJobStart(start, session: writer)
        try await database.revokeScreenEvidencePolicy(admission.policy)
        await fails(.inactive) { try await self.database.appendJobEnd(self.end(start, outcome: .succeeded, status: 0), session: self.writer) }
        let gap = JobObservation(runID: start.runID, kind: start.kind, phase: .gap, outcome: .interrupted,
            gapReason: .admissionChanged)
        let recorded = try await database.appendJobEnd(gap, session: writer)
        XCTAssertEqual(recorded.observation.phase, .gap)
        let retained = try await database.resolveJobEvidence(recorded.reference)
        guard case .available(_, let retainedStamp) = retained else { return XCTFail("Paused local history must remain readable") }
        XCTAssertEqual(retainedStamp.policyPhase, .revoked)
        try await database.closeJobWriter(writer, reason: .serviceStopped)
        let transition = try await database.prepareScreenEvidencePolicy(session: admission.policy.session,
            policy: .init(config: CaptureConfig(excludedAppBundleIDs: ["com.authored.excluded"])))
        try await database.activateScreenEvidencePolicy(transition)
        let hidden = try await database.jobChronology(.init(), after: nil)
        XCTAssertTrue(hidden.events.isEmpty, "Filter policy before page limits")
    }

    func testForgedOrClosedWriterCannotUseDurableActivePolicy() async throws {
        let forged = JobWriterSession(id: UUID(), admission: admission)
        await fails(.inactive) { try await self.database.appendJobStart(self.observation(), session: forged) }
        try await database.closeJobWriter(writer, reason: .serviceStopped)
        await fails(.inactive) { try await self.database.appendJobStart(self.observation(), session: self.writer) }
        let next = try await database.openJobWriter(admission: admission)
        XCTAssertNotEqual(next.id, writer.id)
        try await database.closeJobWriter(writer, reason: .serviceStopped) // stale close cannot retire next
        _ = try await database.appendJobStart(observation(), session: next)
        try await database.closeJobWriter(next, reason: .serviceStopped)
    }

    func testPreparedPolicyAndAbsentLiveCapabilityFailClosed() async throws {
        try await database.closeJobWriter(writer, reason: .serviceStopped)
        let prepared = try await database.prepareScreenEvidencePolicy(session: admission.policy.session,
            policy: .init(config: CaptureConfig()))
        await fails(.inactive) { try await self.database.openJobWriter(admission: .init(masterGeneration: UUID(), policy: prepared)) }
        try await database.activateScreenEvidencePolicy(prepared)
        try await database.endScreenEvidenceWriterSession(prepared.session)
        await fails(.inactive) { try await self.database.openJobWriter(admission: .init(masterGeneration: UUID(), policy: prepared)) }
    }

    func testPausedHistoryReadsDoNotRestoreWriterAuthority() async throws {
        let start = observation()
        _ = try await database.appendJobStart(start, session: writer)
        let terminal = try await database.appendJobEnd(end(start, outcome: .succeeded, status: 0), session: writer)
        let activePage = try await database.jobChronology(.init(), after: nil)
        try await database.closeJobWriter(writer, reason: .recordingPaused)
        try await database.endScreenEvidenceWriterSession(admission.policy.session)
        guard case .available(let exact, let pausedStamp) = try await database.resolveJobEvidence(terminal.reference) else {
            return XCTFail("Inspecting retained history incorrectly required restarting recording")
        }
        XCTAssertEqual(exact, terminal)
        XCTAssertEqual(pausedStamp.policyPhase, .revoked)
        let oldStampValid = try await database.validateJobRead(activePage.stamp)
        XCTAssertFalse(oldStampValid)
        let page = try await database.jobChronology(.init(), after: nil)
        XCTAssertEqual(page.events.count, 2)
        await fails(.inactive) { try await self.database.openJobWriter(admission: self.admission) }
        await fails(.inactive) { try await self.database.appendJobStart(self.observation(), session: self.writer) }
    }

    func testPreparedOrCorruptRetainedReadPolicyCannotDiscloseJobHistory() async throws {
        let start = try await database.appendJobStart(observation(), session: writer)
        let pending = try await database.prepareScreenEvidencePolicy(session: admission.policy.session,
            policy: .init(config: CaptureConfig()))
        let prepared = try await database.resolveJobEvidence(start.event.reference)
        XCTAssertEqual(prepared, .unavailable(.notPermitted))
        await fails(.inactive) { try await self.database.jobChronology(.init(), after: nil) }
        try await database.activateScreenEvidencePolicy(pending)
        let raw = await database.getConnection(), db = try XCTUnwrap(raw)
        try PipelineSQL.execute(db, "UPDATE screen_evidence_admission_state SET policyPayload='{}' WHERE id=1")
        let corrupt = try await database.resolveJobEvidence(start.event.reference)
        XCTAssertEqual(corrupt, .unavailable(.integrityFailure))
    }

    func testBoundedOutstandingRunsAndJoinedCloseProduceOnlyGapReceipts() async throws {
        for _ in 0..<8 { _ = try await database.appendJobStart(observation(), session: writer) }
        await fails(.capacityExceeded) { try await self.database.appendJobStart(self.observation(), session: self.writer) }
        try await database.closeJobWriter(writer, reason: .recordingPaused)
        let page = try await database.jobChronology(.init(outcome: .interrupted), after: nil)
        XCTAssertEqual(page.events.count, 8)
        XCTAssertTrue(page.events.allSatisfy { $0.observation.gapReason == .recordingPaused && $0.observation.terminationStatus == nil })
        writer = try await database.openJobWriter(admission: admission)
        _ = try await database.appendJobStart(observation(), session: writer)
    }

    func testExactStoreProducerAndRevisionCannotAlias() async throws {
        let receipt = try await database.appendJobStart(observation(), session: writer)
        let ref = receipt.event.reference
        for other in [JobEvidenceRef(storeID: UUID(), producerID: ref.producerID, eventID: ref.eventID),
                      .init(storeID: ref.storeID, producerID: UUID(), eventID: ref.eventID),
                      .init(storeID: ref.storeID, producerID: ref.producerID, eventID: ref.eventID, revision: 2)] {
            let result = try await database.resolveJobEvidence(other)
            XCTAssertEqual(result, .unavailable(.unsupportedReference))
        }
    }

    func testKeysetCursorIsBoundToQueryAndRevision() async throws {
        for _ in 0..<4 {
            let start = observation(kind: .test)
            _ = try await database.appendJobStart(start, session: writer)
            _ = try await database.appendJobEnd(end(start, outcome: .succeeded, status: 0), session: writer)
        }
        let query = JobChronologyQuery(kind: .test, limit: 3)
        let first = try await database.jobChronology(query, after: nil)
        let cursor = try XCTUnwrap(first.next)
        let second = try await database.jobChronology(query, after: cursor)
        XCTAssertTrue(Set(first.events.map(\.reference)).isDisjoint(with: Set(second.events.map(\.reference))))
        await fails(.invalidRequest) { try await self.database.jobChronology(.init(kind: .build, limit: 3), after: cursor) }
        let extra = observation()
        _ = try await database.appendJobStart(extra, session: writer)
        await fails(.staleRead) { try await self.database.jobChronology(query, after: cursor) }
    }

    func testActualReceiptTimeBoundsAndCurrentPolicyApplyBeforePageLimit() async throws {
        let previous = observation(kind: .build)
        _ = try await database.appendJobStart(previous, session: writer)
        _ = try await database.appendJobEnd(end(previous, outcome: .failed, status: 2), session: writer)
        try await database.closeJobWriter(writer, reason: .serviceStopped)
        let policy = try await database.prepareScreenEvidencePolicy(session: admission.policy.session,
            policy: .init(config: CaptureConfig(excludedAppBundleIDs: ["com.authored.hidden"])))
        try await database.activateScreenEvidencePolicy(policy)
        admission = .init(masterGeneration: UUID(), policy: policy)
        writer = try await database.openJobWriter(admission: admission)
        // Current-policy evidence has an earlier observed wall time than excluded
        // rows. Filtering after LIMIT would incorrectly yield an empty result.
        let time = Date().addingTimeInterval(-60), uptime = max(0, ProcessInfo.processInfo.systemUptime - 60)
        let start = JobObservation(runID: UUID(), kind: .test, phase: .started, observedAt: time, observedUptime: uptime)
        let accepted = try await database.appendJobStart(start, session: writer)
        let current = try await database.jobChronology(.init(limit: 1), after: nil)
        XCTAssertEqual(current.events.map(\.reference), [accepted.event.reference])
        let excludedTime = try await database.jobChronology(.init(from: time.addingTimeInterval(1), kind: .test), after: nil)
        XCTAssertTrue(excludedTime.events.isEmpty)
        let bounded = try await database.jobChronology(.init(from: time.addingTimeInterval(-1), through: time, kind: .test), after: nil)
        XCTAssertEqual(bounded.events.map(\.reference), [accepted.event.reference])
    }

    func testMalformedTimesAndInconsistentNativeStatusesNeverPersist() async throws {
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let bad = [
            JobObservation(runID: UUID(), kind: .command, phase: .started, observedAt: now.addingTimeInterval(60), observedUptime: uptime),
            .init(runID: UUID(), kind: .command, phase: .started, observedAt: now, observedUptime: -.infinity),
            .init(runID: UUID(), kind: .command, phase: .started, outcome: .succeeded, terminationStatus: 0),
            .init(runID: UUID(), kind: .command, phase: .started, observedAt: Date(timeIntervalSince1970: .nan), observedUptime: uptime)
        ]
        for event in bad { await fails(.invalidRequest) { try await self.database.appendJobStart(event, session: self.writer) } }
        let start = observation()
        _ = try await database.appendJobStart(start, session: writer)
        await fails(.invalidRequest) { try await self.database.appendJobEnd(self.end(start, outcome: .succeeded, status: 1), session: self.writer) }
        await fails(.invalidRequest) { try await self.database.jobChronology(.init(limit: 201), after: nil) }
        let page = try await database.jobChronology(.init(), after: nil)
        XCTAssertEqual(page.events.count, 1)
    }

    func testCorruptPayloadCannotResolveAsValidEvidence() async throws {
        let start = try await database.appendJobStart(observation(), session: writer)
        let raw = await database.getConnection(), db = try XCTUnwrap(raw)
        try PipelineSQL.execute(db, "DROP TRIGGER job_event_immutable")
        try PipelineSQL.execute(db, "UPDATE job_event SET payload='{}' WHERE eventID=?", [.text(start.event.reference.eventID.uuidString)])
        let result = try await database.resolveJobEvidence(start.event.reference)
        XCTAssertEqual(result, .unavailable(.integrityFailure))
    }

    func testFailedCloseRetiresWriterAndNextOwnerRecoversPendingAsInterrupted() async throws {
        let start = observation(kind: .build)
        _ = try await database.appendJobStart(start, session: writer)
        let raw = await database.getConnection(), db = try XCTUnwrap(raw)
        try PipelineSQL.execute(db, """
            CREATE TRIGGER authored_close_failure BEFORE UPDATE OF terminalEventID ON job_run
            BEGIN SELECT RAISE(ABORT,'authored close failure'); END
            """)
        do { try await database.closeJobWriter(writer, reason: .serviceStopped); XCTFail("Expected real SQLite failure") } catch { }
        try PipelineSQL.execute(db, "DROP TRIGGER authored_close_failure")
        await fails(.inactive) { try await self.database.appendJobEnd(self.end(start, outcome: .succeeded, status: 0), session: self.writer) }
        let next = try await database.openJobWriter(admission: admission)
        let gaps = try await database.jobChronology(.init(outcome: .interrupted), after: nil)
        XCTAssertEqual(gaps.events.count, 1)
        XCTAssertEqual(gaps.events.first?.observation.gapReason, .producerRestarted)
        XCTAssertEqual(gaps.events.first?.observerSessionID, next.id)
        XCTAssertNil(gaps.events.first?.observation.terminationStatus)
        writer = next
    }

    func testIndependentPersistedReaderCannotRestoreWriterCapability() async throws {
        let receipt = try await database.appendJobStart(observation(), session: writer)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("job-capability-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("authored.sqlite").path
        // SQLCipher may omit shared-cache support. Persist the real admitted
        // database, close the backup connection, then open an independent reader.
        try await database.jobCapabilityFixtureBackup(to: path)
        var opened: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        let reader = try XCTUnwrap(opened)
        defer { sqlite3_close_v2(reader) }
        let retained = try JobSQL.readStamp(reader)
        XCTAssertEqual(retained.policy, admission.policy)
        XCTAssertEqual(retained.policyPhase, .active)
        XCTAssertEqual(try JobSQL.event(reader, receipt.event.reference.eventID), receipt.event,
                       "The independent reader must inspect the same persisted fact")
        XCTAssertThrowsError(try JobSQL.requireActive(reader, capability: .init(), admission: admission)) {
            XCTAssertEqual($0 as? JobEventError, .inactive,
                           "Retained active policy must not restore a live writer capability")
        }
    }

    private func observation(kind: JobKind = .command) -> JobObservation {
        .init(runID: UUID(), kind: kind, phase: .started)
    }
    private func end(_ start: JobObservation, outcome: JobOutcome, status: Int32) -> JobObservation {
        .init(runID: start.runID, kind: start.kind, phase: .terminal, outcome: outcome, terminationStatus: status)
    }
    private func fails<T>(_ expected: JobEventError, _ operation: () async throws -> T) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)") }
        catch let error as JobEventError { XCTAssertEqual(error, expected) }
        catch { XCTFail("Unexpected error type: \(type(of: error))") }
    }
}

private extension DatabaseManager {
    func jobCapabilityFixtureBackup(to path: String) throws {
        let source = try XCTUnwrap(getConnection())
        var destination: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        let target = try XCTUnwrap(destination)
        defer { sqlite3_close_v2(target) }
        let backup = try XCTUnwrap(sqlite3_backup_init(target, "main", source, "main"))
        XCTAssertEqual(sqlite3_backup_step(backup, -1), SQLITE_DONE)
        XCTAssertEqual(sqlite3_backup_finish(backup), SQLITE_OK)
    }
}
