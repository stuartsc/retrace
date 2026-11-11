import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import XCTest
#if !RETRACE_STREAM_STANDALONE
@testable import Capture
#endif

final class ScreenCaptureStreamPoolTests: XCTestCase {
    func testConstructionIsInertAndStoppedPoolCannotStartNativeWork() async throws {
        let native = StreamNativeFixture()
        let pool = ScreenCaptureStreamPool()
        await assertStreamError(.inactive) { try await pool.read(key: self.key()) { native } }
        XCTAssertEqual(native.starts, 0)
        try await pool.stop()
        XCTAssertEqual(native.stops, 0)
    }

    func testNativeBGRACompleteThenIdleReuseOneImmutableImage() async throws {
        let native = StreamNativeFixture()
        let pool = ScreenCaptureStreamPool()
        try await pool.beginSession()
        native.onStart = { try native.send(status: .complete, blue: 47) }
        let first = try await pool.read(key: key()) { native }
        XCTAssertFalse(first.isConfirmedIdle)
        XCTAssertEqual(first.image.width, 4)
        XCTAssertEqual(first.image.height, 2)
        XCTAssertEqual(first.image.dataProvider?.data as Data?, Data(repeating: 47, count: 32))
        let second = Task { try await pool.read(key: key(), timeout: .seconds(1)) { native } }
        try await Task.sleep(for: .milliseconds(30))
        try native.send(status: .idle)
        let idle = try await second.value
        XCTAssertTrue(idle.isConfirmedIdle)
        XCTAssertTrue(first.image === idle.image, "Idle proof must reuse the immutable complete frame")
        XCTAssertTrue(CMTimeCompare(idle.nativeTime, first.nativeTime) > 0)
        XCTAssertEqual(native.starts, 1)
        try await pool.stop()
        XCTAssertEqual(native.stops, 1)
    }

