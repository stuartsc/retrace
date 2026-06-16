import Foundation
import Shared

public enum DictationManagerError: Error, LocalizedError, Sendable {
    case noActiveSession
    case insertionTargetChanged

    public var errorDescription: String? {
        switch self {
        case .noActiveSession:
            return "No active dictation session"
        case .insertionTargetChanged:
            return "Focused app changed before dictation could be inserted"
        }
    }
}

public protocol DictationSessionStoring: Actor {
    func save(_ session: DictationSession) async throws
}

public actor NullDictationSessionStore: DictationSessionStoring {
    public init() {}
    public func save(_ session: DictationSession) async throws {}
}

public actor DictationManager {
    private var transcriptionService: any TranscriptionProtocol
    private var insertionService: any DictationInsertionServicing
    private var sessionStore: any DictationSessionStoring
    private var config: DictationConfig
    private let audioBuffer: DictationAudioBuffer
    private var activeSession: DictationSession?

    public init(
        transcriptionService: any TranscriptionProtocol,
        insertionService: any DictationInsertionServicing = ClipboardDictationInsertionService(),
        sessionStore: any DictationSessionStoring = NullDictationSessionStore(),
        config: DictationConfig = .default,
        audioBuffer: DictationAudioBuffer = DictationAudioBuffer()
    ) {
        self.transcriptionService = transcriptionService
        self.insertionService = insertionService
        self.sessionStore = sessionStore
        self.config = config
        self.audioBuffer = audioBuffer
    }

    public func updateTranscriptionService(_ service: any TranscriptionProtocol) {
        transcriptionService = service
    }

    public func updateSessionStore(_ store: any DictationSessionStoring) {
        sessionStore = store
    }

    public func updateConfig(_ config: DictationConfig) {
        self.config = config
    }

    public func getConfig() -> DictationConfig {
        config
    }

    public func ingest(_ audio: CapturedAudio) async {
        guard audio.source == .microphone else { return }
        await audioBuffer.append(audio)
    }

    @discardableResult
    public func beginDictation(at startedAt: Date = Date(), targetContext: DictationTargetContext?) async -> UUID {
        if let activeSession {
            return activeSession.id
        }

        let session = DictationSession(
            startedAt: startedAt,
            endedAt: nil,
            insertedAt: nil,
            text: "",
            status: .capturing,
            targetContext: targetContext,
            insertionMethod: config.insertionMethod,
            errorMessage: nil
        )
        activeSession = session
        try? await sessionStore.save(session)
        return session.id
    }

    public func endDictation(
        at endedAt: Date = Date(),
        currentTargetContext: DictationTargetContext? = nil,
        validateInsertionTarget: Bool = false
    ) async throws -> DictationSession {
        guard let session = activeSession else {
            throw DictationManagerError.noActiveSession
        }
        activeSession = nil

        guard config.isEnabled else {
            let cancelled = session.updated(
                endedAt: endedAt,
                status: .cancelled,
                errorMessage: "Dictation is disabled"
            )
            try? await sessionStore.save(cancelled)
            return cancelled
        }

        let sliceStart = session.startedAt.addingTimeInterval(-config.preRollSeconds)
        let sliceEnd = endedAt.addingTimeInterval(config.postRollSeconds)
        guard let slice = await audioBuffer.slice(from: sliceStart, to: sliceEnd) else {
            let empty = session.updated(
                endedAt: endedAt,
                status: .empty,
                errorMessage: "No microphone audio captured"
            )
            try? await sessionStore.save(empty)
            return empty
        }

        do {
            let transcription = try await transcriptionService.transcribe(slice.audioData)
            guard let formattedText = DictationTextFormatter.formatted(transcription.text) else {
                let empty = session.updated(
                    endedAt: endedAt,
                    status: .empty,
                    errorMessage: "No speech detected"
                )
                try? await sessionStore.save(empty)
                return empty
            }

            guard !validateInsertionTarget || (session.targetContext?.isCompatibleInsertionTarget(with: currentTargetContext) ?? true) else {
                let blocked = session.updated(
                    endedAt: endedAt,
                    text: formattedText,
                    status: .blockedFocusChanged,
                    errorMessage: DictationManagerError.insertionTargetChanged.localizedDescription
                )
                try? await sessionStore.save(blocked)
                return blocked
            }

            try await insertionService.insert(
                text: formattedText,
                method: config.insertionMethod,
                restoreDelay: config.restoreClipboardDelaySeconds
            )

            let insertedAt = Date()
            let inserted = session.updated(
                endedAt: endedAt,
                insertedAt: insertedAt,
                text: formattedText,
                status: .inserted
            )
            try? await sessionStore.save(inserted)
            return inserted
        } catch DictationInsertionError.secureInputEnabled {
            let blocked = session.updated(
                endedAt: endedAt,
                status: .blockedSecureInput,
                errorMessage: DictationInsertionError.secureInputEnabled.localizedDescription
            )
            try? await sessionStore.save(blocked)
            return blocked
        } catch {
            let failed = session.updated(
                endedAt: endedAt,
                status: .failed,
                errorMessage: error.localizedDescription
            )
            try? await sessionStore.save(failed)
            return failed
        }
    }
}
