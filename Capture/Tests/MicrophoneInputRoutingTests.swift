import AVFoundation
import CoreMedia
import XCTest
import Shared
@testable import Capture

/// Only device enumeration and session calls are controlled. Routing, stream
/// ownership, CoreMedia PCM buffers and native resampling are the production path.
final class MicrophoneInputRoutingTests: XCTestCase {
    func testDefaultChangeKeepsStreamAndDrainsEachNativeFormatExactlyOnce() async throws {
        let hardware = RoutingHardware()
        let capture = MicrophoneAudioCapture(config: .default, hardware: hardware)
        let stream = await capture.audioStream
        let collected = Task { var values: [CapturedAudio] = []; for await value in stream { values.append(value) }; return values }
        try await capture.startCapture()
        let oldValue = await hardware.currentDelegate
        let oldDelegate = try XCTUnwrap(oldValue)
        let oldPCM = try tone(rate: 44_100, frames: 44_100, frequency: 440)
        oldDelegate.receive(try sampleBuffer(oldPCM), receivedAt: Date(timeIntervalSince1970: 100))

        let switched = expectation(description: "Studio Display selected after macOS default changes")
        await hardware.setDefault(.studio, onAttach: { switched.fulfill() })
        await hardware.signalChange()
        await fulfillment(of: [switched], timeout: 1)
        let newValue = await hardware.currentDelegate
        let newDelegate = try XCTUnwrap(newValue)
        XCTAssertFalse(oldDelegate === newDelegate)
        let newPCM = try tone(rate: 48_000, frames: 48_000, frequency: 880)
        newDelegate.receive(try sampleBuffer(newPCM), receivedAt: Date(timeIntervalSince1970: 200))
        // A native callback retained before detachment must not enter the new route.
        oldDelegate.receive(try sampleBuffer(oldPCM), receivedAt: Date(timeIntervalSince1970: 300))
        await capture.stopCapture()
        let values = await collected.value
        let expectedOld = try converted(oldPCM)
        let expectedNew = try converted(newPCM)
        XCTAssertEqual(values.reduce(into: Data()) { $0.append($1.audioData) }, expectedOld + expectedNew)
        XCTAssertEqual(values.first?.timestamp, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(values.first(where: { $0.timestamp.timeIntervalSince1970 >= 200 })?.timestamp,
                       Date(timeIntervalSince1970: 200))
        XCTAssertEqual(values.reduce(0) { $0 + $1.duration }, 2, accuracy: 0.000001)
        let facts = await hardware.facts
        XCTAssertEqual(facts.attached, ["built-in", "studio"])
        XCTAssertEqual(facts.starts, 1, "A route change must not restart the capture session")
        XCTAssertEqual(facts.stops, 1)
    }

    func testUnavailableDefaultKeepsStreamOpenAndNextDeviceEventRecovers() async throws {
        let hardware = RoutingHardware()
        let capture = MicrophoneAudioCapture(config: .default, hardware: hardware)
        let idle = await capture.runtimeState()
        XCTAssertEqual(idle, .paused)
        let idleFacts = await hardware.facts
        XCTAssertEqual(idleFacts.starts, 0, "Reading runtime must not open a native session")
        try await capture.startCapture()
        let running = await capture.runtimeState()
        XCTAssertEqual(running, .running)
        let stream = await capture.audioStream
        let ended = expectation(description: "Stream remains open during input loss")
        ended.isInverted = true
        let consumer = Task { for await _ in stream {}; ended.fulfill() }
        let detached = expectation(description: "Unavailable default detaches old input")
        await hardware.setDefault(nil, onDetach: { detached.fulfill() })
        await hardware.signalChange()
        await fulfillment(of: [detached], timeout: 1)
        let unavailable = await capture.runtimeState()
        XCTAssertEqual(unavailable, .unavailable, "A session without its selected input cannot report running")
        await fulfillment(of: [ended], timeout: 0.05)
        let recovered = expectation(description: "A newly available selected input recovers")
        await hardware.setDefault(.studio, onAttach: { recovered.fulfill() })
        await hardware.signalDeviceChange(uid: MicrophoneInputDevice.studio.uid)
        await fulfillment(of: [recovered], timeout: 1)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await capture.runtimeState() != .running, ContinuousClock.now < deadline { await Task.yield() }
        let resumed = await capture.runtimeState()
        XCTAssertEqual(resumed, .running)
        await capture.stopCapture()
        let stopped = await capture.runtimeState()
        XCTAssertEqual(stopped, .paused)
        await consumer.value
        let facts = await hardware.facts
        XCTAssertEqual(facts.attached, ["built-in", "studio"])
        XCTAssertEqual(facts.starts, 1)
    }

    func testFailedReplacementRetriesSameUIDOnNextEventWithoutFallback() async throws {
        let hardware = RoutingHardware()
        let capture = MicrophoneAudioCapture(config: .default, hardware: hardware)
        try await capture.startCapture()
        let failed = expectation(description: "The selected input open fails")
        await hardware.failNextAttach(to: .studio, onAttempt: { failed.fulfill() })
        await hardware.signalChange()
        await fulfillment(of: [failed], timeout: 1)
        let retried = expectation(description: "Same default UID is retried after failure")
        await hardware.setDefault(.studio, onAttach: { retried.fulfill() })
        await hardware.signalChange()
        await fulfillment(of: [retried], timeout: 1)
        let facts = await hardware.facts
        XCTAssertEqual(facts.attachAttempts, ["built-in", "studio", "studio"])
        XCTAssertEqual(facts.attached, ["built-in", "studio"])
        await capture.stopCapture()
    }

    func testStopFencesHeldDefaultReadAndJoinsBeforeFinishingStream() async throws {
        let hardware = RoutingHardware()
        let capture = MicrophoneAudioCapture(config: .default, hardware: hardware)
        try await capture.startCapture()
        let stream = await capture.audioStream
        let oldValue = await hardware.currentDelegate
        let oldDelegate = try XCTUnwrap(oldValue)
        let entered = expectation(description: "Default input resolution is suspended")
        let readGate = RoutingGate()
        await hardware.holdNextRead(readGate, entered: { entered.fulfill() })
        await hardware.setDefault(.studio)
        await hardware.signalChange()
        await fulfillment(of: [entered], timeout: 1)
        let observationStopped = expectation(description: "Stop revokes native observation first")
        await hardware.onObservationStop { observationStopped.fulfill() }
        let prematureStop = expectation(description: "Stop must join in-flight input resolution")
        prematureStop.isInverted = true
        let stopping = Task { await capture.stopCapture(); prematureStop.fulfill() }
        await fulfillment(of: [observationStopped], timeout: 1)
        oldDelegate.receive(try sampleBuffer(tone(rate: 48_000, frames: 48_000, frequency: 440)),
                            receivedAt: Date(timeIntervalSince1970: 400))
        await hardware.signalChange(reconnect: true)
        await fulfillment(of: [prematureStop], timeout: 0.05)
        await readGate.release()
        await stopping.value
        var values: [CapturedAudio] = []
        for await value in stream { values.append(value) }
        XCTAssertTrue(values.isEmpty, "Callbacks after pause cannot publish while stop joins native work")
        let facts = await hardware.facts
        XCTAssertEqual(facts.attached, ["built-in"], "Held stale device resolution cannot reconnect after stop")
        XCTAssertEqual(facts.stops, 1)
        XCTAssertEqual(facts.observationStops, 1)
    }

    func testStopJoinsHeldAttachAndLateCallbackCannotPublishOrRestart() async throws {
        let hardware = RoutingHardware()
        let capture = MicrophoneAudioCapture(config: .default, hardware: hardware)
        try await capture.startCapture()
        let stream = await capture.audioStream
        let gate = RoutingGate()
        let entered = expectation(description: "Native input attach is suspended")
        await hardware.holdNextAttach(gate, entered: { entered.fulfill() })
        await hardware.setDefault(.studio)
        await hardware.signalChange()
        await fulfillment(of: [entered], timeout: 1)
        let delegateValue = await hardware.currentDelegate
        let lateDelegate = try XCTUnwrap(delegateValue)
        let observerStopped = expectation(description: "Observation stopped")
        await hardware.onObservationStop { observerStopped.fulfill() }
        let earlyStop = expectation(description: "Stop waits for attach completion")
        earlyStop.isInverted = true
        let stop = Task { await capture.stopCapture(); earlyStop.fulfill() }
        await fulfillment(of: [observerStopped], timeout: 1)
        lateDelegate.receive(try sampleBuffer(tone(rate: 48_000, frames: 48_000, frequency: 880)), receivedAt: Date())
        await fulfillment(of: [earlyStop], timeout: 0.05)
        await gate.release()
        await stop.value
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 0)
        let facts = await hardware.facts
        XCTAssertEqual(facts.starts, 1)
        XCTAssertEqual(facts.stops, 1)
    }

