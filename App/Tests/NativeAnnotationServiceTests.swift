import Foundation
import Database
import Shared
import XCTest
@testable import App

final class NativeAnnotationServiceTests: XCTestCase {
    func testLocalAndMCPUseSameRecordsAndRetriesSurviveDispatcherRestart() async throws {
        let f = try await AnnotationFixture.make()
        let local = try await f.owner.read(references: [f.reference])
        _ = try await f.owner.apply(snapshot: local, mutation: .createComment(body: "Authored local note", author: "Fixture", attachments: [], anchor: f.reference.frameID))
        let dispatcher = try f.dispatcher()
        let read = await dispatcher.execute(try f.readRequest(.commentsRead), bearerToken: f.token)
        XCTAssertEqual(read.status, .succeeded)
        XCTAssertTrue(String(decoding: try RetraceWire.encoder().encode(read), as: UTF8.self).contains("Authored local note"))
        let selected = try XCTUnwrap(read.data).decode(AnnotationSelectionEnvelope.self)
        let request = RetraceCommandRequest(requestID: UUID(), operation: .tagsWrite, arguments: selected.arguments(action: "add", text: "Remember"))
        let first = await dispatcher.execute(request, bearerToken: f.token)
        XCTAssertEqual(first.status, .succeeded)
        await dispatcher.close()
        let reopened = try f.dispatcher()
        let replay = await reopened.execute(request, bearerToken: f.token)
        XCTAssertEqual(replay.status, .succeeded); XCTAssertTrue(replay.replayed); XCTAssertEqual(replay.data, first.data)
        let current = try await f.owner.read(references: [f.reference])
        XCTAssertEqual(current.segments.first?.tags.map(\.name), ["Remember"])
        await reopened.close(); try await f.close()
    }

    func testDeletionRequiresCurrentPreviewAndDoesNotRetainCommentContent() async throws {
        let f = try await AnnotationFixture.make()
        let local = try await f.owner.read(references: [f.reference])
        let receipt = try await f.owner.apply(snapshot: local, mutation: .createComment(body: "Sensitive authored note", author: "Fixture", attachments: [], anchor: nil))
        let id = try XCTUnwrap(receipt.commentID), dispatcher = try f.dispatcher()
        let read = await dispatcher.execute(try f.readRequest(.commentsRead), bearerToken: f.token)
        let selected = try XCTUnwrap(read.data).decode(AnnotationSelectionEnvelope.self)
        let arguments = selected.arguments(action: "delete", id: id.value)
        let refused = await dispatcher.execute(.init(requestID: UUID(), operation: .commentsRemove, arguments: arguments), bearerToken: f.token)
        XCTAssertEqual(refused.code, "preview_required")
        let previewRequest = RetraceCommandRequest(requestID: UUID(), operation: .commentsRemove, arguments: arguments, mode: .preview)
        let preview = await dispatcher.execute(previewRequest, bearerToken: f.token)
        let proof = try XCTUnwrap(preview.preview)
        XCTAssertFalse(proof.summary.contains("Sensitive authored note"))
        let confirmed = await dispatcher.execute(.init(requestID: UUID(), operation: .commentsRemove, arguments: arguments,
            confirmation: .init(previewID: proof.id, digest: proof.digest)), bearerToken: f.token)
        XCTAssertEqual(confirmed.status, .succeeded)
        let repeated = await dispatcher.execute(previewRequest, bearerToken: f.token)
        XCTAssertTrue(repeated.replayed)
        XCTAssertFalse(String(decoding: try RetraceWire.encoder().encode(repeated), as: UTF8.self).contains("Sensitive authored note"))
        let current = try await f.owner.read(references: [f.reference])
        XCTAssertTrue(current.segments[0].comments.isEmpty)
        await dispatcher.close(); try await f.close()
    }

