import XCTest
import AppKit
import SwiftUI
import CoreMedia
import CoreVideo
import Shared
import Database
import Storage
import App
@testable import Retrace

/// Ordinary Timeline reads, using the production coordinator, private SQLite
/// and real original-frame journals. No capture device or live history is used.
@MainActor
final class TimelineOriginalFrameTests: XCTestCase {
    private var root: URL!
    private var services: ServiceContainer!
    private var database: DatabaseManager!
    private var adapter: DataAdapter!
    private var coordinator: AppCoordinator!
    private var model: SimpleTimelineViewModel!
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    private let pathID = VideoSegmentID(value: 1_700_000_000_000)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TimelineOriginal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        services = ServiceContainer(databasePath: root.appendingPathComponent("private.db").path,
            storageConfig: StorageConfig(storageRootPath: root.path))
        database = await services.database
        try await database.initialize()
        let storage = await services.storage
        try await storage.initialize(config: StorageConfig(storageRootPath: root.path))
        adapter = DataAdapter(retraceConnection: SQLiteConnection(db: await database.getConnection()),
            retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
        try await adapter.initialize()
        await services.installOriginalFrameTestAdapter(adapter)
        let coordinator = AppCoordinator(services: services)
        self.coordinator = coordinator
        model = SimpleTimelineViewModel(coordinator: coordinator,
            evidenceClient: .live(service: { try await coordinator.progressiveRecall() }),
            transientDirectory: root.appendingPathComponent("private-cache"))
    }

