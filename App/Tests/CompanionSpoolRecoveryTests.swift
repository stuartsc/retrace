import Darwin
import Foundation
import Shared
import XCTest
@testable import App

final class CompanionSpoolRecoveryTests: XCTestCase {
    func testFullQuotaRecoversCrashPublicationLinkBeforeApplyingOrdinaryFileLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = CompanionSpool(root: root, nativeStoreID: UUID())
        try spool.initialize()
        let objects = root.appendingPathComponent("objects")
        for index in 0..<4096 {
            let name = String(repeating: "0", count: 60) + String(format: "%04x", index) + ".m4a"
            XCTAssertTrue(FileManager.default.createFile(atPath: objects.appendingPathComponent(name).path,
                contents: Data(), attributes: [.posixPermissions: 0o600]))
        }
        let retained = objects.appendingPathComponent(String(repeating: "0", count: 64) + ".m4a")
        let temporary = objects.appendingPathComponent(".publish-" + UUID().uuidString)
        XCTAssertEqual(Darwin.link(retained.path, temporary.path), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: objects.path).count, 4097)
        try spool.initialize()
        XCTAssertFalse(spool.exists(temporary))
        XCTAssertEqual(try spool.entries("objects").count, 4096)
        XCTAssertEqual(try spool.read(retained, limit: 0), Data(), "The retained link must remain and regain single-link ownership")
        try spool.initialize() // Reopen is idempotent.

        let overQuota = objects.appendingPathComponent(String(repeating: "f", count: 64) + ".m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: overQuota.path, contents: Data(), attributes: [.posixPermissions: 0o600]))
        XCTAssertThrowsError(try spool.initialize()) { XCTAssertEqual($0 as? CompanionError, .capacityExceeded) }
        XCTAssertTrue(spool.exists(overQuota), "Recovery must not remove ordinary files to force quota compliance")
    }

    func testCrashCleanupRejectsUnknownOrUnsafeTempsWithoutFollowingTheirTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = CompanionSpool(root: root, nativeStoreID: UUID())
        try spool.initialize()
        let objects = root.appendingPathComponent("objects"), original = root.appendingPathComponent("original.m4a")
        let bytes = Data("Authored original recording remains unchanged".utf8)
        try bytes.write(to: original)
        let unsafe = objects.appendingPathComponent(".publish-" + UUID().uuidString)
        XCTAssertEqual(Darwin.symlink(original.path, unsafe.path), 0)
        XCTAssertThrowsError(try spool.initialize()) { XCTAssertEqual($0 as? CompanionError, .unsafeStorage) }
        XCTAssertTrue(spool.exists(unsafe)); XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(Darwin.unlink(unsafe.path), 0)
        let unknown = objects.appendingPathComponent(".publish-not-a-uuid")
        XCTAssertTrue(FileManager.default.createFile(atPath: unknown.path, contents: bytes, attributes: [.posixPermissions: 0o600]))
        XCTAssertThrowsError(try spool.initialize()) { XCTAssertEqual($0 as? CompanionError, .unsafeStorage) }
        XCTAssertTrue(spool.exists(unknown)); XCTAssertEqual(try Data(contentsOf: original), bytes)
    }
    func testExclusivePublicationPreservesExistingBytesAndRejectsUnknownHardlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = CompanionSpool(root: root, nativeStoreID: UUID())
        try spool.initialize()
        let path = root.appendingPathComponent("requests/immutable.json")
        let original = Data("Original immutable publication".utf8)
        try spool.publish(original, to: path)
        try spool.publish(original, to: path)
        XCTAssertThrowsError(try spool.publish(Data("Substituted publication".utf8), to: path))
        XCTAssertEqual(try spool.read(path, limit: 64), original)
        let alias = root.appendingPathComponent("unknown-alias")
        XCTAssertEqual(Darwin.link(path.path, alias.path), 0)
        XCTAssertThrowsError(try spool.read(path, limit: 64)) { XCTAssertEqual($0 as? CompanionError, .unsafeStorage) }
        XCTAssertThrowsError(try spool.publish(original, to: path))
        XCTAssertEqual(try Data(contentsOf: alias), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: path.deletingLastPathComponent().path)
            .contains(where: { $0.hasPrefix(".publish-") }))
    }

}
