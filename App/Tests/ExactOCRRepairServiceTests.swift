import Foundation
import Shared
import Database
import XCTest
@testable import App

final class ExactOCRRepairServiceTests: XCTestCase {
    func testCoalescedRequestUsesOneFullExtractionAndReturnsCommittedReference() async throws {
        let fixture = try await RepairFixture.make(), id = UUID()
        let first = Task { try await fixture.owner.repair(reference: fixture.reference, requestID: id) }
        try await fixture.processing.waitUntilEntered()
        let second = Task { try await fixture.owner.repair(reference: fixture.reference, requestID: id) }
        await fixture.processing.release()
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a, b)
        let calls = await fixture.processing.calls, released = await fixture.governor.releases
        XCTAssertEqual(calls, 1); XCTAssertEqual(released, 1)
        let text = try await fixture.database.screenEvidence(a.reference)
        XCTAssertEqual(text?.text?.fullText, "Fresh repair")
        await fixture.owner.close(); try await fixture.database.close()
    }

    func testCancellationWaitsForNativeWorkAndPreservesPriorText() async throws {
        let fixture = try await RepairFixture.make()
        let task = Task { try await fixture.owner.repair(reference: fixture.reference, requestID: UUID()) }
        try await fixture.processing.waitUntilEntered()
        task.cancel()
        let releasesWhileHeld = await fixture.governor.releases
        XCTAssertEqual(releasesWhileHeld, 0, "Native work must remain owned until it returns")
        await fixture.processing.release()
        do { _ = try await task.value; XCTFail("Cancelled work must not publish") } catch is CancellationError { }
        try await fixture.assertOriginal()
        let released = await fixture.governor.releases
        XCTAssertEqual(released, 1)
        await fixture.owner.close(); try await fixture.database.close()
    }

    func testPolicyAndCommandRevocationDuringOCRPreventPublication() async throws {
        for policyChange in [false, true] {
            let fixture = try await RepairFixture.make(), fence = NativeMutationFence()
            let task = Task { try await fixture.owner.repair(reference: fixture.reference,
                requestID: UUID(), commandFence: fence) }
            try await fixture.processing.waitUntilEntered()
            if policyChange { fixture.owner.invalidate() } else { fence.invalidate() }
            await fixture.processing.release()
            do { _ = try await task.value; XCTFail("Revoked work must not publish") } catch is CancellationError { }
            try await fixture.assertOriginal()
            await fixture.owner.close(); try await fixture.database.close()
        }
    }

    func testSourceChangedDuringOCRRejectsReplacement() async throws {
        let fixture = try await RepairFixture.make()
        let task = Task { try await fixture.owner.repair(reference: fixture.reference, requestID: UUID()) }
        try await fixture.processing.waitUntilEntered()
        _ = try await fixture.database.commitFrameOCR(frameID: fixture.reference.frameID,
            text: .init(frameID: fixture.reference.frameID, timestamp: fixture.time, regions: [], fullText: "Newer native writer"),
            frameWidth: 100, frameHeight: 100)
        await fixture.processing.release()
        do { _ = try await task.value; XCTFail("Stale extraction must not overwrite newer text") }
        catch ExactOCRRepairError.staleTarget { }
        let current = try await fixture.database.currentScreenEvidence(frameID: fixture.reference.frameID, storeID: fixture.reference.storeID)
        XCTAssertEqual(current?.text?.fullText, "Newer native writer")
        await fixture.owner.close(); try await fixture.database.close()
    }

    func testMCPJobTracksRecognitionAndJoinedCancellationAndDoesNotRepeatRequest() async throws {
        let fixture = try await RepairFixture.make()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = "exact-repair-client-32-characters-minimum-length"
        let dispatcher = try RetraceCommandDispatcher(directory: directory,
            grants: [.init(clientID: "repair", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.processing])],
            handlers: [.init(operation: .processingRepair, runsAsJob: true) { context in
                let result = try await fixture.owner.repair(reference: fixture.reference, requestID: context.requestID,
                    clientID: context.clientID, commandFence: context.mutationFence,
                    progress: { await context.reportProgress($0) })
                return try .encode(result)
            }])
        let request = RetraceCommandRequest(requestID: UUID(), operation: .processingRepair)
        let submitted = await dispatcher.execute(request, bearerToken: token)
        let job = try XCTUnwrap(submitted.data).decode(RetraceCommandJob.self)
        try await fixture.processing.waitUntilEntered()
        let arguments = RetraceJSON.object(["id": .string(job.id.uuidString)])
        let observed = await dispatcher.execute(.init(requestID: UUID(), operation: .jobRead, arguments: arguments), bearerToken: token)
        let running = try XCTUnwrap(observed.data).decode(RetraceCommandJob.self)
        XCTAssertEqual(running.state, .running); XCTAssertEqual(running.repairPhase, .recognizing)
        let cancellation = Task { await dispatcher.execute(.init(requestID: UUID(), operation: .jobCancel, arguments: arguments), bearerToken: token) }
        // Wait for the real permit's cancellation flag, not a scheduler delay assumption.
        try await fixture.governor.waitUntilCancelled()
        let held = await fixture.governor.releases
        XCTAssertEqual(held, 0)
        await fixture.processing.release()
        let cancelled = await cancellation.value
        let finished = try XCTUnwrap(cancelled.data).decode(RetraceCommandJob.self)
        XCTAssertEqual(finished.state, .cancelled)
        let replay = await dispatcher.execute(request, bearerToken: token)
        XCTAssertTrue(replay.replayed)
        let replayJob = try XCTUnwrap(replay.data).decode(RetraceCommandJob.self)
        XCTAssertEqual(replayJob.id, job.id)
        try await fixture.assertOriginal()
        await dispatcher.close(); await fixture.owner.close(); try await fixture.database.close()
    }
}

