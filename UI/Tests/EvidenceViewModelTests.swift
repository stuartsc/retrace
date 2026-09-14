import XCTest
import Foundation
import Shared
import Database
import App
import Storage
@testable import Retrace

@MainActor
final class EvidenceViewModelTests: XCTestCase {
    private var database: DatabaseManager!
    private var segmentID: Int64 = 0
    private let session = UUID()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:evidence_ui_\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        segmentID = try await database.insertSegment(bundleID: "word", startDate: start, endDate: start.addingTimeInterval(60),
            windowName: "Test screen", browserUrl: nil, type: 0)
    }
    override func tearDown() async throws { try await database.close() }

    func testSlowOldResolutionCannotOverwriteNewSelection() async throws {
        let first = try await append(1, title: "First")
        let second = try await append(2, title: "Second")
        let firstRef = EvidenceRef.activity(ActivityEvidenceRef(storeID: first.storeID, eventID: first.id))
        let secondRef = EvidenceRef.activity(ActivityEvidenceRef(storeID: second.storeID, eventID: second.id))
        let entered = expectation(description: "old resolution entered")
        let gate = EvidenceCompatibilityResolutionGate(entered: entered)
        defer { Task { await gate.release() } }
        var source = client()
        source.resolve = { ref in
            if ref == firstRef { await gate.enter(); return .activity(first) }
            return .activity(second)
        }
        let model = EvidenceViewModel(client: source)
        let old = Task { await model.openEvidence(firstRef) }
        await fulfillment(of: [entered], timeout: 2)
        await model.openEvidence(secondRef)
        await gate.release()
        await old.value
        XCTAssertEqual(model.evidenceReference, secondRef)
        guard case .activity(let result) = model.resolution else { return XCTFail("Expected current activity") }
        XCTAssertEqual(result.id, second.id)
        model.closeEvidence()
        XCTAssertNil(model.resolution)
        XCTAssertNil(model.evidenceReference)
    }

    func testEvidenceDeeplinkKeepsExactSourceAndRejectsMalformedPayload() throws {
        let reference = EvidenceRef.screen(ScreenEvidenceRef(storeID: UUID(), source: .rewind,
            observationID: UUID(), frameID: FrameID(value: 7), extractionRevision: 3, blockIDs: [2]))
        let url = try XCTUnwrap(reference.deepLink)
        XCTAssertEqual(DeeplinkHandler.route(for: url), .evidence(reference))
        XCTAssertNil(DeeplinkHandler.route(for: URL(string: "retrace://evidence?ref=invalid")!))
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
        let model = EvidenceViewModel(client: source)
        await model.openEvidence(.screen(ref))
        guard case .unavailable(.recordingMissing) = model.resolution else { return XCTFail("Missing media must remain unavailable") }
        XCTAssertEqual(model.retainedSnapshot?.text?.fullText, "Retained amount 900")
        XCTAssertEqual(model.retainedSnapshot?.ref, ref)
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
        let model = EvidenceViewModel(client: source)
        await model.openEvidence(.screen(link.screen))
        XCTAssertEqual(model.evidenceReference, .screen(link.screen))
        XCTAssertEqual(model.newerRevision, link.screen.extractionRevision + 1)
        guard case .screen(let cited, _) = model.resolution else { return XCTFail("Expected cited screenshot") }
        XCTAssertEqual(cited.text?.fullText, "Amount 100")
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
        let model = EvidenceViewModel(client: source)
        await model.openSearchResult(result)
        guard case .unavailable(.sourceDisconnected) = model.resolution else { return XCTFail("Expected disconnected original source") }
        XCTAssertNil(model.evidenceReference)
    }

    func testBackgroundOCRRefreshOffersNewerTextWithoutReplacingSelectedExtraction() async throws {
        let event = try await append(1, title: "Authored refresh fixture")
        let link = try await screenLink(event)
        let stored = try await database.screenEvidence(link.screen)
        let snapshot = try XCTUnwrap(stored)
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
            bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        var source = client()
        let db = database!
        source.resolve = { _ in .screen(snapshot, image: image) }
        source.currentRevision = { try await db.currentScreenEvidence(frameID: $0.frameID, storeID: $0.storeID)?.ref.extractionRevision }
        let model = EvidenceViewModel(client: source)
        await model.openEvidence(.screen(link.screen))
        XCTAssertNil(model.newerRevision)
        _ = try await database.commitFrameOCR(frameID: link.screen.frameID,
            text: ExtractedText(frameID: link.screen.frameID, timestamp: link.capturedAt, regions: [
                TextRegion(frameID: link.screen.frameID, text: "New OCR amount 900", bounds: CGRect(x: 5, y: 5, width: 80, height: 10))
            ]), frameWidth: 100, frameHeight: 100)
        await model.refreshCurrentRevision()
        XCTAssertEqual(model.newerRevision, link.screen.extractionRevision + 1)
        guard case .screen(let selected, _) = model.resolution else { return XCTFail("Selected evidence was replaced") }
        XCTAssertEqual(selected.text?.fullText, "Amount 100")
        XCTAssertEqual(selected.ref, link.screen)
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

    private func client() -> EvidenceClient {
        let db = database!
        return EvidenceClient(
            reference: { _ in throw EvidenceUnavailableReason.sourceDisconnected },
            frameReference: { _, _ in throw EvidenceUnavailableReason.sourceDisconnected },
            resolve: { ref in
                if case .activity(let target) = ref, let stored = try? await db.activityEvent(id: target.eventID) {
                    return .activity(stored)
                }
                return .unavailable(.evidenceDeleted)
            }, currentRevision: { _ in nil }, track: { _, _, _ in })
    }
}

private actor EvidenceCompatibilityResolutionGate {
    private let entered: XCTestExpectation
    private var blocked: CheckedContinuation<Void, Never>?
    private var released = false
    init(entered: XCTestExpectation) { self.entered = entered }
    func enter() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            blocked = continuation
            entered.fulfill()
        }
    }
    func release() { released = true; blocked?.resume(); blocked = nil }
}
