import App
import Shared
import XCTest
@testable import Retrace

@MainActor
final class RetentionReviewModelTests: XCTestCase {
    func testPagingRequiresNewExplicitConfirmationAndCutoffChangesClearSelection() async throws {
        let boundary = RetentionReviewBoundary()
        let model = RetentionReviewModel(client: boundary.client, cutoff: Date(timeIntervalSince1970: 1_780_000_000))
        model.loadPreview()
        await settled(model)
        let first = try XCTUnwrap(model.preview)
        XCTAssertNotNil(first.nextContinuationID)
        let before = await boundary.executions
        XCTAssertEqual(before, 0)
        model.loadNextPage()
        await settled(model)
        let next = try XCTUnwrap(model.preview)
        XCTAssertNotEqual(next.id, first.id)
        let afterPaging = await boundary.executions
        XCTAssertEqual(afterPaging, 0)
        model.confirm()
        await settled(model)
        let executed = await boundary.executedPreview
        XCTAssertEqual(executed?.id, next.id)
        XCTAssertEqual(model.outcome?.deletedFrames, 2)
        model.changeCutoff(model.cutoff.addingTimeInterval(-60))
        XCTAssertNil(model.preview); XCTAssertNil(model.nextContinuationID); XCTAssertNil(model.outcome)
        model.confirm()
        let afterInvalidConfirm = await boundary.executions
        XCTAssertEqual(afterInvalidConfirm, 1)
    }

    func testCancelledCommittedExecutionStillDisplaysCounts() async throws {
        let boundary = RetentionReviewBoundary(holdExecution: true)
        let model = RetentionReviewModel(client: boundary.client)
        model.loadPreview(); await settled(model)
        model.confirm()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.phase != .drainingOutput, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(model.phase, .drainingOutput)
        model.cancel()
        await boundary.release()
        await settled(model)
        XCTAssertEqual(model.outcome?.deletedFrames, 2)
        XCTAssertTrue(model.outcome?.partial == true)
        XCTAssertEqual(model.phase, .completed)
    }

    private func settled(_ model: RetentionReviewModel) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.busy, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(model.busy)
    }
}

private actor RetentionReviewBoundary {
    private(set) var executions = 0
    private(set) var executedPreview: RetentionCommandPreview?
    private var holdExecution: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private let store = UUID()
    private let revision = UUID()
    init(holdExecution: Bool = false) { self.holdExecution = holdExecution }
    nonisolated var client: RetentionReviewModel.Client {
        .init(preview: { try await self.preview(cutoff: $0, continuation: $1) },
              execute: { try await self.execute($0, fence: $1, progress: $2) })
    }
    private func preview(cutoff: Date, continuation: UUID?) -> RetentionCommandPreview {
        .init(id: UUID(), clientID: "authored", nativeStoreID: store, captureRevision: revision,
            cutoff: cutoff, expiresAt: Date().addingTimeInterval(120), fingerprint: "authored",
            frames: 2, sessions: 1, videoCandidates: 0, hasMore: continuation == nil,
            nextContinuationID: continuation == nil ? UUID() : nil, scannedFrames: 2)
    }
    private func execute(_ preview: RetentionCommandPreview, fence: NativeMutationFence,
                         progress: @escaping @Sendable (RetentionCommandPhase) async -> Void) async throws -> RetentionCommandOutcome {
        try fence.withAdmission { executions += 1; executedPreview = preview }
        await progress(.drainingOutput)
        if holdExecution { await withCheckedContinuation { continuation = $0 } }
        return .init(previewID: preview.id, nativeStoreID: store, deletedFrames: 2, deletedSessions: 1,
            deletedVideoRows: 0, pendingVideoFiles: 0, partial: Task.isCancelled)
    }
    func release() { holdExecution = false; continuation?.resume(); continuation = nil }
}
