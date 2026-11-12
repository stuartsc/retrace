import App
import AppKit
import Database
import Foundation
import Shared
import Storage
import XCTest
@testable import Retrace

@MainActor
final class TranscriptCommandLifecycleTests: XCTestCase {
    func testHideDuringHeldExactResolutionPreventsLateWindow() async throws {
        let fixture = try await TranscriptCommandFixture.make()
        let entered = expectation(description: "Exact private transcript read held")
        let hold = TranscriptCommandHold(entered: entered)
        var presentations = 0
        let controller = fixture.controller(present: { _ in presentations += 1 }, hold: hold)
        let opening = Task { try await controller.showExactFromCommand(fixture.references[0], coordinator: fixture.coordinator,
            authorization: .init(fence: NativeMutationFence(), validation: {})) }
        await fulfillment(of: [entered], timeout: 3)
        controller.hide(); await hold.release()
        do { try await opening.value; XCTFail("Hide revokes the pending exact read") }
        catch is CancellationError { }
        XCTAssertFalse(controller.isVisible); XCTAssertEqual(presentations, 0)
        controller.window?.close(); try await fixture.close()
    }

    func testOrdinarySelectionDuringHeldAuthorizationWinsOverExactCommand() async throws {
        let fixture = try await TranscriptCommandFixture.make()
        let entered = expectation(description: "Command authorization held")
        let hold = TranscriptCommandHold(entered: entered)
        var presentations = 0
        let controller = fixture.controller(present: { _ in presentations += 1 })
        let opening = Task { try await controller.showExactFromCommand(fixture.references[0], coordinator: fixture.coordinator,
            authorization: .init(fence: NativeMutationFence(), validation: { await hold.wait() })) }
        await fulfillment(of: [entered], timeout: 3)
        controller.showExactSearchResult(fixture.rows[1])
        await hold.release()
        do { try await opening.value; XCTFail("Ordinary selection supersedes pending command") }
        catch is CancellationError { }
        XCTAssertEqual(try visibleIDs(controller), [fixture.rows[1].id]); XCTAssertEqual(presentations, 1)
        controller.hide(); controller.window?.close(); try await fixture.close()
    }

    func testReverseCommandCompletionAndCleanupPreserveNewerExactTranscript() async throws {
        let fixture = try await TranscriptCommandFixture.make()
        let entered = expectation(description: "Older exact command waits")
        let hold = TranscriptCommandHold(entered: entered)
        var presentations = 0
        let controller = fixture.controller(present: { _ in presentations += 1 })
        let old = Task { try await controller.showExactFromCommand(fixture.references[0], coordinator: fixture.coordinator,
            authorization: .init(fence: NativeMutationFence(), validation: { await hold.wait() })) }
        await fulfillment(of: [entered], timeout: 3)
        try await controller.showExactFromCommand(fixture.references[1], coordinator: fixture.coordinator,
            authorization: .init(fence: NativeMutationFence(), validation: {}))
        await hold.release()
        do { try await old.value; XCTFail("Older command cannot replace current exact transcript") }
        catch is CancellationError { }
        XCTAssertEqual(try visibleIDs(controller), [fixture.rows[1].id]); XCTAssertEqual(presentations, 1)
        controller.hide(); controller.window?.close(); try await fixture.close()
    }

    func testReconfigurationAndNativeCloseRevokePendingExactCommands() async throws {
        let fixture = try await TranscriptCommandFixture.make()
        for reconfigure in [false, true] {
            let entered = expectation(description: "Pending transcript before owner lifecycle change")
            let hold = TranscriptCommandHold(entered: entered)
            var presentations = 0
            let controller = fixture.controller(present: { _ in presentations += 1 })
            let opening = Task { try await controller.showExactFromCommand(fixture.references[0], coordinator: fixture.coordinator,
                authorization: .init(fence: NativeMutationFence(), validation: { await hold.wait() })) }
            await fulfillment(of: [entered], timeout: 3)
            if reconfigure {
                controller.configure(coordinator: AppCoordinator(services: ServiceContainer(databasePath: "file:replacement-\(UUID())?mode=memory&cache=private",
                    storageConfig: .init(storageRootPath: fixture.root.path))))
            } else { controller.windowWillClose(.init(name: NSWindow.willCloseNotification, object: controller.window)) }
            await hold.release()
            do { try await opening.value; XCTFail("Changed window/source owner must reject late publication") }
            catch is CancellationError { }
            XCTAssertFalse(controller.isVisible); XCTAssertEqual(presentations, 0)
            controller.hide(); controller.window?.close()
        }
        try await fixture.close()
    }

