import Darwin
import Foundation
import XCTest
import Shared
@testable import Storage

/// Real metadata scans in private directories. No production paths, settings, or media readers.
final class StorageUsageMonitorTests: XCTestCase {
    private var directory: URL!
    private var monitors: [StorageUsageMonitor] = []

    override func setUpWithError() throws {
        // Foundation's standardization intentionally rewrites /private/var to
        // /var on macOS; POSIX realpath supplies the actual no-symlink root.
        let canonical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("RetraceStorageUsageTests_\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for monitor in monitors { await monitor.close() }
        monitors.removeAll()
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    func testConstructionAndSnapshotsAreInert() async throws {
        let missing = directory.appendingPathComponent("not-created")
        let monitor = makeMonitor([.init(id: "native", url: missing)])
        let snapshot = await monitor.snapshot()
        XCTAssertNil(snapshot.latestReport)
        XCTAssertNil(snapshot.lastCompleteReport)
        XCTAssertFalse(snapshot.isScanning)
        XCTAssertFalse(snapshot.isClosed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testNativeCategoriesIncludeHiddenOriginalsAndDatabaseJournals() async throws {
        let expected: [(String, Int, StorageUsageCategory)] = [
            ("chunks/202609/30/100", 11, .screenVideo),
            ("audio/batch_1.m4a", 13, .audio),
            ("audio/chunk-media/pending/record.json", 17, .originals),
            ("retrace.db", 19, .database), ("retrace.db-wal", 23, .database),
            ("retrace.db-shm", 29, .database), ("wal/original_segment_1/.pixels", 31, .originals),
            (".originals/pixels", 37, .originals), ("indexes/semantic.bin", 41, .indexes),
            ("models/whisper.bin", 43, .models), ("model-cache/semantic/model.bin", 67, .models),
            ("favicon_cache/icon.png", 71, .caches), ("app_names.json", 73, .caches),
            ("app_icon_colors.json", 79, .caches), ("cache/image", 47, .caches),
            ("temp/encoding", 53, .caches), ("logs/retrace.log", 59, .logs),
            ("notes/税務 🔍.json", 61, .other)
        ]
        for (path, bytes, _) in expected { try write(path, bytes: bytes) }
        let monitor = makeMonitor([.init(id: "native", url: directory, classifyNativeLibrary: true)])
        let snapshot = await monitor.refresh()
        let report = try XCTUnwrap(snapshot.latestReport)
        XCTAssertTrue(report.isComplete, "\(report.issues)")
        for category in StorageUsageCategory.allCases {
            let matching = expected.filter { $0.2 == category }
            XCTAssertEqual(report.categories[category]?.logicalBytes, UInt64(matching.reduce(0) { $0 + $1.1 }))
            XCTAssertEqual(report.categories[category]?.fileCount, UInt64(matching.count))
        }
        XCTAssertEqual(report.total.logicalBytes, UInt64(expected.reduce(0) { $0 + $1.1 }))
        XCTAssertEqual(report.total.fileCount, UInt64(expected.count))
        XCTAssertGreaterThan(report.total.allocatedBytes, 0)
        XCTAssertEqual(report.id, snapshot.lastCompleteReport?.id)
        XCTAssertGreaterThanOrEqual(report.finishedAt, report.startedAt)
    }

    func testExplicitRootsPreserveBackupsCandidatesAndImportedCategories() async throws {
        var roots: [StorageUsageRoot] = []
        for (index, category) in StorageUsageCategory.allCases.enumerated() {
            let path = "\(category.rawValue)/payload"
            try write(path, bytes: index + 1)
            roots.append(.init(id: category.rawValue,
                               url: directory.appendingPathComponent(category.rawValue),
                               defaultCategory: category))
        }
        let snapshot = await makeMonitor(roots).refresh()
        let report = try XCTUnwrap(snapshot.latestReport)
        XCTAssertTrue(report.isComplete)
        for (index, category) in StorageUsageCategory.allCases.enumerated() {
            XCTAssertEqual(report.categories[category]?.logicalBytes, UInt64(index + 1))
        }
    }

    func testOverlappingAndDuplicateRootsCountOnceWithSpecificRootCategory() async throws {
        try write("cache/model/weights", bytes: 31)
        try write("audio/batch.m4a", bytes: 17)
        let specific = directory.appendingPathComponent("cache/model")
        let monitor = makeMonitor([
            .init(id: "native", url: directory, classifyNativeLibrary: true),
            .init(id: "model", url: specific, defaultCategory: .models),
            .init(id: "duplicate", url: directory, defaultCategory: .backups)
        ])
        let snapshot = await monitor.refresh()
        let report = try XCTUnwrap(snapshot.latestReport)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.total.logicalBytes, 48)
        XCTAssertEqual(report.total.fileCount, 2)
        XCTAssertEqual(report.categories[.models]?.logicalBytes, 31)
        XCTAssertEqual(report.categories[.caches]?.logicalBytes, 0)
        XCTAssertEqual(report.roots.first { $0.rootID == "duplicate" }?.status, .coveredByOtherRoot)
        XCTAssertEqual(report.roots.first { $0.rootID == "duplicate" }?.coveredByRootID, "native")
    }

    func testHardLinksAreDeduplicatedAcrossRootsByDeviceAndInode() async throws {
        try write("audio/original", bytes: 31)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("backup"), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: directory.appendingPathComponent("audio/original"),
                                        to: directory.appendingPathComponent("backup/copy"))
        let snapshot = await makeMonitor([
            .init(id: "audio", url: directory.appendingPathComponent("audio"), defaultCategory: .audio),
            .init(id: "backup", url: directory.appendingPathComponent("backup"), defaultCategory: .backups)
        ]).refresh()
        let report = try XCTUnwrap(snapshot.latestReport)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.total.logicalBytes, 31)
        XCTAssertEqual(report.total.fileCount, 1)
    }

    func testChildSymlinksNeverReadExternalContents() async throws {
        try write("outside/secret", bytes: 97)
        try write("native/chunks/video", bytes: 11)
        let native = directory.appendingPathComponent("native")
        try FileManager.default.createSymbolicLink(at: native.appendingPathComponent("escape"),
                                                   withDestinationURL: directory.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(at: native.appendingPathComponent("file-link"),
                                                   withDestinationURL: directory.appendingPathComponent("outside/secret"))
        let snapshot = await makeMonitor([.init(id: "native", url: native, classifyNativeLibrary: true)]).refresh()
        let report = try XCTUnwrap(snapshot.latestReport)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.total.logicalBytes, 11)
        XCTAssertEqual(report.roots.first?.skippedSymbolicLinks, 2)
    }

    func testRootAndAncestorSymlinksAreUnavailable() async throws {
        try write("outside/nested/secret", bytes: 97)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("outside"))
        let snapshot = await makeMonitor([
            .init(id: "root-link", url: link),
            .init(id: "parent-link", url: link.appendingPathComponent("nested"))
        ]).refresh()
        let report = try XCTUnwrap(snapshot.latestReport)
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(report.total.logicalBytes, 0)
        XCTAssertEqual(report.roots.map(\.status), [.unavailable, .unavailable])
        XCTAssertEqual(Set(report.issues.map(\.reason)), [.symbolicLinkRoot])
        XCTAssertNil(snapshot.lastCompleteReport)
    }

