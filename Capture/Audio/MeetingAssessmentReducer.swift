import Foundation
import Shared

struct MeetingSample: Sendable {
    let observations: [MeetingObservation]
    let observedAt: Date
    let observedUptime: TimeInterval
    let candidateCount: Int
    let controlsVisited: Int
}

/// Reduces independently timed native observations; never turns process
/// presence, generic input IO or global speech into a call on its own.
struct MeetingAssessmentReducer {
    static let freshnessSeconds = MeetingAssessment.maximumFreshnessSeconds
    private let sessionID: UUID
    private var revision: UInt64 = 0
    private var current: MeetingAssessment?
    private var supportedApplication: MeetingApplicationIdentity?
    private var supportedSince: Date?
    private var endedObservation: MeetingObservation?
    private var possibleApplication: MeetingApplicationIdentity?
    private var possibleSince: Date?

    init(sessionID: UUID) { self.sessionID = sessionID }

    /// An unavailable inventory can hide the presented app, but must not lose
    /// the exact supported lifetime still awaiting affirmative end evidence.
    var terminationTarget: MeetingApplicationIdentity? { endedObservation == nil ? supportedApplication : nil }

    mutating func consume(_ sample: MeetingSample, comparisonEnabled: Bool,
                          speech: MeetingObservation?) -> MeetingAssessment {
        guard MeetingObservationAdmission.valid(sample) else {
            return publish(phase: .unknown, application: nil, sample: sample.safeEmpty,
                           observations: [], uncertainties: [.identityUnproved])
        }
        let observations = sample.observations
        let uncertainty = Set(observations.compactMap(\.uncertainty))
        if !uncertainty.isDisjoint(with: [.privacyExcluded, .policyUnavailable]) {
            supportedApplication = nil; supportedSince = nil; endedObservation = nil
            possibleApplication = nil; possibleSince = nil
            return publish(phase: .unknown, application: nil, sample: sample, observations: [],
                           uncertainties: Array(uncertainty))
        }
        let present = observations.filter { $0.source == .applicationInventory && $0.signal == .present }
        let noCandidates = observations.first { $0.source == .applicationInventory && $0.signal == .noCandidates }
        let ended = observations.first {
            $0.source == .applicationInventory && $0.signal == .processEnded &&
                $0.application == supportedApplication && supportedApplication != nil
        }
        // A positive end receipt may be one-shot (PID replacement). Retain it
        // even while another candidate remains possible in the current view.
        if let ended { endedObservation = ended }
        let supporting = comparisonEnabled ? observations.first { controls in
            guard controls.source == .visibleCallControls, controls.signal == .inCallControls,
                  present.contains(where: { $0.application == controls.application }) else { return false }
            return observations.contains { input in
                input.source == .coreAudioProcessInput && input.signal == .runningInput &&
                    input.application == controls.application &&
                    abs(input.interval.endedUptime - controls.interval.endedUptime) <= 2
            }
        } : nil
        if let supporting, let application = supporting.application {
            if supportedApplication != application || endedObservation != nil {
                supportedApplication = application
                endedObservation = nil
                supportedSince = max(supporting.interval.endedAt,
                    observations.first(where: { $0.source == .coreAudioProcessInput && $0.signal == .runningInput &&
                                                $0.application == application })!.interval.endedAt)
            }
            return publish(phase: .supportedActive, application: application, sample: sample,
                observations: retained(observations, application: application, speech: speech, sample: sample),
                uncertainties: Array(uncertainty))
        }
        if let ended, present.isEmpty {
            return publish(phase: .ended, application: supportedApplication, sample: sample,
                observations: [ended] + (noCandidates.map { [$0] } ?? []),
                uncertainties: Array(uncertainty), endedAt: ended.interval.endedAt)
        }
        if noCandidates != nil {
            if let endedObservation {
                return publish(phase: .ended, application: supportedApplication, sample: sample,
                    observations: [endedObservation, noCandidates!], uncertainties: [], endedAt: endedObservation.interval.endedAt)
            }
            // Absence alone is not affirmative process-end evidence. Preserve
            // earlier support as uncertain until the same lifetime is checked.
            if supportedApplication != nil {
                return publish(phase: .possible, application: supportedApplication, sample: sample,
                               observations: [noCandidates!], uncertainties: [.noCorroboration])
            }
            return publish(phase: .notDetected, application: nil, sample: sample,
                           observations: [noCandidates!], uncertainties: [])
        }
        if let presence = present.first(where: { $0.application == supportedApplication }) ?? present.first {
            var reasons = uncertainty
            reasons.insert(comparisonEnabled ? .noCorroboration : .comparisonDisabled)
            return publish(phase: .possible, application: presence.application, sample: sample,
                observations: retained(observations, application: presence.application, speech: speech, sample: sample),
                uncertainties: Array(reasons))
        }
        return publish(phase: .unknown, application: nil, sample: sample,
            observations: observations.filter { $0.signal == .unavailable },
            uncertainties: uncertainty.isEmpty ? [.nativeUnavailable] : Array(uncertainty))
    }

