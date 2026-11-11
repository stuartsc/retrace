import Database
import Foundation
import Shared
import SQLCipher
import XCTest
@testable import App
@testable import Capture

final class MeetingIntegrationTests: XCTestCase {
    func testPostCommitBridgeIsAdmittedByRealDetectorWithoutInventingCallOwnership() async throws {
        let received = expectation(description: "Global transcript signal retained by detector")
        let app = MeetingApplicationIdentity(bundleID: "test.owned.transcript-process",
            processID: ProcessInfo.processInfo.processIdentifier, processGeneration: UUID())
        let detector = MeetingDetector(environment: .init(sample: { _, _, _ in
            let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
            let interval = CaptureReadInterval(startedAt: now, endedAt: now,
                startedUptime: uptime, endedUptime: uptime)
            return MeetingSample(observations: [.init(interval: interval, source: .applicationInventory,
                signal: .present, application: app)], observedAt: now, observedUptime: uptime,
                candidateCount: 1, controlsVisited: 0)
        }, reset: {}, sleep: { try await Task.sleep(for: .milliseconds(20)) },
            date: { Date() }, uptime: { ProcessInfo.processInfo.systemUptime }))
        addTeardownBlock { await detector.stopMonitoring() }
        let sink = MeetingBridgeStateSink(received: received)
        await detector.onStateChangeAsync { await sink.observe($0) }
        await detector.startMonitoring(bundleIDs: [app.bundleID])
        let ended = Date().addingTimeInterval(-1)
        let receipt = AudioTranscriptCommitReceipt(startedAt: ended.addingTimeInterval(-2), endedAt: ended,
            source: .microphone, acceptedTranscription: true)
        await MeetingIntegration.observe(receipt) { await detector.observeSpeech($0) }
        await fulfillment(of: [received], timeout: 5)
        let observed = await sink.retained()
        let retained = try XCTUnwrap(observed)
        XCTAssertEqual(retained.phase, .possible, "Global transcript speech cannot corroborate an active call")
        let speech = try XCTUnwrap(retained.observations.first { $0.source == .transcriptSpeech })
        XCTAssertNil(speech.application)
        XCTAssertTrue(speech.evidence.isEmpty)
        XCTAssertEqual(speech.audioOccurrence?.endedAt, ended, "Delivery cannot refresh original audio time")
        await MeetingIntegration.observe(.init(startedAt: ended.addingTimeInterval(-90),
            endedAt: ended.addingTimeInterval(-80), source: .microphone, acceptedTranscription: true)) { _ in
                XCTFail("Old transcription must never be delivered as current speech")
            }
        await detector.stopMonitoring()
    }

    func testMeetingOutcomePersistsOnlyBoundedCategoriesInSQLite() async throws {
        let database = DatabaseManager(databasePath: "file:meeting-metrics-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        addTeardownBlock { try? await database.close() }
        await MeetingIntegration.record(.init(phase: .possible, comparisonEnabled: true,
            uncertainties: [.noCorroboration], candidateCount: 1, controlsVisited: 8,
            elapsedMilliseconds: 12), database: database)
        await MeetingIntegration.record(.init(phase: .unknown, comparisonEnabled: true,
            uncertainties: [], candidateCount: -1, controlsVisited: Int.max,
            elapsedMilliseconds: .nan), database: database)
        let rows = try await database.meetingMetricRows()
        XCTAssertEqual(rows.count, 2)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rows[0].utf8)) as? [String: Any])
        XCTAssertEqual(value["phase"] as? String, "possible")
        XCTAssertEqual(Set(value.keys), Set(["phase", "comparisonEnabled", "uncertainties", "candidateCount", "controlsVisited", "elapsedMilliseconds"]))
        XCTAssertEqual(rows[1], "{\"outcome\":\"invalidMeasurement\"}")
    }

    func testPrivateContainerComparisonTogglePreservesAudioAndDoesNotStartRecording() async throws {
        let services = ServiceContainer(inMemory: true)
        let before = await services.audioCapture.getConfig()
        await services.audioCapture.setMeetingEvidenceComparisonEnabled(true)
        let after = await services.audioCapture.getConfig()
        XCTAssertTrue(after.meetingEvidenceComparisonEnabled)
        XCTAssertEqual(after.microphoneEnabled, before.microphoneEnabled)
        XCTAssertEqual(after.systemAudioEnabled, before.systemAudioEnabled)
        XCTAssertEqual(after.hasConsentedToMeetingRecording, before.hasConsentedToMeetingRecording)
        let capturing = await services.audioCapture.isCapturing
        XCTAssertFalse(capturing)
        let state = await services.audioCapture.getMeetingState()
        XCTAssertFalse(state.isInMeeting, "A comparison switch cannot manufacture an active call")
    }
}

private actor MeetingBridgeStateSink {
    let received: XCTestExpectation
    private var first: MeetingAssessment?
    init(received: XCTestExpectation) { self.received = received }
    func observe(_ state: MeetingState) {
        guard first == nil, let assessment = state.assessment,
              assessment.observations.contains(where: { $0.source == .transcriptSpeech }) else { return }
        first = assessment; received.fulfill()
    }
    func retained() -> MeetingAssessment? { first }
}

private extension DatabaseManager {
    func meetingMetricRows() throws -> [String] {
        let db = try XCTUnwrap(getConnection())
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT metadata FROM daily_metrics WHERE metricType='meeting_assessment' ORDER BY rowid", -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryPreparationFailed("Private meeting metrics query")
        }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { rows.append(String(cString: text)) }
        }
        return rows
    }
}