    func testStopDuringNativeStartCancelsStartupAndAllowsCleanRestart() async throws {
        let hardware = RoutingHardware()
        let capture = MicrophoneAudioCapture(config: .default, hardware: hardware)
        let stream = await capture.audioStream
        let gate = RoutingGate()
        let entered = expectation(description: "Native start is suspended")
        await hardware.holdNextStart(gate, entered: { entered.fulfill() })
        let start = Task { try await capture.startCapture() }
        await fulfillment(of: [entered], timeout: 1)
        let observerStopped = expectation(description: "Startup observation revoked")
        await hardware.onObservationStop { observerStopped.fulfill() }
        let earlyStop = expectation(description: "Stop joins native startup")
        earlyStop.isInverted = true
        let stop = Task { await capture.stopCapture(); earlyStop.fulfill() }
        await fulfillment(of: [observerStopped], timeout: 1)
        await fulfillment(of: [earlyStop], timeout: 0.05)
        await gate.release()
        await stop.value
        do { try await start.value; XCTFail("Stopped startup returned success") } catch is CancellationError {}
        for await _ in stream { XCTFail("Stopped startup produced audio") }

        await hardware.setDefault(.studio)
        try await capture.startCapture()
        let fresh = await capture.audioStream
        await hardware.signalOldObservation()
        let value = await hardware.currentDelegate
        try XCTUnwrap(value).receive(try sampleBuffer(tone(rate: 48_000, frames: 48_000, frequency: 880)), receivedAt: Date())
        await capture.stopCapture()
        var bytes = 0
        for await audio in fresh { bytes += audio.audioData.count }
        XCTAssertEqual(bytes, 32_000)
        let facts = await hardware.facts
        XCTAssertEqual(facts.attached, ["built-in", "studio"])
        XCTAssertEqual(facts.observationStops, 2)
    }

