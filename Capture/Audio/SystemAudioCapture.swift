import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import Shared

/// System audio capture (Pipeline B)
/// Uses ScreenCaptureKit to capture system audio output
/// PRIVACY: Automatically muted during meetings unless user has consented
public actor SystemAudioCapture: NSObject {

    private var stream: SCStream?
    private var streamOutput: SystemAudioStreamOutput?
    private var isRunning = false
    private var isMuted = false
    private let muteState = SystemAudioMuteState()

    private let formatConverter: AudioFormatConverter
    private let sampleHandlerQueue = DispatchQueue(
        label: SystemAudioCaptureConcurrencyPolicy.sampleHandlerQueueLabel,
        qos: .userInitiated
    )

    // Audio stream
    private var audioContinuation: AsyncStream<CapturedAudio>.Continuation?
    private var _audioStream: AsyncStream<CapturedAudio>?

    // Configuration
    private var config: AudioCaptureConfig

    public init(config: AudioCaptureConfig) {
        self.config = config
        self.formatConverter = AudioFormatConverter()
        super.init()
    }

    // MARK: - Lifecycle

    /// Start capturing system audio
    public func startCapture() async throws {
        guard !isRunning else { return }

        // Create audio stream
        let (stream, continuation) = AudioStreamBufferingPolicy.makeStream(
            limit: AudioStreamBufferingPolicy.sourceSampleLimit
        )
        self._audioStream = stream
        self.audioContinuation = continuation
        muteState.set(isMuted)
        formatConverter.reset()

        // Get shareable content
        Log.info("[SystemAudioCapture] Requesting shareable content...", category: .capture)
        let availableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )

        Log.info("[SystemAudioCapture] Found \(availableContent.displays.count) displays, \(availableContent.applications.count) apps", category: .capture)

        guard let display = availableContent.displays.first else {
            throw AudioCaptureError.systemAudioNotAvailable
        }

        // Create filter — capture all audio from the display
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        // Configure stream for audio-only
        let streamConfig = SCStreamConfiguration()
        streamConfig.capturesAudio = true
        streamConfig.excludesCurrentProcessAudio = true  // Don't capture our own audio output
        streamConfig.sampleRate = 48000  // System default, we'll convert to 16kHz
        streamConfig.channelCount = 2    // Stereo system audio, we'll convert to mono

        // We don't need video for audio-only capture
        streamConfig.width = 1
        streamConfig.height = 1
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        streamConfig.showsCursor = false

        // Create stream output handler
        let output = SystemAudioStreamOutput(
            continuation: audioContinuation!,
            formatConverter: formatConverter,
            muteState: muteState
        )
        self.streamOutput = output

        // Create and configure stream
        let scStream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)

        // Add audio output handler
        try scStream.addStreamOutput(
            output,
            type: .audio,
            sampleHandlerQueue: sampleHandlerQueue
        )

        // Start capture
        Log.info("[SystemAudioCapture] Starting SCStream capture...", category: .capture)
        try await scStream.startCapture()

        self.stream = scStream
        self.isRunning = true
        Log.info("[SystemAudioCapture] System audio capture started successfully", category: .capture)
    }

    /// Stop capturing
    public func stopCapture() async throws {
        // Even if ScreenCaptureKit reports a stop error, end the local source
        // stream so the coordinator can drain queued samples without hanging.
        defer {
            streamOutput?.finish()
            stream = nil
            streamOutput = nil
            isRunning = false
            audioContinuation?.finish()
            audioContinuation = nil
            _audioStream = nil
        }
        if let stream = stream {
            try await stream.stopCapture()
        }
    }

    /// Get audio stream
    public var audioStream: AsyncStream<CapturedAudio> {
        get async {
            if let stream = _audioStream {
                return stream
            }

            let (stream, continuation) = AudioStreamBufferingPolicy.makeStream(
                limit: AudioStreamBufferingPolicy.sourceSampleLimit
            )
            self._audioStream = stream
            self.audioContinuation = continuation
            return stream
        }
    }

    // MARK: - Muting Control

    /// Set mute state (for privacy during meetings)
    public func setMuted(_ muted: Bool) {
        self.isMuted = muted
        if let streamOutput {
            streamOutput.setMuted(muted)
        } else {
            muteState.set(muted)
        }
    }

    /// Get current mute state
    public func getMuted() -> Bool {
        return isMuted
    }

    // MARK: - Configuration

    /// Update configuration
    public func updateConfig(_ newConfig: AudioCaptureConfig) async throws {
        let wasRunning = isRunning

        if wasRunning {
            try await stopCapture()
        }

        self.config = newConfig

        if wasRunning {
            try await startCapture()
        }
    }
}