    private func visibleIDs(_ controller: TranscriptWindowController) throws -> [Int64] {
        let hosting = try XCTUnwrap(controller.window?.contentView as? FirstMouseHostingView<TranscriptContentView>)
        return hosting.rootView.transcriptions.map(\.id)
    }
}

private actor TranscriptCommandHold {
    private let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation) { self.entered = entered }
    func wait() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
    func release() { continuation?.resume(); continuation = nil }
}

private struct TranscriptCommandFixture: Sendable {
    let root: URL
    let database: DatabaseManager
    let adapter: DataAdapter
    let markers: TimelineMarkerService
    let companion: CompanionController
    let reader: LiveContextSearchService
    let coordinator: AppCoordinator
    let rows: [AudioTranscription]
    let references: [V23TranscriptReference]

    @MainActor static func make() async throws -> Self {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-command-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = "file:transcript-command-ui-\(UUID())?mode=memory&cache=private"
        let database = DatabaseManager(databasePath: path); try await database.initialize()
        let pointer = await database.getConnection(), audio = AudioTranscriptionQueries(db: try XCTUnwrap(pointer))
        let adapter = DataAdapter(retraceConnection: try await database.makeRecallReadConnection(),
            retraceConfig: .init(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
        try await adapter.initialize()
        let native = try await database.activityStoreID()
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { native })
        let state = NativeCaptureState(config: Shared.CaptureConfig(), revision: UUID())
        let recall = ProgressiveRecallService(database: database, adapter: adapter, configuration: { state.config },
            disclosureState: { state }, imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
        let companion = CompanionController(storageRoot: root.appendingPathComponent("companion"), nativeStoreID: native,
            databasePath: path, adapter: adapter, recall: recall, markers: markers,
            verifiedBytes: { _ in XCTFail("Transcript navigation must not read media"); throw CompanionError.unavailable }, policy: {})
        let reader = LiveContextSearchService(database: database, audio: audio, adapter: adapter, recall: recall,
            markers: markers, captureState: { state })
        var rows: [AudioTranscription] = []
        for index in 0..<2 {
            let time = Date(timeIntervalSince1970: 1_800_000_000 + Double(index * 10))
            let id = try await audio.insertTranscription(sessionID: nil, text: "Private authored row \(index)",
                startTime: time, endTime: time.addingTimeInterval(2), source: .microphone, confidence: nil, words: [])
            let row = try await audio.getContextEntry(id: id); rows.append(try XCTUnwrap(row))
        }
        let coordinator = AppCoordinator(services: ServiceContainer(databasePath: "file:unstarted-ui-\(UUID())?mode=memory&cache=private",
            storageConfig: .init(storageRootPath: root.path)))
        return .init(root: root, database: database, adapter: adapter, markers: markers, companion: companion,
            reader: reader, coordinator: coordinator, rows: rows,
            references: try rows.map { try CompanionTranscriptSnapshot.recordingReference(for: $0, nativeStoreID: native) })
    }

    @MainActor func controller(present: @escaping (NSPanel) -> Void, hold: TranscriptCommandHold? = nil) -> TranscriptWindowController {
        let playback = TranscriptAudioPlayback(resolve: { _ in XCTFail("Opening must not prepare playback"); throw TranscriptAudioError.unavailable }, isMuted: true)
        return .init(playback: playback, presentWindow: present, commandCoordinator: coordinator, loadExactCommand: { reference in
            let row = try await reader.resolveTranscript(reference)
            await hold?.wait()
            return (row, companion)
        })
    }
    func close() async throws {
        try await companion.close(); try await markers.close(); await adapter.shutdown(); try await database.close()
        try FileManager.default.removeItem(at: root)
    }
}
