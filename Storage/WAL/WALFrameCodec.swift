import Compression
import CryptoKit
import Foundation
import Shared

/// One bounded record codec for capture, recovery, indexing and exact reads.
/// V1 has its original 36-byte header. V2 starts with a reserved NaN bit pattern,
/// which cannot be a valid legacy capture timestamp, and never falls back to V1.
enum WALFrameCodec {
    static let version2Marker: UInt64 = 0x7ff8_5254_5741_4c32
    static let version2HeaderBytes = 76
    static let version3HeaderBytes = 148

    /// Independently opt-in candidates. Production callers retain V2 until corpus acceptance.
    enum PixelCompression: UInt16, Sendable {
        case disabled = 0, lzfse = 1, lz4 = 2
        var algorithm: compression_algorithm {
            self == .lz4 ? COMPRESSION_LZ4 : COMPRESSION_LZFSE
        }
    }
    static let maximumMetadataBytes = 65_536
    static let maximumFrameBytes: UInt64 = 256 * 1024 * 1024

    struct EncodedRecord {
        let header: Data
        let metadata: Data
        let pixels: Data

        var byteCount: Int64 { Int64(header.count) + Int64(metadata.count) + Int64(pixels.count) }
    }

    struct DecodedRecord {
        let frame: CapturedFrame
        let nextOffset: UInt64
    }

    static func encode(_ frame: CapturedFrame, path: String, compression: PixelCompression = .disabled) throws -> EncodedRecord {
        guard frame.timestamp.timeIntervalSince1970.isFinite,
              frame.width > 0, frame.height > 0, frame.bytesPerRow > 0,
              frame.width <= Int(UInt32.max) / 4, frame.height <= Int(UInt32.max),
              frame.bytesPerRow >= frame.width * 4, frame.bytesPerRow <= Int(UInt32.max),
              frame.height <= Int(maximumFrameBytes) / frame.bytesPerRow,
              frame.imageData.count == frame.height * frame.bytesPerRow,
              validMetadata(frame.metadata) else {
            throw StorageError.fileWriteFailed(path: path, underlying: "Invalid original frame or capture metadata")
        }
        let metadata: Data
        do {
            try frame.metadata.validatedCaptureText(frameWidth: frame.width, frameHeight: frame.height, timestamp: frame.timestamp)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            metadata = try encoder.encode(frame.metadata)
        } catch {
            throw StorageError.fileWriteFailed(path: path, underlying: "Cannot encode complete original metadata")
        }
        guard !metadata.isEmpty, metadata.count <= maximumMetadataBytes else {
            throw StorageError.fileWriteFailed(path: path, underlying: "Original metadata exceeds its bounded record budget")
        }
        var header = Data()
        append(version2Marker, to: &header)
        append(UInt16(2), to: &header)
        append(UInt16(0), to: &header)
        append(UInt32(metadata.count), to: &header)
        append(frame.timestamp.timeIntervalSince1970.bitPattern, to: &header)
        append(UInt32(frame.width), to: &header)
        append(UInt32(frame.height), to: &header)
        append(UInt32(frame.bytesPerRow), to: &header)
        append(UInt32(frame.imageData.count), to: &header)
        append(frame.metadata.displayID, to: &header)
        header.append(contentsOf: SHA256.hash(data: metadata))
        guard compression != .disabled else {
            return EncodedRecord(header: header, metadata: metadata, pixels: frame.imageData)
        }
        // Failure or expansion keeps raw bytes. Each record is independently decodable.
        let compressed = compress(frame.imageData, algorithm: compression.algorithm)
        let useCompressed = compressed.map { $0.count + 72 < frame.imageData.count } ?? false
        let pixels = useCompressed ? compressed! : frame.imageData
        header.replaceSubrange(8..<10, with: [3, 0])
        append(UInt32(pixels.count), to: &header)
        append(useCompressed ? compression.rawValue : UInt16(0), to: &header)
        append(UInt16(0), to: &header)
        header.append(contentsOf: SHA256.hash(data: frame.imageData))
        header.append(contentsOf: SHA256.hash(data: pixels))
        return EncodedRecord(header: header, metadata: metadata, pixels: pixels)
    }

    static func read(handle: FileHandle, path: String, sourceSize: UInt64,
                     offset: UInt64, loadPixels: Bool) throws -> DecodedRecord? {
        guard offset <= sourceSize else { throw failure(path, "Frame offset is outside its original file") }
        guard offset < sourceSize else { return nil }
        guard sourceSize - offset >= 8 else { throw failure(path, "Truncated frame marker at \(offset)") }
        try handle.seek(toOffset: offset)
        let prefix = try readExact(handle, count: 8, path: path)
        let marker: UInt64 = integer(prefix, at: 0)
        if marker == version2Marker {
            return try readVersion2(handle: handle, prefix: prefix, path: path,
                                    sourceSize: sourceSize, offset: offset, loadPixels: loadPixels)
        }
        return try readVersion1(handle: handle, prefix: prefix, path: path,
                                sourceSize: sourceSize, offset: offset, loadPixels: loadPixels)
    }

