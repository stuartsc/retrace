import App
import Database
import Shared
import XCTest
@testable import Retrace

@MainActor
final class LiveContextWorkspaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testHistoryLoadsNewestFirstAcrossDaysAndPastFiveHundredWithoutChangingScope() async throws {
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        var expected: [Int64] = []
        for index in 0..<620 {
            // Equal start/end pairs exercise the reader's final row-ID key.
            let start = now.addingTimeInterval(-Double(index / 2) * 300 - 10)
            let id = try await queries.insertTranscription(sessionID: nil, text: "Authored history item \(index)",
                startTime: start, endTime: start.addingTimeInterval(3), source: .microphone,
                confidence: nil, words: [])
            if index.isMultiple(of: 2) { expected.append(id) }
            else { expected.insert(id, at: expected.count - 1) }
        }
        let model = LiveContextWorkspaceModel(loadAudio: { interval, cursor, query in
            let page = try await queries.getContextPage(from: interval.start, to: interval.end,
                limit: 100, before: cursor, query: query)
            XCTAssertLessThanOrEqual(page.entries.count, 100)
            XCTAssertLessThanOrEqual(page.scannedCandidates, 512)
            return page
        }, loadScreens: { _ in .init(rows: [], hasMore: false) },
           readEntry: { try await queries.getContextEntry(id: $0) })
        model.setActive(true)
        await model.refresh(now: now)
        XCTAssertEqual(model.transcripts.map(\.id), Array(expected.prefix(100)))
        model.pauseFollowing()
        let scope = model.interval
        var requests = 0
        while model.canLoadOlder, requests < 12 {
            await model.refresh(now: now.addingTimeInterval(60), loadOlder: true)
            XCTAssertEqual(model.interval, scope, "Continuation must retain its original query scope")
            requests += 1
        }
        XCTAssertEqual(model.transcripts.map(\.id), expected)
        XCTAssertEqual(model.transcriptItems.compactMap(\.recording).map(\.id), expected,
            "Newest first is also the presented order, not just the SQL order")
        XCTAssertEqual(Set(model.transcripts.map(\.id)).count, 620)
        XCTAssertFalse(model.canLoadOlder)
        model.setActive(false)
        try await database.close()
    }

    func testLatestTranscriptTimeComesFromReadableSavedTextRatherThanPendingAudio() {
        let rows = [row(id: 1, text: "Saved text", offset: -120), row(id: 2, text: "", offset: -10)]
        XCTAssertEqual(LiveContextPresentation.latestTranscriptDate(rows), now.addingTimeInterval(-117))
        XCTAssertNil(LiveContextPresentation.latestTranscriptDate([rows[1]]))
    }

    func testCustomIntervalRejectsReversedDatesAndRecentWindowIsThirtyMinutes() {
        XCTAssertNil(LiveContextRange.custom.interval(now: now, from: now, to: now.addingTimeInterval(-10)))
        let recent = LiveContextRange.recent.interval(now: now, from: now, to: now)
        XCTAssertEqual(recent?.duration, 1_800)
        XCTAssertEqual(recent?.end, now)
    }

    func testHeldReadCannotPublishAfterCloseAndReopeningJoinsTheOldRead() async throws {
        let gate = LiveContextReadGate()
        let first = row(id: 1, text: "Saved text", offset: -10)
        let model = makeModel(loadAudio: { _, _ in
            await gate.wait()
            return AudioContextPage(entries: [first], nextCursor: nil)
        })
        model.setActive(true)
        let old = Task { await model.refresh(now: now) }
        await gate.waitUntilEntered()
        model.setActive(false)
        model.setActive(true)
        let reopened = Task { await model.refresh(now: now) }
        await Task.yield()
        XCTAssertTrue(model.transcripts.isEmpty)
        await gate.open()
        await old.value
        await reopened.value
        XCTAssertEqual(model.transcripts.map(\.id), [first.id])
        let attempts = await gate.attempts
        XCTAssertEqual(attempts, 2)
        model.setActive(false)
    }

    func testReadingHistoryKeepsVisibleRowsWhileReportingNewerSavedText() async throws {
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let first = try await queries.insertTranscription(sessionID: nil, text: "Original saved text",
            startTime: now.addingTimeInterval(-100), endTime: now.addingTimeInterval(-95),
            source: .microphone, confidence: nil, words: [])
        let model = makeModel(loadAudio: { interval, cursor in
            try await queries.getContextPage(from: interval.start, to: interval.end, limit: 20, before: cursor)
        })
        model.setActive(true)
        await model.refresh(now: now)
        model.pauseFollowing()
        let pendingID = try await queries.insertRawBatch(startTime: now.addingTimeInterval(1), endTime: now.addingTimeInterval(4),
            source: .microphone, audioPath: "audio/batch_1800000001000_microphone_fixture.m4a", audioSize: 20)
        let originalPending = try await queries.getContextEntry(id: pendingID)
        XCTAssertEqual(originalPending?.transcriptStatus, "pending")
        let initialPendingCount = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(initialPendingCount, 1, "The authored fixture must be eligible for the pending queue")
        let second = try await queries.insertTranscription(sessionID: nil, text: "New saved text",
            startTime: now.addingTimeInterval(10), endTime: now.addingTimeInterval(15),
            source: .microphone, confidence: nil, words: [])
        await model.refresh(now: now.addingTimeInterval(30))
        XCTAssertEqual(model.transcripts.map(\.id), [first])
        XCTAssertEqual(model.latestTranscriptAt, now.addingTimeInterval(15))
        XCTAssertEqual(model.interval?.end, now, "The visible page and its cursor retain their original interval")
        XCTAssertTrue(model.hasNewerContent)
        model.returnToLive()
        await model.refresh(now: now.addingTimeInterval(30))
        XCTAssertEqual(model.transcripts.first?.id, second)
        XCTAssertEqual(model.transcripts.count, 3, "Pending recordings must remain visible beside prepared text")
        let pending = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(pending, 1, "Opening and refreshing the workspace must not start inference")
        let retainedPending = try await queries.getContextEntry(id: pendingID)
        XCTAssertTrue(LiveContextPresentation.sameRecording(try XCTUnwrap(originalPending), try XCTUnwrap(retainedPending)),
            "Opening the workspace must preserve the complete pending recording")
        model.setActive(false)
        try await database.close()
    }

    func testCopyPreviewContainsOnlyLoadedRowsAndDisclosesCoverage() {
        let preview = LiveContextPresentation.copyPreview(rows: [row(id: 4, text: "Authored sentence", offset: -60)],
            interval: DateInterval(start: now.addingTimeInterval(-1_800), end: now),
            hasMore: true, selectedScreen: nil)
        XCTAssertTrue(preview.contains("Authored sentence"))
        XCTAssertTrue(preview.contains("More recordings are available"))
        XCTAssertTrue(preview.contains("Speaker: unassigned"))
        XCTAssertFalse(preview.contains("Operating Brief"))
    }

    func testActionValidationRejectsDeletedSQLiteRowsAndClosedWorkspace() async throws {
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        _ = try await queries.insertTranscription(sessionID: nil, text: "Only the retained recording may be copied",
            startTime: now.addingTimeInterval(-20), endTime: now.addingTimeInterval(-15),
            source: .microphone, confidence: nil, words: [])
        let model = LiveContextWorkspaceModel(loadAudio: { interval, cursor, query in
            try await queries.getContextPage(from: interval.start, to: interval.end, before: cursor, query: query)
        }, loadScreens: { _ in LiveContextScreenPage(rows: [], hasMore: false) },
           readEntry: { try await queries.getContextEntry(id: $0) })
        model.setActive(true)
        await model.refresh(now: now)
        let retained = model.transcripts
        let valid = await model.validateForAction(retained)
        XCTAssertTrue(valid)
        _ = try await queries.deleteTranscriptions(olderThan: now)
        let deleted = await model.validateForAction(retained)
        XCTAssertFalse(deleted)
        model.setActive(false)
        let closed = await model.validateForAction(retained)
        XCTAssertFalse(closed)
        try await database.close()
    }

    func testHeldRecordingProofDoesNotDelaySavedAudioOrScreensAndCloseRejectsLateProof() async throws {
        let gate = LiveContextReadGate()
        let saved = row(id: 41, text: "Readable before optional identity enrichment", offset: -30)
        let screenReads = LiveContextReadCounter()
        let model = LiveContextWorkspaceModel(loadAudio: { _, _, _ in
            .init(entries: [saved], nextCursor: nil)
        }, loadScreens: { _ in
            await screenReads.record()
            return .init(rows: [], hasMore: true)
        }, referenceRecordings: { _ in
            await gate.wait()
            return []
        })
        model.setActive(true)
        let refresh = Task { await model.refresh(now: now) }
        await gate.waitUntilEntered()
        XCTAssertEqual(model.transcripts.map(\.id), [saved.id], "Optional source proofs cannot withhold ordinary saved text")
        let reads = await screenReads.count
        XCTAssertEqual(reads, 1, "Screen context must be read before an optional proof can suspend")
        XCTAssertTrue(model.screensHaveMore, "The screen page must publish independently of proof enrichment")
        model.setActive(false)
        let hiddenRevision = model.transcriptRevision
        await gate.open()
        await refresh.value
        XCTAssertEqual(model.transcriptRevision, hiddenRevision, "A cancelled proof cannot publish a late projection")
        XCTAssertFalse(model.presentationReady)
    }

    func testHeldAudioReaderDoesNotStarveScreenContext() async {
        let audioGate = LiveContextReadGate(), screens = LiveContextReadCounter()
        let saved = row(id: 39, text: "Audio arrives after the screen", offset: -30)
        let model = LiveContextWorkspaceModel(loadAudio: { _, _, _ in
            await audioGate.wait()
            return .init(entries: [saved], nextCursor: nil)
        }, loadScreens: { _ in
            await screens.record()
            return .init(rows: [], hasMore: true)
        })
        model.setActive(true)
        let refresh = Task { await model.refresh(now: now) }
        await audioGate.waitUntilEntered()
        let deadline = ContinuousClock.now + .seconds(2)
        while !model.screensHaveMore, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(model.screensHaveMore, "A held audio database read must not withhold independently available screen context")
        let count = await screens.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(model.transcripts.isEmpty)
        await audioGate.open()
        await refresh.value
        XCTAssertEqual(model.transcripts.map(\.id), [saved.id])
        model.setActive(false)
    }

    func testReadingInteractionDuringHeldRefreshCannotReplacePinnedRows() async {
        let gate = LiveContextReadGate(), reads = LiveContextReadCounter()
        let original = row(id: 51, text: "Pinned before the delayed page returns", offset: -30)
        let arrived = row(id: 52, text: "Delayed arrival", offset: -10)
        let model = makeModel(loadAudio: { _, _ in
            await reads.record()
            if await reads.count == 1 { return .init(entries: [original], nextCursor: nil) }
            await gate.wait()
            return .init(entries: [arrived, original], nextCursor: nil)
        })
        model.setActive(true)
        await model.refresh(now: now)
        let oldItems = model.transcriptItems.map(\.id)
        let pending = Task { await model.refresh(now: now.addingTimeInterval(10)) }
        await gate.waitUntilEntered()
        model.pauseFollowing()
        await gate.open()
        await pending.value
        XCTAssertFalse(model.followingLive)
        XCTAssertEqual(model.transcripts.map(\.id), [original.id])
        XCTAssertEqual(model.transcriptItems.map(\.id), oldItems, "A read admitted while following cannot replace rows after native reading input")
        model.setActive(false)
    }

    func testHeldSpeakerPageDoesNotDelaySavedAudioOrScreensAndScopeChangeRejectsLatePage() async {
        let gate = LiveContextReadGate()
        let saved = row(id: 42, text: "The screen is useful while speakers are offline", offset: -30)
        let model = LiveContextWorkspaceModel(loadAudio: { _, _, _ in
            .init(entries: [saved], nextCursor: nil)
        }, loadScreens: { _ in .init(rows: [], hasMore: true) }, loadSpeakers: { _, _ in
            await gate.wait()
            return .init(items: [], nextCursor: "stale-speaker-cursor", incomplete: true)
        })
        model.setActive(true)
        let refresh = Task { await model.refresh(now: now) }
        await gate.waitUntilEntered()
        XCTAssertEqual(model.transcripts.map(\.id), [saved.id])
        XCTAssertTrue(model.screensHaveMore, "An unavailable speaker reader cannot starve the screen page")
        model.configure(range: .custom, from: now.addingTimeInterval(-5), to: now, query: "new scope")
        await gate.open()
        await refresh.value
        XCTAssertNil(model.speakerCursor, "A cancelled optional page cannot attach its cursor to the replacement interval")
        XCTAssertFalse(model.speakerCoverageIncomplete)
        XCTAssertTrue(model.transcripts.isEmpty)
        model.setActive(false)
    }

    func testResumeRetainsPinnedHistoryButWaitsForCanonicalRowsAndRemovesHiddenDeletion() async throws {
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let first = try await queries.insertTranscription(sessionID: nil, text: "Retained history", startTime: now.addingTimeInterval(-100),
            endTime: now.addingTimeInterval(-95), source: .microphone, confidence: nil, words: [])
        let deleted = try await queries.insertTranscription(sessionID: nil, text: "Deleted while Settings is visible", startTime: now.addingTimeInterval(-80),
            endTime: now.addingTimeInterval(-75), source: .microphone, confidence: nil, words: [])
        let validation = LiveContextReadGate()
        let model = LiveContextWorkspaceModel(loadAudio: { interval, cursor, _ in
            try await queries.getContextPage(from: interval.start, to: interval.end, before: cursor)
        }, loadScreens: { _ in .init(rows: [], hasMore: false) }, readEntry: { id in
            await validation.wait()
            return try await queries.getContextEntry(id: id)
        })
        model.setActive(true)
        await model.refresh(now: now)
        model.pauseFollowing()
        let originalInterval = model.interval
        let retained = model.transcripts.map(\.id)
        XCTAssertEqual(Set(retained), [first, deleted])
        model.setActive(false)
        XCTAssertEqual(model.transcripts.map(\.id), retained, "Hiding retains the native list's bounded reading snapshot")
        XCTAssertFalse(model.presentationReady, "Retained rows are hidden evidence until canonical revalidation")
        _ = try await queries.deleteTranscription(id: deleted)
        _ = try await queries.insertTranscription(sessionID: nil, text: "New head does not replace pinned history", startTime: now.addingTimeInterval(10),
            endTime: now.addingTimeInterval(15), source: .microphone, confidence: nil, words: [])
        model.setActive(true)
        let resumed = Task { await model.refresh(now: now.addingTimeInterval(30)) }
        await validation.waitUntilEntered()
        XCTAssertFalse(model.presentationReady, "Returning from Settings must not expose rows before the held canonical read")
        XCTAssertFalse(model.followingLive)
        await validation.open()
        await resumed.value
        XCTAssertTrue(model.presentationReady)
        XCTAssertEqual(model.transcripts.map(\.id), [first])
        XCTAssertEqual(model.interval, originalInterval)
        XCTAssertFalse(model.followingLive)
        model.setActive(false)
        try await database.close()
    }

    func testScopedSQLiteScreenMutationPreservesPinnedTranscriptIdentityAndInterval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-scoped-mutation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let audio = try await queries.insertTranscription(sessionID: nil, text: "Reading survives OCR replacement", startTime: now.addingTimeInterval(-30),
            endTime: now.addingTimeInterval(-20), source: .microphone, confidence: nil, words: [])
        let time = now.addingTimeInterval(-25)
        let segment = try await database.insertSegment(bundleID: "test.live.scoped", startDate: time, endDate: time,
            windowName: "Authored screen", browserUrl: nil, type: 0)
        let metadata = FrameMetadata(appBundleID: "test.live.scoped", appName: "Authored", windowName: "Authored screen")
        let frame = FrameID(value: try await database.insertFrame(.init(id: .init(value: 0), timestamp: time,
            segmentID: .init(value: segment), frameIndexInSegment: 0, metadata: metadata)))
        _ = try await database.commitFrameOCR(frameID: frame, text: .init(frameID: frame, timestamp: time, regions: [], fullText: "First OCR", metadata: metadata),
            frameWidth: 100, frameHeight: 100)
        let storeID = try await database.activityStoreID()
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { storeID })
        let changes = ContextRangePresentationService(markers: markers, validateEvidence: { _ in }, currentEpoch: { "private-fixture" })
        let sourceGeneration = UUID().uuidString
        let model = LiveContextWorkspaceModel(loadAudio: { interval, cursor, _ in
            try await queries.getContextPage(from: interval.start, to: interval.end, before: cursor)
        }, loadScreens: { interval in
            let rows = try await database.getFramesWithVideoInfo(from: interval.start, to: interval.end, limit: 10)
            return .init(rows: rows.map { DashboardScreenshotRow(value: $0, sourceGeneration: sourceGeneration) }, hasMore: false)
        }, readEntry: { try await queries.getContextEntry(id: $0) }, sourceChanges: { changes })
        model.setActive(true)
        await model.refresh(now: now)
        model.pauseFollowing()
        let screen = try XCTUnwrap(model.screens.first)
        model.selectScreen(screen)
        let pinnedItems = model.transcriptItems.map(\.id), pinnedInterval = model.interval
        let revision = model.sourceInvalidationRevision
        try await database.setSourceMutationObserver { changes.invalidate($0) }
        _ = try await database.commitFrameOCR(frameID: frame, text: .init(frameID: frame, timestamp: time, regions: [], fullText: "Repaired OCR", metadata: metadata),
            frameWidth: 100, frameHeight: 100)
        let deadline = ContinuousClock.now + .seconds(2)
        while model.sourceInvalidationRevision == revision, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNotEqual(model.sourceInvalidationRevision, revision, "The real SQLite mutation must reach the subscribed workspace")
        XCTAssertEqual(model.transcripts.map(\.id), [audio])
        XCTAssertEqual(model.transcriptItems.map(\.id), pinnedItems, "Replacing a screen must not recreate unrelated transcript identities")
        XCTAssertEqual(model.interval, pinnedInterval)
        XCTAssertFalse(model.followingLive)
        XCTAssertNil(model.selectedScreenID, "The superseded screen selection must be revoked immediately")
        await model.refresh(now: now)
        XCTAssertEqual(model.transcripts.map(\.id), [audio])
        model.setActive(false)
        try await database.setSourceMutationObserver(nil)
        await changes.close(); try await markers.close(); try await database.close()
    }

    func testRequiredSourceSubscriptionFailureBlocksCoreReadsAndRetryRevalidatesRetainedRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-source-admission-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let audio = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let id = try await audio.insertTranscription(sessionID: nil, text: "Canonical row before Settings", startTime: now.addingTimeInterval(-30),
            endTime: now.addingTimeInterval(-20), source: .microphone, confidence: nil, words: [])
        let storeID = try await database.activityStoreID()
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { storeID })
        let changes = ContextRangePresentationService(markers: markers, validateEvidence: { _ in }, currentEpoch: { "private-source-admission" })
        let admission = LiveContextSourceAvailability()
        let audioReads = LiveContextReadCounter(), screenReads = LiveContextReadCounter(), canonicalReads = LiveContextReadCounter()
        let model = LiveContextWorkspaceModel(loadAudio: { interval, cursor, _ in
            await audioReads.record()
            return try await audio.getContextPage(from: interval.start, to: interval.end, before: cursor)
        }, loadScreens: { _ in
            await screenReads.record()
            return .init(rows: [], hasMore: false)
        }, readEntry: { id in
            await canonicalReads.record()
            return try await audio.getContextEntry(id: id)
        }, sourceChanges: {
            guard await admission.available else { throw CompanionError.unavailable }
            return changes
        })
        model.setActive(true)
        await model.refresh(now: now)
        var audioCount = await audioReads.count, screenCount = await screenReads.count
        XCTAssertEqual(audioCount, 0)
        XCTAssertEqual(screenCount, 0)
        XCTAssertFalse(model.presentationReady)
        XCTAssertNotNil(model.audioError, "Failure to install a required source observer must explain the Retry state")
        await admission.setAvailable(true)
        await model.refresh(now: now)
        XCTAssertEqual(model.transcripts.map(\.id), [id])
        XCTAssertTrue(model.presentationReady)
        model.pauseFollowing()
        model.setActive(false)
        await admission.setAvailable(false)
        _ = try await audio.deleteTranscription(id: id)
        model.setActive(true)
        await model.refresh(now: now)
        audioCount = await audioReads.count; screenCount = await screenReads.count
        XCTAssertEqual(audioCount, 1)
        XCTAssertEqual(screenCount, 1)
        XCTAssertFalse(model.presentationReady)
        XCTAssertEqual(model.transcripts.map(\.id), [id], "The bounded cache stays hidden while observer registration is unavailable")
        await admission.setAvailable(true)
        await model.refresh(now: now)
        let canonicalCount = await canonicalReads.count
        XCTAssertEqual(canonicalCount, 1, "Successful Retry must check the retained row in canonical SQLite before revealing it")
        XCTAssertTrue(model.transcripts.isEmpty)
        XCTAssertTrue(model.presentationReady)
        XCTAssertFalse(model.followingLive)
        model.setActive(false)
        await changes.close(); try await markers.close(); try await database.close()
    }

    func testRequiredSpeakerSubscriptionFailureCannotPublishAvailableCoreEvidence() async {
        let audioReads = LiveContextReadCounter(), screenReads = LiveContextReadCounter()
        let saved = row(id: 62, text: "Must remain undisclosed without required source observation", offset: -30)
        let model = LiveContextWorkspaceModel(loadAudio: { _, _, _ in
            await audioReads.record()
            return .init(entries: [saved], nextCursor: nil)
        }, loadScreens: { _ in
            await screenReads.record()
            return .init(rows: [], hasMore: true)
        }, speakerChanges: { throw CompanionError.unavailable })
        model.setActive(true)
        await model.refresh(now: now)
        let audioCount = await audioReads.count, screenCount = await screenReads.count
        XCTAssertEqual(audioCount, 0)
        XCTAssertEqual(screenCount, 0)
        XCTAssertTrue(model.transcripts.isEmpty)
        XCTAssertFalse(model.screensHaveMore)
        XCTAssertFalse(model.presentationReady)
        XCTAssertNotNil(model.audioError)
        model.setActive(false)
    }

    func testOlderRequestsBehindHeldHeadShareOneSQLiteContinuation() async throws {
        let fixture = try await makePaginationFixture()
        let headGate = LiveContextReadGate(), olderGate = LiveContextReadGate()
        let headCalls = LiveContextReadCounter(), olderCalls = LiveContextReadCounter()
        let olderReadStarted = expectation(description: "One continuation reaches SQLite")
        olderReadStarted.assertForOverFulfill = true
        let model = makeModel { interval, cursor in
            if cursor == nil {
                if await headCalls.recordAndReturn() == 2 { await headGate.wait() }
            } else {
                await olderCalls.record()
                olderReadStarted.fulfill()
                await olderGate.wait()
            }
            return try await fixture.queries.getContextPage(from: interval.start, to: interval.end, limit: 2, before: cursor)
        }
        model.setActive(true)
        await model.refresh(now: now)
        XCTAssertEqual(model.transcripts.map(\.id), Array(fixture.ids.prefix(2)))
        XCTAssertNotNil(model.nextCursor)
        model.pauseFollowing()
        let retainedInterval = model.interval
        let head = Task { await model.refresh(now: now.addingTimeInterval(30)) }
        await headGate.waitUntilEntered()
        let callersStarted = expectation(description: "Both older callers wait behind the head")
        callersStarted.expectedFulfillmentCount = 2
        let first = Task { callersStarted.fulfill(); await model.refresh(now: now.addingTimeInterval(30), loadOlder: true) }
        let second = Task { callersStarted.fulfill(); await model.refresh(now: now.addingTimeInterval(30), loadOlder: true) }
        await fulfillment(of: [callersStarted], timeout: 2)
        await headGate.open()
        await fulfillment(of: [olderReadStarted], timeout: 2)
        await olderGate.open()
        await head.value; await first.value; await second.value
        let continuationCount = await olderCalls.count
        XCTAssertEqual(continuationCount, 1)
        XCTAssertEqual(model.transcripts.map(\.id), Array(fixture.ids.prefix(4)))
        XCTAssertEqual(model.interval, retainedInterval)
        XCTAssertNotNil(model.nextCursor, "Duplicate older callers must not drain the remaining page")
        XCTAssertFalse(model.followingLive)
        model.setActive(false)
        try await fixture.database.close()
    }

    func testLazyAudioHistoryContinuesWhenOptionalSpeakerReadFails() async throws {
        let fixture = try await makePaginationFixture()
        let model = LiveContextWorkspaceModel(loadAudio: { interval, cursor, query in
            try await fixture.queries.getContextPage(from: interval.start, to: interval.end, limit: 2, before: cursor, query: query)
        }, loadScreens: { _ in .init(rows: [], hasMore: false) },
           loadSpeakers: { _, _ in throw CompanionError.unavailable })
        model.setActive(true)
        await model.refresh(now: now)
        XCTAssertNotNil(model.speakerError)
        XCTAssertEqual(model.transcripts.map(\.id), Array(fixture.ids.prefix(2)))
        await model.loadOlderIfNeeded(near: model.transcriptItems.last?.id)
        XCTAssertEqual(model.transcripts.map(\.id), Array(fixture.ids.prefix(4)),
            "Unavailable optional speaker enrichment must not block scrolling saved audio")
        model.setActive(false)
        try await fixture.database.close()
    }

    func testHidingCancelsOlderRequestWaitingBehindHeldSQLiteHead() async throws {
        let fixture = try await makePaginationFixture()
        let gate = LiveContextReadGate(), heads = LiveContextReadCounter(), olderCalls = LiveContextReadCounter()
        let model = makeModel { interval, cursor in
            if cursor == nil {
                if await heads.recordAndReturn() == 2 { await gate.wait() }
            } else { await olderCalls.record() }
            return try await fixture.queries.getContextPage(from: interval.start, to: interval.end, limit: 2, before: cursor)
        }
        model.setActive(true)
        await model.refresh(now: now)
        let retained = model.transcripts.map(\.id)
        model.pauseFollowing()
        let head = Task { await model.refresh(now: now.addingTimeInterval(30)) }
        await gate.waitUntilEntered()
        let started = expectation(description: "Older caller waits behind the head")
        let older = Task { started.fulfill(); await model.refresh(now: now.addingTimeInterval(30), loadOlder: true) }
        await fulfillment(of: [started], timeout: 2)
        model.setActive(false)
        await gate.open()
        await head.value; await older.value
        let continuationCount = await olderCalls.count
        XCTAssertEqual(continuationCount, 0)
        XCTAssertEqual(model.transcripts.map(\.id), retained)
        XCTAssertFalse(model.presentationReady)
        try await fixture.database.close()
    }

    func testEmptyIncompleteAudioScanAdvancesOnlyExplicitlyAndPreservesPinnedCoverage() async throws {
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        // These completed historical recordings do not overlap the recent
        // interval. A much earlier long recording does, after the first bound.
        for index in 0..<600 {
            let start = now.addingTimeInterval(-3_600 - Double(index) * 4)
            _ = try await queries.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(3),
                source: .microphone, audioPath: "audio/history-\(index).m4a", audioSize: 20)
        }
        let overlap = try await queries.insertRawBatch(startTime: now.addingTimeInterval(-7_200),
            endTime: now.addingTimeInterval(-10), source: .microphone, audioPath: "audio/long-overlap.m4a", audioSize: 20)
        let calls = LiveContextReadCounter()
        let model = makeModel { interval, cursor in
            await calls.record()
            return try await queries.getContextPage(from: interval.start, to: interval.end, limit: 2, before: cursor)
        }
        model.configure(range: .recent, from: now.addingTimeInterval(-1_800), to: now, query: "")
        model.setActive(true)
        await model.refresh(now: now)
        var count = await calls.count
        XCTAssertEqual(count, 1, "An accepted partial page cannot automatically drain older candidates")
        XCTAssertTrue(model.transcripts.isEmpty)
        XCTAssertTrue(model.audioScanIncomplete)
        XCTAssertNotNil(model.audioScanNotice)
        XCTAssertNotNil(model.nextCursor)
        XCTAssertTrue(model.canLoadOlder)
        model.pauseFollowing()
        let retainedInterval = model.interval
        // A fresh head can prove another matching page, but must not overwrite
        // the pinned empty page's incomplete scan or its continuation.
        for index in 0..<3 {
            let start = now.addingTimeInterval(-20 - Double(index) * 4)
            _ = try await queries.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(3),
                source: .microphone, audioPath: "audio/new-head-\(index).m4a", audioSize: 20)
        }
        await model.refresh(now: now.addingTimeInterval(30))
        count = await calls.count
        XCTAssertEqual(count, 2)
        XCTAssertTrue(model.transcripts.isEmpty)
        XCTAssertTrue(model.audioScanIncomplete)
        XCTAssertNotNil(model.audioScanNotice)
        XCTAssertEqual(model.interval, retainedInterval)
        await model.refresh(now: now.addingTimeInterval(30), loadOlder: true)
        count = await calls.count
        XCTAssertEqual(count, 3)
        XCTAssertEqual(model.transcripts.map(\.id), [overlap])
        XCTAssertFalse(model.audioScanIncomplete)
        XCTAssertNil(model.audioScanNotice)
        XCTAssertNil(model.nextCursor)
        XCTAssertFalse(model.canLoadOlder)
        XCTAssertEqual(model.interval, retainedInterval)
        model.configure(range: .recent, from: now.addingTimeInterval(-1_800), to: now, query: "")
        XCTAssertFalse(model.audioScanIncomplete)
        model.setActive(false)
        try await database.close()
    }

    private func makePaginationFixture() async throws -> (database: DatabaseManager, queries: AudioTranscriptionQueries, ids: [Int64]) {
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        var ids: [Int64] = []
        for index in 0..<6 {
            let start = now.addingTimeInterval(-10 - Double(index) * 10)
            ids.append(try await queries.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(3),
                source: .microphone, audioPath: "audio/page-\(index).m4a", audioSize: 20))
        }
        return (database, queries, ids)
    }

    func testBusyAudioAdmissionRetriesWithinOneRefreshAndPublishesRecoveredPage() async {
        let saved = row(id: 81, text: "", offset: -30)
        let script = LiveContextAudioReadScript(failures: [.connectionBusy, .connectionBusy],
            page: .init(entries: [saved], nextCursor: nil))
        let model = makeModel { _, _ in try await script.read() }
        model.setActive(true)
        await model.refresh(now: now)
        let attempts = await script.attempts
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(model.transcripts.map(\.id), [saved.id])
        XCTAssertNil(model.audioError)
        XCTAssertTrue(model.presentationReady)
        model.setActive(false)
    }

    func testBusyAudioAdmissionStopsAfterThreeAttemptsAndNextRefreshCanRecover() async {
        let saved = row(id: 82, text: "", offset: -30)
        let script = LiveContextAudioReadScript(failures: Array(repeating: .connectionBusy, count: 3),
            page: .init(entries: [saved], nextCursor: nil))
        let model = makeModel { _, _ in try await script.read() }
        model.setActive(true)
        await model.refresh(now: now)
        let attempts = await script.attempts
        XCTAssertEqual(attempts, 3)
        XCTAssertTrue(model.transcripts.isEmpty)
        XCTAssertEqual(model.audioError, "Saved audio is temporarily busy. Retry in a moment.")
        await model.refresh(now: now)
        let recoveredAttempts = await script.attempts
        XCTAssertEqual(recoveredAttempts, 4)
        XCTAssertEqual(model.transcripts.map(\.id), [saved.id])
        XCTAssertNil(model.audioError)
        model.setActive(false)
    }

    func testNonBusyAudioFailuresAreReportedWithoutRetry() async {
        let cases: [(AudioContextReadError, String)] = [
            (.budgetExceeded, "This audio read exceeded its time limit. Retry or choose a narrower interval."),
            (.invalidContinuation, "This audio page is no longer available. Return to live or choose another interval."),
            (.closed, "The audio reader is unavailable. Retry when the library is ready.")
        ]
        for (failure, message) in cases {
            let script = LiveContextAudioReadScript(failures: [failure], page: .init(entries: [], nextCursor: nil))
            let model = makeModel { _, _ in try await script.read() }
            model.setActive(true)
            await model.refresh(now: now)
            let attempts = await script.attempts
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(model.audioError, message)
            model.setActive(false)
        }
    }

    func testHidingDuringBusyAudioBackoffCancelsRetryAndLatePublication() async {
        let saved = row(id: 83, text: "", offset: -30)
        let script = LiveContextAudioReadScript(failures: [.connectionBusy],
            page: .init(entries: [saved], nextCursor: nil))
        let model = makeModel { _, _ in try await script.read() }
        model.setActive(true)
        let refreshing = Task { await model.refresh(now: now) }
        await script.waitUntilAttempted()
        model.setActive(false)
        await refreshing.value
        let attempts = await script.attempts
        XCTAssertEqual(attempts, 1, "Cancellation during admission backoff must prevent a second database read")
        XCTAssertTrue(model.transcripts.isEmpty)
        XCTAssertNil(model.audioError)
        XCTAssertFalse(model.presentationReady)
    }

    private func makeModel(loadAudio: @escaping @Sendable (DateInterval, AudioContextCursor?) async throws -> AudioContextPage) -> LiveContextWorkspaceModel {
        LiveContextWorkspaceModel(loadAudio: { interval, cursor, _ in try await loadAudio(interval, cursor) },
            loadScreens: { _ in LiveContextScreenPage(rows: [], hasMore: false) })
    }

    private func row(id: Int64, text: String, offset: TimeInterval) -> AudioTranscription {
        AudioTranscription(id: id, sessionID: nil, text: text, startTime: now.addingTimeInterval(offset),
            endTime: now.addingTimeInterval(offset + 3), source: .microphone, confidence: nil,
            createdAt: now, transcriptStatus: text.isEmpty ? "pending" : "transcribed")
    }
}

private actor LiveContextReadCounter {
    private(set) var count = 0
    func record() { count += 1 }
    func recordAndReturn() -> Int { count += 1; return count }
}

private actor LiveContextSourceAvailability {
    private(set) var available = false
    func setAvailable(_ value: Bool) { available = value }
}

private actor LiveContextReadGate {
    private var entered = false
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var attempts = 0

    func wait() async {
        attempts += 1
        entered = true
        let waiting = enteredWaiters
        enteredWaiters = []
        waiting.forEach { $0.resume() }
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        opened = true
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }
}

private actor LiveContextAudioReadScript {
    private var failures: [AudioContextReadError]
    private let page: AudioContextPage
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var attempts = 0

    init(failures: [AudioContextReadError], page: AudioContextPage) {
        self.failures = failures; self.page = page
    }

    func read() throws -> AudioContextPage {
        attempts += 1
        let pending = waiters; waiters = []
        pending.forEach { $0.resume() }
        if !failures.isEmpty { throw failures.removeFirst() }
        return page
    }

    func waitUntilAttempted() async {
        guard attempts == 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
