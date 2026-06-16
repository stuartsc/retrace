import XCTest
@testable import Processing

final class AudioSpeechActivityPolicyTests: XCTestCase {
    func testAllowsQuietBatchWhenItContainsSpeechLikeActiveWindow() {
        let audio = Self.pcmWithBurst(
            duration: 30,
            sampleRate: 16_000,
            baselineAmplitude: 0.0012,
            burstAmplitude: 0.012,
            burstStart: 14,
            burstDuration: 1.2
        )

        let result = AudioSpeechActivityPolicy.evaluate(
            audio,
            sampleRate: 16_000,
            channels: 1
        )

        XCTAssertTrue(result.shouldTranscribe)
        XCTAssertLessThan(result.fullBatchRMS, 0.003)
        XCTAssertGreaterThan(result.activeWindowRMS, 0.004)
    }

    func testStillTranscribesContinuousLowLevelRoomNoiseButClassifiesItAsProbableSilence() {
        let audio = Self.pcmNoise(
            duration: 30,
            sampleRate: 16_000,
            amplitude: 0.0012
        )

        let result = AudioSpeechActivityPolicy.evaluate(
            audio,
            sampleRate: 16_000,
            channels: 1
        )

        XCTAssertTrue(result.shouldTranscribe)
        XCTAssertTrue(result.isProbablySilence)
        XCTAssertLessThan(result.fullBatchRMS, 0.003)
        XCTAssertLessThan(result.activeWindowRMS, 0.004)
    }

    func testEmptyAudioIsTheOnlyNonTranscribableInput() {
        let result = AudioSpeechActivityPolicy.evaluate(
            Data(),
            sampleRate: 16_000,
            channels: 1
        )

        XCTAssertFalse(result.shouldTranscribe)
        XCTAssertTrue(result.isProbablySilence)
    }

    private static func pcmWithBurst(
        duration: TimeInterval,
        sampleRate: Int,
        baselineAmplitude: Double,
        burstAmplitude: Double,
        burstStart: TimeInterval,
        burstDuration: TimeInterval
    ) -> Data {
        var samples: [Int16] = []
        let totalSamples = Int(duration * Double(sampleRate))
        let burstStartSample = Int(burstStart * Double(sampleRate))
        let burstEndSample = Int((burstStart + burstDuration) * Double(sampleRate))

        for index in 0..<totalSamples {
            let amplitude = (burstStartSample..<burstEndSample).contains(index)
                ? burstAmplitude
                : baselineAmplitude
            let wave = sin(2.0 * Double.pi * 220.0 * Double(index) / Double(sampleRate))
            samples.append(Int16(max(-1.0, min(1.0, wave * amplitude)) * 32767.0))
        }

        return Data(bytes: samples, count: samples.count * MemoryLayout<Int16>.size)
    }

    private static func pcmNoise(duration: TimeInterval, sampleRate: Int, amplitude: Double) -> Data {
        var samples: [Int16] = []
        let totalSamples = Int(duration * Double(sampleRate))

        for index in 0..<totalSamples {
            let wave = sin(2.0 * Double.pi * 90.0 * Double(index) / Double(sampleRate))
            samples.append(Int16(max(-1.0, min(1.0, wave * amplitude)) * 32767.0))
        }

        return Data(bytes: samples, count: samples.count * MemoryLayout<Int16>.size)
    }
}
