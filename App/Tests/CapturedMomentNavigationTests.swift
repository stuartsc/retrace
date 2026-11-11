import CoreGraphics
import Database
import Foundation
import Shared
import Storage
import XCTest
@testable import App

final class CapturedMomentNavigationTests: XCTestCase {
    private var database: DatabaseManager!
    private var transition: ScreenEvidencePolicyTransition!
    private var pathID: Int64 = 1_790_000_100_000
    private let config = CaptureConfig(excludePrivateWindows: false, backend: .screenCaptureKitCandidate)

    override func setUp() async throws {
        database = DatabaseManager()
        try await database.initialize()
        transition = try await database.beginScreenEvidenceWriterSession(policy: .init(config: config))
        try await database.activateScreenEvidencePolicy(transition)
    }

    override func tearDown() async throws { try await database?.close() }

    func testUnrelatedRecordingDoesNotBreakAPinnedDisplayLink() async throws {
        let historical = try group(at: 10)
        try await begin(historical)
        let selected = try await store(historical, index: 0, at: 12)
        let companion = try await store(historical, index: 1, at: 13)
        let oldValue = try await database.captureGroup(for: selected)
        let old = try XCTUnwrap(oldValue)
        try await begin(group(at: 20))
        do { try await database.revalidateCaptureGroupRead(old.stamp); XCTFail("Journal must advance") }
        catch { }
        let target = try await CapturedMomentNavigation.resolve(store: database, selected: selected,
            attemptID: historical.targets[1].attemptID)
        XCTAssertEqual(target, companion, "A click must resolve the same durable attempt against fresh journal state")
    }

    func testPendingDisplayCanFinishWhileSelectionStaysPinnedAndDeletionNeverReturnsPixels() async throws {
        let moment = try group(at: 10)
        try await begin(moment)
        let selected = try await store(moment, index: 0, at: 12)
        let pending = try await CapturedMomentNavigation.resolve(store: database, selected: selected,
            attemptID: moment.targets[1].attemptID)
        XCTAssertNil(pending)
        let companion = try await store(moment, index: 1, at: 13)
        let completed = try await CapturedMomentNavigation.resolve(store: database, selected: selected,
            attemptID: moment.targets[1].attemptID)
        XCTAssertEqual(completed, companion)
        try await database.deleteFrame(id: companion.frameID)
        let deleted = try await CapturedMomentNavigation.resolve(store: database, selected: selected,
            attemptID: moment.targets[1].attemptID)
        XCTAssertNil(deleted)
    }

    func testCurrentExclusionRejectsPinnedNavigation() async throws {
        let moment = try group(at: 10)
        try await begin(moment)
        let selected = try await store(moment, index: 0, at: 12)
        _ = try await store(moment, index: 1, at: 13)
        let changed = try await database.prepareScreenEvidencePolicy(session: transition.session,
            policy: .init(config: CaptureConfig(excludedAppBundleIDs: ["com.test.capture-group"],
                                                excludePrivateWindows: false)))
        try await database.activateScreenEvidencePolicy(changed)
        do {
            _ = try await CapturedMomentNavigation.resolve(store: database, selected: selected,
                attemptID: moment.targets[1].attemptID)
            XCTFail("A displayed old strip is not authority to navigate excluded evidence")
        } catch { }
    }

    func testDurableOriginalSurvivesRevokedFreshAdmissionAndExactWriterRestartRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GroupRecovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(storageRoot: root)
        try await storage.initialize(config: StorageConfig(storageRootPath: root.path))
        let wal = await storage.getWALManager()
        let storeID = try await database.originalStoreID()
        try await wal.configureOriginalStore(storeID: storeID)
        let moment = try group(at: 10)
        try await begin(moment)
        let member = CaptureGroupFrameReceipt(group: moment, target: moment.targets[0])
        let pixels = CapturePixelReceipt(attemptID: member.attemptID,
            interval: .init(startedAt: time(12), endedAt: time(12.1), startedUptime: 12, endedUptime: 12.1))
        try await database.appendCaptureGroupEvent(.init(occurredAt: time(12.2), monotonicTime: 12.2,
            payload: .attemptOutcome(.init(member: member, disposition: .retainedCandidate, pixelReceipt: pixels))))
        let captured = CapturedFrame(timestamp: time(12), imageData: Data(repeating: 96, count: 64 * 64 * 4),
            width: 64, height: 64, bytesPerRow: 256, metadata: .init(appBundleID: "com.test.capture-group",
                displayID: member.displayID, captureMonotonicTime: 12,
                capturePolicySHA256: moment.capturePolicySHA256, pixelReceipt: pixels, captureGroup: member))
        let sourceID = VideoSegmentID(value: pathID); pathID += 1
        var session = try await wal.createSession(videoID: sourceID)
        try await wal.appendFrame(captured, to: &session)
        let originalBytes = try Data(contentsOf: session.framesURL)
        let videoID = try await database.insertVideoSegment(.init(id: .init(value: 0), startTime: time(12),
            endTime: time(12), frameCount: 0, fileSizeBytes: 0, relativePath: "videos/\(sourceID.value).mp4",
            width: 64, height: 64))
        let segmentID = try await database.insertSegment(bundleID: "com.test.capture-group", startDate: time(12),
            endDate: time(12), windowName: nil, browserUrl: nil, type: 0)
        let descriptor = FrameReference(id: .init(value: 0), timestamp: captured.timestamp,
            segmentID: .init(value: segmentID), videoID: .init(value: videoID), frameIndexInSegment: 0,
            metadata: captured.metadata)
        try await database.revokeScreenEvidencePolicy(transition)
        do {
            _ = try await database.insertCapturedFrame(descriptor, originalVideoPathID: sourceID)
            XCTFail("A revoked live writer must not commit a new group/frame association")
        } catch { }
        let emptyCount = try await database.getFrameCount()
        let emptyAlias = try await database.lookupOriginalFrame(sourceStoreID: storeID,
            originalVideoPathID: sourceID, sourceIndex: 0)
        XCTAssertEqual(emptyCount, 0); XCTAssertEqual(emptyAlias, .unknown)
        XCTAssertEqual(try Data(contentsOf: session.framesURL), originalBytes)
        try await wal.finalizeSession(session)