    func testFailedNativeStartClosesPreacquiredStreamAndStopsObservation() async throws {
        let hardware = RoutingHardware()
        await hardware.setStartResult(false)
        let capture = MicrophoneAudioCapture(config: .default, hardware: hardware)
        let stream = await capture.audioStream
        do { try await capture.startCapture(); XCTFail("Native start failure returned success") }
        catch AudioCaptureError.captureSessionFailed {}
        for await _ in stream { XCTFail("Failed start produced audio") }
        let facts = await hardware.facts
        XCTAssertEqual(facts.stops, 1)
        XCTAssertEqual(facts.observationStops, 1)
    }

    func testUnavailableInitialInputFailsWithoutChoosingAnotherDevice() async throws {
        let hardware = RoutingHardware()
        await hardware.setDefault(nil)
        let capture = MicrophoneAudioCapture(config: .default, hardware: hardware)
        let stream = await capture.audioStream
        do { try await capture.startCapture(); XCTFail("Missing selected input returned success") }
        catch AudioCaptureError.invalidConfiguration {}
        for await _ in stream { XCTFail("Unavailable input produced audio") }
        let facts = await hardware.facts
        XCTAssertEqual(facts.attached, [])
        XCTAssertEqual(facts.starts, 0)
        XCTAssertEqual(facts.observationStops, 1)
    }

