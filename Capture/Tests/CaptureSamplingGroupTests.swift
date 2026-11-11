import CoreGraphics
import Foundation
import Shared
import XCTest
@testable import Capture

/// Real CoreGraphics pixels and AsyncStreams cross controlled native inventory
/// and a private filesystem journal. Physical display/TCC acceptance is separate.
final class CaptureSamplingGroupTests: XCTestCase {
    private func config() -> CaptureConfig {
        CaptureConfig(backend: .screenCaptureKitCandidate, captureGroupReceiptsEnabled: true)
    }

    func testEnabledGroupCaptureWithoutAJournalFailsBeforeNativeRead() async throws {
        let fixture = GroupPixelFixture()
        let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false,
            displayAttachments: CaptureDisplayAttachmentTracker(observeNativeChanges: false))
        let stream = AsyncStream<CapturedFrame>.makeStream()
        do {
            try await source.startCapture(config: config(), frameContinuation: stream.continuation, displayID: 42)
            XCTFail("A grouped source requires durable begin acknowledgement")
        } catch CaptureGroupJournalError.unavailable { }
        let readCount1 = await fixture.readCount()
        XCTAssertEqual(readCount1, 0)
        stream.continuation.finish()
        try await source.stopCapture()
    }

    func testActivationAndDurableBeginAcknowledgementPrecedeEveryNativeRead() async throws {
        let fixture = GroupPixelFixture()
        let journal = try GroupFileJournal()
        let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false,
            displayAttachments: CaptureDisplayAttachmentTracker(observeNativeChanges: false))
        let delivery = CaptureGroupDelivery(journal: journal)
        await source.setGroupDelivery(delivery)
        addTeardownBlock { try? await source.stopCapture(); try? await delivery.cancelUnforwarded(reason: .sourceStopped); await journal.close() }
        let stream = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingOldest(2))
        try await source.startCapture(config: config(), frameContinuation: stream.continuation, displayID: 42)
        await source.captureImmediateAndResetTimer()
        let readCount2 = await fixture.readCount()
        XCTAssertEqual(readCount2, 0)
        let initialEvents = await journal.events()
        XCTAssertTrue(initialEvents.isEmpty)
        let gate = GroupTestGate()
        let entered = expectation(description: "begin waiting for actual journal commit")
        await journal.holdNextBegin(gate, entered: { entered.fulfill() })
        try await source.activateGroupedSampling(expectedPolicySHA256: ScreenEvidenceAccessPolicy(config: config()).fingerprintSHA256())
        let capture = Task { await source.captureImmediateAndResetTimer() }
        addTeardownBlock { await gate.release(); await capture.value }
        await fulfillment(of: [entered], timeout: 3)
        let readCount3 = await fixture.readCount()
        XCTAssertEqual(readCount3, 0)
        await gate.release()
        await capture.value
        stream.continuation.finish()
        var frames: [CapturedFrame] = []
        for await frame in stream.stream { frames.append(frame) }
        XCTAssertEqual(frames.count, 2)
        let events = await journal.events()
        guard case .began(let group) = try XCTUnwrap(events.first).payload else { return XCTFail("Missing durable begin") }
        XCTAssertEqual(group.targets.count, 2)
        XCTAssertEqual(Set(frames.compactMap { $0.metadata.captureGroup?.groupID }), [group.groupID])
        for frame in frames {
            let member = try XCTUnwrap(frame.metadata.captureGroup)
            XCTAssertEqual(member.attemptID, frame.metadata.pixelReceipt?.attemptID)
            XCTAssertTrue(group.targets.contains { $0.attemptID == member.attemptID && $0.attachment.attachmentID == member.attachmentID })
        }
        let first = try XCTUnwrap(frames.first?.metadata.pixelReceipt)
        let second = try XCTUnwrap(frames.last?.metadata.pixelReceipt)
        XCTAssertLessThanOrEqual(first.interval.endedUptime, second.interval.startedUptime)
        XCTAssertNotEqual(first.interval.startedUptime, second.interval.startedUptime)
        let durableEvents = try await journal.readDurableEvents()
        XCTAssertEqual(durableEvents.count, events.count)
        try await source.stopCapture()
        try await delivery.cancelUnforwarded(reason: .sourceStopped)
    }

    func testManagerSuppressionNamesTheExactEarlierAttemptWithoutRefreshingItsTime() async throws {
        let fixture = GroupPixelFixture(), journal = try GroupFileJournal()
        let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false,
            displayAttachments: CaptureDisplayAttachmentTracker(observeNativeChanges: false))
        let manager = CaptureManager(config: config(), metadataProvider: GroupMetadataProvider(), groupJournal: journal, source: source,
            lifecycleEnvironment: .init(hasPermission: { true }, activeDisplayID: { 42 }, startDisplayMonitoring: { _ in }, stopDisplayMonitoring: {}))
        addTeardownBlock { try? await manager.stopCapture(); await journal.close() }
        try await manager.startCapture(config: config())
        let output = await manager.frameStream
        var iterator = output.makeAsyncIterator()
        await source.captureImmediateAndResetTimer()
        let firstValue = await iterator.next(), secondValue = await iterator.next()
        let first = [try XCTUnwrap(firstValue), try XCTUnwrap(secondValue)]
        let suppressed = expectation(description: "both actual forwarding decisions committed")
        suppressed.expectedFulfillmentCount = 2
        await journal.onSuppression { suppressed.fulfill() }
        await source.captureImmediateAndResetTimer()
        await fulfillment(of: [suppressed], timeout: 3)
        // Stop joins the actual forwarding worker and the lossless journal drain.
        try await manager.stopCapture()
        let outcomes = await journal.events().compactMap { event -> CaptureAttemptOutcome? in
            if case .attemptOutcome(let outcome) = event.payload, outcome.disposition == .suppressedSimilar { return outcome }
            return nil
        }
        XCTAssertEqual(outcomes.count, 2)
        for outcome in outcomes {
            XCTAssertEqual(outcome.comparison?.method, .exactPixelsV1)
            XCTAssertEqual(outcome.comparison?.exactPixelSHA256?.count, 64)
            let earlier = try XCTUnwrap(first.first { $0.metadata.displayID == outcome.member.displayID })
            let reference = try XCTUnwrap(outcome.similarReference)
            XCTAssertEqual(reference.member, earlier.metadata.captureGroup)
            XCTAssertEqual(reference.pixelReceipt, earlier.metadata.pixelReceipt)
            XCTAssertNotEqual(reference.member.groupID, outcome.member.groupID)
            XCTAssertNotEqual(reference.pixelReceipt.interval.startedUptime, outcome.pixelReceipt?.interval.startedUptime)
        }
    }

    func testRejectedEarlierReferenceRetainsFreshPixelsInsteadOfReusingDeletedEvidence() async throws {
        let fixture = GroupPixelFixture(), journal = try GroupFileJournal()
        await fixture.onlyFirstDisplay()
        let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false,
            displayAttachments: CaptureDisplayAttachmentTracker(observeNativeChanges: false))
        let manager = CaptureManager(config: config(), metadataProvider: GroupMetadataProvider(), groupJournal: journal, source: source,
            lifecycleEnvironment: .init(hasPermission: { true }, activeDisplayID: { 42 }, startDisplayMonitoring: { _ in }, stopDisplayMonitoring: {}))
        addTeardownBlock { try? await manager.stopCapture(); await journal.close() }
        try await manager.startCapture(config: config())
        let output = await manager.frameStream
        var iterator = output.makeAsyncIterator()
        await source.captureImmediateAndResetTimer()
        let firstValue = await iterator.next()
        let first = try XCTUnwrap(firstValue)
        await journal.rejectNextReference()
        await source.captureImmediateAndResetTimer()
        let freshValue = await iterator.next()
        let fresh = try XCTUnwrap(freshValue)
        XCTAssertEqual(first.imageData, fresh.imageData)
        XCTAssertNotEqual(first.metadata.pixelReceipt?.attemptID, fresh.metadata.pixelReceipt?.attemptID)
        let isCapturing = await manager.isCapturing
        XCTAssertTrue(isCapturing)
    }

    func testDisplayRemovalAndReconfigurationDiscardStaleCompletionsAndRotateAttachmentIdentity() async throws {
        let fixture = GroupPixelFixture(), journal = try GroupFileJournal()
        await fixture.onlyFirstDisplay()
        let tracker = CaptureDisplayAttachmentTracker(observeNativeChanges: false)
        let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false,
            displayAttachments: tracker)
        let delivery = CaptureGroupDelivery(journal: journal)
        await source.setGroupDelivery(delivery)
        let stream = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingOldest(2))
        addTeardownBlock { try? await source.stopCapture(); try? await delivery.cancelUnforwarded(reason: .sourceStopped); await journal.close() }
        try await source.startCapture(config: config(), frameContinuation: stream.continuation, displayID: 42)
        try await source.activateGroupedSampling(expectedPolicySHA256: ScreenEvidenceAccessPolicy(config: config()).fingerprintSHA256())
        await source.captureImmediateAndResetTimer()
        var iterator = stream.stream.makeAsyncIterator()
        let firstValue = await iterator.next()
        let first = try XCTUnwrap(firstValue)
        try await delivery.forwarded(try XCTUnwrap(first.metadata.captureGroup))
        let entered = expectation(description: "native pixel request held")
        let gate = GroupTestGate()
        await fixture.holdNextRead(gate, entered: { entered.fulfill() })
        let cycle = Task { await source.captureImmediateAndResetTimer() }
        addTeardownBlock { await gate.release(); await cycle.value }
        await fulfillment(of: [entered], timeout: 3)
        tracker.noteReconfiguration(displayID: 42)
        await gate.release(); await cycle.value
        await source.captureImmediateAndResetTimer()
        stream.continuation.finish()
        let replacementValue = await iterator.next()
        let replacement = try XCTUnwrap(replacementValue)
        XCTAssertNotEqual(first.metadata.captureGroup?.attachmentID, replacement.metadata.captureGroup?.attachmentID)
        let stale = await iterator.next()
        XCTAssertNil(stale, "Stale completion must never join the new attachment")
        let discarded = await journal.events().contains { event in
            if case .attemptOutcome(let outcome) = event.payload { return outcome.reason == .displayReconfigured }
            return false
        }
        XCTAssertTrue(discarded)
    }

    func testLosslessRawBufferDropAndJournalFailureLeaveExplicitOutcomes() async throws {
        let fixture = GroupPixelFixture(), journal = try GroupFileJournal()
        let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false,
            displayAttachments: CaptureDisplayAttachmentTracker(observeNativeChanges: false))
        let delivery = CaptureGroupDelivery(journal: journal)
        await source.setGroupDelivery(delivery)
        let stream = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingOldest(1))
        addTeardownBlock { try? await source.stopCapture(); try? await delivery.cancelUnforwarded(reason: .sourceStopped); await journal.close() }
        try await source.startCapture(config: config(), frameContinuation: stream.continuation, displayID: 42)
        try await source.activateGroupedSampling(expectedPolicySHA256: ScreenEvidenceAccessPolicy(config: config()).fingerprintSHA256())
        await source.captureImmediateAndResetTimer()
        let drops = await journal.events().compactMap { event -> CaptureAttemptOutcome? in
            if case .attemptOutcome(let outcome) = event.payload, outcome.disposition == .dropped { return outcome }
            return nil
        }
        XCTAssertEqual(drops.count, 1)
        XCTAssertEqual(drops.first?.reason, .rawBufferBackpressure)
        await journal.failNextWrite()
        await source.captureImmediateAndResetTimer()
        let readCount = await fixture.readCount()
        await source.captureImmediateAndResetTimer()
        let stoppedReadCount = await fixture.readCount()
        XCTAssertEqual(stoppedReadCount, readCount, "Journal failure must stop native reads")
        stream.continuation.finish()
    }

    func testConfigurationCancellationAccountsForUnreadTargetsAndJoinsNativeRead() async throws {
        let fixture = GroupPixelFixture(), journal = try GroupFileJournal()
        let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false,
            displayAttachments: CaptureDisplayAttachmentTracker(observeNativeChanges: false))
        let delivery = CaptureGroupDelivery(journal: journal)
        await source.setGroupDelivery(delivery)
        let stream = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingOldest(2))
        addTeardownBlock { try? await source.stopCapture(); try? await delivery.cancelUnforwarded(reason: .sourceStopped); await journal.close() }
        try await source.startCapture(config: config(), frameContinuation: stream.continuation, displayID: 42)
        try await source.activateGroupedSampling(expectedPolicySHA256: ScreenEvidenceAccessPolicy(config: config()).fingerprintSHA256())
        let gate = GroupTestGate(), entered = expectation(description: "owned native read")
        await fixture.holdNextRead(gate, entered: { entered.fulfill() })
        let capture = Task { await source.captureImmediateAndResetTimer() }
        addTeardownBlock { await gate.release(); await capture.value }
        await fulfillment(of: [entered], timeout: 3)
        let invalidated = expectation(description: "source invalidated before join")
        await source.setInvalidationCheckpoint { invalidated.fulfill() }
        addTeardownBlock { await source.setInvalidationCheckpoint(nil) }
        let suspension = Task { await source.suspendGroupedSampling() }
        await fulfillment(of: [invalidated], timeout: 3)
        await source.setInvalidationCheckpoint(nil)
        await gate.release(); await suspension.value; await capture.value
        stream.continuation.finish()
        var frames: [CapturedFrame] = []
        for await frame in stream.stream { frames.append(frame) }
        XCTAssertTrue(frames.isEmpty)
        let events = await journal.events()
        let cancellations = events.compactMap { event -> CaptureAttemptOutcome? in
            if case .attemptOutcome(let outcome) = event.payload, outcome.disposition == .cancelled { return outcome }
            return nil
        }
        XCTAssertEqual(cancellations.count, 2)
        XCTAssertEqual(cancellations.filter { $0.pixelReceipt != nil }.count, 1,
            "Only the attempted native read has a pixel interval; an unread display has no invented read time")
        XCTAssertTrue(events.contains { if case .samplingEnded(let end) = $0.payload { return end.reason == .configurationChanged }; return false })
        await source.captureImmediateAndResetTimer()
        let readCount = await fixture.readCount()
        XCTAssertEqual(readCount, 1, "Suspended grouped sampling cannot resume before policy activation")
    }

    func testEndingSamplingDoesNotCancelForwardedCandidatesAndCapacityIsBounded() async throws {
        let fixture = GroupPixelFixture(), journal = try GroupFileJournal()
        await fixture.onlyFirstDisplay()
        let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false,
            displayAttachments: CaptureDisplayAttachmentTracker(observeNativeChanges: false))
        let delivery = CaptureGroupDelivery(journal: journal, maximumGroups: 2)
        await source.setGroupDelivery(delivery)
        let stream = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingOldest(2))
        addTeardownBlock { try? await source.stopCapture(); try? await delivery.cancelUnforwarded(reason: .sourceStopped); await journal.close() }
        try await source.startCapture(config: config(), frameContinuation: stream.continuation, displayID: 42)
        try await source.activateGroupedSampling(expectedPolicySHA256: ScreenEvidenceAccessPolicy(config: config()).fingerprintSHA256())
        await source.captureImmediateAndResetTimer()
        var iterator = stream.stream.makeAsyncIterator()
        let firstValue = await iterator.next(), first = try XCTUnwrap(firstValue)
        let member = try XCTUnwrap(first.metadata.captureGroup)
        try await delivery.forwarded(member)
        await source.captureImmediateAndResetTimer()
        await source.captureImmediateAndResetTimer()
        await source.captureImmediateAndResetTimer() // Third unresolved group cannot consume more native pixels.
        let readCount = await fixture.readCount()
        XCTAssertEqual(readCount, 3)
        try await source.stopCapture()
        try await delivery.cancelUnforwarded(reason: .sourceStopped)
        let firstOutcomes = await journal.events().compactMap { event -> CaptureAttemptOutcome? in
            if case .attemptOutcome(let outcome) = event.payload, outcome.member == member { return outcome }
            return nil
        }
        XCTAssertEqual(firstOutcomes.map(\.disposition), [.retainedCandidate],
            "Capture ending cannot cancel a candidate that already belongs to App's durable pipeline")
        stream.continuation.finish()
    }

    func testRemovedInventoryAndPolicyChangeNeverReuseAnAttachmentOrAnOldActivation() async throws {
        let fixture = GroupPixelFixture(), journal = try GroupFileJournal()
        await fixture.onlyFirstDisplay()
        let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false,
            displayAttachments: CaptureDisplayAttachmentTracker(observeNativeChanges: false))
        let delivery = CaptureGroupDelivery(journal: journal)
        await source.setGroupDelivery(delivery)
        let stream = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingOldest(2))
        addTeardownBlock { try? await source.stopCapture(); try? await delivery.cancelUnforwarded(reason: .sourceStopped); await journal.close() }
        try await source.startCapture(config: config(), frameContinuation: stream.continuation, displayID: 42)
        let oldPolicy = try ScreenEvidenceAccessPolicy(config: config()).fingerprintSHA256()
        try await source.activateGroupedSampling(expectedPolicySHA256: oldPolicy)
        await source.captureImmediateAndResetTimer()
        var iterator = stream.stream.makeAsyncIterator()
        let firstValue = await iterator.next(), first = try XCTUnwrap(firstValue)
        try await delivery.forwarded(try XCTUnwrap(first.metadata.captureGroup))
        let gate = GroupTestGate(), entered = expectation(description: "pixels before display removal")
        await fixture.holdNextRead(gate, entered: { entered.fulfill() })
        let capture = Task { await source.captureImmediateAndResetTimer() }
        addTeardownBlock { await gate.release(); await capture.value }
        await fulfillment(of: [entered], timeout: 3)
        await fixture.removeAllDisplays()
        await gate.release(); await capture.value
        await fixture.onlyFirstDisplay()
        await source.captureImmediateAndResetTimer()
        let replacementValue = await iterator.next(), replacement = try XCTUnwrap(replacementValue)
        XCTAssertNotEqual(first.metadata.captureGroup?.attachmentID, replacement.metadata.captureGroup?.attachmentID)
        try await delivery.forwarded(try XCTUnwrap(replacement.metadata.captureGroup))
        let changed = CaptureConfig(excludedAppBundleIDs: ["test.authored.new.exclusion"],
            backend: .screenCaptureKitCandidate, captureGroupReceiptsEnabled: true)
        try await source.updateConfig(changed)
        do {
            try await source.activateGroupedSampling(expectedPolicySHA256: oldPolicy)
            XCTFail("An old activation cannot authorize a changed privacy configuration")
        } catch CaptureGroupJournalError.inactive { }
        await source.captureImmediateAndResetTimer()
        let heldCount = await fixture.readCount()
        XCTAssertEqual(heldCount, 3)
        try await source.activateGroupedSampling(expectedPolicySHA256: ScreenEvidenceAccessPolicy(config: changed).fingerprintSHA256())
        await source.captureImmediateAndResetTimer()
        let freshValue = await iterator.next(), fresh = try XCTUnwrap(freshValue)
        XCTAssertNotEqual(replacement.metadata.captureGroup?.configurationGeneration, fresh.metadata.captureGroup?.configurationGeneration)
        XCTAssertNotEqual(replacement.metadata.capturePolicySHA256, fresh.metadata.capturePolicySHA256)
        stream.continuation.finish()
    }

    func testNativeDisplayObserverRegistrationEndsBeforeTrackerReuse() throws {
        // Uses public CoreGraphics inventory/observer APIs without changing any
        // display mode, reading desktop pixels or requesting permissions.
        let id = CGMainDisplayID()
        guard id > 0, let nativeID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let uuid = UUID(uuidString: CFUUIDCreateString(nil, nativeID) as String),
              let mode = CGDisplayCopyDisplayMode(id) else { throw XCTSkip("No native display inventory") }
        let descriptor = CaptureDisplayDescriptor(displayID: id, monitorUUID: uuid, bounds: CGDisplayBounds(id),
            pixelWidth: CGDisplayPixelsWide(id), pixelHeight: CGDisplayPixelsHigh(id),
            rotationDegrees: CGDisplayRotation(id), refreshRateHz: mode.refreshRate,
            modeID: UInt32(bitPattern: mode.ioDisplayModeID))
        let tracker = CaptureDisplayAttachmentTracker()
        try tracker.start(); defer { tracker.stop() }
        let first = try XCTUnwrap(tracker.sample([descriptor])[id])
        XCTAssertTrue(tracker.isCurrent(first))
        tracker.noteReconfiguration(displayID: id, beginsConfiguration: true)
        let changing = try XCTUnwrap(tracker.sample([descriptor])[id])
        XCTAssertFalse(tracker.isCurrent(changing), "Enumeration during the native begin/end interval is not stable")
        tracker.noteReconfiguration(displayID: id, beginsConfiguration: false)
        let next = try XCTUnwrap(tracker.sample([descriptor])[id])
        XCTAssertTrue(tracker.isCurrent(next))
        XCTAssertNotEqual(first.attachmentID, next.attachmentID)
        tracker.stop()
        XCTAssertFalse(tracker.isCurrent(next))
        try tracker.start()
        let restarted = try XCTUnwrap(tracker.sample([descriptor])[id])
        XCTAssertNotEqual(next.attachmentID, restarted.attachmentID)
    }

    func testManagerOutputPressureJournalsEachDroppedAttemptBeforeStopCompletes() async throws {
        let fixture = GroupPixelFixture(), journal = try GroupFileJournal()
        let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false,
            displayAttachments: CaptureDisplayAttachmentTracker(observeNativeChanges: false))
        let manager = CaptureManager(config: config(), metadataProvider: GroupMetadataProvider(), groupJournal: journal,
            source: source, lifecycleEnvironment: .init(hasPermission: { true }, activeDisplayID: { 42 },
                startDisplayMonitoring: { _ in }, stopDisplayMonitoring: {}))
        addTeardownBlock { try? await manager.stopCapture(); await journal.close() }
        try await manager.startCapture(config: config())
        let output = await manager.frameStream
        let outputFull = expectation(description: "two candidates passed to the full output buffer")
        outputFull.expectedFulfillmentCount = 2
        await manager.setGroupForwardedCheckpoint { _ in outputFull.fulfill() }
        await source.captureImmediateAndResetTimer()
        await fulfillment(of: [outputFull], timeout: 3)
        await manager.setGroupForwardedCheckpoint(nil)
        await manager.invalidateDeduplication(displayID: nil)
        let dropped = expectation(description: "two exact output-pressure outcomes committed")
        dropped.expectedFulfillmentCount = 2
        await journal.onOutcome { if $0.reason == .outputBufferBackpressure { dropped.fulfill() } }
        await source.captureImmediateAndResetTimer()
        await fulfillment(of: [dropped], timeout: 3)
        try await manager.stopCapture()
        var preserved: [CapturedFrame] = []
        for await frame in output { preserved.append(frame) }
        XCTAssertEqual(preserved.count, 2)
        let discarded = await journal.events().compactMap { event -> CaptureAttemptOutcome? in
            if case .attemptOutcome(let outcome) = event.payload, outcome.reason == .outputBufferBackpressure { return outcome }
            return nil
        }
        XCTAssertEqual(Set(discarded.map { $0.member.displayID }), [42, 43])
        XCTAssertTrue(discarded.allSatisfy { $0.pixelReceipt?.attemptID == $0.member.attemptID })
        XCTAssertTrue(discarded.allSatisfy { drop in !preserved.contains { $0.metadata.captureGroup == drop.member } })
    }

    func testRestartWaitsForOwnedFatalSourceTeardownBeforeRequestingPermissionAgain() async throws {
        let fixture = GroupPixelFixture(), journal = try GroupFileJournal()
        await fixture.onlyFirstDisplay()
        let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false,
            displayAttachments: CaptureDisplayAttachmentTracker(observeNativeChanges: false))
        let gate = GroupTestGate(), stopping = expectation(description: "fatal source teardown held")
        let manager = CaptureManager(config: config(), metadataProvider: GroupMetadataProvider(), groupJournal: journal,
            source: source, lifecycleEnvironment: .init(hasPermission: { await fixture.requestPermission() },
                activeDisplayID: { 42 }, startDisplayMonitoring: { _ in }, stopDisplayMonitoring: {
                    if await fixture.isFirstStop() { stopping.fulfill(); await gate.wait() }
                }))
        addTeardownBlock { await gate.release(); try? await manager.stopCapture(); await journal.close() }
        try await manager.startCapture(config: config())
        await journal.failNextWrite()
        await source.captureImmediateAndResetTimer()
        await fulfillment(of: [stopping], timeout: 3)
        let entered = expectation(description: "restart owns its lifecycle slot")
        await manager.setLifecycleEnqueuedCheckpoint { entered.fulfill() }
        let restartConfig = config()
        let restart = Task { try await manager.startCapture(config: restartConfig) }
        addTeardownBlock { await gate.release(); _ = try? await restart.value }
        await fulfillment(of: [entered], timeout: 3)
        let before = await fixture.permissionRequestCount()
        XCTAssertEqual(before, 1, "A restart cannot overtake still-owned native teardown")
        await gate.release(); try await restart.value
        await manager.setLifecycleEnqueuedCheckpoint(nil)
        let after = await fixture.permissionRequestCount()
        XCTAssertEqual(after, 2)
        let output = await manager.frameStream
        var iterator = output.makeAsyncIterator()
        await source.captureImmediateAndResetTimer()
        let retained = await iterator.next()
        XCTAssertNotNil(retained, "The stale fatal task cannot stop its replacement source")
    }

    func testSleepingAttachedDisplayRemainsAnExplicitUnreadGroupMember() async throws {
        let fixture = GroupPixelFixture(), journal = try GroupFileJournal()
        await fixture.sleepSecondDisplay()
        let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false,
            displayAttachments: CaptureDisplayAttachmentTracker(observeNativeChanges: false))
        let delivery = CaptureGroupDelivery(journal: journal)
        await source.setGroupDelivery(delivery)
        let stream = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingOldest(2))
        addTeardownBlock { try? await source.stopCapture(); try? await delivery.cancelUnforwarded(reason: .sourceStopped); await journal.close() }
        try await source.startCapture(config: config(), frameContinuation: stream.continuation, displayID: 42)
        try await source.activateGroupedSampling(expectedPolicySHA256: ScreenEvidenceAccessPolicy(config: config()).fingerprintSHA256())
        await source.captureImmediateAndResetTimer()
        let events = await journal.events(), readCount = await fixture.readCount()
        guard case .began(let group) = try XCTUnwrap(events.first).payload else { return XCTFail("Missing group") }
        XCTAssertEqual(group.targets.map { $0.attachment.displayID }, [42, 43])
        XCTAssertEqual(readCount, 1)
        let asleep = events.compactMap { event -> CaptureAttemptOutcome? in
            if case .attemptOutcome(let outcome) = event.payload, outcome.member.displayID == 43 { return outcome }
            return nil
        }
        XCTAssertEqual(asleep.count, 1)
        XCTAssertEqual(asleep.first?.reason, .displayAsleep)
        XCTAssertNil(asleep.first?.pixelReceipt)
        stream.continuation.finish()
    }

    func testFailedCandidateWriteAndLostAcknowledgementCanStopAndRestartWithOneGroupSlot() async throws {
        for lostAcknowledgement in [false, true] {
            let fixture = GroupPixelFixture(), journal = try GroupFileJournal()
            await fixture.onlyFirstDisplay()
            let source = ScreenCaptureKitCapture(environment: fixture.environment(), automaticallyPoll: false,
                displayAttachments: CaptureDisplayAttachmentTracker(observeNativeChanges: false))
            let delivery = CaptureGroupDelivery(journal: journal, maximumGroups: 1)
            await source.setGroupDelivery(delivery)
            let failedStream = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingOldest(2))
            addTeardownBlock { try? await source.stopCapture(); try? await delivery.cancelUnforwarded(reason: .sourceStopped); await journal.close() }
            try await source.startCapture(config: config(), frameContinuation: failedStream.continuation, displayID: 42)
            try await source.activateGroupedSampling(expectedPolicySHA256: ScreenEvidenceAccessPolicy(config: config()).fingerprintSHA256())
            await journal.failNextCandidate(acknowledgementLost: lostAcknowledgement)
            await source.captureImmediateAndResetTimer()
            try await source.stopCapture()
            try await delivery.cancelUnforwarded(reason: .sourceStopped)
            let firstEvents = try await journal.readDurableEvents()
            XCTAssertEqual(Set(firstEvents.map(\.eventID)).count, firstEvents.count,
                "A retry after fsync uses the same envelope and never duplicates the event")
            let cancellation = firstEvents.compactMap { event -> CaptureAttemptOutcome? in
                if case .attemptOutcome(let outcome) = event.payload, outcome.disposition == .cancelled { return outcome }
                return nil
            }
            XCTAssertEqual(cancellation.count, 1)
            XCTAssertNotNil(cancellation.first?.pixelReceipt, "The actual read interval survives a failed candidate acknowledgement")
            XCTAssertTrue(firstEvents.contains { if case .samplingEnded = $0.payload { return true }; return false })
            let restarted = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingOldest(2))
            try await source.startCapture(config: config(), frameContinuation: restarted.continuation, displayID: 42)
            try await source.activateGroupedSampling(expectedPolicySHA256: ScreenEvidenceAccessPolicy(config: config()).fingerprintSHA256())
            await source.captureImmediateAndResetTimer()
            restarted.continuation.finish()
            var frames: [CapturedFrame] = []
            for await frame in restarted.stream { frames.append(frame) }
            XCTAssertEqual(frames.count, 1, "A healthy restart cannot remain wedged by an old local group entry")
            try await source.stopCapture()
            try await delivery.cancelUnforwarded(reason: .sourceStopped)
            await journal.close()
        }
    }

    func testReceiptlessOutcomeCannotPredateEnumerationOrSuppressWithoutAnExactAnchor() throws {
        let descriptor = GroupPixelFixture.descriptor(displayID: 42)
        let attachment = descriptor.attachment(id: UUID())
        let stamp = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let interval = CaptureReadInterval(startedAt: stamp, endedAt: stamp, startedUptime: uptime, endedUptime: uptime)
        let group = CaptureSamplingGroup(groupID: UUID(), sessionID: UUID(), configurationGeneration: 1,
            backend: .screenCaptureKitCandidate, displayPolicy: .allDisplays,
            capturePolicySHA256: try ScreenEvidenceAccessPolicy(config: config()).fingerprintSHA256(),
            enumeration: interval, targets: [.init(attemptID: UUID(), attachment: attachment)])
        let member = CaptureGroupFrameReceipt(group: group, target: group.targets[0])
        let tooEarly = CaptureGroupEvent(occurredAt: stamp, monotonicTime: uptime - 1,
            payload: .attemptOutcome(.init(member: member, disposition: .unavailable, reason: .displayUnavailable)))
        XCTAssertThrowsError(try tooEarly.validatedEncoding(group: group))
        let receipt = CapturePixelReceipt(attemptID: member.attemptID, interval: interval)
        let unanchored = CaptureGroupEvent(occurredAt: stamp, monotonicTime: uptime,
            payload: .attemptOutcome(.init(member: member, disposition: .suppressedSimilar, pixelReceipt: receipt,
                comparison: .init(pixelThreshold: 0.9985, directTextEnabled: false))))
        XCTAssertThrowsError(try unanchored.validatedEncoding(group: group))
    }
}

