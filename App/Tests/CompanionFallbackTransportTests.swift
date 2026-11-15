import Database
import Foundation
import Shared
import Storage
import XCTest
@testable import App

/// Real private spool/catalogue and AAC files; the test seam controls only remote
/// availability, monotonic time and the expensive inference admission boundary.
final class CompanionFallbackTransportTests: XCTestCase {
    func testNewCataloguePublicationFallsBackWhenRemoteWasOfflineFromStart() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let remote = LeaseRemote(), clock = TestClock(), execution = ExecutionProbe()
        await remote.setOffline(true)
        let transport = fixture.transport(remote: remote, clock: clock) { root, id, admitted, admission in
            try await admitted(); try admission(); execution.enter()
            try fixture.writeResult(root: root, id: id)
            return fixture.result
        }
        // Use the actual service publication boundary to establish durable new
        // provenance, rather than treating a missing assignment as proof.
        let service = CompanionEnrichmentService(root: fixture.root.appendingPathComponent("delivery"),
            nativeStoreID: fixture.native, transport: transport, revalidate: { _ in }, importResult: { _, _, _, _ in })
        let request = try CompanionWire.decode(CompanionJobRequest.self, data: fixture.request, limit: 768 * 1024)
        _ = try await service.publish(request, objects: [.init(sha256: CompanionWire.digest(fixture.media), data: fixture.media)])
        _ = try await service.synchronize()
        XCTAssertFalse(execution.entered)
        XCTAssertEqual(try fixture.assignment()["publicationAttempted"] as? Bool, false)
        clock.advance(301)
        _ = try await service.synchronize()
        try await eventually { execution.entered && FileManager.default.fileExists(atPath: fixture.output.path) }
        _ = try await service.synchronize()
        let retained = try await service.retainedResult(jobID: fixture.id)
        XCTAssertNotNil(retained)
        let publications = await remote.publications
        XCTAssertEqual(publications, 0)
        try await service.close()
    }

    func testRemoteRecoveryCancelsWaitingLocalAdmissionWithoutBlockingDelivery() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let governor = HeldGovernor(), execution = ExecutionProbe()
        let remote = LeaseRemote(), clock = TestClock()
        let transport = fixture.transport(remote: remote, clock: clock) { root, id, admitted, admission in
            try await BackgroundProcessingContext.run(governor: governor, kind: .refinement) {
                try await admitted(); try admission(); execution.enter()
                return fixture.result
            }
        }
        try await fixture.publish(transport)
        await remote.setOffline(true)
        _ = try await transport.result(id: fixture.id)
        clock.advance(301)
        let pending = try await transport.result(id: fixture.id)
        XCTAssertNil(pending)
        try await eventually { governor.waiting }
        let waiting = await transport.processingStatus()
        XCTAssertEqual(waiting?.phase, .waitingForQuiet)
        await remote.setOffline(false, result: fixture.result)
        let recovered = try await transport.result(id: fixture.id)
        XCTAssertEqual(recovered, fixture.result)
        XCTAssertFalse(execution.entered)
        XCTAssertTrue(governor.cancelled)
        let assignment = try fixture.assignment()
        XCTAssertEqual(assignment["local"] as? Bool, false)
        try await transport.acknowledge(id: fixture.id, resultSHA256: CompanionWire.digest(fixture.result))
        let acknowledgements = await remote.acknowledgements
        XCTAssertEqual(acknowledgements, 1)
        await transport.close()
    }

    func testUnknownAndLegacyGrantCannotEnableTimeoutOnlyLocalTakeover() async throws {
        for mode in [LeaseRemote.GrantMode.unknown, .legacy] {
            let fixture = try await Fixture.make()
            let remote = LeaseRemote(mode: mode), clock = TestClock(), execution = ExecutionProbe()
            let transport = fixture.transport(remote: remote, clock: clock) { _, _, admitted, _ in
                execution.enter(); try await admitted(); return fixture.result
            }
            let catalogue = try await fixture.importResult()
            let catalogueID = try await catalogue.identity()
            try await transport.bindCatalogue(catalogueID)
            try await fixture.publish(transport)
            // An existing unknown assignment must not be relabelled fresh,
            // even if a publication callback is mistakenly replayed.
            try await transport.registerUnpublishedJob(id: fixture.id, data: fixture.request)
            XCTAssertNil(try fixture.assignment()["knownUnpublished"])
            await remote.setOffline(true)
            _ = try await transport.result(id: fixture.id)
            clock.advance(86_400)
            _ = try await transport.result(id: fixture.id)
            XCTAssertFalse(execution.entered)
            XCTAssertEqual(try fixture.assignment()["local"] as? Bool, false)
            let publishes = await remote.publications
            XCTAssertEqual(publishes, mode == .legacy ? 1 : 0,
                           "Legacy peers retain their existing remote-only processing")
            try await catalogue.close(); await transport.close(); fixture.remove()
        }
    }

    func testRecreatedCatalogueCannotReuseUnpublishedProofFromOlderCatalogue() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let remote = LeaseRemote(), clock = TestClock(), execution = ExecutionProbe()
        await remote.setOffline(true)
        let firstCatalogue = try await fixture.importResult()
        let firstID = try await firstCatalogue.identity()
        let first = fixture.transport(remote: remote, clock: clock) { _, _, _, _ in
            execution.enter(); return fixture.result
        }
        try await first.bindCatalogue(firstID)
        try await first.registerUnpublishedJob(id: fixture.id, data: fixture.request)
        try await fixture.publish(first)
        await first.close(); try await firstCatalogue.close()
        let replacement = CompanionDeliveryDatabase(databasePath: fixture.root.appendingPathComponent("replacement.db").path,
            nativeStoreID: fixture.native)
        try await replacement.initialize()
        let second = fixture.transport(remote: remote, clock: clock) { _, _, _, _ in
            execution.enter(); return fixture.result
        }
        let replacementID = try await replacement.identity()
        try await second.bindCatalogue(replacementID)
        try await second.registerUnpublishedJob(id: fixture.id, data: fixture.request)
        _ = try await second.result(id: fixture.id)
        clock.advance(86_400)
        _ = try await second.result(id: fixture.id)
        XCTAssertFalse(execution.entered)
        XCTAssertEqual(try fixture.assignment()["provenanceCatalogueID"] as? String, firstID.uuidString)
        try await replacement.close(); await second.close()
    }

    func testRestartAfterLocalImportAcknowledgesPersistedOwnerWithoutRemote() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let remote = LeaseRemote(), clock = TestClock(), execution = ExecutionProbe()
        let first = fixture.transport(remote: remote, clock: clock) { root, id, admitted, admission in
            try await admitted(); try admission(); execution.enter()
            try fixture.writeResult(root: root, id: id)
            return fixture.result
        }
        try await fixture.publish(first)
        try await fixture.startFailover(first, remote: remote, clock: clock)
        try await eventually { execution.entered && FileManager.default.fileExists(atPath: fixture.output.path) }
        let imported = try await fixture.importResult()
        await first.close()
        let second = fixture.transport(remote: remote, clock: clock) { _, _, _, _ in
            XCTFail("Imported local result must not run inference again")
            throw CompanionError.unavailable
        }
        try await second.acknowledge(id: fixture.id, resultSHA256: CompanionWire.digest(fixture.result))
        // Repeating the acknowledgement after collection is itself durable.
        try await second.acknowledge(id: fixture.id, resultSHA256: CompanionWire.digest(fixture.result))
        let acknowledgements = await remote.acknowledgements
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.object.path))
        XCTAssertEqual(try Data(contentsOf: fixture.original), fixture.media)
        let retained = try await imported.record(jobID: fixture.id)
        XCTAssertEqual(retained?.stage, .imported)
        XCTAssertEqual(retained?.resultPayload, fixture.result)
        try await imported.close(); await second.close()
    }

    func testAcknowledgementCancelsAndJoinsLocalReaderBeforeCollectingInputs() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let remote = LeaseRemote(), clock = TestClock(), execution = ExecutionProbe()
        let readerMayExit = AsyncLatch(), acknowledgement = ExecutionProbe()
        let transport = fixture.transport(remote: remote, clock: clock) { root, id, admitted, admission in
            try await admitted(); try admission()
            let handle = try FileHandle(forReadingFrom: fixture.object)
            defer { try? handle.close(); execution.join() }
            try fixture.writeResult(root: root, id: id)
            execution.enter()
            return await withTaskCancellationHandler {
                await readerMayExit.wait()
                return fixture.result
            } onCancel: { execution.cancel() }
        }
        try await fixture.publish(transport)
        try await fixture.startFailover(transport, remote: remote, clock: clock)
        try await eventually { execution.entered }
        let imported = try await fixture.importResult()
        let ack = Task {
            try await transport.acknowledge(id: fixture.id, resultSHA256: CompanionWire.digest(fixture.result))
            acknowledgement.enter()
        }
        try await eventually { execution.cancelled }
        XCTAssertFalse(acknowledgement.entered)
        XCTAssertFalse(execution.joined)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.object.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
        readerMayExit.open()
        try await ack.value
        XCTAssertTrue(execution.joined)
        XCTAssertTrue(acknowledgement.entered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.object.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.receipt.path))
        let retained = try await imported.record(jobID: fixture.id)
        XCTAssertEqual(retained?.resultPayload, fixture.result)
        XCTAssertEqual(try Data(contentsOf: fixture.original), fixture.media)
        try await imported.close(); await transport.close()
    }

    private func eventually(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Owned asynchronous boundary did not arrive")
    }

    private struct Fixture: Sendable {
        let root: URL, native: UUID, original: URL, media: Data, request: Data, result: Data, id: String
        var routing: URL { root.appendingPathComponent("routing") }
        var object: URL { routing.appendingPathComponent("objects/\(CompanionWire.digest(media)).m4a") }
        var output: URL { routing.appendingPathComponent("execution-results/\(id).json") }
        var receipt: URL { routing.appendingPathComponent("routing-receipts/\(id).json") }
        static func make() async throws -> Self {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let start = Date(timeIntervalSince1970: 1_800_000_000), native = UUID()
            let samples = (0..<16000).map { Int16(sin(Double($0) * 2 * .pi * 220 / 16000) * 4000) }
            let saved = try await AudioSegmentWriter(storageRoot: root).writeFullBatch(
                audioData: samples.withUnsafeBytes { Data($0) }, timestamp: start, source: .microphone)
            let original = root.appendingPathComponent(saved.filePath), media = try Data(contentsOf: original)
            let identity = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(), startSample: 0,
                sampleCount: 16000, sampleRate: 16000, approximateOrigin: start)
            let text = "Authored draft words"
            let request = CompanionJobRequest(sourceStoreID: native, observedAt: start, speaker: .init(
                sourceIdentity: identity, firstPassText: text,
                media: [.init(sha256: CompanionWire.digest(media), byteCount: media.count,
                    mediaID: String(repeating: "a", count: 64), offsetSamples: 0, countSamples: 16000, sourceStartSample: 0)],
                firstPassReferences: [.init(nativeStoreID: native, source: .microphone, rowID: 1,
                    snapshotSHA256: String(repeating: "b", count: 64))]))
            try request.validate()
            let bytes = try CompanionWire.encode(request), id = CompanionWire.digest(bytes)
            let enhanced = CompanionSpeakerEnrichment(sourceIdentity: identity,
                firstPassSHA256: CompanionWire.digest(Data(text.utf8)), enhancedText: "Authored improved words",
                turns: [.init(start: 0, end: 1, text: "Authored improved words", speakerID: id + ":state:unknown",
                    speakerLabel: "Unknown speaker", speakerStatus: .unknown)], automaticNamesCalibrated: false,
                modelFingerprint: String(repeating: "c", count: 64))
            let object: [String: Any] = ["version": 1, "jobID": id, "kind": "speaker", "sourceStoreID": native.uuidString,
                "speakerEnrichment": try JSONSerialization.jsonObject(with: CompanionWire.encode(enhanced))]
            let result = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let decoded = try CompanionWire.decode(CompanionResult.self, data: result, limit: 2 * 1024 * 1024)
            try CompanionWire.validate(decoded, request: request, id: id)
            return .init(root: root, native: native, original: original, media: media, request: bytes, result: result, id: id)
        }
        func transport(remote: LeaseRemote, clock: TestClock, execute: @escaping CompanionFallbackTransport.Execute) -> CompanionFallbackTransport {
            CompanionFallbackTransport(remote: remote, root: routing, nativeStoreID: native, execute: execute, now: { clock.now })
        }
        func publish(_ transport: CompanionFallbackTransport) async throws {
            try await transport.publishObject(sha256: CompanionWire.digest(media), data: media)
            try await transport.publishJob(id: id, data: request)
        }
        func startFailover(_ transport: CompanionFallbackTransport, remote: LeaseRemote, clock: TestClock) async throws {
            await remote.setOffline(true)
            _ = try await transport.result(id: id)
            clock.advance(301)
            _ = try await transport.result(id: id)
        }
        func writeResult(root: URL, id: String) throws {
            try result.write(to: root.appendingPathComponent("execution-results/\(id).json"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        }
        func assignment() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
                routing.appendingPathComponent("assignments/\(id).json"))) as? [String: Any])
        }
        func importResult() async throws -> CompanionDeliveryDatabase {
            let catalog = CompanionDeliveryDatabase(databasePath: root.appendingPathComponent("retained.db").path, nativeStoreID: native)
            try await catalog.initialize()
            try await catalog.importLegacy(requestPayload: request, resultPayload: result, stage: .imported)
            return catalog
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private actor LeaseRemote: CompanionLeaseTransport {
    enum GrantMode { case supported, unknown, legacy }
    let mode: GrantMode
    private var offline = false
    private var returnedResult: Data?
    private(set) var publications = 0
    private(set) var acknowledgements = 0
    init(mode: GrantMode = .supported) { self.mode = mode }
    func setOffline(_ value: Bool, result: Data? = nil) { offline = value; returnedResult = result }
    func publishObject(sha256: String, data: Data) throws { try available() }
    func publishJob(id: String, data: Data) throws { try available(); publications += 1 }
    func result(id: String) throws -> Data? { try available(); return returnedResult }
    func acknowledge(id: String, resultSHA256: String) throws { try available(); acknowledgements += 1 }
    func grantExecution(id: String, attempt: String) throws -> Bool {
        try available()
        if mode == .unknown { throw CompanionError.transportRejected }
        return mode == .supported
    }
    func revokeExecution(id: String, attempt: String) throws -> Bool { try available(); return true }
    func close() {}
    private func available() throws { if offline { throw CompanionError.unavailable } }
}
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ seconds: Int64) { lock.withLock { instant = instant.advanced(by: .seconds(seconds)) } }
}
private final class ExecutionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values = (entered: false, cancelled: false, joined: false)
    var entered: Bool { lock.withLock { values.entered } }
    var cancelled: Bool { lock.withLock { values.cancelled } }
    var joined: Bool { lock.withLock { values.joined } }
    func enter() { lock.withLock { values.entered = true } }
    func cancel() { lock.withLock { values.cancelled = true } }
    func join() { lock.withLock { values.joined = true } }
}
private final class AsyncLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if opened { return true }
                continuations.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }
    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true; let values = continuations; continuations = []; return values
        }
        pending.forEach { $0.resume() }
    }
}
private final class HeldGovernor: BackgroundProcessingProtocol, @unchecked Sendable {
    private let gate = AsyncLatch(), state = ExecutionProbe()
    var waiting: Bool { state.entered }
    var cancelled: Bool { state.cancelled }
    func acquire(_ kind: BackgroundProcessingKind) async throws -> BackgroundProcessingPermit {
        XCTAssertEqual(kind, .refinement); state.enter()
        await withTaskCancellationHandler { await gate.wait() } onCancel: { self.state.cancel(); self.gate.open() }
        try Task.checkCancellation()
        return .init(threadCount: 1)
    }
    func release(_ permit: BackgroundProcessingPermit) {}
}
