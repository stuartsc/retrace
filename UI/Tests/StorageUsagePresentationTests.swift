import Darwin
import Foundation
import Shared
import Storage
import XCTest
@testable import Retrace

final class StorageUsagePresentationTests: XCTestCase {
    func testPeriodicReportIncludesAudioAndRollbackCopiesAndCachedReadDoesNotRescan() async throws {
        let canonical = try XCTUnwrap(realpath(NSTemporaryDirectory(), nil))
        let root = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent(UUID().uuidString)
        free(canonical)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [("library/audio/authored.m4a", 4096), ("library/chunks/recording", 8192),
                     ("library/retrace.db", 16384), ("backup/retrace.db", 32768)]
        for (name, size) in files {
            let file = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 42, count: size).write(to: file)
        }
        let monitor = StorageUsageMonitor(roots: [
            .init(id: "native", url: root.appendingPathComponent("library"), classifyNativeLibrary: true),
            .init(id: "backups", url: root.appendingPathComponent("backup"), defaultCategory: .backups)
        ])
        let first = StorageUsagePresentation(snapshot: await monitor.refresh())
        XCTAssertEqual(first.report?.total.logicalBytes, 61440)
        XCTAssertEqual(first.report?.categories[.audio]?.logicalBytes, 4096)
        XCTAssertEqual(first.report?.categories[.backups]?.logicalBytes, 32768)
        XCTAssertEqual(first.report?.total.fileCount, 4)
        XCTAssertFalse(first.isPartial)
        XCTAssertFalse(first.isShowingLastComplete)
        try Data(repeating: 13, count: 4096).write(to: root.appendingPathComponent("library/audio/new.m4a"))
        let cached = StorageUsagePresentation(snapshot: await monitor.snapshot())
        XCTAssertEqual(cached.report?.id, first.report?.id)
        XCTAssertEqual(cached.report?.total.logicalBytes, 61440, "Presenting the cache must not start a new scan")
        let refreshed = StorageUsagePresentation(snapshot: await monitor.refresh())
        XCTAssertEqual(refreshed.report?.total.logicalBytes, 65536)
        // An unavailable root is not zero, and cannot replace an older complete total.
        try FileManager.default.removeItem(at: root.appendingPathComponent("backup"))
        let incomplete = await monitor.refresh()
        let retained = StorageUsagePresentation(snapshot: incomplete)
        XCTAssertEqual(retained.report?.id, refreshed.report?.id)
        XCTAssertTrue(retained.isShowingLastComplete)
        XCTAssertFalse(retained.isPartial)
        let partialOnly = StorageUsagePresentation(snapshot: .init(latestReport: incomplete.latestReport))
        XCTAssertTrue(partialOnly.isPartial)
        XCTAssertEqual(partialOnly.report?.total.fileCount, 4)
        await monitor.close()
    }

    func testUnmeasuredStorageRemainsUnknown() {
        let presentation = StorageUsagePresentation(snapshot: .init())
        XCTAssertNil(presentation.report)
        XCTAssertEqual(presentation.value, "Not measured")
        XCTAssertFalse(presentation.isPartial)
    }
}
