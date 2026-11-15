import App
import Database
import Foundation
import Shared
import XCTest
@testable import Retrace

@MainActor
final class TranscriptPublicationGuardTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_800_000_000)

    func testRegularOpenRejectsSourceOrCorrectionAfterReadBeforePublication() async throws {
        for change in [CompanionSpeakerChange.all, .source(.init(.init(targets: [.audioRow(1)]))),
                       .correction(jobID: "changed-job", speakerID: "speaker")] {
            let db = DatabaseManager(databasePath: ":memory:"); try await db.initialize()
            let connection = await db.getConnection()
            let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
            _ = try await queries.insertTranscription(sessionID: nil, text: "Private authored draft",
                startTime: time, endTime: time.addingTimeInterval(1), source: .microphone, confidence: nil, words: [])
            let events = TranscriptPublicationEvents(), hold = TranscriptPublicationHold()
            var presented = 0
            let playback = TranscriptAudioPlayback(resolve: { _ in throw TranscriptAudioError.unavailable }, isMuted: true)
            let controller = TranscriptWindowController(playback: playback, presentWindow: { _ in presented += 1 },
                loadRecordings: { timestamp in
                    let publication = events.guardBeforeRead()
                    var page = try await TranscriptRecordingLoader.load(queries: queries, at: timestamp)
                    await hold.wait()
                    publication.narrow(recordings: page.transcriptions, speakers: [])
                    page.publication = publication
                    return page
                })
            controller.currentTimestampProvider = { self.time }
            let opening = Task { await controller.open(at: time) }
            await hold.waitUntilEntered()
            events.send(change)
            await hold.release(); await opening.value
            XCTAssertEqual(presented, 0)
            XCTAssertNil(controller.window, "The revoked read must not create even a hidden panel")
            XCTAssertFalse(controller.isVisible)
            controller.hide()
            try await db.close()
        }
    }

    func testExactSelectionRejectsChangeAfterItsFinalRead() async throws {
        let events = TranscriptPublicationEvents(), hold = TranscriptPublicationHold()
        let publication = events.guardBeforeRead()
        let row = AudioTranscription(id: 1, sessionID: nil, text: "Exact saved draft", startTime: time,
            endTime: time.addingTimeInterval(1), source: .microphone, confidence: nil, createdAt: time)
        var presented = 0
        let playback = TranscriptAudioPlayback(resolve: { _ in throw TranscriptAudioError.unavailable }, isMuted: true)
        let controller = TranscriptWindowController(playback: playback, presentWindow: { _ in presented += 1 })
        let selection = Task {
            // Represents the final validated row already returned by App's exact reader.
            publication.narrow(recordings: [row], speakers: [])
            await hold.wait()
            try controller.showExactPreparedSearchResult([row], enrichment: nil, publication: publication)
        }
        await hold.waitUntilEntered()
        events.send(.all)
        await hold.release()
        do { try await selection.value; XCTFail("Changed policy must revoke the exact selection") }
        catch { XCTAssertEqual(error as? CompanionError, .staleEvidence) }
        XCTAssertEqual(presented, 0); XCTAssertNil(controller.window)
        controller.hide()
    }

    func testPublicationGuardRetainsObservationAndFiltersOnlyAfterPublication() throws {
        let events = TranscriptPublicationEvents()
        var publication: TranscriptPublicationGuard? = events.guardBeforeRead()
        XCTAssertEqual(events.count, 1)
        publication?.narrow(recordings: [], speakers: [])
        events.send(.source(.indexOnly))
        XCTAssertThrowsError(try publication?.withAdmission {})
        publication = nil
        XCTAssertEqual(events.count, 0)
    }

    func testFailedObservationRegistrationRejectsPublication() {
        for failure in [CompanionError.closed, .capacityExceeded] {
            let publication = TranscriptPublicationGuard(register: { _ in throw failure }, remove: { _ in
                XCTFail("A failed registration has no observation to remove")
            })
            publication.narrow(recordings: [], speakers: [])
            var presented = false
            XCTAssertThrowsError(try publication.withAdmission { presented = true }) { error in
                XCTAssertEqual(error as? CompanionError, .staleEvidence)
            }
            XCTAssertFalse(presented)
        }
    }
}

private final class TranscriptPublicationEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [UUID: @Sendable (CompanionSpeakerChange) -> Void] = [:]
    var count: Int { lock.lock(); defer { lock.unlock() }; return callbacks.count }
    func guardBeforeRead() -> TranscriptPublicationGuard {
        TranscriptPublicationGuard(register: { callback in
            self.lock.lock(); defer { self.lock.unlock() }
            let id = UUID(); self.callbacks[id] = callback; return id
        }, remove: { id in
            self.lock.lock(); defer { self.lock.unlock() }; self.callbacks[id] = nil
        })
    }
    func send(_ change: CompanionSpeakerChange) {
        lock.lock(); let values = Array(callbacks.values); lock.unlock()
        for callback in values { callback(change) }
    }
}

private actor TranscriptPublicationHold {
    private var waiting: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { waiting = $0; entered?.resume(); entered = nil }
    }
    func waitUntilEntered() async {
        if waiting != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { waiting?.resume(); waiting = nil }
}
