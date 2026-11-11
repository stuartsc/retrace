import Foundation
import Shared
import XCTest
@testable import Capture

/// Authored observation sequences exercise the production reducer and real
/// AsyncStream lifecycle. Native sources are covered in MeetingNativeEvidenceTests.
final class MeetingDetectorTests: XCTestCase {
    func testSavedAudioConfigurationPreservesConsentAndDefaultsComparisonOff() throws {
        let legacy = Data(#"{"microphoneEnabled":false,"systemAudioEnabled":true,"voiceProcessingEnabled":false,"hasConsentedToMeetingRecording":false,"bufferDurationSeconds":8,"targetSampleRate":16000,"targetChannels":1,"meetingAppBundleIDs":["com.microsoft.teams2"]}"#.utf8)
        let decoded = try JSONDecoder().decode(AudioCaptureConfig.self, from: legacy)
        XCTAssertFalse(decoded.meetingEvidenceComparisonEnabled)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? NSDictionary)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertEqual(encoded.removeValue(forKey: "meetingEvidenceComparisonEnabled") as? Bool, false)
        XCTAssertEqual(encoded as NSDictionary, original, "Default migration must preserve existing recording/consent values")
        var invalid = encoded; invalid["meetingEvidenceComparisonEnabled"] = "true"
        XCTAssertThrowsError(try JSONDecoder().decode(AudioCaptureConfig.self,
            from: JSONSerialization.data(withJSONObject: invalid)))
    }

    func testTeamsPresenceAndProfilePhotoLikeAbsenceOfControlsNeverActivate() throws {
        var reducer = MeetingAssessmentReducer(sessionID: UUID())
        let sample = try persistedSample(observations: [presence()])
        let result = reducer.consume(sample, comparisonEnabled: true, speech: nil)
        XCTAssertEqual(result.phase, .possible)
        XCTAssertNil(result.supportedSince)
        XCTAssertTrue(result.requiresMeetingAudioProtection(at: 101))
        let later = reducer.consume(try persistedSample(observations: [presence(time: 102)], time: 102),
                                    comparisonEnabled: true, speech: nil)
        XCTAssertEqual(result.possibleSince, at(100))
        XCTAssertEqual(later.possibleSince, result.possibleSince)
    }

    func testInputAloneAndGlobalSpeechCannotInventCallOwnership() throws {
        var reducer = MeetingAssessmentReducer(sessionID: UUID())
        let speech = observation(source: .transcriptSpeech, signal: .speech, application: nil,
                                 audioSource: .microphone)
        let result = reducer.consume(try persistedSample(observations: [presence(), input()]),
                                     comparisonEnabled: true, speech: speech)
        XCTAssertEqual(result.phase, .possible)
        XCTAssertTrue(result.observations.contains { $0.source == .transcriptSpeech && $0.application == nil })
        XCTAssertFalse(result.observations.contains { $0.source == .visibleCallControls })
    }

    func testOnlySameProcessFreshControlsAndInputSupportActive() throws {
        var reducer = MeetingAssessmentReducer(sessionID: UUID())
        let first = reducer.consume(try persistedSample(observations: [presence(), controls(), input()]),
                                    comparisonEnabled: true, speech: nil)
        XCTAssertEqual(first.phase, .supportedActive)
        XCTAssertEqual(first.supportedSince, at(100))
        let second = reducer.consume(try persistedSample(observations: [presence(time: 102), controls(time: 102), input(time: 102)],
                                                          time: 102), comparisonEnabled: true, speech: nil)
        XCTAssertEqual(second.phase, .supportedActive)
        XCTAssertEqual(second.supportedSince, first.supportedSince, "Do not reset call evidence time on each poll")
    }

    func testDifferentGenerationSamePIDCannotCorroborate() throws {
        var reducer = MeetingAssessmentReducer(sessionID: UUID())
        let reused = MeetingApplicationIdentity(bundleID: app.bundleID, processID: app.processID, processGeneration: UUID())
        let result = reducer.consume(try persistedSample(observations: [presence(), controls(), input(application: reused)]),
                                     comparisonEnabled: true, speech: nil)
        XCTAssertEqual(result.phase, .possible)
    }

