import Foundation

public extension Notification.Name {
    /// Content-free wake hints; readers still fetch and validate canonical rows.
    static let retraceAudioTextCommitted = Notification.Name("Retrace.audioTextCommitted")
    static let retraceLiveDraftChanged = Notification.Name("Retrace.liveDraftChanged")
}

public enum LiveTranscriptionState: String, Sendable {
    case disabled, waitingForMicrophone, preparing, listening, missingAssets, unavailable, interrupted, resourcePressure, stopped
}

/// Ephemeral preview only, never an evidence reference, search result or voice action.
public struct LiveTranscriptionSnapshot: Sendable, Equatable {
    public var enabled: Bool = false
    public var nativeFirstPassEnabled: Bool = false
    public var state: LiveTranscriptionState = .disabled
    public var spans: [VoiceRecognitionUpdate] = []
    public var firstUpdateMilliseconds: Double?
    public init() {}
    public var text: String { spans.map(\.text).joined(separator: " ") }
    public var notice: String {
        switch state {
        case .disabled: return "Fast microphone drafts are off"
        case .waitingForMicrophone: return "Waiting for microphone recording"
        case .preparing: return "Preparing on-device microphone drafts"
        case .listening: return nativeFirstPassEnabled
            ? "Microphone draft · covered recordings get native text, then quiet-time correction"
            : "Microphone draft · saved text is prepared separately"
        case .missingAssets: return "Speech assets unavailable · using saved-audio transcription"
        case .unavailable: return "Streaming unavailable · using saved-audio transcription"
        case .interrupted: return "Draft interrupted · recording continues"
        case .resourcePressure: return "Draft paused for system load · recording continues"
        case .stopped: return "Microphone drafts stopped"
        }
    }
}
