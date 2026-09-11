import Foundation
import XCTest
import Shared
@testable import Storage

/// Exercise the current extensionless chunks/YYYYMM/DD/<ID> layout using real files.
final class DirectoryManagerTests: XCTestCase {
    private var root: URL!
    private var directoryManager: DirectoryManager!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceDirectoryTests_\(UUID().uuidString)", isDirectory: true)
        directoryManager = DirectoryManager(storageRoot: root)
        try await directoryManager.ensureBaseDirectories()
    }

    override func tearDown() async throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        root = nil
        directoryManager = nil
        try await super.tearDown()
    }

    func testEnsureBaseDirectoriesCreatesExpectedFolders() async throws {
        for name in ["chunks", "temp"] {
            let url = root.appendingPathComponent(name, isDirectory: true)
            XCTAssertEqual(try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, true)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("segments").path))
    }

    func testEnsureBaseDirectoriesPreservesExistingContents() async throws {
        let existing = root.appendingPathComponent("chunks/existing-video")
        let contents = Data([0x00, 0x01, 0x02, 0x03])
        try contents.write(to: existing)
        try await directoryManager.ensureBaseDirectories()
        XCTAssertEqual(try Data(contentsOf: existing), contents)
    }

    func testSegmentURLLayout() async throws {
        let url = try await directoryManager.segmentURL(for: VideoSegmentID(value: 123456), date: fixtureDate())
        let expected = root.appendingPathComponent("chunks/202501/02/123456")
        XCTAssertEqual(url.standardizedFileURL, expected.standardizedFileURL)
        XCTAssertTrue(url.pathExtension.isEmpty)
        XCTAssertEqual(try url.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey]).isDirectory, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Allocating a path creates directories, not media")

        let contents = Data([0x66, 0x74, 0x79, 0x70])
        try contents.write(to: url)
        XCTAssertEqual(try Data(contentsOf: url), contents)
    }

    func testRelativePathFromRootRoundTripsExistingSegment() async throws {
        let url = try await directoryManager.segmentURL(for: VideoSegmentID(value: 789), date: fixtureDate())
        let contents = Data([0x01, 0x02, 0x03])
        try contents.write(to: url)
        let relative = await directoryManager.relativePath(from: url)
        XCTAssertEqual(relative, "chunks/202501/02/789")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(relative)), contents)
    }

    func testListAllSegmentFilesFindsExtensionlessMediaOnlyUnderChunks() async throws {
        let first = try await directoryManager.segmentURL(for: VideoSegmentID(value: 1), date: fixtureDate())
        let secondDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: fixtureDate()))
        let second = try await directoryManager.segmentURL(for: VideoSegmentID(value: 2), date: secondDate)
        for url in [first, second, root.appendingPathComponent("temp/in-progress"), root.appendingPathComponent("chunks/.hidden")] {
            try Data([0x01]).write(to: url)
        }
        let found = try await directoryManager.listAllSegmentFiles()
        XCTAssertEqual(Set(found.map { $0.standardizedFileURL.path }), Set([first.path, second.path]))
        for url in found {
            XCTAssertEqual(try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, true)
        }
    }

    private func fixtureDate() throws -> Date {
        // Production deliberately uses Calendar.current; construct the fixture in the
        // same calendar/time zone so a local date cannot roll into the previous day.
        try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 2, hour: 12)))
    }
}
