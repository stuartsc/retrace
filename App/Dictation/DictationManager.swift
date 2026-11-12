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
    private var microphoneAllowed = true
    private var microphoneGeneration: UInt64 = 0
    private var microphoneAdmission = NativeMutationFence()
    private var endingTasks: [UUID: Task<DictationSession, Error>] = [:]

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
        guard microphoneAllowed, audio.source == .microphone else { return }
        await audioBuffer.append(audio, microphoneGeneration: microphoneGeneration)
    }

    /// Joined privacy boundary. Re-enabling cannot reuse pre-roll or insert a
    /// transcription started before this boundary, even if recognition ignores cancellation.
    public func setMicrophoneAllowed(_ allowed: Bool) async {
        // Revoke before the first suspension, including a paste already queued
        // on MainActor. A later enable receives a different capability.
        if !allowed {
            microphoneAdmission.invalidate()
            microphoneGeneration &+= 1
        } else if !microphoneAllowed {
            microphoneAdmission = NativeMutationFence()
        }
        microphoneAllowed = allowed
        await audioBuffer.setMicrophoneAllowed(allowed, generation: microphoneGeneration)
        guard !allowed else { return }
        if let session = activeSession {
            activeSession = nil
            try? await sessionStore.save(session.updated(endedAt: Date(), status: .cancelled,
                errorMessage: "Microphone recording is disabled"))
        }
        let pending = Array(endingTasks.values)
        for task in pending { task.cancel() }
        for task in pending { _ = await task.result }
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
        guard let session = activeSession else { throw DictationManagerError.noActiveSession }
        activeSession = nil
        let id = UUID(), generation = microphoneGeneration, admission = microphoneAdmission
        let task = Task { try await self.finishDictation(session: session, at: endedAt, currentTargetContext: currentTargetContext,
            validateInsertionTarget: validateInsertionTarget, generation: generation, admission: admission) }
        endingTasks[id] = task
        defer { endingTasks[id] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func finishDictation(session: DictationSession, at endedAt: Date, currentTargetContext: DictationTargetContext?,
                                validateInsertionTarget: Bool, generation: UInt64,
                                admission: NativeMutationFence) async throws -> DictationSession {
        guard config.isEnabled, microphoneAllowed, generation == microphoneGeneration else {
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
            try Task.checkCancellation()
            guard microphoneAllowed, generation == microphoneGeneration else { throw CancellationError() }
            let transcription = try await transcriptionService.transcribe(slice.audioData)
            try Task.checkCancellation()
            guard microphoneAllowed, generation == microphoneGeneration else { throw CancellationError() }
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
                restoreDelay: config.restoreClipboardDelaySeconds,
                admission: admission
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
        } catch is CancellationError {
            let cancelled = session.updated(endedAt: endedAt, status: .cancelled,
                errorMessage: "Microphone recording changed")
            try? await sessionStore.save(cancelled)
            return cancelled
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
