import Foundation
import XCTest
import Database
import Shared
import Storage
@testable import App

final class CompanionSettingsTests: XCTestCase {
    func testSupersededHeldEnrollmentResetCannotCloseNewerConfiguration() async throws {
        let entered = expectation(description: "Older enrollment reset reaches submitted metric")
        let held = HeldEnrollmentMetric(entered: { entered.fulfill() })
        let fixture = try await Fixture.make(markerMetrics: { action, outcome in
            if action == .companionEnrollment, outcome == .submitted { await held.submit() }
        })
        let old = try await fixture.markers.setCompanionEnrollment(enabled: true)
        await held.arm()
        let firstReservation = fixture.owner.reserveConfiguration()
        let older = Task { try await fixture.owner.prepareEnrollmentReset(reservation: firstReservation) }
        await fulfillment(of: [entered], timeout: 3)
        let newerReservation = fixture.owner.reserveConfiguration()
        let completedEarly = expectation(description: "New configuration must join the held older reset")
        completedEarly.isInverted = true
        let newer = Task {
            try await fixture.owner.prepareEnrollmentReset(reservation: newerReservation)
            try await fixture.owner.configure(.init(endpoint: URL(string: "http://127.0.0.1:9013/retrace-companion")!,
                bearerToken: String(repeating: "b", count: 48)), reservation: newerReservation, restartEnrollment: true)
            completedEarly.fulfill()
        }
        await fulfillment(of: [completedEarly], timeout: 0.2)
        await held.release()
        do { try await older.value; XCTFail("Superseded reset must not report success") }
        catch { XCTAssertEqual(error as? CompanionError, .staleEvidence) }
        try await newer.value
        let active = try await fixture.markers.companionEnrollment()
        XCTAssertEqual(active?.active, true)
        XCTAssertNotEqual(active?.id, old?.id)
        let fresh = manifest(try await fixture.database.activityStoreID())
        _ = try await fixture.markers.registerAudioManifest(fresh)
        let admitted = try await fixture.markers.companionBatchCandidate(manifestID: fresh.id)
        XCTAssertEqual(admitted?.enrollmentID, active?.id, "The superseded reset cannot silently disable new enrollment")
        try await fixture.close()
    }

    func testCloseJoinsHeldEnrollmentPreparation() async throws {
        let entered = expectation(description: "Preparation reaches held metric")
        let held = HeldEnrollmentMetric(entered: { entered.fulfill() })
        let fixture = try await Fixture.make(markerMetrics: { action, outcome in
            if action == .companionEnrollment, outcome == .submitted { await held.submit() }
        })
        await held.arm()
        let reservation = fixture.owner.reserveConfiguration()
        let preparation = Task { try await fixture.owner.prepareEnrollmentReset(reservation: reservation) }
        await fulfillment(of: [entered], timeout: 3)
        let closedEarly = expectation(description: "Close must join preparation and its metric")
        closedEarly.isInverted = true
        let close = Task { try await fixture.owner.close(); closedEarly.fulfill() }
        await fulfillment(of: [closedEarly], timeout: 0.2)
        await held.release()
        do { try await preparation.value; XCTFail("Close cancels pending preparation") }
        catch is CancellationError {}
        try await close.value
        try await fixture.close()
    }

