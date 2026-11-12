import Foundation
import Darwin
import Shared

/// Cheap, content-free health read by the dashboard. Filesystem work belongs to
/// the joined original-spool owner and never runs from a view or status getter.
public struct OriginalRetentionSnapshot: Sendable, Equatable {
    public let spool: OriginalSpoolStatus?
    public let notice: String?
    public let coverageNotice: String?
    public let blocked: Bool
    public let skippedScreenUpdates: Int
}

public final class OriginalRetentionStatusHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var spool: OriginalSpoolStatus?
    private var notice: String?
    private var blocked = false
    private var skippedScreenUpdates = 0
    private var coverage = OriginalCaptureCoverageReceipt()

    public var snapshot: OriginalRetentionSnapshot {
        lock.withLock {
            OriginalRetentionSnapshot(spool: spool, notice: notice, coverageNotice: coverageNotice, blocked: blocked,
                                      skippedScreenUpdates: skippedScreenUpdates)
        }
    }

    @discardableResult
    func notePressure(_ pressure: OriginalSpoolPressure) -> OriginalCaptureCoverageReceipt {
        lock.withLock {
            blocked = true
            skippedScreenUpdates += 1
            let now = Date()
            coverage.firstMissedAt = coverage.firstMissedAt ?? now
            coverage.lastMissedAt = now
            switch pressure {
            case .capacityLimit:
                coverage.spoolLimitUpdates += 1
                notice = "Screen capture is waiting for text preparation and archive checks. Original images are retained."
            case .freeSpaceHeadroom:
                coverage.freeSpaceUpdates += 1
                notice = "Screen capture is waiting for disk space to preserve 20 GiB of free space. Original images are retained."
            }
            return coverage
        }
    }

    func noteCaptureResumed() {
        lock.withLock {
            guard blocked else { return }
            blocked = false
            notice = "Screen capture resumed."
        }
    }

    func update(_ status: OriginalSpoolStatus) {
        lock.withLock {
            spool = status
            if !blocked {
                notice = status.unattributedSessions > 0
                    ? "\(status.unattributedSessions) older original-image sessions need recovery verification. They are retained; current recording continues."
                    : nil
            }
        }
    }

    func noteUnverified() {
        lock.withLock {
            guard !blocked else { return }
            notice = "Some original images are retained while archive verification is retried."
        }
    }

    func restoreCoverage(_ receipt: OriginalCaptureCoverageReceipt) {
        lock.withLock {
            coverage = receipt
            skippedScreenUpdates = receipt.spoolLimitUpdates + receipt.freeSpaceUpdates
        }
    }

    private var coverageNotice: String? {
        skippedScreenUpdates > 0
            ? "\(skippedScreenUpdates) screen updates could not be saved while storage was under pressure."
            : nil
    }
}

/// Durable categorical coverage, independent of transient storage/verification
/// notices. Contains counts and wall times only, never screen or audio content.
struct OriginalCaptureCoverageReceipt: Codable, Sendable, Equatable {
    var version = 1
    var spoolLimitUpdates = 0
    var freeSpaceUpdates = 0
    var firstMissedAt: Date?
    var lastMissedAt: Date?
}

actor OriginalCaptureCoverageJournal {
    let url: URL
    init(url: URL) { self.url = url }

    func read() throws -> OriginalCaptureCoverageReceipt {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4_097) ?? Data()
        guard data.count <= 4_096 else { throw CocoaError(.fileReadCorruptFile) }
        let value = try JSONDecoder().decode(OriginalCaptureCoverageReceipt.self, from: data)
        guard value.version == 1, value.spoolLimitUpdates >= 0, value.freeSpaceUpdates >= 0,
              !value.spoolLimitUpdates.addingReportingOverflow(value.freeSpaceUpdates).overflow else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    func persist(_ value: OriginalCaptureCoverageReceipt) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
