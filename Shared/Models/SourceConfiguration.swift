import Foundation

/// The only configurable imported source is the already locally selected Rewind
/// library. A command never supplies a path, a new source, or an import request.
public struct SourceConfigurationSnapshot: Codable, Equatable, Sendable {
    public let source: FrameSource
    public let revision: UUID
    public let configuredEnabled: Bool
    public let effectiveEnabled: Bool
    public let hasLocalSelection: Bool
    public let transitioning: Bool
    public let issue: SourceConfigurationIssue?
    public let observedAt: Date

    public init(revision: UUID, configuredEnabled: Bool, effectiveEnabled: Bool,
                hasLocalSelection: Bool, transitioning: Bool,
                issue: SourceConfigurationIssue?, observedAt: Date) {
        source = .rewind; self.revision = revision; self.configuredEnabled = configuredEnabled
        self.effectiveEnabled = effectiveEnabled; self.hasLocalSelection = hasLocalSelection
        self.transitioning = transitioning; self.issue = issue; self.observedAt = observedAt
    }
}

public enum SourceConfigurationIssue: String, Codable, Sendable {
    case selectionUnavailable, connectionFailed, persistenceFailed, cleanupFailed
}

public struct SourceConfigurationPreview: Codable, Equatable, Sendable {
    public let id: UUID
    public let expectedRevision: UUID
    public let enabled: Bool
    public let expiresAt: Date
    public let summary: String

    public init(id: UUID, expectedRevision: UUID, enabled: Bool, expiresAt: Date) {
        self.id = id; self.expectedRevision = expectedRevision; self.enabled = enabled; self.expiresAt = expiresAt
        summary = enabled
            ? "Enable read-only access to the existing locally selected Rewind library. No recordings are imported or copied."
            : "Disconnect the Rewind library and clear its active reads. Existing recordings remain in place."
    }
}

/// A receipt describes the completed command, not the current source state. Read
/// a new snapshot before showing current availability after a retry.
public struct SourceConfigurationReceipt: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let changed: Bool
    public let state: SourceConfigurationSnapshot
    public init(requestID: UUID, changed: Bool, state: SourceConfigurationSnapshot) {
        self.requestID = requestID; self.changed = changed; self.state = state
    }
}

public enum SourceConfigurationError: Error, Equatable, Sendable {
    case invalidRequest, stalePreview, busy, closed, selectionUnavailable
    case connectionFailed, persistenceFailed, cleanupFailed
}
