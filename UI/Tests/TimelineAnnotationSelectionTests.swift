import XCTest
import AppKit
import Shared
import Database
import Storage
import App
@testable import Retrace

/// Native annotation mutations and menu lifetime races use authored SQLite rows.
/// No recording, preferences, production files, or screenshot decoding is started.
@MainActor
final class TimelineAnnotationSelectionTests: XCTestCase {
    func testConsecutiveMutationsRefreshRevisionAndKeepClickedLaterFrameAnchor() async throws {
        let f = try await AnnotationTimelineFixture.make()
        let model = f.model
        model.frames = Array(f.rows.prefix(2))
        model.timelineContextMenuSegmentIndex = 1
        model.showCommentSubmenu = true
        await model.loadTimelineContextMenuData()

        for body in ["First explanation", "Second explanation"] {
            let completed = expectation(description: "comment mutation joined")
            model.test_annotationMutationCompleted = { completed.fulfill() }
            model.newCommentText = body
            model.addCommentToSelectedSegment()
            await fulfillment(of: [completed], timeout: 3)
        }
        let comments = try await f.database.getCommentsForSegment(segmentId: SegmentID(value: f.rows[1].frame.segmentID.value))
        XCTAssertEqual(comments.map(\.body), ["First explanation", "Second explanation"])
        XCTAssertEqual(comments.map(\.frameID), [f.rows[1].frame.id, f.rows[1].frame.id], "The clicked later frame must remain the exact comment anchor")
        XCTAssertEqual(model.selectedBlockComments.count, 2)
        for comment in comments {
            let removed = await model.removeCommentFromSelectedTimelineBlock(comment: comment)
            XCTAssertTrue(removed, "The second deletion must use a refreshed revision in the same panel")
        }
        let remaining = try await f.database.getCommentsForSegment(segmentId: SegmentID(value: f.rows[1].frame.segmentID.value))
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(model.selectedBlockComments.isEmpty)

        for name in ["First tag", "Second tag"] {
            let completed = expectation(description: "tag mutation joined")
            model.test_annotationMutationCompleted = { completed.fulfill() }
            model.newTagName = name
            model.createAndAddTag()
            await fulfillment(of: [completed], timeout: 3)
        }
        let tags = try await f.database.getTagsForSegment(segmentId: SegmentID(value: f.rows[1].frame.segmentID.value))
        XCTAssertEqual(Set(tags.map(\.name)), ["First tag", "Second tag"])
        for tag in tags {
            let completed = expectation(description: "tag toggle joined")
            model.test_annotationMutationCompleted = { completed.fulfill() }
            model.toggleTagOnSelectedSegment(tag: tag)
            await fulfillment(of: [completed], timeout: 3)
        }
        let finalTags = try await f.database.getTagsForSegment(segmentId: SegmentID(value: f.rows[1].frame.segmentID.value))
        XCTAssertTrue(finalTags.isEmpty)
        try await f.close()
    }

    func testLateCommentSuccessAndFailureCannotReplaceSameIndexReopenedPanel() async throws {
        for fail in [false, true] {
            let f = try await AnnotationTimelineFixture.make()
            try await f.seedComment("Original A", row: f.rows[0])
            try await f.seedComment("Current B", row: f.rows[2])
            let model = f.model, entered = expectation(description: "original comment read held")
            let gate = AnnotationTimelineGate(entered: entered)
            model.frames = [f.rows[0]]
            model.timelineContextMenuSegmentIndex = 0
            model.showCommentSubmenu = true
            model.test_annotationCommentsRead = { id in
                let rows = try await f.database.getCommentsForSegment(segmentId: id)
                await gate.holdFirst()
                if fail && id == SegmentID(value: f.rows[0].frame.segmentID.value) { throw NativeAnnotationError.unavailable }
                return rows
            }
            let pending = Task { await model.loadCommentsForSelectedTimelineBlock() }
            await fulfillment(of: [entered], timeout: 3)
            model.dismissTimelineContextMenu()
            model.frames = [f.rows[2]]
            model.timelineContextMenuSegmentIndex = 0
            model.showCommentSubmenu = true
            await model.loadCommentsForSelectedTimelineBlock()
            XCTAssertEqual(model.selectedBlockComments.map(\.body), ["Current B"])
            await gate.release(); await pending.value
            XCTAssertEqual(model.selectedBlockComments.map(\.body), ["Current B"])
            XCTAssertNil(model.blockCommentsLoadError)
            XCTAssertFalse(model.isLoadingBlockComments)
            let current = try XCTUnwrap(model.selectedBlockComments.first)
            let removed = await model.removeCommentFromSelectedTimelineBlock(comment: current)
            XCTAssertTrue(removed, "A late read may not erase the reopened panel's mutation proof")
            try await f.close()
        }
    }