    func testControlsWithoutPolicyOrWindowProofAreRejected() throws {
        for invalid in [observation(source: .visibleCallControls, signal: .inCallControls),
                        observation(source: .visibleCallControls, signal: .inCallControls, windowID: 4,
                                    windowObservationID: UUID(), policy: "malformed")] {
            var reducer = MeetingAssessmentReducer(sessionID: UUID())
            let result = reducer.consume(try persistedSample(observations: [presence(), invalid, input()]),
                                         comparisonEnabled: true, speech: nil)
            XCTAssertEqual(result.phase, .unknown)
            XCTAssertTrue(result.requiresMeetingAudioProtection(at: 101))
        }
    }

    func testExpiredEvidenceNeverBecomesEndedOrReleasesPrivacy() throws {
        var reducer = MeetingAssessmentReducer(sessionID: UUID())
        let active = reducer.consume(try persistedSample(observations: [presence(), controls(), input()]),
                                     comparisonEnabled: true, speech: nil)
        let expired = reducer.expired(at: at(110), uptime: 110)
        XCTAssertEqual(expired.phase, .possible)
        XCTAssertEqual(expired.supportedSince, active.supportedSince)
        XCTAssertNil(expired.endedAt)
        XCTAssertTrue(expired.uncertainties.contains(.stale))
        XCTAssertTrue(expired.requiresMeetingAudioProtection(at: 110))
        XCTAssertTrue(active.requiresMeetingAudioProtection(at: 110))
    }

    func testPrejoinAndIdleCannotEndHiddenCallInAnotherWindow() throws {
        var reducer = MeetingAssessmentReducer(sessionID: UUID())
        _ = reducer.consume(try persistedSample(observations: [presence(), controls(), input()]),
                            comparisonEnabled: true, speech: nil)
        let result = reducer.consume(try persistedSample(observations: [presence(time: 102), controls(signal: .prejoinControls, time: 102),
                                                                        input(signal: .idleInput, time: 102)], time: 102),
                                     comparisonEnabled: true, speech: nil)
        XCTAssertEqual(result.phase, .possible)
        XCTAssertNil(result.endedAt)
        XCTAssertTrue(result.requiresMeetingAudioProtection(at: 103))
    }

    func testAffirmativeProcessEndPreservesEvidenceTimeAndExpires() throws {
        var reducer = MeetingAssessmentReducer(sessionID: UUID())
        _ = reducer.consume(try persistedSample(observations: [presence(), controls(), input()]),
                            comparisonEnabled: true, speech: nil)
        let result = reducer.consume(try persistedSample(observations: [
            observation(source: .applicationInventory, signal: .processEnded, time: 102),
            observation(source: .applicationInventory, signal: .noCandidates, application: nil, time: 102)], time: 102),
                                     comparisonEnabled: true, speech: nil)
        XCTAssertEqual(result.phase, .ended)
        XCTAssertEqual(result.endedAt, at(102))
        XCTAssertEqual(result.supportedSince, at(100))
        XCTAssertFalse(result.requiresMeetingAudioProtection(at: 103))
        XCTAssertTrue(result.requiresMeetingAudioProtection(at: 110))
        let later = reducer.consume(try persistedSample(observations: [observation(source: .applicationInventory,
            signal: .noCandidates, application: nil, time: 104)], time: 104), comparisonEnabled: true, speech: nil)
        XCTAssertEqual(later.phase, .ended)
        XCTAssertEqual(later.endedAt, result.endedAt, "Fresh absence must not rewrite the earlier affirmative end")
        XCTAssertEqual(later.supportedSince, result.supportedSince)
        XCTAssertFalse(later.requiresMeetingAudioProtection(at: 105))
    }