    func testReconnectOfSameUIDReplacesDelegateAndResetsPrimedSamples() async throws {
        let hardware = RoutingHardware()
        let capture = MicrophoneAudioCapture(config: .default, hardware: hardware)
        try await capture.startCapture()
        let oldValue = await hardware.currentDelegate
        let old = try XCTUnwrap(oldValue)
        old.receive(try sampleBuffer(tone(rate: 48_000, frames: 1, frequency: 440)),
                    receivedAt: Date(timeIntervalSince1970: 100))
        let reattached = expectation(description: "Same UID reconnect refreshes native input")
        await hardware.setDefault(.builtIn, onAttach: { reattached.fulfill() })
        await hardware.signalDeviceChange(uid: MicrophoneInputDevice.builtIn.uid)
        await fulfillment(of: [reattached], timeout: 1)
        let newValue = await hardware.currentDelegate
        XCTAssertFalse(old === newValue)
        let stream = await capture.audioStream
        let pcm = try tone(rate: 48_000, frames: 48_000, frequency: 880)
        try XCTUnwrap(newValue).receive(try sampleBuffer(pcm), receivedAt: Date(timeIntervalSince1970: 200))
        await capture.stopCapture()
        var current = Data()
        for await value in stream where value.timestamp.timeIntervalSince1970 >= 200 { current.append(value.audioData) }
        XCTAssertEqual(current, try converted(pcm), "Old priming state must never leak into replacement input")
    }

    func testTenThousandNotificationsCoalesceWithoutRestartingUnchangedInput() async throws {
        let hardware = RoutingHardware()
        let capture = MicrophoneAudioCapture(config: .default, hardware: hardware)
        try await capture.startCapture()
        let gate = RoutingGate()
        let entered = expectation(description: "One route read holds the notification burst")
        await hardware.holdNextRead(gate, entered: { entered.fulfill() })
        await hardware.signalChange()
        await fulfillment(of: [entered], timeout: 1)
        await hardware.signalBurst(count: 10_000)
        let lastRead = expectation(description: "Latest pending change is observed")
        await hardware.onNextRead { lastRead.fulfill() }
        await gate.release()
        await fulfillment(of: [lastRead], timeout: 1)
        await capture.stopCapture()
        let facts = await hardware.facts
        XCTAssertEqual(facts.reads, 3, "One initial read, one held read and one coalesced read")
        XCTAssertEqual(facts.attached, ["built-in"])
        XCTAssertEqual(facts.starts, 1)
    }

    func testEventBufferPreservesReconnectIntentAndClosesAgainstLateCallbacks() async throws {
        let events = MicrophoneInputChangeEvents()
        events.setInputUID("selected")
        events.signalDeviceChange(uid: "selected")
        events.setInputUID("selected")
        for _ in 0..<10_000 { events.signal() }
        XCTAssertTrue(events.takeReconnectRequest())
        XCTAssertFalse(events.takeReconnectRequest())
        events.finish()
        events.signalDeviceChange(uid: "selected")
        events.setInputUID("selected")
        var count = 0
        for await _ in events.stream { count += 1 }
        XCTAssertEqual(count, 1)
        XCTAssertFalse(events.takeReconnectRequest())
    }

    func testNativeDefaultInputObserverCanBeRegisteredAndJoinedWithoutOpeningDevices() async throws {
        let hardware = NativeMicrophoneCaptureHardware()
        let observation = try await hardware.observeInputChanges()
        await observation.stop()
        await observation.stop()
        observation.events.signal(reconnect: true)
        var count = 0
        for await _ in observation.events.stream { count += 1 }
        XCTAssertLessThanOrEqual(count, 1, "Only a coalesced event accepted before stop may remain")
        let running = await hardware.isRunning()
        XCTAssertFalse(running)
    }

