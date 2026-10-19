import Foundation
import Darwin
import os
import XCTest
@testable import Retrace

final class ProcessCPULogReaderTests: XCTestCase {
    func testLargeSparseLogReadsOnlyBoundedTailAndPreservesFile() throws {
        let url = try temporaryLog()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 2 * 1024 * 1024 * 1024)
        try handle.write(contentsOf: Data("\n{\"sample\":1}\n{\"sample\":2}\n".utf8))
        try handle.close()
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let result = try ProcessCPULogReader.readTail(at: url, maximumBytes: 4096, maximumLineBytes: 128, maximumLines: 10)
        XCTAssertTrue(result.wasTruncated)
        XCTAssertLessThanOrEqual(result.bytesRead, 4096)
        XCTAssertEqual(result.lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"sample\":1}", "{\"sample\":2}"])
        XCTAssertEqual(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size)
    }

    func testKeepsNewestCompleteLinesInOrderAndReportsBound() throws {
        let url = try temporaryLog()
        try Data((0..<20).map { "sample-\($0)\n" }.joined().utf8).write(to: url)
        let result = try ProcessCPULogReader.readTail(at: url, maximumLines: 3)
        XCTAssertEqual(result.lines.map { String(decoding: $0, as: UTF8.self) }, ["sample-17", "sample-18", "sample-19"])
        XCTAssertTrue(result.wasTruncated)
    }

    func testOversizedAndUnterminatedRecordsCannotBePublished() throws {
        let url = try temporaryLog()
        try Data((String(repeating: "x", count: 200_000) + "\ngood\nunfinished").utf8).write(to: url)
        let result = try ProcessCPULogReader.readTail(at: url, maximumLineBytes: 128)
        XCTAssertEqual(result.lines, [Data("good".utf8)])
        XCTAssertTrue(result.wasTruncated)
    }

    func testSmallCompleteLogRetainsEveryCompleteRecord() throws {
        let url = try temporaryLog()
        try Data("one\ntwo\n".utf8).write(to: url)
        let result = try ProcessCPULogReader.readTail(at: url)
        XCTAssertEqual(result.lines, [Data("one".utf8), Data("two".utf8)])
        XCTAssertFalse(result.wasTruncated)
        XCTAssertEqual(result.bytesRead, 8)
    }

    func testCancelledReadDoesNotPublishPartialResults() async throws {
        let url = try temporaryLog()
        try Data("sample\n".utf8).write(to: url)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ProcessCPULogReader.readTail(at: url)
        }
        do { _ = try await task.value; XCTFail("Cancelled read must stop") }
        catch is CancellationError {}
    }

    func testSymlinkIsRejectedWithoutReadingItsTarget() throws {
        let url = try temporaryLog()
        let link = url.deletingLastPathComponent().appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try ProcessCPULogReader.readTail(at: link))
    }

    func testCancellationAfterOpeningClosesTheOwnedDescriptor() async throws {
        let url = try temporaryLog()
        try Data("sample\n".utf8).write(to: url)
        let observedDescriptor = OSAllocatedUnfairLock(initialState: Int32(-1))
        let task = Task.detached {
            try ProcessCPULogReader.$didReadChunkForTesting.withValue({ descriptor in
                observedDescriptor.withLock { $0 = descriptor }
                withUnsafeCurrentTask { $0?.cancel() }
            }) { try ProcessCPULogReader.readTail(at: url) }
        }
        do { _ = try await task.value; XCTFail("In-flight cancellation must stop the read") }
        catch is CancellationError {}
        let descriptor = observedDescriptor.withLock { $0 }
        XCTAssertGreaterThanOrEqual(descriptor, 0, "The test must reach an open native file")
        var openInfo = stat()
        if fstat(descriptor, &openInfo) == 0 {
            var sourceInfo = stat()
            XCTAssertEqual(url.withUnsafeFileSystemRepresentation { lstat($0!, &sourceInfo) }, 0)
            XCTAssertFalse(openInfo.st_ino == sourceInfo.st_ino && openInfo.st_dev == sourceInfo.st_dev,
                           "The cancelled reader must not retain its source descriptor")
        }
    }

    func testCancelledPartialAggregateIsReloadedBeforeNextSnapshot() async throws {
        let url = try temporaryLog()
        let now = Date().timeIntervalSince1970
        let rows: [[String: Any]] = (1...2).map { index in
            ["timestamp": now - Double(3 - index), "durationSeconds": 1.0,
             "groupDeltaUnit": "ns", "groupDeltaNanoseconds": ["authored-log-process": 10_000_000]]
        }
        var data = Data()
        for row in rows {
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(0x0A)
        }
        try data.write(to: url)
        let sampler = ProcessCPULogSampler(logFileURL: url,
            displayNamesFileURL: url.deletingLastPathComponent().appendingPathComponent("groups.json"))
        let task = Task.detached {
            await ProcessCPULogSampler.$didConsumeLogEntryForTesting.withValue({
                withUnsafeCurrentTask { $0?.cancel() }
            }) {
                await sampler.sampleAndMaybeLoadSnapshot(windowDuration: 60, expectedIntervalSeconds: 2,
                                                         shouldBuildSnapshot: true)
            }
        }
        let cancelled = await task.value
        XCTAssertNil(cancelled, "A partial aggregate must not be published")
        let recovered = await sampler.sampleAndMaybeLoadSnapshot(windowDuration: 60, expectedIntervalSeconds: 2,
                                                                 shouldBuildSnapshot: true)
        let snapshot = try XCTUnwrap(recovered)
        let authored = try XCTUnwrap(snapshot.topProcesses.first { $0.id == "authored-log-process" })
        XCTAssertEqual(authored.cpuSeconds, 0.02, accuracy: 0.000001,
                       "The next read must recover both authored rows; unrelated live sampling cannot satisfy this check")
        let persisted = try FileHandle(forReadingFrom: url)
        defer { try? persisted.close() }
        XCTAssertEqual(try persisted.read(upToCount: data.count), data,
                       "Sampling must preserve the original diagnostic prefix")
    }

    func testOpeningSamplerDoesNotRewriteLargeHistory() async throws {
        let url = try temporaryLog()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 2 * 1024 * 1024 * 1024)
        try handle.write(contentsOf: Data("\n{\"old\":true}\n".utf8))
        try handle.close()
        let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let sampler = ProcessCPULogSampler(logFileURL: url,
            displayNamesFileURL: url.deletingLastPathComponent().appendingPathComponent("groups.json"))
        _ = await sampler.sampleAndMaybeLoadSnapshot(windowDuration: 60, expectedIntervalSeconds: 2,
                                                    shouldBuildSnapshot: true)
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        XCTAssertEqual(after.fileSize, before.fileSize)
        XCTAssertEqual(after.contentModificationDate, before.contentModificationDate)
    }

    private func temporaryLog() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("process.jsonl")
        try Data().write(to: url)
        return url
    }
}
