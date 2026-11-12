import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database

final class SpokenMarkerPersistenceTests: XCTestCase {
    private var directory: URL!
    private var database: ContextDatabase!
    private var rule: KeywordRule!
    private let nativeID = UUID()
    private let generation = UUID()
    private let continuity = UUID()
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private var path: String { directory.appendingPathComponent("context.db").path }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-store-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = ContextDatabase(databasePath: path, nativeStoreID: nativeID)
        try await database.initialize()
        rule = try await database.saveKeywordRule(.init(phrase: "remember this", name: "Remember", meaning: "Keep this moment", enabled: true), expectedRevision: nil)
    }

    override func tearDown() async throws {
        try await database.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testManualTitleAndNoteSurviveRecognitionRevisionWithoutChangingVerbatimExplanation() async throws {
        let partial = try await database.applySpokenObservation(observation(status: .provisional))
        let edited = try await database.updateMarker(.init(id: partial.marker.id, expectedRevision: partial.marker.revision,
            title: "My reviewed title", note: "My separate note"))
        let final = try await database.applySpokenObservation(observation(occurrence: partial.observation.occurrenceID,
            expected: partial.observation.revision, status: .confirmed))
        XCTAssertEqual(final.marker.title, edited.title)
        XCTAssertEqual(final.marker.note, edited.note)
        XCTAssertEqual(final.marker.userEditedAt, edited.userEditedAt)
        XCTAssertEqual(final.marker.spokenObservation?.explanation, final.observation.explanation)
        XCTAssertNotEqual(final.observation.explanation, edited.note)
        XCTAssertEqual(final.observation.anchor, partial.observation.anchor)
        let deleted = try await database.setMarkerDeleted(id: final.marker.id, expectedRevision: final.marker.revision, deleted: true)
        let restored = try await database.setMarkerDeleted(id: deleted.id, expectedRevision: deleted.revision, deleted: false)
        XCTAssertEqual(restored.userEditedAt, edited.userEditedAt)
        try await reopen()
        let retained = try await database.marker(id: restored.id, includeDeleted: false)
        XCTAssertEqual(retained, restored)
    }

    func testPartialFinalRetriesPersistImmutableRevisionsAndDistinctRepeatedOccurrences() async throws {
        let command = observation(status: .provisional)
        let partial = try await database.applySpokenObservation(command)
        let retry = try await database.applySpokenObservation(command)
        XCTAssertEqual(retry, partial)
        let final = try await database.applySpokenObservation(observation(occurrence: command.occurrenceID,
            expected: partial.observation.revision, status: .confirmed, anchor: anchor(start: 16_100, end: 20_000)))
        XCTAssertEqual(final.marker.id, partial.marker.id)
        XCTAssertEqual(final.marker.spokenObservation?.status, .confirmed)
        try await reopen()
        let firstReceipt = try await database.applySpokenObservation(command)
        XCTAssertEqual(firstReceipt, partial)
        let history = try await database.spokenObservations(occurrenceID: command.occurrenceID, afterSequence: 0, limit: 20)
        XCTAssertEqual(history.map(\.revision), [partial.observation.revision, final.observation.revision])
        let repeated = try await database.applySpokenObservation(observation(status: .confirmed, anchor: final.observation.anchor))
        XCTAssertNotEqual(repeated.marker.id, final.marker.id)
        let markers = try await database.listMarkers(.init())
        XCTAssertEqual(markers.markers.count, 2)
    }

    func testRequestConflictAndStaleObservationRevisionRejectWithoutAppending() async throws {
        let command = observation(status: .provisional)
        let partial = try await database.applySpokenObservation(command)
        let conflicting = SpokenObservationCommand(clientID: command.clientID, requestID: command.requestID,
            occurrenceID: command.occurrenceID, expectedRevision: nil, status: .withdrawn, anchor: command.anchor,
            ruleSnapshot: rule, matchedPhrase: rule.phrase, explanation: "Changed request")
        await assertError(.requestConflict) { _ = try await self.database.applySpokenObservation(conflicting) }
        await assertError(.revisionConflict) {
            _ = try await self.database.applySpokenObservation(self.observation(occurrence: command.occurrenceID, expected: UUID(), status: .confirmed))
        }
        let history = try await database.spokenObservations(occurrenceID: command.occurrenceID, afterSequence: 0, limit: 20)
        XCTAssertEqual(history, [partial.observation])
    }

    func testUserUndoneOccurrenceStaysSuppressedAcrossLateFinalAndReopen() async throws {
        let partial = try await database.applySpokenObservation(observation(status: .provisional))
        let deleted = try await database.setMarkerDeleted(id: partial.marker.id, expectedRevision: partial.marker.revision, deleted: true)
        try await reopen()
        let final = try await database.applySpokenObservation(observation(occurrence: partial.observation.occurrenceID,
            expected: partial.observation.revision, status: .confirmed))
        XCTAssertTrue(final.suppressed)
        XCTAssertEqual(final.marker, deleted)
        let active = try await database.listMarkers(.init())
        XCTAssertTrue(active.markers.isEmpty)
        let state = try await database.spokenMarkerState(occurrenceID: partial.observation.occurrenceID)
        XCTAssertEqual(state?.observation.status, .confirmed)
        XCTAssertEqual(state?.marker.deletedAt, deleted.deletedAt)
    }

    func testConfirmedAnchorCannotMoveAfterWithdrawalAndContextPinRemainsIndependent() async throws {
        let final = try await database.applySpokenObservation(observation(status: .confirmed))
        let pinned = try await database.saveContextRange(markerID: final.marker.id,
            range: .init(start: origin, end: origin.addingTimeInterval(60), explanation: "Pinned by user", ownership: .pinned), expectedRevision: nil)
        await assertError(.confirmedAnchorConflict) {
            _ = try await self.database.applySpokenObservation(self.observation(occurrence: final.observation.occurrenceID,
                expected: final.observation.revision, status: .confirmed, anchor: self.anchor(start: 17_000, end: 20_000)))
        }
        let withdrawn = try await database.applySpokenObservation(observation(occurrence: final.observation.occurrenceID,
            expected: final.observation.revision, status: .withdrawn))
        XCTAssertNil(withdrawn.marker.deletedAt)
        let active = try await database.listMarkers(.init())
        XCTAssertTrue(active.markers.isEmpty)
        await assertError(.confirmedAnchorConflict) {
            _ = try await self.database.applySpokenObservation(self.observation(occurrence: final.observation.occurrenceID,
                expected: withdrawn.observation.revision, status: .confirmed, anchor: self.anchor(start: 17_000, end: 20_000)))
        }
        let restored = try await database.applySpokenObservation(observation(occurrence: final.observation.occurrenceID,
            expected: withdrawn.observation.revision, status: .confirmed))
        let ranges = try await database.listContextRanges(markerID: restored.marker.id, limit: 64)
        XCTAssertEqual(ranges, [pinned])
    }

    func testInvalidAndSystemProvenanceAndUnconfiguredRulesAreRejected() async throws {
        await assertError(.invalidInput) { _ = try await self.database.applySpokenObservation(self.observation(status: .confirmed, anchor: self.anchor(source: .system))) }
        await assertError(.invalidInput) { _ = try await self.database.applySpokenObservation(self.observation(status: .confirmed, anchor: self.anchor(storeID: UUID()))) }
        await assertError(.invalidInput) { _ = try await self.database.applySpokenObservation(self.observation(status: .confirmed, anchor: self.anchor(start: -1, end: 10))) }
        let unknown = KeywordRule(phrase: rule.phrase, name: rule.name, meaning: rule.meaning, enabled: true)
        let command = SpokenObservationCommand(occurrenceID: UUID(), status: .confirmed, anchor: anchor(), ruleSnapshot: unknown,
                                               matchedPhrase: unknown.phrase, explanation: "Unknown rule")
        await assertError(.ruleUnavailable) { _ = try await self.database.applySpokenObservation(command) }
        let page = try await database.listMarkers(.init())
        XCTAssertTrue(page.markers.isEmpty)
    }

    func testManifestRegistrationReopenIntersectionAndMediaRemainSeparateFromRecognition() async throws {
        let spoken = try await database.applySpokenObservation(observation(status: .confirmed))
        let before = try await database.audioManifests(intersecting: spoken.observation.anchor, limit: 20)
        XCTAssertTrue(before.isEmpty)
        let media = manifest(start: 0, count: 32_000)
        let saved = try await database.registerAudioManifest(media)
        let retry = try await database.registerAudioManifest(media)
        XCTAssertEqual(saved, retry)
        try await reopen()
        let found = try await database.audioManifests(intersecting: anchor(), limit: 20)
        XCTAssertEqual(found, [media])
        let exact = try await database.audioManifest(relativePath: media.relativePath)
        XCTAssertEqual(exact, media)
        let absent = try await database.audioManifest(relativePath: "audio/unregistered.m4a")
        XCTAssertNil(absent)
        let boundary = try await database.audioManifests(intersecting: anchor(start: 32_000, end: 33_000), limit: 20)
        XCTAssertTrue(boundary.isEmpty)
        let state = try await database.spokenMarkerState(occurrenceID: spoken.observation.occurrenceID)
        XCTAssertEqual(state?.observation, spoken.observation)
    }

    func testMediaOverlapConflictingRetryAndUnsafeMappingsAreRejected() async throws {
        let first = manifest(start: 0, count: 32_000)
        _ = try await database.registerAudioManifest(first)
        let conflict = AudioMediaManifest(id: first.id, nativeStoreID: nativeID, relativePath: first.relativePath,
            sha256: String(repeating: "b", count: 64), frameCount: first.frameCount, sourceRanges: first.sourceRanges)
        await assertError(.requestConflict) { _ = try await self.database.registerAudioManifest(conflict) }
        let overlappingFile = try await database.registerAudioManifest(manifest(start: 31_000, count: 16_000))
        let alternatives = try await database.audioManifests(intersecting: anchor(start: 31_000, end: 32_000), limit: 20)
        XCTAssertEqual(Set(alternatives.map(\.id)), [first.id, overlappingFile.id])
        _ = try await database.registerAudioManifest(manifest(start: 32_000, count: 16_000)) // Adjacent ranges are distinct.
        let duplicated = AudioMediaManifest(nativeStoreID: nativeID, relativePath: "audio/duplicated.m4a",
            sha256: String(repeating: "a", count: 64), frameCount: 64_000,
            sourceRanges: [first.sourceRanges[0], .init(source: first.sourceRanges[0].source, batchStartSample: 32_000)])
        await assertError(.mediaMappingConflict) { _ = try await self.database.registerAudioManifest(duplicated) }
        let unsafe = AudioMediaManifest(nativeStoreID: nativeID, relativePath: "audio/../recording.db",
            sha256: String(repeating: "a", count: 64), frameCount: 16_000, sourceRanges: first.sourceRanges)
        await assertError(.invalidInput) { _ = try await self.database.registerAudioManifest(unsafe) }
        let system = AudioMediaManifest(nativeStoreID: nativeID, source: .system, relativePath: "audio/system.m4a",
            sha256: String(repeating: "a", count: 64), frameCount: first.frameCount, sourceRanges: first.sourceRanges)
        await assertError(.invalidInput) { _ = try await self.database.registerAudioManifest(system) }
    }

    func testVersionOneContextMigratesAdditivelyWithoutChangingManualMarker() async throws {
        let manual = try await database.createManualMarker(.init(anchoredAt: origin))
        try await database.close()
        // Reconstruct the actual V1 shape to exercise the additive migration on a private file.
        try sql("""
            DROP TABLE audio_session_settings_commands; DROP TABLE audio_session_settings;
            DROP TABLE companion_batch_candidates; DROP TABLE companion_enrollments;
            DROP TABLE context_range_revisions; DROP TABLE context_proposals; DROP TABLE context_proposal_heads;
            DROP INDEX context_ranges_active; ALTER TABLE marker_context_ranges DROP COLUMN active;
            DROP TABLE audio_media_ranges; DROP TABLE audio_media_manifests;
            DROP TABLE spoken_commands; DROP TABLE spoken_observations; DROP TABLE spoken_occurrences;
            ALTER TABLE timeline_markers DROP COLUMN spoken_state; PRAGMA user_version=1;
            """)
        database = ContextDatabase(databasePath: path, nativeStoreID: nativeID)
        try await database.initialize()
        let retained = try await database.marker(id: manual.id, includeDeleted: false)
        XCTAssertEqual(retained, manual)
        _ = try await database.applySpokenObservation(observation(status: .confirmed))
    }

    func testObservationHistoryRejectsInPlaceMutationAndReceiptFailureRollsBack() async throws {
        let first = try await database.applySpokenObservation(observation(status: .provisional))
        XCTAssertThrowsError(try sql("UPDATE spoken_observations SET payload=x'00'"))
        XCTAssertThrowsError(try sql("DELETE FROM spoken_observations"))
        try sql("CREATE TRIGGER reject_spoken_receipt BEFORE INSERT ON spoken_commands BEGIN SELECT RAISE(ABORT,'injected'); END")
        let final = observation(occurrence: first.observation.occurrenceID, expected: first.observation.revision, status: .confirmed)
        do { _ = try await database.applySpokenObservation(final); XCTFail("Receipt failure must roll back") } catch { }
        let state = try await database.spokenMarkerState(occurrenceID: first.observation.occurrenceID)
        XCTAssertEqual(state, first)
        try sql("DROP TRIGGER reject_spoken_receipt")
        _ = try await database.applySpokenObservation(final)
    }

    private func observation(occurrence: UUID = UUID(), expected: UUID? = nil, status: SpokenRecognitionStatus,
                             anchor: SpokenMarkerAnchor? = nil) -> SpokenObservationCommand {
        .init(occurrenceID: occurrence, expectedRevision: expected, status: status, anchor: anchor ?? self.anchor(),
              ruleSnapshot: rule, matchedPhrase: rule.phrase, explanation: "Matched configured microphone phrase")
    }

    private func anchor(start: Int64 = 16_000, end: Int64 = 20_000, source: AudioSource = .microphone,
                        storeID: UUID? = nil) -> SpokenMarkerAnchor {
        .init(nativeStoreID: storeID ?? nativeID, source: source, recordingGeneration: generation, continuityID: continuity,
              startSample: start, endSample: end, approximateOrigin: origin, timingPrecision: .enclosingTimedSpan)
    }

    private func manifest(start: Int64, count: Int64) -> AudioMediaManifest {
        .init(nativeStoreID: nativeID, relativePath: "audio/\(UUID()).m4a", sha256: String(repeating: "a", count: 64), frameCount: count,
              sourceRanges: [.init(source: .init(recordingGeneration: generation, continuityID: continuity,
                    startSample: start, sampleCount: count, sampleRate: 16_000, approximateOrigin: origin), batchStartSample: 0)])
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

    private func sql(_ query: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw ContextStoreError.incompatibleDatabase }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite test", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }
}
