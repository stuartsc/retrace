import Foundation
import Shared
import SQLCipher
import XCTest
@testable import Database

final class NativeAnnotationPersistenceTests: XCTestCase {
    func testAtomicCreationAndExactReadDoNotExposeAttachmentPaths() async throws {
        let f = try await Fixture.make(), snapshot = try await f.read()
        let attachment = SegmentCommentAttachment(id: "authored", filePath: "/private/authored-only.txt", fileName: "authored.txt")
        let receipt = try await f.apply(snapshot, .createComment(body: "Retained explanation", author: "Fixture", attachments: [attachment], anchor: f.refs[0].frameID))
        let current = try await f.read()
        XCTAssertEqual(receipt.affectedSegments, 2)
        XCTAssertEqual(current.segments.map { $0.comments.first?.id }, [receipt.commentID, receipt.commentID])
        XCTAssertEqual(current.segments.first?.comments.first?.attachmentCount, 1)
        let exported = String(decoding: try JSONEncoder().encode(current), as: UTF8.self)
        XCTAssertFalse(exported.contains("/private/")); XCTAssertFalse(exported.contains("filePath"))
        try await f.db.close()
    }

    func testAnnotationABARejectedWhileFreshRecordingPreservesSelection() async throws {
        let f = try await Fixture.make(), original = try await f.read()
        _ = try await Fixture.insert(f.db, time: f.time.addingTimeInterval(60))
        let afterCapture = try await f.read()
        XCTAssertEqual(original, afterCapture, "Ordinary capture must not expire an annotation edit")
        let tag = try await f.db.createTag(name: "Temporary")
        try await f.db.addTagToSegment(segmentId: original.segments[0].id, tagId: tag.id)
        try await f.db.removeTagFromSegment(segmentId: original.segments[0].id, tagId: tag.id)
        do { _ = try await f.apply(original, .addTag(name: "Late edit")); XCTFail("ABA must reject stale revision") }
        catch NativeAnnotationError.staleSelection { }
        let late = try await f.db.getTag(name: "Late edit")
        XCTAssertNil(late)
        try await f.db.close()
    }

    func testFullLinkedSetRequiredForGlobalCommentEditAndDelete() async throws {
        let f = try await Fixture.make(), original = try await f.read()
        let receipt = try await f.apply(original, .createComment(body: "Shared note", author: "Fixture", attachments: [], anchor: nil))
        let id = try XCTUnwrap(receipt.commentID)
        let partial = try await f.db.nativeAnnotations(references: [f.refs[0]], policy: f.policy)
        let mutations: [NativeAnnotationMutation] = [.updateComment(id: id, body: "Unauthorized partial edit"), .deleteComment(id: id)]
        for mutation in mutations {
            do { _ = try await f.apply(partial, mutation); XCTFail("Every affected source must be selected") }
            catch NativeAnnotationError.notPermitted { }
        }
        _ = try await f.apply(partial, .unlinkComment(id: id))
        let current = try await f.read()
        XCTAssertTrue(current.segments[0].comments.isEmpty)
        XCTAssertEqual(current.segments[1].comments.first?.body, "Shared note")
        try await f.db.close()
    }

    func testPolicyHiddenImportedAndReservedTagCannotMutate() async throws {
        let f = try await Fixture.make(), original = try await f.read()
        do { _ = try await f.apply(original, .addTag(name: " HIDDEN ")); XCTFail("Reserved visibility tag") }
        catch NativeAnnotationError.notPermitted { }
        let ref = f.refs[0]
        let imported = ScreenEvidenceRef(storeID: ref.storeID, source: .rewind, observationID: ref.observationID,
            frameID: ref.frameID, extractionRevision: ref.extractionRevision)
        do { _ = try await f.db.nativeAnnotations(references: [imported], policy: f.policy); XCTFail("Imported source") }
        catch NativeAnnotationError.notPermitted { }
        do {
            _ = try await f.db.nativeAnnotations(references: f.refs, policy: .init(config: Shared.CaptureConfig(excludedAppBundleIDs: ["com.fixture.annotations"])))
            XCTFail("Excluded source")
        } catch NativeAnnotationError.notPermitted { }
        let hiddenValue = try await f.db.getTag(name: "hidden"), hidden = try XCTUnwrap(hiddenValue)
        try await f.db.addTagToSegment(segmentId: original.segments[0].id, tagId: hidden.id)
        do { _ = try await f.apply(original, .addTag(name: "Forbidden")); XCTFail("Hidden source") }
        catch NativeAnnotationError.staleSelection { }
        let forbidden = try await f.db.getTag(name: "Forbidden")
        XCTAssertNil(forbidden)
        try await f.db.close()
    }

