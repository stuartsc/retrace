import XCTest
import Shared
@testable import App

final class InstalledCPUGovernorTests: XCTestCase {
    func testServiceShutdownClosesGovernorAndSamplerBeforeDatabase() async throws {
        let services = ServiceContainer(inMemory: true)
        await services.setInitializationBoundaryForTesting(remainder: {})
        try await services.initialize()
        let governor = await services.backgroundProcessing
        await governor.updateEnvironment(.init(idleSeconds: 0))
        let waiting = Task { try await governor.acquire(.ambientSpeech) }
        await services.setBeforeDatabaseCloseForTesting {
            let status = await governor.snapshot()
            XCTAssertTrue(status.isClosed, "Native admission must close before SQLite")
            let sample = await services.resourceUsage.snapshot()
            XCTAssertFalse(sample.isCurrent, "Sampler must be joined before SQLite closes")
        }
        try await services.shutdown()
        // Cleanup even in the intentionally failing RED run.
        waiting.cancel()
        _ = try? await waiting.value
        await governor.close()
        await services.resourceUsage.close()
    }
}
