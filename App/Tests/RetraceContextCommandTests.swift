import Database
import Foundation
import Shared
import Storage
import XCTest
@testable import App

final class RetraceContextCommandTests: XCTestCase {
    func testSharedSearchAndCopyRequireEvidenceGrantForInheritedRanges() async throws {
        let fixture = try await Fixture.make()
        let marker = try await fixture.markers.createManualMarker(.init(anchoredAt: fixture.time, title: "Range marker"))
        let manual = try await fixture.markers.saveContextRange(markerID: marker.id,
            range: .init(start: fixture.time, end: fixture.time.addingTimeInterval(1),
                         explanation: "Budget user context", ownership: .manual),
            expectedRevision: nil, expectedMarkerRevision: marker.revision)
        let support = CompanionEvidenceItem(id: "retained-budget", reference: .init(v23Transcript: .init(
            nativeStoreID: marker.nativeStoreID, source: .microphone, rowID: 1, snapshotSHA256: String(repeating: "a", count: 64))),
            start: fixture.time, end: fixture.time.addingTimeInterval(1), text: "Budget inherited source")
        let request = CompanionJobRequest(sourceStoreID: marker.nativeStoreID, observedAt: fixture.time, context: .init(
            markerID: marker.id, markerRevision: marker.revision, snapshotID: UUID(), query: "Budget",
            verbatimExplanation: "", developing: true, incomplete: true, evidence: [support]))
        let requestData = try CompanionWire.encode(request)
        let result = CompanionResult(jobID: CompanionWire.digest(requestData), sourceStoreID: marker.nativeStoreID,
            contextProposal: .init(markerID: marker.id, markerRevision: marker.revision, snapshotID: request.context!.snapshotID,
                verbatimExplanation: "", developing: true, incomplete: true,
                ranges: [.init(id: UUID(), start: support.start, end: support.end, explanation: support.text,
                               supportIDs: [support.id], score: 1)], method: "authored"))
        try await CompanionContextImporter(markers: fixture.markers).apply(request: request, result: result,
            requestData: requestData, resultData: CompanionWire.encode(result))
        let ranges = try await fixture.markers.listContextRanges(markerID: marker.id)
        let inherited = try XCTUnwrap(ranges.first { $0.effectiveExplanationOrigin == .companionDerived })
        let interval = DateInterval(start: fixture.time.addingTimeInterval(-1), duration: 20)
        let token = "marker-range-only-32-characters-minimum-length", digest = RetraceCommandDispatcher.tokenDigest(token)
        // A marker-scoped handler exercises the shared service independently of the
        // production search/copy operations, which already require evidence.read.
        let dispatcher = try RetraceCommandDispatcher(directory: fixture.root.appendingPathComponent("commands"),
            grants: [.init(clientID: "reader", tokenSHA256: digest, capabilities: [.markersRead])],
            handlers: [.init(operation: .markerRead) { context in
                let page = try await fixture.service.searchGranted(interval: interval, query: "Budget", context: context)
                let copied = try await fixture.service.copyGranted(references: [.range(marker: marker, range: manual)],
                    interval: interval, partial: true, context: context)
                XCTAssertTrue(copied.text.contains("Budget user context"))
                if context.capabilities.contains(.evidenceRead) {
                    XCTAssertTrue(page.items.contains { $0.text == "Budget inherited source" })
                    _ = try await fixture.service.copyGranted(references: [.range(marker: marker, range: inherited)],
                        interval: interval, partial: true, context: context)
                } else {
                    XCTAssertFalse(page.items.contains { $0.text.contains("Budget inherited source") })
                    do {
                        _ = try await fixture.service.copyGranted(references: [.range(marker: marker, range: inherited)],
                            interval: interval, partial: true, context: context)
                        XCTFail("Inherited context requires its evidence grant even through a marker-scoped handler")
                    } catch RetraceCommandError.notPermitted { }
                    catch { XCTFail("Unexpected inherited-range failure: \(error)") }
                }
                return .null
            }])
        let first = await dispatcher.execute(.init(requestID: UUID(), operation: .markerRead), bearerToken: token)
        XCTAssertEqual(first.status, .succeeded)
        let restrictedCalls = await fixture.evidenceCounter.calls
        XCTAssertEqual(restrictedCalls, 0, "Manual range reads must not validate or disclose unrelated inherited sources")
        try await dispatcher.replaceGrants([.init(clientID: "reader", tokenSHA256: digest, capabilities: [.markersRead, .evidenceRead])])
        let second = await dispatcher.execute(.init(requestID: UUID(), operation: .markerRead), bearerToken: token)
        XCTAssertEqual(second.status, .succeeded)
        let allowedCalls = await fixture.evidenceCounter.calls
        XCTAssertGreaterThan(allowedCalls, 0)
        await dispatcher.close(); try await fixture.close()
    }

