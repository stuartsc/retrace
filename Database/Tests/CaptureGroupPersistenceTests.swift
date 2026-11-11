import CoreGraphics
import Foundation
import Shared
import SQLCipher
import XCTest
@testable import Database

final class CaptureGroupPersistenceTests: XCTestCase {
    private var database: DatabaseManager!
    private var transition: ScreenEvidencePolicyTransition!
    private var nextPathID: Int64 = 1_790_000_000_000
    private let config = CaptureConfig(excludePrivateWindows: false, backend: .screenCaptureKitCandidate)

    override func setUp() async throws {
        database = DatabaseManager()
        try await database.initialize()
        transition = try await database.beginScreenEvidenceWriterSession(policy: .init(config: config))
        try await database.activateScreenEvidencePolicy(transition)
    }

    override func tearDown() async throws { try await database?.close() }

    func testBeginAtomicallyPersistsEveryTargetAndRejectsConflictingRetry() async throws {
        let group = try makeGroup()
        let began = event(.began(group), at: 11)
        try await database.appendCaptureGroupEvent(began)
        try await database.appendCaptureGroupEvent(began)
        let counts = try await database.captureGroupFixtureCounts()
        XCTAssertEqual(counts.groups, 1); XCTAssertEqual(counts.members, 2); XCTAssertEqual(counts.events, 1)
        let altered = CaptureGroupEvent(eventID: began.eventID, occurredAt: time(11.1), monotonicTime: 11.1,
                                        payload: .began(group))
        await assertFails { try await self.database.appendCaptureGroupEvent(altered) }
        let unchanged = try await database.captureGroupFixtureCounts()
        XCTAssertEqual(unchanged.events, 1)
    }

    func testPreparedOrRevokedPolicyCannotBeginNativePixels() async throws {
        let group = try makeGroup()
        try await database.revokeScreenEvidencePolicy(transition)
        await assertFails { try await self.database.appendCaptureGroupEvent(self.event(.began(group), at: 11)) }
        let prepared = try await database.prepareScreenEvidencePolicy(session: transition.session, policy: .init(config: config))
        await assertFails { try await self.database.appendCaptureGroupEvent(self.event(.began(group), at: 11)) }
        try await database.activateScreenEvidencePolicy(prepared)
        try await database.appendCaptureGroupEvent(event(.began(group), at: 11))
        let counts = try await database.captureGroupFixtureCounts()
        XCTAssertEqual(counts.members, 2)
    }

    func testSamplingEndDoesNotCloseCandidateDrainAndStoredTimeIsExact() async throws {
        let group = try makeGroup()
        try await database.appendCaptureGroupEvent(event(.began(group), at: 11))
        try await database.appendCaptureGroupEvent(event(.samplingEnded(.init(groupID: group.groupID,
            sessionID: group.sessionID, reason: .completed)), at: 14))
        let first = try await capture(group, target: 0, at: 12)
        let second = try await capture(group, target: 1, at: 13)
        let value = try await database.captureGroup(for: first.ref)
        let snapshot = try XCTUnwrap(value)
        XCTAssertEqual(snapshot.samplingEnd, .completed)
        XCTAssertEqual(snapshot.members.map(\.state), [.stored, .stored])
        XCTAssertEqual(snapshot.members.compactMap(\.reference), [first.ref, second.ref])
        XCTAssertEqual(snapshot.members.compactMap(\.evidenceTimestamp), [time(12), time(13)])
    }

    func testIdenticalBeginRetryNeverRegrantsRevokedPreparedOrReplacedAuthority() async throws {
        let group = try makeGroup()
        let began = event(.began(group), at: 11)
        try await database.appendCaptureGroupEvent(began)
        try await database.revokeScreenEvidencePolicy(transition)
        await assertFails { try await self.database.appendCaptureGroupEvent(began) }
        let prepared = try await database.prepareScreenEvidencePolicy(session: transition.session, policy: .init(config: config))
        await assertFails { try await self.database.appendCaptureGroupEvent(began) }
        try await database.activateScreenEvidencePolicy(prepared)
        await assertFails { try await self.database.appendCaptureGroupEvent(began) }
        let restarted = try await database.beginScreenEvidenceWriterSession(policy: .init(config: config))
        try await database.activateScreenEvidencePolicy(restarted)
        await assertFails { try await self.database.appendCaptureGroupEvent(began) }
        let counts = try await database.captureGroupFixtureCounts()
        XCTAssertEqual(counts.groups, 1); XCTAssertEqual(counts.events, 1)
    }

