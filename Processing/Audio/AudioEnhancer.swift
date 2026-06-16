import Foundation

/// Non-destructive PCM Int16 enhancement used only as transcription retry material.
/// Raw audio remains the source of truth on disk.
public enum AudioEnhancementVariant: String, Sendable, CaseIterable {
    case raw
    case normalized
    case boostedLimiter
    case aggressiveBoostedLimiter
    case highPassBoosted

    public static let retryOrder: [AudioEnhancementVariant] = [
        .raw,
        .normalized,
        .boostedLimiter,
        .aggressiveBoostedLimiter,
        .highPassBoosted
    ]
}

public enum AudioEnhancer {
    private static let limiterCeiling = 0.98

    public static func enhance(
        _ audioData: Data,
        variant: AudioEnhancementVariant,
        sampleRate: Int,
        channels: Int
    ) -> Data {
        switch variant {
        case .raw:
            return audioData
        case .normalized:
            return applyGain(audioData, targetPeak: 0.72, maximumGain: 24.0)
        case .boostedLimiter:
            return applyGain(audioData, targetPeak: 0.88, maximumGain: 48.0)
        case .aggressiveBoostedLimiter:
            return applyGain(audioData, targetPeak: 0.92, maximumGain: 96.0)
        case .highPassBoosted:
            let filtered = highPass(audioData, sampleRate: sampleRate, channels: channels)
            return applyGain(filtered, targetPeak: 0.84, maximumGain: 36.0)
        }
    }

    public static func rms(_ audioData: Data) -> Double {
        let samples = int16Samples(from: audioData)
        guard !samples.isEmpty else { return 0 }

        let sumSquares = samples.reduce(0.0) { partial, sample in
            let normalized = Double(sample) / 32768.0
            return partial + normalized * normalized
        }
        return (sumSquares / Double(samples.count)).squareRoot()
    }

    public static func peak(_ audioData: Data) -> Double {
        let samples = int16Samples(from: audioData)
        guard !samples.isEmpty else { return 0 }
        let maxValue = samples.map { abs(Double($0) / 32768.0) }.max() ?? 0
        return min(maxValue, 1.0)
    }

    private static func applyGain(_ audioData: Data, targetPeak: Double, maximumGain: Double) -> Data {
        let samples = int16Samples(from: audioData)
        guard !samples.isEmpty else { return audioData }

        let currentPeak = max(peak(audioData), 0.0001)
        let gain = min(max(targetPeak / currentPeak, 1.0), maximumGain)

        let enhanced = samples.map { sample -> Int16 in
            let boosted = Double(sample) * gain
            let limited = max(-limiterCeiling * 32767.0, min(limiterCeiling * 32767.0, boosted))
            return Int16(limited.rounded())
        }

        return Data(bytes: enhanced, count: enhanced.count * MemoryLayout<Int16>.size)
    }

    private static func highPass(_ audioData: Data, sampleRate: Int, channels: Int) -> Data {
        let samples = int16Samples(from: audioData)
        guard samples.count > 1 else { return audioData }

        let safeSampleRate = max(sampleRate, 1)
        let safeChannels = max(channels, 1)
        let cutoff = 90.0
        let dt = 1.0 / Double(safeSampleRate * safeChannels)
        let rc = 1.0 / (2.0 * Double.pi * cutoff)
        let alpha = rc / (rc + dt)

        var output = [Int16]()
        output.reserveCapacity(samples.count)

        var previousInput = Double(samples[0])
        var previousOutput = 0.0
        output.append(samples[0])

        for sample in samples.dropFirst() {
            let input = Double(sample)
            let filtered = alpha * (previousOutput + input - previousInput)
            let limited = max(-limiterCeiling * 32767.0, min(limiterCeiling * 32767.0, filtered))
            output.append(Int16(limited.rounded()))
            previousInput = input
            previousOutput = filtered
        }

        return Data(bytes: output, count: output.count * MemoryLayout<Int16>.size)
    }

    private static func int16Samples(from audioData: Data) -> [Int16] {
        let sampleCount = audioData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }

        return audioData.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Int16.self).prefix(sampleCount))
        }
    }
}
