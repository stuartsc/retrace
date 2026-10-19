import Darwin
import Foundation
import Shared
import XCTest
@testable import App

final class StorageUsageServiceTests: XCTestCase {
    func testConfiguredExternalLogsAndCachesAreIncludedWithoutScanningUnrelatedCaches() async throws {
        let allocated = try XCTUnwrap(realpath(NSTemporaryDirectory(), nil))
        let temporary = URL(fileURLWithPath: String(cString: allocated)); free(allocated)
        let home = temporary.appendingPathComponent("storage-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let fixtures: [(String, Int)] = [
            ("Library/Logs/Retrace/retrace.log", 128),
            ("Library/Caches/io.retrace.app/TimelineFrameBuffer/frame", 256),
            ("Library/Caches/search_thumbnails_v1/authored.jpg", 512),
            ("Library/Caches/search_results_cache.json", 1024),
            ("Library/Caches/other_apps_cache.json", 2048),
            ("Library/Caches/unrelated-app/private", 4096)
        ]
        for (relative, bytes) in fixtures {
            let file = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 42, count: bytes).write(to: file)
        }
        let ownedIDs: Set<String> = ["nativeLogs", "nativeCaches", "searchThumbnails", "searchResults", "otherApps"]
        let actualHome = FileManager.default.homeDirectoryForCurrentUser.path + "/"
        let configured = StorageUsageService.roots(native: home.appendingPathComponent("native"), includeRelatedLibraries: true)
        // Map the actual production root plan into an authored home. Never scan
        // the real user's log/cache files or alter their preferences.
        let roots = try configured.filter { ownedIDs.contains($0.id) }.map { root -> StorageUsageRoot in
            XCTAssertTrue(root.url.path.hasPrefix(actualHome))
            guard root.url.path.hasPrefix(actualHome) else { throw CocoaError(.fileReadInvalidFileName) }
            return .init(id: root.id, url: home.appendingPathComponent(String(root.url.path.dropFirst(actualHome.count))),
                defaultCategory: root.defaultCategory, missingBehavior: root.missingBehavior)
        }
        let service = StorageUsageService(roots: roots, resources: ResourceUsageMonitor())
        await service.start()
        let snapshot = await service.refresh()
        await service.close()
        let report = try XCTUnwrap(snapshot.latestReport)
        XCTAssertTrue(report.isComplete, "\(report.issues)")
        XCTAssertEqual(report.categories[.logs]?.logicalBytes, 128)
        XCTAssertEqual(report.categories[.caches]?.logicalBytes, 3840)
        XCTAssertEqual(report.total.fileCount, 5)
        XCTAssertEqual(report.total.logicalBytes, 3968, "Other applications' caches must stay outside this inventory")
    }

    func testOwnerStartsExplicitlyCachesAndJoinsBeforeRestart() async throws {
        // Preserve the actual POSIX path: Foundation standardization can turn
        // /private/var into its /var symlink, which the scanner correctly rejects.
        let allocated = try XCTUnwrap(realpath(NSTemporaryDirectory(), nil))
        let temporary = URL(fileURLWithPath: String(cString: allocated)); free(allocated)
        let root = temporary.appendingPathComponent("storage-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: false)
        try Data(repeating: 12, count: 8192).write(to: audio.appendingPathComponent("authored.m4a"))
        let resource = ResourceUsageMonitor()
        let service = StorageUsageService(roots: [.init(id: "native", url: root, classifyNativeLibrary: true)], resources: resource)
        let initial = await service.snapshot()
        XCTAssertNil(initial.latestReport)
        await service.start()
        let first = await service.refresh()
        XCTAssertTrue(try XCTUnwrap(first.latestReport).isComplete)
        XCTAssertEqual(first.latestReport?.categories[.audio]?.logicalBytes, 8192)
        try Data(repeating: 13, count: 4096).write(to: audio.appendingPathComponent("next.m4a"))
        let cached = await service.snapshot()
        XCTAssertEqual(cached.latestReport?.id, first.latestReport?.id, "Reading the UI cache must not scan")
        await service.close()
        let closed = await service.refresh()
        XCTAssertTrue(closed.isClosed)
        XCTAssertEqual(closed.latestReport?.id, first.latestReport?.id)
        await service.start()
        let reopened = await service.refresh()
        XCTAssertFalse(reopened.isClosed)
        XCTAssertEqual(reopened.latestReport?.categories[.audio]?.logicalBytes, 12288)
        await service.close()
    }

    func testImmediateCloseJoinsDeferredStartupWithoutLeavingAScanner() async throws {
        let service = StorageUsageService(roots: [], resources: ResourceUsageMonitor())
        await service.start()
        async let first: Void = service.close()
        async let second: Void = service.close()
        _ = await (first, second)
        let closed = await service.snapshot()
        XCTAssertTrue(closed.isClosed)
        XCTAssertFalse(closed.isScanning)
        try await Task.sleep(for: .milliseconds(30))
        let after = await service.snapshot()
        XCTAssertEqual(after, closed)
    }
}
