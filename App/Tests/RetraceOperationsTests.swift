import Foundation
import Shared
import XCTest
@testable import App

final class RetraceOperationsTests: XCTestCase {
    func testReadDoesNotStartOptionalOwnersOrCreateStorageAndUnknownCountsStayUnknown() async throws {
        let services = ServiceContainer(inMemory: true)
        let coordinator = AppCoordinator(services: services)
        let root = await services.storage.getStorageDirectory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let snapshot = await coordinator.operationsSnapshot()
        XCTAssertNil(snapshot.pendingText)
        XCTAssertNil(snapshot.processingText)
        XCTAssertNil(snapshot.pendingSavedAudio)
        XCTAssertNil(snapshot.companion)
        XCTAssertNil(snapshot.voiceMarkers)
        XCTAssertFalse(snapshot.cpu.isCurrent)
        XCTAssertTrue(snapshot.unavailable.contains(.textQueue))
        XCTAssertTrue(snapshot.unavailable.contains(.savedAudioQueue))
        XCTAssertTrue(snapshot.unavailable.contains(.cpuMeasurement))
        XCTAssertGreaterThanOrEqual(snapshot.observedAt, snapshot.observationStartedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Reading operations must not initialize a store, model, transport or file scan")
    }

    func testBacklogReportsActualGovernorPermitAndRequiresOperationsGrant() async throws {
        let services = ServiceContainer(inMemory: true)
        let coordinator = AppCoordinator(services: services)
        // The real governor admits explicit work without native background scheduling.
        let permit = try await BackgroundProcessingContext.$explicitRequest.withValue(true) {
            try await services.backgroundProcessing.acquire(.historicalOCR)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = "operations-reader-token-at-least-32-characters"
        let evidence = "evidence-reader-token-at-least-32-characters"
        let dispatcher = try RetraceCommandDispatcher(directory: root, grants: [
            .init(clientID: "operations", tokenSHA256: RetraceCommandDispatcher.tokenDigest(reader), capabilities: [.operationsRead]),
            .init(clientID: "evidence", tokenSHA256: RetraceCommandDispatcher.tokenDigest(evidence), capabilities: [.evidenceRead])
        ], handlers: RetraceOperationsService.handlers(coordinator: coordinator))
        let denied = await dispatcher.execute(.init(requestID: UUID(), operation: .backlog), bearerToken: evidence)
        XCTAssertEqual(denied.status, .denied)
        let response = await dispatcher.execute(.init(requestID: UUID(), operation: .backlog), bearerToken: reader)
        XCTAssertEqual(response.status, .succeeded)
        let snapshot = try XCTUnwrap(response.data).decode(RetraceOperationsSnapshot.self)
        XCTAssertTrue(snapshot.background.running)
        XCTAssertEqual(snapshot.background.activeKind, "historicalOCR")
        XCTAssertEqual(snapshot.background.waitingCount, 0)
        XCTAssertNil(snapshot.pendingText, "No OCR queue exists; a governor permit is not a pending-frame count")
        await services.backgroundProcessing.release(permit)
        await services.backgroundProcessing.close()
        let stopped = await coordinator.operationsSnapshot()
        XCTAssertTrue(stopped.background.closed)
        XCTAssertFalse(stopped.background.running)
        await dispatcher.close()
    }
}
