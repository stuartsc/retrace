import Foundation

public struct NativeRecordingState: Codable, Sendable, Equatable {
    public let active: Bool
    public let revision: UUID
    public let transitioning: Bool
    public init(active: Bool, revision: UUID, transitioning: Bool) {
        self.active = active; self.revision = revision; self.transitioning = transitioning
    }
}

public struct NativeCaptureState: Codable, Sendable {
    public let config: CaptureConfig
    public let revision: UUID
    public init(config: CaptureConfig, revision: UUID) { self.config = config; self.revision = revision }
}
