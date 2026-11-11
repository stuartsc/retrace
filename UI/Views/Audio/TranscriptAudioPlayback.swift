import AVFoundation
import Combine
import Database
import Foundation
import Shared
import App

/// Identity includes the recording and range, since refinement can replace a row's audio.
struct TranscriptAudioRequest: Equatable, Sendable {
    let id: Int64
    let start: Date
    let end: Date
    let source: AudioSource
    let audioPath: String?
    let batchAudioPath: String?
    let evidenceReference: AudioEvidenceRef?

    init(transcription: AudioTranscription) {
        id = transcription.id
        start = transcription.startTime
        end = transcription.endTime
        source = transcription.source
        audioPath = transcription.audioPath
        batchAudioPath = transcription.batchAudioPath
        evidenceReference = transcription.evidenceReference
    }

    var hasAudioPath: Bool { [audioPath, batchAudioPath].contains { !($0 ?? "").isEmpty } }
}

struct TranscriptAudioClip: Sendable {
    let url: URL?
    let asset: AVURLAsset?
    let startTime: TimeInterval
    let endTime: TimeInterval
    let lease: AudioPlaybackLease?
    let waveData: Data?

    init(url: URL, asset: AVURLAsset, startTime: TimeInterval, endTime: TimeInterval) {
        self.url = url; self.asset = asset; self.startTime = startTime; self.endTime = endTime
        lease = nil; waveData = nil
    }
    init(lease: AudioPlaybackLease) {
        url = nil; asset = nil; startTime = 0; endTime = Double(lease.pcmData.count) / 32_000
        self.lease = lease
        var wave = Data()
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) }
        }
        wave.append(Data("RIFF".utf8)); number(UInt32(36 + lease.pcmData.count))
        wave.append(Data("WAVEfmt ".utf8)); number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(16_000)); number(UInt32(32_000)); number(UInt16(2)); number(UInt16(16))
        wave.append(Data("data".utf8)); number(UInt32(lease.pcmData.count)); wave.append(lease.pcmData)
        waveData = wave
    }
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
    static func resolve(request: TranscriptAudioRequest, coordinator: AppCoordinator) async throws -> TranscriptAudioClip {
        let paths = [request.audioPath, request.batchAudioPath].compactMap { $0 }
        if paths.contains(where: { $0.hasPrefix("audio/chunk-media/") || $0.hasSuffix(".retraceaudio") }) {
            guard let reference = request.evidenceReference else { throw TranscriptAudioError.unavailable }
            let lease = try await coordinator.acquireAudioPlayback(reference)
            do {
                try Task.checkCancellation()
                guard reference.startTime == request.start.timeIntervalSince1970,
                      reference.endTime == request.end.timeIntervalSince1970,
                      lease.source == request.source, paths.contains(lease.relativePath) else {
                    throw TranscriptAudioError.timingUnavailable
                }
                return TranscriptAudioClip(lease: lease)
            }
            catch { await lease.release(); throw error }
        }
        let root = await coordinator.getAudioStorageDirectory()
        return try await resolve(request: request, storageRoot: root)
    }
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

