import Foundation
import Shared
import XCTest
@testable import App

final class SourceConfigurationServiceTests: XCTestCase {
    func testMCPConfirmationReusesServicePreviewAndDurableReplayDoesNotReconnect() async throws {
        let backend = SourceTestBackend(), owner = SourceConfigurationService(backend: backend.dependencies)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let token = "source-configuration-token-at-least-32-characters"
        let grants: [RetraceClientGrant] = [.init(clientID: "source-client",
            tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.settingsRead, .settingsWrite])]
        var dispatcher = try RetraceCommandDispatcher(directory: root, grants: grants,
            handlers: RetraceSourceCommands.handlers(owner: { owner }))
        let read = await dispatcher.execute(.init(requestID: UUID(), operation: .sourcesRead), bearerToken: token)
        let snapshot = try XCTUnwrap(read.data).decode(SourceConfigurationSnapshot.self)
        let arguments = RetraceJSON.object(["source": .string("rewind"), "enabled": .bool(true),
            "expectedRevision": .string(snapshot.revision.uuidString)])
        let offered = await dispatcher.execute(.init(requestID: UUID(), operation: .sourcesUpdate,
            arguments: arguments, mode: .preview), bearerToken: token)
        let preview = try XCTUnwrap(offered.preview)
        XCTAssertEqual(backend.counts, [0, 0, 0], "Preview must not open or persist source access")
        let request = RetraceCommandRequest(requestID: UUID(), operation: .sourcesUpdate, arguments: arguments,
            confirmation: .init(previewID: preview.id, digest: preview.digest))
        let applied = await dispatcher.execute(request, bearerToken: token)
        XCTAssertEqual(applied.status, .succeeded)
        XCTAssertEqual(backend.counts, [1, 0, 1])
        await dispatcher.close()
        dispatcher = try RetraceCommandDispatcher(directory: root, grants: grants,
            handlers: RetraceSourceCommands.handlers(owner: { owner }))
        let retry = await dispatcher.execute(request, bearerToken: token)
        XCTAssertEqual(retry.status, .succeeded); XCTAssertTrue(retry.replayed)
        XCTAssertEqual(backend.counts, [1, 0, 1])
        await dispatcher.close(); await owner.close()
    }

    func testMCPSourceReplacementRejectsEarlierConfirmationAndNoPathArgumentIsAccepted() async throws {
        let backend = SourceTestBackend(), owner = SourceConfigurationService(backend: backend.dependencies)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let token = "source-preview-token-at-least-32-characters"
        let dispatcher = try RetraceCommandDispatcher(directory: root, grants: [.init(clientID: "source-client",
            tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.settingsRead, .settingsWrite])],
            handlers: RetraceSourceCommands.handlers(owner: { owner }))
        let before = try await owner.read()
        let arguments = RetraceJSON.object(["source": .string("rewind"), "enabled": .bool(true), "expectedRevision": .string(before.revision.uuidString)])
        let offered = await dispatcher.execute(.init(requestID: UUID(), operation: .sourcesUpdate,
            arguments: arguments, mode: .preview), bearerToken: token)
        let preview = try XCTUnwrap(offered.preview)
        backend.replaceSelection("different-local-library")
        let result = await dispatcher.execute(.init(requestID: UUID(), operation: .sourcesUpdate, arguments: arguments,
            confirmation: .init(previewID: preview.id, digest: preview.digest)), bearerToken: token)
        XCTAssertEqual(result.status, .conflict)
        let invalid = await dispatcher.execute(.init(requestID: UUID(), operation: .sourcesUpdate,
            arguments: .object(["source": .string("rewind"), "enabled": .bool(true), "expectedRevision": .string(before.revision.uuidString),
                "path": .string("/private/unauthorized.db")]), mode: .preview), bearerToken: token)
        XCTAssertEqual(invalid.status, .failed)
        XCTAssertEqual(backend.counts, [0, 0, 0])
        await dispatcher.close(); await owner.close()
    }

    func testLocalFolderChangeDisconnectsBeforePersistAndKeepsEnabledPreferenceOnReconnectFailure() async throws {
        let backend = SourceTestBackend(enabled: true), owner = SourceConfigurationService(backend: backend.dependencies)
        let before = try await owner.read()
        let oldPreview = try await owner.preview(clientID: "client", expectedRevision: before.revision, enabled: false)
        backend.setFailure(.connectionFailed)
        do {
            _ = try await owner.changeLocalSelection {
                XCTAssertFalse(backend.environment.effectiveEnabled)
                XCTAssertTrue(backend.environment.configuredEnabled)
                backend.replaceSelection("new-local-library")
            }
            XCTFail("Failed reconnect")
        } catch { XCTAssertEqual(error as? SourceConfigurationError, .connectionFailed) }
        let after = try await owner.read()
        XCTAssertTrue(after.configuredEnabled); XCTAssertFalse(after.effectiveEnabled)
        XCTAssertEqual(after.issue, .connectionFailed)
        do { try await owner.validatePreview(clientID: "client", previewID: oldPreview.id); XCTFail("Old folder preview") }
        catch { XCTAssertEqual(error as? SourceConfigurationError, .stalePreview) }
        XCTAssertEqual(backend.counts, [1, 2, 0])
        await owner.close()
    }

    func testLocalSelectionFingerprintTracksFileReplacementWithoutReadingContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("selected.db")
        XCTAssertNil(SourceConfigurationSelectionIdentity.fingerprint(databasePath: database.path))
        try Data("authored original".utf8).write(to: database)
        let first = try XCTUnwrap(SourceConfigurationSelectionIdentity.fingerprint(databasePath: database.path))
        XCTAssertEqual(first.utf8.count, 64)
        let handle = try FileHandle(forWritingTo: database)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(" ordinary write".utf8)); try handle.close()
        XCTAssertEqual(SourceConfigurationSelectionIdentity.fingerprint(databasePath: database.path), first)
        let replacement = root.appendingPathComponent("replacement.db")
        try Data("authored replacement".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: database)
        try FileManager.default.moveItem(at: replacement, to: database)
        XCTAssertNotEqual(SourceConfigurationSelectionIdentity.fingerprint(databasePath: database.path), first)
    }

    func testReadIsPassiveAndEnableFailureDoesNotPersistOrReportAvailable() async throws {
        let backend = SourceTestBackend(), owner = SourceConfigurationService(backend: backend.dependencies)
        let state = try await owner.read()
        XCTAssertFalse(state.effectiveEnabled)
        XCTAssertEqual(backend.counts, [0, 0, 0])
        backend.setFailure(.connectionFailed)
        let preview = try await owner.preview(clientID: "local", expectedRevision: state.revision, enabled: true)
        do { _ = try await owner.apply(clientID: "local", requestID: UUID(), previewID: preview.id); XCTFail("Open failure") }
        catch { XCTAssertEqual(error as? SourceConfigurationError, .connectionFailed) }
        let after = try await owner.read()
        XCTAssertFalse(after.configuredEnabled); XCTAssertFalse(after.effectiveEnabled)
        XCTAssertEqual(after.issue, .connectionFailed)
        XCTAssertEqual(backend.counts, [1, 1, 0])
        await owner.close()
    }

    func testSuccessfulRequestCoalescesAndRetryReturnsOriginalReceipt() async throws {
        let backend = SourceTestBackend(), gate = SourceTestGate()
        backend.setGate(gate)
        let owner = SourceConfigurationService(backend: backend.dependencies)
        let before = try await owner.read()
        let preview = try await owner.preview(clientID: "client", expectedRevision: before.revision, enabled: true)
        let request = UUID()
        let first = Task { try await owner.apply(clientID: "client", requestID: request, previewID: preview.id) }
        await fulfillment(of: [gate.entered], timeout: 2)
        let duplicate = Task { try await owner.apply(clientID: "client", requestID: request, previewID: preview.id) }
        do { _ = try await owner.apply(clientID: "other", requestID: UUID(), previewID: preview.id); XCTFail("Different transition must fail busy") }
        catch { XCTAssertEqual(error as? SourceConfigurationError, .busy) }
        await gate.release()
        let receipt = try await first.value, joined = try await duplicate.value
        XCTAssertEqual(receipt, joined)
        XCTAssertTrue(receipt.state.configuredEnabled); XCTAssertTrue(receipt.state.effectiveEnabled)
        let replay = try await owner.apply(clientID: "client", requestID: request, previewID: preview.id)
        XCTAssertEqual(replay, receipt)
        XCTAssertEqual(backend.counts, [1, 0, 1])
        do { _ = try await owner.apply(clientID: "client", requestID: request, previewID: UUID()); XCTFail("Conflicting reuse") }
        catch { XCTAssertEqual(error as? SourceConfigurationError, .invalidRequest) }
        await owner.close()
    }

    func testPreviewBindsClientRevisionLocalSelectionAndExpiry() async throws {
        let backend = SourceTestBackend(), clock = SourceTestClock()
        let owner = SourceConfigurationService(backend: backend.dependencies, clock: { clock.now })
        let before = try await owner.read()
        let preview = try await owner.preview(clientID: "client", expectedRevision: before.revision, enabled: true)
        do { _ = try await owner.apply(clientID: "other", requestID: UUID(), previewID: preview.id); XCTFail("Client-bound") }
        catch { XCTAssertEqual(error as? SourceConfigurationError, .stalePreview) }
        backend.replaceSelection("replacement")
        do { _ = try await owner.apply(clientID: "client", requestID: UUID(), previewID: preview.id); XCTFail("Replaced library") }
        catch { XCTAssertEqual(error as? SourceConfigurationError, .stalePreview) }
        let current = try await owner.read()
        XCTAssertNotEqual(before.revision, current.revision)
        let expiring = try await owner.preview(clientID: "client", expectedRevision: current.revision, enabled: true)
        clock.advance(121)
        do { _ = try await owner.apply(clientID: "client", requestID: UUID(), previewID: expiring.id); XCTFail("Expired preview") }
        catch { XCTAssertEqual(error as? SourceConfigurationError, .stalePreview) }
        XCTAssertEqual(backend.counts, [0, 0, 0])
        await owner.close()
    }

    func testRevocationDuringNativeOpenRejectsPublicationAndJoinsCleanup() async throws {
        let backend = SourceTestBackend(), gate = SourceTestGate(), fence = NativeMutationFence()
        backend.setGate(gate)
        let owner = SourceConfigurationService(backend: backend.dependencies)
        let state = try await owner.read()
        let preview = try await owner.preview(clientID: "client", expectedRevision: state.revision, enabled: true)
        let request = Task { try await owner.apply(clientID: "client", requestID: UUID(), previewID: preview.id, commandFence: fence) }
        await fulfillment(of: [gate.entered], timeout: 2)
        fence.invalidate(); await gate.release()
        do { _ = try await request.value; XCTFail("Revoked grant") }
        catch { XCTAssertTrue(error is CancellationError) }
        let after = try await owner.read()
        XCTAssertFalse(after.effectiveEnabled); XCTAssertFalse(after.configuredEnabled)
        XCTAssertEqual(backend.counts, [1, 1, 0])
        await owner.close()
    }

    func testDisableStaysDisconnectedWhenPreferenceCannotBeSaved() async throws {
        let backend = SourceTestBackend(enabled: true)
        backend.setFailure(.persistenceFailed)
        let owner = SourceConfigurationService(backend: backend.dependencies)
        let before = try await owner.read()
        let preview = try await owner.preview(clientID: "local", expectedRevision: before.revision, enabled: false)
        do { _ = try await owner.apply(clientID: "local", requestID: UUID(), previewID: preview.id); XCTFail("Persistence failure") }
        catch { XCTAssertEqual(error as? SourceConfigurationError, .persistenceFailed) }
        let after = try await owner.read()
        XCTAssertTrue(after.configuredEnabled, "Unsaved preference must not be reported as saved")
        XCTAssertFalse(after.effectiveEnabled, "A failed disable save must never reconnect the source")
        XCTAssertEqual(after.issue, .persistenceFailed)
        XCTAssertEqual(backend.counts, [0, 1, 0])
        await owner.close()
    }

    func testCancellationAfterLogicalCommitReturnsReceiptWithoutRollback() async throws {
        let backend = SourceTestBackend()
        backend.cancelAfterCommit()
        let owner = SourceConfigurationService(backend: backend.dependencies)
        let before = try await owner.read()
        let preview = try await owner.preview(clientID: "local", expectedRevision: before.revision, enabled: true)
        let receipt = try await owner.apply(clientID: "local", requestID: UUID(), previewID: preview.id)
        XCTAssertTrue(receipt.state.configuredEnabled); XCTAssertTrue(receipt.state.effectiveEnabled)
        XCTAssertEqual(backend.counts, [1, 0, 1])
        await owner.close()
    }

    func testCloseWaitsForHeldNativeOpenAndCannotPublishAfterShutdown() async throws {
        let backend = SourceTestBackend(), gate = SourceTestGate()
        backend.setGate(gate)
        let owner = SourceConfigurationService(backend: backend.dependencies)
        let before = try await owner.read()
        let preview = try await owner.preview(clientID: "local", expectedRevision: before.revision, enabled: true)
        let request = Task { try await owner.apply(clientID: "local", requestID: UUID(), previewID: preview.id) }
        await fulfillment(of: [gate.entered], timeout: 2)
        let closed = expectation(description: "close waits for native cleanup")
        closed.isInverted = true
        let closing = Task { await owner.close(); closed.fulfill() }
        await fulfillment(of: [closed], timeout: 0.05)
        await gate.release(); await closing.value
        do { _ = try await request.value; XCTFail("Closed owner") } catch { }
        XCTAssertEqual(backend.counts, [1, 1, 0])
        XCTAssertFalse(backend.environment.effectiveEnabled)
        do { _ = try await owner.read(); XCTFail("Terminal close") }
        catch { XCTAssertEqual(error as? SourceConfigurationError, .closed) }
    }

    func testMissingSelectionCanBeDisabledButCannotBeEnabled() async throws {
        let backend = SourceTestBackend(enabled: true)
        backend.replaceSelection(nil)
        let owner = SourceConfigurationService(backend: backend.dependencies)
        let before = try await owner.read()
        XCTAssertFalse(before.hasLocalSelection)
        do { _ = try await owner.preview(clientID: "local", expectedRevision: before.revision, enabled: true); XCTFail("No local selection") }
        catch { XCTAssertEqual(error as? SourceConfigurationError, .selectionUnavailable) }
        let preview = try await owner.preview(clientID: "local", expectedRevision: before.revision, enabled: false)
        let receipt = try await owner.apply(clientID: "local", requestID: UUID(), previewID: preview.id)
        XCTAssertFalse(receipt.state.effectiveEnabled); XCTAssertFalse(receipt.state.configuredEnabled)
        await owner.close()
    }
}

