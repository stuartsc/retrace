import CoreGraphics
import Database
import Foundation
import Shared
import XCTest
@testable import Capture

/// Public Capture lifecycle calls, a real private SQLite writer and owned pixel
/// streams. Only native device completion and durable acknowledgement delivery
/// are controlled; no desktop, application, Keychain or recording is consulted.
final class CaptureConfigurationAdmissionTests: XCTestCase {
    private var database: DatabaseManager!
    private var bridge: CaptureAdmissionTestBridge!
    private var source: AdmissionTestFrameSource!
    private var manager: CaptureManager!
    private var reference: ScreenEvidenceRef!
    private var cursor: ScreenEvidenceConsumerCursor!
    private var gates: [AdmissionTestGate] = []
    private var tasks: [Task<Void, Error>] = []
    private let queueEntries = AdmissionTestCounter()
    private let nativeCalls = AdmissionTestCounter()
    private let appID = "test.capture.admission.authored"
    private let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private var allowed: CaptureConfig { config(excluding: []) }
    private var denied: CaptureConfig { config(excluding: [appID]) }

    override func setUp() async throws {
        database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let segment = try await database.insertSegment(bundleID: appID, startDate: capturedAt,
            endDate: capturedAt, windowName: "Authored policy fixture", browserUrl: nil, type: 0)
        let descriptor = FrameReference(id: .init(value: 0), timestamp: capturedAt,
            segmentID: .init(value: segment), frameIndexInSegment: 0,
            metadata: .init(appBundleID: appID, windowName: "Authored policy fixture", displayID: 7))
        let frameID = FrameID(value: try await database.insertFrame(descriptor))
        let text = "Authored retained invoice 42000, not 47000."
        _ = try await database.commitFrameOCR(frameID: frameID,
            text: ExtractedText(frameID: frameID, timestamp: capturedAt,
                regions: [TextRegion(frameID: frameID, text: text,
                    bounds: CGRect(x: 1, y: 1, width: 30, height: 10))],
                fullText: text, metadata: descriptor.metadata), frameWidth: 32, frameHeight: 32)
        let storeID = try await database.activityStoreID()
        let snapshot = try await database.currentScreenEvidence(frameID: frameID, storeID: storeID)
        reference = try XCTUnwrap(snapshot).ref
        let consumer = try await database.beginScreenEvidenceBootstrap(consumerID: UUID(), leaseDuration: 120)
        cursor = consumer.cursor
        _ = try await database.advanceScreenEvidenceConsumer(cursor: cursor, limit: 10)
        _ = try await database.advanceScreenEvidenceConsumer(cursor: cursor, limit: 10)

        bridge = CaptureAdmissionTestBridge(database: database)
        let source = AdmissionTestFrameSource()
        self.source = source
        let nativeCalls = nativeCalls
        manager = CaptureManager(config: allowed, metadataProvider: AdmissionTestMetadata(),
            configurationAdmission: bridge, source: source,
            lifecycleEnvironment: CaptureLifecycleEnvironment(
                hasPermission: { nativeCalls.increment(); return await source.hasPermission() },
                activeDisplayID: { nativeCalls.increment(); return 7 },
                startDisplayMonitoring: { _ in nativeCalls.increment() },
                stopDisplayMonitoring: { nativeCalls.increment() }))
        let queueEntries = queueEntries
        await manager.setLifecycleEnqueuedCheckpoint { queueEntries.increment() }
    }

    override func tearDown() async throws {
        for task in tasks { task.cancel() }
        for gate in gates { await gate.release() }
        for task in tasks { _ = try? await task.value }
        try await manager?.stopCapture()
        try await manager?.shutdownConfigurationAdmission()
        try await bridge?.endSession()
        try await database?.close()
    }

    func testInitializationIsHardwareFreeAndReplacesThePriorWriterIncarnation() async throws {
        let old = try await seedActivePolicy()
        let oldReceipt = try await stageArtifact()
        try await manager.initializeConfigurationAdmission()
        XCTAssertEqual(nativeCalls.value, 0, "Opening historical authority must not request native capture")
        let starts = await source.startCount
        XCTAssertEqual(starts, 0)
        let fresh = try await probeClaim()
        XCTAssertNotEqual(fresh.policy.session.writerID, old.session.writerID,
                          "An owning startup cannot recover an earlier capability from disk")
        await assertUnreadable(oldReceipt)
        try await manager.shutdownConfigurationAdmission()
        await assertClaimDenied(.inactive)
        try await manager.initializeConfigurationAdmission()
        let restarted = try await probeClaim()
        XCTAssertNotEqual(restarted.policy.session.writerID, fresh.policy.session.writerID)
    }

