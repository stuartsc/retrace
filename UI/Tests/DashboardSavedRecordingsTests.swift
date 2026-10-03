import AppKit
import AVFoundation
import CryptoKit
import Database
import Shared
import Storage
import SwiftUI
import XCTest
@testable import Retrace

@MainActor
final class DashboardSavedRecordingsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testLiveFeedShowsPendingSQLiteRecordingWithItsExactMediaRequest() async throws {
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let id = try await pending(queries, offset: 0)
        let page = try await DashboardSavedRecordingsQuery.load(queries: queries, through: base.addingTimeInterval(10))
        XCTAssertEqual(page.rows.map(\.id), [id])
        let row = try XCTUnwrap(page.rows.first)
        XCTAssertEqual(row.textStatusLabel, "Text not ready")
        XCTAssertEqual(row.request.start, base)
        XCTAssertEqual(row.request.end, base.addingTimeInterval(3))
        XCTAssertEqual(row.request.audioPath, "audio/batch_1800000000000_microphone_fixture.m4a")
        XCTAssertFalse(page.hasMore)
        let count = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(count, 1)
        try await database.close()
    }

    func testNativeLiveViewRendersPendingDateAndDeliberatePlaybackControl() async throws {
        guard ProcessInfo.processInfo.environment["RETRACE_TEST_NATIVE_AUDIO_VIEW"] == "1" else {
            throw XCTSkip("Set RETRACE_TEST_NATIVE_AUDIO_VIEW=1 in a session with native SwiftUI accessibility support")
        }
        let fixture = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let id = try await queries.insertRawBatch(startTime: base, endTime: base.addingTimeInterval(3),
            source: .microphone, audioPath: fixture.path, audioSize: fixture.size)
        let through = base.addingTimeInterval(10)
        let playback = TranscriptAudioPlayback(resolve: {
            try await TranscriptAudioFileResolver.resolve(request: $0, storageRoot: fixture.root)
        }, isMuted: true)
        let model = DashboardSavedRecordingsModel(playback: playback,
            load: { try await DashboardSavedRecordingsQuery.load(queries: queries, through: through) })
        model.setActive(true)
        await model.refresh()

        _ = NSApplication.shared
        let panel = DashboardSavedRecordingsTestPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 620, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let hosting = NSHostingView(rootView: DashboardSavedRecordingsView(
            model: model, isActive: true, sourceRevision: 0))
        panel.contentView = hosting
        panel.orderFront(nil)
        defer {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
            model.setActive(false)
        }

        let dateLabel = base.formatted(date: .abbreviated, time: .shortened)
        let playLabel = "Play recording from \(dateLabel)"
        var observedElements: [String] = []
        do {
            try await waitUntil {
                hosting.layoutSubtreeIfNeeded()
                hosting.displayIfNeeded()
                let elements = Self.accessibleElements(in: hosting)
                observedElements = elements.map {
                    "\(type(of: $0)) role=\($0.accessibilityAttributeValue(.role) as? String ?? "nil") text=\(Self.accessibleText($0))"
                }
                let text = elements.map(Self.accessibleText)
                return text.contains { $0.contains(dateLabel) } && text.contains { $0.contains("Microphone · Text not ready") } &&
                    elements.contains { Self.accessibleText($0).contains(playLabel) && $0.accessibilityActionNames().contains(.press) }
            }
        } catch {
            XCTFail("Offscreen native AX did not expose the expected authored row: \(observedElements)")
            throw error
        }
        XCTAssertLessThan(panel.frame.maxX, 0, "The native fixture must stay off the user's desktop")
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.isMainWindow)
        XCTAssertNil(playback.player, "Rendering the saved recording must not start playback")
        XCTAssertEqual(model.rows.map(\.id), [id])
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let renderedPNG = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(renderedPNG.count, 2_000, "The actual native view must render more than a blank surface")

        let playButton = try XCTUnwrap(Self.accessibleElements(in: hosting).first {
            Self.accessibleText($0).contains(playLabel) && $0.accessibilityActionNames().contains(.press)
        })
        playButton.accessibilityPerformAction(.press)
        try await waitUntil { playback.state.phase == .playing }
        let player = try XCTUnwrap(playback.player)
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.currentItem?.forwardPlaybackEndTime.seconds ?? -1, 3, accuracy: 0.02)
        XCTAssertEqual(playback.state.request?.id, id)
        XCTAssertEqual(playback.state.request?.start, base)
        XCTAssertEqual(playback.state.request?.end, base.addingTimeInterval(3))
        XCTAssertEqual(playback.state.request?.audioPath, fixture.path)
        let pendingCount = try await queries.getUntranscribedBatchCount()
        XCTAssertEqual(pendingCount, 1, "Playback must leave pending transcription unchanged")
        panel.orderOut(nil)
        panel.contentView = nil
        model.setActive(false)
        try await database.close()
    }

    func testRecentFeedIsBoundedAndExcludesRowsWithoutRetainedAudio() async throws {
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        var ids: [Int64] = []
        for index in 0..<20 { ids.append(try await pending(queries, offset: Double(index * 10))) }
        let page = try await DashboardSavedRecordingsQuery.load(queries: queries, through: base.addingTimeInterval(300))
        XCTAssertEqual(page.rows.map(\.id), Array(ids.suffix(12).reversed()))
        XCTAssertTrue(page.hasMore)
        _ = try await queries.deleteTranscriptions(olderThan: base.addingTimeInterval(300))
        _ = try await queries.insertTranscription(sessionID: nil, text: "Older text without media", startTime: base,
            endTime: base.addingTimeInterval(3), source: .microphone, confidence: nil, words: [])
        let empty = try await DashboardSavedRecordingsQuery.load(queries: queries, through: base.addingTimeInterval(300))
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertFalse(empty.hasMore)
        try await database.close()
    }

    func testMixedRowsReportRawPageTruncationWithoutClaimingTwelveRecordings() async throws {
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        var ids: [Int64] = []
        for index in 0..<20 { ids.append(try await pending(queries, offset: Double(index * 10))) }
        for index in 0..<5 {
            _ = try await queries.insertTranscription(sessionID: nil, text: "Text without retained media",
                startTime: base.addingTimeInterval(Double(200 + index)), endTime: base.addingTimeInterval(Double(201 + index)),
                source: .microphone, confidence: nil, words: [])
        }
        let page = try await DashboardSavedRecordingsQuery.load(queries: queries, through: base.addingTimeInterval(300))
        XCTAssertTrue(page.hasMore, "A raw overflow sentinel must disclose omitted history even when some rows lack audio")
        XCTAssertEqual(page.rows.map(\.id), Array(ids.suffix(7).reversed()))
        try await database.close()
    }

    func testDeactivateReactivateJoinsHeldReadBeforeStartingNewGeneration() async throws {
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let firstID = try await pending(queries, offset: 0)
        let gate = DashboardSavedAudioGate()
        let through = base.addingTimeInterval(30)
        let playback = TranscriptAudioPlayback(resolve: { _ in throw TranscriptAudioError.unavailable }, isMuted: true)
        let model = DashboardSavedRecordingsModel(playback: playback, load: {
            let rows = try await queries.getTranscriptions(from: Date(timeIntervalSince1970: 0), to: through, includeActivityRows: true)
            let page = DashboardSavedRecordingsPage(rows: rows.map(DashboardSavedRecording.init), hasMore: false)
            await gate.wait() // Deliberately ignores task cancellation to model a native/SQLite read already in progress.
            return page
        })
        model.setActive(true)
        let first = Task { await model.refresh() }
        await gate.waitUntilEntered()
        model.setActive(false)
        let newestID = try await pending(queries, offset: 10)
        model.setActive(true)
        var reopenedStarted = false
        let reopened = Task { reopenedStarted = true; await model.refresh() }
        try await waitUntil { reopenedStarted }
        try await Task.sleep(for: .milliseconds(30))
        let heldAttempts = await gate.attempts
        XCTAssertEqual(heldAttempts, 1, "A cancelled read must remain owned until it exits")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.isLoading, "Reopening must report loading while the previous read is draining")
        await gate.open()
        await first.value
        await reopened.value
        let completedAttempts = await gate.attempts
        XCTAssertEqual(completedAttempts, 2)
        XCTAssertEqual(model.rows.map(\.id), [newestID, firstID], "The reopened generation must eventually make its own fresh read")
        model.setActive(false)
        try await database.close()
    }

    func testHeldLiveReadCannotPublishAfterTabOrWindowCloses() async throws {
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        _ = try await pending(queries, offset: 0)
        let rows = try await queries.getTranscriptions(from: base, to: base.addingTimeInterval(10), includeActivityRows: true)
        let page = DashboardSavedRecordingsPage(rows: rows.map(DashboardSavedRecording.init), hasMore: false)
        let gate = DashboardSavedAudioGate()
        let playback = TranscriptAudioPlayback(resolve: { _ in throw TranscriptAudioError.unavailable }, isMuted: true)
        let model = DashboardSavedRecordingsModel(playback: playback, load: { await gate.wait(); return page })
        model.setActive(true)
        let refresh = Task { await model.refresh() }
        await gate.waitUntilEntered()
        model.setActive(false)
        await gate.open()
        await refresh.value
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(playback.player)
        try await database.close()
    }

    func testRefreshCoalescesAndCancellationOfDuplicateDoesNotCancelTheOwner() async throws {
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let id = try await pending(queries, offset: 0)
        let rows = try await queries.getTranscriptions(from: base, to: base.addingTimeInterval(10), includeActivityRows: true)
        let page = DashboardSavedRecordingsPage(rows: rows.map(DashboardSavedRecording.init), hasMore: false)
        let gate = DashboardSavedAudioGate()
        let playback = TranscriptAudioPlayback(resolve: { _ in throw TranscriptAudioError.unavailable }, isMuted: true)
        let model = DashboardSavedRecordingsModel(playback: playback, load: { await gate.wait(); return page })
        model.setActive(true)
        let first = Task { await model.refresh() }
        await gate.waitUntilEntered()
        var duplicateStarted = false
        let duplicate = Task { duplicateStarted = true; await model.refresh() }
        try await waitUntil { duplicateStarted }
        duplicate.cancel()
        await gate.open()
        await first.value
        await duplicate.value
        let attempts = await gate.attempts
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(model.rows.map(\.id), [id])
        model.setActive(false)
        XCTAssertTrue(model.rows.isEmpty)
        try await database.close()
    }

    func testRefreshReplacesPendingWithPreparedRowsAndDeletionStopsNativePlayback() async throws {
        let fixture = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let id = try await queries.insertRawBatch(startTime: base, endTime: base.addingTimeInterval(3),
            source: .microphone, audioPath: fixture.path, audioSize: fixture.size)
        let through = base.addingTimeInterval(10)
        let playback = TranscriptAudioPlayback(resolve: {
            try await TranscriptAudioFileResolver.resolve(request: $0, storageRoot: fixture.root)
        }, isMuted: true)
        let model = DashboardSavedRecordingsModel(playback: playback,
            load: { try await DashboardSavedRecordingsQuery.load(queries: queries, through: through) })
        model.setActive(true)
        await model.refresh()
        XCTAssertNil(playback.player, "Loading recent audio must not play it")
        let request = try XCTUnwrap(model.rows.first?.request)
        XCTAssertEqual(request.id, id)
        playback.toggle(request)
        try await waitUntil { playback.state.phase == .playing }
        let player = try XCTUnwrap(playback.player)
        await model.refresh()
        XCTAssertTrue(playback.player === player, "The same retained range keeps its player during refresh")
        let pendingRows = try await queries.getUntranscribedBatches(limit: 1)
        let batch = try XCTUnwrap(pendingRows.first)
        let replacement: AudioTranscriptionQueries.TranscriptionBatchRecord = (
            sessionID: nil, text: "Stuart’s saved amount $3,210.50 ✅", startTime: base,
            endTime: base.addingTimeInterval(2), source: .microphone, confidence: nil, words: [],
            audioPath: fixture.path, transcriptionPass: 1, batchAudioPath: fixture.path,
            transcriptStatus: "transcribed", detectedLanguage: "en", audioVariant: "raw", qualityFlags: nil)
        let replaced = try await queries.completePendingRawBatch(batch, with: [replacement])
        XCTAssertTrue(replaced)
        await model.refresh()
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertNotEqual(model.rows.first?.id, id)
        XCTAssertEqual(model.rows.first?.textStatusLabel, "Text available")
        XCTAssertNil(playback.player, "Replaced row/range must stop the old player")
        let prepared = try XCTUnwrap(model.rows.first)
        playback.toggle(prepared.request)
        try await waitUntil { playback.state.phase == .playing }
        try await queries.deleteTranscription(id: prepared.id)
        await model.refresh()
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(playback.player, "Deleted recordings must not continue playing")
        model.setActive(false)
        try await database.close()
    }

    private func pending(_ queries: AudioTranscriptionQueries, offset: TimeInterval) async throws -> Int64 {
        let start = base.addingTimeInterval(offset)
        return try await queries.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(3),
            source: .microphone, audioPath: "audio/batch_\(Int(start.timeIntervalSince1970 * 1_000))_microphone_fixture.m4a", audioSize: 60_598)
    }

    private func makeRecording() async throws -> (root: URL, path: String, size: Int64) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-live-audio-\(UUID())")
        if let fixturePath = ProcessInfo.processInfo.environment["RETRACE_AUDIO_VISIBILITY_FIXTURE_AAC"] {
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
        let samples = (0..<48_000).map { Int16(sin(Double($0) * 2 * .pi * 440 / 16_000) * 4_000) }
        let result = try await AudioSegmentWriter(storageRoot: root).writeFullBatch(
            audioData: samples.withUnsafeBytes { Data($0) }, timestamp: base, source: .microphone)
        return (root, result.filePath, result.fileSize)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
        if !predicate() { throw NSError(domain: "DashboardSavedRecordingsTests", code: 1) }
    }

    // In-process AppKit compatibility bridge also reaches SwiftUI AX objects
    // that do not declare NSAccessibilityProtocol conformance.
    private static func accessibleElements(in root: NSObject) -> [NSObject] {
        var result: [NSObject] = []
        var remaining = [(root, 0)]
        var visited = Set<ObjectIdentifier>()
        while let (element, depth) = remaining.popLast(), visited.count < 2_000 {
            guard depth < 40, visited.insert(ObjectIdentifier(element)).inserted else { continue }
            result.append(element)
            let children = element.accessibilityAttributeValue(.children) as? [NSObject] ?? []
            remaining.append(contentsOf: children.map { ($0, depth + 1) })
            if let view = element as? NSView {
                remaining.append(contentsOf: view.subviews.map { ($0, depth + 1) })
            }
        }
        return result
    }

    private static func accessibleText(_ element: NSObject) -> String {
        [NSAccessibility.Attribute.title, .description, .value]
            .compactMap { element.accessibilityAttributeValue($0) as? String }.joined(separator: " ")
    }
}

private final class DashboardSavedRecordingsTestPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private actor DashboardSavedAudioGate {
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
