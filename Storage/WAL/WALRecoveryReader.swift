import Foundation
import Shared

/// Reads one validated WAL record at a time. Header scanning skips pixel payloads;
/// encoding allocates only the current frame, regardless of the WAL file's size.
actor WALRecoveryReader {
    // Supports an 8K BGRA frame, with a hard bound against corrupt allocation sizes.
    static let maximumFrameBytes: UInt64 = 256 * 1024 * 1024
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
        guard offset < sourceSize else { return nil }
        guard sourceSize - offset >= 36 else { throw failure("Truncated frame header at \(offset)") }
        try handle.seek(toOffset: offset)
        let header = try readExact(36)
        let timestamp: Double = value(header, at: 0)
        let width: UInt32 = value(header, at: 8)
        let height: UInt32 = value(header, at: 12)
        let bytesPerRow: UInt32 = value(header, at: 16)
        let dataSize: UInt32 = value(header, at: 20)
        let displayID: UInt32 = value(header, at: 24)
        let lengths: [UInt16] = [28, 30, 32, 34].map { value(header, at: $0) }
        guard timestamp.isFinite, width > 0, height > 0,
              UInt64(bytesPerRow) >= UInt64(width) * 4,
              UInt64(dataSize) == UInt64(bytesPerRow) * UInt64(height),
              UInt64(dataSize) <= Self.maximumFrameBytes else {
            throw failure("Invalid BGRA frame dimensions/payload at \(offset)")
        }
        let metadataBytes = lengths.reduce(UInt64(0)) { $0 + UInt64($1) }
        let recordBytes = UInt64(36) + metadataBytes + UInt64(dataSize)
        guard recordBytes <= sourceSize - offset else { throw failure("Truncated frame payload at \(offset)") }
        let strings: [String?] = try lengths.map { length in
            guard length > 0 else { return nil }
            guard let string = String(data: try readExact(Int(length)), encoding: .utf8) else {
                throw failure("Invalid UTF-8 frame metadata at \(offset)")
            }
            return string
        }
        let pixels = loadPixels ? try readExact(Int(dataSize)) : Data()
        let frame = CapturedFrame(timestamp: Date(timeIntervalSince1970: timestamp), imageData: pixels,
                                  width: Int(width), height: Int(height), bytesPerRow: Int(bytesPerRow),
                                  metadata: FrameMetadata(appBundleID: strings[0], appName: strings[1],
                                                          windowName: strings[2], browserURL: strings[3],
                                                          displayID: displayID))
        return WALRecoveryRecord(frame: frame, index: index, offset: offset,
                                 nextOffset: offset + recordBytes, databaseFrameID: frameIDsByOffset[offset])
    }

    func sourceIsUnchanged() throws -> Bool {
        let size = try FileManager.default.attributesOfItem(atPath: session.framesURL.path)[.size] as? NSNumber
        return size?.uint64Value == sourceSize
    }

    private func readExact(_ count: Int) throws -> Data {
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw failure("Incomplete read of \(count) bytes")
        }
        return data
    }

    private func value<T>(_ data: Data, at offset: Int) -> T {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }

    private func failure(_ detail: String) -> StorageError {
        .fileReadFailed(path: session.framesURL.path, underlying: detail)
    }

    private static func readFrameIDs(session: WALSession) throws -> [UInt64: Int64] {
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