    func testStalePreviewAndCrossClientSelectionsAreRejected() async throws {
        let f = try await AnnotationFixture.make()
        let initial = try await f.owner.read(references: [f.reference])
        let receipt = try await f.owner.apply(snapshot: initial, mutation: .addTag(name: "Original"))
        let id = try XCTUnwrap(receipt.tagID), dispatcher = try f.dispatcher(secondClient: true)
        let read = await dispatcher.execute(try f.readRequest(.tagsRead), bearerToken: f.token)
        let selected = try XCTUnwrap(read.data).decode(AnnotationSelectionEnvelope.self)
        let args = selected.arguments(action: "unlink", id: id.value)
        let wrong = await dispatcher.execute(.init(requestID: UUID(), operation: .tagsRemove, arguments: args, mode: .preview), bearerToken: f.otherToken)
        XCTAssertEqual(wrong.status, .conflict)
        let preview = await dispatcher.execute(.init(requestID: UUID(), operation: .tagsRemove, arguments: args, mode: .preview), bearerToken: f.token)
        let proof = try XCTUnwrap(preview.preview)
        let changed = try await f.owner.read(references: [f.reference])
        _ = try await f.owner.apply(snapshot: changed, mutation: .addTag(name: "Concurrent"))
        let stale = await dispatcher.execute(.init(requestID: UUID(), operation: .tagsRemove, arguments: args,
            confirmation: .init(previewID: proof.id, digest: proof.digest)), bearerToken: f.token)
        XCTAssertEqual(stale.status, .conflict)
        let current = try await f.owner.read(references: [f.reference])
        XCTAssertTrue(current.segments[0].tags.contains(where: { $0.id == id }))
        await dispatcher.close(); try await f.close()
    }

    func testRevocationDuringHeldReadDisclosesNothingAndPolicyInvalidationRejectsWrite() async throws {
        let f = try await AnnotationFixture.make(), gate = AnnotationGate()
        let state = NativeCaptureState(config: Shared.CaptureConfig(), revision: UUID())
        let owner = NativeAnnotationService(database: f.database, captureState: { await gate.wait(); return state })
        let dispatcher = try RetraceCommandDispatcher(directory: f.directory,
            grants: [f.grant], handlers: RetraceAnnotationCommands.handlers(owner: { owner }))
        let request = try f.readRequest(.commentsRead)
        let read = Task { await dispatcher.execute(request, bearerToken: f.token) }
        try await gate.entered()
        try await dispatcher.replaceGrants([])
        await gate.release()
        let rejected = await read.value
        XCTAssertEqual(rejected.status, .denied); XCTAssertNil(rejected.data)
        await dispatcher.close(); await owner.close()
        let snapshot = try await f.owner.read(references: [f.reference]), writeGate = AnnotationGate()
        let heldOwner = NativeAnnotationService(database: f.database, captureState: { await writeGate.wait(); return state })
        let write = Task { try await heldOwner.apply(snapshot: snapshot, mutation: .addTag(name: "Revoked policy")) }
        try await writeGate.entered(); heldOwner.invalidate(); await writeGate.release()
        do { _ = try await write.value; XCTFail("Revoked policy must reject publication") } catch is CancellationError { }
        let unchanged = try await f.owner.read(references: [f.reference])
        XCTAssertEqual(unchanged, snapshot)
        await heldOwner.close(); try await f.close()
    }

    func testSuccessfulMutationJoinsOutputDrainAndTerminalClose() async throws {
        let f = try await AnnotationFixture.make(), gate = AnnotationGate()
        let state = NativeCaptureState(config: Shared.CaptureConfig(), revision: UUID())
        let owner = NativeAnnotationService(database: f.database, captureState: { state }, drainOutput: { await gate.wait() })
        let snapshot = try await owner.read(references: [f.reference])
        let pending = Task { try await owner.apply(snapshot: snapshot, mutation: .addTag(name: "Committed")) }
        try await gate.entered()
        let current = try await f.owner.read(references: [f.reference])
        XCTAssertEqual(current.segments[0].tags.map(\.name), ["Committed"])
        let closed = AnnotationCompletion()
        let close = Task { await owner.close(); await closed.mark() }
        await Task.yield()
        let prematurelyClosed = await closed.finished
        XCTAssertFalse(prematurelyClosed)
        await gate.release(); _ = try await pending.value; await close.value
        do { _ = try await owner.read(references: [f.reference]); XCTFail("Terminal close") } catch NativeAnnotationError.closed { }
        try await f.close()
    }