    func testInitializationWaitsForTheExistingLifecycleSlot() async throws {
        let old = try await seedActivePolicy()
        let gate = makeGate()
        let blocker = launch { try await self.manager.runLifecycleOperation { await gate.hold() } }
        guard await requireEntered(gate) else { return }
        let initialization = launch { try await self.manager.initializeConfigurationAdmission() }
        await requireQueueEntries(2)
        let during = try await probeClaim()
        XCTAssertEqual(during.policy.session, old.session)
        await gate.release()
        try await blocker.value
        try await initialization.value
        let after = try await probeClaim()
        XCTAssertNotEqual(after.policy.session.writerID, old.session.writerID)
    }

    func testExplicitStartupDeactivatesBeforeNativeSourceApplicationAndActivatesItsPolicy() async throws {
        _ = try await seedActivePolicy()
        let receipt = try await stageArtifact()
        let gate = makeGate()
        await source.holdNextStart(gate)
        let start = launch { try await self.manager.startCapture(config: self.denied) }
        guard await requireEntered(gate) else { return }
        await assertUnreadable(receipt)
        await assertClaimDenied(.inactive)
        await gate.release()
        try await start.value
        await assertClaimDenied(.notPermitted)
        let applied = await source.lastConfiguration
        XCTAssertEqual(applied.map(ScreenEvidenceAccessPolicy.init(config:)), ScreenEvidenceAccessPolicy(config: denied))
    }

    func testRuntimeUpdateDeactivatesBeforeNativeSourceAcknowledgement() async throws {
        _ = try await seedActivePolicy()
        try await manager.startCapture(config: allowed)
        let receipt = try await stageArtifact()
        let gate = makeGate()
        await source.holdNextUpdate(gate)
        let update = launch { try await self.manager.updateConfig(self.denied) }
        guard await requireEntered(gate) else { return }
        await assertUnreadable(receipt)
        await assertClaimDenied(.inactive)
        await gate.release()
        try await update.value
        await assertClaimDenied(.notPermitted)
    }

    func testPausedConfigurationChangeAndRoundTripCannotReviveAnOldArtifact() async throws {
        let old = try await seedActivePolicy()
        let receipt = try await stageArtifact()
        try await manager.updateConfig(denied)
        await assertClaimDenied(.notPermitted)
        try await manager.updateConfig(allowed)
        let current = try await probeClaim()
        XCTAssertEqual(current.policy.session, old.session, "Settings do not create a new app incarnation")
        XCTAssertGreaterThan(current.policy.policyEpoch, old.policyEpoch)
        await assertUnreadable(receipt)
        let starts = await source.startCount
        XCTAssertEqual(starts, 0, "Updating historical privacy while paused must not start capture")
    }

    func testNativeStartupFailureLeavesAdmissionInactiveAndJoinsTheOwnedStream() async throws {
        _ = try await seedActivePolicy()
        await source.failNextStart()
        do {
            try await manager.startCapture(config: denied)
            XCTFail("The actual source failure must reach the caller")
        } catch AdmissionTestFailure.nativeSource { }
        await assertClaimDenied(.inactive)
        let active = await source.isActive
        XCTAssertFalse(active, "Partially acquired source must be stopped before failed startup returns")
        let capturing = await manager.isCapturing
        XCTAssertFalse(capturing)
    }

    func testAdmittedPermissionDenialClosesAdmissionBeforeAnySourceStarts() async throws {
        _ = try await seedActivePolicy()
        let receipt = try await stageArtifact()
        await source.setPermission(false)
        do {
            try await manager.startCapture(config: denied)
            XCTFail("Permission denial must fail startup")
        } catch CaptureError.permissionDenied { }
        let starts = await source.startCount
        XCTAssertEqual(starts, 0, "A denied startup cannot acquire the native source")
        let capturing = await manager.isCapturing
        XCTAssertFalse(capturing)
        await assertClaimDenied(.inactive)
        await assertUnreadable(receipt)

        await source.setPermission(true)
        try await manager.startCapture(config: allowed)
        _ = try await probeClaim()
        await assertUnreadable(receipt)
    }

