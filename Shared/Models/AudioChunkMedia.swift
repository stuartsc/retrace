import Foundation

/// New-format capture is fixed to the native 16 kHz mono Int16 contract.
/// An origin/stream changes at every discontinuity; gaps are never synthesized as silence.
public struct AudioChunkInput: Sendable {
    public let id: UUID
    public let streamID: UUID
    public let source: AudioSource
    public let origin: Date
    public let startFrame: Int64
    public let pcmData: Data
    public init(id: UUID = UUID(), streamID: UUID, source: AudioSource, origin: Date,
                startFrame: Int64, pcmData: Data) {
        self.id = id; self.streamID = streamID; self.source = source; self.origin = origin
        self.startFrame = startFrame; self.pcmData = pcmData
    }
}

/// Versioned native decoder semantics. Encoded AAC identity and exact valid
/// sample ranges are authoritative; native floating-point amplitudes can vary
/// slightly between decodes of the same lossy file.
public enum AudioChunkDecodeContract: String, Codable, Sendable {
    case nativeAACPCM16V1
}

/// Immutable encoder receipt, including actual native AAC packet-table timing.
public struct AudioChunkDescriptor: Codable, Equatable, Sendable {
    public let storeID: UUID
    public let id: UUID
    public let streamID: UUID
    public let source: AudioSource
    public let origin: Date
    public let startFrame: Int64
    public let frameCount: Int64
    public let relativePath: String
    public let encodedBytes: Int64
    public let encodedSHA256: String
    public let originalPCMSHA256: String
    /// PCM observed at encoding verification. For nativeAACPCM16V1 this is an
    /// immutable diagnostic, not a promise of identical decoder amplitude bits.
    /// A missing decodeContract retains the pretrial strict hash interpretation.
    public let decodedPCMSHA256: String
    public let decodeContract: AudioChunkDecodeContract?
    public let validFrames: Int64
    public let primingFrames: Int64
    public let remainderFrames: Int64
    public let packetCount: Int64
    public let framesPerPacket: Int64
    public let trackStartSeconds: Double
    public init(storeID: UUID, id: UUID, streamID: UUID, source: AudioSource, origin: Date, startFrame: Int64,
                frameCount: Int64, relativePath: String, encodedBytes: Int64, encodedSHA256: String,
                originalPCMSHA256: String, decodedPCMSHA256: String, validFrames: Int64,
                primingFrames: Int64, remainderFrames: Int64, packetCount: Int64,
                framesPerPacket: Int64, trackStartSeconds: Double,
                decodeContract: AudioChunkDecodeContract? = nil) {
        self.id = id; self.streamID = streamID; self.source = source; self.origin = origin
        self.storeID = storeID
        self.startFrame = startFrame; self.frameCount = frameCount; self.relativePath = relativePath
        self.encodedBytes = encodedBytes; self.encodedSHA256 = encodedSHA256
        self.originalPCMSHA256 = originalPCMSHA256; self.decodedPCMSHA256 = decodedPCMSHA256
        self.decodeContract = decodeContract
        self.validFrames = validFrames; self.primingFrames = primingFrames
        self.remainderFrames = remainderFrames; self.packetCount = packetCount
        self.framesPerPacket = framesPerPacket; self.trackStartSeconds = trackStartSeconds
    }
}

public struct AudioChunkRange: Codable, Equatable, Sendable {
    public let chunk: AudioChunkDescriptor
    public let offsetFrames: Int64
    public let frameCount: Int64
    public init(chunk: AudioChunkDescriptor, offsetFrames: Int64, frameCount: Int64) {
        self.chunk = chunk; self.offsetFrames = offsetFrames; self.frameCount = frameCount
    }
}

/// A window is a logical recording, not another encoded copy. Its ID equals the
/// newly captured chunk ID; at most five seconds of its predecessor supply context.
public struct AudioWindowManifest: Codable, Equatable, Sendable {
    public static let sampleRate = 16_000
    public static let maximumChunkFrames: Int64 = 160_000
    public static let maximumContextFrames: Int64 = 80_000
    public static let maximumWindowFrames: Int64 = 240_000
    public let version: Int
    public let storeID: UUID
    public let id: UUID
    public let streamID: UUID
    public let source: AudioSource
    public let origin: Date
    public let startFrame: Int64
    public let frameCount: Int64
    /// First sample owned by this window, relative to the window start.
    public let ownedStartFrame: Int64
    public let ranges: [AudioChunkRange]
    public var startTime: Date { origin.addingTimeInterval(Double(startFrame) / Double(Self.sampleRate)) }
    public var endTime: Date { startTime.addingTimeInterval(Double(frameCount) / Double(Self.sampleRate)) }
    public var ownedStartTime: Date { startTime.addingTimeInterval(Double(ownedStartFrame) / Double(Self.sampleRate)) }
    public init(version: Int = 1, storeID: UUID, id: UUID, streamID: UUID, source: AudioSource, origin: Date,
                startFrame: Int64, frameCount: Int64, ownedStartFrame: Int64, ranges: [AudioChunkRange]) {
        self.version = version; self.storeID = storeID; self.id = id; self.streamID = streamID; self.source = source
        self.origin = origin; self.startFrame = startFrame; self.frameCount = frameCount
        self.ownedStartFrame = ownedStartFrame; self.ranges = ranges
    }
}

public struct StoredAudioWindow: Codable, Equatable, Sendable {
    public let manifest: AudioWindowManifest
    public let relativePath: String
    public let manifestSHA256: String
    public let manifestBytes: Int64
    public init(manifest: AudioWindowManifest, relativePath: String, manifestSHA256: String, manifestBytes: Int64) {
        self.manifest = manifest; self.relativePath = relativePath
        self.manifestSHA256 = manifestSHA256; self.manifestBytes = manifestBytes
    }
}

/// Revocation can stop playback synchronously while the owning actor joins cleanup.
public final class AudioMediaLeaseValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    private var onRevocation: (@Sendable () -> Void)?
    public init() {}
    public var isValid: Bool { lock.lock(); defer { lock.unlock() }; return !invalidated }
    public func revoke() {
        lock.lock()
        let callback = invalidated ? nil : onRevocation
        invalidated = true
        onRevocation = nil
        lock.unlock()
        callback?()
    }
    /// One playback consumer per lease. Delivery occurs outside the lock; an
    /// already revoked lease delivers immediately instead of missing the edge.
    public func observeRevocation(_ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        let revoked = invalidated
        if !revoked { onRevocation = callback }
        lock.unlock()
        if revoked { callback() }
    }
}

/// A verified encoded source and ordered valid sample selection. Native lossy
/// decode amplitudes need not be bit-identical across separate leases. Consumers
/// use these exact leased bytes for transcription or playback through release.
public struct AudioWindowReadLease: Sendable {
    public let id: UUID
    public let window: StoredAudioWindow
    public let pcmData: Data
    public let validity: AudioMediaLeaseValidity
    public init(id: UUID, window: StoredAudioWindow, pcmData: Data, validity: AudioMediaLeaseValidity) {
        self.id = id; self.window = window; self.pcmData = pcmData; self.validity = validity
    }
}