    private static func readVersion2(handle: FileHandle, prefix: Data, path: String,
                                     sourceSize: UInt64, offset: UInt64, loadPixels: Bool) throws -> DecodedRecord {
        guard sourceSize - offset >= UInt64(version2HeaderBytes) else {
            throw failure(path, "Truncated V2 frame header at \(offset)")
        }
        var header = prefix
        header.append(try readExact(handle, count: version2HeaderBytes - 8, path: path))
        let version: UInt16 = integer(header, at: 8)
        let reserved: UInt16 = integer(header, at: 10)
        let metadataBytes: UInt32 = integer(header, at: 12)
        guard (version == 2 || version == 3), reserved == 0, metadataBytes > 0,
              metadataBytes <= UInt32(maximumMetadataBytes) else {
            throw failure(path, "Unsupported or malformed V2 frame header at \(offset)")
        }
        let timestamp = Double(bitPattern: integer(header, at: 16))
        let width: UInt32 = integer(header, at: 24)
        let height: UInt32 = integer(header, at: 28)
        let bytesPerRow: UInt32 = integer(header, at: 32)
        let dataSize: UInt32 = integer(header, at: 36)
        let displayID: UInt32 = integer(header, at: 40)
        try validateDimensions(timestamp: timestamp, width: width, height: height,
                               bytesPerRow: bytesPerRow, dataSize: dataSize, path: path)
        var storedSize = dataSize
        var codec = PixelCompression.disabled
        if version == 3 {
            guard sourceSize - offset >= UInt64(version3HeaderBytes) else {
                throw failure(path, "Truncated V3 frame header")
            }
            header.append(try readExact(handle, count: version3HeaderBytes - version2HeaderBytes, path: path))
            storedSize = integer(header, at: 76)
            let codecID: UInt16 = integer(header, at: 80)
            let extraReserved: UInt16 = integer(header, at: 82)
            guard let decodedCodec = PixelCompression(rawValue: codecID), extraReserved == 0,
                  storedSize > 0, storedSize <= dataSize,
                  decodedCodec != .disabled || storedSize == dataSize else {
                throw failure(path, "Invalid V3 codec or bounded payload size")
            }
            codec = decodedCodec
        }
        let recordBytes = UInt64(header.count) + UInt64(metadataBytes) + UInt64(storedSize)
        guard recordBytes <= sourceSize - offset else { throw failure(path, "Truncated V2 frame payload at \(offset)") }
        let payload = try readExact(handle, count: Int(metadataBytes), path: path)
        guard Data(SHA256.hash(data: payload)) == header.subdata(in: 44..<76) else {
            throw failure(path, "Original metadata checksum mismatch at \(offset)")
        }
        let metadata: FrameMetadata
        do {
            metadata = try JSONDecoder().decode(FrameMetadata.self, from: payload)
        } catch {
            throw failure(path, "Missing or malformed complete original metadata at \(offset)")
        }
        guard metadata.displayID == displayID, validMetadata(metadata) else {
            throw failure(path, "Original metadata identity mismatch at \(offset)")
        }
        do {
            try metadata.validatedCaptureText(frameWidth: Int(width), frameHeight: Int(height),
                                              timestamp: Date(timeIntervalSince1970: timestamp))
        } catch {
            throw failure(path, "Original direct text does not match its pixel receipt at \(offset)")
        }
        var pixels = Data()
        if loadPixels {
            let stored = try readExact(handle, count: Int(storedSize), path: path)
            if version == 3, Data(SHA256.hash(data: stored)) != header.subdata(in: 116..<148) {
                throw failure(path, "Stored pixel payload checksum mismatch")
            }
            pixels = codec == .disabled ? stored : try decompress(stored, size: Int(dataSize), algorithm: codec.algorithm, path: path)
            if version == 3, Data(SHA256.hash(data: pixels)) != header.subdata(in: 84..<116) {
                throw failure(path, "Original pixel checksum mismatch")
            }
        }
        let frame = CapturedFrame(timestamp: Date(timeIntervalSince1970: timestamp), imageData: pixels,
                                  width: Int(width), height: Int(height), bytesPerRow: Int(bytesPerRow), metadata: metadata)
        return DecodedRecord(frame: frame, nextOffset: offset + recordBytes)
    }

