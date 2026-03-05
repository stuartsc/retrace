import Foundation
import Shared

/// Batch of accumulated audio for transcription
public struct AudioBatch: Sendable {
    /// Combined PCM Int16 audio data
    public let audioData: Data
    /// Audio source (microphone or system)
    public let source: AudioSource
    /// Timestamp of the first sample in the batch
    public let startTimestamp: Date
    /// Timestamp of the last sample in the batch
    public let endTimestamp: Date
    /// Total duration in seconds
    public let duration: TimeInterval
    /// Sample rate
    public let sampleRate: Int
    /// Number of channels
    public let channels: Int
}

/// Accumulates CapturedAudio samples into time-windowed batches per source
/// Returns a batch when the buffer reaches maxBufferDuration worth of PCM data
public actor AudioBufferManager {

    private let maxBufferDuration: TimeInterval

    // Separate buffers for mic and system audio
    private var micBuffer = Data()
    private var micStartTimestamp: Date?
    private var micEndTimestamp: Date?
    private var micDuration: TimeInterval = 0
    private var micSampleRate: Int = 16000
    private var micChannels: Int = 1

    private var systemBuffer = Data()
    private var systemStartTimestamp: Date?
    private var systemEndTimestamp: Date?
    private var systemDuration: TimeInterval = 0
    private var systemSampleRate: Int = 16000
    private var systemChannels: Int = 1

    public init(maxBufferDuration: TimeInterval = 30.0) {
        self.maxBufferDuration = maxBufferDuration
    }

    /// Add a captured audio sample to the appropriate buffer.
    /// Returns an AudioBatch if the buffer has reached maxBufferDuration.
    public func addSample(_ audio: CapturedAudio) -> AudioBatch? {
        switch audio.source {
        case .microphone:
            micBuffer.append(audio.audioData)
            if micStartTimestamp == nil {
                micStartTimestamp = audio.timestamp
            }
            micEndTimestamp = audio.timestamp
            micDuration += audio.duration
            micSampleRate = audio.sampleRate
            micChannels = audio.channels

            if micDuration >= maxBufferDuration {
                return flushMicBuffer()
            }

        case .system, .zoom, .googleMeet, .microsoftTeams, .slack, .discord, .unknown:
            systemBuffer.append(audio.audioData)
            if systemStartTimestamp == nil {
                systemStartTimestamp = audio.timestamp
            }
            systemEndTimestamp = audio.timestamp
            systemDuration += audio.duration
            systemSampleRate = audio.sampleRate
            systemChannels = audio.channels

            if systemDuration >= maxBufferDuration {
                return flushSystemBuffer()
            }
        }

        return nil
    }

    /// Flush all remaining buffers on pipeline shutdown.
    /// Returns up to 2 batches (one per source).
    public func flush() -> [AudioBatch] {
        var batches: [AudioBatch] = []
        if let batch = flushMicBuffer() {
            batches.append(batch)
        }
        if let batch = flushSystemBuffer() {
            batches.append(batch)
        }
        return batches
    }

    // MARK: - Private

    private func flushMicBuffer() -> AudioBatch? {
        guard !micBuffer.isEmpty, let start = micStartTimestamp else { return nil }

        let batch = AudioBatch(
            audioData: micBuffer,
            source: .microphone,
            startTimestamp: start,
            endTimestamp: micEndTimestamp ?? start,
            duration: micDuration,
            sampleRate: micSampleRate,
            channels: micChannels
        )

        micBuffer = Data()
        micStartTimestamp = nil
        micEndTimestamp = nil
        micDuration = 0

        return batch
    }

    private func flushSystemBuffer() -> AudioBatch? {
        guard !systemBuffer.isEmpty, let start = systemStartTimestamp else { return nil }

        let batch = AudioBatch(
            audioData: systemBuffer,
            source: .system,
            startTimestamp: start,
            endTimestamp: systemEndTimestamp ?? start,
            duration: systemDuration,
            sampleRate: systemSampleRate,
            channels: systemChannels
        )

        systemBuffer = Data()
        systemStartTimestamp = nil
        systemEndTimestamp = nil
        systemDuration = 0

        return batch
    }
}
