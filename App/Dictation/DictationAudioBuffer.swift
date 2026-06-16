import Foundation
import Shared

public struct DictationAudioSlice: Sendable, Equatable {
    public let audioData: Data
    public let startTime: Date
    public let endTime: Date
    public let duration: TimeInterval
    public let sampleRate: Int
    public let channels: Int
}

/// Rolling microphone PCM buffer used for low-latency push-to-dictate extraction.
public actor DictationAudioBuffer {
    private let maxDuration: TimeInterval
    private var samples: [CapturedAudio] = []

    public init(maxDuration: TimeInterval = 90) {
        self.maxDuration = maxDuration
        samples.reserveCapacity(2_048)
    }

    public func append(_ audio: CapturedAudio) {
        guard audio.source == .microphone, audio.duration > 0, !audio.audioData.isEmpty else {
            return
        }

        if let lastTimestamp = samples.last?.timestamp, audio.timestamp < lastTimestamp {
            let insertionIndex = samples.firstIndex { $0.timestamp > audio.timestamp } ?? samples.endIndex
            samples.insert(audio, at: insertionIndex)
        } else {
            samples.append(audio)
        }

        let latestEnd = audio.timestamp.addingTimeInterval(audio.duration)
        let cutoff = latestEnd.addingTimeInterval(-maxDuration)
        var firstRetainedIndex = samples.startIndex
        while firstRetainedIndex < samples.endIndex,
              samples[firstRetainedIndex].timestamp.addingTimeInterval(samples[firstRetainedIndex].duration) <= cutoff {
            samples.formIndex(after: &firstRetainedIndex)
        }
        if firstRetainedIndex > samples.startIndex {
            samples.removeSubrange(samples.startIndex..<firstRetainedIndex)
        }
    }

    public func slice(from requestedStart: Date, to requestedEnd: Date) -> DictationAudioSlice? {
        guard requestedEnd > requestedStart else { return nil }

        var output = Data()
        var sampleRate: Int?
        var channels: Int?
        var firstStart: Date?
        var lastEnd: Date?

        for sample in samples {
            let sampleStart = sample.timestamp
            let sampleEnd = sample.timestamp.addingTimeInterval(sample.duration)
            guard sampleEnd > requestedStart, sampleStart < requestedEnd else {
                continue
            }

            let overlapStart = max(sampleStart, requestedStart)
            let overlapEnd = min(sampleEnd, requestedEnd)
            guard overlapEnd > overlapStart else { continue }

            let rate = max(sample.sampleRate, 1)
            let channelCount = max(sample.channels, 1)
            let bytesPerFrame = channelCount * MemoryLayout<Int16>.size
            let totalFrames = sample.audioData.count / bytesPerFrame
            guard totalFrames > 0 else { continue }

            let startFrame = clampedFrameIndex(
                seconds: overlapStart.timeIntervalSince(sampleStart),
                sampleRate: rate,
                totalFrames: totalFrames,
                roundingRule: .down
            )
            let endFrame = clampedFrameIndex(
                seconds: overlapEnd.timeIntervalSince(sampleStart),
                sampleRate: rate,
                totalFrames: totalFrames,
                roundingRule: .up
            )
            guard endFrame > startFrame else { continue }

            let startByte = startFrame * bytesPerFrame
            let endByte = endFrame * bytesPerFrame
            output.append(sample.audioData.subdata(in: startByte..<endByte))

            sampleRate = sampleRate ?? rate
            channels = channels ?? channelCount
            firstStart = firstStart ?? sampleStart.addingTimeInterval(Double(startFrame) / Double(rate))
            lastEnd = sampleStart.addingTimeInterval(Double(endFrame) / Double(rate))
        }

        guard !output.isEmpty,
              let resolvedSampleRate = sampleRate,
              let resolvedChannels = channels,
              let resolvedStart = firstStart,
              let resolvedEnd = lastEnd else {
            return nil
        }

        let frameCount = output.count / (resolvedChannels * MemoryLayout<Int16>.size)
        let duration = Double(frameCount) / Double(resolvedSampleRate)

        return DictationAudioSlice(
            audioData: output,
            startTime: resolvedStart,
            endTime: resolvedEnd,
            duration: duration,
            sampleRate: resolvedSampleRate,
            channels: resolvedChannels
        )
    }

    private func clampedFrameIndex(
        seconds: TimeInterval,
        sampleRate: Int,
        totalFrames: Int,
        roundingRule: FloatingPointRoundingRule
    ) -> Int {
        let boundaryTolerance: TimeInterval = 1e-6
        let adjustedSeconds = roundingRule == .down
            ? seconds + boundaryTolerance
            : seconds - boundaryTolerance
        let scaled = adjustedSeconds * Double(sampleRate)
        let rawIndex = scaled.rounded(roundingRule)
        return min(max(Int(rawIndex), 0), totalFrames)
    }
}
