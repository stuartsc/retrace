import Database
import Foundation
import Shared
import XCTest
@testable import App

final class RetraceRetentionCommandsTests: XCTestCase {
    func testQueuedJobCannotConsumeReplacementPreviewForTheSameCutoff() async throws {
        let firstID = UUID(), secondID = UUID(), firstGate = RetentionMCPGate(), secondGate = RetentionMCPGate()
        let fixture = try await RetentionMCPFixture.make(beforeApply: { context in
            if context.requestID == firstID { await firstGate.wait() }
            if context.requestID == secondID { await secondGate.wait() }
        })
        let firstOffer = await fixture.dispatcher.execute(fixture.previewRequest(), bearerToken: fixture.token)
        let secondOffer = await fixture.dispatcher.execute(fixture.previewRequest(), bearerToken: fixture.token)
        let firstProof = try XCTUnwrap(firstOffer.preview), secondProof = try XCTUnwrap(secondOffer.preview)
        let original = try XCTUnwrap(firstProof.details).decode(RetentionCommandPreview.self)
        let sameSelection = try XCTUnwrap(secondProof.details).decode(RetentionCommandPreview.self)
        XCTAssertEqual(original.id, sameSelection.id)
        let first = await fixture.dispatcher.execute(.init(requestID: firstID, operation: .retention,
            arguments: fixture.arguments, confirmation: .init(previewID: firstProof.id, digest: firstProof.digest)), bearerToken: fixture.token)
        let firstJob = try XCTUnwrap(first.data).decode(RetraceCommandJob.self)
        try await firstGate.waitForEntry()
        let second = await fixture.dispatcher.execute(.init(requestID: secondID, operation: .retention,
            arguments: fixture.arguments, confirmation: .init(previewID: secondProof.id, digest: secondProof.digest)), bearerToken: fixture.token)
        let secondJob = try XCTUnwrap(second.data).decode(RetraceCommandJob.self)
        try await secondGate.waitForEntry()
        await firstGate.release()
        let firstOutcome = try await fixture.finishedJob(firstJob.id)
        XCTAssertEqual(firstOutcome.retentionOutcome?.previewID, original.id)

        let replacementFrame = try await fixture.addFrame(path: "chunks/newly-discovered")
        let replacementOffer = await fixture.dispatcher.execute(fixture.previewRequest(), bearerToken: fixture.token)
        let replacementProof = try XCTUnwrap(replacementOffer.preview)
        let replacement = try XCTUnwrap(replacementProof.details).decode(RetentionCommandPreview.self)
        XCTAssertNotEqual(replacement.id, original.id)
        XCTAssertEqual(replacement.frames, 1)
        await secondGate.release()
        let staleOutcome = try await fixture.finishedJob(secondJob.id)
        XCTAssertEqual(staleOutcome.state, .failed)
        XCTAssertNil(staleOutcome.retentionOutcome)
        let stillPresent = try await fixture.database.getFrame(id: .init(value: replacementFrame))
        XCTAssertNotNil(stillPresent, "The old proof must never authorize a newly cached selection")

        // The rejected old job must also leave the replacement's own proof usable.
        let accepted = await fixture.dispatcher.execute(.init(requestID: UUID(), operation: .retention,
            arguments: fixture.arguments, confirmation: .init(previewID: replacementProof.id, digest: replacementProof.digest)), bearerToken: fixture.token)
        let replacementJob = try XCTUnwrap(accepted.data).decode(RetraceCommandJob.self)
        let replacementOutcome = try await fixture.finishedJob(replacementJob.id)
        XCTAssertEqual(replacementOutcome.retentionOutcome?.previewID, replacement.id)
        XCTAssertEqual(replacementOutcome.retentionOutcome?.deletedFrames, 1)
        try await fixture.close()
    }