actor GroupTestGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

actor GroupPixelFixture {
    private var targets = [GroupPixelFixture.descriptor(displayID: 42), GroupPixelFixture.descriptor(displayID: 43)]
    private var sleepingDisplays: Set<UInt32> = []
    private var reads = 0
    private var permissionRequests = 0
    private var stops = 0
    private var gate: GroupTestGate?
    private var entered: (@Sendable () -> Void)?
    nonisolated static func descriptor(displayID: UInt32) -> CaptureDisplayDescriptor {
        CaptureDisplayDescriptor(displayID: displayID,
            monitorUUID: UUID(uuidString: displayID == 42 ? "00000000-0000-0000-0000-000000000042" : "00000000-0000-0000-0000-000000000043")!,
            bounds: CGRect(x: displayID == 42 ? 0 : 64, y: 0, width: 64, height: 48),
            pixelWidth: 64, pixelHeight: 48, rotationDegrees: 0, refreshRateHz: 60, modeID: 1)
    }
    func onlyFirstDisplay() { targets = [Self.descriptor(displayID: 42)] }
    func removeAllDisplays() { targets = [] }
    func sleepSecondDisplay() { sleepingDisplays = [43] }
    func readCount() -> Int { reads }
    func requestPermission() -> Bool { permissionRequests += 1; return true }
    func permissionRequestCount() -> Int { permissionRequests }
    func isFirstStop() -> Bool { stops += 1; return stops == 1 }
    func holdNextRead(_ gate: GroupTestGate, entered: @escaping @Sendable () -> Void) { self.gate = gate; self.entered = entered }
    nonisolated func environment() -> ScreenCaptureEnvironment {
        ScreenCaptureEnvironment(displays: { await self.displays() }, context: { display, _ in
            CapturedWindowSample(context: nil, privacySignature: "owned-native-raster", displayOnlyID: display.displayID)
        }, attributedPixels: { display, _, _, _, attempt in
            try await self.pixels(display: display, attempt: attempt)
        })
    }
    private func displays() -> [CaptureDisplayTarget] { targets.map { CaptureDisplayTarget(descriptor: $0, isAsleep: sleepingDisplays.contains($0.displayID)) } }
    private func pixels(display: CaptureDisplayTarget, attempt: CapturePixelAttempt?) async throws -> CaptureAttributedPixelRead? {
        let read = try await CaptureVisibleTextReader.readImage(proof: nil, context: nil, enabled: false,
            backend: .screenCaptureKitCandidate, reservedAttemptID: attempt?.id, pixelReadCompleted: attempt?.didRead) {
                try await self.makeImage()
            }
        guard let read else { return nil }
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.draw(read.image, in: CGRect(x: 0, y: 0, width: 64, height: 48))
        let frame = CapturedFrame(timestamp: read.pixelReceipt.interval.startedAt,
            imageData: Data(bytes: try XCTUnwrap(context.data), count: 256 * 48), width: 64, height: 48,
            bytesPerRow: 256, metadata: FrameMetadata(displayID: display.displayID))
        return CaptureAttributedPixelRead(frame: frame, pixelReceipt: read.pixelReceipt)
    }
    private func makeImage() async throws -> CGImage {
        reads += 1
        let gate = gate, entered = entered; self.gate = nil; self.entered = nil
        entered?(); await gate?.wait()
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        return try XCTUnwrap(context.makeImage())
    }
}

