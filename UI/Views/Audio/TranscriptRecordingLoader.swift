import Database
import Foundation

/// The bounded recording page shared by initial panel opens and later refreshes.
struct TranscriptRecordingPage: Sendable {
    let transcriptions: [AudioTranscription]
    let isTruncated: Bool
}

enum TranscriptRecordingLoadError: Error { case unavailable }

enum TranscriptRecordingLoader {
    static let windowSeconds: TimeInterval = 30 * 60
    static let maximumRows = 1_000

    static func load(queries: AudioTranscriptionQueries, at timestamp: Date) async throws -> TranscriptRecordingPage {
        try Task.checkCancellation()
        let rows = try await queries.getTranscriptions(
            from: timestamp.addingTimeInterval(-windowSeconds),
            to: timestamp.addingTimeInterval(windowSeconds),
            limit: maximumRows + 1,
            includeActivityRows: true
        )
        try Task.checkCancellation()
        // The existing query returns the latest rows wholly within this window.
        // Keep one overflow sentinel so the panel never implies this is a complete page.
        return TranscriptRecordingPage(
            transcriptions: Array(rows.prefix(maximumRows)),
            isTruncated: rows.count > maximumRows
        )
    }
}
