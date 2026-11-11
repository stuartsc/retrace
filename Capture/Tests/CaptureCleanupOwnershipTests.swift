import CoreGraphics
import Foundation
import Shared
import XCTest
@testable import Capture

/// Exercise the real candidate, router, manager and AsyncStream teardown. Only
/// the native environment's start/stop acknowledgements are substituted.
final class CaptureCleanupOwnershipTests: XCTestCase {
    func testRouterRetriesFailedStopBeforeReleasingItsSource() async throws {
        let harness = makeHarness(stopFailures: 1)
        let pair = AsyncStream<CapturedFrame>.makeStream()
        defer { pair.continuation.finish() }
        try await harness.router.startCapture(config: candidateConfig,
            frameContinuation: pair.continuation, displayID: 42)

        await expectStopFailure { try await harness.router.stopCapture() }
        try await harness.router.stopCapture()

        let state = await harness.native.snapshot()
        XCTAssertEqual(state.stopAttempts, 2)
        XCTAssertFalse(state.ownsSession, "A successful retry must drain the source retained after failure")
    }

    func testRouterRejectsBackendReplacementWhileOldCleanupStillFails() async throws {
        let harness = makeHarness(stopFailures: 2)
        let pair = AsyncStream<CapturedFrame>.makeStream()
        defer { pair.continuation.finish() }
        try await harness.router.startCapture(config: candidateConfig,
            frameContinuation: pair.continuation, displayID: 42)
        await expectStopFailure { try await harness.router.stopCapture() }

        await expectStopFailure {
            try await harness.router.startCapture(config: .default,
                frameContinuation: pair.continuation, displayID: 42)
        }
        let prematureStarts = await harness.legacy.startCount
        XCTAssertEqual(prematureStarts, 0, "The replacement cannot hide a native source that failed to stop")

        try await harness.router.startCapture(config: .default,
            frameContinuation: pair.continuation, displayID: 42)
        let state = await harness.native.snapshot()
        let replacementStarts = await harness.legacy.startCount
        XCTAssertEqual(state.stopAttempts, 3)
        XCTAssertFalse(state.ownsSession)
        XCTAssertEqual(replacementStarts, 1)
    }

    func testManagerStopRetryDrainsNativeOwnerAfterItsFrameStreamFinished() async throws {
        let harness = makeHarness(stopFailures: 1)
        try await harness.manager.startCapture(config: candidateConfig)
        let output = await harness.manager.frameStream
        await expectStopFailure { try await harness.manager.stopCapture() }
        var frameCount = 0
        for await _ in output { frameCount += 1 }
        XCTAssertEqual(frameCount, 0, "Failed native stop must still join and close frame forwarding")
        let capturing = await harness.manager.isCapturing
        XCTAssertFalse(capturing)

        try await harness.manager.stopCapture()
        let state = await harness.native.snapshot()
        XCTAssertEqual(state.stopAttempts, 2)
        XCTAssertFalse(state.ownsSession, "Stopped UI/stream state must not erase pending native cleanup")
    }

    func testManagerRejectsRestartAndConfigurationUntilNativeCleanupSucceeds() async throws {
        for changeConfiguration in [false, true] {
            let harness = makeHarness(stopFailures: 2)
            try await harness.manager.startCapture(config: candidateConfig)
            await expectStopFailure { try await harness.manager.stopCapture() }

            await expectStopFailure {
                if changeConfiguration { try await harness.manager.updateConfig(.default) }
                else { try await harness.manager.startCapture(config: .default) }
            }
            let starts = await harness.legacy.startCount
            let retainedConfig = await harness.manager.getConfig()
            XCTAssertEqual(starts, 0)
            XCTAssertEqual(retainedConfig.backend, .screenCaptureKitCandidate,
                           "Unresolved cleanup cannot be bypassed by applying a replacement configuration")

            try await harness.manager.startCapture(config: .default)
            let state = await harness.native.snapshot()
            let successfulStarts = await harness.legacy.startCount
            XCTAssertEqual(state.stopAttempts, 3)
            XCTAssertFalse(state.ownsSession)
            XCTAssertEqual(successfulStarts, 1)
        }
    }

