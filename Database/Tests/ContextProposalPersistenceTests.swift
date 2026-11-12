import CryptoKit
import Foundation
import Shared
import SQLCipher
import XCTest
@testable import Database

final class ContextProposalPersistenceTests: XCTestCase {
    func testAtomicSupersessionPreservesPinnedProvenanceAndRetryCannotResurrectOldRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), path = root.appendingPathComponent("context.db").path
        let db = ContextDatabase(databasePath: path, nativeStoreID: native)
        try await db.initialize()
        let marker = try await db.createManualMarker(.init(anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let first = try command(marker: marker, expectedHead: nil, rangeIDs: [UUID(), UUID()])
        let receipt = try await db.applyContextProposal(first)
        let wireDecoder = JSONDecoder(); wireDecoder.dateDecodingStrategy = .millisecondsSince1970
        let originalResult = try wireDecoder.decode(CompanionResult.self, from: first.resultPayload)
        let originalProposal = try XCTUnwrap(originalResult.contextProposal)
        let changedResult = CompanionResult(jobID: first.jobID, sourceStoreID: native,
            contextProposal: .init(markerID: marker.id, markerRevision: marker.revision, snapshotID: originalProposal.snapshotID,
                verbatimExplanation: originalProposal.verbatimExplanation, developing: originalProposal.developing,
                incomplete: originalProposal.incomplete, ranges: originalProposal.ranges, method: "Different computation"))
        let wireEncoder = JSONEncoder(); wireEncoder.dateEncodingStrategy = .millisecondsSince1970
        do {
            _ = try await db.applyContextProposal(.init(jobID: first.jobID, proposalRevision: first.proposalRevision,
                expectedMarkerRevision: first.expectedMarkerRevision, expectedProposalHead: nil,
                requestPayload: first.requestPayload, resultPayload: wireEncoder.encode(changedResult)))
            XCTFail("One retained job cannot accept conflicting result bytes")
        } catch { XCTAssertEqual(error as? ContextStoreError, .requestConflict) }
        let initial = try await db.listContextRanges(markerID: marker.id, limit: 64)
        let inherited = try XCTUnwrap(initial.first)
        let pinned = try await db.saveContextRange(markerID: marker.id,
            range: .init(id: inherited.id, start: inherited.start, end: inherited.end, explanation: inherited.explanation,
                ownership: .pinned, userNote: "My separate note"), expectedRevision: inherited.revision, expectedMarkerRevision: marker.revision)
        XCTAssertEqual(pinned.provenance, inherited.provenance)
        XCTAssertEqual(pinned.effectiveExplanationOrigin, .companionDerived)
        let next = try command(marker: marker, expectedHead: receipt.head.revision, rangeIDs: [UUID()])
        let nextReceipt = try await db.applyContextProposal(next)
        let replaced = try await db.listContextRanges(markerID: marker.id, limit: 64)
        XCTAssertEqual(replaced.count, 2)
        XCTAssertTrue(replaced.contains(pinned))
        let empty = try command(marker: marker, expectedHead: nextReceipt.head.revision, rangeIDs: [])
        let last = try await db.applyContextProposal(empty)
        _ = try await db.applyContextProposal(first)
        let retained = try await db.listContextRanges(markerID: marker.id, limit: 64)
        XCTAssertEqual(retained, [pinned])
        let head = try await db.contextProposalHead(markerID: marker.id)
        XCTAssertEqual(head, last.head)
        do {
            _ = try await db.applyContextProposal(command(marker: marker, expectedHead: nil, rangeIDs: [UUID()]))
            XCTFail("An unseen stale response cannot replace a newer head")
        } catch { XCTAssertEqual(error as? ContextStoreError, .revisionConflict) }
        let history = try await db.contextRangeHistory(markerID: marker.id, afterSequence: 0, limit: 100)
        XCTAssertTrue(history.contains { $0.state == .superseded })
        try await db.close()
        let reopened = ContextDatabase(databasePath: path, nativeStoreID: native)
        try await reopened.initialize()
        let original = try await reopened.contextProposal(jobID: first.jobID)
        XCTAssertEqual(original?.requestPayload, first.requestPayload)
        XCTAssertEqual(original?.resultPayload, first.resultPayload)
        let persisted = try await reopened.listContextRanges(markerID: marker.id, limit: 64)
        XCTAssertEqual(persisted, [pinned])
        try await reopened.close()
    }

    func testGenericEditCannotRelabelInheritedExplanationAsUserAuthored() async throws {
        let db = ContextDatabase(databasePath: ":memory:", nativeStoreID: UUID())
        try await db.initialize()
        let marker = try await db.createManualMarker(.init(anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)))
        _ = try await db.applyContextProposal(command(marker: marker, expectedHead: nil, rangeIDs: [UUID()]))
        let ranges = try await db.listContextRanges(markerID: marker.id, limit: 64)
        let range = try XCTUnwrap(ranges.first)
        do {
            _ = try await db.saveContextRange(markerID: marker.id, range: .init(id: range.id,
                start: range.start, end: range.end, explanation: "Relabelled copy", ownership: .manual),
                expectedRevision: range.revision, expectedMarkerRevision: marker.revision)
            XCTFail("An explicit separate user note is required")
        } catch { XCTAssertEqual(error as? ContextStoreError, .invalidInput) }
        try await db.close()
    }

    func testVersionTwoLegacyRangeMigrationKeepsCopiedTextUnverifiedAcrossOwnershipChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), path = root.appendingPathComponent("context.db").path
        let database = ContextDatabase(databasePath: path, nativeStoreID: native)
        try await database.initialize()
        let marker = try await database.createManualMarker(.init(anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)))
        var original: [MarkerContextRange] = []
        for ownership in [MarkerContextOwnership.proposed, .manual, .pinned] {
            original.append(try await database.saveContextRange(markerID: marker.id,
                range: .init(start: marker.anchoredAt, end: marker.anchoredAt.addingTimeInterval(1),
                    explanation: "Legacy retained copy", ownership: ownership), expectedRevision: nil))
        }
        try await database.close()
        try sql("""
            DROP TABLE audio_session_settings_commands; DROP TABLE audio_session_settings;
            DROP TABLE companion_batch_candidates; DROP TABLE companion_enrollments;
            DROP TABLE context_range_revisions; DROP TABLE context_proposals; DROP TABLE context_proposal_heads;
            DROP INDEX context_ranges_active; ALTER TABLE marker_context_ranges DROP COLUMN active;
            PRAGMA user_version=2;
            """, path: path)
        for range in original { try replaceLegacyPayload(range, markerID: marker.id, path: path) }
        let reopened = ContextDatabase(databasePath: path, nativeStoreID: native)
        try await reopened.initialize()
        let migrated = try await reopened.listContextRanges(markerID: marker.id, limit: 64)
        XCTAssertEqual(Set(migrated.map(\.id)), Set(original.map(\.id)))
        XCTAssertTrue(migrated.allSatisfy { $0.explanationOrigin == nil && $0.provenance == nil && $0.effectiveExplanationOrigin == .legacyUnverified })
        let old = try XCTUnwrap(migrated.first { $0.ownership == .proposed })
        let pinned = try await reopened.saveContextRange(markerID: marker.id,
            range: .init(id: old.id, start: old.start, end: old.end, explanation: old.explanation,
                ownership: .pinned, userNote: "My separate correction"), expectedRevision: old.revision)
        XCTAssertEqual(pinned.effectiveExplanationOrigin, .legacyUnverified)
        let history = try await reopened.contextRangeHistory(markerID: marker.id, afterSequence: 0, limit: 10)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.first?.range.explanationOrigin, nil)
        try await reopened.close()
    }

    func testInjectedReceiptAndHeadFailureRollBackRangesHistoryAndProposal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), path = root.appendingPathComponent("context.db").path
        let database = ContextDatabase(databasePath: path, nativeStoreID: native)
        try await database.initialize()
        let marker = try await database.createManualMarker(.init(anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let initial = try await database.applyContextProposal(command(marker: marker, expectedHead: nil, rangeIDs: [UUID()]))
        let ranges = try await database.listContextRanges(markerID: marker.id, limit: 64)
        let history = try await database.contextRangeHistory(markerID: marker.id, afterSequence: 0, limit: 100)
        for target in ["context_proposals", "context_proposal_heads"] {
            let proposal = try command(marker: marker, expectedHead: initial.head.revision, rangeIDs: [UUID()])
            try sql("CREATE TRIGGER injected_reject BEFORE UPDATE ON " + target + " BEGIN SELECT RAISE(ABORT,'authored failure'); END", path: path)
            do { _ = try await database.applyContextProposal(proposal); XCTFail("Injected write must fail") }
            catch { XCTAssertFalse(error is ContextStoreError, "The injected SQLite failure must be the cause") }
            let unchangedRanges = try await database.listContextRanges(markerID: marker.id, limit: 64)
            let unchangedHistory = try await database.contextRangeHistory(markerID: marker.id, afterSequence: 0, limit: 100)
            let unchangedHead = try await database.contextProposalHead(markerID: marker.id)
            let absent = try await database.contextProposal(jobID: proposal.jobID)
            XCTAssertEqual(unchangedRanges, ranges); XCTAssertEqual(unchangedHistory, history)
            XCTAssertEqual(unchangedHead, initial.head); XCTAssertNil(absent)
            try sql("DROP TRIGGER injected_reject", path: path)
        }
        try await database.close()
    }

    func testTwoIndependentConnectionsCompareAndSwapOneProposalHead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), path = root.appendingPathComponent("context.db").path
        let first = ContextDatabase(databasePath: path, nativeStoreID: native)
        let second = ContextDatabase(databasePath: path, nativeStoreID: native)
        try await first.initialize(); try await second.initialize()
        let marker = try await first.createManualMarker(.init(anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let a = try command(marker: marker, expectedHead: nil, rangeIDs: [UUID()])
        let b = try command(marker: marker, expectedHead: nil, rangeIDs: [UUID()])
        let start = ProposalRaceBarrier()
        let jobs = [Task { await start.enter(); return await Self.attempt(first, command: a) },
                    Task { await start.enter(); return await Self.attempt(second, command: b) }]
        let outcomes = [await jobs[0].value, await jobs[1].value]
        XCTAssertEqual(outcomes.filter { $0 == "committed" }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == "revisionConflict" }.count, 1)
        let headA = try await first.contextProposalHead(markerID: marker.id)
        let headB = try await second.contextProposalHead(markerID: marker.id)
        XCTAssertEqual(headA, headB)
        let rows = try await first.listContextRanges(markerID: marker.id, limit: 64)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.provenance?.jobID, headA?.jobID)
        try await first.close(); try await second.close()
    }

    private static func attempt(_ store: ContextDatabase, command: ContextProposalCommand) async -> String {
        do { _ = try await store.applyContextProposal(command); return "committed" }
        catch ContextStoreError.revisionConflict { return "revisionConflict" }
        catch { return "unexpected: \(error)" }
    }
    private func sql(_ sql: String, path: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(path, &connection) == SQLITE_OK, let connection else { throw NSError(domain: "fixture-open", code: 1) }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: String(cString: sqlite3_errmsg(connection)), code: 2)
        }
    }
    private func replaceLegacyPayload(_ range: MarkerContextRange, markerID: UUID, path: String) throws {
        struct LegacyRange: Encodable {
            let id: UUID, revision: UUID
            let start: Date, end: Date
            let explanation: String
            let ownership: MarkerContextOwnership
        }
        let payload = try JSONEncoder().encode(LegacyRange(id: range.id, revision: range.revision,
            start: range.start, end: range.end, explanation: range.explanation, ownership: range.ownership))
        var connection: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open(path, &connection) == SQLITE_OK, let connection else { throw NSError(domain: "fixture-open", code: 1) }
        defer { sqlite3_close(connection) }
        guard sqlite3_prepare_v2(connection, "UPDATE marker_context_ranges SET payload=? WHERE marker_id=? AND id=?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw NSError(domain: "fixture-prepare", code: 2) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient) }
        sqlite3_bind_text(statement, 2, markerID.uuidString, -1, transient)
        sqlite3_bind_text(statement, 3, range.id.uuidString, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw NSError(domain: "fixture-write", code: 3) }
    }

    private func command(marker: TimelineMarker, expectedHead: UUID?, rangeIDs: [UUID]) throws -> ContextProposalCommand {
        let snapshot = UUID(), start = marker.anchoredAt
        let evidence = rangeIDs.enumerated().map { index, id in
            CompanionEvidenceItem(id: id.uuidString, reference: .init(v23Transcript: .init(nativeStoreID: marker.nativeStoreID,
                source: .microphone, rowID: Int64(index + 1), snapshotSHA256: String(repeating: "a", count: 64))),
                start: start.addingTimeInterval(Double(index)), end: start.addingTimeInterval(Double(index + 1)), text: "Exact support \(index)")
        }
        let request = CompanionJobRequest(sourceStoreID: marker.nativeStoreID, observedAt: start,
            context: .init(markerID: marker.id, markerRevision: marker.revision, snapshotID: snapshot,
                query: "Decision", verbatimExplanation: "", developing: true, incomplete: true, evidence: evidence, expectedProposalHead: expectedHead))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(request), jobID = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let result = CompanionResult(jobID: jobID, sourceStoreID: marker.nativeStoreID,
            contextProposal: .init(markerID: marker.id, markerRevision: marker.revision, snapshotID: snapshot,
                verbatimExplanation: "", developing: true, incomplete: true, ranges: zip(rangeIDs, evidence).map { id, item in
                    .init(id: id, start: item.start, end: item.end, explanation: item.text, supportIDs: [item.id], score: 0.9)
                }, method: "authored"))
        return .init(jobID: jobID, proposalRevision: snapshot, expectedMarkerRevision: marker.revision, expectedProposalHead: expectedHead,
            requestPayload: data, resultPayload: try encoder.encode(result))
    }
}

private actor ProposalRaceBarrier {
    private var entered = 0
    private var first: CheckedContinuation<Void, Never>?
    func enter() async {
        entered += 1
        if entered == 2 { first?.resume(); first = nil; return }
        await withCheckedContinuation { first = $0 }
    }
}
