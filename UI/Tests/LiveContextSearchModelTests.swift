import App
import Database
import Foundation
import Shared
import Storage
import XCTest
@testable import Retrace

@MainActor
final class LiveContextSearchModelTests: XCTestCase {
    func testSourceInvalidationClearsSearchAndSelectionBeforeHeldReadAndResetRejectsLateResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-search-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = DatabaseManager(databasePath: root.appendingPathComponent("recordings.db").path)
        try await database.initialize()
        let connection = await database.getConnection()
        let audio = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let adapter = DataAdapter(retraceConnection: try await database.makeRecallReadConnection(),
            retraceConfig: .init(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
        try await adapter.initialize()
        let policy = NativeCaptureState(config: .init(), revision: UUID())
        let recall = ProgressiveRecallService(database: database, adapter: adapter, configuration: { policy.config },
            disclosureState: { policy }, imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
        let storeID = try await database.activityStoreID()
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { storeID })
        let presentations = ContextRangePresentationService(markers: markers, validateEvidence: { _ in }, currentEpoch: { "fixture" })
        let service = LiveContextSearchService(database: database, audio: audio, adapter: adapter, recall: recall, markers: markers,
            captureState: { policy }, contextRanges: presentations)
        let gate = LiveSearchReaderGate(service: service)
        let time = Date(timeIntervalSince1970: 1_800_000_000), interval = DateInterval(start: time, duration: 10)
        let segment = try await database.insertSegment(bundleID: "com.fixture.aster", startDate: time, endDate: time,
            windowName: "Aster workspace", browserUrl: nil, type: 0)
        let metadata = FrameMetadata(appBundleID: "com.fixture.aster", windowName: "Aster workspace")
        let frame = FrameID(value: try await database.insertFrame(.init(id: .init(value: 0), timestamp: time,
            segmentID: .init(value: segment), frameIndexInSegment: 0, metadata: metadata)))
        _ = try await database.commitFrameOCR(frameID: frame,
            text: .init(frameID: frame, timestamp: time, regions: [], fullText: "Aster historical screen", metadata: metadata), frameWidth: 100, frameHeight: 100)
        let marker = try await markers.createManualMarker(.init(anchoredAt: time, title: "Aster marker"))
        _ = try await markers.saveContextRange(markerID: marker.id,
            range: .init(start: time, end: time.addingTimeInterval(2), explanation: "Aster user context", ownership: .manual),
            expectedRevision: nil, expectedMarkerRevision: marker.revision)
        let recordingID = try await audio.insertTranscription(sessionID: nil, text: "Aster recorded words", startTime: time,
            endTime: time.addingTimeInterval(2), source: .microphone, confidence: nil, words: [],
            audioPath: "audio/aster-original.m4a", batchAudioPath: "audio/aster-original.m4a")
        let model = LiveContextSearchModel(service: { await gate.get() }, rangePresentations: { presentations })
        let initialReads = await gate.readCount
        XCTAssertEqual(initialReads, 0, "Creating the model must not query or activate inference")
        model.submit(interval: interval, query: "Aster")
        await model.finishPendingRead()
        XCTAssertEqual(Set(model.items.map(\.kind)), ["Transcripts", "Marker", "Context range", "Screens", "Apps and windows"])
        model.selectedIDs = Set(model.items.map(\.id))
        let oldRevision = model.revision
        let selection = model.selectedIDs
        let beforeCopy = try await service.copy(references: model.selectedReferences, interval: interval, partial: false)
        try await database.setSourceMutationObserver { mutation in presentations.invalidate(mutation) }
        let later = time.addingTimeInterval(20)
        try await database.updateSegmentEndDate(id: segment, endDate: later)
        let next = FrameID(value: try await database.insertFrame(.init(id: .init(value: 0), timestamp: later,
            segmentID: .init(value: segment), frameIndexInSegment: 1, metadata: metadata)))
        _ = try await database.commitFrameOCR(frameID: next,
            text: .init(frameID: next, timestamp: later, regions: [], fullText: "New captured words", metadata: metadata), frameWidth: 100, frameHeight: 100)
        _ = try await audio.insertRawBatch(startTime: later, endTime: later.addingTimeInterval(2), source: .microphone,
            audioPath: "audio/new-capture.m4a", audioSize: 100)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.revision, oldRevision, "New capture, segment extension and OCR must preserve the historical review")
        XCTAssertEqual(model.selectedIDs, selection)
        let afterCopy = try await service.copy(references: model.selectedReferences, interval: interval, partial: false)
        XCTAssertEqual(afterCopy.text, beforeCopy.text, "The reviewed copy preview remains valid after unrelated recording")

        await gate.holdNextRead()
        let higherPassID = try await audio.insertTranscription(sessionID: nil, text: "Aster improved words", startTime: time,
            endTime: time.addingTimeInterval(2), source: .microphone, confidence: nil, words: [],
            audioPath: "audio/aster-original.m4a", transcriptionPass: 2, batchAudioPath: "audio/aster-original.m4a")
        try await gate.waitForHeldRead()
        XCTAssertTrue(model.items.isEmpty, "A new row in the selected batch supersedes the old latest-pass selection")
        XCTAssertTrue(model.selectedIDs.isEmpty)
        await gate.releaseRead()
        try await Task.sleep(for: .milliseconds(30)); await model.finishPendingRead()
        await gate.holdNextRead()
        _ = try await audio.deleteTranscription(id: recordingID)
        _ = try await audio.deleteTranscription(id: higherPassID)
        _ = try await markers.setMarkerDeleted(id: marker.id, expectedRevision: marker.revision, deleted: true)
        presentations.invalidate()
        try await gate.waitForHeldRead()
        XCTAssertNotEqual(model.revision, oldRevision)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.coverage.isEmpty)
        XCTAssertTrue(model.selectedReferences.isEmpty)
        XCTAssertTrue(model.selectedIDs.isEmpty)
        XCTAssertEqual(model.query, "Aster")
        XCTAssertEqual(model.interval, interval)
        model.reset()
        await gate.releaseRead()
        await model.finishPendingRead()
        XCTAssertTrue(model.items.isEmpty, "Reset must reject a delayed refresh completion")
        XCTAssertFalse(model.isSearching)
        model.submit(interval: interval, query: "Aster")
        await model.finishPendingRead()
        XCTAssertEqual(Set(model.items.map(\.kind)), ["Screens", "Apps and windows"], "Fresh search must reflect the canonical deletion")
        model.selectedIDs = Set(model.items.map(\.id))
        await gate.holdNextRead()
        let hiddenValue = try await database.getTag(name: "hidden")
        let hidden = try XCTUnwrap(hiddenValue)
        try await database.addTagToSegment(segmentId: .init(value: segment), tagId: hidden.id)
        try await gate.waitForHeldRead()
        XCTAssertTrue(model.items.isEmpty, "A hidden source clears before the replacement read returns")
        XCTAssertTrue(model.selectedIDs.isEmpty)
        await gate.releaseRead()
        try await Task.sleep(for: .milliseconds(30)); await model.finishPendingRead()
        XCTAssertTrue(model.items.isEmpty)
        model.reset()
        try await database.setSourceMutationObserver(nil)
        await presentations.close(); try await markers.close(); await adapter.shutdown(); try await database.close()
    }
}

private actor LiveSearchReaderGate {
    let service: LiveContextSearchService
    private(set) var readCount = 0
    private var hold = false, entered = false
    private var heldRead: CheckedContinuation<Void, Never>?
    init(service: LiveContextSearchService) { self.service = service }
    func get() async -> LiveContextSearchService {
        readCount += 1
        if hold {
            hold = false; entered = true
            await withCheckedContinuation { heldRead = $0 }
        }
        return service
    }
    func holdNextRead() { hold = true; entered = false }
    func waitForHeldRead() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard entered else { throw NSError(domain: "LiveSearchInvalidationDidNotRefresh", code: 1) }
    }
    func releaseRead() { heldRead?.resume(); heldRead = nil }
}
