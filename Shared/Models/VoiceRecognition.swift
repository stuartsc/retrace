import Foundation

/// Timing belongs to the original converted microphone PCM. A native timed run
/// can contain several words; only its first/last lexical tokens have known edges.
public struct VoiceTimedToken: Sendable, Equatable {
    public let text: String
    public let startSample: Int64
    public let endSample: Int64
    public let hasStartBoundary: Bool
    public let hasEndBoundary: Bool
    public init(text: String, startSample: Int64, endSample: Int64,
                hasStartBoundary: Bool, hasEndBoundary: Bool) {
        self.text = text; self.startSample = startSample; self.endSample = endSample
        self.hasStartBoundary = hasStartBoundary; self.hasEndBoundary = hasEndBoundary
    }
}

public struct VoiceRecognitionUpdate: Sendable, Equatable {
    public let source: LiveAudioSampleIdentity
    public let startSample: Int64
    public let endSample: Int64
    public let text: String
    public let tokens: [VoiceTimedToken]
    public let isFinal: Bool
    public init(source: LiveAudioSampleIdentity, startSample: Int64, endSample: Int64,
                text: String, tokens: [VoiceTimedToken], isFinal: Bool) {
        self.source = source; self.startSample = startSample; self.endSample = endSample
        self.text = text; self.tokens = tokens; self.isFinal = isFinal
    }
}

public enum VoiceRecognitionEvent: Sendable {
    case ready
    case update(VoiceRecognitionUpdate)
    /// Native analyzer finalization can advance without repeating unchanged text.
    case finalized(recordingGeneration: UUID, continuityID: UUID, throughSample: Int64)
    case discontinuity
}

public enum VoiceMarkerState: String, Sendable, Codable {
    case disabled, waitingForMicrophone, preparing, listening, playbackSuppressed
    case unavailable, missingAssets, droppedInput, resourcePressure, writeFailed, stopped
}

public struct VoiceMarkerStatus: Sendable, Codable, Equatable {
    public var state: VoiceMarkerState
    public var enabledRuleCount: Int
    public var lastMarkerID: UUID?
    public var lastAcknowledgedAt: Date?
    public var lastAcknowledgementMilliseconds: Double?
    public var acknowledgedProvisional: Bool
    public var mediaMappingIncomplete: Bool
    public init(state: VoiceMarkerState = .disabled, enabledRuleCount: Int = 0,
                lastMarkerID: UUID? = nil, lastAcknowledgedAt: Date? = nil,
                lastAcknowledgementMilliseconds: Double? = nil,
                acknowledgedProvisional: Bool = false, mediaMappingIncomplete: Bool = false) {
        self.state = state; self.enabledRuleCount = enabledRuleCount
        self.lastMarkerID = lastMarkerID; self.lastAcknowledgedAt = lastAcknowledgedAt
        self.lastAcknowledgementMilliseconds = lastAcknowledgementMilliseconds
        self.acknowledgedProvisional = acknowledgedProvisional
        self.mediaMappingIncomplete = mediaMappingIncomplete
    }
}

/// The owner shares existing captured buffers; implementations never open a device.
public protocol VoiceRecognitionProtocol: Actor {
    func run(input: AsyncStream<CapturedAudio>,
             receive: @escaping @Sendable (VoiceRecognitionEvent) async throws -> Void) async throws
}

public enum VoiceRecognitionError: Error, Sendable, Equatable {
    case unavailable, missingAssets, invalidInput, discontinuity, droppedInput, alreadyRunning
}
