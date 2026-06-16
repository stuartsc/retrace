import XCTest
@testable import Processing

final class AudioEnhancementPolicyTests: XCTestCase {
    func testEnhancementVariantsKeepRawFirst() {
        let variants = AudioEnhancementVariant.retryOrder

        XCTAssertEqual(variants.first, .raw)
        XCTAssertTrue(variants.contains(.normalized))
        XCTAssertTrue(variants.contains(.boostedLimiter))
        XCTAssertTrue(variants.contains(.aggressiveBoostedLimiter))
        XCTAssertTrue(variants.contains(.highPassBoosted))
    }

    func testNormalizationRaisesQuietSpeechWithoutChangingDuration() {
        let audio = Self.pcmSine(duration: 1.0, sampleRate: 16_000, amplitude: 0.01)

        let enhanced = AudioEnhancer.enhance(
            audio,
            variant: .normalized,
            sampleRate: 16_000,
            channels: 1
        )

        XCTAssertEqual(enhanced.count, audio.count)
        XCTAssertGreaterThan(AudioEnhancer.rms(enhanced), AudioEnhancer.rms(audio))
        XCTAssertLessThanOrEqual(AudioEnhancer.peak(enhanced), 0.981)
    }

    func testBoostedLimiterPreventsClipping() {
        let audio = Self.pcmSine(duration: 1.0, sampleRate: 16_000, amplitude: 0.95)

        let enhanced = AudioEnhancer.enhance(
            audio,
            variant: .boostedLimiter,
            sampleRate: 16_000,
            channels: 1
        )

        XCTAssertEqual(enhanced.count, audio.count)
        XCTAssertLessThanOrEqual(AudioEnhancer.peak(enhanced), 0.981)
    }

    private static func pcmSine(duration: TimeInterval, sampleRate: Int, amplitude: Double) -> Data {
        let totalSamples = Int(duration * Double(sampleRate))
        var samples: [Int16] = []
        samples.reserveCapacity(totalSamples)

        for index in 0..<totalSamples {
            let wave = sin(2.0 * Double.pi * 220.0 * Double(index) / Double(sampleRate))
            samples.append(Int16(max(-1.0, min(1.0, wave * amplitude)) * 32767.0))
        }

        return Data(bytes: samples, count: samples.count * MemoryLayout<Int16>.size)
    }
}
