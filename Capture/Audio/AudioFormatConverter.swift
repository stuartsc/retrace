import AVFoundation
import CoreMedia
import Foundation
import Shared

/// Stateful conversion to 16 kHz mono Int16 PCM, with native anti-alias filtering.
/// Each capture source owns one instance. Its lock protects AVAudioConverter across
/// serialized capture callbacks and background stop/reset calls; never call it from UI rendering.
public final class AudioFormatConverter: AudioFormatConverterProtocol, @unchecked Sendable {
    public let targetSampleRate = 16_000
    public let targetChannels = 1

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    public init() {}

    /// Compatibility entry point for interleaved raw PCM. Production callbacks use
    /// convert(sampleBuffer:) so the real channel layout and bit depth are retained.
    public func convertToStandardFormat(
        inputData: UnsafeRawPointer,
        inputLength: Int,
        inputSampleRate: Double,
        inputChannels: Int,
        inputFormat: AudioFormatType
    ) throws -> Data {
        let commonFormat: AVAudioCommonFormat
        let bytesPerSample: Int
        switch inputFormat {
        case .float32: commonFormat = .pcmFormatFloat32; bytesPerSample = 4
        case .int16: commonFormat = .pcmFormatInt16; bytesPerSample = 2
        case .int32: commonFormat = .pcmFormatInt32; bytesPerSample = 4
        }
        guard inputChannels > 0, inputChannels <= Int(UInt32.max),
              inputChannels <= Int.max / bytesPerSample,
              inputSampleRate.isFinite, inputSampleRate > 0 else {
            throw AudioCaptureError.formatConversionFailed
        }
        let bytesPerFrame = inputChannels * bytesPerSample
        guard inputLength > 0, inputLength.isMultiple(of: bytesPerFrame),
              inputLength / bytesPerFrame <= Int(UInt32.max),
              let format = AVAudioFormat(
                commonFormat: commonFormat, sampleRate: inputSampleRate,
                channels: AVAudioChannelCount(inputChannels), interleaved: true
              ) else { throw AudioCaptureError.formatConversionFailed }
        let frames = AVAudioFrameCount(inputLength / bytesPerFrame)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw AudioCaptureError.bufferAllocationFailed
        }
        buffer.frameLength = frames
        guard let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else {
            throw AudioCaptureError.bufferAllocationFailed
        }
        memcpy(destination, inputData, inputLength)
        return try convert(buffer: buffer)
    }

    /// Copies the actual PCM layout, including every noninterleaved channel plane.
    /// CoreMedia also handles segmented CMBlockBuffers; no borrowed pointers escape.
    public func convert(sampleBuffer: CMSampleBuffer) throws -> Data {
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard CMSampleBufferDataIsReady(sampleBuffer), count > 0, count <= Int(Int32.max),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio else {
            throw AudioCaptureError.formatConversionFailed
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.commonFormat != .otherFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw AudioCaptureError.formatConversionFailed
        }
        buffer.frameLength = AVAudioFrameCount(count)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { throw AudioCaptureError.formatConversionFailed }
        return try convert(buffer: buffer)
    }

    /// Successive buffers belong to one continuous source. Returning no bytes while
    /// the filter primes is valid; callers publish only the frames actually emitted.
    public func convert(buffer: AVAudioPCMBuffer) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard buffer.frameLength > 0, buffer.format.sampleRate.isFinite,
              buffer.format.sampleRate > 0, buffer.format.commonFormat != .otherFormat else {
            throw AudioCaptureError.formatConversionFailed
        }

        var output = Data()
        if inputFormat != buffer.format {
            if let oldFormat = inputFormat {
                output.append(try finishLocked())
                Log.info("[AudioFormatConverter] Audio format changed: \(oldFormat) -> \(buffer.format)", category: .capture)
            }
            let target = try outputFormat(sampleRate: Double(targetSampleRate))
            guard let fresh = AVAudioConverter(from: buffer.format, to: target) else {
                throw AudioCaptureError.formatConversionFailed
            }
            fresh.downmix = buffer.format.channelCount > 1
            fresh.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = fresh
            inputFormat = buffer.format
        }
        guard let converter else { throw AudioCaptureError.formatConversionFailed }
        let capacity = try outputCapacity(for: buffer, sampleRate: Double(targetSampleRate))
        guard let converted = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw AudioCaptureError.bufferAllocationFailed
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            guard !consumed else {
                // An end-of-stream here would reset filter/phase state every callback.
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else {
            resetLocked()
            throw AudioCaptureError.formatConversionFailed
        }
        output.append(try data(from: converted))
        return output
    }

    /// Drain filter samples on source shutdown, then permit a fresh stream.
    public func finish() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try finishLocked()
    }

    /// Discard pending samples at a privacy boundary or when capture restarts.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        resetLocked()
    }

    private func finishLocked() throws -> Data {
        guard let converter else { return Data() }
        defer { resetLocked() }
        var result = Data()
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4_096) else {
                throw AudioCaptureError.bufferAllocationFailed
            }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error, error == nil else { throw AudioCaptureError.formatConversionFailed }
            result.append(try data(from: buffer))
            if status == .endOfStream || buffer.frameLength == 0 { break }
        }
        return result
    }

    private func resetLocked() {
        converter = nil
        inputFormat = nil
    }

    private func data(from buffer: AVAudioPCMBuffer) throws -> Data {
        guard buffer.frameLength > 0 else { return Data() }
        guard let samples = buffer.int16ChannelData?[0] else { throw AudioCaptureError.formatConversionFailed }
        return Data(bytes: samples, count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
    }

    private func outputFormat(sampleRate: Double) throws -> AVAudioFormat {
        guard sampleRate.isFinite, sampleRate > 0,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
              ) else { throw AudioCaptureError.formatConversionFailed }
        return format
    }

    private func outputCapacity(for buffer: AVAudioPCMBuffer, sampleRate: Double) throws -> AVAudioFrameCount {
        let frames = ceil(Double(buffer.frameLength) * sampleRate / buffer.format.sampleRate) + 4_096
        guard frames.isFinite, frames > 0, frames <= Double(UInt32.max) else {
            throw AudioCaptureError.bufferAllocationFailed
        }
        return AVAudioFrameCount(frames)
    }

    /// Finite-buffer compatibility helper; live capture uses the persistent converter above.
    public func resampleWithAVAudioConverter(
        buffer: AVAudioPCMBuffer, targetSampleRate: Double
    ) throws -> AVAudioPCMBuffer {
        let format = try outputFormat(sampleRate: targetSampleRate)
        guard let converter = AVAudioConverter(from: buffer.format, to: format),
              let output = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: try outputCapacity(for: buffer, sampleRate: targetSampleRate)
              ) else { throw AudioCaptureError.formatConversionFailed }
        converter.downmix = buffer.format.channelCount > 1
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !consumed else { inputStatus.pointee = .endOfStream; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else { throw AudioCaptureError.formatConversionFailed }
        return output
    }
}

public enum AudioCaptureError: Error, Sendable {
    case permissionDenied
    case audioEngineStartFailed(String)
    case captureSessionFailed(String)
    case formatConversionFailed
    case bufferAllocationFailed
    case invalidConfiguration(String)
    case systemAudioNotAvailable
    case meetingDetectionFailed
}
