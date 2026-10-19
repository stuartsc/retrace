import Darwin
import Foundation

/// A diagnostic view must never decode an entire multi-gigabyte process log.
/// Reads a bounded tail and only returns complete, individually bounded records.
enum ProcessCPULogReader {
    static let byteLimit = 4 * 1024 * 1024
    static let lineLimit = 128 * 1024
    static let recordLimit = 256
    #if DEBUG
    @TaskLocal static var didReadChunkForTesting: (@Sendable (Int32) -> Void)?
    #endif

    struct Result: Sendable {
        let lines: [Data]
        let bytesRead: Int
        let wasTruncated: Bool
    }

    enum ReadError: Error { case invalidLimits, notRegularFile, changedDuringRead }

    static func readTail(at url: URL, maximumBytes: Int = byteLimit,
                         maximumLineBytes: Int = lineLimit,
                         maximumLines: Int = recordLimit) throws -> Result {
        try Task.checkCancellation()
        guard (1...byteLimit).contains(maximumBytes), (1...lineLimit).contains(maximumLineBytes),
              (1...recordLimit).contains(maximumLines) else { throw ReadError.invalidLimits }
        guard url.isFileURL else { throw ReadError.notRegularFile }
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw ReadError.notRegularFile
        }
        let length = UInt64(info.st_size)
        let start = length > UInt64(maximumBytes) ? length - UInt64(maximumBytes) : 0
        try handle.seek(toOffset: start)
        var remaining = Int(length - start)
        var bytesRead = 0
        var truncated = start > 0
        var discardLine = start > 0 // A tail may begin in the middle of a record.
        var pending = Data()
        var lines: [Data] = []
        var oldestIndex = 0
        while remaining > 0 {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining)), !chunk.isEmpty else {
                throw ReadError.changedDuringRead
            }
            bytesRead += chunk.count
            remaining -= chunk.count
            #if DEBUG
            didReadChunkForTesting?(descriptor)
            #endif
            let parts = chunk.split(separator: 0x0A, omittingEmptySubsequences: false)
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                if !discardLine {
                    if pending.count + part.count > maximumLineBytes {
                        discardLine = true
                        truncated = true
                        pending.removeAll(keepingCapacity: true)
                    } else {
                        pending.append(contentsOf: part)
                    }
                }
                if index < parts.count - 1 {
                    if !discardLine && !pending.isEmpty {
                        if lines.count == maximumLines {
                            lines[oldestIndex] = pending
                            oldestIndex = (oldestIndex + 1) % maximumLines
                            truncated = true
                        } else { lines.append(pending) }
                    }
                    pending = Data()
                    discardLine = false
                }
            }
        }
        // The writer appends a newline after the JSON. An unterminated tail is
        // not a committed record, even when its current bytes happen to parse.
        if !pending.isEmpty || discardLine { truncated = true }
        try Task.checkCancellation()
        let ordered = oldestIndex == 0 ? lines : Array(lines[oldestIndex...]) + Array(lines[..<oldestIndex])
        return Result(lines: ordered, bytesRead: bytesRead, wasTruncated: truncated)
    }
}
