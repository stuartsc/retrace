import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database

/// Real private SQLite files exercise transactions, durable receipts and revision fences.
final class ContextDatabaseTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appendingPathComponent("context.db").path }
    private let nativeID = UUID()
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000.125)
    private var database: ContextDatabase!
    private var store: any ContextStoreProtocol { database }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("context-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = ContextDatabase(databasePath: path, nativeStoreID: nativeID)
        try await database.initialize()
    }

    override func tearDown() async throws {
        try await database.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testMarkerEditHasDurableReceiptAndPreservesImmutableAnchor() async throws {
        let original = try await store.createManualMarker(.init(anchoredAt: anchor, title: "Original", note: "Before"))
        let command = TimelineMarkerEditCommand(id: original.id, expectedRevision: original.revision,
            title: "Reviewed title", note: "A manual explanation")
        let edited = try await store.updateMarker(command)
        XCTAssertNotEqual(edited.revision, original.revision)
        XCTAssertEqual(edited.anchoredAt, original.anchoredAt)
        XCTAssertEqual(edited.createdAt, original.createdAt)
        XCTAssertEqual(edited.nativeStoreID, original.nativeStoreID)
        XCTAssertEqual(edited.title, "Reviewed title")
        XCTAssertNotNil(edited.userEditedAt)
        try await reopen()
        let retry = try await store.updateMarker(command)
        XCTAssertEqual(retry, edited)
        let clearNote = try await store.updateMarker(.init(id: edited.id, expectedRevision: edited.revision,
            title: edited.title, note: nil))
        XCTAssertNil(clearNote.note)
        await assertError(.revisionConflict) {
            _ = try await self.store.updateMarker(.init(id: original.id, expectedRevision: original.revision,
                title: "Stale edit", note: nil))
        }
        await assertError(.requestConflict) {
            _ = try await self.store.updateMarker(.init(clientID: command.clientID, requestID: command.requestID,
                id: command.id, expectedRevision: command.expectedRevision, title: "Different retry", note: command.note))
        }
        let deleted = try await store.setMarkerDeleted(id: clearNote.id, expectedRevision: clearNote.revision, deleted: true)
        await assertError(.markerNotFound) {
            _ = try await self.store.updateMarker(.init(id: deleted.id, expectedRevision: deleted.revision,
                title: "Cannot edit a deleted marker", note: nil))
        }
        let historicalReceipt = try await store.updateMarker(command)
        XCTAssertEqual(historicalReceipt, edited)
        let active = try await store.marker(id: edited.id, includeDeleted: false)
        XCTAssertNil(active, "Historical edit retries cannot restore a removed marker")
    }

    func testMarkerEditReceiptFailureRollsBackAndInvalidPayloadDoesNotAdvanceRevision() async throws {
        let original = try await store.createManualMarker(.init(anchoredAt: anchor))
        let command = TimelineMarkerEditCommand(id: original.id, expectedRevision: original.revision,
            title: "Reviewed title", note: nil)
        try sql("CREATE TRIGGER reject_edit_receipt BEFORE INSERT ON marker_commands BEGIN SELECT RAISE(ABORT,'injected'); END")
        do { _ = try await store.updateMarker(command); XCTFail("Failed receipt cannot acknowledge an edit") }
        catch { }
        let unchanged = try await store.marker(id: original.id, includeDeleted: false)
        XCTAssertEqual(unchanged, original)
        try sql("DROP TRIGGER reject_edit_receipt")
        await assertError(.invalidInput) {
            _ = try await self.store.updateMarker(.init(id: original.id, expectedRevision: original.revision,
                title: "", note: nil))
        }
        let edited = try await store.updateMarker(command)
        XCTAssertEqual(edited.title, command.title)
    }

    func testIdentityAndExactManualAnchorSurviveReopen() async throws {
        let contextID = try await store.contextStoreID()
        let ref = ScreenEvidenceRef(storeID: nativeID, source: .native, observationID: UUID(),
                                    frameID: FrameID(value: 42), extractionRevision: 2, blockIDs: [0, 3])
        let marker = try await store.createManualMarker(.init(anchoredAt: anchor, title: "Budget café 🧭", screenReference: ref))
        try await reopen()
        let reopenedID = try await store.contextStoreID()
        let retained = try await store.marker(id: marker.id, includeDeleted: false)
        XCTAssertEqual(reopenedID, contextID)
        XCTAssertEqual(retained, marker)
        XCTAssertEqual(retained?.screenReference, ref)
        XCTAssertEqual(retained?.anchoredAt, anchor)
    }

    func testWrongNativeStoreAndForeignDatabaseAreRejectedWithoutMutation() async throws {
        let wrong = ContextDatabase(databasePath: path, nativeStoreID: UUID())
        await assertError(.nativeStoreMismatch) { try await wrong.initialize() }
        let foreignPath = directory.appendingPathComponent("recording.db").path
        try sql("CREATE TABLE frame(id INTEGER PRIMARY KEY); PRAGMA user_version=23", at: foreignPath)
        let foreign = ContextDatabase(databasePath: foreignPath, nativeStoreID: nativeID)
        await assertError(.incompatibleDatabase) { try await foreign.initialize() }
        XCTAssertEqual(try scalar("PRAGMA user_version", at: foreignPath), 23)
        XCTAssertEqual(try scalar("SELECT count(*) FROM sqlite_master WHERE name='context_metadata'", at: foreignPath), 0)
    }

    func testCreationRetriesAreDurableAndConflictingReuseFails() async throws {
        let command = ManualTimelineMarkerCommand(requestID: UUID(), anchoredAt: anchor, note: "Review '100%' later")
        let first = try await store.createManualMarker(command)
        let immediateRetry = try await store.createManualMarker(command)
        XCTAssertEqual(immediateRetry, first)
        try await reopen()
        let retry = try await store.createManualMarker(command)
        XCTAssertEqual(retry, first)
        let conflict = ManualTimelineMarkerCommand(requestID: command.requestID, anchoredAt: anchor, note: "Changed")
        await assertError(.requestConflict) { _ = try await self.store.createManualMarker(conflict) }
        let otherClient = ManualTimelineMarkerCommand(clientID: "other-client", requestID: command.requestID, anchoredAt: anchor)
        let independent = try await store.createManualMarker(otherClient)
        XCTAssertNotEqual(independent.id, first.id)
        let page = try await store.listMarkers(.init(limit: 10))
        XCTAssertEqual(page.markers.count, 2)
    }

    func testSoftDeleteUndoAndCreationReceiptDoNotResurrectMarker() async throws {
        let command = ManualTimelineMarkerCommand(anchoredAt: anchor)
        let original = try await store.createManualMarker(command)
        let deleted = try await store.setMarkerDeleted(id: original.id, expectedRevision: original.revision, deleted: true)
        XCTAssertNotNil(deleted.deletedAt)
        try await reopen()
        let retry = try await store.createManualMarker(command)
        XCTAssertEqual(retry, original) // Historical command receipt, never a current-state assertion.
        let hidden = try await store.marker(id: original.id, includeDeleted: false)
        XCTAssertNil(hidden)
        await assertError(.revisionConflict) {
            _ = try await self.store.setMarkerDeleted(id: original.id, expectedRevision: original.revision, deleted: false)
        }
        let restored = try await store.setMarkerDeleted(id: original.id, expectedRevision: deleted.revision, deleted: false)
        XCTAssertNil(restored.deletedAt)
        XCTAssertNotEqual(restored.revision, deleted.revision)
    }

    func testIndependentContextRangesAndPinnedOwnershipRejectLateProposal() async throws {
        let marker = try await store.createManualMarker(.init(anchoredAt: anchor))
        let initial = MarkerContextRange(start: anchor.addingTimeInterval(-60), end: anchor,
                                         explanation: "Previous discussion", ownership: .proposed)
        let proposed = try await store.saveContextRange(markerID: marker.id, range: initial, expectedRevision: nil)
        let second = try await store.saveContextRange(markerID: marker.id,
            range: .init(start: anchor, end: anchor.addingTimeInterval(60), explanation: "Follow-up", ownership: .manual),
            expectedRevision: nil)
        let pin = MarkerContextRange(id: proposed.id, start: proposed.start, end: proposed.end,
                                    explanation: proposed.explanation, ownership: .pinned, userNote: "Keep this selection")
        let pinned = try await store.saveContextRange(markerID: marker.id, range: pin, expectedRevision: proposed.revision)
        await assertError(.revisionConflict) {
            _ = try await self.store.saveContextRange(markerID: marker.id, range: initial, expectedRevision: proposed.revision)
        }
        await assertError(.protectedContextRange) {
            _ = try await self.store.saveContextRange(markerID: marker.id, range: initial, expectedRevision: pinned.revision)
        }
        try await reopen()
        let ranges = try await store.listContextRanges(markerID: marker.id, limit: 64)
        XCTAssertEqual(Set(ranges.map(\.id)), [pinned.id, second.id])
        XCTAssertEqual(ranges.first { $0.id == pinned.id }, pinned)
        let retained = try await store.marker(id: marker.id, includeDeleted: false)
        XCTAssertEqual(retained?.revision, marker.revision)
    }

    func testKeywordRulesDefaultDisabledAndEnforceRevisionAcrossReopen() async throws {
        let rule = try await store.saveKeywordRule(.init(phrase: "remember this", aliases: ["mark this"],
                                                        name: "Remember", meaning: "Keep this moment"), expectedRevision: nil)
        XCTAssertFalse(rule.enabled)
        XCTAssertEqual(rule.action, .markOnTimeline)
        try await reopen()
        let rules = try await store.listKeywordRules(afterID: nil, limit: 10)
        XCTAssertEqual(rules, [rule])
        let changed = KeywordRule(id: rule.id, phrase: rule.phrase, aliases: rule.aliases,
                                  name: rule.name, meaning: rule.meaning, enabled: true)
        let saved = try await store.saveKeywordRule(changed, expectedRevision: rule.revision)
        XCTAssertTrue(saved.enabled)
        await assertError(.revisionConflict) { _ = try await self.store.saveKeywordRule(changed, expectedRevision: rule.revision) }
    }

    func testMarkerListingUsesStableBoundedCursorAndExcludesDeleted() async throws {
        for index in 0..<5 {
            _ = try await store.createManualMarker(.init(anchoredAt: anchor, title: "Marker \(index)"))
        }
        let first = try await store.listMarkers(.init(limit: 2))
        let second = try await store.listMarkers(.init(before: try XCTUnwrap(first.nextCursor), limit: 2))
        let third = try await store.listMarkers(.init(before: try XCTUnwrap(second.nextCursor), limit: 2))
        XCTAssertEqual(Set((first.markers + second.markers + third.markers).map(\.id)).count, 5)
        XCTAssertEqual(third.markers.count, 1)
        XCTAssertNil(third.nextCursor)
        await assertError(.invalidInput) { _ = try await self.store.listMarkers(.init(limit: 0)) }
        await assertError(.invalidInput) { _ = try await self.store.listMarkers(.init(limit: 201)) }
    }

    func testInvalidPayloadAndForeignScreenReferenceNeverPersist() async throws {
        await assertError(.invalidInput) { _ = try await self.store.createManualMarker(.init(anchoredAt: Date(timeIntervalSince1970: .nan))) }
        await assertError(.invalidInput) { _ = try await self.store.createManualMarker(.init(anchoredAt: self.anchor, title: String(repeating: "é", count: 513))) }
        let wrong = ScreenEvidenceRef(storeID: UUID(), source: .native, observationID: UUID(), frameID: FrameID(value: 1), extractionRevision: 1)
        await assertError(.invalidInput) { _ = try await self.store.createManualMarker(.init(anchoredAt: self.anchor, screenReference: wrong)) }
        let invalid = ScreenEvidenceRef(storeID: nativeID, source: .native, observationID: UUID(), frameID: FrameID(value: 0), extractionRevision: 1)
        await assertError(.invalidInput) { _ = try await self.store.createManualMarker(.init(anchoredAt: self.anchor, screenReference: invalid)) }
        let page = try await store.listMarkers(.init())
        XCTAssertTrue(page.markers.isEmpty)
    }

    func testCommandReceiptFailureRollsBackMarkerAndCanRetry() async throws {
        try sql("CREATE TRIGGER reject_marker_receipt BEFORE INSERT ON marker_commands BEGIN SELECT RAISE(ABORT,'injected'); END")
        let command = ManualTimelineMarkerCommand(anchoredAt: anchor)
        do {
            _ = try await store.createManualMarker(command)
            XCTFail("Failed transaction must not return a marker acknowledgement")
        } catch { }
        let page = try await store.listMarkers(.init())
        XCTAssertTrue(page.markers.isEmpty)
        XCTAssertEqual(try scalar("SELECT count(*) FROM marker_commands"), 0)
        try sql("DROP TRIGGER reject_marker_receipt")
        _ = try await store.createManualMarker(command)
        XCTAssertEqual(try scalar("SELECT count(*) FROM timeline_markers"), 1)
    }

    func testDeferredCommitFailureDoesNotReturnAcknowledgementOrRetainReceipt() async throws {
        try sql("""
            CREATE TABLE failure_parent(id INTEGER PRIMARY KEY);
            CREATE TABLE failure_child(parent_id INTEGER REFERENCES failure_parent(id) DEFERRABLE INITIALLY DEFERRED);
            CREATE TRIGGER reject_marker_commit AFTER INSERT ON marker_commands
            BEGIN INSERT INTO failure_child(parent_id) VALUES(1); END;
            """)
        let command = ManualTimelineMarkerCommand(anchoredAt: anchor)
        do {
            _ = try await store.createManualMarker(command)
            XCTFail("COMMIT failure must not return an acknowledgement")
        } catch { }
        XCTAssertEqual(try scalar("SELECT count(*) FROM timeline_markers"), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM marker_commands"), 0)
        try sql("DROP TRIGGER reject_marker_commit")
        let saved = try await store.createManualMarker(command)
        try await reopen()
        let retry = try await store.createManualMarker(command)
        XCTAssertEqual(retry, saved)
    }

    func testSeparateConnectionsSerializeIdenticalCreationRequests() async throws {
        let second = ContextDatabase(databasePath: path, nativeStoreID: nativeID)
        try await second.initialize()
        let command = ManualTimelineMarkerCommand(anchoredAt: anchor)
        async let firstOutcome = store.createManualMarker(command)
        async let secondOutcome = second.createManualMarker(command)
        let outcomes = try await (firstOutcome, secondOutcome)
        XCTAssertEqual(outcomes.0, outcomes.1)
        XCTAssertEqual(try scalar("SELECT count(*) FROM timeline_markers"), 1)
        try await second.close()
    }

    func testContextRangeCapacityAndValidationRejectWithoutTruncation() async throws {
        let marker = try await store.createManualMarker(.init(anchoredAt: anchor))
        for index in 0..<64 {
            _ = try await store.saveContextRange(markerID: marker.id,
                range: .init(start: anchor, end: anchor, explanation: "Range \(index)", ownership: .manual), expectedRevision: nil)
        }
        await assertError(.capacityExceeded) {
            _ = try await self.store.saveContextRange(markerID: marker.id,
                range: .init(start: self.anchor, end: self.anchor, explanation: "Extra", ownership: .proposed), expectedRevision: nil)
        }
        let retained = try await store.listContextRanges(markerID: marker.id, limit: 64)
        XCTAssertEqual(retained.count, 64)
        await assertError(.invalidInput) {
            _ = try await self.store.saveContextRange(markerID: marker.id,
                range: .init(start: self.anchor, end: self.anchor.addingTimeInterval(-1), explanation: "Invalid", ownership: .manual), expectedRevision: nil)
        }
        await assertError(.invalidInput) {
            _ = try await self.store.saveKeywordRule(.init(phrase: "Remember", aliases: Array(repeating: "alias", count: 17),
                                                          name: "Remember", meaning: ""), expectedRevision: nil)
        }
    }

    func testCloseIsTerminalAndNeverAcknowledgesNewMarker() async throws {
        try await store.close()
        await assertError(.closed) { _ = try await self.store.createManualMarker(.init(anchoredAt: self.anchor)) }
        await assertError(.closed) { try await self.database.initialize() }
        try await store.close()
        try await reopen()
        let page = try await store.listMarkers(.init())
        XCTAssertTrue(page.markers.isEmpty)
    }

    private func reopen() async throws {
        try await database.close()
        database = ContextDatabase(databasePath: path, nativeStoreID: nativeID)
        try await database.initialize()
    }

    private func assertError(_ expected: ContextStoreError, operation: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? ContextStoreError, expected, file: file, line: line) }
    }

    private func sql(_ statement: String, at customPath: String? = nil) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(customPath ?? path, &handle) == SQLITE_OK, let handle else { throw ContextStoreError.incompatibleDatabase }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite test", code: Int(sqlite3_errcode(handle)),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
    }

    private func scalar(_ query: String, at customPath: String? = nil) throws -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open(customPath ?? path, &handle) == SQLITE_OK, let handle else { throw ContextStoreError.incompatibleDatabase }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else { throw ContextStoreError.incompatibleDatabase }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ContextStoreError.incompatibleDatabase }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
