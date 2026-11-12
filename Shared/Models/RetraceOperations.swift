import Foundation

/// Bounded content-free observations gathered over an interval. The observation
/// time does not turn retained CPU measurements or delivery state into fresh work.
/// These counts describe different queues and must never be summed as unique jobs.
public struct RetraceOperationsSnapshot: Codable, Sendable {
    public enum Unavailable: String, Codable, Sendable {
        case textQueue, savedAudioQueue, cpuMeasurement, activityHealth
    }
    public struct Background: Codable, Sendable {
        public let waitingCount: Int
        public let running: Bool
        public let processNow: Bool
        public let waitingForQuietMoment: Bool
        public let closed: Bool
        public let originalSpoolUnderPressure: Bool
        public let activeKind: String?
        public let waitReason: String?
        public init(waitingCount: Int, running: Bool, processNow: Bool, waitingForQuietMoment: Bool,
                    closed: Bool, originalSpoolUnderPressure: Bool, activeKind: String?, waitReason: String?) {
            self.waitingCount = waitingCount; self.running = running; self.processNow = processNow
            self.waitingForQuietMoment = waitingForQuietMoment; self.closed = closed
            self.originalSpoolUnderPressure = originalSpoolUnderPressure
            self.activeKind = activeKind; self.waitReason = waitReason
        }
    }
    public struct Companion: Codable, Sendable {
        public let state: String
        /// Last observed delivery queue, not a fresh network round trip.
        public let pendingCount: Int
        public let partialDeliveryPossible: Bool
        public init(state: String, pendingCount: Int, partialDeliveryPossible: Bool) {
            self.state = state; self.pendingCount = pendingCount; self.partialDeliveryPossible = partialDeliveryPossible
        }
    }
    public struct VoiceMarkers: Codable, Sendable {
        public let state: VoiceMarkerState
        public let enabledRuleCount: Int
        public let mediaMappingIncomplete: Bool
        public init(state: VoiceMarkerState, enabledRuleCount: Int, mediaMappingIncomplete: Bool) {
            self.state = state; self.enabledRuleCount = enabledRuleCount; self.mediaMappingIncomplete = mediaMappingIncomplete
        }
    }
    public let observationStartedAt: Date
    public let observedAt: Date
    public let liveLaptop: Bool
    public let recording: Bool
    public let recordingPersistenceFailed: Bool
    public let contextCollecting: Bool
    public let contextDegraded: Bool
    public let pendingText: Int?
    public let processingText: Int?
    public let failedText: Int?
    public let oldestPendingTextAt: Date?
    /// Unknown until a bounded saved-audio queue observation is available.
    public let pendingSavedAudio: Int?
    public let audioProcessedAt: Date?
    public let background: Background
    public let cpu: ResourceUsageSnapshot
    /// nil means the owner has not been initialized; reading does not create it.
    public let companion: Companion?
    public let voiceMarkers: VoiceMarkers?
    public let unavailable: [Unavailable]

    public init(observationStartedAt: Date, observedAt: Date, recording: Bool, recordingPersistenceFailed: Bool,
                contextCollecting: Bool, contextDegraded: Bool, pendingText: Int?, processingText: Int?, failedText: Int?,
                oldestPendingTextAt: Date?, pendingSavedAudio: Int?, audioProcessedAt: Date?, background: Background,
                cpu: ResourceUsageSnapshot, companion: Companion?, voiceMarkers: VoiceMarkers?, unavailable: [Unavailable]) {
        self.observationStartedAt = observationStartedAt; self.observedAt = observedAt; liveLaptop = true
        self.recording = recording; self.recordingPersistenceFailed = recordingPersistenceFailed
        self.contextCollecting = contextCollecting; self.contextDegraded = contextDegraded
        self.pendingText = pendingText; self.processingText = processingText; self.failedText = failedText
        self.oldestPendingTextAt = oldestPendingTextAt; self.pendingSavedAudio = pendingSavedAudio
        self.audioProcessedAt = audioProcessedAt; self.background = background; self.cpu = cpu
        self.companion = companion; self.voiceMarkers = voiceMarkers; self.unavailable = unavailable
    }
}