    func testJournalChangesInvalidateAReadEvenWithoutNewScreenEvidence() async throws {
        let group = try makeGroup()
        try await database.appendCaptureGroupEvent(event(.began(group), at: 11))
        let first = try await capture(group, target: 0, at: 12)
        let initialValue = try await database.captureGroup(for: first.ref)
        let initial = try XCTUnwrap(initialValue)
        try await database.revalidateCaptureGroupRead(initial.stamp)
        let missing = CaptureAttemptOutcome(member: .init(group: group, target: group.targets[1]),
            disposition: .unavailable, reason: .displayUnavailable)
        try await database.appendCaptureGroupEvent(event(.attemptOutcome(missing), at: 13))
        await assertFails { try await self.database.revalidateCaptureGroupRead(initial.stamp) }
        let secondValue = try await database.captureGroup(for: first.ref)
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(second.members[1].state, .unavailable)
        try await database.appendCaptureGroupEvent(event(.samplingEnded(.init(groupID: group.groupID,
            sessionID: group.sessionID, reason: .completed)), at: 14))
        await assertFails { try await self.database.revalidateCaptureGroupRead(second.stamp) }
    }

    func testSuppressionReflectsLaterPriorCandidateLossInsteadOfStayingPending() async throws {
        let earlier = try makeGroup()
        try await database.appendCaptureGroupEvent(event(.began(earlier), at: 11))
        let anchor = CaptureGroupFrameReceipt(group: earlier, target: earlier.targets[0])
        let anchorPixels = receipt(anchor.attemptID, at: 12)
        try await database.appendCaptureGroupEvent(event(.attemptOutcome(.init(member: anchor,
            disposition: .retainedCandidate, pixelReceipt: anchorPixels)), at: 12.5))
        let later = try makeGroup(sessionID: earlier.sessionID, attachment: earlier.targets[0].attachment, start: 20)
        try await database.appendCaptureGroupEvent(event(.began(later), at: 21))
        let current = try await capture(later, target: 1, at: 23)
        let suppressed = CaptureGroupFrameReceipt(group: later, target: later.targets[0])
        let pixels = receipt(suppressed.attemptID, at: 22)
        try await database.appendCaptureGroupEvent(event(.attemptOutcome(.init(member: suppressed,
            disposition: .retainedCandidate, pixelReceipt: pixels)), at: 22.5))
        try await database.appendCaptureGroupEvent(event(.attemptOutcome(.init(member: suppressed,
            disposition: .suppressedSimilar, pixelReceipt: pixels,
            similarReference: .init(member: anchor, pixelReceipt: anchorPixels),
            comparison: .init(pixelThreshold: 0.01, directTextEnabled: false))), at: 23.5))
        let beforeValue = try await database.captureGroup(for: current.ref)
        let before = try XCTUnwrap(beforeValue)
        XCTAssertEqual(before.members[0].state, .pending)
        try await database.appendCaptureGroupEvent(event(.attemptOutcome(.init(member: anchor,
            disposition: .dropped, reason: .outputBufferBackpressure, pixelReceipt: anchorPixels)), at: 24))
        await assertFails { try await self.database.revalidateCaptureGroupRead(before.stamp) }
        let afterValue = try await database.captureGroup(for: current.ref)
        let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(after.members[0].state, .dropped)
        XCTAssertNil(after.members[0].reference)
    }

