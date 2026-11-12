import Foundation
import Shared

/// Runs only after the App owner has validated the retained request/result and current source.
enum CompanionTurnResolver {
    static func resolve(_ batch: CompanionSpeakerPresentation, reference: CompanionTurnReference) throws -> CompanionTurnPresentation {
        try reference.validate()
        guard reference.nativeStoreID == batch.nativeStoreID, reference.jobID == batch.jobID,
              batch.turnReferences.indices.contains(reference.turnIndex),
              batch.turnReferences[reference.turnIndex] == reference,
              batch.enhancement.turns.indices.contains(reference.turnIndex), !batch.firstPassReferences.isEmpty else { throw CompanionError.staleEvidence }
        let turn = batch.enhancement.turns[reference.turnIndex], source = batch.enhancement.sourceIdentity
        guard source.isValid, turn.start.isFinite, turn.end.isFinite, turn.start >= 0, turn.start < turn.end,
              turn.end <= Double(source.sampleCount) / 16000 else { throw CompanionError.invalidPayload }
        // Bounds are checked before conversion. Edge clamping only corrects the floating-point
        // round trip of a validated source endpoint; it never admits an out-of-source turn.
        let start = Int64(floor(turn.start * 16000)), end = min(source.sampleCount, Int64(ceil(turn.end * 16000)))
        guard start >= 0, start < end, end <= source.sampleCount else { throw CompanionError.invalidPayload }
        let selected = LiveAudioSampleIdentity(recordingGeneration: source.recordingGeneration, continuityID: source.continuityID,
            startSample: source.startSample + start, sampleCount: end - start, sampleRate: 16000, approximateOrigin: source.approximateOrigin)
        let correction = batch.corrections.first { $0.speakerID == turn.speakerID }
        guard correction?.revision == reference.correctionRevision else { throw CompanionError.staleEvidence }
        let status: CompanionTurnSpeakerStatus
        let label: String
        if let name = correction?.displayName { status = .manualName; label = name }
        else if turn.speakerStatus == .overlap { status = .overlap; label = turn.speakerLabel }
        else if turn.speakerStatus == .suggested, let name = turn.candidateName { status = .suggestion; label = "Suggested: " + name }
        else if turn.speakerID.contains(":cluster:") { status = .anonymous; label = turn.speakerLabel }
        else { status = .unknown; label = turn.speakerLabel }
        return .init(reference: reference, turn: turn, sourceIdentity: selected, displayLabel: label, speakerStatus: status,
            firstPassText: batch.firstPassText, firstPassSourceIdentity: batch.firstPassSourceIdentity,
            firstPassReferences: batch.firstPassReferences, sourceDependencies: batch.sourceDependencies)
    }
}