actor GroupFileJournal: CaptureGroupJournalProtocol {
    private let url: URL
    private let file: FileHandle
    private var recorded: [CaptureGroupEvent] = []
    private var groups: [UUID: CaptureSamplingGroup] = [:]
    private var nextBeginGate: GroupTestGate?
    private var beginEntered: (@Sendable () -> Void)?
    private var rejectReference = false
    private var failWrite = false
    private var candidateFailure: Bool?
    private var suppression: (@Sendable () -> Void)?
    private var outcomeCallback: (@Sendable (CaptureAttemptOutcome) -> Void)?
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-group-journal-\(UUID()).jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { throw CocoaError(.fileWriteUnknown) }
        file = try FileHandle(forWritingTo: url)
    }
    func holdNextBegin(_ gate: GroupTestGate, entered: @escaping @Sendable () -> Void) { nextBeginGate = gate; beginEntered = entered }
    func onSuppression(_ callback: @escaping @Sendable () -> Void) { suppression = callback }
    func onOutcome(_ callback: @escaping @Sendable (CaptureAttemptOutcome) -> Void) { outcomeCallback = callback }
    func rejectNextReference() { rejectReference = true }
    func failNextWrite() { failWrite = true }
    func failNextCandidate(acknowledgementLost: Bool) { candidateFailure = acknowledgementLost }
    func events() -> [CaptureGroupEvent] { recorded }
    func appendCaptureGroupEvent(_ event: CaptureGroupEvent) async throws {
        if let previous = recorded.first(where: { $0.eventID == event.eventID }) {
            guard previous == event else { throw CaptureGroupJournalError.invalidTransition }
            return
        }
        var loseAcknowledgement = false
        if case .attemptOutcome(let outcome) = event.payload, outcome.disposition == .retainedCandidate,
           let afterWrite = candidateFailure {
            candidateFailure = nil
            if !afterWrite { throw CaptureGroupJournalError.unavailable }
            loseAcknowledgement = true
        }
        if failWrite { failWrite = false; throw CaptureGroupJournalError.unavailable }
        let group: CaptureSamplingGroup?
        switch event.payload {
        case .began(let descriptor):
            let gate = nextBeginGate, entered = beginEntered; nextBeginGate = nil; beginEntered = nil
            entered?(); await gate?.wait()
            group = nil; groups[descriptor.groupID] = descriptor
        case .attemptOutcome(let outcome):
            if outcome.disposition == .suppressedSimilar, rejectReference {
                rejectReference = false; throw CaptureGroupJournalError.referenceUnavailable
            }
            group = groups[outcome.member.groupID]
        case .samplingEnded(let end): group = groups[end.groupID]
        }
        let encoded = try event.validatedEncoding(group: group)
        try file.seekToEnd(); try file.write(contentsOf: encoded + Data([10])); try file.synchronize()
        recorded.append(event)
        if loseAcknowledgement { throw CaptureGroupJournalError.unavailable }
        if case .attemptOutcome(let outcome) = event.payload, outcome.disposition == .suppressedSimilar { suppression?() }
        if case .attemptOutcome(let outcome) = event.payload { outcomeCallback?(outcome) }
    }
    func readDurableEvents() throws -> [CaptureGroupEvent] {
        try Data(contentsOf: url).split(separator: 10).map { try JSONDecoder().decode(CaptureGroupEvent.self, from: Data($0)) }
    }
    func close() { try? file.close(); try? FileManager.default.removeItem(at: url) }
}

private actor GroupMetadataProvider: FrontmostMetadataProviding {
    func getFrontmostAppInfo(includeBrowserURL: Bool) async -> FrameMetadata { .empty }
}
