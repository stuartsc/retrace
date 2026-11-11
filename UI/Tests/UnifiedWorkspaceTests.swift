import AppKit
import SwiftUI
import XCTest
import Shared
import Database
import App
import Storage
@testable import Retrace

@MainActor
final class UnifiedWorkspaceTests: XCTestCase {
    private var database: DatabaseManager!
    private var adapter: DataAdapter!
    private var recall: ProgressiveRecallService!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let root = FileManager.default.temporaryDirectory.path
        adapter = DataAdapter(retraceConnection: SQLiteConnection(db: try XCTUnwrap(connection)),
            retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: root, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root), database: database)
        try await adapter.initialize()
        recall = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() },
            imageReader: { _ in XCTFail("Search admission must not decode media"); throw EvidenceUnavailableReason.unsupported })
    }

    override func tearDown() async throws {
        await adapter.shutdown()
        try await database.close()
    }

    func testLiveSQLiteRefreshKeepsPinnedHistoryAndExactExtraction() async throws {
        let first = try await insert(at: 0, text: "Proposal amount 47000")
        let model = makeModel()
        await model.refresh()
        await model.select(first)
        let reference = model.evidence.evidenceReference
        _ = try await insert(at: 2, text: "New live screen")
        _ = try await database.commitFrameOCR(frameID: first.frame.id,
            text: ExtractedText(frameID: first.frame.id, timestamp: first.frame.timestamp,
                regions: [TextRegion(frameID: first.frame.id, text: "Refined 48000", bounds: .init(x: 0, y: 0, width: 10, height: 10))]),
            frameWidth: 100, frameHeight: 100)
        await model.refresh()
        XCTAssertEqual(model.mode, .history)
        XCTAssertEqual(model.selection, first.id)
        XCTAssertEqual(model.evidence.evidenceReference, reference)
        XCTAssertEqual(model.evidence.retainedSnapshot?.text?.fullText, "Proposal amount 47000")
        XCTAssertEqual(model.evidence.newerRevision, 2)
        XCTAssertEqual(model.rows.count, 2)
    }

    func testBackForwardRetainsExactCitationsAndExplicitReturnToNow() async throws {
        let first = try await insert(at: 0, text: "First")
        let second = try await insert(at: 2, text: "Second")
        let model = makeModel()
        await model.select(first)
        let firstRef = model.evidence.evidenceReference
        await model.select(second)
        let secondRef = model.evidence.evidenceReference
        await model.goBack()
        XCTAssertEqual(model.evidence.evidenceReference, firstRef)
        XCTAssertTrue(model.canGoForward)
        await model.goForward()
        XCTAssertEqual(model.evidence.evidenceReference, secondRef)
        await model.returnToNow()
        XCTAssertEqual(model.mode, .now)
        XCTAssertEqual(model.selection, second.id)
        let third = try await insert(at: 4, text: "Newest")
        await model.refresh()
        XCTAssertEqual(model.selection, third.id)
        await model.goBack()
        XCTAssertEqual(model.evidence.evidenceReference, secondRef)
        XCTAssertEqual(model.mode, .history)
    }

    func testRefreshOfDeletedPinnedSQLiteEvidenceRevokesPresentationAndPlaybackAdmission() async throws {
        let row = try await insert(at: 0, text: "Selected evidence must disappear after deletion")
        let model = makeModel()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        _ = try await queries.insertTranscription(sessionID: nil, text: "Authored selected audio",
            startTime: row.frame.timestamp, endTime: row.frame.timestamp.addingTimeInterval(1),
            source: .microphone, confidence: nil, words: [], audioPath: nil, batchAudioPath: nil)
        let playback = TranscriptAudioPlayback(resolve: { _ in throw TranscriptAudioError.unreadable }, isMuted: true)
        let audio = WorkspaceAudioContext(playback: playback, query: { at in
            try await queries.getTranscriptions(from: at.addingTimeInterval(-1), to: at.addingTimeInterval(2))
        })
        var invalidations = 0
        model.onSelectionInvalidated = { invalidations += 1; audio.clear() }
        await model.select(row)
        let reference = try XCTUnwrap(model.presentedReference)
        let admission = try XCTUnwrap(model.selectionAdmission)
        let loaded = await audio.load(for: admission, model: model)
        XCTAssertTrue(loaded)
        XCTAssertEqual(audio.transcriptions.count, 1)
        let before = invalidations
        try await database.deleteFrame(id: row.frame.id)
        await model.refresh()
        XCTAssertNil(model.presentedReference)
        XCTAssertNil(model.evidence.selectedFrame)
        XCTAssertNil(model.evidence.retainedSnapshot)
        XCTAssertEqual(model.evidence.evidenceReference, reference, "Keep only the original citation for retry")
        XCTAssertFalse(model.admits(admission))
        XCTAssertTrue(audio.transcriptions.isEmpty, "Revoked screen admission must clear the transcript inspector")
        XCTAssertGreaterThan(invalidations, before, "Deletion must synchronously revoke the audio owner")
        guard case .unavailable = model.evidence.resolution else { return XCTFail("Deleted selection remained visible") }
    }

    func testTranscriptSelectionOwnsEverySuspensionAndCannotPlayAfterAnotherSelectionCloseOrSourceChange() async throws {
        let first = try await insert(at: 0, text: "First transcript screen")
        let second = try await insert(at: 2, text: "Second transcript screen")
        let db = database!
        for stage in ["seek", "anchor", "audio"] {
            for interruption in ["selection", "close", "source"] {
                let entered = expectation(description: "Transcript held at \(stage) before \(interruption)")
                let gate = WorkspaceReadGate(entered: entered)
                let model = UnifiedWorkspaceModel(evidence: EvidenceViewModel(client: evidenceClient()),
                    latest: { try await Self.rows(db) }, search: { _ in [] }, track: { _ in }, seek: { _ in
                        let rows = try await Self.rows(db)
                        if stage == "seek" { await gate.wait() }
                        return rows
                    })
                var played: [EvidenceRef] = []
                let pending = Task {
                    await model.selectTranscript(at: first.frame.timestamp, anchor: {
                        if stage == "anchor" { await gate.wait() }
                    }, loadAudio: { _ in
                        if stage == "audio" { await gate.wait() }
                        return true
                    }, play: { played.append($0.reference) })
                }
                await fulfillment(of: [entered], timeout: 5)
                if interruption == "selection" { await model.select(second) }
                else if interruption == "close" { model.close() }
                else { model.sourceDidChange() }
                await gate.release(); await pending.value
                XCTAssertTrue(played.isEmpty, "Stale transcript reached playback after \(stage)/\(interruption)")
                if interruption == "selection" { XCTAssertEqual(model.selection, second.id) }
                model.close()
            }
        }
    }

    func testDeletingLastLiveFrameAlsoClearsNowWhenLatestQueryReturnsNoRows() async throws {
        let row = try await insert(at: 0, text: "Last available live capture")
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(model.mode, .now)
        XCTAssertNotNil(model.presentedReference)
        try await database.deleteFrame(id: row.frame.id)
        await model.refresh()
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.presentedReference)
        XCTAssertNil(model.evidence.selectedFrame)
        XCTAssertNil(model.evidence.retainedSnapshot)
    }

    func testCloseRejectsLateSQLiteReadAndReopenCanRefresh() async throws {
        _ = try await insert(at: 0, text: "Private fixture")
        let entered = expectation(description: "SQLite result delayed")
        let gate = WorkspaceReadGate(entered: entered)
        let db = database!
        let model = makeModel(latest: {
            let values = try await Self.rows(db)
            await gate.wait()
            return values
        })
        let pending = Task { await model.refresh() }
        await fulfillment(of: [entered], timeout: 2)
        model.close()
        await gate.release()
        await pending.value
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.selection)
        XCTAssertNil(model.evidence.resolution)
        model.reopen()
        await model.refresh()
        XCTAssertEqual(model.rows.count, 1)
    }

    func testNewSelectionAndCloseFenceLateEvidenceResolution() async throws {
        let first = try await insert(at: 0, text: "Old")
        let second = try await insert(at: 2, text: "New")
        let entered = expectation(description: "First evidence delayed")
        let gate = WorkspaceReadGate(entered: entered)
        var client = evidenceClient()
        let retained = client.retainedScreen
        client.retainedScreen = { reference in
            let result = await retained(reference)
            if reference.frameID == first.frame.id { await gate.wait() }
            return result
        }
        let model = makeModel(client: client)
        let pending = Task { await model.select(first) }
        await fulfillment(of: [entered], timeout: 2)
        await model.select(second)
        let accepted = model.evidence.evidenceReference
        await gate.release(); await pending.value
        XCTAssertEqual(model.selection, second.id)
        XCTAssertEqual(model.evidence.evidenceReference, accepted)
        model.close()
        XCTAssertNil(model.evidence.resolution)
        XCTAssertFalse(model.isVisible)
    }

    func testSourceReplacementDoesNotRelabelRetainedRowsOrSelection() async throws {
        let first = try await insert(at: 0, text: "Old source")
        let model = makeModel()
        await model.select(first)
        model.sourceDidChange()
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.selection, first.id)
        guard case .unavailable(.sourceDisconnected) = model.evidence.resolution else {
            return XCTFail("Source changes must clear pixels before revalidation")
        }
    }

    func testNarrowNativeLayoutUsesDrawerAndCandidateDefaultsOff() {
        let suite = "workspace-fixture-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(defaults.bool(forKey: UnifiedWorkspacePolicy.defaultsKey))
        for width in [760.0, 1_400.0] {
            let imageProbe = NSView(), inspectorProbe = NSView()
            let content = UnifiedWorkspaceColumns(width: width, showsDrawer: .constant(true),
                content: { WorkspaceNativeProbe(view: imageProbe).frame(minWidth: 200, minHeight: 200) },
                inspector: { WorkspaceNativeProbe(view: inspectorProbe).frame(minWidth: 200, minHeight: 200) })
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            let window = NSPanel(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let imageBounds = imageProbe.convert(imageProbe.bounds, to: host)
            let inspectorBounds = inspectorProbe.convert(inspectorProbe.bounds, to: host)
            XCTAssertGreaterThan(inspectorBounds.width, 250)
            if width < 1_080 {
                XCTAssertLessThan(inspectorBounds.minX, imageBounds.maxX, "Narrow inspector must overlay the image as a drawer")
            } else {
                XCTAssertGreaterThanOrEqual(inspectorBounds.minX, imageBounds.maxX, "Wide inspector must occupy its own column")
            }
            XCTAssertFalse(window.isVisible, "This native layout fixture must stay off the shared desktop")
            window.close()
        }
    }

    func testCaptureBackendChoicePreservesDecodedPrivacyAndTimingConfiguration() throws {
        let configured = CaptureConfig(captureIntervalSeconds: 5, adaptiveCaptureEnabled: false,
            deduplicationThreshold: 0.999, maxResolution: .uhd4K,
            excludedAppBundleIDs: ["private.fixture"], excludePrivateWindows: true,
            customPrivateWindowPatterns: ["private"], showCursor: false,
            redactWindowTitlePatterns: ["secret"], redactBrowserURLPatterns: ["account"],
            idleThresholdSeconds: 77, captureOnWindowChange: false, captureVisibleTextEnabled: true,
            captureGroupReceiptsEnabled: true)
        let restored = try JSONDecoder().decode(CaptureConfig.self, from: JSONEncoder().encode(configured))
        let candidate = CaptureBackendSettingsPolicy.replacing(restored, backend: .screenCaptureKitCandidate, displayPolicy: .allDisplays)
        XCTAssertEqual(candidate.backend, .screenCaptureKitCandidate)
        XCTAssertEqual(candidate.displayPolicy, .allDisplays)
        XCTAssertEqual(candidate.excludedAppBundleIDs, configured.excludedAppBundleIDs)
        XCTAssertEqual(candidate.redactWindowTitlePatterns, configured.redactWindowTitlePatterns)
        XCTAssertEqual(candidate.redactBrowserURLPatterns, configured.redactBrowserURLPatterns)
        XCTAssertEqual(candidate.idleThresholdSeconds, 77)
        XCTAssertFalse(candidate.captureOnWindowChange)
        XCTAssertFalse(candidate.showCursor)
        XCTAssertEqual(candidate.captureIntervalSeconds, 5)
        XCTAssertEqual(candidate.customPrivateWindowPatterns, ["private"])
        XCTAssertTrue(candidate.captureVisibleTextEnabled)
        XCTAssertTrue(candidate.captureGroupReceiptsEnabled)
        let rollback = CaptureBackendSettingsPolicy.replacing(candidate, backend: .legacy, displayPolicy: .activeDisplay)
        XCTAssertFalse(rollback.captureGroupReceiptsEnabled, "Legacy backend cannot be left with an unsupported switch")
        XCTAssertTrue(rollback.captureVisibleTextEnabled)
        XCTAssertEqual(rollback.redactBrowserURLPatterns, configured.redactBrowserURLPatterns)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configured)) as? [String: Any])
        legacy.removeValue(forKey: "captureVisibleTextEnabled")
        legacy.removeValue(forKey: "captureGroupReceiptsEnabled")
        let old = try JSONDecoder().decode(CaptureConfig.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(old.captureVisibleTextEnabled, "Existing settings must remain independently opt-in")
        XCTAssertFalse(old.captureGroupReceiptsEnabled)
    }

    func testBookmarkReopensExactSQLiteRevisionAndDeletionStaysUnavailable() async throws {
        let row = try await insert(at: 0, text: "Saved 47000")
        let model = makeModel()
        await model.select(row)
        await model.toggleBookmark()
        let bookmark = try XCTUnwrap(model.bookmarks.first)
        _ = try await database.commitFrameOCR(frameID: row.frame.id,
            text: ExtractedText(frameID: row.frame.id, timestamp: row.frame.timestamp,
                regions: [TextRegion(frameID: row.frame.id, text: "Changed 48000", bounds: .init(x: 0, y: 0, width: 10, height: 10))]),
            frameWidth: 100, frameHeight: 100)
        await model.openBookmark(bookmark)
        XCTAssertEqual(model.evidence.retainedSnapshot?.text?.fullText, "Saved 47000")
        XCTAssertEqual(model.evidence.evidenceReference, bookmark.reference)
        try await database.deleteFrame(id: row.frame.id)
        await model.openBookmark(bookmark)
        XCTAssertNil(model.evidence.retainedSnapshot)
        XCTAssertNil(model.presentedReference)
        await model.removeBookmark(bookmark.id)
        XCTAssertTrue(model.bookmarks.isEmpty)
    }

    func testCancelledSearchCannotRepublishLateResult() async throws {
        let row = try await insert(at: 0, text: "Search fixture")
        let entered = expectation(description: "Search held")
        let gate = WorkspaceReadGate(entered: entered)
        let client = evidenceClient()
        let ref = try await client.frameReference(row.frame.id, .native)
        let result = SearchResult(id: row.frame.id, timestamp: row.frame.timestamp, snippet: "Search fixture",
            matchedText: "Search fixture", relevanceScore: 1, metadata: row.frame.metadata,
            segmentID: row.frame.segmentID, frameIndex: 0, evidenceRef: ref)
        let model = UnifiedWorkspaceModel(evidence: EvidenceViewModel(client: client), latest: { [row] },
            search: { _ in await gate.wait(); return [result] }, track: { _ in })
        let search = Task { await model.submitSearch("fixture") }
        await fulfillment(of: [entered], timeout: 2)
        model.cancelSearch()
        await gate.release(); await search.value
        XCTAssertFalse(model.isSearching)
        XCTAssertTrue(model.searchResults.isEmpty)
    }

    func testMomentSearchCoveragePublishesWithRealSQLiteEvidenceAndClearsOnInvalidation() async throws {
        let row = try await insert(at: 0, text: "Approval NOT GRANTED for INV-8042")
        let client = evidenceClient()
        let ref = try await client.frameReference(row.frame.id, .native)
        let hit = SearchResult(id: row.frame.id, timestamp: row.frame.timestamp, snippet: "Approval NOT GRANTED for INV-8042",
            matchedText: "INV-8042", relevanceScore: 1, metadata: row.frame.metadata,
            segmentID: row.frame.segmentID, frameIndex: 0, evidenceRef: ref,
            matchExplanation: .init(bases: [.exactIdentifier], exactIdentifiers: ["INV-8042"]))
        let coverage = MomentSearchCoverage(nativeSemanticUsed: true, lexicalScanComplete: true,
            semanticScanComplete: false, nativeIndexCaughtUp: false, indexedObservations: 1,
            pendingObservations: 2, skippedObservations: 1, unavailableLexicalObservations: 0)
        let model = UnifiedWorkspaceModel(evidence: EvidenceViewModel(client: client), latest: { [row] },
            search: { _ in XCTFail("The configured moments route owns this explicit request"); return [] },
            momentSearch: { query in .init(query: .init(text: query), results: [hit], totalCount: 1,
                searchTimeMs: 1, momentCoverage: coverage) }, track: { _ in })
        await model.submitSearch("INV-8042")
        XCTAssertEqual(model.searchResults.map(\.id), [row.frame.id])
        XCTAssertEqual(model.momentCoverage, coverage)
        XCTAssertTrue(model.hasSearched)
        await model.refresh()
        XCTAssertEqual(model.searchResults.map(\.id), [row.frame.id])
        XCTAssertEqual(model.momentCoverage, coverage,
            "A routine unchanged refresh must retain the original query's work-limit and index-coverage warning")
        XCTAssertFalse(model.searchNeedsRefresh)
        try await database.deleteFrame(id: row.frame.id)
        await model.refresh()
        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertNil(model.momentCoverage, "Changed results require a new coverage scan")
        XCTAssertTrue(model.searchNeedsRefresh, "Revocation must replace old coverage with a visible stale-results disclosure")
        model.sourceDidChange()
        XCTAssertFalse(model.hasSearched)
        XCTAssertFalse(model.searchNeedsRefresh)
    }

    func testCancelledMomentSearchCannotPublishLateCoverageOrItsRealSQLiteHit() async throws {
        let row = try await insert(at: 0, text: "Authored late moment")
        let client = evidenceClient()
        let ref = try await client.frameReference(row.frame.id, .native)
        let hit = SearchResult(id: row.frame.id, timestamp: row.frame.timestamp, snippet: "Authored late moment",
            matchedText: "moment", relevanceScore: 1, metadata: row.frame.metadata,
            segmentID: row.frame.segmentID, frameIndex: 0, evidenceRef: ref)
        let entered = expectation(description: "Moment search held")
        let gate = WorkspaceReadGate(entered: entered)
        addTeardownBlock { await gate.release() }
        let model = UnifiedWorkspaceModel(evidence: EvidenceViewModel(client: client), latest: { [row] },
            search: { _ in [] }, momentSearch: { query in
                await gate.wait()
                return .init(query: .init(text: query), results: [hit], totalCount: 1, searchTimeMs: 1,
                    momentCoverage: .init(nativeSemanticUsed: true, lexicalScanComplete: true,
                        semanticScanComplete: true, nativeIndexCaughtUp: true, indexedObservations: 1,
                        pendingObservations: 0, skippedObservations: 0, unavailableLexicalObservations: 0))
            }, track: { _ in })
        let search = Task { await model.submitSearch("moment") }
        await fulfillment(of: [entered], timeout: 2)
        model.cancelSearch()
        await gate.release(); await search.value
        XCTAssertFalse(model.isSearching)
        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertNil(model.momentCoverage)
        XCTAssertFalse(model.hasSearched)
    }

    func testUnavailableSearchSelectionDoesNotReopenPreviousMoment() async throws {
        let row = try await insert(at: 0, text: "Previous recorded moment")
        let model = makeModel()
        await model.select(row)
        let ref = try await evidenceClient().frameReference(row.frame.id, .native)
        let invalid = SearchResult(id: .init(value: 999), timestamp: row.frame.timestamp,
            snippet: "Invalid selection", matchedText: "Invalid selection", relevanceScore: 1,
            metadata: row.frame.metadata, segmentID: row.frame.segmentID, frameIndex: 0, evidenceRef: ref)
        await model.select(invalid)
        model.close(); model.reopen()
        await model.refresh()
        XCTAssertNil(model.evidence.evidenceReference)
        XCTAssertNil(model.evidence.retainedSnapshot)
        guard case .unavailable(.integrityFailure) = model.evidence.resolution else {
            return XCTFail("Reopening must retry the original failed proof, never a previous moment")
        }
    }

    private func insert(at offset: Double, text: String) async throws -> DashboardScreenshotRow {
        let at = start.addingTimeInterval(offset)
        let segment = try await database.insertSegment(bundleID: "workspace.fixture", startDate: at,
            endDate: at.addingTimeInterval(1), windowName: "Fixture", browserUrl: nil, type: 0)
        let id = FrameID(value: try await database.insertFrame(FrameReference(id: .init(value: 0), timestamp: at,
            segmentID: .init(value: segment), frameIndexInSegment: 0, metadata: FrameMetadata(appName: "Fixture"))))
        try await database.markFrameReadable(frameID: id.value)
        _ = try await database.commitFrameOCR(frameID: id, text: ExtractedText(frameID: id, timestamp: at,
            regions: [TextRegion(frameID: id, text: text, bounds: .init(x: 0, y: 0, width: 10, height: 10))]),
            frameWidth: 100, frameHeight: 100)
        let rows = try await Self.rows(database)
        return try XCTUnwrap(rows.first { $0.frame.id == id })
    }

    private static func rows(_ database: DatabaseManager) async throws -> [DashboardScreenshotRow] {
        let token = try await database.activityStoreID().uuidString
        return try await database.getMostRecentFramesWithVideoInfo(limit: 100).map {
            DashboardScreenshotRow(value: $0, sourceGeneration: token)
        }
    }

    private func evidenceClient() -> EvidenceClient {
        let db = database!
        let recall = recall!
        return EvidenceClient(reference: { result in try XCTUnwrap(result.evidenceRef) },
            frameReference: { id, _ in
                let store = try await db.activityStoreID()
                let snapshot = try await db.currentScreenEvidence(frameID: id, storeID: store)
                return try XCTUnwrap(snapshot).ref
            }, resolve: { _ in .unavailable(.recordingMissing) },
            currentRevision: { ref in try await db.currentScreenEvidence(frameID: ref.frameID, storeID: ref.storeID)?.ref.extractionRevision },
            track: { _, _, _ in }, retainedScreen: { try? await db.screenEvidence($0) },
            sourceGeneration: { _ in try await db.activityStoreID().uuidString },
            presentationStamp: { try await recall.presentationStamp(sources: $0) })
    }

    private func makeModel(client: EvidenceClient? = nil,
        latest: (@Sendable () async throws -> [DashboardScreenshotRow])? = nil) -> UnifiedWorkspaceModel {
        let db = database!
        return UnifiedWorkspaceModel(evidence: EvidenceViewModel(client: client ?? evidenceClient()),
            latest: latest ?? { try await Self.rows(db) }, search: { _ in [] }, track: { _ in })
    }
}

private struct WorkspaceNativeProbe: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) { }
}

private actor WorkspaceReadGate {
    let entered: XCTestExpectation
    var opened = false
    var continuation: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation) { self.entered = entered }
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuation = $0; entered.fulfill() }
    }
    func release() { opened = true; continuation?.resume(); continuation = nil }
}