private final class SourceTestBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var configured: Bool, effective: Bool
    private var fingerprint: String? = "locally-selected-library"
    private var connections = 0, disconnections = 0, commits = 0
    private var failure: SourceConfigurationError?
    private var gate: SourceTestGate?
    private var cancelOnCommit = false
    init(enabled: Bool = false) { configured = enabled; effective = enabled }
    var dependencies: SourceConfigurationBackend {
        .init(observe: { self.environment }, connect: { fingerprint, fences in
            let gate = self.beginConnect()
            await gate?.wait()
            try self.connect(fingerprint, fences: fences)
        }, disconnectAndDrain: { self.disconnect() }, commitPreference: { enabled, fingerprint in
            try self.commit(enabled, fingerprint)
        })
    }
    var environment: SourceConfigurationEnvironment {
        lock.lock(); defer { lock.unlock() }
        return .init(configuredEnabled: configured, effectiveEnabled: effective, selectionFingerprint: fingerprint)
    }
    var counts: [Int] { lock.lock(); defer { lock.unlock() }; return [connections, disconnections, commits] }
    func setFailure(_ value: SourceConfigurationError) { lock.lock(); defer { lock.unlock() }; failure = value }
    func setGate(_ value: SourceTestGate) { lock.lock(); defer { lock.unlock() }; gate = value }
    func replaceSelection(_ value: String?) { lock.lock(); defer { lock.unlock() }; fingerprint = value }
    func cancelAfterCommit() { lock.lock(); defer { lock.unlock() }; cancelOnCommit = true }
    private func beginConnect() -> SourceTestGate? { lock.lock(); defer { lock.unlock() }; connections += 1; return gate }
    private func connect(_ expected: String, fences: [NativeMutationFence]) throws {
        func apply(_ index: Int) throws {
            if index < fences.count { return try fences[index].withAdmission { try apply(index + 1) } }
            lock.lock(); defer { lock.unlock() }
            guard fingerprint == expected else { throw SourceConfigurationError.stalePreview }
            if failure == .connectionFailed { throw SourceConfigurationError.connectionFailed }
            effective = true
        }
        try apply(0)
    }
    private func disconnect() { lock.lock(); defer { lock.unlock() }; disconnections += 1; effective = false }
    private func commit(_ enabled: Bool, _ expected: String?) throws {
        lock.lock(); defer { lock.unlock() }
        guard fingerprint == expected else { throw SourceConfigurationError.stalePreview }
        if failure == .persistenceFailed { throw SourceConfigurationError.persistenceFailed }
        commits += 1; configured = enabled
        if cancelOnCommit { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

private actor SourceTestGate {
    nonisolated let entered = XCTestExpectation(description: "native source open held")
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        entered.fulfill()
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private final class SourceTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}
