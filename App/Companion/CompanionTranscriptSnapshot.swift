import Foundation
import Database
import Shared

public enum CompanionTranscriptSnapshot {
    /// Speaker enhancement can retain a completed but uncertain first pass. Pending
    /// raw placeholders and later refinement rows are not first-pass publication.
    public static func firstPassReferences(for rows: [AudioTranscription], nativeStoreID: UUID) throws -> [V23TranscriptReference] {
        guard (1...1024).contains(rows.count), Set(rows.map(\.id)).count == rows.count,
              let path = rows.first?.batchAudioPath, !path.isEmpty, path.utf8.count <= 1024,
              !path.contains("\0"), rows.allSatisfy({ row in
                  row.source == .microphone && row.transcriptionPass == 1 && row.batchAudioPath == path &&
                  ["transcribed", "needs_repair"].contains(row.transcriptStatus)
              }) else { throw CompanionError.invalidPayload }
        return try rows.map { try recordingReference(for: $0, nativeStoreID: nativeStoreID) }
    }
    private struct Fields: Codable {
        let id: Int64; let sessionID: String?; let text: String; let startTime: Date; let endTime: Date
        let source: AudioSource; let confidence: Double?; let createdAt: Date; let audioPath: String?
        let batchAudioPath: String?; let transcriptStatus: String; let detectedLanguage: String?
        let audioVariant: String; let qualityFlags: String?; let transcriptionPass: Int
        init(_ row: AudioTranscription) {
            id = row.id; sessionID = row.sessionID; text = row.text; startTime = row.startTime; endTime = row.endTime
            source = row.source; confidence = row.confidence; createdAt = row.createdAt; audioPath = row.audioPath
            batchAudioPath = row.batchAudioPath; transcriptStatus = row.transcriptStatus; detectedLanguage = row.detectedLanguage
            audioVariant = row.audioVariant; qualityFlags = row.qualityFlags; transcriptionPass = row.transcriptionPass
        }
    }
    public static func reference(for row: AudioTranscription, nativeStoreID: UUID) throws -> V23TranscriptReference {
        guard row.transcriptStatus == "transcribed" else { throw CompanionError.invalidPayload }
        return try recordingReference(for: row, nativeStoreID: nativeStoreID)
    }
    /// Exact current-row proof, including pending/repair states; it asserts no transcript or media availability.
    public static func recordingReference(for row: AudioTranscription, nativeStoreID: UUID) throws -> V23TranscriptReference {
        guard row.id > 0, row.source == .microphone || row.source == .system,
              row.transcriptionPass > 0,
              row.text.utf8.count <= 262_144, row.endTime >= row.startTime else { throw CompanionError.invalidPayload }
        try CompanionBounds.date(row.startTime); try CompanionBounds.date(row.endTime); try CompanionBounds.date(row.createdAt)
        return V23TranscriptReference(nativeStoreID: nativeStoreID, source: row.source, rowID: row.id,
            snapshotSHA256: CompanionWire.digest(try CompanionWire.encode(Fields(row))))
    }
    public static func matches(_ reference: V23TranscriptReference, record: AudioTranscription, nativeStoreID: UUID) throws -> Bool {
        // A V23 row has no proven PCM generation column. Reject an invented optional generation.
        guard reference.recordingGeneration == nil else { return false }
        return try self.reference(for: record, nativeStoreID: nativeStoreID) == reference
    }
    public static func matchesRecording(_ reference: V23TranscriptReference, record: AudioTranscription, nativeStoreID: UUID) throws -> Bool {
        guard reference.recordingGeneration == nil else { return false }
        return try recordingReference(for: record, nativeStoreID: nativeStoreID) == reference
    }
}
