import XCTest
import Shared

final class AudioCaptureConfigPrivacyTests: XCTestCase {
    func testDefaultAudioCaptureKeepsSystemAndMeetingAudioOptIn() {
        let config = AudioCaptureConfig.default

        XCTAssertFalse(config.systemAudioEnabled)
        XCTAssertFalse(config.hasConsentedToMeetingRecording)
    }
}
