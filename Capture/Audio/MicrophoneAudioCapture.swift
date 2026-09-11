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

        // A restarted source must not inherit filter samples from its previous session.
        formatConverter.reset()

        // Configure capture session
        do {
            try configureCaptureSession(continuation: continuation)
        } catch {
            stopCapture()
            throw error
        }
        Log.info("[MicrophoneAudioCapture] Capture session configured", category: .capture)

        // Start on background queue (startRunning is synchronous and can block)
        let session = captureSession
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
                cont.resume()
            }
        }

        try finishStartingCapture()
    }

    func finishStartingCapture() throws {
        guard captureSession.isRunning else {
            stopCapture()
            throw AudioCaptureError.captureSessionFailed("Microphone capture session did not start")
        }
        isRunning = true
        Log.info("[MicrophoneAudioCapture] AVCaptureSession running=true (shared mic, no Voice Processing)", category: .capture)
    }

    /// Stop capturing
    public func stopCapture() {
        // A failed start or a preacquired stream still needs deterministic teardown.
        if captureSession.isRunning { captureSession.stopRunning() }
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)

        // Remove inputs/outputs
        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }
        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }

        // Stop callbacks before draining the final native resampler samples.
        delegate?.finish()
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

final class MicAudioDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<CapturedAudio>.Continuation
    private let formatConverter: AudioFormatConverter
    // Callback conversion and background shutdown share this bounded critical section.
    private let stateLock = NSLock()
    private var isFinished = false
    private var pendingStart: Date?
    private var lastOutputEnd: Date?
    private var reportedConversionFailure = false

    init(continuation: AsyncStream<CapturedAudio>.Continuation, formatConverter: AudioFormatConverter) {
        self.continuation = continuation
        self.formatConverter = formatConverter
        super.init()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        receive(sampleBuffer, receivedAt: Date())
    }

    func receive(_ sampleBuffer: CMSampleBuffer, receivedAt: Date) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isFinished else { return }
        if pendingStart == nil { pendingStart = receivedAt }
        do {
            let data = try formatConverter.convert(sampleBuffer: sampleBuffer)
            emit(data, at: pendingStart ?? receivedAt)
            reportedConversionFailure = false
        } catch {
            // A rejected packet is a discontinuity; retain neither filter history nor
            // its wall-clock anchor. Empty successful output above is normal priming.
            formatConverter.reset()
            pendingStart = nil
            lastOutputEnd = nil
            if !reportedConversionFailure {
                Log.warning("[MicrophoneAudioCapture] Audio format conversion failed; waiting for a valid buffer", category: .capture)
                reportedConversionFailure = true
            }
        }
    }

    func finish() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isFinished else { return }
        isFinished = true
        do {
            emit(try formatConverter.finish(), at: lastOutputEnd ?? pendingStart ?? Date())
        } catch {
            Log.warning("[MicrophoneAudioCapture] Could not drain final audio conversion samples", category: .capture)
        }
    }

    private func emit(_ data: Data, at timestamp: Date) {
        guard !data.isEmpty else { return }
        let duration = Double(data.count) / Double(formatConverter.targetSampleRate * MemoryLayout<Int16>.size)
        continuation.yield(CapturedAudio(
            timestamp: timestamp, audioData: data, duration: duration, source: .microphone,
            sampleRate: formatConverter.targetSampleRate, channels: formatConverter.targetChannels
        ))
        lastOutputEnd = timestamp.addingTimeInterval(duration)
        pendingStart = nil
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