    func testFailureOnSecondLinkRollsBackCommentAndFirstLink() async throws {
        let f = try await Fixture.make(), original = try await f.read()
        let connection = await f.db.getConnection(), db = try XCTUnwrap(connection)
        let lastID = original.segments[1].id.value
        XCTAssertEqual(sqlite3_exec(db, "CREATE TEMP TRIGGER fail_annotation_link BEFORE INSERT ON segment_comment_link WHEN NEW.segmentId=\(lastID) BEGIN SELECT RAISE(ABORT,'authored failure'); END", nil, nil, nil), SQLITE_OK)
        do { _ = try await f.apply(original, .createComment(body: "Rollback", author: "Fixture", attachments: [], anchor: nil)); XCTFail("Injected second link must fail") } catch { }
        let unchanged = try await f.read()
        XCTAssertEqual(unchanged, original)
        let comments = try await f.db.getCommentsForSegment(segmentId: original.segments[0].id)
        XCTAssertTrue(comments.isEmpty)
        try await f.db.close()
    }

    func testRevokedCommandFencePreventsNativePublication() async throws {
        let f = try await Fixture.make(), original = try await f.read(), fence = NativeMutationFence()
        fence.invalidate()
        do { _ = try await f.db.mutateNativeAnnotations(expected: original, mutation: .addTag(name: "Revoked"), policy: f.policy, fences: [fence]); XCTFail("Revocation") }
        catch is CancellationError { }
        let current = try await f.read()
        XCTAssertEqual(current, original)
        try await f.db.close()
    }

    func testTagAndCommentCapacityOverflowRollBackEntireMutation() async throws {
        let f = try await Fixture.make()
        let connection = await f.db.getConnection(), db = try XCTUnwrap(connection)
        let first = try await f.read().segments[0].id.value
        for index in 0..<128 {
            try PipelineSQL.execute(db, "INSERT INTO tag(name) VALUES(?)", [.text("Tag \(index)")])
            let id = sqlite3_last_insert_rowid(db)
            try PipelineSQL.execute(db, "INSERT INTO segment_tag(segmentId,tagId) VALUES(?,?)", [.integer(first), .integer(id)])
        }
        var before = try await f.read()
        do { _ = try await f.apply(before, .addTag(name: "Overflow")); XCTFail("129th tag must roll back") }
        catch NativeAnnotationError.tooLarge { }
        var after = try await f.read()
        XCTAssertEqual(after, before)
        let overflow = try await f.db.getTag(name: "Overflow")
        XCTAssertNil(overflow, "The newly created catalog tag must roll back too")
        for index in 0..<64 { _ = try insertComment(db, body: "Comment \(index)", segments: [first]) }
        before = try await f.read()
        do { _ = try await f.apply(before, .createComment(body: "Overflow note", author: "Fixture", attachments: [], anchor: nil)); XCTFail("65th comment must roll back") }
        catch NativeAnnotationError.tooLarge { }
        after = try await f.read()
        XCTAssertEqual(after, before)
        XCTAssertTrue(after.segments[1].comments.isEmpty, "No partial link may remain on the other selected segment")
        try await f.db.close()
    }

    func testGlobalCommentLinkCapacityIncludesUnselectedSegments() async throws {
        let f = try await Fixture.make()
        let connection = await f.db.getConnection(), db = try XCTUnwrap(connection)
        let selected = try await f.read(), first = selected.segments[0].id.value
        var links = [first]
        for index in 0..<63 {
            let id = try await f.db.insertSegment(bundleID: "com.fixture.annotations", startDate: f.time.addingTimeInterval(Double(index + 20)),
                endDate: f.time.addingTimeInterval(Double(index + 20)), windowName: "Unselected authored target", browserUrl: nil, type: 0)
            links.append(id)
        }
        let id = try insertComment(db, body: "Shared at capacity", segments: links)
        let before = try await f.read()
        do { _ = try await f.apply(before, .linkComment(id: id)); XCTFail("Every existing link must be included in the affected scope") }
        catch NativeAnnotationError.notPermitted { }
        var after = try await f.read()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try PipelineSQL.integers(db, "SELECT count(*) FROM segment_comment_link WHERE commentId=?", [.integer(id.value)]), [64])

