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
        guard isRunning else { return }

        if let stream = stream {
            try await stream.stopCapture()
        }

        stream = nil
        streamOutput = nil
        isRunning = false

        audioContinuation?.finish()
        audioContinuation = nil
        _audioStream = nil
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
        muteState.set(muted)
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
private class SystemAudioStreamOutput: NSObject, SCStreamOutput {

    private let continuation: AsyncStream<CapturedAudio>.Continuation
    private let formatConverter: AudioFormatConverter
    private let muteState: SystemAudioMuteState

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
        guard !muteState.get() else { return }

        processAudioBuffer(sampleBuffer)
    }

    private func processAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        do {
            // Get format description
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                return
            }

            let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
            guard let asbd = audioStreamBasicDescription?.pointee else {
                return
            }

            // Extract audio buffer list with retained block buffer
            var audioBufferList = AudioBufferList()
            var blockBuffer: CMBlockBuffer?

            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: &audioBufferList,
                bufferListSize: MemoryLayout<AudioBufferList>.size,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: &blockBuffer
            )

            guard status == noErr else {
                Log.error("[SystemAudioCapture] Error getting audio buffer list: \(status)", category: .capture)
                return
            }

            // Keep blockBuffer alive while processing audio data
            // The blockBuffer owns the memory that audioBufferList points to
            _ = try withExtendedLifetime(blockBuffer) {
                // Process each buffer in the buffer list
                let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)

                for audioBuffer in buffers {
                    guard let data = audioBuffer.mData else { continue }

                    let convertedData = try formatConverter.convertToStandardFormat(
                        inputData: data,
                        inputLength: Int(audioBuffer.mDataByteSize),
                        inputSampleRate: asbd.mSampleRate,
                        inputChannels: Int(asbd.mChannelsPerFrame),
                        inputFormat: audioFormatType(from: asbd.mFormatFlags)
                    )

                    let duration = Double(CMSampleBufferGetNumSamples(sampleBuffer)) / asbd.mSampleRate

                    let capturedAudio = CapturedAudio(
                        timestamp: Date(),
                        audioData: convertedData,
                        duration: duration,
                        source: .system,
                        sampleRate: formatConverter.targetSampleRate,
                        channels: formatConverter.targetChannels
                    )

                    continuation.yield(capturedAudio)
                }
            }

        } catch {
            Log.error("[SystemAudioCapture] Error converting system audio: \(error)", category: .capture)
        }
    }

    private func audioFormatType(from flags: AudioFormatFlags) -> AudioFormatType {
        if flags & kAudioFormatFlagIsFloat != 0 {
            return .float32
        } else if flags & kAudioFormatFlagIsSignedInteger != 0 {
            return .int16  // Assuming 16-bit
        } else {
            return .int16  // Default
        }
    }
}

enum SystemAudioCaptureConcurrencyPolicy {
    static let sampleHandlerQueueLabel = "io.retrace.system-audio-capture"
    static let usesPerSampleTasks = false
}

private final class SystemAudioMuteState: @unchecked Sendable {
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