    func testUnrelatedDeviceEventRechecksDefaultWithoutReplacingHealthyInput() async throws {
        let hardware = RoutingHardware()
        let capture = MicrophoneAudioCapture(config: .default, hardware: hardware)
        try await capture.startCapture()
        let original = await hardware.currentDelegate
        let read = expectation(description: "Device event rechecks current default")
        let detached = expectation(description: "Unrelated device must not detach selected input")
        detached.isInverted = true
        await hardware.onNextRead { read.fulfill() }
        await hardware.setDefault(.builtIn, onDetach: { detached.fulfill() })
        await hardware.signalDeviceChange(uid: "unused-headset")
        await fulfillment(of: [read], timeout: 1)
        await fulfillment(of: [detached], timeout: 0.1)
        let current = await hardware.currentDelegate
        XCTAssertTrue(original === current)
        let facts = await hardware.facts
        XCTAssertEqual(facts.attached, ["built-in"])
        await capture.stopCapture()
    }

    func testLaterPauseCancelsRestartQueuedBehindHeldStop() async throws {
        let hardware = RoutingHardware()
        let capture = MicrophoneAudioCapture(config: .default, hardware: hardware)
        try await capture.startCapture()
        let gate = RoutingGate()
        let enteredStop = expectation(description: "First native stop is held")
        await hardware.holdNextStop(gate, entered: { enteredStop.fulfill() })
        let firstStop = Task { await capture.stopCapture() }
        await fulfillment(of: [enteredStop], timeout: 1)
        let queued = expectation(description: "Restart enters the microphone actor while stop is held")
        let restart = Task { try await capture.startReportingEntry { queued.fulfill() } }
        await fulfillment(of: [queued], timeout: 1)
        let secondEntered = expectation(description: "Later pause enters the actor")
        let secondStop = Task { await capture.stopReportingEntry { secondEntered.fulfill() } }
        await fulfillment(of: [secondEntered], timeout: 1)
        await gate.release()
        await firstStop.value
        await secondStop.value
        do { try await restart.value; XCTFail("A later pause must cancel the queued restart") }
        catch is CancellationError {}
        let facts = await hardware.facts
        let running = await hardware.isRunning()
        XCTAssertEqual(facts.starts, 1)
        XCTAssertEqual(facts.observationStops, 1)
        XCTAssertFalse(running, "The latest stop must not leave an unowned recording session")
        await capture.stopCapture()
    }

    func testRestartAfterJoinedStopGetsItsOwnJoinedTeardown() async throws {
        let hardware = RoutingHardware()
        let capture = MicrophoneAudioCapture(config: .default, hardware: hardware)
        try await capture.startCapture()
        let firstGate = RoutingGate()
        let firstEntered = expectation(description: "Old native stop is held")
        await hardware.holdNextStop(firstGate, entered: { firstEntered.fulfill() })
        let oldStop = Task { await capture.stopCapture() }
        await fulfillment(of: [firstEntered], timeout: 1)
        let queued = expectation(description: "Replacement waits on old stop")
        let newStartGate = RoutingGate()
        let newStarted = expectation(description: "Replacement entered its own native startup")
        await hardware.holdNextStart(newStartGate, entered: { newStarted.fulfill() })
        let restart = Task { try await capture.startReportingEntry { queued.fulfill() } }
        await fulfillment(of: [queued], timeout: 1)
        await firstGate.release()
        await fulfillment(of: [newStarted], timeout: 1)
        let observedStop = expectation(description: "Replacement observation is revoked")
        await hardware.onObservationStop { observedStop.fulfill() }
        let earlyReturn = expectation(description: "New stop must join new startup")
        earlyReturn.isInverted = true
        let newStop = Task { await capture.stopCapture(); earlyReturn.fulfill() }
        await fulfillment(of: [observedStop], timeout: 1)
        await fulfillment(of: [earlyReturn], timeout: 0.05)
        await newStartGate.release()
        await newStop.value
        await oldStop.value
        do { try await restart.value; XCTFail("Replacement cancelled by pause returned success") }
        catch is CancellationError {}
        let facts = await hardware.facts
        let running = await hardware.isRunning()
        XCTAssertEqual(facts.stops, 2)
        XCTAssertEqual(facts.observationStops, 2)
        XCTAssertFalse(running)
    }

