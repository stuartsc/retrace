import Foundation
import XCTest
import Shared
@testable import App

final class RetraceCommandJobTests: XCTestCase {
    func testCompletionDuringReadAuthorizationCannotBecomeInterrupted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = "job-completion-race-token-at-least-32-characters"
        let grant = RetraceClientGrant(clientID: "owner", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.maintenance])
        let workerGate = JobReadCompletionGate()
        let readGate = JobReadCompletionGate()
        let readEntered = expectation(description: "Read retained the running record")
        let handler = RetraceCommandHandler(operation: .maintenance, runsAsJob: true) { context in
            await workerGate.wait()
            try await context.authorize()
            return .null
        }
        let dispatcher = try RetraceCommandDispatcher(directory: directory, grants: [grant], handlers: [handler])
        let submitted = await dispatcher.execute(.init(requestID: UUID(), operation: .maintenance), bearerToken: token)
        let job = try XCTUnwrap(submitted.data).decode(RetraceCommandJob.self)
        let arguments = RetraceJSON.object(["id": .string(job.id.uuidString)])
        await dispatcher.holdNextJobReadForTesting {
            readEntered.fulfill()
            await readGate.wait()
        }
        let suspended = Task {
            await dispatcher.execute(.init(requestID: UUID(), operation: .jobRead, arguments: arguments), bearerToken: token)
        }
        await fulfillment(of: [readEntered], timeout: 2)
        await workerGate.release()
        // A second ordinary read observes the actual durable terminal result before
        // the first read resumes with its formerly running snapshot.
        var completed = false
        for _ in 0..<100 {
            let response = await dispatcher.execute(.init(requestID: UUID(), operation: .jobRead, arguments: arguments), bearerToken: token)
            if try response.data?.decode(RetraceCommandJob.self).state == .succeeded {
                completed = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await readGate.release()
        let resumed = await suspended.value
        XCTAssertTrue(completed)
        XCTAssertEqual(try XCTUnwrap(resumed.data).decode(RetraceCommandJob.self).state, .succeeded)
        await dispatcher.close()
        let reopened = try RetraceCommandDispatcher(directory: directory, grants: [grant], handlers: [handler])
        let persisted = await reopened.execute(.init(requestID: UUID(), operation: .jobRead, arguments: arguments), bearerToken: token)
        XCTAssertEqual(try XCTUnwrap(persisted.data).decode(RetraceCommandJob.self).state, .succeeded)
        await reopened.close()
    }

    func testJobReadRequiresItsOriginalCapabilityAfterClientGrantChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = "job-capability-test-token-at-least-32-characters"
        let digest = RetraceCommandDispatcher.tokenDigest(token)
        let dispatcher = try RetraceCommandDispatcher(directory: directory,
            grants: [.init(clientID: "owner", tokenSHA256: digest, capabilities: [.maintenance])],
            handlers: [.init(operation: .maintenance, runsAsJob: true) { _ in .null }])
        let submitted = await dispatcher.execute(.init(requestID: UUID(), operation: .maintenance), bearerToken: token)
        let job = try XCTUnwrap(submitted.data).decode(RetraceCommandJob.self)
        let arguments = RetraceJSON.object(["id": .string(job.id.uuidString)])
        let cancellation = RetraceCommandRequest(requestID: UUID(), operation: .jobCancel, arguments: arguments)
        let cancelled = await dispatcher.execute(cancellation, bearerToken: token)
        XCTAssertEqual(cancelled.status, .succeeded)
        try await dispatcher.replaceGrants([.init(clientID: "owner", tokenSHA256: digest, capabilities: [.processing])])
        for operation in [RetraceOperation.jobRead, .jobCancel] {
            let result = await dispatcher.execute(.init(requestID: UUID(), operation: operation, arguments: arguments), bearerToken: token)
            XCTAssertEqual(result.status, .denied, "A different capability cannot inspect or control an older maintenance job")
            XCTAssertNil(result.data)
        }
        let replay = await dispatcher.execute(cancellation, bearerToken: token)
        XCTAssertEqual(replay.status, .denied, "Cached cancellation receipts retain their originating capability")
        XCTAssertNil(replay.data)
        await dispatcher.close()
    }

    func testJobOutlivesSubmissionAndResultSurvivesReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = "test-token-32-characters-minimum-length"
        let grant = RetraceClientGrant(clientID: "owner", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.maintenance])
        let output = directory.appendingPathComponent("completed.txt")
        let handler = RetraceCommandHandler(operation: .maintenance, runsAsJob: true) { context in
            try await Task.sleep(for: .milliseconds(10))
            try await context.authorize()
            try Data("completed".utf8).write(to: output)
            return .null
        }
        let dispatcher = try RetraceCommandDispatcher(directory: directory, grants: [grant], handlers: [handler])
        let response = await dispatcher.execute(.init(requestID: UUID(), operation: .maintenance), bearerToken: token)
        XCTAssertEqual(response.status, .succeeded)
        let job = try XCTUnwrap(response.data).decode(RetraceCommandJob.self)
        var status = job
        for _ in 0..<100 where status.state == .running {
            try await Task.sleep(for: .milliseconds(10))
            let response = await dispatcher.execute(.init(requestID: UUID(), operation: .jobRead, arguments: .object(["id": .string(job.id.uuidString)])), bearerToken: token)
            status = try XCTUnwrap(response.data).decode(RetraceCommandJob.self)
        }
        XCTAssertEqual(status.state, .succeeded)
        XCTAssertEqual(try String(contentsOf: output), "completed")
        await dispatcher.close()
        let reopened = try RetraceCommandDispatcher(directory: directory, grants: [grant], handlers: [handler])
        let read = await reopened.execute(.init(requestID: UUID(), operation: .jobRead, arguments: .object(["id": .string(job.id.uuidString)])), bearerToken: token)
        let persisted = try XCTUnwrap(read.data).decode(RetraceCommandJob.self)
        XCTAssertEqual(persisted.state, .succeeded)
        await reopened.close()
    }

    func testCancellationJoinsWorkerAndRemainsClientBound() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = "owner-token-32-characters-minimum-length"
        let stranger = "other-token-32-characters-minimum-length"
        let dispatcher = try RetraceCommandDispatcher(directory: directory,
            grants: [.init(clientID: "owner", tokenSHA256: RetraceCommandDispatcher.tokenDigest(owner), capabilities: [.processing]),
                     .init(clientID: "stranger", tokenSHA256: RetraceCommandDispatcher.tokenDigest(stranger), capabilities: [.processing])],
            handlers: [.init(operation: .processingRepair, runsAsJob: true) { _ in
                try await Task.sleep(for: .seconds(60)); return .null
            }])
        let submitted = await dispatcher.execute(.init(requestID: UUID(), operation: .processingRepair), bearerToken: owner)
        let job = try XCTUnwrap(submitted.data).decode(RetraceCommandJob.self)
        let arguments = RetraceJSON.object(["id": .string(job.id.uuidString)])
        let denied = await dispatcher.execute(.init(requestID: UUID(), operation: .jobRead, arguments: arguments), bearerToken: stranger)
        XCTAssertEqual(denied.status, .unavailable)
        let cancelled = await dispatcher.execute(.init(requestID: UUID(), operation: .jobCancel, arguments: arguments), bearerToken: owner)
        let status = try XCTUnwrap(cancelled.data).decode(RetraceCommandJob.self)
        XCTAssertEqual(status.state, .cancelled)
        XCTAssertTrue(status.effectsMayBePartial)
        await dispatcher.close()
    }
}

private actor JobReadCompletionGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
