import Foundation
import Shared

/// A bounded in-memory PCM selection, with the underlying files leased until
/// the consumer stops and acknowledges release. No temporary audio copy is made.
public struct AudioPlaybackLease: Sendable {
    public let id: UUID
    public let reference: AudioEvidenceRef
    public let source: AudioSource
    public let relativePath: String
    public let pcmData: Data
    public let validity: AudioMediaLeaseValidity
    public let release: @Sendable () async -> Void
}

public actor AudioMediaPlaybackOwner {
    private struct Entry {
        let reference: AudioEvidenceRef
        let lease: AudioWindowReadLease
        let policy: ScreenEvidenceAccessPolicy
    }
    private let evidence: any AudioEvidenceStoreProtocol
    private let media: any AudioChunkMediaStoreProtocol
    private let configuration: @Sendable () async -> CaptureConfig
    private var entries: [UUID: Entry] = [:]
    private var acquiring = 0
    private var releasing = 0
    private var validating = 0
    private var epoch = UUID()
    private var closed = false
    private var monitor: Task<Void, Never>?
    private var monitorID: UUID?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var closing: Task<Void, Never>?

    public init(evidence: any AudioEvidenceStoreProtocol, media: any AudioChunkMediaStoreProtocol,
                configuration: @escaping @Sendable () async -> CaptureConfig) {
        self.evidence = evidence; self.media = media; self.configuration = configuration
    }

    public func acquire(_ reference: AudioEvidenceRef) async throws -> AudioPlaybackLease {
        guard !closed, entries.count + acquiring < 4 else { throw AudioChunkMediaError.closed }
        acquiring += 1
        defer { acquiring -= 1; signalDrain() }
        let generation = epoch
        let policy = ScreenEvidenceAccessPolicy(config: await configuration())
        guard case .available(let window, let snapshot, let stamp) = try await evidence.readAudioMedia(reference),
              snapshot.reference == reference, window.manifest.storeID == reference.storeID else {
            throw AudioChunkMediaError.unavailable
        }
        let lease = try await media.readWindow(window)
        do {
            guard ScreenEvidenceAccessPolicy(config: await configuration()) == policy else { throw AudioChunkMediaError.revoked }
            try await evidence.revalidateAudioEvidence(stamp, references: [reference])
            try Task.checkCancellation()
            guard !closed, epoch == generation, lease.validity.isValid else { throw AudioChunkMediaError.revoked }
            let origin = window.manifest.startTime.timeIntervalSince1970
            let start = (reference.startTime - origin) * 16_000
            let end = (reference.endTime - origin) * 16_000
            // V30 row times have millisecond precision. Preserve the manifest's
            // exact origin, allowing only that known quantization at the edges.
            guard start.isFinite, end.isFinite, start >= -16.01, end > start,
                  end <= Double(window.manifest.frameCount) + 16.01,
                  lease.pcmData.count == window.manifest.frameCount * 2 else {
                throw AudioChunkMediaError.invalidReceipt
            }
            let lower = max(0, Int(start.rounded()))
            let upper = min(Int(window.manifest.frameCount), Int(end.rounded()))
            guard upper > lower else { throw AudioChunkMediaError.invalidReceipt }
            let pcm = lease.pcmData.subdata(in: lower * 2..<upper * 2)
            entries[lease.id] = Entry(reference: reference, lease: lease, policy: policy)
            startMonitoring()
            return AudioPlaybackLease(id: lease.id, reference: reference, source: snapshot.recordingSource,
                relativePath: window.relativePath, pcmData: pcm,
                validity: lease.validity, release: { [self] in await release(lease.id) })
        } catch {
            await media.release(lease)
            throw error
        }
    }

    /// Exact reads refresh the mutation stamp; unrelated new audio does not stop
    /// playback. Deletion, revision replacement, policy change or media revocation does.
    public func revalidateActive() async {
        guard !closed else { return }
        validating += 1
        defer { validating -= 1; signalDrain() }
        for (id, entry) in entries {
            do {
                guard !closed, entry.lease.validity.isValid,
                      ScreenEvidenceAccessPolicy(config: await configuration()) == entry.policy,
                      case .available(let current, let snapshot, let stamp) = try await evidence.readAudioMedia(entry.reference),
                      current == entry.lease.window, snapshot.reference == entry.reference else {
                    throw AudioChunkMediaError.revoked
                }
                try await evidence.revalidateAudioEvidence(stamp, references: [entry.reference])
            } catch { if entries[id] != nil { entry.lease.validity.revoke() } }
        }
    }

    /// Called before App-owned invalidating policy changes. External SQLite
    /// changes are detected by bounded 250 ms revalidation, not an atomic UI fence.
    public func invalidate() {
        epoch = UUID()
        for entry in entries.values { entry.lease.validity.revoke() }
    }

    public func close() async {
        if let closing { await closing.value; return }
        closed = true
        invalidate()
        let task = Task { await drain() }
        closing = task
        await task.value
    }

    private func drain() async {
        let owned = monitor; monitor = nil; monitorID = nil
        owned?.cancel()
        await owned?.value
        if !entries.isEmpty || acquiring > 0 || releasing > 0 || validating > 0 {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private func release(_ id: UUID) async {
        guard let entry = entries.removeValue(forKey: id) else { return }
        releasing += 1
        entry.lease.validity.revoke()
        await media.release(entry.lease)
        releasing -= 1
        if entries.isEmpty { monitor?.cancel() }
        signalDrain()
    }
    private func signalDrain() {
        guard entries.isEmpty, acquiring == 0, releasing == 0, validating == 0 else { return }
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }
    private func startMonitoring() {
        guard monitor == nil else { return }
        let id = UUID(); monitorID = id
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                guard let self else { break }
                await self.revalidateActive()
            }
            await self?.monitorEnded(id)
        }
    }
    private func monitorEnded(_ id: UUID) {
        guard monitorID == id else { return }
        monitor = nil; monitorID = nil
        if !closed, !entries.isEmpty { startMonitoring() }
    }
}