    func testLateTagSuccessAndFailureCannotEraseNewerLoadInSamePanel() async throws {
        for fail in [false, true] {
            let f = try await AnnotationTimelineFixture.make()
            let snapshot = try await f.owner.read(references: [try XCTUnwrap(f.rows[0].exactReference)])
            _ = try await f.owner.apply(snapshot: snapshot, mutation: .addTag(name: "Current tag"))
            let model = f.model, entered = expectation(description: "original tag read held")
            let gate = AnnotationTimelineGate(entered: entered)
            model.frames = [f.rows[0]]
            model.timelineContextMenuSegmentIndex = 0
            model.showTagSubmenu = true
            model.test_annotationTagsRead = {
                let tags = try await f.database.getAllTags()
                let first = await gate.holdFirst()
                if fail && first { throw NativeAnnotationError.unavailable }
                return tags
            }
            let pending = Task { await model.loadTags() }
            await fulfillment(of: [entered], timeout: 3)
            await model.loadTags()
            let currentTag = try XCTUnwrap(model.availableTags.first { $0.name == "Current tag" })
            XCTAssertTrue(model.selectedSegmentTags.contains(currentTag.id))
            await gate.release(); await pending.value
            XCTAssertTrue(model.selectedSegmentTags.contains(currentTag.id))
            let completed = expectation(description: "newer tag proof remains usable")
            model.test_annotationMutationCompleted = { completed.fulfill() }
            model.toggleTagOnSelectedSegment(tag: currentTag)
            await fulfillment(of: [completed], timeout: 3)
            let tags = try await f.database.getTagsForSegment(segmentId: SegmentID(value: f.rows[0].frame.segmentID.value))
            XCTAssertTrue(tags.isEmpty)
            try await f.close()
        }
    }

    func testClickedFrameWithWrongSourceProofCannotCreateUnanchoredComment() async throws {
        let f = try await AnnotationTimelineFixture.make(), later = f.rows[1]
        f.model.frames = [f.rows[0], TimelineFrame(frame: later.frame, videoInfo: nil, processingStatus: 2,
                                                 exactReference: f.rows[0].exactReference)]
        f.model.timelineContextMenuSegmentIndex = 1
        f.model.showCommentSubmenu = true
        await f.model.loadCommentsForSelectedTimelineBlock()
        XCTAssertNotNil(f.model.blockCommentsLoadError)
        f.model.newCommentText = "Must not be saved without exact anchor"
        f.model.addCommentToSelectedSegment()
        XCTAssertFalse(f.model.isAddingComment)
        let comments = try await f.database.getCommentsForSegment(segmentId: SegmentID(value: later.frame.segmentID.value))
        XCTAssertTrue(comments.isEmpty)
        try await f.close()
    }

    func testReplacingPanelDuringSaveReleasesOnlyThatSelectionsBusyState() async throws {
        let firstHeld = expectation(description: "first committed save held")
        let secondHeld = expectation(description: "second committed save held")
        let gate = AnnotationTimelineWriteGate(entered: [firstHeld, secondHeld])
        let f = try await AnnotationTimelineFixture.make(drainOutput: { await gate.holdNext() })
        let model = f.model
        model.frames = [f.rows[0], f.rows[2]]
        model.timelineContextMenuSegmentIndex = 0
        model.showCommentSubmenu = true
        await model.loadTimelineContextMenuData()
        let firstFinished = expectation(description: "first stale save completed")
        let secondFinished = expectation(description: "second current save completed")
        var completions = 0
        model.test_annotationMutationCompleted = {
            completions += 1
            if completions == 1 { firstFinished.fulfill() }
            else { secondFinished.fulfill() }
        }
        model.newCommentText = "Saved for A"
        model.addCommentToSelectedSegment()
        await fulfillment(of: [firstHeld], timeout: 3)
        XCTAssertTrue(model.isAddingComment)

        // Replace the selection directly, without the dismiss path's reset.
        model.timelineContextMenuSegmentIndex = 1
        await model.loadTimelineContextMenuData()
        XCTAssertFalse(model.isAddingComment, "The replacement panel must allow its own save")
        model.newCommentText = "Saved for B"
        model.addCommentToSelectedSegment()
        await fulfillment(of: [secondHeld], timeout: 3)
        XCTAssertTrue(model.isAddingComment)
        await gate.release(0)
        await fulfillment(of: [firstFinished], timeout: 3)
        XCTAssertTrue(model.isAddingComment, "An old completion cannot clear the newer save's busy state")
        XCTAssertEqual(model.newCommentText, "Saved for B")
        await gate.release(1)
        await fulfillment(of: [secondFinished], timeout: 3)
        XCTAssertFalse(model.isAddingComment)
        XCTAssertEqual(model.selectedBlockComments.map(\.body), ["Saved for B"])
        try await f.close()
    }
}