    func testMissingOptionalRootIsZeroButRequiredOrMissingParentIsUnavailable() async throws {
        let snapshot = await makeMonitor([
            .init(id: "optional", url: directory.appendingPathComponent("optional"), missingBehavior: .knownZero),
            .init(id: "required", url: directory.appendingPathComponent("required")),
            .init(id: "offline", url: directory.appendingPathComponent("unmounted/library"), missingBehavior: .knownZero)
        ]).refresh()
        let report = try XCTUnwrap(snapshot.latestReport)
        XCTAssertEqual(report.roots.first { $0.rootID == "optional" }?.status, .absent)
        XCTAssertEqual(report.roots.first { $0.rootID == "required" }?.status, .unavailable)
        XCTAssertEqual(report.roots.first { $0.rootID == "offline" }?.status, .unavailable)
        XCTAssertEqual(report.totalIssueCount, 2)
        XCTAssertFalse(report.isComplete)
    }

    func testSpecialFilesAndNonFileURLsAreInvalidRoots() async throws {
        let fifo = directory.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let snapshot = await makeMonitor([
            .init(id: "fifo", url: fifo),
            .init(id: "https", url: try XCTUnwrap(URL(string: "https://example.invalid/library")))
        ]).refresh()
        let report = try XCTUnwrap(snapshot.latestReport)
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(report.total.logicalBytes, 0)
        XCTAssertEqual(report.totalIssueCount, 2)
        XCTAssertTrue(report.issues.allSatisfy { $0.reason == .invalidRoot })
    }

