import Darwin
import Foundation
import Shared

/// Recovers WAL records with bounded pixel memory and restart-safe publication.
/// The original WAL is retained until every encoded chunk, database transaction,
/// and durable OCR extraction has succeeded. Recovery confirms archives and
/// enqueues work; the original spool reconciler owns later source cleanup.
public actor RecoveryManager {
    private static let maximumFramesPerChunk = 150
    private let walManager: WALManager
    private let storage: StorageProtocol
    private let database: DatabaseProtocol
    private var frameEnqueueCallback: (@Sendable ([Int64]) async throws -> Void)?
    private var recoveryTask: Task<RecoveryResult, Error>?

    public init(walManager: WALManager, storage: StorageProtocol, database: DatabaseProtocol,
                processing: ProcessingProtocol? = nil, search: SearchProtocol? = nil) {
        self.walManager = walManager
        self.storage = storage
        self.database = database
    }

    public func setFrameEnqueueCallback(_ callback: @escaping @Sendable ([Int64]) async throws -> Void) {
        frameEnqueueCallback = callback
    }

    public func recoverAll() async throws -> RecoveryResult {
        try Task.checkCancellation()
        if let recoveryTask { return try await recoveryTask.value }
        let task = Task { try await self.performRecovery() }
        recoveryTask = task
        defer { recoveryTask = nil }
        // Only the caller creating this work owns its cancellation. A caller
        // joining an existing recovery must not cancel work owned by another.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performRecovery() async throws -> RecoveryResult {
        let sessions = try await walManager.listRecoverableSessions()
        var recoveredSessions = 0
        var frames = 0
        var videos = 0
        for session in sessions {
            try Task.checkCancellation()
            do {
                let result = try await recover(session)
                recoveredSessions += result.sessionsRecovered
                frames += result.framesRecovered
                videos += result.videoSegmentsCreated
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.error("[Recovery] Retaining WAL \(session.videoID.value) after recovery failure: \(error)", category: .storage)
            }
        }
        try Task.checkCancellation()
        return RecoveryResult(sessionsRecovered: recoveredSessions, framesRecovered: frames,
                              videoSegmentsCreated: videos)
    }

    private func recover(_ session: WALSession) async throws -> RecoveryResult {
        try await walManager.withOriginalReadLease(videoID: session.videoID) {
            try await self.recoverWithLease(session)
        }
    }

    private func recoverWithLease(_ session: WALSession) async throws -> RecoveryResult {
        let storeID = try await database.originalStoreID()
        guard try await walManager.originalReceipt(for: session).sourceStoreID == storeID else {
            throw failure(session, "Originals have no matching database-store attribution; source retained")
        }
        try await walManager.configureOriginalStore(storeID: storeID)
        let reader = try WALRecoveryReader(session: session)
        let scan = try await reader.scan()
        var journal = try loadJournal(session: session, sourceSize: scan.sourceSize)
        var createdVideos = 0
        var recoveredFrames = 0
        var offset: UInt64 = 0
        var index = 0
        var chunkIndex = 0

        while index < scan.frameCount {
            try Task.checkCancellation()
            let records = try await readChunk(reader, at: offset, index: index,
                                              limit: min(Self.maximumFramesPerChunk, scan.frameCount - index))
            guard let last = records.last else { throw failure(session, "Recovery made no progress") }
            if chunkIndex < journal.chunks.count {
                let chunk = journal.chunks[chunkIndex]
                guard chunk.startOffset == offset, chunk.startIndex == index,
                      chunk.frameCount == records.count, chunk.endOffset == last.nextOffset else {
                    throw failure(session, "Recovery journal does not match source WAL")
                }
            } else {
                journal.chunks.append(RecoveryChunk(startOffset: offset, endOffset: last.nextOffset,
                                                    startIndex: index, frameCount: records.count))
            }

            var recoverable: [WALRecoveryRecord] = []
            let deletions = try await walManager.originalReceipt(for: session).deleted
            for sourceRecord in records {
                var record = sourceRecord
                let alias = try await database.lookupOriginalFrame(sourceStoreID: storeID,
                    originalVideoPathID: session.videoID, sourceIndex: record.index)
                if let deletion = deletions.first(where: { $0.sourceIndex == record.index }) {
                    guard record.databaseFrameID == nil || record.databaseFrameID == deletion.frameID else {
                        throw failure(session, "Deletion receipt conflicts with its persisted frame map")
                    }
                    switch alias {
                    case .deleted(let frameID) where frameID.value == deletion.frameID:
                        break
                    case .unknown:
                        guard record.databaseFrameID == deletion.frameID,
                              case .deleted(let deletedStoreID) = try await database.originalFrameDisposition(
                            frameID: FrameID(value: deletion.frameID)), deletedStoreID == storeID else {
                            throw failure(session, "Deletion receipt has no canonical source proof")
                        }
                    default:
                        throw failure(session, "Deletion receipt conflicts with its canonical source alias")
                    }
                    // A prior crash may have persisted the deletion before this
                    // ID map. Repair it so the cleanup reader can acknowledge it.
                    try await walManager.registerFrameID(videoID: session.videoID, frameID: deletion.frameID,
                        frameIndex: record.index)
                    continue
                }
                switch alias {
                case .unknown:
                    break
                case .retained(let frameID):
                    guard record.databaseFrameID == nil || record.databaseFrameID == frameID.value else {
                        throw failure(session, "Original source alias conflicts with its persisted frame map")
                    }
                    try await walManager.registerFrameID(videoID: session.videoID, frameID: frameID.value,
                                                         frameIndex: record.index)
                    record = WALRecoveryRecord(frame: record.frame, index: record.index, offset: record.offset,
                        nextOffset: record.nextOffset, databaseFrameID: frameID.value)
                case .deleted(let frameID):
                    guard record.databaseFrameID == nil || record.databaseFrameID == frameID.value else {
                        throw failure(session, "Deleted original source alias conflicts with its persisted frame map")
                    }
                    try await walManager.registerFrameID(videoID: session.videoID, frameID: frameID.value,
                                                         frameIndex: record.index)
                    try await walManager.markOriginalDeleted(session: session, storeID: storeID,
                        frameID: frameID.value, sourceIndex: record.index)
                    continue
                }
                if let mappedID = record.databaseFrameID,
                   try await database.getFrame(id: FrameID(value: mappedID)) == nil {
                    // A previously published identity that disappeared was deleted.
                    // Persist the skip before any output publication can recreate it.
                    guard case .deleted(let deletedStoreID) = try await database.originalFrameDisposition(frameID: FrameID(value: mappedID)),
                          deletedStoreID == storeID else {
                        throw failure(session, "Missing mapped identity has no matching durable deletion receipt")
                    }
                    try await walManager.markOriginalDeleted(session: session, storeID: storeID,
                                                             frameID: mappedID, sourceIndex: record.index)
                    continue
                }
                recoverable.append(record)
            }
            if recoverable.isEmpty {
                journal.chunks[chunkIndex].committed = true
                try saveJournal(journal, session: session)
                index += records.count
                offset = last.nextOffset
                chunkIndex += 1
                continue
            }
            if let previousIndices = journal.chunks[chunkIndex].sourceIndices,
               previousIndices != recoverable.map(\.index) {
                guard Set(recoverable.map(\.index)).isSubset(of: Set(previousIndices)) else {
                    throw failure(session, "Recovery checkpoint changed without a proved deletion")
                }
                // The previous output may already be published. Preserve it and
                // replace only the journal checkpoint before encoding survivors
                // into a fresh archive. The database rechecks immutable aliases
                // when publishing, including a deletion arriving during encoding.
                journal.chunks[chunkIndex] = RecoveryChunk(startOffset: offset, endOffset: last.nextOffset,
                    startIndex: index, frameCount: records.count)
                try saveJournal(journal, session: session)
            }

            if journal.chunks[chunkIndex].video == nil {
                // An incomplete output is never referenced by the database: video
                // metadata is checkpointed before the database transaction starts.
                if let abandonedID = journal.chunks[chunkIndex].outputID {
                    guard abandonedID != session.videoID else { throw failure(session, "Recovery output must not overwrite the source video") }
                    if try await storage.segmentExists(id: abandonedID) {
                        try await storage.deleteSegment(id: abandonedID)
                    }
                }
                let writer = try await storage.createRecoverySegmentWriter()
                journal.chunks[chunkIndex].outputID = await writer.segmentID
                try saveJournal(journal, session: session)
                do {
                    for record in recoverable {
                        try Task.checkCancellation()
                        guard let loaded = try await reader.readRecord(at: record.offset, index: record.index, loadPixels: true) else {
                            throw failure(session, "Missing frame during encoding")
                        }
                        try await writer.appendFrame(loaded.frame)
                    }
                    let encoded = try await writer.finalize()
                    guard encoded.frameCount == recoverable.count,
                          try await storage.countFramesInSegment(id: encoded.id) == recoverable.count,
                          try await storage.isVideoValid(id: encoded.id) else {
                        throw failure(session, "Encoded recovery output is incomplete or unreadable")
                    }
                    let outputURL = try await storage.getSegmentPath(id: encoded.id)
                    let outputHandle = try FileHandle(forWritingTo: outputURL)
                    do {
                        try outputHandle.synchronize()
                        try outputHandle.close()
                    } catch {
                        try? outputHandle.close()
                        throw error
                    }
                    // Retain original capture times; writer startTime is recovery wall time.
                    journal.chunks[chunkIndex].video = VideoSegment(
                        id: encoded.id, startTime: recoverable[0].frame.timestamp, endTime: recoverable[recoverable.count - 1].frame.timestamp,
                        frameCount: encoded.frameCount, fileSizeBytes: encoded.fileSizeBytes,
                        relativePath: encoded.relativePath, width: encoded.width, height: encoded.height)
                    journal.chunks[chunkIndex].sourceIndices = recoverable.map(\.index)
                    try saveJournal(journal, session: session)
                    createdVideos += 1
                } catch {
                    // The original source WAL still owns every pixel. Canceling the
                    // new, unpublished output cannot remove original evidence.
                    // Once finalized metadata may have reached the journal, keep
                    // that output even when journal fsync fails: restart can retry
                    // the same publication rather than referencing a removed file.
                    if journal.chunks[chunkIndex].video == nil { try? await writer.cancel() }
                    throw error
                }
            }

            guard let video = journal.chunks[chunkIndex].video else { throw failure(session, "Missing encoded checkpoint") }
            guard try await storage.countFramesInSegment(id: video.id) == video.frameCount,
                  try await storage.isVideoValid(id: video.id) else {
                throw failure(session, "Checkpoint video is missing or invalid; original WAL retained")
            }
            if !journal.chunks[chunkIndex].committed {
                try Task.checkCancellation()
                let references = recoverable.enumerated().map { outputIndex, record in
                    FrameReference(id: FrameID(value: record.databaseFrameID ?? 0),
                                   timestamp: record.frame.timestamp, segmentID: AppSegmentID(value: 0),
                                   videoID: video.id, frameIndexInSegment: outputIndex,
                                   metadata: record.frame.metadata, source: .native)
                }
                let ids = try await database.commitRecoveredFrames(video: video,
                    originalVideoPathID: session.videoID, originalFrameIndices: recoverable.map(\.index), frames: references)
                guard ids.count == recoverable.count else { throw failure(session, "Database did not confirm every recovered frame") }
                journal.chunks[chunkIndex].frameIDs = ids
                try saveJournal(journal, session: session)
                for (position, id) in ids.enumerated() {
                    try await walManager.registerFrameID(videoID: session.videoID, frameID: id,
                                                         frameIndex: recoverable[position].index)
                }
                try Task.checkCancellation()
                try await enqueue(ids)
                try Task.checkCancellation()
                journal.chunks[chunkIndex].committed = true
                try saveJournal(journal, session: session)
                recoveredFrames += ids.count
            }
            let ids = journal.chunks[chunkIndex].frameIDs ?? recoverable.compactMap(\.databaseFrameID)
            guard ids.count == recoverable.count,
                  let firstFrame = try await database.getFrame(id: FrameID(value: ids[0])),
                  let publishedVideo = try await database.getVideoSegment(id: firstFrame.videoID) else {
                throw failure(session, "Cannot prove committed recovery frame identities; originals retained")
            }
            for (position, id) in ids.enumerated() {
                try await walManager.registerFrameID(videoID: session.videoID, frameID: id,
                                                     frameIndex: recoverable[position].index)
            }
            try await walManager.confirmOriginalArchive(session: session, video: publishedVideo,
                sourceIndices: recoverable.map(\.index), frameIDs: ids)
            index += records.count
            offset = last.nextOffset
            chunkIndex += 1
        }

        guard journal.chunks.count == chunkIndex else { throw failure(session, "Journal extends beyond valid source frames") }
        guard try await reader.sourceIsUnchanged() else { throw failure(session, "WAL changed during recovery") }
        if let tailError = scan.tailError {
            Log.warning("[Recovery] Recovered \(scan.frameCount) complete frames; retaining WAL \(session.videoID.value) with damaged tail: \(tailError)", category: .storage)
            return RecoveryResult(sessionsRecovered: 0, framesRecovered: recoveredFrames, videoSegmentsCreated: createdVideos)
        }
        guard scan.frameCount >= session.metadata.frameCount else {
            throw failure(session, "Metadata records more frames than the WAL contains")
        }
        try Task.checkCancellation()
        try await walManager.finalizeSession(session)
        Log.info("[Recovery] Confirmed \(scan.frameCount) archive mappings for WAL \(session.videoID.value); originals retained for extraction", category: .storage)
        return RecoveryResult(sessionsRecovered: 1, framesRecovered: recoveredFrames, videoSegmentsCreated: createdVideos)
    }

    private func readChunk(_ reader: WALRecoveryReader, at startOffset: UInt64, index: Int, limit: Int) async throws -> [WALRecoveryRecord] {
        var records: [WALRecoveryRecord] = []
        var offset = startOffset
        for position in 0..<limit {
            guard let record = try await reader.readRecord(at: offset, index: index + position, loadPixels: false) else { break }
            if let first = records.first,
               first.frame.width != record.frame.width || first.frame.height != record.frame.height { break }
            records.append(record)
            offset = record.nextOffset
        }
        return records
    }

    private func enqueue(_ ids: [Int64]) async throws {
        let statuses = try await database.getFrameProcessingStatuses(frameIDs: ids)
        var pending: [Int64] = []
        for id in ids {
            switch statuses[id] ?? 0 {
            case 2: continue
            case 4: try await database.markFrameReadable(frameID: id)
            case 1, 3: try await database.updateFrameProcessingStatus(frameID: id, status: 0)
            case 0: break
            default: throw StorageError.fileWriteFailed(path: "WAL recovery", underlying: "Unknown processing status for frame \(id)")
            }
            pending.append(id)
        }
        if !pending.isEmpty {
            guard let callback = frameEnqueueCallback else {
                throw StorageError.fileWriteFailed(path: "WAL recovery", underlying: "OCR enqueue callback is unavailable")
            }
            try await callback(pending)
        }
    }

    private func loadJournal(session: WALSession, sourceSize: UInt64) throws -> RecoveryJournal {
        let url = session.sessionDir.appendingPathComponent("recovery-progress.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return RecoveryJournal(sourceSize: sourceSize, chunks: [])
        }
        let journal = try JSONDecoder().decode(RecoveryJournal.self, from: Data(contentsOf: url))
        guard journal.version == 1, journal.sourceSize == sourceSize else {
            throw failure(session, "Recovery journal version or WAL size has changed")
        }
        return journal
    }

    private func saveJournal(_ journal: RecoveryJournal, session: WALSession) throws {
        let url = session.sessionDir.appendingPathComponent("recovery-progress.json")
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        // Persist the atomic rename in the containing directory as well as the file.
        let descriptor = open(session.sessionDir.path, O_RDONLY)
        guard descriptor >= 0 else { throw failure(session, "Cannot open journal directory for synchronization") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw failure(session, "Cannot synchronize recovery journal directory") }
    }

    private func failure(_ session: WALSession, _ detail: String) -> StorageError {
        .fileWriteFailed(path: session.framesURL.path, underlying: detail)
    }
}

private struct RecoveryJournal: Codable {
    var version = 1
    let sourceSize: UInt64
    var chunks: [RecoveryChunk]
}

private struct RecoveryChunk: Codable {
    let startOffset: UInt64
    let endOffset: UInt64
    let startIndex: Int
    let frameCount: Int
    var outputID: VideoSegmentID?
    var video: VideoSegment?
    var sourceIndices: [Int]?
    var frameIDs: [Int64]?
    var committed = false
}

// MARK: - Models

public struct RecoveryResult: Sendable {
    public let sessionsRecovered: Int
    public let framesRecovered: Int
    public let videoSegmentsCreated: Int

    public init(sessionsRecovered: Int, framesRecovered: Int, videoSegmentsCreated: Int) {
        self.sessionsRecovered = sessionsRecovered
        self.framesRecovered = framesRecovered
        self.videoSegmentsCreated = videoSegmentsCreated
    }
}
