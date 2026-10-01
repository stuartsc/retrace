import Foundation
import Shared

/// Refinement uses the same admission owner as first-pass transcription.
/// Dictation retains the direct service and never waits for quiet-time admission.
actor BackgroundTranscriptionService: TranscriptionProtocol {
    private let service: any TranscriptionProtocol
    private let governor: any BackgroundProcessingProtocol

    init(service: any TranscriptionProtocol, governor: any BackgroundProcessingProtocol) {
        self.service = service; self.governor = governor
    }
    func initialize() async throws { try await service.initialize() }
    func cleanup() async { await service.cleanup() }
    func transcribe(_ data: Data) async throws -> TranscriptionResult {
        try await BackgroundProcessingContext.run(governor: governor, kind: .refinement) { [service] in
            try await service.transcribe(data)
        }
    }
    func transcribeWithTimestamps(_ data: Data, wordLevel: Bool, initialPrompt: String?) async throws -> DetailedTranscriptionResult {
        try await transcribeWithTimestamps(data, wordLevel: wordLevel, initialPrompt: initialPrompt, languageHint: nil)
    }
    func transcribeWithTimestamps(_ data: Data, wordLevel: Bool, initialPrompt: String?, languageHint: String?) async throws -> DetailedTranscriptionResult {
        try await BackgroundProcessingContext.run(governor: governor, kind: .refinement) { [service] in
            try await service.transcribeWithTimestamps(data, wordLevel: wordLevel,
                initialPrompt: initialPrompt, languageHint: languageHint)
        }
    }
}