    func testAffirmativeEndIsRetainedWhenReplacementCandidateIsStillPresent() throws {
        var reducer = MeetingAssessmentReducer(sessionID: UUID())
        _ = reducer.consume(try persistedSample(observations: [presence(), controls(), input()]),
                            comparisonEnabled: true, speech: nil)
        let replacement = MeetingApplicationIdentity(bundleID: app.bundleID, processID: app.processID,
                                                     processGeneration: UUID())
        let replaced = reducer.consume(try persistedSample(observations: [
            observation(source: .applicationInventory, signal: .processEnded, time: 102),
            observation(source: .applicationInventory, signal: .present, application: replacement, time: 102)], time: 102),
            comparisonEnabled: true, speech: nil)
        XCTAssertEqual(replaced.phase, .possible)
        XCTAssertEqual(replaced.application, replacement)
        XCTAssertNil(reducer.terminationTarget, "Affirmative lifetime end is consumed even while another candidate remains")
        let absent = reducer.consume(try persistedSample(observations: [observation(source: .applicationInventory,
            signal: .noCandidates, application: nil, time: 104)], time: 104), comparisonEnabled: true, speech: nil)
        XCTAssertEqual(absent.phase, .ended)
        XCTAssertEqual(absent.application, app)
        XCTAssertEqual(absent.endedAt, at(102), "A one-shot PID replacement receipt must survive later absence")
        XCTAssertEqual(absent.supportedSince, at(100))
    }

    func testUnknownInventoryAndComparisonDisabledRemainConservative() throws {
        var reducer = MeetingAssessmentReducer(sessionID: UUID())
        let disabled = reducer.consume(try persistedSample(observations: [presence(), controls(), input()]),
                                       comparisonEnabled: false, speech: nil)
        XCTAssertEqual(disabled.phase, .possible)
        XCTAssertTrue(disabled.uncertainties.contains(.comparisonDisabled))
        let unknown = reducer.consume(try persistedSample(observations: [observation(source: .applicationInventory,
            signal: .unavailable, application: nil, uncertainty: .nativeUnavailable)]), comparisonEnabled: true, speech: nil)
        XCTAssertEqual(unknown.phase, .unknown)
        XCTAssertTrue(unknown.requiresMeetingAudioProtection(at: 101))
    }

    func testMalformedLargeFutureAndReversedObservationsFailClosed() throws {
        let reversed = MeetingObservation(interval: CaptureReadInterval(startedAt: at(101), endedAt: at(100),
            startedUptime: 101, endedUptime: 100), source: .applicationInventory, signal: .present, application: app)
        for observations in [[reversed], [presence(time: 200)], Array(repeating: presence(), count: 65),
                             [presence(), observation(source: .applicationInventory, signal: .noCandidates, application: nil)]] {
            var reducer = MeetingAssessmentReducer(sessionID: UUID())
            let result = reducer.consume(try persistedSample(observations: observations), comparisonEnabled: true, speech: nil)
            XCTAssertEqual(result.phase, .unknown)
            XCTAssertTrue(result.requiresMeetingAudioProtection(at: 101))
        }
    }

    func testPrivacyGateDropsActualStreamWhenStateExpiresButNeverChangesAudioConsent() async throws {
        var reducer = MeetingAssessmentReducer(sessionID: UUID())
        let idle = reducer.consume(try persistedSample(observations: [observation(source: .applicationInventory,
            signal: .noCandidates, application: nil)]), comparisonEnabled: true, speech: nil)
        let state = MeetingState(assessment: idle)
        let noConsent = AudioCaptureConfig(systemAudioEnabled: true)
        let consent = AudioCaptureConfig(systemAudioEnabled: true, hasConsentedToMeetingRecording: true)
        let pair = AsyncStream<CapturedAudio>.makeStream()
        let audio = CapturedAudio(timestamp: at(100), audioData: Data([0, 0, 1, 0]), duration: 0.000125,
                                  source: .system, sampleRate: 16_000, channels: 1)
        pair.continuation.yield(audio); pair.continuation.finish()
        var received = 0
        for await sample in pair.stream {
            XCTAssertFalse(sample.audioData.isEmpty)
            if MeetingAudioPrivacyPolicy.permitsSystemAudio(state: state, config: noConsent, uptime: 110) { received += 1 }
        }
        XCTAssertEqual(received, 0)
        XCTAssertTrue(MeetingAudioPrivacyPolicy.permitsSystemAudio(state: state, config: noConsent, uptime: 101))
        XCTAssertTrue(MeetingAudioPrivacyPolicy.permitsSystemAudio(state: state, config: consent, uptime: 110))
        XCTAssertFalse(MeetingAudioPrivacyPolicy.permitsSystemAudio(state: state, config: .default, uptime: 101))
        XCTAssertFalse(MeetingAudioPrivacyPolicy.permitsSystemAudio(state: .notInMeeting, config: noConsent, uptime: 101),
                       "The old bool initializer does not carry fresh negative evidence")
    }

