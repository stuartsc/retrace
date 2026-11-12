import Foundation
import CryptoKit
import SQLCipher
import Shared
import XCTest
@testable import Database

final class CompanionDeliveryDatabaseTests: XCTestCase {
    func testInitializationFinalizesIdentityReadBeforeEnablingWAL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("delivery.db").path, native = UUID()
        for _ in 0..<2 {
            let writer = CompanionDeliveryDatabase(databasePath: path, nativeStoreID: native)
            try await writer.initialize()
            var reader: OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(path, &reader, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
            let opened = try XCTUnwrap(reader)
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(opened, "PRAGMA journal_mode", -1, &statement, nil), SQLITE_OK)
            let query = try XCTUnwrap(statement)
            XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
            XCTAssertEqual(String(cString: try XCTUnwrap(sqlite3_column_text(query, 0))), "wal")
            XCTAssertEqual(sqlite3_finalize(query), SQLITE_OK)
            XCTAssertEqual(sqlite3_close(opened), SQLITE_OK)
            try await writer.close()
        }
    }

    func testCompletedHistoryDoesNotConsumeActiveCapacityAndReopenRetainsBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), path = root.appendingPathComponent("delivery.db").path
        let db = CompanionDeliveryDatabase(databasePath: path, nativeStoreID: native)
        try await db.initialize()
        for index in 0..<260 {
            let bytes = try request(native, index: index)
            let receipt = try await db.publishGroup(semanticPayload: bytes, requests: [bytes], reservationID: UUID())
            let id = try XCTUnwrap(receipt.jobIDs.first)
            try await db.transition(jobID: id, stage: .invalidated)
        }
        let fresh = try request(native, index: 300)
        let receipt = try await db.publishGroup(semanticPayload: fresh, requests: [fresh], reservationID: UUID())
        let id = try XCTUnwrap(receipt.jobIDs.first)
        let active = try await db.records(activeOnly: true, limit: 256)
        XCTAssertEqual(active.map(\.jobID), [id])
        try await db.close()
        let read = CompanionDeliveryDatabase(databasePath: path, nativeStoreID: native, readOnly: true)
        try await read.initialize()
        let retained = try await read.record(jobID: id)
        XCTAssertEqual(retained?.requestPayload, fresh)
        try await read.close()
    }
    func testGroupCapacityFailureCreatesNoPartialJobsAndRetryKeepsOriginalOutcome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), db = CompanionDeliveryDatabase(databasePath: root.appendingPathComponent("delivery.db").path, nativeStoreID: native)
        try await db.initialize()
        var ids: [String] = []
        for index in 0..<255 {
            let bytes = try request(native, index: index)
            ids += try await db.publishGroup(semanticPayload: bytes, requests: [bytes], reservationID: UUID()).jobIDs
        }
        let a = try request(native, index: 256), b = try request(native, index: 257), semantic = Data("two-fragment-fixture".utf8)
        do { _ = try await db.publishGroup(semanticPayload: semantic, requests: [a, b], reservationID: UUID()); XCTFail("Group must be atomic") }
        catch { XCTAssertEqual(error as? CompanionError, .capacityExceeded) }
        let before = try await db.records(activeOnly: true, limit: 256)
        XCTAssertEqual(before.count, 255)
        try await db.transition(jobID: ids[0], stage: .invalidated)
        let saved = try await db.publishGroup(semanticPayload: semantic, requests: [a, b], reservationID: UUID())
        let replay = try await db.publishGroup(semanticPayload: semantic, requests: [], reservationID: UUID())
        XCTAssertEqual(saved, replay)
        XCTAssertEqual(saved.jobIDs.count, 2)
        try await db.close()
    }
    func testObjectLeaseAndSharedActiveReferencesPreventPrematureCollection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), path = root.appendingPathComponent("delivery.db").path
        let db = CompanionDeliveryDatabase(databasePath: path, nativeStoreID: native)
        try await db.initialize()
        let object = CompanionObjectReservation(sha256: String(repeating: "a", count: 64), byteCount: 128), reservation = UUID()
        try await db.reserveObjects([object], owner: reservation)
        let leased = try await db.claimObjectGarbage(); XCTAssertTrue(leased.isEmpty)
        try await db.markObjectReady(object)
        let first = try speaker(native, object: object, start: 0), second = try speaker(native, object: object, start: 16000)
        let receipt = try await db.publishGroup(semanticPayload: Data("shared media".utf8), requests: [first, second], reservationID: reservation)
        try await db.transition(jobID: receipt.jobIDs[0], stage: .invalidated)
        let shared = try await db.claimObjectGarbage(); XCTAssertTrue(shared.isEmpty)
        try await db.transition(jobID: receipt.jobIDs[1], stage: .invalidated)
        let claimed = try await db.claimObjectGarbage(); XCTAssertEqual(claimed, [object])
        do { try await db.reserveObjects([object], owner: UUID()); XCTFail("A deleting object cannot be leased") }
        catch { XCTAssertEqual(error as? CompanionError, .unavailable) }
        try await db.close()
        let reopened = CompanionDeliveryDatabase(databasePath: path, nativeStoreID: native)
        try await reopened.initialize()
        let crashRetry = try await reopened.claimObjectGarbage(); XCTAssertEqual(crashRetry, [object])
        try await reopened.completeObjectDeletion(sha256: object.sha256)
        let empty = try await reopened.claimObjectGarbage(); XCTAssertTrue(empty.isEmpty)
        let retained = try await reopened.record(jobID: receipt.jobIDs[0]); XCTAssertEqual(retained?.requestPayload, first)
        try await reopened.close()
    }
    func testReadOnlyMissingOrUnpublishedCatalogDoesNotCreateAndWrongStoreRejects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("delivery.db").path, native = UUID()
        let missing = CompanionDeliveryDatabase(databasePath: path, nativeStoreID: native, readOnly: true)
        do { try await missing.initialize(); XCTFail("Not published") }
        catch { XCTAssertEqual(error as? CompanionError, .unavailable) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path)); try await missing.close()
        let writer = CompanionDeliveryDatabase(databasePath: path, nativeStoreID: native)
        try await writer.initialize()
        let wrong = CompanionDeliveryDatabase(databasePath: path, nativeStoreID: UUID(), readOnly: true)
        do { try await wrong.initialize(); XCTFail("Native identity required") }
        catch { XCTAssertEqual(error as? CompanionError, .nativeStoreMismatch) }
        try await wrong.close(); try await writer.close()
    }
    func testSpeakerHistoryUsesStableKeysetAndExactRetainedResultsAcrossReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), path = root.appendingPathComponent("delivery.db").path
        let db = CompanionDeliveryDatabase(databasePath: path, nativeStoreID: native)
        try await db.initialize()
        let object = CompanionObjectReservation(sha256: String(repeating: "a", count: 64), byteCount: 128), lease = UUID()
        try await db.reserveObjects([object], owner: lease); try await db.markObjectReady(object)
        var expected: [String] = []
        for index in 0..<5 {
            let bytes = try speaker(native, object: object, start: Int64(index * 16000))
            let receipt = try await db.publishGroup(semanticPayload: bytes, requests: [bytes], reservationID: lease)
            let id = receipt.jobIDs[0]; expected.append(id)
            let result = try speakerResult(native, request: bytes, id: id)
            try await db.storeResult(jobID: id, payload: result); try await db.transition(jobID: id, stage: .imported)
            try await db.transition(jobID: id, stage: .acknowledged)
        }
        let from = Date(timeIntervalSince1970: 1_800_000_000), to = from.addingTimeInterval(10)
        let first = try await db.speakerPage(from: from, to: to, limit: 2)
        XCTAssertEqual(first.records.count, 2)
        try await db.close()
        let read = CompanionDeliveryDatabase(databasePath: path, nativeStoreID: native, readOnly: true)
        try await read.initialize()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let savedCursor = try XCTUnwrap(first.nextCursor)
        let resumedCursor = try decoder.decode(CompanionDeliveryCursor.self, from: encoder.encode(savedCursor))
        let second = try await read.speakerPage(from: from, to: to, before: resumedCursor, limit: 2)
        let third = try await read.speakerPage(from: from, to: to, before: second.nextCursor, limit: 2)
        let all = first.records + second.records + third.records
        XCTAssertEqual(Set(all.map(\.jobID)), Set(expected)); XCTAssertEqual(all.count, 5); XCTAssertNil(third.nextCursor)
        let retained = try await read.record(jobID: expected[0]); XCTAssertNotNil(retained?.resultPayload)
        try await read.close()
    }
    func testInvalidatedRequestCannotBecomeSuccessfulNewPublicationGroup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), db = CompanionDeliveryDatabase(databasePath: root.appendingPathComponent("delivery.db").path, nativeStoreID: native)
        try await db.initialize()
        let bytes = try request(native, index: 1)
        let first = try await db.publishGroup(semanticPayload: bytes, requests: [bytes], reservationID: UUID())
        try await db.transition(jobID: first.jobIDs[0], stage: .invalidated)
        do {
            _ = try await db.publishGroup(semanticPayload: Data("distinct new group".utf8), requests: [bytes], reservationID: UUID())
            XCTFail("Inactive work cannot be acknowledged as a new successful publication")
        } catch { XCTAssertEqual(error as? CompanionError, .staleEvidence) }
        let active = try await db.activeRecords(); XCTAssertTrue(active.isEmpty)
        try await db.close()
    }
    func testIndexedSelectorsNeedNoSortAndVMInterruptLeavesReaderUsable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let native = UUID(), path = root.appendingPathComponent("delivery.db").path
        let db = CompanionDeliveryDatabase(databasePath: path, nativeStoreID: native)
        try await db.initialize()
        let bytes = try request(native, index: 1)
        _ = try await db.publishGroup(semanticPayload: bytes, requests: [bytes], reservationID: UUID())
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let pointer = try XCTUnwrap(connection); defer { sqlite3_close(pointer) }
        let queries = [
            "SELECT j.id FROM jobs j INDEXED BY jobs_active_sequence WHERE j.active=1 AND j.sequence<999 ORDER BY j.sequence DESC LIMIT 8",
            "SELECT j.id FROM jobs j INDEXED BY jobs_source_samples WHERE j.kind='speaker' AND j.stage!='invalidated' AND j.recording_generation='g' AND j.continuity='c' AND j.origin=x'30' AND j.sample_start>=0 AND j.sample_start<960000 AND j.sample_end>0 ORDER BY j.sample_start DESC,j.id DESC LIMIT 257",
            "SELECT j.id FROM jobs j INDEXED BY jobs_speaker_time WHERE j.kind='speaker' AND j.stage IN ('imported','acknowledged') AND j.import_sequence<=999 AND j.source_start>=0 AND j.source_start<=120 AND j.source_end>=60 ORDER BY j.source_start DESC,j.id DESC LIMIT 65"
        ]
        for sql in queries {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(pointer, "EXPLAIN QUERY PLAN " + sql, -1, &statement, nil), SQLITE_OK)
            let prepared = try XCTUnwrap(statement); defer { sqlite3_finalize(prepared) }
            var details: [String] = []
            while sqlite3_step(prepared) == SQLITE_ROW { details.append(String(cString: sqlite3_column_text(prepared, 3))) }
            XCTAssertFalse(details.contains { $0.contains("TEMP B-TREE") }, details.joined(separator: "; "))
            XCTAssertTrue(details.contains { $0.contains("SEARCH j USING INDEX") })
        }
        // Force the actual SQLCipher progress callback to interrupt, then verify its
        // scoped handler is removed rather than poisoning subsequent reads.
        await db.setReadInstructionLimitForTesting(1)
        do { _ = try await db.activeRecords(); XCTFail("The VM budget must fail closed") }
        catch { XCTAssertEqual(error as? CompanionError, .capacityExceeded) }
        await db.setReadInstructionLimitForTesting(nil)
        let recovered = try await db.activeRecords(); XCTAssertEqual(recovered.count, 1)
        try await db.close()
    }
    private func speaker(_ native: UUID, object: CompanionObjectReservation, start: Int64) throws -> Data {
        let source = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(), startSample: start,
            sampleCount: 16000, sampleRate: 16000, approximateOrigin: Date(timeIntervalSince1970: 1_800_000_000))
        let request = CompanionJobRequest(sourceStoreID: native, observedAt: source.approximateOrigin.addingTimeInterval(Double(start) / 16000),
            speaker: .init(sourceIdentity: source, firstPassText: "Original", media: [.init(sha256: object.sha256,
                byteCount: object.byteCount, mediaID: String(repeating: "b", count: 64), offsetSamples: 0, countSamples: 16000, sourceStartSample: start)],
                firstPassReferences: [.init(nativeStoreID: native, source: .microphone, rowID: start + 1, snapshotSHA256: String(repeating: "c", count: 64))]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(request)
    }
    private func speakerResult(_ native: UUID, request: Data, id: String) throws -> Data {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let speaker = try XCTUnwrap(object["speaker"] as? [String: Any])
        let result: [String: Any] = ["version": 1, "jobID": id, "kind": "speaker", "sourceStoreID": native.uuidString,
            "speakerEnrichment": ["sourceIdentity": try XCTUnwrap(speaker["sourceIdentity"]),
                "firstPassSHA256": SHA256.hash(data: Data("Original".utf8)).map { String(format: "%02x", $0) }.joined(),
                "enhancedText": "Authored", "turns": [], "automaticNamesCalibrated": false, "modelFingerprint": String(repeating: "d", count: 64)]]
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }
    private func request(_ store: UUID, index: Int) throws -> Data {
        let request = CompanionJobRequest(sourceStoreID: store, observedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
            context: .init(markerID: UUID(), markerRevision: UUID(), snapshotID: UUID(), query: "Authored decision", verbatimExplanation: "",
                developing: true, incomplete: true, evidence: []))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(request)
    }
}
