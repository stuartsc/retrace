import Foundation

/// Cheap scheduling hint, never a permission to skip or discard a recording.
/// Even a brief active window makes a quiet batch uncertain rather than silent.
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

    public static func evaluate(_ audioData: Data, sampleRate: Int, channels: Int) -> Evaluation {
        let active = activeWindowStats(audioData, sampleRate: sampleRate, channels: channels)
        let fullBatchRMS = active.fullRMS
        let isProbablySilence = fullBatchRMS < fullBatchRMSFloor && active.maxRMS < activeWindowRMSFloor
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
    ) -> (maxRMS: Double, duration: TimeInterval, fullRMS: Double) {
        let safeSampleRate = max(sampleRate, 1)
        let safeChannels = max(channels, 1)
        let samplesPerWindow = max(Int(activeWindowDuration * Double(safeSampleRate * safeChannels)), 1)
        let int16Count = audioData.count / MemoryLayout<Int16>.size
        guard int16Count > 0 else { return (0, 0, 0) }
        var maxRMS = 0.0
        var activeSamples = 0
        var sumSquares = 0.0
        // One scan, no per-window Data allocation. Include the partial tail so
        // a brief word at a batch boundary keeps its scheduling priority.
        audioData.withUnsafeBytes { buffer in
            let samples = buffer.bindMemory(to: Int16.self)
            var offset = 0
            while offset < int16Count {
                let count = min(samplesPerWindow, int16Count - offset)
                var windowSquares = 0.0
                for index in offset..<(offset + count) {
                    let normalized = Double(samples[index]) / 32768.0
                    windowSquares += normalized * normalized
                }
                let rms = (windowSquares / Double(count)).squareRoot()
                maxRMS = max(maxRMS, rms)
                if rms >= activeWindowRMSFloor { activeSamples += count }
                sumSquares += windowSquares
                offset += count
            }
        }
        return (maxRMS, Double(activeSamples) / Double(safeSampleRate) / Double(safeChannels),
                (sumSquares / Double(int16Count)).squareRoot())
    }
}
