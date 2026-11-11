import Foundation
import Shared

/// Lazy local reader ownership only. This grants no policy/consent authority,
/// opens no media, and starts no bootstrap, capture, model or background search.
/// The underlying native reader instruments awaited categorical read attempts;
/// App still revalidates its current local policy before presenting returned text.
public actor AudioHistoryOwner: AudioEvidenceStoreProtocol {
    private struct Acquisition {
        let id: UUID
        let task: Task<any AudioEvidenceStoreProtocol, Error>
    }
    private let factory: @Sendable () async throws -> any AudioEvidenceStoreProtocol
    private var reader: (any AudioEvidenceStoreProtocol)?
    private var acquisition: Acquisition?
    private var closing: Task<Void, Never>?
    private(set) var isClosed = false
    private var active = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    public init(factory: @escaping @Sendable () async throws -> any AudioEvidenceStoreProtocol) {
        self.factory = factory
    }

    public func searchAudioEvidence(_ request: AudioEvidenceSearchRequest) async throws -> AudioEvidenceSearchPage {
        try enter(); defer { leave() }
        let reader = try await acquire()
        try checkCurrent()
        let result = try await reader.searchAudioEvidence(request)
        try checkCurrent()
        return result
    }
    public func readAudioEvidence(_ reference: AudioEvidenceRef) async throws -> AudioEvidenceReadResult {
        try enter(); defer { leave() }
        let reader = try await acquire()
        try checkCurrent()
        let result = try await reader.readAudioEvidence(reference)
        try checkCurrent()
        return result
    }
    public func revalidateAudioEvidence(_ stamp: AudioEvidenceReadStamp, references: [AudioEvidenceRef]) async throws {
        try enter(); defer { leave() }
        let reader = try await acquire()
        try checkCurrent()
        try await reader.revalidateAudioEvidence(stamp, references: references)
        try checkCurrent()
    }
    public func readAudioMedia(_ reference: AudioEvidenceRef) async throws -> AudioEvidenceMediaReadResult {
        try enter(); defer { leave() }
        let reader = try await acquire()
        try checkCurrent()
        let result = try await reader.readAudioMedia(reference)
        try checkCurrent()
        return result
    }
    public func audioEvidenceCoverage() async throws -> AudioEvidenceCoverage {
        try enter(); defer { leave() }
        let reader = try await acquire()
        try checkCurrent()
        let result = try await reader.audioEvidenceCoverage()
        try checkCurrent()
        return result
    }

    /// Terminal admission precedes the first suspension. An independent owning
    /// task joins even when a close caller is cancelled. Replacement uses a new
    /// owner only after this old owner's close has completed.
    public func close() async {
        if let closing { await closing.value; return }
        isClosed = true
        acquisition?.task.cancel()
        let task = Task { await drain() }
        closing = task
        await task.value
    }

    /// Only ServiceContainer's serialized, nonterminal initialization retry uses
    /// this after rollback has joined. Public evidence reads never reopen it.
    func reopenAfterJoinedClose() async throws {
        try Task.checkCancellation()
        guard isClosed else { return }
        await closing?.value
        try Task.checkCancellation()
        guard active == 0, reader == nil, acquisition == nil else { throw AudioEvidenceError.readerClosed }
        closing = nil
        isClosed = false
    }

    private func checkCurrent() throws {
        guard !isClosed else { throw AudioEvidenceError.readerClosed }
        try Task.checkCancellation()
    }
    private func enter() throws { try checkCurrent(); active += 1 }
    private func leave() {
        active -= 1
        if active == 0 {
            let pending = drainWaiters; drainWaiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
    private func acquire() async throws -> any AudioEvidenceStoreProtocol {
        try checkCurrent()
        if let reader { return reader }
        let pending: Acquisition
        if let acquisition { pending = acquisition }
        else {
            let factory = factory
            pending = Acquisition(id: UUID(), task: Task { try await factory() })
            acquisition = pending
        }
        do {
            let value = try await pending.task.value
            // Keep a late completed task owned until close drains its reader.
            guard !isClosed else { throw AudioEvidenceError.readerClosed }
            if acquisition?.id == pending.id {
                reader = value
                acquisition = nil
            }
            try Task.checkCancellation()
            return value
        } catch {
            if isClosed { throw AudioEvidenceError.readerClosed }
            if acquisition?.id == pending.id { acquisition = nil }
            throw error
        }
    }
    private func drain() async {
        var owned = reader
        if let acquisition {
            let result = await acquisition.task.result
            if case .success(let acquired) = result { owned = acquired }
        }
        // Close the reader before waiting for operations: its own terminal fence
        // must reach active reads; both layers then join their callbacks/defers.
        await owned?.close()
        if active > 0 { await withCheckedContinuation { drainWaiters.append($0) } }
        reader = nil
        acquisition = nil
    }
}
