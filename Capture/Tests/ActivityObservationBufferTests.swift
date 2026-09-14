import XCTest
import ApplicationServices
import Shared
@testable import Capture

final class ActivityObservationBufferTests: XCTestCase {
    func testBoundedStreamRetainsObservedTransitionsAndReportsOverflow() async {
        let buffer = ActivityObservationBuffer(capacity: 2)
        buffer.send(.init(kind: .focus, app: nil))
        buffer.send(.init(kind: .reconciliation, app: nil))
        buffer.send(.init(kind: .heartbeat, app: nil))
        XCTAssertEqual(buffer.takeDroppedCount(), 1)
        XCTAssertEqual(buffer.takeDroppedCount(), 0)
        buffer.finish()
        var received: [ActivityEventKind] = []
        for await signal in buffer.stream { received.append(signal.kind) }
        XCTAssertEqual(received, [.focus, .reconciliation])
    }

    func testPrivacyBoundaryInvalidatesAlreadyQueuedContent() async {
        let buffer = ActivityObservationBuffer(capacity: 4)
        buffer.send(.init(kind: .focus, app: nil))
        buffer.suspend()
        buffer.finish()
        for await signal in buffer.stream {
            XCTAssertFalse(buffer.permitsContent(generation: signal.generation))
        }
    }

    func testLateEnrichmentCannotAdoptAResumedPrivacyGeneration() async {
        let buffer = ActivityObservationBuffer(capacity: 4)
        let oldEnrichment = ActivityObservationSignal(kind: .enrichment, app: nil, generation: 0)
        buffer.suspend()
        buffer.resume()
        buffer.send(oldEnrichment)
        buffer.finish()
        var received = 0
        for await _ in buffer.stream { received += 1 }
        XCTAssertEqual(received, 0, "The generation must be checked atomically while enqueueing late enrichment")
    }

    func testAXRefreshCallbackIsDetachedAtObservationStop() async {
        let refreshes = expectation(description: "AX refresh requested")
        refreshes.expectedFulfillmentCount = 1
        refreshes.assertForOverFulfill = true
        let buffer = ActivityObservationBuffer(capacity: 2)
        buffer.setObserverRefresh { refreshes.fulfill() }
        buffer.refreshObserver()
        await fulfillment(of: [refreshes], timeout: 1)
        buffer.setObserverRefresh(nil)
        buffer.refreshObserver()
        buffer.finish()
    }

    func testEnrichmentEnqueueRequiresCurrentNotificationRevision() async {
        let buffer = ActivityObservationBuffer(capacity: 4)
        let before = ObservedWindowGenerations.shared.notificationRevision
        ActivityAXNotificationHandler.handle(kAXTitleChangedNotification, app: nil, buffer: buffer)
        let current = ObservedWindowGenerations.shared.notificationRevision
        XCTAssertGreaterThan(current, before)
        buffer.send(.init(kind: .enrichment, app: nil, notificationRevision: before))
        buffer.send(.init(kind: .enrichment, app: nil, notificationRevision: current))
        buffer.finish()
        var received: [ActivityObservationSignal] = []
        for await signal in buffer.stream { received.append(signal) }
        XCTAssertEqual(received.map(\.kind), [.focus, .enrichment])
        XCTAssertEqual(received.last?.notificationRevision, current,
                       "An old AX result cannot acquire the latest revision while entering the queue")
    }
}