    func testNativeRuntimeFailureLeavesAdmissionInactiveUntilAnExplicitRetry() async throws {
        _ = try await seedActivePolicy()
        try await manager.startCapture(config: allowed)
        let receipt = try await stageArtifact()
        await source.failNextUpdate()
        do {
            try await manager.updateConfig(denied)
            XCTFail("The actual source failure must reach the caller")
        } catch AdmissionTestFailure.nativeSource { }
        await assertClaimDenied(.inactive)
        await assertUnreadable(receipt)
        try await manager.updateConfig(allowed)
        let retry = try await probeClaim()
        XCTAssertGreaterThan(retry.policy.policyEpoch, receipt.claim.policy.policyEpoch)
        await assertUnreadable(receipt)
    }

    func testCancellingAdmittedStartupJoinsLateSourceAndRevokesAdmission() async throws {
        _ = try await seedActivePolicy()
        let gate = makeGate()
        await source.holdNextStart(gate)
        let start = launch { try await self.manager.startCapture(config: self.allowed) }
        guard await requireEntered(gate) else { return }
        start.cancel()
        await gate.release()
        await assertCancelled(start)
        await assertClaimDenied(.inactive)
        let active = await source.isActive
        XCTAssertFalse(active)
        try await manager.startCapture(config: allowed)
        _ = try await claim()
    }

    func testCancellingAdmittedRuntimeUpdateDoesNotReactivateItsPreviousEpoch() async throws {
        _ = try await seedActivePolicy()
        try await manager.startCapture(config: allowed)
        let receipt = try await stageArtifact()
        let gate = makeGate()
        await source.holdNextUpdate(gate)
        let update = launch { try await self.manager.updateConfig(self.denied) }
        guard await requireEntered(gate) else { return }
        update.cancel()
        await gate.release()
        await assertCancelled(update)
        await assertClaimDenied(.inactive)
        await assertUnreadable(receipt)
    }

    func testCancellationAfterRealActivationCommitJoinsExactRevocationBeforeReturning() async throws {
        _ = try await seedActivePolicy()
        let activation = makeGate()
        let revocation = makeGate()
        await bridge.holdNextActivation(activation)
        await bridge.holdNextRevocation(revocation)
        let finished = AdmissionTestCounter()
        let update = launch {
            defer { finished.increment() }
            try await self.manager.updateConfig(self.allowed)
        }
        guard await requireEntered(activation) else { return }
        let committed = try await probeClaim()
        update.cancel()
        await activation.release()
        guard await requireEntered(revocation) else { return }
        XCTAssertEqual(finished.value, 0, "Cancelled caller must join the real revocation acknowledgement")
        await assertClaimDenied(.inactive)
        await revocation.release()
        await assertCancelled(update)
        do {
            try await database.activateScreenEvidencePolicy(committed.policy)
            XCTFail("A revoked transition must never reactivate")
        } catch let error as ScreenEvidenceAdmissionError {
            XCTAssertTrue([.inactive, .stalePolicy, .staleSession].contains(error))
        }
    }

    func testCancelledQueuedUpdateCannotApplyOrRevokeTheFollowingConfiguration() async throws {
        _ = try await seedActivePolicy()
        let gate = makeGate()
        let blocker = launch { try await self.manager.runLifecycleOperation { await gate.hold() } }
        guard await requireEntered(gate) else { return }
        let cancelled = launch { try await self.manager.updateConfig(self.denied) }
        await requireQueueEntries(2)
        let nextConfig = config(excluding: ["test.other.application"])
        let next = launch { try await self.manager.updateConfig(nextConfig) }
        await requireQueueEntries(3)
        cancelled.cancel()
        let before = await manager.getConfig()
        XCTAssertEqual(ScreenEvidenceAccessPolicy(config: before), ScreenEvidenceAccessPolicy(config: allowed))
        await gate.release()
        try await blocker.value
        await assertCancelled(cancelled)
        try await next.value
        let receipt = try await stageArtifact()
        let read = try await database.readScreenEvidenceArtifact(receipt)
        XCTAssertEqual(read.data, artifact)
        let after = await manager.getConfig()
        XCTAssertEqual(ScreenEvidenceAccessPolicy(config: after), ScreenEvidenceAccessPolicy(config: nextConfig))
        let prepared = await bridge.preparedPolicies
        XCTAssertFalse(prepared.contains(ScreenEvidenceAccessPolicy(config: denied)),
                       "A cancelled caller that never owned the slot must not prepare a policy")
    }

