import Foundation

/// Durable capture position, retained even when deletion precedes filesystem
/// frame-ID registration. Numeric frame IDs are meaningful only in their store.
public enum OriginalFrameAlias: Sendable, Equatable {
    case unknown
    case retained(frameID: FrameID)
    case deleted(frameID: FrameID)
}

/// A database acknowledgement, not an inference from queue state or file age.
/// The current archive mapping travels with extraction completion so storage can
/// reject a stale receipt after recovery moves a frame into a different video.
public enum OriginalFrameDisposition: Sendable {
    case pending
    case extracted(storeID: UUID, frame: FrameReference, archive: VideoSegment)
    case deleted(storeID: UUID)
}

public enum OriginalSpoolPressure: Error, Sendable, Equatable {
    case capacityLimit(retainedBytes: Int64, incomingBytes: Int64, limitBytes: Int64)
    case freeSpaceHeadroom(availableBytes: Int64, incomingBytes: Int64, minimumFreeBytes: Int64)
}

/// Content-free storage health. Limits apply to new admissions, never eviction
/// of pending originals. Archive readers remain compatible with old recordings.
public struct OriginalSpoolStatus: Sendable, Equatable {
    public static let defaultLimitBytes: Int64 = 5 * 1_024 * 1_024 * 1_024
    public static let defaultMinimumFreeBytes: Int64 = 20 * 1_024 * 1_024 * 1_024

    public let retainedBytes: Int64
    public let limitBytes: Int64
    public let availableBytes: Int64
    public let minimumFreeBytes: Int64
    public let retainedSessions: Int

    public init(retainedBytes: Int64, limitBytes: Int64 = Self.defaultLimitBytes,
                availableBytes: Int64, minimumFreeBytes: Int64 = Self.defaultMinimumFreeBytes,
                retainedSessions: Int) {
        self.retainedBytes = retainedBytes
        self.limitBytes = limitBytes
        self.availableBytes = availableBytes
        self.minimumFreeBytes = minimumFreeBytes
        self.retainedSessions = retainedSessions
    }
}