private struct RepairFixture {
    let database: DatabaseManager, owner: ExactOCRRepairService, processing: HeldRepairProcessing
    let governor: RepairGovernor, reference: ScreenEvidenceRef, time: Date
    static func make() async throws -> Self {
        let database = DatabaseManager(databasePath: "file:app_repair_\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let segment = try await database.insertSegment(bundleID: "com.fixture.repair", startDate: time, endDate: time,
            windowName: "Authored repair", browserUrl: nil, type: 0)
        let frame = FrameID(value: try await database.insertFrame(.init(id: .init(value: 0), timestamp: time,
            segmentID: .init(value: segment), frameIndexInSegment: 0,
            metadata: .init(appBundleID: "com.fixture.repair", windowName: "Authored repair"))))
        _ = try await database.commitFrameOCR(frameID: frame, text: .init(frameID: frame, timestamp: time,
            regions: [], fullText: "Original text"), frameWidth: 100, frameHeight: 100)
        let store = try await database.activityStoreID(), saved = try await database.currentScreenEvidence(frameID: frame, storeID: store)
        let reference = try XCTUnwrap(saved).ref, processing = HeldRepairProcessing(), governor = RepairGovernor()
        let state = NativeCaptureState(config: Shared.CaptureConfig(), revision: UUID())
        let owner = ExactOCRRepairService(database: database, processing: processing, governor: governor,
            captureState: { state }, pixels: { target in
                .init(timestamp: target.snapshot.frame.timestamp, imageData: Data(repeating: 0, count: 40_000),
                    width: 100, height: 100, bytesPerRow: 400, metadata: target.snapshot.frame.metadata)
            })
        return .init(database: database, owner: owner, processing: processing, governor: governor, reference: reference, time: time)
    }
    func assertOriginal(file: StaticString = #filePath, line: UInt = #line) async throws {
        let current = try await database.currentScreenEvidence(frameID: reference.frameID, storeID: reference.storeID)
        XCTAssertEqual(current?.ref, reference, file: file, line: line)
        XCTAssertEqual(current?.text?.fullText, "Original text", file: file, line: line)
    }
}

private actor RepairGovernor: BackgroundProcessingProtocol {
    var releases = 0
    private var permit: BackgroundProcessingPermit?
    func acquire(_ kind: BackgroundProcessingKind) async throws -> BackgroundProcessingPermit {
        XCTAssertEqual(kind, .historicalOCR); XCTAssertTrue(BackgroundProcessingContext.explicitRequest)
        let value = BackgroundProcessingPermit(threadCount: 1); permit = value; return value
    }
    func release(_ permit: BackgroundProcessingPermit) { releases += 1 }
    func waitUntilCancelled() async throws {
        for _ in 0..<200 {
            if permit?.cancellation.isCancelled == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for cancellation"); throw ExactOCRRepairError.closed
    }
}

private actor HeldRepairProcessing: ProcessingProtocol {
    var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func waitUntilEntered() async throws {
        for _ in 0..<200 {
            if continuation != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for retained OCR"); throw ExactOCRRepairError.closed
    }
    func release() { continuation?.resume(); continuation = nil }
    func reprocessText(from frame: CapturedFrame) async throws -> ExtractedText {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        return .init(frameID: .init(value: 0), timestamp: frame.timestamp, regions: [], fullText: "Fresh repair", metadata: frame.metadata)
    }
    func extractText(from frame: CapturedFrame) async throws -> ExtractedText { throw ExactOCRRepairError.invalidTarget }
    func initialize(config: ProcessingConfig) {}
    func extractTextViaOCR(from frame: CapturedFrame) async throws -> [TextRegion] { [] }
    func extractTextViaAccessibility() async throws -> [TextRegion] { [] }
    func queueFrame(_ frame: CapturedFrame, completion: @escaping @Sendable (Result<ExtractedText, ProcessingError>) -> Void) {}
    var queuedFrameCount: Int { 0 }
    func waitForQueueDrain() {}
    func updateConfig(_ config: ProcessingConfig) {}
    func getConfig() -> ProcessingConfig { ProcessingConfig() }
}
