import AVFoundation
import Foundation
import Shared

/// Decodes M4A (AAC) audio files back to raw PCM Int16 data
/// Used by the backfill job to load saved batch audio for transcription
/// Owner: STORAGE agent
public enum AudioFileDecoder {

    public struct DecodedAudio: Sendable {
        public let data: Data
        public let sampleRate: Int
        public let duration: TimeInterval
    }

    /// Decode an M4A file to PCM Int16 data at 16kHz mono
    /// - Parameter fileURL: Path to the M4A file
    /// - Returns: PCM Int16 data, sample rate, and duration
    public static func decodeToPCM(fileURL: URL) throws -> DecodedAudio {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw StorageError.fileReadFailed(path: fileURL.path, underlying: "File not found")
        }

        let audioFile = try AVAudioFile(forReading: fileURL)

        // Target format: 16kHz mono Int16 PCM (what whisper expects)
        let targetSampleRate: Double = 16000
        let targetChannels: AVAudioChannelCount = 1
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        ) else {
            throw StorageError.fileReadFailed(path: fileURL.path, underlying: "Failed to create target audio format")
        }

        // Read source file into a float buffer first (AVAudioFile requires float for processing)
        let sourceFormat = audioFile.processingFormat
        let sourceFrameCount = AVAudioFrameCount(audioFile.length)

        guard sourceFrameCount > 0 else {
            throw StorageError.fileReadFailed(path: fileURL.path, underlying: "Audio file is empty")
        }

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrameCount) else {
            throw StorageError.fileReadFailed(path: fileURL.path, underlying: "Failed to create source buffer")
        }

        try audioFile.read(into: sourceBuffer)

        // Convert to target format using AVAudioConverter
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw StorageError.fileReadFailed(path: fileURL.path, underlying: "Failed to create audio converter from \(sourceFormat) to \(targetFormat)")
        }

        // Calculate target frame count based on sample rate ratio
        let sampleRateRatio = targetSampleRate / sourceFormat.sampleRate
        let targetFrameCount = AVAudioFrameCount(Double(sourceFrameCount) * sampleRateRatio)

        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrameCount) else {
            throw StorageError.fileReadFailed(path: fileURL.path, underlying: "Failed to create target buffer")
        }

        var conversionError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        let status = converter.convert(to: targetBuffer, error: &conversionError, withInputFrom: inputBlock)

        if let error = conversionError {
            throw StorageError.fileReadFailed(path: fileURL.path, underlying: "Audio conversion failed: \(error.localizedDescription)")
        }

        guard status != .error else {
            throw StorageError.fileReadFailed(path: fileURL.path, underlying: "Audio conversion returned error status")
        }

        // Extract Int16 PCM data from buffer
        guard let int16Data = targetBuffer.int16ChannelData else {
            throw StorageError.fileReadFailed(path: fileURL.path, underlying: "Failed to get Int16 channel data from converted buffer")
        }

        let frameCount = Int(targetBuffer.frameLength)
        let byteCount = frameCount * MemoryLayout<Int16>.size
        let data = Data(bytes: int16Data[0], count: byteCount)

        let duration = Double(frameCount) / targetSampleRate

        return DecodedAudio(
            data: data,
            sampleRate: Int(targetSampleRate),
            duration: duration
        )
    }
}
