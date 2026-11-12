import Foundation
import Shared
import XCTest
@testable import App

final class RetraceContextRangeGrantTests: XCTestCase {
    func testMarkerOnlyGrantRetainsManualDataWithoutReadingInheritedEvidence() async throws {
        let fixture = try await Fixture.make()
        let counter = EvidenceCounter()
        let owner = ContextRangePresentationService(markers: fixture.markers,
            validateEvidence: { _ in await counter.record() }, currentEpoch: { "stable" })
        let token = "marker-reader-32-characters-minimum-length"
        let dispatcher = try RetraceCommandDispatcher(directory: fixture.root.appendingPathComponent("commands"),
            grants: [.init(clientID: "reader", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.markersRead])],
            handlers: [.init(operation: .contextRead) { try await RetraceContextRangeCommands.read($0, owner: owner) }])
        let request = RetraceCommandRequest(requestID: UUID(), operation: .contextRead, arguments: .object(["id": .string(fixture.marker.id.uuidString)]))
        let limited = await dispatcher.execute(request, bearerToken: token)
        XCTAssertEqual(limited.status, .succeeded)
        let page = try XCTUnwrap(limited.data).decode(ContextRangePresentationPage.self)
        let manual = try XCTUnwrap(page.items.first { $0.id == fixture.manualID })
        XCTAssertEqual(manual.range?.explanation, "User authored context")
        let derived = try XCTUnwrap(page.items.first { $0.id == fixture.derivedID })
        XCTAssertEqual(derived.availability, .evidenceGrantRequired)
        XCTAssertNil(derived.range); XCTAssertNil(derived.reference.provenance)
        XCTAssertEqual(derived.userNote, "My independent note")
        let queries = await counter.calls
        XCTAssertEqual(queries, 0, "A marker grant must not query the derived evidence source")
        let encoded = String(decoding: try RetraceWire.encoder().encode(limited), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Confidential inherited evidence"))
        XCTAssertFalse(encoded.contains("private-support-id"))
        try await dispatcher.replaceGrants([.init(clientID: "reader", tokenSHA256: RetraceCommandDispatcher.tokenDigest(token), capabilities: [.markersRead, .evidenceRead])])
        let allowed = await dispatcher.execute(request, bearerToken: token)
        XCTAssertEqual(allowed.status, .succeeded)
        let expanded = try XCTUnwrap(allowed.data).decode(ContextRangePresentationPage.self)
        XCTAssertEqual(expanded.items.first { $0.id == fixture.derivedID }?.range?.explanation, "Confidential inherited evidence")
        let allowedQueries = await counter.calls
        XCTAssertGreaterThan(allowedQueries, 0)
        await dispatcher.close(); await owner.close(); try await fixture.close()
    }

    func testEvidenceGrantRevokedDuringSourceValidationReturnsNoContext() async throws {
        let fixture = try await Fixture.make(), gate = HeldEvidence()
        let owner = ContextRangePresentationService(markers: fixture.markers,
            validateEvidence: { _ in await gate.hold() }, currentEpoch: { "stable" })
        let token = "revoking-reader-32-characters-minimum-length"
        let digest = RetraceCommandDispatcher.tokenDigest(token)
        let dispatcher = try RetraceCommandDispatcher(directory: fixture.root.appendingPathComponent("commands"),
            grants: [.init(clientID: "reader", tokenSHA256: digest, capabilities: [.markersRead, .evidenceRead])],
            handlers: [.init(operation: .contextRead) { try await RetraceContextRangeCommands.read($0, owner: owner) }])
        let read = Task { await dispatcher.execute(.init(requestID: UUID(), operation: .contextRead,
            arguments: .object(["id": .string(fixture.marker.id.uuidString)])), bearerToken: token) }
        await gate.waitUntilEntered()
        try await dispatcher.replaceGrants([.init(clientID: "reader", tokenSHA256: digest, capabilities: [.markersRead])])
        await gate.release()
        let denied = await read.value
        XCTAssertEqual(denied.status, .denied); XCTAssertNil(denied.data)
        await dispatcher.close(); await owner.close(); try await fixture.close()
    }

    private struct Fixture {
        let root: URL, markers: TimelineMarkerService, marker: TimelineMarker, manualID: UUID, derivedID: UUID
        static func make() async throws -> Self {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), native = UUID()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: root.appendingPathComponent("commands"), withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { native })
            let time = Date(timeIntervalSince1970: 1_800_000_000)
            let marker = try await markers.createManualMarker(.init(anchoredAt: time))
            let support = CompanionEvidenceItem(id: "private-support-id", reference: .init(v23Transcript: .init(nativeStoreID: native,
                source: .microphone, rowID: 1, snapshotSHA256: String(repeating: "a", count: 64))),
                start: time.addingTimeInterval(-123), end: time.addingTimeInterval(-120), text: "Confidential inherited evidence")
            let request = CompanionJobRequest(sourceStoreID: native, observedAt: time, context: .init(markerID: marker.id,
                markerRevision: marker.revision, snapshotID: UUID(), query: "Remember", verbatimExplanation: "",
                developing: true, incomplete: true, evidence: [support]))
            let bytes = try CompanionWire.encode(request), derivedID = UUID()
            let result = CompanionResult(jobID: CompanionWire.digest(bytes), sourceStoreID: native,
                contextProposal: .init(markerID: marker.id, markerRevision: marker.revision, snapshotID: request.context!.snapshotID,
                    verbatimExplanation: "", developing: true, incomplete: true,
                    ranges: [.init(id: derivedID, start: support.start, end: support.end, explanation: support.text,
                                  supportIDs: [support.id], score: 1)], method: "authored"))
            try await CompanionContextImporter(markers: markers).apply(request: request, result: result, requestData: bytes, resultData: CompanionWire.encode(result))
            let ranges = try await markers.listContextRanges(markerID: marker.id)
            let derived = try XCTUnwrap(ranges.first)
            _ = try await markers.saveContextRange(markerID: marker.id, range: .init(id: derived.id, start: derived.start, end: derived.end,
                explanation: derived.explanation, ownership: .pinned, userNote: "My independent note"), expectedRevision: derived.revision,
                expectedMarkerRevision: marker.revision)
            let manual = try await markers.saveContextRange(markerID: marker.id,
                range: .init(start: time, end: time.addingTimeInterval(1), explanation: "User authored context", ownership: .manual),
                expectedRevision: nil, expectedMarkerRevision: marker.revision)
            return .init(root: root, markers: markers, marker: marker, manualID: manual.id, derivedID: derivedID)
        }
        func close() async throws { try await markers.close(); try FileManager.default.removeItem(at: root) }
    }
    private actor EvidenceCounter { var calls = 0; func record() { calls += 1 } }
    private actor HeldEvidence {
        private var entered = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async {
            if entered { return }
            entered = true; waiting.forEach { $0.resume() }; waiting.removeAll()
            await withCheckedContinuation { continuation = $0 }
        }
        func waitUntilEntered() async { if !entered { await withCheckedContinuation { waiting.append($0) } } }
        func release() { continuation?.resume(); continuation = nil }
    }
}