    func testConcurrentStartsShareOneNativeStartupAndReportCapturedInputFormat() async throws {
        let hardware = RoutingHardware()
        let capture = MicrophoneAudioCapture(config: .default, hardware: hardware)
        let gate = RoutingGate()
        let entered = expectation(description: "First native startup is held")
        await hardware.holdNextStart(gate, entered: { entered.fulfill() })
        let first = Task { try await capture.startCapture() }
        await fulfillment(of: [entered], timeout: 1)
        let joined = expectation(description: "Second caller enters the same startup")
        let second = Task { try await capture.startReportingEntry { joined.fulfill() } }
        await fulfillment(of: [joined], timeout: 1)
        await gate.release()
        try await first.value
        try await second.value
        try await capture.startCapture()
        await hardware.setDefault(.studio) // No change event has been delivered yet.
        let format = await capture.getInputFormat()
        let voiceProcessing = await capture.isVoiceProcessingEnabled()
        XCTAssertEqual(format.sampleRate, 44_100, "Report the opened input, not a newer unhandled default")
        XCTAssertEqual(format.channels, 1)
        XCTAssertFalse(voiceProcessing)
        let facts = await hardware.facts
        XCTAssertEqual(facts.starts, 1)
        XCTAssertEqual(facts.attached, ["built-in"])
        await capture.stopCapture()
        let stoppedFormat = await capture.getInputFormat()
        XCTAssertEqual(stoppedFormat.sampleRate, 0)
        XCTAssertEqual(stoppedFormat.channels, 0)
    }

    func testCancelledStartupJoinsNativeWorkAndClosesItsStream() async throws {
        let hardware = RoutingHardware()
        let capture = MicrophoneAudioCapture(config: .default, hardware: hardware)
        let stream = await capture.audioStream
        let gate = RoutingGate()
        let entered = expectation(description: "Native startup held before cancellation")
        await hardware.holdNextStart(gate, entered: { entered.fulfill() })
        let start = Task { try await capture.startCapture() }
        await fulfillment(of: [entered], timeout: 1)
        start.cancel()
        await gate.release()
        do { try await start.value; XCTFail("Cancelled startup returned success") }
        catch is CancellationError {}
        for await _ in stream { XCTFail("Cancelled startup published audio") }
        let facts = await hardware.facts
        let running = await hardware.isRunning()
        XCTAssertEqual(facts.observationStops, 1)
        XCTAssertEqual(facts.stops, 1)
        XCTAssertFalse(running)
    }

    func testFailedDefaultReadDetachesUncertainInputAndRecoversOnNextEvent() async throws {
        let hardware = RoutingHardware()
        let capture = MicrophoneAudioCapture(config: .default, hardware: hardware)
        try await capture.startCapture()
        let detached = expectation(description: "Lookup failure detaches uncertain selected input")
        await hardware.setDefault(.builtIn, onDetach: { detached.fulfill() })
        await hardware.failNextDefaultRead()
        await hardware.signalChange()
        await fulfillment(of: [detached], timeout: 1)
        let recovered = expectation(description: "Same selected input retries after lookup recovery")
        await hardware.setDefault(.builtIn, onAttach: { recovered.fulfill() })
        await hardware.signalChange()
        await fulfillment(of: [recovered], timeout: 1)
        await capture.stopCapture()
        let facts = await hardware.facts
        XCTAssertEqual(facts.attached, ["built-in", "built-in"])
        XCTAssertEqual(facts.starts, 1)
    }