    func testExactFileRootsCountMetadataOnceAcrossParentAndHardLink() async throws {
        try write("record.json", bytes: 17)
        try write("nested/unrelated", bytes: 31)
        let file = directory.appendingPathComponent("record.json")
        try FileManager.default.linkItem(at: file, to: directory.appendingPathComponent("nested/alias.json"))
        let snapshot = await makeMonitor([
            .init(id: "record", url: file, defaultCategory: .caches),
            .init(id: "parent", url: directory, defaultCategory: .other)
        ]).refresh()
        let report = try XCTUnwrap(snapshot.latestReport)
        XCTAssertTrue(report.isComplete, "\(report.issues)")
        XCTAssertEqual(report.total.logicalBytes, 48)
        XCTAssertEqual(report.total.fileCount, 2)
        XCTAssertEqual(report.categories[.caches]?.logicalBytes, 17)
        XCTAssertEqual(report.categories[.other]?.logicalBytes, 31)
        XCTAssertFalse(report.volumes.isEmpty)
    }

    func testSparseAllocationAndVolumeFreeSpaceAreSeparateFromLogicalBytes() async throws {
        let file = directory.appendingPathComponent("sparse")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 16 * 1_024 * 1_024)
        try handle.close()
        let snapshot = await makeMonitor([.init(id: "native", url: directory)]).refresh()
        let report = try XCTUnwrap(snapshot.latestReport)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.total.logicalBytes, 16 * 1_024 * 1_024)
        XCTAssertLessThan(report.total.allocatedBytes, report.total.logicalBytes)
        let volume = try XCTUnwrap(report.volumes.first)
        XCTAssertGreaterThan(volume.totalBytes, 0)
        XCTAssertLessThanOrEqual(volume.availableBytes, volume.totalBytes)
        XCTAssertEqual(report.volumes.count, 1)
    }

    func testRefreshReplacesCountsAndPreservesLastCompleteAfterFailure() async throws {
        try write("library/audio/file", bytes: 3)
        let root = directory.appendingPathComponent("library")
        let monitor = makeMonitor([.init(id: "native", url: root, classifyNativeLibrary: true)])
        let first = await monitor.refresh()
        try write("library/audio/file", bytes: 7)
        let second = await monitor.refresh()
        XCTAssertEqual(second.latestReport?.total.logicalBytes, 7)
        XCTAssertNotEqual(first.latestReport?.id, second.latestReport?.id)
        try FileManager.default.removeItem(at: root)
        let unavailable = await monitor.refresh()
        XCTAssertEqual(unavailable.latestReport?.roots.first?.status, .unavailable)
        XCTAssertFalse(try XCTUnwrap(unavailable.latestReport).isComplete)
        XCTAssertEqual(unavailable.lastCompleteReport?.id, second.latestReport?.id)
        XCTAssertEqual(unavailable.lastCompleteReport?.total.logicalBytes, 7)
    }

    func testConcurrentRefreshesJoinOneScan() async throws {
        for index in 0..<40 { try write("file-\(index)", bytes: 1) }
        let probe = StorageUsageBatchProbe()
        let monitor = makeMonitor([.init(id: "native", url: directory)],
                                  configuration: .init(batchSize: 20),
                                  shouldDefer: { await probe.markBatch(); return true })
        let first = Task { await monitor.refresh() }
        try await waitUntil { await probe.count > 0 }
        let scanning = await monitor.snapshot()
        XCTAssertTrue(scanning.isScanning)
        let joined = await withTaskGroup(of: StorageUsageSnapshot.self) { group in
            for _ in 0..<8 { group.addTask { await monitor.refresh() } }
            var results: [StorageUsageSnapshot] = []
            for await result in group { results.append(result) }
            return results
        }
        let original = await first.value
        XCTAssertNotNil(original.latestReport)
        XCTAssertTrue(joined.allSatisfy { $0.latestReport?.id == original.latestReport?.id })
        XCTAssertTrue(joined.allSatisfy { !$0.isScanning })
    }

    func testCloseCancelsAndJoinsScanAndRetainsLastComplete() async throws {
        try write("file", bytes: 3)
        let probe = StorageUsageBatchProbe()
        let monitor = makeMonitor([.init(id: "native", url: directory)],
                                  configuration: .init(batchSize: 1),
                                  shouldDefer: { await probe.markBatch(); return true })
        let complete = await monitor.refresh()
        let previousBatches = await probe.count
        for index in 0..<40 { try write("file-\(index)", bytes: 1) }
        let pending = Task { await monitor.refresh() }
        try await waitUntil { await probe.count > previousBatches }
        async let firstClose: Void = monitor.close()
        async let secondClose: Void = monitor.close()
        _ = await (firstClose, secondClose)
        _ = await pending.value
        let closed = await monitor.snapshot()
        XCTAssertTrue(closed.isClosed)
        XCTAssertFalse(closed.isScanning)
        XCTAssertEqual(closed.lastCompleteReport?.id, complete.latestReport?.id)
        XCTAssertTrue(try XCTUnwrap(closed.latestReport).isCancelled)
        XCTAssertFalse(try XCTUnwrap(closed.latestReport).isComplete)
        await monitor.start()
        let unchanged = await monitor.refresh()
        XCTAssertEqual(unchanged, closed)
    }

    func testStartPerformsInitialAndPeriodicRefresh() async throws {
        try write("file", bytes: 3)
        let monitor = makeMonitor([.init(id: "native", url: directory)],
                                  configuration: .init(refreshInterval: 0.05))
        await monitor.start()
        let initial = await monitor.snapshot()
        XCTAssertEqual(initial.latestReport?.total.logicalBytes, 3)
        try write("file", bytes: 5)
        try await waitUntil { await monitor.snapshot().latestReport?.total.logicalBytes == 5 }
        await monitor.close()
        let closed = await monitor.snapshot()
        try await Task.sleep(for: .milliseconds(100))
        let later = await monitor.snapshot()
        XCTAssertEqual(closed, later)
    }

    func testDepthAndHardLinkLimitsProducePartialReports() async throws {
        try write("deep/nested/payload", bytes: 9)
        let depth = await makeMonitor([.init(id: "native", url: directory)],
                                      configuration: .init(maxDepth: 1)).refresh()
        XCTAssertFalse(try XCTUnwrap(depth.latestReport).isComplete)
        XCTAssertTrue(try XCTUnwrap(depth.latestReport).issues.contains { $0.reason == .resourceLimit })
        try write("links/a", bytes: 3)
        try write("links/b", bytes: 7)
        for name in ["a", "b"] {
            try FileManager.default.linkItem(at: directory.appendingPathComponent("links/\(name)"),
                                            to: directory.appendingPathComponent("links/\(name)-copy"))
        }
        let links = await makeMonitor([.init(id: "links", url: directory.appendingPathComponent("links"))],
                                      configuration: .init(maxHardLinkIdentities: 1)).refresh()
        XCTAssertFalse(try XCTUnwrap(links.latestReport).isComplete)
        XCTAssertTrue(try XCTUnwrap(links.latestReport).issues.contains { $0.reason == .resourceLimit })
        XCTAssertLessThanOrEqual(try XCTUnwrap(links.latestReport).total.fileCount, 1)
    }

    func testIssuesAreBoundedAndEmptyRootsAreACompleteEmptyObservation() async throws {
        let roots = (0..<10).map { StorageUsageRoot(id: "missing-\($0)", url: directory.appendingPathComponent("\($0)")) }
        let errors = await makeMonitor(roots, configuration: .init(maxIssues: 2)).refresh()
        XCTAssertEqual(errors.latestReport?.issues.count, 2)
        XCTAssertEqual(errors.latestReport?.totalIssueCount, 10)
        XCTAssertFalse(try XCTUnwrap(errors.latestReport).isComplete)
        let empty = await makeMonitor([]).refresh()
        XCTAssertTrue(try XCTUnwrap(empty.latestReport).isComplete)
        XCTAssertEqual(empty.latestReport?.total, .init())
    }

    func testCancelledRefreshWaiterDoesNotCancelTheSharedScan() async throws {
        for index in 0..<40 { try write("file-\(index)", bytes: 1) }
        let probe = StorageUsageBatchProbe()
        let monitor = makeMonitor([.init(id: "native", url: directory)],
                                  configuration: .init(batchSize: 20),
                                  shouldDefer: { await probe.markBatch(); return true })
        let owner = Task { await monitor.refresh() }
        try await waitUntil { await probe.count > 0 }
        let waiter = Task { await monitor.refresh() }
        waiter.cancel()
        let joined = await waiter.value
        let completed = await owner.value
        XCTAssertTrue(try XCTUnwrap(completed.latestReport).isComplete)
        XCTAssertEqual(joined.latestReport?.id, completed.latestReport?.id)
        XCTAssertEqual(completed.latestReport?.total.fileCount, 40)
    }

    func testUnreadableRootRemainsUnavailableInsteadOfZero() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission denial requires a non-root test process") }
        try write("locked/payload", bytes: 29)
        let locked = directory.appendingPathComponent("locked")
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { _ = chmod(locked.path, 0o700) }
        let snapshot = await makeMonitor([.init(id: "locked", url: locked, missingBehavior: .knownZero)]).refresh()
        let report = try XCTUnwrap(snapshot.latestReport)
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(report.roots.first?.status, .unavailable)
        XCTAssertTrue(report.issues.contains { $0.reason == .unreadableRoot && $0.systemError == EACCES })
    }

    func testTenThousandFilesYieldWithoutLosingTotalsOrInventingIssueLimits() async throws {
        for index in 0..<10_001 { try write("audio/\(index / 100)/batch_\(index)", bytes: 1) }
        let probe = StorageUsageBatchProbe()
        let snapshot = await makeMonitor([.init(id: "native", url: directory, classifyNativeLibrary: true)],
                                         shouldDefer: { await probe.markBatch(); return false }).refresh()
        let report = try XCTUnwrap(snapshot.latestReport)
        XCTAssertTrue(report.isComplete, "\(report.issues)")
        XCTAssertEqual(report.total.fileCount, 10_001)
        XCTAssertEqual(report.categories[.audio]?.logicalBytes, 10_001)
        let batchCount = await probe.count
        XCTAssertGreaterThan(batchCount, 30)
    }

    func testOptionalEmptyRootIsCompleteAndHasVolumeContext() async throws {
        let snapshot = await makeMonitor([
            .init(id: "optional", url: directory.appendingPathComponent("absent"), missingBehavior: .knownZero)
        ]).refresh()
        let report = try XCTUnwrap(snapshot.latestReport)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.roots.first?.status, .absent)
        XCTAssertEqual(report.total, .init())
        XCTAssertEqual(report.volumes.count, 1)
        let encoded = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(StorageUsageReport.self, from: encoded), report)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(directory.path))
    }

    func testDuplicateIdentifiersAndExcessRootsAreExplicitlyIncomplete() async throws {
        try write("first/payload", bytes: 3)
        try write("second/payload", bytes: 7)
        let duplicate = await makeMonitor([
            .init(id: "duplicate", url: directory.appendingPathComponent("first")),
            .init(id: "duplicate", url: directory.appendingPathComponent("second"))
        ]).refresh()
        XCTAssertFalse(try XCTUnwrap(duplicate.latestReport).isComplete)
        XCTAssertEqual(duplicate.latestReport?.total.logicalBytes, 3)
        XCTAssertTrue(try XCTUnwrap(duplicate.latestReport).issues.contains { $0.reason == .invalidRoot })
        let many = (0..<257).map {
            StorageUsageRoot(id: "optional-\($0)", url: directory.appendingPathComponent("absent-\($0)"), missingBehavior: .knownZero)
        }
        let bounded = await makeMonitor(many).refresh()
        XCTAssertFalse(try XCTUnwrap(bounded.latestReport).isComplete)
        XCTAssertEqual(bounded.latestReport?.roots.count, 256)
        XCTAssertTrue(try XCTUnwrap(bounded.latestReport).issues.contains { $0.reason == .resourceLimit })
    }

    func testDotDotRootCannotNormalizeAwayASymlink() async throws {
        try write("library/payload", bytes: 7)
        let traversal = URL(fileURLWithPath: directory.path + "/link/../library")
        let snapshot = await makeMonitor([.init(id: "traversal", url: traversal)]).refresh()
        XCTAssertFalse(try XCTUnwrap(snapshot.latestReport).isComplete)
        XCTAssertTrue(try XCTUnwrap(snapshot.latestReport).issues.contains { $0.reason == .invalidRoot })
        XCTAssertEqual(snapshot.latestReport?.total.fileCount, 0)
    }

    func testTinyCadenceIsBoundedToAvoidABusyPeriodicLoop() {
        XCTAssertEqual(StorageUsageConfiguration(refreshInterval: .leastNonzeroMagnitude).refreshInterval, 0.05)
        XCTAssertEqual(StorageUsageConfiguration(refreshInterval: .infinity).refreshInterval, 900)
        XCTAssertEqual(StorageUsageConfiguration(refreshInterval: -1).refreshInterval, 900)
    }

    func testConfigurationRejectsNonfiniteCadenceAndBoundsMemoryControls() {
        let config = StorageUsageConfiguration(refreshInterval: .nan, batchSize: 0,
                                                maxDepth: .max, maxHardLinkIdentities: 0, maxIssues: .max)
        XCTAssertEqual(config.refreshInterval, 900)
        XCTAssertEqual(config.batchSize, 1)
        XCTAssertEqual(config.maxDepth, 256)
        XCTAssertEqual(config.maxHardLinkIdentities, 1)
        XCTAssertEqual(config.maxIssues, 256)
    }

    private func makeMonitor(_ roots: [StorageUsageRoot], configuration: StorageUsageConfiguration = .init(),
                             shouldDefer: @escaping @Sendable () async -> Bool = { false }) -> StorageUsageMonitor {
        let monitor = StorageUsageMonitor(roots: roots, configuration: configuration, shouldDefer: shouldDefer)
        monitors.append(monitor)
        return monitor
    }

    private func write(_ path: String, bytes: Int) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    private func waitUntil(_ predicate: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for storage scan boundary")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor StorageUsageBatchProbe {
    private(set) var count = 0
    func markBatch() { count += 1 }
}
