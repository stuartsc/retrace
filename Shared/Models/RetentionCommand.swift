import Foundation

/// Retention commands affect native screen history only. Audio and note-bearing
/// sessions remain retained and require their own explicit lifecycle.
public struct RetentionCommandPolicy: Codable, Sendable, Equatable {
    public let excludedApps: Set<String>
    public let excludedTagIDs: Set<Int64>
    public let excludeHidden: Bool
    public init(excludedApps: Set<String> = [], excludedTagIDs: Set<Int64> = [], excludeHidden: Bool = false) {
        self.excludedApps = excludedApps; self.excludedTagIDs = excludedTagIDs; self.excludeHidden = excludeHidden
    }
}

/// Internal discovery position, never mutation authority or an MCP argument.
/// Rows inserted behind a position require a fresh scan; each page is revalidated
/// independently before deletion. Both streams advance over ineligible rows.
public struct RetentionCommandCursor: Sendable {
    public let nativeStoreID: UUID
    public let cutoff: Date
    public let frameTimestamp: Int64?
    public let frameID: Int64?
    public let framesComplete: Bool
    public let videoID: Int64?
    public let videosComplete: Bool
    public init(nativeStoreID: UUID, cutoff: Date, frameTimestamp: Int64?, frameID: Int64?,
                framesComplete: Bool, videoID: Int64?, videosComplete: Bool) {
        self.nativeStoreID = nativeStoreID; self.cutoff = cutoff
        self.frameTimestamp = frameTimestamp; self.frameID = frameID; self.framesComplete = framesComplete
        self.videoID = videoID; self.videosComplete = videosComplete
    }
}

/// Internal writer-issued selection. Never accept these fields from an MCP client.
public struct RetentionCommandSelection: Sendable {
    public let id: UUID
    public let nativeStoreID: UUID
    public let cutoff: Date
    public let expiresAt: Date
    public let fingerprint: String
    public let frameIDs: [Int64]
    public let segmentIDs: [Int64]
    public let videos: [VideoSegment]
    public let hasMoreFrames: Bool
    public let hasMoreVideos: Bool
    public let externalVersion: Int64
    public let nextCursor: RetentionCommandCursor?
    public let scannedFrames: Int
    public let skippedFrames: Int
    public let scannedVideos: Int
    public let skippedVideos: Int
    public init(id: UUID, nativeStoreID: UUID, cutoff: Date, expiresAt: Date, fingerprint: String,
                frameIDs: [Int64], segmentIDs: [Int64], videos: [VideoSegment], hasMoreFrames: Bool,
                hasMoreVideos: Bool, externalVersion: Int64, nextCursor: RetentionCommandCursor? = nil,
                scannedFrames: Int = 0, skippedFrames: Int = 0, scannedVideos: Int = 0, skippedVideos: Int = 0) {
        self.id = id; self.nativeStoreID = nativeStoreID; self.cutoff = cutoff; self.expiresAt = expiresAt
        self.fingerprint = fingerprint; self.frameIDs = frameIDs; self.segmentIDs = segmentIDs; self.videos = videos
        self.hasMoreFrames = hasMoreFrames; self.hasMoreVideos = hasMoreVideos; self.externalVersion = externalVersion
        self.nextCursor = nextCursor; self.scannedFrames = scannedFrames; self.skippedFrames = skippedFrames
        self.scannedVideos = scannedVideos; self.skippedVideos = skippedVideos
    }
}

/// Reviewable, bounded destructive preview. No file path or recorded text is disclosed.
public struct RetentionCommandPreview: Codable, Sendable, Equatable {
    public let id: UUID
    public let clientID: String
    public let nativeStoreID: UUID
    public let captureRevision: UUID
    public let cutoff: Date
    public let expiresAt: Date
    public let fingerprint: String
    public let frames: Int
    public let sessions: Int
    public let videoCandidates: Int
    public let hasMore: Bool
    public let retainsAudio: Bool
    public let fileDeletionDeferred: Bool
    /// Continue discovery with this opaque, client-bound token. Following it
    /// supersedes this unexecuted preview. It expires with this preview.
    public let nextContinuationID: UUID?
    public let scannedFrames: Int
    public let skippedFrames: Int
    public let scannedVideos: Int
    public let skippedVideos: Int
    public let deferredVideoFiles: Int
    public init(id: UUID, clientID: String, nativeStoreID: UUID, captureRevision: UUID, cutoff: Date,
                expiresAt: Date, fingerprint: String, frames: Int, sessions: Int, videoCandidates: Int, hasMore: Bool,
                nextContinuationID: UUID? = nil, scannedFrames: Int = 0, skippedFrames: Int = 0,
                scannedVideos: Int = 0, skippedVideos: Int = 0, deferredVideoFiles: Int = 0) {
        self.id = id; self.clientID = clientID; self.nativeStoreID = nativeStoreID; self.captureRevision = captureRevision
        self.cutoff = cutoff; self.expiresAt = expiresAt; self.fingerprint = fingerprint; self.frames = frames
        self.sessions = sessions; self.videoCandidates = videoCandidates; self.hasMore = hasMore
        retainsAudio = true; fileDeletionDeferred = true
        self.nextContinuationID = nextContinuationID; self.scannedFrames = scannedFrames; self.skippedFrames = skippedFrames
        self.scannedVideos = scannedVideos; self.skippedVideos = skippedVideos; self.deferredVideoFiles = deferredVideoFiles
    }
}

public enum RetentionCommandPhase: String, Codable, Sendable { case validating, deletingScreens, drainingOutput, checkingVideos, completed }

public struct RetentionCommandOutcome: Codable, Sendable, Equatable {
    public let previewID: UUID
    public let nativeStoreID: UUID
    public let deletedFrames: Int
    public let deletedSessions: Int
    public let deletedVideoRows: Int
    public let pendingVideoFiles: Int
    public let reclaimedBytes: Int64
    public let retainsAudio: Bool
    public let partial: Bool
    public init(previewID: UUID, nativeStoreID: UUID, deletedFrames: Int, deletedSessions: Int,
                deletedVideoRows: Int, pendingVideoFiles: Int, partial: Bool) {
        self.previewID = previewID; self.nativeStoreID = nativeStoreID; self.deletedFrames = deletedFrames
        self.deletedSessions = deletedSessions; self.deletedVideoRows = deletedVideoRows
        self.pendingVideoFiles = pendingVideoFiles; reclaimedBytes = 0; retainsAudio = true; self.partial = partial
    }
}

public enum RetentionCommandError: Error, Sendable { case invalidArguments, unavailable, stalePreview, notPermitted, busy, closed }