    func testMixedSearchGrantsBoundPagingAndSharedCopyRejectsChanges() async throws {
        let fixture = try await Fixture.make()
        let token = "evidence-token-32-characters-minimum-length", all = "all-sources-token-32-characters-minimum-length"
        let commands = RetraceContextCommands(reader: { fixture.service })
        let dispatcher = try RetraceCommandDispatcher(directory: fixture.root.appendingPathComponent("commands"), grants: [
            .init(clientID: "evidence", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.evidenceRead]),
            .init(clientID: "all", tokenSHA256: RetraceCommandDispatcher.tokenDigest(all), capabilities: [.evidenceRead, .annotationsRead, .markersRead])
        ], handlers: [.init(operation: .search) { try await commands.search($0) }, .init(operation: .copyContext) { try await commands.copy($0) }])
        let args: RetraceJSON = .object(["from": .number(fixture.time.addingTimeInterval(-1).timeIntervalSince1970 * 1000),
            "to": .number(fixture.time.addingTimeInterval(10).timeIntervalSince1970 * 1000), "text": .string("Budget"), "limit": .integer(1)])
        let limited = await dispatcher.execute(.init(requestID: UUID(), operation: .search, arguments: args), bearerToken: token)
        XCTAssertEqual(limited.status, .succeeded)
        let limitedText = String(decoding: try RetraceWire.encoder().encode(limited), as: UTF8.self)
        XCTAssertFalse(limitedText.contains("Budget private note")); XCTAssertFalse(limitedText.contains("Budget private marker"))
        XCTAssertTrue(limitedText.contains("no grant"))
        var arguments = args, collected: [[String: Any]] = []
        var firstCursor: String?
        for _ in 0..<10 {
            let page = await dispatcher.execute(.init(requestID: UUID(), operation: .search, arguments: arguments), bearerToken: all)
            XCTAssertEqual(page.status, .succeeded)
            let body = try object(page)
            collected += try XCTUnwrap(body["entries"] as? [[String: Any]])
            guard let cursor = body["nextCursor"] as? String else { break }
            firstCursor = firstCursor ?? cursor
            guard case .object(var fields) = args else { fatalError() }
            fields["cursor"] = .string(cursor); arguments = .object(fields)
        }
        XCTAssertEqual(Set(collected.compactMap { $0["kind"] as? String }), ["Notes", "Marker", "Transcripts"])
        XCTAssertEqual(collected.count, 3, "Continuation must not skip or duplicate the shared source page")
        let noteSelection = try XCTUnwrap(collected.first { $0["kind"] as? String == "Notes" }?["selectionID"] as? String)
        let copyArgs: RetraceJSON = .object(["selectionIDs": .array([.string(noteSelection)]), "question": .string("What should I remember?")])
        let crossClient = await dispatcher.execute(.init(requestID: UUID(), operation: .copyContext, arguments: copyArgs), bearerToken: token)
        XCTAssertEqual(crossClient.status, .conflict)
        let copy = await dispatcher.execute(.init(requestID: UUID(), operation: .copyContext, arguments: copyArgs), bearerToken: all)
        XCTAssertEqual(copy.status, .succeeded)
        let text = try XCTUnwrap(try object(copy)["text"] as? String)
        XCTAssertTrue(text.contains("Budget private note")); XCTAssertTrue(text.contains("What should I remember?")); XCTAssertTrue(text.contains("Source:"))
        try await fixture.database.updateSegmentComment(commentId: fixture.note.id, body: "Corrected note", author: fixture.note.author, attachments: [])
        let stale = await dispatcher.execute(.init(requestID: UUID(), operation: .copyContext, arguments: copyArgs), bearerToken: all)
        XCTAssertEqual(stale.status, .conflict); XCTAssertNil(stale.data)
        if let firstCursor, case .object(var fields) = args {
            fields["cursor"] = .string(firstCursor)
            let foreign = await dispatcher.execute(.init(requestID: UUID(), operation: .search, arguments: .object(fields)), bearerToken: token)
            XCTAssertEqual(foreign.status, .conflict)
        }
        await dispatcher.close(); try await fixture.close()
    }

    func testAdditionalGrantCannotEscapeItsCommandScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = SavedContext()
        let token = "test-token-32-characters-minimum-length"
        let dispatcher = try RetraceCommandDispatcher(directory: root, grants: [.init(clientID: "owner",
            tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.evidenceRead, .markersRead])],
            handlers: [.init(operation: .search) { context in
                try await context.authorize(.markersRead)
                do { try await context.authorize(.annotationsRead); XCTFail("Missing source grant accepted") } catch { }
                await saved.set(context); return .null
            }])
        let response = await dispatcher.execute(.init(requestID: UUID(), operation: .search), bearerToken: token)
        XCTAssertEqual(response.status, .succeeded)
        let value = await saved.value
        do { try await XCTUnwrap(value).authorize(.markersRead); XCTFail("Escaped command context accepted") } catch { }
        await dispatcher.close()
    }
    private func object(_ response: RetraceCommandResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: RetraceWire.encoder().encode(XCTUnwrap(response.data))) as? [String: Any])
    }
    private actor SavedContext { var value: RetraceCommandContext?; func set(_ context: RetraceCommandContext) { value = context } }
    private actor EvidenceCounter { var calls = 0; func record() { calls += 1 } }
    private struct Fixture: Sendable {
        let root: URL, database: DatabaseManager, adapter: DataAdapter, markers: TimelineMarkerService, service: LiveContextSearchService
        let ranges: ContextRangePresentationService, evidenceCounter: EvidenceCounter
        let note: SegmentComment
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        static func make() async throws -> Self {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: root.appendingPathComponent("commands"), withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let database = DatabaseManager(databasePath: root.appendingPathComponent("recordings.db").path)
            try await database.initialize()
            let connection = await database.getConnection(), native = try await database.activityStoreID()
            let audio = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
            let adapter = DataAdapter(retraceConnection: try await database.makeRecallReadConnection(),
                retraceConfig: .init(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
                retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
            try await adapter.initialize()
            let state = NativeCaptureState(config: Shared.CaptureConfig(), revision: UUID())
            let recall = ProgressiveRecallService(database: database, adapter: adapter, configuration: { state.config },
                disclosureState: { state }, imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
            let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { native })
            let evidenceCounter = EvidenceCounter()
            let ranges = ContextRangePresentationService(markers: markers,
                validateEvidence: { _ in await evidenceCounter.record() }, currentEpoch: { "fixture" })
            let time = Date(timeIntervalSince1970: 1_800_000_000)
            let segment = try await database.insertSegment(bundleID: "com.fixture", startDate: time, endDate: time.addingTimeInterval(4), windowName: nil, browserUrl: nil, type: 0)
            let note = try await database.createSegmentComment(body: "Budget private note", author: "Fixture")
            try await database.addCommentToSegment(segmentId: .init(value: segment), commentId: note.id)
            _ = try await markers.createManualMarker(.init(anchoredAt: time, title: "Budget private marker"))
            _ = try await audio.insertTranscription(sessionID: nil, text: "Budget audio", startTime: time, endTime: time.addingTimeInterval(1), source: .microphone, confidence: nil, words: [])
            return .init(root: root, database: database, adapter: adapter, markers: markers,
                service: .init(database: database, audio: audio, adapter: adapter, recall: recall, markers: markers,
                    captureState: { state }, contextRanges: ranges), ranges: ranges, evidenceCounter: evidenceCounter, note: note)
        }
        func close() async throws { await ranges.close(); try await markers.close(); await adapter.shutdown(); try await database.close(); try FileManager.default.removeItem(at: root) }
    }
}