    mutating func expired(at date: Date, uptime: TimeInterval, reason: MeetingUncertainty = .stale) -> MeetingAssessment {
        let sample = MeetingSample(observations: [], observedAt: date, observedUptime: uptime,
                                   candidateCount: 0, controlsVisited: 0).safeEmpty
        return publish(phase: supportedApplication == nil || endedObservation != nil ? .unknown : .possible,
                       application: endedObservation == nil ? supportedApplication : nil,
                       sample: sample, observations: [], uncertainties: [reason])
    }

    private func retained(_ observations: [MeetingObservation], application: MeetingApplicationIdentity?,
                          speech: MeetingObservation?, sample: MeetingSample) -> [MeetingObservation] {
        var kept = observations.filter { $0.application == application }.prefix(7).map { $0 }
        if let speech, MeetingObservationAdmission.validSpeech(speech, now: sample.observedUptime, date: sample.observedAt) { kept.append(speech) }
        return kept
    }

    private mutating func publish(phase: MeetingPhase, application: MeetingApplicationIdentity?, sample: MeetingSample,
                                  observations: [MeetingObservation], uncertainties: [MeetingUncertainty],
                                  endedAt: Date? = nil) -> MeetingAssessment {
        revision &+= 1
        if let application, let presence = sample.observations.first(where: {
            $0.source == .applicationInventory && $0.signal == .present && $0.application == application
        }), possibleApplication != application {
            possibleApplication = application; possibleSince = presence.interval.endedAt
        }
        var reasons = Set(uncertainties)
        if observations.count > 8 || reasons.count > 8 { reasons.insert(.budgetExceeded) }
        let orderedReasons = reasons.sorted {
            if $0 == .budgetExceeded { return $1 != .budgetExceeded }
            if $1 == .budgetExceeded { return false }
            return $0.rawValue < $1.rawValue
        }
        let value = MeetingAssessment(monitoringSessionID: sessionID, revision: revision, phase: phase,
            application: application, observedAt: sample.observedAt, observedUptime: sample.observedUptime,
            validUntilUptime: sample.observedUptime + Self.freshnessSeconds,
            possibleSince: application == possibleApplication ? possibleSince : nil,
            supportedSince: application == supportedApplication ? supportedSince : nil, endedAt: endedAt,
            observations: Array(observations.prefix(8)),
            uncertainties: Array(orderedReasons.prefix(8)))
        current = value
        return value
    }
}

enum MeetingObservationAdmission {
    static func valid(_ sample: MeetingSample) -> Bool {
        guard sample.observedAt.timeIntervalSince1970.isFinite, sample.observedUptime.isFinite,
              sample.observedUptime >= 0, sample.observedUptime <= Double.greatestFiniteMagnitude - 60,
              (0...16).contains(sample.candidateCount), (0...128).contains(sample.controlsVisited),
              sample.observations.count <= 64,
              Set(sample.observations.map(\.id)).count == sample.observations.count,
              sample.observations.allSatisfy({ valid($0, now: sample.observedUptime, date: sample.observedAt, speech: false) &&
                                               $0.interval.endedAt <= sample.observedAt }) else { return false }
        let absent = sample.observations.filter { $0.signal == .noCandidates }
        let present = sample.observations.filter { $0.signal == .present }
        let controls = sample.observations.filter { $0.source == .visibleCallControls && $0.signal != .unavailable }
        let input = sample.observations.filter { $0.source == .coreAudioProcessInput && $0.signal != .unavailable }
        return absent.count <= 1 && (absent.isEmpty || present.isEmpty) && present.count <= 16 &&
            sample.candidateCount == present.count && controls.count <= 1 && input.count <= 1 &&
            (absent.isEmpty || !sample.observations.contains { $0.signal == .unavailable }) &&
            !sample.observations.contains { ended in
                ended.signal == .processEnded && present.contains { $0.application == ended.application }
            }
    }

    static func validSpeech(_ observation: MeetingObservation, now: TimeInterval, date: Date) -> Bool {
        valid(observation, now: now, date: date, speech: true)
    }

