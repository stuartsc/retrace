import Foundation
import XCTest
@testable import App

final class RetentionPathValidationTests: XCTestCase {
    private func storageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RetentionPathTests-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chunks"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testRegularChunkAndMissingChunkRetryStayWithinStorageRoot() throws {
        let root = try storageRoot()
        let file = root.appendingPathComponent("chunks/1700000000001")
        try Data([1, 2, 3]).write(to: file)
        let valid = try RetentionManager.validatedVideoURL(root: root, relativePath: "chunks/1700000000001")
        XCTAssertEqual(valid, file.resolvingSymlinksInPath())
        try FileManager.default.removeItem(at: file)
        let retry = try RetentionManager.validatedVideoURL(root: root, relativePath: "chunks/1700000000001")
        XCTAssertEqual(retry, valid, "Missing files must permit idempotent database cleanup")
    }

    func testRejectsAbsoluteTraversalAndNonVideoPaths() throws {
        let root = try storageRoot()
        for path in ["/tmp/file", "chunks/../retrace.db", "audio/recording.m4a", "retrace.db", "chunks//file", "chunks/./file"] {
            XCTAssertThrowsError(try RetentionManager.validatedVideoURL(root: root, relativePath: path), path)
        }
    }

    func testDirectoryCannotBeUsedAsAFileDeletionCandidate() throws {
        let root = try storageRoot()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chunks/session"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try RetentionManager.validatedVideoURL(root: root, relativePath: "chunks/session"))
    }

    func testSymlinksCannotRedirectDeletionOutsideOrAliasAnotherChunk() throws {
        let root = try storageRoot()
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("RetentionExternal-\(UUID())")
        try Data([7]).write(to: external)
        addTeardownBlock { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("chunks/escape"), withDestinationURL: external)
        XCTAssertThrowsError(try RetentionManager.validatedVideoURL(root: root, relativePath: "chunks/escape"))
        let real = root.appendingPathComponent("chunks/real")
        try Data([8]).write(to: real)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("chunks/alias"), withDestinationURL: real)
        XCTAssertThrowsError(try RetentionManager.validatedVideoURL(root: root, relativePath: "chunks/alias"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path))
    }

    func testMissingStorageRootIsNotTreatedAsMissingVideo() throws {
        let root = try storageRoot()
        try FileManager.default.removeItem(at: root)
        XCTAssertThrowsError(try RetentionManager.validatedVideoURL(root: root, relativePath: "chunks/file"))
    }

    func testDeletionFindsMP4FallbackAndCountsActualRemovedBytes() throws {
        let root = try storageRoot()
        let path = "chunks/1700000000300"
        let fallback = root.appendingPathComponent(path + ".mp4")
        try Data([1, 2, 3]).write(to: fallback)
        let targets = try RetentionManager.validatedVideoURLs(root: root, relativePath: path)
        let removed = try RetentionManager.deleteValidatedVideoFiles(root: root, relativePath: path, expectedURLs: targets)
        XCTAssertEqual(removed, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.path))
        let retry = try RetentionManager.deleteValidatedVideoFiles(root: root, relativePath: path, expectedURLs: targets)
        XCTAssertEqual(retry, 0)
    }

    func testDeletionRemovesBothUnreferencedPrimaryAndReaderFallback() throws {
        let root = try storageRoot()
        let path = "chunks/1700000000301.mp4"
        let primary = root.appendingPathComponent(path)
        let fallback = root.appendingPathComponent(path + ".mp4")
        try Data([1, 2, 3]).write(to: primary)
        try Data([4, 5]).write(to: fallback)
        let targets = try RetentionManager.validatedVideoURLs(root: root, relativePath: path)
        let removed = try RetentionManager.deleteValidatedVideoFiles(root: root, relativePath: path, expectedURLs: targets)
        XCTAssertEqual(removed, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: primary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.path))
    }

    func testUnsafeFallbackIsRejectedBeforePrimaryFileIsRemoved() throws {
        let root = try storageRoot()
        let path = "chunks/1700000000302"
        let primary = root.appendingPathComponent(path)
        let fallback = root.appendingPathComponent(path + ".mp4")
        try Data([1, 2, 3]).write(to: primary)
        let targets = try RetentionManager.validatedVideoURLs(root: root, relativePath: path)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        XCTAssertThrowsError(try RetentionManager.deleteValidatedVideoFiles(root: root, relativePath: path, expectedURLs: targets))
        XCTAssertTrue(FileManager.default.fileExists(atPath: primary.path))
    }
}
