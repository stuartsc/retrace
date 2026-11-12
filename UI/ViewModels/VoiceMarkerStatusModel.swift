import App
import Combine
import Foundation
import Shared

enum VoiceMarkerPresentation {
    static func title(_ status: VoiceMarkerStatus?) -> String {
        guard let status else { return "Checking voice markers" }
        switch status.state {
        case .disabled: return "Voice markers off"
        case .waitingForMicrophone: return "Voice markers waiting for microphone"
        case .preparing: return "Preparing voice markers"
        case .listening: return "Voice markers listening"
        case .playbackSuppressed: return "Voice markers paused for playback"
        case .unavailable: return "Voice markers unavailable"
        case .missingAssets: return "Voice recognition assets unavailable"
        case .droppedInput: return "Voice marker input interrupted"
        case .resourcePressure: return "Voice markers paused for system load"
        case .writeFailed: return "Voice marker save failed"
        case .stopped: return "Voice markers stopped"
        }
    }

    static func detail(_ status: VoiceMarkerStatus?) -> String {
        guard let status else { return "Reading local recognition status." }
        let suffix = status.mediaMappingIncomplete ? " Some saved audio mappings are unavailable." : ""
        switch status.state {
        case .disabled: return "Enable a rule to mark matching phrases while microphone recording is active." + suffix
        case .waitingForMicrophone: return "Enabled rules wait for the existing microphone recording stream." + suffix
        case .preparing: return "Preparing on-device recognition for enabled rules." + suffix
        case .listening: return "\(status.enabledRuleCount) enabled rules. Provisional matches are labelled until recognition confirms them." + suffix
        case .playbackSuppressed: return "Recognition pauses during Retrace playback to prevent recordings from creating markers." + suffix
        case .unavailable: return "On-device voice recognition is not available on this Mac." + suffix
        case .missingAssets: return "The required on-device recognition assets are not available." + suffix
        case .droppedInput: return "Recognition lost part of its audio input. Recording continues independently." + suffix
        case .resourcePressure: return "Recognition is paused while the system is under load." + suffix
        case .writeFailed: return "A voice marker could not be saved. No successful marker acknowledgement is implied." + suffix
        case .stopped: return "The local recognition service is stopped." + suffix
        }
    }
}

/// Reads the App-owned recognizer; a view never owns or starts a recognition task.
@MainActor
final class VoiceMarkerStatusModel: ObservableObject {
    @Published private(set) var status: VoiceMarkerStatus?
    @Published private(set) var acknowledgedMarker: TimelineMarker?
    @Published private(set) var readFailed = false
    private let readStatus: @Sendable () async throws -> VoiceMarkerStatus
    private let readMarker: @Sendable (UUID) async throws -> TimelineMarker?
    private var isReading = false

    init(readStatus: @escaping @Sendable () async throws -> VoiceMarkerStatus,
         readMarker: @escaping @Sendable (UUID) async throws -> TimelineMarker? = { _ in nil }) {
        self.readStatus = readStatus; self.readMarker = readMarker
    }

    convenience init(coordinator: AppCoordinator) {
        self.init(readStatus: { try await coordinator.voiceMarkers().status() },
            readMarker: { try await coordinator.timelineMarkers().marker(id: $0) })
    }

    func refresh() async {
        guard !isReading, !Task.isCancelled else { return }
        isReading = true
        defer { isReading = false }
        do {
            let snapshot = try await readStatus()
            var marker: TimelineMarker?
            if let id = snapshot.lastMarkerID, snapshot.lastAcknowledgedAt != nil {
                let retained = try await readMarker(id)
                if retained?.id == id, retained?.deletedAt == nil,
                   let observation = retained?.spokenObservation, observation.status != .withdrawn {
                    marker = retained
                }
            }
            guard !Task.isCancelled else { return }
            status = snapshot; acknowledgedMarker = marker; readFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            status = nil; acknowledgedMarker = nil; readFailed = true
        }
    }

    var title: String { readFailed ? "Voice status unavailable" : VoiceMarkerPresentation.title(status) }
    var detail: String { readFailed ? "Local voice status could not be read." : VoiceMarkerPresentation.detail(status) }
}