    func testSuppressionUsesExactEarlierStoredSampleAndDeletionCannotResurrectIt() async throws {
        let group = try makeGroup()
        try await database.appendCaptureGroupEvent(event(.began(group), at: 11))
        let anchor = try await capture(group, target: 0, at: 12)
        let next = try makeGroup(sessionID: group.sessionID, attachment: group.targets[0].attachment, start: 20)
        try await database.appendCaptureGroupEvent(event(.began(next), at: 21))
        let current = try await capture(next, target: 1, at: 23)
        let member = CaptureGroupFrameReceipt(group: next, target: next.targets[0])
        let pixels = receipt(next.targets[0].attemptID, at: 22)
        try await database.appendCaptureGroupEvent(event(.attemptOutcome(.init(member: member,
            disposition: .retainedCandidate, pixelReceipt: pixels)), at: 22.5))
        let older = CaptureAttemptReference(member: .init(group: group, target: group.targets[0]),
                                           pixelReceipt: receipt(group.targets[0].attemptID, at: 12))
        try await database.appendCaptureGroupEvent(event(.attemptOutcome(.init(member: member,
            disposition: .suppressedSimilar, pixelReceipt: pixels, similarReference: older,
            comparison: .init(pixelThreshold: 0.01, directTextEnabled: true))), at: 23.5))
        let beforeValue = try await database.captureGroup(for: current.ref)
        let before = try XCTUnwrap(beforeValue)
        XCTAssertEqual(before.members[0].state, .similar)
        XCTAssertEqual(before.members[0].reference, anchor.ref)
        XCTAssertEqual(before.members[0].evidenceTimestamp, time(12))
        try await database.deleteFrames(ids: [anchor.frame.id])
        let afterValue = try await database.captureGroup(for: current.ref)
        let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(after.members[0].state, .deleted)
        XCTAssertNil(after.members[0].reference)
        await assertFails { _ = try await self.capture(group, target: 0, at: 12) }
    }

    func testExactReuseKeepsObservationTimeAndDeletionCannotResurrectPixels() async throws {
        let group = try makeGroup()
        try await database.appendCaptureGroupEvent(event(.began(group), at: 11))
        let anchor = try await capture(group, target: 0, at: 12)
        let next = try makeGroup(sessionID: group.sessionID, attachment: group.targets[0].attachment, start: 20)
        try await database.appendCaptureGroupEvent(event(.began(next), at: 21))
        let current = try await capture(next, target: 1, at: 23)
        let member = CaptureGroupFrameReceipt(group: next, target: next.targets[0])
        let pixels = receipt(next.targets[0].attemptID, at: 22)
        try await database.appendCaptureGroupEvent(event(.attemptOutcome(.init(member: member,
            disposition: .retainedCandidate, pixelReceipt: pixels)), at: 22.5))
        let older = CaptureAttemptReference(member: .init(group: group, target: group.targets[0]),
                                           pixelReceipt: receipt(group.targets[0].attemptID, at: 12))
        try await database.appendCaptureGroupEvent(event(.attemptOutcome(.init(member: member,
            disposition: .suppressedSimilar, pixelReceipt: pixels, similarReference: older,
            comparison: .init(exactPixelSHA256: String(repeating: "a", count: 64), directTextEnabled: true))), at: 23.5))
        let beforeValue = try await database.captureGroup(for: current.ref)
        let before = try XCTUnwrap(beforeValue)
        XCTAssertEqual(before.members[0].outcome?.comparison?.method, .exactPixelsV1)
        XCTAssertEqual(before.members[0].outcome?.pixelReceipt?.interval.startedAt, time(22))
        XCTAssertEqual(before.members[0].state, .similar)
        XCTAssertEqual(before.members[0].reference, anchor.ref)
        XCTAssertEqual(before.members[0].evidenceTimestamp, time(12))
        try await database.deleteFrames(ids: [anchor.frame.id])
        let afterValue = try await database.captureGroup(for: current.ref)
        let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(after.members[0].state, .deleted)
        XCTAssertNil(after.members[0].reference)
        await assertFails { _ = try await self.capture(group, target: 0, at: 12) }
    }

