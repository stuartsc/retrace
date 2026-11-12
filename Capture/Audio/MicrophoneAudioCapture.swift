import Foundation
import AVFoundation
import CoreMedia
import CoreAudio
import Shared

/// Microphone audio capture (Pipeline A)
/// Uses AVCaptureSession for shared mic access — does NOT block other apps from using the mic
public actor MicrophoneAudioCapture {

    private let hardware: any MicrophoneCaptureHardware
    private var delegate: MicAudioDelegate?
    private var selectedInput: MicrophoneInputDevice?
    private var isRunning = false
    private var generation: UUID?
    private var starting: Task<Void, Error>?
    private var routing: Task<Void, Never>?
    private var stopping: (id: UUID, task: Task<Void, Never>)?
    private var observation: (any MicrophoneInputObservation)?
    private var stopRevision: UInt64 = 0
    private var audioContinuation: AsyncStream<CapturedAudio>.Continuation?
    private var _audioStream: AsyncStream<CapturedAudio>?
    private var config: AudioCaptureConfig

    public init(config: AudioCaptureConfig) {
        self.config = config
        self.hardware = NativeMicrophoneCaptureHardware()
    }

    init(config: AudioCaptureConfig, hardware: any MicrophoneCaptureHardware) {
        self.config = config
        self.hardware = hardware
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

    /// Passive native connection state. A running session can have no selected
    /// input while waiting for a device event; that is unavailable, not running.
    public func runtimeState() -> AudioSourceRuntimeState {
        guard generation != nil else { return .paused }
        return isRunning && selectedInput != nil ? .running : .unavailable
    }

    /// Start one source stream. Concurrent starts share native startup; device
    /// changes replace only the input/delegate while this stream stays open.
    public func startCapture() async throws {
        let requestedAtStopRevision = stopRevision
        while let stop = stopping {
            await stop.task.value
            if stopping?.id == stop.id { stopping = nil }
        }
        try Task.checkCancellation()
        guard stopRevision == requestedAtStopRevision else { throw CancellationError() }
        if let starting { try await starting.value; return }
        guard !isRunning else { return }
        _ = await audioStream
        let id = UUID()
        generation = id
        let task = Task { try await self.beginCapture(generation: id) }
        starting = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
                try Task.checkCancellation()
            } onCancel: { task.cancel() }
            if generation == id { starting = nil }
        } catch {
            // A superseded start cannot tear down a replacement recording.
            if generation == id { await stopCapture() }
            throw error
        }
    }

    private func beginCapture(generation id: UUID) async throws {
        let observation = try await hardware.observeInputChanges()
        do { try checkGeneration(id) }
        catch { await observation.stop(); throw error }
        self.observation = observation
        try await selectDefaultInput(generation: id, reconnect: false, required: true)
        try checkGeneration(id)
        await hardware.startRunning()
        try checkGeneration(id)
        let running = await hardware.isRunning()
        try checkGeneration(id)
        guard running else {
            throw AudioCaptureError.captureSessionFailed("Microphone capture session did not start")
        }
        isRunning = true
        let events = observation.events
        routing = Task { [weak self] in
            for await _ in events.stream {
                guard !Task.isCancelled else { break }
                await self?.refreshDefaultInput(generation: id, reconnect: events.takeReconnectRequest())
            }
        }
        Log.info("[MicrophoneAudioCapture] Microphone session running; following default input", category: .capture)
    }

    private func checkGeneration(_ id: UUID) throws {
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
    }

    private func refreshDefaultInput(generation id: UUID, reconnect: Bool) async {
        do { try await selectDefaultInput(generation: id, reconnect: reconnect, required: false) }
        catch is CancellationError { /* Stop owns final session teardown. */ }
        catch {
            Log.warning("[MicrophoneAudioCapture] Default input unavailable; waiting for a device change", category: .capture)
        }
    }

    private func selectDefaultInput(generation id: UUID, reconnect: Bool, required: Bool) async throws {
        try checkGeneration(id)
        let input: MicrophoneInputDevice?
        do { input = try await hardware.defaultInput() }
        catch {
            try checkGeneration(id)
            await detachCurrentInput()
            try checkGeneration(id)
            throw error
        }
        try checkGeneration(id)
        if let input, selectedInput?.uid == input.uid, !reconnect { return }

        await detachCurrentInput()
        try checkGeneration(id)
        guard let input else {
            Log.warning("[MicrophoneAudioCapture] Default input unavailable; waiting for a device change", category: .capture)
            if required { throw AudioCaptureError.invalidConfiguration("No audio input device available") }
            return
        }
        guard let continuation = audioContinuation else { throw CancellationError() }
        let next = MicAudioDelegate(continuation: continuation, formatConverter: AudioFormatConverter(),
            recordingGeneration: id)
        observation?.events.setInputUID(input.uid)
        delegate = next
        do {
            try await hardware.attach(input, delegate: next)
            try checkGeneration(id)
            selectedInput = input
            Log.info("[MicrophoneAudioCapture] Default microphone input connected", category: .capture)
        } catch {
            next.stopAcceptingSamples()
            await detachCurrentInput()
            try checkGeneration(id)
            throw error
        }
    }

    private func detachCurrentInput() async {
        selectedInput = nil
        observation?.events.setInputUID(nil)
        let previous = delegate
        // Keep the delegate reachable so stop can revoke it while the queue drains.
        await hardware.detach()
        previous?.finish()
        delegate = nil
    }

    /// Revoke callback admission before any await, then join startup, observation,
    /// routing and native callbacks before the final stream termination.
    public func stopCapture() async {
        stopRevision &+= 1
        generation = nil
        isRunning = false
        delegate?.stopAcceptingSamples()
        observation?.events.finish()
        if let stopping { await stopping.task.value; return }
        let start = starting
        let route = routing
        let observed = observation
        starting = nil
        routing = nil
        observation = nil
        start?.cancel()
        route?.cancel()
        let id = UUID()
        let task = Task {
            await observed?.stop()
            _ = try? await start?.value
            await route?.value
            await self.finishStoppingCapture(stopID: id)
        }
        stopping = (id, task)
        await task.value
        if stopping?.id == id { stopping = nil }
    }

    private func finishStoppingCapture(stopID: UUID) async {
        await hardware.stopRunning()
        delegate?.finish()
        audioContinuation?.finish()
        audioContinuation = nil
        _audioStream = nil
        delegate = nil
        selectedInput = nil
        // Retire ownership before this task completes: a waiting restart must
        // never inherit a completed stop tuple that could absorb its next pause.
        if stopping?.id == stopID { stopping = nil }
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
        let wasRunning = generation != nil
        let expectedStopRevision = stopRevision &+ 1

        if wasRunning {
            await stopCapture()
        }

        self.config = newConfig

        if wasRunning {
            guard stopRevision == expectedStopRevision else { return }
            try await startCapture()
        }
    }

}

