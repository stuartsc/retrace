import Foundation
import XCTest
@testable import Shared

final class DiagnosticFileLoggingTests: XCTestCase {
    func testDisabledPersistenceDoesNotCreateDirectoryOrRetryFileOpen() async throws {
        try await Task.detached(priority: .utility) {
            let root = try Self.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let destination = root.appendingPathComponent("absent", isDirectory: true)
            let logger = LogFile(directory: destination, persistenceEnabled: false)

            logger.append("Authored first diagnostic")
            logger.append("Authored second diagnostic")

            XCTAssertTrue(logger.readLastLines(count: 20).isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }.value
    }

    func testDisabledPersistencePreservesExistingLogAndRotationFilesWithoutReadingThem() async throws {
        try await Task.detached(priority: .utility) {
            let root = try Self.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let current = root.appendingPathComponent("retrace.log")
            let rotated = root.appendingPathComponent("retrace.old.log")
            // Exceeds the actual rotation threshold, so an accidental append
            // also exercises the destructive rename/replacement path.
            let currentBytes = Data(repeating: 65, count: 5 * 1024 * 1024 + 1)
            let rotatedBytes = Data("Authored previous diagnostic\n".utf8)
            try currentBytes.write(to: current)
            try rotatedBytes.write(to: rotated)
            let logger = LogFile(directory: root, persistenceEnabled: false)

            XCTAssertTrue(logger.readLastLines(count: 20).isEmpty)
            logger.append("Authored first diagnostic")
            logger.append("Authored retry diagnostic")

            XCTAssertTrue(try Data(contentsOf: current) == currentBytes)
            XCTAssertTrue(try Data(contentsOf: rotated) == rotatedBytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
                           ["retrace.log", "retrace.old.log"])
        }.value
    }

    func testEnabledPersistenceAppendsAndReadsActualPrivateFile() async throws {
        try await Task.detached(priority: .utility) {
            let root = try Self.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let logger = LogFile(directory: root, persistenceEnabled: true)
            logger.append("Authored first diagnostic")
            logger.append("Authored second diagnostic")

            XCTAssertEqual(logger.readLastLines(count: 1), ["Authored second diagnostic"])
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("retrace.log"), encoding: .utf8),
                           "Authored first diagnostic\nAuthored second diagnostic\n")
        }.value
    }

    func testDefaultAdmissionUsesProcessLaunchSettingForActualPrivateFile() async throws {
        try await Task.detached(priority: .utility) {
            let root = try Self.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let destination = root.appendingPathComponent("default", isDirectory: true)
            let logger = LogFile(directory: destination)
            logger.append("Authored default diagnostic")

            #if DEBUG
            let disabled = ProcessInfo.processInfo.environment["RETRACE_TEST_DISABLE_FILE_LOGGING"] == "1"
            #else
            let disabled = false
            #endif
            XCTAssertEqual(FileManager.default.fileExists(atPath: destination.path), !disabled)
            XCTAssertEqual(logger.readLastLines(count: 1), disabled ? [] : ["Authored default diagnostic"])
        }.value
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticFileLogging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