    private static func readVersion1(handle: FileHandle, prefix: Data, path: String,
                                     sourceSize: UInt64, offset: UInt64, loadPixels: Bool) throws -> DecodedRecord {
        guard sourceSize - offset >= 36 else { throw failure(path, "Truncated legacy frame header at \(offset)") }
        var header = prefix
        header.append(try readExact(handle, count: 28, path: path))
        let timestamp = Double(bitPattern: integer(header, at: 0))
        let width: UInt32 = integer(header, at: 8)
        let height: UInt32 = integer(header, at: 12)
        let bytesPerRow: UInt32 = integer(header, at: 16)
        let dataSize: UInt32 = integer(header, at: 20)
        let displayID: UInt32 = integer(header, at: 24)
        let lengths: [UInt16] = [28, 30, 32, 34].map { integer(header, at: $0) }
        try validateDimensions(timestamp: timestamp, width: width, height: height,
                               bytesPerRow: bytesPerRow, dataSize: dataSize, path: path)
        let metadataBytes = lengths.reduce(UInt64(0)) { $0 + UInt64($1) }
        let recordBytes = UInt64(36) + metadataBytes + UInt64(dataSize)
        guard recordBytes <= sourceSize - offset else { throw failure(path, "Truncated legacy frame payload at \(offset)") }
        let strings: [String?] = try lengths.map { length in
            guard length > 0 else { return nil }
            guard let string = String(data: try readExact(handle, count: Int(length), path: path), encoding: .utf8) else {
                throw failure(path, "Invalid UTF-8 legacy frame metadata at \(offset)")
            }
            return string
        }
        let pixels = loadPixels ? try readExact(handle, count: Int(dataSize), path: path) : Data()
        let metadata = FrameMetadata(appBundleID: strings[0], appName: strings[1], windowName: strings[2],
                                     browserURL: strings[3], displayID: displayID)
        let frame = CapturedFrame(timestamp: Date(timeIntervalSince1970: timestamp), imageData: pixels,
                                  width: Int(width), height: Int(height), bytesPerRow: Int(bytesPerRow), metadata: metadata)
        return DecodedRecord(frame: frame, nextOffset: offset + recordBytes)
    }

    private static func compress(_ data: Data, algorithm: compression_algorithm) -> Data? {
        var output = Data(count: data.count)
        let capacity = output.count
        let count = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, algorithm)
            }
        }
        guard count > 0, count < capacity else { return nil }
        output.count = count
        return output
    }

    private static func decompress(_ data: Data, size: Int, algorithm: compression_algorithm, path: String) throws -> Data {
        // One sentinel byte distinguishes an exactly sized stream from an expansion bomb.
        // Dimensions have already bounded size to maximumFrameBytes before allocation.
        var output = Data(count: size + 1)
        let valid = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source -> Bool in
                var stream = compression_stream(dst_ptr: destination.bindMemory(to: UInt8.self).baseAddress!,
                    dst_size: size + 1, src_ptr: source.bindMemory(to: UInt8.self).baseAddress!,
                    src_size: data.count, state: nil)
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { return false }
                defer { compression_stream_destroy(&stream) }
                // Initialization owns state only; bind buffers explicitly after initialization.
                stream.dst_ptr = destination.bindMemory(to: UInt8.self).baseAddress!
                stream.dst_size = size + 1
                stream.src_ptr = source.bindMemory(to: UInt8.self).baseAddress!
                stream.src_size = data.count
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                return status == COMPRESSION_STATUS_END && stream.src_size == 0 && stream.dst_size == 1
            }
        }
        guard valid else { throw failure(path, "Invalid, oversized or trailing compressed original pixels") }
        output.count = size
        return output
    }

    private static func validateDimensions(timestamp: Double, width: UInt32, height: UInt32,
                                           bytesPerRow: UInt32, dataSize: UInt32, path: String) throws {
        guard timestamp.isFinite, width > 0, height > 0,
              UInt64(bytesPerRow) >= UInt64(width) * 4,
              UInt64(dataSize) == UInt64(bytesPerRow) * UInt64(height),
              UInt64(dataSize) <= maximumFrameBytes else {
            throw failure(path, "Invalid original BGRA frame dimensions or payload")
        }
    }

    private static func validMetadata(_ metadata: FrameMetadata) -> Bool {
        // Bound input strings before JSONEncoder allocates its output. The encoded
        // representation has its own stricter byte check after escaping/field names.
        var strings = [metadata.appBundleID, metadata.appName, metadata.windowName,
                       metadata.browserURL, metadata.redactionReason, metadata.capturePolicySHA256]
        if let context = metadata.captureContext {
            guard context.uncertainty.count <= maximumMetadataBytes / 3 else { return false }
            strings += [context.appBundleID, context.appName, context.processGeneration,
                        context.windowGeneration, context.windowTitle, context.documentID,
                        context.paneID, context.safeURL, context.adapter]
            strings += context.uncertainty.map(Optional.some)
        }
        if let identity = metadata.activityIdentity {
            strings += [identity.processGeneration, identity.windowGeneration, identity.documentID, identity.paneID]
        }
        var remaining = maximumMetadataBytes
        for string in strings {
            let count = string?.utf8.count ?? 0
            guard count <= remaining else { return false }
            remaining -= count
        }
        if let monotonic = metadata.captureMonotonicTime, !monotonic.isFinite { return false }
        if let identity = metadata.activityIdentity, !identity.captureMonotonicTime.isFinite { return false }
        if let digest = metadata.capturePolicySHA256 {
            return digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        return true
    }

    private static func readExact(_ handle: FileHandle, count: Int, path: String) throws -> Data {
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw failure(path, "Incomplete bounded original record read")
        }
        return data
    }

    private static func integer<T: FixedWidthInteger>(_ data: Data, at offset: Int) -> T {
        T(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) })
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func failure(_ path: String, _ detail: String) -> StorageError {
        .fileReadFailed(path: path, underlying: detail)
    }
}
