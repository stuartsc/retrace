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
    private var meetingComparisonRequest = UUID()

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

    public init(config: AudioCaptureConfig = .default,
                meetingCaptureConfig: (@Sendable () async -> MeetingCapturePolicySnapshot?)? = nil) {
        self.config = config
        self.microphoneCapture = MicrophoneAudioCapture(config: config)
        self.systemAudioCapture = SystemAudioCapture(config: config)
        self.meetingDetector = MeetingDetector(captureConfig: meetingCaptureConfig)
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

        meetingComparisonRequest = UUID()
        self.config = config

        // Create combined audio stream
        let (stream, continuation) = AudioStreamBufferingPolicy.makeStream(
            limit: AudioStreamBufferingPolicy.combinedSampleLimit
        )
        self._audioStream = stream
        self.audioContinuation = continuation

        // Install the owned, awaited consumer before the first observation.
        // Unknown/stale evidence must never release no-consent audio protection.
        await meetingDetector.onStateChangeAsync { [weak self] state in
            await self?.handleMeetingStateChange(state)
        }
        await meetingDetector.setComparisonEnabled(config.meetingEvidenceComparisonEnabled)
        await systemAudioCapture.setMuted(!config.hasConsentedToMeetingRecording)
        await meetingDetector.startMonitoring(bundleIDs: config.meetingAppBundleIDs)

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
                let beforeStart = await meetingDetector.getCurrentState()
                await updateSystemAudioMuteState(meetingState: beforeStart)
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
        guard isCapturing else {
            // A consumer can acquire a stream before a failed/cancelled native
            // start. Finish that exact stream so graceful drain cannot await a
            // lazily created, device-less producer forever.
            audioContinuation?.finish()
            audioContinuation = nil
            _audioStream = nil
            return
        }

        await meetingDetector.stopMonitoring()
        await microphoneCapture.stopCapture()
        var systemStopError: Error?
        do {
            try await systemAudioCapture.stopCapture()
        } catch {
            systemStopError = error
        }
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
        meetingComparisonRequest = UUID()
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
        return await meetingDetector.getCurrentState()
    }

    /// App bridges existing transcription/speech-like-energy results. This does
    /// not start audio or inspect a transcript; observations retain original times.
    public func observeMeetingSpeech(_ observation: MeetingObservation) async {
        await meetingDetector.observeSpeech(observation)
    }

    /// Updates only the comparison detector. Existing PCM streams, recording
    /// choices and consent survive. Read getConfig() after ACK for accepted state.
    public func setMeetingEvidenceComparisonEnabled(_ enabled: Bool) async {
        let request = UUID()
        meetingComparisonRequest = request
        await meetingDetector.setComparisonEnabled(enabled)
        let acknowledged = await meetingDetector.comparisonIsEnabled()
        guard request == meetingComparisonRequest else { return }
        config = config.withMeetingEvidenceComparisonEnabled(acknowledged)
    }

    /// Awaited by the detector; stop/reconfigure joins in-flight metric delivery.
    /// A handler must not await this manager's stop from within its own delivery.
    public func setMeetingOutcomeHandler(_ handler: (@Sendable (MeetingDetectionOutcome) async -> Void)?) async {
        await meetingDetector.setOutcomeHandler(handler)
    }

    public func setSystemAudioMuted(_ muted: Bool) async {
        let permitted = MeetingAudioPrivacyPolicy.permitsSystemAudio(state: currentMeetingState, config: config,
            uptime: ProcessInfo.processInfo.systemUptime)
        await systemAudioCapture.setMuted(muted || !permitted)
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
        // The native source may be awaiting a slow observer/native call when a
        // previously absent inventory expires. Enforce freshness again before
        // delivering PCM, so an old unmute cannot outlive its evidence lease.
        guard MeetingAudioPrivacyPolicy.permitsSystemAudio(state: currentMeetingState, config: config,
            uptime: ProcessInfo.processInfo.systemUptime) else { return }
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
        let wasInMeeting = currentMeetingState.isInMeeting
        currentMeetingState = state

        // Update statistics
        if state.isInMeeting && !wasInMeeting {
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
    /// Confidence and consent are separate. Possible/unknown/stale observations
    /// protect audio; app presence alone never becomes a supported active call.
    private func updateSystemAudioMuteState(meetingState: MeetingState) async {
        let shouldMute = !MeetingAudioPrivacyPolicy.permitsSystemAudio(state: meetingState, config: config,
            uptime: ProcessInfo.processInfo.systemUptime)
        if shouldMute, !(await systemAudioCapture.getMuted()) {
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