    func testCancelledQueuedInitializationCannotRevokeTheFollowingWriter() async throws {
        try await assertQueuedCancellationPreservesFollowingWriter { manager, _ in
            try await manager.initializeConfigurationAdmission()
        }
    }

    func testCancelledQueuedStartupCannotAcquireSourceOrRevokeTheFollowingWriter() async throws {
        try await assertQueuedCancellationPreservesFollowingWriter { manager, config in
            try await manager.startCapture(config: config)
        }
    }

    func testCurrentConfigurationIsSelectedAfterEarlierQueuedUpdateCompletes() async throws {
        _ = try await seedActivePolicy()
        let gate = makeGate()
        let blocker = launch { try await self.manager.runLifecycleOperation { await gate.hold() } }
        guard await requireEntered(gate) else { return }
        let update = launch { try await self.manager.updateConfig(self.denied) }
        await requireQueueEntries(2)
        let start = launch { try await self.manager.startUsingCurrentConfiguration() }
        await requireQueueEntries(3)
        await gate.release()
        try await blocker.value
        try await update.value
        try await start.value
        let applied = await source.lastConfiguration
        XCTAssertEqual(applied.map(ScreenEvidenceAccessPolicy.init(config:)), ScreenEvidenceAccessPolicy(config: denied),
                       "Startup must not overwrite the earlier queued privacy change with a prequeue snapshot")
        await assertClaimDenied(.notPermitted)
    }

    func testShutdownWaitsForHeldActivationThenClosesAuthorityEvenWhileCaptureIsPaused() async throws {
        _ = try await seedActivePolicy()
        let activation = makeGate()
        await bridge.holdNextActivation(activation)
        let update = launch { try await self.manager.updateConfig(self.allowed) }
        guard await requireEntered(activation) else { return }
        let shutdown = launch { try await self.manager.shutdownConfigurationAdmission() }
        await requireQueueEntries(2)
        await activation.release()
        try await update.value
        try await shutdown.value
        await assertClaimDenied(.inactive)
        do {
            try await manager.updateConfig(allowed)
            XCTFail("An ended owner cannot reactivate through a late settings callback")
        } catch let error as ScreenEvidenceAdmissionError {
            XCTAssertTrue([.inactive, .staleSession].contains(error))
        }
        await assertClaimDenied(.inactive)
    }

    func testOrdinaryPausePreservesHistoricalAuthorityAndDrainsTheRealPixelStream() async throws {
        _ = try await seedActivePolicy()
        try await manager.startCapture(config: allowed)
        let stream = await manager.frameStream
        let received = expectation(description: "authored CoreGraphics pixels traversed production forwarding")
        let collector = Task { () -> CapturedFrame? in
            for await frame in stream { received.fulfill(); return frame }
            return nil
        }
        let expected = try pixels()
        await source.yield(expected)
        await fulfillment(of: [received], timeout: 3)
        try await manager.stopCapture()
        let output = await collector.value
        XCTAssertEqual(output?.imageData, expected.imageData)
        let receipt = try await stageArtifact()
        let retained = try await database.readScreenEvidenceArtifact(receipt)
        XCTAssertEqual(retained.data, artifact)
    }

    private var artifact: Data { Data("authored unpublished artifact".utf8) }

    private func config(excluding: Set<String>) -> CaptureConfig {
        CaptureConfig(adaptiveCaptureEnabled: false, excludedAppBundleIDs: excluding,
                      excludePrivateWindows: false, captureOnWindowChange: false)
    }

    /// A pre-existing capable writer is real setup for the individual assignment
    /// tests; startup's installation itself is covered separately above.
    private func seedActivePolicy() async throws -> ScreenEvidencePolicyTransition {
        let transition = try await bridge.beginSession(config: allowed)
        try await bridge.activate(transition)
        return transition
    }

    private func claim() async throws -> ScreenEvidenceDerivationClaim {
        try await database.claimScreenEvidenceDerivation(ScreenEvidenceDerivationRequest(cursor: cursor,
            expansion: .init(reference: reference, blockLimit: 4, maximumUTF8Bytes: 1024), channel: .lexical,
            transformation: .init(identifier: "capture-admission-authored-v1",
                fingerprintSHA256: String(repeating: "a", count: 64), artifactFormat: "authored-opaque-v1"),
            executionDuration: 30))
    }

    private func probeClaim() async throws -> ScreenEvidenceDerivationClaim {
        let admitted = try await claim()
        try await database.cancelScreenEvidenceDerivation(admitted)
        return admitted
    }

