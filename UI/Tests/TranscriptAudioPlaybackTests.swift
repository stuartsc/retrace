import AVFoundation
import AppKit
import XCTest
import Database
import Shared
import Storage
import App
@testable import Retrace

@MainActor
final class TranscriptAudioPlaybackTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testChunkWindowUsesVerifiedPCMAndReleasesAfterNativeStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-playback-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = DatabaseManager(databasePath: root.appendingPathComponent("fixture.sqlite").path)
        try await database.initialize()
        let pointer = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(pointer))
        let store = AudioChunkMediaStore(storageRoot: root, storeID: try await queries.audioMediaStoreID())
        let window = try await store.persistChunk(.init(streamID: UUID(), source: .microphone,
            origin: base, startFrame: 0, pcmData: pcm()), previous: nil)
        let raw = try await queries.registerRawAudioWindow(window)
        let source = try await queries.pendingFirstPassSource(rawBatchID: raw, path: window.relativePath)
        _ = try await queries.commitFirstPass(rawBatchID: raw, records: [
            (nil, "Cedar playback", base.addingTimeInterval(0.5), base.addingTimeInterval(2.5),
             .microphone, 0.9, [], window.relativePath, 1, window.relativePath, "transcribed", "en", "raw", nil)
        ], originalSource: source)
        let reader = try await database.makeAudioEvidenceStore()
        let owner = AudioMediaPlaybackOwner(evidence: reader, media: store, configuration: { CaptureConfig() })
        let rows = try await queries.getTranscriptions(from: base, to: base.addingTimeInterval(4))
        let request = TranscriptAudioRequest(transcription: try XCTUnwrap(rows.first))
        let ref = try XCTUnwrap(request.evidenceReference)
        let playback = TranscriptAudioPlayback(resolve: { _ in
            TranscriptAudioClip(lease: try await owner.acquire(ref))
        }, isMuted: true)
        playback.toggle(request)
        try await waitUntil { playback.state.phase == .playing }
        let native = try XCTUnwrap(playback.pcmPlayer)
        XCTAssertEqual(native.volume, 0)
        XCTAssertEqual(native.duration, 2, accuracy: 1.0 / 16_000)
        playback.toggle(request)
        XCTAssertEqual(playback.state.phase, .paused)
        await playback.playFromStart(request)
        XCTAssertTrue(native.isPlaying)
        XCTAssertEqual(playback.state.phase, .playing)
        await owner.invalidate()
        try await waitUntil { playback.state.phase == .failed }
        XCTAssertFalse(native.isPlaying)
        await playback.stopAndDrain()
        // A cancelled late media load must release the native file lease even
        // before a player exists; close below joins that release.
        let gate = TranscriptPlaybackGate()
        let late = TranscriptAudioPlayback(resolve: { _ in
            let clip = TranscriptAudioClip(lease: try await owner.acquire(ref))
            await gate.wait()
            return clip
        }, isMuted: true)
        late.toggle(request)
        try await waitUntil { gate.isWaiting }
        await late.stopAndDrain()
        XCTAssertNil(late.pcmPlayer)
        XCTAssertEqual(late.state.phase, .idle)
        playback.toggle(request)
        try await waitUntil { playback.state.phase == .playing }
        let deletedPlayer = try XCTUnwrap(playback.pcmPlayer)
        _ = try await queries.deleteTranscription(id: try XCTUnwrap(rows.first?.id))
        await owner.revalidateActive()
        try await waitUntil { playback.state.phase == .failed }
        XCTAssertFalse(deletedPlayer.isPlaying)
        await playback.stopAndDrain()
        await owner.close(); await reader.close(); await store.close()
        try await database.close()
        try FileManager.default.removeItem(at: root)
    }

    func testSQLiteSentenceSeeksInsideCanonicalAACAndStopsAtItsEnd() async throws {
        let fixture = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        _ = try await queries.insertTranscription(sessionID: nil, text: "Authored playback fixture",
            startTime: base.addingTimeInterval(0.75), endTime: base.addingTimeInterval(1.25),
            source: .microphone, confidence: nil, words: [], audioPath: fixture.path,
            batchAudioPath: fixture.path)
        let rows = try await queries.getTranscriptions(from: base, to: base.addingTimeInterval(3))
        let request = TranscriptAudioRequest(transcription: try XCTUnwrap(rows.first))
        let clip = try await TranscriptAudioFileResolver.resolve(request: request, storageRoot: fixture.root)
        XCTAssertEqual(clip.startTime, 0.75, accuracy: 0.002)
        XCTAssertEqual(clip.endTime, 1.25, accuracy: 0.002)
        var events: [TranscriptAudioPlayback.Event] = []
        var playingItem: AVPlayerItem?
        var completedAt: TimeInterval?
        let playback = TranscriptAudioPlayback(resolve: { _ in clip }, isMuted: true,
            onEvent: { event in
                events.append(event)
                if event.outcome == .completed { completedAt = playingItem?.currentTime().seconds }
            })
        defer { playback.stop(reason: .closed) }
        playback.toggle(request)
        try await waitUntil { playback.state.phase == .playing }
        let player = try XCTUnwrap(playback.player)
        playingItem = player.currentItem
        XCTAssertTrue(player.isMuted, "The tests must never play sound on the shared desktop")
        XCTAssertEqual(player.currentItem?.forwardPlaybackEndTime.seconds ?? 0, 1.25, accuracy: 0.002)
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, 0.74)
        try await waitUntil { playback.state.phase == .idle }
        XCTAssertEqual(try XCTUnwrap(completedAt), 1.25, accuracy: 0.04)
        XCTAssertNil(playback.player)
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(events.map(\.outcome), [.requested, .started, .completed])
        for event in events {
            try await database.recordMetricEvent(metricType: .audioTranscriptPlayback,
                metadata: event.metadata)
        }
        let counts = try await database.getDailyMetrics(metricType: .audioTranscriptPlayback,
            from: Date().addingTimeInterval(-60), to: Date().addingTimeInterval(60))
        XCTAssertEqual(counts.reduce(0) { $0 + $1.value }, 3)
        XCTAssertFalse(events.contains { $0.metadata.contains(fixture.path) || $0.metadata.contains("Authored") })
        try await database.close()
    }

    func testPauseResumeAndReplayUseOneNativePlayer() async throws {
        let fixture = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = request(path: fixture.path, start: 0.5, end: 2.5)
        let playback = TranscriptAudioPlayback(resolve: {
            try await TranscriptAudioFileResolver.resolve(request: $0, storageRoot: fixture.root)
        }, isMuted: true)
        defer { playback.stop(reason: .closed) }
        playback.toggle(request)
        try await waitUntil { playback.state.phase == .playing }
        let first = try XCTUnwrap(playback.player)
        playback.toggle(request)
        XCTAssertEqual(playback.state.phase, .paused)
        XCTAssertEqual(first.rate, 0)
        let pausedTime = first.currentTime().seconds
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(first.currentTime().seconds, pausedTime, accuracy: 0.02)
        playback.toggle(request)
        XCTAssertTrue(playback.player === first)
        try await waitUntil { playback.state.phase == .idle }
        playback.toggle(request)
        try await waitUntil { playback.state.phase == .playing }
        XCTAssertFalse(playback.player === first)
        XCTAssertLessThan(playback.player?.currentTime().seconds ?? 3, 0.8)
    }

    func testLegacySentenceClipAndMissingSentenceFallbackToBatch() async throws {
        let fixture = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sentence = try await AudioSegmentWriter(storageRoot: fixture.root).writeAudioSegment(
            audioData: pcm(), startTime: 1, endTime: 2, timestamp: base.addingTimeInterval(1), source: .microphone)
        let request = request(path: sentence.filePath, batch: fixture.path, start: 1, end: 2)
        let legacy = try await TranscriptAudioFileResolver.resolve(request: request, storageRoot: fixture.root)
        XCTAssertEqual(legacy.startTime, 0, accuracy: 0.002)
        XCTAssertEqual(legacy.endTime, 1, accuracy: 0.002)
        try FileManager.default.removeItem(at: XCTUnwrap(legacy.url))
        let fallback = try await TranscriptAudioFileResolver.resolve(request: request, storageRoot: fixture.root)
        XCTAssertEqual(fallback.startTime, 1, accuracy: 0.002)
        XCTAssertEqual(fallback.endTime, 2, accuracy: 0.002)
        XCTAssertEqual(try XCTUnwrap(fallback.url).lastPathComponent, URL(fileURLWithPath: fixture.path).lastPathComponent)
    }

    func testMissingCorruptAndOutOfRangeRecordingsFailWithoutPlaying() async throws {
        let fixture = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let corrupt = "audio/batch_1800000000000_microphone_corrupt.m4a"
        try Data("not audio".utf8).write(to: fixture.root.appendingPathComponent(corrupt))
        for request in [request(path: "audio/batch_1800000000000_missing.m4a"),
                        request(path: corrupt), request(path: fixture.path, start: 5, end: 6),
                        request(path: fixture.path, start: -1, end: 1),
                        request(path: fixture.path, start: 1, end: 1)] {
            var events: [TranscriptAudioPlayback.Event] = []
            let playback = TranscriptAudioPlayback(resolve: {
                try await TranscriptAudioFileResolver.resolve(request: $0, storageRoot: fixture.root)
            }, isMuted: true, onEvent: { events.append($0) })
            playback.toggle(request)
            try await waitUntil { playback.state.phase == .failed }
            XCTAssertNil(playback.player)
            XCTAssertFalse(playback.state.message?.isEmpty ?? true)
            XCTAssertEqual(events.map(\.outcome), [.requested, .failed])
        }
    }

    func testResolverRejectsTraversalSymlinkEscapeAndUnknownTiming() async throws {
        let fixture = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("outside.m4a")
        try FileManager.default.copyItem(at: fixture.root.appendingPathComponent(fixture.path), to: outside)
        let link = "audio/batch_1800000000000_microphone_link.m4a"
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent(link),
            withDestinationURL: outside)
        let unknown = "audio/unknown.m4a"
        try FileManager.default.copyItem(at: outside, to: fixture.root.appendingPathComponent(unknown))
        for path in ["audio/../outside.m4a", outside.path, link, unknown] {
            do {
                _ = try await TranscriptAudioFileResolver.resolve(request: request(path: path), storageRoot: fixture.root)
                XCTFail("Untrusted path or unknown recording origin must not play: \(path)")
            } catch { }
        }
    }

    func testFinderResolutionDoesNotRequireDecodableAudioOrKnownTiming() async throws {
        let fixture = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for path in ["audio/legacy-name.m4a", "audio/batch_1800000000000_microphone_broken.m4a"] {
            let url = fixture.root.appendingPathComponent(path)
            try Data("damaged recording".utf8).write(to: url)
            let located = try await TranscriptAudioFileResolver.resolveURL(request: request(path: path, start: 20, end: 30),
                storageRoot: fixture.root)
            XCTAssertEqual(located, url.resolvingSymlinksInPath())
        }
    }

    func testClosingDuringPreparationCannotStartLatePlayback() async throws {
        let fixture = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = request(path: fixture.path)
        let clip = try await TranscriptAudioFileResolver.resolve(request: request, storageRoot: fixture.root)
        let gate = TranscriptPlaybackGate()
        var events: [TranscriptAudioPlayback.Event] = []
        let playback = TranscriptAudioPlayback(resolve: { _ in
            await gate.wait()
            return clip
        }, isMuted: true, onEvent: { events.append($0) })
        defer { gate.open(); playback.stop(reason: .closed) }
        playback.toggle(request)
        let pending = playback.preparationTask
        try await waitUntil { gate.isWaiting }
        playback.stop(reason: .closed)
        gate.open()
        await pending?.value
        XCTAssertEqual(playback.state.phase, .idle)
        XCTAssertNil(playback.player)
        XCTAssertEqual(events.map(\.outcome), [.requested, .closed])
    }

    func testSwitchingSelectionFencesLatePreparationAndOldCompletion() async throws {
        let fixture = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let old = request(path: fixture.path, id: 1, start: 0, end: 1)
        let current = request(path: fixture.path, id: 2, start: 1, end: 2.8)
        let gate = TranscriptPlaybackGate()
        let playback = TranscriptAudioPlayback(resolve: { request in
            let clip = try await TranscriptAudioFileResolver.resolve(request: request, storageRoot: fixture.root)
            if request.id == 1 { await gate.wait() }
            return clip
        }, isMuted: true)
        defer { gate.open(); playback.stop(reason: .closed) }
        playback.toggle(old)
        let pending = playback.preparationTask
        try await waitUntil { gate.isWaiting }
        playback.toggle(current)
        try await waitUntil { playback.state.phase == .playing }
        let player = playback.player
        gate.open()
        await pending?.value
        XCTAssertEqual(playback.state.request, current)
        XCTAssertTrue(playback.player === player)
        let oldItem = try XCTUnwrap(player?.currentItem)
        playback.toggle(request(path: fixture.path, id: 3, start: 0, end: 2.8))
        try await waitUntil { playback.state.phase == .playing }
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(playback.state.request?.id, 3)
        XCTAssertEqual(player?.rate, 0)
    }

    func testRefreshRetainsSameRecordingButStopsReplacedSelection() async throws {
        let fixture = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = request(path: fixture.path, end: 2.8)
        let playback = TranscriptAudioPlayback(resolve: {
            try await TranscriptAudioFileResolver.resolve(request: $0, storageRoot: fixture.root)
        }, isMuted: true)
        playback.toggle(request)
        try await waitUntil { playback.state.phase == .playing }
        let player = try XCTUnwrap(playback.player)
        playback.retainSelection(in: [request])
        XCTAssertTrue(playback.player === player)
        playback.retainSelection(in: [self.request(path: fixture.path, start: 1, end: 2)])
        XCTAssertEqual(playback.state.phase, .idle)
        XCTAssertEqual(player.rate, 0)
        XCTAssertNil(player.currentItem)
    }

    func testPlayableAmbientRowsKeepTheirOwnRecordingButtons() {
        let rows = (0..<2).map { index in
            AudioTranscription(id: Int64(index), sessionID: nil, text: "*typing*",
                startTime: base.addingTimeInterval(Double(index) * 10),
                endTime: base.addingTimeInterval(Double(index) * 10 + 8), source: .microphone,
                confidence: nil, createdAt: base, audioPath: "audio/batch_1800000000000_microphone_test.m4a")
        }
        XCTAssertEqual(TranscriptPresentationPolicy.presentationRows(from: rows).count, 2)
    }

    func testBothPanelCloseRoutesStopPlaybackWithoutPresentingAWindow() async throws {
        _ = NSApplication.shared
        let fixture = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let row = AudioTranscription(id: 1, sessionID: nil, text: "An authored audio transcript for playback.",
            startTime: base.addingTimeInterval(0.5), endTime: base.addingTimeInterval(2.5),
            source: .microphone, confidence: nil, createdAt: base, audioPath: fixture.path)
        let playback = TranscriptAudioPlayback(resolve: {
            try await TranscriptAudioFileResolver.resolve(request: $0, storageRoot: fixture.root)
        }, isMuted: true)
        // Exercise the production panel/controller, withholding only desktop presentation.
        let controller = TranscriptWindowController(playback: playback, presentWindow: { _ in })
        defer { controller.hide(); controller.window?.close() }
        controller.show(transcriptions: [row], timestamp: base)
        XCTAssertFalse(controller.window?.isVisible ?? true)
        playback.toggle(TranscriptAudioRequest(transcription: row))
        try await waitUntil { playback.state.phase == .playing }
        controller.show(transcriptions: [row], timestamp: base.addingTimeInterval(5))
        XCTAssertEqual(playback.state.phase, .playing, "Refreshing the same row must retain playback")
        controller.hide()
        XCTAssertEqual(playback.state.phase, .idle)
        XCTAssertNil(playback.player)
        controller.show(transcriptions: [row], timestamp: base)
        playback.toggle(TranscriptAudioRequest(transcription: row))
        try await waitUntil { playback.state.phase == .playing }
        controller.window?.close()
        XCTAssertEqual(playback.state.phase, .idle)
        XCTAssertFalse(controller.isVisible)
        XCTAssertNil(playback.player)
    }

    private func request(path: String, batch: String? = nil, id: Int64 = 1,
                         start: Double = 0, end: Double = 1) -> TranscriptAudioRequest {
        TranscriptAudioRequest(transcription: AudioTranscription(id: id, sessionID: nil, text: "Authored fixture",
            startTime: base.addingTimeInterval(start), endTime: base.addingTimeInterval(end),
            source: .microphone, confidence: nil, createdAt: base, audioPath: path, batchAudioPath: batch))
    }

    func testWaveformReadsRealAACWithinBoundedSelectedRange() async throws {
        let fixture = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let clip = try await TranscriptAudioFileResolver.resolve(
            request: request(path: fixture.path, start: 0.5, end: 2.5), storageRoot: fixture.root)
        let values = try await TranscriptWaveform.read(clip)
        XCTAssertEqual(values.count, 80)
        XCTAssertTrue(values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        XCTAssertGreaterThan(values.max() ?? 0, 0.1)
    }

    func testPlaybackRateAndTranscriptReselectionSeekOneNativePlayer() async throws {
        let fixture = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = request(path: fixture.path, start: 0.5, end: 2.5)
        let playback = TranscriptAudioPlayback(resolve: {
            try await TranscriptAudioFileResolver.resolve(request: $0, storageRoot: fixture.root)
        }, isMuted: true)
        defer { playback.stop(reason: .closed) }
        playback.setRate(1.5)
        playback.toggle(request)
        try await waitUntil { playback.state.phase == .playing }
        let player = try XCTUnwrap(playback.player)
        XCTAssertEqual(player.rate, 1.5, accuracy: 0.01)
        playback.toggle(request)
        await playback.playFromStart(request)
        XCTAssertTrue(playback.player === player)
        XCTAssertEqual(playback.state.phase, .playing)
        XCTAssertLessThan(player.currentTime().seconds, 0.85)
        playback.setRate(.nan)
        XCTAssertEqual(playback.playbackRate, 1.5)
        playback.stop(reason: .closed)
        XCTAssertTrue(playback.waveform.isEmpty)
    }

    func testRevokedWorkspaceAdmissionCannotStartAfterNativeClipResolution() async throws {
        let fixture = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = request(path: fixture.path, start: 0.5, end: 2.5)
        let gate = TranscriptPlaybackGate()
        var admitted = true
        var outcomes: [TranscriptAudioPlayback.Outcome] = []
        let playback = TranscriptAudioPlayback(resolve: { request in
            let clip = try await TranscriptAudioFileResolver.resolve(request: request, storageRoot: fixture.root)
            await gate.wait()
            return clip
        }, isMuted: true, onEvent: { outcomes.append($0.outcome) })
        defer { playback.stop(reason: .closed) }
        await playback.playFromStart(request, isAdmitted: { admitted })
        try await waitUntil { gate.isWaiting }
        let pending = playback.preparationTask
        admitted = false
        gate.open()
        await pending?.value
        XCTAssertNil(playback.player)
        XCTAssertEqual(playback.state.phase, .idle)
        XCTAssertFalse(outcomes.contains(.started))
    }

    private func makeRecording() async throws -> (root: URL, path: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-playback-\(UUID())")
        let file = try await AudioSegmentWriter(storageRoot: root).writeFullBatch(audioData: pcm(),
            timestamp: base, source: .microphone)
        return (root, file.filePath)
    }

    private func pcm() -> Data {
        // Authored three-second tone, encoded by the production AAC writer; no retained user audio.
        let samples = (0..<48_000).map { Int16(sin(Double($0) * 2 * .pi * 440 / 16_000) * 4_000) }
        return samples.withUnsafeBytes { Data($0) }
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !predicate() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "Native playback did not reach the expected state")
        if !predicate() { throw NSError(domain: "TranscriptAudioPlaybackTests", code: 1) }
    }
}

@MainActor
private final class TranscriptPlaybackGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    var isWaiting: Bool { continuation != nil }
    func wait() async {
        guard !isOpen, !Task.isCancelled else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor in self.open() }
        }
    }
    func open() { isOpen = true; continuation?.resume(); continuation = nil }
}