    func testCrashAfterNewCredentialWriteCannotRestoreThePriorEnrollment() async throws {
        let fixture = try await Fixture.make()
        let old = try await fixture.markers.setCompanionEnrollment(enabled: true)
        let disabledPeriod = manifest(try await fixture.database.activityStoreID())
        _ = try await fixture.markers.registerAudioManifest(disabledPeriod)
        let credentials = MemoryCredentials()
        credentials.failAfterNextWrite()
        let settings = CompanionSettingsService(controller: fixture.owner, credentials: credentials.operations)
        do {
            try await settings.configure(endpoint: URL(string: "http://127.0.0.1:9013/retrace-companion")!,
                bearerToken: String(repeating: "a", count: 48))
            XCTFail("The injected interruption occurs after credentials commit but before configuration applies")
        } catch { }
        XCTAssertNotNil(try credentials.read())
        let interrupted = try await fixture.markers.companionEnrollment()
        XCTAssertNil(interrupted, "The previous epoch must close before enabled credentials become durable")
        try await settings.close(); try await fixture.close(removeFiles: false)
        let restarted = try await Fixture.make(root: fixture.root)
        let restored = CompanionSettingsService(controller: restarted.owner, credentials: credentials.operations)
        try await restored.restore()
        let current = try await restarted.markers.companionEnrollment()
        XCTAssertEqual(current?.active, true)
        XCTAssertNotEqual(current?.id, old?.id)
        let eligible = try await restarted.markers.companionBatchCandidates(now: Date(), limit: 8)
        XCTAssertTrue(eligible.isEmpty)
        try await restored.close(); try await restarted.close()
    }

    func testEnableWithAbsentCredentialsCannotReuseInterruptedDisconnectEnrollment() async throws {
        let fixture = try await Fixture.make()
        let old = try await fixture.markers.setCompanionEnrollment(enabled: true)
        let duringInterruptedDisable = manifest(try await fixture.database.activityStoreID())
        _ = try await fixture.markers.registerAudioManifest(duringInterruptedDisable)
        let settings = CompanionSettingsService(controller: fixture.owner, credentials: MemoryCredentials().operations)
        // Deliberately skip startup restore: a same-process retry must also close
        // the prior epoch when the persisted configuration is absent.
        try await settings.configure(endpoint: URL(string: "http://127.0.0.1:9013/retrace-companion")!,
            bearerToken: String(repeating: "a", count: 48))
        let next = try await fixture.markers.companionEnrollment()
        XCTAssertNotEqual(next?.id, old?.id)
        let eligible = try await fixture.markers.companionBatchCandidates(now: Date(), limit: 8)
        XCTAssertTrue(eligible.isEmpty)
        try await settings.close(); try await fixture.close()
    }

    func testRestartAfterInterruptedDisconnectClosesEnrollmentBeforeNewMedia() async throws {
        let fixture = try await Fixture.make()
        let old = try await fixture.markers.setCompanionEnrollment(enabled: true)
        let before = manifest(try await fixture.database.activityStoreID())
        _ = try await fixture.markers.registerAudioManifest(before)
        // The Keychain removal committed, but the process exited before its
        // asynchronous controller transition closed the old enrollment.
        let credentials = MemoryCredentials()
        try credentials.write(nil)
        try await fixture.close(removeFiles: false)
        let restarted = try await Fixture.make(root: fixture.root)
        let settings = CompanionSettingsService(controller: restarted.owner, credentials: credentials.operations)
        try await settings.restore()
        let closed = try await restarted.markers.companionEnrollment()
        XCTAssertNil(closed, "The getter returns only the active enrollment")
        let disabled = manifest(try await restarted.database.activityStoreID())
        _ = try await restarted.markers.registerAudioManifest(disabled)
        let disabledCandidate = try await restarted.markers.companionBatchCandidate(manifestID: disabled.id)
        XCTAssertNil(disabledCandidate)
        try await settings.configure(endpoint: URL(string: "http://127.0.0.1:9013/retrace-companion")!,
            bearerToken: String(repeating: "a", count: 48))
        let next = try await restarted.markers.companionEnrollment()
        XCTAssertEqual(next?.active, true)
        XCTAssertNotEqual(next?.id, old?.id)
        let pending = try await restarted.markers.companionBatchCandidates(now: Date(), limit: 8)
        XCTAssertTrue(pending.isEmpty, "Re-enabling must not admit either the old epoch or disabled-period recordings")
        let fresh = manifest(try await restarted.database.activityStoreID())
        _ = try await restarted.markers.registerAudioManifest(fresh)
        let admitted = try await restarted.markers.companionBatchCandidate(manifestID: fresh.id)
        XCTAssertEqual(admitted?.enrollmentID, next?.id)
        try await settings.close(); try await restarted.close()
    }

