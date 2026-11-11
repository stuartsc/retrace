import Foundation
import Shared

/// Write-Ahead Log Manager for crash-safe frame persistence
///
/// Writes raw captured frames to disk before video encoding, ensuring:
/// - No data loss on crash/termination
/// - Sequential exact-pixel writes (raw by default, opt-in independent lossless records)
/// - Recovery on app restart
///
/// Directory structure:
/// {AppPaths.storageRoot}/wal/
///   └── original_segment_{videoID}/  (legacy active_segment_ remains readable)
///       ├── frames.bin      # Binary: [FrameHeader|PixelData][FrameHeader|PixelData]...
///       └── metadata.json   # Segment metadata (videoID, startTime, frameCount)
public actor WALManager {
    public static let defaultQuarantineMaxAge: TimeInterval = 24 * 60 * 60
    public static let defaultQuarantineMaxBytes: Int64 = 2 * 1024 * 1024 * 1024

    let walRootURL: URL
    let maximumSpoolBytes: Int64
    let minimumFreeBytes: Int64
    let availableSpoolBytes: @Sendable () throws -> Int64
    var originalSpoolReconciliation: Task<OriginalSpoolStatus, Error>?
    var originalStoreID: UUID?
    /// Sessions opened by this process belong to active capture, never startup recovery.
    var liveSessionIDs: Set<VideoSegmentID> = []
    private var frameIDOffsetIndexCache: [Int64: WALFrameIDOffsetIndex] = [:]
    private var originalPixelCompression: OriginalPixelCompression
    /// A failed rollback retains its source for recovery and cannot accept another append.
    private var appendRecoveryRequired: Set<VideoSegmentID> = []

    public init(walRoot: URL,
                maximumSpoolBytes: Int64 = OriginalSpoolStatus.defaultLimitBytes,
                minimumFreeBytes: Int64 = OriginalSpoolStatus.defaultMinimumFreeBytes,
                availableBytes: (@Sendable () throws -> Int64)? = nil,
                originalPixelCompression: OriginalPixelCompression = .disabled) {
        self.walRootURL = walRoot
        self.maximumSpoolBytes = max(0, maximumSpoolBytes)
        self.minimumFreeBytes = max(0, minimumFreeBytes)
        self.originalPixelCompression = originalPixelCompression
        self.availableSpoolBytes = availableBytes ?? {
            let values = try FileManager.default.attributesOfFileSystem(forPath: walRoot.path)
            guard let bytes = values[.systemFreeSize] as? NSNumber else {
                throw StorageError.fileReadFailed(path: walRoot.path, underlying: "Free disk capacity is unavailable")
            }
            return bytes.int64Value
        }
    }

    /// Applies to subsequent records only. Older V1/V2/V3 records remain readable
    /// regardless of this writer setting, including mixed-format sessions.
    public func configureOriginalPixelCompression(_ compression: OriginalPixelCompression) {
        originalPixelCompression = compression
    }

    /// File presence also includes retained recovery material. Only a session
    /// opened by this manager can still receive pixels from its live writer.
    public func isLiveSession(videoID: VideoSegmentID) -> Bool {
        liveSessionIDs.contains(videoID)
    }

    public func initialize() async throws {
        // Create WAL root directory if needed
        if !FileManager.default.fileExists(atPath: walRootURL.path) {
            try FileManager.default.createDirectory(
                at: walRootURL,
                withIntermediateDirectories: true
            )
        }

        _ = try await pruneQuarantinedSessions()
    }

    // MARK: - Write Operations

    /// Create a new WAL session for a video segment
    public func createSession(videoID: VideoSegmentID) async throws -> WALSession {
        let sessionDir = walRootURL.appendingPathComponent("original_segment_\(videoID.value)")
        guard videoID.value > 0, !FileManager.default.fileExists(atPath: sessionDirectory(videoID: videoID).path) else {
            throw StorageError.fileWriteFailed(path: sessionDir.path, underlying: "Original session identity already exists or is invalid")
        }

        // Create session directory
        try FileManager.default.createDirectory(
            at: sessionDir,
            withIntermediateDirectories: true
        )

        // Create empty frames.bin file
        let framesURL = sessionDir.appendingPathComponent("frames.bin")
        FileManager.default.createFile(atPath: framesURL.path, contents: nil)
        let frameMapURL = sessionDir.appendingPathComponent("frame_id_map.bin")
        FileManager.default.createFile(atPath: frameMapURL.path, contents: nil)

        // Create metadata file
        let metadata = WALMetadata(
            videoID: videoID,
            startTime: Date(),
            frameCount: 0,
            width: 0,
            height: 0
        )
        try saveMetadata(metadata, to: sessionDir)
        let createdSession = WALSession(videoID: videoID, sessionDir: sessionDir,
            framesURL: framesURL, metadata: metadata)
        var receipt = OriginalSpoolReceipt()
        receipt.sourceStoreID = originalStoreID
        try saveOriginalReceipt(receipt, for: createdSession)
        liveSessionIDs.insert(videoID)

        return WALSession(
            videoID: videoID,
            sessionDir: sessionDir,
            framesURL: framesURL,
            metadata: metadata
        )
    }

    /// Append a frame to the WAL
    public func appendFrame(_ frame: CapturedFrame, to session: inout WALSession) async throws {
        try Task.checkCancellation()
        guard !appendRecoveryRequired.contains(session.videoID) else {
            throw StorageError.fileWriteFailed(path: session.framesURL.path, underlying: "Original session requires recovery after an unsuccessful rollback")
        }
        guard !(try originalReceipt(for: session).sealed) else {
            throw StorageError.fileWriteFailed(path: session.framesURL.path, underlying: "Sealed original frame session")
        }
        let compression: WALFrameCodec.PixelCompression
        switch originalPixelCompression {
        case .disabled: compression = .disabled
        case .lzfse: compression = .lzfse
        case .lz4: compression = .lz4
        }
        let record = try WALFrameCodec.encode(frame, path: session.framesURL.path, compression: compression)
        try Task.checkCancellation()
        // Admission uses the actual bounded record, including compression headers,
        // metadata and raw fallback, while keeping acknowledgement reserves intact.
        try ensureOriginalSpoolAdmission(incomingBytes: record.byteCount)
        let previousMetadataBytes = try boundedMetadataBytes(from: session.sessionDir)
        var updatedMetadata = session.metadata
        let nextCount = updatedMetadata.frameCount.addingReportingOverflow(1)
        guard updatedMetadata.frameCount >= 0, !nextCount.overflow else {
            throw StorageError.fileWriteFailed(path: session.framesURL.path, underlying: "Invalid original frame count")
        }
        updatedMetadata.frameCount = nextCount.partialValue
        if updatedMetadata.width == 0 {
            updatedMetadata.width = frame.width
            updatedMetadata.height = frame.height
        }
        // Open file handle for appending
        guard let fileHandle = FileHandle(forWritingAtPath: session.framesURL.path) else {
            throw StorageError.fileWriteFailed(
                path: session.framesURL.path,
                underlying: "Cannot open file for appending"
            )
        }
        defer { try? fileHandle.close() }

        let previousOffset = try fileHandle.seekToEnd()
        do {
            try fileHandle.write(contentsOf: record.header)
            try fileHandle.write(contentsOf: record.metadata)
            try fileHandle.write(contentsOf: record.pixels)
            try fileHandle.synchronize()
            try saveMetadata(updatedMetadata, to: session.sessionDir)
            // Publish the caller's state only after both durable writes succeed.
            session.metadata = updatedMetadata
        } catch {
            let appendError = error
            do {
                // Atomic replacement can succeed before a later metadata fsync
                // fails. Restore that metadata before removing its extra pixels.
                if try boundedMetadataBytes(from: session.sessionDir) != previousMetadataBytes {
                    let metadataURL = session.sessionDir.appendingPathComponent("metadata.json")
                    try previousMetadataBytes.write(to: metadataURL, options: .atomic)
                    try OriginalSpoolFiles.synchronizeFileAndParent(metadataURL)
                }
                try fileHandle.truncate(atOffset: previousOffset)
                try fileHandle.synchronize()
            } catch {
                appendRecoveryRequired.insert(session.videoID)
                throw StorageError.fileWriteFailed(path: session.framesURL.path,
                    underlying: "Original append failed and rollback was unavailable; retained session requires recovery")
            }
            throw appendError
        }
    }

    /// Persist a stable mapping from database frameID -> WAL frame offset.
    /// This lets OCR load the exact raw payload by frameID, avoiding index drift.
    public func registerFrameID(videoID: VideoSegmentID, frameID: Int64, frameIndex: Int) async throws {
        guard frameIndex >= 0, frameID > 0 else {
            throw StorageError.fileWriteFailed(
                path: "WAL(\(videoID.value))",
                underlying: "Cannot register negative frame index \(frameIndex)"
            )
        }

        let sessionDir = sessionDirectory(videoID: videoID)
        let framesURL = sessionDir.appendingPathComponent("frames.bin")
        let mapURL = sessionDir.appendingPathComponent("frame_id_map.bin")
        let metadata = try loadMetadata(from: sessionDir)
        let session = WALSession(videoID: videoID, sessionDir: sessionDir, framesURL: framesURL, metadata: metadata)
        try validateOriginalSession(session)

        guard FileManager.default.fileExists(atPath: framesURL.path) else {
            throw StorageError.fileNotFound(path: framesURL.path)
        }
        if !FileManager.default.fileExists(atPath: mapURL.path) {
            FileManager.default.createFile(atPath: mapURL.path, contents: nil)
        }

        let currentFramesSize = (try? FileManager.default.attributesOfItem(atPath: framesURL.path)[.size] as? Int64) ?? 0
        guard currentFramesSize > 0 else {
            throw StorageError.fileWriteFailed(path: framesURL.path, underlying: "WAL frames file is empty")
        }

        let frameOffset = try validatedFrameOffset(framesURL: framesURL, matching: .index(frameIndex))

        // Do not suspend between validating the map and appending to it: another
        // registration on this actor must not pass the same stale identity check.
        let checkedMap = try WALRecoveryReader.readFrameIDs(session: session)
        guard checkedMap[frameOffset] == nil || checkedMap[frameOffset] == frameID else {
            throw StorageError.fileWriteFailed(path: mapURL.path, underlying: "Original frame already has a different database identity")
        }
        if let existingOffset = checkedMap.first(where: { $0.value == frameID })?.key {
            guard existingOffset == frameOffset else {
                throw StorageError.fileWriteFailed(path: mapURL.path, underlying: "Conflicting original frame identity")
            }
            return
        }
        let mappingHandle = try FileHandle(forWritingTo: mapURL)
        defer { try? mappingHandle.close() }
        let mapSize = try mappingHandle.seekToEnd()
        if mapSize % UInt64(Self.frameIDMapRecordSize) != 0 {
            try mappingHandle.truncate(atOffset: mapSize - mapSize % UInt64(Self.frameIDMapRecordSize))
            try mappingHandle.synchronize()
        }
        try mappingHandle.close()

        let record = WALFrameIDMapRecord(frameID: frameID, frameOffset: frameOffset)
        try appendFrameIDMapRecord(record, to: mapURL)

        if var cached = frameIDOffsetIndexCache[videoID.value] {
            cached.fileSize += Int64(Self.frameIDMapRecordSize)
            cached.offsetByFrameID[frameID] = frameOffset
            frameIDOffsetIndexCache[videoID.value] = cached
        }
    }

    /// Stop appending while retaining originals for durable extraction and archive acknowledgement.
    public func finalizeSession(_ session: WALSession) async throws {
        defer { liveSessionIDs.remove(session.videoID) }
        guard FileManager.default.fileExists(atPath: session.sessionDir.path) else { return }
        var receipt = try originalReceipt(for: session)
        receipt.sealed = true
        try saveOriginalReceipt(receipt, for: session)
    }

    /// Called only after exact acknowledgements and an exclusive reader lease.
    func removeAcknowledgedSession(_ session: WALSession) throws {
        try validateOriginalSession(session)
        try FileManager.default.removeItem(at: session.sessionDir)
        try OriginalSpoolFiles.synchronizeDirectory(walRootURL)
        frameIDOffsetIndexCache.removeValue(forKey: session.videoID.value)
        liveSessionIDs.remove(session.videoID)
    }

    /// Move a WAL session out of the active recovery path without deleting it.
    /// Reserved for explicit quarantine decisions. Recovery streams large files;
    /// age and size alone must not quarantine recoverable active sessions.
    public func quarantineSession(_ session: WALSession, reason: String) async throws -> URL {
        let quarantineRoot = walRootURL.appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)

        let safeReason = reason
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "-"
            }
            .reduce(into: "") { result, character in
                if !(result.last == "-" && character == "-") {
                    result.append(character)
                }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        let timestamp = Int(Date().timeIntervalSince1970)
        var destination = quarantineRoot.appendingPathComponent(
            "\(session.sessionDir.lastPathComponent)-\(timestamp)-\(safeReason.isEmpty ? "quarantined" : safeReason)",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = quarantineRoot.appendingPathComponent(
                "\(destination.lastPathComponent)-\(UUID().uuidString)",
                isDirectory: true
            )
        }

        try FileManager.default.moveItem(at: session.sessionDir, to: destination)
        liveSessionIDs.remove(session.videoID)
        frameIDOffsetIndexCache.removeValue(forKey: session.videoID.value)
        Log.warning("[WAL] Quarantined WAL session \(session.videoID.value) to \(destination.path) reason=\(reason)", category: .storage)
        _ = try? await pruneQuarantinedSessions()
        return destination
    }

    /// Bound quarantined raw WAL buffers so crash-recovery data cannot become an
    /// untracked second archive. This never touches active WAL sessions or encoded
    /// video chunks.
    public func pruneQuarantinedSessions(
        maxAge: TimeInterval = WALManager.defaultQuarantineMaxAge,
        maxBytes: Int64 = WALManager.defaultQuarantineMaxBytes,
        now: Date = Date()
    ) async throws -> WALQuarantinePruneResult {
        let quarantineRoot = walRootURL.appendingPathComponent("quarantine", isDirectory: true)
        guard FileManager.default.fileExists(atPath: quarantineRoot.path) else {
            return WALQuarantinePruneResult(deletedSessionCount: 0, deletedBytes: 0, remainingBytes: 0)
        }

        var sessions = try quarantinedSessionRecords(in: quarantineRoot)
        guard !sessions.isEmpty else {
            return WALQuarantinePruneResult(deletedSessionCount: 0, deletedBytes: 0, remainingBytes: 0)
        }

        let cutoff = now.addingTimeInterval(-maxAge)
        var deletedSessionCount = 0
        var deletedBytes: Int64 = 0
        var remainingSessions: [QuarantinedWALSessionRecord] = []

        for session in sessions {
            if !session.protectedOriginal && session.referenceDate < cutoff {
                try FileManager.default.removeItem(at: session.url)
                deletedSessionCount += 1
                deletedBytes += session.size
            } else {
                remainingSessions.append(session)
            }
        }

        sessions = remainingSessions.sorted { lhs, rhs in
            if lhs.referenceDate == rhs.referenceDate {
                return lhs.url.lastPathComponent < rhs.url.lastPathComponent
            }
            return lhs.referenceDate < rhs.referenceDate
        }

        var remainingBytes = sessions.reduce(Int64(0)) { $0 + $1.size }
        if maxBytes >= 0 && remainingBytes > maxBytes {
            for session in sessions where !session.protectedOriginal {
                guard remainingBytes > maxBytes else { break }
                try FileManager.default.removeItem(at: session.url)
                deletedSessionCount += 1
                deletedBytes += session.size
                remainingBytes -= session.size
            }
        }

        if deletedSessionCount > 0 {
            Log.warning(
                "[WAL] Pruned \(deletedSessionCount) quarantined WAL sessions, freed \(Self.formatBytes(deletedBytes)), remaining \(Self.formatBytes(max(0, remainingBytes)))",
                category: .storage
            )
        }

        return WALQuarantinePruneResult(
            deletedSessionCount: deletedSessionCount,
            deletedBytes: deletedBytes,
            remainingBytes: max(0, remainingBytes)
        )
    }

    /// Clear ALL WAL sessions (used when changing database location)
    /// WARNING: This deletes unrecovered frame data! Only call when intentionally switching databases.
    public func clearAllSessions() async throws {
        guard FileManager.default.fileExists(atPath: walRootURL.path) else {
            return
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: walRootURL,
            includingPropertiesForKeys: nil
        )

        var clearedCount = 0
        for dir in contents where dir.hasDirectoryPath {
            if dir.lastPathComponent.hasPrefix("active_segment_") {
                try FileManager.default.removeItem(at: dir)
                clearedCount += 1
            }
        }

        if clearedCount > 0 {
            Log.warning("[WAL] Cleared \(clearedCount) WAL sessions (database location changed)", category: .storage)
        }

        frameIDOffsetIndexCache.removeAll()
        liveSessionIDs.removeAll()
    }

    // MARK: - Recovery Operations

    /// Startup recovery only owns sessions left by a previous process. Keep
    /// listActiveSessions inclusive for orphan-video and normal capture bookkeeping.
    public func listRecoverableSessions() async throws -> [WALSession] {
        var result: [WALSession] = []
        for session in try await listActiveSessions() where !liveSessionIDs.contains(session.videoID) {
            // Recovery reports a malformed receipt at the per-session boundary;
            // it must not prevent recovery of unrelated, valid sessions.
            if (try? originalReceipt(for: session).archiveComplete) != true { result.append(session) }
        }
        return result
    }

    /// List all active WAL sessions (for crash recovery)
    public func listActiveSessions() async throws -> [WALSession] {
        guard FileManager.default.fileExists(atPath: walRootURL.path) else {
            return []
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: walRootURL,
            includingPropertiesForKeys: nil
        )

        var sessions: [WALSession] = []
        for dir in contents where dir.hasDirectoryPath {
            // New originals use a prefix older rollback binaries do not recover/delete.
            let dirName = dir.lastPathComponent
            guard dirName.hasPrefix("active_segment_") || dirName.hasPrefix("original_segment_"),
                  let videoIDStr = dirName.split(separator: "_").last,
                  let videoIDValue = Int64(videoIDStr) else {
                continue
            }

            let framesURL = dir.appendingPathComponent("frames.bin")
            guard FileManager.default.fileExists(atPath: framesURL.path) else {
                continue
            }

            // Load metadata
            let metadata: WALMetadata
            do { metadata = try loadMetadata(from: dir) }
            catch {
                Log.warning("[WAL] Retaining session with unavailable metadata: \(videoIDValue)", category: .storage)
                continue
            }

            sessions.append(WALSession(
                videoID: VideoSegmentID(value: videoIDValue),
                sessionDir: dir,
                framesURL: framesURL,
                metadata: metadata
            ))
        }

        return sessions
    }

    /// Read all frames from a WAL session
    public func readFrames(from session: WALSession) async throws -> [CapturedFrame] {
        try await withOriginalReadLease(videoID: session.videoID) {
            try await self.readFramesWithLease(from: session)
        }
    }

    private func readFramesWithLease(from session: WALSession) async throws -> [CapturedFrame] {
        let fileHandle = try FileHandle(forReadingFrom: session.framesURL)
        defer { try? fileHandle.close() }
        let sourceSize = try fileHandle.seekToEnd()
        var offset: UInt64 = 0
        var frames: [CapturedFrame] = []
        while let record = try WALFrameCodec.read(handle: fileHandle, path: session.framesURL.path,
            sourceSize: sourceSize, offset: offset, loadPixels: true) {
            frames.append(record.frame)
            offset = record.nextOffset
        }
        return frames
    }

    /// Reads only an explicitly mapped database frame, validating the immutable capture identity.
    /// `videoID` is the WAL session/path ID, which is distinct from the database video ID.
    public func readExactFrame(videoID: VideoSegmentID, frameID: Int64,
                               expectedTimestamp: Date, expectedWidth: Int, expectedHeight: Int,
                               expectedDisplayID: UInt32) async throws -> CapturedFrame {
        do {
            return try await withOriginalReadLease(videoID: videoID) {
                try await self.readExactFrameWithLease(videoID: videoID, frameID: frameID,
                    expectedTimestamp: expectedTimestamp, expectedWidth: expectedWidth,
                    expectedHeight: expectedHeight, expectedDisplayID: expectedDisplayID)
            }
        } catch is CancellationError {
            throw ExactFrameReadError.cancelled
        }
    }

    private func readExactFrameWithLease(videoID: VideoSegmentID, frameID: Int64,
                               expectedTimestamp: Date, expectedWidth: Int, expectedHeight: Int,
                               expectedDisplayID: UInt32) async throws -> CapturedFrame {
        guard !Task.isCancelled else { throw ExactFrameReadError.cancelled }
        guard videoID.value > 0, frameID > 0, expectedTimestamp.timeIntervalSince1970.isFinite,
              expectedWidth > 0, expectedHeight > 0 else {
            throw ExactFrameReadError.integrityFailure
        }
        let sessionDir = sessionDirectory(videoID: videoID)
        let framesURL = sessionDir.appendingPathComponent("frames.bin")
        guard FileManager.default.fileExists(atPath: framesURL.path) else {
            throw ExactFrameReadError.recordingMissing
        }
        do {
            // Reuse the bounded recovery reader's validated headers, UTF-8, pixel
            // layout, and conflict-checked identity map. No index fallback is allowed.
            let session = WALSession(videoID: videoID, sessionDir: sessionDir, framesURL: framesURL,
                metadata: WALMetadata(videoID: videoID, startTime: expectedTimestamp,
                                      frameCount: 0, width: expectedWidth, height: expectedHeight))
            guard !(try originalReceipt(for: session).deleted.contains { $0.frameID == frameID }) else {
                throw ExactFrameReadError.recordingMissing
            }
            let reader = try WALRecoveryReader(session: session)
            guard let mappedOffset = await reader.frameOffset(for: frameID) else {
                throw ExactFrameReadError.frameFinalising
            }
            // Prove the mapped address is a record boundary. An arbitrary offset
            // into another capture's payload cannot establish frame identity.
            var offset: UInt64 = 0
            var index = 0
            while offset < mappedOffset {
                guard !Task.isCancelled else { throw ExactFrameReadError.cancelled }
                guard let record = try await reader.readRecord(at: offset, index: index, loadPixels: false) else {
                    throw ExactFrameReadError.integrityFailure
                }
                offset = record.nextOffset
                index += 1
            }
            guard offset == mappedOffset,
                  let record = try await reader.readRecord(at: offset, index: index, loadPixels: true),
                  record.databaseFrameID == frameID else {
                throw ExactFrameReadError.integrityFailure
            }
            let frame = record.frame
            guard frame.width == expectedWidth, frame.height == expectedHeight,
                  frame.metadata.displayID == expectedDisplayID,
                  abs(frame.timestamp.timeIntervalSince(expectedTimestamp)) <= 0.001 else {
                throw ExactFrameReadError.integrityFailure
            }
            guard !Task.isCancelled else { throw ExactFrameReadError.cancelled }
            guard FileManager.default.fileExists(atPath: framesURL.path) else {
                throw ExactFrameReadError.recordingMissing
            }
            guard !(try originalReceipt(for: session).deleted.contains { $0.frameID == frameID }) else {
                throw ExactFrameReadError.recordingMissing
            }
            return frame
        } catch let error as ExactFrameReadError {
            throw error
        } catch {
            if Task.isCancelled { throw ExactFrameReadError.cancelled }
            throw ExactFrameReadError.integrityFailure
        }
    }

    /// Read a single frame from an active WAL session by database frame ID.
    /// Falls back to frame index when map entry is missing (e.g. crash before mapping persisted).
    public func readFrame(videoID: VideoSegmentID, frameID: Int64, fallbackFrameIndex: Int) async throws -> CapturedFrame {
        try await withOriginalReadLease(videoID: videoID) {
            try await self.readMappedFrameWithLease(videoID: videoID, frameID: frameID,
                                                    fallbackFrameIndex: fallbackFrameIndex)
        }
    }

    private func readMappedFrameWithLease(videoID: VideoSegmentID, frameID: Int64,
                                          fallbackFrameIndex: Int) async throws -> CapturedFrame {
        let sessionDir = sessionDirectory(videoID: videoID)
        let framesURL = sessionDir.appendingPathComponent("frames.bin")
        let mapURL = sessionDir.appendingPathComponent("frame_id_map.bin")

        guard FileManager.default.fileExists(atPath: framesURL.path) else {
            throw StorageError.fileNotFound(path: framesURL.path)
        }

        if FileManager.default.fileExists(atPath: mapURL.path) {
            let mapFileSize = (try? FileManager.default.attributesOfItem(atPath: mapURL.path)[.size] as? Int64) ?? 0
            if mapFileSize > 0 {
                let offsetByFrameID = try frameIDOffsets(
                    for: videoID.value,
                    mapURL: mapURL,
                    currentFileSize: mapFileSize
                )
                if let mappedOffset = offsetByFrameID[frameID] {
                    let boundary = try validatedFrameOffset(framesURL: framesURL, matching: .offset(mappedOffset))
                    return try readFrame(videoID: videoID, atOffset: boundary)
                }
            }
        }

        return try await readFrame(videoID: videoID, frameIndex: fallbackFrameIndex)
    }

    /// Read a single frame from an active WAL session by capture index.
    /// This avoids loading the entire WAL into memory when OCR needs one frame.
    public func readFrame(videoID: VideoSegmentID, frameIndex: Int) async throws -> CapturedFrame {
        try await withOriginalReadLease(videoID: videoID) {
            try await self.readIndexedFrameWithLease(videoID: videoID, frameIndex: frameIndex)
        }
    }

    private func readIndexedFrameWithLease(videoID: VideoSegmentID, frameIndex: Int) async throws -> CapturedFrame {
        guard frameIndex >= 0 else {
            throw StorageError.fileReadFailed(
                path: "WAL(\(videoID.value))",
                underlying: "Frame index \(frameIndex) is negative"
            )
        }

        let sessionDir = sessionDirectory(videoID: videoID)
        let framesURL = sessionDir.appendingPathComponent("frames.bin")
        guard FileManager.default.fileExists(atPath: framesURL.path) else {
            throw StorageError.fileNotFound(path: framesURL.path)
        }

        let currentFileSize = (try? FileManager.default.attributesOfItem(atPath: framesURL.path)[.size] as? Int64) ?? 0
        if currentFileSize <= 0 {
            throw StorageError.fileReadFailed(path: framesURL.path, underlying: "WAL file is empty")
        }

        let offset = try validatedFrameOffset(framesURL: framesURL, matching: .index(frameIndex))
        return try readFrame(videoID: videoID, atOffset: offset)
    }

    // MARK: - Private Helpers

    private static let frameIDMapRecordSize = MemoryLayout<Int64>.size + MemoryLayout<UInt64>.size

    private func frameIDOffsets(for videoIDValue: Int64, mapURL: URL, currentFileSize: Int64) throws -> [Int64: UInt64] {
        if let cached = frameIDOffsetIndexCache[videoIDValue], cached.fileSize == currentFileSize {
            return cached.offsetByFrameID
        }

        let index = try buildFrameIDOffsetIndex(mapURL: mapURL)
        frameIDOffsetIndexCache[videoIDValue] = WALFrameIDOffsetIndex(
            fileSize: currentFileSize,
            offsetByFrameID: index
        )
        return index
    }

    private func buildFrameIDOffsetIndex(mapURL: URL) throws -> [Int64: UInt64] {
        guard let fileHandle = FileHandle(forReadingAtPath: mapURL.path) else {
            throw StorageError.fileReadFailed(
                path: mapURL.path,
                underlying: "Cannot open WAL frame map for indexing"
            )
        }
        defer { try? fileHandle.close() }

        var offsetByFrameID: [Int64: UInt64] = [:]
        var frameIDByOffset: [UInt64: Int64] = [:]

        while true {
            guard let recordData = try? fileHandle.read(upToCount: Self.frameIDMapRecordSize), !recordData.isEmpty else {
                break
            }
            // A crash may interrupt the final mapping append; retain its proved prefix.
            guard recordData.count == Self.frameIDMapRecordSize else { break }

            let record = try parseFrameIDMapRecord(recordData, path: mapURL.path)
            guard record.frameID > 0,
                  offsetByFrameID[record.frameID] == nil || offsetByFrameID[record.frameID] == record.frameOffset,
                  frameIDByOffset[record.frameOffset] == nil || frameIDByOffset[record.frameOffset] == record.frameID else {
                throw StorageError.fileReadFailed(path: mapURL.path, underlying: "Conflicting original frame identity map")
            }
            offsetByFrameID[record.frameID] = record.frameOffset
            frameIDByOffset[record.frameOffset] = record.frameID
        }

        return offsetByFrameID
    }

    private func appendFrameIDMapRecord(_ record: WALFrameIDMapRecord, to mapURL: URL) throws {
        guard let fileHandle = FileHandle(forWritingAtPath: mapURL.path) else {
            throw StorageError.fileWriteFailed(
                path: mapURL.path,
                underlying: "Cannot open frame map for appending"
            )
        }
        defer { try? fileHandle.close() }

        if #available(macOS 10.15.4, *) {
            try fileHandle.seekToEnd()
        } else {
            fileHandle.seekToEndOfFile()
        }

        var data = Data()
        var frameID = record.frameID
        var frameOffset = record.frameOffset
        withUnsafeBytes(of: &frameID) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &frameOffset) { data.append(contentsOf: $0) }

        if #available(macOS 10.15.4, *) {
            try fileHandle.write(contentsOf: data)
        } else {
            fileHandle.write(data)
        }
        try fileHandle.synchronize()
    }

    /// Prove every preceding boundary and the requested complete record, then
    /// stop. A damaged later tail must not block recovery/OCR of a valid prefix.
    /// No same-size offset cache substitutes for this current integrity check.
    private func validatedFrameOffset(framesURL: URL, matching requested: WALFrameLocation) throws -> UInt64 {
        let fileHandle = try FileHandle(forReadingFrom: framesURL)
        defer { try? fileHandle.close() }
        let sourceSize = try fileHandle.seekToEnd()
        var offset: UInt64 = 0
        var index = 0
        while let record = try WALFrameCodec.read(handle: fileHandle, path: framesURL.path,
            sourceSize: sourceSize, offset: offset, loadPixels: false) {
            switch requested {
            case .index(let target):
                if index == target { return offset }
            case .offset(let target):
                if offset == target { return offset }
                guard record.nextOffset <= target else {
                    throw StorageError.fileReadFailed(path: framesURL.path,
                        underlying: "Mapped original offset is not a record boundary")
                }
            }
            offset = record.nextOffset
            index += 1
        }
        throw StorageError.fileReadFailed(path: framesURL.path, underlying: "Requested original record is absent")
    }

    private func readFrame(videoID: VideoSegmentID, atOffset frameOffset: UInt64) throws -> CapturedFrame {
        let sessionDir = sessionDirectory(videoID: videoID)
        let framesURL = sessionDir.appendingPathComponent("frames.bin")
        let fileHandle = try FileHandle(forReadingFrom: framesURL)
        defer { try? fileHandle.close() }
        let sourceSize = try fileHandle.seekToEnd()
        guard let record = try WALFrameCodec.read(handle: fileHandle, path: framesURL.path,
            sourceSize: sourceSize, offset: frameOffset, loadPixels: true) else {
            throw StorageError.fileReadFailed(path: framesURL.path, underlying: "Original frame offset is at end of file")
        }
        return record.frame
    }

    private func quarantinedSessionRecords(in quarantineRoot: URL) throws -> [QuarantinedWALSessionRecord] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: quarantineRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        )

        var records: [QuarantinedWALSessionRecord] = []
        for url in contents {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values.isDirectory == true else { continue }

            let size = try directorySize(at: url)
            let metadataStart = try? loadMetadata(from: url).startTime
            let referenceDate = metadataStart ?? values.contentModificationDate ?? Date.distantPast
            let protectedOriginal = url.lastPathComponent.hasPrefix("original_segment_")
                || FileManager.default.fileExists(atPath: url.appendingPathComponent("original-retention.json").path)
            records.append(QuarantinedWALSessionRecord(url: url, size: size, referenceDate: referenceDate,
                                                       protectedOriginal: protectedOriginal))
        }

        return records
    }

    private func directorySize(at root: URL) throws -> Int64 {
        let sizeKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(sizeKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: sizeKeys)
            guard values.isDirectory != true else { continue }

            let byteCount = values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0
            total += Int64(byteCount)
        }

        return total
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(0, bytes))
    }

    private func saveMetadata(_ metadata: WALMetadata, to dir: URL) throws {
        let metadataURL = dir.appendingPathComponent("metadata.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
        try OriginalSpoolFiles.synchronizeFileAndParent(metadataURL)
    }

    private func boundedMetadataBytes(from directory: URL) throws -> Data {
        let url = directory.appendingPathComponent("metadata.json")
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let bytes = try handle.read(upToCount: WALFrameCodec.maximumMetadataBytes + 1),
              !bytes.isEmpty, bytes.count <= WALFrameCodec.maximumMetadataBytes else {
            throw StorageError.fileReadFailed(path: url.path, underlying: "Invalid bounded WAL metadata")
        }
        return bytes
    }

    private func loadMetadata(from dir: URL) throws -> WALMetadata {
        let metadataURL = dir.appendingPathComponent("metadata.json")
        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WALMetadata.self, from: data)
    }

    private func parseFrameIDMapRecord(_ data: Data, path: String) throws -> WALFrameIDMapRecord {
        guard data.count == Self.frameIDMapRecordSize else {
            throw StorageError.fileReadFailed(
                path: path,
                underlying: "Invalid frame map record size \(data.count)"
            )
        }

        let frameID = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int64.self) }
        let frameOffset = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: MemoryLayout<Int64>.size, as: UInt64.self) }
        return WALFrameIDMapRecord(frameID: frameID, frameOffset: frameOffset)
    }
}

