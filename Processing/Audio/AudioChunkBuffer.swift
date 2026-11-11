import Foundation
import Shared

/// Capture owns samples once. Inference overlap is assembled later from durable
/// ranges, so this buffer never retains or re-emits an already emitted sample.
public actor AudioChunkBuffer {
    public enum InputError: Error, Sendable {
        case invalidFormat
        case invalidPCM
        case invalidTiming
        case callbackTooLarge
    }

    private struct Stream {
        let id: UUID
        let source: AudioSource
        let origin: Date
        let captureContinuityID: UUID?
        var nextFrame: Int64 = 0
        var bufferStartFrame: Int64 = 0
        var data = Data()
    }

    private var streams: [AudioSource: Stream] = [:]
    private static let maximumCallbackFrames = 960_000
    private static let bytesPerFrame = 2

    public init() {}

    /// At most seven outputs (one old partial plus six ten-second chunks).
    /// Invalid callbacks leave accepted PCM available to `finish()`.
    public func append(_ audio: CapturedAudio) throws -> [AudioChunkInput] {
        guard audio.sampleRate == 16_000, audio.channels == 1 else { throw InputError.invalidFormat }
        guard !audio.audioData.isEmpty, audio.audioData.count.isMultiple(of: Self.bytesPerFrame) else {
            throw InputError.invalidPCM
        }
        let frameCount = audio.audioData.count / Self.bytesPerFrame
        guard frameCount <= Self.maximumCallbackFrames else { throw InputError.callbackTooLarge }
        let duration = Double(frameCount) / 16_000
        guard audio.timestamp.timeIntervalSince1970.isFinite,
              abs(audio.timestamp.timeIntervalSince1970) < 9_000_000_000,
              audio.duration.isFinite, audio.duration > 0,
              abs(audio.duration - duration) <= 1.0 / 16_000 else { throw InputError.invalidTiming }

        var outputs: [AudioChunkInput] = []
        var stream: Stream
        if let existing = streams[audio.source] {
            let expected = existing.origin.addingTimeInterval(Double(existing.nextFrame) / 16_000)
            if existing.captureContinuityID == audio.continuityID,
               abs(audio.timestamp.timeIntervalSince(expected)) <= 1.0 / 16_000 {
                // Native callback dates can round by a sample. The stream's
                // integer sample clock remains the single canonical timebase.
                stream = existing
            } else {
                if !existing.data.isEmpty { outputs.append(Self.chunk(existing)) }
                stream = Stream(id: UUID(), source: audio.source, origin: audio.timestamp, captureContinuityID: audio.continuityID)
            }
        } else {
            stream = Stream(id: UUID(), source: audio.source, origin: audio.timestamp, captureContinuityID: audio.continuityID)
        }

        var offset = 0
        let maximumBytes = Int(AudioWindowManifest.maximumChunkFrames) * Self.bytesPerFrame
        while offset < audio.audioData.count {
            let count = min(maximumBytes - stream.data.count, audio.audioData.count - offset)
            stream.data.append(audio.audioData.subdata(in: offset..<offset + count))
            stream.nextFrame += Int64(count / Self.bytesPerFrame)
            offset += count
            if stream.data.count == maximumBytes {
                outputs.append(Self.chunk(stream))
                stream.data = Data()
                stream.bufferStartFrame = stream.nextFrame
            }
        }
        streams[audio.source] = stream
        return outputs
    }

    /// Final partials retain their actual sample count; no padding is invented.
    public func finish() -> [AudioChunkInput] {
        let result = streams.values.sorted { $0.source.rawValue < $1.source.rawValue }
            .filter { !$0.data.isEmpty }.map(Self.chunk)
        streams.removeAll()
        return result
    }

    private static func chunk(_ stream: Stream) -> AudioChunkInput {
        AudioChunkInput(streamID: stream.id, source: stream.source, origin: stream.origin,
            startFrame: stream.bufferStartFrame, pcmData: stream.data)
    }
}
