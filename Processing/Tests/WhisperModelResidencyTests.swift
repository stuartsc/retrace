import Foundation
import XCTest
import Shared
@testable import Processing

final class WhisperModelResidencyTests: XCTestCase {
    func testResidentModelStillRequiresExplicitInitialization() async {
        let service = WhisperCppTranscriptionService(
            modelPath: Self.missingModelPath(),
            modelResidency: .resident
        )

        do {
            _ = try await service.transcribe(Data())
            XCTFail("Expected transcription to require explicit initialization")
        } catch TranscriptionError.notInitialized {
            // Expected.
        } catch {
            XCTFail("Expected notInitialized, received \(error)")
        }
    }

    func testOnDemandModelAttemptsToLoadForFirstTranscription() async {
        let modelPath = Self.missingModelPath()
        let service = WhisperCppTranscriptionService(
            modelPath: modelPath,
            modelResidency: .onDemand(idleTimeout: .seconds(1))
        )

        do {
            _ = try await service.transcribe(Data())
            XCTFail("Expected the missing model load to fail")
        } catch TranscriptionError.modelLoadFailed(let message) {
            XCTAssertTrue(message.contains(modelPath))
        } catch {
            XCTFail("Expected modelLoadFailed, received \(error)")
        }
    }

    private static func missingModelPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-whisper-\(UUID().uuidString).bin")
            .path
    }
}
