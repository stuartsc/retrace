import Foundation

/// A local comparison result, never proof of what the user was working on.
public enum MeetingPhase: String, Codable, Sendable {
    case notDetected, unknown, possible, supportedActive, ended
}

/// Ephemeral capture-owned policy fence. A new revision is issued before every
/// configuration transition, including a later rollback to the same settings.
public struct MeetingCapturePolicySnapshot: Sendable {
    public let configuration: CaptureConfig
    public let revision: UInt64
    public init(configuration: CaptureConfig, revision: UInt64) {
        self.configuration = configuration; self.revision = revision
    }
}

public struct MeetingApplicationIdentity: Hashable, Codable, Sendable {
    public let bundleID: String
    public let processID: Int32
    /// An opaque token for a proven native process lifetime, not just its PID.
    public let processGeneration: UUID
    public init(bundleID: String, processID: Int32, processGeneration: UUID) {
        self.bundleID = bundleID; self.processID = processID; self.processGeneration = processGeneration
    }
}

public enum MeetingSignalSource: String, Codable, Sendable {
    case applicationInventory, visibleCallControls, coreAudioProcessInput, transcriptSpeech, audioEnergy
}

public enum MeetingSignal: String, Codable, Sendable {
    case present, noCandidates, processEnded, inCallControls, prejoinControls
    case runningInput, idleInput, speech, speechLikeEnergy, silence, unavailable
}

public enum MeetingUncertainty: String, Codable, Sendable {
    case comparisonDisabled, permissionUnavailable, policyUnavailable, privacyExcluded
    case identityUnproved, controlsUnavailable, visibilityUnverified, observerUnavailable
    case sourceChanged, budgetExceeded, nativeUnavailable, noCorroboration, stale, cancelled, stopped
}

public struct MeetingAudioOccurrence: Equatable, Codable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public init(startedAt: Date, endedAt: Date) { self.startedAt = startedAt; self.endedAt = endedAt }
}

/// No window title, control label, transcript or raw audio is retained here.
/// interval is the actual native observation or speech-decision read receipt.
/// audioOccurrence preserves the original batch dates; no capture uptime is invented.
/// Global microphone/system speech has nil application; it is not app-owned IO.
public struct MeetingObservation: Equatable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let interval: CaptureReadInterval
    public let source: MeetingSignalSource
    public let signal: MeetingSignal
    public let application: MeetingApplicationIdentity?
    public let windowID: UInt32?
    /// Lifetime of the native AX observation bracket; not a cross-poll window join.
    public let windowObservationID: UUID?
    public let capturePolicySHA256: String?
    public let audioSource: AudioSource?
    public let audioOccurrence: MeetingAudioOccurrence?
    public let evidence: [EvidenceRef]
    public let uncertainty: MeetingUncertainty?

    public init(id: UUID = UUID(), interval: CaptureReadInterval, source: MeetingSignalSource,
                signal: MeetingSignal, application: MeetingApplicationIdentity? = nil,
                windowID: UInt32? = nil, windowObservationID: UUID? = nil,
                capturePolicySHA256: String? = nil, audioSource: AudioSource? = nil,
                audioOccurrence: MeetingAudioOccurrence? = nil,
                evidence: [EvidenceRef] = [], uncertainty: MeetingUncertainty? = nil) {
        self.id = id; self.interval = interval; self.source = source; self.signal = signal
        self.application = application; self.windowID = windowID; self.windowObservationID = windowObservationID
        self.capturePolicySHA256 = capturePolicySHA256; self.audioSource = audioSource; self.audioOccurrence = audioOccurrence
        self.evidence = evidence; self.uncertainty = uncertainty
    }
}