// MARK: - Stream Output Handler

/// Handles audio samples from SCStream
final class SystemAudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let continuation: AsyncStream<CapturedAudio>.Continuation
    private let formatConverter: AudioFormatConverter
    private let muteState: SystemAudioMuteState
    private let stateLock = NSLock()
    private var isFinished = false
    private var wasMuted = false
    private var pendingStart: Date?
    private var lastOutputEnd: Date?
    private var reportedConversionFailure = false

    init(
        continuation: AsyncStream<CapturedAudio>.Continuation,
        formatConverter: AudioFormatConverter,
        muteState: SystemAudioMuteState
    ) {
        self.continuation = continuation
        self.formatConverter = formatConverter
        self.muteState = muteState
        super.init()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio else { return }
        receive(sampleBuffer, receivedAt: Date())
    }

    func receive(_ sampleBuffer: CMSampleBuffer, receivedAt: Date) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isFinished else { return }
        if muteState.get() {
            if !wasMuted {
                // Never carry retained samples across a recording-consent boundary.
                formatConverter.reset()
                pendingStart = nil
                lastOutputEnd = nil
            }
            wasMuted = true
            return
        }
        wasMuted = false
        if pendingStart == nil { pendingStart = receivedAt }
        do {
            let data = try formatConverter.convert(sampleBuffer: sampleBuffer)
            emit(data, at: pendingStart ?? receivedAt)
            reportedConversionFailure = false
        } catch {
            formatConverter.reset()
            pendingStart = nil
            lastOutputEnd = nil
            if !reportedConversionFailure {
                Log.warning("[SystemAudioCapture] Audio format conversion failed; waiting for a valid buffer", category: .capture)
                reportedConversionFailure = true
            }
        }
    }

    func setMuted(_ muted: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        muteState.set(muted)
        if muted {
            formatConverter.reset()
            pendingStart = nil
            lastOutputEnd = nil
        }
        wasMuted = muted
    }

    func finish() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isFinished else { return }
        isFinished = true
        if muteState.get() {
            formatConverter.reset()
            return
        }
        do {
            emit(try formatConverter.finish(), at: lastOutputEnd ?? pendingStart ?? Date())
        } catch {
            Log.warning("[SystemAudioCapture] Could not drain final audio conversion samples", category: .capture)
        }
    }

    private func emit(_ data: Data, at timestamp: Date) {
        guard !data.isEmpty else { return }
        let duration = Double(data.count) / Double(formatConverter.targetSampleRate * MemoryLayout<Int16>.size)
        continuation.yield(CapturedAudio(
            timestamp: timestamp, audioData: data, duration: duration, source: .system,
            sampleRate: formatConverter.targetSampleRate, channels: formatConverter.targetChannels
        ))
        lastOutputEnd = timestamp.addingTimeInterval(duration)
        pendingStart = nil
    }
}

enum SystemAudioCaptureConcurrencyPolicy {
    static let sampleHandlerQueueLabel = "io.retrace.system-audio-capture"
    static let usesPerSampleTasks = false
}

final class SystemAudioMuteState: @unchecked Sendable {
    private let lock = NSLock()
    private var muted = false

    func set(_ muted: Bool) {
        lock.lock()
        self.muted = muted
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return muted
    }
}
