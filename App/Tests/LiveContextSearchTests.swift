import Database
import Foundation
import Shared
import Storage
import XCTest
@testable import App

final class LiveContextSearchTests: XCTestCase {
    func testSelectedTurnCopyKeepsOriginalSeparateAndRejectsRevocationDuringCollection() async throws {
        let reader = LiveCopyTurnReader()
        let fixture = try await Fixture.make(turn: { try await reader.resolve($0) })
        let native = try await fixture.database.activityStoreID(), time = fixture.time
        let identity = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(), startSample: 32_000,
            sampleCount: 16_000, sampleRate: 16_000, approximateOrigin: time)
        let reference = CompanionTurnReference(nativeStoreID: native, jobID: String(repeating: "a", count: 64),
            resultSHA256: String(repeating: "b", count: 64), turnIndex: 0, correctionRevision: nil)
        let turn = CompanionSpeakerTurn(start: 2, end: 3, text: "Selected turn words", speakerID: reference.jobID + ":cluster:1",
            speakerLabel: "Speaker 1", speakerStatus: .unknown)
        let presentation = CompanionTurnPresentation(reference: reference, turn: turn, sourceIdentity: identity,
            displayLabel: "Speaker 1", speakerStatus: .anonymous, firstPassText: "Full original first pass",
            firstPassSourceIdentity: identity, firstPassReferences: [])
        await reader.set(presentation)
        let copy = try await fixture.service.copy(references: [.speakerTurn(reference)], interval: .init(start: time, duration: 10), partial: false)
        XCTAssertTrue(copy.text.contains("Speaker 1: Selected turn words"))
        XCTAssertTrue(copy.text.contains("Approximate wall interval"))
        XCTAssertTrue(copy.text.contains("32000..<48000"))
        XCTAssertTrue(copy.text.contains("Retained first pass — full original recording"))
        XCTAssertTrue(copy.text.contains("Full original first pass"))
        await reader.revokeAfterNextResolution()
        do {
            _ = try await fixture.service.copy(references: [.speakerTurn(reference)], interval: .init(start: time, duration: 10), partial: false)
            XCTFail("A correction or source revocation between preview reads must reject the whole copy")
        } catch { XCTAssertEqual(error as? CompanionError, .staleEvidence) }
        try await fixture.close()
    }

    func testSearchPagesEverySourceAndCopyRejectsEditedNotesAndDeletedAudio() async throws {
        let fixture = try await Fixture.make()
        let time = fixture.time, db = fixture.database, audio = fixture.audio
        let segment = try await db.insertSegment(bundleID: "com.fixture.budget", startDate: time,
            endDate: time.addingTimeInterval(4), windowName: "Budget review", browserUrl: nil, type: 0)
        let metadata = FrameMetadata(appBundleID: "com.fixture.budget", windowName: "Budget review")
        let frame = FrameID(value: try await db.insertFrame(.init(id: .init(value: 0), timestamp: time,
            segmentID: .init(value: segment), frameIndexInSegment: 0, metadata: metadata)))
        _ = try await db.commitFrameOCR(frameID: frame,
            text: .init(frameID: frame, timestamp: time, regions: [], fullText: "Budget recorded screen", metadata: metadata),
            frameWidth: 100, frameHeight: 100)
        let note = try await db.createSegmentComment(body: "Budget note", author: "Author")
        try await db.addCommentToSegment(segmentId: .init(value: segment), commentId: note.id)
        _ = try await fixture.markers.createManualMarker(.init(anchoredAt: time, title: "Budget marker"))
        let recordingID = try await audio.insertTranscription(sessionID: nil, text: "Budget spoken evidence",
            startTime: time, endTime: time.addingTimeInterval(3), source: .microphone, confidence: nil, words: [])
        let interval = DateInterval(start: time.addingTimeInterval(-1), end: time.addingTimeInterval(10))
        let page = try await fixture.service.search(interval: interval, query: "Budget")
        XCTAssertTrue(Set(page.items.map(\.kind)).isSuperset(of: ["Transcripts", "Apps and windows", "Notes", "Marker", "Screens"]))
        XCTAssertEqual(Set(page.coverage.map(\.source)).count, 6)
        XCTAssertNotNil(page.coverage.first { $0.source == "Speakers" }?.notice)
        let copy = try await fixture.service.copy(references: page.items.map(\.reference), interval: interval, question: "What was discussed?", partial: true)
        XCTAssertTrue(copy.text.contains("Budget spoken evidence"))
        XCTAssertTrue(copy.text.contains("snapshot "))
        XCTAssertTrue(copy.text.contains("What was discussed?"))
        XCTAssertTrue(copy.text.contains("Partial selection"))
        try await db.updateSegmentComment(commentId: note.id, body: "Revised note", author: note.author, attachments: [])
        let noteReference = try XCTUnwrap(page.items.first { $0.kind == "Notes" }?.reference)
        do {
            _ = try await fixture.service.copy(references: [noteReference], interval: interval, partial: false)
            XCTFail("Edited notes cannot retain their old copy authorization")
        } catch { }
        _ = try await audio.deleteTranscription(id: recordingID)
        let audioReference = try XCTUnwrap(page.items.first { $0.kind == "Transcripts" }?.reference)
        do {
            _ = try await fixture.service.copy(references: [audioReference], interval: interval, partial: false)
            XCTFail("Deleted recording must fail copy")
        } catch { }
        try await fixture.close()
    }

    func testPendingAudioCopyIsSourceQualifiedWithoutInventingTextOrSpeakers() async throws {
        let fixture = try await Fixture.make()
        let id = try await fixture.audio.insertRawBatch(startTime: fixture.time, endTime: fixture.time.addingTimeInterval(3),
            source: .microphone, audioPath: "audio/batch_1800000000000_microphone_fixture.m4a", audioSize: 10)
        let rowValue = try await fixture.audio.getContextEntry(id: id)
        let row = try XCTUnwrap(rowValue)
        let references = try await fixture.service.transcriptReferences([row])
        let material = try await fixture.service.copy(references: references,
            interval: .init(start: fixture.time, duration: 4), partial: false)
        XCTAssertTrue(material.text.contains("Status: pending"))
        XCTAssertTrue(material.text.contains("speaker unassigned"))
        XCTAssertTrue(material.text.contains("snapshot "))
        let pending = try await fixture.audio.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 1, "Read/copy must not schedule inference")
        try await fixture.close()
    }

    func testHiddenOrCurrentlyExcludedEvidenceCannotBeCopiedFromAnEarlierSearch() async throws {
        let fixture = try await Fixture.make()
        let db = fixture.database, time = fixture.time
        let segment = try await db.insertSegment(bundleID: "com.fixture.budget", startDate: time,
            endDate: time.addingTimeInterval(4), windowName: "Budget review", browserUrl: nil, type: 0)
        let metadata = FrameMetadata(appBundleID: "com.fixture.budget", windowName: "Budget review")
        let frame = FrameID(value: try await db.insertFrame(.init(id: .init(value: 0), timestamp: time,
            segmentID: .init(value: segment), frameIndexInSegment: 0, metadata: metadata)))
        _ = try await db.commitFrameOCR(frameID: frame, text: .init(frameID: frame, timestamp: time,
            regions: [], fullText: "Budget evidence", metadata: metadata), frameWidth: 100, frameHeight: 100)
        let note = try await db.createSegmentComment(body: "Budget note", author: "Fixture")
        try await db.addCommentToSegment(segmentId: .init(value: segment), commentId: note.id)
        let interval = DateInterval(start: time.addingTimeInterval(-1), duration: 10)
        let page = try await fixture.service.search(interval: interval, query: "Budget")
        XCTAssertEqual(Set(page.items.map(\.kind)), ["Screens", "Apps and windows", "Notes"])
        let hiddenValue = try await db.getTag(name: "hidden")
        let hidden = try XCTUnwrap(hiddenValue)
        try await db.addTagToSegment(segmentId: .init(value: segment), tagId: hidden.id)
        for item in page.items {
            do {
                _ = try await fixture.service.copy(references: [item.reference], interval: interval, partial: false)
                XCTFail("Hidden \(item.kind) remained readable")
            } catch { }
        }
        try await db.removeTagFromSegment(segmentId: .init(value: segment), tagId: hidden.id)
        await fixture.policy.exclude()
        for item in page.items {
            do {
                _ = try await fixture.service.copy(references: [item.reference], interval: interval, partial: false)
                XCTFail("Excluded \(item.kind) remained readable")
            } catch { }
        }
        let excluded = try await fixture.service.search(interval: interval, query: "Budget")
        XCTAssertTrue(excluded.items.isEmpty)
        await fixture.policy.excludeTitle()
        for item in page.items {
            do {
                _ = try await fixture.service.copy(references: [item.reference], interval: interval, partial: false)
                XCTFail("Currently excluded title remained copyable through \(item.kind)")
            } catch { }
        }
        try await fixture.close()
    }

    private struct Fixture {
        let root: URL
        let database: DatabaseManager
        let audio: AudioTranscriptionQueries
        let adapter: DataAdapter
        let markers: TimelineMarkerService
        let service: LiveContextSearchService
        let policy: LiveContextTestPolicy
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        static func make(turn: LiveContextSearchService.TurnReader? = nil) async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-search-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let database = DatabaseManager(databasePath: root.appendingPathComponent("recordings.db").path)
            try await database.initialize()
            let connection = await database.getConnection()
            let audio = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
            let adapter = DataAdapter(retraceConnection: try await database.makeRecallReadConnection(),
                retraceConfig: .init(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
                retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
            try await adapter.initialize()
            let policy = LiveContextTestPolicy()
            let recall = ProgressiveRecallService(database: database, adapter: adapter, configuration: { await policy.state().config },
                disclosureState: { await policy.state() },
                imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
            let storeID = try await database.activityStoreID()
            let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { storeID })
            return Fixture(root: root, database: database, audio: audio, adapter: adapter, markers: markers,
                service: LiveContextSearchService(database: database, audio: audio, adapter: adapter, recall: recall, markers: markers,
                    captureState: { await policy.state() }, turn: turn), policy: policy)
        }
        func close() async throws {
            try await markers.close(); await adapter.shutdown(); try await database.close()
            try FileManager.default.removeItem(at: root)
        }
    }
}

private actor LiveCopyTurnReader {
    private var current: CompanionTurnPresentation?
    private var revokeNext = false
    func set(_ value: CompanionTurnPresentation) { current = value }
    func revokeAfterNextResolution() { revokeNext = true }
    func resolve(_ reference: CompanionTurnReference) throws -> CompanionTurnPresentation {
        guard let current, current.reference == reference else { throw CompanionError.staleEvidence }
        if revokeNext { self.current = nil; revokeNext = false }
        return current
    }
}

private actor LiveContextTestPolicy {
    private var excluded = false
    private var titleExcluded = false
    private var revision = UUID()
    func state() -> NativeCaptureState { .init(config: .init(excludedAppBundleIDs: excluded ? ["com.fixture.budget"] : [],
        redactWindowTitlePatterns: titleExcluded ? ["Budget"] : []), revision: revision) }
    func exclude() { excluded = true; revision = UUID() }
    func excludeTitle() { excluded = false; titleExcluded = true; revision = UUID() }
}
