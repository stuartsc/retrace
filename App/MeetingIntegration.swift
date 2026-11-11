import Capture
import Database
import Foundation
import Processing
import Shared

public struct MeetingHealthSnapshot: Sendable {
    public let comparisonEnabled: Bool
    public let monitoring: Bool
    public let assessment: MeetingAssessment?

    public init(comparisonEnabled: Bool, monitoring: Bool, assessment: MeetingAssessment?) {
        self.comparisonEnabled = comparisonEnabled; self.monitoring = monitoring; self.assessment = assessment
    }

    public func summary(at uptime: TimeInterval) -> String {
        guard monitoring else { return "Call detection paused" }
        guard let assessment, assessment.isFresh(at: uptime) else {
            return "Call state unavailable"
        }
        switch assessment.phase {
        case .notDetected: return "No meeting app detected"
        case .unknown: return "Call state unavailable"
        case .possible: return "Possible call"
        case .supportedActive: return "Call supported by current signals"
        case .ended: return "Previously detected call ended"
        }
    }
}

enum MeetingIntegration {
    static let defaultsKey = "meetingEvidenceComparisonEnabled"

    static func processingConfiguration(_ configuration: AudioProcessingConfig,
                                        audio: AudioCaptureManager) -> AudioProcessingConfig {
        AudioProcessingConfig(enableWordLevelTimestamps: configuration.enableWordLevelTimestamps,
            minimumConfidence: configuration.minimumConfidence, maxBufferDuration: configuration.maxBufferDuration,
            maxQueuedLiveTranscriptionBatches: configuration.maxQueuedLiveTranscriptionBatches,
            chunkedAudioEnabled: configuration.chunkedAudioEnabled,
            transcriptionCallback: configuration.transcriptionCallback, committedTranscriptionCallback: { receipt in
                await observe(receipt, audio: audio)
                await configuration.committedTranscriptionCallback?(receipt)
            })
    }

    static func record(_ outcome: MeetingDetectionOutcome, database: DatabaseManager) async {
        do {
            guard (0...64).contains(outcome.candidateCount), (0...256).contains(outcome.controlsVisited),
                  outcome.uncertainties.count <= 8, outcome.elapsedMilliseconds.isFinite,
                  (0...60_000).contains(outcome.elapsedMilliseconds) else {
                try await database.recordMetricEvent(metricType: .meetingAssessment,
                    metadata: "{\"outcome\":\"invalidMeasurement\"}")
                return
            }
            struct Measurement: Encodable {
                let phase: MeetingPhase
                let comparisonEnabled: Bool
                let uncertainties: [MeetingUncertainty]
                let candidateCount: Int
                let controlsVisited: Int
                let elapsedMilliseconds: Double
            }
            let value = Measurement(phase: outcome.phase, comparisonEnabled: outcome.comparisonEnabled,
                uncertainties: Array(Set(outcome.uncertainties)).sorted { $0.rawValue < $1.rawValue },
                candidateCount: outcome.candidateCount, controlsVisited: outcome.controlsVisited,
                elapsedMilliseconds: outcome.elapsedMilliseconds)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try await database.recordMetricEvent(metricType: .meetingAssessment,
                metadata: String(decoding: try encoder.encode(value), as: UTF8.self))
        } catch { Log.warning("Call assessment metric could not be persisted", category: .app) }
    }

    static func observe(_ receipt: AudioTranscriptCommitReceipt, audio: AudioCaptureManager) async {
        await observe(receipt) { await audio.observeMeetingSpeech($0) }
    }

    static func observe(_ receipt: AudioTranscriptCommitReceipt,
                        deliver: @Sendable (MeetingObservation) async -> Void) async {
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let duration = receipt.endedAt.timeIntervalSince(receipt.startedAt)
        let age = now.timeIntervalSince(receipt.endedAt)
        guard receipt.acceptedTranscription, duration.isFinite, (0...60).contains(duration),
              age.isFinite, (0...45).contains(age) else { return }
        // Delayed decoding preserves original occurrence dates. No app attribution
        // or retained evidence identity can be inferred from a global audio batch.
        let observation = MeetingObservation(interval: .init(startedAt: now, endedAt: now,
            startedUptime: uptime, endedUptime: uptime), source: .transcriptSpeech, signal: .speech,
            audioSource: receipt.source,
            audioOccurrence: .init(startedAt: receipt.startedAt, endedAt: receipt.endedAt))
        await deliver(observation)
    }
}
