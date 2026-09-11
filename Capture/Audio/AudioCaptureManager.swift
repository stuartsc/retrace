import Foundation
import AVFoundation
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
        guard !isCapturing else { return }

        self.config = config

        // Create combined audio stream
        let (stream, continuation) = AudioStreamBufferingPolicy.makeStream(
            limit: AudioStreamBufferingPolicy.combinedSampleLimit
        )
        self._audioStream = stream
        self.audioContinuation = continuation

        // Start meeting detection
        await meetingDetector.startMonitoring(bundleIDs: config.meetingAppBundleIDs)
        await meetingDetector.onStateChange { [weak self] state in
            Task {
                await self?.handleMeetingStateChange(state)
            }
        }

        // Start microphone capture if enabled
        if config.microphoneEnabled {
            do {
                try await microphoneCapture.startCapture()
            } catch {
                await microphoneCapture.stopCapture()
                await meetingDetector.stopMonitoring()
                audioContinuation?.finish()
                audioContinuation = nil
                _audioStream = nil
                throw error
            }
            let microphoneStream = await microphoneCapture.audioStream
            microphoneStreamTask = AudioStreamForwarding.start(microphoneStream) { [weak self] audio in
                await self?.receiveMicrophoneAudio(audio)
            }
        }

        // Start system audio capture if enabled (non-fatal if it fails)
        if config.systemAudioEnabled {
            do {
                try await systemAudioCapture.startCapture()

                // Apply initial mute state based on current meeting state
                let currentState = await meetingDetector.getCurrentState()
                await updateSystemAudioMuteState(meetingState: currentState)

                let systemStream = await systemAudioCapture.audioStream
                systemAudioStreamTask = AudioStreamForwarding.start(systemStream) { [weak self] audio in
                    await self?.receiveSystemAudio(audio)
                }
                Log.info("[AudioCaptureManager] System audio capture started", category: .capture)
            } catch {
                try? await systemAudioCapture.stopCapture()
                Log.warning("[AudioCaptureManager] System audio capture failed (will continue with mic only): \(error)", category: .capture)
            }
        }

        isCapturing = true
        statistics = AudioCaptureStatistics(
            microphoneSamplesRecorded: 0,
            systemAudioSamplesRecorded: 0,
            microphoneDurationSeconds: 0,
            systemAudioDurationSeconds: 0,
            captureStartTime: Date(),
            lastSampleTime: nil,
            meetingDetectedCount: 0,
            autoMuteCount: 0
        )
    }

    public func stopCapture() async throws {
        guard isCapturing else { return }

        await microphoneCapture.stopCapture()
        var systemStopError: Error?
        do {
            try await systemAudioCapture.stopCapture()
        } catch {
            systemStopError = error
        }
        await meetingDetector.stopMonitoring()

        // Source stop finishes its stream, including resampler tails. Cancelling
        // these consumers would discard queued audio instead of forwarding it.
        await AudioStreamForwarding.drain([microphoneStreamTask, systemAudioStreamTask])
        isCapturing = false
        microphoneStreamTask = nil
        systemAudioStreamTask = nil
        audioContinuation?.finish()
        audioContinuation = nil
        _audioStream = nil
        if let systemStopError { throw systemStopError }
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

    public func updateConfig(_ config: AudioCaptureConfig) async throws {
        let wasCapturing = isCapturing

        if wasCapturing {
            try await stopCapture()
        }

        self.config = config

        if wasCapturing {
            try await startCapture(config: config)
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
    private func handleMeetingStateChange(_ state: MeetingState) async {
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