        // The post-result reader independently enforces global link bounds even
        // if a native trigger adds links during an otherwise admitted mutation.
        try PipelineSQL.execute(db, "DELETE FROM segment_comment_link WHERE commentId=? AND segmentId<>?", [.integer(id.value), .integer(first)])
        let admitted = try await f.read(), second = admitted.segments[1].id.value
        let extras = links.dropFirst().map(String.init).joined(separator: ",")
        try PipelineSQL.execute(db, """
            CREATE TEMP TRIGGER overflow_annotation_links AFTER INSERT ON segment_comment_link
            WHEN NEW.commentId=\(id.value) AND NEW.segmentId=\(second) BEGIN
              INSERT INTO segment_comment_link(commentId,segmentId)
              SELECT \(id.value),id FROM segment WHERE id IN (\(extras));
            END
            """)
        do { _ = try await f.apply(admitted, .linkComment(id: id)); XCTFail("65th post-mutation global link must roll back") }
        catch NativeAnnotationError.tooLarge { }
        after = try await f.read()
        XCTAssertEqual(after, admitted)
        XCTAssertEqual(try PipelineSQL.integers(db, "SELECT count(*) FROM segment_comment_link WHERE commentId=?", [.integer(id.value)]), [1])
        try await f.db.close()
    }

    func testAggregateFingerprintOverflowRollsBackCommentGrowth() async throws {
        let f = try await Fixture.make()
        let connection = await f.db.getConnection(), db = try XCTUnwrap(connection)
        let initial = try await f.read(), first = initial.segments[0].id.value
        // Each comment appears in both the public segment and retained fingerprint.
        // Seven maximum bodies fit; the eighth crosses the complete 256 KiB bound.
        for _ in 0..<7 { _ = try insertComment(db, body: String(repeating: "a", count: 16_384), segments: [first]) }
        let id = try insertComment(db, body: "Small", segments: [first])
        let before = try await f.read()
        do { _ = try await f.apply(before, .updateComment(id: id, body: String(repeating: "b", count: 16_384))); XCTFail("Aggregate result must remain readable") }
        catch NativeAnnotationError.tooLarge { }
        let after = try await f.read()
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.segments[0].comments.last?.body, "Small")
        try await f.db.close()
    }

    func testCommentReceiptsCountOnlyActuallyLinkedSelectedSegments() async throws {
        let f = try await Fixture.make()
        let first = try await f.db.nativeAnnotations(references: [f.refs[0]], policy: f.policy)
        let created = try await f.apply(first, .createComment(body: "Single link", author: "Fixture", attachments: [], anchor: nil))
        let id = try XCTUnwrap(created.commentID)
        var all = try await f.read()
        let updated = try await f.apply(all, .updateComment(id: id, body: "Edited"))
        XCTAssertEqual(updated.affectedSegments, 1)
        all = try await f.read()
        let preview = try await f.db.nativeAnnotationImpact(expected: all, mutation: .deleteComment(id: id), policy: f.policy)
        let deleted = try await f.apply(all, .deleteComment(id: id))
        XCTAssertEqual(preview, 1); XCTAssertEqual(deleted.affectedSegments, preview)
        try await f.db.close()
    }

    func testIndependentConnectionABAAndReopenInvalidateOldSelections() async throws {
        // Bundled SQLCipher defines SQLITE_OMIT_SHARED_CACHE, so named memory
        // URIs cannot exercise an independent writer. Use a private real file
        // without consulting live encryption preferences or Keychain instead.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-reopen-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("native.db").path
        let f = try await Fixture.make(unencryptedFile: path), original = try await f.read()
        var external: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &external, SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        let other = try XCTUnwrap(external)
        defer { sqlite3_close(other) }
        // The independent writer has no connection-local TEMP epoch triggers.
        // Two commits restore identical payload while main.data_version advances.
        try PipelineSQL.execute(other, "INSERT INTO tag(name) VALUES('External temporary')")
        try PipelineSQL.execute(other, "DELETE FROM tag WHERE name='External temporary'")
        let afterExternal = try await f.read()
        XCTAssertEqual(afterExternal.fingerprint, original.fingerprint)
        XCTAssertNotEqual(afterExternal.revision.externalVersion, original.revision.externalVersion)
        do { _ = try await f.apply(original, .addTag(name: "Stale external")); XCTFail("Independent writer ABA") }
        catch NativeAnnotationError.staleSelection { }
        try await f.db.close()
        let reopened = DatabaseManager(testingUnencryptedDatabasePath: path)
        try await reopened.initialize()
        let current = try await reopened.nativeAnnotations(references: f.refs, policy: f.policy)
        XCTAssertEqual(current.nativeStoreID, original.nativeStoreID)
        XCTAssertNotEqual(current.revision.connectionID, afterExternal.revision.connectionID)
        do {
            _ = try await reopened.mutateNativeAnnotations(expected: afterExternal, mutation: .addTag(name: "Stale reopened"), policy: f.policy, fences: [NativeMutationFence()])
            XCTFail("Reopen must reject old process-local selection")
        } catch NativeAnnotationError.staleSelection { }
        try await reopened.close()
    }

    func testExpiryDuringMutationRollsBackRowsAndRevisionBeforeCommit() async throws {
        let f = try await Fixture.make(), original = try await f.read()
        let now = Date(timeIntervalSince1970: 1_800_000_000), clock = AnnotationExpiryClock(now)
        let fence = NativeMutationFence(expiresAt: now.addingTimeInterval(1), clock: { clock.now() })
        let connection = await f.db.getConnection(), db = try XCTUnwrap(connection)
        let context = Unmanaged.passRetained(clock).toOpaque()
        XCTAssertEqual(sqlite3_create_function_v2(db, "advance_annotation_clock", 0, SQLITE_UTF8,
            context, { context, _, _ in
                guard let context, let stored = sqlite3_user_data(context) else { return }
                Unmanaged<AnnotationExpiryClock>.fromOpaque(stored).takeUnretainedValue().advance()
                sqlite3_result_int(context, 1)
            }, nil, nil, { context in
                if let context { Unmanaged<AnnotationExpiryClock>.fromOpaque(context).release() }
            }), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TEMP TRIGGER expire_annotation AFTER INSERT ON tag BEGIN SELECT advance_annotation_clock(); END", nil, nil, nil), SQLITE_OK)
        do {
            _ = try await f.db.mutateNativeAnnotations(expected: original, mutation: .addTag(name: "Expired"), policy: f.policy, fences: [fence])
            XCTFail("Publication crossed deadline")
        } catch is CancellationError { }
        XCTAssertEqual(clock.now(), now.addingTimeInterval(2))
        let after = try await f.read(), tag = try await f.db.getTag(name: "Expired")
        XCTAssertEqual(after, original); XCTAssertNil(tag)
        try await f.db.close()
    }

    private func insertComment(_ db: OpaquePointer, body: String, segments: [Int64]) throws -> SegmentCommentID {
        try PipelineSQL.execute(db, "INSERT INTO segment_comment(body,author,attachmentsJson,createdAt,updatedAt) VALUES(?,'Fixture','[]',1,1)", [.text(body)])
        let id = sqlite3_last_insert_rowid(db)
        for segment in segments {
            try PipelineSQL.execute(db, "INSERT INTO segment_comment_link(commentId,segmentId) VALUES(?,?)", [.integer(id), .integer(segment)])
        }
        return .init(value: id)
    }
}

