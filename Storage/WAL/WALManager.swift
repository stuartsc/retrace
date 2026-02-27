import Foundation
import Shared

/// Write-Ahead Log Manager for crash-safe frame persistence
///
/// Writes raw captured frames to disk before video encoding, ensuring:
/// - No data loss on crash/termination
/// - Fast sequential writes (raw BGRA pixels)
/// - Recovery on app restart
///
/// Directory structure:
/// {AppPaths.storageRoot}/wal/
///   └── active_segment_{videoID}/
///       ├── frames.bin      # Binary: [FrameHeader|PixelData][FrameHeader|PixelData]...
///       └── metadata.json   # Segment metadata (videoID, startTime, frameCount)
public actor WALManager {
    private let walRootURL: URL
    private var frameOffsetIndexCache: [Int64: WALFrameOffsetIndex] = [:]
    private var frameIDOffsetIndexCache: [Int64: WALFrameIDOffsetIndex] = [:]

    public init(walRoot: URL) {
        self.walRootURL = walRoot
    }

    public func initialize() async throws {
        // Create WAL root directory if needed
        if !FileManager.default.fileExists(atPath: walRootURL.path) {
            try FileManager.default.createDirectory(
                at: walRootURL,
                withIntermediateDirectories: true
            )
        }
    }

    // MARK: - Write Operations

    /// Create a new WAL session for a video segment
    public func createSession(videoID: VideoSegmentID) async throws -> WALSession {
        let sessionDir = walRootURL.appendingPathComponent("active_segment_\(videoID.value)")

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

        return WALSession(
            videoID: videoID,
            sessionDir: sessionDir,
            framesURL: framesURL,
            metadata: metadata
        )
    }

    /// Append a frame to the WAL
    public func appendFrame(_ frame: CapturedFrame, to session: inout WALSession) async throws {
        // Open file handle for appending
        guard let fileHandle = FileHandle(forWritingAtPath: session.framesURL.path) else {
            throw StorageError.fileWriteFailed(
                path: session.framesURL.path,
                underlying: "Cannot open file for appending"
            )
        }
        defer { try? fileHandle.close() }

        // Seek to end
        if #available(macOS 10.15.4, *) {
            try fileHandle.seekToEnd()
        } else {
            fileHandle.seekToEndOfFile()
        }

        // Write frame header + pixel data
        let header = WALFrameHeader(
            timestamp: frame.timestamp.timeIntervalSince1970,
            width: UInt32(frame.width),
            height: UInt32(frame.height),
            bytesPerRow: UInt32(frame.bytesPerRow),
            dataSize: UInt32(frame.imageData.count),
            displayID: frame.metadata.displayID,
            appBundleIDLength: UInt16(frame.metadata.appBundleID?.utf8.count ?? 0),
            appNameLength: UInt16(frame.metadata.appName?.utf8.count ?? 0),
            windowNameLength: UInt16(frame.metadata.windowName?.utf8.count ?? 0),
            browserURLLength: UInt16(frame.metadata.browserURL?.utf8.count ?? 0)
        )

        // Write header
        var headerData = Data()
        withUnsafeBytes(of: header.timestamp) { headerData.append(contentsOf: $0) }
        withUnsafeBytes(of: header.width) { headerData.append(contentsOf: $0) }
        withUnsafeBytes(of: header.height) { headerData.append(contentsOf: $0) }
        withUnsafeBytes(of: header.bytesPerRow) { headerData.append(contentsOf: $0) }
        withUnsafeBytes(of: header.dataSize) { headerData.append(contentsOf: $0) }
        withUnsafeBytes(of: header.displayID) { headerData.append(contentsOf: $0) }
        withUnsafeBytes(of: header.appBundleIDLength) { headerData.append(contentsOf: $0) }
        withUnsafeBytes(of: header.appNameLength) { headerData.append(contentsOf: $0) }
        withUnsafeBytes(of: header.windowNameLength) { headerData.append(contentsOf: $0) }
        withUnsafeBytes(of: header.browserURLLength) { headerData.append(contentsOf: $0) }

        if #available(macOS 10.15.4, *) {
            try fileHandle.write(contentsOf: headerData)
        } else {
            fileHandle.write(headerData)
        }

        // Write metadata strings
        if let appBundleID = frame.metadata.appBundleID?.data(using: .utf8) {
            if #available(macOS 10.15.4, *) {
                try fileHandle.write(contentsOf: appBundleID)
            } else {
                fileHandle.write(appBundleID)
            }
        }
        if let appName = frame.metadata.appName?.data(using: .utf8) {
            if #available(macOS 10.15.4, *) {
                try fileHandle.write(contentsOf: appName)
            } else {
                fileHandle.write(appName)
            }
        }
        if let windowName = frame.metadata.windowName?.data(using: .utf8) {
            if #available(macOS 10.15.4, *) {
                try fileHandle.write(contentsOf: windowName)
            } else {
                fileHandle.write(windowName)
            }
        }
        if let browserURL = frame.metadata.browserURL?.data(using: .utf8) {
            if #available(macOS 10.15.4, *) {
                try fileHandle.write(contentsOf: browserURL)
            } else {
                fileHandle.write(browserURL)
            }
        }

        // Write pixel data
        if #available(macOS 10.15.4, *) {
            try fileHandle.write(contentsOf: frame.imageData)
        } else {
            fileHandle.write(frame.imageData)
        }

        // Update session metadata
        session.metadata.frameCount += 1
        if session.metadata.width == 0 {
            session.metadata.width = frame.width
            session.metadata.height = frame.height
        }

        try saveMetadata(session.metadata, to: session.sessionDir)

        // Invalidate frame offset index cache so the next random-access read
        // can rebuild with the newly appended frame.
        frameOffsetIndexCache.removeValue(forKey: session.videoID.value)
    }

    /// Persist a stable mapping from database frameID -> WAL frame offset.
    /// This lets OCR load the exact raw payload by frameID, avoiding index drift.
    public func registerFrameID(videoID: VideoSegmentID, frameID: Int64, frameIndex: Int) async throws {
        guard frameIndex >= 0 else {
            throw StorageError.fileWriteFailed(
                path: "WAL(\(videoID.value))",
                underlying: "Cannot register negative frame index \(frameIndex)"
            )
        }

        let sessionDir = walRootURL.appendingPathComponent("active_segment_\(videoID.value)")
        let framesURL = sessionDir.appendingPathComponent("frames.bin")
        let mapURL = sessionDir.appendingPathComponent("frame_id_map.bin")

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

        let offsets = try frameOffsets(
            for: videoID.value,
            framesURL: framesURL,
            currentFileSize: currentFramesSize
        )
        guard frameIndex < offsets.count else {
            throw StorageError.fileWriteFailed(
                path: framesURL.path,
                underlying: "Cannot register frameID \(frameID): frameIndex \(frameIndex) out of range (0..<\(offsets.count))"
            )
        }

        let record = WALFrameIDMapRecord(frameID: frameID, frameOffset: offsets[frameIndex])
        try appendFrameIDMapRecord(record, to: mapURL)

        if var cached = frameIDOffsetIndexCache[videoID.value] {
            cached.fileSize += Int64(Self.frameIDMapRecordSize)
            cached.offsetByFrameID[frameID] = offsets[frameIndex]
            frameIDOffsetIndexCache[videoID.value] = cached
        }
    }

    /// Finalize a WAL session (after successful video encoding)
    public func finalizeSession(_ session: WALSession) async throws {
        // Delete the WAL directory - video is now safely encoded
        // Use try? to handle case where directory was already deleted (e.g., double-finalize)
        if FileManager.default.fileExists(atPath: session.sessionDir.path) {
            try FileManager.default.removeItem(at: session.sessionDir)
        }
        frameOffsetIndexCache.removeValue(forKey: session.videoID.value)
        frameIDOffsetIndexCache.removeValue(forKey: session.videoID.value)
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

        frameOffsetIndexCache.removeAll()
        frameIDOffsetIndexCache.removeAll()
    }

    // MARK: - Recovery Operations

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
            // Parse videoID from directory name: "active_segment_{videoID}"
            let dirName = dir.lastPathComponent
            guard dirName.hasPrefix("active_segment_"),
                  let videoIDStr = dirName.split(separator: "_").last,
                  let videoIDValue = Int64(videoIDStr) else {
                continue
            }

            let framesURL = dir.appendingPathComponent("frames.bin")
            guard FileManager.default.fileExists(atPath: framesURL.path) else {
                continue
            }

            // Load metadata
            let metadata = try loadMetadata(from: dir)

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
        guard let fileHandle = FileHandle(forReadingAtPath: session.framesURL.path) else {
            throw StorageError.fileReadFailed(
                path: session.framesURL.path,
                underlying: "Cannot open file for reading"
            )
        }
        defer { try? fileHandle.close() }

        var frames: [CapturedFrame] = []

        while true {
            // Read header: 8+4+4+4+4+4+2+2+2+2 = 36 bytes
            let headerSize = 36
            guard let headerData = try? fileHandle.read(upToCount: headerSize),
                  headerData.count == headerSize else {
                break // End of file
            }

            let header = try parseFrameHeader(from: headerData)

            // Read metadata strings
            let appBundleID = try header.appBundleIDLength > 0
                ? String(data: fileHandle.read(upToCount: Int(header.appBundleIDLength))!, encoding: .utf8)
                : nil
            let appName = try header.appNameLength > 0
                ? String(data: fileHandle.read(upToCount: Int(header.appNameLength))!, encoding: .utf8)
                : nil
            let windowName = try header.windowNameLength > 0
                ? String(data: fileHandle.read(upToCount: Int(header.windowNameLength))!, encoding: .utf8)
                : nil
            let browserURL = try header.browserURLLength > 0
                ? String(data: fileHandle.read(upToCount: Int(header.browserURLLength))!, encoding: .utf8)
                : nil

            // Read pixel data
            guard let pixelData = try? fileHandle.read(upToCount: Int(header.dataSize)),
                  pixelData.count == Int(header.dataSize) else {
                throw StorageError.fileReadFailed(
                    path: session.framesURL.path,
                    underlying: "Incomplete frame data"
                )
            }

            let frame = CapturedFrame(
                timestamp: Date(timeIntervalSince1970: header.timestamp),
                imageData: pixelData,
                width: Int(header.width),
                height: Int(header.height),
                bytesPerRow: Int(header.bytesPerRow),
                metadata: FrameMetadata(
                    appBundleID: appBundleID,
                    appName: appName,
                    windowName: windowName,
                    browserURL: browserURL,
                    displayID: header.displayID
                )
            )

            frames.append(frame)
        }

        return frames
    }

    /// Read a single frame from an active WAL session by database frame ID.
    /// Falls back to frame index when map entry is missing (e.g. crash before mapping persisted).
    public func readFrame(videoID: VideoSegmentID, frameID: Int64, fallbackFrameIndex: Int) async throws -> CapturedFrame {
        let sessionDir = walRootURL.appendingPathComponent("active_segment_\(videoID.value)")
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
                    return try readFrame(videoID: videoID, atOffset: mappedOffset)
                }
            }
        }

        return try await readFrame(videoID: videoID, frameIndex: fallbackFrameIndex)
    }

    /// Read a single frame from an active WAL session by capture index.
    /// This avoids loading the entire WAL into memory when OCR needs one frame.
    public func readFrame(videoID: VideoSegmentID, frameIndex: Int) async throws -> CapturedFrame {
        guard frameIndex >= 0 else {
            throw StorageError.fileReadFailed(
                path: "WAL(\(videoID.value))",
                underlying: "Frame index \(frameIndex) is negative"
            )
        }

        let sessionDir = walRootURL.appendingPathComponent("active_segment_\(videoID.value)")
        let framesURL = sessionDir.appendingPathComponent("frames.bin")
        guard FileManager.default.fileExists(atPath: framesURL.path) else {
            throw StorageError.fileNotFound(path: framesURL.path)
        }

        let currentFileSize = (try? FileManager.default.attributesOfItem(atPath: framesURL.path)[.size] as? Int64) ?? 0
        if currentFileSize <= 0 {
            throw StorageError.fileReadFailed(path: framesURL.path, underlying: "WAL file is empty")
        }

        let offsets = try frameOffsets(
            for: videoID.value,
            framesURL: framesURL,
            currentFileSize: currentFileSize
        )
        guard frameIndex < offsets.count else {
            throw StorageError.fileReadFailed(
                path: framesURL.path,
                underlying: "Frame index \(frameIndex) out of range (0..<\(offsets.count))"
            )
        }

        return try readFrame(videoID: videoID, atOffset: offsets[frameIndex])
    }

    // MARK: - Private Helpers

    private static let headerSize = 36
    private static let frameIDMapRecordSize = MemoryLayout<Int64>.size + MemoryLayout<UInt64>.size

    private func frameOffsets(for videoIDValue: Int64, framesURL: URL, currentFileSize: Int64) throws -> [UInt64] {
        if let cached = frameOffsetIndexCache[videoIDValue], cached.fileSize == currentFileSize {
            return cached.offsets
        }

        let offsets = try buildFrameOffsetIndex(framesURL: framesURL)
        frameOffsetIndexCache[videoIDValue] = WALFrameOffsetIndex(fileSize: currentFileSize, offsets: offsets)
        return offsets
    }

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

        while true {
            guard let recordData = try? fileHandle.read(upToCount: Self.frameIDMapRecordSize), !recordData.isEmpty else {
                break
            }
            guard recordData.count == Self.frameIDMapRecordSize else {
                throw StorageError.fileReadFailed(
                    path: mapURL.path,
                    underlying: "Incomplete frame map record (got \(recordData.count) bytes)"
                )
            }

            let record = try parseFrameIDMapRecord(recordData, path: mapURL.path)
            offsetByFrameID[record.frameID] = record.frameOffset
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
    }

    private func buildFrameOffsetIndex(framesURL: URL) throws -> [UInt64] {
        guard let fileHandle = FileHandle(forReadingAtPath: framesURL.path) else {
            throw StorageError.fileReadFailed(
                path: framesURL.path,
                underlying: "Cannot open WAL for indexing"
            )
        }
        defer { try? fileHandle.close() }

        var offsets: [UInt64] = []

        while true {
            let frameOffset = currentOffset(fileHandle: fileHandle)
            guard let headerData = try? fileHandle.read(upToCount: Self.headerSize), !headerData.isEmpty else {
                break
            }
            guard headerData.count == Self.headerSize else {
                throw StorageError.fileReadFailed(
                    path: framesURL.path,
                    underlying: "Incomplete frame header while indexing (got \(headerData.count) bytes)"
                )
            }

            offsets.append(frameOffset)
            let header = try parseFrameHeader(from: headerData)

            let metadataBytes = Int(header.appBundleIDLength)
                + Int(header.appNameLength)
                + Int(header.windowNameLength)
                + Int(header.browserURLLength)
            let payloadBytes = metadataBytes + Int(header.dataSize)
            let nextOffset = frameOffset + UInt64(Self.headerSize + payloadBytes)
            try seek(fileHandle: fileHandle, toOffset: nextOffset)
        }

        return offsets
    }

    private func readFrame(videoID: VideoSegmentID, atOffset frameOffset: UInt64) throws -> CapturedFrame {
        let sessionDir = walRootURL.appendingPathComponent("active_segment_\(videoID.value)")
        let framesURL = sessionDir.appendingPathComponent("frames.bin")
        guard let fileHandle = FileHandle(forReadingAtPath: framesURL.path) else {
            throw StorageError.fileReadFailed(
                path: framesURL.path,
                underlying: "Cannot open WAL for reading"
            )
        }
        defer { try? fileHandle.close() }

        try seek(fileHandle: fileHandle, toOffset: frameOffset)

        let headerData = try readExact(
            fileHandle: fileHandle,
            count: Self.headerSize,
            path: framesURL.path,
            label: "frame header at offset \(frameOffset)"
        )
        let header = try parseFrameHeader(from: headerData)

        let appBundleID = try readOptionalString(
            fileHandle: fileHandle,
            length: Int(header.appBundleIDLength),
            path: framesURL.path,
            label: "appBundleID"
        )
        let appName = try readOptionalString(
            fileHandle: fileHandle,
            length: Int(header.appNameLength),
            path: framesURL.path,
            label: "appName"
        )
        let windowName = try readOptionalString(
            fileHandle: fileHandle,
            length: Int(header.windowNameLength),
            path: framesURL.path,
            label: "windowName"
        )
        let browserURL = try readOptionalString(
            fileHandle: fileHandle,
            length: Int(header.browserURLLength),
            path: framesURL.path,
            label: "browserURL"
        )

        let pixelData = try readExact(
            fileHandle: fileHandle,
            count: Int(header.dataSize),
            path: framesURL.path,
            label: "pixel data at offset \(frameOffset)"
        )

        return CapturedFrame(
            timestamp: Date(timeIntervalSince1970: header.timestamp),
            imageData: pixelData,
            width: Int(header.width),
            height: Int(header.height),
            bytesPerRow: Int(header.bytesPerRow),
            metadata: FrameMetadata(
                appBundleID: appBundleID,
                appName: appName,
                windowName: windowName,
                browserURL: browserURL,
                displayID: header.displayID
            )
        )
    }

    private func currentOffset(fileHandle: FileHandle) -> UInt64 {
        if #available(macOS 10.15.4, *) {
            return (try? fileHandle.offset()) ?? 0
        } else {
            return fileHandle.offsetInFile
        }
    }

    private func seek(fileHandle: FileHandle, toOffset: UInt64) throws {
        if #available(macOS 10.15.4, *) {
            try fileHandle.seek(toOffset: toOffset)
        } else {
            fileHandle.seek(toFileOffset: toOffset)
        }
    }

    private func readExact(fileHandle: FileHandle, count: Int, path: String, label: String) throws -> Data {
        guard count >= 0 else {
            throw StorageError.fileReadFailed(path: path, underlying: "Invalid read size \(count) for \(label)")
        }
        if count == 0 {
            return Data()
        }

        guard let data = try? fileHandle.read(upToCount: count), data.count == count else {
            throw StorageError.fileReadFailed(
                path: path,
                underlying: "Incomplete \(label): expected \(count) bytes"
            )
        }
        return data
    }

    private func readOptionalString(
        fileHandle: FileHandle,
        length: Int,
        path: String,
        label: String
    ) throws -> String? {
        if length == 0 {
            return nil
        }

        let data = try readExact(fileHandle: fileHandle, count: length, path: path, label: label)
        return String(data: data, encoding: .utf8)
    }

    private func saveMetadata(_ metadata: WALMetadata, to dir: URL) throws {
        let metadataURL = dir.appendingPathComponent("metadata.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL)
    }

    private func loadMetadata(from dir: URL) throws -> WALMetadata {
        let metadataURL = dir.appendingPathComponent("metadata.json")
        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WALMetadata.self, from: data)
    }

    private func parseFrameHeader(from data: Data) throws -> WALFrameHeader {
        // Header size: 8+4+4+4+4+4+2+2+2+2 = 36 bytes
        let expectedHeaderSize = 36
        guard data.count >= expectedHeaderSize else {
            throw StorageError.fileReadFailed(
                path: "WAL header",
                underlying: "Incomplete header: expected \(expectedHeaderSize) bytes, got \(data.count)"
            )
        }

        var offset = 0

        func read<T>(_ type: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            // Bounds check to prevent crash on corrupted data
            guard offset + size <= data.count else {
                throw StorageError.fileReadFailed(
                    path: "WAL header",
                    underlying: "Out of bounds read at offset \(offset) for \(size) bytes (data size: \(data.count))"
                )
            }
            let value = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: type) }
            offset += size
            return value
        }

        return WALFrameHeader(
            timestamp: try read(Double.self),
            width: try read(UInt32.self),
            height: try read(UInt32.self),
            bytesPerRow: try read(UInt32.self),
            dataSize: try read(UInt32.self),
            displayID: try read(UInt32.self),
            appBundleIDLength: try read(UInt16.self),
            appNameLength: try read(UInt16.self),
            windowNameLength: try read(UInt16.self),
            browserURLLength: try read(UInt16.self)
        )
    }

    private func parseFrameIDMapRecord(_ data: Data, path: String) throws -> WALFrameIDMapRecord {
        guard data.count == Self.frameIDMapRecordSize else {
            throw StorageError.fileReadFailed(
                path: path,
                underlying: "Invalid frame map record size \(data.count)"
            )
        }

        let frameID = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Int64.self) }
        let frameOffset = data.withUnsafeBytes { $0.load(fromByteOffset: MemoryLayout<Int64>.size, as: UInt64.self) }
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

/// Frame header in WAL binary format (36 bytes fixed size + variable metadata strings)
private struct WALFrameHeader {
    let timestamp: Double           // 8 bytes - Unix timestamp
    let width: UInt32              // 4 bytes
    let height: UInt32             // 4 bytes
    let bytesPerRow: UInt32        // 4 bytes
    let dataSize: UInt32           // 4 bytes - pixel data size
    let displayID: UInt32          // 4 bytes
    let appBundleIDLength: UInt16  // 2 bytes
    let appNameLength: UInt16      // 2 bytes
    let windowNameLength: UInt16   // 2 bytes
    let browserURLLength: UInt16   // 2 bytes
    // Total: 36 bytes (8+20+8)
    // Followed by: appBundleID, appName, windowName, browserURL (UTF-8 strings)
    // Followed by: pixel data (dataSize bytes)
}

private struct WALFrameOffsetIndex {
    let fileSize: Int64
    let offsets: [UInt64]
}

private struct WALFrameIDOffsetIndex {
    var fileSize: Int64
    var offsetByFrameID: [Int64: UInt64]
}

private struct WALFrameIDMapRecord {
    let frameID: Int64
    let frameOffset: UInt64
}
