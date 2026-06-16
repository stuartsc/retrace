import Foundation

/// Decides whether a captured audio batch has enough speech-like energy to transcribe.
/// Whole-batch RMS alone misses short quiet utterances inside mostly silent 30s batches.
public struct AudioSpeechActivityPolicy: Sendable {
    public struct Evaluation: Sendable {
        public let shouldTranscribe: Bool
        public let isProbablySilence: Bool
        public let fullBatchRMS: Double
        public let activeWindowRMS: Double
        public let activeDuration: TimeInterval
    }

    private static let fullBatchRMSFloor = 0.003
    private static let activeWindowRMSFloor = 0.004
    private static let activeWindowDuration: TimeInterval = 0.25
    private static let minimumActiveDuration: TimeInterval = 0.40

    public static func evaluate(_ audioData: Data, sampleRate: Int, channels: Int) -> Evaluation {
        let fullBatchRMS = calculateRMS(audioData)
        let active = activeWindowStats(audioData, sampleRate: sampleRate, channels: channels)
        let isProbablySilence = fullBatchRMS < fullBatchRMSFloor &&
            (active.duration < minimumActiveDuration || active.maxRMS < activeWindowRMSFloor)
        let shouldTranscribe = audioData.count >= MemoryLayout<Int16>.size

        return Evaluation(
            shouldTranscribe: shouldTranscribe,
            isProbablySilence: isProbablySilence,
            fullBatchRMS: fullBatchRMS,
            activeWindowRMS: active.maxRMS,
            activeDuration: active.duration
        )
    }

    private static func activeWindowStats(
        _ audioData: Data,
        sampleRate: Int,
        channels: Int
    ) -> (maxRMS: Double, duration: TimeInterval) {
        let safeSampleRate = max(sampleRate, 1)
        let safeChannels = max(channels, 1)
        let samplesPerWindow = max(Int(activeWindowDuration * Double(safeSampleRate * safeChannels)), 1)
        let bytesPerWindow = samplesPerWindow * MemoryLayout<Int16>.size
        guard audioData.count >= bytesPerWindow else {
            let rms = calculateRMS(audioData)
            return (rms, rms >= activeWindowRMSFloor ? activeWindowDuration : 0)
        }

        var maxRMS = 0.0
        var activeWindowCount = 0
        var offset = 0
        while offset + bytesPerWindow <= audioData.count {
            let window = audioData.subdata(in: offset..<(offset + bytesPerWindow))
            let rms = calculateRMS(window)
            maxRMS = max(maxRMS, rms)
            if rms >= activeWindowRMSFloor {
                activeWindowCount += 1
            }
            offset += bytesPerWindow
        }

        return (maxRMS, Double(activeWindowCount) * activeWindowDuration)
    }

    private static func calculateRMS(_ audioData: Data) -> Double {
        let int16Count = audioData.count / MemoryLayout<Int16>.size
        guard int16Count > 0 else { return 0 }

        var sumSquares = 0.0
        audioData.withUnsafeBytes { buffer in
            let samples = buffer.bindMemory(to: Int16.self)
            for index in 0..<int16Count {
                let normalized = Double(samples[index]) / 32768.0
                sumSquares += normalized * normalized
            }
        }
        return (sumSquares / Double(int16Count)).squareRoot()
    }
}
