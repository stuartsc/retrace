import Foundation
import Shared

/// Reads one validated WAL record at a time. Header scanning skips pixel payloads;
/// encoding allocates only the current frame, regardless of the WAL file's size.
actor WALRecoveryReader {
    // Supports an 8K BGRA frame, with a hard bound against corrupt allocation sizes.
    static let maximumFrameBytes = WALFrameCodec.maximumFrameBytes
    private let session: WALSession
    private let handle: FileHandle
    private let sourceSize: UInt64
    private let frameIDsByOffset: [UInt64: Int64]

    init(session: WALSession) throws {
        self.session = session
        self.handle = try FileHandle(forReadingFrom: session.framesURL)
        self.sourceSize = try handle.seekToEnd()
        self.frameIDsByOffset = try Self.readFrameIDs(session: session)
    }

    deinit { try? handle.close() }

    /// A conflict-checked persisted mapping; callers must still prove its record boundary.
    func frameOffset(for frameID: Int64) -> UInt64? {
        frameIDsByOffset.first(where: { $0.value == frameID })?.key
    }

    func scan() throws -> WALRecoveryScan {
        var offset: UInt64 = 0
        var count = 0
        while offset < sourceSize {
            do {
                guard let record = try readRecord(at: offset, index: count, loadPixels: false) else { break }
                offset = record.nextOffset
                count += 1
            } catch {
                return WALRecoveryScan(frameCount: count, completeBytes: offset, sourceSize: sourceSize,
                                       tailError: String(describing: error))
            }
        }
        return WALRecoveryScan(frameCount: count, completeBytes: offset, sourceSize: sourceSize, tailError: nil)
    }

    func readRecord(at offset: UInt64, index: Int, loadPixels: Bool) throws -> WALRecoveryRecord? {
        guard let record = try WALFrameCodec.read(handle: handle, path: session.framesURL.path,
            sourceSize: sourceSize, offset: offset, loadPixels: loadPixels) else { return nil }
        return WALRecoveryRecord(frame: record.frame, index: index, offset: offset,
                                 nextOffset: record.nextOffset, databaseFrameID: frameIDsByOffset[offset])
    }

    func sourceIsUnchanged() throws -> Bool {
        let size = try FileManager.default.attributesOfItem(atPath: session.framesURL.path)[.size] as? NSNumber
        return size?.uint64Value == sourceSize
    }

    static func readFrameIDs(session: WALSession) throws -> [UInt64: Int64] {
        let path = session.sessionDir.appendingPathComponent("frame_id_map.bin")
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        var byOffset: [UInt64: Int64] = [:]
        var byID: [Int64: UInt64] = [:]
        while let data = try handle.read(upToCount: 16), !data.isEmpty {
            // A crash may interrupt the last append. Keep earlier durable mappings.
            guard data.count == 16 else { break }
            let id = data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
            let offset = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
            guard id > 0, byOffset[offset] == nil || byOffset[offset] == id,
                  byID[id] == nil || byID[id] == offset else {
                throw StorageError.fileReadFailed(path: path.path, underlying: "Conflicting WAL frame identity map")
            }
            byOffset[offset] = id
            byID[id] = offset
        }
        return byOffset
    }
}

struct WALRecoveryScan: Sendable {
    let frameCount: Int
    let completeBytes: UInt64
    let sourceSize: UInt64
    let tailError: String?
}

struct WALRecoveryRecord: Sendable {
    let frame: CapturedFrame
    let index: Int
    let offset: UInt64
    let nextOffset: UInt64
    let databaseFrameID: Int64?
}