    func testStopJoinsHeldNativeReadAndRejectsItsLateActiveObservation() async throws {
        let channel = MeetingSampleChannel()
        let detector = MeetingDetector(environment: .init(sample: { _, _, _ in await channel.next() },
            reset: {}, sleep: { try await Task.sleep(for: .seconds(60), clock: .continuous) },
            date: { at(100) }, uptime: { 100 }))
        await detector.setComparisonEnabled(true)
        let recorder = MeetingStateRecorder()
        await detector.onStateChangeAsync { await recorder.append($0) }
        await detector.startMonitoring(bundleIDs: [app.bundleID])
        await channel.waitUntilRead()
        let stopped = Task { await detector.stopMonitoring() }
        await channel.waitUntilCancelled()
        await channel.release(try persistedSample(observations: [presence(), controls(), input()]))
        await stopped.value
        XCTAssertFalse(detector.isMeetingActive())
        let values = await recorder.values
        XCTAssertFalse(values.contains { $0.isInMeeting })
        let count = values.count
        await detector.stopMonitoring()
        let finalCount = await recorder.values.count
        XCTAssertEqual(finalCount, count, "Joined stop is idempotent; no orphan callback after completion")
    }

    func testCallbackDeliveryIsAwaitedAndNoOverlappingNativeReads() async throws {
        let channel = MeetingSampleChannel()
        let detector = MeetingDetector(environment: .init(sample: { _, _, _ in await channel.next() }, reset: {},
            sleep: { try await Task.sleep(for: .seconds(60), clock: .continuous) }, date: { at(100) }, uptime: { 100 }))
        await detector.setComparisonEnabled(true)
        let delivered = expectation(description: "owned callback")
        await detector.onStateChangeAsync { state in if state.isInMeeting { delivered.fulfill() } }
        await detector.startMonitoring(bundleIDs: [app.bundleID])
        await channel.waitUntilRead()
        await channel.release(try persistedSample(observations: [presence(), controls(), input()]))
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertTrue(detector.isMeetingActive())
        await detector.stopMonitoring()
        let maximum = await channel.maximumActiveReads
        XCTAssertEqual(maximum, 1)
    }

    func testComparisonChangeJoinsAwaitedMetricDeliveryBeforeStartingNextGeneration() async throws {
        let channel = MeetingSampleChannel()
        let outcomeEntered = expectation(description: "active outcome entered")
        let outcomeCancelled = expectation(description: "old outcome cancellation observed")
        let heldOutcome = MeetingHeldOutcome(entered: { outcomeEntered.fulfill() },
                                             cancelled: { outcomeCancelled.fulfill() })
        let absent = try persistedSample(observations: [observation(source: .applicationInventory,
            signal: .noCandidates, application: nil)])
        let detector = MeetingDetector(environment: .init(sample: { _, enabled, _ in
            enabled ? await channel.next() : absent
        }, reset: {}, sleep: { try await Task.sleep(for: .seconds(60), clock: .continuous) },
            date: { at(100) }, uptime: { 100 }))
        await detector.setComparisonEnabled(true)
        await detector.setOutcomeHandler { outcome in
            if outcome.phase == .supportedActive { await heldOutcome.receive() }
        }
        await detector.startMonitoring(bundleIDs: [app.bundleID])
        await channel.waitUntilRead()
        await channel.release(try persistedSample(observations: [presence(), controls(), input()]))
        await fulfillment(of: [outcomeEntered], timeout: 5)
        let change = Task { await detector.setComparisonEnabled(false) }
        await fulfillment(of: [outcomeCancelled], timeout: 5)
        let beforeRelease = await heldOutcome.completed
        XCTAssertFalse(beforeRelease, "The actual pending delivery remains owned across cancellation")
        await heldOutcome.release()
        await change.value
        XCTAssertFalse(detector.isMeetingActive())
        let delivered = await heldOutcome.completed
        XCTAssertTrue(delivered, "Comparison ACK must join the preceding metric callback")
        await detector.stopMonitoring()
    }