        // New owning writer plus new filesystem reader; no live-path fallback
        // invokes recovery while the rejected writer is still admitting frames.
        transition = try await database.beginScreenEvidenceWriterSession(policy: .init(config: config))
        try await database.activateScreenEvidencePolicy(transition)
        let reopened = WALManager(walRoot: root.appendingPathComponent("wal"))
        let recovery = RecoveryManager(walManager: reopened, storage: storage, database: database)
        await recovery.setFrameEnqueueCallback { _ in }
        let recovered = try await recovery.recoverAll()
        XCTAssertEqual(recovered.framesRecovered, 1)
        let rows = try await database.getFrames(from: .distantPast, to: .distantFuture, limit: 5)
        let row = try XCTUnwrap(rows.first)
        let snapshotValue = try await database.currentScreenEvidence(frameID: row.id, storeID: storeID)
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertEqual(snapshot.frame.metadata.captureGroup, member)
        XCTAssertEqual(snapshot.frame.metadata.pixelReceipt, pixels)
        let retained = try await reopened.readFrame(videoID: sourceID, frameIndex: 0)
        XCTAssertEqual(retained.imageData, captured.imageData)
        let groupValue = try await database.captureGroup(for: snapshot.ref)
        let groupSnapshot = try XCTUnwrap(groupValue)
        XCTAssertEqual(groupSnapshot.members.map(\.state), [.stored, .interrupted])
        try await database.deleteFrame(id: row.id)
        _ = try await recovery.recoverAll()
        let deletedCount = try await database.getFrameCount()
        XCTAssertEqual(deletedCount, 0, "Original recovery cannot recreate a deleted grouped frame")
    }

    private func group(at value: Double) throws -> CaptureSamplingGroup {
        let targets = (0..<2).map { index in CaptureSamplingTarget(attemptID: UUID(), attachment:
            .init(attachmentID: UUID(), displayID: UInt32(index + 51), monitorUUID: UUID(),
                bounds: CGRect(x: index * 64, y: 0, width: 64, height: 64),
                pixelWidth: 64, pixelHeight: 64, rotationDegrees: 0, refreshRateHz: 60, modeID: 1)) }
        return .init(groupID: UUID(), sessionID: UUID(), configurationGeneration: 1,
            backend: .screenCaptureKitCandidate, displayPolicy: .allDisplays,
            capturePolicySHA256: try ScreenEvidenceAccessPolicy(config: config).fingerprintSHA256(),
            enumeration: .init(startedAt: time(value), endedAt: time(value + 0.1),
                startedUptime: value, endedUptime: value + 0.1), targets: targets)
    }

    private func begin(_ group: CaptureSamplingGroup) async throws {
        try await database.appendCaptureGroupEvent(.init(occurredAt: group.enumeration.endedAt,
            monotonicTime: group.enumeration.endedUptime, payload: .began(group)))
    }

    private func store(_ group: CaptureSamplingGroup, index: Int, at value: Double) async throws -> ScreenEvidenceRef {
        let member = CaptureGroupFrameReceipt(group: group, target: group.targets[index])
        let pixels = CapturePixelReceipt(attemptID: member.attemptID,
            interval: .init(startedAt: time(value), endedAt: time(value + 0.1),
                            startedUptime: value, endedUptime: value + 0.1))
        try await database.appendCaptureGroupEvent(.init(occurredAt: time(value + 0.2),
            monotonicTime: value + 0.2, payload: .attemptOutcome(.init(member: member,
                disposition: .retainedCandidate, pixelReceipt: pixels))))
        let path = VideoSegmentID(value: pathID); pathID += 1
        let videoID = try await database.insertVideoSegment(.init(id: .init(value: 0),
            startTime: time(value), endTime: time(value), frameCount: 1, fileSizeBytes: 0,
            relativePath: "videos/\(path.value).mp4", width: 64, height: 64))
        let segment = try await database.insertSegment(bundleID: "com.test.capture-group", startDate: time(value),
            endDate: time(value), windowName: "Authored displays", browserUrl: nil, type: 0)
        let frame = FrameReference(id: .init(value: 0), timestamp: time(value), segmentID: .init(value: segment),
            videoID: .init(value: videoID), frameIndexInSegment: 0,
            metadata: .init(appBundleID: "com.test.capture-group", displayID: member.displayID,
                captureMonotonicTime: value, capturePolicySHA256: group.capturePolicySHA256,
                pixelReceipt: pixels, captureGroup: member))
        let frameID = try await database.insertCapturedFrame(frame, originalVideoPathID: path)
        let snapshot = try await database.currentScreenEvidence(frameID: .init(value: frameID),
            storeID: transition.session.storeID)
        return try XCTUnwrap(snapshot).ref
    }

    private func time(_ value: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + value) }
}