    private func stageArtifact() async throws -> ScreenEvidenceArtifactReceipt {
        let acquired = try await claim()
        return try await database.stageScreenEvidenceArtifact(claim: acquired, data: artifact)
    }

    private func assertQueuedCancellationPreservesFollowingWriter(
        _ operation: @escaping @Sendable (CaptureManager, CaptureConfig) async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let original = try await seedActivePolicy()
        let gate = makeGate()
        let blocker = launch { try await self.manager.runLifecycleOperation { await gate.hold() } }
        guard await requireEntered(gate, file: file, line: line) else { return }
        let cancelled = launch { try await operation(self.manager, self.denied) }
        await requireQueueEntries(2, file: file, line: line)
        cancelled.cancel()
        let following = launch { try await self.manager.initializeConfigurationAdmission() }
        await requireQueueEntries(3, file: file, line: line)
        await gate.release()
        try await blocker.value
        await assertCancelled(cancelled, file: file, line: line)
        try await following.value

        let receipt = try await stageArtifact()
        XCTAssertNotEqual(receipt.claim.policy.session.writerID, original.session.writerID, file: file, line: line)
        let retained = try await database.readScreenEvidenceArtifact(receipt)
        XCTAssertEqual(retained.data, artifact, file: file, line: line)
        let starts = await source.startCount
        XCTAssertEqual(starts, 0, "A caller cancelled before admission must never start a source", file: file, line: line)
        XCTAssertEqual(nativeCalls.value, 0, "Queued cancellation must be checked before native permission/display calls", file: file, line: line)
        let opened = await bridge.begunSessions
        XCTAssertEqual(opened.count, 2, "Only the original and following owners may create real writer incarnations", file: file, line: line)
        let revoked = await bridge.revokedTransitions
        XCTAssertTrue(revoked.isEmpty, "A cancelled unadmitted operation owns no transition to revoke", file: file, line: line)
        let prepared = await bridge.preparedPolicies
        XCTAssertFalse(prepared.contains(ScreenEvidenceAccessPolicy(config: denied)), file: file, line: line)
    }

    private func assertClaimDenied(_ expected: ScreenEvidenceAdmissionError,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let admitted = try await claim()
            try await database.cancelScreenEvidenceDerivation(admitted)
            XCTFail("Claim unexpectedly admitted", file: file, line: line)
        }
        catch let error as ScreenEvidenceAdmissionError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("Unexpected failure: \(error)", file: file, line: line) }
    }

    private func assertUnreadable(_ receipt: ScreenEvidenceArtifactReceipt,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await database.readScreenEvidenceArtifact(receipt)
            XCTFail("Old artifact remained readable across the policy boundary", file: file, line: line)
        } catch let error as ScreenEvidenceAdmissionError {
            XCTAssertTrue([.inactive, .staleSession, .stalePolicy, .notPermitted, .artifactUnavailable].contains(error),
                          "Unexpected refusal: \(error)", file: file, line: line)
        } catch { XCTFail("Unexpected failure: \(error)", file: file, line: line) }
    }

    private func assertCancelled(_ task: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await task.value; XCTFail("Cancelled owner reported success", file: file, line: line) }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation, received \(error)", file: file, line: line) }
    }

    private func launch(_ operation: @escaping @Sendable () async throws -> Void) -> Task<Void, Error> {
        let task = Task { try await operation() }
        tasks.append(task)
        return task
    }

    private func makeGate() -> AdmissionTestGate {
        let gate = AdmissionTestGate()
        gates.append(gate)
        return gate
    }

    private func requireEntered(_ gate: AdmissionTestGate, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        guard await eventually({ await gate.entered }) else {
            XCTFail("Production operation never reached the held boundary", file: file, line: line)
            return false
        }
        return true
    }

    private func requireQueueEntries(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let arrived = await eventually { self.queueEntries.value >= count }
        XCTAssertTrue(arrived, "Public operation bypassed the lifecycle queue", file: file, line: line)
    }

    private func eventually(_ predicate: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await !predicate() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5), clock: .continuous)
        }
        return true
    }

    private func pixels() throws -> CapturedFrame {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return CapturedFrame(timestamp: capturedAt,
            imageData: Data(bytes: try XCTUnwrap(context.data), count: 4096),
            width: 32, height: 32, bytesPerRow: 128,
            metadata: .init(appBundleID: appID, displayID: 7))
    }
}

