import Foundation
import Shared
import XCTest
@testable import App

final class NativeControlCommandTests: XCTestCase {
    func testIdenticalLocalConfigurationRetryRestoresAdmissionAfterExpiredRemoteUpdate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let services = ServiceContainer(databasePath: "file:native_control_\(UUID())?mode=memory&cache=private",
            storageConfig: .init(storageRootPath: root.path))
        await services.setInitializationBoundaryForTesting(remainder: {})
        try await services.initialize()
        let coordinator = AppCoordinator(services: services)
        let original = await coordinator.getCaptureConfig()
        let proposed = CaptureConfig(captureIntervalSeconds: original.captureIntervalSeconds == 10 ? 20 : 10)
        let clock = ConfigurationExpiryClock()
        let fence = NativeMutationFence(expiresAt: Date(timeIntervalSince1970: 100), clock: { clock.now() })
        do {
            try await coordinator.updateCaptureConfig(proposed, commandFence: fence)
            XCTFail("Grant expires after policy preparation")
        } catch is CancellationError { }
        let restored = await coordinator.getCaptureConfig()
        let inactive = await services.capture.hasActiveConfigurationAdmission()
        XCTAssertEqual(restored, original)
        XCTAssertFalse(inactive, "Failed update leaves evidence policy revoked")
        try await coordinator.updateCaptureConfig(original)
        let active = await services.capture.hasActiveConfigurationAdmission()
        XCTAssertTrue(active, "Same-config local retry must pass the real admission transaction")
        try await services.shutdown()
        try FileManager.default.removeItem(at: root)
    }

    func testCancelledCommandAtSecondLifecycleHandoffCannotBeginPrivacyFenceOrTeardown() async throws {
        let lifecycle = RecordingLifecycle()
        let entered = expectation(description: "native lifecycle held")
        let queued = expectation(description: "stop queued behind lifecycle")
        let release = DispatchSemaphore(value: 0)
        let holding = Task.detached { await lifecycle.holdCommandTestOwner(entered, release) }
        await fulfillment(of: [entered], timeout: 2)
        let command = Task {
            queued.fulfill()
            try await lifecycle.stopFromCommand(onRequest: { XCTFail("Cancelled request must not change recording preferences") },
                operation: { XCTFail("Cancelled request must not stop devices") })
        }
        await fulfillment(of: [queued], timeout: 2)
        command.cancel(); release.signal(); await holding.value
        do { try await command.value; XCTFail("Cancelled lifecycle admission") }
        catch { XCTAssertTrue(error is CancellationError) }
        // Required shutdown still runs even if its caller is already cancelled.
        let cleanup = expectation(description: "mandatory cleanup retained")
        let mandatory = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await lifecycle.stop(onRequest: {}, operation: { cleanup.fulfill() })
        }
        try await mandatory.value
        await fulfillment(of: [cleanup], timeout: 2)
    }

    func testCancelledQueuedRecordingCommandDoesNotBeginStopOrAdvanceOwnerRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let services = ServiceContainer(databasePath: root.appendingPathComponent("unused.db").path,
            storageConfig: .init(storageRootPath: root.path))
        let coordinator = AppCoordinator(services: services)
        let before = await coordinator.recordingCommandState()
        let entered = expectation(description: "native coordinator held")
        let queued = expectation(description: "command queued behind coordinator")
        let release = DispatchSemaphore(value: 0)
        let holding = Task.detached { await coordinator.holdCommandTestOwner(entered, release) }
        await fulfillment(of: [entered], timeout: 2)
        let command = Task {
            queued.fulfill()
            try await coordinator.setRecordingFromCommand(active: false, expectedRevision: before.revision)
        }
        await fulfillment(of: [queued], timeout: 2)
        command.cancel(); release.signal(); await holding.value
        do { try await command.value; XCTFail("Cancelled native admission") }
        catch { XCTAssertTrue(error is CancellationError) }
        let after = await coordinator.recordingCommandState()
        XCTAssertEqual(after, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testCancelledQueuedOverrideDoesNotChangeGovernorState() async throws {
        let governor = BackgroundProcessingGovernor(observeSystem: false)
        let entered = expectation(description: "native governor held")
        let queued = expectation(description: "override queued behind governor")
        let release = DispatchSemaphore(value: 0)
        let holding = Task.detached { await governor.holdCommandTestOwner(entered, release) }
        await fulfillment(of: [entered], timeout: 2)
        let command = Task { queued.fulfill(); try await governor.setProcessNowFromCommand(true) }
        await fulfillment(of: [queued], timeout: 2)
        command.cancel(); release.signal(); await holding.value
        do { try await command.value; XCTFail("Cancelled native admission") }
        catch { XCTAssertTrue(error is CancellationError) }
        let snapshot = await governor.snapshot()
        XCTAssertFalse(snapshot.processNow)
        await governor.close()
    }
}

private final class ConfigurationExpiryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return Date(timeIntervalSince1970: reads < 4 ? 0 : 200)
    }
}

private extension AppCoordinator {
    func holdCommandTestOwner(_ entered: XCTestExpectation, _ release: DispatchSemaphore) {
        entered.fulfill(); _ = release.wait(timeout: .now() + 5)
    }
}
private extension BackgroundProcessingGovernor {
    func holdCommandTestOwner(_ entered: XCTestExpectation, _ release: DispatchSemaphore) {
        entered.fulfill(); _ = release.wait(timeout: .now() + 5)
    }
}
private extension RecordingLifecycle {
    func holdCommandTestOwner(_ entered: XCTestExpectation, _ release: DispatchSemaphore) {
        entered.fulfill(); _ = release.wait(timeout: .now() + 5)
    }
}
