import Foundation
import Darwin
import Database
import Shared

/// Explicit, bounded screen-retention command owner shared by UI and MCP.
/// The dispatcher persists request outcomes; these short-lived confirmations are
/// process-local and deliberately become unavailable after restart.
public actor RetentionCommandService {
    private struct Pending: Sendable {
        let publicPreview: RetentionCommandPreview
        let selection: RetentionCommandSelection
        let policy: RetentionCommandPolicy
        let access: ScreenEvidenceAccessPolicy
        let root: URL
        let missingFiles: Set<VideoSegmentID>
        let fence: NativeMutationFence
        let ownerFence: NativeMutationFence
    }
    private struct Continuation: Sendable {
        let previewID: UUID
        let clientID: String
        let captureRevision: UUID
        let policy: RetentionCommandPolicy
        let root: URL
        let cursor: RetentionCommandCursor
        let expiresAt: Date
        let ownerFence: NativeMutationFence
    }
    private let database: DatabaseManager
    private let captureState: @Sendable () async throws -> NativeCaptureState
    private let retentionPolicy: @Sendable () async throws -> RetentionCommandPolicy
    private let storageRoot: @Sendable () async -> URL
    private let drainOutput: @Sendable () async -> Void
    private let invalidateStorageCaches: @Sendable () async -> Void
    private nonisolated let admission = RetentionCommandAdmission()
    private var pending: [UUID: Pending] = [:]
    private var continuations: [UUID: Continuation] = [:]
    private var work: [UUID: Task<Void, Never>] = [:]
    private var executing = false
    private var closed = false

    public init(database: DatabaseManager, captureState: @escaping @Sendable () async throws -> NativeCaptureState,
                retentionPolicy: @escaping @Sendable () async throws -> RetentionCommandPolicy,
                storageRoot: @escaping @Sendable () async -> URL,
                drainOutput: @escaping @Sendable () async -> Void,
                invalidateStorageCaches: @escaping @Sendable () async -> Void = {}) {
        self.database = database; self.captureState = captureState; self.retentionPolicy = retentionPolicy
        self.storageRoot = storageRoot; self.drainOutput = drainOutput; self.invalidateStorageCaches = invalidateStorageCaches
    }
    /// Call synchronously before capture or retention policy changes and shutdown.
    public nonisolated func invalidate() { admission.invalidate() }

    /// A continuation advances discovery and supersedes its unexecuted preview.
    /// It never confirms deletion; the returned page needs its own confirmation.
    public func preview(clientID: String, cutoff: Date, continuationID: UUID? = nil) async throws -> RetentionCommandPreview {
        guard !closed else { throw RetentionCommandError.closed }
        guard !executing else { throw RetentionCommandError.busy }
        guard !clientID.isEmpty, clientID.utf8.count <= 256, !clientID.contains("\0") else { throw RetentionCommandError.invalidArguments }
        let expired = pending.filter { $0.value.publicPreview.expiresAt <= Date() }.map(\.key)
        for id in expired { pending.removeValue(forKey: id)?.fence.invalidate() }
        continuations = continuations.filter { $0.value.expiresAt > Date() }
        let continuation: Continuation?
        if let continuationID {
            guard let retained = continuations[continuationID], retained.clientID == clientID,
                  retained.cursor.cutoff == cutoff else { throw RetentionCommandError.stalePreview }
            try retained.ownerFence.withAdmission {}
            continuations[continuationID] = nil
            pending.removeValue(forKey: retained.previewID)?.fence.invalidate()
            continuation = retained
        } else { continuation = nil }
        guard pending.count < 4 else { throw RetentionCommandError.busy }
        let epoch = admission.current()
        return try await owned { [database, captureState, retentionPolicy, storageRoot] in
            for id in expired { try? await database.discardRetentionCommand(id) }
            if let continuation { try await database.discardRetentionCommand(continuation.previewID) }
            try epoch.withAdmission {}
            let state = try await captureState(), policy = try await retentionPolicy(), root = await storageRoot()
            if let continuation {
                try continuation.ownerFence.withAdmission {}
                guard continuation.captureRevision == state.revision, continuation.policy == policy,
                      continuation.root == root else { throw RetentionCommandError.stalePreview }
            }
            let access = ScreenEvidenceAccessPolicy(config: state.config)
            let selection = try await database.previewRetentionCommand(cutoff: cutoff, policy: policy, access: access, after: continuation?.cursor)
            do {
                var missing: Set<VideoSegmentID> = []
                for video in selection.videos {
                    try Task.checkCancellation()
                    if (try? Self.filesAreMissing(root: root, path: video.relativePath)) == true { missing.insert(video.id) }
                }
                guard try await captureState().revision == state.revision, try await retentionPolicy() == policy else { throw RetentionCommandError.stalePreview }
                try epoch.withAdmission {}
                let nextID = selection.nextCursor.map { _ in UUID() }
                let preview = RetentionCommandPreview(id: selection.id, clientID: clientID, nativeStoreID: selection.nativeStoreID,
                    captureRevision: state.revision, cutoff: selection.cutoff, expiresAt: selection.expiresAt,
                    fingerprint: selection.fingerprint, frames: selection.frameIDs.count, sessions: selection.segmentIDs.count,
                    videoCandidates: selection.videos.count, hasMore: selection.hasMoreFrames || selection.hasMoreVideos,
                    nextContinuationID: nextID, scannedFrames: selection.scannedFrames, skippedFrames: selection.skippedFrames,
                    scannedVideos: selection.scannedVideos, skippedVideos: selection.skippedVideos,
                    deferredVideoFiles: selection.videos.count - missing.count)
                let item = Pending(publicPreview: preview, selection: selection, policy: policy, access: access, root: root,
                               missingFiles: missing, fence: NativeMutationFence(expiresAt: selection.expiresAt), ownerFence: epoch)
                try await self.retain(item, nextID: nextID)
                return preview
            } catch { try? await database.discardRetentionCommand(selection.id); throw error }
        }
    }

    private func retain(_ item: Pending, nextID: UUID?) throws {
        guard !closed else { throw RetentionCommandError.closed }
        guard pending.count < 4 else { throw RetentionCommandError.busy }
        guard nextID == nil || continuations.count < 8 else { throw RetentionCommandError.busy }
        try item.ownerFence.withAdmission {}
        pending[item.selection.id] = item
        if let nextID, let cursor = item.selection.nextCursor {
            continuations[nextID] = .init(previewID: item.selection.id, clientID: item.publicPreview.clientID,
                captureRevision: item.publicPreview.captureRevision, policy: item.policy, root: item.root,
                cursor: cursor, expiresAt: item.selection.expiresAt, ownerFence: item.ownerFence)
        }
    }

    /// Reuses an exact issued preview during confirmation. This performs no scan,
    /// replacement selection or deletion; SQLite revalidates targets at execution.
    public func validatePreview(preview: RetentionCommandPreview, clientID: String) async throws {
        guard !closed else { throw RetentionCommandError.closed }
        guard !executing else { throw RetentionCommandError.busy }
        guard let item = pending[preview.id], item.publicPreview == preview,
              preview.clientID == clientID, preview.expiresAt > Date() else { throw RetentionCommandError.stalePreview }
        try item.ownerFence.withAdmission {}
        try item.fence.withAdmission {}
        guard try await captureState().revision == preview.captureRevision,
              try await retentionPolicy() == item.policy,
              await storageRoot() == item.root else { throw RetentionCommandError.stalePreview }
        guard !closed, !executing, pending[preview.id]?.publicPreview == preview,
              preview.expiresAt > Date() else { throw RetentionCommandError.stalePreview }
        try item.ownerFence.withAdmission {}
        try item.fence.withAdmission {}
    }

    public func execute(preview: RetentionCommandPreview, clientID: String, commandFence: NativeMutationFence,
                        progress: @escaping @Sendable (RetentionCommandPhase) async -> Void = { _ in }) async throws -> RetentionCommandOutcome {
        guard !closed else { throw RetentionCommandError.closed }
        guard !executing else { throw RetentionCommandError.busy }
        guard let item = pending[preview.id], item.publicPreview == preview, clientID == preview.clientID,
              preview.expiresAt > Date() else { throw RetentionCommandError.stalePreview }
        executing = true; pending[preview.id] = nil
        defer { executing = false }
        let epoch = item.ownerFence
        return try await owned { [database, captureState, retentionPolicy, storageRoot, drainOutput, invalidateStorageCaches] in
            do {
                await progress(.validating)
                try epoch.withAdmission {}
                guard try await captureState().revision == preview.captureRevision,
                      try await retentionPolicy() == item.policy,
                      await storageRoot() == item.root else { throw RetentionCommandError.stalePreview }
                await progress(.deletingScreens)
                let fences = [epoch, commandFence, item.fence]
                let deleted = try await database.executeRetentionCommand(item.selection, policy: item.policy, access: item.access, fences: fences)
                // Once committed, cancellation must still join revocation and return
                // the committed counts; a retry must never repeat destructive work.
                await progress(.drainingOutput)
                await drainOutput()
                var cleaned = 0, pendingFiles = item.selection.videos.count
                await progress(.checkingVideos)
                if !Task.isCancelled {
                    for video in item.selection.videos where item.missingFiles.contains(video.id) {
                        if Task.isCancelled { break }
                        do {
                            let removed = try await database.completeRetentionCommandMissingVideo(selection: item.selection, candidate: video, fences: fences) {
                                try Self.filesAreMissing(root: item.root, path: video.relativePath)
                            }
                            await drainOutput()
                            if removed { cleaned += 1; pendingFiles -= 1 }
                        } catch { continue }
                    }
                }
                // Deferred/stale rows need a new reviewed selection. Do not keep
                // mutation authority alive just because an opaque scan continues.
                try? await database.discardRetentionCommand(preview.id)
                if cleaned > 0 { await invalidateStorageCaches() }
                await progress(.completed)
                return .init(previewID: preview.id, nativeStoreID: preview.nativeStoreID,
                    deletedFrames: deleted.frames, deletedSessions: deleted.sessions, deletedVideoRows: cleaned,
                    pendingVideoFiles: pendingFiles,
                    partial: preview.hasMore || preview.skippedFrames > 0 || preview.skippedVideos > 0 || pendingFiles > 0 || Task.isCancelled)
            } catch { try? await database.discardRetentionCommand(preview.id); throw error }
        }
    }

    private nonisolated static func filesAreMissing(root: URL, path: String) throws -> Bool {
        let urls = try RetentionManager.validatedVideoURLs(root: root, relativePath: path)
        for url in urls {
            var attributes = stat()
            let status = url.path.withCString { lstat($0, &attributes) }
            if status == 0 { return false }
            guard errno == ENOENT else { throw RetentionCommandError.unavailable }
        }
        return true
    }

    private func owned<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard !closed else { throw RetentionCommandError.closed }
        guard work.count < 4 else { throw RetentionCommandError.busy }
        let id = UUID(), task = Task { try await operation() }
        work[id] = Task { _ = await task.result }
        defer { work[id] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func close() async {
        closed = true; admission.invalidate()
        let operations = Array(work.values)
        for task in operations { await task.value }
        let previews = pending; pending.removeAll()
        continuations.removeAll()
        for (id, item) in previews { item.fence.invalidate(); try? await database.discardRetentionCommand(id) }
    }
}

private final class RetentionCommandAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch = NativeMutationFence()
    func current() -> NativeMutationFence { lock.lock(); defer { lock.unlock() }; return epoch }
    func invalidate() { lock.lock(); let previous = epoch; epoch = NativeMutationFence(); lock.unlock(); previous.invalidate() }
}
