import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

struct ScreenCaptureStreamKey: Sendable, Equatable {
    let displayID: UInt32
    let displayIdentity: String
    let width: Int
    let height: Int
    let configurationIdentity: String
}

struct ScreenCaptureStreamSnapshot: @unchecked Sendable {
    let image: CGImage
    let nativeTime: CMTime
    let isConfirmedIdle: Bool
}

enum ScreenCaptureStreamError: Error, Equatable {
    case inactive, invalidConfiguration, capacityExceeded, unavailable, timedOut, busy, nativeFailure
}

protocol ScreenCaptureStreamSession: Sendable {
    func start(receive: @escaping @Sendable (CMSampleBuffer) -> Void,
               failed: @escaping @Sendable () -> Void) async throws
    func stop() async throws
}

/// The native boundary is injected; construction never starts a screen read.
actor ScreenCaptureStreamPool {
    private final class Entry: @unchecked Sendable {
        let key: ScreenCaptureStreamKey
        let mailbox: ScreenCaptureStreamMailbox
        let session: any ScreenCaptureStreamSession
        let starting: Task<Void, Error>
        var stopping: (id: UUID, task: Task<Void, Error>)?
        var reading = false

        init(key: ScreenCaptureStreamKey, session: any ScreenCaptureStreamSession) {
            self.key = key; self.session = session
            let mailbox = ScreenCaptureStreamMailbox(width: key.width, height: key.height)
            self.mailbox = mailbox
            starting = Task {
                try await session.start(receive: { mailbox.receive($0) },
                                        failed: { mailbox.close(ScreenCaptureStreamError.nativeFailure) })
            }
        }
    }

    private let maximumDisplays: Int
    private let maximumRetainedBytes: Int
    private var active = false
    private var generation: UInt64 = 0
    private var entries: [UInt32: Entry] = [:]

    init(maximumDisplays: Int = 8, maximumRetainedBytes: Int = 256 * 1024 * 1024) {
        self.maximumDisplays = maximumDisplays; self.maximumRetainedBytes = maximumRetainedBytes
    }

    func beginSession() async throws {
        generation &+= 1
        let admitted = generation
        active = false
        try await drainAll()
        try Task.checkCancellation()
        guard generation == admitted else { throw ScreenCaptureStreamError.inactive }
        active = true
    }

    func stop() async throws {
        active = false; generation &+= 1
        try await drainAll()
    }

    func reconcile(_ displays: [UInt32: String]) async throws {
        let removed = entries.values.filter { displays[$0.key.displayID] != $0.key.displayIdentity }
        for entry in removed { entry.mailbox.close(ScreenCaptureStreamError.inactive) }
        var failure: Error?
        for entry in removed {
            do { try await drain(entry) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    func invalidate(displayID: UInt32) async throws {
        if let entry = entries[displayID] { try await drain(entry) }
    }

    func read(key: ScreenCaptureStreamKey, timeout: Duration = .seconds(3),
              makeSession: @Sendable () -> any ScreenCaptureStreamSession) async throws -> ScreenCaptureStreamSnapshot {
        try Task.checkCancellation()
        guard active else { throw ScreenCaptureStreamError.inactive }
        guard key.displayID > 0, !key.displayIdentity.isEmpty, !key.configurationIdentity.isEmpty,
              key.width > 0, key.height > 0, key.width <= 16_384, key.height <= 16_384,
              key.width * key.height <= 33_554_432, timeout > .zero else {
            throw ScreenCaptureStreamError.invalidConfiguration
        }
        let admitted = generation
        // Compare native display time, not callback arrival time. A delayed
        // callback from before the AX/context bracket cannot become fresh pixels.
        let after = CMClockGetTime(CMClockGetHostTimeClock())
        if let previous = entries[key.displayID], previous.key != key || previous.stopping != nil {
            try await drain(previous)
        }
        guard active, generation == admitted else { throw ScreenCaptureStreamError.inactive }
        try Task.checkCancellation()
        let entry: Entry
        if let current = entries[key.displayID] {
            // A different reader may have installed a new filter while this
            // call joined the previous stop. Never read that caller's pixels.
            guard current.key == key, current.stopping == nil else { throw ScreenCaptureStreamError.busy }
            entry = current
        } else {
            let retained = entries.values.reduce(0) { $0 + $1.key.width * $1.key.height * 4 }
            let required = key.width * key.height * 4
            guard entries.count < maximumDisplays, required <= maximumRetainedBytes,
                  retained <= maximumRetainedBytes - required else { throw ScreenCaptureStreamError.capacityExceeded }
            entry = Entry(key: key, session: makeSession())
            entries[key.displayID] = entry
        }
        guard !entry.reading else { throw ScreenCaptureStreamError.busy }
        entry.reading = true
        defer { entry.reading = false }
        do {
            let snapshot = try await withTaskCancellationHandler {
                // Native start and stop have completion callbacks but no public
                // abort API. Join start even when the requesting task cancels.
                try await entry.starting.value
                try Task.checkCancellation()
                return try await entry.mailbox.next(after: after, timeout: timeout)
            } onCancel: { entry.mailbox.close(CancellationError()) }
            try Task.checkCancellation()
            guard active, generation == admitted, entries[key.displayID] === entry else {
                throw ScreenCaptureStreamError.inactive
            }
            return snapshot
        } catch {
            try await drain(entry)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func drainAll() async throws {
        let retiring = Array(entries.values)
        for entry in retiring { entry.mailbox.close(ScreenCaptureStreamError.inactive) }
        var failure: Error?
        for entry in retiring {
            do { try await drain(entry) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    private func drain(_ entry: Entry) async throws {
        entry.mailbox.close(ScreenCaptureStreamError.inactive)
        let operation: (id: UUID, task: Task<Void, Error>)
        if let stopping = entry.stopping { operation = stopping }
        else {
            let task = Task {
                _ = await entry.starting.result
                try await entry.session.stop()
            }
            operation = (UUID(), task)
            entry.stopping = operation
        }
        do {
            try await operation.task.value
            if entries[entry.key.displayID] === entry { entries.removeValue(forKey: entry.key.displayID) }
        } catch {
            // Retain the session on failure so later stop/start can retry cleanup;
            // releasing a reference is not proof that native capture has stopped.
            if entry.stopping?.id == operation.id { entry.stopping = nil }
            throw error
        }
    }
}

/// Synchronous native callbacks update a single bounded slot. No Task or queue
/// of retained CVPixelBuffers is created per event. Native pixels are copied
/// once into immutable BGRA memory before WindowServer can recycle the buffer.
private final class ScreenCaptureStreamMailbox: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let after: CMTime
        let continuation: CheckedContinuation<ScreenCaptureStreamSnapshot, Error>
    }
    private let lock = NSLock()
    private let width: Int
    private let height: Int
    private var latest: ScreenCaptureStreamSnapshot?
    private var failure: Error?
    private var waiter: Waiter?
    private var nativeTimeFloor: CMTime?

    init(width: Int, height: Int) { self.width = width; self.height = height }

    func receive(_ sample: CMSampleBuffer) {
        guard !lock.withLock({ failure != nil }) else { return }
        guard CMSampleBufferIsValid(sample),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.count == 1,
              let rawStatus = attachments[0][.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            close(ScreenCaptureStreamError.unavailable); return
        }
        if status == .started {
            lock.withLock { latest = nil; nativeTimeFloor = CMClockGetTime(CMClockGetHostTimeClock()) }
            return // A resumed stream needs a new complete frame, not old idle pixels.
        }
        guard let displayTime = attachments[0][.displayTime] as? NSNumber, displayTime.uint64Value > 0 else {
            close(ScreenCaptureStreamError.unavailable); return
        }
        let nativeTime = CMClockMakeHostTimeFromSystemUnits(displayTime.uint64Value)
        guard nativeTime.isValid, nativeTime.isNumeric,
              CMTimeCompare(nativeTime, CMClockGetTime(CMClockGetHostTimeClock())) <= 0 else {
            close(ScreenCaptureStreamError.unavailable); return
        }
        guard lock.withLock({ nativeTimeFloor.map { CMTimeCompare(nativeTime, $0) >= 0 } ?? true }) else { return }
        let image: CGImage?
        switch status {
        case .complete:
            image = Self.copyImage(sample, width: width, height: height)
        case .idle:
            image = lock.withLock { latest?.image }
        default:
            close(ScreenCaptureStreamError.unavailable); return
        }
        guard let image else { close(ScreenCaptureStreamError.unavailable); return }
        let snapshot = ScreenCaptureStreamSnapshot(image: image, nativeTime: nativeTime, isConfirmedIdle: status == .idle)
        let completion: CheckedContinuation<ScreenCaptureStreamSnapshot, Error>? = lock.withLock {
            guard failure == nil else { return nil }
            guard nativeTimeFloor.map({ CMTimeCompare(nativeTime, $0) >= 0 }) ?? true else { return nil }
            guard latest.map({ CMTimeCompare(nativeTime, $0.nativeTime) > 0 }) ?? true else {
                return nil // Out-of-order events never regress the retained proof.
            }
            latest = snapshot
            guard let waiting = waiter, CMTimeCompare(nativeTime, waiting.after) >= 0 else { return nil }
            waiter = nil
            return waiting.continuation
        }
        completion?.resume(returning: snapshot)
    }

    func close(_ error: Error) {
        let completion = lock.withLock { () -> CheckedContinuation<ScreenCaptureStreamSnapshot, Error>? in
            guard failure == nil else { return nil }
            failure = error; latest = nil
            defer { waiter = nil }
            return waiter?.continuation
        }
        completion?.resume(throwing: error)
    }

    func next(after: CMTime, timeout: Duration) async throws -> ScreenCaptureStreamSnapshot {
        try await withThrowingTaskGroup(of: ScreenCaptureStreamSnapshot.self) { group in
            group.addTask { try await self.wait(after: after) }
            group.addTask {
                try await Task.sleep(for: timeout, clock: .continuous)
                throw ScreenCaptureStreamError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ScreenCaptureStreamError.unavailable }
            return result
        }
    }

    private func wait(after: CMTime) async throws -> ScreenCaptureStreamSnapshot {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<ScreenCaptureStreamSnapshot, Error>? = lock.withLock {
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if let failure { return .failure(failure) }
                    if let latest, CMTimeCompare(latest.nativeTime, after) >= 0 { return .success(latest) }
                    guard waiter == nil else { return .failure(ScreenCaptureStreamError.busy) }
                    waiter = Waiter(id: id, after: after, continuation: continuation)
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let continuation = self.lock.withLock { () -> CheckedContinuation<ScreenCaptureStreamSnapshot, Error>? in
                guard self.waiter?.id == id else { return nil }
                defer { self.waiter = nil }
                return self.waiter?.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    private static func copyImage(_ sample: CMSampleBuffer, width: Int, height: Int) -> CGImage? {
        guard let pixels = CMSampleBufferGetImageBuffer(sample), !CVPixelBufferIsPlanar(pixels),
              CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(pixels) == width, CVPixelBufferGetHeight(pixels) == height,
              CVPixelBufferGetBytesPerRow(pixels) >= width * 4,
              CVPixelBufferGetBytesPerRow(pixels) <= 16_384 * 8,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let source = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let bytesPerRow = width * 4, sourceStride = CVPixelBufferGetBytesPerRow(pixels)
        var bytes = Data(count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { destination in
            guard let base = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(base.advanced(by: row * bytesPerRow), source.advanced(by: row * sourceStride), bytesPerRow)
            }
        }
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        let colorSpace: CGColorSpace
        if let attachment = CVBufferCopyAttachment(pixels, kCVImageBufferCGColorSpaceKey, nil),
           CFGetTypeID(attachment) == CGColorSpace.typeID {
            colorSpace = unsafeBitCast(attachment, to: CGColorSpace.self)
        } else { colorSpace = CGColorSpace(name: CGColorSpace.sRGB)! }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// One SCStream, one serial callback queue. Pool ownership serializes start and
/// stop; stop drains callback work before releasing the native output object.
final class NativeScreenCaptureStreamSession: NSObject, ScreenCaptureStreamSession,
                                               SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let queue = DispatchQueue(label: "retrace.capture.screencapturekit", qos: .utility)
    private let callbackLock = NSLock()
    private var receive: (@Sendable (CMSampleBuffer) -> Void)?
    private var failed: (@Sendable () -> Void)?
    private var stoppedByNative = false
    private var stream: SCStream?
    private var started = false
    private var outputAdded = false

    init(filter: SCContentFilter, configuration: SCStreamConfiguration) {
        self.filter = filter; self.configuration = configuration
    }

    func start(receive: @escaping @Sendable (CMSampleBuffer) -> Void,
               failed: @escaping @Sendable () -> Void) async throws {
        // Permission is checked again at actual native start. Never prompt here.
        guard CGPreflightScreenCaptureAccess() else { throw ScreenCaptureStreamError.unavailable }
        callbackLock.withLock { self.receive = receive; self.failed = failed; stoppedByNative = false }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        outputAdded = true
        try await stream.startCapture()
        started = true
    }

    func stop() async throws {
        callbackLock.withLock { receive = nil; failed = nil }
        if let stream {
            if started && !callbackLock.withLock({ stoppedByNative }) { try await stream.stopCapture() }
            started = false
            if outputAdded { try stream.removeStreamOutput(self, type: .screen); outputAdded = false }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async { continuation.resume() }
            }
            self.stream = nil
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        callbackLock.withLock { receive }?(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        callbackLock.withLock { stoppedByNative = true; return failed }?()
    }
}
