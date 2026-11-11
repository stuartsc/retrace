import CryptoKit
import Foundation

public enum AudioChunkMediaError: String, Error, Sendable {
    case invalidReceipt, unavailable, revoked, closed
}

/// Version-one bounds are checked before arithmetic, serialization or native decode.
public enum AudioChunkMediaValidation {
    public static func chunkPath(streamID: UUID, id: UUID) -> String {
        "audio/chunk-media/\(streamID.uuidString.lowercased())/\(id.uuidString.lowercased()).m4a"
    }
    public static func windowPath(streamID: UUID, id: UUID) -> String {
        "audio/chunk-media/\(streamID.uuidString.lowercased())/window_\(id.uuidString.lowercased()).retraceaudio"
    }
    public static func validate(_ chunk: AudioChunkDescriptor) throws {
        guard chunk.source != .unknown, validTime(chunk.origin), chunk.startFrame >= 0, chunk.startFrame <= 1 << 48,
              chunk.frameCount > 0, chunk.frameCount <= AudioWindowManifest.maximumChunkFrames,
              chunk.relativePath == chunkPath(streamID: chunk.streamID, id: chunk.id),
              chunk.encodedBytes > 0, chunk.encodedBytes <= 4 * 1_024 * 1_024,
              digest(chunk.encodedSHA256), digest(chunk.originalPCMSHA256), digest(chunk.decodedPCMSHA256),
              chunk.validFrames == chunk.frameCount, chunk.primingFrames >= 0, chunk.primingFrames <= 16_384,
              chunk.remainderFrames >= 0, chunk.remainderFrames <= 16_384,
              chunk.packetCount > 0, chunk.packetCount <= 1_024,
              chunk.framesPerPacket > 0, chunk.framesPerPacket <= 4_096,
              chunk.packetCount * chunk.framesPerPacket == chunk.validFrames + chunk.primingFrames + chunk.remainderFrames,
              chunk.trackStartSeconds.isFinite, chunk.trackStartSeconds >= 0, chunk.trackStartSeconds <= 1 else {
            throw AudioChunkMediaError.invalidReceipt
        }
    }
    public static func validate(_ window: AudioWindowManifest) throws {
        guard window.version == 1, validTime(window.origin), window.startFrame >= 0,
              window.startFrame <= 1 << 48, window.frameCount > 0,
              window.frameCount <= AudioWindowManifest.maximumWindowFrames,
              window.ownedStartFrame >= 0, window.ownedStartFrame <= AudioWindowManifest.maximumContextFrames,
              (1...2).contains(window.ranges.count) else { throw AudioChunkMediaError.invalidReceipt }
        var next = window.startFrame
        var total: Int64 = 0
        for range in window.ranges {
            try validate(range.chunk)
            guard range.chunk.storeID == window.storeID, range.chunk.streamID == window.streamID,
                  range.chunk.source == window.source, range.chunk.origin == window.origin,
                  range.offsetFrames >= 0, range.offsetFrames < range.chunk.frameCount,
                  range.frameCount > 0, range.frameCount <= range.chunk.frameCount - range.offsetFrames,
                  range.chunk.startFrame + range.offsetFrames == next else { throw AudioChunkMediaError.invalidReceipt }
            total += range.frameCount
            next += range.frameCount
        }
        guard let current = window.ranges.last, current.chunk.id == window.id,
              current.offsetFrames == 0, current.frameCount == current.chunk.frameCount,
              total == window.frameCount, window.ownedStartFrame == total - current.frameCount else {
            throw AudioChunkMediaError.invalidReceipt
        }
        if window.ranges.count == 2 {
            let previous = window.ranges[0]
            guard previous.chunk.id != current.chunk.id,
                  previous.frameCount == min(AudioWindowManifest.maximumContextFrames, previous.chunk.frameCount),
                  previous.offsetFrames + previous.frameCount == previous.chunk.frameCount else {
                throw AudioChunkMediaError.invalidReceipt
            }
        }
    }
    public static func encodedManifestData(_ window: AudioWindowManifest) throws -> Data {
        try validate(window)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(window)
    }
    public static func validate(_ stored: StoredAudioWindow) throws {
        try validate(stored.manifest)
        guard stored.relativePath == windowPath(streamID: stored.manifest.streamID, id: stored.manifest.id),
              stored.manifestBytes > 0, stored.manifestBytes <= 65_536,
              digest(stored.manifestSHA256) else { throw AudioChunkMediaError.invalidReceipt }
        let bytes = try encodedManifestData(stored.manifest)
        guard bytes.count == stored.manifestBytes,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == stored.manifestSHA256 else {
            throw AudioChunkMediaError.invalidReceipt
        }
    }
    private static func digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func validTime(_ value: Date) -> Bool {
        let seconds = value.timeIntervalSince1970
        return seconds.isFinite && seconds >= 0 && seconds < 32_503_680_000
    }
}