    func testOldCallbackAndMissingEventsCannotInventCurrentPixels() async throws {
        let native = StreamNativeFixture()
        let pool = ScreenCaptureStreamPool()
        try await pool.beginSession()
        let earlier = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 1, preferredTimescale: 1_000_000))
        native.onStart = { try native.send(status: .complete, time: earlier) }
        await assertStreamError(.timedOut) {
            try await pool.read(key: self.key(), timeout: .milliseconds(40)) { native }
        }
        XCTAssertEqual(native.stops, 1, "A timed-out stream must release native capture before returning")
        try await pool.stop()
    }

    func testIdleWithoutCompleteAndBlankCannotReuseAnImage() async throws {
        for status in [SCFrameStatus.idle, .blank, .suspended, .stopped] {
            let native = StreamNativeFixture()
            let pool = ScreenCaptureStreamPool()
            try await pool.beginSession()
            native.onStart = { try native.send(status: status) }
            await assertStreamError(.unavailable) { try await pool.read(key: self.key()) { native } }
            XCTAssertEqual(native.stops, 1)
            try await pool.stop()
        }
    }

    func testStartedIsNotAPixelProofAndWaitsForACompleteFrame() async throws {
        let native = StreamNativeFixture()
        let pool = ScreenCaptureStreamPool()
        try await pool.beginSession()
        native.onStart = {
            try native.send(status: .started)
            try native.send(status: .complete, blue: 18)
        }
        let snapshot = try await pool.read(key: key()) { native }
        XCTAssertFalse(snapshot.isConfirmedIdle)
        XCTAssertEqual(snapshot.image.dataProvider?.data as Data?, Data(repeating: 18, count: 32))
        try await pool.stop()
    }

    func testDelayedPreStartFrameCannotSeedLaterIdleReuse() async throws {
        let native = StreamNativeFixture()
        let beforeRestart = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()),
                                           CMTime(seconds: 1, preferredTimescale: 1_000_000))
        native.onStart = {
            try native.send(status: .started)
            try native.send(status: .complete, blue: 99, time: beforeRestart)
            try native.send(status: .idle)
        }
        let pool = ScreenCaptureStreamPool()
        try await pool.beginSession()
        await assertStreamError(.unavailable) { try await pool.read(key: self.key()) { native } }
        try await pool.stop()
    }

    func testPixelGeometryAndMissingStatusFailClosed() async throws {
        for invalidGeometry in [true, false] {
            let native = StreamNativeFixture()
            let pool = ScreenCaptureStreamPool()
            try await pool.beginSession()
            native.onStart = { native.deliver(try StreamNativeFixture.sample(status: invalidGeometry ? .complete : nil,
                                                                           width: invalidGeometry ? 3 : 4)) }
            await assertStreamError(.unavailable) { try await pool.read(key: self.key()) { native } }
            try await pool.stop()
        }
    }

    func testFilterChangeStopsOldStreamBeforeReplacementAndCannotReuseOldIdle() async throws {
        let old = StreamNativeFixture(), new = StreamNativeFixture()
        let pool = ScreenCaptureStreamPool()
        try await pool.beginSession()
        old.onStart = { try old.send(status: .complete) }
        _ = try await pool.read(key: key()) { old }
        new.onStart = {
            XCTAssertEqual(old.stops, 1)
            try new.send(status: .idle)
        }
        await assertStreamError(.unavailable) { try await pool.read(key: self.key(configuration: "new policy")) { new } }
        XCTAssertEqual(old.stops, 1)
        XCTAssertEqual(new.stops, 1)
        try await pool.stop()
    }

    func testNativeFailureJoinsCleanupAndRestartDoesNotReuseEarlierPixels() async throws {
        let failed = StreamNativeFixture(), restarted = StreamNativeFixture()
        let pool = ScreenCaptureStreamPool()
        try await pool.beginSession()
        failed.onStart = { failed.fail() }
        await assertStreamError(.nativeFailure) { try await pool.read(key: self.key()) { failed } }
        XCTAssertEqual(failed.stops, 1)
        restarted.onStart = { try restarted.send(status: .complete, blue: 9) }
        let result = try await pool.read(key: key()) { restarted }
        XCTAssertFalse(result.isConfirmedIdle)
        try await pool.stop()
        XCTAssertEqual(restarted.stops, 1)
    }

    func testStopCancelsWaitingReadAndJoinsHeldNativeStart() async throws {
        let entered = expectation(description: "native start entered")
        let gate = StreamFixtureGate()
        let native = StreamNativeFixture()
        native.startGate = gate
        native.onStart = { entered.fulfill() }
        let pool = ScreenCaptureStreamPool()
        try await pool.beginSession()
        let reading = Task { try await pool.read(key: key()) { native } }
        await fulfillment(of: [entered], timeout: 1)
        let stopping = Task { try await pool.stop() }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(native.stops, 0, "Stop must join the native start before stopping its stream")
        await gate.release()
        try await stopping.value
        do { _ = try await reading.value; XCTFail("Stopped read returned pixels") } catch {}
        XCTAssertEqual(native.stops, 1)
    }

    func testCancellationReleasesNativeStreamAndDoesNotCancelAnotherDisplay() async throws {
        let first = StreamNativeFixture(), second = StreamNativeFixture()
        let entered = expectation(description: "read started")
        first.onStart = { entered.fulfill() }
        second.onStart = { try second.send(status: .complete) }
        let pool = ScreenCaptureStreamPool()
        try await pool.beginSession()
        _ = try await pool.read(key: key(displayID: 43)) { second }
        let reading = Task { try await pool.read(key: key()) { first } }
        await fulfillment(of: [entered], timeout: 1)
        reading.cancel()
        do { _ = try await reading.value; XCTFail("Cancelled read returned pixels") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(first.stops, 1)
        XCTAssertEqual(second.stops, 0)
        try await pool.stop()
        XCTAssertEqual(second.stops, 1)
    }

    func testAttachmentRemovalAndResourceBoundsStopOnlyAffectedStreams() async throws {
        let first = StreamNativeFixture(), second = StreamNativeFixture(), third = StreamNativeFixture()
        first.onStart = { try first.send(status: .complete) }
        second.onStart = { try second.send(status: .complete) }
        let pool = ScreenCaptureStreamPool(maximumDisplays: 2, maximumRetainedBytes: 64)
        try await pool.beginSession()
        _ = try await pool.read(key: key()) { first }
        _ = try await pool.read(key: key(displayID: 43)) { second }
        await assertStreamError(.capacityExceeded) { try await pool.read(key: self.key(displayID: 44)) { third } }
        XCTAssertEqual(third.starts, 0)
        try await pool.reconcile([43: "attached"])
        XCTAssertEqual(first.stops, 1)
        XCTAssertEqual(second.stops, 0)
        try await pool.reconcile([43: "replacement display"])
        XCTAssertEqual(second.stops, 1)
        try await pool.stop()
    }

    func testInvalidDimensionsDoNotStartNativeCapture() async throws {
        let native = StreamNativeFixture()
        let pool = ScreenCaptureStreamPool()
        try await pool.beginSession()
        for width in [0, -1, Int.max, 16_385] {
            await assertStreamError(.invalidConfiguration) {
                try await pool.read(key: ScreenCaptureStreamKey(displayID: 42, displayIdentity: "attached", width: width,
                    height: 2, configurationIdentity: "policy")) { native }
            }
        }
        XCTAssertEqual(native.starts, 0)
        try await pool.stop()
    }

    func testFailedStopRetainsNativeOwnershipUntilCleanupRetry() async throws {
        let native = StreamNativeFixture()
        native.stopFailures = 1
        native.onStart = { try native.send(status: .complete) }
        let pool = ScreenCaptureStreamPool()
        try await pool.beginSession()
        _ = try await pool.read(key: key()) { native }
        do { try await pool.stop(); XCTFail("Native cleanup failure was hidden") }
        catch { XCTAssertEqual(error as? ScreenCaptureStreamError, .nativeFailure) }
        XCTAssertEqual(native.stops, 1)
        try await pool.beginSession()
        XCTAssertEqual(native.stops, 2, "A new session must join cleanup of the failed old session first")
        try await pool.stop()
    }

    func testFutureDisplayTimeAndZeroReadTimeoutFailClosed() async throws {
        let native = StreamNativeFixture()
        native.onStart = {
            try native.send(status: .complete, time: CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()),
                                                              CMTime(seconds: 10, preferredTimescale: 1_000_000)))
        }
        let pool = ScreenCaptureStreamPool()
        try await pool.beginSession()
        await assertStreamError(.invalidConfiguration) { try await pool.read(key: self.key(), timeout: .zero) { native } }
        XCTAssertEqual(native.starts, 0)
        await assertStreamError(.unavailable) { try await pool.read(key: self.key()) { native } }
        XCTAssertEqual(native.stops, 1)
        try await pool.stop()
    }

    func testParallelReadCannotCreateASecondStreamForTheSameDisplay() async throws {
        let native = StreamNativeFixture()
        let entered = expectation(description: "first read entered")
        native.onStart = { entered.fulfill() }
        let pool = ScreenCaptureStreamPool()
        try await pool.beginSession()
        let reading = Task { try await pool.read(key: key()) { native } }
        await fulfillment(of: [entered], timeout: 1)
        await assertStreamError(.busy) { try await pool.read(key: self.key()) { native } }
        XCTAssertEqual(native.starts, 1)
        reading.cancel()
        _ = await reading.result
        try await pool.stop()
    }

    private func key(displayID: UInt32 = 42, configuration: String = "policy") -> ScreenCaptureStreamKey {
        ScreenCaptureStreamKey(displayID: displayID, displayIdentity: "attached", width: 4, height: 2,
                               configurationIdentity: configuration)
    }

    private func assertStreamError(_ expected: ScreenCaptureStreamError,
        operation: () async throws -> ScreenCaptureStreamSnapshot,
        file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? ScreenCaptureStreamError, expected, file: file, line: line) }
    }
}

