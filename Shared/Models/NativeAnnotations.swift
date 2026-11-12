import Foundation

/// A process-local native annotation revision. It is deliberately not a reusable
/// evidence grant. Reopening the native writer changes its connection identity.
public struct NativeAnnotationRevision: Codable, Sendable, Equatable {
    public let connectionID: UUID
    public let sequence: Int64
    public let externalVersion: Int64
    public init(connectionID: UUID, sequence: Int64, externalVersion: Int64) {
        self.connectionID = connectionID; self.sequence = sequence; self.externalVersion = externalVersion
    }
}

public struct NativeAnnotationComment: Codable, Sendable, Equatable {
    public let id: SegmentCommentID
    public let body: String
    public let author: String
    public let attachmentCount: Int
    public let createdAt: Date
    public let updatedAt: Date
    public init(id: SegmentCommentID, body: String, author: String, attachmentCount: Int, createdAt: Date, updatedAt: Date) {
        self.id = id; self.body = body; self.author = author; self.attachmentCount = attachmentCount
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct NativeAnnotationSegment: Codable, Sendable, Equatable {
    public let id: SegmentID
    public let reference: ScreenEvidenceRef
    public let tags: [Tag]
    public let comments: [NativeAnnotationComment]
    public init(id: SegmentID, reference: ScreenEvidenceRef, tags: [Tag], comments: [NativeAnnotationComment]) {
        self.id = id; self.reference = reference; self.tags = tags; self.comments = comments
    }
}

/// An exact bounded set of native segments and their annotation state. Attachment
/// file paths and screen text are excluded. fingerprint also covers non-exported
/// attachment metadata and the complete comment link set.
public struct NativeAnnotationSnapshot: Codable, Sendable, Equatable {
    public let nativeStoreID: UUID
    public let revision: NativeAnnotationRevision
    public let fingerprint: String
    public let segments: [NativeAnnotationSegment]
    public init(nativeStoreID: UUID, revision: NativeAnnotationRevision, fingerprint: String, segments: [NativeAnnotationSegment]) {
        self.nativeStoreID = nativeStoreID; self.revision = revision; self.fingerprint = fingerprint; self.segments = segments
    }
}

/// Native UI and command clients enter the same bounded mutation. The reserved
/// hidden tag is intentionally absent: visibility remains an explicit local action.
public enum NativeAnnotationMutation: Sendable {
    case addTag(name: String)
    case removeTag(id: TagID)
    case deleteTag(id: TagID)
    case createComment(body: String, author: String, attachments: [SegmentCommentAttachment], anchor: FrameID?)
    case updateComment(id: SegmentCommentID, body: String)
    case linkComment(id: SegmentCommentID)
    case unlinkComment(id: SegmentCommentID)
    case deleteComment(id: SegmentCommentID)
}

/// Content-free durable command result. Consumers re-read current annotations.
public struct NativeAnnotationReceipt: Codable, Sendable, Equatable {
    public let nativeStoreID: UUID
    public let affectedSegments: Int
    public let tagID: TagID?
    public let commentID: SegmentCommentID?
    public init(nativeStoreID: UUID, affectedSegments: Int, tagID: TagID? = nil, commentID: SegmentCommentID? = nil) {
        self.nativeStoreID = nativeStoreID; self.affectedSegments = affectedSegments
        self.tagID = tagID; self.commentID = commentID
    }
}

public enum NativeAnnotationError: Error, Sendable {
    case invalidArguments, unavailable, staleSelection, notPermitted, tooLarge, closed
}