private struct Fixture {
    let db: DatabaseManager, refs: [ScreenEvidenceRef], time: Date
    var policy: ScreenEvidenceAccessPolicy { .init(config: Shared.CaptureConfig()) }
    static func make(unencryptedFile path: String? = nil) async throws -> Self {
        let db: DatabaseManager
        if let path { db = DatabaseManager(testingUnencryptedDatabasePath: path) }
        else { db = DatabaseManager(databasePath: "file:annotation_\(UUID())?mode=memory&cache=private") }
        try await db.initialize()
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try await insert(db, time: time), b = try await insert(db, time: time.addingTimeInterval(5))
        return .init(db: db, refs: [a,b], time: time)
    }
    static func insert(_ db: DatabaseManager, time: Date) async throws -> ScreenEvidenceRef {
        let segment = try await db.insertSegment(bundleID: "com.fixture.annotations", startDate: time, endDate: time,
            windowName: "Authored annotation target", browserUrl: nil, type: 0)
        let frame = FrameID(value: try await db.insertFrame(.init(id: .init(value: 0), timestamp: time,
            segmentID: .init(value: segment), frameIndexInSegment: 0,
            metadata: .init(appBundleID: "com.fixture.annotations", windowName: "Authored annotation target"))))
        _ = try await db.commitFrameOCR(frameID: frame, text: .init(frameID: frame, timestamp: time, regions: [], fullText: "Authored text"), frameWidth: 100, frameHeight: 100)
        let store = try await db.activityStoreID(), current = try await db.currentScreenEvidence(frameID: frame, storeID: store)
        return try XCTUnwrap(current).ref
    }
    func read() async throws -> NativeAnnotationSnapshot { try await db.nativeAnnotations(references: refs, policy: policy) }
    func apply(_ expected: NativeAnnotationSnapshot, _ mutation: NativeAnnotationMutation) async throws -> NativeAnnotationReceipt {
        try await db.mutateNativeAnnotations(expected: expected, mutation: mutation, policy: policy, fences: [NativeMutationFence()])
    }
}

private final class AnnotationExpiryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); value = value.addingTimeInterval(2); lock.unlock() }
}
