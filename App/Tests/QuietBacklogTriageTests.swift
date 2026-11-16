import Foundation
import XCTest
@testable import App

final class QuietBacklogTriageTests: XCTestCase {
    func testStopsWhenBacklogDrainsAndUses48HourCutoff() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var remaining = 1_200
        var cutoffs: [Date] = []
        var pauses = 0
        let total = try await QuietBacklogTriage.runTurn(now: now, mark: { cutoff, limit in
            cutoffs.append(cutoff)
            let marked = min(limit, remaining); remaining -= marked; return marked
        }, isCancelled: { false }, pause: { pauses += 1 })
        XCTAssertEqual(total, 1_200)
        XCTAssertEqual(cutoffs.count, 3) // 500 + 500 + 200
        XCTAssertEqual(pauses, 2)
        XCTAssertTrue(cutoffs.allSatisfy { $0 == now.addingTimeInterval(-48 * 3_600) })
    }

    func testCapsBatchesPerTurnAndStopsOnCancel() async throws {
        var calls = 0
        let capped = try await QuietBacklogTriage.runTurn(now: Date(), mark: { _, limit in calls += 1; return limit },
            isCancelled: { false }, pause: {})
        XCTAssertEqual(calls, QuietBacklogTriage.maximumBatchesPerTurn)
        XCTAssertEqual(capped, QuietBacklogTriage.maximumBatchesPerTurn * QuietBacklogTriage.batchSize)
        calls = 0
        let cancelled = try await QuietBacklogTriage.runTurn(now: Date(), mark: { _, limit in calls += 1; return limit },
            isCancelled: { calls >= 2 }, pause: {})
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(cancelled, 1_000)
    }
}