// MARK: - Models

/// WAL session representing an active segment being recorded
public struct WALSession: Sendable {
    public let videoID: VideoSegmentID
    public let sessionDir: URL
    public let framesURL: URL
    public var metadata: WALMetadata

    public init(videoID: VideoSegmentID, sessionDir: URL, framesURL: URL, metadata: WALMetadata) {
        self.videoID = videoID
        self.sessionDir = sessionDir
        self.framesURL = framesURL
        self.metadata = metadata
    }
}

/// Metadata for a WAL session
public struct WALMetadata: Codable, Sendable {
    public let videoID: VideoSegmentID
    public let startTime: Date
    public var frameCount: Int
    public var width: Int
    public var height: Int

    public init(videoID: VideoSegmentID, startTime: Date, frameCount: Int, width: Int, height: Int) {
        self.videoID = videoID
        self.startTime = startTime
        self.frameCount = frameCount
        self.width = width
        self.height = height
    }
}

private enum WALFrameLocation {
    case index(Int)
    case offset(UInt64)
}

private struct WALFrameIDOffsetIndex {
    var fileSize: Int64
    var offsetByFrameID: [Int64: UInt64]
}

private struct WALFrameIDMapRecord {
    let frameID: Int64
    let frameOffset: UInt64
}

private struct QuarantinedWALSessionRecord {
    let url: URL
    let size: Int64
    let referenceDate: Date
    let protectedOriginal: Bool
}

public struct WALQuarantinePruneResult: Sendable, Equatable {
    public let deletedSessionCount: Int
    public let deletedBytes: Int64
    public let remainingBytes: Int64

    public init(deletedSessionCount: Int, deletedBytes: Int64, remainingBytes: Int64) {
        self.deletedSessionCount = deletedSessionCount
        self.deletedBytes = deletedBytes
        self.remainingBytes = remainingBytes
    }
}