    func testPolicyChangeHidesWholeGroupUntilFreshAuthorityAndDoesNotInventImportedGroups() async throws {
        let group = try makeGroup()
        try await database.appendCaptureGroupEvent(event(.began(group), at: 11))
        let frame = try await capture(group, target: 0, at: 12)
        let updated = try await database.prepareScreenEvidencePolicy(session: transition.session,
            policy: .init(config: CaptureConfig(excludedAppBundleIDs: ["com.test.group"], excludePrivateWindows: false)))
        try await database.activateScreenEvidencePolicy(updated)
        await assertFails { _ = try await self.database.captureGroup(for: frame.ref) }
        let imported = ScreenEvidenceRef(storeID: frame.ref.storeID, source: .rewind,
            observationID: frame.ref.observationID, frameID: frame.ref.frameID,
            extractionRevision: frame.ref.extractionRevision)
        await assertFails { _ = try await self.database.captureGroup(for: imported) }
    }

    func testLateTerminalOutcomeDrainsAfterRevokeButCannotReopenStoredOrDroppedMember() async throws {
        let group = try makeGroup()
        try await database.appendCaptureGroupEvent(event(.began(group), at: 11))
        let frame = try await capture(group, target: 0, at: 12)
        try await database.revokeScreenEvidencePolicy(transition)
        let cancelled = CaptureAttemptOutcome(member: .init(group: group, target: group.targets[1]),
            disposition: .cancelled, reason: .sourceStopped)
        try await database.appendCaptureGroupEvent(event(.attemptOutcome(cancelled), at: 14))
        let changed = CaptureAttemptOutcome(member: .init(group: group, target: group.targets[0]),
            disposition: .dropped, reason: .outputBufferBackpressure,
            pixelReceipt: receipt(group.targets[0].attemptID, at: 12))
        await assertFails { try await self.database.appendCaptureGroupEvent(self.event(.attemptOutcome(changed), at: 14)) }
        let revived = CaptureAttemptOutcome(member: .init(group: group, target: group.targets[1]),
            disposition: .retainedCandidate, pixelReceipt: receipt(group.targets[1].attemptID, at: 13))
        await assertFails { try await self.database.appendCaptureGroupEvent(self.event(.attemptOutcome(revived), at: 15)) }
        XCTAssertEqual(frame.frame.id.value, frame.ref.frameID.value)
    }

    func testMismatchedAttemptOrDimensionsRollbackFrameAndAliasTogether() async throws {
        let group = try makeGroup()
        try await database.appendCaptureGroupEvent(event(.began(group), at: 11))
        let member = CaptureGroupFrameReceipt(group: group, target: group.targets[0])
        let pixels = receipt(group.targets[0].attemptID, at: 12)
        try await database.appendCaptureGroupEvent(event(.attemptOutcome(.init(member: member,
            disposition: .retainedCandidate, pixelReceipt: pixels)), at: 12.5))
        await assertFails { _ = try await self.insert(group, target: 0, at: 12, width: 128) }
        let rows = try await database.getFrames(from: .distantPast, to: .distantFuture, limit: 10)
        XCTAssertTrue(rows.isEmpty)
        let counts = try await database.captureGroupFixtureCounts()
        XCTAssertEqual(counts.aliases, 0)
        let wrong = CaptureAttemptOutcome(member: member, disposition: .retainedCandidate,
            pixelReceipt: receipt(UUID(), at: 12))
        await assertFails { try await self.database.appendCaptureGroupEvent(self.event(.attemptOutcome(wrong), at: 13)) }
    }

