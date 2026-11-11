import CoreGraphics
import Foundation
import Shared
import Database
import Storage
import SQLCipher
import XCTest
@testable import App

/// Canonical private SQLite and immutable OCR/activity inputs. The only double is
/// the optional model/external provider boundary; native loading requires an explicit fixture opt-in.
final class LocalContextServiceTests: XCTestCase {
    private var database: DatabaseManager!
    private var adapter: DataAdapter!
    private var evidence: ProgressiveRecallService!
    private var service: LocalContextService!
    private let policy = ContextTestPolicy()
    private let clock = ContextTestClock()
    private let model = ContextTestModel()
    private let metrics = ContextTestMetrics()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:local-context-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let raw = await database.getConnection()
        adapter = DataAdapter(retraceConnection: SQLiteConnection(db: try XCTUnwrap(raw)),
            retraceConfig: .init(dateFormatter: nil, storageRoot: "/tmp", source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: "/tmp"), database: database)
        try await adapter.initialize()
        let policy = policy
        evidence = ProgressiveRecallService(database: database, adapter: adapter, configuration: { await policy.value() },
            imageReader: { _ in XCTFail("Context read attempted media decoding"); throw EvidenceUnavailableReason.recordingMissing })
        let active = try await database.beginScreenEvidenceWriterSession(policy: .init(config: CaptureConfig()))
        try await database.activateScreenEvidencePolicy(active)
        service = makeService()
    }

    override func tearDown() async throws {
        await model.release()
        await metrics.release()
        await policy.release()
        if let service { await service.stop() }
        if let adapter { await adapter.shutdown() }
        if let database { try await database.close() }
    }

    func testExplicitNativeTopicUsesPrivateCanonicalEvidenceAndRetainsExactSupports() async throws {
        guard ProcessInfo.processInfo.environment["RETRACE_LOCAL_CONTEXT_NATIVE"] == "1" else {
            throw XCTSkip("Explicit on-device Foundation Models fixture requires RETRACE_LOCAL_CONTEXT_NATIVE=1")
        }
        await service.stop()
        service = LocalContextService(database: database, evidence: evidence,
            model: FoundationModelsLocalContextModel(), recordMetric: { _ in })
        let screen = try await insertScreen("Cedar proposal pricing remains a draft. Fifteen thousand dollars, not fifty thousand. Approval NOT GRANTED.")
        let result = try await service.refresh(.init(screenReferences: [screen], foundationModelsEnabled: true))
        if result.modelStatus == .unavailable {
            throw XCTSkip("On-device Foundation Models or the current locale is unavailable; no native topic acceptance")
        }
        XCTAssertEqual(result.modelStatus, .used, "Explicit native generation must succeed; fallback is not model acceptance")
        let topic = try XCTUnwrap(result.items.first { $0.kind == .topicInterpretation })
        let excerpt = try XCTUnwrap(result.items.first { $0.kind == .screenExcerpt })
        XCTAssertTrue(topic.isInterpretation)
        XCTAssertEqual(topic.supports, excerpt.supports)
        XCTAssertEqual(excerpt.supports.count, 1)
        if case .screen(let span) = try XCTUnwrap(topic.supports.first) {
            XCTAssertEqual(span.fragmentID.reference, screen)
        } else { XCTFail("A topic must keep the supplied exact screen support") }
        XCTAssertLessThanOrEqual(topic.title.split(whereSeparator: { $0.isWhitespace }).count, 5)
        let report = try JSONSerialization.data(withJSONObject: [
            "scope": "authored_private_sqlite_native_topic", "label": topic.title,
            "interpretation": true, "exact_supports": topic.supports.count
        ], options: [.sortedKeys])
        print("NATIVE_LOCAL_CONTEXT " + String(decoding: report, as: UTF8.self))
        try await database.deleteFrame(id: screen.frameID)
        do { let afterDeletion = try await service.current(); XCTAssertNil(afterDeletion) }
        catch { /* Current source deletion may reject the entire presentation. */ }
    }

    func testDefaultUsesRealCanonicalTextAndActivityWithoutCallingModel() async throws {
        let screen = try await insertScreen("Pricing café 🧭: AU$1,024; status pending.")
        let activity = try await insertActivity()
        let result = try await service.refresh(.init(screenReferences: [screen], activityReferences: [activity]))
        XCTAssertEqual(result.modelStatus, .disabled)
        XCTAssertEqual(result.scope, .selectedNativeScreenAndActivity)
        XCTAssertTrue(result.items.contains { $0.kind == .screenExcerpt && $0.excerpt == "Pricing café 🧭: AU$1,024; status pending." })
        XCTAssertTrue(result.items.contains { $0.supports.contains(.activity(activity)) })
        let calls = await model.calls
        XCTAssertEqual(calls, 0)
        let screenSupport = try XCTUnwrap(result.items.flatMap(\.supports).first { if case .screen = $0 { return true }; return false })
        if case .screen(let span) = screenSupport {
            XCTAssertEqual(span.fragmentID.reference, screen)
            XCTAssertEqual(span.utf16Range.length, "Pricing café 🧭: AU$1,024; status pending.".utf16.count)
        }
    }

    func testRenewedInteractionKeepsDeterministicCardsWhenOptionalTopicIsCancelled() async throws {
        await service.stop()
        let governor = BackgroundProcessingGovernor(observeSystem: false)
        await governor.updateEnvironment(.init(idleSeconds: 600))
        service = LocalContextService(database: database, evidence: evidence, governor: governor,
            model: model, clock: { [clock] in clock.read() }, recordMetric: { _ in })
        let screen = try await insertScreen("Cedar budget remains unapproved.")
        await model.hold()
        let owner = service!
        let request = Task { try await owner.refresh(.init(screenReferences: [screen], foundationModelsEnabled: true)) }
        await model.waitUntilEntered()
        await governor.updateEnvironment(.init(idleSeconds: 0))
        await model.release()
        let result = try await request.value
        XCTAssertTrue(result.items.contains { $0.kind == .screenExcerpt })
        XCTAssertFalse(result.items.contains { $0.kind == .topicInterpretation })
        await owner.stop()
        await governor.close()
    }

    func testEmptyInputAndUnavailableModelKeepDeterministicResults() async throws {
        let empty = try await service.refresh(.init())
        XCTAssertTrue(empty.items.isEmpty)
        let noInput = try await service.refresh(.init(foundationModelsEnabled: true))
        XCTAssertEqual(noInput.modelStatus, .noInput)
        let screen = try await insertScreen("Authored proposal notes")
        let result = try await service.refresh(.init(screenReferences: [screen], foundationModelsEnabled: true))
        XCTAssertEqual(result.modelStatus, .unavailable)
        XCTAssertEqual(result.items.filter { $0.kind == .screenExcerpt }.count, 1)
        let calls = await model.calls
        XCTAssertEqual(calls, 1)
    }

    func testTopicIsAnInterpretationWithOnlySuppliedExactSupports() async throws {
        await model.setResponse(.init(label: "Proposal pricing", supportIDs: [0]))
        let screen = try await insertScreen("Proposal pricing is under discussion.")
        let result = try await service.refresh(.init(screenReferences: [screen], foundationModelsEnabled: true))
        let topic = try XCTUnwrap(result.items.first { $0.kind == .topicInterpretation })
        XCTAssertEqual(topic.title, "Proposal pricing")
        XCTAssertTrue(topic.isInterpretation)
        XCTAssertEqual(topic.supports, try XCTUnwrap(result.items.first { $0.kind == .screenExcerpt }).supports)
        XCTAssertEqual(result.modelStatus, .used)
    }

    func testUnknownDuplicateAndOversizedModelOutputCannotCreateEvidence() async throws {
        let screen = try await insertScreen("Only this authored statement exists.")
        for proposal in [LocalContextTopicProposal(label: "Invented", supportIDs: [999]),
                         .init(label: "Duplicate", supportIDs: [0, 0]),
                         .init(label: String(repeating: "x", count: 81), supportIDs: [0])] {
            let isolated = makeService()
            await model.setResponse(proposal)
            let result = try await isolated.refresh(.init(screenReferences: [screen], foundationModelsEnabled: true))
            XCTAssertEqual(result.modelStatus, .rejected)
            XCTAssertFalse(result.items.contains { $0.isInterpretation })
            await isolated.stop()
        }
    }

    func testDeletionDuringGenerationReturnsNoSnapshot() async throws {
        let screen = try await insertScreen("This screen will be deleted.")
        await model.hold()
        let service = service!
        let task = Task { try await service.refresh(.init(screenReferences: [screen], foundationModelsEnabled: true)) }
        await model.waitUntilEntered()
        _ = try await database.deleteFrames(olderThan: now.addingTimeInterval(1))
        await model.release()
        await expectFailure(task)
        let current = try await service.current()
        XCTAssertNil(current)
    }

    func testOCRRevisionChangeDuringGenerationRejectsOldSupport() async throws {
        let screen = try await insertScreen("Build status pending")
        await model.hold()
        let service = service!
        let task = Task { try await service.refresh(.init(screenReferences: [screen], foundationModelsEnabled: true)) }
        await model.waitUntilEntered()
        _ = try await database.commitFrameOCR(frameID: screen.frameID,
            text: .init(frameID: screen.frameID, timestamp: now, regions: [], fullText: "Build status failed", metadata: .init(appBundleID: "com.authored.context")),
            frameWidth: 640, frameHeight: 360)
        await model.release()
        await expectFailure(task)
    }

    func testPrivacyChangeDuringAwaitedMetricCannotPublish() async throws {
        let screen = try await insertScreen("Private authored context")
        await metrics.holdPublication()
        let service = service!
        let task = Task { try await service.refresh(.init(screenReferences: [screen])) }
        await metrics.waitUntilEntered()
        await policy.exclude()
        await metrics.release()
        await expectFailure(task)
    }

    func testActivityDeletionAndHiddenDocumentAcknowledgementInvalidatePublishedCards() async throws {
        let first = try await insertActivity(document: "document-1")
        let second = try await insertActivity(document: "document-1")
        _ = try await service.refresh(.init(activityReferences: [second]))
        let firstEvent = try await database.activityEvent(id: first.eventID)
        let context = try XCTUnwrap(firstEvent?.event.context)
        let correction = try await database.submitActivityCorrection(.init(targetEventIDs: [first.eventID], expectedRevision: 0,
            action: .hide, scope: .document, documentKey: context.stableDocumentKey, confirmed: true))
        // A pending document hide applies to selected targets, not other events.
        _ = try await service.refresh(.init(activityReferences: [second]))
        try await database.acknowledgeActivityCorrection(id: correction.command.id, expectedRevision: correction.revision, applied: true)
        await expectCurrentFailure()
        try await database.deleteActivity(eventIDs: [second.eventID])
        do { _ = try await service.refresh(.init(activityReferences: [second])); XCTFail("Deleted activity reappeared") } catch { }
    }

    func testHiddenTagDeletionAndRecreationUsesCurrentNamedTag() async throws {
        let screen = try await insertScreen("A hidden authored screen")
        let retained = try await database.currentScreenEvidence(frameID: screen.frameID, storeID: screen.storeID)
        let snapshot = try XCTUnwrap(retained)
        if let old = try await database.getTag(name: "hidden") { try await database.deleteTag(tagId: old.id) }
        let tag = try await database.createTag(name: "hidden")
        try await database.addTagToSegment(segmentId: .init(value: snapshot.frame.segmentID.value), tagId: tag.id)
        do { _ = try await service.refresh(.init(screenReferences: [screen])); XCTFail("Hidden frame admitted") } catch { }
    }

    func testExpiryUsesMonotonicClockEvenWhenWallClockMovesBackwards() async throws {
        let screen = try await insertScreen("Bounded lifetime")
        _ = try await service.refresh(.init(screenReferences: [screen]))
        clock.advance(wall: -300, uptime: 121)
        let current = try await service.current()
        XCTAssertNil(current)
        let events = await metrics.events
        XCTAssertTrue(events.contains { $0.operation == .expired })
    }

    func testIdenticalConcurrentRequestsCoalesceOneModelCall() async throws {
        let screen = try await insertScreen("One bounded topic request")
        await model.hold()
        let service = service!, request = LocalContextRequest(screenReferences: [screen], foundationModelsEnabled: true)
        let first = Task { try await service.refresh(request) }
        await model.waitUntilEntered()
        let second = Task { try await service.refresh(request) }
        await model.release()
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a.revision, b.revision)
        let calls = await model.calls
        XCTAssertEqual(calls, 1)
    }

    func testRepeatedVisibleTextReusesTopicButPublishesNewCanonicalReference() async throws {
        await model.setResponse(.init(label: "Proposal", supportIDs: [0]))
        let first = try await insertScreen("Same meaningful text")
        _ = try await service.refresh(.init(screenReferences: [first], foundationModelsEnabled: true))
        let next = try await insertScreen("Same meaningful text")
        let result = try await service.refresh(.init(screenReferences: [next], foundationModelsEnabled: true))
        let calls = await model.calls
        XCTAssertEqual(calls, 1)
        for support in result.items.flatMap(\.supports) {
            if case .screen(let span) = support { XCTAssertEqual(span.fragmentID.reference, next) }
        }
    }

    func testSupersedingRequestAndStopJoinWorkAndRejectLateCalls() async throws {
        let first = try await insertScreen("First topic"), next = try await insertScreen("Second topic")
        await model.hold()
        let service = service!
        let old = Task { try await service.refresh(.init(screenReferences: [first], foundationModelsEnabled: true)) }
        await model.waitUntilEntered()
        let replacement = Task { try await service.refresh(.init(screenReferences: [next])) }
        await model.waitUntilCancelled()
        await model.release()
        await expectFailure(old)
        let result = try await replacement.value
        XCTAssertTrue(result.items.contains { $0.excerpt == "Second topic" })
        async let one: Void = service.stop()
        async let two: Void = service.stop()
        _ = await (one, two)
        let count = await metrics.events.count
        do { _ = try await service.refresh(.init()); XCTFail("Stopped service restarted") } catch { }
        do { _ = try await service.current(); XCTFail("Stopped service returned cached state") } catch { }
        let after = await metrics.events.count
        XCTAssertEqual(after, count)
        let events = await metrics.events
        XCTAssertEqual(events.last?.operation, .stopped)
    }

    func testCallerCancellationCannotReturnOrCacheACompletedGeneration() async throws {
        let screen = try await insertScreen("Cancelled evidence")
        await model.hold()
        let service = service!
        let task = Task { try await service.refresh(.init(screenReferences: [screen], foundationModelsEnabled: true)) }
        await model.waitUntilEntered()
        task.cancel()
        await model.release()
        await expectFailure(task)
        let current = try await service.current()
        XCTAssertNil(current)
    }

    func testExternalWithoutProviderAuthorityIsOmitted() async throws {
        let screen = try await insertScreen("Proposal context")
        let result = try await service.refresh(.init(screenReferences: [screen], externalSnapshot: external()))
        XCTAssertTrue(result.externalProviders.isEmpty)
        XCTAssertFalse(result.items.contains { $0.kind == .externalSignal })
    }

    func testProviderRevisionChangeDuringGenerationRejectsExternalBatch() async throws {
        let provider = ContextTestProvider()
        let service = makeService(external: { await provider.accepts($0) })
        let screen = try await insertScreen("Proposal context")
        await model.hold()
        let snapshot = external()
        await provider.set(snapshot)
        let task = Task { try await service.refresh(.init(screenReferences: [screen], externalSnapshot: snapshot, foundationModelsEnabled: true)) }
        await model.waitUntilEntered()
        await provider.set(nil)
        await model.release()
        await expectFailure(task)
        await service.stop()
    }

    func testForeignStoreDuplicateAndOversizedRequestsFailBeforeModel() async throws {
        let screen = try await insertScreen("Bounded input")
        let foreign = ScreenEvidenceRef(storeID: UUID(), source: .native, observationID: screen.observationID,
            frameID: screen.frameID, extractionRevision: screen.extractionRevision)
        for request in [LocalContextRequest(screenReferences: [foreign]), .init(screenReferences: [screen, screen]),
                        .init(screenReferences: Array(repeating: screen, count: 10_000))] {
            do { _ = try await service.refresh(request); XCTFail("Invalid request admitted") } catch { }
        }
        let calls = await model.calls
        XCTAssertEqual(calls, 0)
    }

    func testCanonicalPolicyEpochDetectsSameValueABAChange() async throws {
        let screen = try await insertScreen("Same policy value is not the same epoch")
        let active = try await database.localContextPolicyIdentity()
        await model.hold()
        let service = service!
        let task = Task { try await service.refresh(.init(screenReferences: [screen], foundationModelsEnabled: true)) }
        await model.waitUntilEntered()
        let changed = try await database.prepareScreenEvidencePolicy(session: active.session,
            policy: .init(config: CaptureConfig(excludedAppBundleIDs: ["com.unrelated.app"])))
        try await database.activateScreenEvidencePolicy(changed)
        let restored = try await database.prepareScreenEvidencePolicy(session: active.session, policy: .init(config: CaptureConfig()))
        try await database.activateScreenEvidencePolicy(restored)
        XCTAssertNotEqual(active.policyEpoch, restored.policyEpoch)
        XCTAssertEqual(active.policySHA256, restored.policySHA256)
        await model.release()
        await expectFailure(task)
    }

    func testUnownedPolicyAndWriterEndDenyContextEvenForDeterministicMode() async throws {
        let screen = try await insertScreen("Canonical owner required")
        _ = try await service.refresh(.init(screenReferences: [screen]))
        let active = try await database.localContextPolicyIdentity()
        try await database.endScreenEvidenceWriterSession(active.session)
        await expectCurrentFailure()
        do { _ = try await service.refresh(.init(screenReferences: [screen])); XCTFail("Unowned policy admitted context") } catch { }
    }

    func testLargeUnicodeExcerptReportsPartialCoverageAndExactUTF16Span() async throws {
        let text = String(repeating: "Café 🧭 AU$1,024 — pending. ", count: 1_000)
        let screen = try await insertScreen(text)
        let result = try await service.refresh(.init(screenReferences: [screen]))
        XCTAssertTrue(result.screenTextTruncated)
        let item = try XCTUnwrap(result.items.first { $0.kind == .screenExcerpt })
        let excerpt = try XCTUnwrap(item.excerpt)
        XCTAssertLessThanOrEqual(excerpt.utf8.count, 384)
        XCTAssertTrue(text.hasPrefix(excerpt))
        if case .screen(let span) = try XCTUnwrap(item.supports.first) {
            XCTAssertEqual((text as NSString).substring(with: NSRange(location: span.utf16Range.location, length: span.utf16Range.length)), excerpt)
        } else { XCTFail("Screen excerpt lacked a screen span") }
    }

    func testModelFailureUsesTheSameCanonicalFallback() async throws {
        let screen = try await insertScreen("A deterministic fallback survives model failure")
        await model.fail()
        let result = try await service.refresh(.init(screenReferences: [screen], foundationModelsEnabled: true))
        XCTAssertEqual(result.modelStatus, .failed)
        XCTAssertEqual(result.items.filter { $0.kind == .screenExcerpt }.count, 1)
    }

    func testStopWaitsForActiveGenerationAndNoMetricArrivesAfterCleanup() async throws {
        let screen = try await insertScreen("Held generation")
        await model.hold()
        let service = service!
        let request = Task { try await service.refresh(.init(screenReferences: [screen], foundationModelsEnabled: true)) }
        await model.waitUntilEntered()
        let closing = Task { await service.stop() }
        await model.waitUntilCancelled()
        let before = await metrics.events
        XCTAssertFalse(before.contains { $0.operation == .stopped })
        await model.release()
        await closing.value
        await expectFailure(request)
        let after = await metrics.events
        XCTAssertEqual(after.last?.operation, .stopped)
        let count = after.count
        do { _ = try await service.current(); XCTFail("Stopped service returned") } catch { }
        let finalCount = await metrics.events.count
        XCTAssertEqual(count, finalCount)
    }

    func testDeletionAfterFinalScreenStampBeforeCanonicalFenceCannotPublish() async throws {
        let screen = try await insertScreen("Deleted at the final screen boundary")
        await metrics.holdPublication()
        let service = service!
        let task = Task { try await service.refresh(.init(screenReferences: [screen])) }
        await metrics.waitUntilEntered()
        // The final revalidation of one screen uses two presentation policies,
        // currentRevision, retainedScreen, then the two final stamp policies.
        // Hold the last config callback after its screen revision was read.
        await policy.holdAfterReads(6)
        await metrics.release()
        await policy.waitUntilEntered()
        _ = try await database.deleteFrames(olderThan: now.addingTimeInterval(1))
        await policy.release()
        await expectFailure(task)
        let current = try await service.current()
        XCTAssertNil(current)
    }

    func testModelDelayConsumesOriginalMonotonicLease() async throws {
        let screen = try await insertScreen("Authored generation delay")
        await model.hold()
        let service = service!
        let task = Task { try await service.refresh(.init(screenReferences: [screen], foundationModelsEnabled: true)) }
        await model.waitUntilEntered()
        clock.advance(wall: 0, uptime: 30)
        await model.release()
        let result = try await task.value
        XCTAssertEqual(result.expiresAtUptime, 220)
        XCTAssertEqual(result.expiresAtUptime - clock.read().uptime, 90)
        clock.advance(wall: -60, uptime: 91)
        let current = try await service.current()
        XCTAssertNil(current)
    }

    func testExternalSignalDisplacingLocalExcerptMarksPartialCoverage() async throws {
        var screens: [ScreenEvidenceRef] = []
        for index in 0..<5 { screens.append(try await insertScreen("Proposal topic \(index)")) }
        let provider = ContextTestProvider(), supplied = external()
        await provider.set(supplied)
        let isolated = makeService(external: { await provider.accepts($0) })
        let result = try await isolated.refresh(.init(screenReferences: screens, externalSnapshot: supplied))
        XCTAssertEqual(result.items.filter { $0.kind == .screenExcerpt }.count, 4)
        XCTAssertEqual(result.items.filter { $0.kind == .externalSignal }.count, 1)
        XCTAssertTrue(result.screenTextTruncated)
        await isolated.stop()
    }

    private func makeService(external: LocalContextExternalRevalidator? = nil) -> LocalContextService {
        let clock = clock, metrics = metrics
        return LocalContextService(database: database, evidence: evidence, model: model,
            externalRevalidator: external, clock: { clock.read() }, recordMetric: { await metrics.record($0) })
    }

    private func insertScreen(_ text: String) async throws -> ScreenEvidenceRef {
        let segment = try await database.insertSegment(bundleID: "com.authored.context", startDate: now, endDate: now,
            windowName: "Authored context", browserUrl: nil, type: 0)
        let video = try await database.insertVideoSegment(.init(id: .init(value: 0), startTime: now, endTime: now,
            frameCount: 1, fileSizeBytes: 100, relativePath: "authored.mp4", width: 640, height: 360))
        let metadata = FrameMetadata(appBundleID: "com.authored.context", appName: "Authored", windowName: "Authored context")
        let id = try await database.insertFrame(.init(id: .init(value: 0), timestamp: now, segmentID: .init(value: segment),
            videoID: .init(value: video), frameIndexInSegment: 0, encodingStatus: .success, metadata: metadata))
        let frameID = FrameID(value: id)
        _ = try await database.commitFrameOCR(frameID: frameID,
            text: .init(frameID: frameID, timestamp: now, regions: [], fullText: text, metadata: metadata), frameWidth: 640, frameHeight: 360)
        let store = try await database.activityStoreID()
        let snapshot = try await database.currentScreenEvidence(frameID: frameID, storeID: store)
        return try XCTUnwrap(snapshot).ref
    }

    private func insertActivity(document: String? = nil) async throws -> ActivityEvidenceRef {
        let event = ActivityEvent(sessionID: UUID(), sequence: 1, observedAt: now, monotonicTime: 10,
            kind: .focus, coverage: .observed,
            context: .init(appBundleID: "com.authored.context", appName: "Authored", processID: 42,
                processGeneration: "authored-run", windowID: 17, windowGeneration: "authored-window",
                windowTitle: "Proposal context", documentID: document), method: "authored-activity")
        let saved = try await database.appendActivity(event)
        return .init(storeID: saved.storeID, eventID: saved.id)
    }

    private func external() -> LocalContextExternalSnapshot {
        .init(providerID: "fuseintel", revision: "authored-1", generatedAt: now, expiresAt: now.addingTimeInterval(90),
            items: [.init(id: "signal-1", title: "Proposal review", detail: "Provider says review is pending.",
                         citations: [.init(source: "authored-provider", sourceID: "source-1", citation: "Authored citation")])])
    }

    private func expectFailure(_ task: Task<LocalContextSnapshot, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("Invalidated generation returned evidence", file: file, line: line) } catch { }
    }
    private func expectCurrentFailure(file: StaticString = #filePath, line: UInt = #line) async {
        do { let value = try await service.current(); XCTAssertNil(value, file: file, line: line) } catch { }
    }
}