    func testMCPSelectionExpiryDuringHeldWritePreventsPublication() async throws {
        let f = try await AnnotationFixture.make(), gate = AnnotationGate(enabled: false)
        let clock = AnnotationCommandClock(Date(timeIntervalSince1970: 1_800_000_000))
        let state = NativeCaptureState(config: Shared.CaptureConfig(), revision: UUID())
        let owner = NativeAnnotationService(database: f.database, captureState: { await gate.wait(); return state })
        let dispatcher = try RetraceCommandDispatcher(directory: f.directory, grants: [f.grant],
            handlers: RetraceAnnotationCommands.handlers(owner: { owner }, clock: { clock.now() }))
        let read = await dispatcher.execute(try f.readRequest(.tagsRead), bearerToken: f.token)
        let selected = try XCTUnwrap(read.data).decode(AnnotationSelectionEnvelope.self)
        let request = RetraceCommandRequest(requestID: UUID(), operation: .tagsWrite,
            arguments: selected.arguments(action: "add", text: "Expired selection"))
        await gate.arm()
        let pending = Task { await dispatcher.execute(request, bearerToken: f.token) }
        try await gate.entered()
        clock.advance()
        await gate.release()
        let result = await pending.value
        XCTAssertNotEqual(result.status, .succeeded)
        let current = try await f.owner.read(references: [f.reference])
        XCTAssertTrue(current.segments[0].tags.isEmpty)
        let replay = await dispatcher.execute(request, bearerToken: f.token)
        XCTAssertEqual(replay.status, .indeterminate)
        XCTAssertEqual(replay.code, "reserved_outcome_unknown")
        await dispatcher.close(); await owner.close(); try await f.close()
    }
}

private struct AnnotationSelectionEnvelope: Decodable {
    let selectionID: UUID, expectedRevision: UUID
    func arguments(action: String, text: String? = nil, id: Int64? = nil) -> RetraceJSON {
        var fields: [String: RetraceJSON] = ["selectionID": .string(selectionID.uuidString), "expectedRevision": .string(expectedRevision.uuidString), "action": .string(action)]
        if let text { fields["text"] = .string(text) }; if let id { fields["id"] = .integer(id) }
        return .object(fields)
    }
}
private struct AnnotationFixture: Sendable {
    let database: DatabaseManager, owner: NativeAnnotationService, reference: ScreenEvidenceRef, directory: URL
    let token = "annotation-authored-client-token-at-least-thirty-two-characters"
    let otherToken = "annotation-second-client-token-at-least-thirty-two-characters"
    var grant: RetraceClientGrant { .init(clientID: "fixture", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.annotationsRead, .annotationsWrite]) }
    static func make() async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let db = DatabaseManager(databasePath: "file:annotation_service_\(UUID())?mode=memory&cache=private")
        try await db.initialize()
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let segment = try await db.insertSegment(bundleID: "com.fixture.annotations", startDate: time, endDate: time, windowName: "Authored", browserUrl: nil, type: 0)
        let frame = FrameID(value: try await db.insertFrame(.init(id: .init(value: 0), timestamp: time, segmentID: .init(value: segment), frameIndexInSegment: 0,
            metadata: .init(appBundleID: "com.fixture.annotations", windowName: "Authored"))))
        _ = try await db.commitFrameOCR(frameID: frame, text: .init(frameID: frame, timestamp: time, regions: [], fullText: "Authored"), frameWidth: 100, frameHeight: 100)
        let store = try await db.activityStoreID(), current = try await db.currentScreenEvidence(frameID: frame, storeID: store)
        let state = NativeCaptureState(config: Shared.CaptureConfig(), revision: UUID())
        return .init(database: db, owner: NativeAnnotationService(database: db, captureState: { state }), reference: try XCTUnwrap(current).ref, directory: directory)
    }
    func readRequest(_ operation: RetraceOperation) throws -> RetraceCommandRequest {
        .init(requestID: UUID(), operation: operation, arguments: .object(["references": try .encode([reference])]))
    }
    func dispatcher(secondClient: Bool = false) throws -> RetraceCommandDispatcher {
        let grants = [grant] + (secondClient ? [.init(clientID: "other", tokenSHA256: RetraceCommandDispatcher.tokenDigest(otherToken), capabilities: [.annotationsRead, .annotationsWrite])] : [])
        return try .init(directory: directory, grants: grants, handlers: RetraceAnnotationCommands.handlers(owner: { owner }))
    }
    func close() async throws { await owner.close(); try await database.close(); try FileManager.default.removeItem(at: directory) }
}
private actor AnnotationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var enabled: Bool
    init(enabled: Bool = true) { self.enabled = enabled }
    func arm() { enabled = true }
    func wait() async { if enabled && !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
    func entered() async throws {
        for _ in 0..<200 { if continuation != nil { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw NativeAnnotationError.unavailable
    }
}
private actor AnnotationCompletion { var finished = false; func mark() { finished = true } }
private final class AnnotationCommandClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); value = value.addingTimeInterval(121); lock.unlock() }
}
