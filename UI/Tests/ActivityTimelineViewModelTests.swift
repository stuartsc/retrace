import XCTest
import Foundation
import Shared
import Database
import App
import Storage
@testable import Retrace

@MainActor
final class ActivityTimelineViewModelTests: XCTestCase {
    private var database: DatabaseManager!
    private var segmentID: Int64 = 0
    private let session = UUID()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:activity_ui_\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        segmentID = try await database.insertSegment(bundleID: "word", startDate: start, endDate: start.addingTimeInterval(60),
            windowName: "Test screen", browserUrl: nil, type: 0)
    }
    override func tearDown() async throws { try await database.close() }

    func testMetadataSearchPagesBeforeOCRAndDoesNotLoseFilteredContinuation() async throws {
        for index in 1...12 { _ = try await append(index, title: index > 6 ? "Budget café" : "Other") }
        let model = ActivityTimelineViewModel(client: client(), pageSize: 2)
        model.queryText = "cafe"
        await model.refresh()
        XCTAssertEqual(model.events.map(\.event.sequence), [7, 8])
        XCTAssertTrue(model.hasMore)
        await model.loadMore()
        XCTAssertEqual(model.events.map(\.event.sequence), [7, 8, 9, 10])
        await model.loadMore()
        XCTAssertEqual(model.events.map(\.event.sequence), [7, 8, 9, 10, 11, 12])
        XCTAssertFalse(model.hasMore)
        let frames = try await database.getMostRecentFrames(limit: 1)
        XCTAssertTrue(frames.isEmpty)
    }

    func testEmptyFilteredPageStillOffersContinuation() async throws {
        for index in 1...4 { _ = try await append(index, title: index < 3 ? "Excluded" : "Visible") }
        var source = client()
        let db = database!
        source.activity = { query in
            let page = try await db.searchActivity(query)
            return ActivityPage(events: page.events.filter { $0.event.context?.windowTitle != "Excluded" }, nextSequence: page.nextSequence)
        }
        let model = ActivityTimelineViewModel(client: source, pageSize: 2)
        await model.refresh()
        XCTAssertTrue(model.events.isEmpty)
        XCTAssertTrue(model.hasMore)
        await model.loadMore()
        XCTAssertEqual(model.events.map(\.event.sequence), [3, 4])
        XCTAssertFalse(model.hasMore)
    }

    func testSelectedCorrectionDraftThenPendingAndRevokePreservesRawMetadata() async throws {
        let event = try await append(1, title: "Original")
        let model = ActivityTimelineViewModel(client: client())
        await model.refresh()
        model.selectedEventIDs = [event.id]
        await model.submitCorrection(action: .rename, label: "Draft", confirmed: false)
        XCTAssertEqual(model.episodes.first?.title, "Original")
        await model.submitCorrection(action: .rename, label: "Reviewed", confirmed: true)
        XCTAssertEqual(model.episodes.first?.title, "Reviewed")
        XCTAssertEqual(model.corrections.last?.status, .pending)
        let pending = try XCTUnwrap(model.corrections.last)
        await model.revoke(pending)
        XCTAssertEqual(model.episodes.first?.title, "Original")
        let retained = try await database.activityEvent(id: event.id)
        XCTAssertEqual(retained?.event.context?.windowTitle, "Original")
    }

    func testCommittedCorrectionSurvivesFailedReadbackWithHonestSavedStatus() async throws {
        let event = try await append(1, title: "Original")
        var source = client(); let db = database!
        source.corrections = {
            let receipts = try await db.activityCorrections()
            if !receipts.isEmpty { throw EvidenceUnavailableReason.sourceDisconnected }
            return receipts
        }
        let model = ActivityTimelineViewModel(client: source)
        await model.refresh(); model.selectedEventIDs = [event.id]
        await model.submitCorrection(action: .rename, label: "Reviewed", confirmed: true)
        let receipts = try await database.activityCorrections()
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(model.corrections.map(\.command.id), receipts.map(\.command.id))
        XCTAssertEqual(model.episodes.first?.title, "Reviewed")
        XCTAssertTrue(model.message?.contains("saved") == true)
        XCTAssertTrue(model.message?.contains("refresh") == true)
        XCTAssertFalse(model.message?.contains("could not be saved") == true)
    }

    func testCommittedUndoSurvivesFailedReadbackWithHonestSavedStatus() async throws {
        let event = try await append(1, title: "Original")
        let original = try await database.submitActivityCorrection(ActivityCorrection(targetEventIDs: [event.id],
            expectedRevision: 0, action: .rename, label: "Reviewed", confirmed: true))
        var source = client(); let db = database!
        source.corrections = {
            let receipts = try await db.activityCorrections()
            if receipts.count > 1 { throw EvidenceUnavailableReason.sourceDisconnected }
            return receipts
        }
        let model = ActivityTimelineViewModel(client: source)
        await model.refresh(); await model.revoke(original)
        let receipts = try await database.activityCorrections()
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(Set(model.corrections.map(\.command.id)), Set(receipts.map(\.command.id)))
        XCTAssertEqual(model.episodes.first?.title, "Original")
        XCTAssertTrue(model.message?.contains("saved") == true)
        XCTAssertTrue(model.message?.contains("refresh") == true)
        XCTAssertFalse(model.message?.contains("could not be saved") == true)
    }

    func testDelayedPageCannotDiscardAConfirmedCorrectionOrItsUndoReceipt() async throws {
        let first = try await append(1, title: "First")
        _ = try await append(2, title: "Second")
        let gate = RecallResolutionGate()
        var source = client(); let db = database!
        source.corrections = {
            let receipts = try await db.activityCorrections()
            if await gate.armed { await gate.enter() }
            return receipts
        }
        let model = ActivityTimelineViewModel(client: source, pageSize: 1)
        await model.refresh(); await gate.arm()
        let paging = Task { await model.loadMore() }
        await gate.waitUntilEntered()
        model.selectedEventIDs = [first.id]
        await model.submitCorrection(action: .rename, label: "Saved while paging", confirmed: true)
        let committed = model.corrections
        XCTAssertEqual(committed.count, 1)
        await gate.release(); await paging.value
        XCTAssertEqual(model.corrections.map(\.command.id), committed.map(\.command.id))
        XCTAssertEqual(model.episodes.first?.title, "Saved while paging")
        XCTAssertEqual(model.events.count, 2, "The new page still arrives while its stale correction snapshot is ignored")
    }

    func testDelayedPageCannotRestoreDisabledStateAfterContextCollectionIsEnabled() async throws {
        _ = try await append(1, title: "First")
        _ = try await append(2, title: "Second")
        let gate = RecallResolutionGate(), control = RecallContextControl()
        var source = client()
        source.contextEnabled = {
            let enabled = await control.enabled
            if await gate.armed { await gate.enter() }
            return enabled
        }
        source.setContextEnabled = { await control.set($0) }
        let model = ActivityTimelineViewModel(client: source, pageSize: 1)
        await model.refresh(); await gate.arm()
        let paging = Task { await model.loadMore() }
        await gate.waitUntilEntered()
        await model.setContextCollection(true)
        XCTAssertEqual(model.contextEnabled, true)
        await gate.release(); await paging.value
        XCTAssertEqual(model.contextEnabled, true, "A stale metadata page cannot misrepresent the acknowledged capture setting")
        let enabled = await control.enabled
        XCTAssertTrue(enabled)
        XCTAssertEqual(model.events.count, 2)
    }

    func testShortVisitCountIncludesInterruptionsInsideGroupedEpisodes() async throws {
        for (index, offset) in [0.0, 20, 22, 42].enumerated() {
            let chat = index == 1
            _ = try await database.appendActivity(ActivityEvent(sessionID: session, sequence: Int64(index + 1),
                observedAt: start.addingTimeInterval(offset), monotonicTime: offset,
                kind: index == 3 ? .heartbeat : .focus, coverage: .observed,
                context: ActivityContext(appBundleID: chat ? "chat" : "word", appName: chat ? "Chat" : "Word",
                    processID: chat ? 2 : 1, processGeneration: chat ? "chat" : "word",
                    windowID: chat ? 2 : 1, windowTitle: chat ? "Quick lookup" : "Proposal",
                    documentID: chat ? "chat-a" : "doc-a"), method: "timed-ui-fixture"))
        }
        let model = ActivityTimelineViewModel(client: client())
        await model.refresh()
        XCTAssertEqual(model.episodes.count, 1)
        XCTAssertEqual(model.hiddenGlanceCount, 1, "A grouped document episode still contains the two-second visit")
        model.hideGlances = true
        XCTAssertEqual(model.visibleEpisodes.count, 1, "The surrounding document work remains visible")
        XCTAssertEqual(model.visibleIntervals(in: try XCTUnwrap(model.episodes.first)).map { $0.context?.appBundleID }, ["word", "word"])
        XCTAssertEqual(model.episodes.flatMap(\.intervals).count, 3, "Presentation suppression never deletes intervals")
        model.hideGlances = false
        XCTAssertEqual(model.visibleIntervals(in: try XCTUnwrap(model.episodes.first)).count, 3)
    }

    func testBriefVisitsStayVisibleUntilExplicitlyHiddenAndGroupingIsReversible() async throws {
        _ = try await append(1, title: "Budget")
        _ = try await append(2, title: "Quick lookup")
        _ = try await append(3, title: "Budget")
        let model = ActivityTimelineViewModel(client: client())
        await model.refresh()
        XCTAssertFalse(model.hideGlances)
        XCTAssertEqual(model.visibleEpisodes.count, model.episodes.count)
        await model.setGrouped(false)
        let ungroupedCount = model.episodes.count
        await model.setGrouped(true)
        await model.setGrouped(false)
        XCTAssertEqual(model.episodes.count, ungroupedCount)
        model.hideGlances = true
        XCTAssertGreaterThan(model.hiddenGlanceCount, 0)
        model.hideGlances = false
        XCTAssertEqual(model.visibleEpisodes.count, model.episodes.count)
    }

    func testSlowOldResolutionCannotOverwriteNewSelectionOrReopenAfterClose() async throws {
        let first = try await append(1, title: "First")
        let second = try await append(2, title: "Second")
        let firstRef = EvidenceRef.activity(ActivityEvidenceRef(storeID: first.storeID, eventID: first.id))
        let secondRef = EvidenceRef.activity(ActivityEvidenceRef(storeID: second.storeID, eventID: second.id))
        let gate = RecallResolutionGate()
        var source = client()
        source.resolve = { ref in
            if ref == firstRef { await gate.enter(); return .activity(first) }
            return .activity(second)
        }
        let model = ActivityTimelineViewModel(client: source)
        let old = Task { await model.openEvidence(firstRef) }
        await gate.waitUntilEntered()
        await model.openEvidence(secondRef)
        await gate.release()
        await old.value
        XCTAssertEqual(model.evidenceReference, secondRef)
        guard case .activity(let result) = model.resolution else { return XCTFail("Expected current activity") }
        XCTAssertEqual(result.id, second.id)
        model.cancel()
        XCTAssertNil(model.resolution)
        XCTAssertNil(model.evidenceReference)
    }

    func testRemovedAssociationDoesNotPresentAnOtherwiseRetainedScreen() async throws {
        let event = try await append(1, title: "Budget")
        let screen = ScreenEvidenceRef(storeID: event.storeID, source: .native, observationID: UUID(), frameID: FrameID(value: 99), extractionRevision: 0)
        let removed = ActivityScreenLink(id: UUID(), commitSequence: event.commitSequence + 1, eventID: event.id,
            screen: screen, capturedAt: start, method: "captured-surface-v1")
        var source = client()
        source.resolve = { _ in XCTFail("Removed association must be checked before resolving media"); return .unavailable(.recordingMissing) }
        let model = ActivityTimelineViewModel(client: source)
        await model.openEvidence(.screen(screen), link: removed)
        XCTAssertTrue(model.associationUnavailable)
        XCTAssertNil(model.resolution)
    }

    func testEvidenceDeeplinkKeepsExactSourceAndRejectsMalformedPayload() throws {
        let reference = EvidenceRef.screen(ScreenEvidenceRef(storeID: UUID(), source: .rewind,
            observationID: UUID(), frameID: FrameID(value: 7), extractionRevision: 3, blockIDs: [2]))
        let url = try XCTUnwrap(reference.deepLink)
        XCTAssertEqual(DeeplinkHandler.route(for: url), .evidence(reference))
        XCTAssertNil(DeeplinkHandler.route(for: URL(string: "retrace://evidence?ref=invalid")!))
    }

    func testContextCollectionControlPublishesAcknowledgedStateAndHasNoRecordingSideEffect() async {
        let control = RecallContextControl()
        var source = client()
        source.contextEnabled = { await control.enabled }
        source.setContextEnabled = { await control.set($0) }
        let model = ActivityTimelineViewModel(client: source)
        await model.refresh()
        XCTAssertEqual(model.contextEnabled, false)
        await model.setContextCollection(true)
        XCTAssertEqual(model.contextEnabled, true)
        await model.setContextCollection(false)
        XCTAssertEqual(model.contextEnabled, false)
        let actions = await control.actions
        XCTAssertEqual(actions, [true, false])
    }

    func testMissingImageCanShowRetainedExactTextWithoutBecomingResolvedImage() async throws {
        let metadata = FrameMetadata(appBundleID: "word", appName: "Word", windowName: "Saved title")
        let id = try await database.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: start,
            segmentID: AppSegmentID(value: segmentID), frameIndexInSegment: 0, metadata: metadata))
        let frame = FrameID(value: id)
        let text = ExtractedText(frameID: frame, timestamp: start,
            regions: [TextRegion(frameID: frame, text: "Retained amount 900", bounds: CGRect(x: 10, y: 10, width: 80, height: 10))])
        _ = try await database.commitFrameOCR(frameID: frame, text: text, frameWidth: 100, frameHeight: 100)
        let storeID = try await database.activityStoreID()
        let saved = try await database.currentScreenEvidence(frameID: frame, storeID: storeID)
        let ref = try XCTUnwrap(saved?.ref)
        var source = client(); let db = database!
        source.resolve = { _ in .unavailable(.recordingMissing) }
        source.retainedScreen = { try? await db.screenEvidence($0) }
        let model = ActivityTimelineViewModel(client: source)
        await model.openEvidence(.screen(ref))
        guard case .unavailable(.recordingMissing) = model.resolution else { return XCTFail("Missing media must remain unavailable") }
        XCTAssertEqual(model.retainedSnapshot?.text?.fullText, "Retained amount 900")
        XCTAssertEqual(model.retainedSnapshot?.ref, ref)
    }

    func testFailedMetadataReadIsAnErrorRatherThanEmptyHistory() async {
        var source = client()
        source.activity = { _ in throw EvidenceUnavailableReason.sourceDisconnected }
        let model = ActivityTimelineViewModel(client: source)
        await model.refresh()
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.isLoading)
    }

    func testDeleteSelectedActivityRefreshesProjectionAndClosesEvidence() async throws {
        let event = try await append(1, title: "Delete selection")
        let model = ActivityTimelineViewModel(client: client())
        await model.refresh()
        model.selectedEventIDs = [event.id]
        await model.openEvidence(.activity(ActivityEvidenceRef(storeID: event.storeID, eventID: event.id)))
        await model.deleteSelected()
        XCTAssertTrue(model.events.isEmpty)
        XCTAssertNil(model.evidenceReference)
        let deleted = try await database.activityEvent(id: event.id)
        XCTAssertNil(deleted)
    }

    func testKnownDocumentScopeRejectsMixedDocumentsWithoutSendingCommand() async throws {
        let first = try await append(1, title: "First document")
        let second = try await append(2, title: "Second document")
        let model = ActivityTimelineViewModel(client: client())
        await model.refresh(); model.selectedEventIDs = [first.id, second.id]
        await model.submitCorrection(action: .assignProject, label: "Project", scope: .document, confirmed: true)
        XCTAssertTrue(model.corrections.isEmpty)
        XCTAssertNotNil(model.message)
    }

    func testRealScreenLinkPagesAndConcurrentDeletionCannotPublishRemovedAssociation() async throws {
        let event = try await append(1, title: "Budget")
        var links: [ActivityScreenLink] = []
        for _ in 0..<23 { links.append(try await screenLink(event)) }
        let gate = RecallResolutionGate()
        var source = client(); let db = database!
        source.resolve = { ref in
            await gate.enter()
            if case .screen(let screen) = ref, let saved = try? await db.screenEvidence(screen) {
                let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                context.setFillColor(CGColor(gray: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
                return .screen(saved, image: context.makeImage()!)
            }
            return .unavailable(.evidenceDeleted)
        }
        let model = ActivityTimelineViewModel(client: source)
        await model.refresh()
        let interval = try XCTUnwrap(model.episodes.first?.intervals.first)
        await model.loadLinks(for: interval)
        XCTAssertEqual(model.linksByInterval[interval.id]?.count, 20)
        XCTAssertTrue(model.intervalsWithMoreLinks.contains(interval.id))
        await model.loadLinks(for: interval)
        XCTAssertEqual(model.linksByInterval[interval.id]?.count, 23)
        XCTAssertFalse(model.intervalsWithMoreLinks.contains(interval.id))
        let link = try XCTUnwrap(links.first)
        let opening = Task { await model.openEvidence(.screen(link.screen), link: link) }
        await gate.waitUntilEntered()
        try await database.deleteActivity(eventIDs: [event.id])
        await gate.release(); await opening.value
        XCTAssertTrue(model.associationUnavailable)
        XCTAssertNil(model.resolution)
        let retained = try await database.screenEvidence(link.screen)
        XCTAssertNotNil(retained)
    }

    func testAssociationDeletedDuringRetainedTextReadCannotPublishOrphanedText() async throws {
        let event = try await append(1, title: "Budget")
        let link = try await screenLink(event)
        let gate = RecallResolutionGate()
        var source = client(); let db = database!
        source.resolve = { _ in .unavailable(.recordingMissing) }
        source.retainedScreen = { ref in
            let retained = try? await db.screenEvidence(ref)
            await gate.enter()
            return retained
        }
        let model = ActivityTimelineViewModel(client: source)
        let opening = Task { await model.openEvidence(.screen(link.screen), link: link) }
        await gate.waitUntilEntered()
        try await database.deleteActivity(eventIDs: [event.id])
        await gate.release(); await opening.value
        XCTAssertTrue(model.associationUnavailable)
        XCTAssertNil(model.evidenceReference)
        XCTAssertNil(model.resolution)
        XCTAssertNil(model.retainedSnapshot)
        let retained = try await database.screenEvidence(link.screen)
        XCTAssertNotNil(retained, "Deleting activity removes its association without deleting independent screen evidence")
    }

    func testRefinedExtractionOffersNewRevisionWhileKeepingCitedText() async throws {
        let event = try await append(1, title: "Budget")
        let link = try await screenLink(event)
        let first = try await database.screenEvidence(link.screen)
        let imageContext = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(imageContext.makeImage())
        _ = try await database.commitFrameOCR(frameID: link.screen.frameID, text: ExtractedText(frameID: link.screen.frameID,
            timestamp: event.event.observedAt.addingTimeInterval(0.5), regions: [TextRegion(frameID: link.screen.frameID,
            text: "Corrected 900", bounds: CGRect(x: 5, y: 5, width: 80, height: 10))]), frameWidth: 100, frameHeight: 100)
        var source = client(); let db = database!
        let snapshot = try XCTUnwrap(first)
        source.resolve = { _ in .screen(snapshot, image: image) }
        source.currentRevision = { try await db.currentScreenEvidence(frameID: $0.frameID, storeID: $0.storeID)?.ref.extractionRevision }
        let model = ActivityTimelineViewModel(client: source)
        await model.openEvidence(.screen(link.screen))
        XCTAssertEqual(model.evidenceReference, .screen(link.screen))
        XCTAssertEqual(model.newerRevision, link.screen.extractionRevision + 1)
        guard case .screen(let cited, _) = model.resolution else { return XCTFail("Expected cited screenshot") }
        XCTAssertEqual(cited.text?.fullText, "Amount 100")
    }

    func testConfirmedCorrectionKeepsReviewedSelectionWhenAnotherSelectionArrivesDuringPersistence() async throws {
        let first = try await append(1, title: "Reviewed target")
        let second = try await append(2, title: "Unreviewed target")
        let gate = RecallResolutionGate()
        var source = client(); let db = database!
        source.activityHealth = {
            if await gate.armed { await gate.enter() }
            return try await db.activityHealth()
        }
        let model = ActivityTimelineViewModel(client: source)
        await model.refresh(); model.selectedEventIDs = [first.id]
        await gate.arm()
        let confirmation = Task { await model.submitCorrection(action: .rename, label: "Reviewed", confirmed: true) }
        await gate.waitUntilEntered()
        model.selectedEventIDs = [second.id]
        await gate.release(); await confirmation.value
        XCTAssertEqual(model.corrections.last?.command.targetEventIDs, [first.id])
    }

    func testLegacySearchSelectionPassesOriginalSourceAndTimestampToValidatedReferenceAPI() async {
        let result = SearchResult(id: FrameID(value: 42), timestamp: start, snippet: "saved", matchedText: "saved",
            relevanceScore: 1, metadata: FrameMetadata(appName: "Imported"), segmentID: AppSegmentID(value: 1), frameIndex: 0, source: .rewind)
        var source = client()
        source.reference = { original in
            XCTAssertEqual(original.source, .rewind)
            XCTAssertEqual(original.timestamp, result.timestamp)
            XCTAssertEqual(original.id, result.id)
            throw EvidenceUnavailableReason.sourceDisconnected
        }
        source.resolve = { _ in XCTFail("Rejected old search source must not resolve another library's frame"); return .unavailable(.integrityFailure) }
        let model = ActivityTimelineViewModel(client: source)
        await model.openSearchResult(result)
        guard case .unavailable(.sourceDisconnected) = model.resolution else { return XCTFail("Expected disconnected original source") }
        XCTAssertNil(model.evidenceReference)
    }

    func testIndexedSearchCitationKeepsItsRevisionWithoutLazyFrameMaterialization() async throws {
        let event = try await append(1, title: "Budget")
        let link = try await screenLink(event)
        let result = SearchResult(id: link.screen.frameID, timestamp: link.capturedAt, snippet: "Amount", matchedText: "Amount",
            relevanceScore: 1, metadata: FrameMetadata(appName: "Word"), segmentID: AppSegmentID(value: segmentID),
            frameIndex: 0, source: .native, evidenceRef: link.screen)
        var source = client()
        source.reference = { _ in XCTFail("Saved citation must bypass lazy materialization"); throw EvidenceUnavailableReason.integrityFailure }
        let model = ActivityTimelineViewModel(client: source)
        await model.openSearchResult(result)
        XCTAssertEqual(model.evidenceReference, .screen(link.screen))
    }

    func testDelayedOldMetadataQueryCannotReplaceNewFilteredPage() async throws {
        _ = try await append(1, title: "First")
        _ = try await append(2, title: "Second")
        let gate = RecallResolutionGate()
        var source = client(); let db = database!
        source.activity = { query in
            if query.text == "First" { await gate.enter() }
            return try await db.searchActivity(query)
        }
        let model = ActivityTimelineViewModel(client: source)
        model.queryText = "First"
        let first = Task { await model.refresh() }
        await gate.waitUntilEntered()
        model.queryText = "Second"; await model.refresh()
        await gate.release(); await first.value
        XCTAssertEqual(model.events.map { $0.event.context?.windowTitle }, ["Second"])
        XCTAssertFalse(model.isLoading)
    }

    func testDelayedProjectionCannotRestoreOldEpisodesAfterChangedFilterFails() async throws {
        _ = try await append(1, title: "Old proposal")
        let gate = RecallResolutionGate()
        var source = client()
        let project = source.project, activity = source.activity
        source.project = { rows, commands, grouped in
            if await gate.armed { await gate.enter() }
            return await project(rows, commands, grouped)
        }
        source.activity = { query in
            if query.text == "New filter" { throw CocoaError(.fileReadNoPermission) }
            return try await activity(query)
        }
        let model = ActivityTimelineViewModel(client: source)
        await model.refresh()
        XCTAssertFalse(model.episodes.isEmpty)
        await gate.arm()
        let grouping = Task { await model.setGrouped(false) }
        await gate.waitUntilEntered()
        model.queryText = "New filter"
        await model.refresh()
        XCTAssertTrue(model.events.isEmpty)
        XCTAssertNotNil(model.message)
        await gate.release(); await grouping.value
        XCTAssertTrue(model.episodes.isEmpty, "Old projection cannot republish results for the previous filter")
    }

    func testLiveClientUsesPrivacyServiceAndCanonicalPendingCorrectionStore() async throws {
        let event = try await append(1, title: "Service-backed evidence")
        let pointer = await database.getConnection()
        let root = FileManager.default.temporaryDirectory.path
        let adapter = DataAdapter(retraceConnection: SQLiteConnection(db: try XCTUnwrap(pointer)),
            retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: root, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root), database: database)
        try await adapter.initialize()
        let service = ProgressiveRecallService(database: database, adapter: adapter,
            configuration: { CaptureConfig() }, imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
        let live = ActivityTimelineClient.live(service: service, coordinator: AppCoordinator())
        let page = try await live.activity(ActivityQuery(text: "Service-backed"))
        XCTAssertEqual(page.events.map(\.id), [event.id])
        let health = try await live.activityHealth()
        let receipt = try await live.correct(ActivityCorrection(targetEventIDs: [event.id], expectedRevision: health.correctionRevision,
            action: .rename, label: "Reviewed through service", confirmed: true))
        XCTAssertEqual(receipt.status, .pending)
        let saved = try await live.corrections()
        XCTAssertEqual(saved.last?.command.id, receipt.command.id)
        let result = await live.resolve(.activity(ActivityEvidenceRef(storeID: event.storeID, eventID: event.id)))
        guard case .activity(let observed) = result else { return XCTFail("Expected canonical activity through live service") }
        XCTAssertEqual(observed.event.context?.windowTitle, "Service-backed evidence")
        let links = try await live.links(event.id, 0, 20)
        XCTAssertTrue(links.isEmpty)
        await live.track(.opened, "success", 1)
        try await live.delete([event.id])
        let remaining = try await live.activity(ActivityQuery())
        XCTAssertTrue(remaining.events.isEmpty)
        await adapter.shutdown()
    }

    func testCorrectionUndoAndDeletionFailuresRemainVisibleWithoutChangingSelection() async throws {
        let event = try await append(1, title: "Retained on failure")
        var source = client()
        source.correct = { _ in throw EvidenceUnavailableReason.integrityFailure }
        source.delete = { _ in throw EvidenceUnavailableReason.integrityFailure }
        let model = ActivityTimelineViewModel(client: source)
        await model.refresh(); model.selectedEventIDs = [event.id]
        await model.submitCorrection(action: .rename, label: "Failure", confirmed: true)
        XCTAssertNotNil(model.message)
        XCTAssertTrue(model.corrections.isEmpty)
        let command = ActivityCorrection(targetEventIDs: [event.id], expectedRevision: 0, action: .hide, confirmed: true)
        await model.revoke(ActivityCorrectionReceipt(command: command, revision: 1, status: .pending))
        XCTAssertNotNil(model.message)
        await model.deleteSelected()
        XCTAssertNotNil(model.message)
        XCTAssertEqual(model.selectedEventIDs, [event.id])
        XCTAssertFalse(model.isMutating)
        let retained = try await database.activityEvent(id: event.id)
        XCTAssertNotNil(retained)
    }

    private func screenLink(_ event: PersistedActivityEvent) async throws -> ActivityScreenLink {
        let context = try XCTUnwrap(event.event.context)
        let captureTime = event.event.observedAt.addingTimeInterval(0.5)
        let monotonic = event.event.monotonicTime + 0.5
        let proof = ActivityCaptureIdentity(activityEventID: event.id, sessionID: event.event.sessionID,
            processID: 1, processGeneration: "process", windowID: 1, windowGeneration: "window",
            captureMonotonicTime: monotonic, documentID: context.documentID)
        let metadata = FrameMetadata(appBundleID: "word", appName: "Word", windowName: context.windowTitle, displayID: 1,
            captureContext: context, captureMonotonicTime: monotonic, activityIdentity: proof)
        let id = try await database.insertFrame(FrameReference(id: FrameID(value: 0), timestamp: captureTime,
            segmentID: AppSegmentID(value: segmentID), frameIndexInSegment: 0, metadata: metadata))
        let frame = FrameID(value: id)
        _ = try await database.commitFrameOCR(frameID: frame, text: ExtractedText(frameID: frame, timestamp: captureTime,
            regions: [TextRegion(frameID: frame, text: "Amount 100", bounds: CGRect(x: 5, y: 5, width: 80, height: 10))]),
            frameWidth: 100, frameHeight: 100)
        let snapshot = try await database.currentScreenEvidence(frameID: frame, storeID: event.storeID)
        return try await database.linkActivityScreen(eventID: event.id, screen: XCTUnwrap(snapshot).ref,
            capturedAt: captureTime, method: "captured-surface-v1")
    }

    private func append(_ index: Int, title: String) async throws -> PersistedActivityEvent {
        try await database.appendActivity(ActivityEvent(sessionID: session, sequence: Int64(index),
            observedAt: start.addingTimeInterval(Double(index * 2)), monotonicTime: Double(index * 2),
            kind: .focus, coverage: .observed, context: ActivityContext(appBundleID: "word", appName: "Word",
                processID: 1, processGeneration: "process", windowID: 1, windowGeneration: "window", windowTitle: title,
                displayID: 1, documentID: title), method: "fixture"))
    }

    private func client() -> ActivityTimelineClient {
        let db = database!
        return ActivityTimelineClient(activity: { try await db.searchActivity($0) },
            corrections: { try await db.activityCorrections() }, activityHealth: { try await db.activityHealth() },
            stageHealth: { nil }, correct: { try await db.submitActivityCorrection($0) },
            delete: { try await db.deleteActivity(eventIDs: $0) },
            links: { try await db.activityScreenLinks(eventID: $0, afterSequence: $1, limit: $2) },
            reference: { _ in throw EvidenceUnavailableReason.sourceDisconnected },
            resolve: { ref in
                if case .activity(let target) = ref, let stored = try? await db.activityEvent(id: target.eventID) { return .activity(stored) }
                return .unavailable(.evidenceDeleted)
            }, currentRevision: { _ in nil }, track: { _, _, _ in })
    }
}

private actor RecallResolutionGate {
    var armed = false
    private var entered = false
    private var entering: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    func enter() async {
        armed = false
        entered = true; entering?.resume(); entering = nil
        await withCheckedContinuation { blocked = $0 }
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { entering = $0 } } }
    func release() { blocked?.resume(); blocked = nil }
    func arm() { armed = true }
}

private actor RecallContextControl {
    var enabled = false
    var actions: [Bool] = []
    func set(_ value: Bool) { enabled = value; actions.append(value) }
}
