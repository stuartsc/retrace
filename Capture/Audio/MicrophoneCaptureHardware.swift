import AVFoundation
import CoreAudio
import Foundation
import Shared

/// Device identity is exact; an unavailable selected UID never permits a different input.
struct MicrophoneInputDevice: Equatable, Sendable {
    let uid: String
    let sampleRate: Double
    let channels: Int
}

/// The external device boundary. Capture ownership and PCM conversion remain in
/// MicrophoneAudioCapture; all native session operations use one background queue.
protocol MicrophoneCaptureHardware: Sendable {
    func defaultInput() async throws -> MicrophoneInputDevice?
    func attach(_ input: MicrophoneInputDevice, delegate: MicAudioDelegate) async throws
    func detach() async
    func startRunning() async
    func isRunning() async -> Bool
    func stopRunning() async
    func observeInputChanges() async throws -> any MicrophoneInputObservation
}

protocol MicrophoneInputObservation: Sendable {
    var events: MicrophoneInputChangeEvents { get }
    func stop() async
}

/// One pending resample, regardless of notification burst size. Reconnect intent
/// is OR-ed separately so coalescing cannot erase a disconnect/reconnect event.
final class MicrophoneInputChangeEvents: @unchecked Sendable {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var active = true
    private var reconnect = false
    private var inputUID: String?

    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
    }

    func signal(reconnect: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        self.reconnect = self.reconnect || reconnect
        continuation.yield(())
    }

    func takeReconnectRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = reconnect
        reconnect = false
        return value
    }

    func signalDeviceChange(uid: String) {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        reconnect = reconnect || uid == inputUID
        continuation.yield(())
    }

    func setInputUID(_ uid: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        if inputUID != uid { reconnect = false }
        inputUID = uid
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        active = false
        reconnect = false
        inputUID = nil
        continuation.finish()
    }
}

final class NativeMicrophoneCaptureHardware: MicrophoneCaptureHardware, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.retrace.mic-session", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "io.retrace.mic-capture", qos: .userInitiated)
    private let session = AVCaptureSession()
    private var output: AVCaptureAudioDataOutput?

    func defaultInput() async throws -> MicrophoneInputDevice? {
        try await perform {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var deviceID = AudioDeviceID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                             &size, &deviceID) == noErr else {
                throw AudioCaptureError.invalidConfiguration("Default microphone lookup failed")
            }
            guard deviceID != kAudioObjectUnknown else { return nil }
            address.mSelector = kAudioDevicePropertyDeviceUID
            // CoreAudio returns a retained CFString for DeviceUID (AudioHardwareBase.h).
            // Receive the C-owned pointer explicitly, then transfer its retain to ARC.
            var result: Unmanaged<CFString>?
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &result) { pointer in
                AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, UnsafeMutableRawPointer(pointer))
            }
            guard status == noErr, let uid = result?.takeRetainedValue(),
                  let device = AVCaptureDevice(uniqueID: uid as String),
                  device.hasMediaType(.audio), device.isConnected else { return nil }
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee
            return MicrophoneInputDevice(uid: uid as String, sampleRate: asbd?.mSampleRate ?? 0,
                                         channels: Int(asbd?.mChannelsPerFrame ?? 0))
        }
    }

    func attach(_ input: MicrophoneInputDevice, delegate: MicAudioDelegate) async throws {
        try await perform {
            guard let device = AVCaptureDevice(uniqueID: input.uid), device.isConnected,
                  device.hasMediaType(.audio) else {
                throw AudioCaptureError.invalidConfiguration("Selected microphone is unavailable")
            }
            let nativeInput = try AVCaptureDeviceInput(device: device)
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }
            guard self.session.canAddInput(nativeInput) else {
                throw AudioCaptureError.invalidConfiguration("Cannot add selected microphone input")
            }
            if self.output == nil {
                let output = AVCaptureAudioDataOutput()
                guard self.session.canAddOutput(output) else {
                    throw AudioCaptureError.invalidConfiguration("Cannot add microphone output")
                }
                self.session.addOutput(output)
                self.output = output
            }
            self.session.addInput(nativeInput)
            self.output?.setSampleBufferDelegate(delegate, queue: self.sampleQueue)
        }
    }

    func detach() async {
        await perform {
            self.output?.setSampleBufferDelegate(nil, queue: nil)
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            self.session.commitConfiguration()
        }
        await drainSamples()
    }

    func startRunning() async { await perform { self.session.startRunning() } }
    func isRunning() async -> Bool { await perform { self.session.isRunning } }

    func stopRunning() async {
        await perform {
            if self.session.isRunning { self.session.stopRunning() }
            self.output?.setSampleBufferDelegate(nil, queue: nil)
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }
            self.session.commitConfiguration()
            self.output = nil
        }
        await drainSamples()
    }

    func observeInputChanges() async throws -> any MicrophoneInputObservation {
        try await perform { try NativeMicrophoneInputObservation(queue: self.queue) }
    }

    private func drainSamples() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async { continuation.resume() }
        }
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}

/// CoreAudio reports default selection changes; AVFoundation reports device
/// availability. Callbacks only coalesce a signal; they never enumerate/open an
/// input, spawn a task, change permissions, or touch the public audio stream.
private final class NativeMicrophoneInputObservation: MicrophoneInputObservation, @unchecked Sendable {
    let events = MicrophoneInputChangeEvents()
    private let queue: DispatchQueue
    private let listener: AudioObjectPropertyListenerBlock
    private var tokens: [NSObjectProtocol] = []
    private var stopped = false // Confined to queue.

    init(queue: DispatchQueue) throws {
        self.queue = queue
        let events = self.events
        listener = { _, _ in events.signal() }
        var address = Self.defaultInputAddress
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                          &address, queue, listener)
        guard status == noErr else {
            events.finish()
            throw AudioCaptureError.captureSessionFailed("Default microphone observer registration failed (\(status))")
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { notification in
                guard let device = notification.object as? AVCaptureDevice, device.hasMediaType(.audio) else { return }
                events.signalDeviceChange(uid: device.uniqueID)
            })
        }
    }

    func stop() async {
        events.finish()
        await withCheckedContinuation { continuation in
            queue.async {
                if !self.stopped {
                    self.stopped = true
                    self.tokens.forEach { NotificationCenter.default.removeObserver($0) }
                    self.tokens.removeAll()
                    var address = Self.defaultInputAddress
                    let status = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                                         &address, self.queue, self.listener)
                    if status != noErr {
                        Log.warning("[MicrophoneAudioCapture] Default input observer removal failed (\(status)); callbacks revoked", category: .capture)
                    }
                }
                continuation.resume()
            }
        }
        // The second queue turn joins callbacks queued before listener removal.
        // A later native callback retains only the already-revoked event buffer.
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
