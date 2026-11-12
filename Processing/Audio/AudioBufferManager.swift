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
    /// Exact native microphone slices only; gaps and legacy packets remain unproven.
    public let sourceRanges: [AudioBatchSourceRange]
    /// Provenance was omitted because of malformed PCM/identity or the metadata bound.
    public let sourceMappingIncomplete: Bool

    public init(audioData: Data, source: AudioSource, startTimestamp: Date, endTimestamp: Date,
                duration: TimeInterval, sampleRate: Int, channels: Int,
                sourceRanges: [AudioBatchSourceRange] = [], sourceMappingIncomplete: Bool = false) {
        self.audioData = audioData; self.source = source
        self.startTimestamp = startTimestamp; self.endTimestamp = endTimestamp
        self.duration = duration; self.sampleRate = sampleRate; self.channels = channels
        self.sourceRanges = sourceRanges
        self.sourceMappingIncomplete = sourceMappingIncomplete
    }
}

/// Accumulates CapturedAudio samples into time-windowed batches per source
/// Returns a batch when the buffer reaches maxBufferDuration worth of PCM data.
/// Keeps an overlap of audio between batches so sentences aren't cut at boundaries.
public actor AudioBufferManager {

    private let maxBufferDuration: TimeInterval
    /// Seconds of audio to carry over from the end of one batch to the start of the next
    private let overlapDuration: TimeInterval = 5.0

    // Separate buffers for mic and system audio
    private var micBuffer = Data()
    private var micStartTimestamp: Date?
    private var micEndTimestamp: Date?
    private var micDuration: TimeInterval = 0
    private var micSampleRate: Int = 16000
    private var micChannels: Int = 1
    private var micHasUnsavedAudio = false
    static let maximumSourceRanges = 256
    /// Byte coordinates preserve alignment while malformed prefixes age out.
    private struct SourceByteRange {
        let source: LiveAudioSampleIdentity
        let startByte: Int
        var endByte: Int { startByte + Int(source.sampleCount) * 2 }
    }
    private var micSourceRanges: [SourceByteRange] = []
    private var micInvalidFormatThroughByte = 0
    private var micOmittedMappingThroughByte = 0

    private var systemBuffer = Data()
    private var systemStartTimestamp: Date?
    private var systemEndTimestamp: Date?
    private var systemDuration: TimeInterval = 0
    private var systemSampleRate: Int = 16000
    private var systemChannels: Int = 1
    private var systemHasUnsavedAudio = false

    public init(maxBufferDuration: TimeInterval = 30.0) {
        self.maxBufferDuration = maxBufferDuration
    }

    /// Add a captured audio sample to the appropriate buffer.
    /// Returns an AudioBatch if the buffer has reached maxBufferDuration.
    public func addSample(_ audio: CapturedAudio) -> AudioBatch? {
        switch audio.source {
        case .microphone:
            micHasUnsavedAudio = true
            let endByte = micBuffer.count + audio.audioData.count
            let validFormat = audio.sampleRate == 16_000 && audio.channels == 1 && audio.audioData.count % 2 == 0
            if !validFormat {
                micInvalidFormatThroughByte = endByte
            }
            if let identity = audio.sampleIdentity {
                if validFormat, identity.isValid, identity.sampleCount == Int64(audio.audioData.count / 2) {
                    appendRange(SourceByteRange(source: identity, startByte: micBuffer.count))
                } else {
                    micOmittedMappingThroughByte = endByte
                }
            }
            micBuffer.append(audio.audioData)
            if micStartTimestamp == nil {
                micStartTimestamp = audio.timestamp
            }
            micEndTimestamp = audio.timestamp.addingTimeInterval(audio.duration)
            micDuration += audio.duration
            micSampleRate = audio.sampleRate
            micChannels = audio.channels

            if micDuration >= maxBufferDuration {
                return flushMicBuffer()
            }

        case .system, .zoom, .googleMeet, .microsoftTeams, .slack, .discord, .unknown:
            systemHasUnsavedAudio = true
            systemBuffer.append(audio.audioData)
            if systemStartTimestamp == nil {
                systemStartTimestamp = audio.timestamp
            }
            systemEndTimestamp = audio.timestamp.addingTimeInterval(audio.duration)
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
        if micHasUnsavedAudio, let batch = flushMicBuffer() {
            batches.append(batch)
        }
        if systemHasUnsavedAudio, let batch = flushSystemBuffer() {
            batches.append(batch)
        }
        micBuffer.removeAll(); micStartTimestamp = nil; micEndTimestamp = nil; micDuration = 0
        systemBuffer.removeAll(); systemStartTimestamp = nil; systemEndTimestamp = nil; systemDuration = 0
        micHasUnsavedAudio = false; systemHasUnsavedAudio = false
        micSourceRanges = []; micInvalidFormatThroughByte = 0; micOmittedMappingThroughByte = 0
        return batches
    }

    // MARK: - Private

    private func flushMicBuffer() -> AudioBatch? {
        guard !micBuffer.isEmpty, let start = micStartTimestamp else { return nil }
        micHasUnsavedAudio = false

        let batch = AudioBatch(
            audioData: micBuffer,
            source: .microphone,
            startTimestamp: start,
            endTimestamp: micEndTimestamp ?? start,
            duration: micDuration,
            sampleRate: micSampleRate,
            channels: micChannels,
            sourceRanges: micInvalidFormatThroughByte == 0 ? micSourceRanges.compactMap { range in
                guard range.startByte % 2 == 0 else { return nil }
                return AudioBatchSourceRange(source: range.source, batchStartSample: Int64(range.startByte / 2))
            } : [],
            sourceMappingIncomplete: micInvalidFormatThroughByte > 0 || micOmittedMappingThroughByte > 0 ||
                micSourceRanges.contains(where: { $0.startByte % 2 != 0 })
        )

        // Keep the last overlapDuration of audio as carry-over for the next batch
        let overlapBytes = Int(overlapDuration * Double(micSampleRate) * Double(micChannels) * 2) // 2 bytes per Int16 sample
        if micBuffer.count > overlapBytes {
            let firstRetainedByte = micBuffer.count - overlapBytes
            micSourceRanges = Self.retainedRanges(micSourceRanges, from: firstRetainedByte, through: micBuffer.count)
            micInvalidFormatThroughByte = max(0, micInvalidFormatThroughByte - firstRetainedByte)
            micOmittedMappingThroughByte = max(0, micOmittedMappingThroughByte - firstRetainedByte)
            let overlapData = micBuffer.suffix(overlapBytes)
            micBuffer = Data(overlapData)
            micStartTimestamp = micEndTimestamp?.addingTimeInterval(-overlapDuration)
            micDuration = overlapDuration
        } else {
            micBuffer = Data()
            micStartTimestamp = nil
            micEndTimestamp = nil
            micDuration = 0
            micSourceRanges = []
            micInvalidFormatThroughByte = 0
            micOmittedMappingThroughByte = 0
        }

        return batch
    }

    private func flushSystemBuffer() -> AudioBatch? {
        guard !systemBuffer.isEmpty, let start = systemStartTimestamp else { return nil }
        systemHasUnsavedAudio = false

        let batch = AudioBatch(
            audioData: systemBuffer,
            source: .system,
            startTimestamp: start,
            endTimestamp: systemEndTimestamp ?? start,
            duration: systemDuration,
            sampleRate: systemSampleRate,
            channels: systemChannels
        )

        // Keep the last overlapDuration of audio as carry-over for the next batch
        let overlapBytes = Int(overlapDuration * Double(systemSampleRate) * Double(systemChannels) * 2)
        if systemBuffer.count > overlapBytes {
            let overlapData = systemBuffer.suffix(overlapBytes)
            systemBuffer = Data(overlapData)
            systemStartTimestamp = systemEndTimestamp?.addingTimeInterval(-overlapDuration)
            systemDuration = overlapDuration
        } else {
            systemBuffer = Data()
            systemStartTimestamp = nil
            systemEndTimestamp = nil
            systemDuration = 0
        }

        return batch
    }

    private func appendRange(_ range: SourceByteRange) {
        if let previous = micSourceRanges.last,
           previous.source.recordingGeneration == range.source.recordingGeneration,
           previous.source.continuityID == range.source.continuityID,
           previous.source.sampleRate == range.source.sampleRate,
           previous.source.approximateOrigin == range.source.approximateOrigin,
           previous.source.startSample + previous.source.sampleCount == range.source.startSample,
           previous.endByte == range.startByte {
            let merged = LiveAudioSampleIdentity(recordingGeneration: previous.source.recordingGeneration,
                continuityID: previous.source.continuityID, startSample: previous.source.startSample,
                sampleCount: previous.source.sampleCount + range.source.sampleCount,
                sampleRate: previous.source.sampleRate, approximateOrigin: previous.source.approximateOrigin)
            if merged.isValid {
                micSourceRanges[micSourceRanges.count - 1] = SourceByteRange(source: merged, startByte: previous.startByte)
                return
            }
        }
        if micSourceRanges.count == Self.maximumSourceRanges {
            let omitted = micSourceRanges.removeFirst()
            micOmittedMappingThroughByte = max(micOmittedMappingThroughByte, omitted.endByte)
        }
        micSourceRanges.append(range)
    }

    private static func retainedRanges(_ ranges: [SourceByteRange], from first: Int,
                                       through end: Int) -> [SourceByteRange] {
        ranges.compactMap { range in
            let start = max(first, range.startByte)
            let stop = min(end, range.endByte)
            guard start < stop, (start - range.startByte) % 2 == 0, (stop - start) % 2 == 0 else { return nil }
            let source = LiveAudioSampleIdentity(recordingGeneration: range.source.recordingGeneration,
                continuityID: range.source.continuityID,
                startSample: range.source.startSample + Int64((start - range.startByte) / 2),
                sampleCount: Int64((stop - start) / 2), sampleRate: range.source.sampleRate,
                approximateOrigin: range.source.approximateOrigin)
            return SourceByteRange(source: source, startByte: start - first)
        }
    }
}