    func testComparisonOnlyManagerChangePreservesConfigurationAndRunningStream() async throws {
        // Neither source is enabled: this exercises the real coordinator/stream
        // without opening a microphone, tap, capture device, or user window.
        let configuration = AudioCaptureConfig(microphoneEnabled: false, systemAudioEnabled: false,
            voiceProcessingEnabled: true, hasConsentedToMeetingRecording: true,
            bufferDurationSeconds: 3.5, targetSampleRate: 48_000, targetChannels: 2,
            meetingAppBundleIDs: ["owned.fixture.meeting"])
        let manager = AudioCaptureManager(config: configuration)
        try await manager.startCapture(config: configuration)
        addTeardownBlock { try await manager.stopCapture() }
        let started = await manager.getStatistics().captureStartTime
        let originalStream = await manager.audioStream
        let completed = expectation(description: "original combined stream completes on stop")
        let draining = Task { for await _ in originalStream {} ; completed.fulfill() }
        for enabled in [true, false] {
            await manager.setMeetingEvidenceComparisonEnabled(enabled)
            let actual = await manager.getConfig()
            var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(actual)) as? [String: Any])
            XCTAssertEqual(encoded.removeValue(forKey: "meetingEvidenceComparisonEnabled") as? Bool, enabled)
            var expected = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
            expected.removeValue(forKey: "meetingEvidenceComparisonEnabled")
            XCTAssertEqual(encoded as NSDictionary, expected as NSDictionary)
            let capturing = await manager.isCapturing
            let stillStarted = await manager.getStatistics().captureStartTime
            XCTAssertTrue(capturing)
            XCTAssertEqual(stillStarted, started, "A comparison-only change must not restart either audio stream")
        }
        try await manager.stopCapture()
        await fulfillment(of: [completed], timeout: 5)
        await draining.value
    }

    func testStaleSpeechArrivalDoesNotRefreshItsOccurrenceOrActivate() throws {
        var reducer = MeetingAssessmentReducer(sessionID: UUID())
        let staleSpeech = observation(source: .transcriptSpeech, signal: .speech, application: nil,
                                      audioSource: .system, time: 100,
                                      occurrence: MeetingAudioOccurrence(startedAt: at(0), endedAt: at(1)))
        let result = reducer.consume(try persistedSample(observations: [presence()]), comparisonEnabled: true, speech: staleSpeech)
        XCTAssertEqual(result.phase, .possible)
        XCTAssertFalse(result.observations.contains { $0.id == staleSpeech.id })
    }

    func testSpeechOccurrenceBoundsAndExplicitGlobalScopeAreAdmittedBeforeReduction() {
        let valid = observation(source: .audioEnergy, signal: .speechLikeEnergy, application: nil,
                                audioSource: .microphone)
        XCTAssertTrue(MeetingObservationAdmission.validSpeech(valid, now: 100, date: at(100)))
        for occurrence in [MeetingAudioOccurrence(startedAt: at(101), endedAt: at(102)),
                           MeetingAudioOccurrence(startedAt: at(99), endedAt: at(98)),
                           MeetingAudioOccurrence(startedAt: at(0), endedAt: at(100))] {
            let invalid = observation(source: .transcriptSpeech, signal: .speech, application: nil,
                audioSource: .microphone, occurrence: occurrence)
            XCTAssertFalse(MeetingObservationAdmission.validSpeech(invalid, now: 100, date: at(100)))
        }
        let falselyOwned = observation(source: .transcriptSpeech, signal: .speech, audioSource: .system)
        XCTAssertFalse(MeetingObservationAdmission.validSpeech(falselyOwned, now: 100, date: at(100)))
    }
}