    func testOnlyPrivateMountedEndpointsAreAccepted() throws {
        for value in ["https://spare.example.ts.net/retrace-companion", "http://127.0.0.1:9013/retrace-companion/"] {
            XCTAssertNoThrow(try CompanionSettingsService.validate(try XCTUnwrap(URL(string: value))))
        }
        for value in ["https://example.com/retrace-companion", "https://spare.example.ts.net/",
                      "https://spare.example.ts.net/retrace-companion?token=secret",
                      "https://user@spare.example.ts.net/retrace-companion", "http://spare.example.ts.net/retrace-companion",
                      "https://spare.example.ts.net:8443/retrace-companion"] {
            XCTAssertThrowsError(try CompanionSettingsService.validate(try XCTUnwrap(URL(string: value))))
        }
    }

    func testStateDoesNotActivateSavedConfigurationOrExposeToken() async throws {
        let fixture = try await Fixture.make()
        let credentials = MemoryCredentials()
        let saved = CompanionSettingsService.Stored(endpoint: URL(string: "https://spare.example.ts.net/retrace-companion")!,
                                                     token: String(repeating: "s", count: 48))
        try credentials.write(JSONEncoder().encode(saved))
        let settings = CompanionSettingsService(controller: fixture.owner, credentials: credentials.operations)
        let state = await settings.state()
        XCTAssertEqual(state.endpoint, saved.endpoint.absoluteString)
        XCTAssertTrue(state.configured)
        let ownerState = await fixture.owner.status()
        XCTAssertEqual(ownerState.state, .unconfigured)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.companionRoot.path))
        try await settings.close()
        try await fixture.close()
    }

    func testDisableSupersedesHeldEnableBeforeTransportAdmission() async throws {
        let policy = HeldPolicy()
        let fixture = try await Fixture.make(policy: { await policy.enter() })
        let credentials = MemoryCredentials()
        let settings = CompanionSettingsService(controller: fixture.owner, credentials: credentials.operations)
        let enable = Task { try await settings.configure(endpoint: URL(string: "http://127.0.0.1:9013/retrace-companion")!,
                                                         bearerToken: String(repeating: "a", count: 48)) }
        let entered = await eventually { await policy.entered }
        XCTAssertTrue(entered)
        let disable = Task { try await settings.configure(endpoint: nil, bearerToken: nil) }
        let removed = await eventually { credentials.hasWrittenRemoval }
        XCTAssertTrue(removed, "Revocation must be durable before waiting for the obsolete enable")
        await policy.release()
        _ = await enable.result
        try await disable.value
        let state = await settings.state(), status = await fixture.owner.status()
        XCTAssertFalse(state.configured)
        XCTAssertNil(try credentials.read())
        XCTAssertEqual(status.state, .unconfigured)
        try await settings.close(); try await fixture.close()
    }

    func testFailedCredentialRemovalLeavesRuntimeSuspendedAndReportsFailure() async throws {
        let fixture = try await Fixture.make()
        let credentials = MemoryCredentials()
        let saved = CompanionSettingsService.Stored(endpoint: URL(string: "https://spare.example.ts.net/retrace-companion")!,
                                                     token: String(repeating: "s", count: 48))
        try credentials.write(JSONEncoder().encode(saved))
        let settings = CompanionSettingsService(controller: fixture.owner, credentials: credentials.operations)
        _ = await settings.state()
        credentials.failWrites()
        do { try await settings.configure(endpoint: nil, bearerToken: nil); XCTFail("A failed removal cannot report success") }
        catch {}
        let state = await settings.state(), status = await fixture.owner.status()
        XCTAssertTrue(state.configured, "Expose that the old persisted configuration still exists")
        XCTAssertNotNil(state.lastError)
        XCTAssertEqual(status.state, .suspended)
        do { try await settings.resumeAfterPolicyChange(); XCTFail("Policy changes must not undo a failed explicit disconnect") }
        catch { XCTAssertEqual(error as? CompanionError, .unavailable) }
        do { try await settings.restore(); XCTFail("Restore must not undo the persistence-failure suspension") }
        catch { XCTAssertEqual(error as? CompanionError, .unavailable) }
        let after = await settings.state(), afterStatus = await fixture.owner.status()
        XCTAssertEqual(after.lastError, state.lastError)
        XCTAssertEqual(afterStatus.state, .suspended)
        try await settings.close(); try await fixture.close()
    }

    private func eventually(_ predicate: () async -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < end {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }

    private func manifest(_ native: UUID) -> AudioMediaManifest {
        let id = UUID()
        return .init(id: id, nativeStoreID: native, relativePath: "audio/\(id).m4a",
            sha256: String(repeating: "a", count: 64), frameCount: 16000,
            sourceRanges: [.init(source: .init(recordingGeneration: UUID(), continuityID: UUID(), startSample: 0,
                sampleCount: 16000, sampleRate: 16000, approximateOrigin: Date(timeIntervalSince1970: 1_800_000_000)), batchStartSample: 0)])
    }

    private struct Fixture {
        let root: URL, companionRoot: URL
        let database: DatabaseManager
        let adapter: DataAdapter
        let markers: TimelineMarkerService
        let owner: CompanionController
        static func make(root existingRoot: URL? = nil, policy: @escaping @Sendable () async throws -> Void = {}, markerMetrics: @escaping TimelineMarkerService.Metrics = { _, _ in }) async throws -> Fixture {
            let root = existingRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("companion-settings-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let path = root.appendingPathComponent("recording.db").path
            let database = DatabaseManager(databasePath: path)
            try await database.initialize()
            let adapter = DataAdapter(retraceConnection: try await database.makeRecallReadConnection(),
                retraceConfig: .init(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
                retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
            try await adapter.initialize()
            let native = try await adapter.evidenceStoreID(source: .native)
            let recall = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() },
                imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
            let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { native }, metrics: markerMetrics)
            let companionRoot = root.appendingPathComponent("companion")
            let owner = CompanionController(storageRoot: companionRoot, nativeStoreID: native, databasePath: path,
                adapter: adapter, recall: recall, markers: markers,
                verifiedBytes: { _ in throw CompanionError.unavailable }, policy: policy)
            return .init(root: root, companionRoot: companionRoot, database: database, adapter: adapter, markers: markers, owner: owner)
        }
        func close(removeFiles: Bool = true) async throws {
            try await owner.close(); try await markers.close(); await adapter.shutdown(); try await database.close()
            if removeFiles { try FileManager.default.removeItem(at: root) }
        }
    }
}

private final class MemoryCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    private var failure = false
    private var failAfterWrite = false
    private var removal = false
    var operations: CompanionSettingsService.Credentials { .init(read: { try self.read() }, write: { try self.write($0) }) }
    var hasWrittenRemoval: Bool { lock.lock(); defer { lock.unlock() }; return removal }
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; return bytes }
    func write(_ value: Data?) throws {
        lock.lock(); defer { lock.unlock() }
        if failure { throw CompanionError.unsafeStorage }
        bytes = value; if value == nil { removal = true }
        if failAfterWrite { failAfterWrite = false; throw CompanionError.unsafeStorage }
    }
    func failWrites() { lock.lock(); failure = true; lock.unlock() }
    func failAfterNextWrite() { lock.lock(); failAfterWrite = true; lock.unlock() }
}
private actor HeldPolicy {
    private(set) var entered = false
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?
    func enter() async {
        entered = true
        if !released { await withCheckedContinuation { waiting = $0 } }
    }
    func release() { released = true; waiting?.resume(); waiting = nil }
}

private actor HeldEnrollmentMetric {
    private let entered: @Sendable () -> Void
    private var armed = false
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?
    init(entered: @escaping @Sendable () -> Void) { self.entered = entered }
    func arm() { armed = true }
    func submit() async {
        guard armed else { return }; armed = false
        entered()
        if !released { await withCheckedContinuation { waiting = $0 } }
    }
    func release() { released = true; waiting?.resume(); waiting = nil }
}