private enum AdmissionTestFailure: Error { case nativeSource }

private struct AdmissionTestMetadata: FrontmostMetadataProviding {
    func getFrontmostAppInfo(includeBrowserURL: Bool) async -> FrameMetadata {
        XCTFail("Lifecycle fixture must not request frontmost application metadata")
        return .empty
    }
}

private final class AdmissionTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// External completion deliberately ignores cancellation, like a native API that
/// returns late. Release-before-entry is supported so teardown cannot strand it.
private actor AdmissionTestGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func hold() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor AdmissionTestFrameSource: CaptureFrameSource {
    private var continuation: AsyncStream<CapturedFrame>.Continuation?
    private var startGate: AdmissionTestGate?
    private var updateGate: AdmissionTestGate?
    private var startFailure = false
    private var updateFailure = false
    private var permissionGranted = true
    private(set) var isActive = false
    private(set) var startCount = 0
    private(set) var lastConfiguration: CaptureConfig?

    func holdNextStart(_ gate: AdmissionTestGate) { startGate = gate }
    func holdNextUpdate(_ gate: AdmissionTestGate) { updateGate = gate }
    func failNextStart() { startFailure = true }
    func failNextUpdate() { updateFailure = true }
    func setPermission(_ granted: Bool) { permissionGranted = granted }
    func hasPermission() -> Bool { permissionGranted }

    func startCapture(config: CaptureConfig, frameContinuation: AsyncStream<CapturedFrame>.Continuation,
                      displayID: CGDirectDisplayID?) async throws {
        let gate = startGate; startGate = nil
        startCount += 1
        continuation = frameContinuation
        isActive = true
        lastConfiguration = config
        await gate?.hold()
        if startFailure { startFailure = false; throw AdmissionTestFailure.nativeSource }
    }
    func updateConfig(_ config: CaptureConfig) async throws {
        let gate = updateGate; updateGate = nil
        lastConfiguration = config
        await gate?.hold()
        if updateFailure { updateFailure = false; throw AdmissionTestFailure.nativeSource }
    }
    func stopCapture() {
        isActive = false
        continuation = nil
    }
    func captureImmediateAndResetTimer() { }
    func yield(_ frame: CapturedFrame) { continuation?.yield(frame) }
}

/// Forward every authority decision to the production database. Holds are after
/// the actual commit and change only delivery of the acknowledgement.
private actor CaptureAdmissionTestBridge: CaptureConfigurationAdmissionProtocol {
    private let database: DatabaseManager
    private var session: ScreenEvidenceWriterSession?
    private var activationGate: AdmissionTestGate?
    private var revocationGate: AdmissionTestGate?
    private(set) var preparedPolicies: [ScreenEvidenceAccessPolicy] = []
    private(set) var begunSessions: [ScreenEvidenceWriterSession] = []
    private(set) var revokedTransitions: [ScreenEvidencePolicyTransition] = []

    init(database: DatabaseManager) { self.database = database }
    func holdNextActivation(_ gate: AdmissionTestGate) { activationGate = gate }
    func holdNextRevocation(_ gate: AdmissionTestGate) { revocationGate = gate }

    func beginSession(config: CaptureConfig) async throws -> ScreenEvidencePolicyTransition {
        let transition = try await database.beginScreenEvidenceWriterSession(policy: .init(config: config))
        session = transition.session
        begunSessions.append(transition.session)
        return transition
    }
    func prepareConfiguration(_ config: CaptureConfig) async throws -> ScreenEvidencePolicyTransition {
        guard let session else { throw ScreenEvidenceAdmissionError.inactive }
        let policy = ScreenEvidenceAccessPolicy(config: config)
        let transition = try await database.prepareScreenEvidencePolicy(session: session, policy: policy)
        preparedPolicies.append(policy)
        return transition
    }
    func activate(_ transition: ScreenEvidencePolicyTransition) async throws {
        try await database.activateScreenEvidencePolicy(transition)
        let gate = activationGate; activationGate = nil
        await gate?.hold()
    }
    func revoke(_ transition: ScreenEvidencePolicyTransition) async throws {
        try await database.revokeScreenEvidencePolicy(transition)
        revokedTransitions.append(transition)
        let gate = revocationGate; revocationGate = nil
        await gate?.hold()
    }
    func endSession() async throws {
        guard let session else { return }
        try await database.endScreenEvidenceWriterSession(session)
        self.session = nil
    }
}
