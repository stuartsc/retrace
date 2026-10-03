import AVFoundation
import AppKit
import CryptoKit
import XCTest
import Database
import Shared
import Storage
@testable import Retrace

@MainActor
final class TranscriptRecordingVisibilityTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testPendingAACLoadsWithoutTranscribingOrPlayingAndRetainsItsExactRange() async throws {
        let fixture = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let id = try await queries.insertRawBatch(startTime: base, endTime: base.addingTimeInterval(3),
            source: .microphone, audioPath: fixture.path, audioSize: fixture.size)
        let originalBytes = try Data(contentsOf: fixture.root.appendingPathComponent(fixture.path))

        let page = try await TranscriptRecordingLoader.load(queries: queries, at: base)
        XCTAssertEqual(page.transcriptions.map(\.id), [id], "Saved audio must be visible before text is prepared")
        XCTAssertFalse(page.isTruncated)
        let row = try XCTUnwrap(page.transcriptions.first)
        XCTAssertEqual(row.transcriptStatus, "pending")
        XCTAssertEqual(row.text, "")
        XCTAssertEqual(TranscriptPresentationPolicy.presentationRows(from: [row]).first?.textPreparationLabel,
            "Text not ready — waiting for background processing")
        let request = TranscriptAudioRequest(transcription: row)
        let clip = try await TranscriptAudioFileResolver.resolve(request: request, storageRoot: fixture.root)
        XCTAssertEqual(clip.startTime, 0, accuracy: 0.002)
        XCTAssertEqual(clip.endTime, 3, accuracy: 0.002)
        let playback = TranscriptAudioPlayback(resolve: { _ in clip }, isMuted: true)
        _ = NSApplication.shared
        let controller = TranscriptWindowController(playback: playback, presentWindow: { _ in },
            loadRecordings: { try await TranscriptRecordingLoader.load(queries: queries, at: $0) })
        defer { controller.hide(); controller.window?.close() }
        controller.currentTimestampProvider = { self.base }
        await controller.open(at: base)
        let content = try XCTUnwrap(controller.window?.contentView as? FirstMouseHostingView<TranscriptContentView>)
        XCTAssertEqual(content.rootView.transcriptions.map(\.id), [id])
        XCTAssertEqual(playback.state.phase, .idle, "Opening recordings must not start playback")
        XCTAssertNil(playback.player)
        let pendingCount = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(pendingCount, 1, "Opening the panel must not start transcription or mutate pending work")
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(fixture.path)), originalBytes)

        playback.toggle(request)
        try await waitUntil { playback.state.phase == .playing }
        XCTAssertTrue(playback.player?.isMuted == true)
        XCTAssertEqual(playback.player?.currentItem?.forwardPlaybackEndTime.seconds ?? 0, 3, accuracy: 0.002)
        controller.hide()
        XCTAssertNil(playback.player)
        try await database.close()
    }

    func testRecordingPageIncludesActivityAndRepairRowsButKeepsLatestTranscriptPass() async throws {
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let ambient = try await insert(queries, text: "[silence]", status: "probable_silence", offset: 1)
        let repair = try await insert(queries, text: "", status: "needs_repair", offset: 2)
        let batchPath = "audio/batch_1800000000000_microphone_fixture.m4a"
        _ = try await queries.insertTranscription(sessionID: nil, text: "Old pass", startTime: base,
            endTime: base.addingTimeInterval(1), source: .microphone, confidence: nil, words: [],
            audioPath: batchPath, transcriptionPass: 1, batchAudioPath: batchPath)
        let newest = try await queries.insertTranscription(sessionID: nil, text: "Stuart’s amount: $3,210.50 ✅",
            startTime: base, endTime: base.addingTimeInterval(1), source: .microphone, confidence: nil,
            words: [], audioPath: batchPath, transcriptionPass: 2, batchAudioPath: batchPath)
        let page = try await TranscriptRecordingLoader.load(queries: queries, at: base)
        XCTAssertEqual(Set(page.transcriptions.map(\.id)), Set([ambient, repair, newest]))
        XCTAssertEqual(page.transcriptions.first(where: { $0.id == newest })?.text, "Stuart’s amount: $3,210.50 ✅")
        let presented = TranscriptPresentationPolicy.presentationRows(from: page.transcriptions)
        XCTAssertEqual(presented.first(where: { $0.id == repair })?.textPreparationLabel,
            "Text needs another processing pass")
        XCTAssertNil(presented.first(where: { $0.id == newest })?.textPreparationLabel)
        try await database.close()
    }

    func testTenThousandRowsStayBoundedAndReportOmittedOlderRecordings() async throws {
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let records: [AudioTranscriptionQueries.TranscriptionBatchRecord] = (0..<10_005).map { index in
            let start = base.addingTimeInterval(Double(index) / 10)
            return (sessionID: nil, text: "", startTime: start, endTime: start.addingTimeInterval(0.05),
                source: .microphone, confidence: nil, words: [], audioPath: nil, transcriptionPass: 1,
                batchAudioPath: nil, transcriptStatus: "pending", detectedLanguage: nil,
                audioVariant: "raw", qualityFlags: nil)
        }
        let ids = try await queries.insertTranscriptionsBatch(records)
        let page = try await TranscriptRecordingLoader.load(queries: queries, at: base)
        XCTAssertEqual(page.transcriptions.count, TranscriptRecordingLoader.maximumRows)
        XCTAssertTrue(page.isTruncated)
        XCTAssertEqual(page.transcriptions.map(\.id), Array(ids.suffix(TranscriptRecordingLoader.maximumRows).reversed()))
        try await database.close()
    }

    func testEmptyAndExactlyFullPagesDoNotClaimTruncation() async throws {
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let empty = try await TranscriptRecordingLoader.load(queries: queries, at: base)
        XCTAssertTrue(empty.transcriptions.isEmpty)
        XCTAssertFalse(empty.isTruncated)
        for index in 0..<TranscriptRecordingLoader.maximumRows {
            _ = try await insert(queries, text: "Saved line \(index)", offset: Double(index))
        }
        let full = try await TranscriptRecordingLoader.load(queries: queries, at: base)
        XCTAssertEqual(full.transcriptions.count, TranscriptRecordingLoader.maximumRows)
        XCTAssertFalse(full.isTruncated)
        let outside = try await TranscriptRecordingLoader.load(queries: queries, at: base.addingTimeInterval(3_600))
        XCTAssertTrue(outside.transcriptions.isEmpty)
        try await database.close()
    }

    func testStationaryPanelRefreshesCompletedTextAndDeletionWithoutPresentingOrPlaying() async throws {
        _ = NSApplication.shared
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let id = try await insert(queries, text: "", status: "pending", offset: 1)
        let initial = try await queries.getTranscriptions(from: base, to: base.addingTimeInterval(3), includeActivityRows: true)
        var presentations = 0
        let playback = TranscriptAudioPlayback(resolve: { _ in throw TranscriptAudioError.unavailable }, isMuted: true)
        let controller = TranscriptWindowController(playback: playback, presentWindow: { _ in presentations += 1 },
            loadRecordings: { try await TranscriptRecordingLoader.load(queries: queries, at: $0) })
        defer { controller.hide(); controller.window?.close() }
        controller.currentTimestampProvider = { self.base }
        controller.show(transcriptions: initial, timestamp: base)
        let now = Date()
        XCTAssertNil(controller.refreshIfNeeded(now: now), "Do not query once per timer tick")
        try await queries.updateBatchOutcome(id: id, text: "Prepared text after opening", transcriptStatus: "transcribed",
            detectedLanguage: "en", audioVariant: "raw", qualityFlags: nil)
        let refresh = try XCTUnwrap(controller.refreshIfNeeded(now: now.addingTimeInterval(16)),
            "A stationary visible panel must eventually discover text preparation")
        await refresh.value
        let content = try XCTUnwrap(controller.window?.contentView as? FirstMouseHostingView<TranscriptContentView>)
        XCTAssertEqual(content.rootView.transcriptions.map(\.text), ["Prepared text after opening"])
        XCTAssertEqual(presentations, 1, "A background read must not steal focus")
        XCTAssertNil(playback.player)
        try await queries.deleteTranscription(id: id)
        let deletionRefresh = try XCTUnwrap(controller.refreshIfNeeded(now: now.addingTimeInterval(32)))
        await deletionRefresh.value
        XCTAssertTrue(content.rootView.transcriptions.isEmpty, "Deleted rows must disappear without scrubbing")
        XCTAssertEqual(presentations, 1)
        controller.hide()
        XCTAssertNil(controller.refreshIfNeeded(now: now.addingTimeInterval(48)))
        try await database.close()
    }

    func testRefreshCoalescesAndDiscardsRowsWhenTimelineMovesDuringRead() async throws {
        _ = NSApplication.shared
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        _ = try await insert(queries, text: "Late result", offset: 1)
        let gate = TranscriptRecordingReadGate()
        var selected = base.addingTimeInterval(5)
        var presentations = 0
        let playback = TranscriptAudioPlayback(resolve: { _ in throw TranscriptAudioError.unavailable }, isMuted: true)
        let controller = TranscriptWindowController(playback: playback, presentWindow: { _ in presentations += 1 },
            loadRecordings: { timestamp in
                await gate.wait()
                return try await TranscriptRecordingLoader.load(queries: queries, at: timestamp)
            })
        defer { controller.hide(); controller.window?.close() }
        controller.currentTimestampProvider = { selected }
        controller.show(transcriptions: [], timestamp: base)
        let refresh = try XCTUnwrap(controller.refreshIfNeeded())
        await gate.waitUntilEntered()
        XCTAssertNil(controller.refreshIfNeeded(), "Only one bounded read may be in flight")
        selected = base.addingTimeInterval(10)
        await gate.open()
        await refresh.value
        let content = try XCTUnwrap(controller.window?.contentView as? FirstMouseHostingView<TranscriptContentView>)
        XCTAssertTrue(content.rootView.transcriptions.isEmpty, "An old range must not overwrite the new timeline selection")
        XCTAssertEqual(presentations, 1)
        try await database.close()
    }

    func testReplacingTimestampProviderOrClosingRejectsHeldRefresh() async throws {
        _ = NSApplication.shared
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        _ = try await insert(queries, text: "Old provider result", offset: 1)
        let page = try await TranscriptRecordingLoader.load(queries: queries, at: base)
        for closesPanel in [false, true] {
            let gate = TranscriptRecordingReadGate()
            let playback = TranscriptAudioPlayback(resolve: { _ in throw TranscriptAudioError.unavailable }, isMuted: true)
            let controller = TranscriptWindowController(playback: playback, presentWindow: { _ in },
                loadRecordings: { _ in
                    await gate.wait()
                    return page // Deliberately ignores cancellation to exercise the publication fence.
                })
            defer { controller.hide(); controller.window?.close() }
            let selected = base.addingTimeInterval(5)
            controller.currentTimestampProvider = { selected }
            controller.show(transcriptions: [], timestamp: base)
            let refresh = try XCTUnwrap(controller.refreshIfNeeded())
            await gate.waitUntilEntered()
            if closesPanel { controller.hide() }
            else { controller.currentTimestampProvider = { selected } }
            await gate.open()
            await refresh.value
            let content = try XCTUnwrap(controller.window?.contentView as? FirstMouseHostingView<TranscriptContentView>)
            XCTAssertTrue(content.rootView.transcriptions.isEmpty)
            XCTAssertEqual(controller.isVisible, !closesPanel)
            XCTAssertNil(playback.player)
        }
        try await database.close()
    }

    func testClosingPanelOrReplacingProviderCannotBeUndoneByHeldInitialOpen() async throws {
        _ = NSApplication.shared
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        _ = try await insert(queries, text: "Late initial result", offset: 1)
        let page = try await TranscriptRecordingLoader.load(queries: queries, at: base)
        for route in ["hide", "windowClose", "provider"] {
            let gate = TranscriptRecordingReadGate()
            var presentations = 0
            let playback = TranscriptAudioPlayback(resolve: { _ in throw TranscriptAudioError.unavailable }, isMuted: true)
            let controller = TranscriptWindowController(playback: playback, presentWindow: { _ in presentations += 1 },
                loadRecordings: { _ in await gate.wait(); return page })
            defer { controller.hide(); controller.window?.close() }
            controller.currentTimestampProvider = { self.base }
            controller.show(transcriptions: [], timestamp: base)
            let opening = Task { await controller.open(at: base) }
            await gate.waitUntilEntered()
            switch route {
            case "hide": controller.hide()
            case "windowClose": controller.window?.close()
            default: controller.currentTimestampProvider = { self.base }
            }
            await gate.open()
            await opening.value
            XCTAssertEqual(presentations, 1, "A late \(route) completion must not reopen or focus the panel")
            XCTAssertEqual(controller.isVisible, route == "provider")
            let content = try XCTUnwrap(controller.window?.contentView as? FirstMouseHostingView<TranscriptContentView>)
            XCTAssertTrue(content.rootView.transcriptions.isEmpty)
            XCTAssertNil(playback.player)
        }
        try await database.close()
    }

    func testInitialOpenCoalescesAndOnlyItsOriginalCallerCanCancelTheRead() async throws {
        _ = NSApplication.shared
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let id = try await insert(queries, text: "One owned read", offset: 1)
        let page = try await TranscriptRecordingLoader.load(queries: queries, at: base)
        for cancelOriginal in [false, true] {
            let gate = TranscriptRecordingReadGate()
            var presentations = 0
            let playback = TranscriptAudioPlayback(resolve: { _ in throw TranscriptAudioError.unavailable }, isMuted: true)
            let controller = TranscriptWindowController(playback: playback, presentWindow: { _ in presentations += 1 },
                loadRecordings: { _ in await gate.wait(); return page })
            defer { controller.hide(); controller.window?.close() }
            controller.currentTimestampProvider = { self.base }
            let opening = Task { await controller.open(at: base) }
            await gate.waitUntilEntered()
            var duplicateStarted = false
            let duplicate = Task { duplicateStarted = true; await controller.open(at: base) }
            try await waitUntil { duplicateStarted }
            if cancelOriginal { opening.cancel() } else { duplicate.cancel() }
            await gate.open()
            await opening.value
            await duplicate.value
            let attempts = await gate.attempts
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(presentations, cancelOriginal ? 0 : 1)
            XCTAssertEqual(controller.isVisible, !cancelOriginal)
            if !cancelOriginal {
                let content = try XCTUnwrap(controller.window?.contentView as? FirstMouseHostingView<TranscriptContentView>)
                XCTAssertEqual(content.rootView.transcriptions.map(\.id), [id])
            }
        }
        try await database.close()
    }

    func testReadFailureDoesNotOpenPanelOrRetryEveryTimerTick() async throws {
        _ = NSApplication.shared
        let playback = TranscriptAudioPlayback(resolve: { _ in throw TranscriptAudioError.unavailable }, isMuted: true)
        let controller = TranscriptWindowController(playback: playback, presentWindow: { _ in },
            loadRecordings: { _ in throw TranscriptRecordingLoadError.unavailable })
        defer { controller.hide(); controller.window?.close() }
        controller.currentTimestampProvider = { self.base }
        await controller.open(at: base)
        XCTAssertFalse(controller.isVisible)
        XCTAssertNil(controller.window)
        controller.show(transcriptions: [], timestamp: base)
        let now = Date().addingTimeInterval(16)
        let failedRefresh = try XCTUnwrap(controller.refreshIfNeeded(now: now))
        await failedRefresh.value
        XCTAssertNil(controller.refreshIfNeeded(now: now.addingTimeInterval(1)))
        XCTAssertNil(playback.player)
    }

    private func insert(_ queries: AudioTranscriptionQueries, text: String, status: String = "transcribed",
                        offset: TimeInterval) async throws -> Int64 {
        try await queries.insertTranscription(sessionID: nil, text: text,
            startTime: base.addingTimeInterval(offset), endTime: base.addingTimeInterval(offset + 0.05),
            source: .microphone, confidence: nil, words: [], transcriptStatus: status)
    }

    private func makeRecording() async throws -> (root: URL, path: String, size: Int64) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-pending-audio-\(UUID())")
        if let fixturePath = ProcessInfo.processInfo.environment["RETRACE_AUDIO_VISIBILITY_FIXTURE_AAC"] {
            // Explicit, byte-pinned authored fixture for hosts without AAC encoding services.
            // This path does not count as native writer acceptance.
            let bytes = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard hash == "12d984dc71bad6e5bacab2f8fceb4423911a46e7ae5a23c9c1c41c349f8830dd" else {
                throw NSError(domain: "AuthoredAACFixtureHashMismatch", code: 1)
            }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("audio"), withIntermediateDirectories: true)
            let path = "audio/batch_1800000000000_microphone_authored.m4a"
            try bytes.write(to: root.appendingPathComponent(path))
            return (root, path, Int64(bytes.count))
        }
        // Authored tone only. The production writer creates a genuine three-second AAC recording.
        let samples = (0..<48_000).map { Int16(sin(Double($0) * 2 * .pi * 440 / 16_000) * 4_000) }
        let file = try await AudioSegmentWriter(storageRoot: root).writeFullBatch(
            audioData: samples.withUnsafeBytes { Data($0) }, timestamp: base, source: .microphone)
        let bytes = try Data(contentsOf: root.appendingPathComponent(file.filePath)).count
        return (root, file.filePath, Int64(bytes))
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
        if !predicate() { throw NSError(domain: "TranscriptRecordingVisibilityTests", code: 1) }
    }
}

private actor TranscriptRecordingReadGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var entered: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private(set) var attempts = 0

    func wait() async {
        attempts += 1
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            entered?.resume()
            entered = nil
        }
    }

    func waitUntilEntered() async {
        guard continuations.isEmpty else { return }
        await withCheckedContinuation { entered = $0 }
    }

    func open() {
        isOpen = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}
