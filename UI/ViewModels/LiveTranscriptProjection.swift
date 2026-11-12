import App
import CryptoKit
import Database
import Foundation
import Shared

struct LiveTranscriptTurn: Identifiable {
    let presentation: CompanionSpeakerPresentation
    let index: Int
    let reference: CompanionTurnReference
    let interval: DateInterval
    var turn: CompanionSpeakerTurn { presentation.enhancement.turns[index] }
    var id: String { "turn:\(reference.nativeStoreID):\(reference.jobID):\(reference.resultSHA256):\(index)" }
    var speakerScopeID: String { "\(reference.nativeStoreID):\(reference.jobID):\(turn.speakerID)" }
    var correction: CompanionSpeakerCorrection? { presentation.corrections.first { $0.speakerID == turn.speakerID } }
    var displayLabel: String { correction?.displayName ?? turn.speakerLabel }
    var statusText: String {
        if correction?.displayName != nil { return "Manual name" }
        switch turn.speakerStatus {
        case .suggested: return "Suggested: \(turn.candidateName ?? "unconfirmed identity")"
        case .overlap: return "Overlapping voices"
        case .unknown: return turn.speakerID.contains(":cluster:") ? "Anonymous · this recording" : "Unassigned"
        }
    }
}

struct LiveTranscriptOriginal: Identifiable {
    let id: String
    let presentation: CompanionSpeakerPresentation
    let hasDisplayedTurns: Bool
    var startedAt: Date {
        let source = presentation.firstPassSourceIdentity
        return source.approximateOrigin.addingTimeInterval(Double(source.startSample) / Double(source.sampleRate))
    }
}

enum LiveTranscriptItem: Identifiable {
    case recording(AudioTranscription)
    case turn(LiveTranscriptTurn)
    case original(LiveTranscriptOriginal)
    var id: String {
        switch self {
        case .recording(let row): return "recording:\(row.source.rawValue):\(row.id)"
        case .turn(let turn): return turn.id
        case .original(let original): return original.id
        }
    }
    var startedAt: Date {
        switch self {
        case .recording(let row): return row.startTime
        case .turn(let turn): return turn.interval.start
        case .original(let original): return original.startedAt
        }
    }
    var recording: AudioTranscription? { if case .recording(let value) = self { return value }; return nil }
    var turn: LiveTranscriptTurn? { if case .turn(let value) = self { return value }; return nil }
    var original: LiveTranscriptOriginal? { if case .original(let value) = self { return value }; return nil }
}

struct LiveTranscriptProjection {
    let items: [LiveTranscriptItem]
    let truncated: Bool

    /// Projection only: source validity belongs to the App reader. Equal wall times,
    /// text, labels or paths never establish recording or person identity.
    static func make(recordings: [AudioTranscription], speakers: [CompanionSpeakerPresentation],
                     interval: DateInterval, recordingReferences: [V23TranscriptReference] = [], maximumTurns: Int = 500) -> Self {
        let bound = max(1, maximumTurns)
        var turns: [LiveTranscriptTurn] = [], omitted = false
        for presentation in speakers {
            guard presentation.turnReferences.count == presentation.enhancement.turns.count else { omitted = true; continue }
            let source = presentation.enhancement.sourceIdentity
            guard source.isValid else { omitted = true; continue }
            var count = 0
            for index in presentation.enhancement.turns.indices.reversed() {
                let turn = presentation.enhancement.turns[index], reference = presentation.turnReferences[index]
                guard reference.nativeStoreID == presentation.nativeStoreID, reference.jobID == presentation.jobID,
                      reference.turnIndex == index, turn.start.isFinite, turn.end.isFinite, turn.start >= 0,
                      turn.end > turn.start, turn.end <= Double(source.sampleCount) / Double(source.sampleRate) else { omitted = true; continue }
                let origin = source.approximateOrigin.addingTimeInterval(Double(source.startSample) / Double(source.sampleRate))
                let start = origin.addingTimeInterval(turn.start), end = origin.addingTimeInterval(turn.end)
                guard start < interval.end, end > interval.start else { continue }
                if count >= bound { omitted = true; break }
                turns.append(.init(presentation: presentation, index: index, reference: reference, interval: .init(start: start, end: end)))
                count += 1
            }
        }
        turns.sort { $0.interval.start == $1.interval.start ? $0.id < $1.id : $0.interval.start < $1.interval.start }
        if turns.count > bound { turns = Array(turns.suffix(bound)); omitted = true }
        let displayedJobs = Set(turns.map { $0.presentation.jobID })
        var originals: [LiveTranscriptOriginal] = [], seen = Set<String>()
        for presentation in speakers where !presentation.firstPassReferences.isEmpty {
            // All proofs participate; a shared timestamp or a first matching row is insufficient.
            let proof = presentation.firstPassReferences.map { "\($0.nativeStoreID):\($0.source.rawValue):\($0.rowID):\($0.snapshotSHA256)" }.joined(separator: "|")
            let key = "original:" + SHA256.hash(data: Data(proof.utf8)).map { String(format: "%02x", $0) }.joined()
            guard seen.insert(key).inserted else { continue }
            originals.append(.init(id: key, presentation: presentation, hasDisplayedTurns: displayedJobs.contains(presentation.jobID)))
        }
        var covered: [Int64: [(V23TranscriptReference, UUID)]] = [:]
        for original in originals where original.hasDisplayedTurns {
            for reference in original.presentation.firstPassReferences {
                covered[reference.rowID, default: []].append((reference, original.presentation.nativeStoreID))
            }
        }
        let proofsByID = Dictionary(recordingReferences.map { ($0.rowID, $0) }, uniquingKeysWith: { first, _ in first })
        let retainedRows = recordings.filter { row in
            // Pending/unreviewed rows can never be replaced by inferred text.
            guard row.transcriptStatus == "transcribed", row.transcriptionPass == 1 else { return true }
            guard let ownReference = proofsByID[row.id],
                  (try? CompanionTranscriptSnapshot.matches(ownReference, record: row, nativeStoreID: ownReference.nativeStoreID)) == true else { return true }
            return !(covered[row.id] ?? []).contains { reference, store in
                reference == ownReference && store == ownReference.nativeStoreID
            }
        }
        var items = retainedRows.map(LiveTranscriptItem.recording) + originals.map(LiveTranscriptItem.original) + turns.map(LiveTranscriptItem.turn)
        items.sort {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            if let lhs = $0.recording, let rhs = $1.recording {
                return lhs.endTime == rhs.endTime ? lhs.id > rhs.id : lhs.endTime > rhs.endTime
            }
            return $0.id > $1.id
        }
        return .init(items: items, truncated: omitted)
    }
}
