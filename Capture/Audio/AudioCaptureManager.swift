import Foundation
import AVFoundation
import CoreGraphics
import Shared

enum AudioStreamBufferingPolicy {
    static let sourceSampleLimit = 6_000
    static let combinedSampleLimit = 12_000

    static func makeStream(
        limit: Int
    ) -> (stream: AsyncStream<CapturedAudio>, continuation: AsyncStream<CapturedAudio>.Continuation) {
        AsyncStream<CapturedAudio>.makeStream(
            of: CapturedAudio.self,
            bufferingPolicy: .bufferingNewest(limit)
        )
    }
}

/// Own the source stream before a forwarding task can be scheduled. Shutdown
/// finishes sources first, then awaits these tasks so queued filter tails survive.
enum AudioStreamForwarding {
    static func start(
        _ stream: AsyncStream<CapturedAudio>,
        receive: @escaping @Sendable (CapturedAudio) async -> Void
    ) -> Task<Void, Never> {
        Task {
            for await audio in stream { await receive(audio) }
        }
    }

    static func drain(_ tasks: [Task<Void, Never>?]) async {
        for task in tasks { await task?.value }
    }
}

/// Main coordinator for audio capture with dual-pipeline architecture
/// Pipeline A: Shared microphone capture with native PCM conversion
/// Pipeline B: System Audio (privacy-aware, auto-muted during meetings)
public actor AudioCaptureManager: AudioCaptureProtocol {

    // Pipelines
    private let microphoneCapture: MicrophoneAudioCapture
    private let systemAudioCapture: SystemAudioCapture
    private let meetingDetector: MeetingDetector

    // State
    private var config: AudioCaptureConfig
    public private(set) var isCapturing: Bool = false
    private var currentMeetingState: MeetingState = .notInMeeting
    private var sessionOpen = false
    private var sessionGeneration: UUID?
    private var stopRevision: UInt64 = 0
    private var lifecycleTail: Task<Void, Never>?
    private var microphoneRuntime = AudioSourceRuntime(.paused)
    private var systemRuntime = AudioSourceRuntime(.disabled)

    // Statistics
    private var statistics = AudioCaptureStatistics(
        microphoneSamplesRecorded: 0,
        systemAudioSamplesRecorded: 0,
        microphoneDurationSeconds: 0,
        systemAudioDurationSeconds: 0,
        captureStartTime: nil,
        lastSampleTime: nil,
        meetingDetectedCount: 0,
        autoMuteCount: 0
    )

    // Combined audio stream
    private var audioContinuation: AsyncStream<CapturedAudio>.Continuation?
    private var _audioStream: AsyncStream<CapturedAudio>?
    private var microphoneStreamTask: Task<Void, Never>?
    private var systemAudioStreamTask: Task<Void, Never>?

    public init(config: AudioCaptureConfig = .default) {
        self.config = config
        self.microphoneCapture = MicrophoneAudioCapture(config: config)
        self.systemAudioCapture = SystemAudioCapture(config: config)
        self.meetingDetector = MeetingDetector()
    }

    // MARK: - AudioCaptureProtocol Implementation

    public func hasMicrophonePermission() async -> Bool {
        return await microphoneCapture.hasPermission()
    }

    public func requestMicrophonePermission() async -> Bool {
        return await microphoneCapture.requestPermission()
    }

    public func startCapture(config: AudioCaptureConfig) async throws {
        let requestedAt = stopRevision
        try await serialized { owner in
            guard owner.stopRevision == requestedAt else { throw CancellationError() }
            try await owner.beginCapture(config: config)
        }
    }

    private func beginCapture(config: AudioCaptureConfig) async throws {
        guard !sessionOpen else { return }
        self.config = config
        let token = UUID()
        sessionGeneration = token; sessionOpen = true
        microphoneRuntime = .init(config.microphoneEnabled ? .unavailable : .disabled)
        systemRuntime = .init(config.systemAudioEnabled ? .unavailable : .disabled)
        let (stream, continuation) = AudioStreamBufferingPolicy.makeStream(limit: AudioStreamBufferingPolicy.combinedSampleLimit)
        _audioStream = stream; audioContinuation = continuation
        statistics = AudioCaptureStatistics(microphoneSamplesRecorded: 0, systemAudioSamplesRecorded: 0,
            microphoneDurationSeconds: 0, systemAudioDurationSeconds: 0, captureStartTime: Date(),
            lastSampleTime: nil, meetingDetectedCount: 0, autoMuteCount: 0)
        do {
            // No source failure prevents an independent enabled source from starting.
            if config.microphoneEnabled {
                if await microphoneCapture.hasPermission() {
                    try checkSession(token)
                    do {
                        try await microphoneCapture.startCapture()
                        try checkSession(token)
                        let source = await microphoneCapture.audioStream
                        microphoneStreamTask = AudioStreamForwarding.start(source) { [weak self] audio in
                            await self?.receiveMicrophoneAudio(audio)
                        }
                        microphoneRuntime = .init(.running)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        await microphoneCapture.stopCapture()
                        microphoneRuntime = .init(.failed)
                    }
                } else { microphoneRuntime = .init(.permissionDenied) }
            }
            try checkSession(token)
            if config.systemAudioEnabled {
                // Preflight reads never request OS permission. Establish the mute
                // before SCStream can emit its first sample; detection is awaited.
                if CGPreflightScreenCaptureAccess() {
                    await systemAudioCapture.setMuted(true)
                    await meetingDetector.onStateChange { [weak self] state in
                        Task { await self?.handleMeetingStateChange(state, generation: token) }
                    }
                    await meetingDetector.startMonitoring(bundleIDs: config.meetingAppBundleIDs)
                    try checkSession(token)
                    currentMeetingState = await meetingDetector.getCurrentState()
                    try checkSession(token)
                    await updateSystemAudioMuteState(meetingState: currentMeetingState)
                    try checkSession(token)
                    do {
                        try await systemAudioCapture.startCapture()
                        try checkSession(token)
                        let source = await systemAudioCapture.audioStream
                        systemAudioStreamTask = AudioStreamForwarding.start(source) { [weak self] audio in
                            await self?.receiveSystemAudio(audio)
                        }
                        systemRuntime = .init(await systemAudioCapture.getMuted() ? .mutedForMeeting : .running)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try? await systemAudioCapture.stopCapture()
                        await meetingDetector.stopMonitoring()
                        systemRuntime = .init(.failed)
                    }
                } else { systemRuntime = .init(.permissionDenied) }
            }
            try checkSession(token)
            isCapturing = microphoneRuntime.isActive || systemRuntime.isActive
        } catch {
            try? await endCapture()
            throw error
        }
    }

    public func stopCapture() async throws {
        stopRevision &+= 1
        sessionGeneration = nil
        try await serialized { owner in try await owner.endCapture() }
    }

    private func endCapture() async throws {
        sessionGeneration = nil
        await microphoneCapture.stopCapture()
        var systemStopError: Error?
        do { try await systemAudioCapture.stopCapture() }
        catch { systemStopError = error }
        await meetingDetector.stopMonitoring()
        await AudioStreamForwarding.drain([microphoneStreamTask, systemAudioStreamTask])
        isCapturing = false; sessionOpen = false
        microphoneStreamTask = nil; systemAudioStreamTask = nil
        audioContinuation?.finish(); audioContinuation = nil; _audioStream = nil
        microphoneRuntime = .init(config.microphoneEnabled ? .paused : .disabled)
        systemRuntime = .init(config.systemAudioEnabled ? .paused : .disabled)
        if let systemStopError { throw systemStopError }
    }

    private func checkSession(_ token: UUID) throws {
        try Task.checkCancellation()
        guard sessionGeneration == token else { throw CancellationError() }
    }

    private func serialized<T: Sendable>(_ operation: @escaping @Sendable (isolated AudioCaptureManager) async throws -> T) async throws -> T {
        let previous = lifecycleTail
        let task = Task { await previous?.value; return try await operation(self) }
        lifecycleTail = Task { _ = await task.result }
        // Stops must join cleanup even if their callers are cancelled.
        return try await task.value
    }

    public func runtimeSnapshot() async -> AudioCaptureRuntime {
        let generation = sessionGeneration
        if sessionOpen, config.microphoneEnabled, microphoneRuntime.isActive {
            let native = await microphoneCapture.runtimeState()
            // A pause/restart can occur during the native actor hop. Its newer
            // categorical state wins over the observation from the old session.
            if generation == sessionGeneration {
                return .init(microphone: .init(native, lastSampleAt: microphoneRuntime.lastSampleAt),
                             systemAudio: systemRuntime)
            }
        }
        return AudioCaptureRuntime(microphone: microphoneRuntime, systemAudio: systemRuntime)
    }

    public var audioStream: AsyncStream<CapturedAudio> {
        if let stream = _audioStream {
            return stream
        }

        let (stream, continuation) = AudioStreamBufferingPolicy.makeStream(
            limit: AudioStreamBufferingPolicy.combinedSampleLimit
        )
        self._audioStream = stream
        self.audioContinuation = continuation
        return stream
    }

    /// Runtime settings must go through App's owner, which drains the consumer
    /// before replacing this stream. An active direct call is rejected.
    public func updateConfig(_ config: AudioCaptureConfig) async throws {
        try await serialized { owner in
            guard !owner.sessionOpen else { throw AudioCaptureError.captureSessionFailed("Audio settings require the session owner") }
            owner.config = config
        }
    }

    public func getConfig() async -> AudioCaptureConfig {
        return config
    }

    public func getMeetingState() async -> MeetingState {
        return currentMeetingState
    }

    public func setSystemAudioMuted(_ muted: Bool) async {
        await systemAudioCapture.setMuted(muted)
    }

    public func isSystemAudioMuted() async -> Bool {
        return await systemAudioCapture.getMuted()
    }

    public func getStatistics() async -> AudioCaptureStatistics {
        return statistics
    }

    // MARK: - Private Stream Merging

    private func receiveMicrophoneAudio(_ audio: CapturedAudio) {
        microphoneRuntime = .init(.running, lastSampleAt: Date())
        audioContinuation?.yield(audio)

        // Update statistics
        statistics = AudioCaptureStatistics(
            microphoneSamplesRecorded: statistics.microphoneSamplesRecorded + 1,
            systemAudioSamplesRecorded: statistics.systemAudioSamplesRecorded,
            microphoneDurationSeconds: statistics.microphoneDurationSeconds + audio.duration,
            systemAudioDurationSeconds: statistics.systemAudioDurationSeconds,
            captureStartTime: statistics.captureStartTime,
            lastSampleTime: Date(),
            meetingDetectedCount: statistics.meetingDetectedCount,
            autoMuteCount: statistics.autoMuteCount
        )
    }

    private func receiveSystemAudio(_ audio: CapturedAudio) {
        systemRuntime = .init(.running, lastSampleAt: Date())
        audioContinuation?.yield(audio)

        // Update statistics
        statistics = AudioCaptureStatistics(
            microphoneSamplesRecorded: statistics.microphoneSamplesRecorded,
            systemAudioSamplesRecorded: statistics.systemAudioSamplesRecorded + 1,
            microphoneDurationSeconds: statistics.microphoneDurationSeconds,
            systemAudioDurationSeconds: statistics.systemAudioDurationSeconds + audio.duration,
            captureStartTime: statistics.captureStartTime,
            lastSampleTime: Date(),
            meetingDetectedCount: statistics.meetingDetectedCount,
            autoMuteCount: statistics.autoMuteCount
        )
    }

    // MARK: - Privacy-Aware Muting Logic

    /// Handle meeting state changes and apply automatic muting logic
    private func handleMeetingStateChange(_ state: MeetingState, generation: UUID) async {
        guard sessionGeneration == generation, config.systemAudioEnabled else { return }
        currentMeetingState = state

        // Update statistics
        if state.isInMeeting {
            statistics = AudioCaptureStatistics(
                microphoneSamplesRecorded: statistics.microphoneSamplesRecorded,
                systemAudioSamplesRecorded: statistics.systemAudioSamplesRecorded,
                microphoneDurationSeconds: statistics.microphoneDurationSeconds,
                systemAudioDurationSeconds: statistics.systemAudioDurationSeconds,
                captureStartTime: statistics.captureStartTime,
                lastSampleTime: statistics.lastSampleTime,
                meetingDetectedCount: statistics.meetingDetectedCount + 1,
                autoMuteCount: statistics.autoMuteCount
            )
        }

        await updateSystemAudioMuteState(meetingState: state)
        guard sessionGeneration == generation else { return }
        if systemRuntime.isActive {
            systemRuntime = .init(await systemAudioCapture.getMuted() ? .mutedForMeeting : .running,
                lastSampleAt: systemRuntime.lastSampleAt)
        }
    }

    /// Update system audio mute state based on meeting state and user consent
    /// PRIVACY LOGIC:
    /// - IF in meeting AND no consent: MUTE system audio
    /// - IF in meeting AND has consent: ALLOW system audio
    /// - IF not in meeting: ALLOW system audio
    private func updateSystemAudioMuteState(meetingState: MeetingState) async {
        let shouldMute: Bool

        if meetingState.isInMeeting {
            // In a meeting - check consent
            if config.hasConsentedToMeetingRecording {
                // User has explicitly consented to recording during meetings
                shouldMute = false
            } else {
                // No consent - automatically mute to protect privacy
                shouldMute = true

                // Update auto-mute count
                statistics = AudioCaptureStatistics(
                    microphoneSamplesRecorded: statistics.microphoneSamplesRecorded,
                    systemAudioSamplesRecorded: statistics.systemAudioSamplesRecorded,
                    microphoneDurationSeconds: statistics.microphoneDurationSeconds,
                    systemAudioDurationSeconds: statistics.systemAudioDurationSeconds,
                    captureStartTime: statistics.captureStartTime,
                    lastSampleTime: statistics.lastSampleTime,
                    meetingDetectedCount: statistics.meetingDetectedCount,
                    autoMuteCount: statistics.autoMuteCount + 1
                )
            }
        } else {
            // Not in a meeting - allow system audio
            shouldMute = false
        }

        await systemAudioCapture.setMuted(shouldMute)
    }
}

// MARK: - Validation & Debugging

extension AudioCaptureManager {

    /// Verify Voice Processing is enabled on microphone
    public func isVoiceProcessingEnabled() async -> Bool {
        return await microphoneCapture.isVoiceProcessingEnabled()
    }

    /// Get microphone input format
    public func getMicrophoneFormat() async -> (sampleRate: Double, channels: Int) {
        return await microphoneCapture.getInputFormat()
    }

    /// Force a meeting state check (for testing)
    public func checkMeetingStatus() async -> MeetingState {
        return await meetingDetector.getCurrentState()
    }
}
