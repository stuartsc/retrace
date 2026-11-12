import Foundation
import Shared
import XCTest
@testable import App

final class RetentionOutputDrainTests: XCTestCase {
    func testCommittedRetentionJoinsOutputDrainBeforeReturning() async throws {
        let services = ServiceContainer(inMemory: true)
        let database = await services.database
        try await database.initialize()
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let segment = try await database.insertSegment(bundleID: "test.retrace.retention", startDate: time,
            endDate: time, windowName: "Authored retention fixture", browserUrl: nil, type: 0)
        let frame = FrameID(value: try await database.insertFrame(.init(id: .init(value: 0), timestamp: time,
            segmentID: .init(value: segment), frameIndexInSegment: 0,
            metadata: .init(appBundleID: "test.retrace.retention", appName: "Authored fixture"))))
        let entered = expectation(description: "Native retention committed before output drain")
        let hold = RetentionDrainHold()
        await services.retentionManager.setSourceMutationDrain {
            entered.fulfill()
            await hold.wait()
        }
        let completed = RetentionDrainCompletion()
        let cleanup = Task {
            let result = await services.retentionManager.runCleanupForTesting(cutoff: time.addingTimeInterval(1))
            await completed.finish()
            return result
        }
        await fulfillment(of: [entered], timeout: 3)
        let retained = try await database.getFrame(id: frame)
        XCTAssertNil(retained, "Drain must run outside and after the canonical deletion transaction")
        let returned = await completed.finished
        XCTAssertFalse(returned, "Committed retention must not acknowledge completion before output has stopped")
        await hold.release()
        let result = await cleanup.value
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.deletedFrames, 1)
        try await database.close()
    }
}

private actor RetentionDrainHold {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor RetentionDrainCompletion {
    private(set) var finished = false
    func finish() { finished = true }
}