    func testConfirmedJobRetainsCommittedCountsAfterCancelAndDurableReplay() async throws {
        let gate = RetentionMCPGate(), fixture = try await RetentionMCPFixture.make(drain: { await gate.wait() })
        let offered = await fixture.dispatcher.execute(fixture.previewRequest(), bearerToken: fixture.token)
        let proof = try XCTUnwrap(offered.preview)
        let details = try XCTUnwrap(proof.details).decode(RetentionCommandPreview.self)
        XCTAssertEqual(details.frames, 1); XCTAssertEqual(details.scannedFrames, 1)
        XCTAssertTrue(details.retainsAudio); XCTAssertTrue(details.fileDeletionDeferred)
        let originalFrame = try await fixture.database.getFrame(id: .init(value: fixture.frame))
        XCTAssertNotNil(originalFrame, "A preview cannot delete history")
        let command = RetraceCommandRequest(requestID: UUID(), operation: .retention, arguments: fixture.arguments,
            confirmation: .init(previewID: proof.id, digest: proof.digest))
        let started = await fixture.dispatcher.execute(command, bearerToken: fixture.token)
        XCTAssertEqual(started.status, .succeeded, "Confirmation must reuse the original writer selection")
        let job = try XCTUnwrap(started.data).decode(RetraceCommandJob.self)
        try await gate.waitForEntry()
        let afterCommit = try await fixture.database.getFrame(id: .init(value: fixture.frame))
        XCTAssertNil(afterCommit)
        let reading = await fixture.dispatcher.execute(.init(requestID: UUID(), operation: .jobRead,
            arguments: .object(["id": .string(job.id.uuidString)])), bearerToken: fixture.token)
        let progress = try XCTUnwrap(reading.data).decode(RetraceCommandJob.self)
        XCTAssertEqual(progress.retentionPhase, .drainingOutput)
        XCTAssertNil(progress.repairPhase)
        let cancelling = Task {
            await fixture.dispatcher.execute(.init(requestID: UUID(), operation: .jobCancel,
                arguments: .object(["id": .string(job.id.uuidString)])), bearerToken: fixture.token)
        }
        try await gate.waitForCancellation()
        await gate.release()
        let cancelled = await cancelling.value
        let completed = try XCTUnwrap(cancelled.data).decode(RetraceCommandJob.self)
        XCTAssertEqual(completed.state, .succeeded, "Cancellation cannot undo committed screen deletion")
        XCTAssertEqual(completed.retentionOutcome?.deletedFrames, 1)
        XCTAssertEqual(completed.retentionOutcome?.previewID, details.id)
        XCTAssertTrue(completed.effectsMayBePartial)
        XCTAssertNil(completed.repairOutcome)
        await fixture.dispatcher.close()
        let reopened = try fixture.makeDispatcher()
        let retry = await reopened.execute(command, bearerToken: fixture.token)
        XCTAssertTrue(retry.replayed)
        let replayedJob = try XCTUnwrap(retry.data).decode(RetraceCommandJob.self)
        XCTAssertEqual(replayedJob.id, job.id)
        let persisted = await reopened.execute(.init(requestID: UUID(), operation: .jobRead,
            arguments: .object(["id": .string(job.id.uuidString)])), bearerToken: fixture.token)
        let retained = try XCTUnwrap(persisted.data).decode(RetraceCommandJob.self)
        XCTAssertEqual(retained.retentionOutcome, completed.retentionOutcome)
        await reopened.close(); try await fixture.close()
    }

    func testRevokedPreviewAndUnprivilegedClientCannotDelete() async throws {
        let fixture = try await RetentionMCPFixture.make()
        let offered = await fixture.dispatcher.execute(fixture.previewRequest(), bearerToken: fixture.token)
        let preview = try XCTUnwrap(offered.preview)
        fixture.owner.invalidate()
        let refused = await fixture.dispatcher.execute(.init(requestID: UUID(), operation: .retention,
            arguments: fixture.arguments, confirmation: .init(previewID: preview.id, digest: preview.digest)), bearerToken: fixture.token)
        XCTAssertEqual(refused.status, .conflict)
        let denied = await fixture.dispatcher.execute(fixture.previewRequest(), bearerToken: "unauthorized-client-token-at-least-32-characters")
        XCTAssertEqual(denied.status, .denied)
        let frame = try await fixture.database.getFrame(id: .init(value: fixture.frame))
        XCTAssertNotNil(frame)
        try await fixture.close()
    }

    func testNextPageOnlyDiscoversAndSupersedesPreviousConfirmation() async throws {
        let fixture = try await RetentionMCPFixture.make()
        for index in 0..<100 { try await fixture.addVideo(path: "chunks/later-\(index)") }
        let first = await fixture.dispatcher.execute(fixture.previewRequest(), bearerToken: fixture.token)
        let firstProof = try XCTUnwrap(first.preview)
        let firstPage = try XCTUnwrap(firstProof.details).decode(RetentionCommandPreview.self)
        let continuation = try XCTUnwrap(firstPage.nextContinuationID)
        let nextArguments = RetraceJSON.object(["cutoff": .number(fixture.cutoff.timeIntervalSince1970 * 1000),
                                               "continuationID": .string(continuation.uuidString)])
        let next = await fixture.dispatcher.execute(.init(requestID: UUID(), operation: .retention,
            arguments: nextArguments, mode: .preview), bearerToken: fixture.token)
        let nextProof = try XCTUnwrap(next.preview)
        let nextPage = try XCTUnwrap(nextProof.details).decode(RetentionCommandPreview.self)
        XCTAssertNotEqual(nextPage.id, firstPage.id)
        XCTAssertEqual(nextPage.scannedVideos, 1)
        let stale = await fixture.dispatcher.execute(.init(requestID: UUID(), operation: .retention,
            arguments: fixture.arguments, confirmation: .init(previewID: firstProof.id, digest: firstProof.digest)), bearerToken: fixture.token)
        XCTAssertEqual(stale.status, .conflict)
        let frame = try await fixture.database.getFrame(id: .init(value: fixture.frame))
        XCTAssertNotNil(frame, "Following a continuation is never confirmation")
        try await fixture.close()
    }
}