private actor ContextTestPolicy {
    private var excluded = false
    private var remainingReads: Int?
    private var entered = false
    private var releaseGate: CheckedContinuation<Void, Never>?
    func exclude() { excluded = true }
    func holdAfterReads(_ count: Int) { remainingReads = count; entered = false }
    func waitUntilEntered() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !entered && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(entered, "Final policy read checkpoint was not reached")
    }
    func release() { remainingReads = nil; releaseGate?.resume(); releaseGate = nil }
    func value() async -> CaptureConfig {
        if let count = remainingReads {
            remainingReads = count - 1
            if count == 1 { entered = true; await withCheckedContinuation { releaseGate = $0 } }
        }
        return CaptureConfig(excludedAppBundleIDs: excluded ? ["com.authored.context"] : [])
    }
}
private final class ContextTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wall = Date(timeIntervalSince1970: 1_800_000_000)
    private var uptime: TimeInterval = 100
    func read() -> LocalContextInstant { lock.lock(); defer { lock.unlock() }; return .init(wall: wall, uptime: uptime) }
    func advance(wall seconds: TimeInterval, uptime delta: TimeInterval) { lock.lock(); defer { lock.unlock() }; wall.addTimeInterval(seconds); uptime += delta }
}
private actor ContextTestModel: LocalContextTopicModel {
    private(set) var calls = 0
    private var response: LocalContextTopicProposal?
    private var shouldFail = false
    private var cancelled = false
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    func fail() { shouldFail = true }
    func waitUntilCancelled() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !cancelled && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(cancelled, "Model work did not receive cancellation")
    }
    private func markCancelled() { cancelled = true; cancelWaiters.forEach { $0.resume() }; cancelWaiters.removeAll() }
    private var held = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseGate: CheckedContinuation<Void, Never>?
    func setResponse(_ value: LocalContextTopicProposal?) { response = value }
    func hold() { held = true; entered = false }
    func waitUntilEntered() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !entered && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(entered, "Owned test checkpoint was not reached")
    }
    func release() { held = false; releaseGate?.resume(); releaseGate = nil }
    func topic(for candidates: [LocalContextModelCandidate]) async throws -> LocalContextTopicProposal? {
        calls += 1; entered = true; waiters.forEach { $0.resume() }; waiters.removeAll()
        if held {
            await withTaskCancellationHandler {
                await withCheckedContinuation { releaseGate = $0 }
            } onCancel: { Task { await self.markCancelled() } }
        }
        try Task.checkCancellation()
        if shouldFail { throw ContextTestModelFailure.authored }
        return response
    }
}
private enum ContextTestModelFailure: Error { case authored }
private actor ContextTestMetrics {
    private(set) var events: [LocalContextMetric] = []
    private var held = false, entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseGate: CheckedContinuation<Void, Never>?
    func holdPublication() { held = true; entered = false }
    func waitUntilEntered() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !entered && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(entered, "Owned test checkpoint was not reached")
    }
    func release() { held = false; releaseGate?.resume(); releaseGate = nil }
    func record(_ event: LocalContextMetric) async {
        events.append(event)
        if held && event.operation == .prepared {
            entered = true; waiters.forEach { $0.resume() }; waiters.removeAll()
            await withCheckedContinuation { releaseGate = $0 }
        }
    }
}
private actor ContextTestProvider {
    private var current: LocalContextExternalSnapshot?
    func set(_ value: LocalContextExternalSnapshot?) { current = value }
    func accepts(_ value: LocalContextExternalSnapshot) -> Bool { current == value }
}
