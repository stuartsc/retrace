import AVFoundation
import Foundation
import Shared

/// Writes sentence-level audio segments to disk as compressed M4A files
/// Owner: STORAGE agent
public actor AudioSegmentWriter {
    private let storageRoot: URL

    public init(storageRoot: URL) {
        self.storageRoot = storageRoot
    }

    /// Extract audio segment from buffer and save to M4A file
    /// - Parameters:
    ///   - audioData: Full PCM buffer (e.g., 30s chunk)
    ///   - startTime: Sentence start time relative to buffer start (seconds)
    ///   - endTime: Sentence end time relative to buffer start (seconds)
    ///   - sampleRate: Audio sample rate (default 16000 Hz)
    ///   - channels: Number of audio channels (default 1 for mono)
    ///   - timestamp: Absolute timestamp for the sentence
    ///   - source: Audio source (microphone or system_audio)
    /// - Returns: Tuple of (relative file path, file size in bytes)
    public func writeAudioSegment(
        audioData: Data,
        startTime: Double,
        endTime: Double,
        sampleRate: Int = 16000,
        channels: Int = 1,
        timestamp: Date,
        source: AudioSource
    ) async throws -> (filePath: String, fileSize: Int64) {

        // Validation
        guard !audioData.isEmpty else {
            throw StorageError.fileWriteFailed(path: "audio segment", underlying: "Empty audio data")
        }
        guard startTime >= 0 && endTime > startTime else {
            throw StorageError.fileWriteFailed(path: "audio segment", underlying: "Invalid time range: \(startTime)-\(endTime)")
        }

        // Calculate byte offsets for the sentence
        let bytesPerSample = 2  // Int16 PCM
        let startSample = Int(startTime * Double(sampleRate))
        let endSample = Int(endTime * Double(sampleRate))
        let startByte = startSample * bytesPerSample * channels
        let endByte = endSample * bytesPerSample * channels

        // Extract sentence audio data
        guard startByte >= 0 && endByte <= audioData.count && startByte < endByte else {
            throw StorageError.fileWriteFailed(path: "audio segment", underlying: "Invalid byte range: \(startByte)-\(endByte) for buffer size \(audioData.count)")
        }
        let sentenceData = audioData.subdata(in: startByte..<endByte)

        guard !sentenceData.isEmpty else {
            throw StorageError.fileWriteFailed(path: "audio segment", underlying: "Extracted audio segment is empty")
        }

        // Create output directory structure: audio/2024/12/13/
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy/MM/dd"
        let datePath = dateFormatter.string(from: timestamp)
        let outputDir = storageRoot
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent(datePath, isDirectory: true)

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Generate unique filename: sentence_{timestamp}_{source}_{hash}_{uuid}.m4a
        // UUID suffix prevents overwriting in case of hash collision
        let timestampMs = Int(timestamp.timeIntervalSince1970 * 1000)
        let hash = String(abs(sentenceData.hashValue) & 0xFFFF, radix: 16, uppercase: true)
        let uuid = UUID().uuidString.prefix(8)
        let filename = "sentence_\(timestampMs)_\(source.rawValue)_\(hash)_\(uuid).m4a"
        let outputURL = outputDir.appendingPathComponent(filename)

        // Check if file already exists (should never happen with UUID, but safety check)
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw StorageError.fileWriteFailed(path: outputURL.path, underlying: "File already exists")
        }

        // Convert PCM to M4A (AAC compression)
        try await convertPCMToM4A(
            pcmData: sentenceData,
            outputURL: outputURL,
            sampleRate: sampleRate,
            channels: channels
        )

        // Get file size
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = attrs[.size] as? Int64 ?? 0

        // Return relative path from storage root
        let relativePath = "audio/\(datePath)/\(filename)"

        return (relativePath, fileSize)
    }

    /// Convert raw PCM Int16 data to compressed M4A file using AVAudioFile
    private func convertPCMToM4A(
        pcmData: Data,
        outputURL: URL,
        sampleRate: Int,
        channels: Int
    ) async throws {

        // Remove existing file if present
        try? FileManager.default.removeItem(at: outputURL)

        // Create PCM format matching input data (Int16, interleaved)
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            throw StorageError.fileWriteFailed(path: outputURL.path, underlying: "Failed to create input audio format")
        }

        // Create float format for the intermediate buffer (AVAudioFile requires float for writing)
        guard let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else {
            throw StorageError.fileWriteFailed(path: outputURL.path, underlying: "Failed to create float audio format")
        }

        // AAC output settings (use quality-based encoding; explicit bitrate fails at 16kHz)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: channels,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        // Create output file with AAC compression
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        // Create PCM buffer from raw Int16 data
        let frameCount = pcmData.count / (MemoryLayout<Int16>.size * channels)
        guard let floatBuffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw StorageError.fileWriteFailed(path: outputURL.path, underlying: "Failed to create float buffer")
        }
        floatBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Convert Int16 PCM data to Float32
        pcmData.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) in
            guard let int16Ptr = rawPtr.bindMemory(to: Int16.self).baseAddress,
                  let floatChannelData = floatBuffer.floatChannelData else { return }

            let floatPtr = floatChannelData[0]
            for i in 0..<frameCount {
                floatPtr[i] = Float(int16Ptr[i]) / 32768.0
            }
        }

        // Write to file (AVAudioFile handles AAC encoding internally)
        try outputFile.write(from: floatBuffer)
    }

    /// Write the full batch audio buffer to disk as a compressed M4A file
    /// Called before transcription to ensure raw audio is never lost
    /// - Parameters:
    ///   - audioData: Full PCM buffer (e.g., 30s chunk)
    ///   - sampleRate: Audio sample rate (default 16000 Hz)
    ///   - channels: Number of audio channels (default 1 for mono)
    ///   - timestamp: Absolute timestamp for the batch start
    ///   - source: Audio source (microphone or system_audio)
    /// - Returns: Tuple of (relative file path, file size in bytes)
    public func writeFullBatch(
        audioData: Data,
        sampleRate: Int = 16000,
        channels: Int = 1,
        timestamp: Date,
        source: AudioSource
    ) async throws -> (filePath: String, fileSize: Int64) {

        guard !audioData.isEmpty else {
            throw StorageError.fileWriteFailed(path: "audio batch", underlying: "Empty audio data")
        }

        // Create output directory structure: audio/YYYY/MM/DD/
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy/MM/dd"
        let datePath = dateFormatter.string(from: timestamp)
        let outputDir = storageRoot
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent(datePath, isDirectory: true)

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Generate unique filename: batch_{timestamp}_{source}_{hash}_{uuid}.m4a
        let timestampMs = Int(timestamp.timeIntervalSince1970 * 1000)
        let hash = String(abs(audioData.hashValue) & 0xFFFF, radix: 16, uppercase: true)
        let uuid = UUID().uuidString.prefix(8)
        let filename = "batch_\(timestampMs)_\(source.rawValue)_\(hash)_\(uuid).m4a"
        let outputURL = outputDir.appendingPathComponent(filename)

        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw StorageError.fileWriteFailed(path: outputURL.path, underlying: "File already exists")
        }

        // Convert PCM to M4A (AAC compression)
        try await convertPCMToM4A(
            pcmData: audioData,
            outputURL: outputURL,
            sampleRate: sampleRate,
            channels: channels
        )

        // Get file size
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = attrs[.size] as? Int64 ?? 0

        let relativePath = "audio/\(datePath)/\(filename)"
        return (relativePath, fileSize)
    }

    /// Delete an audio segment file
    public func deleteAudioSegment(relativePath: String) throws {
        let fileURL = storageRoot.appendingPathComponent(relativePath)
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Get the full URL for an audio segment
    public func getAudioSegmentURL(relativePath: String) -> URL {
        return storageRoot.appendingPathComponent(relativePath)
    }
}