@MainActor
private struct AnnotationTimelineFixture {
    let database: DatabaseManager
    let adapter: DataAdapter
    let owner: NativeAnnotationService
    let model: SimpleTimelineViewModel
    let rows: [TimelineFrame]

    static func make(drainOutput: @escaping @Sendable () async -> Void = {}) async throws -> Self {
        let database = DatabaseManager(databasePath: "file:timeline_annotations_\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let pointer = await database.getConnection()
        let root = FileManager.default.temporaryDirectory.path
        let adapter = DataAdapter(retraceConnection: SQLiteConnection(db: try XCTUnwrap(pointer)),
            retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: root, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root), database: database)
        try await adapter.initialize()
        let state = NativeCaptureState(config: Shared.CaptureConfig(), revision: UUID())
        let owner = NativeAnnotationService(database: database, captureState: { state }, drainOutput: drainOutput)
        let evidence = ProgressiveRecallService(database: database, adapter: adapter, configuration: { Shared.CaptureConfig() },
            imageReader: { _ in throw NativeAnnotationError.unavailable })
        let model = SimpleTimelineViewModel(coordinator: AppCoordinator(), evidenceClient: .live(service: evidence),
            transientDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("unused-annotations-\(UUID())"))
        model.test_annotationService = owner
        model.test_annotationTagsRead = { try await database.getAllTags() }
        model.test_annotationCommentsRead = { try await database.getCommentsForSegment(segmentId: $0) }
        var rows: [TimelineFrame] = []
        for group in 0..<2 {
            let time = Date(timeIntervalSince1970: 1_800_000_000 + Double(group * 10))
            let bundleID = "com.authored.annotations\(group)"
            let metadata = FrameMetadata(appBundleID: bundleID, windowName: "Authored")
            let segment = try await database.insertSegment(bundleID: bundleID, startDate: time,
                endDate: time.addingTimeInterval(1), windowName: "Authored", browserUrl: nil, type: 0)
            for index in 0..<(group == 0 ? 2 : 1) {
                let captured = time.addingTimeInterval(Double(index))
                let id = FrameID(value: try await database.insertFrame(.init(id: .init(value: 0), timestamp: captured,
                    segmentID: .init(value: segment), frameIndexInSegment: index, metadata: metadata)))
                let frame = FrameReference(id: id, timestamp: captured, segmentID: .init(value: segment),
                    frameIndexInSegment: index, metadata: metadata)
                _ = try await database.commitFrameOCR(frameID: id, text: .init(frameID: id, timestamp: captured,
                    regions: [], fullText: "Authored annotation source"), frameWidth: 100, frameHeight: 100)
                let store = try await database.activityStoreID()
                let snapshot = try await database.currentScreenEvidence(frameID: id, storeID: store)
                rows.append(.init(frame: frame, videoInfo: nil, processingStatus: 2, exactReference: try XCTUnwrap(snapshot).ref))
            }
        }
        return .init(database: database, adapter: adapter, owner: owner, model: model, rows: rows)
    }

    func seedComment(_ body: String, row: TimelineFrame) async throws {
        let snapshot = try await owner.read(references: [try XCTUnwrap(row.exactReference)])
        _ = try await owner.apply(snapshot: snapshot, mutation: .createComment(body: body, author: "Fixture", attachments: [], anchor: row.frame.id))
    }

    func close() async throws {
        model.dismissTimelineContextMenu()
        model.handleTimelineClosed()
        model.test_annotationCommentsRead = nil
        model.test_annotationTagsRead = nil
        model.test_annotationMutationCompleted = nil
        await owner.close()
        await adapter.shutdown()
        try await database.close()
    }
}

private actor AnnotationTimelineGate {
    let entered: XCTestExpectation
    private var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation) { self.entered = entered }
    @discardableResult
    func holdFirst() async -> Bool {
        guard !started else { return false }
        started = true
        entered.fulfill()
        if !released { await withCheckedContinuation { continuation = $0 } }
        return true
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor AnnotationTimelineWriteGate {
    let entered: [XCTestExpectation]
    private var count = 0
    private var released = Set<Int>()
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    init(entered: [XCTestExpectation]) { self.entered = entered }
    func holdNext() async {
        let index = count
        count += 1
        guard entered.indices.contains(index) else { return }
        entered[index].fulfill()
        if !released.contains(index) {
            await withCheckedContinuation { continuations[index] = $0 }
        }
    }
    func release(_ index: Int) {
        released.insert(index)
        continuations.removeValue(forKey: index)?.resume()
    }
}
