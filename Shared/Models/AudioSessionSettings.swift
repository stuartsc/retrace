import Foundation

/// The only remotely configurable audio fields. Consent, formats and device routing
/// remain native policy. These settings live in the context sidecar, never V23.
public struct AudioSessionSettings: Codable, Sendable, Equatable {
    public let revision: UUID
    public let microphoneEnabled: Bool
    public let systemAudioEnabled: Bool
    public init(revision: UUID = UUID(), microphoneEnabled: Bool, systemAudioEnabled: Bool) {
        self.revision = revision; self.microphoneEnabled = microphoneEnabled
        self.systemAudioEnabled = systemAudioEnabled
    }
    public func applying(to base: AudioCaptureConfig, systemAudioPermitted: Bool = true) -> AudioCaptureConfig {
        AudioCaptureConfig(microphoneEnabled: microphoneEnabled,
            systemAudioEnabled: systemAudioEnabled && systemAudioPermitted,
            voiceProcessingEnabled: base.voiceProcessingEnabled,
            hasConsentedToMeetingRecording: base.hasConsentedToMeetingRecording,
            bufferDurationSeconds: base.bufferDurationSeconds, targetSampleRate: base.targetSampleRate,
            targetChannels: base.targetChannels, meetingAppBundleIDs: base.meetingAppBundleIDs)
    }
}

public struct AudioSessionSettingsCommand: Codable, Sendable, Equatable {
    public let clientID: String
    public let requestID: UUID
    public let expectedRevision: UUID
    public let microphoneEnabled: Bool
    public let systemAudioEnabled: Bool
    public init(clientID: String = "local-ui", requestID: UUID = UUID(), expectedRevision: UUID,
                microphoneEnabled: Bool, systemAudioEnabled: Bool) {
        self.clientID = clientID; self.requestID = requestID; self.expectedRevision = expectedRevision
        self.microphoneEnabled = microphoneEnabled; self.systemAudioEnabled = systemAudioEnabled
    }
}

/// Historical configured outcome. A retry returns this exact receipt; it is not a
/// claim about current devices or an instruction to restore an old configuration.
public struct AudioSessionSettingsReceipt: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let settings: AudioSessionSettings
    public init(requestID: UUID, settings: AudioSessionSettings) {
        self.requestID = requestID; self.settings = settings
    }
}

public enum AudioSourceRuntimeState: String, Codable, Sendable {
    case disabled, paused, running, mutedForMeeting, permissionDenied, unavailable, failed, blockedByPolicy
}
public struct AudioSourceRuntime: Codable, Sendable, Equatable {
    public let state: AudioSourceRuntimeState
    public let lastSampleAt: Date?
    public init(_ state: AudioSourceRuntimeState, lastSampleAt: Date? = nil) {
        self.state = state; self.lastSampleAt = lastSampleAt
    }
    public var isActive: Bool { state == .running || state == .mutedForMeeting }
}
public struct AudioCaptureRuntime: Codable, Sendable, Equatable {
    public let microphone: AudioSourceRuntime
    public let systemAudio: AudioSourceRuntime
    public init(microphone: AudioSourceRuntime, systemAudio: AudioSourceRuntime) {
        self.microphone = microphone; self.systemAudio = systemAudio
    }
}
public enum AudioSessionPhase: String, Codable, Sendable {
    case paused, starting, running, reconfiguring, degraded, stopping, closed
}
public enum AudioSessionIssue: String, Codable, Sendable { case settingsUnavailable, cleanupFailed, startupFailed }
public struct AudioSessionSnapshot: Codable, Sendable, Equatable {
    public let observedAt: Date
    public let configured: AudioSessionSettings?
    public let recordingRequested: Bool
    public let phase: AudioSessionPhase
    public let runtime: AudioCaptureRuntime
    public let issue: AudioSessionIssue?
    public init(observedAt: Date = Date(), configured: AudioSessionSettings?, recordingRequested: Bool,
                phase: AudioSessionPhase, runtime: AudioCaptureRuntime, issue: AudioSessionIssue? = nil) {
        self.observedAt = observedAt; self.configured = configured; self.recordingRequested = recordingRequested
        self.phase = phase; self.runtime = runtime; self.issue = issue
    }
}
public enum AudioSessionError: Error, Sendable { case closed, busy, settingsUnavailable, systemAudioPolicyUnavailable, cleanupFailed }

public protocol AudioSessionSettingsStoreProtocol: Actor {
    /// Atomic insert-if-absent. Existing malformed data fails; it is never reset to defaults.
    func initializeAudioSessionSettings(microphoneEnabled: Bool, systemAudioEnabled: Bool) async throws -> AudioSessionSettings
    func audioSessionSettings() async throws -> AudioSessionSettings
    func applyAudioSessionSettings(_ command: AudioSessionSettingsCommand,
                                   fences: [NativeMutationFence]) async throws -> AudioSessionSettingsReceipt
}
