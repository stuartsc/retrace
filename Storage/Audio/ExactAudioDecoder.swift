import AudioToolbox
import Foundation

public enum ExactAudioDecodeError: Error, Equatable, Sendable {
    case invalidInput, unsupportedFormat, frameCountMismatch, decodeFailed
}

/// Decodes an immutable, already verified AAC snapshot. No filesystem path is
/// reopened after identity validation and no resampling changes source offsets.
public enum ExactAudioDecoder {
    public static func decode(aac: Data, expectedFrames: Int64) throws -> Data {
        try Task.checkCancellation()
        guard !aac.isEmpty, aac.count <= 16 * 1_024 * 1_024,
              expectedFrames > 0, expectedFrames <= 120 * 16_000 else {
            throw ExactAudioDecodeError.invalidInput
        }
        let bytes = ExactAudioBytes(aac)
        let context = Unmanaged.passRetained(bytes).toOpaque()
        defer { Unmanaged<ExactAudioBytes>.fromOpaque(context).release() }
        var opened: AudioFileID?
        guard AudioFileOpenWithCallbacks(context, exactAudioRead, nil, exactAudioSize, nil,
            kAudioFileM4AType, &opened) == noErr, let file = opened else {
            throw ExactAudioDecodeError.decodeFailed
        }
        defer { AudioFileClose(file) }
        var wrapped: ExtAudioFileRef?
        guard ExtAudioFileWrapAudioFileID(file, false, &wrapped) == noErr, let reader = wrapped else {
            throw ExactAudioDecodeError.decodeFailed
        }
        defer { ExtAudioFileDispose(reader) }
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(reader, kExtAudioFileProperty_FileDataFormat, &formatSize, &format) == noErr,
              format.mFormatID == kAudioFormatMPEG4AAC, format.mSampleRate == 16_000,
              format.mChannelsPerFrame == 1 else { throw ExactAudioDecodeError.unsupportedFormat }
        var length: Int64 = 0
        var lengthSize = UInt32(MemoryLayout<Int64>.size)
        guard ExtAudioFileGetProperty(reader, kExtAudioFileProperty_FileLengthFrames, &lengthSize, &length) == noErr,
              length == expectedFrames else { throw ExactAudioDecodeError.frameCountMismatch }
        var client = AudioStreamBasicDescription(mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        guard ExtAudioFileSetProperty(reader, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client) == noErr else {
            throw ExactAudioDecodeError.decodeFailed
        }
        var result = Data()
        result.reserveCapacity(Int(expectedFrames) * 2)
        var samples = [Int16](repeating: 0, count: 8_192)
        while true {
            try Task.checkCancellation()
            var count: UInt32 = 8_192
            let status = samples.withUnsafeMutableBytes { storage in
                var buffers = AudioBufferList(mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(storage.count), mData: storage.baseAddress))
                return ExtAudioFileRead(reader, &count, &buffers)
            }
            guard status == noErr, count <= 8_192 else { throw ExactAudioDecodeError.decodeFailed }
            if count == 0 { break }
            guard result.count + Int(count) * 2 <= Int(expectedFrames) * 2 else {
                throw ExactAudioDecodeError.frameCountMismatch
            }
            samples.withUnsafeBytes { result.append(contentsOf: $0.prefix(Int(count) * 2)) }
        }
        guard result.count == Int(expectedFrames) * 2 else { throw ExactAudioDecodeError.frameCountMismatch }
        return result
    }
}

private final class ExactAudioBytes {
    let data: Data
    init(_ data: Data) { self.data = data }
}
private let exactAudioRead: AudioFile_ReadProc = { context, position, requested, buffer, actual in
    actual.pointee = 0
    let bytes = Unmanaged<ExactAudioBytes>.fromOpaque(context).takeUnretainedValue().data
    guard position >= 0, position <= Int64(bytes.count) else { return kAudioFilePositionError }
    let count = min(Int(requested), bytes.count - Int(position))
    if count > 0 { bytes.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), from: Int(position)..<(Int(position) + count)) }
    actual.pointee = UInt32(count)
    return noErr
}
private let exactAudioSize: AudioFile_GetSizeProc = { context in
    Int64(Unmanaged<ExactAudioBytes>.fromOpaque(context).takeUnretainedValue().data.count)
}
