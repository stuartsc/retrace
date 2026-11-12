import AVFoundation
import CoreMedia
import Foundation

/// Validated native sample interval, independent of callback queue delivery time.
struct AudioNativePacketTiming {
    let presentation: CMTime
    let end: CMTime
    let sampleRate: Double
    let format: CMFormatDescription

    init(_ sampleBuffer: CMSampleBuffer) throws {
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMSampleBufferDataIsReady(sampleBuffer), count > 0,
              presentation.isNumeric, presentation.timescale > 0,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mSampleRate.isFinite, description.mSampleRate > 0,
              description.mSampleRate <= 384_000,
              Double(count) <= description.mSampleRate * 60 else {
            throw AudioCaptureError.formatConversionFailed
        }
        self.presentation = presentation
        self.sampleRate = description.mSampleRate
        self.format = format
        self.end = CMTimeAdd(presentation,
            CMTime(seconds: Double(count) / description.mSampleRate, preferredTimescale: 1_000_000_000))
        guard end.isNumeric, CMTimeGetSeconds(presentation).isFinite, CMTimeGetSeconds(end).isFinite else {
            throw AudioCaptureError.formatConversionFailed
        }
    }
}

/// Protected by each delegate's existing state lock. The first receipt date is
/// an approximate wall-clock anchor; subsequent relative timing comes from PTS
/// and emitted PCM frames, never from variable callback delivery latency.
struct AudioCaptureSampleClock {
    private var format: CMFormatDescription?
    private var nativeOrigin: CMTime?
    private var expectedNativeStart: CMTime?
    private(set) var wallOrigin: Date?
    private(set) var emittedFrames: Int64 = 0
    private(set) var continuityID: UUID?

    func isContinuous(_ packet: AudioNativePacketTiming) -> Bool {
        guard let format, let expectedNativeStart,
              CMFormatDescriptionEqual(format, otherFormatDescription: packet.format),
              packet.presentation.epoch == expectedNativeStart.epoch else { return false }
        // Numeric CMTime rounding can differ by nanoseconds; half one native
        // sample admits representation error without smoothing a missing sample.
        let delta = abs(CMTimeGetSeconds(CMTimeSubtract(packet.presentation, expectedNativeStart)))
        return delta.isFinite && delta < 0.5 / packet.sampleRate
    }

    mutating func begin(_ packet: AudioNativePacketTiming, receivedAt: Date) {
        let newOrigin: Date
        if let nativeOrigin, let expectedNativeStart, let wallOrigin,
           packet.presentation.epoch == nativeOrigin.epoch,
           CMTimeCompare(packet.presentation, expectedNativeStart) >= 0 {
            // Forward PTS gaps (including sleep) and format changes retain the
            // native elapsed interval. A reset/backwards clock gets a new anchor.
            newOrigin = wallOrigin.addingTimeInterval(CMTimeGetSeconds(CMTimeSubtract(packet.presentation, nativeOrigin)))
        } else {
            newOrigin = receivedAt
        }
        nativeOrigin = packet.presentation
        expectedNativeStart = packet.presentation
        wallOrigin = newOrigin
        format = packet.format
        emittedFrames = 0
        continuityID = UUID()
    }

    mutating func consumed(_ packet: AudioNativePacketTiming) { expectedNativeStart = packet.end }

    mutating func timestampForOutput(frameCount: Int) -> Date? {
        guard frameCount > 0, let wallOrigin else { return nil }
        let timestamp = wallOrigin.addingTimeInterval(Double(emittedFrames) / 16_000)
        emittedFrames += Int64(frameCount)
        return timestamp
    }

    mutating func reset() { self = AudioCaptureSampleClock() }
}
