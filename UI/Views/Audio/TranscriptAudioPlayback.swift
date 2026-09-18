import AVFoundation
import Combine
import Database
import Foundation
import Shared

/// Identity includes the recording and range, since refinement can replace a row's audio.
struct TranscriptAudioRequest: Equatable, Sendable {
    let id: Int64
    let start: Date
    let end: Date
    let source: AudioSource
    let audioPath: String?
    let batchAudioPath: String?

    init(transcription: AudioTranscription) {
        id = transcription.id
        start = transcription.startTime
        end = transcription.endTime
        source = transcription.source
        audioPath = transcription.audioPath
        batchAudioPath = transcription.batchAudioPath
    }

    var hasAudioPath: Bool { [audioPath, batchAudioPath].contains { !($0 ?? "").isEmpty } }
}

struct TranscriptAudioClip: Sendable {
    let url: URL
    let asset: AVURLAsset
    let startTime: TimeInterval
    let endTime: TimeInterval
}

enum TranscriptAudioError: Error {
    case unavailable, timingUnavailable, unreadable

    var message: String {
        switch self {
        case .unavailable: return "Audio file unavailable"
        case .timingUnavailable: return "Audio timing unavailable"
        case .unreadable: return "Unable to play this recording"
        }
    }
}

enum TranscriptAudioFileResolver {
    /// Finder can reveal an existing recording even when its codec or timing is unusable.
    static func resolveURL(request: TranscriptAudioRequest, storageRoot: URL) async throws -> URL {
        for path in [request.audioPath, request.batchAudioPath].compactMap({ $0 }) {
            try Task.checkCancellation()
            if let url = try? validatedURL(path: path, storageRoot: storageRoot) { return url }
        }
        throw TranscriptAudioError.unavailable
    }

    /// Nonisolated async work: file checks, symlink resolution and asset loading stay off main.
    static func resolve(request: TranscriptAudioRequest, storageRoot: URL) async throws -> TranscriptAudioClip {
        var lastError = TranscriptAudioError.unavailable
        var visited = Set<String>()
        for path in [request.audioPath, request.batchAudioPath].compactMap({ $0 }) where visited.insert(path).inserted {
            try Task.checkCancellation()
            do {
                let url = try validatedURL(path: path, storageRoot: storageRoot)
                // AudioSegmentWriter encodes the absolute recording start in milliseconds in
                // both batch_* and legacy sentence_* filenames. Row times are absolute too.
                let parts = URL(fileURLWithPath: path).lastPathComponent.split(separator: "_")
                guard parts.count >= 3, ["batch", "sentence"].contains(String(parts[0])),
                      let milliseconds = Int64(parts[1]), milliseconds > 0 else {
                    throw TranscriptAudioError.timingUnavailable
                }
                let origin = Double(milliseconds) / 1_000
                let start = request.start.timeIntervalSince1970 - origin
                let end = request.end.timeIntervalSince1970 - origin
                guard start.isFinite, end.isFinite, start >= -0.002, end > max(0, start) else {
                    throw TranscriptAudioError.timingUnavailable
                }
                let asset = AVURLAsset(url: url)
                let (duration, playable) = try await asset.load(.duration, .isPlayable)
                try Task.checkCancellation()
                guard playable, duration.seconds.isFinite, duration.seconds > 0 else {
                    throw TranscriptAudioError.unreadable
                }
                let clampedEnd = min(end, duration.seconds)
                guard clampedEnd > max(0, start) else { throw TranscriptAudioError.timingUnavailable }
                return TranscriptAudioClip(url: url, asset: asset, startTime: max(0, start), endTime: clampedEnd)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TranscriptAudioError {
                lastError = error
            } catch {
                lastError = .unreadable
            }
        }
        throw lastError
    }

    private static func validatedURL(path: String, storageRoot: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2, components.first == "audio",
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw TranscriptAudioError.unavailable
        }
        let root = storageRoot.resolvingSymlinksInPath().standardizedFileURL
        let audioRoot = root.appendingPathComponent("audio", isDirectory: true)
        let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(audioRoot.path + "/"),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw TranscriptAudioError.unavailable
        }
        return url
    }
}