public struct MeetingAssessment: Equatable, Codable, Sendable {
    public static let maximumFreshnessSeconds: TimeInterval = 6
    public let monitoringSessionID: UUID
    public let revision: UInt64
    public let phase: MeetingPhase
    public let application: MeetingApplicationIdentity?
    public let observedAt: Date
    public let observedUptime: TimeInterval
    public let validUntilUptime: TimeInterval
    /// First observed app presence for this lifetime; not a claimed call start.
    public let possibleSince: Date?
    /// First observed support, not an inferred true call start time.
    public let supportedSince: Date?
    /// Affirmative end evidence time. Expiry/pause never fabricate an end.
    public let endedAt: Date?
    public let observations: [MeetingObservation] // At most eight.
    public let uncertainties: [MeetingUncertainty] // At most eight, unique.

    public init(monitoringSessionID: UUID, revision: UInt64, phase: MeetingPhase,
                application: MeetingApplicationIdentity?, observedAt: Date,
                observedUptime: TimeInterval, validUntilUptime: TimeInterval,
                possibleSince: Date?, supportedSince: Date?, endedAt: Date?, observations: [MeetingObservation],
                uncertainties: [MeetingUncertainty]) {
        self.monitoringSessionID = monitoringSessionID; self.revision = revision; self.phase = phase
        self.application = application; self.observedAt = observedAt; self.observedUptime = observedUptime
        self.validUntilUptime = validUntilUptime; self.possibleSince = possibleSince
        self.supportedSince = supportedSince; self.endedAt = endedAt
        self.observations = observations; self.uncertainties = uncertainties
    }

    public func isFresh(at uptime: TimeInterval) -> Bool {
        uptime.isFinite && observedUptime.isFinite && validUntilUptime.isFinite &&
            observedUptime >= 0 && validUntilUptime >= observedUptime &&
            validUntilUptime - observedUptime <= Self.maximumFreshnessSeconds &&
            uptime >= observedUptime && uptime <= validUntilUptime
    }

    /// Confidence and recording consent are independent. Only a complete fresh
    /// absence inventory can release this protection; expiry always protects.
    public func requiresMeetingAudioProtection(at uptime: TimeInterval) -> Bool {
        guard isFresh(at: uptime), phase == .notDetected || phase == .ended,
              observations.count <= 8, uncertainties.isEmpty,
              !observations.contains(where: { $0.signal == .present || $0.signal == .unavailable }) else { return true }
        let absent = observations.filter { $0.source == .applicationInventory && $0.signal == .noCandidates }
        guard absent.count == 1, let proof = absent.first, proof.application == nil, proof.uncertainty == nil,
              proof.windowID == nil, proof.windowObservationID == nil, proof.capturePolicySHA256 == nil,
              proof.audioSource == nil, proof.audioOccurrence == nil, proof.evidence.isEmpty else { return true }
        let interval = proof.interval
        return !(interval.startedUptime.isFinite && interval.endedUptime.isFinite && interval.startedUptime >= 0 &&
            interval.endedUptime >= interval.startedUptime && interval.endedUptime - interval.startedUptime <= 2 &&
            interval.endedUptime <= observedUptime && uptime - interval.endedUptime <= Self.maximumFreshnessSeconds &&
            interval.startedAt.timeIntervalSince1970.isFinite && interval.endedAt.timeIntervalSince1970.isFinite &&
            interval.endedAt >= interval.startedAt && interval.endedAt <= observedAt)
    }
}

/// Content-free callback for App-owned daily_metrics. A transition/attempt is
/// measured independently of whether any retained evidence was available.
public struct MeetingDetectionOutcome: Sendable {
    public let phase: MeetingPhase
    public let comparisonEnabled: Bool
    public let uncertainties: [MeetingUncertainty]
    public let candidateCount: Int
    public let controlsVisited: Int
    public let elapsedMilliseconds: Double
    public init(phase: MeetingPhase, comparisonEnabled: Bool, uncertainties: [MeetingUncertainty],
                candidateCount: Int, controlsVisited: Int, elapsedMilliseconds: Double) {
        self.phase = phase; self.comparisonEnabled = comparisonEnabled; self.uncertainties = uncertainties
        self.candidateCount = candidateCount; self.controlsVisited = controlsVisited
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}