    func testFailedObservationRegistrationClosesStreamWithoutOpeningInput() async throws {
        let hardware = RoutingHardware()
        await hardware.failObservationRegistration()
        let capture = MicrophoneAudioCapture(config: .default, hardware: hardware)
        let stream = await capture.audioStream
        do { try await capture.startCapture(); XCTFail("Unobserved startup returned success") }
        catch AudioCaptureError.captureSessionFailed {}
        for await _ in stream { XCTFail("Unobserved startup produced audio") }
        let facts = await hardware.facts
        XCTAssertEqual(facts.starts, 0)
        XCTAssertEqual(facts.reads, 0)
        XCTAssertEqual(facts.attached, [])
        XCTAssertEqual(facts.stops, 1)
    }

    func testConfigurationRestartHonoursLaterPause() async throws {
        let hardware = RoutingHardware()
        let capture = MicrophoneAudioCapture(config: .default, hardware: hardware)
        try await capture.startCapture()
        let gate = RoutingGate()
        let entered = expectation(description: "Configuration stop is held")
        await hardware.holdNextStop(gate, entered: { entered.fulfill() })
        let update = Task { try await capture.updateConfig(.default) }
        await fulfillment(of: [entered], timeout: 1)
        let paused = expectation(description: "Later explicit pause enters")
        let stop = Task { await capture.stopReportingEntry { paused.fulfill() } }
        await fulfillment(of: [paused], timeout: 1)
        await gate.release()
        try await update.value
        await stop.value
        try await capture.updateConfig(.default)
        var facts = await hardware.facts
        XCTAssertEqual(facts.starts, 1, "Neither a superseded update nor a paused update may resume recording")
        try await capture.startCapture()
        try await capture.updateConfig(.default)
        facts = await hardware.facts
        XCTAssertEqual(facts.starts, 3, "An active configuration update still performs its explicit restart")
        await capture.stopCapture()
    }

    private func tone(rate: Double, frames: Int, frequency: Double) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                                channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<frames { samples[index] = Float(0.4 * sin(2 * .pi * frequency * Double(index) / rate)) }
        return buffer
    }

    private func converted(_ buffer: AVAudioPCMBuffer) throws -> Data {
        let converter = AudioFormatConverter()
        return try converter.convert(buffer: buffer) + converter.finish()
    }

    private func sampleBuffer(_ pcm: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: pcm.format.formatDescription,
            sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let result = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(result), noErr)
        return result
    }
}

private extension MicrophoneInputDevice {
    static let builtIn = Self(uid: "built-in", sampleRate: 44_100, channels: 1)
    static let studio = Self(uid: "studio", sampleRate: 48_000, channels: 1)
}

private extension MicrophoneAudioCapture {
    // The acknowledgement and lifecycle call run in one actor turn until the
    // production method's first suspension, making queued-intent order explicit.
    func startReportingEntry(_ entered: @Sendable () -> Void) async throws { entered(); try await startCapture() }
    func stopReportingEntry(_ entered: @Sendable () -> Void) async { entered(); await stopCapture() }
}

private actor RoutingGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
}

private final class RoutingObservation: MicrophoneInputObservation, @unchecked Sendable {
    let events = MicrophoneInputChangeEvents()
    let stopped: @Sendable () async -> Void
    init(stopped: @escaping @Sendable () async -> Void) { self.stopped = stopped }
    func stop() async { events.finish(); await stopped() }
}