/// One player per transcript panel. Every async completion belongs to an exact selection generation.
@MainActor
final class TranscriptAudioPlayback: ObservableObject {
    enum Phase { case idle, loading, playing, paused, failed }
    struct State {
        var phase: Phase = .idle
        var request: TranscriptAudioRequest?
        var message: String?
    }
    enum Outcome: String, Encodable {
        case requested, started, paused, resumed, completed, failed, cancelled, closed, selectionChanged
    }
    struct Event: Encodable {
        let outcome: Outcome
        let source: String
        // Categorical metadata only: never transcript text, file paths, IDs or recording times.
        var metadata: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }
    }

    @Published private(set) var state = State()
    private(set) var player: AVPlayer?
    private let resolve: @Sendable (TranscriptAudioRequest) async throws -> TranscriptAudioClip
    private let onEvent: (Event) -> Void
    private let isMuted: Bool
    private(set) var preparationTask: Task<Void, Never>?
    private var generation = UUID()
    private var notifications: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?

    init(resolve: @escaping @Sendable (TranscriptAudioRequest) async throws -> TranscriptAudioClip,
         isMuted: Bool = false, onEvent: @escaping (Event) -> Void = { _ in }) {
        self.resolve = resolve
        self.isMuted = isMuted
        self.onEvent = onEvent
    }

    deinit {
        preparationTask?.cancel()
        player?.pause()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func toggle(_ request: TranscriptAudioRequest) {
        if state.request == request {
            switch state.phase {
            case .playing:
                player?.pause()
                state.phase = .paused
                record(.paused, request)
                return
            case .paused:
                player?.play()
                state.phase = .playing
                record(.resumed, request)
                return
            case .loading:
                stop(reason: .cancelled)
                return
            case .idle, .failed: break
            }
        }
        stop(reason: .selectionChanged)
        let token = generation
        let started = ContinuousClock.now
        state = State(phase: .loading, request: request)
        record(.requested, request)
        preparationTask = Task { [weak self, resolve] in
            do {
                let clip = try await resolve(request)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                let item = AVPlayerItem(asset: clip.asset)
                item.forwardPlaybackEndTime = CMTime(seconds: clip.endTime, preferredTimescale: 48_000)
                let player = AVPlayer(playerItem: item)
                player.isMuted = self.isMuted
                self.player = player
                self.observe(item, token: token, request: request)
                let sought = await player.seek(to: CMTime(seconds: clip.startTime, preferredTimescale: 48_000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
                try Task.checkCancellation()
                guard self.generation == token else { return }
                guard sought, item.status != .failed else { throw TranscriptAudioError.unreadable }
                player.play()
                self.state = State(phase: .playing, request: request)
                self.preparationTask = nil
                self.record(.started, request)
                let elapsed = started.duration(to: .now).components
                let elapsedMs = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
                Task.detached(priority: .utility) {
                    Log.recordLatency("transcript.audio.start_ms", valueMs: elapsedMs,
                        category: .ui, summaryEvery: 10, warningThresholdMs: 500, criticalThresholdMs: 2_000)
                }
            } catch {
                guard let self, self.generation == token else { return }
                self.fail(request, error: error as? TranscriptAudioError ?? .unreadable)
            }
        }
    }

    func stop(reason: Outcome) {
        if let request = state.request, [.loading, .playing, .paused].contains(state.phase) {
            record(reason, request)
        }
        clearPlayer()
        state = State()
    }

    func retainSelection(in requests: [TranscriptAudioRequest]) {
        if let request = state.request, !requests.contains(request) { stop(reason: .selectionChanged) }
    }

    private func observe(_ item: AVPlayerItem, token: UUID, request: TranscriptAudioRequest) {
        notifications = [
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.record(.completed, request)
                    self.clearPlayer()
                    self.state = State()
                }
            },
            NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.fail(request, error: .unreadable)
                }
            }
        ]
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.fail(request, error: .unreadable)
            }
        }
    }

    private func fail(_ request: TranscriptAudioRequest, error: TranscriptAudioError) {
        clearPlayer()
        state = State(phase: .failed, request: request, message: error.message)
        record(.failed, request)
    }

    private func clearPlayer() {
        generation = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
        statusObservation = nil
        player?.pause()
        player?.currentItem?.cancelPendingSeeks()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func record(_ outcome: Outcome, _ request: TranscriptAudioRequest) {
        onEvent(Event(outcome: outcome, source: request.source.rawValue))
    }
}