    private static func valid(_ observation: MeetingObservation, now: TimeInterval, date: Date, speech: Bool) -> Bool {
        let interval = observation.interval
        guard interval.startedAt.timeIntervalSince1970.isFinite, interval.endedAt.timeIntervalSince1970.isFinite,
              interval.endedAt >= interval.startedAt, interval.startedUptime.isFinite, interval.endedUptime.isFinite,
              interval.startedUptime >= 0, interval.endedUptime >= interval.startedUptime,
              now.isFinite, interval.endedUptime <= now,
              now - interval.endedUptime <= MeetingAssessmentReducer.freshnessSeconds,
              interval.endedUptime - interval.startedUptime <= 2,
              observation.evidence.count <= 4 else { return false }
        if let application = observation.application {
            guard application.processID > 0, !application.bundleID.isEmpty, application.bundleID.utf8.count <= 256,
                  !application.bundleID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        }
        guard observation.evidence.allSatisfy({ reference in
            switch reference {
            case .audio(let audio):
                return !audio.segmentID.isEmpty && audio.segmentID.utf8.count <= 256 && audio.transcriptRevision > 0 &&
                    audio.startTime.isFinite && audio.endTime.isFinite && audio.startTime >= 0 && audio.endTime >= audio.startTime
            case .screen(let screen):
                return screen.frameID.value > 0 && screen.extractionRevision > 0 && screen.blockIDs.count <= 128 &&
                    screen.blockIDs.allSatisfy { $0 >= 0 }
            case .activity, .job: return false
            }
        }), Set(observation.evidence).count == observation.evidence.count,
            let encoded = try? JSONEncoder().encode(observation), encoded.count <= 8 * 1_024 else { return false }
        if observation.signal == .unavailable {
            return !speech && observation.uncertainty != nil && observation.windowID == nil &&
                observation.windowObservationID == nil && observation.capturePolicySHA256 == nil &&
                observation.audioSource == nil && observation.audioOccurrence == nil && observation.evidence.isEmpty
        }
        guard observation.uncertainty == nil else { return false }
        if speech {
            guard observation.application == nil, observation.windowID == nil, observation.windowObservationID == nil,
                  observation.capturePolicySHA256 == nil, observation.audioSource != nil,
                  let occurrence = observation.audioOccurrence, date.timeIntervalSince1970.isFinite,
                  occurrence.startedAt.timeIntervalSince1970.isFinite, occurrence.endedAt.timeIntervalSince1970.isFinite,
                  occurrence.endedAt >= occurrence.startedAt,
                  occurrence.endedAt.timeIntervalSince(occurrence.startedAt) <= 60,
                  occurrence.endedAt <= date, occurrence.endedAt <= interval.endedAt,
                  date.timeIntervalSince(occurrence.endedAt) <= 45, interval.endedAt <= date,
                  observation.evidence.allSatisfy({ if case .audio = $0 { return true }; return false }) else { return false }
            return (observation.source == .transcriptSpeech && [.speech, .silence].contains(observation.signal)) ||
                (observation.source == .audioEnergy && [.speechLikeEnergy, .silence].contains(observation.signal))
        }
        guard observation.audioSource == nil, observation.audioOccurrence == nil else { return false }
        if observation.source == .visibleCallControls {
            guard [.inCallControls, .prejoinControls].contains(observation.signal), observation.application != nil,
                  observation.windowID.map({ $0 > 0 }) == true, observation.windowObservationID != nil,
                  let policy = observation.capturePolicySHA256, policy.utf8.count == 64,
                  policy.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  observation.evidence.allSatisfy({ if case .screen = $0 { return true }; return false }) else { return false }
            return true
        }
        guard observation.windowID == nil, observation.windowObservationID == nil,
              observation.capturePolicySHA256 == nil, observation.evidence.isEmpty else { return false }
        switch observation.source {
        case .applicationInventory:
            return observation.signal == .noCandidates ? observation.application == nil :
                ([.present, .processEnded].contains(observation.signal) && observation.application != nil)
        case .coreAudioProcessInput:
            return observation.application != nil && [.runningInput, .idleInput].contains(observation.signal)
        default: return false
        }
    }
}

private extension MeetingSample {
    var safeEmpty: MeetingSample {
        MeetingSample(observations: [], observedAt: observedAt.timeIntervalSince1970.isFinite ? observedAt : Date(),
            observedUptime: observedUptime.isFinite && observedUptime >= 0 && observedUptime < Double.greatestFiniteMagnitude - 60
                ? observedUptime : ProcessInfo.processInfo.systemUptime,
            candidateCount: 0, controlsVisited: 0)
    }
}

enum MeetingAudioPrivacyPolicy {
    static func permitsSystemAudio(state: MeetingState, config: AudioCaptureConfig, uptime: TimeInterval) -> Bool {
        config.systemAudioEnabled && (config.hasConsentedToMeetingRecording ||
                                     !state.requiresMeetingAudioProtection(at: uptime))
    }
}
