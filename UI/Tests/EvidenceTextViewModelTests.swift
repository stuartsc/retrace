import XCTest
import CoreGraphics
import Shared
import Database
import Storage
import App
@testable import Retrace

@MainActor
final class EvidenceTextViewModelTests: XCTestCase {
    private var database: DatabaseManager!
    private var adapter: DataAdapter!
    private let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private var frameID: FrameID!

    override func setUp() async throws {
        database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let root = FileManager.default.temporaryDirectory.path
        adapter = DataAdapter(retraceConnection: SQLiteConnection(db: try XCTUnwrap(connection)),
            retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: root, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root), database: database)
        try await adapter.initialize()
        let segment = try await database.insertSegment(bundleID: "com.test.text-pages", startDate: capturedAt,
            endDate: capturedAt, windowName: "Authored OCR page fixture", browserUrl: nil, type: 0)
        let id = try await database.insertFrame(FrameReference(id: .init(value: 0), timestamp: capturedAt,
            segmentID: .init(value: segment), frameIndexInSegment: 0,
            metadata: FrameMetadata(appBundleID: "com.test.text-pages", windowName: "Authored OCR page fixture")))
        frameID = FrameID(value: id)
    }

    override func tearDown() async throws {
        await adapter.shutdown()
        try await database.close()
    }

    func testBoundedPagesKeepExactUnicodeAndRevalidatePreviousPage() async throws {
        let ref = try await commit("🧠 café 東京 approval 47000")
        let service = service()
        let model = EvidenceTextViewModel(blockLimit: 1, maximumUTF8Bytes: 4) {
            try await service.expandScreenEvidence($0, for: .localUser)
        }
        await model.open(ref)
        let first = try XCTUnwrap(model.page)
        XCTAssertEqual(first.fragments.map(\.text).joined(), "🧠")
        XCTAssertFalse(model.canGoBack)
        await model.next()
        let second = try XCTUnwrap(model.page)
        XCTAssertNotEqual(first.fragments.first?.id, second.fragments.first?.id)
        XCTAssertLessThanOrEqual(second.textUTF8Bytes, 4)
        XCTAssertTrue(model.canGoBack)
        XCTAssertEqual(model.pageNumber, 2)
        await model.previous()
        XCTAssertEqual(model.page?.fragments.map(\.id), first.fragments.map(\.id))
        XCTAssertEqual(model.pageNumber, 1)
        XCTAssertFalse(model.canGoBack)
    }

    func testDeniedNextPageClearsPreviouslyPermittedText() async throws {
        let ref = try await commit("Authored private text has a continuation")
        let privacy = TextPagePrivacy()
        let service = service { await privacy.config() }
        let model = EvidenceTextViewModel(maximumUTF8Bytes: 4) {
            try await service.expandScreenEvidence($0, for: .localUser)
        }
        await model.open(ref)
        XCTAssertNotNil(model.page?.nextCursor)
        await privacy.exclude()
        await model.next()
        XCTAssertNil(model.page)
        XCTAssertEqual(model.error, .notPermitted)
        XCTAssertFalse(model.canGoBack)
    }

    func testDuplicateOpenJoinsOnePageRequest() async throws {
        let ref = try await commit("Authored coalesced read")
        let service = service()
        let entered = expectation(description: "page held")
        let gate = TextPageGate(entered: entered)
        defer { Task { await gate.release() } }
        let model = EvidenceTextViewModel { request in
            let page = try await service.expandScreenEvidence(request, for: .localUser)
            await gate.hold()
            return page
        }
        let first = Task { await model.open(ref) }
        await fulfillment(of: [entered], timeout: 2)
        let started = expectation(description: "duplicate joined")
        let duplicate = Task { started.fulfill(); await model.open(ref) }
        await fulfillment(of: [started], timeout: 2)
        duplicate.cancel()
        await gate.release()
        await first.value; await duplicate.value
        let reads = await gate.count
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(model.page?.reference, ref)
    }

    func testCancellingInitiatingTaskRejectsHeldPageAndPermitsFreshRetry() async throws {
        let ref = try await commit("Authored cancellation ownership fixture")
        let service = service()
        let entered = expectation(description: "initiating page held")
        let gate = TextPageGate(entered: entered)
        let outcomes = TextPageOutcomes()
        defer { Task { await gate.release() } }
        let model = EvidenceTextViewModel(report: { await outcomes.record($0, count: $1) }) { request in
            let page = try await service.expandScreenEvidence(request, for: .localUser)
            await gate.hold()
            return page
        }
        let initiating = Task { await model.open(ref) }
        await fulfillment(of: [entered], timeout: 2)
        initiating.cancel()
        await gate.release()
        await initiating.value
        XCTAssertNil(model.reference)
        XCTAssertNil(model.page)
        XCTAssertFalse(model.isLoading)
        let cancelledOutcomes = await outcomes.entries
        XCTAssertFalse(cancelledOutcomes.contains { $0.outcome == "success" })

        await model.open(ref)
        XCTAssertEqual(model.page?.reference, ref)
        let reads = await gate.count
        XCTAssertEqual(reads, 2, "Retry must start a fresh access-checked page request")
    }

    func testNewRevisionAndCloseRejectCancellationIgnoringOldPage() async throws {
        let old = try await commit("Old authored value 42000")
        let newer = try await commit("New authored value 47000")
        let service = service()
        let entered = expectation(description: "old page held")
        let gate = TextPageGate(entered: entered)
        defer { Task { await gate.release() } }
        let model = EvidenceTextViewModel { request in
            let page = try await service.expandScreenEvidence(request, for: .localUser)
            if request.reference == old { await gate.hold() }
            return page
        }
        let oldTask = Task { await model.open(old) }
        await fulfillment(of: [entered], timeout: 2)
        await model.open(newer)
        XCTAssertEqual(model.page?.reference, newer)
        model.cancel()
        await gate.release(); await oldTask.value
        XCTAssertNil(model.reference)
        XCTAssertNil(model.page)
        XCTAssertFalse(model.isLoading)
    }

    func testAdmittedPageReportsSuccessfulOutcomeWithoutRecordedContents() async throws {
        let ref = try await commit("Authored evidence metric fixture")
        let service = service()
        let outcomes = TextPageOutcomes()
        let model = EvidenceTextViewModel(report: { await outcomes.record($0, count: $1) }) {
            try await service.expandScreenEvidence($0, for: .localUser)
        }
        await model.open(ref)
        let page = try XCTUnwrap(model.page)
        let recorded = await outcomes.entries
        XCTAssertEqual(recorded.map(\.outcome), ["success"])
        XCTAssertEqual(recorded.map(\.count), [page.fragments.count])
    }

    private func commit(_ text: String) async throws -> ScreenEvidenceRef {
        _ = try await database.commitFrameOCR(frameID: frameID, text: ExtractedText(frameID: frameID,
            timestamp: capturedAt, regions: [TextRegion(frameID: frameID, text: text,
                bounds: CGRect(x: 5, y: 5, width: 200, height: 30))]), frameWidth: 640, frameHeight: 360)
        let store = try await database.activityStoreID()
        let snapshot = try await database.currentScreenEvidence(frameID: frameID, storeID: store)
        return try XCTUnwrap(snapshot?.ref)
    }

    private func service(configuration: @escaping @Sendable () async -> CaptureConfig = { CaptureConfig() }) -> ProgressiveRecallService {
        ProgressiveRecallService(database: database, adapter: adapter, configuration: configuration,
            imageReader: { _ in XCTFail("Text pages never decode media"); throw EvidenceUnavailableReason.recordingMissing })
    }
}

private actor TextPagePrivacy {
    var excluded = false
    func exclude() { excluded = true }
    func config() -> CaptureConfig {
        CaptureConfig(excludedAppBundleIDs: excluded ? ["com.test.text-pages"] : [])
    }
}

private actor TextPageGate {
    let entered: XCTestExpectation
    var count = 0
    var released = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(entered: XCTestExpectation) { self.entered = entered }
    func hold() async {
        count += 1
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0); entered.fulfill() }
    }
    func release() { released = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

private actor TextPageOutcomes {
    struct Entry { let outcome: String; let count: Int }
    var entries: [Entry] = []
    func record(_ outcome: String, count: Int) { entries.append(Entry(outcome: outcome, count: count)) }
}
