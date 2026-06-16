import Foundation
import AVFoundation
import CoreMedia
import CoreAudio
import Shared

/// Microphone audio capture (Pipeline A)
/// Uses AVCaptureSession for shared mic access — does NOT block other apps from using the mic
public actor MicrophoneAudioCapture {

    private let captureSession = AVCaptureSession()
    private var audioOutput: AVCaptureAudioDataOutput?
    private var delegate: MicAudioDelegate?
    private let formatConverter: AudioFormatConverter
    private var isRunning = false

    // Audio stream
    private var audioContinuation: AsyncStream<CapturedAudio>.Continuation?
    private var _audioStream: AsyncStream<CapturedAudio>?

    // Configuration
    private var config: AudioCaptureConfig

    public init(config: AudioCaptureConfig) {
        self.config = config
        self.formatConverter = AudioFormatConverter()
    }

    // MARK: - Permission

    /// Check microphone permission
    public func hasPermission() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        default:
            return false
        }
    }

    /// Request microphone permission
    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Lifecycle

    /// Start capturing microphone audio
    public func startCapture() async throws {
        guard !isRunning else {
            Log.warning("[MicrophoneAudioCapture] Already running, skipping", category: .capture)
            return
        }

        print("[MicrophoneAudioCapture] Starting capture...")
        Log.info("[MicrophoneAudioCapture] Starting capture...", category: .capture)

        // Create audio stream
        let (stream, continuation) = AudioStreamBufferingPolicy.makeStream(
            limit: AudioStreamBufferingPolicy.sourceSampleLimit
        )
        self._audioStream = stream
        self.audioContinuation = continuation

        // Configure capture session
        try configureCaptureSession(continuation: continuation)
        Log.info("[MicrophoneAudioCapture] Capture session configured", category: .capture)

        // Start on background queue (startRunning is synchronous and can block)
        let session = captureSession
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
                cont.resume()
            }
        }

        let running = captureSession.isRunning
        isRunning = running
        Log.info("[MicrophoneAudioCapture] AVCaptureSession running=\(running) (shared mic, no Voice Processing)", category: .capture)
    }

    /// Stop capturing
    public func stopCapture() {
        guard isRunning else { return }

        captureSession.stopRunning()

        // Remove inputs/outputs
        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }
        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }

        isRunning = false
        audioContinuation?.finish()
        audioContinuation = nil
        _audioStream = nil
        delegate = nil
        audioOutput = nil
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

    /// Update configuration
    public func updateConfig(_ newConfig: AudioCaptureConfig) async throws {
        let wasRunning = isRunning

        if wasRunning {
            stopCapture()
        }

        self.config = newConfig

        if wasRunning {
            try await startCapture()
        }
    }

    // MARK: - Private Configuration

    private func configureCaptureSession(continuation: AsyncStream<CapturedAudio>.Continuation) throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // Get default audio device (mic)
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            throw AudioCaptureError.invalidConfiguration("No audio input device available")
        }

        Log.info("[MicrophoneAudioCapture] Using device: \(audioDevice.localizedName)", category: .capture)

        // Add input
        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
        guard captureSession.canAddInput(audioInput) else {
            throw AudioCaptureError.invalidConfiguration("Cannot add audio input to capture session")
        }
        captureSession.addInput(audioInput)

        // Add output
        let output = AVCaptureAudioDataOutput()
        let callbackQueue = DispatchQueue(label: "io.retrace.mic-capture", qos: .userInitiated)

        let del = MicAudioDelegate(
            continuation: continuation,
            formatConverter: formatConverter
        )
        output.setSampleBufferDelegate(del, queue: callbackQueue)

        guard captureSession.canAddOutput(output) else {
            throw AudioCaptureError.invalidConfiguration("Cannot add audio output to capture session")
        }
        captureSession.addOutput(output)

        self.audioOutput = output
        self.delegate = del
    }
}

// MARK: - AVCaptureAudioDataOutput Delegate

private final class MicAudioDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

    private let continuation: AsyncStream<CapturedAudio>.Continuation
    private let formatConverter: AudioFormatConverter

    init(continuation: AsyncStream<CapturedAudio>.Continuation, formatConverter: AudioFormatConverter) {
        self.continuation = continuation
        self.formatConverter = formatConverter
        super.init()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        guard let desc = asbd else { return }

        let sampleRate = desc.mSampleRate
        let channels = Int(desc.mChannelsPerFrame)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)

        guard frameCount > 0 else { return }

        // Get raw audio data
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let rawData = dataPointer else { return }

        do {
            // Determine input format from ASBD
            let inputFormat: AudioFormatType
            if desc.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                inputFormat = .float32
            } else if desc.mBitsPerChannel == 16 {
                inputFormat = .int16
            } else {
                inputFormat = .float32  // fallback
            }

            let convertedData = try formatConverter.convertToStandardFormat(
                inputData: UnsafeRawPointer(rawData),
                inputLength: totalLength,
                inputSampleRate: sampleRate,
                inputChannels: channels,
                inputFormat: inputFormat
            )

            let duration = Double(frameCount) / sampleRate

            let capturedAudio = CapturedAudio(
                timestamp: Date(),
                audioData: convertedData,
                duration: duration,
                source: .microphone,
                sampleRate: formatConverter.targetSampleRate,
                channels: formatConverter.targetChannels
            )

            continuation.yield(capturedAudio)

        } catch {
            // Don't spam logs for every buffer
        }
    }
}

// MARK: - Voice Processing Validation (legacy compatibility)

extension MicrophoneAudioCapture {

    /// Voice Processing is no longer used — always returns false
    public func isVoiceProcessingEnabled() -> Bool {
        return false
    }

    /// Get current audio format information
    public func getInputFormat() -> (sampleRate: Double, channels: Int) {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            return (0, 0)
        }
        let format = device.activeFormat.formatDescription
        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            return (asbd.mSampleRate, Int(asbd.mChannelsPerFrame))
        }
        return (0, 0)
    }
}
