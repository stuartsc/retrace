import Foundation
import Shared
import XCTest
@testable import App

final class RetraceForegroundRouterTests: XCTestCase {
    func testGrantRevocationAtNonCooperativeUIBoundaryPreventsNativeEffect() async throws {
        let router = RetraceForegroundRouter(), held = ForegroundEffectHold()
        let entered = expectation(description: "UI preparation holds before native effect")
        let fence = NativeMutationFence()
        let id = await router.register(open: { _, authorization in
            await held.wait { entered.fulfill() }
            try authorization.effect { XCTFail("Revoked authority must not publish a native window") }
        }, playback: { _, _ in })
        let task = Task { try await router.open(.transcript(.init(nativeStoreID: UUID(), source: .microphone,
            rowID: 1, snapshotSHA256: String(repeating: "a", count: 64))), commandFence: fence, authorization: {}) }
        await fulfillment(of: [entered], timeout: 3)
        fence.invalidate()
        await held.release()
        do { try await task.value; XCTFail("A non-cooperative preparation cannot bypass the final fence") }
        catch is CancellationError { }
        await router.unregister(id)
    }

    func testUnregisterRevokesEffectBeforeJoiningNonCooperativePreparation() async throws {
        let router = RetraceForegroundRouter(), held = ForegroundEffectHold()
        let entered = expectation(description: "Playback preparation held")
        let cancelled = expectation(description: "Unregister revoked and cancelled the admitted callback")
        let fence = NativeMutationFence()
        let id = await router.register(open: { _, _ in }, playback: { _, authorization in
            await withTaskCancellationHandler { await held.wait { entered.fulfill() } }
                onCancel: { cancelled.fulfill() }
            try authorization.effect { XCTFail("Unregistered native effect must not run") }
        })
        let task = Task { try await router.playback(.stop, commandFence: fence, authorization: {}) }
        await fulfillment(of: [entered], timeout: 3)
        let unregistering = Task { await router.unregister(id) }
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertThrowsError(try fence.withAdmission {})
        await held.release(); await unregistering.value
        do { try await task.value; XCTFail("Removed registration cannot acknowledge playback") }
        catch is CancellationError { }
    }
    func testUnavailableWithoutUIAndUnregisterCancelsAndJoinsActualCallback() async throws {
        let router = RetraceForegroundRouter()
        let target = RetraceNavigationTarget.marker(id: UUID(), expectedRevision: UUID())
        do { try await router.open(target, authorization: {}); XCTFail("No UI cannot report success") }
        catch RetraceCommandError.unavailable { }
        let entered = expectation(description: "Real foreground callback entered")
        let exited = expectation(description: "Cancelled callback exited")
        let registration = await router.register(open: { _, _ in
            entered.fulfill()
            defer { exited.fulfill() }
            try await Task.sleep(for: .seconds(30))
        }, playback: { _, _ in })
        let action = Task { try await router.open(target, authorization: {}) }
        await fulfillment(of: [entered], timeout: 3)
        await router.unregister(registration)
        await fulfillment(of: [exited], timeout: 3)
        do { try await action.value; XCTFail("A removed UI registration cannot acknowledge success") }
        catch is CancellationError { }
        do { try await router.playback(.stop, authorization: {}); XCTFail("Removed registration is unavailable") }
        catch RetraceCommandError.unavailable { }
    }

    func testAuthorizationFailureNeverCallsUIAndOldTokenCannotRemoveReplacement() async throws {
        let router = RetraceForegroundRouter()
        let first = await router.register(open: { _, _ in XCTFail("Old callback must not run") }, playback: { _, _ in })
        let invoked = expectation(description: "Replacement UI callback invoked")
        let second = await router.register(open: { _, _ in invoked.fulfill() }, playback: { _, _ in })
        await router.unregister(first)
        let target = RetraceNavigationTarget.marker(id: UUID(), expectedRevision: UUID())
        do {
            try await router.open(target, authorization: { throw RetraceCommandError.notPermitted })
            XCTFail("Revoked grant must not run UI callback")
        } catch RetraceCommandError.notPermitted { }
        try await router.open(target, authorization: {})
        await fulfillment(of: [invoked], timeout: 3)
        await router.unregister(second)
    }
}

private actor ForegroundEffectHold {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait(entered: @Sendable () -> Void) async {
        await withCheckedContinuation { continuation = $0; entered() }
    }
    func release() { continuation?.resume(); continuation = nil }
}
