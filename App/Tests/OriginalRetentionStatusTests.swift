import Foundation
import Shared
import XCTest
@testable import App

final class OriginalRetentionStatusTests: XCTestCase {
    func testPressureIsVisibleUntilAnActualCaptureResumesAndGapRemainsVisible() {
        let status = OriginalRetentionStatusHolder()
        status.notePressure(.capacityLimit(retainedBytes: 5_000, incomingBytes: 100, limitBytes: 5_000))
        XCTAssertTrue(status.snapshot.blocked)
        XCTAssertEqual(status.snapshot.skippedScreenUpdates, 1)
        XCTAssertTrue(status.snapshot.notice?.contains("Original images are retained") == true)
        // Freed space alone does not prove the writer restarted.
        status.update(.init(retainedBytes: 0, availableBytes: 40 * 1_024 * 1_024 * 1_024, retainedSessions: 0))
        XCTAssertTrue(status.snapshot.blocked)
        status.noteCaptureResumed()
        XCTAssertFalse(status.snapshot.blocked)
        XCTAssertTrue(status.snapshot.coverageNotice?.contains("1 screen updates could not be saved") == true)
        status.update(.init(retainedBytes: 0, availableBytes: 40 * 1_024 * 1_024 * 1_024, retainedSessions: 0))
        XCTAssertNotNil(status.snapshot.coverageNotice, "Later healthy scans must not hide an earlier capture gap")
    }

    func testUnattributedLegacySourcesAreVisibleWithoutBlockingCurrentRecording() {
        let status = OriginalRetentionStatusHolder()
        status.update(.init(retainedBytes: 100, availableBytes: 40 * 1_024 * 1_024 * 1_024,
                            retainedSessions: 1, unattributedSessions: 1))
        XCTAssertFalse(status.snapshot.blocked)
        XCTAssertTrue(status.snapshot.notice?.contains("need recovery verification") == true)
        XCTAssertEqual(status.snapshot.spool?.retainedBytes, 100)
    }
    func testVerificationFailureCannotOverwriteGapAndRestartRestoresCategoricalCoverage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OriginalCoverage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("coverage.json")
        let status = OriginalRetentionStatusHolder()
        let receipt = status.notePressure(.capacityLimit(retainedBytes: 5_000, incomingBytes: 100, limitBytes: 5_000))
        try await OriginalCaptureCoverageJournal(url: url).persist(receipt)
        status.noteCaptureResumed()
        let gap = status.snapshot.coverageNotice
        status.noteUnverified()
        XCTAssertEqual(status.snapshot.coverageNotice, gap)
        XCTAssertTrue(status.snapshot.notice?.contains("verification") == true)
        let reopened = OriginalRetentionStatusHolder()
        reopened.restoreCoverage(try await OriginalCaptureCoverageJournal(url: url).read())
        XCTAssertEqual(reopened.snapshot.coverageNotice, gap)
        XCTAssertEqual(reopened.snapshot.skippedScreenUpdates, 1)
        XCTAssertFalse(reopened.snapshot.blocked, "A previous gap does not assert that current capture is blocked")
    }

}
