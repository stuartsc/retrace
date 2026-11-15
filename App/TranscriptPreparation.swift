import Database
import Foundation

/// Presentation stage is independent of whether the recording has been saved.
public enum TranscriptPreparation {
    public static func label(_ row: AudioTranscription) -> String {
        guard !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return row.transcriptStatus == "pending" ? "Text pending" : "Audio saved · no readable text"
        }
        switch row.transcriptStatus {
        case "pending", "needs_repair", "needs_review": return "Draft · improving text"
        default: return row.transcriptionPass > 1 ? "Refined transcript" : "Draft"
        }
    }
}