    func testFailedStartupCleanupRemainsRetryableThroughPublicStop() async throws {
        let harness = makeHarness(stopFailures: 2, failStart: true)
        do {
            try await harness.manager.startCapture(config: candidateConfig)
            XCTFail("The injected partial native startup must fail")
        } catch let failure as CaptureLifecycleCleanupFailure {
            XCTAssertFalse(failure.cleanupErrors.isEmpty)
        }
        let failed = await harness.native.snapshot()
        XCTAssertTrue(failed.ownsSession)
        XCTAssertEqual(failed.stopAttempts, 2)

        try await harness.manager.stopCapture()
        let drained = await harness.native.snapshot()
        XCTAssertEqual(drained.stopAttempts, 3)
        XCTAssertFalse(drained.ownsSession)
    }

    private var candidateConfig: CaptureConfig { CaptureConfig(backend: .screenCaptureKitCandidate) }

    private func makeHarness(stopFailures: Int, failStart: Bool = false) -> CleanupHarness {
        let native = CleanupNativeEnvironment(stopFailures: stopFailures, failStart: failStart)
        let candidate = ScreenCaptureKitCapture(environment: native.environment(), automaticallyPoll: false)
        let legacy = CleanupLegacySource()
        let router = CaptureSourceRouter(legacy: legacy, candidate: candidate)
        let manager = CaptureManager(config: candidateConfig, metadataProvider: CleanupMetadataProvider(),
            source: router, lifecycleEnvironment: CaptureLifecycleEnvironment(hasPermission: { true },
                activeDisplayID: { 42 }, startDisplayMonitoring: { _ in }, stopDisplayMonitoring: {}))
        addTeardownBlock {
            await native.allowCleanup()
            try? await manager.stopCapture()
            try? await router.stopCapture()
            try? await candidate.stopCapture()
        }
        return CleanupHarness(native: native, candidate: candidate, legacy: legacy, router: router, manager: manager)
    }

    private func expectStopFailure(_ operation: () async throws -> Void,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected native stop failure", file: file, line: line) }
        catch CleanupFailure.stop { }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }
}

private enum CleanupFailure: Error { case start, stop }

private struct CleanupHarness {
    let native: CleanupNativeEnvironment
    let candidate: ScreenCaptureKitCapture
    let legacy: CleanupLegacySource
    let router: CaptureSourceRouter
    let manager: CaptureManager
}

private actor CleanupNativeEnvironment {
    struct State: Sendable { let stopAttempts: Int; let ownsSession: Bool }
    private var stopFailures: Int
    private let failStart: Bool
    private var stopAttempts = 0
    private var ownsSession = false

    init(stopFailures: Int, failStart: Bool) {
        self.stopFailures = stopFailures; self.failStart = failStart
    }

    nonisolated func environment() -> ScreenCaptureEnvironment {
        ScreenCaptureEnvironment(displays: { [.init(displayID: 42, identity: "authored-display")] },
            context: { _, _ in CapturedWindowSample(context: nil) }, pixels: { _, _ in nil },
            beginSession: { try await self.begin() }, endSession: { try await self.end() })
    }

    func snapshot() -> State { State(stopAttempts: stopAttempts, ownsSession: ownsSession) }
    func allowCleanup() { stopFailures = 0 }

    private func begin() throws {
        ownsSession = true
        if failStart { throw CleanupFailure.start }
    }

    private func end() throws {
        stopAttempts += 1
        if stopFailures > 0 { stopFailures -= 1; throw CleanupFailure.stop }
        ownsSession = false
    }
}

private actor CleanupLegacySource: CaptureFrameSource {
    private(set) var startCount = 0
    private var continuation: AsyncStream<CapturedFrame>.Continuation?
    func startCapture(config: CaptureConfig, frameContinuation: AsyncStream<CapturedFrame>.Continuation,
                      displayID: CGDirectDisplayID?) {
        startCount += 1; continuation = frameContinuation
    }
    func stopCapture() { continuation = nil }
    func updateConfig(_ config: CaptureConfig) { }
    func captureImmediateAndResetTimer() { }
}

private struct CleanupMetadataProvider: FrontmostMetadataProviding {
    func getFrontmostAppInfo(includeBrowserURL: Bool) async -> FrameMetadata { .empty }
}
