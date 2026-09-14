import XCTest
import CoreGraphics
import AppKit
import Shared
import Database
import Storage
import App
import SQLCipher
@testable import Retrace

/// Real indexed selections and authored pixels exercise the presentation owner
/// using isolated models and owned offscreen panels, without preferences or recorded content.
@MainActor
final class TimelineEvidenceSelectionTests: XCTestCase {
    private var database: DatabaseManager!
    private var adapter: DataAdapter!
    private let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let pointer = await database.getConnection()
        let root = FileManager.default.temporaryDirectory.path
        adapter = DataAdapter(retraceConnection: SQLiteConnection(db: try XCTUnwrap(pointer)),
            retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: root, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root), database: database)
        try await adapter.initialize()
    }

    override func tearDown() async throws {
        await adapter.shutdown()
        try await database.close()
    }

    func testIndexedResultAlwaysValidatesSourceIDAndTimestampBeforeImageRead() async throws {
        _ = try await insertFrame()
        let selected = try await hit()
        XCTAssertNotNil(selected.evidenceRef)
        let probe = ImageProbe(image: try Self.image())
        let model = EvidenceViewModel(client: .live(service: service(probe)))
        for invalid in [copy(selected, source: .rewind), copy(selected, id: .init(value: 999)),
                        copy(selected, timestamp: selected.timestamp.addingTimeInterval(1))] {
            await model.openSearchResult(invalid)
            assertUnavailable(model, reason: .integrityFailure)
        }
        let rejectedReads = await probe.count
        XCTAssertEqual(rejectedReads, 0)
        await model.openSearchResult(selected)
        let snapshot = try screen(model)
        XCTAssertEqual(snapshot.ref, selected.evidenceRef)
        let acceptedReads = await probe.count
        XCTAssertEqual(acceptedReads, 1)
    }

    func testSelectedRevisionKeepsOriginalTextBoundsAndPixelsAfterRefinement() async throws {
        let frame = try await insertFrame()
        let selected = try await hit()
        let oldRef = try XCTUnwrap(selected.evidenceRef)
        let stored = try await database.screenEvidence(oldRef)
        let original = try XCTUnwrap(stored)
        try await commit(frame, text: "contract Amount 900 Status REVISED", x: 200)
        let model = EvidenceViewModel(client: .live(service: service(ImageProbe(image: try Self.image()))))
        await model.openSearchResult(selected)
        let resolved = try screen(model)
        XCTAssertEqual(resolved.ref, oldRef)
        XCTAssertEqual(resolved.text?.regions, original.text?.regions)
        XCTAssertEqual(resolved.text?.fullText, original.text?.fullText)
        XCTAssertEqual(resolved.text?.regions.first?.bounds.minX, 10)
        XCTAssertTrue(resolved.text?.fullText.contains("47000") == true)
        XCTAssertEqual(model.newerRevision, oldRef.extractionRevision + 1)
        guard case .screen(_, let image) = model.resolution else { return XCTFail("Missing exact pixels") }
        let pixel = try Self.pixel(image, x: 20)
        XCTAssertGreaterThan(pixel[0], 240)
        XCTAssertLessThan(pixel[2], 10)
    }

    func testDuplicateInFlightRequestsJoinOneRealResolution() async throws {
        _ = try await insertFrame()
        let selected = try await hit()
        let entered = expectation(description: "real resolution held")
        let gate = ResolutionGate(entered: entered)
        defer { Task { await gate.release() } }
        let probe = ImageProbe(image: try Self.image())
        var client = EvidenceClient.live(service: service(probe))
        let resolve = client.resolve
        client.resolve = { reference in await gate.hold(await resolve(reference)) }
        let model = EvidenceViewModel(client: client)
        let first = Task { await model.openSearchResult(selected) }
        await fulfillment(of: [entered], timeout: 2)
        let duplicateEntered = expectation(description: "duplicate callback entered")
        let second = Task { duplicateEntered.fulfill(); await model.openSearchResult(selected) }
        await fulfillment(of: [duplicateEntered], timeout: 2)
        await gate.release()
        await first.value; await second.value
        _ = try screen(model)
        let reads = await probe.count
        XCTAssertEqual(reads, 1, "The duplicate overlay callback must join the same request")
    }

    func testDifferentRevisionsDoNotCoalesceAndLateOldResultCannotReplaceNew() async throws {
        let frame = try await insertFrame()
        let old = try await hit()
        try await commit(frame, text: "contract Amount 900 Status REVISED", x: 200)
        let newer = try await hit()
        XCTAssertEqual(old.sourceQualifiedID, newer.sourceQualifiedID)
        XCTAssertNotEqual(old.evidenceRef, newer.evidenceRef)
        let entered = expectation(description: "old revision held")
        let gate = ResolutionGate(entered: entered)
        defer { Task { await gate.release() } }
        var client = EvidenceClient.live(service: service(ImageProbe(image: try Self.image())))
        let resolve = client.resolve
        client.resolve = { reference in
            let result = await resolve(reference)
            return reference == .screen(old.evidenceRef!) ? await gate.hold(result) : result
        }
        let model = EvidenceViewModel(client: client)
        let oldTask = Task { await model.openSearchResult(old) }
        await fulfillment(of: [entered], timeout: 2)
        let newCompleted = expectation(description: "new revision completed independently")
        let newTask = Task { await model.openSearchResult(newer); newCompleted.fulfill() }
        await fulfillment(of: [newCompleted], timeout: 2)
        await gate.release(); await oldTask.value
        await newTask.value
        XCTAssertEqual(try screen(model).ref, newer.evidenceRef)
        XCTAssertTrue(model.resolvingEvidence == false)
    }

    func testCloseClearsExactStateAndIgnoresCancellationIgnoringLateResult() async throws {
        _ = try await insertFrame()
        let selected = try await hit()
        let entered = expectation(description: "resolution held")
        let gate = ResolutionGate(entered: entered)
        defer { Task { await gate.release() } }
        var client = EvidenceClient.live(service: service(ImageProbe(image: try Self.image())))
        let resolve = client.resolve
        client.resolve = { reference in await gate.hold(await resolve(reference)) }
        let model = EvidenceViewModel(client: client)
        let task = Task { await model.openSearchResult(selected) }
        await fulfillment(of: [entered], timeout: 2)
        model.closeEvidence()
        await gate.release(); await task.value
        XCTAssertFalse(model.isPresentingEvidence)
        XCTAssertFalse(model.resolvingEvidence)
        XCTAssertNil(model.evidenceReference)
        XCTAssertNil(model.resolution)
        XCTAssertNil(model.retainedSnapshot)
        XCTAssertNil(model.selectedFrame)
        await model.openSearchResult(selected)
        XCTAssertEqual(try screen(model).ref, selected.evidenceRef)
    }

    func testOnlyInitiatingCallerCancellationInvalidatesJoinedExactResolution() async throws {
        _ = try await insertFrame()
        let selected = try await hit()
        for cancelOwner in [true, false] {
            let entered = expectation(description: "shared exact resolution held")
            let gate = ResolutionGate(entered: entered)
            defer { Task { await gate.release() } }
            var client = EvidenceClient.live(service: service(ImageProbe(image: try Self.image())))
            let resolve = client.resolve
            client.resolve = { await gate.hold(await resolve($0)) }
            let model = EvidenceViewModel(client: client)
            let owner = Task { await model.openSearchResult(selected) }
            await fulfillment(of: [entered], timeout: 2)
            let duplicateEntered = expectation(description: "duplicate joined exact resolution")
            let duplicate = Task { duplicateEntered.fulfill(); await model.openSearchResult(selected) }
            await fulfillment(of: [duplicateEntered], timeout: 2)
            if cancelOwner { owner.cancel() } else { duplicate.cancel() }
            await gate.release(); await owner.value; await duplicate.value
            if cancelOwner {
                XCTAssertFalse(model.isPresentingEvidence)
                XCTAssertNil(model.resolution)
                XCTAssertNil(model.evidenceReference)
                await model.openSearchResult(selected)
            }
            XCTAssertEqual(try screen(model).ref, selected.evidenceRef)
        }
    }

    func testFrameSelectionRejectsReusedRowWithDifferentCaptureTimeIncludingRetainedText() async throws {
        let frame = try await insertFrame()
        let stale = FrameReference(id: frame.id, timestamp: frame.timestamp.addingTimeInterval(-10),
            segmentID: frame.segmentID, frameIndexInSegment: 0, metadata: frame.metadata, source: frame.source)
        let valid = EvidenceClient.live(service: service(ImageProbe(image: try Self.image())))
        let model = EvidenceViewModel(client: valid)
        await model.openFrame(stale)
        assertUnavailable(model, reason: .integrityFailure)
        XCTAssertNil(model.retainedSnapshot)
        var missingImage = valid
        missingImage.resolve = { _ in .unavailable(.recordingMissing) }
        let retained = EvidenceViewModel(client: missingImage)
        await retained.openFrame(stale)
        assertUnavailable(retained, reason: .integrityFailure)
        XCTAssertNil(retained.retainedSnapshot)
        await model.openFrame(frame)
        XCTAssertEqual(try screen(model).frame.id, frame.id)
    }

    func testImportedReplacementWithCollidingNumericIDCannotReplaceSelectedEvidence() async throws {
        let first = try importedStore(text: "contract source Alpha")
        let second = try importedStore(text: "contract source Beta")
        await configure(first)
        let old = try await hit(source: .rewind)
        await configure(second)
        let probe = ImageProbe(image: try Self.image())
        let model = EvidenceViewModel(client: .live(service: service(probe)))
        await model.openSearchResult(old)
        // This is an unmaterialized legacy hit: its captured selection token no
        // longer agrees with the replacement database's index identity.
        assertUnavailable(model, reason: .integrityFailure)
        let staleReads = await probe.count
        XCTAssertEqual(staleReads, 0)
        let fresh = try await hit(source: .rewind)
        XCTAssertEqual(fresh.id, old.id)
        await model.openSearchResult(fresh)
        let result = try screen(model)
        XCTAssertTrue(result.text?.fullText.contains("Beta") == true)
        XCTAssertEqual(result.ref.source, .rewind)
    }

    func testFrameSourceTokenRejectsSameIDAndCaptureTimeFromReplacementBeforeRead() async throws {
        let first = try importedStore(text: "contract source Alpha")
        let second = try importedStore(text: "contract source Beta")
        await configure(first)
        let original = try await hit(source: .rewind)
        let frame = FrameReference(id: original.id, timestamp: original.timestamp, segmentID: original.segmentID,
            videoID: original.videoID, frameIndexInSegment: original.frameIndex, metadata: original.metadata, source: original.source)
        let token = try await adapter.evidenceStoreID(source: .rewind).uuidString
        await configure(second)
        let replacement = try await hit(source: .rewind)
        XCTAssertEqual(original.id, replacement.id)
        XCTAssertEqual(original.timestamp, replacement.timestamp)
        let probe = ImageProbe(image: try Self.image())
        var client = EvidenceClient.live(service: service(probe))
        let sourceAdapter = adapter!
        client.sourceGeneration = { try await sourceAdapter.evidenceStoreID(source: $0).uuidString }
        let model = EvidenceViewModel(client: client)
        await model.openFrame(frame, expectedSourceGeneration: token)
        assertUnavailable(model, reason: .sourceDisconnected)
        XCTAssertNil(model.selectedFrame)
        XCTAssertNil(model.evidenceReference)
        let reads = await probe.count
        XCTAssertEqual(reads, 0, "The stale list token must be checked before resolving replacement media")
    }

    func testFrameSourceTokenIsRecheckedAfterHeldRealResolution() async throws {
        let first = try importedStore(text: "contract source Alpha")
        let second = try importedStore(text: "contract source Beta")
        await configure(first)
        let original = try await hit(source: .rewind)
        let frame = FrameReference(id: original.id, timestamp: original.timestamp, segmentID: original.segmentID,
            videoID: original.videoID, frameIndexInSegment: original.frameIndex, metadata: original.metadata, source: original.source)
        let token = try await adapter.evidenceStoreID(source: .rewind).uuidString
        let entered = expectation(description: "original source resolved before replacement")
        let gate = ResolutionGate(entered: entered)
        defer { Task { await gate.release() } }
        var client = EvidenceClient.live(service: service(ImageProbe(image: try Self.image())))
        let sourceAdapter = adapter!
        client.sourceGeneration = { try await sourceAdapter.evidenceStoreID(source: $0).uuidString }
        let resolve = client.resolve
        client.resolve = { await gate.hold(await resolve($0)) }
        let model = EvidenceViewModel(client: client)
        let pending = Task { await model.openFrame(frame, expectedSourceGeneration: token) }
        await fulfillment(of: [entered], timeout: 2)
        await configure(second)
        await gate.release(); await pending.value
        assertUnavailable(model, reason: .sourceDisconnected)
        XCTAssertNil(model.selectedFrame)
        XCTAssertNil(model.evidenceReference)
    }

    func testTimelineKeepsExactEvidenceOutsideLoadedTapeAndMutableRefreshCannotReplaceIt() async throws {
        let selectedFrame = try await insertFrame()
        let selected = try await hit()
        let model = isolatedTimeline(client: .live(service: service(ImageProbe(image: try Self.image()))))
        // The loaded tape has no selected row. This is a real different SQLite frame.
        let other = try await insertFrame()
        model.frames = [TimelineFrame(frame: other, videoInfo: nil, processingStatus: 1)]
        model.isInLiveMode = true
        await model.openSearchResult(selected)
        XCTAssertFalse(model.isInLiveMode)
        XCTAssertEqual(model.currentFrame?.id, selectedFrame.id)
        XCTAssertEqual(model.currentFrame?.source, selectedFrame.source)
        XCTAssertEqual(model.currentTimestamp, selectedFrame.timestamp)
        XCTAssertEqual(try screen(model.evidence).ref, selected.evidenceRef)
        XCTAssertTrue(model.frames.contains { $0.frame.id == selectedFrame.id })

        try await commit(selectedFrame, text: "contract changed mutable extraction", x: 200)
        let db = database!
        model.test_refreshProcessingStatusesHooks.getFrameProcessingStatuses = { ids in
            try await db.getFrameProcessingStatuses(frameIDs: ids)
        }
        model.test_refreshProcessingStatusesHooks.getFrameWithVideoInfoByID = { _ in nil }
        await model.refreshProcessingStatuses()
        model.currentImage = NSImage(cgImage: try Self.image(), size: .zero)
        XCTAssertEqual(try screen(model.evidence).ref, selected.evidenceRef)
        XCTAssertTrue(model.evidence.selectedFrame?.id == selectedFrame.id)
        XCTAssertTrue(try screen(model.evidence).text?.fullText.contains("47000") == true)
        model.currentImage = nil
        model.navigateToFrame(model.currentIndex)
        XCTAssertFalse(model.evidence.isPresentingEvidence)
        XCTAssertNotNil(model.currentImage, "Same-index scrubbing must retain the verified historical image")
    }

    func testDeletedSelectionClearsPreviousPixelsAndNeverOpensLoadedNeighbour() async throws {
        let frame = try await insertFrame()
        let selected = try await hit()
        let neighbour = try await insertFrame()
        let model = isolatedTimeline(client: .live(service: service(ImageProbe(image: try Self.image()))))
        model.frames = [TimelineFrame(frame: neighbour, videoInfo: nil, processingStatus: 2)]
        await model.openSearchResult(selected)
        _ = try screen(model.evidence)
        try await database.deleteFrame(id: frame.id)
        await model.openSearchResult(selected)
        guard case .unavailable = model.evidence.resolution else { return XCTFail("Deleted target must stay unavailable") }
        XCTAssertNil(model.evidence.selectedFrame)
        XCTAssertNil(model.evidence.retainedSnapshot)
        XCTAssertNil(model.currentFrame, "The loaded neighbour cannot substitute for a missing exact selection")
        XCTAssertTrue(model.evidence.isPresentingEvidence)
    }

    func testSameIndexScrubAndTimelineCloseCancelPendingSelection() async throws {
        let frame = try await insertFrame()
        let selected = try await hit()
        for closeWindow in [false, true] {
            let entered = expectation(description: "exact read entered")
            let gate = ResolutionGate(entered: entered)
            var client = EvidenceClient.live(service: service(ImageProbe(image: try Self.image())))
            let resolve = client.resolve
            client.resolve = { reference in await gate.hold(await resolve(reference)) }
            let model = isolatedTimeline(client: client)
            model.frames = [TimelineFrame(frame: frame, videoInfo: nil, processingStatus: 2)]
            let pending = Task { await model.openSearchResult(selected) }
            await fulfillment(of: [entered], timeout: 2)
            if closeWindow { model.handleTimelineClosed() }
            else { model.navigateToFrame(0) }
            await gate.release(); await pending.value
            XCTAssertFalse(model.evidence.isPresentingEvidence)
            XCTAssertNil(model.evidence.resolution)
            XCTAssertNil(model.evidence.selectedFrame)
        }
    }

    func testOverlayDeliversRealSelectionOnceBeforeDismissalAndCloseCancelsQueuedNavigation() async throws {
        _ = try await insertFrame()
        let selected = try await hit()
        let probe = ImageProbe(image: try Self.image())
        let model = isolatedTimeline(client: .live(service: service(probe)))
        var delivery = SpotlightSelectionDelivery()
        var delivered: [SearchResult] = []
        var pending: Task<Void, Never>?
        let callback: (SearchResult, String) -> Void = { result, query in
            XCTAssertEqual(query, "contract")
            delivered.append(result)
            pending = model.selectSearchResult(result)
        }
        XCTAssertTrue(delivery.deliver(selected, query: "contract", to: callback))
        XCTAssertFalse(delivery.deliver(selected, query: "contract", to: callback))
        XCTAssertEqual(delivered.count, 1, "A second click during dismissal cannot schedule another navigation")
        XCTAssertEqual(delivered.first?.evidenceRef, selected.evidenceRef)
        model.handleTimelineClosed()
        await pending?.value
        XCTAssertFalse(model.evidence.isPresentingEvidence)
        let reads = await probe.count
        XCTAssertEqual(reads, 0, "Close owns cancellation even before the selection task first runs")
    }

    func testNativeOffscreenReopenFencesOldFadeCoordinatorAndRefreshCompletions() async throws {
        _ = NSApplication.shared
        _ = try await insertFrame()
        let selected = try await hit()
        for suspension in HideSuspension.allCases {
            let entered = expectation(description: "hide suspended at \(suspension)")
            let finished = expectation(description: "hide callback finished")
            let gate = ResolutionGate(entered: entered)
            if suspension == .fade { entered.fulfill() }
            let effects = WindowEffects()
            let model = isolatedTimeline(client: .live(service: service(ImageProbe(image: try Self.image()))))
            let panel = OffscreenEvidencePanel(contentRect: NSRect(x: -12_000, y: -12_000, width: 200, height: 80),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            defer { panel.orderOut(nil); panel.close(); Task { await gate.release() } }
            let controller = TimelineWindowController(preparedWindow: panel, viewModel: model, coordinator: AppCoordinator(),
                presentationOverrides: .init(show: { $0.orderFront(nil) }, fadeOut: { _, completion in
                    effects.fadeCompletion = completion
                }, visibility: { visible in
                    effects.visibility.append(visible)
                    if !visible, suspension == .coordinator { await gate.wait() }
                }, refresh: {
                    if suspension == .refresh { await gate.wait() }
                }, restoreFocus: { effects.focusRestores += 1 }, monitors: { effects.monitors.append($0) },
                hideCompleted: { finished.fulfill() }))
            controller.onClose = { effects.closes += 1 }
            controller.show()
            XCTAssertTrue(panel.isVisible)
            XCTAssertLessThan(panel.frame.maxX, -1_000)
            XCTAssertFalse(panel.isKeyWindow)
            controller.hide()
            XCTAssertEqual(effects.monitors.last, false)
            if suspension != .fade {
                effects.fadeCompletion?()
            }
            await fulfillment(of: [entered], timeout: 2)
            controller.show()
            await model.openSearchResult(selected)
            if suspension == .fade { effects.fadeCompletion?() }
            else { await gate.release() }
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertTrue(panel.isVisible, "A previous fade cannot order out the reopened native panel")
            XCTAssertFalse(panel.ignoresMouseEvents)
            XCTAssertTrue(controller.isVisible)
            XCTAssertEqual(effects.monitors.last, true, "Reopening must restore the input monitors removed by hide")
            XCTAssertEqual(effects.focusRestores, 0)
            XCTAssertEqual(effects.closes, 0)
            XCTAssertEqual(model.evidence.evidenceReference, selected.evidenceRef.map(EvidenceRef.screen))
            XCTAssertTrue(model.evidence.isPresentingEvidence)
            model.closeExactEvidence()
        }
    }

    func testExternalExactRoutesShowHistoricalEvidenceAndRejectForeignCoordinator() async throws {
        _ = NSApplication.shared
        _ = try await insertFrame()
        let selected = try await hit()
        let other = try await insertFrame()
        for initiallyVisible in [false, true] {
            let owner = AppCoordinator()
            let model = isolatedTimeline(client: .live(service: service(ImageProbe(image: try Self.image()))))
            model.frames = [TimelineFrame(frame: other, videoInfo: nil, processingStatus: 2)]
            model.isInLiveMode = true
            let panel = OffscreenEvidencePanel(contentRect: NSRect(x: -12_000, y: -12_000, width: 200, height: 80),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            defer { panel.orderOut(nil); panel.close(); model.closeExactEvidence() }
            let effects = WindowEffects()
            let controller = TimelineWindowController(preparedWindow: panel, viewModel: model, coordinator: owner,
                presentationOverrides: .init(show: { $0.orderFront(nil) }, fadeOut: { _, _ in },
                    visibility: { _ in }, refresh: {}, restoreFocus: { effects.focusRestores += 1 }, monitors: { _ in }))
            if initiallyVisible { controller.show() }
            await controller.openSearchResult(selected, coordinator: owner)
            XCTAssertTrue(panel.isVisible)
            XCTAssertTrue(controller.isVisible)
            XCTAssertFalse(model.isInLiveMode)
            XCTAssertEqual(model.evidence.evidenceReference, selected.evidenceRef.map(EvidenceRef.screen))
            XCTAssertEqual(model.currentFrame?.id, selected.id)
            XCTAssertEqual(effects.focusRestores, 0)
            model.closeExactEvidence()
            let reference = EvidenceRef.screen(try XCTUnwrap(selected.evidenceRef))
            await controller.openEvidence(reference, coordinator: owner)
            XCTAssertEqual(model.evidence.evidenceReference, reference)
            await controller.openSearchResult(copy(selected, id: other.id), coordinator: AppCoordinator())
            XCTAssertEqual(model.evidence.evidenceReference, reference, "A foreign coordinator cannot mutate this window's selection")
            controller.hide()
            XCTAssertFalse(model.evidence.isPresentingEvidence, "Close cancels exact work before any delayed fade")
        }
    }

    func testEvidenceExpansionBridgeUsesTheSelectedImmutableSQLiteRevision() async throws {
        let frame = try await insertFrame()
        let selected = try await hit()
        let model = EvidenceViewModel(client: .live(service: service(ImageProbe(image: try Self.image()))))
        await model.openSearchResult(selected)
        try await commit(frame, text: "contract replaced mutable text", x: 200)
        let reference = try XCTUnwrap(selected.evidenceRef)
        let page = try await model.expandText(.init(reference: reference, maximumUTF8Bytes: 8))
        XCTAssertEqual(page.reference, reference)
        XCTAssertEqual(page.captureTimestamp, selected.timestamp)
        XCTAssertEqual(page.fragments.map(\.text).joined(), "contract")
        XCTAssertLessThanOrEqual(page.textUTF8Bytes, 8)
        XCTAssertNotNil(page.nextCursor)
        let latest = try await hit()
        do {
            _ = try await model.expandText(.init(reference: try XCTUnwrap(latest.evidenceRef)))
            XCTFail("A page request cannot switch the selected extraction")
        } catch let reason as EvidenceUnavailableReason { XCTAssertEqual(reason, .integrityFailure) }
    }

    func testExpansionBridgeRejectsHeldPageAfterClose() async throws {
        _ = try await insertFrame()
        let selected = try await hit()
        let entered = expectation(description: "selected immutable page held")
        let gate = ResolutionGate(entered: entered)
        defer { Task { await gate.release() } }
        var client = EvidenceClient.live(service: service(ImageProbe(image: try Self.image())))
        let expand = client.expand
        client.expand = { request in
            let page = try await expand(request)
            await gate.wait()
            return page
        }
        let model = EvidenceViewModel(client: client)
        await model.openSearchResult(selected)
        let request = ScreenEvidenceExpansionRequest(reference: try XCTUnwrap(selected.evidenceRef))
        let pending = Task { try await model.expandText(request) }
        await fulfillment(of: [entered], timeout: 2)
        model.closeEvidence()
        await gate.release()
        do { _ = try await pending.value; XCTFail("A closed selection cannot expose a late page") }
        catch is CancellationError {}
        catch { XCTFail("Expected cancellation, received \(type(of: error))") }
    }

    func testExpansionBridgeRechecksCapturedSourceTokenAfterPageRead() async throws {
        let first = try importedStore(text: "contract source Alpha")
        let second = try importedStore(text: "contract source Beta")
        await configure(first)
        let original = try await hit(source: .rewind)
        let frame = FrameReference(id: original.id, timestamp: original.timestamp, segmentID: original.segmentID,
            videoID: original.videoID, frameIndexInSegment: original.frameIndex, metadata: original.metadata, source: original.source)
        let live = service(ImageProbe(image: try Self.image()))
        let token = try await live.sourceGeneration(source: frame.source)
        let entered = expectation(description: "source-qualified page held")
        let gate = ResolutionGate(entered: entered)
        defer { Task { await gate.release() } }
        var client = EvidenceClient.live(service: live)
        let expand = client.expand
        client.expand = { request in let page = try await expand(request); await gate.wait(); return page }
        let model = EvidenceViewModel(client: client)
        await model.openFrame(frame, expectedSourceGeneration: token)
        let reference = try screen(model).ref
        let pending = Task { try await model.expandText(.init(reference: reference)) }
        await fulfillment(of: [entered], timeout: 2)
        await configure(second)
        await gate.release()
        do { _ = try await pending.value; XCTFail("Replacement source must invalidate the pending page") }
        catch let reason as EvidenceUnavailableReason { XCTAssertEqual(reason, .sourceDisconnected) }
    }

    func testSourceChangeRevalidatesOriginalCitationWithoutOpeningReplacementRow() async throws {
        let first = try importedStore(text: "contract source Alpha")
        let second = try importedStore(text: "contract source Beta")
        await configure(first)
        let selected = try await hit(source: .rewind)
        let probe = ImageProbe(image: try Self.image())
        let model = isolatedTimeline(client: .live(service: service(probe)))
        await model.openSearchResult(selected)
        let original = try screen(model.evidence).ref
        await configure(second)
        await model.revalidateExactEvidence().value
        XCTAssertTrue(model.evidence.isPresentingEvidence)
        assertUnavailable(model.evidence, reason: .sourceDisconnected)
        XCTAssertNil(model.evidence.selectedFrame)
        XCTAssertNil(model.currentFrame)
        XCTAssertEqual(model.evidence.evidenceReference, .screen(original))
        let reads = await probe.count
        XCTAssertEqual(reads, 1, "Source revalidation cannot decode the replacement row")
    }

    func testLateMutableSQLiteOCRCannotRepopulatePinnedEvidenceSelectionState() async throws {
        let frame = try await insertFrame()
        let selected = try await hit()
        try await commit(frame, text: "contract newer mutable text", x: 200)
        let model = isolatedTimeline(client: .live(service: service(ImageProbe(image: try Self.image()))))
        model.frames = [TimelineFrame(frame: frame, videoInfo: nil, processingStatus: 2)]
        let entered = expectation(description: "mutable OCR read held")
        let gate = ResolutionGate(entered: entered)
        defer { Task { await gate.release() } }
        let sourceAdapter = adapter!
        model.test_ocrNodesRead = { id, source in
            let nodes = try await sourceAdapter.getAllOCRNodes(frameID: id, source: source)
            XCTAssertTrue(nodes.contains { $0.text.contains("newer mutable") })
            await gate.wait()
            return nodes
        }
        let pending = Task { await model.reloadOCRNodesOnly(for: frame.id) }
        await fulfillment(of: [entered], timeout: 2)
        await model.openSearchResult(selected)
        XCTAssertTrue(model.ocrNodes.isEmpty)
        await gate.release(); await pending.value
        XCTAssertTrue(model.ocrNodes.isEmpty, "Late ordinary OCR cannot add selectable text to the pinned revision")
        XCTAssertEqual(try screen(model.evidence).ref, selected.evidenceRef)
    }

    func testLateInitialSQLiteFailureCannotReplaceNewExactSelectionState() async throws {
        _ = try await insertFrame()
        let selected = try await hit()
        let model = isolatedTimeline(client: .live(service: service(ImageProbe(image: try Self.image()))))
        let entered = expectation(description: "initial query held before actual SQLite error")
        let gate = ResolutionGate(entered: entered)
        defer { Task { await gate.release() } }
        let connection = await database.getConnection()
        let pointer = try XCTUnwrap(connection)
        let reader = SQLiteConnection(db: pointer)
        model.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { _, _ in
            await gate.wait()
            try reader.execute(sql: "SELECT missing_authored_column FROM frame")
            XCTFail("The authored SQLite query must fail")
            return []
        }
        let pending = Task { await model.loadMostRecentFrame() }
        await fulfillment(of: [entered], timeout: 2)
        await model.openSearchResult(selected)
        await gate.release(); await pending.value
        XCTAssertNil(model.error, "A failure from the older load does not own the new selection's error state")
        XCTAssertEqual(try screen(model.evidence).ref, selected.evidenceRef)
    }

    private enum HideSuspension: CaseIterable { case fade, coordinator, refresh }
    private final class OffscreenEvidencePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }
    private final class WindowEffects {
        var fadeCompletion: (() -> Void)?
        var visibility: [Bool] = []
        var monitors: [Bool] = []
        var focusRestores = 0
        var closes = 0
    }

    private func isolatedTimeline(client: EvidenceClient) -> SimpleTimelineViewModel {
        SimpleTimelineViewModel(coordinator: AppCoordinator(), evidenceClient: client,
            transientDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("unused-timeline-\(UUID())"))
    }

    private func service(_ probe: ImageProbe) -> ProgressiveRecallService {
        ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() },
            imageReader: { _ in await probe.read() })
    }

    private func insertFrame() async throws -> FrameReference {
        let metadata = FrameMetadata(appBundleID: "com.test.authored", appName: "Authored", windowName: "Contract")
        let segment = try await database.insertSegment(bundleID: "com.test.authored", startDate: capturedAt,
            endDate: capturedAt, windowName: "Contract", browserUrl: nil, type: 0)
        let id = try await database.insertFrame(FrameReference(id: .init(value: 0), timestamp: capturedAt,
            segmentID: .init(value: segment), frameIndexInSegment: 0, metadata: metadata))
        let frame = FrameReference(id: .init(value: id), timestamp: capturedAt, segmentID: .init(value: segment),
            frameIndexInSegment: 0, metadata: metadata)
        try await commit(frame, text: "contract Amount 47000 Status SENT", x: 10)
        return frame
    }

    private func commit(_ frame: FrameReference, text: String, x: CGFloat) async throws {
        _ = try await database.commitFrameOCR(frameID: frame.id,
            text: ExtractedText(frameID: frame.id, timestamp: frame.timestamp,
                regions: [TextRegion(frameID: frame.id, text: text, bounds: CGRect(x: x, y: 10, width: 100, height: 40))],
                metadata: frame.metadata), frameWidth: 640, frameHeight: 360)
    }

    private func hit(source: FrameSource = .native) async throws -> SearchResult {
        let page = try await adapter.search(query: SearchQuery(text: "contract", limit: 5, mode: .all, sortOrder: .oldestFirst))
        return try XCTUnwrap(page.results.first { $0.source == source })
    }

    private func copy(_ result: SearchResult, source: FrameSource? = nil, id: FrameID? = nil, timestamp: Date? = nil) -> SearchResult {
        SearchResult(id: id ?? result.id, timestamp: timestamp ?? result.timestamp, snippet: result.snippet,
            matchedText: result.matchedText, relevanceScore: result.relevanceScore, metadata: result.metadata,
            segmentID: result.segmentID, videoID: result.videoID, frameIndex: result.frameIndex,
            videoPath: result.videoPath, videoFrameRate: result.videoFrameRate, source: source ?? result.source,
            highlightNode: result.highlightNode, evidenceRef: result.evidenceRef, selectionToken: result.selectionToken)
    }

    private func screen(_ model: EvidenceViewModel, file: StaticString = #filePath, line: UInt = #line) throws -> ScreenEvidenceSnapshot {
        guard case .screen(let snapshot, _) = model.resolution else {
            XCTFail("Expected exact authored screen evidence", file: file, line: line)
            throw EvidenceUnavailableReason.integrityFailure
        }
        XCTAssertTrue(model.isPresentingEvidence, file: file, line: line)
        return snapshot
    }

    private func assertUnavailable(_ model: EvidenceViewModel, reason: EvidenceUnavailableReason,
        file: StaticString = #filePath, line: UInt = #line) {
        guard case .unavailable(let actual) = model.resolution else {
            return XCTFail("Expected unavailable evidence without substitute pixels", file: file, line: line)
        }
        XCTAssertEqual(actual, reason, file: file, line: line)
    }

    private actor ImageProbe {
        let image: CGImage
        var count = 0
        init(image: CGImage) { self.image = image }
        func read() -> CGImage { count += 1; return image }
    }

    private actor ResolutionGate {
        let entered: XCTestExpectation
        var released = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        init(entered: XCTestExpectation) { self.entered = entered }
        func hold(_ result: EvidenceResolution) async -> EvidenceResolution {
            await wait()
            return result
        }
        func wait() async {
            if !released {
                entered.fulfill()
                await withCheckedContinuation { waiters.append($0) }
            }
        }
        func release() { released = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    }

    private struct ImportedStore { let reader: SQLiteConnection; let config: DatabaseConfig }

    private func importedStore(text: String) throws -> ImportedStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-evidence-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("source.sqlite").path
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &pointer), SQLITE_OK)
        let db = try XCTUnwrap(pointer)
        let writer = SQLiteConnection(db: db)
        addTeardownBlock { sqlite3_close_v2(db); try? FileManager.default.removeItem(at: root) }
        try writer.execute(sql: """
            CREATE TABLE segment(id INTEGER PRIMARY KEY,bundleID TEXT,startDate TEXT,endDate TEXT,windowName TEXT,browserUrl TEXT,type INTEGER);
            CREATE TABLE frame(id INTEGER PRIMARY KEY,createdAt TEXT,imageFileName TEXT,segmentId INTEGER,videoId INTEGER,videoFrameIndex INTEGER,encodingStatus TEXT);
            CREATE TABLE video(id INTEGER PRIMARY KEY,path TEXT,frameRate REAL,width INTEGER,height INTEGER);
            CREATE VIRTUAL TABLE searchRanking USING fts5(text,otherText,title);
            CREATE TABLE doc_segment(docid INTEGER,segmentId INTEGER,frameId INTEGER);
            INSERT INTO segment VALUES(1,'com.test.imported','2023-11-14T22:13:20.000','2023-11-14T22:13:20.000','Imported contract',NULL,0);
            INSERT INTO video VALUES(7,'recording.mp4',30,640,360);
            INSERT INTO frame VALUES(42,'2023-11-14T22:13:20.000','authored',1,7,0,'encoded');
            INSERT INTO doc_segment VALUES(1,1,42);
            """)
        let statement = try XCTUnwrap(writer.prepare(sql: "INSERT INTO searchRanking(rowid,text,otherText,title) VALUES(1,?,NULL,'Imported contract')"))
        sqlite3_bind_text(statement, 1, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        writer.finalize(statement)
        return ImportedStore(reader: try SQLiteConnection(readOnlyDatabasePath: path),
            config: DatabaseConfig(dateFormatter: DatabaseConfig.rewind.dateFormatter, storageRoot: root.path, source: .rewind, cutoffDate: .distantFuture))
    }

    private func configure(_ source: ImportedStore) async {
        await adapter.configureRewind(connection: source.reader, config: source.config,
            imageExtractor: HEVCStorageExtractor(storageRoot: source.config.storageRoot), cutoffDate: .distantFuture)
    }

    private static func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8,
            bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 360))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 320, y: 0, width: 320, height: 360))
        return try XCTUnwrap(context.makeImage())
    }

    private static func pixel(_ image: CGImage, x: Int) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let pointer = try XCTUnwrap(CFDataGetBytePtr(data))
        return Array(UnsafeBufferPointer(start: pointer + x * 4, count: 4))
    }
}