private struct RetentionMCPFixture {
    let root: URL
    let database: DatabaseManager
    let owner: RetentionCommandService
    let dispatcher: RetraceCommandDispatcher
    let cutoff: Date
    let frame: Int64
    let token = "retention-test-token-at-least-32-characters"
    var arguments: RetraceJSON { .object(["cutoff": .number(cutoff.timeIntervalSince1970 * 1000)]) }
    func previewRequest() -> RetraceCommandRequest { .init(requestID: UUID(), operation: .retention, arguments: arguments, mode: .preview) }
    static func make(drain: @escaping @Sendable () async -> Void = {},
                     beforeApply: @escaping @Sendable (RetraceCommandContext) async -> Void = { _ in }) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RetentionMCP-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("commands"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chunks"), withIntermediateDirectories: false)
        let database = DatabaseManager(databasePath: "file:retention_mcp_\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let cutoff = Date(timeIntervalSince1970: 1_780_000_000), time = cutoff.addingTimeInterval(-10)
        let video = try await database.insertVideoSegment(.init(id: .init(value: 0), startTime: time, endTime: time,
            frameCount: 1, fileSizeBytes: 3, relativePath: "chunks/authored", width: 64, height: 64))
        try await database.markVideoFinalized(id: video, frameCount: 1, fileSize: 3)
        let segment = try await database.insertSegment(bundleID: "com.authored.retention", startDate: time, endDate: time,
            windowName: "Authored", browserUrl: nil, type: 0)
        let frame = try await database.insertFrame(.init(id: .init(value: 0), timestamp: time, segmentID: .init(value: segment),
            videoID: .init(value: video), frameIndexInSegment: 0, metadata: .init(appBundleID: "com.authored.retention")))
        let state = NativeCaptureState(config: Shared.CaptureConfig(), revision: UUID())
        let owner = RetentionCommandService(database: database, captureState: { state }, retentionPolicy: { .init() },
            storageRoot: { root }, drainOutput: drain)
        let handler = try XCTUnwrap(RetraceRetentionCommands.handlers(owner: { owner }).first)
        let heldHandler = RetraceCommandHandler(operation: .retention, runsAsJob: true, preview: handler.preview) { context in
            await beforeApply(context)
            return try await handler.execute(context)
        }
        let dispatcher = try RetraceCommandDispatcher(directory: root.appendingPathComponent("commands"),
            grants: [.init(clientID: "retention-client", tokenSHA256: RetraceCommandDispatcher.tokenDigest("retention-test-token-at-least-32-characters"), capabilities: [.maintenance])],
            handlers: [heldHandler])
        return .init(root: root, database: database, owner: owner, dispatcher: dispatcher, cutoff: cutoff, frame: frame)
    }
    func makeDispatcher() throws -> RetraceCommandDispatcher {
        try .init(directory: root.appendingPathComponent("commands"),
            grants: [.init(clientID: "retention-client", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.maintenance])],
            handlers: RetraceRetentionCommands.handlers(owner: { owner }))
    }
    func addVideo(path: String) async throws {
        let time = cutoff.addingTimeInterval(-10)
        let video = try await database.insertVideoSegment(.init(id: .init(value: 0), startTime: time, endTime: time,
            frameCount: 1, fileSizeBytes: 3, relativePath: path, width: 64, height: 64))
        try await database.markVideoFinalized(id: video, frameCount: 1, fileSize: 3)
    }
    func addFrame(path: String) async throws -> Int64 {
        let time = cutoff.addingTimeInterval(-5)
        let video = try await database.insertVideoSegment(.init(id: .init(value: 0), startTime: time, endTime: time,
            frameCount: 1, fileSizeBytes: 3, relativePath: path, width: 64, height: 64))
        try await database.markVideoFinalized(id: video, frameCount: 1, fileSize: 3)
        let segment = try await database.insertSegment(bundleID: "com.authored.retention", startDate: time, endDate: time,
            windowName: "New authored history", browserUrl: nil, type: 0)
        return try await database.insertFrame(.init(id: .init(value: 0), timestamp: time, segmentID: .init(value: segment),
            videoID: .init(value: video), frameIndexInSegment: 0, metadata: .init(appBundleID: "com.authored.retention")))
    }
    func finishedJob(_ id: UUID) async throws -> RetraceCommandJob {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let response = await dispatcher.execute(.init(requestID: UUID(), operation: .jobRead,
                arguments: .object(["id": .string(id.uuidString)])), bearerToken: token)
            let job = try XCTUnwrap(response.data).decode(RetraceCommandJob.self)
            if job.state != .running { return job }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RetentionCommandError.unavailable
    }
    func close() async throws {
        await dispatcher.close(); await owner.close(); try await database.close()
        try FileManager.default.removeItem(at: root)
    }
}

private final class RetentionCancellationProbe: @unchecked Sendable {
    private let lock = NSLock(); private var cancelled = false
    func mark() { lock.lock(); cancelled = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
private actor RetentionMCPGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var released = false
    private let cancellation = RetentionCancellationProbe()
    func wait() async {
        guard !released else { return }
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: { [cancellation] in cancellation.mark() }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
    func waitForEntry() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard entered else { throw RetentionCommandError.unavailable }
    }
    func waitForCancellation() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !cancellation.value, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard cancellation.value else { throw RetentionCommandError.unavailable }
    }
}