private actor StreamFixtureGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { if !released { await withCheckedContinuation { waiter = $0 } } }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private final class StreamNativeFixture: ScreenCaptureStreamSession, @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (starts: 0, stops: 0)
    private var receiver: (@Sendable (CMSampleBuffer) -> Void)?
    private var failure: (@Sendable () -> Void)?
    var onStart: (@Sendable () throws -> Void)?
    var startGate: StreamFixtureGate?
    var stopFailures = 0
    var starts: Int { lock.withLock { counts.starts } }
    var stops: Int { lock.withLock { counts.stops } }
    func start(receive: @escaping @Sendable (CMSampleBuffer) -> Void, failed: @escaping @Sendable () -> Void) async throws {
        lock.withLock { counts.starts += 1; receiver = receive; failure = failed }
        try onStart?()
        await startGate?.wait()
    }
    func stop() async throws {
        try lock.withLock {
            counts.stops += 1
            if stopFailures > 0 { stopFailures -= 1; throw ScreenCaptureStreamError.nativeFailure }
            receiver = nil; failure = nil
        }
    }
    func fail() { lock.withLock { failure }?() }
    func deliver(_ sample: CMSampleBuffer) { lock.withLock { receiver }?(sample) }
    func send(status: SCFrameStatus, blue: UInt8 = 1, time: CMTime? = nil) throws {
        deliver(try Self.sample(status: status, blue: blue, time: time))
    }

    static func sample(status: SCFrameStatus? = .complete, width: Int = 4,
                       blue: UInt8 = 1, time: CMTime? = nil) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, 2, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), Int32(blue), CVPixelBufferGetBytesPerRow(pixels) * 2)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixels, formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: time ?? CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
            formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        let result = try XCTUnwrap(sample)
        let array = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true))
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
        if let status {
            let number = status.rawValue as CFNumber
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(SCStreamFrameInfo.status.rawValue as CFString).toOpaque(),
                                 Unmanaged.passUnretained(number).toOpaque())
        }
        let displayed = NSNumber(value: CMClockConvertHostTimeToSystemUnits(timing.presentationTimeStamp))
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(SCStreamFrameInfo.displayTime.rawValue as CFString).toOpaque(),
                             Unmanaged.passUnretained(displayed).toOpaque())
        return result
    }
}