    override func tearDown() async throws {
        await model?.test_stopForegroundImages()
        model = nil
        await adapter?.shutdown()
        try await database?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testStatusFourOriginalDisplaysBeforeVideoFinalization() async throws {
        let rows = try await originals(status: 4)
        try await assertExactServiceReads(rows[0], gray: 30)
        model.frames = rows
        model.currentIndex = 0
        await model.test_loadForegroundImage()
        XCTAssertFalse(model.frameNotReady, "OCR/video readiness cannot hide a retained original")
        try assertDisplayed(gray: 30)
    }

    func testCompletedOCRStillReadsDistinctOriginalsWithIdenticalTimestamps() async throws {
        let rows = try await originals(status: 2)
        try await assertExactServiceReads(rows[1], gray: 220)
        model.frames = rows
        model.currentIndex = 0
        await model.test_loadForegroundImage()
        try assertDisplayed(gray: 30)
        model.currentIndex = 1
        await model.test_loadForegroundImage()
        try assertDisplayed(gray: 220)
        XCTAssertFalse(model.evidence.isPresentingEvidence, "Ordinary scrubbing keeps its existing interface")
    }

    func testHistoricalCanvasRendersVerifiedOriginalEvenWhenVideoIsEmpty() async throws {
        let rows = try await originals(status: 2)
        let service = try await coordinator.progressiveRecall()
        let reference = try await service.reference(frameID: rows[1].frame.id, source: .native)
        guard case .screen(_, let image) = await service.resolve(.screen(reference), for: .localUser) else {
            return XCTFail("Expected exact original")
        }
        model.frames = rows
        model.currentIndex = 1
        model.currentImage = NSImage(cgImage: image, size: .zero)
        let view = SimpleTimelineView(coordinator: coordinator, viewModel: model, onClose: {})
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 128, height: 128),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view.test_historicalFrameContent().frame(width: 128, height: 128)
            .environmentObject(AppCoordinatorWrapper(coordinator: coordinator)))
        panel.contentView = hosting
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.contentView = nil; panel.close() }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let rendered = try XCTUnwrap(bitmap.cgImage)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertLessThan(panel.frame.maxX, 0)
        XCTAssertEqual(try pixel(rendered), 220, accuracy: 2,
            "A separate video-size gate must not hide already verified original pixels")
    }

    func testMissingOriginalMappingNeverFallsBackToAnotherFrameIndex() async throws {
        let rows = try await originals(status: 2, mapped: false)
        model.frames = rows
        model.currentIndex = 1
        await model.test_loadForegroundImage()
        XCTAssertNil(model.currentImage)
        XCTAssertTrue(model.frameNotReady, "Missing exact mapping is pending independently of OCR status")
        let wal = await services.storage.getWALManager()
        try await wal.registerFrameID(videoID: pathID, frameID: rows[1].frame.id.value, frameIndex: 1)
        await model.test_loadForegroundImage()
        try assertDisplayed(gray: 220)
    }

    func testSameSelectionReadsRealFinalizedHEVCAfterOriginalBecomesUnavailable() async throws {
        let rows = try await originals(status: 4)
        model.frames = rows
        model.currentIndex = 1
        await model.test_loadForegroundImage()
        try assertDisplayed(gray: 220)
        let url = root.appendingPathComponent("chunks/202311/14/\(pathID.value)")
        try FileManager.default.removeItem(at: url)
        let encoder = HEVCEncoder()
        try await encoder.initialize(width: 64, height: 64, config: .default,
            outputURL: url, segmentStartTime: timestamp)
        for (index, value) in [UInt8(30), 220].enumerated() {
            var optionalBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &optionalBuffer), kCVReturnSuccess)
            let buffer = try XCTUnwrap(optionalBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<64 {
                for x in 0..<64 {
                    let offset = y * stride + x * 4
                    bytes[offset] = value; bytes[offset + 1] = value; bytes[offset + 2] = value; bytes[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try await encoder.encode(pixelBuffer: buffer, timestamp: CMTime(value: Int64(index), timescale: 30))
        }
        try await encoder.finalize()
        let size = try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        try await database.markVideoFinalized(id: rows[1].frame.videoID.value, frameCount: 2, fileSize: Int64(size))
        // Remove this test's own journal, so success must come from actual HEVC decoding.
        try FileManager.default.removeItem(at: root.appendingPathComponent("wal"))
        await model.test_loadForegroundImage()
        try assertDisplayed(gray: 220, accuracy: 12)
    }

    func testRapidScrubbingCancelsActiveReadAndKeepsOnlyLatestRequest() async throws {
        let rows = try await originals(status: 2)
        let gate = await installHeldReader()
        defer { Task { await gate.release() } }
        model.frames = rows
        model.currentIndex = 0
        model.test_requestForegroundImage()
        await fulfillment(of: [gate.entered], timeout: 3)
        model.currentIndex = 1
        model.test_requestForegroundImage()
        model.currentIndex = 0
        model.test_requestForegroundImage()
        XCTAssertNil(model.currentImage)
        await gate.release()
        await model.test_joinForegroundImages()
        try assertDisplayed(gray: 30)
        let reads = await gate.reads
        let cancelled = await gate.firstReadWasCancelled
        XCTAssertEqual(reads, 2, "Discard the first A and coalesce B/A into one fresh A")
        XCTAssertTrue(cancelled, "Selection replacement must cancel native work, not just hide its result")
    }

    func testCloseClearsPixelsAndRejectsLateReadAcrossReopen() async throws {
        let rows = try await originals(status: 2)
        model.frames = rows
        await model.test_loadForegroundImage()
        try assertDisplayed(gray: 30)
        model.handleTimelineClosed()
        XCTAssertNil(model.currentImage, "Closing clears retained presentation pixels synchronously")
        let gate = await installHeldReader()
        defer { Task { await gate.release() } }
        model.frames = rows
        model.test_requestForegroundImage()
        await fulfillment(of: [gate.entered], timeout: 3)
        model.handleTimelineClosed()
        model.handleTimelineOpened()
        model.currentIndex = 1
        model.test_requestForegroundImage()
        await gate.release()
        await model.test_joinForegroundImages()
        try assertDisplayed(gray: 220)
        let cancelled = await gate.firstReadWasCancelled
        let maxActive = await gate.maxActive
        XCTAssertTrue(cancelled)
        XCTAssertEqual(maxActive, 1, "A reopened request must join cancelled native work before starting")
    }

    func testReplacingRowsAtSameIndexImmediatelyClearsOldPixels() async throws {
        let rows = try await originals(status: 2)
        model.frames = [rows[0]]
        await model.test_loadForegroundImage()
        try assertDisplayed(gray: 30)
        model.frames = [rows[1]]
        XCTAssertNil(model.currentImage, "A replaced row at index zero is a new capture")
        await model.test_loadForegroundImage()
        try assertDisplayed(gray: 220)
    }

    func testStatusRefreshPreservesQueryProofAndRecoversPendingOriginal() async throws {
        let rows = try await originals(status: 4, mapped: false)
        model.frames = [rows[1]]
        await model.test_loadForegroundImage()
        XCTAssertTrue(model.frameNotReady)
        let wal = await services.storage.getWALManager()
        try await wal.registerFrameID(videoID: pathID, frameID: rows[1].frame.id.value, frameIndex: 1)
        // Media readiness may change without changing OCR status.
        await model.refreshProcessingStatuses()
        await model.test_joinForegroundImages()
        try assertDisplayed(gray: 220)
        try await database.updateFrameProcessingStatus(frameID: rows[1].frame.id.value, status: 2)
        await model.refreshProcessingStatuses()
        await model.test_joinForegroundImages()
        XCTAssertEqual(model.frames[0].sourceGeneration, rows[1].sourceGeneration)
        try assertDisplayed(gray: 220)
    }

    func testWrongCaptureTimeCannotDisplayAnotherImageWithSameID() async throws {
        let rows = try await originals(status: 2)
        let frame = rows[0].frame
        let wrong = FrameReference(id: frame.id, timestamp: frame.timestamp.addingTimeInterval(1),
            segmentID: frame.segmentID, videoID: frame.videoID, frameIndexInSegment: frame.frameIndexInSegment,
            metadata: frame.metadata, source: frame.source)
        model.frames = [TimelineFrame(frame: wrong, videoInfo: rows[0].videoInfo,
            processingStatus: 2, sourceGeneration: rows[0].sourceGeneration)]
        await model.test_loadForegroundImage()
        XCTAssertNil(model.currentImage)
        XCTAssertTrue(model.frameLoadError)
    }

    func testDeletionDuringNativeImageReadCannotPublishPixels() async throws {
        try await assertNativeMutationDuringRead(deny: false)
    }

    func testPrivacyChangeDuringNativeImageReadCannotPublishPixels() async throws {
        try await assertNativeMutationDuringRead(deny: true)
    }

    private func assertNativeMutationDuringRead(deny: Bool) async throws {
        let rows = try await originals(status: 2)
        let base = try await coordinator.progressiveRecall()
        let gate = OriginalReadGate(entered: expectation(description: "real native pixels held"))
        defer { Task { await gate.release() } }
        let policy = OriginalReadPolicy()
        let service = ProgressiveRecallService(database: database, adapter: adapter,
            configuration: { await policy.config() }, imageReader: { item in
                XCTAssertFalse(Thread.isMainThread, "Exact native reads must not run on MainActor")
                let ref = try await base.reference(frameID: item.frame.id, source: item.frame.source)
                guard case .screen(_, let image) = await base.resolve(.screen(ref), for: .localUser) else {
                    throw EvidenceUnavailableReason.integrityFailure
                }
                await gate.holdFirstRead()
                return image
            })
        await model.test_stopForegroundImages()
        model = SimpleTimelineViewModel(coordinator: coordinator, evidenceClient: .live(service: service),
            transientDirectory: root.appendingPathComponent("held-native"))
        model.frames = [rows[0]]
        model.test_requestForegroundImage()
        await fulfillment(of: [gate.entered], timeout: 3)
        if deny { await policy.deny() }
        else { try await database.deleteFrame(id: rows[0].frame.id) }
        await gate.release()
        await model.test_joinForegroundImages()
        XCTAssertNil(model.currentImage)
        XCTAssertTrue(model.frameLoadError)
    }

    private func installHeldReader() async -> OriginalReadGate {
        let gate = OriginalReadGate(entered: expectation(description: "first real resolution held"))
        let coordinator = coordinator!
        var client = EvidenceClient.live(service: { try await coordinator.progressiveRecall() })
        let resolve = client.resolve
        client.resolve = { reference in
            await gate.begin()
            let result = await resolve(reference)
            await gate.holdFirstRead()
            await gate.end()
            return result
        }
        await model.test_stopForegroundImages()
        model = SimpleTimelineViewModel(coordinator: coordinator, evidenceClient: client,
            transientDirectory: root.appendingPathComponent("held-read"))
        return gate
    }

    private actor OriginalReadPolicy {
        private var denied = false
        func deny() { denied = true }
        func config() -> CaptureConfig {
            CaptureConfig(excludedAppBundleIDs: denied ? ["com.test.authored"] : [])
        }
    }

    private actor OriginalReadGate {
        nonisolated let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var reads = 0
        private(set) var firstReadWasCancelled = false
        private var active = 0
        private(set) var maxActive = 0
        init(entered: XCTestExpectation) { self.entered = entered }
        func begin() { active += 1; maxActive = max(maxActive, active) }
        func end() { active -= 1 }
        func holdFirstRead() async {
            reads += 1
            guard reads == 1 else { return }
            entered.fulfill()
            if !released { await withCheckedContinuation { continuation = $0 } }
            firstReadWasCancelled = Task.isCancelled
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    func testFreshOriginalBeforeAnyOCRAppearsInRealTimelineQuery() async throws {
        let rows = try await originals(status: 4, commitText: false)
        let queried = try await model.test_readTimelineRows()
        XCTAssertEqual(Set(queried.map { $0.frame.id }), Set(rows.map { $0.frame.id }),
            "Ordinary queries must retain saved captures before video/OCR completes")
        model.frames = [rows[0]]
        await model.test_loadForegroundImage()
        try assertDisplayed(gray: 30)
    }

    func testClosingExactSelectionRetainsProofWithoutNeighbourhood() async throws {
        let rows = try await originals(status: 2)
        let service = try await coordinator.progressiveRecall()
        let reference = try await service.reference(frameID: rows[1].frame.id, source: .native)
        await model.openEvidence(.screen(reference))
        XCTAssertTrue(model.evidence.isPresentingEvidence)
        model.closeExactEvidence()
        await model.test_loadForegroundImage()
        try assertDisplayed(gray: 220)
    }

    func testClosingExactSelectionDuringAnchorReadKeepsImmutableReference() async throws {
        let rows = try await originals(status: 2)
        let service = try await coordinator.progressiveRecall()
        let reference = try await service.reference(frameID: rows[1].frame.id, source: .native)
        let gate = OriginalReadGate(entered: expectation(description: "anchor source read held"))
        var client = EvidenceClient.live(service: service)
        let sourceGeneration = client.sourceGeneration
        client.sourceGeneration = { source in
            let generation = try await sourceGeneration(source)
            await gate.holdFirstRead()
            return generation
        }
        model = SimpleTimelineViewModel(coordinator: coordinator, evidenceClient: client,
            transientDirectory: root.appendingPathComponent("held-anchor"))
        model.test_exactNeighbourhoodEnabled = true
        let opening = Task { await model.openEvidence(.screen(reference)) }
        await fulfillment(of: [gate.entered], timeout: 3)
        model.closeExactEvidence()
        await gate.release()
        await opening.value
        await model.test_loadForegroundImage()
        try assertDisplayed(gray: 220)
    }

    func testAllFilteredQueryPathsRetainPendingCapturesAndStillHideHiddenSegments() async throws {
        let rows = try await originals(status: 4, commitText: false)
        let expected = Set(rows.map { $0.frame.id })
        var metadata = FilterCriteria.none
        metadata.windowNameFilter = "Original fixture"
        func queryAll() async throws -> [[FrameWithVideoInfo]] {
            [try await adapter.getMostRecentFramesWithVideoInfo(limit: 10, filters: FilterCriteria.none),
             try await adapter.getMostRecentFramesWithVideoInfo(limit: 10, filters: metadata),
             try await adapter.getFramesWithVideoInfo(from: timestamp.addingTimeInterval(-1),
                 to: timestamp.addingTimeInterval(1), limit: 10, filters: FilterCriteria.none),
             try await adapter.getFramesWithVideoInfoBefore(timestamp: timestamp.addingTimeInterval(1), limit: 10, filters: FilterCriteria.none),
             try await adapter.getFramesWithVideoInfoAfter(timestamp: timestamp.addingTimeInterval(-1), limit: 10, filters: FilterCriteria.none)]
        }
        for items in try await queryAll() { XCTAssertEqual(Set(items.map { $0.frame.id }), expected) }
        let tags = try await database.getAllTags()
        let hidden = try XCTUnwrap(tags.first { $0.name == "hidden" })
        try await database.addTagToSegment(segmentId: SegmentID(value: rows[0].frame.segmentID.value), tagId: hidden.id)
        for items in try await queryAll() { XCTAssertTrue(items.isEmpty, "Hidden segments remain absent in every query shape") }
    }

    func testSourceInvalidationClearsImageAndCancelsPendingRead() async throws {
        let rows = try await originals(status: 2)
        model.frames = rows
        await model.test_loadForegroundImage()
        try assertDisplayed(gray: 30)
        model.invalidateCachesAndReload()
        XCTAssertNil(model.currentImage)
        let gate = await installHeldReader()
        defer { Task { await gate.release() } }
        model.frames = rows
        model.test_requestForegroundImage()
        await fulfillment(of: [gate.entered], timeout: 3)
        model.invalidateCachesAndReload()
        await gate.release()
        await model.test_joinForegroundImages()
        XCTAssertNil(model.currentImage)
        let cancelled = await gate.firstReadWasCancelled
        XCTAssertTrue(cancelled)
    }

    func testBoundaryPagingReconcilesPixelsAfterPrependAndNewestAdvance() async throws {
        let rows = try await originals(status: 2, distinctTimestamps: true)
        model.frames = [rows[1]]
        await model.test_loadForegroundImage()
        try assertDisplayed(gray: 220)
        await model.test_loadBoundary(newer: false)
        await model.test_joinForegroundImages()
        XCTAssertEqual(model.currentFrame?.id, rows[1].frame.id)
        XCTAssertEqual(model.frames.count, 2)
        try assertDisplayed(gray: 220)
        model.frames = [rows[0]]
        model.currentIndex = 0
        await model.test_loadForegroundImage()
        try assertDisplayed(gray: 30)
        await model.test_loadBoundary(newer: true)
        await model.test_joinForegroundImages()
        XCTAssertEqual(model.currentFrame?.id, rows[1].frame.id)
        try assertDisplayed(gray: 220)
    }

    func testImmediateAndDeferredWindowTrimRetainExactSelectedPixels() async throws {
        let rows = try await originals(status: 2, distinctTimestamps: true,
            values: (0..<105).map { UInt8(50 + $0) })
        for deferred in [false, true] {
            model.frames = rows
            model.currentIndex = 90
            await model.test_loadForegroundImage()
            try assertDisplayed(gray: 140)
            model.isActivelyScrolling = deferred
            model.test_trimNewerWindow()
            if deferred { XCTAssertEqual(model.frames.count, 105); model.isActivelyScrolling = false }
            await model.test_joinForegroundImages()
            XCTAssertEqual(model.frames.count, 100)
            XCTAssertEqual(model.currentFrame?.id, rows[90].frame.id)
            try assertDisplayed(gray: 140)
        }
    }

    func testRetainedNativeHostingViewReopensForegroundOwner() async throws {
        let rows = try await originals(status: 2)
        model.frames = rows
        model.currentIndex = 1
        await model.test_loadForegroundImage()
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 128, height: 128),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: Color.black.frame(width: 128, height: 128))
        panel.contentView?.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        model.handleTimelineClosed()
        let hidden = expectation(description: "native hide completed")
        let controller = TimelineWindowController(preparedWindow: panel, hostingView: hosting,
            viewModel: model, coordinator: coordinator, presentationOverrides: .init(
                show: { $0.orderFront(nil) }, fadeOut: { _, completion in completion() },
                visibility: { _ in }, refresh: {}, restoreFocus: {}, monitors: { _ in },
                hideCompleted: { hidden.fulfill() }))
        defer {
            model.stopPeriodicStatusRefresh(); model.handleTimelineClosed()
            panel.orderOut(nil); panel.close()
        }
        controller.show()
        await model.test_joinForegroundImages()
        XCTAssertNotNil(hosting.superview)
        XCTAssertFalse(panel.isKeyWindow)
        try assertDisplayed(gray: 220)
        controller.hide(restorePreviousFocus: false)
        await fulfillment(of: [hidden], timeout: 3)
        XCTAssertNil(model.currentImage)
        XCTAssertNotNil(hosting.superview, "Immediate reopen exercises the retained view, before delayed detachment")
        controller.show()
        await model.test_joinForegroundImages()
        try assertDisplayed(gray: 220)
    }

    func testFailedLiveCaptureLoadsSelectedHistoricalOriginalWithoutNavigation() async throws {
        let rows = try await originals(status: 2)
        model.frames = rows
        model.currentIndex = 1
        await model.test_loadForegroundImage()
        model.handleTimelineClosed()
        model.isInLiveMode = true
        let panel = makeOffscreenPanel()
        let controller = TimelineWindowController(preparedWindow: panel, viewModel: model,
            coordinator: coordinator, presentationOverrides: .init(show: { $0.orderFront(nil) },
                fadeOut: { _, completion in completion() }, visibility: { _ in }, refresh: {},
                restoreFocus: {}, monitors: { _ in }, liveCapture: { nil }))
        defer { model.stopPeriodicStatusRefresh(); model.handleTimelineClosed(); panel.orderOut(nil); panel.close() }
        controller.show()
        XCTAssertNil(model.currentImage)
        await controller.test_startLiveCapture()
        await model.test_joinForegroundImages()
        XCTAssertFalse(model.isInLiveMode)
        XCTAssertEqual(model.currentFrame?.id, rows[1].frame.id)
        try assertDisplayed(gray: 220)
    }

    func testFilteredOpenOwnsPresentationAcrossOldHideAndLaterClose() async throws {
        let rows = try await originals(status: 2)
        for reopenDuringHide in [true, false] {
            let gate = OriginalReadGate(entered: expectation(description: "filtered query held"))
            let service = try await coordinator.progressiveRecall()
            var client = EvidenceClient.live(service: service)
            let generation = client.sourceGeneration
            client.sourceGeneration = { source in
                let value = try await generation(source)
                await gate.holdFirstRead()
                return value
            }
            await model.test_stopForegroundImages()
            model = SimpleTimelineViewModel(coordinator: coordinator, evidenceClient: client,
                transientDirectory: root.appendingPathComponent("filtered-\(reopenDuringHide)"))
            model.frames = rows
            let panel = makeOffscreenPanel()
            let hidden = expectation(description: "old hide completed")
            var fadeCompletion: (@Sendable () -> Void)?
            let controller = TimelineWindowController(preparedWindow: panel, viewModel: model,
                coordinator: coordinator, presentationOverrides: .init(show: { $0.orderFront(nil) },
                    fadeOut: { _, completion in fadeCompletion = completion }, visibility: { _ in },
                    refresh: {}, restoreFocus: {}, monitors: { _ in }, hideCompleted: { hidden.fulfill() }))
            controller.show()
            if reopenDuringHide { controller.hide(restorePreviousFocus: false) }
            controller.showWithFilter(bundleID: "com.test.authored", windowName: "Original fixture")
            await fulfillment(of: [gate.entered], timeout: 3)
            if !reopenDuringHide {
                controller.hide(restorePreviousFocus: false)
                fadeCompletion?()
                await fulfillment(of: [hidden], timeout: 3)
            }
            await gate.release()
            await controller.test_joinFilteredOpen()
            if reopenDuringHide {
                fadeCompletion?()
                await fulfillment(of: [hidden], timeout: 3)
            }
            XCTAssertEqual(panel.isVisible, reopenDuringHide)
            XCTAssertEqual(controller.isVisible, reopenDuringHide)
            model.stopPeriodicStatusRefresh(); model.handleTimelineClosed()
            await model.test_stopForegroundImages()
            panel.orderOut(nil); panel.close()
        }
    }

    private func makeOffscreenPanel() -> NSPanel {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 128, height: 128),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        return panel
    }

    func testFilteredRowsSupersedeHeldInitialHistoryAtomically() async throws {
        let rows = try await originals(status: 2, distinctTimestamps: true)
        let gate = OriginalReadGate(entered: expectation(description: "initial history held"))
        let service = try await coordinator.progressiveRecall()
        var client = EvidenceClient.live(service: service)
        let generation = client.sourceGeneration
        client.sourceGeneration = { source in
            let value = try await generation(source)
            await gate.holdFirstRead()
            return value
        }
        model = SimpleTimelineViewModel(coordinator: coordinator, evidenceClient: client,
            transientDirectory: root.appendingPathComponent("held-initial"))
        let initial = Task { await model.loadMostRecentFrame() }
        await fulfillment(of: [gate.entered], timeout: 3)
        var criteria = FilterCriteria.none
        criteria.startDate = timestamp.addingTimeInterval(0.5)
        await model.loadFilteredFrames(criteria: criteria)
        XCTAssertEqual(model.frames.map { $0.frame.id }, [rows[1].frame.id],
            "The accepted filter must publish its rows while the older query is still held")
        await gate.release()
        await initial.value
        XCTAssertEqual(model.frames.map { $0.frame.id }, [rows[1].frame.id],
            "The older unfiltered query must not overwrite the accepted filter")
        XCTAssertEqual(model.filterCriteria.startDate, criteria.startDate)
        XCTAssertFalse(model.isLoading)
    }

    private func originals(status: Int, mapped: Bool = true, commitText: Bool = true,
                           distinctTimestamps: Bool = false, values: [UInt8] = [30, 220]) async throws -> [TimelineFrame] {
        let path = "chunks/202311/14/\(pathID.value)"
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        let videoID = try await database.insertVideoSegment(VideoSegment(id: .init(value: 0),
            startTime: timestamp, endTime: timestamp, frameCount: 0, fileSizeBytes: 0,
            relativePath: path, width: 64, height: 64))
        let metadata = FrameMetadata(appBundleID: "com.test.authored", appName: "Authored",
            windowName: "Original fixture", displayID: 1)
        let segmentID = try await database.insertSegment(bundleID: "com.test.authored", startDate: timestamp,
            endDate: timestamp, windowName: "Original fixture", browserUrl: nil, type: 0)
        let wal = await services.storage.getWALManager()
        var session = try await wal.createSession(videoID: pathID)
        var rows: [TimelineFrame] = []
        for (index, value) in values.enumerated() {
            let capturedAt = distinctTimestamps ? timestamp.addingTimeInterval(Double(index)) : timestamp
            var bytes = Data(repeating: value, count: 64 * 64 * 4)
            for offset in stride(from: 3, to: bytes.count, by: 4) { bytes[offset] = 255 }
            let raw = CapturedFrame(timestamp: capturedAt, imageData: bytes, width: 64, height: 64,
                bytesPerRow: 256, metadata: metadata)
            try await wal.appendFrame(raw, to: &session)
            let id = FrameID(value: try await database.insertFrame(FrameReference(id: .init(value: 0),
                timestamp: capturedAt, segmentID: .init(value: segmentID), videoID: .init(value: videoID),
                frameIndexInSegment: index, metadata: metadata)))
            if commitText { _ = try await database.commitFrameOCR(frameID: id,
                text: ExtractedText(frameID: id, timestamp: capturedAt, regions: [], metadata: metadata),
                frameWidth: 64, frameHeight: 64) }
            try await database.updateFrameProcessingStatus(frameID: id.value, status: status)
            if mapped { try await wal.registerFrameID(videoID: pathID, frameID: id.value, frameIndex: index) }
            let read = try await adapter.getFrameWithVideoInfoByID(id: id, source: .native)
            let item = try XCTUnwrap(read)
            XCTAssertFalse(try XCTUnwrap(item.videoInfo).isVideoFinalized)
            rows.append(TimelineFrame(frame: item.frame, videoInfo: item.videoInfo, processingStatus: item.processingStatus))
        }
        let ids = rows.map { $0.frame.id }
        let adapter = adapter!
        let queried = try await model.test_readTimelineRows {
            var items: [FrameWithVideoInfo] = []
            for id in ids {
                if let item = try await adapter.getFrameWithVideoInfoByID(id: id, source: .native) { items.append(item) }
            }
            return items
        }
        XCTAssertEqual(Set(queried.map { $0.frame.id }), Set(ids))
        return queried.sorted { $0.frame.id.value < $1.frame.id.value }
    }

    private func assertExactServiceReads(_ row: TimelineFrame, gray: UInt8) async throws {
        let service = try await coordinator.progressiveRecall()
        let reference = try await service.reference(frameID: row.frame.id, source: row.frame.source)
        guard case .screen(_, let image) = await service.resolve(.screen(reference), for: .localUser) else {
            return XCTFail("The actual exact reader must prove this fixture is readable")
        }
        XCTAssertEqual(try pixel(image), Double(gray), accuracy: 1)
    }

    private func assertDisplayed(gray: UInt8, accuracy: Double = 1,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(model.currentImage, file: file, line: line)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil), file: file, line: line)
        XCTAssertEqual(try pixel(cg), Double(gray), accuracy: accuracy, file: file, line: line)
    }

    private func pixel(_ image: CGImage) throws -> Double {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Double(try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)[0])
    }
}

private extension ServiceContainer {
    func installOriginalFrameTestAdapter(_ adapter: DataAdapter) { dataAdapter = adapter }
}