    func testSQLiteFailureRollsBackAllTargetsAndAllowsExactRetry() async throws {
        let group = try makeGroup()
        try await database.captureGroupFixtureSQL("CREATE TRIGGER fail_group_member BEFORE INSERT ON capture_group_member WHEN NEW.displayID=42 BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
        let begin = event(.began(group), at: 11)
        await assertFails { try await self.database.appendCaptureGroupEvent(begin) }
        let counts = try await database.captureGroupFixtureCounts()
        XCTAssertEqual(counts.groups, 0); XCTAssertEqual(counts.members, 0); XCTAssertEqual(counts.events, 0)
        try await database.captureGroupFixtureSQL("DROP TRIGGER fail_group_member")
        try await database.appendCaptureGroupEvent(begin)
        let retried = try await database.captureGroupFixtureCounts()
        XCTAssertEqual(retried.members, 2)
    }

    private func makeGroup(sessionID: UUID = UUID(), attachment: CaptureDisplayAttachment? = nil,
                           start: Double = 10) throws -> CaptureSamplingGroup {
        let targets = (0..<2).map { index -> CaptureSamplingTarget in
            let display = index == 0 ? attachment : nil
            return .init(attemptID: UUID(), attachment: display ?? .init(attachmentID: UUID(),
                displayID: UInt32(41 + index), monitorUUID: UUID(), bounds: CGRect(x: index * 64, y: 0, width: 64, height: 64),
                pixelWidth: 64, pixelHeight: 64, rotationDegrees: 0, refreshRateHz: 60, modeID: 1))
        }
        return .init(groupID: UUID(), sessionID: sessionID, configurationGeneration: 1,
            backend: .screenCaptureKitCandidate, displayPolicy: .allDisplays,
            capturePolicySHA256: try ScreenEvidenceAccessPolicy(config: config).fingerprintSHA256(),
            enumeration: .init(startedAt: time(start), endedAt: time(start + 0.1),
                               startedUptime: start, endedUptime: start + 0.1), targets: targets)
    }

    private func capture(_ group: CaptureSamplingGroup, target: Int, at: Double) async throws -> ScreenEvidenceSnapshot {
        try await database.appendCaptureGroupEvent(event(.attemptOutcome(.init(
            member: .init(group: group, target: group.targets[target]), disposition: .retainedCandidate,
            pixelReceipt: receipt(group.targets[target].attemptID, at: at))), at: at + 0.5))
        return try await insert(group, target: target, at: at)
    }

    private func insert(_ group: CaptureSamplingGroup, target: Int, at: Double,
                        width: Int = 64) async throws -> ScreenEvidenceSnapshot {
        let pathID = VideoSegmentID(value: nextPathID)
        nextPathID += 1
        let video = VideoSegment(id: .init(value: 0), startTime: time(at), endTime: time(at), frameCount: 1,
            fileSizeBytes: 0, relativePath: "videos/\(pathID.value).mp4", width: width, height: 64)
        let videoID = try await database.insertVideoSegment(video)
        let segmentID = try await database.insertSegment(bundleID: "com.test.group", startDate: time(at),
            endDate: time(at), windowName: "Authored group", browserUrl: nil, type: 0)
        let member = CaptureGroupFrameReceipt(group: group, target: group.targets[target])
        let metadata = FrameMetadata(appBundleID: "com.test.group", displayID: member.displayID,
            captureMonotonicTime: at, capturePolicySHA256: group.capturePolicySHA256,
            pixelReceipt: receipt(member.attemptID, at: at), captureGroup: member)
        let frame = FrameReference(id: .init(value: 0), timestamp: time(at), segmentID: .init(value: segmentID),
            videoID: .init(value: videoID), frameIndexInSegment: 0, metadata: metadata)
        let id = try await database.insertCapturedFrame(frame, originalVideoPathID: pathID)
        let value = try await database.currentScreenEvidence(frameID: .init(value: id), storeID: transition.session.storeID)
        return try XCTUnwrap(value)
    }

    private func time(_ offset: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + offset) }
    private func receipt(_ attempt: UUID, at: Double) -> CapturePixelReceipt {
        .init(attemptID: attempt, interval: .init(startedAt: time(at), endedAt: time(at + 0.1),
                                                startedUptime: at, endedUptime: at + 0.1))
    }
    private func event(_ payload: CaptureGroupEvent.Payload, at: Double) -> CaptureGroupEvent {
        .init(occurredAt: time(at), monotonicTime: at, payload: payload)
    }
    private func assertFails(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected canonical rejection", file: file, line: line) }
        catch { }
    }
}

private extension DatabaseManager {
    func captureGroupFixtureSQL(_ sql: String) throws { try PipelineSQL.execute(requireRecallConnection(), sql) }
    func captureGroupFixtureCounts() throws -> (groups: Int64, members: Int64, events: Int64, aliases: Int64) {
        let db = try requireRecallConnection()
        func count(_ table: String) throws -> Int64 {
            try PipelineSQL.integers(db, "SELECT COUNT(*) FROM \(table)").first ?? -1
        }
        return try (count("capture_group"), count("capture_group_member"), count("capture_group_event"), count("original_frame_source"))
    }
}