private actor RoutingHardware: MicrophoneCaptureHardware {
    struct Facts { var attached: [String] = []; var attachAttempts: [String] = []; var starts = 0; var stops = 0; var observationStops = 0; var reads = 0 }
    var facts = Facts()
    var currentDelegate: MicAudioDelegate?
    private var selected: MicrophoneInputDevice? = .builtIn
    private var observation: RoutingObservation?
    private var oldObservation: RoutingObservation?
    private var running = false
    private var attachCallback: (@Sendable () -> Void)?
    private var detachCallback: (@Sendable () -> Void)?
    private var stopObservationCallback: (@Sendable () -> Void)?
    private var failAttach = false
    private var readGate: RoutingGate?
    private var readEntered: (@Sendable () -> Void)?
    private var nextRead: (@Sendable () -> Void)?
    private var attachGate: RoutingGate?
    private var attachEntered: (@Sendable () -> Void)?
    private var startGate: RoutingGate?
    private var startEntered: (@Sendable () -> Void)?
    private var startResult = true
    private var stopGate: RoutingGate?
    private var stopEntered: (@Sendable () -> Void)?
    private var failRead = false
    private var failObservation = false

    func defaultInput() async throws -> MicrophoneInputDevice? {
        facts.reads += 1
        let callback = nextRead; nextRead = nil; callback?()
        if failRead { failRead = false; throw AudioCaptureError.invalidConfiguration("Authored default-read failure") }
        if let gate = readGate { readGate = nil; readEntered?(); readEntered = nil; await gate.wait() }
        return selected
    }
    func attach(_ input: MicrophoneInputDevice, delegate: MicAudioDelegate) async throws {
        facts.attachAttempts.append(input.uid)
        let callback = attachCallback; attachCallback = nil
        if failAttach { failAttach = false; callback?(); throw AudioCaptureError.invalidConfiguration("Authored input-open failure") }
        currentDelegate = delegate
        facts.attached.append(input.uid)
        if let gate = attachGate { attachGate = nil; attachEntered?(); attachEntered = nil; await gate.wait() }
        callback?()
    }
    func detach() async { currentDelegate = nil; let callback = detachCallback; detachCallback = nil; callback?() }
    func startRunning() async {
        facts.starts += 1
        if let gate = startGate { startGate = nil; startEntered?(); startEntered = nil; await gate.wait() }
        running = startResult
    }
    func isRunning() async -> Bool { running }
    func stopRunning() async {
        facts.stops += 1
        if let gate = stopGate { stopGate = nil; stopEntered?(); stopEntered = nil; await gate.wait() }
        running = false; currentDelegate = nil
    }
    func observeInputChanges() async throws -> any MicrophoneInputObservation {
        if failObservation { throw AudioCaptureError.captureSessionFailed("Authored observer-registration failure") }
        let new = RoutingObservation { [weak self] in await self?.didStopObservation() }
        oldObservation = observation
        observation = new
        return new
    }
    private func didStopObservation() { facts.observationStops += 1; stopObservationCallback?(); stopObservationCallback = nil }
    func onObservationStop(_ callback: @escaping @Sendable () -> Void) { stopObservationCallback = callback }
    func setDefault(_ input: MicrophoneInputDevice?, onAttach: (@Sendable () -> Void)? = nil,
                    onDetach: (@Sendable () -> Void)? = nil) {
        selected = input; attachCallback = onAttach; detachCallback = onDetach
    }
    func signalChange(reconnect: Bool = false) { observation?.events.signal(reconnect: reconnect) }
    func signalBurst(count: Int) { for _ in 0..<count { observation?.events.signal() } }
    func signalDeviceChange(uid: String) { observation?.events.signalDeviceChange(uid: uid) }
    func signalOldObservation() { oldObservation?.events.signal(reconnect: true) }
    func onNextRead(_ callback: @escaping @Sendable () -> Void) { nextRead = callback }
    func setStartResult(_ value: Bool) { startResult = value }
    func failNextDefaultRead() { failRead = true }
    func failObservationRegistration() { failObservation = true }
    func failNextAttach(to input: MicrophoneInputDevice, onAttempt: @escaping @Sendable () -> Void) {
        selected = input; failAttach = true; attachCallback = onAttempt
    }
    func holdNextRead(_ gate: RoutingGate, entered: @escaping @Sendable () -> Void) { readGate = gate; readEntered = entered }
    func holdNextAttach(_ gate: RoutingGate, entered: @escaping @Sendable () -> Void) { attachGate = gate; attachEntered = entered }
    func holdNextStart(_ gate: RoutingGate, entered: @escaping @Sendable () -> Void) { startGate = gate; startEntered = entered }
    func holdNextStop(_ gate: RoutingGate, entered: @escaping @Sendable () -> Void) { stopGate = gate; stopEntered = entered }
}
