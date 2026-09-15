import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database

/// Canonical persistence tests use real SQLite transactions, including injected failures.
final class ActivityPersistenceTests: XCTestCase {
    private var database: DatabaseManager!
    private var store: (any ActivityStoreProtocol) { database }
    private let session = UUID()
    private let time = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:activity_\(UUID())?mode=memory&cache=private")
        try await database.initialize()
    }

    override func tearDown() async throws { try await database.close() }

    func testMetadataSearchNeedsNeitherFramesNorOCRAndFiltersBeforePageLimit() async throws {
        for index in 1...540 {
            _ = try await store.appendActivity(event(Int64(index), title: index > 520 ? "Budget café 🧭" : "Other window",
                                                      app: index > 530 ? "com.microsoft.Word" : "com.test.other"))
        }
        let first = try await store.searchActivity(ActivityQuery(text: "café", from: time.addingTimeInterval(528),
                                                                 appBundleIDs: ["com.microsoft.Word"], limit: 3))
        expectEqual(first.events.map(\.event.sequence), [531, 532, 533])
        let next = try await store.searchActivity(ActivityQuery(text: "café", appBundleIDs: ["com.microsoft.Word"],
                                                                afterSequence: try requireValue(first.nextSequence), limit: 20))
        expectEqual(next.events.map(\.event.sequence), Array(534...540).map(Int64.init))
        expectNil(next.nextSequence)
        expectEqual(try await scalar("SELECT COUNT(*) FROM frame"), 0)
    }

    func testEmptyFilterIsDenyAllAndSpecialCharactersAreLiteral() async throws {
        _ = try await store.appendActivity(event(1, title: "100% ' ; DROP TABLE frame; --"))
        let hidden = try await store.searchActivity(ActivityQuery(appBundleIDs: []))
        let exact = try await store.searchActivity(ActivityQuery(text: "100%"))
        let wildcard = try await store.searchActivity(ActivityQuery(text: "100_"))
        expectTrue(hidden.events.isEmpty)
        expectEqual(exact.events.count, 1)
        expectTrue(wildcard.events.isEmpty)
    }

    func testEventAndFeedRetryIsAtomicAndImmutable() async throws {
        let original = event(1)
        let first = try await store.appendActivity(original)
        let second = try await store.appendActivity(original)
        expectEqual(first.commitSequence, second.commitSequence)
        expectEqual(first.persistedAt, second.persistedAt)
        expectEqual(try await store.activityFeed(after: 0, limit: 20).count, 1)
        let changed = ActivityEvent(id: original.id, sessionID: session, sequence: 1, observedAt: original.observedAt,
                                   monotonicTime: 1, kind: .focus, coverage: .observed, method: "different")
        await assertThrows { _ = try await self.store.appendActivity(changed) }
        try await sql("CREATE TEMP TRIGGER reject_activity_feed BEFORE INSERT ON activity_feed BEGIN SELECT RAISE(ABORT,'injected'); END")
        let failed = event(2)
        await assertThrows { _ = try await self.store.appendActivity(failed) }
        expectNil(try await store.activityEvent(id: failed.id))
        try await sql("DROP TRIGGER reject_activity_feed")
        _ = try await store.appendActivity(failed)
        expectEqual(try await store.activityFeed(after: 0, limit: 20).count, 2)
    }

    func testSessionSequenceClockAndAdministrativeContextIntegrity() async throws {
        _ = try await store.appendActivity(event(1))
        await assertThrows { _ = try await self.store.appendActivity(self.event(1)) }
        await assertThrows { _ = try await self.store.appendActivity(self.event(3)) }
        let backwards = ActivityEvent(sessionID: session, sequence: 2, observedAt: time, monotonicTime: 0,
                                      kind: .focus, coverage: .observed, method: "test")
        await assertThrows { _ = try await self.store.appendActivity(backwards) }
        let invalidPause = ActivityEvent(sessionID: session, sequence: 2, monotonicTime: 2, kind: .pause,
                                        coverage: .paused, context: context("Must not persist"), method: "test")
        await assertThrows { _ = try await self.store.appendActivity(invalidPause) }
        let gap = ActivityEvent(sessionID: session, sequence: 5, observedAt: time, monotonicTime: 5,
                                kind: .gap, coverage: .unknown, method: "queue-overflow")
        _ = try await store.appendActivity(gap)
        _ = try await store.appendActivity(event(6))
        expectEqual(try await store.activityHealth().gapCount, 1)
    }

    func testFeedCheckpointsAreDurableMonotonicAndCannotAcknowledgeFuture() async throws {
        let first = try await store.appendActivity(event(1))
        let second = try await store.appendActivity(event(2))
        try await store.acknowledgeActivityFeed(consumer: "fuseintel", through: second.commitSequence)
        try await store.acknowledgeActivityFeed(consumer: "fuseintel", through: first.commitSequence)
        expectEqual(try await store.activityFeedCheckpoint(consumer: "fuseintel"), second.commitSequence)
        await assertThrows { try await self.store.acknowledgeActivityFeed(consumer: "fuseintel", through: second.commitSequence + 1) }
        await assertThrows { try await self.store.acknowledgeActivityFeed(consumer: "", through: 0) }
        expectEqual(try await store.activityFeedCheckpoint(consumer: "unseen"), 0)
    }

    func testCorrectionConfirmationIsPendingUntilAcknowledgedAndRevokeIsAppendOnly() async throws {
        let target = try await store.appendActivity(event(1))
        let command = ActivityCorrection(targetEventIDs: [target.id], expectedRevision: 0, action: .rename,
                                         label: "Georgetown", confirmed: true)
        let pending = try await store.submitActivityCorrection(command)
        expectEqual(pending.status, .pending)
        let retry = try await store.submitActivityCorrection(command)
        expectEqual(retry.revision, pending.revision)
        try await store.acknowledgeActivityCorrection(id: command.id, expectedRevision: pending.revision, applied: true)
        let revoke = ActivityCorrection(targetEventIDs: [target.id], expectedRevision: pending.revision, action: .revoke,
                                        confirmed: true, revokesCommandID: command.id)
        let undo = try await store.submitActivityCorrection(revoke)
        expectEqual(undo.status, .pending)
        try await store.acknowledgeActivityCorrection(id: revoke.id, expectedRevision: undo.revision, applied: true)
        let receipts = try await store.activityCorrections()
        expectEqual(receipts.count, 2)
        expectEqual(receipts.first { $0.command.id == command.id }?.status, .revoked)
        expectEqual(try await store.activityEvent(id: target.id)?.event.context?.windowTitle, "Original window")
    }

    func testDraftAndStaleCorrectionsNeverAppearApplied() async throws {
        let target = try await store.appendActivity(event(1))
        let draft = try await store.submitActivityCorrection(ActivityCorrection(targetEventIDs: [target.id], expectedRevision: 0,
                                                                               action: .rename, label: "Draft", confirmed: false))
        expectEqual(draft.status, .draft)
        await assertThrows { try await self.store.acknowledgeActivityCorrection(id: draft.command.id, expectedRevision: draft.revision, applied: true) }
        let stale = try await store.submitActivityCorrection(ActivityCorrection(targetEventIDs: [target.id], expectedRevision: 0,
                                                                               action: .rename, label: "Stale", confirmed: true))
        expectEqual(stale.status, .conflict)
        let missing = try await store.submitActivityCorrection(ActivityCorrection(targetEventIDs: [UUID()], expectedRevision: draft.revision,
                                                                                 action: .hide, confirmed: true))
        expectEqual(missing.status, .conflict)
    }

    func testCorrectionOutboxFailureRollsBackRevisionAndCommand() async throws {
        let target = try await store.appendActivity(event(1))
        try await sql("CREATE TEMP TRIGGER reject_correction_feed BEFORE INSERT ON activity_feed WHEN NEW.kind='correction' BEGIN SELECT RAISE(ABORT,'injected'); END")
        let command = ActivityCorrection(targetEventIDs: [target.id], expectedRevision: 0, action: .hide, confirmed: true)
        await assertThrows { _ = try await self.store.submitActivityCorrection(command) }
        expectTrue(try await store.activityCorrections().isEmpty)
        expectEqual(try await store.activityHealth().correctionRevision, 0)
    }

    func testDeletionSanitizesDependentCommandsAndFeedAndPreventsResurrection() async throws {
        let event = event(1, title: "Secret Budget")
        let target = try await store.appendActivity(event)
        _ = try await store.submitActivityCorrection(ActivityCorrection(targetEventIDs: [target.id], expectedRevision: 0,
                                                                         action: .rename, label: "Secret Budget corrected", confirmed: true))
        try await store.deleteActivity(eventIDs: [target.id])
        expectNil(try await store.activityEvent(id: target.id))
        let feed = try await store.activityFeed(after: 0, limit: 50)
        expectTrue(feed.contains { $0.kind == "activity_deleted" && $0.entityID == target.id })
        expectFalse(feed.contains { String(decoding: $0.payload, as: UTF8.self).contains("Secret Budget") })
        let receipts = try await store.activityCorrections()
        expectFalse(receipts.contains { $0.command.label?.contains("Secret Budget") == true })
        await assertThrows { _ = try await self.store.appendActivity(event) }
    }

    func testNativeStoreIdentitySurvivesReinitialization() async throws {
        let db = try requireValue(await database.getConnection())
        let first = try await store.activityStoreID()
        try await MigrationRunner(db: db).runMigrations()
        expectEqual(try await store.activityStoreID(), first)
        expectEqual(try await scalar("SELECT MAX(version) FROM schema_migrations"), 22)
        expectEqual(try await scalar("SELECT COUNT(*) FROM screen_observation"), 0)
    }

    func testRepeatedDeletionRetainsOneTombstoneAndDoesNotAdvanceRevision() async throws {
        let target = try await store.appendActivity(event(1))
        try await store.deleteActivity(eventIDs: [target.id])
        let before = try await store.activityHealth().correctionRevision
        try await store.deleteActivity(eventIDs: [target.id])
        let feed = try await store.activityFeed(after: 0, limit: 20)
        expectEqual(feed.filter { $0.kind == "activity_deleted" }.count, 1)
        expectEqual(try await store.activityHealth().correctionRevision, before)
    }

    func testEnrichmentNeedsOriginalWindowAndProcessGeneration() async throws {
        let original = try await store.appendActivity(event(1))
        let valid = ActivityEvent(sessionID: session, sequence: 2, observedAt: time, monotonicTime: 2, kind: .enrichment,
                                  coverage: .observed, context: context("Enriched safe title"), relatedEventID: original.id, method: "fixture")
        _ = try await store.appendActivity(valid)
        let changed = ActivityContext(appBundleID: "com.microsoft.Word", appName: "Word", processID: 17,
                                       processGeneration: "reused-process", windowID: 12)
        await assertThrows { _ = try await self.store.appendActivity(ActivityEvent(sessionID: self.session, sequence: 3,
            monotonicTime: 3, kind: .enrichment, coverage: .observed, context: changed, relatedEventID: original.id, method: "fixture")) }
    }

    func testReusableScopeAndAcknowledgementRejectConflictingTargetsAndRevisions() async throws {
        let target = try await store.appendActivity(event(1))
        let conflict = try await store.submitActivityCorrection(ActivityCorrection(targetEventIDs: [target.id], expectedRevision: 0,
            action: .assignProject, scope: .document, label: "Project", documentKey: "different-document", confirmed: true))
        expectEqual(conflict.status, .conflict)
        let pending = try await store.submitActivityCorrection(ActivityCorrection(targetEventIDs: [target.id], expectedRevision: 0,
            action: .assignProject, scope: .document, label: "Project", documentKey: target.event.context?.stableDocumentKey, confirmed: true))
        expectEqual(pending.status, .pending)
        await assertThrows { try await self.store.acknowledgeActivityCorrection(id: pending.command.id, expectedRevision: pending.revision + 1, applied: true) }
        try await store.acknowledgeActivityCorrection(id: pending.command.id, expectedRevision: pending.revision, applied: false)
        try await store.acknowledgeActivityCorrection(id: pending.command.id, expectedRevision: pending.revision, applied: false)
        expectEqual(try await store.activityCorrections().filter { $0.command.id == pending.command.id }.first?.status, .conflict)
    }

    func testMetricsContainOnlyCategoricalValuesAndNeverCapturedLabels() async throws {
        let target = try await store.appendActivity(event(1, title: "Sensitive Ledger"))
        _ = try await store.submitActivityCorrection(ActivityCorrection(targetEventIDs: [target.id], expectedRevision: 0,
            action: .rename, label: "Sensitive correction", confirmed: true))
        let db = try requireValue(await database.getConnection())
        let metadata = try PipelineSQL.query(db, "SELECT COALESCE(metadata,'') FROM daily_metrics") { RecallSQL.string($0, 0) }
        expectTrue(metadata.count >= 2)
        expectFalse(metadata.contains { $0.contains("Sensitive") || $0.contains("com.microsoft.Word") })
    }

    func testUnicodeMetadataSearchIsCaseAndAccentInsensitive() async throws {
        _ = try await store.appendActivity(event(1, title: "CAFÉ Résumé"))
        let page = try await store.searchActivity(ActivityQuery(text: "cafe resume"))
        expectEqual(page.events.count, 1)
    }

    func testCorrectionReadDoesNotHideMappingsAfterFiveHundredEarlierOnes() async throws {
        let target = try await store.appendActivity(event(1))
        var latestID = UUID()
        for index in 0...500 {
            let command = ActivityCorrection(targetEventIDs: [target.id], expectedRevision: Int64(index), action: .rename,
                                             label: "Revision \(index + 1)", confirmed: false)
            _ = try await store.submitActivityCorrection(command)
            latestID = command.id
        }
        let receipts = try await store.activityCorrections()
        expectEqual(receipts.count, 501)
        expectEqual(receipts.last?.command.id, latestID)
        expectEqual(receipts.first?.revision, 1)
    }

    func testSparseEligibleRecordBeyondTenThousandRowsIsNotLostToTruncation() async throws {
        let template = event(1)
        _ = try await store.appendActivity(template)
        let db = try requireValue(await database.getConnection())
        // Synthetic SQL is a query-shape regression, separate from capture acceptance.
        try PipelineSQL.execute(db, """
            WITH RECURSIVE n(i) AS (SELECT 2 UNION ALL SELECT i+1 FROM n WHERE i<10050)
            INSERT INTO activity_feed(sequence,kind,entityID,payload)
              SELECT i,'activity',printf('00000000-0000-0000-0000-%012d',i),'{}' FROM n
            """)
        let payload = try RecallSQL.encode(template)
        try PipelineSQL.execute(db, """
            INSERT INTO activity_event(eventID,sessionID,sessionSequence,commitSequence,observedAt,monotonicTime,persistedAt,appBundleID,metadataSearch,payload)
            SELECT entityID,'query-shape-fixture',sequence,sequence,0,0,0,
              CASE WHEN sequence=10050 THEN 'com.target' ELSE 'com.other' END,
              CASE WHEN sequence=10050 THEN 'rare eligible' ELSE 'unrelated' END,?
            FROM activity_feed WHERE sequence>1
            """, [.text(payload)])
        let page = try await store.searchActivity(ActivityQuery(text: "Rare", appBundleIDs: ["com.target"], limit: 1))
        expectEqual(page.events.map(\.commitSequence), [10050])
        expectNil(page.nextSequence)
    }

    private func context(_ title: String, app: String = "com.microsoft.Word") -> ActivityContext {
        ActivityContext(appBundleID: app, appName: "Word", processID: 17, processGeneration: "generation-1",
                        windowID: 12, windowTitle: title, displayID: 2, documentID: "document-1")
    }

    private func event(_ sequence: Int64, title: String = "Original window", app: String = "com.microsoft.Word") -> ActivityEvent {
        ActivityEvent(sessionID: session, sequence: sequence, observedAt: time.addingTimeInterval(Double(sequence)),
                      monotonicTime: Double(sequence), kind: .focus, coverage: .observed, context: context(title, app: app), method: "fixture-v1")
    }

    private func sql(_ value: String) async throws { try PipelineSQL.execute(try requireValue(await database.getConnection()), value) }
    private func scalar(_ value: String) async throws -> Int64 { try PipelineSQL.integers(try requireValue(await database.getConnection()), value).first ?? 0 }
    private func assertThrows(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected persistence rejection", file: file, line: line) } catch { }
    }
}