enum TranscriptWaveform {
    /// Decode a bounded selected range off main. Values are actual peak samples,
    /// never a decorative waveform and never retained after closing playback.
    static func read(_ clip: TranscriptAudioClip) async throws -> [Float] {
        let task = Task.detached(priority: .utility) {
            if let lease = clip.lease {
                guard lease.validity.isValid else { throw TranscriptAudioError.unavailable }
                var values = [Float](repeating: 0, count: 80)
                let count = lease.pcmData.count / 2
                for index in 0..<count {
                    if index % 4_096 == 0 { try Task.checkCancellation() }
                    let sample = lease.pcmData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 2, as: Int16.self) }
                    let bucket = min(79, index * 80 / count)
                    values[bucket] = max(values[bucket], abs(Float(Int16(littleEndian: sample))) / 32_768)
                }
                return values
            }
            guard let url = clip.url else { throw TranscriptAudioError.unavailable }
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            guard format.sampleRate > 0,
                  clip.endTime > clip.startTime else { throw TranscriptAudioError.unreadable }
            let duration = min(clip.endTime - clip.startTime, 300)
            let count = min(AVAudioFramePosition(duration * format.sampleRate), file.length)
            let start = AVAudioFramePosition(clip.startTime * format.sampleRate)
            guard count > 0, start >= 0, start < file.length,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
                throw TranscriptAudioError.unreadable
            }
            file.framePosition = start
            let total = min(count, file.length - start)
            var result = [Float](repeating: 0, count: 80)
            var offset: AVAudioFramePosition = 0
            while offset < total {
                try Task.checkCancellation()
                let frames = AVAudioFrameCount(min(4_096, total - offset))
                try file.read(into: buffer, frameCount: frames)
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
                for index in 0..<Int(buffer.frameLength) {
                    let bucket = min(79, Int((offset + Int64(index)) * 80 / total))
                    for channel in 0..<Int(format.channelCount) {
                        let sample = abs(channels[channel][index])
                        if sample.isFinite { result[bucket] = max(result[bucket], min(1, sample)) }
                    }
                }
                offset += Int64(buffer.frameLength)
            }
            return result
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
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
        case requested, started, paused, resumed, completed, failed, cancelled, closed, selectionChanged, speedChanged, sought
    }
    struct Event: Encodable {
        let outcome: Outcome
        let source: String
        // Categorical metadata only: never transcript text, file paths, IDs or recording times.
        var metadata: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }
    }

    @Published private(set) var state = State()
    @Published private(set) var waveform: [Float] = []
    @Published private(set) var playbackRate: Float = 1
    private(set) var player: AVPlayer?
    private var activeClip: TranscriptAudioClip?
    private var waveformTask: Task<Void, Never>?
    private var playbackAction: UInt64 = 0
    private let resolve: @Sendable (TranscriptAudioRequest) async throws -> TranscriptAudioClip
    private let onEvent: (Event) -> Void
    private let isMuted: Bool
    private(set) var preparationTask: Task<Void, Never>?
    private var generation = UUID()
    private var notifications: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?
    private(set) var pcmPlayer: AVAudioPlayer?
    private var pcmMonitor: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?

    init(resolve: @escaping @Sendable (TranscriptAudioRequest) async throws -> TranscriptAudioClip,
         isMuted: Bool = false, onEvent: @escaping (Event) -> Void = { _ in }) {
        self.resolve = resolve
        self.isMuted = isMuted
        self.onEvent = onEvent
    }

    deinit {
        preparationTask?.cancel()
        waveformTask?.cancel()
        player?.pause()
        pcmPlayer?.stop()
        pcmMonitor?.cancel()
        if let lease = activeClip?.lease { Task { await lease.release() } }
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func toggle(_ request: TranscriptAudioRequest, isAdmitted: @escaping @MainActor () -> Bool = { true }) {
        guard !Task.isCancelled, isAdmitted() else { return }
        playbackAction &+= 1
        if state.request == request {
            switch state.phase {
            case .playing:
                player?.pause()
                pcmPlayer?.pause()
                state.phase = .paused
                record(.paused, request)
                return
            case .paused:
                guard activeClip?.lease?.validity.isValid != false else { fail(request, error: .unavailable); return }
                player?.playImmediately(atRate: playbackRate)
                pcmPlayer?.play()
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
            var pendingLease: AudioPlaybackLease?
            do {
                let clip = try await resolve(request)
                pendingLease = clip.lease
                try Task.checkCancellation()
                guard let self, self.generation == token else { if let pendingLease { await pendingLease.release() }; return }
                guard isAdmitted() else {
                    if let pendingLease { await pendingLease.release() }
                    self.stop(reason: .selectionChanged); return
                }
                self.activeClip = clip
                pendingLease = nil
                if let lease = clip.lease, let wave = clip.waveData {
                    guard lease.validity.isValid else { throw TranscriptAudioError.unavailable }
                    let native = try AVAudioPlayer(data: wave)
                    native.volume = self.isMuted ? 0 : 1
                    native.enableRate = true; native.rate = self.playbackRate
                    self.pcmPlayer = native
                    lease.validity.observeRevocation { [weak self] in
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            self.fail(request, error: .unavailable)
                        }
                    }
                    guard lease.validity.isValid, native.prepareToPlay(), native.play() else {
                        throw TranscriptAudioError.unreadable
                    }
                    self.monitorPCM(token: token, request: request)
                } else {
                guard let asset = clip.asset else { throw TranscriptAudioError.unreadable }
                let item = AVPlayerItem(asset: asset)
                item.forwardPlaybackEndTime = CMTime(seconds: clip.endTime, preferredTimescale: 48_000)
                let player = AVPlayer(playerItem: item)
                player.isMuted = self.isMuted
                self.player = player
                self.activeClip = clip
                self.observe(item, token: token, request: request)
                let sought = await player.seek(to: CMTime(seconds: clip.startTime, preferredTimescale: 48_000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
                try Task.checkCancellation()
                guard self.generation == token else { return }
                guard isAdmitted() else { self.stop(reason: .selectionChanged); return }
                guard sought, item.status != .failed else { throw TranscriptAudioError.unreadable }
                player.playImmediately(atRate: self.playbackRate)
                }
                self.state = State(phase: .playing, request: request)
                self.preparationTask = nil
                self.record(.started, request)
                self.waveformTask = Task { [weak self] in
                    guard let values = try? await TranscriptWaveform.read(clip), !Task.isCancelled,
                          let self, self.generation == token else { return }
                    self.waveform = values
                }
                let elapsed = started.duration(to: .now).components
                let elapsedMs = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
                Task.detached(priority: .utility) {
                    Log.recordLatency("transcript.audio.start_ms", valueMs: elapsedMs,
                        category: .ui, summaryEvery: 10, warningThresholdMs: 500, criticalThresholdMs: 2_000)
                }
            } catch {
                if let pendingLease { await pendingLease.release() }
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

    func stopAndDrain() async {
        let pending = preparationTask
        stop(reason: .closed)
        await pending?.value
        await releaseTask?.value
    }

    func setRate(_ rate: Float) {
        guard rate.isFinite, (0.5...2).contains(rate) else { return }
        playbackRate = rate
        if state.phase == .playing { player?.playImmediately(atRate: rate) }
        pcmPlayer?.rate = rate
        onEvent(Event(outcome: .speedChanged, source: state.request?.source.rawValue ?? "none"))
    }

    func playFromStart(_ request: TranscriptAudioRequest,
                       isAdmitted: @escaping @MainActor () -> Bool = { true }) async {
        guard !Task.isCancelled, isAdmitted() else { return }
        playbackAction &+= 1
        let action = playbackAction
        if state.request == request, let pcmPlayer {
            guard activeClip?.lease?.validity.isValid == true else { fail(request, error: .unavailable); return }
            pcmPlayer.currentTime = 0
            guard pcmPlayer.play() else { fail(request, error: .unreadable); return }
            state.phase = .playing; record(.sought, request); return
        }
        guard state.request == request, let clip = activeClip, let player else {
            if state.request == request, state.phase == .loading { return }
            toggle(request, isAdmitted: isAdmitted); return
        }
        let token = generation
        let sought = await player.seek(to: CMTime(seconds: clip.startTime, preferredTimescale: 48_000),
            toleranceBefore: .zero, toleranceAfter: .zero)
        guard sought, !Task.isCancelled, generation == token, playbackAction == action else { return }
        guard isAdmitted() else { stop(reason: .selectionChanged); return }
        player.playImmediately(atRate: playbackRate)
        state.phase = .playing
        record(.sought, request)
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
        playbackAction &+= 1
        generation = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        waveformTask?.cancel(); waveformTask = nil; waveform = []
        pcmMonitor?.cancel(); pcmMonitor = nil
        pcmPlayer?.stop(); pcmPlayer = nil
        if let lease = activeClip?.lease {
            let prior = releaseTask
            releaseTask = Task { await prior?.value; await lease.release() }
        }
        activeClip = nil
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
        statusObservation = nil
        player?.pause()
        player?.currentItem?.cancelPendingSeeks()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func monitorPCM(token: UUID, request: TranscriptAudioRequest) {
        pcmMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                guard let self, self.generation == token, let native = self.pcmPlayer else { return }
                guard self.activeClip?.lease?.validity.isValid == true else {
                    self.fail(request, error: .unavailable); return
                }
                if self.state.phase == .playing, !native.isPlaying {
                    self.record(.completed, request); self.clearPlayer(); self.state = State(); return
                }
            }
        }
    }

    private func record(_ outcome: Outcome, _ request: TranscriptAudioRequest) {
        onEvent(Event(outcome: outcome, source: request.source.rawValue))
    }
}
