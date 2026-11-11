import Foundation
import Shared
import XCTest
@testable import App

final class AudioMediaServiceLifecycleTests: XCTestCase {
    func testJoinedStartupRollbackReplacesClosedMediaBeforeRetry() async throws {
        let services = ServiceContainer(inMemory: true)
        let attempts = MediaStartupAttempts()
        await services.setInitializationBoundaryForTesting {
            let media = try await services.audioChunkMediaForTesting()
            _ = try await media.pendingWindows(limit: 1)
            if await attempts.next() == 1 { throw AudioEvidenceError.connectionBusy }
        }
        do { try await services.initialize(); XCTFail("Authored first initialization must fail") }
        catch AudioEvidenceError.connectionBusy { }
        try await services.initialize()
        let media = try await services.audioChunkMediaForTesting()
        let pending = try await media.pendingWindows(limit: 1)
        XCTAssertTrue(pending.isEmpty)
        try await services.jobs.beginRecording(generation: UUID())
        let recording = await services.jobs.isRecording
        XCTAssertTrue(recording, "A joined initialization rollback must not leave the policy owner terminal")
        try await services.jobs.endRecording()
        try await services.localRecall.configure(modelPackageURL: nil)
        try await services.shutdown()
        do { _ = try await services.audioChunkMediaForTesting(); XCTFail("Shutdown must reject lazy media acquisition") }
        catch AudioChunkMediaError.closed { }
        do { try await services.initialize(); XCTFail("Terminal shutdown must remain closed") }
        catch { }
    }
}

private actor MediaStartupAttempts {
    private var count = 0
    func next() -> Int { count += 1; return count }
}
