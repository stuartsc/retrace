import Foundation

/// Protocol for speech-to-text transcription services
/// Owner: SHARED
public protocol TranscriptionProtocol: Actor {
    /// Initialize the transcription service
    func initialize() async throws

    /// Cleanup resources
    func cleanup()

    /// Transcribe audio data
    /// - Parameter audioData: PCM Int16 audio data at 16kHz mono
    /// - Returns: Transcription result with text and metadata
    func transcribe(_ audioData: Data) async throws -> TranscriptionResult

    /// Transcribe with word-level timestamps
    /// - Parameters:
    ///   - audioData: PCM Int16 audio data at 16kHz mono
    ///   - wordLevel: Whether to return word-level timestamps
    ///   - initialPrompt: Optional text from previous batch to help whisper continue sentences across boundaries
    /// - Returns: Detailed transcription with timestamps
    func transcribeWithTimestamps(_ audioData: Data, wordLevel: Bool, initialPrompt: String?) async throws -> DetailedTranscriptionResult

    /// Transcribe with word-level timestamps and an optional Whisper language hint.
    /// nil / "auto" keeps the implementation's default language behavior.
    func transcribeWithTimestamps(
        _ audioData: Data,
        wordLevel: Bool,
        initialPrompt: String?,
        languageHint: String?
    ) async throws -> DetailedTranscriptionResult
}

public extension TranscriptionProtocol {
    /// Implementations that do not support language hints fall back to their default behavior.
    func transcribeWithTimestamps(
        _ audioData: Data,
        wordLevel: Bool,
        initialPrompt: String?,
        languageHint: String?
    ) async throws -> DetailedTranscriptionResult {
        try await transcribeWithTimestamps(audioData, wordLevel: wordLevel, initialPrompt: initialPrompt)
    }
}

// MARK: - Result Types

public struct TranscriptionResult: Sendable {
    public let text: String
    public let confidence: Double?
    public let language: String?
    public let duration: Double?

    public init(text: String, confidence: Double? = nil, language: String? = nil, duration: Double? = nil) {
        self.text = text
        self.confidence = confidence
        self.language = language
        self.duration = duration
    }
}

public struct DetailedTranscriptionResult: Sendable {
    public let text: String
    public let words: [TranscriptionWord]
    public let language: String?
    public let duration: Double?

    public init(text: String, words: [TranscriptionWord], language: String? = nil, duration: Double? = nil) {
        self.text = text
        self.words = words
        self.language = language
        self.duration = duration
    }
}