private let app = MeetingApplicationIdentity(bundleID: "com.microsoft.teams2", processID: 7319,
    processGeneration: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
private func at(_ uptime: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + uptime) }
private func observation(source: MeetingSignalSource, signal: MeetingSignal,
                         application: MeetingApplicationIdentity? = app, windowID: UInt32? = nil,
                         windowObservationID: UUID? = nil, policy: String? = nil, audioSource: AudioSource? = nil,
                         time: Double = 100, uncertainty: MeetingUncertainty? = nil,
                         occurrence: MeetingAudioOccurrence? = nil) -> MeetingObservation {
    MeetingObservation(interval: CaptureReadInterval(startedAt: at(time), endedAt: at(time),
        startedUptime: time, endedUptime: time), source: source, signal: signal, application: application,
        windowID: windowID, windowObservationID: windowObservationID, capturePolicySHA256: policy,
        audioSource: audioSource,
        audioOccurrence: audioSource == nil ? nil : (occurrence ?? MeetingAudioOccurrence(startedAt: at(time - 1), endedAt: at(time))),
        uncertainty: uncertainty)
}
private func presence(time: Double = 100) -> MeetingObservation {
    observation(source: .applicationInventory, signal: .present, time: time)
}
private func input(signal: MeetingSignal = .runningInput, application: MeetingApplicationIdentity = app,
                   time: Double = 100) -> MeetingObservation {
    observation(source: .coreAudioProcessInput, signal: signal, application: application, time: time)
}
private func controls(signal: MeetingSignal = .inCallControls, time: Double = 100) -> MeetingObservation {
    observation(source: .visibleCallControls, signal: signal, windowID: 42,
                windowObservationID: UUID(), policy: String(repeating: "a", count: 64), time: time)
}
private func persistedSample(observations: [MeetingObservation], time: Double = 100) throws -> MeetingSample {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-meeting-observation-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("authored-observations.json")
    try JSONEncoder().encode(observations).write(to: url, options: .atomic)
    let retained = try JSONDecoder().decode([MeetingObservation].self, from: Data(contentsOf: url))
    return MeetingSample(observations: retained, observedAt: at(time), observedUptime: time,
                         candidateCount: observations.filter { $0.signal == .present }.count, controlsVisited: 0)
}

private actor MeetingStateRecorder {
    var values: [MeetingState] = []
    func append(_ state: MeetingState) { values.append(state) }
}
private actor MeetingSampleChannel {
    private let pair = AsyncStream<MeetingSample>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private let cancellations = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var active = 0
    private(set) var maximumActiveReads = 0
    func next() async -> MeetingSample {
        active += 1; maximumActiveReads = max(maximumActiveReads, active)
        readWaiters.forEach { $0.resume() }; readWaiters.removeAll()
        let stream = pair.stream
        // The private native-boundary substitute deliberately ignores parent
        // cancellation until released, like an already-entered native call.
        let cancel = cancellations.continuation
        let result = await withTaskCancellationHandler {
            await Task.detached { var iterator = stream.makeAsyncIterator(); return await iterator.next() }.value
        } onCancel: { cancel.yield(()) }
        active -= 1
        return result ?? MeetingSample(observations: [], observedAt: at(100), observedUptime: 100,
                                       candidateCount: 0, controlsVisited: 0)
    }
    func waitUntilRead() async {
        if active > 0 { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }
    func release(_ sample: MeetingSample) { pair.continuation.yield(sample) }
    func waitUntilCancelled() async {
        var iterator = cancellations.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

private actor MeetingHeldOutcome {
    private let entered: @Sendable () -> Void
    private let cancelled: @Sendable () -> Void
    private let releaseSignal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private(set) var completed = false
    init(entered: @escaping @Sendable () -> Void, cancelled: @escaping @Sendable () -> Void) {
        self.entered = entered; self.cancelled = cancelled
    }
    func receive() async {
        entered()
        let stream = releaseSignal.stream, cancellation = cancelled
        await withTaskCancellationHandler {
            await Task.detached { var iterator = stream.makeAsyncIterator(); _ = await iterator.next() }.value
        } onCancel: { cancellation() }
        completed = true
    }
    func release() { releaseSignal.continuation.yield(()) }
}