// MARK: - AVCaptureAudioDataOutput Delegate

final class MicAudioDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<CapturedAudio>.Continuation
    private let formatConverter: AudioFormatConverter
    // Callback conversion and background shutdown share this bounded critical section.
    private let stateLock = NSLock()
    private var isFinished = false
    private var acceptsSamples = true
    private var sampleClock = AudioCaptureSampleClock()
    private let recordingGeneration: UUID
    private var reportedConversionFailure = false

    init(continuation: AsyncStream<CapturedAudio>.Continuation, formatConverter: AudioFormatConverter,
         recordingGeneration: UUID = UUID()) {
        self.continuation = continuation
        self.formatConverter = formatConverter
        self.recordingGeneration = recordingGeneration
        super.init()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        receive(sampleBuffer, receivedAt: Date())
    }

    func receive(_ sampleBuffer: CMSampleBuffer, receivedAt: Date) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isFinished, acceptsSamples else { return }
        let packet: AudioNativePacketTiming
        do { packet = try AudioNativePacketTiming(sampleBuffer) }
        catch {
            // Rejected metadata has not entered the converter. Keep only its
            // already accepted predecessor's tail before ending continuity.
            if let tail = try? formatConverter.finish() { emit(tail) }
            resetAfterConversionFailure()
            return
        }
        do {
            if !sampleClock.isContinuous(packet) {
                emit(try formatConverter.finish())
                sampleClock.begin(packet, receivedAt: receivedAt)
            }
            let data = try formatConverter.convert(sampleBuffer: sampleBuffer)
            sampleClock.consumed(packet)
            emit(data)
            reportedConversionFailure = false
        } catch {
            // A rejected packet is a discontinuity; retain neither filter history nor
            // its wall-clock anchor. Empty successful output above is normal priming.
            resetAfterConversionFailure()
        }
    }

    private func resetAfterConversionFailure() {
        formatConverter.reset()
        sampleClock.reset()
        if !reportedConversionFailure {
            Log.warning("[MicrophoneAudioCapture] Audio format conversion failed; waiting for a valid buffer", category: .capture)
            reportedConversionFailure = true
        }
    }

    /// Pause admission immediately; already converted samples still drain once.
    func stopAcceptingSamples() {
        stateLock.lock()
        acceptsSamples = false
        stateLock.unlock()
    }

    func finish() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isFinished else { return }
        isFinished = true
        do {
            emit(try formatConverter.finish())
        } catch {
            Log.warning("[MicrophoneAudioCapture] Could not drain final audio conversion samples", category: .capture)
        }
    }

    private func emit(_ data: Data) {
        let startSample = sampleClock.emittedFrames
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard !data.isEmpty, let continuityID = sampleClock.continuityID,
              let approximateOrigin = sampleClock.wallOrigin,
              let timestamp = sampleClock.timestampForOutput(frameCount: frameCount) else { return }
        let duration = Double(data.count) / Double(formatConverter.targetSampleRate * MemoryLayout<Int16>.size)
        continuation.yield(CapturedAudio(
            timestamp: timestamp, audioData: data, duration: duration, source: .microphone,
            sampleRate: formatConverter.targetSampleRate, channels: formatConverter.targetChannels,
            sampleIdentity: LiveAudioSampleIdentity(recordingGeneration: recordingGeneration,
                continuityID: continuityID, startSample: startSample, sampleCount: Int64(frameCount),
                sampleRate: formatConverter.targetSampleRate,
                approximateOrigin: approximateOrigin),
            voiceMarkerPlaybackAdmission: RetracePlaybackGate.shared.admission
        ))
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
        guard let input = selectedInput else { return (0, 0) }
        return (input.sampleRate, input.channels)
    }
}
