import App
import Database
import Foundation
import Shared
import XCTest
@testable import Retrace

final class LiveTranscriptProjectionTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_800_000_000)

    func testNewestFirstTurnsRetainPendingUnmatchedAndFullOriginalWithoutDuplicateBatchText() throws {
        let original = row(1, text: "Full original first pass, including the overlapping tail", offset: 0)
        let pending = row(2, text: "", offset: 8)
        let unmatched = row(3, text: "Independent system words", offset: 1, source: .system)
        let presentation = try speaker(original: original, offsets: [(2, 4), (5, 7)])
        let projection = LiveTranscriptProjection.make(recordings: [pending, unmatched, original], speakers: [presentation],
            interval: DateInterval(start: time, duration: 20), recordingReferences: presentation.firstPassReferences)
        XCTAssertEqual(projection.items.map(\.startedAt), projection.items.map(\.startedAt).sorted(by: >))
        XCTAssertEqual(projection.items.compactMap(\.recording).map(\.id), [pending.id, unmatched.id])
        XCTAssertEqual(projection.items.compactMap(\.turn).count, 2)
        XCTAssertEqual(projection.items.compactMap(\.original).map(\.presentation.firstPassText), [original.text])
        XCTAssertFalse(projection.truncated)
    }

    func testEqualTextAndTimeCannotCollapseDifferentRecordingOrAssignNamesAcrossJobs() throws {
        let original = row(1, text: "Shared words", offset: 0)
        let unrelated = row(2, text: original.text, offset: 0)
        let first = try speaker(original: original, offsets: [(0, 2)])
        let second = try speaker(original: unrelated, offsets: [(2, 4)], jobID: String(repeating: "b", count: 64))
        let projection = LiveTranscriptProjection.make(recordings: [unrelated], speakers: [first, second], interval: DateInterval(start: time, duration: 20))
        let turns = projection.items.compactMap(\.turn)
        XCTAssertEqual(Set(turns.map(\.id)).count, 2)
        XCTAssertEqual(Set(turns.map(\.speakerScopeID)).count, 2, "Speaker 1 is scoped to its saved inference")
        let onlyFirst = LiveTranscriptProjection.make(recordings: [unrelated], speakers: [first], interval: DateInterval(start: time, duration: 20))
        XCTAssertEqual(onlyFirst.items.compactMap(\.recording).map(\.id), [unrelated.id], "Matching text and timestamps are not a source proof")
        let otherStore = try CompanionTranscriptSnapshot.reference(for: original, nativeStoreID: UUID())
        let crossStore = LiveTranscriptProjection.make(recordings: [original], speakers: [first],
            interval: DateInterval(start: time, duration: 20), recordingReferences: [otherStore])
        XCTAssertEqual(crossStore.items.compactMap(\.recording).map(\.id), [original.id], "Equal row fields in another store are not the same recording")
    }

    func testManualLabelWinsWhileSuggestionRemainsExplicitAndTurnBoundsStayWithinItsSource() throws {
        let original = row(1, text: "Original", offset: 0)
        let suggested = try speaker(original: original, offsets: [(2, 4)], suggestion: true)
        let named = try speaker(original: original, offsets: [(2, 4)], suggestion: true, manualName: "Maya")
        let suggestedTurn = try XCTUnwrap(LiveTranscriptProjection.make(recordings: [], speakers: [suggested],
            interval: DateInterval(start: time, duration: 20)).items.compactMap(\.turn).first)
        let namedTurn = try XCTUnwrap(LiveTranscriptProjection.make(recordings: [], speakers: [named],
            interval: DateInterval(start: time, duration: 20)).items.compactMap(\.turn).first)
        XCTAssertEqual(suggestedTurn.displayLabel, "Speaker 1")
        XCTAssertTrue(suggestedTurn.statusText.contains("Suggested"))
        XCTAssertEqual(namedTurn.displayLabel, "Maya")
        XCTAssertEqual(namedTurn.statusText, "Manual name")
        XCTAssertEqual(namedTurn.interval.start, time.addingTimeInterval(2))
        XCTAssertEqual(namedTurn.interval.end, time.addingTimeInterval(4))
    }

    func testTurnLimitIsExplicitAndNeverHidesAnOriginalWhoseTurnsWereOmitted() throws {
        let original = row(1, text: "Original", offset: 0)
        let presentation = try speaker(original: original, offsets: [(0, 1), (2, 3), (4, 5)])
        let projection = LiveTranscriptProjection.make(recordings: [original], speakers: [presentation],
            interval: DateInterval(start: time, duration: 20), maximumTurns: 1)
        XCTAssertTrue(projection.truncated)
        XCTAssertEqual(projection.items.compactMap(\.turn).count, 1)
        XCTAssertEqual(projection.items.compactMap(\.original).first?.presentation.firstPassText, original.text)
    }

    @MainActor
    func testLateSpeakerEnrichmentDoesNotReplaceHistoryUntilReturnToLive() async throws {
        let original = row(1, text: "Original history", offset: 0)
        let saved = try speaker(original: original, offsets: [(2, 4)])
        let pages = TurnFixturePages()
        let model = LiveContextWorkspaceModel(loadAudio: { _, _, _ in .init(entries: [original], nextCursor: nil) },
            loadScreens: { _ in .init(rows: [], hasMore: false) }, loadSpeakers: { _, _ in await pages.page() })
        model.setActive(true)
        await model.refresh(now: time.addingTimeInterval(20))
        let visible = model.transcriptItems.map(\.id)
        model.pauseFollowing()
        await pages.replace([saved])
        await model.refresh(now: time.addingTimeInterval(30))
        XCTAssertEqual(model.transcriptItems.map(\.id), visible)
        XCTAssertTrue(model.hasNewerContent)
        model.returnToLive()
        await model.refresh(now: time.addingTimeInterval(30))
        XCTAssertEqual(model.transcriptItems.compactMap(\.turn).count, 1)
        XCTAssertTrue(model.followingLive)
        model.setActive(false)
    }

    @MainActor
    func testSelectedTurnRequestsOnlyItsApproximateScreenIntervalAndSupportsAudioOnly() async throws {
        let original = row(1, text: "Original history", offset: 0)
        let saved = try speaker(original: original, offsets: [(2, 4)])
        let reference = try XCTUnwrap(saved.turnReferences.first)
        let full = saved.enhancement.sourceIdentity
        let selected = CompanionTurnPresentation(reference: reference, turn: saved.enhancement.turns[0],
            sourceIdentity: .init(recordingGeneration: full.recordingGeneration, continuityID: full.continuityID,
                startSample: 32_000, sampleCount: 32_000, sampleRate: 16_000, approximateOrigin: time),
            displayLabel: "Speaker 1", speakerStatus: .anonymous, firstPassText: saved.firstPassText,
            firstPassSourceIdentity: full, firstPassReferences: saved.firstPassReferences)
        let pages = TurnFixturePages()
        let model = LiveContextWorkspaceModel(loadAudio: { _, _, _ in .init(entries: [original], nextCursor: nil) },
            loadScreens: { interval in await pages.recordScreen(interval); return .init(rows: [], hasMore: false) },
            loadSpeakers: { _, _ in .init(items: [saved], nextCursor: nil, incomplete: true) },
            resolveTurn: { expected in guard expected == reference else { throw CompanionError.staleEvidence }; return selected })
        model.setActive(true); await model.refresh(now: time.addingTimeInterval(20))
        try await model.selectTurn(reference)
        await model.refresh(now: time.addingTimeInterval(20))
        let screenInterval = await pages.lastScreen
        XCTAssertEqual(screenInterval, DateInterval(start: time.addingTimeInterval(2), duration: 2))
        XCTAssertEqual(model.selectedTurn?.reference, reference)
        XCTAssertTrue(model.screens.isEmpty, "A missing screen cannot be replaced by a nearby capture")
        XCTAssertEqual(model.transcriptItems.compactMap(\.turn).count, 1)
        XCTAssertFalse(model.followingLive)
        model.setActive(false)
    }

    private func row(_ id: Int64, text: String, offset: Double, source: AudioSource = .microphone) -> AudioTranscription {
        .init(id: id, sessionID: nil, text: text, startTime: time.addingTimeInterval(offset), endTime: time.addingTimeInterval(offset + 10),
            source: source, confidence: nil, createdAt: time, audioPath: "audio/authored.m4a", batchAudioPath: "audio/authored.m4a",
            transcriptStatus: text.isEmpty ? "pending" : "transcribed", transcriptionPass: 1)
    }

    private func speaker(original: AudioTranscription, offsets: [(Double, Double)], jobID: String = String(repeating: "a", count: 64),
                         suggestion: Bool = false, manualName: String? = nil) throws -> CompanionSpeakerPresentation {
        let store = UUID(), identity = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(),
            startSample: 0, sampleCount: 160_000, sampleRate: 16_000, approximateOrigin: time)
        let speakerID = jobID + ":cluster:1"
        let turns: [[String: Any]] = offsets.map { start, end in
            var value: [String: Any] = ["start": start, "end": end, "text": "Turn at \(start)", "speakerID": speakerID,
                "speakerLabel": "Speaker 1", "speakerStatus": suggestion ? "suggested" : "unknown"]
            if suggestion { value["candidateName"] = "Possible Maya"; value["personID"] = "fixture-person"; value["similarity"] = 0.8 }
            return value
        }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let source = try JSONSerialization.jsonObject(with: encoder.encode(identity))
        let object: [String: Any] = ["sourceIdentity": source, "firstPassSHA256": String(repeating: "c", count: 64),
            "enhancedText": "Enhanced fixture", "turns": turns, "automaticNamesCalibrated": false,
            "modelFingerprint": String(repeating: "d", count: 64)]
        let enhancement = try decoder.decode(CompanionSpeakerEnrichment.self, from: JSONSerialization.data(withJSONObject: object))
        let corrections: [CompanionSpeakerCorrection] = manualName.map { [.init(nativeStoreID: store, speakerID: speakerID,
            sourceIdentity: identity, revision: UUID(), displayName: $0, personID: nil, updatedAt: time)] } ?? []
        let references = offsets.indices.map { CompanionTurnReference(nativeStoreID: store, jobID: jobID,
            resultSHA256: String(repeating: "e", count: 64), turnIndex: $0, correctionRevision: corrections.first?.revision) }
        return .init(jobID: jobID, nativeStoreID: store, firstPassText: original.text, enhancement: enhancement,
            corrections: corrections, firstPassSourceIdentity: identity,
            firstPassReferences: [try CompanionTranscriptSnapshot.reference(for: original, nativeStoreID: store)], turnReferences: references)
    }
}

private actor TurnFixturePages {
    private var values: [CompanionSpeakerPresentation] = []
    private(set) var lastScreen: DateInterval?
    func replace(_ values: [CompanionSpeakerPresentation]) { self.values = values }
    func page() -> CompanionSpeakerPage { .init(items: values, nextCursor: nil, incomplete: true) }
    func recordScreen(_ interval: DateInterval) { lastScreen = interval }
}
